import type { CopyArchitectHandoff, GuidanceItem, SoloSessionDetailPayload, WorkPackageDetailPayload, WorkRequestDetail } from "@/types/dashboard";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import type * as React from "react";
import { dashboardPrefersReducedMotion } from "@/components/dashboard/motion-utils";
import { useEffect, useReducer, useState } from "react";
import { CARD_DETAIL_HEIGHT_MS, CARD_DETAIL_LOADING_HOLD_MS, CARD_DETAIL_WIDTH_MS, CardDetailSelection, CardDetailStage, ResolveContextComment, SubmitContextComment, WorkPackageArchiveMutation, WorkPackageBlockerClearMutation, WorkPackageStateMutation, WorkRequestMutation, WorkRequestStateMutation, ensureDashboardRuntimeConfig, jsonHeaders, operatorApiUrl, operatorFetch, readDashboardApiResponse, withLocalOperatorReconnect } from "./runtime";
import { CardDetailLoadingContent } from "./card-detail-loading";
import { BlockerDetailContent, PackageDetailContent, SliceDetailContent } from "./package-detail";
import { RequestDetailContent } from "./request-detail";
import { SoloSessionDetailContent } from "./solo-detail";

export type DetailResourceState<T> = {
  payload: T | null;
  loading: boolean;
  error: string | null;
  resourceKey?: string | null;
};

export type CardDetailDialogState = {
  package: DetailResourceState<WorkPackageDetailPayload>;
  request: DetailResourceState<WorkRequestDetail>;
  solo: DetailResourceState<SoloSessionDetailPayload>;
};

export type CardDetailDialogAction =
  | { type: "resetPackage" }
  | { type: "loadPackage" }
  | { type: "packageSuccess"; payload: WorkPackageDetailPayload }
  | { type: "packageError"; error: string }
  | { type: "resetRequest" }
  | { type: "loadRequest"; requestId: string }
  | { type: "requestSuccess"; payload: WorkRequestDetail }
  | { type: "requestError"; requestId: string; error: string }
  | { type: "resetSolo" }
  | { type: "loadSolo" }
  | { type: "soloSuccess"; payload: SoloSessionDetailPayload }
  | { type: "soloError"; error: string };

const emptyPackageDetailState: DetailResourceState<WorkPackageDetailPayload> = {
  payload: null,
  loading: false,
  error: null,
};

const emptyRequestDetailState: DetailResourceState<WorkRequestDetail> = {
  payload: null,
  loading: false,
  error: null,
};

const emptySoloDetailState: DetailResourceState<SoloSessionDetailPayload> = {
  payload: null,
  loading: false,
  error: null,
};

const initialCardDetailDialogState: CardDetailDialogState = {
  package: emptyPackageDetailState,
  request: emptyRequestDetailState,
  solo: emptySoloDetailState,
};

function cardDetailDialogReducer(state: CardDetailDialogState, action: CardDetailDialogAction): CardDetailDialogState {
  switch (action.type) {
    case "resetPackage":
      return { ...state, package: emptyPackageDetailState };
    case "loadPackage":
      return { ...state, package: { payload: null, loading: true, error: null } };
    case "packageSuccess":
      return { ...state, package: { payload: action.payload, loading: false, error: null } };
    case "packageError":
      return { ...state, package: { payload: null, loading: false, error: action.error } };
    case "resetRequest":
      return { ...state, request: emptyRequestDetailState };
    case "loadRequest":
      return { ...state, request: { payload: null, loading: true, error: null, resourceKey: action.requestId } };
    case "requestSuccess":
      return { ...state, request: { payload: action.payload, loading: false, error: null, resourceKey: action.payload.work_request.id } };
    case "requestError":
      return { ...state, request: { payload: null, loading: false, error: action.error, resourceKey: action.requestId } };
    case "resetSolo":
      return { ...state, solo: emptySoloDetailState };
    case "loadSolo":
      return { ...state, solo: { payload: null, loading: true, error: null } };
    case "soloSuccess":
      return { ...state, solo: { payload: action.payload, loading: false, error: null } };
    case "soloError":
      return { ...state, solo: { payload: null, loading: false, error: action.error } };
  }
}

