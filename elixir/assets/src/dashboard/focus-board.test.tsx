import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";

import { buildFocusBoardItems, FocusBoard } from "./focus-board";

describe("focus board", () => {
  it("assigns each request to one operational category and keeps only recently finished work", () => {
    const items = buildFocusBoardItems([
      request("wr-human", "Needs a decision", [slice("human", "ready_for_clarification")], { openQuestions: 1, status: "clarifying" }),
      request("wr-active", "Shipping", [slice("active", "implementing")]),
      request("wr-clarifying", "Still shaping", [], { status: "clarifying" }),
      request("wr-ready-to-clarify", "Ready to clarify", [slice("clarification-ready", "ready_for_clarification")], { status: "ready_for_clarification" }),
      request("wr-next", "Ready work", [slice("ready", "approved")]),
      request("wr-dependency", "Dependency wait", [slice("waiting", "blocked", {
        dependency: { satisfied: 1, required: 2, active: 0, blocked: 1, unmet_work_package_ids: ["upstream"], inputs: [] },
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

  it("uses consistent category disclosures with operator-priority defaults", () => {
    const html = renderToStaticMarkup(createElement(FocusBoard, {
      details: [
        request("wr-human", "Needs a decision", [slice("human", "ready_for_clarification")], { openQuestions: 1, status: "clarifying" }),
        request("wr-active", "Shipping", [slice("active", "implementing")]),
        request("wr-next", "Ready work", [slice("ready", "approved")]),
        request("wr-waiting", "Dependency wait", [slice("waiting", "blocked", {
          dependency: { satisfied: 1, required: 2, active: 0, blocked: 1, unmet_work_package_ids: ["upstream"], inputs: [] },
        })]),
        request("wr-recent", "Just shipped", [slice("merged", "merged")], { completedAt: "2026-07-21T09:30:00Z" }),
      ],
      now: "2026-07-21T10:00:00Z",
      packages: [],
      activeBlockingEdges: [],
      onSelectGuidance: () => undefined,
      onSelectCard: () => undefined,
      primaryBranchByRepo: new Map(),
      updateAnimations: { motionFor: () => undefined },
    }));
    const disclosureTag = (lane: string) => html.match(new RegExp(`<details[^>]*aria-labelledby="focus-board-${lane}"[^>]*>`))?.[0];
    const laneHtml = (lane: string, nextLane?: string) => html.slice(
      html.indexOf(`aria-labelledby="focus-board-${lane}"`),
      nextLane ? html.indexOf(`aria-labelledby="focus-board-${nextLane}"`) : undefined,
    );
    const frontierTitle = (title: string) => `class="v3-request-frontier-title" title="${title}">${title}`;

    expect(disclosureTag("attention")).toContain("open");
    expect(disclosureTag("active")).toContain("open");
    expect(disclosureTag("next")).not.toContain("open");
    expect(disclosureTag("recent")).not.toContain("open");
    expect(disclosureTag("waiting")).not.toContain("open");
    expect(html.slice(html.indexOf('aria-labelledby="focus-board-recent"'), html.indexOf('aria-labelledby="focus-board-waiting"'))).toContain("text-emerald-600");
    expect(laneHtml("attention", "active")).toContain(frontierTitle("human"));
    expect(laneHtml("active", "next")).toContain(frontierTitle("active"));
    expect(laneHtml("next", "recent")).toContain(frontierTitle("ready"));
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
  options: { completedAt?: string; openQuestions?: number; status?: string } = {},
): WorkRequestDetail {
  const groupIds = [...new Set(workPackages.map((item) => item.product_tree_node_id).filter((value): value is string => Boolean(value)))];
  return {
    work_request: {
      id,
      title,
      repo: "fixture/repo",
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
    recordedAt?: string;
    review?: WorkRequestPackage["review_signal"];
    worker?: WorkRequestPackage["worker_signal"];
  } = {},
): WorkRequestPackage {
  return {
    id,
    work_request_id: "fixture",
    product_tree_node_id: options.group,
    title: id,
    status,
    dependency_signal: options.dependency,
    review_signal: options.review,
    worker_signal: options.worker,
    delivery: options.recordedAt ? { outcome: status, recorded_at: options.recordedAt } : undefined,
  };
}
