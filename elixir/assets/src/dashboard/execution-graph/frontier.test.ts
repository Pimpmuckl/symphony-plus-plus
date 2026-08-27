import { describe, expect, it } from "vitest";

import { executionFrontierProjection } from "./frontier";
import type { ExecutionGraphEffectiveEdge, ExecutionGraphGroup, WorkRequestExecutionGraphModel } from "./model";

describe("execution frontier projection", () => {
  it("keeps single and trivial linear work metadata-only, but promotes a blocked line", () => {
    expect(executionFrontierProjection(graph([pkg("only", "implementing")])).presentation).toBe("metadata");

    const linear = graph(
      [pkg("done", "merged"), pkg("active", "implementing"), pkg("next")],
      [edge("done", "active"), edge("active", "next")],
    );
    expect(executionFrontierProjection(linear).presentation).toBe("metadata");

    linear.work_packages[1].operational_state = { key: "blocked" };
    const blocked = executionFrontierProjection(linear);
    expect(blocked.presentation).toBe("graph");
    expect(blocked.reasons).toContain("blocked");

    const transition = graph(
      [pkg("shipped", "merged", "before"), pkg("ready", "planned", "after")],
      [edge("shipped", "ready")],
      [{ id: "before" }, { id: "after" }],
    );
    expect(executionFrontierProjection(transition).reasons).toContain("group_transition");
  });

  it("uses one prerequisite ring, two dependent rings, and partitions every hidden package", () => {
    const model = graph(
      [
        pkg("far-previous"), pkg("previous"), pkg("active", "implementing"), pkg("next"), pkg("later"), pkg("far-later"),
        pkg("fan-out"), pkg("fan-in"), pkg("island"),
      ],
      [
        edge("far-previous", "previous"), edge("previous", "active"), edge("active", "next"), edge("next", "later"),
        edge("later", "far-later"), edge("active", "fan-out"), edge("next", "fan-in"), edge("fan-out", "fan-in"),
      ],
    );
    model.topological_order = ["far-previous", "previous", "active", "next", "later", "far-later", "fan-out", "fan-in", "island"];
    const projection = executionFrontierProjection(model, new Set(), "forward-2");

    expect(projection.visibleWorkPackageIds).toEqual(["previous", "active", "next", "later", "fan-out", "fan-in"]);
    expect(projection.previousIds).toEqual(["far-previous"]);
    expect(projection.laterIds).toEqual(["far-later"]);
    expect(projection.otherIds).toEqual(["island"]);
    expect(new Set([...projection.visibleWorkPackageIds, ...projection.previousIds, ...projection.laterIds, ...projection.otherIds]).size).toBe(model.work_packages.length);
    expect(projection.reasons).toContain("branching");
  });

  it("recognizes disconnected parallel live work without pretending all disconnected work is visible", () => {
    expect(executionFrontierProjection(graph([pkg("ready-a"), pkg("ready-b")])).presentation).toBe("metadata");
    const projection = executionFrontierProjection(graph([
      pkg("alpha", "reviewing"), pkg("beta", "implementing"), pkg("quiet"),
    ]));

    expect(projection.presentation).toBe("graph");
    expect(projection.reasons).toContain("parallel_live");
    expect(projection.seedIds).toEqual(["alpha", "beta"]);
    expect(projection.otherIds).toEqual(["quiet"]);
  });

  it("keeps grouped large projections deterministic and expands attention group ancestry", () => {
    const groups: ExecutionGraphGroup[] = [
      { id: "delivery", title: "Delivery", position: 2 },
      { id: "build", title: "Build", position: 1 },
      { id: "active", title: "Active", parent_group_id: "build", position: 1 },
    ];
    const packages = [
      pkg("a", "merged", "build", 1), pkg("b", "planned", "active", 2), pkg("c", "planned", "active", 3),
      pkg("d", "planned", "delivery", 4), pkg("e", "planned", "delivery", 5), pkg("f", "planned", "delivery", 6),
    ];
    const edges = [edge("a", "b"), edge("b", "c"), edge("c", "d"), edge("d", "e"), edge("e", "f")];
    const ordered = graph(packages, edges, groups);
    ordered.topological_order = packages.map(({ id }) => id);
    const shuffled = { ...ordered, groups: [...groups].reverse(), work_packages: [...packages].reverse() };

    const attention = new Set(["group:active", "work_package:b"]);
    const left = executionFrontierProjection(ordered, attention, "forward-2");
    const right = executionFrontierProjection(shuffled, attention, "forward-2");

    expect(left.seedIds).toEqual(["b"]);
    expect(left.visibleWorkPackageIds).toEqual(right.visibleWorkPackageIds);
    expect(left.expandedGroupIds).toEqual(["build", "active"]);
    expect(left.groupCadence).toEqual([
      { id: "build", title: "Build", workPackageIds: ["a"] },
      { id: "active", title: "Active", workPackageIds: ["b", "c"] },
      { id: "delivery", title: "Delivery", workPackageIds: ["d"] },
    ]);
    expect(left.reasons).toContain("group_transition");
    expect(left.laterIds).toEqual(["e", "f"]);
  });
});

function graph(
  workPackages: WorkRequestExecutionGraphModel["work_packages"],
  effectiveEdges: ExecutionGraphEffectiveEdge[] = [],
  groups: ExecutionGraphGroup[] = [],
): WorkRequestExecutionGraphModel {
  return { available: true, groups, work_packages: workPackages, effective_edges: effectiveEdges };
}

function pkg(id: string, status = "planned", groupId?: string, sequence?: number): WorkRequestExecutionGraphModel["work_packages"][number] {
  return { id, group_id: groupId, sequence, status, worker_signal: /implement|review/.test(status) ? { status: "active" } : undefined };
}

function edge(prerequisite: string, dependent: string): ExecutionGraphEffectiveEdge {
  return { prerequisite_work_package_id: prerequisite, dependent_work_package_id: dependent };
}
