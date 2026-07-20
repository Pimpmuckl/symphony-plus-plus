import { graphGroupHeaderSize } from "./model";
import type {
  DependencyPathState,
  ExecutionGraphLayoutModel,
  GraphEntityRect,
  GraphOrientation,
  VisibleGraphDependency,
} from "./model";

export type WirePath = {
  key: string;
  edge: string;
  state: DependencyPathState;
  path: string;
  source?: Point;
  intentIds: string[];
  intentCount: number;
  bundle?: boolean;
};

export type WireGate = {
  key: string;
  targetKey: string;
  state: DependencyPathState;
  path: string;
  satisfied: number;
  required: number;
  label: Point & { anchor: "start" | "middle" | "end" };
};

type Point = { x: number; y: number };
type SourcePort = Point & { index: number; count: number; roofIndex?: number; roofCount?: number };
type AxisPoint = { primary: number; cross: number };
type AxisRect = { start: number; end: number; crossStart: number; crossExtent: number };
type RouteKind = "direct" | "corridor" | "local";
type RouteCandidate = {
  dependency: VisibleGraphDependency;
  source: GraphEntityRect;
  target: GraphEntityRect;
  sourceRoot: GraphEntityRect;
  targetRoot: GraphEntityRect;
  start: SourcePort;
  end: Point;
  kind: RouteKind;
};
type Segment = { x1: number; y1: number; x2: number; y2: number };
type RouteOption = { path: string; segments: Segment[] };

const PORT_INSET = 10;
const MIN_PORT_PITCH = 4;
const BRANCH_STUB = 16;
const GATE_OFFSET = 22;
const LANE_PITCH = 8;
const WIRE_CLEARANCE = 6;

export function graphWireRoutes(model: ExecutionGraphLayoutModel, orientation: GraphOrientation) {
  const rects = new Map(model.rects.map((rect) => [rect.key, rect]));
  const starts = sourcePorts(model.dependencies, rects, orientation);
  const { ends, gates } = targetPorts(model.dependencies, rects, orientation);
  const candidates = model.dependencies.flatMap((dependency) => {
    const source = rects.get(dependency.source_key);
    const target = rects.get(dependency.target_key);
    const start = starts.get(dependency.key);
    const end = ends.get(dependency.key);
    if (!source || !target || !start || !end) return [];
    const sourceRoot = rootRect(source, rects);
    const targetRoot = rootRect(target, rects);
    return [{
      dependency,
      source,
      target,
      sourceRoot,
      targetRoot,
      start,
      end,
      kind: routeKind(sourceRoot, targetRoot, orientation),
    } satisfies RouteCandidate];
  });

  const paths = orientation === "mobile"
    ? mobilePaths(candidates)
    : desktopPaths(candidates, model);

  return { paths, gates };
}

function desktopPaths(candidates: RouteCandidate[], model: ExecutionGraphLayoutModel): WirePath[] {
  const planned = new Map<string, RouteOption>();
  const reserved: Segment[] = [];
  const ordered = planningOrder(candidates);
  const plans = ordered.map((candidate) => ({
    candidate,
    obstacles: model.rects.filter((rect) => !rect.parent_group_id && ![candidate.sourceRoot.key, candidate.targetRoot.key].includes(rect.key)),
    options: routeOptions(candidate, model),
  }));

  for (const { candidate, obstacles, options } of plans) {
    const best = bestRoute(options, reserved, obstacles);
    planned.set(candidate.dependency.key, best);
    reserved.push(...best.segments);
  }

  for (let pass = 0; pass < 3; pass += 1) {
    let changed = false;
    for (const { candidate, obstacles, options } of [...plans].reverse()) {
      const key = candidate.dependency.key;
      const current = planned.get(key) as RouteOption;
      const others = [...planned].filter(([otherKey]) => otherKey !== key).flatMap(([, route]) => route.segments);
      const currentScore = routeScore(current, others, obstacles);
      if (currentScore < 1_000_000) continue;
      const best = bestRoute(options, others, obstacles);
      if (routeScore(best, others, obstacles) >= currentScore) continue;
      planned.set(key, best);
      changed = true;
    }
    if (!changed) break;
  }

  return candidates.map((candidate) => wirePath(candidate, (planned.get(candidate.dependency.key) as RouteOption).path));
}

