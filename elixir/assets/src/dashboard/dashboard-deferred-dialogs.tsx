import type { ComponentProps } from "react";
import { lazy, Suspense, useEffect, useRef } from "react";

import type { ActiveBlockingEdge, CopyArchitectHandoff, GuidanceAnswerSubmission, GuidanceItem, WorkRequestDetail } from "@/types/dashboard";
import type { AppDialogState } from "./dashboard-state";
import type {
  CardDetailSelection,
  ResolveContextComment,
  SubmitContextComment,
  WorkPackageArchiveMutation,
  WorkPackageBlockerClearMutation,
  WorkPackageStateMutation,
  WorkRequestMutation,
  WorkRequestStateMutation,
} from "./runtime";
import { attentionTargetForGuidance, attentionLocationForSelection, type AttentionJumpDestination, type AttentionTarget } from "./workstream-attention";

const AttentionDialog = lazy(() => import("./attention-dialog").then((module) => ({ default: module.AttentionDialog })));
const loadCardDetailDialog = () => import("./card-detail-dialog").then((module) => ({ default: module.CardDetailDialog }));
const CardDetailDialog = lazy(loadCardDetailDialog);

export function DashboardDeferredDialogs({
  activeBlockingEdges,
  canMutateComments,
  canMutateOperatorActions,
  changeWorkPackageState,
  changeWorkRequestState,
  copyArchitectHandoff,
  dialogState,
  linkedWorkPackageIds,
  requestDetails,
  onJumpToAttention,
  onArchiveWorkPackage,
  onArchiveWorkRequest,
  onClearWorkPackageBlocker,
  onDeleteWorkRequest,
  onResolveComment,
  onSelectAttention,
  onSelectCard,
  onSubmitComment,
  onSubmitGuidanceAnswer,
}: {
  activeBlockingEdges: ActiveBlockingEdge[];
  canMutateComments: boolean;
  canMutateOperatorActions: boolean;
  changeWorkPackageState: WorkPackageStateMutation;
  changeWorkRequestState: WorkRequestStateMutation;
  copyArchitectHandoff: CopyArchitectHandoff;
  dialogState: AppDialogState;
  linkedWorkPackageIds: Set<string>;
  requestDetails: WorkRequestDetail[];
  onJumpToAttention: (destination: AttentionJumpDestination) => void;
  onArchiveWorkPackage: WorkPackageArchiveMutation;
  onArchiveWorkRequest: WorkRequestMutation;
  onClearWorkPackageBlocker: WorkPackageBlockerClearMutation;
  onDeleteWorkRequest: WorkRequestMutation;
  onResolveComment: ResolveContextComment;
  onSelectAttention: (target: AttentionTarget | null) => void;
  onSelectCard: (selection: CardDetailSelection | null) => void;
  onSubmitComment: SubmitContextComment;
  onSubmitGuidanceAnswer: (item: GuidanceItem, submission: GuidanceAnswerSubmission) => Promise<void>;
}) {
  useEffect(() => {
    void loadCardDetailDialog();
  }, []);

  return (
    <>
      {dialogState.selectedAttention ? (
        <AttentionDialogWithFocusReturn
          canMutateOperatorActions={canMutateOperatorActions}
          onChangeWorkPackageState={changeWorkPackageState}
          onChangeWorkRequestState={changeWorkRequestState}
          onClearWorkPackageBlocker={onClearWorkPackageBlocker}
          onJumpToAttention={onJumpToAttention}
          onOpenChange={(open) => {
            if (!open) onSelectAttention(null);
          }}
          onSubmitGuidanceAnswer={onSubmitGuidanceAnswer}
          requestDetails={requestDetails}
          target={dialogState.selectedAttention}
        />
      ) : null}
      {dialogState.selectedCardDetail ? (
        <CardDetailDialogWithFocusReturn
          selection={dialogState.selectedCardDetail}
          activeBlockingEdges={activeBlockingEdges}
          attentionLocation={dialogState.selectedCardDetail.kind === "blocker" ? attentionLocationForSelection(dialogState.selectedCardDetail, requestDetails) : undefined}
          onJumpToAttention={onJumpToAttention}
          onOpenChange={(open) => {
            if (!open) onSelectCard(null);
          }}
          onSelectGuidance={(item) => onSelectAttention(attentionTargetForGuidance(item))}
          onSelectAttention={onSelectAttention}
          onCopyArchitectHandoff={copyArchitectHandoff}
          onArchiveWorkRequest={onArchiveWorkRequest}
          onChangeWorkRequestState={changeWorkRequestState}
          onDeleteWorkRequest={onDeleteWorkRequest}
          onChangeWorkPackageState={changeWorkPackageState}
          onArchiveWorkPackage={onArchiveWorkPackage}
          onClearWorkPackageBlocker={onClearWorkPackageBlocker}
          canMutateOperatorActions={canMutateOperatorActions}
          linkedWorkPackageIds={linkedWorkPackageIds}
          onSubmitComment={onSubmitComment}
          onResolveComment={onResolveComment}
          canMutateComments={canMutateComments}
        />
      ) : null}
    </>
  );
}

function AttentionDialogWithFocusReturn(props: ComponentProps<typeof AttentionDialog>) {
  const triggerRef = useRef(activeHTMLElement());

  return (
    <Suspense fallback={null}>
      <AttentionDialog
        {...props}
        onCloseAutoFocus={(event) => restoreCardDetailTriggerFocus(event, triggerRef.current)}
      />
    </Suspense>
  );
}

function CardDetailDialogWithFocusReturn(props: ComponentProps<typeof CardDetailDialog>) {
  const triggerRef = useRef(activeHTMLElement());

  return (
    <Suspense fallback={null}>
      <CardDetailDialog
        {...props}
        onCloseAutoFocus={(event) => restoreCardDetailTriggerFocus(event, triggerRef.current)}
      />
    </Suspense>
  );
}

function activeHTMLElement() {
  if (typeof document === "undefined") return null;
  return document.activeElement instanceof HTMLElement ? document.activeElement : null;
}

export function restoreCardDetailTriggerFocus(
  event: Pick<Event, "preventDefault">,
  trigger: Pick<HTMLElement, "focus" | "isConnected"> | null,
) {
  if (!trigger?.isConnected) return;
  event.preventDefault();
  trigger.focus();
}
