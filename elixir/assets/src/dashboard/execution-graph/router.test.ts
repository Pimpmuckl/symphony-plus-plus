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
      const route = routes.paths.find(({ intentIds }) => intentIds.includes(`${sourceId}-target`));
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

  it("sizes projected routes from the rendered child expansion state", () => {
    const width = (model: ReturnType<typeof nestedFanIn>) => model.visibleRects.find(({ key }) => key === "group:parent")?.width;
    const collapsed = [nestedFanIn(1, false), nestedFanIn(5, false)];
    const expanded = [nestedFanIn(1, true), nestedFanIn(5, true)];

    expect(width(collapsed[1])).toBe(width(collapsed[0]));
    expect(width(expanded[1])).toBeGreaterThan(width(expanded[0]) ?? 0);
    expect(auditWireGeometry(expanded[1], graphWireRoutes(expanded[1], "desktop").paths).fatal).toEqual([]);
  });
});

function adjacentFanIn(count: number) {
  const sources = Array.from({ length: count }, (_, index) => `source-${index}`);
  const model = buildExecutionGraphLayout({
    groups: [{ id: "portal", title: "Portal", work_package_ids: [...sources, "target"] }],
    work_packages: [...sources, "target"].map((id) => ({ id, group_id: "portal", title: id })),
    dependency_intents: sources.map((id) => ({
      id: `${id}-target`,
      prerequisite: { kind: "work_package" as const, id },
      dependent: { kind: "work_package" as const, id: "target" },
    })),
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

function nestedFanIn(count: number, expandChildren: boolean) {
  const sources = Array.from({ length: count }, (_, index) => `source-${index}`);
  return buildExecutionGraphLayout({
    groups: [
      { id: "parent", title: "Parent" },
      { id: "sources", parent_group_id: "parent", title: "Sources", work_package_ids: sources },
      { id: "targets", parent_group_id: "parent", title: "Targets", work_package_ids: ["target"] },
    ],
    work_packages: [...sources.map((id) => ({ id, group_id: "sources", title: id })), { id: "target", group_id: "targets", title: "target" }],
    dependency_intents: sources.map((id) => ({
      id: `${id}-nested-target`,
      prerequisite: { kind: "work_package" as const, id },
      dependent: { kind: "work_package" as const, id: "target" },
    })),
  }, "desktop", new Set(["parent", ...(expandChildren ? ["sources", "targets"] : [])]));
}
