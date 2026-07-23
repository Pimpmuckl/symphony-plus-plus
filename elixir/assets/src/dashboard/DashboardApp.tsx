import type { ArchitectHandoffPayload, ContextComment, CopyArchitectHandoff, CreateWorkRequestPayload, DashboardMutationPayload, DashboardPayload, GuidanceAnswerSubmission, GuidanceItem } from "@/types/dashboard";
import type { NewRequestForm } from "@/components/dashboard/new-request-dialog";
import type * as React from "react";
import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import { CardDetailSelection, DASHBOARD_RECONNECT_GRACE_MS, DashboardConnectionIssue, DashboardResponseSelector, DashboardRuntimeConfig, ResolveContextComment, SubmitContextComment, WorkPackageArchiveMutation, WorkPackageBlockerClearMutation, WorkPackageStateMutation, WorkRequestMutation, WorkRequestStateMutation, WorkspaceTab, copyTextToClipboard, createLatestTaskQueue, dashboardCaughtMessage, dashboardEventsUrl, dashboardMutationWorkRequest, dashboardRefreshPath, dashboardRuntimeConfig, enqueueLatestTask, ensureDashboardRuntimeConfig, isReconnectableLocalOperatorError, jsonHeaders, mergeDashboardPayload, mutationHeaders, mutationShouldRefreshDashboard, operatorApiUrl, operatorFetch, patchDashboardWorkRequest, readDashboardApiResponse, reconnectLocalOperatorSession, removeDashboardWorkRequest, withLocalOperatorReconnect } from "./runtime";
import { DashboardShell } from "./dashboard-shell";
import { DashboardDebugTools } from "./dashboard-debug-tools";
import { SoloSessions } from "./solo-sessions";
import { WorkstreamsPane } from "./workspace-tabs";
import {
  activeBlockerItems,
  allGuidanceItems,
  allPackages,
  dashboardContentFingerprint,
  guidanceAnswerUrl,
  repoSummaries,
} from "./dashboard-data";
import { appDialogReducer, appStateReducer, createInitialAppState, initialAppDialogState } from "./dashboard-state";
import { applyDashboardTheme, repoWorkstreamHasWorkItems, shouldShowUpdateSimulationControls, writeDashboardUiStateValue, writeStoredTheme } from "./dashboard-persistence";
import { canMutateDashboardComments, canMutateDashboardOperatorActions } from "./detail-utils";
import { useDashboardOperatorSettings } from "./dashboard-operator-settings";
import { filterWorkstreamsBySearch } from "./dashboard-search";
import { activeWorkRequestDetails, packageSelectionIndex, requestDetailsByRepoKey } from "./workstream-data";
import { useDashboardUpdateAnimations } from "./update-animations";
import { useDashboardSurfaceLoading } from "./dashboard-surface-loading";
import { createDashboardEventRefresh } from "./dashboard-demand-loading";
type DashboardLoadMode = "initial" | "refresh" | "silent" | "reconnect";
function mergeDashboardLoadMode(pending: DashboardLoadMode, next: DashboardLoadMode) {
  return pending === "reconnect" || next === "reconnect" ? "reconnect" : next;
}
export function DashboardApp() { return <><DashboardDebugTools /><DashboardShell {...useDashboardController()} /></>; }
function useDashboardController() {
  const [appState, dispatchApp] = useReducer(appStateReducer, null, createInitialAppState);
  const { dashboard, error, hideEmptyWorkstreams, loading, refreshing, showWelcomeToast, showWorkstreamContextBar, theme, workspaceTab } = appState;
  const [dialogState, dispatchDialog] = useReducer(appDialogReducer, initialAppDialogState);
  const [connectionIssue, setConnectionIssue] = useState<DashboardConnectionIssue | null>(null);
  const [dashboardSearchQuery, setDashboardSearchQuery] = useState("");
  const [surfaceRefreshVersion, setSurfaceRefreshVersion] = useState(0);
  const [animationBaselineReady, setAnimationBaselineReady] = useState(false);
  const showUpdateSimulationControls = useMemo(() => shouldShowUpdateSimulationControls(), []);
  const [runtimeConfig, setRuntimeConfig] = useState<DashboardRuntimeConfig | undefined>(() => dashboardRuntimeConfig);
  const canMutateOperatorActions = canMutateDashboardOperatorActions(runtimeConfig);
  const dashboardRef = useRef<DashboardPayload | null>(dashboard);
  const initialDashboardFingerprint = useMemo(() => dashboardContentFingerprint(dashboard), [dashboard]);
  const dashboardFingerprintRef = useRef(initialDashboardFingerprint);
  const connectionIssueRef = useRef<DashboardConnectionIssue | null>(null);
  const failureVersionRef = useRef(0);
  const refreshQueueRef = useRef(createLatestTaskQueue<DashboardLoadMode>());
  const loadSequenceRef = useRef(0);
  const deferredLoadSequenceRef = useRef(0);
  const refreshingSequenceRef = useRef(0);
  const mutationVersionRef = useRef(0);
  const setDashboard = useCallback((nextDashboard: DashboardPayload | null) => {
    const nextFingerprint = dashboardContentFingerprint(nextDashboard);
    if (dashboardFingerprintRef.current === nextFingerprint) return;
    dashboardFingerprintRef.current = nextFingerprint;
    dashboardRef.current = nextDashboard;
    setAnimationBaselineReady((ready) => ready || Boolean(nextDashboard && !nextDashboard.deferred?.dashboard_sections));
    dispatchApp({ type: "patch", state: { dashboard: nextDashboard } });
  }, []);
  const setLoading = useCallback((nextLoading: boolean) => dispatchApp({ type: "patch", state: { loading: nextLoading } }), []);
  const setRefreshing = useCallback((nextRefreshing: boolean) => dispatchApp({ type: "patch", state: { refreshing: nextRefreshing } }), []);
  const setError = useCallback((nextError: string | null) => dispatchApp({ type: "patch", state: { error: nextError } }), []);
  const clearConnectionFailure = useCallback((failureVersion = failureVersionRef.current) => { if (failureVersion !== failureVersionRef.current) return; connectionIssueRef.current = null; setConnectionIssue(null); setError(null); }, [setError]);
  const setWorkspaceTab = useCallback((nextWorkspaceTab: WorkspaceTab) => dispatchApp({ type: "patch", state: { workspaceTab: nextWorkspaceTab } }), []);
  const updateDashboardSearchQuery = useCallback((query: string) => {
    setDashboardSearchQuery(query);
    if (query.trim()) setWorkspaceTab("workstreams");
  }, [setWorkspaceTab]);
  const setHideEmptyWorkstreams = useCallback((nextHideEmptyWorkstreams: boolean) => dispatchApp({ type: "patch", state: { hideEmptyWorkstreams: nextHideEmptyWorkstreams } }), []);
  const setShowWorkstreamContextBar = useCallback((nextShowWorkstreamContextBar: boolean) => dispatchApp({ type: "patch", state: { showWorkstreamContextBar: nextShowWorkstreamContextBar } }), []);
  const setShowWelcomeToast = useCallback((nextShowWelcomeToast: boolean) => dispatchApp({ type: "patch", state: { showWelcomeToast: nextShowWelcomeToast } }), []);
  const setSelectedGuidance = useCallback((selectedGuidance: GuidanceItem | null) => dispatchDialog({ type: "guidance", selectedGuidance }), []);
  const setSelectedCardDetail = useCallback((selectedCardDetail: CardDetailSelection | null) => dispatchDialog({ type: "cardDetail", selectedCardDetail }), []);
  const setNewRequestOpen = useCallback((open: boolean) => dispatchDialog({ type: "newRequest", open }), []);
  useEffect(() => {
    connectionIssueRef.current = connectionIssue;
  }, [connectionIssue]);
  const recordConnectionFailure = useCallback(
    (message: string, immediate = false, reconnectableLocalSession = false) => {
      failureVersionRef.current += 1;
      const now = Date.now();
      const canGrace = !immediate && Boolean(dashboardRef.current);
      if (!canGrace) {
        setConnectionIssue(null);
        setError(message);
        return;
      }
      const currentIssue = connectionIssueRef.current;
      const firstFailedAt = currentIssue?.firstFailedAt ?? now;
      const nextIssue = { firstFailedAt, lastFailedAt: now, message, reconnectableLocalSession };
      setConnectionIssue(nextIssue);
      if (now - firstFailedAt >= DASHBOARD_RECONNECT_GRACE_MS) {
        setError(message);
      } else {
        setError(null);
      }
    },
    [setError],
  );
  useEffect(() => {
    let cancelled = false;

    void ensureDashboardRuntimeConfig().then((config) => {
      if (!cancelled) setRuntimeConfig(config);
    });

    return () => {
      cancelled = true;
    };
  }, []);
  const applyDashboardResponse = useCallback(
    async (response: Response, fallbackMessage: string, selectDashboard: DashboardResponseSelector = (payload) => payload as DashboardPayload, loadMutationVersion = mutationVersionRef.current, shouldApply: () => boolean = () => true, failureVersion = failureVersionRef.current) => {
      const payload = await readDashboardApiResponse(response, fallbackMessage);
      if (!shouldApply()) return null;
      const nextDashboard = selectDashboard(payload);
      if (!nextDashboard) {
        throw new Error(fallbackMessage);
      }
      if (loadMutationVersion !== mutationVersionRef.current) return nextDashboard;
      setDashboard(mergeDashboardPayload(dashboardRef.current, nextDashboard));
      clearConnectionFailure(failureVersion);
      return nextDashboard;
    },
    [clearConnectionFailure, setDashboard],
  );

  const recordDashboardLoadFailure = useCallback((loadSequence: number, caught: unknown, mode: DashboardLoadMode) => {
    if (loadSequence !== loadSequenceRef.current) return;
    recordConnectionFailure(dashboardCaughtMessage(caught, "Dashboard API unavailable"), mode === "initial" || mode === "reconnect", isReconnectableLocalOperatorError(caught));
  }, [recordConnectionFailure]);

  const runDashboardLoad = useCallback(async (mode: DashboardLoadMode) => {
    const failureVersion = failureVersionRef.current;
    const loadMutationVersion = mutationVersionRef.current;
    const loadSequence = loadSequenceRef.current + 1;
    const showsRefreshing = mode === "refresh" || mode === "reconnect";
    loadSequenceRef.current = loadSequence;
    if (mode === "initial") {
      setLoading(true);
    } else if (showsRefreshing) {
      refreshingSequenceRef.current = loadSequence;
      setRefreshing(true);
    }

    try {
      await withLocalOperatorReconnect(async () => {
        const config = mode === "reconnect" ? await reconnectLocalOperatorSession() : await ensureDashboardRuntimeConfig();
        setRuntimeConfig(config);
        const response = await operatorFetch(operatorApiUrl(dashboardRefreshPath()), { headers: jsonHeaders() });
        if (loadSequence !== loadSequenceRef.current) return;
        const loaded = await applyDashboardResponse(response, "Dashboard API unavailable", undefined, loadMutationVersion, () => loadSequence === loadSequenceRef.current, failureVersion);
        if (loaded) setSurfaceRefreshVersion((version) => version + 1);
      });
    } catch (caught) {
      recordDashboardLoadFailure(loadSequence, caught, mode);
    } finally {
      if (loadSequence === loadSequenceRef.current) {
        setLoading(false);
      }
      if (showsRefreshing && refreshingSequenceRef.current === loadSequence) {
        refreshingSequenceRef.current = 0;
        setRefreshing(false);
      }
    }
  }, [applyDashboardResponse, recordDashboardLoadFailure, setLoading, setRefreshing]);

  const loadDashboard = useCallback(
    (mode: DashboardLoadMode = "refresh") =>
      enqueueLatestTask(refreshQueueRef.current, mode, runDashboardLoad, mergeDashboardLoadMode),
    [runDashboardLoad],
  );

  const loadDashboardDeferred = useCallback(async () => {
    const baseDashboard = dashboardRef.current;
    if (!baseDashboard?.deferred?.dashboard_sections) return;
    const failureVersion = failureVersionRef.current;
    const loadSequence = deferredLoadSequenceRef.current + 1;
    deferredLoadSequenceRef.current = loadSequence;

    try {
      await withLocalOperatorReconnect(async () => {
        const response = await operatorFetch(operatorApiUrl("/dashboard/deferred"), { headers: jsonHeaders() });
        const payload = await readDashboardApiResponse(response, "Dashboard details unavailable");
        if (loadSequence !== deferredLoadSequenceRef.current || dashboardRef.current !== baseDashboard) return;
        const nextDashboard = mergeDashboardPayload(dashboardRef.current, payload as DashboardPayload);
        if (nextDashboard) setDashboard(nextDashboard);
        clearConnectionFailure(failureVersion);
      });
    } catch (caught) {
      if (loadSequence !== deferredLoadSequenceRef.current) return;
      recordConnectionFailure(dashboardCaughtMessage(caught, "Dashboard details unavailable"), false, isReconnectableLocalOperatorError(caught));
    }
  }, [clearConnectionFailure, recordConnectionFailure, setDashboard]);

  const { archivedLoading, loadArchived, soloLoading } = useDashboardSurfaceLoading({
    dashboardRef,
    clearFailure: clearConnectionFailure,
    failureVersionRef,
    recordFailure: recordConnectionFailure,
    refreshVersion: surfaceRefreshVersion,
    setDashboard,
    soloOpen: dashboard !== null && workspaceTab === "solo",
  });

  const refreshAfterMutation = useCallback(async (payload?: DashboardMutationPayload) => {
    if (payload?.dashboard) {
      setDashboard(payload.dashboard);
      clearConnectionFailure();
      return;
    }

    if (!mutationShouldRefreshDashboard(payload)) {
      clearConnectionFailure();
      return;
    }

    await loadDashboard("refresh");
  }, [clearConnectionFailure, loadDashboard, setDashboard]);

  const mutateWorkRequest = useCallback(
    async (workRequestId: string, action: "archive" | "delete" | "state", body: Record<string, unknown>, fallbackMessage: string, options: { archive?: boolean; remove?: boolean } = {}) => {
      const payload = (await withLocalOperatorReconnect(async () => {
        const response = await operatorFetch(operatorApiUrl(`/work-requests/${encodeURIComponent(workRequestId)}/${action}`), {
          method: "POST",
          headers: await mutationHeaders(),
          body: JSON.stringify(body),
        });
        return readDashboardApiResponse(response, fallbackMessage);
      })) as DashboardMutationPayload;

      const workRequest = dashboardMutationWorkRequest(payload);
      mutationVersionRef.current += 1;
      if (options.remove) setDashboard(removeDashboardWorkRequest(dashboardRef.current, workRequestId));
      else if (workRequest) setDashboard(patchDashboardWorkRequest(dashboardRef.current, workRequest, options));
      clearConnectionFailure();
      setSelectedCardDetail(null);
      if (mutationShouldRefreshDashboard(payload)) void loadDashboard("silent");
    },
    [clearConnectionFailure, loadDashboard, setDashboard, setSelectedCardDetail],
  );
  const submitGuidanceAnswer = useCallback(async (item: GuidanceItem, submission: GuidanceAnswerSubmission) => {
    await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(guidanceAnswerUrl(item), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify(submission),
      });
      const payload = (await readDashboardApiResponse(response, "Answer was not recorded")) as DashboardMutationPayload;
      await refreshAfterMutation(payload);
    });
    setSelectedGuidance(null);
  }, [refreshAfterMutation, setSelectedGuidance]);

  const createWorkRequest = useCallback(async (form: NewRequestForm) => {
    const payload = (await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl("/work-requests"), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify(form),
      });
      return readDashboardApiResponse(response, "Request was not created");
    })) as CreateWorkRequestPayload;

    if (!payload.work_request) {
      throw new Error("Request was created, but the dashboard response was incomplete");
    }

    await refreshAfterMutation(payload);
    return payload.work_request;
  }, [refreshAfterMutation]);

  const submitComment = useCallback<SubmitContextComment>(async (target, body) => {
    const payload = (await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl("/comments"), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({
          target_kind: target.target_kind,
          target_id: target.target_id,
          body,
        }),
      });
      return readDashboardApiResponse(response, "Comment was not recorded");
    })) as { comment?: ContextComment } & DashboardMutationPayload;

    if (!payload.comment) {
      throw new Error("Comment was recorded, but the dashboard response was incomplete");
    }

    await refreshAfterMutation(payload);
    return payload.comment;
  }, [refreshAfterMutation]);

  const resolveComment = useCallback<ResolveContextComment>(async (commentId, resolutionNote) => {
    const payload = (await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl(`/comments/${encodeURIComponent(commentId)}/resolve`), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({
          resolution_note: resolutionNote || "",
        }),
      });
      return readDashboardApiResponse(response, "Comment was not resolved");
    })) as { comment?: ContextComment } & DashboardMutationPayload;

    if (!payload.comment) {
      throw new Error("Comment was resolved, but the dashboard response was incomplete");
    }

    await refreshAfterMutation(payload);
    return payload.comment;
  }, [refreshAfterMutation]);

  const copyArchitectHandoff = useCallback<CopyArchitectHandoff>(async (workRequestId, cachedHandoff) => {
    let handoff = cachedHandoff || null;
    let refreshPayload: DashboardMutationPayload | undefined;

    if (!handoff) {
      const payload = (await withLocalOperatorReconnect(async () => {
        const response = await operatorFetch(operatorApiUrl(`/work-requests/${encodeURIComponent(workRequestId)}/architect-handoff`), {
          method: "POST",
          headers: await mutationHeaders(),
          body: JSON.stringify({}),
        });
        return readDashboardApiResponse(response, "Architect handoff unavailable");
      })) as ArchitectHandoffPayload;

      handoff = payload.architect_handoff || null;
      refreshPayload = payload;
    }

    const prompt = handoff?.prompt?.trim();
    if (!handoff || !prompt) {
      throw new Error("Architect handoff did not include a copyable prompt");
    }

    let result;
    try {
      await copyTextToClipboard(prompt);
      result = { handoff, copied: true };
    } catch (caught) {
      result = {
        handoff,
        copied: false,
        copyError: caught instanceof Error ? caught.message : "Clipboard copy unavailable",
      };
    }

    if (refreshPayload) {
      await refreshAfterMutation(refreshPayload);
    }

    return result;
  }, [refreshAfterMutation]);

  const archiveWorkRequest = useCallback<WorkRequestMutation>((workRequestId) => mutateWorkRequest(workRequestId, "archive", {}, "WorkRequest was not archived", { archive: true }), [mutateWorkRequest]);

  const deleteWorkRequest = useCallback<WorkRequestMutation>((workRequestId) => mutateWorkRequest(workRequestId, "delete", {}, "WorkRequest was not deleted", { remove: true }), [mutateWorkRequest]);

  const restoreWorkRequest = useCallback<WorkRequestMutation>(async (workRequestId) => {
    await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl(`/work-requests/${encodeURIComponent(workRequestId)}/restore`), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({}),
      });
      const payload = (await readDashboardApiResponse(response, "WorkRequest was not restored")) as DashboardMutationPayload;
      setDashboard(removeDashboardWorkRequest(dashboardRef.current, workRequestId));
      await refreshAfterMutation(payload);
    });
  }, [refreshAfterMutation, setDashboard]);

  const changeWorkRequestState = useCallback<WorkRequestStateMutation>((workRequestId, nextState) => mutateWorkRequest(workRequestId, "state", { state: nextState }, "WorkRequest state was not changed"), [mutateWorkRequest]);

  const changeWorkPackageState = useCallback<WorkPackageStateMutation>(async (workPackageId, action, options) => {
    await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl(`/work-packages/${encodeURIComponent(workPackageId)}/state`), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({ status: action, no_pr_evidence: options?.noPrEvidence }),
      });
      const payload = (await readDashboardApiResponse(response, "WorkPackage state was not changed")) as DashboardMutationPayload;
      await refreshAfterMutation(payload);
    });
    setSelectedCardDetail(null);
  }, [refreshAfterMutation, setSelectedCardDetail]);

  const archiveWorkPackage = useCallback<WorkPackageArchiveMutation>(async (workPackageId) => {
    await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl(`/work-packages/${encodeURIComponent(workPackageId)}/archive`), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({}),
      });
      const payload = (await readDashboardApiResponse(response, "WorkPackage was not archived")) as DashboardMutationPayload;
      await refreshAfterMutation(payload);
    });
    setSelectedCardDetail(null);
  }, [refreshAfterMutation, setSelectedCardDetail]);

  const clearWorkPackageBlocker = useCallback<WorkPackageBlockerClearMutation>(async (workPackageId, blockerId) => {
    await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl(`/work-packages/${encodeURIComponent(workPackageId)}/blockers/${encodeURIComponent(blockerId)}/clear`), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({}),
      });
      const payload = (await readDashboardApiResponse(response, "Blocker was not cleared")) as DashboardMutationPayload;
      await refreshAfterMutation(payload);
    });
    setSelectedCardDetail(null);
  }, [refreshAfterMutation, setSelectedCardDetail]);

  useEffect(() => {
    let cancelled = false;

    queueMicrotask(() => {
      if (!cancelled) void loadDashboard("initial");
    });

    return () => {
      cancelled = true;
    };
  }, [loadDashboard]);

  useEffect(() => {
    if (dashboard?.deferred?.dashboard_sections) void loadDashboardDeferred();
  }, [dashboard, dashboard?.deferred?.dashboard_sections, loadDashboardDeferred, surfaceRefreshVersion]);

  const dashboardReady = dashboard !== null;

  useEffect(() => {
    if (!dashboardReady || typeof EventSource === "undefined") return;

    const events = new EventSource(dashboardEventsUrl(), { withCredentials: true });
    const eventRefresh = createDashboardEventRefresh(() => void loadDashboard("silent"), () => document.visibilityState);
    events.addEventListener("dashboard_changed", eventRefresh.dashboardChanged);
    document.addEventListener("visibilitychange", eventRefresh.visibilityChanged);
    return () => {
      events.close();
      eventRefresh.dispose();
      document.removeEventListener("visibilitychange", eventRefresh.visibilityChanged);
    };
  }, [dashboardReady, loadDashboard]);

  useEffect(() => {
    writeDashboardUiStateValue("workspaceTab", workspaceTab);
  }, [workspaceTab]);

  useEffect(() => {
    writeDashboardUiStateValue("hideEmptyWorkstreams", hideEmptyWorkstreams);
  }, [hideEmptyWorkstreams]);

  useEffect(() => {
    writeDashboardUiStateValue("showWorkstreamContextBar", showWorkstreamContextBar);
  }, [showWorkstreamContextBar]);

  useEffect(() => {
    writeDashboardUiStateValue("showWelcomeToast", showWelcomeToast);
  }, [showWelcomeToast]);

  useEffect(() => {
    applyDashboardTheme(theme);
  }, [theme]);

  const toggleTheme = useCallback(() => {
    const nextTheme = theme === "dark" ? "light" : "dark";
    writeStoredTheme(nextTheme);
    dispatchApp({ type: "patch", state: { theme: nextTheme } });
  }, [theme]);

  const packages = useMemo(() => allPackages(dashboard), [dashboard]);
  const requests = useMemo(() => dashboard?.work_requests?.work_requests ?? [], [dashboard]);
  const archivedRequests = useMemo(() => dashboard?.archived_work_requests?.work_requests ?? [], [dashboard]);
  const requestDetails = useMemo(() => activeWorkRequestDetails(dashboard), [dashboard]);
  const linkedWorkPackageIds = useMemo(() => new Set(dashboard?.linked_work_package_ids ?? []), [dashboard]);
  const requestDetailsByRepo = useMemo(() => requestDetailsByRepoKey(requestDetails), [requestDetails]);
  const packageSelections = useMemo(() => packageSelectionIndex(requestDetails, packages), [packages, requestDetails]);
  const { archiveAfterDays, openDashboardOnBoot, soloSessionDeleteAfterDays, updateArchiveAfterDays, updateOpenDashboardOnBoot, updateSoloSessionDeleteAfterDays } = useDashboardOperatorSettings({
    dashboard,
    refreshAfterMutation,
  });
  const guidanceItems = useMemo(() => allGuidanceItems(dashboard), [dashboard]);
  const blockerItems = useMemo(() => activeBlockerItems(packages, packageSelections, dashboard?.active_blocking_edges ?? []), [dashboard?.active_blocking_edges, packages, packageSelections]);
  const soloSessions = useMemo(() => dashboard?.solo_sessions?.solo_sessions ?? [], [dashboard]);
  const repos = useMemo(() => repoSummaries(packages, requests, guidanceItems, soloSessions, requestDetails), [
    packages,
    requests,
    guidanceItems,
    soloSessions,
    requestDetails,
  ]);
  const workstreamRepos = useMemo(
    () => (hideEmptyWorkstreams ? repos.filter(repoWorkstreamHasWorkItems) : repos),
    [hideEmptyWorkstreams, repos],
  );
  const searchedWorkstreams = useMemo(
    () => filterWorkstreamsBySearch(workstreamRepos, requestDetailsByRepo, dashboardSearchQuery),
    [dashboardSearchQuery, requestDetailsByRepo, workstreamRepos],
  );
  const hiddenWorkstreamCount = repos.length - workstreamRepos.length;
  const updateAnimations = useDashboardUpdateAnimations({
    blockerItems,
    guidanceItems,
    packages,
    requestDetails,
    ready: animationBaselineReady,
    soloSessions,
  });
  const reconnectDashboard = useCallback(() => loadDashboard("reconnect"), [loadDashboard]);
  const workspacePanes = useMemo<Record<WorkspaceTab, React.ReactNode>>(
    () => ({
      workstreams: (
        <WorkstreamsPane
          repos={searchedWorkstreams.repos}
          hiddenRepoCount={hiddenWorkstreamCount}
          searchActive={searchedWorkstreams.active}
          requestDetailsByRepo={searchedWorkstreams.requestDetailsByRepo}
          now={dashboard?.generated_at}
          activeBlockingEdges={dashboard?.active_blocking_edges ?? []}
          onSelectGuidance={setSelectedGuidance}
          onSelectCard={setSelectedCardDetail}
          showWorkstreamContextBar={showWorkstreamContextBar}
          updateAnimations={updateAnimations}
        />
      ),
      solo: <SoloSessions loading={soloLoading} sessions={soloSessions} onSelectCard={setSelectedCardDetail} updateAnimations={updateAnimations} />,
    }),
    [
      dashboard?.active_blocking_edges,
      dashboard?.generated_at,
      hiddenWorkstreamCount,
      searchedWorkstreams,
      setSelectedCardDetail,
      setSelectedGuidance,
      showWorkstreamContextBar,
      soloSessions,
      soloLoading,
      updateAnimations,
    ],
  );

  return {
    archiveAfterDays,
    archivedRequestsLoading: archivedLoading,
    archivedRequests,
    blockerItems,
    canMutateComments: canMutateDashboardComments(runtimeConfig),
    canMutateOperatorActions,
    changeWorkPackageState,
    changeWorkRequestState,
    connectionIssue,
    copyArchitectHandoff,
    createWorkRequest,
    dashboard,
    dashboardSearchQuery,
    dialogState,
    displayPreferences: { hideEmptyWorkstreams, showWorkstreamContextBar },
    error,
    guidanceItems,
    hiddenWorkstreamCount,
    linkedWorkPackageIds,
    loading,
    onArchiveWorkPackage: archiveWorkPackage,
    onClearWorkPackageBlocker: clearWorkPackageBlocker,
    onArchiveWorkRequest: archiveWorkRequest,
    onOpenArchivedRequests: loadArchived,
    onDeleteWorkRequest: deleteWorkRequest,
    onDashboardSearchQueryChange: updateDashboardSearchQuery,
    onHideEmptyWorkstreamsChange: setHideEmptyWorkstreams,
    onOpenDashboardOnBootChange: updateOpenDashboardOnBoot,
    onReconnectDashboard: reconnectDashboard,
    onRefreshDashboard: loadDashboard,
    onRestoreWorkRequest: restoreWorkRequest,
    onResolveComment: resolveComment,
    onSelectCard: setSelectedCardDetail,
    onSelectGuidance: setSelectedGuidance,
    onSetNewRequestOpen: setNewRequestOpen,
    onShowWorkstreamContextBarChange: setShowWorkstreamContextBar,
    onShowWelcomeToastChange: setShowWelcomeToast,
    onSubmitComment: submitComment,
    onSubmitGuidanceAnswer: submitGuidanceAnswer,
    onUpdateArchiveAfterDays: updateArchiveAfterDays,
    onUpdateSoloSessionDeleteAfterDays: updateSoloSessionDeleteAfterDays,
    onWorkspaceTabChange: setWorkspaceTab,
    refreshing,
    repos,
    showUpdateSimulationControls,
    openDashboardOnBoot,
    showWelcomeToast,
    soloSessionDeleteAfterDays,
    surfaceRefreshVersion,
    theme,
    toggleTheme,
    updateAnimations,
    workspacePanes,
    workspaceTab,
  };
}
