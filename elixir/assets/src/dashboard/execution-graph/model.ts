import { isFinishedBoardStatus } from "@/lib/operational-state";
import { entityRect, layoutRootEntities, orderWithinRanks } from "./layout";

export type DependencyPathState = "satisfied" | "active" | "waiting" | "blocked";
export type GraphOrientation = "desktop" | "mobile";
export type GraphEntityKind = "group" | "work_package";

export type ExecutionGraphGroup = {
  id: string;
  parent_group_id?: string | null;
  title?: string | null;
  description?: string | null;
  position?: number;
  work_package_ids?: string[];
};

export type ExecutionGraphWorkPackageRef = {
  id: string;
  group_id?: string | null;
  sequence?: number;
  title?: string | null;
  repo?: string | null;
  base_branch?: string | null;
  status?: string | null;
  raw_status?: string | null;
  operational_state?: {
    key?: string | null;
    label?: string | null;
    tone?: string | null;
    reason?: string | null;
  } | null;
};
export type ExecutionGraphEffectiveEdge = {
  prerequisite_work_package_id: string;
  dependent_work_package_id: string;
  dependency_ids?: string[];
};
export type ExecutionGraphDependencyEndpoint = {
  kind: GraphEntityKind;
  id: string;
};
export type ExecutionGraphDependencyIntent = {
  id: string;
  prerequisite: ExecutionGraphDependencyEndpoint;
  dependent: ExecutionGraphDependencyEndpoint;
};
export type WorkRequestExecutionGraphModel = {
  available?: boolean;
  base_repo?: string | null;
  base_branch?: string | null;
  groups?: ExecutionGraphGroup[];
  work_packages: Array<ExecutionGraphWorkPackageRef & ExecutionGraphWorkPackageSignals>;
  dependency_intents?: ExecutionGraphDependencyIntent[];
  effective_edges?: ExecutionGraphEffectiveEdge[];
  cycles?: string[][];
};
export type ExecutionGraphWorkPackageSignals = {
  id: string;
  raw_status?: string | null;
  operational_state?: ExecutionGraphWorkPackageRef["operational_state"];
  worker_signal?: {
    status: "active" | "idle" | "paused" | "stale" | "unavailable";
    active_since?: string | null;
    last_activity?: string | null;
    run_label?: string | null;
  } | null;
  pr_signal?: {
    status: "none" | "open" | "merged" | "unavailable";
    url?: string | null;
    number?: number | null;
    repository?: string | null;
    head_sha?: string | null;
    current_head_sha?: string | null;
    head_matches?: boolean | null;
    checks?: {
      status: "pending" | "passing" | "failing" | "unavailable";
      current?: number | null;
      total?: number | null;
    } | null;
  } | null;
  review_signal?: {
    type?: string | null;
    args?: Record<string, unknown> | null;
    status: "pending" | "in_progress" | "passed" | "failed" | "unavailable";
    current?: number | null;
    total?: number | null;
    step?: string | null;
    evidence_id?: string | null;
  } | null;
  dependency_signal?: {
    satisfied: number;
    required: number;
    active: number;
    blocked: number;
    unmet_work_package_ids: string[];
    inputs: Array<{
      work_package_id: string;
      status: DependencyPathState;
    }>;
  } | null;
};
export type ExecutionGraphEntityState = {
  label: string;
  tone: "active" | "waiting" | "blocked" | "complete" | "neutral";
  completed: number;
  total: number;
};
export type ExecutionGraphRepoScope = {
  repo: string;
  branch?: string | null;
};
export type GraphEntityRect = {
  key: string;
  id: string;
  kind: GraphEntityKind;
  parent_group_id?: string | null;
  x: number;
  y: number;
  width: number;
  height: number;
  depth: number;
  row: number;
  column: number;
  order: number;
  expanded?: boolean;
};
export type ExecutionGraphRouting = {
  wrapped: boolean;
  contentRight: number;
  columnGutters: Map<number, number>;
  rowCorridors: Map<number, number>;
  bandBottoms: Map<number, number>;
};
export type VisibleGraphDependency = {
  key: string;
  source_key: string;
  target_key: string;
  state: DependencyPathState;
  intent_ids: string[];
  target_is_collapsed_proxy: boolean;
};
export type ExecutionGraphLayoutModel = {
  groups: Map<string, ExecutionGraphGroup>;
  refs: Map<string, ExecutionGraphWorkPackageRef>;
  signals: Map<string, ExecutionGraphWorkPackageSignals>;
  groupStates: Map<string, ExecutionGraphEntityState>;
  groupScopes: Map<string, ExecutionGraphRepoScope>;
  packageScopes: Map<string, ExecutionGraphRepoScope>;
  baseRepo?: string | null;
  baseBranch?: string | null;
  rects: GraphEntityRect[];
  dependencies: VisibleGraphDependency[];
  incoming: Map<string, VisibleGraphDependency[]>;
  routing?: ExecutionGraphRouting;
  width: number;
  height: number;
};
const metrics = {
  desktop: { cardWidth: 268, childCardWidth: 244, cardHeight: 62, scopedCardHeight: 76, groupWidth: 268, xGap: 92, yGap: 20, x: 36, y: 34, groupHeader: 62, groupPadding: 12, childGap: 8 },
  mobile: { cardWidth: 256, childCardWidth: 232, cardHeight: 62, scopedCardHeight: 76, groupWidth: 256, xGap: 0, yGap: 44, x: 16, y: 24, groupHeader: 62, groupPadding: 12, childGap: 8 },
} as const;
export function graphCardSize(orientation: GraphOrientation) {
  const value = metrics[orientation];
  return { width: value.cardWidth, height: value.cardHeight, xGap: value.xGap, yGap: value.yGap };
}
export function graphGroupHeaderSize(orientation: GraphOrientation) { return metrics[orientation].groupHeader; }
export function defaultExpandedGroupIds(graph: WorkRequestExecutionGraphModel) {
  const context = graphContext(graph);
  return new Set(
    [...context.groups.values()]
      .filter((group) => context.groupStates.get(group.id)?.tone !== "complete")
      .map((group) => group.id),
  );
}
export function buildExecutionGraphLayout(graph: WorkRequestExecutionGraphModel, orientation: GraphOrientation, expandedGroupIds = defaultExpandedGroupIds(graph), renderedGroupIds = expandedGroupIds): ExecutionGraphLayoutModel {
  const context = graphContext(graph);
  const rootKeys = rootEntityKeys(context);
  const rootDependencies = projectedRootDependencies(graphDependencies(graph), context);
  const order = topologicalEntityOrder(rootKeys, rootDependencies, context);
  const depths = entityDepths(order, rootDependencies);
  const rankedOrder = orderWithinRanks(order, depths, rootDependencies);
  const sizes = new Map(rankedOrder.map((key) => [key, entitySize(key, orientation, expandedGroupIds, context)]));
  const rootLayout = layoutRootEntities(rankedOrder, depths, sizes, orientation, metrics[orientation]);
  const rootRects = rootLayout.rects.map((rect) => ({
    ...rect,
    expanded: rect.kind === "group" && expandedGroupIds.has(rect.id),
  }));
  const visibleRects = rootRects.flatMap((rect) => [rect, ...layoutExpandedChildren(rect, orientation, expandedGroupIds, context)]);
  const rects = rootRects.flatMap((rect) => [rect, ...layoutExpandedChildren(rect, orientation, renderedGroupIds, context, expandedGroupIds)]);
  const rectByKey = new Map(visibleRects.map((rect) => [rect.key, rect]));
  const dependencies = visibleDependencies(graphDependencies(graph), rectByKey, context);
  const incoming = groupBy(dependencies, (dependency) => dependency.target_key);
  const edge = Math.max(0, ...visibleRects.map((rect) => rect.x + rect.width));
  const bottom = Math.max(0, ...visibleRects.map((rect) => rect.y + rect.height));

  return {
    groups: context.groups,
    refs: context.refs,
    signals: context.signals,
    groupStates: context.groupStates,
    groupScopes: context.groupScopes,
    packageScopes: context.packageScopes,
    baseRepo: graph.base_repo,
    baseBranch: graph.base_branch,
    rects,
    dependencies,
    incoming,
    routing: rootLayout.routing,
    width: Math.ceil(rootLayout.routing
      ? rootLayout.routing.contentRight + Math.max(84, dependencies.length * 8 + 36)
      : edge + (orientation === "mobile" ? 16 : 28)),
    height: Math.ceil(bottom + 28),
  };
}
export function dependencyProgress(model: ExecutionGraphLayoutModel, targetKey: string) {
  const incoming = model.incoming.get(targetKey) ?? [];
  return { satisfied: incoming.filter((dependency) => dependency.state === "satisfied").length, required: incoming.length };
}
export function workPackageIsFinished(ref?: ExecutionGraphWorkPackageRef, signal?: ExecutionGraphWorkPackageSignals) {
  const operational = signal?.operational_state ?? ref?.operational_state;
  return [signal?.raw_status, ref?.raw_status, ref?.status, operational?.key].some(isFinishedBoardStatus);
}
function graphContext(graph: WorkRequestExecutionGraphModel) {
  const groups = new Map((graph.groups ?? []).map((group) => [group.id, group]));
  const refs = new Map(graph.work_packages.map((item) => [item.id, item]));
  const signals = new Map(graph.work_packages.map((item) => [item.id, item]));
  const childGroups = groupBy([...groups.values()].filter((group) => group.parent_group_id), (group) => group.parent_group_id as string);
  const directPackages = groupBy(graph.work_packages.filter((item) => item.group_id), (item) => item.group_id as string);
  const groupMembers = new Map<string, string[]>();
  const members = (groupId: string, seen = new Set<string>()): string[] => {
    if (groupMembers.has(groupId)) return groupMembers.get(groupId) ?? [];
    if (seen.has(groupId)) return [];
    const nextSeen = new Set(seen).add(groupId);
    const ids = [
      ...(directPackages.get(groupId) ?? []).map((item) => item.id),
      ...(childGroups.get(groupId) ?? []).flatMap((group) => members(group.id, nextSeen)),
    ];
    const result = [...new Set(ids)];
    groupMembers.set(groupId, result);
    return result;
  };
  groups.forEach((_group, id) => members(id));
  const groupStates = new Map([...groups].map(([id]) => [id, groupState(groupMembers.get(id) ?? [], refs, signals)]));
  const groupScopes = new Map(
    [...groups]
      .map(([id]) => [id, sharedExternalScope(groupMembers.get(id) ?? [], refs, graph)] as const)
      .filter((entry): entry is readonly [string, ExecutionGraphRepoScope] => Boolean(entry[1])),
  );
  const packageScopes = new Map(
    [...refs]
      .map(([id, ref]) => [id, visiblePackageScope(ref, groupScopes, groups, graph)] as const)
      .filter((entry): entry is readonly [string, ExecutionGraphRepoScope] => Boolean(entry[1])),
  );

  return { groups, refs, signals, childGroups, directPackages, groupMembers, groupStates, groupScopes, packageScopes };
}

