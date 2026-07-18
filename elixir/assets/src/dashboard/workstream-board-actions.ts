import type { ActiveBlockingEdge, GuidanceItem, WorkRequestPackage, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { CardDetailSelect } from "./runtime";
import { activePackageBlockers, packageBlockerEdge, pendingPackageBlockerEdge } from "./blocker-selection";
import { sliceBlockerCount } from "./workstream-row-state";

export function requestGuidanceItem(detail: WorkRequestDetail, guidanceItems: GuidanceItem[]) {
  return guidanceItems.find((item) => item.source === "clarification" && item.workRequestId === detail.work_request.id) ?? null;
}

export function openBlockersForRequest(
  detail: WorkRequestDetail,
  slices: WorkRequestPackage[],
  packageById: Map<string, WorkPackageCard>,
  activeBlockerCountBySliceId: Map<string, number>,
  activeBlockingEdges: ActiveBlockingEdge[],
  onSelectCard: CardDetailSelect,
) {
  const edge = requestBlockerEdge(detail, slices, activeBlockingEdges);
  if (edge) {
    openBlockerEdge(detail, slices, packageById, edge, onSelectCard);
    return;
  }

  const slice = blockedSlice(slices, packageById, activeBlockerCountBySliceId);
  if (slice) {
    openSliceBlocker(detail, slice, packageById, onSelectCard);
    return;
  }

  onSelectCard({ kind: "request", detail });
}

function blockedSlice(
  slices: WorkRequestPackage[],
  packageById: Map<string, WorkPackageCard>,
  activeBlockerCountBySliceId: Map<string, number>,
) {
  return slices.find((candidate) => sliceBlockerCount(candidate, packageById.get(candidate.work_package_id || ""), activeBlockerCountBySliceId) > 0);
}

function openSliceBlocker(
  detail: WorkRequestDetail,
  slice: WorkRequestPackage,
  packageById: Map<string, WorkPackageCard>,
  onSelectCard: CardDetailSelect,
) {
  const pkg = packageById.get(slice.work_package_id || "");

  if (pkg) {
    const blocker = activePackageBlockers(pkg)[0];
    const edge = blocker ? packageBlockerEdge(blocker, pkg, { detail, slice }) : pendingPackageBlockerEdge(pkg, { detail, slice });
    onSelectCard({ kind: "blocker", blocker: edge, detail, slice, pkg });
    return;
  }

  onSelectCard({ kind: "slice", detail, slice, pkg });
}

function openBlockerEdge(
  detail: WorkRequestDetail,
  slices: WorkRequestPackage[],
  packageById: Map<string, WorkPackageCard>,
  edge: ActiveBlockingEdge,
  onSelectCard: CardDetailSelect,
) {
  const slice = edgeSlice(edge, slices);
  const packageId = edge.work_package_id || edge.to.id || slice?.work_package_id || "";
  const pkg = packageById.get(packageId);

  onSelectCard({ kind: "blocker", blocker: edge, detail, slice, pkg });
}

function requestBlockerEdge(
  detail: WorkRequestDetail,
  slices: WorkRequestPackage[],
  activeBlockingEdges: ActiveBlockingEdge[],
): ActiveBlockingEdge | null {
  const requestId = detail.work_request.id;
  const sliceIds = new Set(slices.map((slice) => slice.id));
  const packageIds = new Set(slices.map((slice) => slice.work_package_id).filter((id): id is string => Boolean(id)));

  for (const edge of activeBlockingEdges) {
    if (!edgeMatchesRequest(edge, requestId, sliceIds, packageIds)) continue;
    return edge;
  }

  return null;
}

function edgeSlice(edge: ActiveBlockingEdge, slices: WorkRequestPackage[]) {
  const workPackageId = edge.work_package_id || edge.to.id;
  return slices.find((candidate) => candidate.id === workPackageId || candidate.work_package_id === workPackageId);
}

function edgeMatchesRequest(
  edge: ActiveBlockingEdge,
  requestId: string,
  sliceIds: Set<string>,
  packageIds: Set<string>,
) {
  return (
    edge.work_request_id === requestId ||
    Boolean(edge.work_package_id && sliceIds.has(edge.work_package_id)) ||
    Boolean(edge.work_package_id && packageIds.has(edge.work_package_id)) ||
    endpointMatches(edge.to, sliceIds, packageIds)
  );
}

function endpointMatches(endpoint: ActiveBlockingEdge["from"], sliceIds: Set<string>, packageIds: Set<string>) {
  return packageIds.has(endpoint.id) || sliceIds.has(endpoint.id);
}
