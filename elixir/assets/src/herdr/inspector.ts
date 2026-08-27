import { executionFrontierProjection } from "@/dashboard/execution-graph/frontier";
import { workRequestExecutionGraphModel } from "@/dashboard/execution-graph/adapter";
import type { WorkRequestDetail as DashboardWorkRequestDetail } from "@/types/dashboard";

import { bindingForTab, bindingFromPane, bindingKey, exactWorkerPaneId } from "./binding";
import { HerdrClient, snapshotFromResponse } from "./herdr-client";
import { renderInspector } from "./render";
import type { HerdrEvent, HerdrSnapshot, InspectorState, WorkRequestDetail } from "./types";

const pluginId = "symphony-plus-plus.execution-inspector";

export async function runInspector(env = process.env) {
  const socketPath = env.HERDR_SOCKET_PATH;
  const paneId = env.HERDR_PANE_ID;
  const tabId = env.SYMPP_TARGET_TAB_ID;
  if (!socketPath || !paneId || !tabId) throw new Error("Herdr did not provide the inspector pane context");

  const client = new HerdrClient(socketPath);
  let snapshot = snapshotFromResponse(await client.request("session.snapshot"));
  const initial = initialBinding(snapshot, env);
  if (!initial) throw new Error("The bound Symphony++ pane is no longer available");
  const state: InspectorState = { binding: initial, pinned: false, snapshot };
  let detailAbort = new AbortController();
  let transition = Promise.resolve();
  const serialize = (action: () => Promise<void>) => transition = transition.then(action, action);
  const watch = () => void watchSympp(state, () => refreshDetail(state, detailAbort.signal).then(() => draw(state)), detailAbort.signal);
  const rebind = async (next: typeof initial) => {
    state.binding = next;
    detailAbort.abort();
    detailAbort = new AbortController();
    state.detail = undefined;
    state.error = undefined;
    await refreshDetail(state, detailAbort.signal);
    watch();
  };
  const close = () => client.request("plugin.pane.close", { pane_id: paneId });

  await client.request("pane.report_metadata", {
    pane_id: paneId,
    source: `plugin:${pluginId}`,
    title: "Symphony++",
    tokens: { sympp_inspector: "true", sympp_inspector_tab_id: tabId },
  });
  await refreshDetail(state, detailAbort.signal);
  draw(state);
  watch();

  await client.subscribe(["pane.created", "pane.focused", "pane.updated", "pane.closed", "pane.moved", "pane.agent_detected"], async (message) => {
    const event = message as HerdrEvent;
    if (!relevantHerdrEvent(event)) return;
    await serialize(async () => {
      snapshot = snapshotFromResponse(await client.request("session.snapshot"));
      state.snapshot = snapshot;
      const ownerPane = snapshot.panes.find((pane) => pane.pane_id === state.binding.paneId);
      const ownerBinding = ownerPane ? bindingFromPane(ownerPane) : undefined;
      const next = bindingForTab(snapshot, tabId, state.binding.paneId);
      if (!state.pinned && !next) {
        await close();
        return;
      }
      if (state.pinned && ownerBinding && bindingKey(ownerBinding) === bindingKey(state.binding) && ownerBinding.endpoint !== state.binding.endpoint) {
        await rebind({ ...state.binding, endpoint: ownerBinding.endpoint });
      } else if (!state.pinned && next && bindingChanged(next, state.binding)) {
        await rebind(next);
      }
      draw(state);
    });
  });

  listenForInput(state, client, paneId, async () => {
    await serialize(async () => {
      if (!state.pinned) {
        state.pinned = true;
        return;
      }
      state.pinned = false;
      state.snapshot = snapshotFromResponse(await client.request("session.snapshot"));
      const next = bindingForTab(state.snapshot, tabId, state.binding.paneId);
      if (!next) {
        await close();
        return;
      }
      if (bindingChanged(next, state.binding)) await rebind(next);
    });
  }, () => draw(state));
  process.stdout.on("resize", () => draw(state));
  process.on("exit", () => process.stdout.write("\u001b[?25h\u001b[0m"));
}

function bindingChanged(left: ReturnType<typeof bindingFromPane>, right: ReturnType<typeof bindingFromPane>) {
  return Boolean(left && right && (bindingKey(left) !== bindingKey(right) || left.endpoint !== right.endpoint));
}

function initialBinding(snapshot: HerdrSnapshot, env: NodeJS.ProcessEnv) {
  const target = snapshot.panes.find((pane) => pane.pane_id === env.SYMPP_TARGET_PANE_ID);
  return target ? bindingFromPane(target) : undefined;
}

