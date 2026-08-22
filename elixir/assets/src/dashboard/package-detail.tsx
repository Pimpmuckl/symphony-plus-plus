import { CheckCircle2, Loader2 } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { DetailDisclosure, DetailFacts, DetailHeader, DetailList, DetailLoadError, DetailSection, DetailStatGrid, DetailSummaryBar } from "@/components/dashboard/detail-layout";
import { MarkdownBlock } from "@/components/dashboard/markdown-block";
import type { ActiveBlockingEdgeEndpoint, WorkRequestPackage, WorkPackageCard, WorkPackageDetailPayload, WorkRequestDetail } from "@/types/dashboard";
import { isFinishedBoardStatus, operationalBadgeVariant, operationalLabel, sliceOperationalState } from "@/lib/operational-state";
import { statusLabel } from "@/lib/status-labels";
import { useCallback, useReducer, useState } from "react";
import { CardDetailSelection, ResolveContextComment, SubmitContextComment, WorkPackageArchiveMutation, WorkPackageBlockerClearMutation, WorkPackageStateAction, WorkPackageStateMutation } from "./runtime";
import { CommentsPanel, useSyncedComments } from "./comments-panel";
import { packageBlockerCopyText } from "./detail-copy";
import { DetailAttentionList, RecentDecisionsDisclosure } from "./detail-extras";
import { commentStatLabel, detailDate, latestPackageProgress, packageOperationalFallbackText, planSummaryText, sliceDeliveryFacts, sliceDeliverySummary, sliceProgressText, targetCommentStats } from "./detail-utils";
import { initialPackageDetailUiState, packageDetailUiReducer } from "./dashboard-state";
import { repoDisplayName } from "./dashboard-persistence";
import { PackageDetailBody, PackageDetailDialogs, type PackageDetailComments, type PackageDetailControls, type PackageDetailDialogControls, type PackageDetailPackage, type PackageDetailStatus } from "./package-detail-presentation";
import { activePackageBlockers, packageBlockerEdge } from "./blocker-selection";
import { AttentionLocationBar } from "./attention-location";
import type { AttentionJumpDestination, AttentionLocation, AttentionTarget } from "./workstream-attention";

