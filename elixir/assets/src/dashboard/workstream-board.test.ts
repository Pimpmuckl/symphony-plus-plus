import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import type { WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import { WorkstreamBoard } from "./workstream-board";
import { architectStartPrompt, mergeRequestDetailsWithExiting, requestIdentityCopyText, visibleRequestBranch } from "./workstream-utils";
import { activeWorkRequestDetails, finishedRequestChildrenStorageKey } from "./workstream-data";

describe("workstream board removal rendering", () => {
  it("renders priority WorkRequest cards before compact execution details arrive", () => {
    const [detail] = activeWorkRequestDetails({
      work_requests: {
        work_requests: [{ id: "wr-priority", title: "Priority request", work_package_count: 3, open_question_count: 1 }],
        total_count: 1,
      },
    });

    expect(detail).toMatchObject({
      work_request: { id: "wr-priority", title: "Priority request" },
      summary: { work_package_count: 3, open_question_count: 1 },
    });
    expect(detail?.work_packages).toBeUndefined();
  });

  it("overlays fresh priority fields while retaining compact execution children", () => {
    const [detail] = activeWorkRequestDetails({
      work_requests: {
        work_requests: [{ id: "wr-priority", title: "Fresh title", status: "sliced", work_package_count: 4 }],
        total_count: 1,
      },
      work_request_details: [{
        work_request: { id: "wr-priority", title: "Stale title", status: "clarifying" },
        summary: { work_package_count: 2, decision_count: 1 },
        work_packages: [{ id: "slice-1", work_request_id: "wr-priority" }],
      }],
    });

    expect(detail).toMatchObject({
      work_request: { title: "Fresh title", status: "sliced" },
      summary: { work_package_count: 4, decision_count: 1 },
      work_packages: [{ id: "slice-1" }],
    });
  });

  it("keeps removed request details renderable while they exit", () => {
    const active = requestDetail("wr-active");
    const removed = requestDetail("wr-removed");

    expect(mergeRequestDetailsWithExiting([active], [removed]).map((detail) => detail.work_request.id)).toEqual(["wr-active", "wr-removed"]);
    expect(mergeRequestDetailsWithExiting([active], [active, removed]).map((detail) => detail.work_request.id)).toEqual(["wr-active", "wr-removed"]);
  });

  it("never renders packages without an owning WorkRequest row", () => {
    const html = renderToStaticMarkup(
      createElement(WorkstreamBoard, {
        repoLabel: "repo",
        repoDetails: [],
        packages: [{ id: "pkg-stale", title: "Stale package" }],
        activeBlockingEdges: [],
        onSelectGuidance: () => undefined,
        onSelectCard: () => undefined,
        primaryBranch: "main",
        expandedFinishedRequests: {},
        finishedRequestScopeKey: "repo",
        onSetFinishedRequestChildrenOpen: () => undefined,
        showContextBar: false,
        updateAnimations: noUpdateAnimations,
      }),
    );

    expect(html).not.toContain("Execution records");
    expect(html).not.toContain("Stale package");
  });

  it("renders the compact shared row header and expands the live execution graph", () => {
    const detail = graphRequestDetail();
    const openKey = finishedRequestChildrenStorageKey("repo", detail.work_request.id);
    const expanded = renderBoard(detail, { [openKey]: true });
    const collapsed = renderBoard(detail, {});

    expect(expanded).toContain('data-expanded="true"');
    expect(expanded).toContain('aria-label="Loading execution graph"');
    expect(collapsed).toContain("Graph request");
    expect(collapsed).toContain("fixture/repo");
    expect(collapsed).toContain("feature/focus-board");
    expect(collapsed).toContain("Graph group");
    expect(collapsed).toContain("Second group");
    expect(collapsed).toContain("Active package");
    expect(collapsed).toContain("Review package");
    expect(collapsed).toContain("CI package");
    expect(collapsed).toContain("Fourth active package");
    expect(collapsed).toContain("Implementing");
    expect(collapsed).toContain("Review 3/4");
    expect(collapsed).toContain("CI 2/3");
    expect(collapsed.match(/data-last="true"/g)).toHaveLength(2);
    expect(collapsed.match(/data-frontier-wire-trunk="true"/g)).toHaveLength(2);
    expect(collapsed.match(/data-frontier-wire="true"/g)).toHaveLength(4);
    expect(collapsed).toContain('<span class="v3-request-frontier-group-title-label">Graph group</span>');
    expect(collapsed).toContain('class="v3-request-frontier-title" title="Active package"');
    expect(collapsed).toContain('aria-label="Open WorkPackage details for Active package"');
    expect(collapsed).not.toMatch(/[├└→]/);
    expect(collapsed).not.toContain("more active");
    expect(collapsed).not.toContain("Terminal stale package");
    expect(collapsed).toContain('href="https://github.com/example/fixture/pull/101"');
    expect(collapsed).toContain('<span class="v3-request-frontier-pr-label" aria-hidden="true">PR</span><span class="v3-request-frontier-pr-number" aria-hidden="true">#101</span>');
    expect(collapsed).toContain("PR #101");
    expect(collapsed).toContain('aria-label="Open request details"');
    expect(collapsed).toContain('aria-label="Copy WorkRequest identity"');
    expect(collapsed).toContain('class="v3-request-controls"');
    expect(requestIdentityCopyText(detail)).toBe("Graph request - WR ID: wr-graph");
    expect(collapsed).toContain('role="progressbar"');
    expect(collapsed).toContain('aria-valuenow="59"');
    expect(collapsed).toContain('<span class="v3-progress-value" aria-hidden="true">59%</span>');
    expect(collapsed.indexOf("v3-request-main")).toBeLessThan(collapsed.indexOf("v3-request-progress"));
    expect(collapsed.indexOf("v3-row-badge-slot")).toBeLessThan(collapsed.indexOf("v3-request-progress"));
    expect(collapsed.indexOf("v3-request-progress")).toBeLessThan(collapsed.indexOf("v3-request-frontier"));
    expect(collapsed).not.toContain('class="v3-row-status"');
    expect(collapsed).not.toContain("v3-progress-state");
    expect(collapsed).not.toContain("v3-request-summary");
    expect(collapsed).not.toContain("v3-entity-kind");
    expect(collapsed).not.toContain("Architect handoff");
    expect(collapsed).not.toContain("v3-execution-graph");
  });

  it("ages the request from the newest update across non-frontier packages", () => {
    const collapsed = renderBoard(graphRequestDetail(), {}, [{ id: "pkg-terminal", updated_at: "2026-07-18T09:25:00Z" }]);
    const daysOld = renderBoard({ work_request: { id: "wr-old", title: "Old request", status: "active", updated_at: "2026-07-16T07:30:00Z" } }, {});
    const requestNewer = renderBoard({
      work_request: { id: "wr-newer", title: "Recently updated request", status: "active", updated_at: "2026-07-18T09:28:00Z" },
      work_packages: [{ id: "wp-newer", work_request_id: "wr-newer", work_package_id: "pkg-newer", status: "active" }],
    }, {}, [{ id: "pkg-newer", status: "active", updated_at: "2026-07-18T09:00:00Z" }]);

    expect(collapsed).toContain("Active · 5m");
    expect(collapsed).not.toContain("Terminal stale package");
    expect(daysOld).toContain("Active · 2d");
    expect(daysOld).not.toContain("Active · 2d 2h");
    expect(requestNewer).toContain("Active · 2m");
  });

  it("omits generic package activity that only repeats the overall request state", () => {
    const blocked = renderBoard({
      work_request: { id: "wr-blocked", title: "Blocked request", status: "blocked" },
      work_packages: [{ id: "wp-blocked", work_request_id: "wr-blocked", title: "Blocked package", status: "blocked" }],
    }, {});
    const active = renderBoard({
      work_request: { id: "wr-active", title: "Active request", status: "active", updated_at: "2026-07-18T09:20:00Z" },
      work_packages: [{ id: "wp-active", work_request_id: "wr-active", title: "Active package", status: "active" }],
    }, {});
    const linkedPackageActive = renderBoard({
      work_request: { id: "wr-linked", title: "Linked runtime", status: "planned" },
      work_packages: [{ id: "slice-linked", work_request_id: "wr-linked", work_package_id: "wp-linked", title: "Linked active package", status: "planned" }],
    }, {}, [{ id: "wp-linked", status: "active" }]);

    expect(blocked).toContain('class="sr-only">Blocked</span>');
    expect(blocked).not.toContain("data-first");
    expect(blocked).not.toContain('class="v3-request-frontier-activity">Blocked</span>');
    expect(active).toContain('class="sr-only">Active · 10m</span>');
    expect(active).not.toContain('class="v3-request-frontier-activity">Active</span>');
    expect(linkedPackageActive).toContain("Linked active package");
  });

  it("hides primary branches, preserves feature branches, and renders the local empty-work prompt", () => {
    const detail: WorkRequestDetail = {
      work_request: { id: "wr-empty", title: "Empty request", repo: "fixture/repo", base_branch: "main", status: "clarifying" },
      clarification_questions: [{ id: "question-1", work_request_id: "wr-empty", status: "open" }],
      product_tree: { nodes: [] },
      work_packages: [],
    };
    const expanded = renderBoard(detail, { [finishedRequestChildrenStorageKey("repo", "wr-empty")]: true });

    expect(visibleRequestBranch("main", "main")).toBeUndefined();
    expect(visibleRequestBranch("master", "develop")).toBeUndefined();
    expect(visibleRequestBranch("develop", "develop")).toBeUndefined();
    expect(visibleRequestBranch("feature/focus-board", "main")).toBe("feature/focus-board");
    expect(expanded).not.toContain(">main<");
    expect(expanded).toContain("No work has been created yet. Copy a prompt to start this WorkRequest with an architect agent.");
    expect(expanded).toContain("lucide-copy");
    expect(expanded).not.toContain("lucide-clipboard-copy");
    expect(expanded).not.toContain("Open Question");
    expect(expanded).not.toContain("v3-execution-graph");
    expect(architectStartPrompt("wr-empty")).toBe("Take a look at WorkRequest wr-empty using $symphony-plus-plus-mcp:symphony-architect. Check it out, bring me any questions if there are any, then let's go.");
  });
});

const noUpdateAnimations = {
  motionFor: () => undefined,
};

function requestDetail(id: string): WorkRequestDetail {
  return {
    work_request: { id, title: id },
  };
}

function graphRequestDetail(): WorkRequestDetail {
  return {
    work_request: {
      id: "wr-graph",
      title: "Graph request",
      repo: "fixture/repo",
      base_branch: "feature/focus-board",
      status: "implementing",
      updated_at: "2026-07-18T07:00:00Z",
    },
    work_packages: [
      {
        id: "wp-active",
        work_request_id: "wr-graph",
        product_tree_node_id: "group-a",
        sequence: 1,
        title: "Active package",
        status: "implementing",
        updated_at: "2026-07-18T09:10:00Z",
        worker_signal: {
          status: "active",
          active_since: "2026-07-18T08:00:00Z",
          last_activity: "2026-07-18T09:15:00Z",
          run_label: "fixture-worker",
        },
        pr_signal: { status: "open", number: 101, url: "https://github.com/example/fixture/pull/101" },
      },
      {
        id: "wp-review",
        work_request_id: "wr-graph",
        product_tree_node_id: "group-a",
        sequence: 2,
        title: "Review package",
        status: "reviewing",
        updated_at: "2026-07-18T09:11:00Z",
        review_signal: { status: "in_progress", current: 3, total: 4 },
        pr_signal: { status: "open", number: 102, url: "https://github.com/example/fixture/pull/102" },
      },
      {
        id: "wp-ci",
        work_request_id: "wr-graph",
        product_tree_node_id: "group-b",
        sequence: 3,
        title: "CI package",
        status: "ci_waiting",
        updated_at: "2026-07-18T09:12:00Z",
        pr_signal: { status: "open", number: 103, url: "https://github.com/example/fixture/pull/103", checks: { status: "pending", current: 2, total: 3 } },
      },
      {
        id: "wp-hidden",
        work_request_id: "wr-graph",
        product_tree_node_id: "group-b",
        sequence: 4,
        title: "Fourth active package",
        status: "implementing",
        updated_at: "2026-07-18T09:20:00Z",
        worker_signal: { status: "active" },
      },
      {
        id: "wp-old",
        work_request_id: "wr-graph",
        work_package_id: "pkg-terminal",
        product_tree_node_id: "group-a",
        sequence: 5,
        title: "Terminal stale package",
        status: "merged",
        review_signal: { status: "in_progress", current: 1, total: 2 },
      },
    ],
    product_tree: {
      available: true,
      execution_graph: {
        available: true,
        work_package_ids: ["wp-active", "wp-review", "wp-ci", "wp-hidden", "wp-old"],
        topological_order: ["wp-active", "wp-review", "wp-ci", "wp-hidden", "wp-old"],
        effective_edges: [],
        cycles: [],
      },
      nodes: [
        { id: "group-a", title: "Graph group", work_package_ids: ["wp-active", "wp-review", "wp-old"] },
        { id: "group-b", title: "Second group", work_package_ids: ["wp-ci", "wp-hidden"] },
      ],
    },
  };
}

function renderBoard(detail: WorkRequestDetail, expandedFinishedRequests: Record<string, boolean>, packages: WorkPackageCard[] = []) {
  return renderToStaticMarkup(
    createElement(WorkstreamBoard, {
      repoLabel: "repo",
      repoDetails: [detail],
      now: "2026-07-18T09:30:00Z",
      packages,
      activeBlockingEdges: [],
      onSelectGuidance: () => undefined,
      onSelectCard: () => undefined,
      primaryBranch: "main",
      expandedFinishedRequests,
      finishedRequestScopeKey: "repo",
      onSetFinishedRequestChildrenOpen: () => undefined,
      showContextBar: false,
      updateAnimations: noUpdateAnimations,
    }),
  );
}