async function loadOperatorPayload<T>(path: string, signal: AbortSignal, fallbackMessage: string): Promise<T> {
  return withLocalOperatorReconnect(async () => {
    await ensureDashboardRuntimeConfig();
    const response = await operatorFetch(operatorApiUrl(path), {
      headers: jsonHeaders(),
      signal,
    });
    const payload = await readDashboardApiResponse(response, fallbackMessage);
    return payload as T;
  });
}

export function CardDetailDialog({
  selection,
  onOpenChange,
  onSelectGuidance,
  onCopyArchitectHandoff,
  onArchiveWorkRequest,
  onChangeWorkRequestState,
  onDeleteWorkRequest,
  onChangeWorkPackageState,
  onArchiveWorkPackage,
  onClearWorkPackageBlocker,
  canMutateOperatorActions,
  linkedWorkPackageIds,
  onSubmitComment,
  onResolveComment,
  canMutateComments,
}: {
  selection: CardDetailSelection | null;
  onOpenChange: (open: boolean) => void;
  onSelectGuidance: (item: GuidanceItem) => void;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  onArchiveWorkRequest: WorkRequestMutation;
  onChangeWorkRequestState: WorkRequestStateMutation;
  onDeleteWorkRequest: WorkRequestMutation;
  onChangeWorkPackageState: WorkPackageStateMutation;
  onArchiveWorkPackage: WorkPackageArchiveMutation;
  onClearWorkPackageBlocker: WorkPackageBlockerClearMutation;
  canMutateOperatorActions: boolean;
  linkedWorkPackageIds: Set<string>;
  onSubmitComment: SubmitContextComment;
  onResolveComment: ResolveContextComment;
  canMutateComments: boolean;
}) {
  const [state, dispatch] = useReducer(cardDetailDialogReducer, initialCardDetailDialogState);
  const packageId = cardDetailPackageId(selection);
  const requestId = cardDetailRequestId(selection);
  const soloSessionId = selection?.kind === "solo" ? selection.session.id : null;
  const selectionIdentity = cardDetailSelectionIdentity(selection);
  const prefersReducedDetailMotion = useDashboardReducedMotionPreference();
  const [detailStage, setDetailStage] = useState<{ key: string; stage: CardDetailStage }>({ key: "closed", stage: "ready" });

  useEffect(() => {
    if (!packageId) {
      dispatch({ type: "resetPackage" });
      return;
    }

    const controller = new AbortController();
    dispatch({ type: "loadPackage" });

    loadOperatorPayload<WorkPackageDetailPayload>(`/work-packages/${encodeURIComponent(packageId)}`, controller.signal, "Package detail unavailable")
      .then((payload) => {
        if (!controller.signal.aborted) dispatch({ type: "packageSuccess", payload });
      })
      .catch((caught) => {
        if (caught instanceof DOMException && caught.name === "AbortError") return;
        if (!controller.signal.aborted) dispatch({ type: "packageError", error: caught instanceof Error ? caught.message : "Package detail unavailable" });
      });

    return () => controller.abort();
  }, [packageId]);

  useEffect(() => {
    if (!requestId) {
      dispatch({ type: "resetRequest" });
      return;
    }

    const controller = new AbortController();
    dispatch({ type: "loadRequest", requestId });

    loadOperatorPayload<WorkRequestDetail>(`/work-requests/${encodeURIComponent(requestId)}`, controller.signal, "WorkRequest detail unavailable")
      .then((payload) => {
        if (!controller.signal.aborted) dispatch({ type: "requestSuccess", payload });
      })
      .catch((caught) => {
        if (caught instanceof DOMException && caught.name === "AbortError") return;
        if (!controller.signal.aborted) dispatch({ type: "requestError", requestId, error: caught instanceof Error ? caught.message : "WorkRequest detail unavailable" });
      });

    return () => controller.abort();
  }, [requestId]);

  useEffect(() => {
    if (!soloSessionId) {
      dispatch({ type: "resetSolo" });
      return;
    }

    const controller = new AbortController();
    dispatch({ type: "loadSolo" });

    loadOperatorPayload<SoloSessionDetailPayload>(`/solo-sessions/${encodeURIComponent(soloSessionId)}`, controller.signal, "Solo Session detail unavailable")
      .then((payload) => {
        if (!controller.signal.aborted) dispatch({ type: "soloSuccess", payload });
      })
      .catch((caught) => {
        if (caught instanceof DOMException && caught.name === "AbortError") return;
        if (!controller.signal.aborted) dispatch({ type: "soloError", error: caught instanceof Error ? caught.message : "Solo Session detail unavailable" });
      });

    return () => controller.abort();
  }, [soloSessionId]);

  useEffect(() => {
    let cancelled = false;

    queueMicrotask(() => {
      if (cancelled) return;

      setDetailStage((current) => {
        if (!selection) return current.key === "closed" ? current : { key: "closed", stage: "ready" };
        return current.key === selectionIdentity ? current : { key: selectionIdentity, stage: prefersReducedDetailMotion ? "ready" : "loading" };
      });
    });

    return () => {
      cancelled = true;
    };
  }, [prefersReducedDetailMotion, selection, selectionIdentity]);

  const detailReady = cardDetailContentReady(selection, state);

  useEffect(() => {
    if (!selection || !prefersReducedDetailMotion || detailStage.key !== selectionIdentity || detailStage.stage === "ready") return;

    let cancelled = false;

    queueMicrotask(() => {
      if (!cancelled) setDetailStage((current) => (current.key === selectionIdentity ? { ...current, stage: "ready" } : current));
    });

    return () => {
      cancelled = true;
    };
  }, [detailStage, prefersReducedDetailMotion, selection, selectionIdentity]);

  useEffect(() => {
    if (prefersReducedDetailMotion || !selection || !detailReady || detailStage.key !== selectionIdentity || detailStage.stage !== "loading") return;

    const timer = window.setTimeout(() => {
      setDetailStage((current) => (current.key === selectionIdentity && current.stage === "loading" ? { ...current, stage: "width" } : current));
    }, CARD_DETAIL_LOADING_HOLD_MS);

    return () => window.clearTimeout(timer);
  }, [detailReady, detailStage, prefersReducedDetailMotion, selection, selectionIdentity]);

  useEffect(() => {
    if (prefersReducedDetailMotion || !selection || detailStage.key !== selectionIdentity) return;

    if (detailStage.stage === "width") {
      const timer = window.setTimeout(() => {
        setDetailStage((current) => (current.key === selectionIdentity && current.stage === "width" ? { ...current, stage: "height" } : current));
      }, CARD_DETAIL_WIDTH_MS);

      return () => window.clearTimeout(timer);
    }

    if (detailStage.stage === "height") {
      const timer = window.setTimeout(() => {
        setDetailStage((current) => (current.key === selectionIdentity && current.stage === "height" ? { ...current, stage: "ready" } : current));
      }, CARD_DETAIL_HEIGHT_MS);

      return () => window.clearTimeout(timer);
    }
  }, [detailStage, prefersReducedDetailMotion, selection, selectionIdentity]);

  const activeDetailStage = prefersReducedDetailMotion ? "ready" : detailStage.key === selectionIdentity ? detailStage.stage : "loading";
  const showStagedLoadingHeader = Boolean(selection && (activeDetailStage === "loading" || activeDetailStage === "width"));
  const detailMotionKey = cardDetailMotionKey(selection, {
    loadingPackage: selection?.kind === "package" && showStagedLoadingHeader,
    loadingRequest: (selection?.kind === "request" || selection?.kind === "slice") && showStagedLoadingHeader,
    loadingSolo: selection?.kind === "solo" && showStagedLoadingHeader,
    packageDetail: state.package.payload,
    packageError: state.package.error,
    requestDetail: state.request.payload,
    requestError: state.request.error,
    soloDetail: state.solo.payload,
    soloError: state.solo.error,
  });

  return (
    <Dialog open={Boolean(selection)} onOpenChange={onOpenChange}>
      <DialogContent className="dashboard-dialog-content card-detail-dialog" data-detail-stage={activeDetailStage} resizeKey={`${activeDetailStage}:${detailMotionKey}`}>
        <NaturalDetailBody motionKey={detailMotionKey}>
          {selection && showStagedLoadingHeader ? <CardDetailLoadingContent selection={selection} stage={activeDetailStage} /> : null}
          {!showStagedLoadingHeader ? (
            <CardDetailReadyContent
              selection={selection}
              state={state}
              onSelectGuidance={onSelectGuidance}
              onCopyArchitectHandoff={onCopyArchitectHandoff}
              onArchiveWorkRequest={onArchiveWorkRequest}
              onChangeWorkRequestState={onChangeWorkRequestState}
              onDeleteWorkRequest={onDeleteWorkRequest}
              onChangeWorkPackageState={onChangeWorkPackageState}
              onArchiveWorkPackage={onArchiveWorkPackage}
              onClearWorkPackageBlocker={onClearWorkPackageBlocker}
              canMutateOperatorActions={canMutateOperatorActions}
              linkedWorkPackageIds={linkedWorkPackageIds}
              onSubmitComment={onSubmitComment}
              onResolveComment={onResolveComment}
              canMutateComments={canMutateComments}
            />
          ) : null}
        </NaturalDetailBody>
      </DialogContent>
    </Dialog>
  );
}

