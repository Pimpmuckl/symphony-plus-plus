import { AlertTriangle, Archive, CheckCircle2, Copy, ListChecks, Loader2, MessageSquareText, Trash2 } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import type { CopyArchitectHandoff, GuidanceItem, WorkRequestDetail } from "@/types/dashboard";
import { DetailDisclosure, DetailFacts, DetailHeader, DetailList, DetailLoadError, DetailSection, DetailSummaryBar, JsonDetail } from "@/components/dashboard/detail-layout";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { MarkdownBlock } from "@/components/dashboard/markdown-block";
import { architectHandoffEligibleRequest, isFinishedBoardStatus, operationalBadgeVariant, operationalLabel } from "@/lib/operational-state";
import { cn } from "@/lib/utils";
import { formatStatus, statusLabel } from "@/lib/status-labels";
import { useCallback, useReducer, useRef, useState } from "react";
import { CommentsPanel, useSyncedComments } from "./comments-panel";
import { RecentDecisionsDisclosure } from "./detail-extras";
import { commentStatLabel, commentStats, detailDate, requestCommentStats, requestOpenQuestions, requestProgressText, requestSliceCounts } from "./detail-utils";
import { ResolveContextComment, SubmitContextComment, WorkRequestMutation, WorkRequestStateMutation } from "./runtime";
import { clarificationGuidanceItem } from "./dashboard-data";
import { stripMarkdown } from "./dashboard-text";
import { initialRequestDetailUiState, requestDetailUiReducer, useScopedHandoffCopy } from "./dashboard-state";
import { repoDisplayName } from "./dashboard-persistence";

