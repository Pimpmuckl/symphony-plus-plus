import { lazy, Suspense } from "react";

import type { CopyArchitectHandoff, GuidanceAnswerSubmission, GuidanceItem } from "@/types/dashboard";
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

const GuidanceDialog = lazy(() => import("@/components/dashboard/guidance-dialog").then((module) => ({ default: module.GuidanceDialog })));
const CardDetailDialog = lazy(() => import("./card-detail-dialog").then((module) => ({ default: module.CardDetailDialog })));

export function DashboardDeferredDialogs({
  canMutateComments,
  canMutateOperatorActions,
  changeWorkPackageState,
  changeWorkRequestState,
  copyArchitectHandoff,
  dialogState,
  linkedWorkPackageIds,
  onArchiveWorkPackage,
  onArchiveWorkRequest,
  onClearWorkPackageBlocker,
  onDeleteWorkRequest,
  onResolveComment,
  onSelectCard,
  onSelectGuidance,
  onSubmitComment,
  onSubmitGuidanceAnswer,
}: {
  canMutateComments: boolean;
  canMutateOperatorActions: boolean;
  changeWorkPackageState: WorkPackageStateMutation;
  changeWorkRequestState: WorkRequestStateMutation;
  copyArchitectHandoff: CopyArchitectHandoff;
  dialogState: AppDialogState;
  linkedWorkPackageIds: Set<string>;
  onArchiveWorkPackage: WorkPackageArchiveMutation;
  onArchiveWorkRequest: WorkRequestMutation;
  onClearWorkPackageBlocker: WorkPackageBlockerClearMutation;
  onDeleteWorkRequest: WorkRequestMutation;
  onResolveComment: ResolveContextComment;
  onSelectCard: (selection: CardDetailSelection | null) => void;
  onSelectGuidance: (item: GuidanceItem | null) => void;
  onSubmitComment: SubmitContextComment;
  onSubmitGuidanceAnswer: (item: GuidanceItem, submission: GuidanceAnswerSubmission) => Promise<void>;
}) {
  return (
    <>
      {dialogState.selectedGuidance ? (
        <Suspense fallback={null}>
          <GuidanceDialog
            canSubmitAnswer={canMutateOperatorActions}
            item={dialogState.selectedGuidance}
            onOpenChange={(open) => {
              if (!open) onSelectGuidance(null);
            }}
            onSubmitAnswer={onSubmitGuidanceAnswer}
          />
        </Suspense>
      ) : null}
      {dialogState.selectedCardDetail ? (
        <Suspense fallback={null}>
          <CardDetailDialog
            selection={dialogState.selectedCardDetail}
            onOpenChange={(open) => {
              if (!open) onSelectCard(null);
            }}
            onSelectGuidance={onSelectGuidance}
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
        </Suspense>
      ) : null}
    </>
  );
}
