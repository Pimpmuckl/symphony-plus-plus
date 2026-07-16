import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import type { WorkRequestDetail } from "@/types/dashboard";
import { mergeRequestDetailsWithExiting, WorkstreamBoard } from "./workstream-board";

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
});

const noUpdateAnimations = {
  motionFor: () => undefined,
};

function requestDetail(id: string): WorkRequestDetail {
  return {
    work_request: { id, title: id },
  };
}
