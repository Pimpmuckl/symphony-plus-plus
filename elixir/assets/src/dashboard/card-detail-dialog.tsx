import type { CopyArchitectHandoff, GuidanceItem, SoloSessionDetailPayload, WorkPackageDetailPayload, WorkRequestDetail } from "@/types/dashboard";
import { Dialog, DialogContent } from "@/components/ui/dialog";
import type * as React from "react";
import { dashboardPrefersReducedMotion } from "@/components/dashboard/motion-utils";
import { useEffect, useReducer, useState } from "react";
import { CARD_DETAIL_HEIGHT_MS, CARD_DETAIL_LOADING_HOLD_MS, CARD_DETAIL_WIDTH_MS, CardDetailSelection, CardDetailStage, ResolveContextComment, SubmitContextComment, WorkPackageArchiveMutation, WorkPackageBlockerClearMutation, WorkPackageStateMutation, WorkRequestMutation, WorkRequestStateMutation, ensureDashboardRuntimeConfig, jsonHeaders, operatorApiUrl, operatorFetch, readDashboardApiResponse, withLocalOperatorReconnect } from "./runtime";
import { CardDetailLoadingContent } from "./card-detail-loading";
import { BlockerDetailContent, PackageDetailContent, SliceDetailContent } from "./package-detail";
import { RequestDetailContent } from "./request-detail";
import { SoloSessionDetailContent } from "./solo-detail";
import { cardDetailContentReady, cardDetailPackageId, cardDetailRequestResourceKey, matchingPackageResource, matchingRequestResource, mergeRequestDetail, type CardDetailDialogState, type DetailResourceState } from "./card-detail-state";

export type CardDetailDialogAction =
  | { type: "resetPackage" }
  | { type: "loadPackage"; packageId: string }
  | { type: "packageSuccess"; packageId: string; payload: WorkPackageDetailPayload }
  | { type: "packageError"; packageId: string; error: string }
  | { type: "resetRequest" }
  | { type: "loadRequest"; resourceKey: string }
  | { type: "requestSuccess"; resourceKey: string; payload: WorkRequestDetail }
  | { type: "requestError"; resourceKey: string; error: string }
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
      return { ...state, package: { payload: null, loading: true, error: null, resourceKey: action.packageId } };
    case "packageSuccess":
      return { ...state, package: { payload: action.payload, loading: false, error: null, resourceKey: action.packageId } };
    case "packageError":
      return { ...state, package: { payload: null, loading: false, error: action.error, resourceKey: action.packageId } };
    case "resetRequest":
      return { ...state, request: emptyRequestDetailState };
    case "loadRequest":
      return { ...state, request: { payload: null, loading: true, error: null, resourceKey: action.resourceKey } };
    case "requestSuccess":
      return { ...state, request: { payload: action.payload, loading: false, error: null, resourceKey: action.resourceKey } };
    case "requestError":
      return { ...state, request: { payload: null, loading: false, error: action.error, resourceKey: action.resourceKey } };
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
  onCloseAutoFocus,
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
  onCloseAutoFocus?: React.ComponentProps<typeof DialogContent>["onCloseAutoFocus"];
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
  const requestResourceKey = cardDetailRequestResourceKey(selection);
  const selectedSliceId = selection?.kind === "slice" ? selection.slice.id : null;
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
    dispatch({ type: "loadPackage", packageId });

    loadOperatorPayload<WorkPackageDetailPayload>(`/work-packages/${encodeURIComponent(packageId)}`, controller.signal, "Package detail unavailable")
      .then((payload) => {
        if (!controller.signal.aborted) dispatch({ type: "packageSuccess", packageId, payload });
      })
      .catch((caught) => {
        if (caught instanceof DOMException && caught.name === "AbortError") return;
        if (!controller.signal.aborted) dispatch({ type: "packageError", packageId, error: caught instanceof Error ? caught.message : "Package detail unavailable" });
      });

    return () => controller.abort();
  }, [packageId]);

  useEffect(() => {
    if (!requestId || !requestResourceKey) {
      dispatch({ type: "resetRequest" });
      return;
    }

    const controller = new AbortController();
    dispatch({ type: "loadRequest", resourceKey: requestResourceKey });
    const query = selectedSliceId ? `?work_package_id=${encodeURIComponent(selectedSliceId)}` : "";

    loadOperatorPayload<WorkRequestDetail>(`/work-requests/${encodeURIComponent(requestId)}${query}`, controller.signal, "WorkRequest detail unavailable")
      .then((payload) => {
        if (!controller.signal.aborted) dispatch({ type: "requestSuccess", resourceKey: requestResourceKey, payload });
      })
      .catch((caught) => {
        if (caught instanceof DOMException && caught.name === "AbortError") return;
        if (!controller.signal.aborted) dispatch({ type: "requestError", resourceKey: requestResourceKey, error: caught instanceof Error ? caught.message : "WorkRequest detail unavailable" });
      });

    return () => controller.abort();
  }, [requestId, requestResourceKey, selectedSliceId]);

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
      <DialogContent className="dashboard-dialog-content card-detail-dialog" data-detail-stage={activeDetailStage} onCloseAutoFocus={onCloseAutoFocus} resizeKey={`${activeDetailStage}:${detailMotionKey}`}>
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
      {
        const packageResource = matchingPackageResource(selection, state);

      return (
        <PackageDetailContent
          selection={selection}
          detailPayload={packageResource.payload}
          loading={!packageResource.payload && !packageResource.error ? true : packageResource.loading}
          error={packageResource.error}
          onChangeWorkPackageState={onChangeWorkPackageState}
          onArchiveWorkPackage={onArchiveWorkPackage}
          canMutateOperatorActions={canMutateOperatorActions}
          linkedWorkPackageIds={linkedWorkPackageIds}
          onSubmitComment={onSubmitComment}
          onResolveComment={onResolveComment}
          canMutateComments={canMutateComments}
        />
      );
      }
    case "blocker":
      {
        const packageResource = matchingPackageResource(selection, state);
        return <BlockerDetailContent selection={selection} detailPayload={packageResource.payload} loading={!packageResource.payload && !packageResource.error} error={packageResource.error} onClearWorkPackageBlocker={onClearWorkPackageBlocker} canMutateOperatorActions={canMutateOperatorActions} />;
      }
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
  const requestResource = matchingRequestResource(selection, state);
  const detail = matchingRequestDetail(selection, requestResource.payload);
  return <RequestDetailContent detail={detail} detailError={requestResource.error} {...props} />;
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
  const requestResource = matchingRequestResource(selection, state);
  const detail = matchingRequestDetail(selection, requestResource.payload);
  const slice = detail.work_packages?.find((candidate) => candidate.id === selection.slice.id) || selection.slice;

  return <SliceDetailContent detail={detail} slice={slice} pkg={selection.pkg} detailError={requestResource.error} {...props} />;
}

function matchingRequestDetail(selection: Extract<CardDetailSelection, { kind: "request" | "slice" }>, payload: WorkRequestDetail | null) {
  if (!payload || payload.work_request.id !== selection.detail.work_request.id) return selection.detail;
  return mergeRequestDetail(selection.detail, payload);
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

function cardDetailRequestId(selection: CardDetailSelection | null) {
  if (selection?.kind === "request" || selection?.kind === "slice") return selection.detail.work_request.id;
  return null;
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
