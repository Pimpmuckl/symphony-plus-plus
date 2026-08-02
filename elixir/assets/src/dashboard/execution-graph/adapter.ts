import type { WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";
import type {
  ProductTreeDependencyEdge,
  ProductTreeDependencyEndpoint,
  ProductTreeExecutionGraph,
  ProductTreeNode,
} from "@/types/product-tree";

import { operationalStateIsBlocked, workPackageIsFinished, type ExecutionGraphDependencyEndpoint, type WorkRequestExecutionGraphModel } from "./model";

const historicalStates = new Set(["skipped", "canceled", "cancelled", "abandoned", "superseded"]);
export type FocusFrontierVariant = "horizon-1" | "forward-2";

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
    cycles: list(graph?.cycles),
  };
}

export function workRequestExecutionFrontierProjection(
  graph: WorkRequestExecutionGraphModel,
  attentionKeys: ReadonlySet<string> = new Set(),
  variant: FocusFrontierVariant = "horizon-1",
) {
  const packages = new Map(graph.work_packages.map((pkg) => [pkg.id, pkg]));
  const edges = graph.effective_edges ?? [];
  const incoming = groupEdges(edges, "dependent_work_package_id", "prerequisite_work_package_id");
  const outgoing = groupEdges(edges, "prerequisite_work_package_id", "dependent_work_package_id");
  const seeds = frontierSeed(graph.work_packages, attentionKeys, incoming, packages);
  const visible = frontierVisiblePackages(variant, seeds, incoming, outgoing);
  const groups = visibleGroupIds(graph, visible);
  const endpointVisible = (endpoint: ExecutionGraphDependencyEndpoint) => endpoint.kind === "group" ? groups.has(endpoint.id) : visible.has(endpoint.id);
  const model = {
    ...graph,
    groups: graph.groups?.filter((group) => groups.has(group.id)),
    work_packages: graph.work_packages.filter((pkg) => visible.has(pkg.id)),
    dependency_intents: graph.dependency_intents?.filter((intent) => endpointVisible(intent.prerequisite) && endpointVisible(intent.dependent)),
    effective_edges: edges.filter((edge) => visible.has(edge.prerequisite_work_package_id) && visible.has(edge.dependent_work_package_id)),
  };
  const expandedGroupIds = visibleGroupIds(graph, seeds);
  return { expandedGroupIds, model };
}

export function workRequestExecutionFrontierModel(
  graph: WorkRequestExecutionGraphModel,
  attentionKeys: ReadonlySet<string> = new Set(),
  variant: FocusFrontierVariant = "horizon-1",
) {
  return workRequestExecutionFrontierProjection(graph, attentionKeys, variant).model;
}

function frontierSeed(
  workPackages: WorkRequestExecutionGraphModel["work_packages"],
  attentionKeys: ReadonlySet<string>,
  incoming: Map<string, string[]>,
  packages: Map<string, WorkRequestExecutionGraphModel["work_packages"][number]>,
) {
  const unfinished = workPackages.filter((pkg) => !workPackageIsFinished(pkg, pkg));
  const live = unfinished.filter((pkg) => [attentionKeys.has(`work_package:${pkg.id}`), packageIsLive(pkg)].some(Boolean));
  return new Set((live.length ? live : unfinished.filter((pkg) => packageIsReady(pkg, incoming.get(pkg.id) ?? [], packages))).map((pkg) => pkg.id));
}

function frontierVisiblePackages(
  variant: FocusFrontierVariant,
  seeds: Set<string>,
  incoming: Map<string, string[]>,
  outgoing: Map<string, string[]>,
) {
  return variant === "forward-2"
    ? directionalHorizon(seeds, incoming, outgoing, 1, 2)
    : symmetricHorizon(seeds, incoming, outgoing, 1);
}

function symmetricHorizon(
  seeds: Set<string>,
  incoming: Map<string, string[]>,
  outgoing: Map<string, string[]>,
  depth: number,
) {
  const visible = new Set(seeds);
  let ring = [...seeds];
  for (let index = 0; index < depth; index += 1) {
    ring = [...new Set(ring.flatMap((id) => [...(incoming.get(id) ?? []), ...(outgoing.get(id) ?? [])]))]
      .filter((id) => !visible.has(id));
    ring.forEach((id) => visible.add(id));
  }
  return visible;
}

function directionalHorizon(
  seeds: Set<string>,
  incoming: Map<string, string[]>,
  outgoing: Map<string, string[]>,
  previousDepth: number,
  followingDepth: number,
) {
  const visible = new Set(seeds);
  addDirectionalRings(visible, seeds, incoming, previousDepth);
  addDirectionalRings(visible, seeds, outgoing, followingDepth);
  return visible;
}

function addDirectionalRings(visible: Set<string>, seeds: Set<string>, edges: Map<string, string[]>, depth: number) {
  let ring = [...seeds];
  for (let index = 0; index < depth; index += 1) {
    ring = [...new Set(ring.flatMap((id) => edges.get(id) ?? []))].filter((id) => !visible.has(id));
    ring.forEach((id) => visible.add(id));
  }
}

function packageIsLive(pkg: WorkRequestExecutionGraphModel["work_packages"][number]) {
  const status = [pkg.raw_status, pkg.status, pkg.operational_state?.key].filter(Boolean).join(" ").toLowerCase();
  const dependencyWaiting = Boolean(pkg.dependency_signal && pkg.dependency_signal.satisfied < pkg.dependency_signal.required);
  return packageHasLiveDelivery(pkg) || /active|implement|review/.test(status) || operationalStateIsBlocked(pkg.operational_state)
    || (!dependencyWaiting && /block|fail|error/.test(status));
}

function packageHasLiveDelivery(pkg: WorkRequestExecutionGraphModel["work_packages"][number]) {
  return pkg.worker_signal?.status === "active" || ["in_progress", "failed"].includes(pkg.review_signal?.status ?? "")
    || ["pending", "failing"].includes(pkg.pr_signal?.checks?.status ?? "");
}

function packageIsReady(pkg: WorkRequestExecutionGraphModel["work_packages"][number], incoming: string[], packages: Map<string, WorkRequestExecutionGraphModel["work_packages"][number]>) {
  const dependency = pkg.dependency_signal;
  if (dependency) return dependency.satisfied >= dependency.required && dependency.blocked === 0;
  return incoming.every((id) => workPackageIsFinished(packages.get(id), packages.get(id)));
}

function groupEdges(
  edges: NonNullable<WorkRequestExecutionGraphModel["effective_edges"]>,
  key: "dependent_work_package_id" | "prerequisite_work_package_id",
  value: "dependent_work_package_id" | "prerequisite_work_package_id",
) {
  const grouped = new Map<string, string[]>();
  for (const edge of edges) grouped.set(edge[key], [...(grouped.get(edge[key]) ?? []), edge[value]]);
  return grouped;
}

function visibleGroupIds(graph: WorkRequestExecutionGraphModel, visiblePackages: Set<string>) {
  const byId = new Map((graph.groups ?? []).map((group) => [group.id, group]));
  const visible = new Set<string>();
  for (const pkg of graph.work_packages) {
    if (!visiblePackages.has(pkg.id)) continue;
    let groupId = pkg.group_id;
    while (groupId && !visible.has(groupId)) { visible.add(groupId); groupId = byId.get(groupId)?.parent_group_id; }
  }
  return visible;
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
