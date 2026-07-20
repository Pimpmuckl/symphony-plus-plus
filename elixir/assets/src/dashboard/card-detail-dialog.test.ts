import { describe, expect, it } from "vitest";

import type { WorkRequestDetail } from "@/types/dashboard";
import { cardDetailContentReady, matchingPackageResource, matchingRequestResource, type CardDetailDialogState, mergeRequestDetail } from "./card-detail-state";
import type { CardDetailSelection } from "./runtime";

const emptyState: CardDetailDialogState = {
  package: { payload: null, loading: true, error: null },
  request: { payload: null, loading: true, error: null },
  solo: { payload: null, loading: false, error: null },
};

describe("card detail summary hydration", () => {
  it("opens WorkRequest and WorkPackage content without waiting for enrichment", () => {
    const requestDetail = boardRequestDetail();
    const requestSelection: CardDetailSelection = { kind: "request", detail: requestDetail };
    const packageSelection: CardDetailSelection = {
      kind: "package",
      pkg: { id: "wp-1", title: "Build the fast path", status: "active" },
    };

    expect(cardDetailContentReady(requestSelection, emptyState)).toBe(true);
    expect(cardDetailContentReady(packageSelection, emptyState)).toBe(true);
  });

  it("merges lean enrichment without discarding board graph data", () => {
    const summary = boardRequestDetail();
    summary.work_request.open_question_count = 1;
    const enrichment: WorkRequestDetail = {
      work_request: {
        id: "wr-1",
        human_description: "Human-readable product intent",
        constraints: { compatibility: "none" },
      },
      decision_logs: [{ id: "decision-3", work_request_id: "wr-1", decision: "Ship the lean path" }],
      work_packages: [{ id: "slice-1", work_request_id: "wr-1", title: "Build the fast path", acceptance_criteria: ["Fast modal"] }],
      summary: { open_question_count: 0, decision_count: 12, comment_count: 4 },
    };

    const merged = mergeRequestDetail(summary, enrichment);

    expect(merged.work_request.title).toBe("Fast modal detail");
    expect(merged.work_request.human_description).toBe("Human-readable product intent");
    expect(merged.work_request.open_question_count).toBe(0);
    expect(merged.work_packages?.map((workPackage) => workPackage.id)).toEqual(["slice-1"]);
    expect(merged.work_packages?.[0].acceptance_criteria).toEqual(["Fast modal"]);
    expect(merged.summary).toMatchObject({ work_package_count: 1, decision_count: 12, comment_count: 4 });
  });

  it("ignores package enrichment from the previously selected package", () => {
    const selection: CardDetailSelection = {
      kind: "package",
      pkg: { id: "wp-new", title: "New package", status: "ready_for_worker" },
    };
    const state: CardDetailDialogState = {
      ...emptyState,
      package: {
        payload: { work_package: { id: "wp-old", title: "Old package", status: "implementing" } },
        loading: false,
        error: null,
        resourceKey: "wp-old",
      },
    };

    expect(matchingPackageResource(selection, state)).toMatchObject({
      payload: null,
      loading: true,
      error: null,
      resourceKey: "wp-new",
    });
  });

  it("surfaces only the selected WorkRequest enrichment error", () => {
    const selection: CardDetailSelection = { kind: "request", detail: boardRequestDetail() };
    const state: CardDetailDialogState = {
      ...emptyState,
      request: { payload: null, loading: false, error: "Detail unavailable", resourceKey: "wr-1" },
    };

    expect(matchingRequestResource(selection, state).error).toBe("Detail unavailable");
    expect(
      matchingRequestResource(
        { kind: "request", detail: { work_request: { id: "wr-other" } } },
        state,
      ).error,
    ).toBeNull();
  });
});

function boardRequestDetail(): WorkRequestDetail {
  return {
    work_request: {
      id: "wr-1",
      title: "Fast modal detail",
      status: "sliced",
      work_package_count: 1,
    },
    work_packages: [{ id: "slice-1", work_request_id: "wr-1", title: "Build the fast path" }],
    summary: { work_package_count: 1, decision_count: 0 },
  };
}
