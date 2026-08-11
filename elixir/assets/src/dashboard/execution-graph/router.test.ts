import { describe, expect, it } from "vitest";

import { auditWireGeometry, routeConflicts, routeSegments } from "./geometry-audit";
import { buildExecutionGraphLayout } from "./model";
import { WIRE_CLEARANCE } from "./portals";
import { graphWireRoutes } from "./router";

describe("execution graph router", () => {
  it("keeps adjacent-column fan-in clear of the Group's bottom gutter", () => {
    const { model, routes, sources, target } = adjacentFanIn(5);
    for (const sourceId of sources) {
      const source = model.visibleRects.find(({ key }) => key === `work_package:${sourceId}`)!;
      const route = routes.paths.find(({ intentIds }) => intentIds.includes(`${sourceId}-0-target`));
      const bottom = Math.max(...routeSegments(route?.path ?? "").flatMap(({ y1, y2 }) => [y1, y2]));
      expect(bottom).toBeLessThanOrEqual(Math.max(source.y + source.height, target.y + target.height));
    }
    expect(auditWireGeometry(model, routes.paths).fatal).toEqual([]);
    expect(routeConflicts(routes.paths)).toEqual([]);
  });

  it("provides clearance-spaced tracks beyond the old eight-track cap", () => {
    const { routes, sources } = adjacentFanIn(10);
    const trackXs = routes.paths.map(({ path }) => routeSegments(path).find(({ x1, x2 }) => x1 === x2)?.x1);
    const sorted = [...new Set(trackXs)].sort((left, right) => (left ?? 0) - (right ?? 0));

    expect(sorted).toHaveLength(sources.length);
    expect(Math.min(...sorted.slice(1).map((x, index) => (x ?? 0) - (sorted[index] ?? 0)))).toBeGreaterThanOrEqual(WIRE_CLEARANCE);
  });

  it("orders adjacent columns to avoid crossed one-to-one routes", () => {
    const { model, routes } = adjacentMatching(4);

    expect(auditWireGeometry(model, routes.paths).fatal).toEqual([]);
    expect(routeConflicts(routes.paths)).toEqual([]);
  });

  it("does not widen the Group for duplicate projected intents", () => {
    const single = adjacentFanIn(1);
    const duplicates = adjacentFanIn(1, 10);
    const width = ({ model }: ReturnType<typeof adjacentFanIn>) => model.visibleRects.find(({ key }) => key === "group:portal")?.width;

    expect(width(duplicates)).toBe(width(single));
  });
});

function adjacentFanIn(count: number, copies = 1) {
  const sources = Array.from({ length: count }, (_, index) => `source-${index}`);
  const model = buildExecutionGraphLayout({
    groups: [{ id: "portal", title: "Portal", work_package_ids: [...sources, "target"] }],
    work_packages: [...sources, "target"].map((id) => ({ id, group_id: "portal", title: id })),
    dependency_intents: sources.flatMap((id) => Array.from({ length: copies }, (_, index) => ({
      id: `${id}-${index}-target`,
      prerequisite: { kind: "work_package" as const, id },
      dependent: { kind: "work_package" as const, id: "target" },
    }))),
  }, "desktop", new Set(["portal"]));
  return {
    model,
    routes: graphWireRoutes(model, "desktop"),
    sources,
    target: model.visibleRects.find(({ key }) => key === "work_package:target")!,
  };
}

function adjacentMatching(count: number) {
  const sources = Array.from({ length: count }, (_, index) => `source-${index}`);
  const targets = Array.from({ length: count }, (_, index) => `target-${index}`);
  const model = buildExecutionGraphLayout({
    groups: [{ id: "portal", title: "Portal", work_package_ids: [...sources, ...targets] }],
    work_packages: [...sources, ...targets].map((id) => ({ id, group_id: "portal", title: id })),
    dependency_intents: sources.map((id, index) => ({
      id: `${id}-match`,
      prerequisite: { kind: "work_package" as const, id },
      dependent: { kind: "work_package" as const, id: targets[count - index - 1] },
    })),
  }, "desktop", new Set(["portal"]));
  return { model, routes: graphWireRoutes(model, "desktop") };
}