type GraphContext = ReturnType<typeof graphContext>;

function sharedExternalScope(
  memberIds: string[],
  refs: Map<string, ExecutionGraphWorkPackageRef>,
  graph: WorkRequestExecutionGraphModel,
): ExecutionGraphRepoScope | undefined {
  if (!memberIds.length) return undefined;
  const baseRepo = normalizedRepo(graph.base_repo);
  const scopes = memberIds.map((id) => packageRepoScope(refs.get(id), graph));
  const first = scopes[0];
  if (!first || normalizedRepo(first.repo) === baseRepo) return undefined;
  if (!scopes.every((scope) => scope && normalizedRepo(scope.repo) === normalizedRepo(first.repo) && scope.branch === first.branch)) return undefined;
  return first;
}

function packageRepoScope(ref: ExecutionGraphWorkPackageRef | undefined, graph: WorkRequestExecutionGraphModel): ExecutionGraphRepoScope | undefined {
  const repo = ref?.repo?.trim() || graph.base_repo?.trim();
  if (!repo) return undefined;
  return { repo, branch: ref?.base_branch?.trim() || graph.base_branch?.trim() };
}

function visiblePackageScope(
  ref: ExecutionGraphWorkPackageRef,
  groupScopes: Map<string, ExecutionGraphRepoScope>,
  groups: Map<string, ExecutionGraphGroup>,
  graph: WorkRequestExecutionGraphModel,
) {
  const scope = packageRepoScope(ref, graph);
  if (!scope || normalizedRepo(scope.repo) === normalizedRepo(graph.base_repo)) return undefined;
  let groupId = ref.group_id;
  while (groupId) {
    if (groupScopes.has(groupId)) return undefined;
    groupId = groups.get(groupId)?.parent_group_id;
  }
  return scope;
}

