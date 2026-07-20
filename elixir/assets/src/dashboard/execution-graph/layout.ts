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

const DESKTOP_COLUMNS = 3;
const WRAPPED_X = 72;
const WRAPPED_Y = 76;
const ROW_GAP = 112;

export function layoutRootEntities(
  order: string[],
  depths: Map<string, number>,
  sizes: Map<string, EntitySize>,
  orientation: GraphOrientation,
  metrics: LayoutMetrics,
): { rects: GraphEntityRect[]; routing?: ExecutionGraphRouting } {
  if (orientation === "mobile") {
    let y = metrics.y;
    const rects = order.map((key, index) => {
      const size = sizes.get(key) ?? { width: metrics.cardWidth, height: metrics.cardHeight };
      const rect = entityRect(key, metrics.x, y, size, 0, index, 0, 0);
      y += size.height + metrics.yGap;
      return rect;
    });
    return { rects };
  }

  if (order.length < DESKTOP_COLUMNS) {
    const rects = unwrappedDesktop(order, depths, sizes, metrics);
    if (!rects.length) return { rects };
    const contentRight = Math.max(...rects.map((rect) => rect.x + rect.width));
    const columnGutters = new Map(rects.map((rect) => [rect.column, rect.x + rect.width + metrics.xGap / 2]));
    return {
      rects,
      routing: { wrapped: false, contentRight, columnGutters, rowCorridors: new Map([[0, Math.max(16, metrics.y - 48)]]) },
    };
  }

  const columnWidths = new Map<number, number>();
  const rowHeights = new Map<number, number>();
  order.forEach((key, index) => {
    const column = index % DESKTOP_COLUMNS;
    const row = Math.floor(index / DESKTOP_COLUMNS);
    const size = sizes.get(key) ?? { width: metrics.cardWidth, height: metrics.cardHeight };
    columnWidths.set(column, Math.max(columnWidths.get(column) ?? 0, size.width));
    rowHeights.set(row, Math.max(rowHeights.get(row) ?? 0, size.height));
  });

  const columnX = positions(DESKTOP_COLUMNS, WRAPPED_X, (column) => (columnWidths.get(column) ?? metrics.cardWidth) + metrics.xGap);
  const rowCount = Math.ceil(order.length / DESKTOP_COLUMNS);
  const rowY = positions(rowCount, WRAPPED_Y, (row) => (rowHeights.get(row) ?? metrics.cardHeight) + ROW_GAP);

  const rects = order.map((key, index) => {
    const depth = depths.get(key) ?? 0;
    const row = Math.floor(index / DESKTOP_COLUMNS);
    const column = index % DESKTOP_COLUMNS;
    const size = sizes.get(key) ?? { width: metrics.cardWidth, height: metrics.cardHeight };
    return entityRect(key, columnX.get(column) ?? WRAPPED_X, rowY.get(row) ?? WRAPPED_Y, size, depth, index, row, column);
  });

  const contentRight = Math.max(...rects.map((rect) => rect.x + rect.width));
  const columnGutters = new Map(
    [...columnX].map(([column, x]) => [column, x + (columnWidths.get(column) ?? metrics.cardWidth) + metrics.xGap / 2]),
  );
  const rowCorridors = new Map([...rowY].map(([row, y]) => [row, y - (row === 0 ? 48 : ROW_GAP / 2)]));
  return { rects, routing: { wrapped: rowCount > 1, contentRight, columnGutters, rowCorridors } };
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

function unwrappedDesktop(order: string[], depths: Map<string, number>, sizes: Map<string, EntitySize>, metrics: LayoutMetrics) {
  let x = metrics.x;
  return order.map((key, index) => {
    const depth = depths.get(key) ?? 0;
    const size = sizes.get(key) ?? { width: metrics.cardWidth, height: metrics.cardHeight };
    const rect = entityRect(key, x, metrics.y, size, depth, index, 0, index);
    x += size.width + metrics.xGap;
    return rect;
  });
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