export function RequestDetailContent({
  detail,
  onSelectGuidance,
  onCopyArchitectHandoff,
  onArchiveWorkRequest,
  onChangeWorkRequestState,
  onDeleteWorkRequest,
  canMutateOperatorActions,
  onSubmitComment,
  onResolveComment,
  canMutateComments,
  detailError,
}: {
  detail: WorkRequestDetail;
  onSelectGuidance: (item: GuidanceItem) => void;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  onArchiveWorkRequest: WorkRequestMutation;
  onChangeWorkRequestState: WorkRequestStateMutation;
  onDeleteWorkRequest: WorkRequestMutation;
  canMutateOperatorActions: boolean;
  onSubmitComment: SubmitContextComment;
  onResolveComment: ResolveContextComment;
  canMutateComments: boolean;
  detailError?: string | null;
}) {
  const request = detail.work_request;
  const [requestComments, setRequestComments] = useSyncedComments(detail.comments || []);
  const [uiState, dispatchUiState] = useReducer(requestDetailUiReducer, initialRequestDetailUiState);
  const { archiveError, archivePending, commentsOpen, deleteError, deletePending, deliverConfirmOpen, stateError, statePending } = uiState;
  const setCommentsOpen = useCallback((open: boolean) => dispatchUiState({ type: "commentsOpen", open }), []);
  const setDeliverConfirmOpen = useCallback((open: boolean) => dispatchUiState({ type: "deliverConfirmOpen", open }), []);
  const commentTextareaRef = useRef<HTMLTextAreaElement | null>(null);
  const operational = request.operational_state || null;
  const detailFinished = [operational?.key, request.status].some(isFinishedBoardStatus);
  const openQuestions = requestOpenQuestions(detail);
  const sliceCounts = requestSliceCounts(detail);
  const currentCommentStats = requestCommentStats(detail, requestComments);
  const requestOnlyCommentStats = commentStats(requestComments);
  const handoffEligible = canMutateOperatorActions && !detailFinished && architectHandoffEligibleRequest(request);
  const handoffHasOpenQuestions = (openQuestions.length || request.open_question_count || 0) > 0;
  const handoffIdentity = `${handoffHasOpenQuestions}:${request.id}:${request.status || ""}:${request.updated_at || ""}`;
  const canManualArchive = canMutateOperatorActions && canArchiveWorkRequest(request);
  const canMarkDelivered = canMutateOperatorActions && !detailFinished;
  const canDelete = canMutateOperatorActions;
  const {
    cachedHandoff,
    error: handoffError,
    recordCopyError,
    recordCopyResult,
    startCopy,
    state: handoffCopyState,
  } = useScopedHandoffCopy(handoffIdentity);
  const preparedHandoff = cachedHandoff();
  const handoffButtonLabel = handoffHasOpenQuestions
    ? preparedHandoff
      ? "Copy Resume Architect Handoff"
      : "Prepare & Copy Resume Handoff"
    : preparedHandoff
      ? "Copy Architect Handoff"
      : "Prepare & Copy Handoff";

  async function copyHandoff() {
    startCopy();

    try {
      recordCopyResult(await onCopyArchitectHandoff(request.id, cachedHandoff()));
    } catch (caught) {
      recordCopyError(caught instanceof Error ? caught.message : "Architect handoff could not be copied");
    }
  }

  const openCommentComposer = useCallback(() => {
    setCommentsOpen(true);
    window.setTimeout(() => commentTextareaRef.current?.focus(), 80);
  }, [setCommentsOpen]);

  async function archiveRequest() {
    dispatchUiState({ type: "archivePending", pending: true });
    dispatchUiState({ type: "archiveError", error: null });

    try {
      await onArchiveWorkRequest(request.id);
    } catch (caught) {
      dispatchUiState({ type: "archiveError", error: caught instanceof Error ? caught.message : "WorkRequest was not archived" });
    } finally {
      dispatchUiState({ type: "archivePending", pending: false });
    }
  }

  async function deleteRequest() {
    dispatchUiState({ type: "deletePending", pending: true });
    dispatchUiState({ type: "deleteError", error: null });

    try {
      await onDeleteWorkRequest(request.id);
    } catch (caught) {
      dispatchUiState({ type: "deleteError", error: caught instanceof Error ? caught.message : "WorkRequest was not deleted" });
    } finally {
      dispatchUiState({ type: "deletePending", pending: false });
    }
  }

  async function markDelivered() {
    dispatchUiState({ type: "statePending", pending: true });
    dispatchUiState({ type: "stateError", error: null });

    try {
      await onChangeWorkRequestState(request.id, "completed");
      setDeliverConfirmOpen(false);
    } catch (caught) {
      dispatchUiState({ type: "stateError", error: caught instanceof Error ? caught.message : "WorkRequest state was not changed" });
    } finally {
      dispatchUiState({ type: "statePending", pending: false });
    }
  }

  return (
    <>
      <DetailHeader
        title={request.title || request.id}
        eyebrow={`${repoDisplayName(request)} / ${request.base_branch || "main"} / ${request.work_type || "feature"}`}
        identifier={request.id}
        identifierLabel="WorkRequest ID"
        badge={<Badge variant={operationalBadgeVariant(operational, request.status)}>{operationalLabel(operational, request.status)}</Badge>}
      />
      <div className="detail-modal-reveal-body grid gap-4">
        <DetailLoadError error={detailError} />
        {handoffEligible || canMutateComments ? (
          <div className={cn("detail-primary-actions", handoffHasOpenQuestions && "detail-primary-actions-muted")} data-guidance-section style={{ animationDelay: "58ms" }}>
            <div className="flex min-w-0 flex-wrap items-center gap-2">
              {handoffEligible ? (
                <Button type="button" size="sm" variant={handoffHasOpenQuestions ? "outline" : "default"} onClick={() => void copyHandoff()} disabled={handoffCopyState === "copying"}>
                  {handoffCopyState === "copying" ? <Loader2 className="size-4 animate-spin" /> : handoffCopyState === "copied" ? <CheckCircle2 className="size-4" /> : <Copy className="size-4" />}
                  {handoffCopyState === "copied" ? "Copied" : handoffButtonLabel}
                </Button>
              ) : null}
              {canMutateComments ? (
                <Button type="button" size="sm" variant="outline" onClick={openCommentComposer}>
                  <MessageSquareText className="size-4" />
                  Add Comment
                </Button>
              ) : null}
            </div>
            {handoffError ? <p className="text-xs text-destructive">{handoffError}</p> : null}
          </div>
        ) : null}
        <RequestStatusControl
          items={requestDetailSummary(detail, openQuestions.length, sliceCounts.total, currentCommentStats)}
          canArchive={canManualArchive}
          canDelete={canDelete}
          canMarkDelivered={canMarkDelivered}
          archiveError={archiveError}
          archivePending={archivePending}
          deleteError={deleteError}
          deletePending={deletePending}
          stateError={stateError}
          statePending={statePending}
          onArchive={() => void archiveRequest()}
          onDelete={() => void deleteRequest()}
          onMarkDelivered={() => setDeliverConfirmOpen(true)}
        />
        <DetailSection title="Product Intent">
          <MarkdownBlock value={request.human_description} empty="No operator-facing description has been recorded yet." />
        </DetailSection>
        <DetailSection title="Progress">
          <p>{requestProgressText(detail)}</p>
        </DetailSection>
        <DetailSection title="Blocked By">
          {openQuestions.length > 0 ? (
            <div className="grid gap-2">
              {openQuestions.slice(0, 2).map((question) => (
                <button
                  type="button"
                  key={question.id}
                  className="detail-list-item text-left hover:border-primary/50 hover:bg-primary/5"
                  onClick={() => onSelectGuidance(clarificationGuidanceItem(detail, question))}
                >
                  <span className="text-sm font-medium">{question.decision_prompt?.tl_dr || stripMarkdown(question.question) || "Open question"}</span>
                  {question.why_needed ? <span className="mt-1 line-clamp-2 text-xs text-muted-foreground">{stripMarkdown(question.why_needed)}</span> : null}
                </button>
              ))}
              {openQuestions.length > 2 ? <p className="text-xs text-muted-foreground">+{openQuestions.length - 2} more open question{openQuestions.length - 2 === 1 ? "" : "s"}</p> : null}
            </div>
          ) : (
            <p>No open human questions.</p>
          )}
        </DetailSection>
        <DetailDisclosure
          title="Comments"
          meta={commentStatLabel(requestOnlyCommentStats.open_comment_count, requestOnlyCommentStats.comment_count)}
          open={commentsOpen}
          onOpenChange={setCommentsOpen}
        >
          <CommentsPanel
            key={`work_request:${request.id}`}
            target={{ target_kind: "work_request", target_id: request.id }}
            comments={requestComments}
            onCommentsChange={setRequestComments}
            onSubmitComment={onSubmitComment}
            onResolveComment={onResolveComment}
            canMutate={canMutateComments}
            textareaRef={commentTextareaRef}
          />
        </DetailDisclosure>
        <RecentDecisionsDisclosure detail={detail} />
        <DetailDisclosure title="Product Plan" meta="IDs, constraints, plan nodes, and execution WorkPackages">
          <DetailFacts
            facts={[
              ["Request ID", request.id],
              ["Dispatch Shape", formatStatus(request.desired_dispatch_shape)],
              ["Raw Lifecycle", statusLabel(request.status)],
              ["Delivered", detailDate(request.completed_at)],
              ["Archived", detailDate(request.archived_at)],
              ["Created", detailDate(request.inserted_at)],
              ["Updated", detailDate(request.updated_at)],
            ]}
          />
          <DetailList title="Plan nodes" items={(detail.product_tree?.nodes || []).map((node) => node.title || node.id)} empty="No product plan nodes recorded." />
          <DetailList title="Execution WorkPackages" items={(detail.work_packages || []).map((slice) => slice.title || slice.id)} empty="No WorkPackages recorded." />
          <JsonDetail label="Constraints" value={request.constraints} />
        </DetailDisclosure>
      </div>
      <DangerousStateConfirmationDialog
        open={deliverConfirmOpen}
        onOpenChange={setDeliverConfirmOpen}
        title="Mark WorkRequest Delivered?"
        description="This manually marks the request Delivered for the local dashboard even if unfinished plan nodes, WorkPackages, or open questions still exist."
        confirmLabel="Mark Delivered"
        pending={statePending}
        onConfirm={() => void markDelivered()}
      />
    </>
  );
}