function normalizedRepo(value?: string | null) {
  return value?.trim().replaceAll("\\", "/").replace(/\.git$/i, "").toLowerCase();
}

function groupState(
  memberIds: string[],
  refs: Map<string, ExecutionGraphWorkPackageRef>,
  signals: Map<string, ExecutionGraphWorkPackageSignals>,
): ExecutionGraphEntityState {
  const completed = memberIds.filter((id) => workPackageIsFinished(refs.get(id), signals.get(id))).length;
  const paths = memberIds.map((id) => workPackageEntityState(refs.get(id), signals.get(id)));
  if (memberIds.length > 0 && completed === memberIds.length) return { label: "Complete", tone: "complete", completed, total: memberIds.length };
  if (paths.includes("active")) return { label: "Active", tone: "active", completed, total: memberIds.length };
  if (paths.includes("blocked")) return { label: "Blocked", tone: "blocked", completed, total: memberIds.length };
  if (memberIds.length > 0) return { label: completed > 0 ? "In progress" : "Planned", tone: completed > 0 ? "waiting" : "neutral", completed, total: memberIds.length };
  return { label: "Empty", tone: "neutral", completed: 0, total: 0 };
}

function workPackagePathState(ref?: ExecutionGraphWorkPackageRef, signal?: ExecutionGraphWorkPackageSignals): DependencyPathState { const state = workPackageEntityState(ref, signal); return state === "blocked" ? "waiting" : state; }

