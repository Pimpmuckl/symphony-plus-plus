export type DependencyPathState = "satisfied" | "active" | "waiting" | "blocked";

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

export type WorkRequestExecutionGraphModel = {
  available?: boolean;
  groups?: ExecutionGraphGroup[];
  work_packages: Array<ExecutionGraphWorkPackageRef & ExecutionGraphWorkPackageSignals>;
  effective_edges?: ExecutionGraphEffectiveEdge[];
  topological_order: string[];
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
    type: string;
    args?: Record<string, unknown>;
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

export type GraphOrientation = "desktop" | "mobile";

export type GraphPoint = {
  id: string;
  x: number;
  y: number;
  depth: number;
  order: number;
};

export type GraphGroupBounds = {
  key: string;
  id: string;
  title: string;
  description?: string | null;
  nestingDepth: number;
  x: number;
  y: number;
  width: number;
  height: number;
};

export type ExecutionGraphLayoutModel = {
  ids: string[];
  refs: Map<string, ExecutionGraphWorkPackageRef>;
  signals: Map<string, ExecutionGraphWorkPackageSignals>;
  incoming: Map<string, ExecutionGraphEffectiveEdge[]>;
  groups: ExecutionGraphGroup[];
  positions: GraphPoint[];
  groupBounds: GraphGroupBounds[];
  width: number;
  height: number;
};

const card = {
  desktop: { width: 264, height: 240, xGap: 96, yGap: 48, x: 56, y: 54 },
  mobile: { width: 272, height: 240, xGap: 0, yGap: 74, x: 32, y: 58 },
} as const;

export function graphCardSize(orientation: GraphOrientation) {
  return card[orientation];
}

export function buildExecutionGraphLayout(
  graph: WorkRequestExecutionGraphModel,
  orientation: GraphOrientation,
): ExecutionGraphLayoutModel {
  const refs = new Map(graph.work_packages.map((item) => [item.id, item]));
  const signals = new Map(graph.work_packages.map((item) => [item.id, item]));
  const ids = orderedIds(graph.topological_order, refs);
  const idSet = new Set(ids);
  const edges = (graph.effective_edges ?? []).filter(
    (edge) => idSet.has(edge.prerequisite_work_package_id) && idSet.has(edge.dependent_work_package_id),
  );
  const incoming = groupBy(edges, (edge) => edge.dependent_work_package_id);
  const depths = dependencyDepths(ids, incoming);
  const positions = layoutPoints(ids, depths, orientation);
  const groups = [...(graph.groups ?? [])].sort(compareGroups);
  const groupBounds = layoutGroupBounds(groups, positions, orientation);
  const size = canvasSize(positions, groupBounds, orientation);

  return { ids, refs, signals, incoming, groups, positions, groupBounds, ...size };
}

export function dependencyState(model: ExecutionGraphLayoutModel, dependentId: string, prerequisiteId: string): DependencyPathState {
  const input = model.signals
    .get(dependentId)
    ?.dependency_signal?.inputs.find((candidate) => candidate.work_package_id === prerequisiteId);

  if (input) return input.status;
  return "waiting";
}

export function dependencyProgress(model: ExecutionGraphLayoutModel, dependentId: string) {
  const incoming = model.incoming.get(dependentId) ?? [];
  const signal = model.signals.get(dependentId)?.dependency_signal;
  const satisfied = signal?.satisfied ?? 0;
  return { satisfied, required: signal?.required ?? incoming.length };
}

function orderedIds(topologicalOrder: string[], refs: Map<string, ExecutionGraphWorkPackageRef>) {
  return [...new Set(topologicalOrder)].filter((id) => refs.has(id));
}

function dependencyDepths(ids: string[], incoming: Map<string, ExecutionGraphEffectiveEdge[]>) {
  const depth = new Map(ids.map((id) => [id, 0]));
  const visited = new Set<string>();

  for (const id of ids) {
    const prerequisiteDepths = (incoming.get(id) ?? [])
      .map((edge) => edge.prerequisite_work_package_id)
      .filter((prerequisiteId) => visited.has(prerequisiteId))
      .map((prerequisiteId) => depth.get(prerequisiteId) ?? 0);
    depth.set(id, prerequisiteDepths.length ? Math.max(...prerequisiteDepths) + 1 : 0);
    visited.add(id);
  }

  return depth;
}

function layoutPoints(ids: string[], depths: Map<string, number>, orientation: GraphOrientation) {
  const metrics = card[orientation];

  if (orientation === "mobile") {
    return ids.map((id, order) => ({ id, x: metrics.x, y: metrics.y + order * (metrics.height + metrics.yGap), depth: depths.get(id) ?? 0, order }));
  }

  const columnCounts = new Map<number, number>();
  return ids.map((id, order) => {
    const depth = depths.get(id) ?? 0;
    const row = columnCounts.get(depth) ?? 0;
    columnCounts.set(depth, row + 1);
    return {
      id,
      x: metrics.x + depth * (metrics.width + metrics.xGap),
      y: metrics.y + row * (metrics.height + metrics.yGap),
      depth,
      order,
    };
  });
}

function layoutGroupBounds(groups: ExecutionGraphGroup[], points: GraphPoint[], orientation: GraphOrientation) {
  const metrics = card[orientation];
  const pointById = new Map(points.map((point) => [point.id, point]));
  const groupById = new Map(groups.map((group) => [group.id, group]));
  const children = groupBy(groups.filter((group) => group.parent_group_id), (group) => group.parent_group_id as string);
  const memo = new Map<string, string[]>();
  const depths = new Map(groups.map((group) => [group.id, nestingDepth(group, groupById)]));
  const maxDepth = Math.max(0, ...depths.values());

  const members = (groupId: string, seen = new Set<string>()): string[] => {
    if (memo.has(groupId)) return memo.get(groupId) ?? [];
    if (seen.has(groupId)) return [];
    const group = groupById.get(groupId);
    if (!group) return [];
    const nextSeen = new Set(seen).add(groupId);
    const ids = [...(group.work_package_ids ?? []), ...(children.get(groupId) ?? []).flatMap((child) => members(child.id, nextSeen))];
    const result = [...new Set(ids)].filter((id) => pointById.has(id));
    memo.set(groupId, result);
    return result;
  };

  return groups.flatMap((group) => {
    const groupPoints = members(group.id).map((id) => pointById.get(id)).filter((point): point is GraphPoint => Boolean(point));
    if (!groupPoints.length) return [];
    const memberIds = new Set(groupPoints.map((point) => point.id));
    const depth = depths.get(group.id) ?? 0;
    const padding = maxDepth ? 18 + Math.round((12 * (maxDepth - depth)) / maxDepth) : 18;
    const runs = memberRuns(points, memberIds, orientation);
    const bounds = mergeSafeBounds(runs.map((run) => pointBounds(run, metrics, padding)), points, memberIds, metrics);
    return bounds.map((bound, index) => ({
      ...bound,
      key: `${group.id}:${index}`,
      id: group.id,
      title: group.title?.trim() || "Untitled group",
      description: group.description,
      nestingDepth: depth,
    }));
  }).sort((left, right) => left.nestingDepth - right.nestingDepth || left.key.localeCompare(right.key));
}

function memberRuns(points: GraphPoint[], memberIds: Set<string>, orientation: GraphOrientation) {
  const lanes = orientation === "mobile" ? [points] : [...groupBy(points, (point) => String(point.depth)).values()];
  return lanes.flatMap((lane) => contiguousRuns([...lane].sort((left, right) => left.y - right.y), memberIds));
}

function contiguousRuns(points: GraphPoint[], memberIds: Set<string>) {
  const runs: GraphPoint[][] = [];
  let current: GraphPoint[] = [];
  for (const point of points) {
    if (memberIds.has(point.id)) current.push(point);
    if (!memberIds.has(point.id) && current.length) {
      runs.push(current);
      current = [];
    }
  }
  if (current.length) runs.push(current);
  return runs;
}

function pointBounds(points: GraphPoint[], metrics: (typeof card)[GraphOrientation], padding: number) {
  const left = Math.min(...points.map((point) => point.x)) - padding;
  const top = Math.min(...points.map((point) => point.y)) - padding - 16;
  const right = Math.max(...points.map((point) => point.x + metrics.width)) + padding;
  const bottom = Math.max(...points.map((point) => point.y + metrics.height)) + padding;
  return { x: left, y: top, width: right - left, height: bottom - top };
}

function mergeSafeBounds(
  bounds: Array<{ x: number; y: number; width: number; height: number }>,
  points: GraphPoint[],
  memberIds: Set<string>,
  metrics: (typeof card)[GraphOrientation],
) {
  const merged: typeof bounds = [];
  for (const bound of bounds.sort((left, right) => left.x - right.x || left.y - right.y)) {
    const previous = merged.at(-1);
    const candidate = previous ? unionBounds(previous, bound) : bound;
    const absorbsOutsider = points.some((point) => !memberIds.has(point.id) && intersects(candidate, point, metrics));
    if (previous && !absorbsOutsider) merged[merged.length - 1] = candidate;
    else merged.push(bound);
  }
  return merged;
}

function unionBounds(left: { x: number; y: number; width: number; height: number }, right: typeof left) {
  const x = Math.min(left.x, right.x);
  const y = Math.min(left.y, right.y);
  const farX = Math.max(left.x + left.width, right.x + right.width);
  const farY = Math.max(left.y + left.height, right.y + right.height);
  return { x, y, width: farX - x, height: farY - y };
}

function intersects(bound: { x: number; y: number; width: number; height: number }, point: GraphPoint, metrics: (typeof card)[GraphOrientation]) {
  return point.x < bound.x + bound.width && point.x + metrics.width > bound.x && point.y < bound.y + bound.height && point.y + metrics.height > bound.y;
}

function nestingDepth(group: ExecutionGraphGroup, groups: Map<string, ExecutionGraphGroup>) {
  let depth = 0;
  let parentId = group.parent_group_id;
  const seen = new Set([group.id]);
  while (parentId && !seen.has(parentId)) {
    seen.add(parentId);
    depth += 1;
    parentId = groups.get(parentId)?.parent_group_id;
  }
  return depth;
}

function canvasSize(points: GraphPoint[], bounds: GraphGroupBounds[], orientation: GraphOrientation) {
  const metrics = card[orientation];
  const right = Math.max(0, ...points.map((point) => point.x + metrics.width), ...bounds.map((bound) => bound.x + bound.width));
  const bottom = Math.max(0, ...points.map((point) => point.y + metrics.height), ...bounds.map((bound) => bound.y + bound.height));
  return { width: Math.ceil(right + (orientation === "mobile" ? 16 : 56)), height: Math.ceil(bottom + 54) };
}

function groupBy<T>(items: T[], key: (item: T) => string) {
  const grouped = new Map<string, T[]>();
  for (const item of items) grouped.set(key(item), [...(grouped.get(key(item)) ?? []), item]);
  return grouped;
}

function compareGroups(left: ExecutionGraphGroup, right: ExecutionGraphGroup) {
  return (left.position ?? Number.MAX_SAFE_INTEGER) - (right.position ?? Number.MAX_SAFE_INTEGER) || left.id.localeCompare(right.id);
}
