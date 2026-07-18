import { describe, expect, it } from "vitest";

import type { WorkRequestPackage, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import {
  requestBoardState,
  rowProgressAttentionState,
  rowProgressIconState,
  requestStatusLabels,
  sliceBlockerCount,
  sliceGuidanceCount,
  statusBadgeWidthForLabels,
  statusBadgeWidthForRequestDetails,
} from "./workstream-row-state";

describe("workstream row state", () => {
  it("sizes status badges from the longest rendered label without the old wide bucket", () => {
    expect(statusBadgeWidthForLabels(["Delivered", "Clarifying"])).toBe("6.2rem");
    expect(statusBadgeWidthForLabels(["Delivered", "Completed Without PR", "Ready For Worker"])).toBe("9.2rem");
  });

  it("maps row progress icons by attention, completion, and active progress priority", () => {
    expect(rowProgressIconState({ progress: 100, tone: "finished" })).toBe("done");
    expect(rowProgressIconState({ progress: 100, blockerCount: 1, tone: "finished" })).toBe("done");
    expect(rowProgressIconState({ progress: 100, guidanceCount: 1, tone: "finished" })).toBe("done");
    expect(rowProgressIconState({ progress: 100, blockerCount: 1, tone: "blocked" })).toBe("active");
    expect(rowProgressAttentionState({ blockerCount: 1, tone: "finished" })).toBe("blocked");
    expect(rowProgressAttentionState({ guidanceCount: 1, tone: "finished" })).toBe("guidance");
    expect(rowProgressIconState({ progress: 45, blockerCount: 1, tone: "implementing" })).toBe("active");
    expect(rowProgressIconState({ progress: 45, guidanceCount: 1, tone: "implementing" })).toBe("active");
    expect(rowProgressAttentionState({ blockerCount: 1, tone: "implementing" })).toBe("blocked");
    expect(rowProgressAttentionState({ guidanceCount: 1, tone: "implementing" })).toBe("guidance");
    expect(rowProgressIconState({ blockerCount: 1, tone: "blocked" })).toBe("blocked");
    expect(rowProgressIconState({ tone: "ready" })).toBe("ready");
    expect(rowProgressIconState({ blockerCount: 1, tone: "ready" })).toBe("blocked");
    expect(rowProgressIconState({ guidanceCount: 1, tone: "ready" })).toBe("guidance");
    expect(rowProgressIconState({ progress: 45, tone: "ready" })).toBe("active");
    expect(rowProgressIconState({ tone: "muted" })).toBe("muted");
    expect(rowProgressIconState({ progress: 100, tone: "muted" })).toBe("muted");
    expect(rowProgressIconState({ progress: 45, tone: "implementing" })).toBe("active");
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

  it("uses guidance color for clarifying request rows", () => {
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
    expect(state.badgeVariant).toBe("guidance");
    expect(state.tone).toBe("guidance");
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

  it("does not attribute package-level blocker edges to sibling slice rows", () => {
    const siblingSlice = plannedSlice("slice-sibling", "pkg-shared", "ready_for_worker", "Ready For Worker");
    const packageOnlyBlockerCounts = new Map([["pkg-shared", 1]]);

    expect(sliceBlockerCount(siblingSlice, { id: "pkg-shared", status: "active" }, new Map())).toBe(0);
    expect(sliceBlockerCount(siblingSlice, { id: "pkg-shared", status: "active" }, packageOnlyBlockerCounts)).toBe(0);
    expect(
      sliceBlockerCount(
        siblingSlice,
        { id: "pkg-shared", status: "active", active_blocker_count: 1 },
        new Map(),
      ),
    ).toBe(1);
  });

  it("does not show delivery-board attention reasons as human guidance on slice rows", () => {
    const closeoutSlice = plannedSlice("slice-closeout", "pkg-closeout", "dispatched", "Needs Closeout");
    closeoutSlice.attention_reason_codes = ["terminal_package_without_delivery_outcome"];
    closeoutSlice.operational_state = {
      key: "needs_closeout",
      label: "Needs Closeout",
      attention_reason_codes: ["terminal_package_without_delivery_outcome"],
      attention_items: [{ key: "terminal_package_without_delivery_outcome", label: "Missing Delivery Closeout", tone: "warning" }],
    };

    expect(sliceGuidanceCount(closeoutSlice, undefined)).toBe(0);
  });

  it("shows slice guidance only for actual human guidance signals", () => {
    const questionSlice = plannedSlice("slice-question", "pkg-question", "active", "Active");
    questionSlice.operational_state = {
      key: "active",
      label: "Active",
      attention_items: [{ key: "clarification_question", label: "Clarification question", tone: "warning" }],
    };

    expect(sliceGuidanceCount(plannedSlice("slice-human", "pkg-human", "human_info_needed", "Human Info Needed"), undefined)).toBe(1);
    expect(sliceGuidanceCount(questionSlice, undefined)).toBe(1);
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