function workPackageEntityState(ref?: ExecutionGraphWorkPackageRef, signal?: ExecutionGraphWorkPackageSignals): DependencyPathState {
  if (workPackageIsFinished(ref, signal)) return "satisfied";
  const status = workPackageStatusText(ref, signal);
  if (deliverySignalFailed(signal)) return "blocked";
  if (waitingOnDependencies(signal)) return "waiting";
  if (/block|error|fail/.test(status)) return "blocked";
  if (deliverySignalActive(signal) || /active|implement|review|claim|progress/.test(status)) return "active";
  return "waiting";
}

function workPackageStatusText(ref?: ExecutionGraphWorkPackageRef, signal?: ExecutionGraphWorkPackageSignals) {
  return [signal?.raw_status, ref?.raw_status, ref?.status, ref?.operational_state?.key].filter(Boolean).join(" ").toLowerCase();
}

function deliverySignalFailed(signal?: ExecutionGraphWorkPackageSignals) {
  return signal?.review_signal?.status === "failed" || signal?.pr_signal?.checks?.status === "failing";
}

function waitingOnDependencies(signal?: ExecutionGraphWorkPackageSignals) {
  const dependency = signal?.dependency_signal;
  return Boolean(dependency && dependency.required > dependency.satisfied);
}

function deliverySignalActive(signal?: ExecutionGraphWorkPackageSignals) {
  return signal?.worker_signal?.status === "active" || signal?.review_signal?.status === "in_progress";
}

function graphDependencies(graph: WorkRequestExecutionGraphModel): ExecutionGraphDependencyIntent[] {
  if (graph.dependency_intents?.length) return graph.dependency_intents;
  return (graph.effective_edges ?? []).map((edge, index) => ({
    id: edge.dependency_ids?.join(":") || `effective:${index}`,
    prerequisite: { kind: "work_package", id: edge.prerequisite_work_package_id },
    dependent: { kind: "work_package", id: edge.dependent_work_package_id },
  }));
}

function rootEntityKeys(context: GraphContext) {
  return [
    ...[...context.groups.values()].filter((group) => !group.parent_group_id).map((group) => groupKey(group.id)),
    ...[...context.refs.values()].filter((ref) => !ref.group_id).map((ref) => packageKey(ref.id)),
  ];
}

function projectedRootDependencies(intents: ExecutionGraphDependencyIntent[], context: GraphContext) {
  const keys = new Set<string>();
  return intents.flatMap((intent) => {
    const source = rootKey(intent.prerequisite, context);
    const target = rootKey(intent.dependent, context);
    const key = `${source}:${target}`;
    if (!source || !target || source === target || keys.has(key)) return [];
    keys.add(key);
    return [{ source, target }];
  });
}