function RequestStatusControl({
  items,
  ...actions
}: {
  items: Array<{ label: string; value: string }>;
} & Parameters<typeof RequestDangerActions>[0]) {
  const [open, setOpen] = useState(false);
  const hasActions = actions.canMarkDelivered || actions.canArchive || actions.canDelete;

  if (!hasActions) return <DetailSummaryBar items={items} />;

  return (
    <div className="request-status-control" data-open={open ? "true" : "false"}>
      <div className="request-status-bar">
        <DetailSummaryBar items={items} />
        <Button
          type="button"
          size="icon"
          variant="ghost"
          className="request-status-actions-toggle"
          aria-expanded={open}
          aria-label={`${open ? "Hide" : "Show"} WorkRequest status actions`}
          onClick={() => setOpen((current) => !current)}
        >
          <ListChecks className="size-4" />
        </Button>
      </div>
      <div className="request-status-actions-reveal" aria-hidden={!open} inert={!open}>
        <div>
          <RequestDangerActions {...actions} />
        </div>
      </div>
    </div>
  );
}

function RequestDangerActions({
  archiveError,
  archivePending,
  canArchive,
  canDelete,
  canMarkDelivered,
  deleteError,
  deletePending,
  onArchive,
  onDelete,
  onMarkDelivered,
  stateError,
  statePending,
}: {
  archiveError: string | null;
  archivePending: boolean;
  canArchive: boolean;
  canDelete: boolean;
  canMarkDelivered: boolean;
  deleteError: string | null;
  deletePending: boolean;
  onArchive: () => void;
  onDelete: () => void;
  onMarkDelivered: () => void;
  stateError: string | null;
  statePending: boolean;
}) {
  if (!canMarkDelivered && !canArchive && !canDelete) return null;

  return (
    <div className="request-status-actions-row">
      <div className="flex flex-wrap gap-2">
        {canMarkDelivered ? (
          <Button type="button" size="sm" variant="destructive" onClick={onMarkDelivered} disabled={statePending}>
            {statePending ? <Loader2 className="size-4 animate-spin" /> : <CheckCircle2 className="size-4" />}
            Mark Delivered
          </Button>
        ) : null}
        {canArchive ? (
          <Button type="button" size="sm" variant="outline" disabled={archivePending} onClick={onArchive}>
            {archivePending ? <Loader2 className="size-4 animate-spin" /> : <Archive className="size-4" />}
            Archive Request
          </Button>
        ) : null}
        {canDelete ? (
          <Button type="button" size="sm" variant="destructive" disabled={deletePending} onClick={onDelete}>
            {deletePending ? <Loader2 className="size-4 animate-spin" /> : <Trash2 className="size-4" />}
            Delete Request
          </Button>
        ) : null}
      </div>
      {stateError ? <p className="text-xs text-destructive">{stateError}</p> : null}
      {archiveError ? <p className="text-xs text-destructive">{archiveError}</p> : null}
      {deleteError ? <p className="text-xs text-destructive">{deleteError}</p> : null}
    </div>
  );
}

