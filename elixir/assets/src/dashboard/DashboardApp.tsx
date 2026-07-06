import type { ArchitectHandoffPayload, ContextComment, CopyArchitectHandoff, CreateWorkRequestPayload, DashboardMutationPayload, DashboardPayload, GuidanceAnswerSubmission, GuidanceItem } from "@/types/dashboard";
import type { NewRequestForm } from "@/components/dashboard/new-request-dialog";
import type * as React from "react";
import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import { CardDetailSelection, DASHBOARD_RECONNECT_GRACE_MS, DashboardConnectionIssue, DashboardResponseSelector, DashboardRuntimeConfig, ResolveContextComment, SubmitContextComment, WorkPackageArchiveMutation, WorkPackageBlockerClearMutation, WorkPackageStateMutation, WorkRequestMutation, WorkRequestStateMutation, WorkspaceTab, copyTextToClipboard, dashboardCaughtMessage, dashboardEventsUrl, dashboardMutationWorkRequest, dashboardRuntimeConfig, ensureDashboardRuntimeConfig, isReconnectableLocalOperatorError, jsonHeaders, mergeDashboardPayload, mutationHeaders, mutationShouldRefreshDashboard, operatorApiUrl, operatorFetch, patchDashboardWorkRequest, readDashboardApiResponse, reconnectLocalOperatorSession, removeDashboardWorkRequest, shouldSkipDashboardLoad, withLocalOperatorReconnect } from "./runtime";
import { DashboardShell } from "./dashboard-shell";
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
import { packageSelectionIndex, requestDetailsByRepoKey } from "./workstream-data";
import { useDashboardUpdateAnimations } from "./update-animations";

type DashboardLoadMode = "initial" | "refresh" | "silent" | "reconnect";

