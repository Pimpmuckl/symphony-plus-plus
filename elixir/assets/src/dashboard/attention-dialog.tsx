import { ArrowLeft, Loader2 } from "lucide-react";
import { useState } from "react";
import type { ComponentProps } from "react";

import { GuidanceDialogBody } from "@/components/dashboard/guidance-dialog";
import { DetailHeader, DetailSection } from "@/components/dashboard/detail-layout";
import { MarkdownBlock } from "@/components/dashboard/markdown-block";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import type { GuidanceAnswerSubmission, GuidanceItem, WorkRequestDetail } from "@/types/dashboard";
import { AttentionLocationBar } from "./attention-location";
import { AttentionPreviewCard } from "./attention-preview-card";
import { BlockerDetailContent } from "./package-detail";
import type { WorkPackageBlockerClearMutation, WorkPackageStateMutation, WorkRequestStateMutation } from "./runtime";
import {
  attentionItemTitle,
  attentionLocationForItem,
  type AttentionItem,
  type AttentionJumpDestination,
  type AttentionTarget,
} from "./workstream-attention";

export function AttentionDialog({
  canMutateOperatorActions,
  onChangeWorkPackageState,
  onChangeWorkRequestState,
  onClearWorkPackageBlocker,
  onCloseAutoFocus,
  onJumpToAttention,
  onOpenChange,
  onSubmitGuidanceAnswer,
  requestDetails,
  target,
}: {
  canMutateOperatorActions: boolean;
  onChangeWorkPackageState: WorkPackageStateMutation;
  onChangeWorkRequestState: WorkRequestStateMutation;
  onClearWorkPackageBlocker: WorkPackageBlockerClearMutation;
  onCloseAutoFocus?: ComponentProps<typeof DialogContent>["onCloseAutoFocus"];
  onJumpToAttention: (destination: AttentionJumpDestination) => void;
  onOpenChange: (open: boolean) => void;
  onSubmitGuidanceAnswer: (item: GuidanceItem, submission: GuidanceAnswerSubmission) => Promise<void>;
  requestDetails: WorkRequestDetail[];
  target: AttentionTarget | null;
}) {
  return (
    <Dialog open={Boolean(target)} onOpenChange={onOpenChange}>
      <DialogContent className="attention-dialog dashboard-dialog-content" onCloseAutoFocus={onCloseAutoFocus}>
        {target ? (
          <AttentionDialogBody
            key={target.items.map((item) => item.key).join("|")}
            canMutateOperatorActions={canMutateOperatorActions}
            onChangeWorkPackageState={onChangeWorkPackageState}
            onChangeWorkRequestState={onChangeWorkRequestState}
            onClearWorkPackageBlocker={onClearWorkPackageBlocker}
            onJumpToAttention={onJumpToAttention}
            onOpenChange={onOpenChange}
            onSubmitGuidanceAnswer={onSubmitGuidanceAnswer}
            requestDetails={requestDetails}
            target={target}
          />
        ) : null}
      </DialogContent>
    </Dialog>
  );
}

function AttentionDialogBody({
  canMutateOperatorActions,
  onChangeWorkPackageState,
  onChangeWorkRequestState,
  onClearWorkPackageBlocker,
  onJumpToAttention,
  onOpenChange,
  onSubmitGuidanceAnswer,
  requestDetails,
  target,
}: {
  canMutateOperatorActions: boolean;
  onChangeWorkPackageState: WorkPackageStateMutation;
  onChangeWorkRequestState: WorkRequestStateMutation;
  onClearWorkPackageBlocker: WorkPackageBlockerClearMutation;
  onJumpToAttention: (destination: AttentionJumpDestination) => void;
  onOpenChange: (open: boolean) => void;
  onSubmitGuidanceAnswer: (item: GuidanceItem, submission: GuidanceAnswerSubmission) => Promise<void>;
  requestDetails: WorkRequestDetail[];
  target: AttentionTarget;
}) {
  const [selectedKey, setSelectedKey] = useState(target.items.length === 1 ? target.items[0]?.key ?? null : null);
  const selected = target.items.find((item) => item.key === selectedKey);

  if (!selected) {
    return (
      <>
        <DialogHeader>
          <DialogTitle>{target.items.length} attention items</DialogTitle>
          <DialogDescription>Choose the blocker or human input that you want to handle.</DialogDescription>
        </DialogHeader>
        <div className="grid gap-3">
          {target.items.map((item, index) => (
            <AttentionPreviewCard
              key={item.key}
              item={item}
              index={index}
              location={attentionLocationForItem(item, requestDetails)}
              onJump={onJumpToAttention}
              onSelect={() => setSelectedKey(item.key)}
            />
          ))}
        </div>
      </>
    );
  }

  return (
    <>
      {target.items.length > 1 ? (
        <Button type="button" variant="ghost" size="sm" className="w-fit px-2" onClick={() => setSelectedKey(null)}>
          <ArrowLeft className="size-4" />
          All attention
        </Button>
      ) : null}
      <AttentionItemBody
        canMutateOperatorActions={canMutateOperatorActions}
        item={selected}
        onChangeWorkPackageState={onChangeWorkPackageState}
        onChangeWorkRequestState={onChangeWorkRequestState}
        onClearWorkPackageBlocker={onClearWorkPackageBlocker}
        onJumpToAttention={onJumpToAttention}
        onOpenChange={onOpenChange}
        onSubmitGuidanceAnswer={onSubmitGuidanceAnswer}
        requestDetails={requestDetails}
      />
    </>
  );
}