async function refreshDetail(state: InspectorState, signal: AbortSignal) {
  try {
    const response = await fetch(`${state.binding.endpoint}/api/v1/sympp/herdr/work-requests/${encodeURIComponent(state.binding.workRequestId)}`, {
      signal: AbortSignal.any([signal, AbortSignal.timeout(10_000)]),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const detail = await response.json() as WorkRequestDetail;
    state.detail = {
      ...detail,
      execution_graph: workRequestExecutionGraphModel(detail as unknown as DashboardWorkRequestDetail, { includeHistorical: true }),
    };
    const ids = selectableIds(state);
    if (!state.selectedId || !ids.includes(state.selectedId)) state.selectedId = ids[0];
    state.error = undefined;
  } catch (error) {
    if ((error as Error).name !== "AbortError") state.error = "Ledger unavailable";
  }
}

async function watchSympp(state: InspectorState, invalidate: () => void, signal: AbortSignal) {
  while (!signal.aborted) {
    let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    try {
      const response = await fetch(`${state.binding.endpoint}/api/v1/sympp/herdr/events`, { signal });
      if (!response.ok || !response.body) throw new Error("event stream unavailable");
      reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      while (!signal.aborted) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const events = buffer.split("\n\n");
        buffer = events.pop() ?? "";
        if (events.some((event) => event.includes("event: invalidated"))) invalidate();
      }
    } catch (error) {
      if ((error as Error).name === "AbortError") return;
    } finally {
      await closeReader(reader);
    }
    await delay(1000, signal);
  }
}

async function closeReader(reader?: ReadableStreamDefaultReader<Uint8Array>) {
  if (!reader) return;
  try { await reader.cancel(); } catch { /* The stream is already closed. */ }
  try { reader.releaseLock(); } catch { /* The reader already released its lock. */ }
}

function listenForInput(
  state: InspectorState,
  client: HerdrClient,
  paneId: string,
  togglePin: () => Promise<void>,
  redraw: () => void,
) {
  process.stdin.resume();
  process.stdin.setEncoding("utf8");
  if (process.stdin.isTTY) process.stdin.setRawMode(true);
  process.stdin.on("data", (key: string) => void handleKey(key, state, client, paneId, togglePin).then(redraw, redraw));
}

async function handleKey(key: string, state: InspectorState, client: HerdrClient, paneId: string, togglePin: () => Promise<void>) {
  switch (key) {
    case "q": case "\u0003": await client.request("plugin.pane.close", { pane_id: paneId }); break;
    case "p": await togglePin(); break;
    case "\u001b[A": case "k": moveSelection(state, -1); break;
    case "\u001b[B": case "j": moveSelection(state, 1); break;
    case "\r": case "\n": await focusSelectedWorker(state, client); break;
  }
}

async function focusSelectedWorker(state: InspectorState, client: HerdrClient) {
  state.snapshot = snapshotFromResponse(await client.request("session.snapshot"));
  const paneId = state.selectedId
    ? exactWorkerPaneId(state.snapshot, state.detail?.worker_sessions, state.selectedId)
    : undefined;
  if (paneId) await client.request("pane.focus", { pane_id: paneId });
}

function moveSelection(state: InspectorState, offset: number) {
  const ids = selectableIds(state);
  if (!ids.length) return;
  const index = Math.max(0, ids.indexOf(state.selectedId ?? ids[0]));
  state.selectedId = ids[(index + offset + ids.length) % ids.length];
}

function selectableIds(state: InspectorState) {
  if (!state.detail) return [];
  const projection = executionFrontierProjection(state.detail.execution_graph, new Set(state.detail.attention_keys ?? []), "forward-2");
  return projection.presentation === "graph" ? projection.visibleWorkPackageIds : projection.model.work_packages.map((pkg) => pkg.id);
}

function relevantHerdrEvent(event: HerdrEvent) {
  const name = event.event ?? "";
  return ["pane.created", "pane.focused", "pane.updated", "pane.closed", "pane.moved", "pane.agent_detected"]
    .some((eventName) => name === eventName || name === eventName.replace(".", "_"));
}

function draw(state: InspectorState) {
  const output = renderInspector(state, process.stdout.columns || 80, process.stdout.rows || 24);
  process.stdout.write(`\u001b[?25l\u001b[H\u001b[2J${output}`);
}

function delay(milliseconds: number, signal: AbortSignal) {
  return new Promise<void>((resolve) => {
    const timeout = setTimeout(resolve, milliseconds);
    signal.addEventListener("abort", () => {
      clearTimeout(timeout);
      resolve();
    }, { once: true });
  });
}