function topologicalEntityOrder(
  keys: string[],
  dependencies: Array<{ source: string; target: string }>,
  context: GraphContext,
) {
  const incoming = new Map(keys.map((key) => [key, 0]));
  const predecessors = groupBy(dependencies, (dependency) => dependency.target);
  const outgoing = groupBy(dependencies, (dependency) => dependency.source);
  const placed = new Map<string, number>();
  // ponytail: greedy parent affinity keeps connected work nearby; use a global crossing optimizer only if measured fixtures outgrow it.
  const compareReady = (left: string, right: string) => {
    const affinity = (key: string) => (predecessors.get(key) ?? [])
      .map((dependency) => placed.get(dependency.source))
      .filter((value): value is number => value != null);
    const leftParents = affinity(left);
    const rightParents = affinity(right);
    return (Math.max(-1, ...rightParents) - Math.max(-1, ...leftParents))
      || (rightParents.length - leftParents.length)
      || compareEntityKeys(left, right, context);
  };
  dependencies.forEach((dependency) => incoming.set(dependency.target, (incoming.get(dependency.target) ?? 0) + 1));
  const ready = keys.filter((key) => (incoming.get(key) ?? 0) === 0).sort(compareReady);
  const order: string[] = [];
  while (ready.length) {
    const key = ready.shift() as string;
    order.push(key);
    placed.set(key, order.length - 1);
    for (const dependency of outgoing.get(key) ?? []) {
      const next = (incoming.get(dependency.target) ?? 0) - 1;
      incoming.set(dependency.target, next);
      if (next === 0) {
        ready.push(dependency.target);
        ready.sort(compareReady);
      }
    }
  }
  return order.length === keys.length ? order : keys.toSorted((left, right) => compareEntityKeys(left, right, context));
}

function entityDepths(order: string[], dependencies: Array<{ source: string; target: string }>) {
  const incoming = groupBy(dependencies, (dependency) => dependency.target);
  const depths = new Map(order.map((key) => [key, 0]));
  const visited = new Set<string>();
  for (const key of order) {
    const sourceDepths = (incoming.get(key) ?? [])
      .filter((dependency) => visited.has(dependency.source))
      .map((dependency) => depths.get(dependency.source) ?? 0);
    depths.set(key, sourceDepths.length ? Math.max(...sourceDepths) + 1 : 0);
    visited.add(key);
  }
  return depths;
}

function entitySize(
  key: string,
  orientation: GraphOrientation,
  expandedGroupIds: Set<string>,
  context: GraphContext,
  seen = new Set<string>(),
): { width: number; height: number } {
  const value = metrics[orientation];
  if (!key.startsWith("group:")) {
    const id = key.slice("work_package:".length);
    const width = context.refs.get(id)?.group_id ? value.childCardWidth : value.cardWidth;
    return { width, height: context.packageScopes.has(id) ? value.scopedCardHeight : value.cardHeight };
  }
  const groupId = key.slice("group:".length);
  if (!expandedGroupIds.has(groupId) || seen.has(groupId)) return { width: value.cardWidth, height: value.cardHeight };
  const nextSeen = new Set(seen).add(groupId);
  const children = directChildKeys(groupId, context);
  const childSizes = children.map((child) => entitySize(child, orientation, expandedGroupIds, context, nextSeen));
  const childHeight = childSizes.reduce((sum, child) => sum + child.height, 0) + Math.max(0, childSizes.length - 1) * value.childGap;
  return {
    width: Math.max(value.groupWidth, ...childSizes.map((child) => child.width + value.groupPadding * 2)),
    height: value.groupHeader + value.groupPadding * 2 + childHeight,
  };
}

function layoutExpandedChildren(
  parent: GraphEntityRect,
  orientation: GraphOrientation,
  renderedGroupIds: Set<string>,
  context: GraphContext,
  expandedGroupIds = renderedGroupIds,
): GraphEntityRect[] {
  if (parent.kind !== "group" || !renderedGroupIds.has(parent.id)) return [];
  const value = metrics[orientation];
  let y = parent.y + value.groupHeader + value.groupPadding;
  return directChildKeys(parent.id, context).flatMap((key, index) => {
    const size = entitySize(key, orientation, expandedGroupIds, context);
    const rect = entityRect(
      key,
      parent.x + value.groupPadding,
      y,
      size,
      parent.depth,
      index,
      parent.row,
      parent.column,
      parent.id,
      key.startsWith("group:") && expandedGroupIds.has(key.slice("group:".length)),
    );
    y += size.height + value.childGap;
    return [rect, ...layoutExpandedChildren(rect, orientation, renderedGroupIds, context, expandedGroupIds)];
  });
}

function visibleDependencies(
  intents: ExecutionGraphDependencyIntent[],
  rects: Map<string, GraphEntityRect>,
  context: GraphContext,
) {
  const grouped = new Map<string, {
    source: string;
    target: string;
    states: DependencyPathState[];
    ids: string[];
    targetProxies: boolean[];
  }>();
  for (const intent of intents) {
    const source = visibleEndpointKey(intent.prerequisite, rects, context);
    const target = visibleEndpointKey(intent.dependent, rects, context);
    if (!source || !target || source === target) continue;
    const key = `${source}:${target}`;
    const value = grouped.get(key) ?? { source, target, states: [], ids: [], targetProxies: [] };
    value.states.push(endpointPathState(intent.prerequisite, context));
    value.ids.push(intent.id);
    value.targetProxies.push(endpointKey(intent.dependent) !== target);
    grouped.set(key, value);
  }
  return [...grouped].map(([key, value]) => ({
    key,
    source_key: value.source,
    target_key: value.target,
    state: combinedPathState(value.states),
    intent_ids: [...new Set(value.ids)],
    target_is_collapsed_proxy: value.targetProxies.every(Boolean),
  }));
}

