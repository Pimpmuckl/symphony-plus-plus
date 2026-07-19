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
type AxisPoint = { primary: number; cross: number };
type AxisRect = { start: number; end: number; crossStart: number; crossExtent: number };
type PortBundle = { key: string; state: DependencyPathState; dependencies: VisibleGraphDependency[] };
type RouteCandidate = { dependency: VisibleGraphDependency; start: Point; end: Point; laneBias: number };
type LaneReservation = { primary: number; crossStart: number; crossEnd: number };

const PORT_INSET = 10;
const PORT_PITCH = 12;
const BRANCH_STUB = 16;
const GATE_OFFSET = 22;
const LANE_PITCH = 9;
const LANE_CLEARANCE = 5;

export function graphWireRoutes(model: ExecutionGraphLayoutModel, orientation: GraphOrientation) {
  const rects = new Map(model.rects.map((rect) => [rect.key, rect]));
  const incoming = groupBy(model.dependencies, (dependency) => dependency.target_key);
  const outgoing = groupBy(model.dependencies, (dependency) => dependency.source_key);
  const starts = new Map<string, Point>();
  const sourceBiases = new Map<string, number>();
  const targetBiases = new Map<string, number>();
  const trunks: WirePath[] = [];

  outgoing.forEach((dependencies, sourceKey) => {
    const source = rects.get(sourceKey);
    if (!source) return;
    dependencies.sort((left, right) => entityCrossCenter(rects.get(left.target_key), orientation) - entityCrossCenter(rects.get(right.target_key), orientation));
    assignSourceLaneBiases(dependencies, source, rects, orientation, sourceBiases);
    const bundles = sourceBundles(dependencies, portCapacity(source, orientation));

    bundles.forEach((bundle, index) => {
      const port = sourcePort(source, orientation, index, bundles.length);
      const branch = bundle.dependencies.length > 1 ? movePrimary(port, orientation, BRANCH_STUB) : port;
      bundle.dependencies.forEach((dependency) => starts.set(dependency.key, branch));
      if (bundle.dependencies.length <= 1) return;
      trunks.push({
        key: `bundle:${sourceKey}:${bundle.key}`,
        edge: bundle.dependencies.map((dependency) => dependency.key).join(" "),
        state: bundle.state,
        path: straightPath(port, branch, orientation),
        intentCount: bundle.dependencies.reduce((sum, dependency) => sum + dependency.intent_ids.length, 0),
        bundle: true,
      });
    });
  });

  const candidates: RouteCandidate[] = [];
  const gates: WireGate[] = [];
  incoming.forEach((dependencies, targetKey) => {
    const target = rects.get(targetKey);
    if (!target) return;
    const visible = dependencies.filter((dependency) => rects.has(dependency.source_key) && starts.has(dependency.key));
    if (!visible.length) return;
    visible.sort((left, right) => entityCrossCenter(rects.get(left.source_key), orientation) - entityCrossCenter(rects.get(right.source_key), orientation));
    assignTargetLaneBiases(visible, target, rects, orientation, targetBiases);
    const forward = visible.some((dependency) => entityPrimaryEnd(rects.get(dependency.source_key), orientation) <= entityPrimaryStart(target, orientation));
    const gate = visible.length > 1 ? buildGate(targetKey, target, visible, forward, orientation) : undefined;
    if (gate) gates.push(gate.value);

    visible.forEach((dependency, index) => {
      candidates.push({
        dependency,
        start: routedStart(starts.get(dependency.key) as Point, rects.get(dependency.source_key) as GraphEntityRect, target, forward, orientation),
        end: gate?.slots[index] ?? targetPort(target, orientation, forward),
        laneBias: targetBiases.get(dependency.key) ?? sourceBiases.get(dependency.key) ?? 0,
      });
    });
  });

  const reservations: LaneReservation[] = [];
  const paths = candidates.map((candidate) => ({
    key: candidate.dependency.key,
    edge: candidate.dependency.key,
    state: candidate.dependency.state,
    path: routedPath(candidate.start, candidate.end, orientation, reservations, candidate.laneBias),
    intentCount: candidate.dependency.intent_ids.length,
    bundle: false,
  }));

  return { paths: [...trunks, ...paths], gates };
}

function assignSourceLaneBiases(
  dependencies: VisibleGraphDependency[],
  source: GraphEntityRect,
  rects: Map<string, GraphEntityRect>,
  orientation: GraphOrientation,
  laneBiases: Map<string, number>,
) {
  const center = entityCrossCenter(source, orientation);
  assignDirectionalBiases(dependencies.filter((dependency) => entityCrossCenter(rects.get(dependency.target_key), orientation) < center), -1, laneBiases);
  assignDirectionalBiases(dependencies.filter((dependency) => entityCrossCenter(rects.get(dependency.target_key), orientation) >= center), 1, laneBiases);
}

