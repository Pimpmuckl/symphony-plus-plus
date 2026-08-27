import {
  operationalStateIsBlocked,
  workPackageIsFinished,
  type ExecutionGraphDependencyEndpoint,
  type ExecutionGraphEffectiveEdge,
  type ExecutionGraphGroup,
  type ExecutionGraphWorkPackageRef,
  type WorkRequestExecutionGraphModel,
} from "./model";

export type ExecutionFrontierVariant = "horizon-1" | "forward-2";
export type ExecutionFrontierReason = "attention" | "blocked" | "branching" | "group_transition" | "parallel_live";

export type ExecutionFrontierProjection = {
  presentation: "graph" | "metadata";
  reasons: ExecutionFrontierReason[];
  seedIds: string[];
  visibleWorkPackageIds: string[];
  previousIds: string[];
  laterIds: string[];
  otherIds: string[];
  expandedGroupIds: string[];
  groupCadence: Array<{ id: string; title?: string | null; workPackageIds: string[] }>;
  model: WorkRequestExecutionGraphModel;
};

export function executionFrontierProjection(
  graph: WorkRequestExecutionGraphModel,
  attentionKeys: ReadonlySet<string> = new Set(),
  variant: ExecutionFrontierVariant = "forward-2",
): ExecutionFrontierProjection {
  const packages = new Map(graph.work_packages.map((pkg) => [pkg.id, pkg]));
  const groups = new Map((graph.groups ?? []).map((group) => [group.id, group]));
  const edges = graph.effective_edges ?? [];
  const incoming = groupEdges(edges, "dependent_work_package_id", "prerequisite_work_package_id");
  const outgoing = groupEdges(edges, "prerequisite_work_package_id", "dependent_work_package_id");
  const liveSeeds = currentSeeds(graph.work_packages, attentionKeys);
  const seeds = frontierSeeds(graph.work_packages, liveSeeds, incoming, packages);
  const visible = frontierVisiblePackages(variant, seeds, incoming, outgoing);
  const visibleGroups = visibleGroupIds(graph, visible);
  const endpointVisible = (endpoint: ExecutionGraphDependencyEndpoint) => endpoint.kind === "group"
    ? visibleGroups.has(endpoint.id)
    : visible.has(endpoint.id);
  const orderedIds = stablePackageIds(graph, packages);
  const hidden = hiddenPartitions(orderedIds, visible, seeds, incoming, outgoing);
  const model = {
    ...graph,
    groups: graph.groups?.filter((group) => visibleGroups.has(group.id)),
    work_packages: graph.work_packages.filter((pkg) => visible.has(pkg.id)),
    dependency_intents: graph.dependency_intents?.filter((intent) => endpointVisible(intent.prerequisite) && endpointVisible(intent.dependent)),
    effective_edges: edges.filter((edge) => visible.has(edge.prerequisite_work_package_id) && visible.has(edge.dependent_work_package_id)),
  };
  const reasons = graphReasons(graph, seeds, liveSeeds, attentionKeys, incoming, outgoing, packages);
  const expandedGroups = visibleGroupIds(graph, seeds);
  attentionGroupIds(attentionKeys, groups).forEach((id) => expandedGroups.add(id));

  return {
    presentation: graph.work_packages.length > 1 && reasons.length > 0 ? "graph" : "metadata",
    reasons,
    seedIds: orderedIds.filter((id) => seeds.has(id)),
    visibleWorkPackageIds: orderedIds.filter((id) => visible.has(id)),
    ...hidden,
    expandedGroupIds: stableGroupIds(graph.groups ?? [], expandedGroups),
    groupCadence: groupCadence(orderedIds.filter((id) => visible.has(id)), packages, groups),
    model,
  };
}

function frontierSeeds(
  workPackages: WorkRequestExecutionGraphModel["work_packages"],
  liveSeeds: Set<string>,
  incoming: Map<string, string[]>,
  packages: Map<string, WorkRequestExecutionGraphModel["work_packages"][number]>,
) {
  const unfinished = workPackages.filter((pkg) => !workPackageIsFinished(pkg, pkg));
  const selected = liveSeeds.size
    ? unfinished.filter((pkg) => liveSeeds.has(pkg.id))
    : unfinished.filter((pkg) => packageIsReady(pkg, incoming.get(pkg.id) ?? [], packages));
  return new Set(selected.map((pkg) => pkg.id));
}