function bestRoute(options: RouteOption[], reserved: Segment[], obstacles: GraphEntityRect[]) {
  let best = options[0];
  let score = routeScore(best, reserved, obstacles);
  for (const option of options.slice(1)) {
    const next = routeScore(option, reserved, obstacles);
    if (next >= score) continue;
    best = option;
    score = next;
  }
  return best;
}

function mobilePaths(candidates: RouteCandidate[]) {
  const reservations: Array<{ track: number; start: number; end: number }> = [];
  return candidates.map((candidate) => {
    const from = toAxis(candidate.start, "mobile");
    const to = toAxis(candidate.end, "mobile");
    const low = Math.min(from.cross, to.cross);
    const high = Math.max(from.cross, to.cross);
    const midpoint = (from.primary + to.primary) / 2;
    let track = midpoint;
    for (let lane = 0; lane < 24; lane += 1) {
      const option = midpoint + alternatingOffset(lane) * LANE_PITCH;
      if (reservations.every((item) => Math.abs(item.track - option) >= 5 || high + 5 <= item.start || low >= item.end + 5)) {
        track = option;
        break;
      }
    }
    reservations.push({ track, start: low, end: high });
    return wirePath(candidate, orthogonalPath(candidate.start, track, to, "mobile"));
  });
}

function routeOptions(candidate: RouteCandidate, model: ExecutionGraphLayoutModel) {
  const routing = model.routing;
  if (candidate.kind === "direct") return directOptions(candidate, routing);
  if (!routing) return [routeFromPoints([candidate.start, candidate.end])];

  const sourceXs = sourceLaneOptions(candidate, routing);
  const targetXs = targetLaneOptions(candidate, model);
  const targetYs = candidate.kind === "local"
    ? spread(candidate.sourceRoot.y + candidate.sourceRoot.height + 16, candidate.sourceRoot.y + candidate.sourceRoot.height + 28, 3)
    : [
        ...lowerBandLaneOptions(candidate, model),
        ...bandLaneOptions(candidate.targetRoot.row, model, "target"),
      ];
  const crossBand = candidate.sourceRoot.row !== candidate.targetRoot.row;
  if (!crossBand) return sameBandOptions(candidate, sourceXs, targetYs, targetXs);
  return crossBandOptions(candidate, model, sourceXs, targetYs, targetXs);
}

function sameBandOptions(candidate: RouteCandidate, sourceXs: number[], targetYs: number[], targetXs: number[]) {
  return sourceXs.flatMap((sourceX) => targetYs.flatMap((targetY) => targetXs.map((targetX) => (
    routeFromPoints([candidate.start, { x: sourceX, y: candidate.start.y }, { x: sourceX, y: targetY }, { x: targetX, y: targetY }, { x: targetX, y: candidate.end.y }, candidate.end])
  ))));
}

function crossBandOptions(candidate: RouteCandidate, model: ExecutionGraphLayoutModel, sourceXs: number[], targetYs: number[], targetXs: number[]) {
  const routing = model.routing as NonNullable<ExecutionGraphLayoutModel["routing"]>;
  const busXs = spread(routing.contentRight + 20, model.width - 20, 6);
  if (candidate.sourceRoot.column >= 2) {
    return busXs.flatMap((busX) => targetYs.flatMap((targetY) => targetXs.map((targetX) => (
      routeFromPoints([candidate.start, { x: busX, y: candidate.start.y }, { x: busX, y: targetY }, { x: targetX, y: targetY }, { x: targetX, y: candidate.end.y }, candidate.end])
    ))));
  }
  const sourceYs = sourceBandLaneOptions(candidate, model);
  return sourceXs.flatMap((sourceX) => sourceYs.flatMap((sourceY) => busXs.flatMap((busX) => targetYs.flatMap((targetY) => targetXs.map((targetX) => (
    routeFromPoints([candidate.start, { x: sourceX, y: candidate.start.y }, { x: sourceX, y: sourceY }, { x: busX, y: sourceY }, { x: busX, y: targetY }, { x: targetX, y: targetY }, { x: targetX, y: candidate.end.y }, candidate.end])
  ))))));
}

