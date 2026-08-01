import { graphGroupHeaderSize } from "./model";
import type { ExecutionGraphLayoutModel, GraphEntityRect } from "./model";
import { WIRE_CLEARANCE } from "./portals";
import type { WirePath } from "./router";

export type Segment = { x1: number; y1: number; x2: number; y2: number };
type GeometryIssueKind = "overlap" | "crossing" | "near";

export function auditWireGeometry(model: ExecutionGraphLayoutModel, paths: WirePath[]) {
  const fatal = new Set<string>();
  const soft = new Set<string>();
  paths.forEach((path) => auditPath(model, path, fatal, soft));
  auditRoutePairs(paths, fatal, soft);
  return { fatal: [...fatal].sort(), soft: [...soft].sort() };
}

function auditPath(model: ExecutionGraphLayoutModel, path: WirePath, fatal: Set<string>, soft: Set<string>) {
  const segments = routeSegments(path.path);
  const dependency = model.dependencies.find(({ key }) => key === path.edge);
  const endpointKeys = new Set(dependency
    ? [...endpointLineage(dependency.source_key, model), ...endpointLineage(dependency.target_key, model)]
    : []);
  auditBounds(model, path.edge, segments, fatal);
  auditEndpoints(model, path.edge, dependency, segments, fatal);
  auditSelf(path.edge, segments, fatal, soft);
  auditObstacles(model, path.edge, endpointKeys, segments, fatal);
  auditHeaders(model, path.edge, endpointKeys, segments, fatal);
  auditShape(path.edge, segments, soft);
}

function auditHeaders(model: ExecutionGraphLayoutModel, edge: string, endpointKeys: Set<string>, segments: Segment[], fatal: Set<string>) {
  for (const item of model.visibleRects) {
    if (!item.expanded || !endpointKeys.has(item.key)) continue;
    const header = { ...item, height: graphGroupHeaderSize("desktop") };
    if (segments.some((segment) => segmentIntersectsInterior(segment, header))) fatal.add(`header:${edge}->${item.key}`);
  }
}

function auditBounds(model: ExecutionGraphLayoutModel, edge: string, segments: Segment[], fatal: Set<string>) {
  for (const segment of segments) {
    const outside = Math.min(segment.x1, segment.x2) < 0 || Math.max(segment.x1, segment.x2) > model.width
      || Math.min(segment.y1, segment.y2) < 0 || Math.max(segment.y1, segment.y2) > model.height;
    if (outside) fatal.add(`bounds:${edge}`);
    if (segment.x1 === segment.x2 && segment.y1 === segment.y2) fatal.add(`zero-length:${edge}`);
  }
}

function auditEndpoints(
  model: ExecutionGraphLayoutModel,
  edge: string,
  dependency: ExecutionGraphLayoutModel["dependencies"][number] | undefined,
  segments: Segment[],
  fatal: Set<string>,
) {
  const source = model.visibleRects.find((item) => item.key === dependency?.source_key);
  const target = model.visibleRects.find((item) => item.key === dependency?.target_key);
  if (source && segments.some((segment) => segmentIntersectsInterior(segment, source))) fatal.add(`source-reentry:${edge}`);
  if (target && segments.slice(0, -1).some((segment) => segmentIntersectsInterior(segment, target))) fatal.add(`target-piercing:${edge}`);
}

function auditSelf(edge: string, segments: Segment[], fatal: Set<string>, soft: Set<string>) {
  for (let left = 0; left < segments.length; left += 1) {
    for (let right = left + 2; right < segments.length; right += 1) {
      const kind = segmentIssueKind(segments[left], segments[right]);
      if (kind === "overlap") fatal.add(`self-overlap:${edge}`);
      if (kind === "crossing") soft.add(`self-crossing:${edge}`);
      if (kind === "near") soft.add(`self-near:${edge}`);
    }
  }
}

function auditObstacles(model: ExecutionGraphLayoutModel, edge: string, endpointKeys: Set<string>, segments: Segment[], fatal: Set<string>) {
  for (const item of model.visibleRects) {
    if (endpointKeys.has(item.key)) continue;
    if (segments.some((segment) => segmentIntersectsInterior(segment, item))) fatal.add(`card:${edge}->${item.key}`);
  }
}

function auditShape(edge: string, segments: Segment[], soft: Set<string>) {
  const length = segments.reduce((sum, segment) => sum + Math.abs(segment.x2 - segment.x1) + Math.abs(segment.y2 - segment.y1), 0);
  const first = segments[0], last = segments.at(-1);
  const direct = first && last ? Math.abs(last.x2 - first.x1) + Math.abs(last.y2 - first.y1) : 0;
  const detour = direct ? length / direct : 1;
  const bends = segments.slice(1).filter((segment, index) => isVertical(segments[index]) !== isVertical(segment)).length;
  if (detour > 2.5) soft.add(`detour:${edge}:${detour.toFixed(2)}x`);
  if (bends > 6) soft.add(`bends:${edge}:${bends}`);
}