function requestDetailSummary(
  detail: WorkRequestDetail,
  openQuestionCount: number,
  sliceCount: number,
  currentCommentStats: ReturnType<typeof requestCommentStats>,
) {
  const request = detail.work_request;

  return [
    { label: "WorkPackages", value: String(sliceCount) },
    { label: "Open Questions", value: String(openQuestionCount || request.open_question_count || 0) },
    { label: "Decisions", value: String(detail.summary?.decision_count ?? detail.decision_logs?.length ?? 0) },
    { label: "Comments", value: commentStatLabel(currentCommentStats.open_comment_count, currentCommentStats.comment_count) },
    { label: "Updated", value: detailDate(request.updated_at || request.inserted_at) },
  ];
}

export function canArchiveWorkRequest(request: WorkRequestDetail["work_request"]) {
  const finishedState = request.operational_state?.key || request.status;
  return Boolean(!request.archived_at && (request.completed_at || isFinishedBoardStatus(finishedState)));
}

export function DangerousStateConfirmationDialog({
  open,
  onOpenChange,
  title,
  description,
  confirmLabel,
  pending,
  onConfirm,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  description: string;
  confirmLabel: string;
  pending: boolean;
  onConfirm: () => void;
}) {
  return (
    <Dialog open={open} onOpenChange={(nextOpen) => (!pending ? onOpenChange(nextOpen) : undefined)}>
      <DialogContent className="dashboard-dialog-content sm:max-w-[420px]">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <AlertTriangle className="size-4 text-destructive" />
            {title}
          </DialogTitle>
          <DialogDescription>{description}</DialogDescription>
        </DialogHeader>
        <div className="flex justify-end gap-2">
          <Button type="button" variant="outline" disabled={pending} onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button type="button" variant="destructive" disabled={pending} onClick={onConfirm}>
            {pending ? <Loader2 className="size-4 animate-spin" /> : <CheckCircle2 className="size-4" />}
            {confirmLabel}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