function visibleEndpointKey(endpoint: ExecutionGraphDependencyEndpoint, rects: Map<string, GraphEntityRect>, context: GraphContext) {
  const key = endpointKey(endpoint);
  if (rects.has(key)) return key;
  let groupId = endpoint.kind === "group" ? endpoint.id : context.refs.get(endpoint.id)?.group_id;
  const seen = new Set<string>();
  while (groupId && !seen.has(groupId)) {
    seen.add(groupId);
    const candidate = groupKey(groupId);
    if (rects.has(candidate)) return candidate;
    groupId = context.groups.get(groupId)?.parent_group_id;
  }
  return undefined;
}

function endpointPathState(endpoint: ExecutionGraphDependencyEndpoint, context: GraphContext): DependencyPathState {
  if (endpoint.kind === "work_package") return workPackagePathState(context.refs.get(endpoint.id), context.signals.get(endpoint.id));
  const tone = context.groupStates.get(endpoint.id)?.tone;
  if (tone === "complete") return "satisfied";
  if (tone === "active") return "active";
  return "waiting";
}

function combinedPathState(states: DependencyPathState[]): DependencyPathState {
  if (states.length > 0 && states.every((state) => state === "satisfied")) return "satisfied";
  if (states.includes("active")) return "active";
  return "waiting";
}

function rootKey(endpoint: ExecutionGraphDependencyEndpoint, context: GraphContext) {
  if (endpoint.kind === "work_package") {
    const groupId = context.refs.get(endpoint.id)?.group_id;
    return groupId ? groupKey(rootGroupId(groupId, context.groups)) : packageKey(endpoint.id);
  }
  return groupKey(rootGroupId(endpoint.id, context.groups));
}

function rootGroupId(groupId: string, groups: Map<string, ExecutionGraphGroup>) {
  const seen = new Set<string>();
  let current = groupId;
  while (!seen.has(current)) {
    seen.add(current);
    const parent = groups.get(current)?.parent_group_id;
    if (!parent) return current;
    current = parent;
  }
  return groupId;
}

function directChildKeys(groupId: string, context: GraphContext) {
  return [
    ...(context.childGroups.get(groupId) ?? []).sort(compareGroups).map((group) => groupKey(group.id)),
    ...(context.directPackages.get(groupId) ?? []).sort(comparePackages).map((ref) => packageKey(ref.id)),
  ];
}

function compareEntityKeys(left: string, right: string, context: GraphContext) {
  if (left.startsWith("group:") && right.startsWith("group:")) return compareGroups(context.groups.get(left.slice(6)), context.groups.get(right.slice(6)));
  if (left.startsWith("work_package:") && right.startsWith("work_package:")) return comparePackages(context.refs.get(left.slice(13)), context.refs.get(right.slice(13)));
  return left.startsWith("group:") ? -1 : 1;
}

function compareGroups(left?: ExecutionGraphGroup, right?: ExecutionGraphGroup) {
  return (left?.position ?? Number.MAX_SAFE_INTEGER) - (right?.position ?? Number.MAX_SAFE_INTEGER) || (left?.id ?? "").localeCompare(right?.id ?? "");
}

function comparePackages(left?: ExecutionGraphWorkPackageRef, right?: ExecutionGraphWorkPackageRef) {
  return (left?.sequence ?? Number.MAX_SAFE_INTEGER) - (right?.sequence ?? Number.MAX_SAFE_INTEGER) || (left?.id ?? "").localeCompare(right?.id ?? "");
}

function endpointKey(endpoint: ExecutionGraphDependencyEndpoint) {
  return endpoint.kind === "group" ? groupKey(endpoint.id) : packageKey(endpoint.id);
}

function groupKey(id: string) {
  return `group:${id}`;
}

function packageKey(id: string) {
  return `work_package:${id}`;
}

function groupBy<T>(items: T[], key: (item: T) => string) {
  const grouped = new Map<string, T[]>();
  for (const item of items) grouped.set(key(item), [...(grouped.get(key(item)) ?? []), item]);
  return grouped;
}