function currentSeeds(
  workPackages: WorkRequestExecutionGraphModel["work_packages"],
  attentionKeys: ReadonlySet<string>,
) {
  return new Set(workPackages
    .filter((pkg) => !workPackageIsFinished(pkg, pkg) && (attentionKeys.has(`work_package:${pkg.id}`) || packageIsLive(pkg)))
    .map((pkg) => pkg.id));
}

function frontierVisiblePackages(
  variant: ExecutionFrontierVariant,
  seeds: Set<string>,
  incoming: Map<string, string[]>,
  outgoing: Map<string, string[]>,
) {
  const visible = new Set(seeds);
  addDirectionalRings(visible, seeds, incoming, 1);
  addDirectionalRings(visible, seeds, outgoing, variant === "forward-2" ? 2 : 1);
  return visible;
}

function addDirectionalRings(visible: Set<string>, seeds: Set<string>, edges: Map<string, string[]>, depth: number) {
  let ring = [...seeds];
  for (let index = 0; index < depth; index += 1) {
    ring = [...new Set(ring.flatMap((id) => edges.get(id) ?? []))].filter((id) => !visible.has(id));
    ring.forEach((id) => visible.add(id));
  }
}

function hiddenPartitions(
  orderedIds: string[],
  visible: Set<string>,
  seeds: Set<string>,
  incoming: Map<string, string[]>,
  outgoing: Map<string, string[]>,
) {
  const previous = reachable(seeds, incoming);
  const later = reachable(seeds, outgoing);
  const previousIds = orderedIds.filter((id) => !visible.has(id) && previous.has(id));
  const previousSet = new Set(previousIds);
  const laterIds = orderedIds.filter((id) => !visible.has(id) && !previousSet.has(id) && later.has(id));
  const classified = new Set([...previousIds, ...laterIds]);
  const otherIds = orderedIds.filter((id) => !visible.has(id) && !classified.has(id));
  return { previousIds, laterIds, otherIds };
}

function reachable(seeds: Set<string>, edges: Map<string, string[]>) {
  const found = new Set<string>();
  const pending = [...seeds];
  while (pending.length) {
    const id = pending.shift()!;
    for (const next of edges.get(id) ?? []) {
      if (seeds.has(next) || found.has(next)) continue;
      found.add(next);
      pending.push(next);
    }
  }
  return found;
}

function graphReasons(
  graph: WorkRequestExecutionGraphModel,
  seeds: Set<string>,
  liveSeeds: Set<string>,
  attentionKeys: ReadonlySet<string>,
  incoming: Map<string, string[]>,
  outgoing: Map<string, string[]>,
  packages: Map<string, WorkRequestExecutionGraphModel["work_packages"][number]>,
) {
  const reasons: ExecutionFrontierReason[] = [];
  if (attentionKeys.size) reasons.push("attention");
  if ([...packages.values()].some((pkg) => operationalStateIsBlocked(pkg.operational_state))) reasons.push("blocked");
  if ([...incoming.values(), ...outgoing.values()].some((ids) => ids.length > 1)) reasons.push("branching");
  if (hasParallelSeeds(liveSeeds, outgoing)) reasons.push("parallel_live");
  if ((graph.effective_edges ?? []).some((edge) => crossesCurrentGroup(edge, seeds, packages))) reasons.push("group_transition");
  return reasons;
}

function hasParallelSeeds(seeds: Set<string>, outgoing: Map<string, string[]>) {
  const ids = [...seeds];
  for (let left = 0; left < ids.length; left += 1) {
    const descendants = reachable(new Set([ids[left]]), outgoing);
    for (let right = left + 1; right < ids.length; right += 1) {
      if (!descendants.has(ids[right]) && !reachable(new Set([ids[right]]), outgoing).has(ids[left])) return true;
    }
  }
  return false;
}