function directOptions(candidate: RouteCandidate, routing?: ExecutionGraphLayoutModel["routing"]) {
  if (Math.abs(candidate.start.y - candidate.end.y) < 1) return [routeFromPoints([candidate.start, candidate.end])];
  const laneIndex = candidate.end.y > candidate.start.y
    ? candidate.start.count - candidate.start.index - 1
    : candidate.start.index;
  const fanoutLane = routing && sourceFanoutLane(candidate, routing, laneIndex);
  const tracks = fanoutLane === undefined
    ? spread(candidate.start.x + BRANCH_STUB, candidate.end.x - BRANCH_STUB, 8)
    : [fanoutLane];
  return tracks
    .map((track) => routeFromPoints([candidate.start, { x: track, y: candidate.start.y }, { x: track, y: candidate.end.y }, candidate.end]));
}

function sourceLaneOptions(candidate: RouteCandidate, routing: NonNullable<ExecutionGraphLayoutModel["routing"]>) {
  const fanoutLane = sourceFanoutLane(candidate, routing);
  if (fanoutLane !== undefined) return [fanoutLane];
  if (candidate.kind === "local") return spread(candidate.sourceRoot.x + candidate.sourceRoot.width + 8, candidate.sourceRoot.x + candidate.sourceRoot.width + 18, 3);
  if (candidate.sourceRoot.column < 2) {
    const right = candidate.sourceRoot.x + candidate.sourceRoot.width;
    const gutter = routing.columnGutters.get(candidate.sourceRoot.column) ?? right + 28;
    return spread(right + 5, Math.max(right + 12, gutter - 6), 8);
  }
  return [routing.contentRight + 20];
}

function targetLaneOptions(candidate: RouteCandidate, model: ExecutionGraphLayoutModel) {
  const previousRight = candidate.targetRoot.column === 0
    ? 8
    : Math.max(...model.rects.filter((rect) => !rect.parent_group_id && rect.row === candidate.targetRoot.row && rect.column === candidate.targetRoot.column - 1).map((rect) => rect.x + rect.width), 8) + 8;
  const lanes = spread(previousRight, candidate.end.x - BRANCH_STUB, 6);
  return candidate.kind === "local" ? lanes.reverse() : lanes;
}

function sourceFanoutLane(candidate: RouteCandidate, routing: NonNullable<ExecutionGraphLayoutModel["routing"]>, laneIndex = candidate.start.index) {
  if (candidate.start.count <= 1) return undefined;
  const right = candidate.sourceRoot.x + candidate.sourceRoot.width;
  const max = candidate.sourceRoot.column < 2
    ? (routing.columnGutters.get(candidate.sourceRoot.column) ?? right + BRANCH_STUB + WIRE_CLEARANCE) - WIRE_CLEARANCE
    : right + BRANCH_STUB + (candidate.start.count - 1) * WIRE_CLEARANCE;
  const requiredMax = right + BRANCH_STUB + (candidate.start.count - 1) * WIRE_CLEARANCE;
  return spread(right + BRANCH_STUB, Math.max(max, requiredMax), candidate.start.count)[laneIndex];
}

function sourceBandLaneOptions(candidate: RouteCandidate, model: ExecutionGraphLayoutModel) {
  const lanes = bandLaneOptions(candidate.sourceRoot.row, model, "source");
  const count = candidate.start.roofCount || candidate.start.count;
  const index = candidate.start.roofIndex ?? candidate.start.index;
  if (count <= 1) return candidate.start.count > 1 ? [lanes[0]] : lanes;
  const requiredSpan = (count - 1) * WIRE_CLEARANCE;
  const span = Math.max((lanes.at(-1) as number) - lanes[0], requiredSpan);
  const low = Math.max(4, (lanes[0] + (lanes.at(-1) as number) - span) / 2);
  return [spread(low, low + span, count)[index]];
}

function lowerBandLaneOptions(candidate: RouteCandidate, model: ExecutionGraphLayoutModel) {
  if (candidate.kind !== "corridor" || candidate.sourceRoot.row !== candidate.targetRoot.row) return [];
  const bottoms = model.rects
    .filter((rect) => !rect.parent_group_id
      && rect.row === candidate.sourceRoot.row
      && rect.column >= candidate.sourceRoot.column
      && rect.column < candidate.targetRoot.column)
    .map((rect) => rect.y + rect.height);
  const bottom = Math.max(candidate.sourceRoot.y + candidate.sourceRoot.height, ...bottoms);
  return spread(bottom + 16, bottom + 28, 3);
}