export function SliceDetailContent({
  detail,
  slice,
  pkg,
  onSubmitComment,
  onResolveComment,
  detailError,
  attentionTarget,
  onSelectAttention,
}: {
  detail: WorkRequestDetail;
  slice: WorkRequestPackage;
  pkg?: WorkPackageCard;
  onSubmitComment: SubmitContextComment;
  onResolveComment: ResolveContextComment;
  detailError?: string | null;
  attentionTarget?: AttentionTarget;
  onSelectAttention: (target: AttentionTarget) => void;
}) {
  const [sliceComments, setSliceComments] = useSyncedComments(slice.comments || []);
  const status = slice.work_package_status || slice.status;
  const operational = sliceOperationalState(slice, pkg);
  const blockerCount = pkg?.active_blocker_count || 0;
  const blocked = blockerCount > 0 || pkg?.status === "blocked" || operational?.key === "blocked";
  const reviewLabel = [slice.review?.type, slice.review?.args?.mode].filter(Boolean).join(" / ");
  const attentionItems = operational?.attention_items || [];
  const currentCommentStats = targetCommentStats(slice, slice.comments || [], sliceComments);
  const deliveryFacts = sliceDeliveryFacts(slice);
  const deliverySummary = sliceDeliverySummary(slice, operational);
  const deliveryMarkdown = sliceDeliveryMarkdown(slice);

  return (
    <>
      <DetailHeader
        title={slice.title || pkg?.title || slice.id}
        eyebrow={`${repoDisplayName(detail.work_request)} / ${detail.work_request.title || detail.work_request.id}`}
        identifier={pkg?.id || slice.work_package_id || slice.id}
        identifierLabel="WorkPackage ID"
        badge={<Badge variant={operationalBadgeVariant(operational, status)}>{operationalLabel(operational, status)}</Badge>}
      />
      <div className="detail-modal-reveal-body grid gap-4">
        <DetailLoadError error={detailError} />
        <DetailSummaryBar
          items={[
            { label: "Review", value: reviewLabel || "Not recorded" },
            { label: "Blockers", value: String(blockerCount) },
            { label: "Comments", value: commentStatLabel(currentCommentStats.open_comment_count, currentCommentStats.comment_count) },
            { label: "Updated", value: detailDate(slice.updated_at || slice.dispatched_at || slice.inserted_at) },
          ]}
        />
        <DetailSection title="Package Goal">
          <MarkdownBlock value={slice.goal} empty={pkg?.kind || "No package goal has been recorded yet."} />
        </DetailSection>
        <DetailSection title="Progress">
          <div className="grid gap-2">
            <p>{operational?.reason || sliceProgressText(slice, pkg)}</p>
            {attentionItems.length > 0 ? <DetailAttentionList items={attentionItems} /> : null}
          </div>
        </DetailSection>
        {deliverySummary || deliveryFacts.length > 0 ? (
          <DetailDisclosure title="Delivery" meta={slice.delivery?.outcome ? statusLabel(slice.delivery.outcome) : operationalLabel(operational, status)}>
            {deliveryMarkdown ? (
              <MarkdownDetail label={deliveryMarkdown.label} value={deliveryMarkdown.value} />
            ) : deliverySummary ? (
              <MarkdownBlock className="mb-3 text-sm" value={deliverySummary} />
            ) : null}
            <DetailFacts facts={deliveryFacts} />
          </DetailDisclosure>
        ) : null}
        <DetailSection title="Blocked By">
          {blocked && attentionTarget ? (
            <button
              type="button"
              className="detail-list-item w-full cursor-pointer text-left transition-colors hover:border-primary/40 hover:bg-accent/60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
              onClick={() => onSelectAttention(attentionTarget)}
            >
              {blockerCount > 0
                ? `${blockerCount} active blocker${blockerCount === 1 ? "" : "s"} on the linked work package.`
                : "Package is marked blocked without a separate blocker record."}
            </button>
          ) : (
            <p>No blocker surfaced for this package.</p>
          )}
        </DetailSection>
        <DetailDisclosure title="Comments" meta={commentStatLabel(currentCommentStats.open_comment_count, currentCommentStats.comment_count)}>
          <CommentsPanel
            key={`work_package:${slice.id}`}
            target={{ target_kind: "work_package", target_id: slice.id }}
            comments={sliceComments}
            onCommentsChange={setSliceComments}
            onSubmitComment={onSubmitComment}
            onResolveComment={onResolveComment}
            canMutate
          />
        </DetailDisclosure>
        <RecentDecisionsDisclosure detail={detail} />
        <DetailDisclosure title="Details" meta="Branch, files, and acceptance">
          <DetailFacts
            facts={[
              ["WorkPackage ID", slice.id],
              ["Raw Lifecycle", statusLabel(slice.status)],
              ["Target Branch", slice.base_branch || detail.work_request.base_branch || "main"],
              ["Dispatched", detailDate(slice.dispatched_at)],
            ]}
          />
          <DetailList title="Acceptance" items={slice.acceptance_criteria || []} empty="No acceptance criteria recorded." />
          <DetailList title="Validation" items={slice.validation_steps || []} empty="No validation steps recorded." />
          <DetailList title="Owned paths" items={slice.allowed_file_globs || []} empty="No owned path constraints recorded." />
          <DetailList title="Stop conditions" items={slice.stop_conditions || []} empty="No stop conditions recorded." />
        </DetailDisclosure>
      </div>
    </>
  );
}