function AttentionItemBody({
  canMutateOperatorActions,
  item,
  onChangeWorkPackageState,
  onChangeWorkRequestState,
  onClearWorkPackageBlocker,
  onJumpToAttention,
  onOpenChange,
  onSubmitGuidanceAnswer,
  requestDetails,
}: {
  canMutateOperatorActions: boolean;
  item: AttentionItem;
  onChangeWorkPackageState: WorkPackageStateMutation;
  onChangeWorkRequestState: WorkRequestStateMutation;
  onClearWorkPackageBlocker: WorkPackageBlockerClearMutation;
  onJumpToAttention: (destination: AttentionJumpDestination) => void;
  onOpenChange: (open: boolean) => void;
  onSubmitGuidanceAnswer: (item: GuidanceItem, submission: GuidanceAnswerSubmission) => Promise<void>;
  requestDetails: WorkRequestDetail[];
}) {
  const location = attentionLocationForItem(item, requestDetails);

  if (item.kind === "guidance") {
    return (
      <GuidanceDialogBody
        canSubmitAnswer={canMutateOperatorActions}
        item={item.item}
        location={location}
        onJumpToAttention={onJumpToAttention}
        onOpenChange={onOpenChange}
        onSubmitAnswer={onSubmitGuidanceAnswer}
      />
    );
  }

  if (item.kind === "blocker") {
    return (
      <BlockerDetailContent
        selection={item.selection}
        detailPayload={null}
        loading={false}
        error={null}
        location={location}
        onJumpToAttention={onJumpToAttention}
        onClearWorkPackageBlocker={onClearWorkPackageBlocker}
        canMutateOperatorActions={canMutateOperatorActions}
      />
    );
  }

  return (
    <StatusAttentionBody
      canMutateOperatorActions={canMutateOperatorActions}
      item={item}
      location={location}
      onChangeWorkPackageState={onChangeWorkPackageState}
      onChangeWorkRequestState={onChangeWorkRequestState}
      onJumpToAttention={onJumpToAttention}
    />
  );
}

function StatusAttentionBody({
  canMutateOperatorActions,
  item,
  location,
  onChangeWorkPackageState,
  onChangeWorkRequestState,
  onJumpToAttention,
}: {
  canMutateOperatorActions: boolean;
  item: Extract<AttentionItem, { kind: "status" }>;
  location: ReturnType<typeof attentionLocationForItem>;
  onChangeWorkPackageState: WorkPackageStateMutation;
  onChangeWorkRequestState: WorkRequestStateMutation;
  onJumpToAttention: (destination: AttentionJumpDestination) => void;
}) {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const workPackageId = blockedPackageId(item);
  const workRequestId = humanInfoWorkRequestId(item);
  const clear = async () => {
    if ((!workPackageId && !workRequestId) || pending) return;
    setPending(true);
    setError(null);
    try {
      if (workPackageId) await onChangeWorkPackageState(workPackageId, "unblock");
      else if (workRequestId) await onChangeWorkRequestState(workRequestId, "ready_for_slicing");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Attention state was not cleared");
      setPending(false);
    }
  };

  return (
    <>
      <DetailHeader
        title={item.label}
        eyebrow={`${location.repo} / attention`}
        badge={<Badge variant={item.tone === "blocked" ? "danger" : "guidance"}>{item.label}</Badge>}
      />
      <AttentionLocationBar location={location} onJump={onJumpToAttention} />
      <div className="detail-modal-reveal-body grid gap-4">
        <DetailSection title={attentionItemTitle(item)}>
          <MarkdownBlock value={item.detail} />
        </DetailSection>
        <p className="text-sm text-muted-foreground">
          {workPackageId
            ? "This package is blocked without a separate blocker record."
            : workRequestId
              ? "No question is attached. Clear this attention state to continue."
            : item.tone === "blocked"
              ? "No separate blocker record is attached, so there is nothing to clear from this view."
            : "No question is attached yet, so there is nothing to answer from this view."}
        </p>
        {(workPackageId || workRequestId) && canMutateOperatorActions ? (
          <Button type="button" variant="destructive" className="w-fit" disabled={pending} onClick={() => void clear()}>
            {pending ? <Loader2 className="size-4 animate-spin" /> : null}
            Clear
          </Button>
        ) : null}
        {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
      </div>
    </>
  );
}

function blockedPackageId(item: Extract<AttentionItem, { kind: "status" }>) {
  if (item.tone !== "blocked") return null;
  const selection = item.selection;
  if (selection.kind === "package") return selection.pkg.status === "blocked" ? selection.pkg.id : null;
  if (selection.kind !== "slice") return null;
  const rawStatuses = [selection.pkg?.status, selection.slice.work_package_status, selection.slice.status];
  return rawStatuses.includes("blocked")
    ? selection.pkg?.id || selection.slice.work_package_id || selection.slice.id
    : null;
}

function humanInfoWorkRequestId(item: Extract<AttentionItem, { kind: "status" }>) {
  if (item.tone !== "guidance" || item.selection.kind !== "request") return null;
  const request = item.selection.detail.work_request;
  return (request.operational_state?.key || request.status) === "human_info_needed" ? request.id : null;
}
