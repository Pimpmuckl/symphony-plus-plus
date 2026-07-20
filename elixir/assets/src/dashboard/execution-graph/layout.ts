import type { ExecutionGraphRouting, GraphEntityRect, GraphOrientation } from "./model";

type EntitySize = { width: number; height: number };
type LayoutMetrics = {
  cardWidth: number;
  cardHeight: number;
  xGap: number;
  yGap: number;
  x: number;
  y: number;
};

const RANKS_PER_BAND = 3;
const DESKTOP_X = 72;
const DESKTOP_Y = 76;
const BAND_GAP = 112;

export function layoutRootEntities(
  order: string[],
  depths: Map<string, number>,
  sizes: Map<string, EntitySize>,
  orientation: GraphOrientation,
  metrics: LayoutMetrics,
): { rects: GraphEntityRect[]; routing?: ExecutionGraphRouting } {
  if (orientation === "mobile") return { rects: mobileLayout(order, sizes, metrics) };
  if (!order.length) return { rects: [] };

  const ranks = groupByRank(order, depths);
  const maxRank = Math.max(...ranks.keys());
  const bandCount = Math.floor(maxRank / RANKS_PER_BAND) + 1;
  const columnWidths = columnWidthsFor(ranks, sizes, metrics);
  const columnX = positions(RANKS_PER_BAND, DESKTOP_X, (column) => (
    (columnWidths.get(column) ?? metrics.cardWidth) + metrics.xGap
  ));
  const bandHeights = new Map<number, number>();

  for (let band = 0; band < bandCount; band += 1) {
    const heights = Array.from({ length: RANKS_PER_BAND }, (_value, column) => (
      stackHeight(ranks.get(band * RANKS_PER_BAND + column) ?? [], sizes, metrics)
    ));
    bandHeights.set(band, Math.max(metrics.cardHeight, ...heights));
  }

  const bandY = positions(bandCount, DESKTOP_Y, (band) => (
    (bandHeights.get(band) ?? metrics.cardHeight) + BAND_GAP
  ));
  const rects: GraphEntityRect[] = [];
  let placed = 0;

  for (let rank = 0; rank <= maxRank; rank += 1) {
    const band = Math.floor(rank / RANKS_PER_BAND);
    const column = rank % RANKS_PER_BAND;
    let y = bandY.get(band) ?? DESKTOP_Y;
    for (const key of ranks.get(rank) ?? []) {
      const size = sizes.get(key) ?? { width: metrics.cardWidth, height: metrics.cardHeight };
      rects.push(entityRect(key, columnX.get(column) ?? DESKTOP_X, y, size, rank, placed, band, column));
      y += size.height + metrics.yGap;
      placed += 1;
    }
  }

  const contentRight = Math.max(...rects.map((rect) => rect.x + rect.width));
  const columnGutters = new Map(
    [...columnX].map(([column, x]) => [
      column,
      x + (columnWidths.get(column) ?? metrics.cardWidth) + metrics.xGap / 2,
    ]),
  );
  const rowCorridors = new Map(
    [...bandY].map(([band, y]) => [band, Math.max(16, y - (band === 0 ? 48 : BAND_GAP / 2))]),
  );
  const bandBottoms = new Map(
    [...bandY].map(([band, y]) => [band, y + (bandHeights.get(band) ?? metrics.cardHeight)]),
  );

  return {
    rects,
    routing: {
      wrapped: bandCount > 1,
      contentRight,
      columnGutters,
      rowCorridors,
      bandBottoms,
    },
  };
}

export function orderWithinRanks(
  order: string[],
  depths: Map<string, number>,
  dependencies: Array<{ source: string; target: string }>,
) {
  const basePosition = new Map(order.map((key, index) => [key, index]));
  const positions = new Map<string, number>();
  const predecessors = groupItems(dependencies, ({ target }) => target);
  const ranks = groupItems(order, (key) => String(depths.get(key) ?? 0));
  const result: string[] = [];

  [...ranks.entries()]
    .sort(([left], [right]) => Number(left) - Number(right))
    .forEach(([, keys]) => {
      keys.sort((left, right) => predecessorScore(left, predecessors, positions) - predecessorScore(right, predecessors, positions)
        || (basePosition.get(left) ?? 0) - (basePosition.get(right) ?? 0));
      keys.forEach((key, index) => positions.set(key, index));
      result.push(...keys);
    });

  return result;
}

export function entityRect(
  key: string,
  x: number,
  y: number,
  size: EntitySize,
  depth: number,
  order: number,
  row: number,
  column: number,
  parentGroupId?: string,
  expanded = false,
): GraphEntityRect {
  const kind = key.startsWith("group:") ? "group" : "work_package";
  return { key, id: key.slice(key.indexOf(":") + 1), kind, parent_group_id: parentGroupId, x, y, ...size, depth, row, column, order, expanded };
}

function mobileLayout(order: string[], sizes: Map<string, EntitySize>, metrics: LayoutMetrics) {
  let y = metrics.y;
  return order.map((key, index) => {
    const size = sizes.get(key) ?? { width: metrics.cardWidth, height: metrics.cardHeight };
    const rect = entityRect(key, metrics.x, y, size, 0, index, index, 0);
    y += size.height + metrics.yGap;
    return rect;
  });
}

function groupByRank(order: string[], depths: Map<string, number>) {
  const ranks = new Map<number, string[]>();
  for (const key of order) {
    const rank = depths.get(key) ?? 0;
    ranks.set(rank, [...(ranks.get(rank) ?? []), key]);
  }
  return ranks;
}

function columnWidthsFor(
  ranks: Map<number, string[]>,
  sizes: Map<string, EntitySize>,
  metrics: LayoutMetrics,
) {
  const widths = new Map<number, number>();
  ranks.forEach((keys, rank) => {
    const column = rank % RANKS_PER_BAND;
    for (const key of keys) {
      widths.set(column, Math.max(widths.get(column) ?? metrics.cardWidth, sizes.get(key)?.width ?? metrics.cardWidth));
    }
  });
  return widths;
}

function stackHeight(keys: string[], sizes: Map<string, EntitySize>, metrics: LayoutMetrics) {
  return keys.reduce((height, key) => height + (sizes.get(key)?.height ?? metrics.cardHeight), 0)
    + Math.max(0, keys.length - 1) * metrics.yGap;
}

function positions(count: number, start: number, step: (index: number) => number) {
  const values = new Map<number, number>();
  let cursor = start;
  for (let index = 0; index < count; index += 1) {
    values.set(index, cursor);
    cursor += step(index);
  }
  return values;
}

function predecessorScore(
  key: string,
  predecessors: Map<string, Array<{ source: string; target: string }>>,
  positionsByKey: Map<string, number>,
) {
  const values = (predecessors.get(key) ?? [])
    .map(({ source }) => positionsByKey.get(source))
    .filter((value): value is number => value != null);
  return values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : Number.POSITIVE_INFINITY;
}

function groupItems<T>(items: T[], key: (item: T) => string) {
  const grouped = new Map<string, T[]>();
  for (const item of items) grouped.set(key(item), [...(grouped.get(key(item)) ?? []), item]);
  return grouped;
}