function assignTargetLaneBiases(
  dependencies: VisibleGraphDependency[],
  target: GraphEntityRect,
  rects: Map<string, GraphEntityRect>,
  orientation: GraphOrientation,
  laneBiases: Map<string, number>,
) {
  const center = entityCrossCenter(target, orientation);
  assignDirectionalBiases(dependencies.filter((dependency) => entityCrossCenter(rects.get(dependency.source_key), orientation) < center), 1, laneBiases);
  assignDirectionalBiases(dependencies.filter((dependency) => entityCrossCenter(rects.get(dependency.source_key), orientation) >= center), -1, laneBiases);
}

function assignDirectionalBiases(dependencies: VisibleGraphDependency[], direction: number, laneBiases: Map<string, number>) {
  if (dependencies.length <= 1) return;
  dependencies.forEach((dependency, index) => laneBiases.set(dependency.key, direction * ((dependencies.length - 1) / 2 - index)));
}

function sourceBundles(dependencies: VisibleGraphDependency[], capacity: number): PortBundle[] {
  if (dependencies.length <= capacity) {
    return dependencies.map((dependency) => ({ key: dependency.key, state: dependency.state, dependencies: [dependency] }));
  }
  const byState = groupBy(dependencies, (dependency) => dependency.state);
  return stateOrder.flatMap((state) => {
    const members = byState.get(state) ?? [];
    return members.length ? [{ key: state, state, dependencies: members }] : [];
  });
}

function portCapacity(rect: GraphEntityRect, orientation: GraphOrientation) {
  const extent = sourcePortExtent(rect, orientation);
  return Math.max(1, Math.min(5, Math.floor((extent - PORT_INSET * 2) / PORT_PITCH) + 1));
}

function sourcePort(rect: GraphEntityRect, orientation: GraphOrientation, index: number, count: number) {
  const axis = axisRect(rect, orientation);
  return fromAxis({ primary: axis.end, cross: axis.crossStart + edgeSlot(index, count, axis.crossExtent) }, orientation);
}

function targetPort(rect: GraphEntityRect, orientation: GraphOrientation, forward: boolean) {
  const axis = axisRect(rect, orientation);
  return fromAxis({ primary: forward ? axis.start : axis.end, cross: axis.crossStart + axis.crossExtent / 2 }, orientation);
}

function buildGate(
  targetKey: string,
  target: GraphEntityRect,
  dependencies: VisibleGraphDependency[],
  forward: boolean,
  orientation: GraphOrientation,
) {
  const targetAxis = axisRect(target, orientation);
  const primary = (forward ? targetAxis.start : targetAxis.end) + (forward ? -GATE_OFFSET : GATE_OFFSET);
  const center = targetAxis.crossStart + targetAxis.crossExtent / 2;
  const span = (dependencies.length - 1) * PORT_PITCH;
  const slots = dependencies.map((_dependency, index) => fromAxis({ primary, cross: center - span / 2 + index * PORT_PITCH }, orientation));
  const first = toAxis(slots[0], orientation);
  const last = toAxis(slots.at(-1) as Point, orientation);
  const railStart = { primary, cross: first.cross - 4 };
  const railEnd = { primary, cross: last.cross + 4 };
  const targetEntry = { primary: forward ? targetAxis.start : targetAxis.end, cross: center };
  const gateCenter = { primary, cross: center };
  const satisfied = dependencies.filter((dependency) => dependency.state === "satisfied").length;
  const state: DependencyPathState = satisfied === dependencies.length ? "satisfied" : "waiting";
  const label = orientation === "desktop"
    ? { x: primary, y: railStart.cross - 7, anchor: "middle" as const }
    : { x: center, y: primary - 7, anchor: "middle" as const };

  return {
    slots,
    value: {
      key: `gate:${targetKey}`,
      targetKey,
      state,
      path: `${linePath(railStart, railEnd, orientation)} ${linePath(gateCenter, targetEntry, orientation)}`,
      satisfied,
      required: dependencies.length,
      label,
    },
  };
}

function routedStart(start: Point, source: GraphEntityRect, target: GraphEntityRect, targetOnStart: boolean, orientation: GraphOrientation) {
  if (!targetOnStart || entityPrimaryEnd(source, orientation) <= entityPrimaryStart(target, orientation)) return start;
  const axis = toAxis(start, orientation);
  return fromAxis({ ...axis, primary: entityPrimaryStart(source, orientation) }, orientation);
}

function routedPath(start: Point, end: Point, orientation: GraphOrientation, reservations: LaneReservation[], laneBias: number) {
  const from = toAxis(start, orientation);
  const to = toAxis(end, orientation);
  if (Math.abs(from.cross - to.cross) < 1) return straightPath(start, end, orientation);
  const crossStart = Math.min(from.cross, to.cross);
  const crossEnd = Math.max(from.cross, to.cross);
  const track = reserveLane(from.primary, to.primary, to.primary - from.primary, crossStart, crossEnd, reservations, laneBias);
  return `M ${pointValue(start)} ${primaryCommand(orientation)} ${number(track)} ${crossCommand(orientation)} ${number(to.cross)} ${primaryCommand(orientation)} ${number(to.primary)}`;
}

