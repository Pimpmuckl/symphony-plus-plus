import { Archive, CheckCircle2, Loader2 } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { DetailCopyButton } from "@/components/dashboard/detail-copy-button";
import { DetailDisclosure, DetailFacts, DetailHeader, DetailList, DetailSection, DetailStatGrid } from "@/components/dashboard/detail-layout";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { MarkdownBlock } from "@/components/dashboard/markdown-block";
import type { ContextComment, PackageOperationalAttention, WorkPackageCard, WorkPackageDetailPayload } from "@/types/dashboard";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { operationalBadgeVariant, operationalLabel } from "@/lib/operational-state";
import { packageReviewLabel } from "@/lib/review-signals";
import { statusLabel } from "@/lib/status-labels";
import type { Dispatch, SetStateAction } from "react";
import { COMMENT_BODY_MAX_LENGTH } from "./runtime";
import type { CardDetailSelection, PackageDetailUiAction, PackageDetailUiState, ResolveContextComment, SubmitContextComment, WorkPackageStateAction } from "./runtime";
import { CommentsPanel } from "./comments-panel";
import { DangerousStateConfirmationDialog } from "./request-detail";
import { DetailActivityList, DetailAttentionList, LineageDisclosure, RecentDecisionsDisclosure } from "./detail-extras";
import { activeAlertLabels, commentStatLabel, detailDate, latestPackageProgress, lineageHasSignal, packageOperationalFallbackText, packageRuntimeText, targetCommentStats } from "./detail-utils";
import { repoDisplayName } from "./dashboard-persistence";

export type PackageBlocker = NonNullable<WorkPackageDetailPayload["blockers"]>[number];
export type PackageDetailPackage = WorkPackageCard & {
  branch_pattern?: string | null;
  product_description?: string | null;
  engineering_scope?: string | null;
  acceptance_criteria?: string[];
  policy_template?: string | null;
};
export type PackageDetailComments = {
  canMutate: boolean;
  comments: ContextComment[];
  onCommentsChange: Dispatch<SetStateAction<ContextComment[]>>;
  onResolveComment: ResolveContextComment;
  onSubmitComment: SubmitContextComment;
};
export type PackageDetailControls = {
  actions: Array<{ value: WorkPackageStateAction; label: string }>;
  archiveError: string | null;
  archivePending: boolean;
  canArchiveUnlinked: boolean;
  onArchiveRequest: () => void;
  onSelectStateAction: (action: string) => void;
  stateError: string | null;
  statePending: boolean;
};
export type PackageDetailStatus = {
  error: string | null;
  loading: boolean;
};
export type PackageDetailDialogControls = {
  archivePackage: () => Promise<void>;
  changePackageState: (action: WorkPackageStateAction, options?: { noPrEvidence?: string }) => Promise<void>;
  dispatchUiState: Dispatch<PackageDetailUiAction>;
  setArchiveConfirmOpen: (open: boolean) => void;
  setEvidenceDialogOpen: (open: boolean) => void;
  setNoPrEvidence: (value: string) => void;
  setStateConfirmOpen: (open: boolean) => void;
};

export function PackageDetailBody({
  attentionItems,
  blockerCopyText,
  blockerCount,
  blockers,
  comments,
  controls,
  currentCommentStats,
  detailPayload,
  lineage,
  operational,
  pkg,
  planLabel,
  progress,
  purposeMarkdown,
  selection,
  status,
  summary,
}: {
  attentionItems: PackageOperationalAttention[];
  blockerCopyText: string;
  blockerCount: number;
  blockers: PackageBlocker[];
  comments: PackageDetailComments;
  controls: PackageDetailControls;
  currentCommentStats: ReturnType<typeof targetCommentStats>;
  detailPayload: WorkPackageDetailPayload | null;
  lineage: WorkPackageCard["lineage"] | WorkPackageDetailPayload["lineage"] | null;
  operational: WorkPackageCard["operational_state"] | null;
  pkg: PackageDetailPackage;
  planLabel: string;
  progress: ReturnType<typeof latestPackageProgress>;
  purposeMarkdown: string;
  selection: Extract<CardDetailSelection, { kind: "package" }>;
  status: PackageDetailStatus;
  summary: WorkPackageDetailPayload["summary"] | undefined;
}) {
  return (
    <>
      <PackageDetailHeader pkg={pkg} operational={operational} blockerCopyText={blockerCopyText} />
      <div className="detail-modal-reveal-body grid gap-4">
        <DetailStatGrid stats={packageDetailStats({ blockerCount, currentCommentStats, operational, pkg, planLabel, summary })} />
        <PackageExecutionScopeSection pkg={pkg} purposeMarkdown={purposeMarkdown} />
        <PackageOperationalTruthSection attentionItems={attentionItems} operational={operational} pkg={pkg} />
        <PackageProgressSection progress={progress} planLabel={planLabel} status={status} />
        <PackageBlockersSection blockerCount={blockerCount} blockers={blockers} error={status.error} />
        <PackageCommentsDisclosure comments={comments} currentCommentStats={currentCommentStats} packageId={pkg.id} />
        <PackageRelatedDisclosures lineage={lineage} selection={selection} />
        <PackageRawDetails detailPayload={detailPayload} operational={operational} pkg={pkg} selection={selection} summary={summary} />
        <PackageStateControls controls={controls} />
      </div>
    </>
  );
}