function bandLaneOptions(row: number, model: ExecutionGraphLayoutModel, side: "source" | "target") {
  const routing = model.routing as NonNullable<ExecutionGraphLayoutModel["routing"]>;
  const bandTop = Math.min(...model.rects.filter((rect) => !rect.parent_group_id && rect.row === row).map((rect) => rect.y));
  if (row === 0 && side === "source") return spread(bandTop - 28, bandTop - 16, 3);
  const previousBottom = row > 0 ? (routing.bandBottoms.get(row - 1) ?? 0) : 0;
  const low = previousBottom + 12;
  const high = bandTop - 18;
  const middle = (low + high) / 2;
  const range = side === "source" ? [low, middle - 4] : [middle + 4, high];
  const count = Math.max(2, Math.min(6, Math.floor((range[1] - range[0]) / WIRE_CLEARANCE) + 1));
  return spread(range[0], range[1], count);
}

function routeFromPoints(points: Point[]): RouteOption {
  const compact = points.filter((point, index) => index === 0 || point.x !== points[index - 1].x || point.y !== points[index - 1].y);
  const segments = compact.slice(1).map((point, index) => ({ x1: compact[index].x, y1: compact[index].y, x2: point.x, y2: point.y }));
  const path = compact.slice(1).reduce((value, point, index) => (
    `${value} ${point.y === compact[index].y ? "H" : "V"} ${number(point.y === compact[index].y ? point.x : point.y)}`
  ), `M ${pointValue(compact[0])}`);
  return { path, segments };
}

function routeScore(option: RouteOption, reserved: Segment[], obstacles: GraphEntityRect[]) {
  const collision = option.segments.some((segment) => obstacles.some((rect) => segmentIntersectsRect(segment, rect))) ? 1_000_000_000 : 0;
  const self = option.segments.flatMap((segment, index) => option.segments.slice(index + 2).map((other) => segmentConflict(segment, other))).reduce((sum, value) => sum + value, 0);
  const existing = option.segments.flatMap((segment) => reserved.map((other) => segmentConflict(segment, other))).reduce((sum, value) => sum + value, 0);
  const length = option.segments.reduce((sum, segment) => sum + Math.abs(segment.x2 - segment.x1) + Math.abs(segment.y2 - segment.y1), 0);
  return collision + self + existing + length;
}

function segmentConflict(left: Segment, right: Segment) {
  const leftHorizontal = left.y1 === left.y2;
  const rightHorizontal = right.y1 === right.y2;
  if (leftHorizontal === rightHorizontal) return parallelConflict(left, right, leftHorizontal);
  const horizontal = leftHorizontal ? left : right;
  const vertical = leftHorizontal ? right : left;
  return orthogonalConflict(horizontal, vertical);
}

function parallelConflict(left: Segment, right: Segment, horizontal: boolean) {
  const distance = Math.abs((horizontal ? left.y1 : left.x1) - (horizontal ? right.y1 : right.x1));
  const overlap = intervalOverlap(horizontal ? left.x1 : left.y1, horizontal ? left.x2 : left.y2, horizontal ? right.x1 : right.y1, horizontal ? right.x2 : right.y2);
  if (overlap <= 2) return 0;
  if (distance === 0) return 100_000_000 + overlap;
  return distance < WIRE_CLEARANCE ? 1_000_000 : 0;
}

function orthogonalConflict(horizontal: Segment, vertical: Segment) {
  const insideX = between(vertical.x1, horizontal.x1, horizontal.x2);
  const insideY = between(horizontal.y1, vertical.y1, vertical.y2);
  if (insideX && insideY) return 100_000_000;
  const nearX = Math.min(Math.abs(vertical.x1 - horizontal.x1), Math.abs(vertical.x1 - horizontal.x2));
  const nearY = Math.min(Math.abs(horizontal.y1 - vertical.y1), Math.abs(horizontal.y1 - vertical.y2));
  return (insideX && nearY < WIRE_CLEARANCE) || (insideY && nearX < WIRE_CLEARANCE) ? 1_000_000 : 0;
}

function segmentIntersectsRect(segment: Segment, rect: GraphEntityRect) {
  if (segment.x1 === segment.x2) return segment.x1 > rect.x + 2 && segment.x1 < rect.x + rect.width - 2 && intervalOverlap(segment.y1, segment.y2, rect.y + 2, rect.y + rect.height - 2) > 0;
  return segment.y1 > rect.y + 2 && segment.y1 < rect.y + rect.height - 2 && intervalOverlap(segment.x1, segment.x2, rect.x + 2, rect.x + rect.width - 2) > 0;
}

