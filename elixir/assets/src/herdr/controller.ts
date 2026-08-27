import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";

import { bindingForTab, bindingKey, inspectorPane } from "./binding";
import { HerdrClient, snapshotFromResponse } from "./herdr-client";
import type { HerdrEvent, HerdrSnapshot } from "./types";

type TabState = {
  inspectorPaneId?: string;
  failedInspectorPaneId?: string;
  ownerPaneId?: string;
  bindingKey?: string;
  suppressedBindingKey?: string;
};

type ControllerState = { tabs: Record<string, TabState> };
type ControllerLock = { path: string; token: string };

const pluginId = "symphony-plus-plus.execution-inspector";

export async function runController(env = process.env) {
  const socketPath = env.HERDR_SOCKET_PATH;
  const stateDir = env.HERDR_PLUGIN_STATE_DIR;
  const pluginRoot = env.HERDR_PLUGIN_ROOT;
  if (!socketPath || !stateDir || !pluginRoot) return;
  fs.mkdirSync(stateDir, { recursive: true });
  const stateName = `controller-${createHash("sha256").update(socketPath).digest("hex").slice(0, 12)}`;
  const lockPath = path.join(stateDir, `${stateName}.lock`);
  const lock = await acquireControllerLock(lockPath);

  try {
    const client = new HerdrClient(socketPath);
    const snapshot = snapshotFromResponse(await client.request("session.snapshot"));
    const statePath = path.join(stateDir, `${stateName}.json`);
    const state = reconcileClosedPane(readState(statePath), parseEvent(env.HERDR_PLUGIN_EVENT_JSON), snapshot);
    await reconcile(client, snapshot, state, windowsDrivePath(pluginRoot));
    writeState(statePath, state);
    client.close();
  } finally {
    releaseControllerLock(lock);
  }
}

