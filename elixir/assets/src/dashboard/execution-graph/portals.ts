import { graphGroupHeaderSize } from "./model";
import type { GraphEntityRect, GraphOrientation } from "./model";

export type Point = { x: number; y: number };

type PortalRouteCandidate = {
  dependency: { key: string };
  source: GraphEntityRect;
  target: GraphEntityRect;
  sourceRoot: GraphEntityRect;
  targetRoot: GraphEntityRect;
  start: Point;
  end: Point;
  kind: string;
  sourceBoundaryIndex?: number;
  sourceBoundaryCount?: number;
  targetBoundaryIndex?: number;
  targetBoundaryCount?: number;
  sourceLaneIndex?: number;
  targetLaneIndex?: number;
  localLaneIndex?: number;
  localLaneCount?: number;
  sourceBoundaryAligned?: boolean;
  targetBoundaryAligned?: boolean;
};

const LOCAL_LANE_PITCH = 8;
export const WIRE_CLEARANCE = 6;

export function assignCandidateSlots<T extends PortalRouteCandidate>(candidates: T[], compare: (left: T, right: T) => number) {
  const values = candidates.map((candidate) => ({ ...candidate }) as T);
  assignBoundarySlots(values, "source", compare);
  assignBoundarySlots(values, "target", compare);

  const lanes = new Map<string, Array<{ candidate: T; role: "local" | "source" | "target" }>>();
  const addLane = (root: GraphEntityRect, candidate: T, role: "local" | "source" | "target") => {
    lanes.set(root.key, [...(lanes.get(root.key) ?? []), { candidate, role }]);
  };
  values.forEach((candidate) => {
    if (candidate.sourceRoot.key === candidate.targetRoot.key) {
      if (["local", "vertical"].includes(candidate.kind)) addLane(candidate.sourceRoot, candidate, "local");
      return;
    }
    if (candidate.source.key !== candidate.sourceRoot.key) addLane(candidate.sourceRoot, candidate, "source");
    if (candidate.target.key !== candidate.targetRoot.key) addLane(candidate.targetRoot, candidate, "target");
  });
  lanes.forEach((members) => {
    const locals = members.filter(({ role }) => role === "local").sort((left, right) => compareRect(left.candidate.source, right.candidate.source) || compare(left.candidate, right.candidate));
    locals.forEach(({ candidate }, index) => {
      candidate.localLaneIndex = index;
      candidate.localLaneCount = locals.length;
    });
    members.filter(({ role }) => role === "source")
      .sort((left, right) => compareRect(left.candidate.source, right.candidate.source) || compare(left.candidate, right.candidate))
      .forEach(({ candidate }, index) => { candidate.sourceLaneIndex = locals.length + index; });
    members.filter(({ role }) => role === "target")
      .sort((left, right) => compareRect(left.candidate.target, right.candidate.target) || compare(left.candidate, right.candidate))
      .forEach(({ candidate }, index) => { candidate.targetLaneIndex = locals.length + index; });
  });
  return values;
}

export function sourceEndpointLeg(candidate: PortalRouteCandidate): Point[] {
  if (candidate.sourceRoot.key === candidate.targetRoot.key || candidate.source.key === candidate.sourceRoot.key) return [candidate.start];
  const portal = sourceBoundaryPortal(candidate);
  const trackX = candidate.start.x + LOCAL_LANE_PITCH + (candidate.sourceLaneIndex ?? 0) * LOCAL_LANE_PITCH;
  return [candidate.start, { x: trackX, y: candidate.start.y }, { x: trackX, y: portal.y }, portal];
}

export function targetEndpointLeg(candidate: PortalRouteCandidate): Point[] {
  if (candidate.sourceRoot.key === candidate.targetRoot.key || candidate.target.key === candidate.targetRoot.key) return [candidate.end];
  const portal = targetBoundaryPortal(candidate);
  const trackX = candidate.end.x - LOCAL_LANE_PITCH - (candidate.targetLaneIndex ?? 0) * LOCAL_LANE_PITCH;
  return [portal, { x: trackX, y: portal.y }, { x: trackX, y: candidate.end.y }, candidate.end];
}

export function outerStart(candidate: PortalRouteCandidate) {
  return sourceEndpointLeg(candidate).at(-1) as Point;
}

export function outerEnd(candidate: PortalRouteCandidate) {
  return targetEndpointLeg(candidate)[0];
}

export function localLane(root: GraphEntityRect, index = 0) {
  return root.y + root.height - 12 - index * LOCAL_LANE_PITCH;
}

export function localBottomPoints(candidate: PortalRouteCandidate) {
  const laneY = localLane(candidate.sourceRoot, candidate.localLaneIndex);
  const reversedIndex = (candidate.localLaneCount ?? 1) - (candidate.localLaneIndex ?? 0) - 1;
  const sourceX = candidate.source.key === candidate.sourceRoot.key
    ? candidate.sourceRoot.x + candidate.sourceRoot.width - 12 - reversedIndex * LOCAL_LANE_PITCH
    : candidate.start.x + LOCAL_LANE_PITCH + reversedIndex * LOCAL_LANE_PITCH;
  const targetX = candidate.target.key === candidate.targetRoot.key
    ? candidate.targetRoot.x + 12 + reversedIndex * LOCAL_LANE_PITCH
    : candidate.end.x - LOCAL_LANE_PITCH - reversedIndex * LOCAL_LANE_PITCH;
  return [candidate.start, { x: sourceX, y: candidate.start.y }, { x: sourceX, y: laneY }, { x: targetX, y: laneY }, { x: targetX, y: candidate.end.y }, candidate.end];
}