function intervalOverlap(a1: number, a2: number, b1: number, b2: number) {
  return Math.min(Math.max(a1, a2), Math.max(b1, b2)) - Math.max(Math.min(a1, a2), Math.min(b1, b2));
}

function between(value: number, start: number, end: number) {
  return value > Math.min(start, end) && value < Math.max(start, end);
}

function routePriority(candidate: RouteCandidate) {
  if (candidate.kind === "direct") return 0;
  if (candidate.kind === "local") return 1;
  return 2;
}

function wirePath(candidate: RouteCandidate, path: string): WirePath {
  return {
    key: candidate.dependency.key,
    edge: candidate.dependency.key,
    state: candidate.dependency.state,
    path,
    source: candidate.start,
    intentIds: candidate.dependency.intent_ids,
    intentCount: candidate.dependency.intent_ids.length,
    bundle: false,
  };
}

function routeKind(source: GraphEntityRect, target: GraphEntityRect, orientation: GraphOrientation): RouteKind {
  if (orientation === "mobile") return "direct";
  if (source.key === target.key) return "local";
  if (source.row === target.row && target.column === source.column + 1) return "direct";
  return "corridor";
}

function sourcePorts(
  dependencies: VisibleGraphDependency[],
  rects: Map<string, GraphEntityRect>,
  orientation: GraphOrientation,
) {
  const ports = new Map<string, SourcePort>();
  groupBy(dependencies, ({ source_key }) => source_key).forEach((members, sourceKey) => {
    const source = rects.get(sourceKey);
    if (!source) return;
    members.sort((left, right) => portPriority(left, rects, orientation) - portPriority(right, rects, orientation)
      || targetDistance(right, source, rects) - targetDistance(left, source, rects)
      || compareTargetPosition(left, right, rects));
    const sourceRoot = rootRect(source, rects);
    const roofMembers = orientation === "desktop"
      ? members.filter((dependency) => {
          const target = rects.get(dependency.target_key);
          if (!target) return false;
          const targetRoot = rootRect(target, rects);
          return sourceRoot.column < 2 && sourceRoot.row !== targetRoot.row;
        })
      : [];
    const roofIndexes = new Map(roofMembers.map((dependency, index) => [dependency.key, index]));
    members.forEach((dependency, index) => ports.set(dependency.key, {
      ...sourcePort(source, orientation, index, members.length),
      index,
      count: members.length,
      roofIndex: roofIndexes.get(dependency.key),
      roofCount: roofMembers.length,
    }));
  });
  return ports;
}

function targetPorts(
  dependencies: VisibleGraphDependency[],
  rects: Map<string, GraphEntityRect>,
  orientation: GraphOrientation,
) {
  const ends = new Map<string, Point>();
  const gates: WireGate[] = [];
  groupBy(dependencies, ({ target_key }) => target_key).forEach((members, targetKey) => {
    const target = rects.get(targetKey);
    if (!target) return;
    members.sort((left, right) => portPriority(left, rects, orientation) - portPriority(right, rects, orientation) || compareSourcePosition(left, right, rects));
    const gateMembers = members.filter(({ target_is_collapsed_proxy }) => !target_is_collapsed_proxy);
    const gate = gateMembers.length > 1 ? buildGate(targetKey, target, gateMembers, orientation) : undefined;
    if (!gate) {
      members.forEach((dependency, index) => ends.set(dependency.key, targetPort(target, orientation, index, members.length)));
      return;
    }

    gates.push(gate.value);
    gateMembers.forEach((dependency, index) => ends.set(dependency.key, gate.slots[index]));
    const proxyMembers = members.filter(({ target_is_collapsed_proxy }) => target_is_collapsed_proxy);
    proxyMembers.forEach((dependency, index) => ends.set(dependency.key, targetPort(target, orientation, index, proxyMembers.length, true)));
  });
  return { ends, gates };
}

