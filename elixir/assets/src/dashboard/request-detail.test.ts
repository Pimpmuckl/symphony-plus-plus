import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { canArchiveWorkRequest } from "./request-detail";
import { RecentDecisionsDisclosure } from "./detail-extras";
import type { WorkRequestCard, WorkRequestDetail } from "@/types/dashboard";

describe("request detail actions", () => {
  it("allows archive for derived delivered requests before completion is persisted", () => {
    expect(
      canArchiveWorkRequest({
        id: "wr-delivered",
        status: "sliced",
        completed_at: null,
        archived_at: null,
        operational_state: { key: "delivered", label: "Delivered", tone: "success" },
      } satisfies WorkRequestCard),
    ).toBe(true);
  });

  it("keeps archive hidden for active or already archived requests", () => {
    expect(
      canArchiveWorkRequest({
        id: "wr-active",
        status: "sliced",
        completed_at: null,
        archived_at: null,
        operational_state: { key: "active", label: "Active", tone: "info" },
      } satisfies WorkRequestCard),
    ).toBe(false);

    expect(
      canArchiveWorkRequest({
        id: "wr-archived",
        status: "sliced",
        completed_at: "2026-06-14T10:00:00.000000Z",
        archived_at: "2026-06-14T10:01:00.000000Z",
        operational_state: { key: "completed", label: "Completed", tone: "success" },
      } satisfies WorkRequestCard),
    ).toBe(false);
  });

  it("reports the total decision count while listing only recent entries", () => {
    const detail = {
      work_request: { id: "wr-decisions" },
      decision_logs: [
        { id: "decision-5", work_request_id: "wr-decisions", decision: "Fifth" },
        { id: "decision-4", work_request_id: "wr-decisions", decision: "Fourth" },
        { id: "decision-3", work_request_id: "wr-decisions", decision: "Third" },
      ],
      summary: { decision_count: 5 },
    } satisfies WorkRequestDetail;

    expect(renderToStaticMarkup(createElement(RecentDecisionsDisclosure, { detail }))).toContain("5 recorded");
  });
});