export function BlockerDetailContent({
  selection,
  detailPayload,
  loading,
  error,
  location,
  onJumpToAttention,
  onClearWorkPackageBlocker,
}: {
  selection: Extract<CardDetailSelection, { kind: "blocker" }>;
  detailPayload: WorkPackageDetailPayload | null;
  loading: boolean;
  error: string | null;
  location?: AttentionLocation;
  onJumpToAttention?: (destination: AttentionJumpDestination) => void;
  onClearWorkPackageBlocker: WorkPackageBlockerClearMutation;
}) {
  const [pending, setPending] = useState(false);
  const [clearError, setClearError] = useState<string | null>(null);
  const scopedDetailPayload = scopedBlockerDetailPayload(selection, detailPayload);
  const pkg = selection.pkg || scopedDetailPayload?.work_package;
  const detail = selection.detail;
  const slice = selection.slice;
  const loadedBlocker = matchingLoadedBlocker(selection.blocker.blocker_id, scopedDetailPayload);
  const blocker = loadedBlocker && pkg ? packageBlockerEdge(loadedBlocker, pkg, { detail, slice }) : selection.blocker;
  const blockerId = blocker.blocker_id;
  const displayBlockerId = blockerId || blocker.id;
  const workPackageId = blockerDetailWorkPackageId(selection, scopedDetailPayload, blocker);
  const title = blocker.summary || pkg?.title || displayBlockerId || "Active blocker";

  async function clearBlocker() {
    if (!workPackageId || !blockerId) return;

    setPending(true);
    setClearError(null);

    try {
      await onClearWorkPackageBlocker(workPackageId, blockerId);
    } catch (caught) {
      setClearError(caught instanceof Error ? caught.message : "Blocker was not cleared");
    } finally {
      setPending(false);
    }
  }

  return (
    <>
      <DetailHeader
        title={title}
        eyebrow={`${pkg ? repoDisplayName(pkg) : detail ? repoDisplayName(detail.work_request) : "Work package"} / active blocker`}
        badge={<Badge variant="danger">Blocked</Badge>}
      />
      {location ? <AttentionLocationBar location={location} onJump={onJumpToAttention} /> : null}
      <div className="detail-modal-reveal-body grid gap-4">
        <DetailStatGrid
          stats={[
            { label: "Blocker", value: displayBlockerId || "Not recorded" },
            { label: "Package", value: workPackageId || "Not linked" },
            { label: "Request", value: detail?.work_request.id || blocker.work_request_id || "Not linked" },
            { label: "WorkPackage", value: slice?.id || blocker.work_package_id || "Not linked" },
            { label: "Blocked Since", value: detailDate(blocker.updated_at) },
          ]}
        />
        <DetailSection title="Blocker">
          <MarkdownBlock value={blocker.body || blocker.summary || ""} empty={loading ? "Loading blocker detail..." : "No blocker body recorded."} />
          {error ? <p className="mt-2 text-xs text-destructive">{error}</p> : null}
        </DetailSection>
        <DetailSection title="Context">
          <DetailFacts
            facts={[
              ["From", endpointLabel(blocker.from)],
              ["To", endpointLabel(blocker.to)],
              ["WorkPackage", pkg?.title || workPackageId || "Not linked"],
              ["WorkPackage", slice?.title || slice?.id || blocker.work_package_id || "Not linked"],
              ["Work Request", detail?.work_request.title || detail?.work_request.id || blocker.work_request_id || "Not linked"],
            ]}
          />
        </DetailSection>
        <div className="flex flex-col items-start gap-2 border-t border-destructive/20 pt-4">
          <Button type="button" size="sm" variant="destructive" onClick={() => void clearBlocker()} disabled={pending || !workPackageId || !blockerId}>
            {pending ? <Loader2 className="size-4 animate-spin" /> : <CheckCircle2 className="size-4" />}
            Clear
          </Button>
          {clearError ? <p className="text-xs text-destructive">{clearError}</p> : null}
          {!workPackageId || !blockerId ? <p className="text-xs text-destructive">Blocker cannot be cleared because its package or blocker id is missing.</p> : null}
        </div>
      </div>
    </>
  );
}

export function scopedBlockerDetailPayload(
  selection: Extract<CardDetailSelection, { kind: "blocker" }>,
  detailPayload: WorkPackageDetailPayload | null,
) {
  const selectedPackageId = selection.pkg?.id || selection.blocker.work_package_id || endpointId(selection.blocker.to, "work_package");
  return detailPayload && (!selectedPackageId || detailPayload.work_package?.id === selectedPackageId) ? detailPayload : null;
}

export function blockerDetailWorkPackageId(
  selection: Extract<CardDetailSelection, { kind: "blocker" }>,
  detailPayload: WorkPackageDetailPayload | null,
  blocker = selection.blocker,
) {
  return (
    selection.pkg?.id ||
    detailPayload?.work_package?.id ||
    blocker.work_package_id ||
    endpointId(blocker.to, "work_package") ||
    selection.slice?.work_package_id ||
    null
  );
}

function matchingLoadedBlocker(blockerId: string | null | undefined, detailPayload: WorkPackageDetailPayload | null) {
  const blockers = activePackageBlockers(detailPayload?.work_package ? { ...detailPayload.work_package, active_blockers: detailPayload.blockers || [] } : undefined);
  if (blockerId) return blockers.find((blocker) => blocker.id === blockerId) || null;
  return null;
}