function CardDetailReadyContent({
  selection,
  state,
  onSelectGuidance,
  onCopyArchitectHandoff,
  onArchiveWorkRequest,
  onChangeWorkRequestState,
  onDeleteWorkRequest,
  onChangeWorkPackageState,
  onArchiveWorkPackage,
  onClearWorkPackageBlocker,
  canMutateOperatorActions,
  linkedWorkPackageIds,
  onSubmitComment,
  onResolveComment,
  canMutateComments,
}: {
  selection: CardDetailSelection | null;
  state: CardDetailDialogState;
  onSelectGuidance: (item: GuidanceItem) => void;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  onArchiveWorkRequest: WorkRequestMutation;
  onChangeWorkRequestState: WorkRequestStateMutation;
  onDeleteWorkRequest: WorkRequestMutation;
  onChangeWorkPackageState: WorkPackageStateMutation;
  onArchiveWorkPackage: WorkPackageArchiveMutation;
  onClearWorkPackageBlocker: WorkPackageBlockerClearMutation;
  canMutateOperatorActions: boolean;
  linkedWorkPackageIds: Set<string>;
  onSubmitComment: SubmitContextComment;
  onResolveComment: ResolveContextComment;
  canMutateComments: boolean;
}) {
  if (!selection) return null;

  switch (selection.kind) {
    case "request":
      return renderRequestDetailContent(selection, state, {
        onSelectGuidance,
        onCopyArchitectHandoff,
        onArchiveWorkRequest,
        onChangeWorkRequestState,
        onDeleteWorkRequest,
        canMutateOperatorActions,
        onSubmitComment,
        onResolveComment,
        canMutateComments,
      });
    case "slice":
      return renderSliceDetailContent(selection, state, {
        onSubmitComment,
        onResolveComment,
        canMutateComments,
      });
    case "package":
      return (
        <PackageDetailContent
          selection={selection}
          detailPayload={state.package.payload}
          loading={!state.package.payload && !state.package.error ? true : state.package.loading}
          error={state.package.error}
          onChangeWorkPackageState={onChangeWorkPackageState}
          onArchiveWorkPackage={onArchiveWorkPackage}
          canMutateOperatorActions={canMutateOperatorActions}
          linkedWorkPackageIds={linkedWorkPackageIds}
          onSubmitComment={onSubmitComment}
          onResolveComment={onResolveComment}
          canMutateComments={canMutateComments}
        />
      );
    case "blocker":
      return <BlockerDetailContent selection={selection} detailPayload={state.package.payload} loading={!state.package.payload && !state.package.error} error={state.package.error} onClearWorkPackageBlocker={onClearWorkPackageBlocker} canMutateOperatorActions={canMutateOperatorActions} />;
    case "solo":
      return <SoloSessionDetailContent session={selection.session} detailPayload={state.solo.payload} loading={!state.solo.payload && !state.solo.error ? true : state.solo.loading} error={state.solo.error} />;
  }
}

