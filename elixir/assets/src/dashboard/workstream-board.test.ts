import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import type { WorkRequestDetail } from "@/types/dashboard";
import { mergeRequestDetailsWithExiting, WorkstreamBoard } from "./workstream-board";
import { finishedRequestChildrenStorageKey } from "./workstream-data";

describe("workstream board removal rendering", () => {
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
        guidanceItems: [],
        onSelectGuidance: () => undefined,
        onSelectCard: () => undefined,
        onCopyArchitectHandoff: async () => ({ handoff: {}, copied: false }),
        canMutateOperatorActions: false,
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

  it("replaces only the expanded WorkRequest body with the live execution graph", () => {
    const detail = graphRequestDetail();
    const openKey = finishedRequestChildrenStorageKey("repo", detail.work_request.id);
    const expanded = renderBoard(detail, { [openKey]: true });
    const collapsed = renderBoard(detail, {});

    expect(expanded).toContain('data-expanded="true"');
    expect(expanded).toContain('data-work-package-id="wp-active"');
    expect(expanded).toContain("Active · 1h 30m");
    expect(expanded).not.toContain("fixture-worker");
    expect(expanded).toContain('data-v3-context-path=');
    expect(expanded).toContain("Graph group");
    expect(expanded).toContain('data-work-package-id="wp-old"');
    expect(expanded).not.toContain("Show history");
    expect(expanded).not.toContain("v3-product-node");
    expect(collapsed).toContain("Graph request");
    expect(collapsed).toContain("fixture/repo");
    expect(collapsed).not.toContain("v3-execution-graph");
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
    work_request: { id: "wr-graph", title: "Graph request", repo: "fixture/repo", base_branch: "main", status: "implementing" },
    work_packages: [
      {
        id: "wp-active",
        work_request_id: "wr-graph",
        product_tree_node_id: "group-a",
        sequence: 1,
        title: "Active package",
        status: "implementing",
        worker_signal: { status: "active", active_since: "2026-07-18T08:00:00Z", run_label: "fixture-worker" },
      },
      { id: "wp-old", work_request_id: "wr-graph", product_tree_node_id: "group-a", sequence: 2, title: "Old package", status: "skipped" },
    ],
    product_tree: {
      available: true,
      execution_graph: {
        available: true,
        work_package_ids: ["wp-active", "wp-old"],
        topological_order: ["wp-active", "wp-old"],
        effective_edges: [],
        cycles: [],
      },
      nodes: [{ id: "group-a", title: "Graph group", work_package_ids: ["wp-active", "wp-old"] }],
    },
  };
}

function renderBoard(detail: WorkRequestDetail, expandedFinishedRequests: Record<string, boolean>) {
  return renderToStaticMarkup(
    createElement(WorkstreamBoard, {
      repoLabel: "repo",
      repoDetails: [detail],
      now: "2026-07-18T09:30:00Z",
      packages: [],
      activeBlockingEdges: [],
      guidanceItems: [],
      onSelectGuidance: () => undefined,
      onSelectCard: () => undefined,
      onCopyArchitectHandoff: async () => ({ handoff: {}, copied: false }),
      canMutateOperatorActions: false,
      expandedFinishedRequests,
      finishedRequestScopeKey: "repo",
      onSetFinishedRequestChildrenOpen: () => undefined,
      showContextBar: false,
      updateAnimations: noUpdateAnimations,
    }),
  );
}