function endpointId(endpoint: ActiveBlockingEdgeEndpoint | undefined, kind: ActiveBlockingEdgeEndpoint["kind"]) {
  return endpoint?.kind === kind ? endpoint.id : null;
}

function endpointLabel(endpoint: ActiveBlockingEdgeEndpoint | undefined) {
  if (!endpoint) return "Not recorded";
  return `${statusLabel(endpoint.kind)} ${endpoint.id}`;
}

export function PackageDetailContent({
  selection,
  detailPayload,
  loading,
  error,
  onChangeWorkPackageState,
  onArchiveWorkPackage,
  linkedWorkPackageIds,
  onSubmitComment,
  onResolveComment,
}: {
  selection: Extract<CardDetailSelection, { kind: "package" }>;
  detailPayload: WorkPackageDetailPayload | null;
  loading: boolean;
  error: string | null;
  onChangeWorkPackageState: WorkPackageStateMutation;
  onArchiveWorkPackage: WorkPackageArchiveMutation;
  linkedWorkPackageIds: Set<string>;
  onSubmitComment: SubmitContextComment;
  onResolveComment: ResolveContextComment;
}) {
  const [packageComments, setPackageComments] = useSyncedComments(detailPayload?.comments || []);
  const [uiState, dispatchUiState] = useReducer(packageDetailUiReducer, initialPackageDetailUiState);
  const {
    archiveError,
    archivePending,
    stateError,
    statePending,
  } = uiState;
  const setEvidenceDialogOpen = useCallback((open: boolean) => dispatchUiState({ type: "evidenceDialogOpen", open }), []);
  const setNoPrEvidence = useCallback((value: string) => dispatchUiState({ type: "noPrEvidence", value }), []);
  const pkg = { ...selection.pkg, ...(detailPayload?.work_package || {}) } as PackageDetailPackage;
  const summary = detailPayload?.summary;
  const blockers = (detailPayload?.blockers || []).filter((blocker) => blocker.active !== false);
  const progress = latestPackageProgress(detailPayload);
  const plan = summary?.plan || pkg.plan;
  const operational = pkg.operational_state || null;
  const lineage = detailPayload?.lineage || pkg.lineage || null;
  const purposeMarkdown = packagePurposeMarkdown(pkg);
  const attentionItems = operational?.attention_items || [];
  const blockerCount = packageBlockerCount(blockers.length, summary, pkg, operational);
  const blockerCopyText = blockerCount > 0
    ? packageBlockerCopyText({
        blockerCount,
        blockers,
        operationalTruth: operational?.reason || packageOperationalFallbackText(pkg),
        pkg,
        repo: repoDisplayName(pkg),
        state: operationalLabel(operational, pkg.status),
      })
    : "";
  const currentCommentStats = targetCommentStats(summary || pkg, detailPayload?.comments || [], packageComments);
  const canMarkMerged = !isFinishedBoardStatus(operational?.key || pkg.status);
  const isLinkedPackage = linkedWorkPackageIds.has(pkg.id);
  const canArchiveUnlinked = !isLinkedPackage && ["merged", "closed"].includes(pkg.status || "");
  const canCloseWithEvidence = Boolean(isLinkedPackage && canMarkMerged && readyWithoutMerge(pkg, operational));
  const stateActions: Array<{ value: WorkPackageStateAction; label: string }> = isLinkedPackage
    ? linkedPackageStateActions(pkg, operational, canMarkMerged, canCloseWithEvidence)
    : !isLinkedPackage && canMarkMerged
      ? [
          { value: "merged_and_archive", label: "Merged + Archive" },
          { value: "closed_and_archive", label: "Closed + Archive" },
        ]
      : [];
  function selectStateAction(action: string) {
    const nextAction = action as WorkPackageStateAction;
    dispatchUiState({ type: "stateError", error: null });
    setNoPrEvidence("");

    if (nextAction === "completed_no_pr") {
      setEvidenceDialogOpen(true);
      return;
    }

    void changePackageState(nextAction);
  }

  async function changePackageState(action: WorkPackageStateAction, options?: { noPrEvidence?: string }) {
    dispatchUiState({ type: "statePending", pending: true });
    dispatchUiState({ type: "stateError", error: null });

    try {
      await onChangeWorkPackageState(pkg.id, action, options);
      dispatchUiState({ type: "stateClosed" });
    } catch (caught) {
      dispatchUiState({ type: "stateError", error: caught instanceof Error ? caught.message : "WorkPackage state was not changed" });
    } finally {
      dispatchUiState({ type: "statePending", pending: false });
    }
  }

  async function archivePackage() {
    dispatchUiState({ type: "archivePending", pending: true });
    dispatchUiState({ type: "archiveError", error: null });

    try {
      await onArchiveWorkPackage(pkg.id);
    } catch (caught) {
      dispatchUiState({ type: "archiveError", error: caught instanceof Error ? caught.message : "WorkPackage was not archived" });
    } finally {
      dispatchUiState({ type: "archivePending", pending: false });
    }
  }

  const comments: PackageDetailComments = {
    canMutate: true,
    comments: packageComments,
    onCommentsChange: setPackageComments,
    onResolveComment,
    onSubmitComment,
  };
  const controls: PackageDetailControls = {
    actions: stateActions,
    archiveError,
    archivePending,
    canArchiveUnlinked,
    onArchiveRequest: () => void archivePackage(),
    onSelectStateAction: selectStateAction,
    stateError,
    statePending,
  };
  const dialogControls: PackageDetailDialogControls = {
    changePackageState,
    setEvidenceDialogOpen,
    setNoPrEvidence,
  };
  const status: PackageDetailStatus = { error, loading };

  return (
    <>
      <PackageDetailBody
        attentionItems={attentionItems}
        blockerCopyText={blockerCopyText}
        blockerCount={blockerCount}
        blockers={blockers}
        comments={comments}
        controls={controls}
        currentCommentStats={currentCommentStats}
        detailPayload={detailPayload}
        lineage={lineage}
        operational={operational}
        pkg={pkg}
        planLabel={planSummaryText(plan)}
        progress={progress}
        purposeMarkdown={purposeMarkdown}
        selection={selection}
        status={status}
        summary={summary}
      />
      <PackageDetailDialogs controls={dialogControls} uiState={uiState} />
    </>
  );
}

