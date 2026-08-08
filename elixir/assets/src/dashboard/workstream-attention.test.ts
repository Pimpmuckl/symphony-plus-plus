import { describe, expect, it } from "vitest";
import type { ActiveBlockingEdge, GuidanceItem, WorkPackageCard, WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";
import type { BlockerItem } from "./dashboard-state";
import { activeBlockerItems } from "./dashboard-data";
import {
  attentionLocationForSelection,
  attentionJumpDestination,
  dashboardAttentionItems,
  groupDirectAttention,
  requestActionableAttentionCounts,
  requestAttentionTarget,
  workPackageDirectAttention,
} from "./workstream-attention";

describe("WorkRequest attention badge targets", () => {
  it("opens the human guidance modal for an open question", () => {
    const detail = requestDetail([]);
    detail.clarification_questions = [{ id: "question-1", work_request_id: "wr-attention", status: "open", question: "Choose a release path" }];

    expect(requestAttentionTarget(detail, new Map(), [], "guidance")).toMatchObject({
      items: [{ kind: "guidance", item: { id: "question-1", workRequestId: "wr-attention" } }],
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
      items: [{ kind: "blocker", selection: { kind: "blocker", blocker, detail, slice, pkg } }],
    });
  });

  it("routes a blocker by its active target when its event owner is terminal", () => {
    const deliveredSlice = requestSlice("slice-delivered", "blocked", "wp-delivered");
    deliveredSlice.operational_state = { key: "blocked", delivery_outcome: "pr_merged" };
    const activeSlice = requestSlice("slice-active", "blocked", "wp-active");
    const detail = requestDetail([deliveredSlice, activeSlice]);
    const deliveredPackage: WorkPackageCard = { id: "wp-delivered", status: "blocked" };
    const activePackage: WorkPackageCard = { id: "wp-active", status: "blocked" };
    const packages = new Map([[deliveredPackage.id, deliveredPackage], [activePackage.id, activePackage]]);
    const blocker: ActiveBlockingEdge = {
      id: "edge-terminal-owner",
      blocker_id: "blocker-terminal-owner",
      work_package_id: deliveredPackage.id,
      from: { kind: "work_package", id: deliveredPackage.id },
      to: { kind: "work_package", id: activePackage.id },
    };

    expect(requestAttentionTarget(detail, packages, [blocker], "blocked")).toMatchObject({
      items: [{ kind: "blocker", selection: { blocker, slice: activeSlice, pkg: activePackage } }],
    });
    const blockerItems = activeBlockerItems([deliveredPackage, activePackage], new Map(), [blocker]);
    expect(blockerItems.find((item) => item.id === blocker.id)?.selection).toMatchObject({ blocker, pkg: activePackage });
    expect(dashboardAttentionItems([detail], packages, [blocker], [], blockerItems)).toMatchObject([
      { kind: "blocker", selection: { blocker, slice: activeSlice, pkg: activePackage } },
    ]);
  });

  it("opens package guidance and embedded blocker records when projections are absent", () => {
    const slice = requestSlice("slice-attention", "human_info_needed", "wp-attention");
    const detail = requestDetail([slice]);
    const guidance: GuidanceItem = {
      source: "guidance",
      id: "guidance-1",
      repo: "fixture/repo",
      repoKey: "fixture/repo",
      title: "Choose a path",
      packageId: "wp-attention",
      detail: "A human decision is required.",
      guidance: { id: "guidance-1", work_package_id: "wp-attention" },
    };
    const pkg: WorkPackageCard = {
      id: "wp-attention",
      status: "blocked",
      active_blockers: [{ id: "blocker-embedded", active: true, summary: "Waiting on approval" }],
    };
    const packages = new Map([[pkg.id, pkg]]);

    expect(requestAttentionTarget(detail, packages, [], "guidance", [guidance])).toMatchObject({
      items: [{ kind: "guidance", item: guidance }],
    });
    expect(requestAttentionTarget(detail, packages, [], "blocked")).toMatchObject({
      items: [{
        kind: "blocker",
        selection: {
          kind: "blocker",
          blocker: { blocker_id: "blocker-embedded", work_package_id: "wp-attention" },
          detail,
          slice,
          pkg,
        },
      }],
    });
  });

  it("does not create attention targets from lifecycle status alone", () => {
    const guidance = requestDetail([requestSlice("slice-guidance", "human_info_needed", "wp-guidance")]);
    const blocked = requestDetail([requestSlice("slice-blocked", "blocked", "wp-blocked")]);

    expect(requestAttentionTarget(guidance, new Map(), [], "guidance")).toBeNull();
    expect(requestAttentionTarget(blocked, new Map(), [], "blocked")).toBeNull();
    expect(requestActionableAttentionCounts(guidance, new Map(), [], [])).toEqual({ blockerCount: 0, guidanceCount: 0 });
    expect(requestActionableAttentionCounts(blocked, new Map(), [], [])).toEqual({ blockerCount: 0, guidanceCount: 0 });
  });

  it("counts a real clearable blocker record but not its projected count", () => {
    const slice = requestSlice("slice-blocked", "blocked", "wp-blocked");
    const detail = requestDetail([slice]);
    const projectedOnly = new Map<string, WorkPackageCard>([["wp-blocked", { id: "wp-blocked", status: "blocked", active_blocker_count: 1 }]]);
    const explicit = new Map<string, WorkPackageCard>([["wp-blocked", {
      id: "wp-blocked",
      status: "blocked",
      active_blocker_count: 1,
      active_blockers: [{ id: "blocker-clearable", active: true }],
    }]]);

    expect(requestActionableAttentionCounts(detail, projectedOnly, [], [])).toEqual({ blockerCount: 0, guidanceCount: 0 });
    expect(requestActionableAttentionCounts(detail, explicit, [], [])).toEqual({ blockerCount: 1, guidanceCount: 0 });
  });

  it("keeps top-bar attention limited to explicit human-action records", () => {
    const blocked = requestSlice("slice-blocked", "blocked", "wp-blocked");
    const reviewFailed = requestSlice("slice-review", "reviewing", "wp-review");
    reviewFailed.review_signal = { status: "failed" };
    const ciFailed = requestSlice("slice-ci", "ci_waiting", "wp-ci");
    ciFailed.pr_signal = { status: "open", number: 42, url: "https://example.test/pull/42", checks: { status: "failing" } };
    const guidanceStatus = requestSlice("slice-guidance", "human_info_needed", "wp-guidance");
    const detail = requestDetail([blocked, reviewFailed, ciFailed, guidanceStatus]);
    const pkg: WorkPackageCard = { id: "wp-blocked", status: "blocked", active_blocker_count: 1 };
    const edge: ActiveBlockingEdge = {
      id: "edge-explicit",
      blocker_id: "blocker-explicit",
      from: { kind: "work_package", id: "wp-source" },
      to: { kind: "work_package", id: pkg.id },
    };
    const blocker: BlockerItem = {
      id: edge.id,
      title: "Explicit blocker",
      repo: "fixture/repo",
      blockerCount: 1,
      detail: "A human can act on this blocker.",
      selection: { kind: "blocker", blocker: edge, detail, slice: blocked, pkg },
    };
    const guidance: GuidanceItem = {
      source: "guidance",
      id: "guidance-explicit",
      repo: "fixture/repo",
      repoKey: "fixture/repo",
      title: "Choose a path",
      packageId: guidanceStatus.id,
      detail: "A human decision is required.",
      guidance: { id: "guidance-explicit", work_package_id: guidanceStatus.id },
    };

    const items = dashboardAttentionItems([detail], new Map([[pkg.id, pkg]]), [edge], [guidance], [blocker]);

    expect(items.map((item) => item.kind).sort()).toEqual(["blocker", "guidance"]);
    expect(items.map((item) => item.key).sort()).toEqual(["blocker:edge-explicit", "guidance:guidance:guidance-explicit"]);
  });

  it("keeps generic lifecycle states out of top-bar human guidance", () => {
    const clarifying = requestDetail([]);
    clarifying.work_request = {
      ...clarifying.work_request,
      id: "wr-clarifying",
      status: "clarifying",
      operational_state: { key: "clarifying", label: "Clarifying" },
    };
    const readyForClarification = requestDetail([requestSlice("slice-clarifying", "ready_for_clarification", "wp-clarifying")]);
    readyForClarification.work_request.id = "wr-ready-for-clarification";
    const humanInfo = requestDetail([requestSlice("slice-human", "human_info_needed", "wp-human")]);
    humanInfo.work_request.id = "wr-human";
    const completed = requestDetail([]);
    completed.work_request.id = "wr-completed";
    completed.work_request.status = "human_info_needed";
    completed.work_request.operational_state = { key: "completed", label: "Completed" };

    const items = dashboardAttentionItems([clarifying, readyForClarification, humanInfo, completed], new Map(), [], [], []);

    expect(items).toEqual([]);
  });

  it("drops stale projected attention attached to a completed WorkRequest", () => {
    const slice = requestSlice("slice-completed", "blocked", "wp-completed");
    const completed = requestDetail([slice]);
    completed.work_request.completed_at = "2026-07-31T12:00:00Z";
    const pkg: WorkPackageCard = { id: "wp-completed", status: "blocked" };
    const guidance: GuidanceItem = {
      source: "guidance",
      id: "guidance-completed",
      repo: "fixture/repo",
      repoKey: "fixture/repo",
      title: "Stale guidance",
      packageId: pkg.id,
      detail: "This should no longer be actionable.",
      guidance: { id: "guidance-completed", work_package_id: pkg.id },
    };
    const blocker: BlockerItem = {
      id: "blocker-completed",
      title: "Stale blocker",
      repo: "fixture/repo",
      blockerCount: 1,
      detail: "This should no longer be actionable.",
      selection: { kind: "slice", detail: completed, slice, pkg },
    };

    expect(dashboardAttentionItems([completed], new Map([[pkg.id, pkg]]), [], [guidance], [blocker])).toEqual([]);
  });

  it("drops stale blocker and guidance attention attached to a delivered WorkPackage", () => {
    const slice = requestSlice("slice-delivered", "blocked", "wp-delivered");
    slice.operational_state = { key: "blocked", delivery_outcome: "pr_merged" };
    const detail = requestDetail([slice]);
    const pkg: WorkPackageCard = {
      id: "wp-delivered",
      status: "blocked",
      active_blockers: [{ id: "stale-blocker", active: true }],
    };
    const guidance: GuidanceItem = {
      source: "guidance",
      id: "stale-guidance",
      repo: "fixture/repo",
      repoKey: "fixture/repo",
      title: "Stale guidance",
      packageId: pkg.id,
      detail: "Already delivered.",
      guidance: { id: "stale-guidance", work_package_id: pkg.id },
    };
    const blocker: BlockerItem = {
      id: "stale-blocker",
      title: "Stale blocker",
      repo: "fixture/repo",
      blockerCount: 1,
      detail: "Already delivered.",
      selection: { kind: "slice", detail, slice, pkg },
    };

    expect(workPackageDirectAttention(detail, slice, pkg, [], [guidance])).toBeNull();
    expect(dashboardAttentionItems([detail], new Map([[pkg.id, pkg]]), [], [guidance], [blocker])).toEqual([]);
  });

  it("opens every attention item under a Group with blockers first", () => {
    const slice = requestSlice("slice-blocked", "blocked", "wp-blocked");
    slice.product_tree_node_id = "group-blocked";
    const guidanceSlice = requestSlice("slice-guidance", "planned", "wp-guidance");
    guidanceSlice.product_tree_node_id = "group-blocked";
    const detail = requestDetail([slice, guidanceSlice]);
    detail.product_tree = { nodes: [{ id: "group-blocked", title: "Blocked group", work_package_ids: [slice.id, guidanceSlice.id] }] };
    const pkg: WorkPackageCard = {
      id: "wp-blocked",
      status: "blocked",
      active_blockers: [{ id: "blocker-direct", active: true, summary: "Needs a human" }],
    };
    const guidancePackage: WorkPackageCard = {
      id: "wp-guidance",
      status: "planned",
      operational_state: { key: "human_info_needed", label: "Human Info Needed" },
    };
    const packages = new Map([[pkg.id, pkg], [guidancePackage.id, guidancePackage]]);
    const guidance: GuidanceItem = {
      source: "guidance",
      id: "guidance-group",
      repo: "fixture/repo",
      repoKey: "fixture/repo",
      title: "Choose a path",
      packageId: guidancePackage.id,
      detail: "A human decision is required.",
      guidance: { id: "guidance-group", work_package_id: guidancePackage.id },
    };

    expect(workPackageDirectAttention(detail, slice, pkg, [], [])).toMatchObject({
      label: "Blocked",
      target: { items: [{ kind: "blocker", selection: { blocker: { blocker_id: "blocker-direct" } } }] },
    });
    expect(groupDirectAttention(detail, "group-blocked", packages, [], [guidance])).toMatchObject({
      label: "Blocked",
      target: {
        items: [
          { kind: "blocker", selection: { blocker: { blocker_id: "blocker-direct" } } },
          { kind: "guidance", tone: "guidance", item: guidance },
        ],
      },
    });

    expect(workPackageDirectAttention(detail, guidanceSlice, guidancePackage, [], [guidance])).toMatchObject({
      label: "Guidance Needed",
      target: { items: [{ kind: "guidance", item: guidance }] },
    });
  });

  it("maps repo, WorkRequest, Group, and WorkPackage to the deepest board jump", () => {
    const slice = requestSlice("slice-jump", "blocked", "wp-jump");
    slice.title = "Jump package";
    slice.product_tree_node_id = "group-jump";
    const detail = requestDetail([slice]);
    detail.work_request.repo = "fixture/repo";
    detail.product_tree = { nodes: [{ id: "group-jump", title: "Jump group", work_package_ids: [slice.id] }] };
    const location = attentionLocationForSelection({ kind: "slice", detail, slice }, [detail]);

    expect(location).toEqual({
      repo: "fixture/repo",
      request: { id: "wr-attention", label: "Needs attention" },
      groups: [{ id: "group-jump", label: "Jump group" }],
      workPackage: { id: "slice-jump", label: "Jump package" },
    });
    expect(attentionJumpDestination(location, "work_package")).toEqual({
      requestId: "wr-attention",
      groupIds: ["group-jump"],
      workPackageId: "slice-jump",
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
