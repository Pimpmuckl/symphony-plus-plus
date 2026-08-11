import { describe, expect, it } from "vitest";

import { auditWireGeometry, routeSegments } from "./geometry-audit";
import { buildExecutionGraphLayout } from "./model";
import { graphWireRoutes } from "./router";

describe("execution graph router", () => {
  it("keeps vertically stacked adjacent-column fan-in out of the Group's bottom gutter", () => {
    const sources = ["one", "two", "three", "four", "five"];
    const model = buildExecutionGraphLayout({
      groups: [{ id: "portal", title: "Portal", work_package_ids: [...sources, "target"] }],
      work_packages: [...sources, "target"].map((id) => ({ id, group_id: "portal", title: id })),
      dependency_intents: sources.map((id) => ({
        id: `${id}-target`,
        prerequisite: { kind: "work_package" as const, id },
        dependent: { kind: "work_package" as const, id: "target" },
      })),
    }, "desktop", new Set(["portal"]));
    const target = model.visibleRects.find(({ key }) => key === "work_package:target")!;
    const routes = graphWireRoutes(model, "desktop");

    for (const sourceId of sources) {
      const source = model.visibleRects.find(({ key }) => key === `work_package:${sourceId}`)!;
      const route = routes.paths.find(({ intentIds }) => intentIds.includes(`${sourceId}-target`));
      const bottom = Math.max(...routeSegments(route?.path ?? "").flatMap(({ y1, y2 }) => [y1, y2]));
      expect(bottom).toBeLessThanOrEqual(Math.max(source.y + source.height, target.y + target.height));
    }
    expect(auditWireGeometry(model, routes.paths).fatal).toEqual([]);
  });
});
