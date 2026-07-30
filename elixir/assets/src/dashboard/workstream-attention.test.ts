import { describe, expect, it } from "vitest";
import type { ActiveBlockingEdge, WorkPackageCard, WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";
import { requestAttentionTarget } from "./workstream-attention";

describe("WorkRequest attention badge targets", () => {
  it("opens the human guidance modal for an open question", () => {
    const detail = requestDetail([]);
    detail.clarification_questions = [{ id: "question-1", work_request_id: "wr-attention", status: "open", question: "Choose a release path" }];

    expect(requestAttentionTarget(detail, new Map(), [], "guidance")).toMatchObject({
      kind: "guidance",
      item: { id: "question-1", workRequestId: "wr-attention" },
    });
  });

  it("opens the existing blocker modal for an active blocker edge", () => {
    const slice = requestSlice("slice-blocked", "blocked", "wp-blocked");
    const detail = requestDetail([slice]);
    const pkg: WorkPackageCard = { id: "wp-blocked", status: "blocked" };
    const blocker: ActiveBlockingEdge = {
      id: "edge-1",
      blocker_id: "blocker-1",
      from: { kind: "work_package", id: "wp-source" },
      to: { kind: "work_package", id: "wp-blocked" },
    };

    expect(requestAttentionTarget(detail, new Map([[pkg.id, pkg]]), [blocker], "blocked")).toMatchObject({
      kind: "card",
      selection: { kind: "blocker", blocker, detail, slice, pkg },
    });
  });

  it("opens the affected WorkPackage detail for guidance or a failed gate without a dedicated modal", () => {
    const guidance = requestSlice("slice-guidance", "human_info_needed", "wp-guidance");
    const failed = { ...requestSlice("slice-failed", "reviewing", "wp-failed"), review_signal: { status: "failed" as const } };
    const detail = requestDetail([guidance, failed]);

    expect(requestAttentionTarget(detail, new Map(), [], "guidance")).toMatchObject({
      kind: "card",
      selection: { kind: "slice", slice: guidance },
    });
    expect(requestAttentionTarget(detail, new Map(), [], "blocked")).toMatchObject({
      kind: "card",
      selection: { kind: "slice", slice: failed },
    });
  });
});

function requestDetail(workPackages: WorkRequestPackage[]): WorkRequestDetail {
  return {
    work_request: { id: "wr-attention", title: "Needs attention", status: "sliced" },
    work_packages: workPackages,
  };
}

function requestSlice(id: string, status: string, workPackageId: string): WorkRequestPackage {
  return {
    id,
    work_request_id: "wr-attention",
    status,
    title: id,
    work_package_id: workPackageId,
    operational_state: { key: status },
  };
}
