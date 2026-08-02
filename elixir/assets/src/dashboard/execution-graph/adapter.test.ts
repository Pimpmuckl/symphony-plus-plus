import { describe, expect, it } from "vitest";

import type { WorkRequestDetail } from "@/types/dashboard";
import { workRequestExecutionFrontierProjection, workRequestExecutionGraphModel } from "./adapter";
import type { WorkRequestExecutionGraphModel } from "./model";

describe("execution graph adapter", () => {
  it("maps dependency intent and lifecycle signals without replacing them with effective edges", () => {
    const detail: WorkRequestDetail = {
      work_request: { id: "wr-adapter", title: "Adapter fixture" },
      work_packages: [
        { id: "wp-active", work_request_id: "wr-adapter", product_tree_node_id: "group-a", title: "Active projection", status: "implementing", operational_state: { key: "implementing", label: "Implementing", tone: "info" }, worker_signal: { status: "active", run_label: "fixture-worker" } },
        { id: "wp-old", work_request_id: "wr-adapter", product_tree_node_id: "group-a", title: "Old", status: "merged", delivery: { outcome: "superseded" } },
      ],
      product_tree: {
        available: true,
        nodes: [{ id: "group-a", title: "Group A", work_package_ids: ["wp-active", "wp-old"] }],
        dependency_edges: [
          { id: "depends", kind: "depends_on", source: { kind: "work_package", id: "wp-active" }, target: { kind: "product_node", id: "group-a" } },
          { id: "blocks", kind: "blocks", source: { kind: "product_node", id: "group-a" }, target: { kind: "work_package", id: "wp-old" } },
        ],
        execution_graph: { available: true, work_package_ids: ["wp-active", "wp-old"], effective_edges: [{ prerequisite_work_package_id: "wp-old", dependent_work_package_id: "wp-active", dependency_ids: ["expanded"] }], topological_order: ["wp-old", "wp-active"] },
      },
    };
    const active = workRequestExecutionGraphModel(detail);
    const all = workRequestExecutionGraphModel(detail, { includeHistorical: true });

    expect(active.work_packages).toEqual([expect.objectContaining({ id: "wp-active", group_id: "group-a", title: "Active projection", worker_signal: { status: "active", run_label: "fixture-worker" } })]);
    expect(active.dependency_intents).toEqual([
      { id: "depends", prerequisite: { kind: "group", id: "group-a" }, dependent: { kind: "work_package", id: "wp-active" } },
      { id: "blocks", prerequisite: { kind: "group", id: "group-a" }, dependent: { kind: "work_package", id: "wp-old" } },
    ]);
    expect(active.effective_edges).toEqual(detail.product_tree?.execution_graph?.effective_edges);
    expect(all.work_packages.map((item) => item.id)).toEqual(["wp-active", "wp-old"]);
  });

  it("projects four graph-only frontier scopes around the same live seed", () => {
    const graph: WorkRequestExecutionGraphModel = {
      groups: [{ id: "history" }, { id: "causes" }, { id: "current" }, { id: "future" }, { id: "side" }, { id: "ready" }],
      work_packages: [
        { id: "done", group_id: "history", status: "merged" },
        { id: "far-cause", group_id: "causes", status: "planned" },
        { id: "near-cause", group_id: "causes", status: "planned" },
        { id: "active", group_id: "current", status: "implementing", worker_signal: { status: "active" } },
        { id: "next", group_id: "future", status: "planned" },
        { id: "deep", group_id: "future", status: "planned" },
        { id: "farther", group_id: "future", status: "planned" },
        { id: "other", group_id: "side", status: "planned" },
        { id: "gated", group_id: "future", status: "planned" },
        { id: "ready", group_id: "ready", status: "planned" },
      ],
      effective_edges: [
        { prerequisite_work_package_id: "done", dependent_work_package_id: "active" },
        { prerequisite_work_package_id: "far-cause", dependent_work_package_id: "near-cause" },
        { prerequisite_work_package_id: "near-cause", dependent_work_package_id: "active" },
        { prerequisite_work_package_id: "active", dependent_work_package_id: "next" },
        { prerequisite_work_package_id: "next", dependent_work_package_id: "deep" },
        { prerequisite_work_package_id: "deep", dependent_work_package_id: "farther" },
        { prerequisite_work_package_id: "active", dependent_work_package_id: "gated" },
        { prerequisite_work_package_id: "other", dependent_work_package_id: "gated" },
      ],
    };
    const oneRing = workRequestExecutionFrontierProjection(graph, new Set(), "horizon-1");
    const forward = workRequestExecutionFrontierProjection(graph, new Set(), "forward-2");

    expect(oneRing.model.work_packages.map((pkg) => pkg.id)).toEqual(["done", "near-cause", "active", "next", "gated"]);
    expect(forward.model.work_packages.map((pkg) => pkg.id)).toEqual(["done", "near-cause", "active", "next", "deep", "gated"]);
    expect([...oneRing.expandedGroupIds]).toEqual(["current"]);
    expect([...forward.expandedGroupIds]).toEqual(["current"]);
  });
});
