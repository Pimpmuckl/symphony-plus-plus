import type { ExecutionGraphGroup, ExecutionGraphWorkPackageRef, GraphOrientation } from "./model";
import { isForwardAdjacentColumn, orderWithinRanks } from "./layout";

type EntitySize = { width: number; height: number };
type ChildDependency = { source: string; target: string };
type GroupLayoutMetrics = {
  childGap: number;
  childBandGap: number;
  childXGap: number;
  groupHeader: number;
  groupPadding: number;
  groupWidth: number;
};

type GroupLayout = {
  items: GroupChildPlacement[];
  width: number;
  height: number;
  laneCount?: number;
  columnGap?: number;
};

const LOCAL_GUTTER = 16;
const LOCAL_LANE_MARGIN = 16;
const LOCAL_LANE_PITCH = 8;

export type GroupChildPlacement = EntitySize & {
  key: string;
  x: number;
  y: number;
  row: number;
  column: number;
};

export function layoutGroupChildren(
  keys: string[],
  sizeFor: (key: string) => EntitySize,
  dependencies: ChildDependency[],
  parentKey: string,
  orientation: GraphOrientation,
  metrics: GroupLayoutMetrics,
) {
  const sizes = new Map(keys.map((key) => [key, sizeFor(key)]));
  const childKeys = new Set(keys);
  const internal = dependencies.filter(({ source, target }) => source !== target && childKeys.has(source) && childKeys.has(target));
  const linkedKeys = new Set(internal.flatMap(({ source, target }) => [source, target]));
  const depths = orientation === "desktop" && internal.length ? dependencyDepths(keys, internal) : undefined;
  const candidates = [verticalLayout(keys, sizes, metrics)];
  if (depths) {
    const rankedKeys = orderWithinRanks(keys, depths, internal);
    candidates.push(horizontalLayout(rankedKeys, sizes, depths, linkedKeys, 2, metrics));
    candidates.push(horizontalLayout(rankedKeys, sizes, depths, linkedKeys, 3, metrics));
  }
  return candidates
    .map((candidate) => reserveLocalLanes(candidate, dependencies, childKeys, parentKey, orientation))
    .toSorted(compareLayouts)[0];
}

function verticalLayout(keys: string[], sizes: Map<string, EntitySize>, metrics: GroupLayoutMetrics) {
  let y = metrics.groupHeader + metrics.groupPadding;
  const items = keys.map((key, row) => {
    const size = sizes.get(key) as EntitySize;
    const item = { key, x: metrics.groupPadding, y, row, column: 0, ...size };
    y += size.height + metrics.childGap;
    return item;
  });
  const contentWidth = Math.max(0, ...items.map((item) => item.width));
  const contentHeight = items.length ? y - metrics.childGap : metrics.groupHeader + metrics.groupPadding;
  return {
    items,
    width: Math.max(metrics.groupWidth, contentWidth + metrics.groupPadding * 2),
    height: contentHeight + metrics.groupPadding,
  };
}

function horizontalLayout(
  keys: string[],
  sizes: Map<string, EntitySize>,
  depths: Map<string, number>,
  linkedKeys: Set<string>,
  columnsPerBand: number,
  metrics: GroupLayoutMetrics,
) {
  const isolated = keys.filter((key) => !linkedKeys.has(key));
  const bands: string[][][] = [];
  if (isolated.length) {
    bands.push(Array.from({ length: columnsPerBand }, () => []));
    isolated.forEach((key, index) => bands[0][index % columnsPerBand].push(key));
  }
  keys.filter((key) => linkedKeys.has(key)).forEach((key) => {
    const depth = depths.get(key) ?? 0;
    const band = Math.floor(depth / columnsPerBand) + (isolated.length ? 1 : 0);
    bands[band] ??= Array.from({ length: columnsPerBand }, () => []);
    bands[band][depth % columnsPerBand].push(key);
  });
  const columnWidths = new Map<number, number>();
  bands.forEach((band) => band.forEach((members, column) => {
    if (members.length) columnWidths.set(column, Math.max(columnWidths.get(column) ?? 0, ...members.map((key) => (sizes.get(key) as EntitySize).width)));
  }));
  const xByColumn = new Map<number, number>();
  let contentRight = metrics.groupPadding;
  for (const [column, width] of [...columnWidths].sort(([left], [right]) => left - right)) {
    xByColumn.set(column, contentRight);
    contentRight += width + metrics.childXGap;
  }
  const items: GroupChildPlacement[] = [];
  let bandTop = metrics.groupHeader + metrics.groupPadding;
  bands.forEach((band) => {
    let bandHeight = 0;
    for (const column of [...columnWidths.keys()].sort()) {
      const members = band[column] ?? [];
      let y = bandTop;
      members.forEach((key, row) => {
        const size = sizes.get(key) as EntitySize;
        items.push({ key, x: xByColumn.get(column) ?? metrics.groupPadding, y, row, column, ...size });
        y += size.height + metrics.childGap;
      });
      bandHeight = Math.max(bandHeight, members.length ? y - bandTop - metrics.childGap : 0);
    }
    bandTop += bandHeight + metrics.childBandGap;
  });
  return {
    items,
    columnGap: metrics.childXGap,
    width: Math.max(metrics.groupWidth, contentRight - metrics.childXGap + metrics.groupPadding),
    height: bandTop - metrics.childBandGap + metrics.groupPadding,
  };
}

