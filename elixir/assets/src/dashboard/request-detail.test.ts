import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { canArchiveWorkRequest, RequestDetailContent } from "./request-detail";
import { RecentDecisionsDisclosure } from "./detail-extras";
import type { WorkRequestCard, WorkRequestDetail } from "@/types/dashboard";
import { Dialog } from "@/components/ui/dialog";

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

  it("places status actions beside Add Comment before the summary", () => {
    const detail = {
      work_request: { id: "wr-actions", title: "Actionable request", status: "completed" },
      work_packages: [],
    } satisfies WorkRequestDetail;
    const html = renderToStaticMarkup(createElement(
      Dialog,
      { open: true },
      createElement(RequestDetailContent, {
        detail,
        onSelectGuidance: () => undefined,
        onCopyArchitectHandoff: async () => ({ handoff: { prompt: "" }, copied: false }),
        onArchiveWorkRequest: async () => undefined,
        onChangeWorkRequestState: async () => undefined,
        onDeleteWorkRequest: async () => undefined,
        canMutateOperatorActions: true,
        onSubmitComment: async () => ({ id: "comment-1", body: "" }),
        onResolveComment: async () => ({ id: "comment-1", body: "" }),
        canMutateComments: true,
      }),
    ));

    expect(html).toContain("WorkPackages");
    expect(html).toContain("Add Comment");
    expect(html).toContain("Archive Request");
    expect(html).toContain("Delete Request");
    expect(html).not.toContain("Show WorkRequest status actions");
    expect(html.indexOf("Add Comment")).toBeLessThan(html.indexOf("Archive Request"));
    expect(html.indexOf("Delete Request")).toBeLessThan(html.indexOf("WorkPackages"));
  });
});