export function localSidePoints(candidate: PortalRouteCandidate) {
  const index = candidate.localLaneIndex ?? 0;
  const reversedIndex = (candidate.localLaneCount ?? 1) - index - 1;
  const sourceX = candidate.start.x + LOCAL_LANE_PITCH + reversedIndex * LOCAL_LANE_PITCH;
  const targetX = candidate.end.x - LOCAL_LANE_PITCH - reversedIndex * LOCAL_LANE_PITCH;
  const turnY = candidate.end.y > candidate.start.y
    ? candidate.source.y + candidate.source.height + WIRE_CLEARANCE / 2
    : candidate.source.y - WIRE_CLEARANCE / 2;
  return [candidate.start, { x: sourceX, y: candidate.start.y }, { x: sourceX, y: turnY }, { x: targetX, y: turnY }, { x: targetX, y: candidate.end.y }, candidate.end];
}

export function sourcePortalApproach(candidate: PortalRouteCandidate, sourceX: number, laneY: number) {
  const leg = sourceEndpointLeg(candidate);
  const start = leg.at(-1) as Point;
  return [...leg, { x: sourceX, y: start.y }, { x: sourceX, y: laneY }];
}

export function targetPortalApproach(candidate: PortalRouteCandidate, targetX: number, targetY: number) {
  const leg = targetEndpointLeg(candidate);
  const end = leg[0];
  return [{ x: targetX, y: targetY }, { x: targetX, y: end.y }, ...leg];
}

export function clearSourceLane(candidate: PortalRouteCandidate, x: number) {
  return candidate.sourceRoot.row === candidate.targetRoot.row && candidate.sourceRoot.x + candidate.sourceRoot.width >= candidate.targetRoot.x
    ? Math.max(x, candidate.targetRoot.x + candidate.targetRoot.width + WIRE_CLEARANCE)
    : x;
}

export function portalRouteKind(source: GraphEntityRect, target: GraphEntityRect, sourceRoot: GraphEntityRect, targetRoot: GraphEntityRect, orientation: GraphOrientation) {
  if (orientation === "mobile") return "direct";
  if (sourceRoot.key !== targetRoot.key) {
    if (sourceRoot.row === targetRoot.row
      && targetRoot.column === sourceRoot.column + 1
      && sourceRoot.x + sourceRoot.width < targetRoot.x) return "direct";
    return "corridor";
  }
  return sameRootRouteKind(source, target);
}

function sameRootRouteKind(source: GraphEntityRect, target: GraphEntityRect) {
  return source.parent_group_id
    && source.parent_group_id === target.parent_group_id
    && target.row === source.row
    && target.column === source.column + 1
    && target.x > source.x
    ? "direct"
    : source.parent_group_id === target.parent_group_id && source.column === target.column && source.y !== target.y
      ? "vertical"
    : "local";
}

function assignBoundarySlots<T extends PortalRouteCandidate>(candidates: T[], side: "source" | "target", compare: (left: T, right: T) => number) {
  const members = candidates.filter((candidate) => candidate.sourceRoot.key !== candidate.targetRoot.key
    && (side === "source" ? candidate.source.key !== candidate.sourceRoot.key : candidate.target.key !== candidate.targetRoot.key));
  groupBy(members, (candidate) => side === "source" ? candidate.sourceRoot.key : candidate.targetRoot.key).forEach((group) => {
    group.sort((left, right) => compareRect(side === "source" ? left.source : left.target, side === "source" ? right.source : right.target) || compare(left, right));
    group.forEach((candidate, index) => {
      if (side === "source") {
        candidate.sourceBoundaryIndex = index;
        candidate.sourceBoundaryCount = group.length;
      } else {
        candidate.targetBoundaryIndex = index;
        candidate.targetBoundaryCount = group.length;
      }
    });
  });
}

function compareRect(left: GraphEntityRect, right: GraphEntityRect) {
  return left.y - right.y || left.x - right.x || left.key.localeCompare(right.key);
}

function sourceBoundaryPortal(candidate: PortalRouteCandidate) {
  return {
    x: candidate.sourceRoot.x + candidate.sourceRoot.width,
    y: candidate.sourceBoundaryAligned
      ? candidate.start.y
      : candidate.sourceRoot.y + graphGroupHeaderSize("desktop") + WIRE_CLEARANCE + (candidate.sourceBoundaryIndex ?? 0) * LOCAL_LANE_PITCH,
  };
}

function targetBoundaryPortal(candidate: PortalRouteCandidate) {
  return {
    x: candidate.targetRoot.x,
    y: candidate.targetBoundaryAligned
      ? candidate.end.y
      : candidate.targetRoot.y + graphGroupHeaderSize("desktop") + WIRE_CLEARANCE + (candidate.targetBoundaryIndex ?? 0) * LOCAL_LANE_PITCH,
  };
}

function groupBy<T>(items: T[], key: (item: T) => string) {
  const grouped = new Map<string, T[]>();
  for (const item of items) grouped.set(key(item), [...(grouped.get(key(item)) ?? []), item]);
  return grouped;
}