async function acquireControllerLock(lockPath: string) {
  const repairPath = `${lockPath}.repair`;
  while (true) {
    repairAbandonedControllerLock(repairPath);
    if (fs.existsSync(repairPath)) {
      await new Promise((resolve) => setTimeout(resolve, 25));
      continue;
    }
    const lock = tryCreateControllerLock(lockPath);
    if (lock) return lock;
    const owner = controllerLockOwner(lockPath);
    if (owner && !processRunning(owner.pid)) {
      const repair = tryCreateControllerLock(repairPath);
      if (repair) {
        try {
          removeControllerLock(lockPath, owner.token);
        } finally {
          releaseControllerLock(repair);
        }
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

function tryCreateControllerLock(lockPath: string): ControllerLock | undefined {
  const token = `${process.pid}:${process.hrtime.bigint()}`;
  try {
    fs.writeFileSync(lockPath, token, { flag: "wx" });
    return { path: lockPath, token };
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") return undefined;
    throw error;
  }
}

function controllerLockOwner(lockPath: string) {
  try {
    const token = fs.readFileSync(lockPath, "utf8");
    return { token, pid: Number.parseInt(token, 10) };
  } catch {
    return undefined;
  }
}

function repairAbandonedControllerLock(lockPath: string) {
  const owner = controllerLockOwner(lockPath);
  if (owner && !processRunning(owner.pid)) quarantineControllerLock(lockPath, owner.token);
}

export function quarantineControllerLock(lockPath: string, token: string) {
  const quarantine = `${lockPath}.stale-${createHash("sha256").update(token).digest("hex").slice(0, 16)}`;
  try {
    fs.linkSync(lockPath, quarantine);
    if (fs.readFileSync(quarantine, "utf8") === token) fs.unlinkSync(lockPath);
  } catch { /* another controller already fenced this exact stale owner */ }
}

function removeControllerLock(lockPath: string, token: string) {
  try {
    if (fs.readFileSync(lockPath, "utf8") === token) fs.unlinkSync(lockPath);
  } catch { /* another controller already released it */ }
}

function releaseControllerLock(lock: ControllerLock) {
  removeControllerLock(lock.path, lock.token);
}

function processRunning(pid: number) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

function readState(statePath: string): ControllerState {
  try {
    const parsed = JSON.parse(fs.readFileSync(statePath, "utf8")) as Partial<ControllerState> | null;
    const tabs = parsed?.tabs;
    if (!tabs || typeof tabs !== "object" || Array.isArray(tabs)) return { tabs: {} };
    const entries = Object.entries(tabs).filter(([, tab]) => tab && typeof tab === "object" && !Array.isArray(tab));
    return { tabs: Object.fromEntries(entries) };
  } catch {
    return { tabs: {} };
  }
}

function writeState(statePath: string, state: ControllerState) {
  const next = `${statePath}.${process.pid}.tmp`;
  fs.writeFileSync(next, JSON.stringify(state));
  fs.renameSync(next, statePath);
}

function parseEvent(value: string | undefined): HerdrEvent | undefined {
  if (!value) return undefined;
  try {
    return JSON.parse(value) as HerdrEvent;
  } catch {
    return undefined;
  }
}

export function reconcileClosedPane(state: ControllerState, event?: HerdrEvent, snapshot?: HerdrSnapshot) {
  const tabId = eventValue(event, "tab.closed", "tab_id");
  if (tabId) delete state.tabs[tabId];
  const exitedPaneId = eventValue(event, "pane.exited", "pane_id");
  if (exitedPaneId) markInspectorFailure(state, exitedPaneId);
  const paneId = eventValue(event, "pane.closed", "pane_id");
  if (paneId) reconcileInspectorClose(state, paneId, snapshot);
  return state;
}

function markInspectorFailure(state: ControllerState, paneId: string) {
  for (const tab of Object.values(state.tabs)) {
    if (tab.inspectorPaneId === paneId) tab.failedInspectorPaneId = paneId;
  }
}

function reconcileInspectorClose(state: ControllerState, paneId: string, snapshot?: HerdrSnapshot) {
  for (const [tabId, tab] of Object.entries(state.tabs)) {
    if (tab.inspectorPaneId !== paneId) continue;
    const failed = tab.failedInspectorPaneId === paneId;
    tab.inspectorPaneId = undefined;
    tab.failedInspectorPaneId = undefined;
    const active = snapshot && bindingForTab(snapshot, tabId, tab.ownerPaneId);
    if (!failed && (!snapshot || (active && bindingKey(active) === tab.bindingKey))) tab.suppressedBindingKey = tab.bindingKey;
  }
}

async function reconcile(client: HerdrClient, snapshot: HerdrSnapshot, state: ControllerState, pluginRoot: string) {
  const tabIds = new Set(snapshot.panes.map((pane) => pane.tab_id));
  for (const tabId of Object.keys(state.tabs)) if (!tabIds.has(tabId)) delete state.tabs[tabId];

  for (const tabId of tabIds) {
    const tab = state.tabs[tabId] ?? {};
    state.tabs[tabId] = tab;
    await reconcileTab(client, snapshot, tabId, tab, pluginRoot);
  }
}

async function reconcileTab(client: HerdrClient, snapshot: HerdrSnapshot, tabId: string, tab: TabState, pluginRoot: string) {
  const existing = snapshot.panes.find((pane) => pane.tab_id === tabId && inspectorPane(pane, tabId));
  if (existing) tab.inspectorPaneId = existing.pane_id;
  else if (tab.inspectorPaneId && !snapshot.panes.some((pane) => pane.pane_id === tab.inspectorPaneId)) tab.inspectorPaneId = undefined;

  const binding = bindingForTab(snapshot, tabId, tab.ownerPaneId);
  if (!binding) return;
  const key = bindingKey(binding);
  tab.ownerPaneId = binding.paneId;
  tab.bindingKey = key;
  if (tab.inspectorPaneId || tab.suppressedBindingKey === key) return;

  const result = await client.request("plugin.pane.open", {
    plugin_id: pluginId,
    entrypoint: "execution-inspector",
    placement: "split",
    target_pane_id: binding.paneId,
    direction: "right",
    focus: false,
    cwd: pluginRoot,
    env: {
      SYMPP_TARGET_TAB_ID: binding.tabId,
      SYMPP_TARGET_PANE_ID: binding.paneId,
      SYMPP_TARGET_WORK_REQUEST_ID: binding.workRequestId,
      SYMPP_TARGET_ENDPOINT: binding.endpoint,
    },
  }) as { plugin_pane?: { pane?: { pane_id?: string } } } | undefined;
  tab.inspectorPaneId = result?.plugin_pane?.pane?.pane_id;
}

export function windowsDrivePath(value: string) {
  return value.startsWith("\\\\?\\") ? value.slice(4) : value;
}

function eventIs(event: HerdrEvent | undefined, name: string) {
  return event?.event === name || event?.event === name.replace(".", "_");
}

function eventValue(event: HerdrEvent | undefined, name: string, key: string) {
  const value = event?.data?.[key];
  return eventIs(event, name) && typeof value === "string" ? value : undefined;
}
