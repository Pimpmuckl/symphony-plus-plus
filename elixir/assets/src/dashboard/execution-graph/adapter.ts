import type { WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";
import type {
  ProductTreeDependencyEdge,
  ProductTreeDependencyEndpoint,
  ProductTreeExecutionGraph,
  ProductTreeNode,
} from "@/types/product-tree";

import type { WorkRequestExecutionGraphModel } from "./model";

const historicalStates = new Set(["skipped", "canceled", "cancelled", "abandoned", "superseded"]);

export function workRequestExecutionGraphModel(
  detail: WorkRequestDetail,
  { includeHistorical = false }: { includeHistorical?: boolean } = {},
): WorkRequestExecutionGraphModel {
  const productTree = detail.product_tree;
  const graph = productTree?.execution_graph;
  const slices = new Map(list(detail.work_packages).map((slice) => [slice.id, slice]));
  const workPackageIds = list(graph?.work_package_ids).filter(
    (id) => includeHistorical || !isHistoricalWorkPackage(slices.get(id)),
  );

  return {
    available: graphAvailable(graph),
    base_repo: firstValue(detail.work_request.repo_key, detail.work_request.repo),
    base_branch: detail.work_request.base_branch,
    groups: list(productTree?.nodes).map(mapGroup),
    work_packages: workPackageIds.map((id) => mapWorkPackage(id, slices.get(id))),
    dependency_intents: list(productTree?.dependency_edges).flatMap(mapDependencyIntent),
    effective_edges: list(graph?.effective_edges),
    topological_order: list(graph?.topological_order),
    cycles: list(graph?.cycles),
  };
}

function mapDependencyIntent(edge: ProductTreeDependencyEdge) {
  const kind = edge.kind?.trim().toLowerCase();
  const source = mapDependencyEndpoint(edge.source);
  const target = mapDependencyEndpoint(edge.target);
  if (!source || !target || !["depends_on", "blocks"].includes(kind ?? "")) return [];

  const prerequisite = kind === "blocks" ? source : target;
  const dependent = kind === "blocks" ? target : source;
  return [{ id: edge.id, prerequisite, dependent }];
}

function mapDependencyEndpoint(endpoint?: ProductTreeDependencyEndpoint) {
  const id = endpoint?.id?.trim();
  if (!id) return undefined;
  if (endpoint?.kind === "work_package") return { kind: "work_package" as const, id };
  if (endpoint?.kind === "product_node") return { kind: "group" as const, id };
  return undefined;
}

function mapGroup(group: ProductTreeNode) {
  return {
    id: group.id,
    parent_group_id: group.parent_id,
    title: group.title,
    description: group.description,
    position: group.position,
    work_package_ids: group.work_package_ids,
  };
}

function mapWorkPackage(id: string, slice?: WorkRequestPackage) {
  return {
    id,
    ...workPackageReference(slice),
    ...workPackageSignals(slice),
  };
}

function workPackageReference(slice?: WorkRequestPackage) {
  return {
    ...sliceReference(slice),
    title: slice?.title,
    repo: slice?.repo,
    base_branch: slice?.base_branch,
    status: slice?.status,
    raw_status: firstValue(slice?.work_package_status, slice?.status),
    operational_state: slice?.operational_state,
  };
}

function sliceReference(slice?: WorkRequestPackage) {
  return { group_id: slice?.product_tree_node_id, sequence: slice?.sequence };
}

function workPackageSignals(slice?: WorkRequestPackage) {
  return {
    worker_signal: slice?.worker_signal,
    pr_signal: slice?.pr_signal,
    review_signal: slice?.review_signal,
    dependency_signal: slice?.dependency_signal,
  };
}

function isHistoricalWorkPackage(slice?: WorkRequestPackage) {
  return sliceHistoryStates(slice).some(isHistoricalState);
}

function sliceHistoryStates(slice?: WorkRequestPackage) {
  return [
    slice?.status,
    slice?.work_package_status,
    slice?.delivery?.outcome,
    slice?.operational_state?.key,
    slice?.operational_state?.delivery_outcome,
  ];
}

function graphAvailable(graph?: ProductTreeExecutionGraph) {
  return graph?.available ?? false;
}

function list<T>(values?: T[] | null) {
  return values ?? [];
}

function firstValue<T>(...values: Array<T | null | undefined>) {
  return values.find((value): value is T => value != null);
}

function isHistoricalState(value: string | null | undefined) {
  return historicalStates.has(value?.trim().toLowerCase() ?? "");
}