function crossesCurrentGroup(
  edge: ExecutionGraphEffectiveEdge,
  seeds: Set<string>,
  packages: Map<string, WorkRequestExecutionGraphModel["work_packages"][number]>,
) {
  if (!seeds.has(edge.prerequisite_work_package_id) && !seeds.has(edge.dependent_work_package_id)) return false;
  const prerequisiteGroup = packages.get(edge.prerequisite_work_package_id)?.group_id;
  const dependentGroup = packages.get(edge.dependent_work_package_id)?.group_id;
  return Boolean(prerequisiteGroup && dependentGroup && prerequisiteGroup !== dependentGroup);
}

function attentionGroupIds(attentionKeys: ReadonlySet<string>, groups: Map<string, ExecutionGraphGroup>) {
  const selected = new Set<string>();
  for (const key of attentionKeys) {
    if (!key.startsWith("group:")) continue;
    let groupId: string | null | undefined = key.slice("group:".length);
    const seen = new Set<string>();
    while (groupId && !seen.has(groupId)) {
      selected.add(groupId);
      seen.add(groupId);
      groupId = groups.get(groupId)?.parent_group_id;
    }
  }
  return selected;
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
  edges: ExecutionGraphEffectiveEdge[],
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
    while (groupId && !visible.has(groupId)) {
      visible.add(groupId);
      groupId = byId.get(groupId)?.parent_group_id;
    }
  }
  return visible;
}

function stablePackageIds(
  graph: WorkRequestExecutionGraphModel,
  packages: Map<string, WorkRequestExecutionGraphModel["work_packages"][number]>,
) {
  const topologicalOrder = new Map((graph.topological_order ?? []).map((id, index) => [id, index]));
  return [...packages.keys()].sort((left, right) => {
    const leftOrder = topologicalOrder.get(left) ?? Number.MAX_SAFE_INTEGER;
    const rightOrder = topologicalOrder.get(right) ?? Number.MAX_SAFE_INTEGER;
    return leftOrder - rightOrder || comparePackages(packages.get(left), packages.get(right));
  });
}

function stableGroupIds(groups: ExecutionGraphGroup[], selected: Set<string>) {
  const byParent = new Map<string | null, ExecutionGraphGroup[]>();
  for (const group of groups) {
    const parent = group.parent_group_id ?? null;
    byParent.set(parent, [...(byParent.get(parent) ?? []), group]);
  }
  const ordered: string[] = [];
  const visit = (group: ExecutionGraphGroup) => {
    if (selected.has(group.id)) ordered.push(group.id);
    (byParent.get(group.id) ?? []).sort(compareGroups).forEach(visit);
  };
  (byParent.get(null) ?? []).sort(compareGroups).forEach(visit);
  return ordered;
}

function groupCadence(
  visibleIds: string[],
  packages: Map<string, WorkRequestExecutionGraphModel["work_packages"][number]>,
  groups: Map<string, ExecutionGraphGroup>,
) {
  const packagesByGroup = new Map<string, string[]>();
  const cadenceIds: string[] = [];
  const seen = new Set<string>();
  for (const id of visibleIds) {
    const groupId = packages.get(id)?.group_id;
    if (!groupId) continue;
    packagesByGroup.set(groupId, [...(packagesByGroup.get(groupId) ?? []), id]);
    const ancestry: string[] = [];
    let current: string | null | undefined = groupId;
    while (current && !ancestry.includes(current)) {
      ancestry.unshift(current);
      current = groups.get(current)?.parent_group_id;
    }
    for (const ancestor of ancestry) {
      if (!seen.has(ancestor)) cadenceIds.push(ancestor);
      seen.add(ancestor);
    }
  }
  return cadenceIds.map((id) => ({
    id,
    title: groups.get(id)?.title,
    workPackageIds: packagesByGroup.get(id) ?? [],
  }));
}

function compareGroups(left?: ExecutionGraphGroup, right?: ExecutionGraphGroup) {
  return (left?.position ?? Number.MAX_SAFE_INTEGER) - (right?.position ?? Number.MAX_SAFE_INTEGER)
    || (left?.id ?? "").localeCompare(right?.id ?? "");
}

function comparePackages(left?: ExecutionGraphWorkPackageRef, right?: ExecutionGraphWorkPackageRef) {
  return (left?.sequence ?? Number.MAX_SAFE_INTEGER) - (right?.sequence ?? Number.MAX_SAFE_INTEGER)
    || (left?.id ?? "").localeCompare(right?.id ?? "");
}
