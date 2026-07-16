import type { ActiveBlockingEdge, GuidanceItem, PlannedSlice, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import { AlertTriangle, GitBranch, MessageSquareText } from "lucide-react";

import { operationalBadgeVariant, operationalLabel, operationalStatusIsRunning, sliceCardTone, sliceLane, sliceOperationalState } from "@/lib/operational-state";
import { uniqueNonEmpty } from "@/lib/collections";
import { updateMotionAttributes } from "@/components/dashboard/motion-utils";
import type { CardDetailSelect, DashboardUpdateAnimations } from "./runtime";
import { openBlockersForSlices, openGuidanceForSlice } from "./workstream-board-actions";
import { sliceProgressPercent } from "./workstream-progress";
import { rowProgressAttentionState, rowProgressIconState, sliceBlockerCount, sliceGuidanceCount } from "./workstream-row-state";
import { EntityCountChips, ProgressStateIcon, RowBadgeSlot, SliceKindSlot } from "./workstream-row-ui";
import { sliceUpdateKey } from "./update-animations";
import { contextPathValue } from "./workstream-context-path";
import type { ContextPathPart } from "./workstream-context-path";
import { repoDisplayName, repoIdentityKey } from "./dashboard-persistence";

export function DirectSliceGroup({
  detail,
  sliceIds,
  slicesById,
  packageById,
  activeBlockerCountBySliceId,
  activeBlockingEdges,
  guidanceItems,
  onSelectGuidance,
  onSelectCard,
  requestPath,
  updateAnimations,
}: {
  detail: WorkRequestDetail;
  sliceIds: string[];
  slicesById: Map<string, PlannedSlice>;
  packageById: Map<string, WorkPackageCard>;
  activeBlockerCountBySliceId: Map<string, number>;
  activeBlockingEdges: ActiveBlockingEdge[];
  guidanceItems: GuidanceItem[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  requestPath: ContextPathPart[];
  updateAnimations: DashboardUpdateAnimations;
}) {
  const directSlices = sliceIds.map((sliceId) => slicesById.get(sliceId)).filter((slice): slice is PlannedSlice => Boolean(slice));
  if (directSlices.length === 0) return null;

  return (
    <div className="v3-direct-slices" data-v3-context-path={contextPathValue(requestPath)}>
      {directSlices.map((slice) => (
        <ProductSliceRow
          key={slice.id}
          detail={detail}
          slice={slice}
          pkg={packageById.get(slice.work_package_id || "")}
          activeBlockerCountBySliceId={activeBlockerCountBySliceId}
          activeBlockingEdges={activeBlockingEdges}
          guidanceItems={guidanceItems}
          onSelectGuidance={onSelectGuidance}
          onSelectCard={onSelectCard}
          updateAnimations={updateAnimations}
        />
      ))}
    </div>
  );
}

export function ProductSliceRow({
  detail,
  slice,
  pkg,
  activeBlockerCountBySliceId,
  activeBlockingEdges,
  guidanceItems,
  onSelectGuidance,
  onSelectCard,
  updateAnimations,
}: {
  detail: WorkRequestDetail;
  slice: PlannedSlice;
  pkg?: WorkPackageCard;
  activeBlockerCountBySliceId: Map<string, number>;
  activeBlockingEdges: ActiveBlockingEdge[];
  guidanceItems: GuidanceItem[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const operational = sliceOperationalState(slice, pkg);
  const rawStatus = slice.work_package_status || slice.status;
  const lane = sliceLane(slice, pkg);
  const tone = sliceCardTone(slice, pkg, lane);
  const blockerCount = sliceBlockerCount(slice, pkg, activeBlockerCountBySliceId);
  const guidanceCount = sliceGuidanceCount(slice, pkg);
  const sliceLabel = operationalLabel(operational, rawStatus);
  const statusActive = operationalStatusIsRunning(operational, rawStatus);
  const progress = sliceProgressPercent(slice, pkg);
  const progressIconState = rowProgressIconState({ blockerCount, guidanceCount, progress, tone });
  const progressAttentionState = rowProgressAttentionState({ blockerCount, guidanceCount, tone });
  const packageById = pkg ? new Map<string, WorkPackageCard>([[pkg.id, pkg]]) : new Map<string, WorkPackageCard>();
  const openSliceDetail = () => onSelectCard({ kind: "slice", detail, slice, pkg });
  const openGuidance = () => openGuidanceForSlice(detail, slice, pkg, guidanceItems, onSelectGuidance, onSelectCard);
  const openBlockers = () => openBlockersForSlices(detail, [slice], packageById, activeBlockerCountBySliceId, activeBlockingEdges, onSelectCard);
  const targetContext = sliceTargetContext(detail, slice, pkg);

  return (
    <div
      className="v3-slice-row v3-entity-row stagger-item"
      data-tone={tone}
      {...updateMotionAttributes(updateAnimations.motionFor(sliceUpdateKey(slice)))}
    >
      <ProgressStateIcon state={progressIconState} attentionState={progressAttentionState} progress={progress} label={sliceLabel} />
      <button type="button" className="v3-slice-main-button" onClick={openSliceDetail}>
        {targetContext ? (
          <span className="v3-request-title-group">
            <span className="v3-request-title">{slice.title || slice.id}</span>
            <span className="v3-request-meta">
              <GitBranch className="size-3.5" />
              <span>{targetContext.repo}</span>
              <span>{targetContext.branch}</span>
            </span>
          </span>
        ) : <span>{slice.title || slice.id}</span>}
      </button>
      <EntityCountChips
        reserveEmpty
        items={[
          { key: "guidance", icon: <MessageSquareText className="size-3.5" />, count: guidanceCount, label: "guidance needed", onClick: guidanceCount > 0 ? openGuidance : undefined, tone: "guidance" },
          { key: "blockers", icon: <AlertTriangle className="size-3.5" />, count: blockerCount, label: "active blockers", onClick: blockerCount > 0 ? openBlockers : undefined, tone: "blocker" },
        ]}
      />
      <span className="v3-row-status v3-slice-status">
        <RowBadgeSlot active={statusActive} label={sliceLabel} variant={operationalBadgeVariant(operational, rawStatus)} />
      </span>
      <SliceKindSlot detail={detail} slice={slice} pkg={pkg} onSelectCard={onSelectCard} />
    </div>
  );
}

function sliceTargetContext(detail: WorkRequestDetail, slice: PlannedSlice, pkg?: WorkPackageCard) {
  const request = detail.work_request;
  const packageRepoRecorded = pkg ? uniqueNonEmpty([pkg.repo_key, pkg.repo, pkg.repo_display]).length > 0 : false;
  const repoDiffers = packageRepoRecorded ? repoIdentityKey(pkg) !== repoIdentityKey(request) : false;
  const requestBranch = uniqueNonEmpty([request.base_branch])[0] ?? "main";
  const targetBranch = uniqueNonEmpty([slice.target_base_branch, pkg?.base_branch, requestBranch])[0] ?? requestBranch;

  if (!repoDiffers && targetBranch === requestBranch) return null;
  return { repo: repoDiffers ? repoDisplayName(pkg) : repoDisplayName(request), branch: targetBranch };
}
