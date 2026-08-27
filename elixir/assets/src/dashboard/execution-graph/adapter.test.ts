import { describe, expect, it } from "vitest";

import type { WorkRequestDetail } from "@/types/dashboard";
import { workRequestExecutionGraphModel } from "./adapter";

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

});