function buildGate(
  targetKey: string,
  target: GraphEntityRect,
  dependencies: VisibleGraphDependency[],
  orientation: GraphOrientation,
) {
  const axis = axisRect(target, orientation);
  const primary = axis.start - GATE_OFFSET;
  const center = axis.crossStart + axis.crossExtent / 2;
  const pitch = Math.max(MIN_PORT_PITCH, Math.min(12, (axis.crossExtent - PORT_INSET * 2) / Math.max(1, dependencies.length - 1)));
  const span = (dependencies.length - 1) * pitch;
  const slots = dependencies.map((_dependency, index) => fromAxis({ primary, cross: center - span / 2 + index * pitch }, orientation));
  const first = toAxis(slots[0], orientation);
  const last = toAxis(slots.at(-1) as Point, orientation);
  const railStart = { primary, cross: first.cross - 4 };
  const railEnd = { primary, cross: last.cross + 4 };
  const gateCenter = { primary, cross: center };
  const targetEntry = { primary: axis.start, cross: center };
  const satisfied = dependencies.filter(({ state }) => state === "satisfied").length;
  const state: DependencyPathState = satisfied === dependencies.length ? "satisfied" : "waiting";

  return {
    slots,
    value: {
      key: `gate:${targetKey}`,
      targetKey,
      state,
      path: `${linePath(railStart, railEnd, orientation)} ${linePath(gateCenter, targetEntry, orientation)}`,
      satisfied,
      required: dependencies.length,
      label: orientation === "desktop"
        ? { x: primary, y: railStart.cross - 7, anchor: "middle" as const }
        : { x: center, y: primary - 7, anchor: "middle" as const },
    },
  };
}

function sourcePort(rect: GraphEntityRect, orientation: GraphOrientation, index: number, count: number) {
  const axis = axisRect(rect, orientation);
  return fromAxis({ primary: axis.end, cross: axis.crossStart + edgeSlot(index, count, axis.crossExtent) }, orientation);
}

function targetPort(rect: GraphEntityRect, orientation: GraphOrientation, index = 0, count = 1, reserveCenter = false) {
  const axis = axisRect(rect, orientation);
  const slotCount = reserveCenter ? count + 1 : count;
  const reservedSlot = Math.floor(slotCount / 2);
  const slotIndex = reserveCenter && index >= reservedSlot ? index + 1 : index;
  return fromAxis({ primary: axis.start, cross: axis.crossStart + edgeSlot(slotIndex, slotCount, axis.crossExtent) }, orientation);
}

function axisRect(rect: GraphEntityRect, orientation: GraphOrientation): AxisRect {
  if (orientation === "desktop") {
    return { start: rect.x, end: rect.x + rect.width, crossStart: rect.y, crossExtent: sourcePortExtent(rect, orientation) };
  }
  const primaryExtent = rect.kind === "group" && rect.expanded ? graphGroupHeaderSize(orientation) : rect.height;
  return { start: rect.y, end: rect.y + primaryExtent, crossStart: rect.x, crossExtent: rect.width };
}

function sourcePortExtent(rect: GraphEntityRect, orientation: GraphOrientation) {
  if (orientation === "mobile") return rect.width;
  return rect.kind === "group" && rect.expanded ? graphGroupHeaderSize(orientation) : rect.height;
}

function edgeSlot(index: number, count: number, extent: number) {
  if (count <= 1) return extent / 2;
  const usable = Math.max(0, extent - PORT_INSET * 2);
  return (extent - usable) / 2 + (index * usable) / (count - 1);
}

function rootRect(rect: GraphEntityRect, rects: Map<string, GraphEntityRect>) {
  let current = rect;
  while (current.parent_group_id) {
    const parent = rects.get(`group:${current.parent_group_id}`);
    if (!parent) break;
    current = parent;
  }
  return current;
}

function compareTargetPosition(left: VisibleGraphDependency, right: VisibleGraphDependency, rects: Map<string, GraphEntityRect>) {
  return compareRects(rects.get(left.target_key), rects.get(right.target_key)) || left.key.localeCompare(right.key);
}

function targetDistance(dependency: VisibleGraphDependency, source: GraphEntityRect, rects: Map<string, GraphEntityRect>) {
  const target = rects.get(dependency.target_key);
  return target ? Math.abs(rootRect(target, rects).row - rootRect(source, rects).row) : 0;
}

