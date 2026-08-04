import type { ActiveBlockingEdge, WorkRequestPackage, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { ProductTreeCompletionMark, ProductTreeNode } from "@/types/product-tree";
import { isFinishedBoardStatus, sliceLane } from "@/lib/operational-state";
import { terminalWorkPackageIds, workRequestIsTerminal } from "./workstream-row-state";

export type ActiveBlockerEntityCounts = {
  requests: Map<string, number>;
  slices: Map<string, number>;
  packages: Map<string, number>;
  sliceBlockerKeys: Map<string, Set<string>>;
};

export function requestProgress(detail: WorkRequestDetail, packageById: Map<string, WorkPackageCard>) {
  const slices = detail.work_packages ?? [];
  const treeProgress = productTreeRootProgress(detail, slices, packageById);

  if (treeProgress.length > 0) return averageProgress(treeProgress);
  if (slices.length > 0) return averageProgress(slices.map((slice) => sliceProgressPercent(slice, packageById.get(slice.work_package_id || ""))));
  return isFinishedBoardStatus(detail.work_request.operational_state?.key || detail.work_request.status) ? 100 : 0;
}

export function sliceProgressPercent(slice: WorkRequestPackage, pkg?: WorkPackageCard) {
  const mark = sliceProgressMark(slice, pkg);
  if (mark === "done") return 100;
  if (mark === "not_done") return 0;

  const completed = pkg?.plan?.completed_count ?? 0;
  const total = pkg?.plan?.total_count ?? 0;
  return total > 0 ? Math.round((completed / total) * 100) : 50;
}

function completionMarkProgress(mark: ProductTreeCompletionMark) {
  if (mark === "done") return 100;
  if (mark === "partial") return 50;
  return 0;
}

export function productNodeProgressPercent(
  node: ProductTreeNode,
  nodeSubtreeSlices: WorkRequestPackage[],
  packageById: Map<string, WorkPackageCard>,
) {
  if (nodeSubtreeSlices.length === 0) return completionMarkProgress(node.computed_completion_mark || node.completion_mark || "unknown");

  return averageProgress(nodeSubtreeSlices.map((slice) => sliceProgressPercent(slice, packageById.get(slice.work_package_id || ""))));
}

export function productTreeCounts(detail: WorkRequestDetail, activeBlockerCount: number) {
  const summary = detail.product_tree?.summary;

  return {
    nodeCount: numberValue(summary?.node_count, detail.product_tree?.nodes?.length),
    sliceCount: numberValue(summary?.work_package_count, detail.work_packages?.length),
    guidanceCount: numberValue(detail.summary?.open_question_count, detail.work_request.open_question_count, openQuestionCount(detail)),
    blockerCount: activeBlockerCount,
  };
}

export function activeBlockerEntityCounts(
  edges: ActiveBlockingEdge[],
  requestDetails: WorkRequestDetail[] = [],
  packageById = new Map<string, WorkPackageCard>(),
): ActiveBlockerEntityCounts {
  const requestIndex = blockerRequestIndex(requestDetails);
  const terminalPackageIds = terminalWorkPackageIds(requestDetails, packageById);
  const terminalRequestIds = new Set(requestDetails.filter(workRequestIsTerminal).map((detail) => detail.work_request.id));
  const blockerKeys = edges.filter((edge) => !edgeTargetsTerminalPackage(edge, terminalPackageIds)).reduce<ActiveBlockerEntityKeySets>((keys, edge) => {
    const blockerKey = activeBlockerKey(edge);

    addBlockerKeys(keys.requests, [...activeBlockerRequestIds(edge, requestIndex)].filter((id) => !terminalRequestIds.has(id)), blockerKey);
    addBlockerKeys(keys.slices, [...activeBlockerSliceIds(edge, requestIndex)].filter((id) => !terminalPackageIds.has(id)), blockerKey);
    addBlockerKeys(keys.packages, [...activeBlockerPackageIds(edge)].filter((id) => !terminalPackageIds.has(id)), blockerKey);

    return keys;
  }, { requests: new Map(), slices: new Map(), packages: new Map() });

  return {
    requests: blockerKeyCounts(blockerKeys.requests),
    slices: blockerKeyCounts(blockerKeys.slices),
    packages: blockerKeyCounts(blockerKeys.packages),
    sliceBlockerKeys: blockerKeys.slices,
  };
}

function edgeTargetsTerminalPackage(edge: ActiveBlockingEdge, terminalPackageIds: Set<string>) {
  const targetId = edge.to.kind === "work_package" && edge.to.id ? edge.to.id : edge.work_package_id;
  return Boolean(targetId && terminalPackageIds.has(targetId));
}

export function activeBlockerEdgesForRequest(edges: ActiveBlockingEdge[], detail: WorkRequestDetail) {
  const requestId = detail.work_request.id;
  const requestIndex = blockerRequestIndex([detail]);
  return edges.filter((edge) => activeBlockerRequestIds(edge, requestIndex).has(requestId));
}

type ActiveBlockerEntityKeySets = {
  requests: Map<string, Set<string>>;
  slices: Map<string, Set<string>>;
  packages: Map<string, Set<string>>;
};

type BlockerRequestIndex = {
  requestIdBySliceId: Map<string, string>;
  requestIdsByPackageId: Map<string, Set<string>>;
  sliceIdsByPackageId: Map<string, Set<string>>;
};

function blockerRequestIndex(requestDetails: WorkRequestDetail[]): BlockerRequestIndex {
  const requestIdBySliceId = new Map<string, string>();
  const requestIdsByPackageId = new Map<string, Set<string>>();
  const sliceIdsByPackageId = new Map<string, Set<string>>();

  for (const detail of requestDetails) {
    const requestId = detail.work_request.id;
    for (const slice of detail.work_packages ?? []) {
      requestIdBySliceId.set(slice.id, requestId);
      if (!slice.work_package_id) continue;

      const requestIds = requestIdsByPackageId.get(slice.work_package_id) ?? new Set<string>();
      requestIds.add(requestId);
      requestIdsByPackageId.set(slice.work_package_id, requestIds);

      const sliceIds = sliceIdsByPackageId.get(slice.work_package_id) ?? new Set<string>();
      sliceIds.add(slice.id);
      sliceIdsByPackageId.set(slice.work_package_id, sliceIds);
    }
  }

  return { requestIdBySliceId, requestIdsByPackageId, sliceIdsByPackageId };
}

function activeBlockerRequestIds(edge: ActiveBlockingEdge, requestIndex: BlockerRequestIndex) {
  const derivedRequestIds = new Set<string>();
  if (edge.work_request_id) derivedRequestIds.add(edge.work_request_id);
  if (edge.work_package_id) {
    const requestId = requestIndex.requestIdBySliceId.get(edge.work_package_id);
    if (requestId) derivedRequestIds.add(requestId);
  }
  if (edge.work_package_id) {
    for (const requestId of requestIndex.requestIdsByPackageId.get(edge.work_package_id) ?? []) {
      derivedRequestIds.add(requestId);
    }
  }
  addEndpointRequestIds(derivedRequestIds, requestIndex, edge.to);
  return derivedRequestIds;
}

function activeBlockerSliceIds(edge: ActiveBlockingEdge, requestIndex: BlockerRequestIndex) {
  const sliceIds = new Set<string>();
  if (edge.work_package_id) sliceIds.add(edge.work_package_id);
  if (edge.work_package_id) {
    for (const sliceId of requestIndex.sliceIdsByPackageId.get(edge.work_package_id) ?? []) {
      sliceIds.add(sliceId);
    }
  }
  addEndpointSliceIds(sliceIds, requestIndex, edge.to);
  return sliceIds;
}

function activeBlockerPackageIds(edge: ActiveBlockingEdge) {
  const packageIds = new Set<string>();
  if (edge.work_package_id) packageIds.add(edge.work_package_id);
  addEndpointPackageIds(packageIds, edge.to);
  return packageIds;
}

function addEndpointRequestIds(
  requestIds: Set<string>,
  requestIndex: BlockerRequestIndex,
  endpoint?: ActiveBlockingEdge["from"],
) {
  if (!endpoint) return;

  if (endpoint.kind === "work_package") {
    for (const requestId of requestIndex.requestIdsByPackageId.get(endpoint.id) ?? []) {
      requestIds.add(requestId);
    }
  }
}

function addEndpointSliceIds(
  sliceIds: Set<string>,
  requestIndex: BlockerRequestIndex,
  endpoint?: ActiveBlockingEdge["from"],
) {
  if (!endpoint) return;

  if (endpoint.kind === "work_package") {
    for (const sliceId of requestIndex.sliceIdsByPackageId.get(endpoint.id) ?? []) {
      sliceIds.add(sliceId);
    }
  }
}

function addEndpointPackageIds(packageIds: Set<string>, endpoint?: ActiveBlockingEdge["from"]) {
  if (endpoint?.kind === "work_package") packageIds.add(endpoint.id);
}

function activeBlockerKey(edge: ActiveBlockingEdge) {
  return edge.blocker_id || edge.id;
}

function addBlockerKeys(blockerKeysByEntityId: Map<string, Set<string>>, ids: Iterable<string>, blockerKey: string) {
  for (const id of ids) {
    const blockerKeys = blockerKeysByEntityId.get(id) ?? new Set<string>();
    blockerKeys.add(blockerKey);
    blockerKeysByEntityId.set(id, blockerKeys);
  }
}

function blockerKeyCounts(blockerKeysByEntityId: Map<string, Set<string>>) {
  return new Map([...blockerKeysByEntityId].map(([id, blockerKeys]) => [id, blockerKeys.size]));
}

export function rootProductSliceIds(detail: WorkRequestDetail, slices: WorkRequestPackage[]) {
  const productTree = detail.product_tree;
  if (!productTree) return slices.map((slice) => slice.id);

  const explicitRootSliceIds = productTree.root_work_package_ids ?? [];
  if (explicitRootSliceIds.length > 0) return explicitRootSliceIds;

  const nestedSliceIds = new Set((productTree.nodes ?? []).flatMap((node) => node.work_package_ids ?? []));
  const rootSliceIds: string[] = [];

  for (const slice of slices) {
    if (!nestedSliceIds.has(slice.id)) rootSliceIds.push(slice.id);
  }

  return rootSliceIds;
}

function openQuestionCount(detail: WorkRequestDetail) {
  return (detail.clarification_questions ?? []).filter((question) => question.status === "open").length;
}

function productTreeRootProgress(detail: WorkRequestDetail, slices: WorkRequestPackage[], packageById: Map<string, WorkPackageCard>) {
  const nodes = detail.product_tree?.nodes ?? [];
  if (nodes.length === 0) return [];

  const nodeById = new Map(nodes.map((node) => [node.id, node]));
  const childrenByParent = productTreeChildrenByParent(nodes);
  const sliceById = new Map(slices.map((slice) => [slice.id, slice]));
  const rootNodeIds = detail.product_tree?.root_node_ids?.length ? detail.product_tree.root_node_ids : implicitRootNodeIds(nodes);
  return [
    ...rootNodeProgress(rootNodeIds, nodeById, childrenByParent, sliceById, packageById),
    ...rootSliceProgress(detail, slices, packageById),
  ];
}

function rootNodeProgress(
  rootNodeIds: string[],
  nodeById: Map<string, ProductTreeNode>,
  childrenByParent: Map<string, ProductTreeNode[]>,
  sliceById: Map<string, WorkRequestPackage>,
  packageById: Map<string, WorkPackageCard>,
) {
  const progress: number[] = [];
  for (const nodeId of rootNodeIds) {
    const node = nodeById.get(nodeId);
    if (node) progress.push(productNodeProgressPercent(node, productNodeSubtreeSlices(node, childrenByParent, sliceById), packageById));
  }
  return progress;
}

function rootSliceProgress(detail: WorkRequestDetail, slices: WorkRequestPackage[], packageById: Map<string, WorkPackageCard>) {
  const progress: number[] = [];
  const sliceById = new Map(slices.map((slice) => [slice.id, slice]));
  for (const sliceId of rootProductSliceIds(detail, slices)) {
    const slice = sliceById.get(sliceId);
    if (slice) progress.push(sliceProgressPercent(slice, packageById.get(slice.work_package_id || "")));
  }
  return progress;
}

function productTreeChildrenByParent(nodes: ProductTreeNode[]) {
  const childrenByParent = new Map<string, ProductTreeNode[]>();
  for (const node of nodes) {
    if (!node.parent_id) continue;
    const children = childrenByParent.get(node.parent_id) ?? [];
    children.push(node);
    childrenByParent.set(node.parent_id, children);
  }

  return childrenByParent;
}

function productNodeSubtreeSlices(
  node: ProductTreeNode,
  childrenByParent: Map<string, ProductTreeNode[]>,
  sliceById: Map<string, WorkRequestPackage>,
  visited = new Set<string>(),
): WorkRequestPackage[] {
  if (visited.has(node.id)) return [];
  visited.add(node.id);

  const slices = (node.work_package_ids ?? []).map((sliceId) => sliceById.get(sliceId)).filter((slice): slice is WorkRequestPackage => Boolean(slice));
  for (const child of childrenByParent.get(node.id) ?? []) {
    slices.push(...productNodeSubtreeSlices(child, childrenByParent, sliceById, visited));
  }

  return slices;
}

function implicitRootNodeIds(nodes: ProductTreeNode[]) {
  const rootIds: string[] = [];
  for (const node of nodes) {
    if (!node.parent_id) rootIds.push(node.id);
  }
  return rootIds;
}

function sliceProgressMark(slice: WorkRequestPackage, pkg?: WorkPackageCard): ProductTreeCompletionMark {
  const lane = sliceLane(slice, pkg);
  if (lane === "finished") return "done";

  const state = slice.operational_state?.key || slice.work_package_status || pkg?.operational_state?.key || pkg?.status || slice.status;
  if (SLICE_PARTIAL_PROGRESS_STATES.has(state || "")) return "partial";

  return "not_done";
}

const SLICE_PARTIAL_PROGRESS_STATES = new Set([
  "active",
  "blocked",
  "ci_waiting",
  "implementing",
  "in_progress",
  "merge_ready",
  "ready_to_finish",
  "merging",
  "merging_into_phase",
  "needs_closeout",
  "planning",
  "ready_for_architect_merge",
  "ready_for_merge",
  "ready_for_human_merge",
  "reviewing",
]);

function averageProgress(values: number[]) {
  if (values.length === 0) return 0;
  return Math.round(values.reduce((total, value) => total + value, 0) / values.length);
}

function numberValue(...values: Array<number | null | undefined>) {
  return values.find((value): value is number => typeof value === "number" && Number.isFinite(value)) ?? 0;
}
