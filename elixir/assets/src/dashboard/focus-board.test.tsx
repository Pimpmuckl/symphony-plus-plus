import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { WorkPackageCard, WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";

import { FocusBoard } from "./focus-board";
import { buildFocusBoardItems, scrollFocusLane } from "./focus-board-data";

describe("focus board", () => {
  it("hands wheel scrolling back to the page at either lane boundary", () => {
    const lane = { clientWidth: 300, scrollLeft: 0, scrollWidth: 900 };

    expect(scrollFocusLane(lane, 0, -100)).toBe(false);
    expect(scrollFocusLane(lane, 0, 100)).toBe(true);
    expect(lane.scrollLeft).toBe(100);
    lane.scrollLeft = 600;
    expect(scrollFocusLane(lane, 0, 100)).toBe(false);
    expect(scrollFocusLane(lane, 0, -100)).toBe(true);
  });

  it("assigns each request to one operational category and keeps only recently finished work", () => {
    const items = buildFocusBoardItems([
      request("wr-human", "Needs a decision", [slice("human", "ready_for_clarification")], { openQuestions: 1, status: "clarifying" }),
      request("wr-active", "Shipping", [slice("active", "implementing")]),
      request("wr-clarifying", "Still shaping", [], { status: "clarifying" }),
      request("wr-ready-to-clarify", "Ready to clarify", [slice("clarification-ready", "ready_for_clarification")], { status: "ready_for_clarification" }),
      request("wr-ready-for-slicing", "Ready for slicing", [], { status: "ready_for_slicing" }),
      request("wr-next", "Ready work", [slice("ready", "approved")]),
      request("wr-dependency", "Dependency wait", [slice("already-done", "delivered"), slice("waiting", "blocked", {
        dependency: { satisfied: 2, required: 2, active: 0, blocked: 1, unmet_work_package_ids: ["upstream"], inputs: [] },
      })]),
      request("wr-recent", "Just shipped", [slice("merged", "merged")], { completedAt: "2026-07-21T09:30:00Z" }),
      request("wr-delivery", "Delivery fallback", [slice("delivered", "merged", { recordedAt: "2026-07-21T09:00:00Z" })]),
      request("wr-old", "Old news", [slice("old", "merged")], { completedAt: "2026-07-19T10:00:00Z" }),
    ], "2026-07-21T10:00:00Z");

    expect(items.map(({ id, lane }) => [id, lane])).toEqual([
      ["wr-human", "attention"],
      ["wr-active", "active"],
      ["wr-clarifying", "waiting"],
      ["wr-ready-to-clarify", "waiting"],
      ["wr-ready-for-slicing", "waiting"],
      ["wr-next", "next"],
      ["wr-dependency", "waiting"],
      ["wr-recent", "recent"],
      ["wr-delivery", "recent"],
    ]);
    expect(new Set(items.map((item) => item.id)).size).toBe(items.length);
  });

  it("uses package runtime and active blocker context for request lanes", () => {
    const detail = request("wr-runtime", "Runtime work", [slice("runtime", "planned", { packageId: "wp-runtime" })]);
    const packages = new Map<string, WorkPackageCard>([["wp-runtime", { id: "wp-runtime", status: "active" }]]);
    const dependencyBlocked = request("wr-package-blocker", "Package blocker", [slice("package-blocker", "blocked", {
      dependency: { satisfied: 0, required: 1, active: 0, blocked: 1, unmet_work_package_ids: ["upstream"], inputs: [] },
      packageId: "wp-package-blocker",
    })]);
    const blockedPackages = new Map<string, WorkPackageCard>([["wp-package-blocker", {
      active_blocker_count: 1,
      id: "wp-package-blocker",
      status: "blocked",
    }]]);

    expect(buildFocusBoardItems([detail], Date.now(), packages)[0]?.lane).toBe("active");
    expect(buildFocusBoardItems([detail], Date.now(), packages, new Map([["wr-runtime", 1]]))[0]?.lane).toBe("attention");
    expect(buildFocusBoardItems([dependencyBlocked], Date.now(), blockedPackages)[0]?.lane).toBe("attention");
  });

  it("shows the package targeted by an active blocker edge in the attention frontier", () => {
    const detail = request("wr-edge", "Blocked by edge", [slice("slice-edge", "planned", { packageId: "wp-edge" })]);
    const html = renderToStaticMarkup(createElement(FocusBoard, {
      details: [detail],
      packages: [{ id: "wp-edge", status: "planned" }],
      activeBlockingEdges: [{
        id: "edge-1",
        blocker_id: "blocker-1",
        from: { kind: "work_package", id: "wp-upstream" },
        to: { kind: "work_package", id: "wp-edge" },
        work_request_id: "wr-edge",
        work_package_id: "wp-edge",
      }],
      onSelectAttention: () => undefined,
      onSelectGuidance: () => undefined,
      onSelectCard: () => undefined,
      primaryBranchByRepo: new Map(),
      updateAnimations: { motionFor: () => undefined },
    }));

    expect(html).toContain('aria-label="Needs you, 1"');
    expect(html).toContain('aria-label="Open attention details for Blocked by edge"');
    expect(html).toContain('title="slice-edge"');
  });

  it("keeps the cross-repository shelf above a persistent workbench", () => {
    const html = renderToStaticMarkup(createElement(FocusBoard, {
      details: [
        request("wr-human", "Needs a decision", [slice("human", "ready_for_clarification")], { openQuestions: 1, status: "clarifying" }),
        request("wr-active", "Shipping", [slice("active", "implementing")]),
        request("wr-next", "Ready work", [slice("ready", "approved")], { repo: "fixture/secondary" }),
        request("wr-next-primary", "Second ready work", [slice("second-ready", "approved")]),
        request("wr-waiting", "Dependency wait", [slice("waiting", "blocked", {
          dependency: { satisfied: 1, required: 2, active: 0, blocked: 1, unmet_work_package_ids: ["upstream"], inputs: [] },
        })]),
        request("wr-recent", "Just shipped", [slice("merged", "merged")], { completedAt: "2026-07-21T09:30:00Z" }),
      ],
      now: "2026-07-21T10:00:00Z",
      packages: [],
      activeBlockingEdges: [],
      onSelectAttention: () => undefined,
      onSelectGuidance: () => undefined,
      onSelectCard: () => undefined,
      primaryBranchByRepo: new Map(),
      updateAnimations: { motionFor: () => undefined },
    }));
    expect(html).toContain('aria-label="Needs you, 1"');
    expect(html).toContain('aria-label="Moving now, 3"');
    expect(html).toContain("fixture/secondary");
    expect(html).toContain('class="focus-board__workbench"');
    expect(html).toContain('data-mode="frontier"');
    expect(html).toContain('aria-label="Dependency board view"');
    expect(html).not.toContain("Dependency wait");
    expect(html).not.toContain("Just shipped");
  });

  it("renders the shared WorkRequest row with attention-scoped frontier work", () => {
    const html = renderToStaticMarkup(createElement(FocusBoard, {
      details: [request("wr-active", "Shipping", [
        slice("active-package", "implementing", { group: "Delivery", worker: { status: "active" } }),
        slice("failed-review", "reviewing", { group: "Quality", review: { status: "failed" } }),
      ])],
      packages: [],
      activeBlockingEdges: [],
      onSelectAttention: () => undefined,
      onSelectGuidance: () => undefined,
      onSelectCard: () => undefined,
      primaryBranchByRepo: new Map(),
      updateAnimations: { motionFor: () => undefined },
    }));

    expect(html).toContain("Focus Board");
    expect(html).toContain('class="focus-board ');
    expect(html).toContain("v3-request-row");
    expect(html).toContain("Close Shipping");
    expect(html).toContain('aria-pressed="true"');
    expect(html).not.toContain("Drag to pan");
    expect(html).toContain("Quality");
    expect(html).toContain("failed-review");
    expect(html).toContain("Review failed");
    expect(html).not.toContain("active-package");
    expect(html).not.toContain("focus-board__row");
  });
});

function request(
  id: string,
  title: string,
  workPackages: WorkRequestPackage[],
  options: { completedAt?: string; openQuestions?: number; repo?: string; status?: string } = {},
): WorkRequestDetail {
  const groupIds = [...new Set(workPackages.map((item) => item.product_tree_node_id).filter((value): value is string => Boolean(value)))];
  return {
    work_request: {
      id,
      title,
      repo: options.repo ?? "fixture/repo",
      status: options.status ?? "sliced",
      completed_at: options.completedAt,
      open_question_count: options.openQuestions,
      work_package_count: workPackages.length,
    },
    summary: { open_question_count: options.openQuestions, work_package_count: workPackages.length },
    work_packages: workPackages,
    product_tree: {
      nodes: groupIds.map((groupId, position) => ({
        id: groupId,
        position,
        title: groupId,
        work_package_ids: workPackages.filter((item) => item.product_tree_node_id === groupId).map((item) => item.id),
      })),
    },
  };
}

function slice(
  id: string,
  status: string,
  options: {
    dependency?: WorkRequestPackage["dependency_signal"];
    group?: string;
    packageId?: string;
    recordedAt?: string;
    review?: WorkRequestPackage["review_signal"];
    worker?: WorkRequestPackage["worker_signal"];
  } = {},
): WorkRequestPackage {
  return {
    id,
    work_request_id: "fixture",
    product_tree_node_id: options.group,
    work_package_id: options.packageId,
    title: id,
    status,
    dependency_signal: options.dependency,
    review_signal: options.review,
    worker_signal: options.worker,
    delivery: options.recordedAt ? { outcome: status, recorded_at: options.recordedAt } : undefined,
  };
}