function portPriority(dependency: VisibleGraphDependency, rects: Map<string, GraphEntityRect>, orientation: GraphOrientation) {
  const source = rects.get(dependency.source_key);
  const target = rects.get(dependency.target_key);
  if (!source || !target) return 0;
  const sourceRoot = rootRect(source, rects);
  const targetRoot = rootRect(target, rects);
  const kind = routeKind(sourceRoot, targetRoot, orientation);
  if (kind === "corridor" && sourceRoot.row === targetRoot.row && target.y + target.height / 2 > sourceRoot.y + sourceRoot.height) return 2;
  return kind === "corridor" ? 0 : kind === "direct" ? 1 : 2;
}

function compareSourcePosition(left: VisibleGraphDependency, right: VisibleGraphDependency, rects: Map<string, GraphEntityRect>) {
  return compareRects(rects.get(left.source_key), rects.get(right.source_key)) || left.key.localeCompare(right.key);
}

function compareRects(left?: GraphEntityRect, right?: GraphEntityRect) {
  const leftValues = rectPosition(left);
  const rightValues = rectPosition(right);
  for (let index = 0; index < leftValues.length; index += 1) {
    const difference = leftValues[index] - rightValues[index];
    if (difference) return difference;
  }
  return 0;
}

function rectPosition(rect?: GraphEntityRect) {
  return rect ? [rect.row, rect.y, rect.column, rect.x] : [0, 0, 0, 0];
}

function compareCandidates(left: RouteCandidate, right: RouteCandidate) {
  const leftDistance = Math.abs(left.targetRoot.row - left.sourceRoot.row);
  const rightDistance = Math.abs(right.targetRoot.row - right.sourceRoot.row);
  return left.targetRoot.row - right.targetRoot.row
    || leftDistance - rightDistance
    || right.sourceRoot.row - left.sourceRoot.row
    || right.sourceRoot.column - left.sourceRoot.column
    || left.start.y - right.start.y
    || left.end.y - right.end.y
    || left.dependency.key.localeCompare(right.dependency.key);
}

function planningOrder(candidates: RouteCandidate[]) {
  const groups = [...groupBy(candidates, ({ source }) => source.key).values()];
  groups.forEach((members) => members.sort((left, right) => (
    Math.abs(right.end.y - right.start.y) - Math.abs(left.end.y - left.start.y)
    || routePriority(left) - routePriority(right)
    || compareCandidates(left, right)
  )));
  groups.sort((left, right) => (
    right[0].sourceRoot.row - left[0].sourceRoot.row
    || right[0].sourceRoot.column - left[0].sourceRoot.column
    || Math.min(...left.map(routePriority)) - Math.min(...right.map(routePriority))
    || compareCandidates(left[0], right[0])
  ));
  return groups.flat();
}

function spread(min: number, max: number, count: number) {
  if (count <= 0) return [];
  if (count === 1) return [(min + max) / 2];
  const low = Math.min(min, max);
  const high = Math.max(min, max);
  return Array.from({ length: count }, (_value, index) => low + ((high - low) * index) / (count - 1));
}

function alternatingOffset(index: number) {
  if (index === 0) return 0;
  const value = Math.ceil(index / 2);
  return index % 2 ? value : -value;
}

function orthogonalPath(start: Point, track: number, end: AxisPoint, orientation: GraphOrientation) {
  return `M ${pointValue(start)} ${orientation === "desktop" ? "H" : "V"} ${number(track)} ${orientation === "desktop" ? "V" : "H"} ${number(end.cross)} ${orientation === "desktop" ? "H" : "V"} ${number(end.primary)}`;
}

function linePath(start: AxisPoint, end: AxisPoint, orientation: GraphOrientation) {
  return `M ${pointValue(fromAxis(start, orientation))} L ${pointValue(fromAxis(end, orientation))}`;
}

function toAxis(point: Point, orientation: GraphOrientation): AxisPoint {
  return orientation === "desktop" ? { primary: point.x, cross: point.y } : { primary: point.y, cross: point.x };
}

function fromAxis(point: AxisPoint, orientation: GraphOrientation): Point {
  return orientation === "desktop" ? { x: point.primary, y: point.cross } : { x: point.cross, y: point.primary };
}

function pointValue(point: Point) {
  return `${number(point.x)} ${number(point.y)}`;
}

function number(value: number) {
  return Number(value.toFixed(2));
}

function groupBy<T>(items: T[], key: (item: T) => string) {
  const grouped = new Map<string, T[]>();
  for (const item of items) grouped.set(key(item), [...(grouped.get(key(item)) ?? []), item]);
  return grouped;
}