function PackageDetailHeader({
  blockerCopyText,
  operational,
  pkg,
}: {
  blockerCopyText: string;
  operational: WorkPackageCard["operational_state"] | null;
  pkg: PackageDetailPackage;
}) {
  return (
    <DetailHeader
      title={pkg.title || pkg.id}
      eyebrow={`${repoDisplayName(pkg)} / ${pkg.base_branch || "main"} / ${pkg.kind || "work package"}`}
      badge={<Badge variant={operationalBadgeVariant(operational, pkg.status)}>{operationalLabel(operational, pkg.status)}</Badge>}
      action={blockerCopyText ? <DetailCopyButton label="Copy blocker details" text={blockerCopyText} /> : null}
    />
  );
}

function PackageExecutionScopeSection({ pkg, purposeMarkdown }: { pkg: PackageDetailPackage; purposeMarkdown: string }) {
  return (
    <DetailSection title="Execution Scope">
      <MarkdownBlock value={purposeMarkdown} empty={pkg.kind || "No execution scope has been recorded yet."} />
    </DetailSection>
  );
}

function PackageOperationalTruthSection({
  attentionItems,
  operational,
  pkg,
}: {
  attentionItems: PackageOperationalAttention[];
  operational: WorkPackageCard["operational_state"] | null;
  pkg: PackageDetailPackage;
}) {
  return (
    <DetailSection title="Operational Truth">
      <div className="grid gap-2">
        <p>{operational?.reason || packageOperationalFallbackText(pkg)}</p>
        {attentionItems.length > 0 ? <DetailAttentionList items={attentionItems} /> : null}
      </div>
    </DetailSection>
  );
}

function PackageCommentsDisclosure({
  comments,
  currentCommentStats,
  packageId,
}: {
  comments: PackageDetailComments;
  currentCommentStats: ReturnType<typeof targetCommentStats>;
  packageId: string;
}) {
  return (
    <DetailDisclosure title="Comments" meta={commentStatLabel(currentCommentStats.open_comment_count, currentCommentStats.comment_count)}>
      <CommentsPanel
        key={`work_package:${packageId}`}
        target={{ target_kind: "work_package", target_id: packageId }}
        comments={comments.comments}
        onCommentsChange={comments.onCommentsChange}
        onSubmitComment={comments.onSubmitComment}
        onResolveComment={comments.onResolveComment}
        canMutate={comments.canMutate}
      />
    </DetailDisclosure>
  );
}

function PackageRelatedDisclosures({
  lineage,
  selection,
}: {
  lineage: WorkPackageCard["lineage"] | WorkPackageDetailPayload["lineage"] | null;
  selection: Extract<CardDetailSelection, { kind: "package" }>;
}) {
  return (
    <>
      {selection.detail ? <RecentDecisionsDisclosure detail={selection.detail} /> : null}
      {lineageHasSignal(lineage) ? <LineageDisclosure lineage={lineage} /> : null}
    </>
  );
}

function PackageRawDetails({
  detailPayload,
  operational,
  pkg,
  selection,
  summary,
}: {
  detailPayload: WorkPackageDetailPayload | null;
  operational: WorkPackageCard["operational_state"] | null;
  pkg: PackageDetailPackage;
  selection: Extract<CardDetailSelection, { kind: "package" }>;
  summary: WorkPackageDetailPayload["summary"] | undefined;
}) {
  return (
    <DetailDisclosure title="Details" meta="PR, review, artifacts, and raw identifiers">
      <DetailFacts facts={packageDetailFacts({ operational, pkg, selection, summary })} />
      <DetailList title="Acceptance" items={pkg.acceptance_criteria || selection.slice?.acceptance_criteria || []} empty="No acceptance criteria recorded." />
      <DetailList title="Alerts" items={activeAlertLabels(detailPayload?.alert_indicators || pkg.alert_indicators || [])} empty="No active alerts." />
    </DetailDisclosure>
  );
}

