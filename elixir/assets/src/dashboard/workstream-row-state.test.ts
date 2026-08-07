import { describe, expect, it } from "vitest";

import type { WorkRequestPackage, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import {
  requestBoardState,
  requestStatusLabels,
  statusBadgeWidthForLabels,
  statusBadgeWidthForRequestDetails,
} from "./workstream-row-state";

describe("workstream row state", () => {
  it("sizes status badges from the longest rendered label without the old wide bucket", () => {
    expect(statusBadgeWidthForLabels(["Delivered", "Clarifying"])).toBe("6.2rem");
    expect(statusBadgeWidthForLabels(["Delivered", "Completed Without PR", "Ready For Worker"])).toBe("9.2rem");
  });

  it("collects request, product node, and slice status labels for one row group", () => {
    const detail: WorkRequestDetail = {
      work_request: {
        id: "wr-row-state",
        status: "ready_for_slicing",
        operational_state: { key: "ready_for_slicing", label: "Ready For Slicing" },
      },
      product_tree: {
        available: true,
        mode: "product_tree",
        nodes: [{ id: "node-1", completion_mark: "partial", completion_label: "Partially Complete" }],
        root_node_ids: ["node-1"],
      },
      work_packages: [
        plannedSlice("slice-1", "pkg-1", "completed_no_pr", "Completed Without PR"),
        plannedSlice("slice-2", undefined, "delivered", "Delivered"),
      ],
    };
    const packageById = new Map<string, WorkPackageCard>([
      ["pkg-1", { id: "pkg-1", status: "completed_no_pr", operational_state: { key: "completed_no_pr", label: "Completed Without PR" } }],
    ]);

    expect(requestStatusLabels(detail, packageById)).toEqual([
      "Ready For Slicing",
      "Partially Complete",
      "Completed Without PR",
      "Delivered",
    ]);
    expect(statusBadgeWidthForRequestDetails([detail], packageById)).toBe("9.2rem");
  });

  it("keeps clarification status visible without treating it as human guidance", () => {
    const detail: WorkRequestDetail = {
      work_request: {
        id: "wr-clarifying",
        status: "clarifying",
        operational_state: { key: "clarifying", label: "Clarifying" },
      },
      work_packages: [],
    };

    const state = requestBoardState(detail, new Map(), { blockerCount: 0, guidanceCount: 0 }, 0);

    expect(state.label).toBe("Clarifying");
    expect(state.kind).toBe("waiting");
    expect(state.badgeVariant).toBe("secondary");
    expect(state.tone).toBe("muted");
  });

  it("uses ready color for ready request rows", () => {
    const detail: WorkRequestDetail = {
      work_request: {
        id: "wr-ready",
        status: "ready_for_slicing",
        operational_state: { key: "ready_for_slicing", label: "Ready For Slicing" },
      },
      work_packages: [],
    };

    const state = requestBoardState(detail, new Map(), { blockerCount: 0, guidanceCount: 0 }, 0);

    expect(state.label).toBe("Ready For Slicing");
    expect(state.badgeVariant).toBe("ready");
    expect(state.tone).toBe("ready");
  });

  it("uses planned state for requests whose visible descendants are only planned", () => {
    const detail: WorkRequestDetail = {
      work_request: {
        id: "wr-partial-planned",
        status: "sliced",
        operational_state: { key: "sliced", label: "Sliced" },
      },
      work_packages: [plannedSlice("slice-planned", undefined, "planned", "Planned")],
    };

    const state = requestBoardState(detail, new Map(), { blockerCount: 0, guidanceCount: 0 }, 50);

    expect(state.kind).toBe("planned");
    expect(state.label).toBe("Planned");
    expect(state.badgeVariant).toBe("secondary");
    expect(state.tone).toBe("muted");
  });

  it("derives request row state from active child slices before raw request status", () => {
    const detail: WorkRequestDetail = {
      work_request: {
        id: "wr-active-child",
        status: "sliced",
        operational_state: { key: "sliced", label: "Sliced" },
      },
      work_packages: [plannedSlice("slice-active-child", "pkg-active", "active", "Active")],
    };

    const state = requestBoardState(detail, new Map(), { blockerCount: 0, guidanceCount: 0 }, 50);

    expect(state.label).toBe("Active");
    expect(state.tone).toBe("implementing");
  });

  it("derives request row state from ready-to-finish child slices", () => {
    const detail: WorkRequestDetail = {
      work_request: {
        id: "wr-ready-finish-child",
        status: "sliced",
        operational_state: { key: "sliced", label: "Sliced" },
      },
      work_packages: [plannedSlice("slice-ready-finish-child", "pkg-ready-finish", "ready_to_finish", "Ready To Finish")],
    };

    const state = requestBoardState(detail, new Map(), { blockerCount: 0, guidanceCount: 0 }, 50);

    expect(state.kind).toBe("ready");
    expect(state.label).toBe("Ready");
    expect(state.tone).toBe("ready");
  });

  it("keeps active rows active at 100 percent plan progress until finished", () => {
    const detail: WorkRequestDetail = {
      work_request: {
        id: "wr-active-full-progress",
        status: "sliced",
        operational_state: { key: "sliced", label: "Sliced" },
      },
      work_packages: [plannedSlice("slice-active-full-progress", "pkg-active", "active", "Active")],
    };
    const packages = new Map<string, WorkPackageCard>([
      ["pkg-active", { id: "pkg-active", status: "active", plan: { completed_count: 1, total_count: 1 } }],
    ]);

    const requestState = requestBoardState(detail, packages, { blockerCount: 0, guidanceCount: 0 }, 100);

    expect(requestState.kind).toBe("active");
  });

  it("does not finish a request while product work remains incomplete", () => {
    const detail: WorkRequestDetail = {
      work_request: { id: "wr-incomplete-product", status: "sliced" },
      product_tree: { nodes: [{ id: "node-open", completion_mark: "not_done" }] },
      work_packages: [plannedSlice("slice-done", undefined, "delivered", "Delivered")],
    };

    expect(requestBoardState(detail, new Map(), { blockerCount: 0, guidanceCount: 0 }, 100).kind).toBe("partial");
  });

  it("uses current slice operational state ahead of stale terminal projections", () => {
    const slice = plannedSlice("slice-current", undefined, "active", "Active");
    slice.work_package_status = "delivered";
    slice.delivery = { outcome: "delivered" };
    const detail: WorkRequestDetail = { work_request: { id: "wr-current", status: "sliced" }, work_packages: [slice] };

    expect(requestBoardState(detail, new Map(), { blockerCount: 0, guidanceCount: 0 }, 100).kind).toBe("active");
  });

  it("keeps terminal request state ahead of stale active children", () => {
    const detail: WorkRequestDetail = {
      work_request: {
        id: "wr-done-active-child",
        status: "delivered",
        operational_state: { key: "delivered", label: "Delivered" },
      },
      work_packages: [plannedSlice("slice-stale-active", "pkg-active", "active", "Active")],
    };
    const packages = new Map<string, WorkPackageCard>([["pkg-active", { id: "pkg-active", status: "active" }]]);
    const requestState = requestBoardState(detail, packages, { blockerCount: 0, guidanceCount: 0 }, 100);

    expect(requestState.kind).toBe("done");
  });

  it("keeps finished request state primary when blockers remain", () => {
    const detail: WorkRequestDetail = {
      work_request: {
        id: "wr-done-blocked",
        status: "delivered",
        operational_state: { key: "delivered", label: "Delivered" },
      },
      work_packages: [],
    };

    const state = requestBoardState(detail, new Map(), { blockerCount: 1, guidanceCount: 0 }, 100);

    expect(state.label).toBe("Delivered");
    expect(state.tone).toBe("finished");
    expect(state.badgeVariant).toBe("success");
  });

  it("keeps failed gates and status-only blockers out of red attention state", () => {
    const reviewFailed = plannedSlice("slice-review", "pkg-review", "reviewing", "Reviewing");
    reviewFailed.review_signal = { status: "failed" };
    const blocked = plannedSlice("slice-blocked", "pkg-blocked", "blocked", "Blocked");

    const recovery = requestBoardState(
      { work_request: { id: "wr-review", status: "sliced" }, work_packages: [reviewFailed] },
      new Map(),
      { blockerCount: 0, guidanceCount: 0 },
      50,
    );
    const waiting = requestBoardState(
      { work_request: { id: "wr-blocked", status: "sliced" }, work_packages: [blocked] },
      new Map(),
      { blockerCount: 0, guidanceCount: 0 },
      50,
    );

    expect(recovery).toMatchObject({ kind: "recovery", badgeVariant: "warning", tone: "review" });
    expect(waiting).toMatchObject({ kind: "waiting", badgeVariant: "secondary", tone: "muted" });
  });

});

function plannedSlice(id: string, workPackageId: string | undefined, stateKey: string, label: string): WorkRequestPackage {
  return {
    id,
    work_request_id: "wr-row-state",
    title: id,
    status: stateKey,
    work_package_id: workPackageId,
    operational_state: { key: stateKey, label },
  };
}