function MarkdownDetail({ label, value }: { label: string; value: string }) {
  return (
    <div className="mb-3 grid gap-1">
      <p className="text-xs font-semibold text-muted-foreground">{label}</p>
      <MarkdownBlock className="text-sm" value={value} />
    </div>
  );
}

function sliceDeliveryMarkdown(slice: WorkRequestPackage) {
  if (slice.delivery?.outcome === "completed_no_pr" && slice.delivery.no_pr_evidence) {
    return { label: "Evidence", value: slice.delivery.no_pr_evidence };
  }

  if (slice.delivery?.outcome === "superseded" && slice.delivery.superseded_reason) {
    return { label: "Reason", value: slice.delivery.superseded_reason };
  }

  if (slice.delivery?.outcome === "abandoned" && slice.delivery.abandoned_rationale) {
    return { label: "Rationale", value: slice.delivery.abandoned_rationale };
  }

  return null;
}

function packagePurposeMarkdown(pkg: { engineering_scope?: string | null; product_description?: string | null }) {
  return pkg.engineering_scope || pkg.product_description || "";
}

function packageBlockerCount(
  visibleBlockerCount: number,
  summary: WorkPackageDetailPayload["summary"] | undefined,
  pkg: WorkPackageCard,
  operational: WorkPackageCard["operational_state"] | null,
) {
  return visibleBlockerCount || summary?.active_blocker_count || pkg.active_blocker_count || (operational?.key === "blocked" || pkg.status === "blocked" ? 1 : 0);
}

export function linkedPackageStateActions(
  pkg: WorkPackageCard,
  operational: WorkPackageCard["operational_state"] | null,
  canMarkMerged: boolean,
  canCloseWithEvidence: boolean,
): Array<{ value: WorkPackageStateAction; label: string }> {
  if (!canMarkMerged) return [];
  if (readyWithoutMerge(pkg, operational)) return canCloseWithEvidence ? [{ value: "completed_no_pr", label: "Close With Evidence" }] : [];
  if ((operational?.merge_required ?? pkg.merge_required) === false) return [];

  return [
    { value: "merged", label: "Mark Merged" },
  ];
}

function readyWithoutMerge(pkg: WorkPackageCard, operational: WorkPackageCard["operational_state"] | null) {
  const key = operational?.key || "";
  if (key === "ready_to_finish") return operational?.tone !== "warning";
  if (key === "merge_ready") return false;
  return (operational?.raw_status || pkg.status || "") === "ready_for_merge" && (operational?.merge_required ?? pkg.merge_required) === false;
}