function reserveLane(
  from: number,
  to: number,
  directSpace: number,
  crossStart: number,
  crossEnd: number,
  reservations: LaneReservation[],
  laneBias: number,
) {
  const forward = directSpace > BRANCH_STUB * 2;
  const midpoint = (from + to) / 2;
  for (let lane = 0; lane < 24; lane += 1) {
    const candidate = forward
      ? clamp(midpoint + (laneBias + laneOffset(lane)) * LANE_PITCH, from + BRANCH_STUB, to - BRANCH_STUB)
      : outsideLane(from, to, lane);
    if (laneAvailable(candidate, crossStart, crossEnd, reservations)) {
      reservations.push({ primary: candidate, crossStart, crossEnd });
      return candidate;
    }
  }
  const fallback = outsideLane(from, to, reservations.length);
  reservations.push({ primary: fallback, crossStart, crossEnd });
  return fallback;
}

function outsideLane(from: number, to: number, lane: number) {
  return to < from
    ? Math.min(from, to) - GATE_OFFSET - lane * LANE_PITCH
    : Math.max(from, to) + GATE_OFFSET + lane * LANE_PITCH;
}

function laneAvailable(primary: number, crossStart: number, crossEnd: number, reservations: LaneReservation[]) {
  return reservations.every((reserved) => (
    Math.abs(reserved.primary - primary) >= LANE_CLEARANCE
    || crossEnd + LANE_CLEARANCE <= reserved.crossStart
    || crossStart >= reserved.crossEnd + LANE_CLEARANCE
  ));
}

function laneOffset(index: number) {
  if (index === 0) return 0;
  const value = Math.ceil(index / 2);
  return index % 2 ? value : -value;
}

function edgeSlot(index: number, count: number, extent: number) {
  if (count <= 1) return extent / 2;
  const usable = Math.max(0, extent - PORT_INSET * 2);
  const span = Math.min((count - 1) * PORT_PITCH, usable);
  return (extent - span) / 2 + (index * span) / (count - 1);
}

function sourcePortExtent(rect: GraphEntityRect, orientation: GraphOrientation) {
  if (orientation === "mobile") return rect.width;
  return rect.kind === "group" && rect.expanded ? graphGroupHeaderSize(orientation) : rect.height;
}

function axisRect(rect: GraphEntityRect, orientation: GraphOrientation): AxisRect {
  if (orientation === "desktop") return { start: rect.x, end: rect.x + rect.width, crossStart: rect.y, crossExtent: sourcePortExtent(rect, orientation) };
  const primaryExtent = rect.kind === "group" && rect.expanded ? graphGroupHeaderSize(orientation) : rect.height;
  return { start: rect.y, end: rect.y + primaryExtent, crossStart: rect.x, crossExtent: rect.width };
}

function entityPrimaryStart(rect: GraphEntityRect | undefined, orientation: GraphOrientation) {
  return rect ? axisRect(rect, orientation).start : 0;
}

function entityPrimaryEnd(rect: GraphEntityRect | undefined, orientation: GraphOrientation) {
  return rect ? axisRect(rect, orientation).end : 0;
}

function entityCrossCenter(rect: GraphEntityRect | undefined, orientation: GraphOrientation) {
  if (!rect) return 0;
  const axis = axisRect(rect, orientation);
  return axis.crossStart + axis.crossExtent / 2;
}

function movePrimary(point: Point, orientation: GraphOrientation, amount: number) {
  const axis = toAxis(point, orientation);
  return fromAxis({ ...axis, primary: axis.primary + amount }, orientation);
}

function straightPath(start: Point, end: Point, orientation: GraphOrientation) {
  const to = toAxis(end, orientation);
  return `M ${pointValue(start)} ${primaryCommand(orientation)} ${number(to.primary)}`;
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

function primaryCommand(orientation: GraphOrientation) {
  return orientation === "desktop" ? "H" : "V";
}

function crossCommand(orientation: GraphOrientation) {
  return orientation === "desktop" ? "V" : "H";
}

function number(value: number) {
  return Number(value.toFixed(2));
}

function clamp(value: number, min: number, max: number) {
  return Math.min(Math.max(value, min), Math.max(min, max));
}

function groupBy<T>(items: T[], key: (item: T) => string) {
  const grouped = new Map<string, T[]>();
  for (const item of items) grouped.set(key(item), [...(grouped.get(key(item)) ?? []), item]);
  return grouped;
}

const stateOrder: DependencyPathState[] = ["blocked", "active", "waiting", "satisfied"];