function auditRoutePairs(paths: WirePath[], fatal: Set<string>, soft: Set<string>) {
  for (let left = 0; left < paths.length; left += 1) {
    for (let right = left + 1; right < paths.length; right += 1) auditRoutePair(paths[left], paths[right], fatal, soft);
  }
}

function auditRoutePair(left: WirePath, right: WirePath, fatal: Set<string>, soft: Set<string>) {
  const pair = `${left.edge}<->${right.edge}`;
  const rightSegments = routeSegments(right.path);
  const kinds = new Set(routeSegments(left.path).flatMap((a) => rightSegments
    .map((b) => segmentIssueKind(a, b)).filter((kind): kind is GeometryIssueKind => Boolean(kind))));
  if (kinds.has("overlap") && !(left.bundle && right.bundle)) fatal.add(`overlap:${pair}`);
  if (kinds.has("crossing")) soft.add(`crossing:${pair}`);
  if (kinds.has("near")) soft.add(`near:${pair}`);
}

function endpointLineage(key: string, model: ExecutionGraphLayoutModel) {
  const keys = [key];
  let item = model.visibleRects.find((candidate) => candidate.key === key);
  while (item?.parent_group_id) {
    const parentKey = `group:${item.parent_group_id}`;
    keys.push(parentKey);
    item = model.visibleRects.find((candidate) => candidate.key === parentKey);
  }
  return keys;
}

export function routeSegments(path: string) {
  const tokens = [...path.matchAll(/([MHV])\s*(-?[\d.]+)(?:\s+(-?[\d.]+))?/g)];
  const segments: Segment[] = [];
  let x = 0, y = 0;
  for (const [, command, first, second] of tokens) {
    const previous = { x, y };
    if (command === "M") [x, y] = [Number(first), Number(second)];
    if (command === "H") x = Number(first);
    if (command === "V") y = Number(first);
    if (command !== "M") segments.push({ x1: previous.x, y1: previous.y, x2: x, y2: y });
  }
  return segments;
}

export function segmentIntersectsInterior(segment: Segment, item: GraphEntityRect) {
  if (isVertical(segment)) {
    return segment.x1 > item.x + 2
      && segment.x1 < item.x + item.width - 2
      && intervalOverlap(segment.y1, segment.y2, item.y + 2, item.y + item.height - 2) > 0;
  }
  return segment.y1 > item.y + 2
    && segment.y1 < item.y + item.height - 2
    && intervalOverlap(segment.x1, segment.x2, item.x + 2, item.x + item.width - 2) > 0;
}

export function routeConflicts(paths: WirePath[]) {
  const conflicts: string[] = [];
  for (let left = 0; left < paths.length; left += 1) {
    for (let right = left + 1; right < paths.length; right += 1) {
      const conflict = routeSegments(paths[left].path).some((a) => routeSegments(paths[right].path).some((b) => Boolean(segmentIssueKind(a, b))));
      if (conflict) conflicts.push(`${paths[left].edge}<->${paths[right].edge}`);
    }
  }
  return conflicts;
}

function segmentIssueKind(left: Segment, right: Segment): GeometryIssueKind | undefined {
  const leftHorizontal = !isVertical(left);
  const rightHorizontal = !isVertical(right);
  if (leftHorizontal === rightHorizontal) return parallelIssueKind(left, right, leftHorizontal);
  return orthogonalIssueKind(leftHorizontal ? left : right, leftHorizontal ? right : left);
}

function parallelIssueKind(left: Segment, right: Segment, horizontal: boolean): GeometryIssueKind | undefined {
  const distance = Math.abs((horizontal ? left.y1 : left.x1) - (horizontal ? right.y1 : right.x1));
  const overlap = intervalOverlap(
    horizontal ? left.x1 : left.y1,
    horizontal ? left.x2 : left.y2,
    horizontal ? right.x1 : right.y1,
    horizontal ? right.x2 : right.y2,
  );
  if (overlap <= 2 || distance >= WIRE_CLEARANCE) return undefined;
  return distance === 0 ? "overlap" : "near";
}

function orthogonalIssueKind(horizontal: Segment, vertical: Segment): GeometryIssueKind | undefined {
  const insideX = within(vertical.x1, horizontal.x1, horizontal.x2);
  const insideY = within(horizontal.y1, vertical.y1, vertical.y2);
  if (insideX && insideY) return "crossing";
  const nearX = Math.min(Math.abs(vertical.x1 - horizontal.x1), Math.abs(vertical.x1 - horizontal.x2));
  const nearY = Math.min(Math.abs(horizontal.y1 - vertical.y1), Math.abs(horizontal.y1 - vertical.y2));
  return (insideX && nearY < WIRE_CLEARANCE) || (insideY && nearX < WIRE_CLEARANCE) ? "near" : undefined;
}

function isVertical(segment: Segment) { return segment.x1 === segment.x2; }
function intervalOverlap(a1: number, a2: number, b1: number, b2: number) { return Math.min(Math.max(a1, a2), Math.max(b1, b2)) - Math.max(Math.min(a1, a2), Math.min(b1, b2)); }
function within(value: number, start: number, end: number) { return value > Math.min(start, end) && value < Math.max(start, end); }