function reserveLocalLanes(layout: GroupLayout, dependencies: ChildDependency[], childKeys: Set<string>, parentKey: string, orientation: GraphOrientation): GroupLayout {
  const placements = new Map(layout.items.map((item) => [item.key, item]));
  const incoming = dependencies.filter(({ source, target }) => source !== parentKey && !childKeys.has(source) && childKeys.has(target)).length;
  const outgoing = dependencies.filter(({ source, target }) => target !== parentKey && childKeys.has(source) && !childKeys.has(target)).length;
  const local = dependencies.filter(({ source, target }) => {
    if (source === parentKey && childKeys.has(target)) return true;
    if (childKeys.has(source) && target === parentKey) return true;
    if (!childKeys.has(source) || !childKeys.has(target)) return false;
    const from = placements.get(source);
    const to = placements.get(target);
    return !from || !to || !isForwardAdjacentColumn(from, to);
  });
  const directTrackCounts = new Map<string, number>();
  dependencies.forEach(({ source, target }) => {
    const from = placements.get(source);
    const to = placements.get(target);
    if (!from || !to || !isForwardAdjacentColumn(from, to)) return;
    for (const key of [`source:${source}`, `target:${target}`]) {
      directTrackCounts.set(key, (directTrackCounts.get(key) ?? 0) + 1);
    }
  });
  const laneCount = local.length;
  const usesBottomLanes = local.some(({ source, target }) => placements.get(source)?.column !== placements.get(target)?.column);
  const leftTracks = incoming + laneCount;
  const rightTracks = outgoing + laneCount;
  const leftGutter = leftTracks ? LOCAL_GUTTER + leftTracks * LOCAL_LANE_PITCH : 0;
  const rightGutter = rightTracks ? LOCAL_GUTTER + rightTracks * LOCAL_LANE_PITCH : 0;
  const innerTracks = Math.max(leftTracks, rightTracks);
  const directTracks = Math.max(0, ...directTrackCounts.values());
  const gapExtra = layout.columnGap === undefined ? 0 : Math.max(innerTracks, directTracks - 1) * LOCAL_LANE_PITCH;
  const maxColumn = Math.max(0, ...layout.items.map(({ column }) => column));
  const topGutter = orientation === "desktop" ? Math.max(incoming, outgoing) * LOCAL_LANE_PITCH : 0;
  if (!laneCount && !leftGutter && !rightGutter && !gapExtra) return { ...layout, laneCount };
  return {
    ...layout,
    items: layout.items.map((item) => ({ ...item, x: item.x + leftGutter + item.column * gapExtra, y: item.y + topGutter })),
    laneCount,
    width: layout.width + leftGutter + rightGutter + maxColumn * gapExtra,
    height: layout.height + topGutter + (usesBottomLanes && laneCount ? LOCAL_LANE_MARGIN + laneCount * LOCAL_LANE_PITCH : 0),
  };
}

export function projectGroupDependencies(
  groupId: string,
  dependencies: ChildDependency[],
  groups: Map<string, ExecutionGraphGroup>,
  refs: Map<string, ExecutionGraphWorkPackageRef>,
  expandedGroupIds: Set<string>,
) {
  const projected = dependencies.map(({ source, target }) => ({
    source: directChildKey(groupId, source, groups, refs),
    target: directChildKey(groupId, target, groups, refs),
  }));
  const seen = new Set<string>();
  return projected.filter((dependency) => {
    if ([dependency.source, dependency.target].some((key) => key.startsWith("group:") && expandedGroupIds.has(key.slice(6)))) return true;
    const key = JSON.stringify(dependency);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function directChildKey(
  groupId: string,
  key: string,
  groups: Map<string, ExecutionGraphGroup>,
  refs: Map<string, ExecutionGraphWorkPackageRef>,
) {
  if (key === `group:${groupId}`) return key;
  const packageId = key.startsWith("work_package:") ? key.slice("work_package:".length) : undefined;
  let current = packageId ? refs.get(packageId)?.group_id : key.startsWith("group:") ? key.slice("group:".length) : undefined;
  if (current === groupId) return key;
  const seen = new Set<string>();
  while (current && !seen.has(current)) {
    seen.add(current);
    const parent = groups.get(current)?.parent_group_id;
    if (parent === groupId) return `group:${current}`;
    current = parent;
  }
  return key;
}

function compareLayouts(left: GroupLayout, right: GroupLayout) {
  return (left.laneCount ?? 0) - (right.laneCount ?? 0)
    || left.width * left.height - right.width * right.height
    || left.width - right.width
    || left.height - right.height;
}

function dependencyDepths(keys: string[], dependencies: ChildDependency[]) {
  const depths = new Map<string, number>();
  const pending = new Set(keys);
  while (pending.size) {
    let progressed = false;
    for (const key of keys) {
      if (!pending.has(key)) continue;
      const parents = dependencies.filter(({ target }) => target === key).map(({ source }) => source);
      if (parents.some((parent) => pending.has(parent))) continue;
      depths.set(key, parents.length ? Math.max(...parents.map((parent) => depths.get(parent) ?? 0)) + 1 : 0);
      pending.delete(key);
      progressed = true;
    }
    if (!progressed) return undefined;
  }
  return depths;
}
