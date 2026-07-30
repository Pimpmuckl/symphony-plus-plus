import { describe, expect, it } from "vitest";

import { activeBlockerEdgesForRequest, activeBlockerEntityCounts, productTreeCounts, requestProgress, sliceProgressPercent } from "./workstream-progress";
import type { ActiveBlockingEdge, WorkRequestPackage, WorkRequestDetail, WorkPackageCard } from "@/types/dashboard";

describe("workstream progress", () => {
  it("counts active direct slices as partial progress", () => {
    const detail = workRequestDetail([
      plannedSlice("slice-active", "active"),
      plannedSlice("slice-planned", "planned"),
    ]);

    expect(requestProgress(detail, new Map<string, WorkPackageCard>())).toBe(25);
  });

  it("counts planning slices as partial progress", () => {
    const detail = workRequestDetail([
      plannedSlice("slice-planning", "planning"),
      plannedSlice("slice-planned", "planned"),
    ]);

    expect(sliceProgressPercent(detail.work_packages![0])).toBe(50);
    expect(requestProgress(detail, new Map<string, WorkPackageCard>())).toBe(25);
  });

  it("counts ready-to-finish slices as partial progress", () => {
    const detail = workRequestDetail([
      plannedSlice("slice-ready-finish", "ready_to_finish"),
      plannedSlice("slice-planned", "planned"),
    ]);

    expect(sliceProgressPercent(detail.work_packages![0])).toBe(50);
    expect(requestProgress(detail, new Map<string, WorkPackageCard>())).toBe(25);
  });

  it("keeps ready-for-worker slices at zero progress", () => {
    const slice = plannedSlice("slice-ready", "ready_for_worker", "pkg-ready");
    const pkg: WorkPackageCard = { id: "pkg-ready", status: "ready_for_worker", plan: { completed_count: 1, total_count: 2 } };

    expect(sliceProgressPercent(slice, pkg)).toBe(0);
  });

  it("derives product-tree request progress from descendant slices before stale partial marks", () => {
    const detail = workRequestDetail([
      plannedSlice("slice-ready", "ready_for_worker", "pkg-ready"),
    ]);
    detail.product_tree = {
      available: true,
      mode: "product_tree",
      nodes: [{ id: "node-ready", completion_mark: "partial", work_package_ids: ["slice-ready"] }],
      root_node_ids: ["node-ready"],
      root_work_package_ids: [],
    };
    const packages = new Map<string, WorkPackageCard>([
      ["pkg-ready", { id: "pkg-ready", status: "ready_for_worker", plan: { completed_count: 1, total_count: 2 } }],
    ]);

    expect(requestProgress(detail, packages)).toBe(0);
  });

  it("uses explicit active blocker evidence before product-tree dependency blocker totals", () => {
    const detail = workRequestDetail([]);
    detail.product_tree = {
      ...detail.product_tree,
      summary: {
        blocker_count: 3,
        node_count: 2,
        work_package_count: 4,
      },
    };

    expect(productTreeCounts(detail, 2).blockerCount).toBe(2);
  });

  it("counts blocker edges through slice and package endpoints before work request fallbacks", () => {
    const detail = workRequestDetail([
      plannedSlice("slice-endpoint", "blocked", "pkg-endpoint"),
      plannedSlice("slice-package", "blocked", "pkg-shared"),
    ]);

    const counts = activeBlockerEntityCounts(
      [
        blockingEdge("blocker-package-detail", { kind: "work_package", id: "unknown-package" }, { kind: "work_package", id: "pkg-endpoint" }),
        blockingEdge("blocker-package", { kind: "work_package", id: "unknown-package" }, { kind: "work_package", id: "pkg-shared" }),
        blockingEdge("blocker-fallback", { kind: "work_package", id: "unknown-package" }, { kind: "work_package", id: "unknown-package" }, "wr-progress"),
      ],
      [detail],
    ).requests;

    expect(counts.get("wr-progress")).toBe(3);
  });

  it("counts active blockers for child slice and package rows without duplicating matched endpoints", () => {
    const detail = workRequestDetail([
      plannedSlice("slice-endpoint", "blocked", "pkg-endpoint"),
      plannedSlice("slice-package", "blocked", "pkg-shared"),
    ]);

    const counts = activeBlockerEntityCounts(
      [
        blockingEdge(
          "blocker-linked",
          { kind: "work_package", id: "pkg-endpoint" },
          { kind: "work_package", id: "pkg-endpoint" },
          undefined,
          { work_package_id: "pkg-endpoint" },
        ),
        blockingEdge(
          "blocker-package",
          { kind: "work_package", id: "pkg-shared" },
          { kind: "work_package", id: "unknown-package" },
          undefined,
          { work_package_id: "pkg-shared" },
        ),
      ],
      [detail],
    );

    expect(counts.requests.get("wr-progress")).toBe(2);
    expect(counts.slices.get("slice-endpoint")).toBe(1);
    expect(counts.slices.get("slice-package")).toBe(1);
    expect(counts.packages.get("pkg-endpoint")).toBe(1);
    expect(counts.packages.get("pkg-shared")).toBe(1);
  });

  it("deduplicates blocker ids for package endpoints shared by multiple slices", () => {
    const detail = workRequestDetail([
      plannedSlice("slice-a", "blocked", "pkg-shared"),
      plannedSlice("slice-b", "blocked", "pkg-shared"),
    ]);

    const counts = activeBlockerEntityCounts(
      [
        blockingEdge(
          "edge-a",
          { kind: "work_package", id: "unknown-package" },
          { kind: "work_package", id: "pkg-shared" },
          undefined,
          { blocker_id: "blocker-shared" },
        ),
        blockingEdge(
          "edge-b",
          { kind: "work_package", id: "unknown-package" },
          { kind: "work_package", id: "pkg-shared" },
          undefined,
          { blocker_id: "blocker-shared" },
        ),
      ],
      [detail],
    );

    expect(counts.requests.get("wr-progress")).toBe(1);
    expect(counts.slices.get("slice-a")).toBe(1);
    expect(counts.slices.get("slice-b")).toBe(1);
    expect(counts.packages.get("pkg-shared")).toBe(1);
    expect([...new Set(counts.sliceBlockerKeys.get("slice-a"))]).toEqual(["blocker-shared"]);
    expect([...new Set(counts.sliceBlockerKeys.get("slice-b"))]).toEqual(["blocker-shared"]);
  });

  it("does not count blocker source endpoints as blocked entities", () => {
    const detail = workRequestDetail([
      plannedSlice("slice-source", "active", "pkg-source"),
      plannedSlice("slice-blocked", "blocked", "pkg-blocked"),
    ]);

    const counts = activeBlockerEntityCounts(
      [
        blockingEdge(
          "source-does-not-own-blocker",
          { kind: "work_package", id: "pkg-source" },
          { kind: "work_package", id: "pkg-blocked" },
        ),
      ],
      [detail],
    );

    expect(counts.slices.get("slice-source")).toBeUndefined();
    expect(counts.packages.get("pkg-source")).toBeUndefined();
    expect(counts.slices.get("slice-blocked")).toBe(1);
    expect(counts.packages.get("pkg-blocked")).toBe(1);
  });

  it("finds blocker edges that target a request through its package", () => {
    const detail = workRequestDetail([plannedSlice("slice-blocked", "blocked", "pkg-blocked")]);
    const matching = blockingEdge(
      "matching-edge",
      { kind: "work_package", id: "pkg-source" },
      { kind: "work_package", id: "pkg-blocked" },
    );
    const unrelated = blockingEdge(
      "unrelated-edge",
      { kind: "work_package", id: "pkg-source" },
      { kind: "work_package", id: "pkg-other" },
    );

    expect(activeBlockerEdgesForRequest([unrelated, matching], detail)).toEqual([matching]);
  });
});

function workRequestDetail(plannedSlices: WorkRequestPackage[]): WorkRequestDetail {
  return {
    work_request: { id: "wr-progress", status: "sliced", operational_state: { key: "active" } },
    work_packages: plannedSlices,
    product_tree: {
      available: true,
      mode: "direct_work_packages",
      nodes: [],
      root_node_ids: [],
      root_work_package_ids: plannedSlices.map((slice) => slice.id),
    },
  };
}

function plannedSlice(id: string, state: string, workPackageId?: string): WorkRequestPackage {
  return {
    id,
    work_request_id: "wr-progress",
    title: id,
    status: "planned",
    work_package_id: workPackageId,
    operational_state: { key: state },
  };
}

function blockingEdge(
  id: string,
  from: ActiveBlockingEdge["from"],
  to: ActiveBlockingEdge["to"],
  workRequestId?: string,
  overrides: Partial<ActiveBlockingEdge> = {},
): ActiveBlockingEdge {
  return {
    id,
    blocker_id: id,
    from,
    to,
    work_request_id: workRequestId,
    ...overrides,
  };
}
