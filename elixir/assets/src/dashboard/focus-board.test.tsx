import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { WorkPackageCard, WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";

import { FocusBoard } from "./focus-board";
import { buildFocusBoardItems } from "./focus-board-data";
import { focusAttachOffset, focusCameraTop, focusSectionOffset, focusSpaceOffsets, focusTravelScale } from "./focus-board-motion";

describe("focus board", () => {
  it("uses existing row slack before reserving expanded board space", () => {
    const rects = [
      { id: "selected", left: 400, top: 300, width: 200, height: 100 },
      { id: "tall-peer", left: 700, top: 300, width: 200, height: 160 },
      { id: "below", left: 400, top: 500, width: 200, height: 200 },
    ];

    expect(focusAttachOffset(rects, "selected")).toBe(60);
    expect(focusAttachOffset(rects, "tall-peer")).toBe(0);
    expect(focusAttachOffset(rects.map((rect) => rect.id === "tall-peer" ? { ...rect, height: 40 } : rect), "tall-peer")).toBe(60);
  });

  it("makes directional space without moving the selected request to another row", () => {
    const offsets = focusSpaceOffsets([
      { id: "selected", left: 400, top: 300, width: 200, height: 100 },
      { id: "above", left: 400, top: 100, width: 200, height: 100 },
      { id: "left", left: 100, top: 300, width: 200, height: 100 },
      { id: "right", left: 700, top: 300, width: 200, height: 100 },
      { id: "below", left: 400, top: 550, width: 200, height: 100 },
    ], "selected", { width: 1200, height: 800 }, 40);

    expect(offsets.get("selected")).toEqual({ opacity: 1, x: -360, y: 0 });
    expect(offsets.get("above")).toEqual({ opacity: 1, x: 0, y: 0 });
    expect(offsets.get("left")?.x).toBeLessThan(0);
    expect(offsets.get("right")?.x).toBeGreaterThan(0);
    expect(offsets.get("below")).toMatchObject({ opacity: 0, x: 0 });
    expect(offsets.get("below")?.y).toBeGreaterThan(0);
  });

  it("keeps small boards from over-ejecting surrounding requests", () => {
    expect(focusTravelScale(120, 800)).toBe(0);
    expect(focusTravelScale(640, 800)).toBe(1);

    const offsets = focusSpaceOffsets([
      { id: "selected", left: 400, top: 300, width: 200, height: 100 },
      { id: "right", left: 700, top: 300, width: 200, height: 100 },
      { id: "offscreen", left: 400, top: 900, width: 200, height: 100 },
    ], "selected", { width: 1200, height: 800 }, 40, 0);

    expect(offsets.get("right")).toEqual({ opacity: 1, x: 0, y: 0 });
    expect(offsets.get("offscreen")).toEqual({ opacity: 1, x: 0, y: 0 });
    expect(focusSectionOffset(600, 800, 0)).toBe(0);
    expect(focusSectionOffset(900, 800)).toBe(0);
  });

  it("moves the camera only when the focused board does not fit in the viewport", () => {
    expect(focusCameraTop(252, 626, 228, 1_300, 88)).toBe(252);
    expect(focusCameraTop(252, 626, 800, 800, 88)).toBe(790);
    expect(focusCameraTop(252, 40, 228, 800, 88)).toBe(204);
  });

  it("assigns each request to one operational category and keeps only recently finished work", () => {
    const items = buildFocusBoardItems([
      request("wr-human", "Needs a decision", [slice("human", "ready_for_clarification")], { openQuestions: 1, status: "clarifying" }),
      request("wr-active", "Shipping", [slice("active", "implementing")]),
      request("wr-clarifying", "Still shaping", [], { status: "clarifying" }),
      request("wr-ready-to-clarify", "Ready to clarify", [slice("clarification-ready", "ready_for_clarification")], { status: "ready_for_clarification" }),
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
      ["wr-clarifying", "next"],
      ["wr-ready-to-clarify", "next"],
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

    expect(html).toContain('aria-labelledby="focus-board-attention"');
    expect(html).toContain('aria-label="Open attention details for Blocked by edge"');
    expect(html).toContain('title="slice-edge"');
  });

  it("uses consistent category disclosures with operator-priority defaults", () => {
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
    const disclosureTag = (lane: string) => html.match(new RegExp(`<section[^>]*aria-labelledby="focus-board-${lane}"[^>]*>`))?.[0];
    const disclosureToggle = (lane: string) => laneHtml(lane).match(/<button[^>]*aria-expanded="(?:true|false)"[^>]*>/)?.[0];
    const laneHtml = (lane: string, nextLane?: string) => html.slice(
      html.indexOf(`aria-labelledby="focus-board-${lane}"`),
      nextLane ? html.indexOf(`aria-labelledby="focus-board-${nextLane}"`) : undefined,
    );
    const frontierTitle = (title: string) => `class="v3-request-frontier-title" title="${title}"><span class="v3-request-frontier-title-copy">${title}</span>`;

    expect(disclosureTag("attention")).toContain('data-section-open="true"');
    expect(disclosureTag("active")).toContain('data-section-open="true"');
    expect(disclosureTag("next")).toContain('data-section-open="false"');
    expect(disclosureTag("recent")).toContain('data-section-open="false"');
    expect(disclosureTag("waiting")).toContain('data-section-open="false"');
    expect(disclosureToggle("attention")).toContain('aria-expanded="true"');
    expect(disclosureToggle("next")).toContain('aria-expanded="false"');
    expect(laneHtml("next", "recent")).toContain('aria-hidden="true" inert=""');
    expect(html.slice(html.indexOf('aria-labelledby="focus-board-recent"'), html.indexOf('aria-labelledby="focus-board-waiting"'))).toContain("text-emerald-600");
    expect(laneHtml("attention", "active")).toContain(frontierTitle("human"));
    expect(laneHtml("active", "next")).toContain(frontierTitle("active"));
    expect(laneHtml("next", "recent")).toContain(frontierTitle("ready"));
    expect(laneHtml("next", "recent")).toContain(frontierTitle("second-ready"));
    expect(laneHtml("next", "recent")).toContain('data-focus-repo-key="fixture/repo"');
    expect(laneHtml("next", "recent")).toContain('data-focus-repo-key="fixture/secondary"');
    expect(laneHtml("next", "recent")).toContain("fixture/secondary");
    expect(laneHtml("next", "recent")).not.toContain("1 request");
    expect(laneHtml("recent", "waiting")).toContain(frontierTitle("merged"));
    expect(laneHtml("waiting")).toContain(frontierTitle("waiting"));
    expect(laneHtml("waiting")).toContain("Waiting 1/2");
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
    expect(html).toContain("Expand Shipping");
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