function packageDetailStats({
  blockerCount,
  currentCommentStats,
  operational,
  pkg,
  planLabel,
  summary,
}: {
  blockerCount: number;
  currentCommentStats: ReturnType<typeof targetCommentStats>;
  operational: WorkPackageCard["operational_state"] | null;
  pkg: PackageDetailPackage;
  planLabel: string;
  summary: WorkPackageDetailPayload["summary"] | undefined;
}) {
  return [
    { label: "State", value: operationalLabel(operational, pkg.status) },
    { label: "Plan", value: planLabel },
    { label: "Runtime", value: packageRuntimeText(summary, pkg) },
    { label: "Blockers", value: String(blockerCount) },
    { label: "Comments", value: commentStatLabel(currentCommentStats.open_comment_count, currentCommentStats.comment_count) },
    { label: "Updated", value: detailDate(summary?.latest_progress_at || pkg.latest_progress_at || pkg.updated_at || pkg.inserted_at) },
  ];
}

function packageDetailFacts({
  operational,
  pkg,
  selection,
  summary,
}: {
  operational: WorkPackageCard["operational_state"] | null;
  pkg: PackageDetailPackage;
  selection: Extract<CardDetailSelection, { kind: "package" }>;
  summary: WorkPackageDetailPayload["summary"] | undefined;
}): Array<[string, string | null | undefined]> {
  return [
    ["Package ID", pkg.id],
    ["Parent", packageParentLabel(pkg, selection)],
    ["Raw Status", statusLabel(packageRawStatus(pkg, operational))],
    ["Policy", packagePolicyLabel(pkg)],
    ["Branch", packageBranchLabel(pkg)],
    ["PR", packagePrLabel(pkg)],
    ["Review", packageReviewStatusLabel(pkg)],
    ["Artifacts", String(packageArtifactCount(pkg, summary))],
    ["Findings", String(packageFindingCount(pkg, summary))],
  ];
}

function packageParentLabel(pkg: PackageDetailPackage, selection: Extract<CardDetailSelection, { kind: "package" }>) {
  return pkg.parent_id || selection.slice?.work_request_id || "Not linked";
}

function packageRawStatus(pkg: PackageDetailPackage, operational: WorkPackageCard["operational_state"] | null) {
  return operational?.raw_status || pkg.status;
}

function packagePolicyLabel(pkg: PackageDetailPackage) {
  return pkg.policy_template || pkg.kind || "Not recorded";
}

function packageBranchLabel(pkg: PackageDetailPackage) {
  return pkg.metadata?.branch?.branch || pkg.branch_pattern || "Not recorded";
}

function packagePrLabel(pkg: PackageDetailPackage) {
  if (pkg.metadata?.pr?.number) return `PR #${pkg.metadata.pr.number}`;
  return pkg.metadata?.pr?.url ? "PR attached" : "Not attached";
}

function packageReviewStatusLabel(pkg: PackageDetailPackage) {
  return packageReviewLabel(pkg) || (pkg.status === "reviewing" ? "Reviewing" : "Not recorded");
}

function packageArtifactCount(pkg: PackageDetailPackage, summary: WorkPackageDetailPayload["summary"] | undefined) {
  return summary?.artifact_count ?? pkg.artifact_count ?? 0;
}

function packageFindingCount(pkg: PackageDetailPackage, summary: WorkPackageDetailPayload["summary"] | undefined) {
  return summary?.finding_count ?? pkg.finding_count ?? 0;
}

function PackageProgressSection({
  progress,
  planLabel,
  status,
}: {
  progress: ReturnType<typeof latestPackageProgress>;
  planLabel: string;
  status: PackageDetailStatus;
}) {
  return (
    <DetailSection title="Progress">
      {status.loading ? (
        <p>Loading latest package activity&hellip;</p>
      ) : progress.length > 0 ? (
        <DetailActivityList items={progress.map((item) => ({ title: item.summary || item.status || "Progress", body: item.body, at: item.created_at }))} />
      ) : (
        <p>{planLabel === "No plan" ? "No package progress recorded yet." : `Plan is ${planLabel.toLowerCase()}.`}</p>
      )}
    </DetailSection>
  );
}

function PackageBlockersSection({
  blockerCount,
  blockers,
  error,
}: {
  blockerCount: number;
  blockers: PackageBlocker[];
  error: string | null;
}) {
  const visibleBlockers: Array<Pick<PackageBlocker, "body" | "resolution" | "status" | "summary" | "updated_at">> =
    blockers.length > 0 ? blockers : [{ summary: "Package is blocked", body: "No blocker detail was included in the board summary." }];

  return (
    <DetailSection title="Blocked By">
      {error ? (
        <p>{error}</p>
      ) : blockerCount > 0 ? (
        <DetailActivityList
          items={visibleBlockers.map((blocker) => ({ title: blocker.summary || blocker.status || "Blocker", body: blocker.body || blocker.resolution, at: blocker.updated_at }))}
        />
      ) : (
        <p>No active blockers surfaced.</p>
      )}
    </DetailSection>
  );
}

