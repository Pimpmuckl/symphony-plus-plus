import { describe, expect, it } from "vitest";

import { activeContextPath } from "./workstream-context-bar";

describe("workstream context bar", () => {
  it("uses the leading visible graph card and follows horizontal scrolling", () => {
    const viewportRect = rectangle(300, 0, 400, 400);
    const positions = {
      hidden: rectangle(50, 100, 200, 100),
      leading: rectangle(310, 100, 200, 100),
      trailing: rectangle(520, 100, 200, 100),
    };
    const markers = [
      marker("hidden", () => positions.hidden, viewportRect),
      marker("leading", () => positions.leading, viewportRect),
      marker("trailing", () => positions.trailing, viewportRect),
    ];
    const board = {
      getBoundingClientRect: () => rectangle(0, 0, 800, 800),
      querySelectorAll: () => markers,
    } as unknown as HTMLDivElement;

    expect(activeContextPath(board)).toEqual([{ id: "leading", label: "leading" }]);

    positions.leading = rectangle(100, 100, 200, 100);
    positions.trailing = rectangle(310, 100, 200, 100);

    expect(activeContextPath(board)).toEqual([{ id: "trailing", label: "trailing" }]);
  });
});

function marker(id: string, rect: () => DOMRect, viewportRect: DOMRect) {
  return {
    dataset: { v3ContextPath: JSON.stringify([{ id, label: id }]) },
    closest: (selector: string) => selector === ".execution-graph__viewport" ? { getBoundingClientRect: () => viewportRect } : null,
    getBoundingClientRect: rect,
  } as unknown as HTMLElement;
}

function rectangle(left: number, top: number, width: number, height: number) {
  return { bottom: top + height, height, left, right: left + width, top, width } as DOMRect;
}