function renderRequestDetailContent(
  selection: Extract<CardDetailSelection, { kind: "request" }>,
  state: CardDetailDialogState,
  props: {
    onSelectGuidance: (item: GuidanceItem) => void;
    onCopyArchitectHandoff: CopyArchitectHandoff;
    onArchiveWorkRequest: WorkRequestMutation;
    onChangeWorkRequestState: WorkRequestStateMutation;
    onDeleteWorkRequest: WorkRequestMutation;
    canMutateOperatorActions: boolean;
    onSubmitComment: SubmitContextComment;
    onResolveComment: ResolveContextComment;
    canMutateComments: boolean;
  },
) {
  const error = matchingRequestError(selection, state);
  if (error) return <RequestDetailLoadError selection={selection} error={error} />;

  const detail = matchingRequestDetail(selection, state);
  if (!detail) return <CardDetailLoadingContent selection={selection} stage="loading" />;

  return <RequestDetailContent detail={detail} {...props} />;
}

function renderSliceDetailContent(
  selection: Extract<CardDetailSelection, { kind: "slice" }>,
  state: CardDetailDialogState,
  props: {
    onSubmitComment: SubmitContextComment;
    onResolveComment: ResolveContextComment;
    canMutateComments: boolean;
  },
) {
  const error = matchingRequestError(selection, state);
  if (error) return <RequestDetailLoadError selection={selection} error={error} />;

  const detail = matchingRequestDetail(selection, state);
  if (!detail) return <CardDetailLoadingContent selection={selection} stage="loading" />;

  const slice = detail.planned_slices?.find((candidate) => candidate.id === selection.slice.id) || selection.slice;

  return <SliceDetailContent detail={detail} slice={slice} pkg={selection.pkg} {...props} />;
}

