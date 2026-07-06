import { describe, expect, it } from "vitest";

import { dashboardEventsUrl, dashboardMutationWorkRequest, mergeDashboardPayload, mutationShouldRefreshDashboard, patchDashboardWorkRequest, removeDashboardWorkRequest, shouldSkipDashboardLoad } from "./runtime";
import type { DashboardPayload, WorkRequestCard } from "@/types/dashboard";

describe("dashboard runtime mutation helpers", () => {
  it("refreshes the board after slim mutation responses by default", () => {
    expect(mutationShouldRefreshDashboard({ ok: true, refresh: { dashboard: true, work_request_id: "wr-1" } })).toBe(true);
    expect(mutationShouldRefreshDashboard({ ok: true })).toBe(true);
  });

  it("allows a mutation response to opt out of a dashboard refresh", () => {
    expect(mutationShouldRefreshDashboard({ ok: true, refresh: { dashboard: false } })).toBe(false);
  });

  it("only skips overlapping unforced silent dashboard loads", () => {
    expect(shouldSkipDashboardLoad(true, "silent", false)).toBe(true);
    expect(shouldSkipDashboardLoad(true, "silent", true)).toBe(false);
    expect(shouldSkipDashboardLoad(true, "refresh", false)).toBe(false);
  });

  it("patches completed WorkRequests in-place", () => {
    const dashboard = dashboardWithRequest({ id: "wr-1", title: "Ship it", status: "ready_for_slicing" });
    const patched = patchDashboardWorkRequest(dashboard, {
      id: "wr-1",
      completed_at: "2026-06-25T12:00:00Z",
      completion_source: "operator",
      operational_state: { key: "completed", label: "Completed" },
    });

    expect(patched?.work_requests?.work_requests?.[0]).toMatchObject({
      id: "wr-1",
      completed_at: "2026-06-25T12:00:00Z",
      completion_source: "operator",
      operational_state: { key: "completed" },
    });
    expect(patched?.work_request_details?.[0]?.work_request).toMatchObject({ id: "wr-1", operational_state: { key: "completed" } });
  });

  it("moves archived WorkRequests out of the active board without losing card context", () => {
    const dashboard = dashboardWithRequest({ id: "wr-1", title: "Archive me", repo: "symphony-plus-plus" });
    const patched = patchDashboardWorkRequest(dashboard, { id: "wr-1", archived_at: "2026-06-25T12:00:00Z" }, { archive: true });

    expect(patched?.work_requests?.work_requests).toEqual([]);
    expect(patched?.work_request_details).toEqual([]);
    expect(patched?.archived_work_requests?.work_requests?.[0]).toMatchObject({
      id: "wr-1",
      title: "Archive me",
      repo: "symphony-plus-plus",
      archived_at: "2026-06-25T12:00:00Z",
    });
  });

  it("removes deleted WorkRequests from active, archived, and detail snapshots", () => {
    const dashboard = dashboardWithRequest({ id: "wr-1", title: "Delete me" });
    const patched = removeDashboardWorkRequest(
      {
        ...dashboard,
        archived_work_requests: { work_requests: [{ id: "wr-1", title: "Archived copy" }], total_count: 1 },
      },
      "wr-1",
    );

    expect(patched?.work_requests?.work_requests).toEqual([]);
    expect(patched?.archived_work_requests?.work_requests).toEqual([]);
    expect(patched?.work_request_details).toEqual([]);
  });

  it("reads compact WorkRequest mutation payloads", () => {
    expect(dashboardMutationWorkRequest({ work_request: { id: "wr-1", archived_at: "2026-06-25T12:00:00Z" } })).toEqual({
      id: "wr-1",
      archived_at: "2026-06-25T12:00:00Z",
    });
    expect(dashboardMutationWorkRequest({ work_request: { archived_at: "2026-06-25T12:00:00Z" } })).toBeNull();
  });

  it("merges deferred dashboard sections into the current snapshot", () => {
    const dashboard = dashboardWithRequest({ id: "wr-1", title: "Active" });
    const merged = mergeDashboardPayload(dashboard, {
      archived_work_requests: { work_requests: [{ id: "wr-old", title: "Archived" }], total_count: 1 },
      deferred: { dashboard_sections: false },
      solo_sessions: { solo_sessions: [{ id: "solo-1" }], total_count: 1 },
      work_request_details: [{ work_request: { id: "wr-1", title: "Hydrated" }, planned_slices: [{ id: "slice-1", work_request_id: "wr-1" }] }],
    });

    expect(merged?.work_requests).toBe(dashboard.work_requests);
    expect(merged).toMatchObject({
      archived_work_requests: { work_requests: [{ id: "wr-old" }] },
      deferred: { dashboard_sections: false },
      solo_sessions: { solo_sessions: [{ id: "solo-1" }] },
      work_request_details: [{ planned_slices: [{ id: "slice-1" }] }],
    });
  });

  it("uses the local operator API base for dashboard events", () => {
    expect(dashboardEventsUrl()).toBe("/api/v1/sympp/operator/dashboard/events");
  });
});

function dashboardWithRequest(workRequest: WorkRequestCard): DashboardPayload {
  return {
    work_requests: { work_requests: [workRequest], total_count: 1 },
    archived_work_requests: { work_requests: [], total_count: 0 },
    work_request_details: [{ work_request: workRequest }],
  };
}
