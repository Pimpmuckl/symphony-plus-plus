import type { ActiveBlockingEdge, GuidanceItem, WorkRequestPackage, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { ProductTreeNode } from "@/types/product-tree";
import type { CardDetailSelect } from "./runtime";
import { activePackageBlockers, packageBlockerEdge, pendingPackageBlockerEdge } from "./blocker-selection";
import { sliceBlockerCount, sliceGuidanceCount } from "./workstream-row-state";

type TreeIndex = {
  childrenByParent: Map<string, ProductTreeNode[]>;
};

export function requestGuidanceItem(detail: WorkRequestDetail, guidanceItems: GuidanceItem[]) {
  return guidanceItems.find((item) => item.source === "clarification" && item.workRequestId === detail.work_request.id) ?? null;
}

export function openGuidanceForSlices(
  detail: WorkRequestDetail,
  slices: WorkRequestPackage[],
  packageById: Map<string, WorkPackageCard>,
  guidanceItems: GuidanceItem[],
  onSelectGuidance: (item: GuidanceItem) => void,
  onSelectCard: CardDetailSelect,
) {
  const item = guidanceItemForSlices(slices, packageById, guidanceItems);
  if (item) {
    onSelectGuidance(item);
    return;
  }

  const slice = slices.find((candidate) => sliceGuidanceCount(candidate, packageById.get(candidate.work_package_id || "")) > 0) ?? slices[0];
  if (slice) {
    onSelectCard({ kind: "slice", detail, slice, pkg: packageById.get(slice.work_package_id || "") });
    return;
  }

  onSelectCard({ kind: "request", detail });
}

export function openGuidanceForSlice(
  detail: WorkRequestDetail,
  slice: WorkRequestPackage,
  pkg: WorkPackageCard | undefined,
  guidanceItems: GuidanceItem[],
  onSelectGuidance: (item: GuidanceItem) => void,
  onSelectCard: CardDetailSelect,
) {
  const item = packageGuidanceItem(pkg, guidanceItems);
  if (item) {
    onSelectGuidance(item);
    return;
  }

  onSelectCard({ kind: "slice", detail, slice, pkg });
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

export function openBlockersForSlices(
  detail: WorkRequestDetail,
  slices: WorkRequestPackage[],
  packageById: Map<string, WorkPackageCard>,
  activeBlockerCountBySliceId: Map<string, number>,
  activeBlockingEdges: ActiveBlockingEdge[],
  onSelectCard: CardDetailSelect,
) {
  const edge = blockerEdgeForSlices(slices, packageById, activeBlockingEdges);
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

export function productNodeSubtreeSlices(
  node: ProductTreeNode,
  treeIndex: TreeIndex,
  slicesById: Map<string, WorkRequestPackage>,
  visited = new Set<string>(),
): WorkRequestPackage[] {
  if (visited.has(node.id)) return [];
  visited.add(node.id);

  const slices = (node.work_package_ids ?? []).map((sliceId) => slicesById.get(sliceId)).filter((slice): slice is WorkRequestPackage => Boolean(slice));
  for (const child of treeIndex.childrenByParent.get(node.id) ?? []) {
    slices.push(...productNodeSubtreeSlices(child, treeIndex, slicesById, visited));
  }

  return slices;
}

function packageGuidanceItem(pkg: WorkPackageCard | undefined, guidanceItems: GuidanceItem[]) {
  if (!pkg) return null;
  return guidanceItems.find((item) => item.source === "guidance" && item.packageId === pkg.id) ?? null;
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

function blockerEdgeForSlices(
  slices: WorkRequestPackage[],
  packageById: Map<string, WorkPackageCard>,
  activeBlockingEdges: ActiveBlockingEdge[],
) {
  return activeBlockingEdges.find((edge) => edgeMatchesAnySlice(edge, slices, packageById)) ?? null;
}

function edgeMatchesAnySlice(edge: ActiveBlockingEdge, slices: WorkRequestPackage[], packageById: Map<string, WorkPackageCard>) {
  return slices.some((slice) => {
    const pkg = packageById.get(slice.work_package_id || "");
    const workPackageId = pkg?.id || slice.work_package_id || slice.id;
    return edge.work_package_id === workPackageId || edge.to.id === workPackageId;
  });
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

function guidanceItemForSlices(slices: WorkRequestPackage[], packageById: Map<string, WorkPackageCard>, guidanceItems: GuidanceItem[]) {
  for (const slice of slices) {
    const item = packageGuidanceItem(packageById.get(slice.work_package_id || ""), guidanceItems);
    if (item) return item;
  }

  return null;
}