function matchingRequestDetail(selection: Extract<CardDetailSelection, { kind: "request" | "slice" }>, state: CardDetailDialogState) {
  const payload = state.request.payload;
  if (!payload) return null;
  return payload.work_request.id === selection.detail.work_request.id ? payload : null;
}

function matchingRequestError(selection: Extract<CardDetailSelection, { kind: "request" | "slice" }>, state: CardDetailDialogState) {
  if (!state.request.error) return null;
  return state.request.resourceKey === selection.detail.work_request.id ? state.request.error : null;
}

function RequestDetailLoadError({ selection, error }: { selection: Extract<CardDetailSelection, { kind: "request" | "slice" }>; error: string }) {
  const request = selection.detail.work_request;

  return (
    <DialogHeader className="detail-loading-header" data-guidance-section style={{ animationDelay: "35ms" }}>
      <div className="min-w-0">
        <DialogTitle className="detail-loading-title">{request.title || request.id}</DialogTitle>
        <DialogDescription className="detail-loading-eyebrow">{error}</DialogDescription>
      </div>
    </DialogHeader>
  );
}

function useDashboardReducedMotionPreference() {
  const [prefersReducedMotion, setPrefersReducedMotion] = useState(() => dashboardPrefersReducedMotion());

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return;

    const query = window.matchMedia("(prefers-reduced-motion: reduce)");
    const updatePreference = () => setPrefersReducedMotion(query.matches);

    query.addEventListener("change", updatePreference);
    return () => query.removeEventListener("change", updatePreference);
  }, []);

  return prefersReducedMotion;
}