export function DashboardApp() {
  const shellProps = useDashboardController();
  return <DashboardShell {...shellProps} />;
}
function useDashboardController() {
  const [appState, dispatchApp] = useReducer(appStateReducer, null, createInitialAppState);
  const { dashboard, error, hideEmptyWorkstreams, loading, refreshing, showWorkstreamContextBar, theme, workspaceTab } = appState;
  const [dialogState, dispatchDialog] = useReducer(appDialogReducer, initialAppDialogState);
  const [connectionIssue, setConnectionIssue] = useState<DashboardConnectionIssue | null>(null);
  const showUpdateSimulationControls = useMemo(() => shouldShowUpdateSimulationControls(), []);
  const [runtimeConfig, setRuntimeConfig] = useState<DashboardRuntimeConfig | undefined>(() => dashboardRuntimeConfig);
  const canMutateOperatorActions = canMutateDashboardOperatorActions(runtimeConfig);
  const dashboardRef = useRef<DashboardPayload | null>(dashboard);
  const initialDashboardFingerprint = useMemo(() => dashboardContentFingerprint(dashboard), [dashboard]);
  const dashboardFingerprintRef = useRef(initialDashboardFingerprint);
  const connectionIssueRef = useRef<DashboardConnectionIssue | null>(null);
  const loadInFlightRef = useRef(false);
  const loadSequenceRef = useRef(0);
  const refreshingSequenceRef = useRef(0);
  const mutationVersionRef = useRef(0);
  const setDashboard = useCallback((nextDashboard: DashboardPayload | null) => {
    const nextFingerprint = dashboardContentFingerprint(nextDashboard);
    if (dashboardFingerprintRef.current === nextFingerprint) return;

    dashboardFingerprintRef.current = nextFingerprint;
    dispatchApp({ type: "patch", state: { dashboard: nextDashboard } });
  }, []);
  const setLoading = useCallback((nextLoading: boolean) => {
    dispatchApp({ type: "patch", state: { loading: nextLoading } });
  }, []);
  const setRefreshing = useCallback((nextRefreshing: boolean) => {
    dispatchApp({ type: "patch", state: { refreshing: nextRefreshing } });
  }, []);
  const setError = useCallback((nextError: string | null) => {
    dispatchApp({ type: "patch", state: { error: nextError } });
  }, []);
  const setWorkspaceTab = useCallback((nextWorkspaceTab: WorkspaceTab) => {
    dispatchApp({ type: "patch", state: { workspaceTab: nextWorkspaceTab } });
  }, []);
  const setHideEmptyWorkstreams = useCallback((nextHideEmptyWorkstreams: boolean) => {
    dispatchApp({ type: "patch", state: { hideEmptyWorkstreams: nextHideEmptyWorkstreams } });
  }, []);
  const setShowWorkstreamContextBar = useCallback((nextShowWorkstreamContextBar: boolean) => {
    dispatchApp({ type: "patch", state: { showWorkstreamContextBar: nextShowWorkstreamContextBar } });
  }, []);
  const setSelectedGuidance = useCallback((selectedGuidance: GuidanceItem | null) => {
    dispatchDialog({ type: "guidance", selectedGuidance });
  }, []);
  const setSelectedCardDetail = useCallback((selectedCardDetail: CardDetailSelection | null) => {
    dispatchDialog({ type: "cardDetail", selectedCardDetail });
  }, []);
  const setNewRequestOpen = useCallback((open: boolean) => {
    dispatchDialog({ type: "newRequest", open });
  }, []);

  useEffect(() => {
    dashboardRef.current = dashboard;
  }, [dashboard]);

  useEffect(() => {
    connectionIssueRef.current = connectionIssue;
  }, [connectionIssue]);

  const recordConnectionFailure = useCallback(
    (message: string, immediate = false, reconnectableLocalSession = false) => {
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
    async (response: Response, fallbackMessage: string, selectDashboard: DashboardResponseSelector = (payload) => payload as DashboardPayload, loadMutationVersion = mutationVersionRef.current, shouldApply: () => boolean = () => true) => {
      const payload = await readDashboardApiResponse(response, fallbackMessage);
      if (!shouldApply()) return null;
      const nextDashboard = selectDashboard(payload);
      if (!nextDashboard) {
        throw new Error(fallbackMessage);
      }
      if (loadMutationVersion !== mutationVersionRef.current) return nextDashboard;
      setDashboard(nextDashboard);
      setConnectionIssue(null);
      setError(null);
      return nextDashboard;
    },
    [setDashboard, setError],
  );

  const recordDashboardLoadFailure = useCallback((loadSequence: number, caught: unknown, mode: DashboardLoadMode) => {
    if (loadSequence !== loadSequenceRef.current) return;
    recordConnectionFailure(dashboardCaughtMessage(caught, "Dashboard API unavailable"), mode === "initial" || mode === "reconnect", isReconnectableLocalOperatorError(caught));
  }, [recordConnectionFailure]);

  const loadDashboard = useCallback(async (mode: DashboardLoadMode = "refresh", force = false) => {
    if (shouldSkipDashboardLoad(loadInFlightRef.current, mode, force)) return;
    const loadMutationVersion = mutationVersionRef.current;
    const loadSequence = loadSequenceRef.current + 1;
    const showsRefreshing = mode === "refresh" || mode === "reconnect";
    loadSequenceRef.current = loadSequence;
    loadInFlightRef.current = true;
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
        const response = await operatorFetch(operatorApiUrl("/dashboard"), { headers: jsonHeaders() });
        if (loadSequence !== loadSequenceRef.current) return;
        await applyDashboardResponse(response, "Dashboard API unavailable", undefined, loadMutationVersion, () => loadSequence === loadSequenceRef.current);
      });
    } catch (caught) {
      recordDashboardLoadFailure(loadSequence, caught, mode);
    } finally {
      if (loadSequence === loadSequenceRef.current) {
        loadInFlightRef.current = false;
        setLoading(false);
      }
      if (showsRefreshing && refreshingSequenceRef.current === loadSequence) {
        refreshingSequenceRef.current = 0;
        setRefreshing(false);
      }
    }
  }, [applyDashboardResponse, recordDashboardLoadFailure, setLoading, setRefreshing]);

  const loadDashboardDeferred = useCallback(async () => {
    const baseDashboard = dashboardRef.current;
    if (!baseDashboard?.deferred?.dashboard_sections) return;

    try {
      await withLocalOperatorReconnect(async () => {
        const response = await operatorFetch(operatorApiUrl("/dashboard/deferred"), { headers: jsonHeaders() });
        const payload = await readDashboardApiResponse(response, "Dashboard details unavailable");
        if (dashboardRef.current !== baseDashboard) return;
        const nextDashboard = mergeDashboardPayload(dashboardRef.current, payload as DashboardPayload);
        if (nextDashboard) setDashboard(nextDashboard);
      });
    } catch (caught) {
      recordConnectionFailure(dashboardCaughtMessage(caught, "Dashboard details unavailable"), false, isReconnectableLocalOperatorError(caught));
    }
  }, [recordConnectionFailure, setDashboard]);

  const refreshAfterMutation = useCallback(async (payload?: DashboardMutationPayload) => {
    if (payload?.dashboard) {
      setDashboard(payload.dashboard);
      setConnectionIssue(null);
      setError(null);
      return;
    }

    if (!mutationShouldRefreshDashboard(payload)) {
      setConnectionIssue(null);
      setError(null);
      return;
    }

    await loadDashboard("refresh");
  }, [loadDashboard, setDashboard, setError]);

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
      setConnectionIssue(null);
      setError(null);
      setSelectedCardDetail(null);
      if (mutationShouldRefreshDashboard(payload)) void loadDashboard("silent", true);
    },
    [loadDashboard, setDashboard, setError, setSelectedCardDetail],
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

  const updateRetentionSetting = useCallback(async (payload: { work_request_archive_after_days?: number; solo_session_delete_after_days?: number }) => {
    await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl("/settings"), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify(payload),
      });
      const responsePayload = (await readDashboardApiResponse(response, "Settings were not saved")) as DashboardMutationPayload;
      await refreshAfterMutation(responsePayload);
    });
  }, [refreshAfterMutation]);

  const updateArchiveAfterDays = useCallback(
    (archiveAfterDays: number) => updateRetentionSetting({ work_request_archive_after_days: archiveAfterDays }),
    [updateRetentionSetting],
  );

  const updateSoloSessionDeleteAfterDays = useCallback(
    (deleteAfterDays: number) => updateRetentionSetting({ solo_session_delete_after_days: deleteAfterDays }),
    [updateRetentionSetting],
  );

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
      await refreshAfterMutation(payload);
    });
  }, [refreshAfterMutation]);

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
  }, [dashboard, dashboard?.deferred?.dashboard_sections, loadDashboardDeferred]);

  const dashboardReady = dashboard !== null;

  useEffect(() => {
    if (!dashboardReady || typeof EventSource === "undefined") return;

    const events = new EventSource(dashboardEventsUrl(), { withCredentials: true });
    events.addEventListener("dashboard_changed", () => void loadDashboard("silent", true));
    return () => events.close();
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
  const requestDetails = useMemo(() => dashboard?.work_request_details ?? [], [dashboard]);
  const linkedWorkPackageIds = useMemo(() => new Set(dashboard?.linked_work_package_ids ?? []), [dashboard]);
  const requestDetailsByRepo = useMemo(() => requestDetailsByRepoKey(requestDetails), [requestDetails]);
  const packageSelections = useMemo(() => packageSelectionIndex(requestDetails, packages), [packages, requestDetails]);
  const archiveAfterDays = dashboard?.settings?.work_request_archive_after_days ?? 14;
  const soloSessionDeleteAfterDays = dashboard?.settings?.solo_session_delete_after_days ?? 30;
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
  const hiddenWorkstreamCount = repos.length - workstreamRepos.length;
  const updateAnimations = useDashboardUpdateAnimations({
    blockerItems,
    guidanceItems,
    packages,
    requestDetails,
    ready: dashboard !== null,
    soloSessions,
  });
  const reconnectDashboard = useCallback(() => loadDashboard("reconnect"), [loadDashboard]);
  const workspacePanes = useMemo<Record<WorkspaceTab, React.ReactNode>>(
    () => ({
      workstreams: (
        <WorkstreamsPane
          repos={workstreamRepos}
          hiddenRepoCount={hiddenWorkstreamCount}
          requestDetailsByRepo={requestDetailsByRepo}
          activeBlockingEdges={dashboard?.active_blocking_edges ?? []}
          guidanceItems={guidanceItems}
          onSelectGuidance={setSelectedGuidance}
          onSelectCard={setSelectedCardDetail}
          onCopyArchitectHandoff={copyArchitectHandoff}
          canMutateOperatorActions={canMutateOperatorActions}
          showWorkstreamContextBar={showWorkstreamContextBar}
          updateAnimations={updateAnimations}
        />
      ),
      solo: <SoloSessions sessions={soloSessions} onSelectCard={setSelectedCardDetail} updateAnimations={updateAnimations} />,
    }),
    [
      copyArchitectHandoff,
      canMutateOperatorActions,
      dashboard?.active_blocking_edges,
      guidanceItems,
      hiddenWorkstreamCount,
      requestDetailsByRepo,
      setSelectedCardDetail,
      setSelectedGuidance,
      showWorkstreamContextBar,
      soloSessions,
      updateAnimations,
      workstreamRepos,
    ],
  );

  return {
    archiveAfterDays,
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
    onDeleteWorkRequest: deleteWorkRequest,
    onHideEmptyWorkstreamsChange: setHideEmptyWorkstreams,
    onReconnectDashboard: reconnectDashboard,
    onRefreshDashboard: loadDashboard,
    onRestoreWorkRequest: restoreWorkRequest,
    onResolveComment: resolveComment,
    onSelectCard: setSelectedCardDetail,
    onSelectGuidance: setSelectedGuidance,
    onSetNewRequestOpen: setNewRequestOpen,
    onShowWorkstreamContextBarChange: setShowWorkstreamContextBar,
    onSubmitComment: submitComment,
    onSubmitGuidanceAnswer: submitGuidanceAnswer,
    onUpdateArchiveAfterDays: updateArchiveAfterDays,
    onUpdateSoloSessionDeleteAfterDays: updateSoloSessionDeleteAfterDays,
    onWorkspaceTabChange: setWorkspaceTab,
    refreshing,
    repos,
    showUpdateSimulationControls,
    soloSessionDeleteAfterDays,
    theme,
    toggleTheme,
    updateAnimations,
    workspacePanes,
    workspaceTab,
  };
}