function PackageStateControls({ controls }: { controls: PackageDetailControls }) {
  if (controls.actions.length === 0 && !controls.canArchiveUnlinked) return null;

  return (
    <div className="flex flex-col items-start gap-2 border-t border-destructive/20 pt-4">
      <div className="flex flex-wrap gap-2">
        {controls.actions.length > 0 ? (
          <Select value="" onValueChange={controls.onSelectStateAction} disabled={controls.statePending}>
            <SelectTrigger className="h-9 w-[190px] border-destructive/40 text-xs">
              <SelectValue placeholder="Change State" />
            </SelectTrigger>
            <SelectContent>
              {controls.actions.map((action) => (
                <SelectItem key={action.value} value={action.value}>
                  {action.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        ) : null}
        {controls.canArchiveUnlinked ? (
          <Button type="button" size="sm" variant="outline" onClick={controls.onArchiveRequest} disabled={controls.archivePending}>
            {controls.archivePending ? <Loader2 className="size-4 animate-spin" /> : <Archive className="size-4" />}
            Archive Record
          </Button>
        ) : null}
      </div>
      {controls.stateError ? <p className="text-xs text-destructive">{controls.stateError}</p> : null}
      {controls.archiveError ? <p className="text-xs text-destructive">{controls.archiveError}</p> : null}
    </div>
  );
}

export function PackageDetailDialogs({
  controls,
  uiState,
}: {
  controls: PackageDetailDialogControls;
  uiState: PackageDetailUiState;
}) {
  const { archiveConfirmOpen, archivePending, evidenceDialogOpen, noPrEvidence, pendingStateAction, stateConfirmOpen, stateError, statePending } = uiState;

  return (
    <>
      <DangerousStateConfirmationDialog
        open={stateConfirmOpen}
        onOpenChange={(open) => {
          controls.setStateConfirmOpen(open);
          if (!open) controls.dispatchUiState({ type: "pendingStateAction", action: null });
        }}
        title={pendingStateAction === "closed_and_archive" ? "Close and Archive Execution Record?" : "Mark Execution Merged?"}
        description={packageStateConfirmationDescription(pendingStateAction)}
        confirmLabel={packageStateConfirmationLabel(pendingStateAction)}
        pending={statePending}
        onConfirm={() => {
          if (pendingStateAction) void controls.changePackageState(pendingStateAction);
        }}
      />
      <Dialog open={evidenceDialogOpen} onOpenChange={controls.setEvidenceDialogOpen}>
        <DialogContent className="dashboard-dialog-content sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>Close With Evidence</DialogTitle>
            <DialogDescription>Record a completed-without-PR delivery for the WorkPackage.</DialogDescription>
          </DialogHeader>
          <div className="grid gap-3">
            <Textarea
              value={noPrEvidence}
              onChange={(event) => controls.setNoPrEvidence(event.target.value)}
              placeholder="Markdown evidence note..."
              disabled={statePending}
              maxLength={COMMENT_BODY_MAX_LENGTH}
            />
            {stateError ? <p className="text-xs text-destructive">{stateError}</p> : null}
            <div className="flex justify-end gap-2">
              <Button type="button" size="sm" variant="outline" onClick={() => controls.setEvidenceDialogOpen(false)} disabled={statePending}>
                Cancel
              </Button>
              <Button
                type="button"
                size="sm"
                variant="destructive"
                onClick={() => void controls.changePackageState("completed_no_pr", { noPrEvidence: noPrEvidence.trim() })}
                disabled={statePending || noPrEvidence.trim().length === 0}
              >
                {statePending ? <Loader2 className="size-4 animate-spin" /> : <CheckCircle2 className="size-4" />}
                Mark Completed Without PR
              </Button>
            </div>
          </div>
        </DialogContent>
      </Dialog>
      <DangerousStateConfirmationDialog
        open={archiveConfirmOpen}
        onOpenChange={controls.setArchiveConfirmOpen}
        title="Archive Unlinked Execution Record?"
        description="This hides the delivered unlinked execution record from the active execution view. The package record stays in the local ledger."
        confirmLabel="Archive Record"
        pending={archivePending}
        onConfirm={() => void controls.archivePackage()}
      />
    </>
  );
}

function packageStateConfirmationDescription(action: WorkPackageStateAction | null) {
  if (action === "merged_and_archive") {
    return "This marks the unlinked execution record Merged and hides it from the active execution view. The package record stays in the local ledger.";
  }

  if (action === "closed_and_archive") {
    return "This marks the unlinked execution record Closed and hides it from the active execution view. The package record stays in the local ledger.";
  }

  return "This manually marks the execution record Merged for the local dashboard. Use it only when the external merge or worker handoff was missed.";
}

function packageStateConfirmationLabel(action: WorkPackageStateAction | null) {
  if (action === "merged_and_archive") return "Merged + Archive";
  if (action === "closed_and_archive") return "Closed + Archive";
  return "Mark Merged";
}