function cardDetailSelectionIdentity(selection: CardDetailSelection | null) {
  if (!selection) return "closed";

  switch (selection.kind) {
    case "request":
      return `request:${selection.detail.work_request.id}`;
    case "slice":
      return `slice:${selection.slice.id}:${selection.pkg?.id || "undispatched"}`;
    case "package":
      return `package:${selection.pkg.id}`;
    case "blocker":
      return `blocker:${selection.blocker.blocker_id || selection.blocker.id}:${selection.pkg?.id || selection.blocker.work_package_id || "unknown"}`;
    case "solo":
      return `solo:${selection.session.id}`;
  }
}

function cardDetailPackageId(selection: CardDetailSelection | null) {
  if (selection?.kind === "package") return selection.pkg.id;
  if (selection?.kind !== "blocker") return null;

  return (
    selection.pkg?.id ||
    selection.blocker.work_package_id ||
    (selection.blocker.to.kind === "work_package" ? selection.blocker.to.id : null)
  );
}

function cardDetailRequestId(selection: CardDetailSelection | null) {
  if (selection?.kind === "request" || selection?.kind === "slice") return selection.detail.work_request.id;
  return null;
}

function cardDetailContentReady(selection: CardDetailSelection | null, state: CardDetailDialogState) {
  if (!selection) return false;

  const packageId = cardDetailPackageId(selection);

  switch (selection.kind) {
    case "request":
    case "slice": {
      if (matchingRequestError(selection, state)) return true;
      const payload = state.request.payload;
      if (!payload) return false;
      return payload.work_request.id === selection.detail.work_request.id;
    }
    case "package": {
      if (state.package.error) return true;
      const payload = state.package.payload;
      if (!payload) return false;
      const payloadId = payload.work_package?.id;
      return !payloadId || payloadId === selection.pkg.id;
    }
    case "blocker":
      if (state.package.error) return true;
      if (!packageId) return true;
      if (!state.package.payload) return false;

      return !state.package.payload.work_package?.id || state.package.payload.work_package.id === packageId;
    case "solo": {
      if (state.solo.error) return true;
      const payload = state.solo.payload;
      if (!payload) return false;
      const payloadId = payload.solo_session?.id;
      return !payloadId || payloadId === selection.session.id;
    }
  }
}

function NaturalDetailBody({ motionKey, children }: { motionKey: string; children: React.ReactNode }) {
  return (
    <div className="detail-modal-natural-frame" data-detail-motion-key={motionKey}>
      <div className="detail-modal-size-inner">{children}</div>
    </div>
  );
}

function cardDetailMotionKey(
  selection: CardDetailSelection | null,
  state: {
    loadingPackage: boolean;
    loadingRequest: boolean;
    loadingSolo: boolean;
    packageDetail: WorkPackageDetailPayload | null;
    packageError: string | null;
    requestDetail: WorkRequestDetail | null;
    requestError: string | null;
    soloDetail: SoloSessionDetailPayload | null;
    soloError: string | null;
  },
) {
  if (!selection) return "closed";

  switch (selection.kind) {
    case "request":
      return `request:${selection.detail.work_request.id}:${detailLoadState(state.loadingRequest, state.requestDetail, state.requestError)}`;
    case "slice":
      return `slice:${selection.slice.id}:${selection.pkg?.id || "undispatched"}:${detailLoadState(state.loadingRequest, state.requestDetail, state.requestError)}`;
    case "package":
      return `package:${selection.pkg.id}:${detailLoadState(state.loadingPackage, state.packageDetail, state.packageError)}`;
    case "blocker":
      return `blocker:${selection.blocker.blocker_id || selection.blocker.id}:${selection.pkg?.id || selection.blocker.work_package_id || "unknown"}`;
    case "solo":
      return `solo:${selection.session.id}:${detailLoadState(state.loadingSolo, state.soloDetail, state.soloError)}`;
  }
}

function detailLoadState(loading: boolean, payload: unknown, error: string | null) {
  if (error) return "error";
  if (payload) return "loaded";
  return loading ? "loading" : "summary";
}
