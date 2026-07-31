import type { GraphOrientation } from "./model";

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
  orientation: GraphOrientation,
  metrics: GroupLayoutMetrics,
) {
  const sizes = new Map(keys.map((key) => [key, sizeFor(key)]));
  const childKeys = new Set(keys);
  const internal = dependencies.filter(({ source, target }) => source !== target && childKeys.has(source) && childKeys.has(target));
  const depths = orientation === "desktop" && internal.length ? dependencyDepths(keys, internal) : undefined;
  return depths ? horizontalLayout(keys, sizes, depths, metrics) : verticalLayout(keys, sizes, metrics);
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
  metrics: GroupLayoutMetrics,
) {
  const columns = new Map<string, string[]>();
  keys.forEach((key) => {
    const depth = depths.get(key) ?? 0;
    const bucket = `${Math.floor(depth / 3)}:${depth % 3}`;
    columns.set(bucket, [...(columns.get(bucket) ?? []), key]);
  });
  const columnWidths = new Map<number, number>();
  columns.forEach((members, bucket) => {
    const column = Number(bucket.split(":")[1]);
    columnWidths.set(column, Math.max(columnWidths.get(column) ?? 0, ...members.map((key) => (sizes.get(key) as EntitySize).width)));
  });
  const xByColumn = new Map<number, number>();
  let contentRight = metrics.groupPadding;
  for (const [column, width] of [...columnWidths].sort(([left], [right]) => left - right)) {
    xByColumn.set(column, contentRight);
    contentRight += width + metrics.childXGap;
  }
  const items: GroupChildPlacement[] = [];
  let bandTop = metrics.groupHeader + metrics.groupPadding;
  const bandCount = Math.max(0, ...[...columns.keys()].map((bucket) => Number(bucket.split(":")[0]))) + 1;
  for (let band = 0; band < bandCount; band += 1) {
    let bandHeight = 0;
    for (const column of [...columnWidths.keys()].sort()) {
      const members = columns.get(`${band}:${column}`) ?? [];
      let y = bandTop;
      members.forEach((key, row) => {
        const size = sizes.get(key) as EntitySize;
        items.push({ key, x: xByColumn.get(column) ?? metrics.groupPadding, y, row, column, ...size });
        y += size.height + metrics.childGap;
      });
      bandHeight = Math.max(bandHeight, members.length ? y - bandTop - metrics.childGap : 0);
    }
    bandTop += bandHeight + metrics.childBandGap;
  }
  return {
    items,
    width: Math.max(metrics.groupWidth, contentRight - metrics.childXGap + metrics.groupPadding),
    height: bandTop - metrics.childBandGap + metrics.groupPadding,
  };
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
