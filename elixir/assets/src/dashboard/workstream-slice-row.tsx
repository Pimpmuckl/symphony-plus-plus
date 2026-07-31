import type { ActiveBlockingEdge, GuidanceItem, WorkPackageCard, WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";
import { GitBranch } from "lucide-react";
import { operationalBadgeVariant, operationalLabel, operationalStatusIsRunning, sliceOperationalState } from "@/lib/operational-state";
import { uniqueNonEmpty } from "@/lib/collections";
import { updateMotionAttributes } from "@/components/dashboard/motion-utils";
import type { CardDetailSelect, DashboardUpdateAnimations } from "./runtime";
import { contextPathValue, type ContextPathPart } from "./workstream-context-path";
import { repoDisplayName, repoIdentityKey } from "./dashboard-persistence";
import { workPackageDirectAttention, type AttentionSelect, type DirectAttention } from "./workstream-attention";
import { RowBadgeSlot } from "./workstream-row-ui";
import { sliceUpdateKey } from "./update-animations";
import { PullRequestBadge } from "./execution-graph/pull-request-badge";

export function DirectSliceGroup({ detail, sliceIds, slicesById, packageById, activeBlockingEdges, guidanceItems, onSelectAttention, onSelectCard, requestPath, updateAnimations }: {
  detail: WorkRequestDetail;
  sliceIds: string[];
  slicesById: Map<string, WorkRequestPackage>;
  packageById: Map<string, WorkPackageCard>;
  activeBlockingEdges: ActiveBlockingEdge[];
  guidanceItems: GuidanceItem[];
  onSelectAttention: AttentionSelect;
  onSelectCard: CardDetailSelect;
  requestPath: ContextPathPart[];
  updateAnimations: DashboardUpdateAnimations;
}) {
  const directSlices = sliceIds.map((sliceId) => slicesById.get(sliceId)).filter((slice): slice is WorkRequestPackage => Boolean(slice));
  if (directSlices.length === 0) return null;

  return (
    <div className="v3-direct-slices" data-v3-context-path={contextPathValue(requestPath)}>
      {directSlices.map((slice) => (
        <ProductSliceRow key={slice.id} detail={detail} slice={slice} pkg={packageById.get(slice.work_package_id || "")} activeBlockingEdges={activeBlockingEdges} guidanceItems={guidanceItems} onSelectAttention={onSelectAttention} onSelectCard={onSelectCard} updateAnimations={updateAnimations} />
      ))}
    </div>
  );
}

export function ProductSliceRow({ detail, slice, pkg, activeBlockingEdges, guidanceItems, onSelectAttention, onSelectCard, updateAnimations }: {
  detail: WorkRequestDetail;
  slice: WorkRequestPackage;
  pkg?: WorkPackageCard;
  activeBlockingEdges: ActiveBlockingEdge[];
  guidanceItems: GuidanceItem[];
  onSelectAttention: AttentionSelect;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const operational = sliceOperationalState(slice, pkg);
  const rawStatus = slice.work_package_status || slice.status || pkg?.status;
  const label = operationalLabel(operational, rawStatus) || "Unknown";
  const title = slice.title || pkg?.title || slice.id;
  const attention = workPackageDirectAttention(detail, slice, pkg, activeBlockingEdges, guidanceItems);
  const targetContext = sliceTargetContext(detail, slice, pkg);

  return (
    <div className="v3-slice-row v3-entity-row stagger-item" data-tone={attention?.tone} data-work-package-id={slice.id} {...updateMotionAttributes(updateAnimations.motionFor(sliceUpdateKey(slice)))}>
      <button type="button" className="v3-slice-main-button" aria-label={`Open WorkPackage details for ${title}`} onClick={() => onSelectCard({ kind: "slice", detail, slice, pkg })}>
        {targetContext ? (
          <span className="v3-request-title-group">
            <span className="v3-request-title">{title}</span>
            <span className="v3-request-meta"><GitBranch className="size-3.5" /><span>{targetContext.repo}</span><span>{targetContext.branch}</span></span>
          </span>
        ) : <span>{title}</span>}
      </button>
      {slice.pr_signal ? <span className="v3-slice-pr"><PullRequestBadge signal={slice.pr_signal} /></span> : null}
      <SliceAttentionBadge attention={attention} fallback={label} label={title} onSelect={onSelectAttention} active={operationalStatusIsRunning(operational, rawStatus)} variant={operationalBadgeVariant(operational, rawStatus)} />
    </div>
  );
}

function SliceAttentionBadge({ active, attention, fallback, label, onSelect, variant }: {
  active: boolean;
  attention: DirectAttention | null;
  fallback: string;
  label: string;
  onSelect: AttentionSelect;
  variant: Parameters<typeof RowBadgeSlot>[0]["variant"];
}) {
  return <RowBadgeSlot active={active} actionLabel={attention ? `Open attention details for ${label}` : undefined} label={attention?.label || fallback} onClick={attention ? () => onSelect(attention.target) : undefined} variant={attention?.tone === "blocked" ? "danger" : attention ? "guidance" : variant} />;
}

function sliceTargetContext(detail: WorkRequestDetail, slice: WorkRequestPackage, pkg?: WorkPackageCard) {
  const request = detail.work_request;
  const packageRepoRecorded = pkg ? uniqueNonEmpty([pkg.repo_key, pkg.repo, pkg.repo_display]).length > 0 : false;
  const repoDiffers = packageRepoRecorded ? repoIdentityKey(pkg) !== repoIdentityKey(request) : false;
  const requestBranch = uniqueNonEmpty([request.base_branch])[0] ?? "main";
  const targetBranch = uniqueNonEmpty([slice.base_branch, pkg?.base_branch, requestBranch])[0] ?? requestBranch;
  if (!repoDiffers && targetBranch === requestBranch) return null;
  return { repo: repoDiffers ? repoDisplayName(pkg) : repoDisplayName(request), branch: targetBranch };
}
