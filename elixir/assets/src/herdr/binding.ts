import type { HerdrPane, HerdrSnapshot, SymppBinding, WorkerSession } from "./types";

const inspectorRole = "sympp_inspector";

export function bindingFromPane(pane: HerdrPane): SymppBinding | undefined {
  const tokens = pane.tokens ?? {};
  const role = tokens.sympp_role;
  const agentSessionId = pane.agent_session?.agent === "codex" ? pane.agent_session.value : undefined;
  if ((role !== "architect" && role !== "coordinator") || tokens.sympp_show_inspector !== "true") return undefined;
  if (!tokens.sympp_work_request_id || !tokens.sympp_endpoint || !agentSessionId) return undefined;
  return {
    paneId: pane.pane_id,
    tabId: pane.tab_id,
    workspaceId: pane.workspace_id,
    role,
    workRequestId: tokens.sympp_work_request_id,
    workPackageId: tokens.sympp_work_package_id || undefined,
    endpoint: tokens.sympp_endpoint.replace(/\/$/, ""),
    agentSessionId,
  };
}

export function bindingKey(binding: SymppBinding) {
  return `${binding.agentSessionId}:${binding.workRequestId}`;
}

export function inspectorPane(pane: HerdrPane, tabId?: string) {
  return pane.tokens?.[inspectorRole] === "true" && (!tabId || pane.tokens.sympp_inspector_tab_id === tabId);
}

export function bindingForTab(snapshot: HerdrSnapshot, tabId: string, previousPaneId?: string) {
  const candidates = snapshot.panes.filter((pane) => pane.tab_id === tabId).flatMap((pane) => {
    const binding = bindingFromPane(pane);
    return binding ? [binding] : [];
  });
  const focused = snapshot.layouts?.find((layout) => layout.tab_id === tabId)?.focused_pane_id;
  return candidates.find((binding) => binding.paneId === focused)
    ?? candidates.find((binding) => binding.paneId === previousPaneId)
    ?? (candidates.length === 1 ? candidates[0] : undefined);
}

export function exactWorkerPaneId(snapshot: HerdrSnapshot | undefined, sessions: WorkerSession[] | undefined, workPackageId: string) {
  const session = sessions?.find((candidate) => candidate.work_package_id === workPackageId)?.agent_session_id;
  if (!snapshot || !session) return undefined;
  const matches = snapshot.panes.filter((pane) => pane.agent_session?.agent === "codex" && pane.agent_session.value === session);
  return matches.length === 1 ? matches[0].pane_id : undefined;
}
