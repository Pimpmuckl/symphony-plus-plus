import { afterEach, describe, expect, it, vi } from "vitest";

import { createLatestTaskQueue, dashboardBootstrapFromRuntimeConfig, dashboardEventsUrl, dashboardMutationWorkRequest, dashboardRefreshPath, enqueueLatestTask, mergeDashboardPayload, mutationShouldRefreshDashboard, patchDashboardWorkRequest, removeDashboardWorkRequest } from "./runtime";
import { createBestEffortGithubSync, createDashboardEventRefresh } from "./dashboard-demand-loading";
import type { DashboardPayload, WorkRequestCard } from "@/types/dashboard";

describe("dashboard runtime mutation helpers", () => {
  afterEach(() => vi.useRealTimers());

  it("refreshes the board after slim mutation responses by default", () => {
    expect(mutationShouldRefreshDashboard({ ok: true, refresh: { dashboard: true, work_request_id: "wr-1" } })).toBe(true);
    expect(mutationShouldRefreshDashboard({ ok: true })).toBe(true);
  });

  it("allows a mutation response to opt out of a dashboard refresh", () => {
    expect(mutationShouldRefreshDashboard({ ok: true, refresh: { dashboard: false } })).toBe(false);
  });

  it("runs one active and one latest trailing task for a burst", async () => {
    const queue = createLatestTaskQueue<string>();
    const runs: string[] = [];
    let releaseFirst!: () => void;
    const firstGate = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    const run = async (task: string) => {
      runs.push(task);
      if (task === "first") await firstGate;
    };

    const settled = enqueueLatestTask(queue, "first", run);
    for (let index = 0; index < 20; index += 1) void enqueueLatestTask(queue, `burst-${index}`, run);

    expect(runs).toEqual(["first"]);
    releaseFirst();
    await settled;
    expect(runs).toEqual(["first", "burst-19"]);
  });

  it("does not let an ordinary invalidation replace a queued reconnect", async () => {
    const queue = createLatestTaskQueue<string>();
    const runs: string[] = [];
    let releaseFirst!: () => void;
    const firstGate = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    const run = async (task: string) => {
      runs.push(task);
      if (task === "first") await firstGate;
    };
    const mergePending = (pending: string, next: string) =>
      pending === "reconnect" || next === "reconnect" ? "reconnect" : next;

    const settled = enqueueLatestTask(queue, "first", run, mergePending);
    void enqueueLatestTask(queue, "reconnect", run, mergePending);
    void enqueueLatestTask(queue, "silent", run, mergePending);

    releaseFirst();
    await settled;
    expect(runs).toEqual(["first", "reconnect"]);
  });

  it("drains work enqueued during queue finalization", async () => {
    const queue = createLatestTaskQueue<string>();
    const runs: string[] = [];
    const run = async (task: string) => {
      runs.push(task);
      if (task === "first") {
        void Promise.resolve().then(() => {
          queueMicrotask(() => void enqueueLatestTask(queue, "late", run));
        });
      }
    };

    await enqueueLatestTask(queue, "first", run);
    expect(runs).toEqual(["first", "late"]);
    expect(queue).toEqual({ active: null, pending: null });
  });

  it("defers hidden dashboard events and refreshes once when visible", () => {
    let visibility: DocumentVisibilityState = "hidden";
    const refresh = vi.fn();
    const eventRefresh = createDashboardEventRefresh(refresh, () => visibility);

    eventRefresh.dashboardChanged();
    eventRefresh.dashboardChanged();
    expect(refresh).not.toHaveBeenCalled();

    visibility = "visible";
    eventRefresh.visibilityChanged();
    eventRefresh.visibilityChanged();
    expect(refresh).toHaveBeenCalledTimes(1);
  });

  it("runs one immediate refresh and one trailing refresh for a visible burst", () => {
    vi.useFakeTimers();
    vi.setSystemTime(1_000);
    const refresh = vi.fn();
    const eventRefresh = createDashboardEventRefresh(refresh, () => "visible", 100);

    eventRefresh.dashboardChanged();
    eventRefresh.dashboardChanged();
    eventRefresh.dashboardChanged();
    expect(refresh).toHaveBeenCalledTimes(1);

    vi.advanceTimersByTime(100);
    expect(refresh).toHaveBeenCalledTimes(2);
  });

  it("refreshes from the operator-priority base endpoint", () => {
    expect(dashboardRefreshPath()).toBe("/dashboard");
  });

  it("accepts only a shaped dashboard bootstrap and otherwise falls back", () => {
    const dashboard = { work_requests: { work_requests: [], total_count: 0 }, deferred: { dashboard_sections: true } };
    expect(dashboardBootstrapFromRuntimeConfig({ dashboard })).toBe(dashboard);
    expect(dashboardBootstrapFromRuntimeConfig({ dashboard: { work_requests: [] } })).toBeNull();
    expect(dashboardBootstrapFromRuntimeConfig({ dashboard: "<script>alert(1)</script>" })).toBeNull();
  });

  it("starts best-effort GitHub sync when deferred dashboard data is ready", async () => {
    const run = vi.fn().mockResolvedValue(undefined);
    const sync = createBestEffortGithubSync(() => "visible");

    await sync.ready(run);

    expect(run).toHaveBeenCalledTimes(1);
  });

  it("suppresses GitHub sync during cooldown and retries when the tab becomes visible", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(1_000);
    let visibility: DocumentVisibilityState = "visible";
    const run = vi.fn().mockResolvedValue(undefined);
    const sync = createBestEffortGithubSync(() => visibility, 100);

    await sync.ready(run);
    await sync.ready(run);
    expect(run).toHaveBeenCalledTimes(1);

    visibility = "hidden";
    vi.advanceTimersByTime(100);
    await sync.visibilityChanged();
    expect(run).toHaveBeenCalledTimes(1);

    visibility = "visible";
    await sync.visibilityChanged();
    expect(run).toHaveBeenCalledTimes(2);
  });

  it("lets successful GitHub sync use the existing dashboard refresh path", async () => {
    const request = vi.fn().mockResolvedValue({ ok: true, refresh: { dashboard: true } });
    const refresh = vi.fn().mockResolvedValue(undefined);
    const sync = createBestEffortGithubSync(() => "visible");

    await sync.ready(async () => {
      const payload = await request();
      if (mutationShouldRefreshDashboard(payload)) await refresh();
    });

    expect(request).toHaveBeenCalledTimes(1);
    expect(refresh).toHaveBeenCalledTimes(1);
  });

  it("ignores GitHub sync failures and remains retryable", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(1_000);
    const run = vi.fn().mockRejectedValueOnce(new Error("offline")).mockResolvedValue(undefined);
    const sync = createBestEffortGithubSync(() => "visible", 100);

    await expect(sync.ready(run)).resolves.toBeUndefined();
    vi.advanceTimersByTime(100);
    await expect(sync.visibilityChanged()).resolves.toBeUndefined();
    expect(run).toHaveBeenCalledTimes(2);
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
        active_blocking_edges: [
          {
            id: "edge-1",
            blocker_id: "blocker-1",
            from: { kind: "work_package", id: "wp-external" },
            to: { kind: "work_package", id: "wp-1" },
            work_request_id: "wr-1",
            work_package_id: "wp-1",
          },
        ],
        archived_work_requests: { work_requests: [{ id: "wr-1", title: "Archived copy" }], total_count: 1 },
        guidance_requests: {
          guidance_requests: [
            { id: "guidance-1", work_package_id: "wp-1" },
            { id: "guidance-external", work_package_id: "wp-external" },
          ],
          total_count: 2,
        },
        linked_work_package_ids: ["wp-1", "wp-external"],
        work_packages: [{ id: "wp-1" }, { id: "wp-external" }],
        work_request_details: [{
          work_request: { id: "wr-1", title: "Delete me" },
          work_packages: [{ id: "slice-1", work_request_id: "wr-1", work_package_id: "wp-1" }],
        }],
      },
      "wr-1",
    );

    expect(patched?.active_blocking_edges).toEqual([]);
    expect(patched?.work_requests?.work_requests).toEqual([]);
    expect(patched?.archived_work_requests?.work_requests).toEqual([]);
    expect(patched?.guidance_requests).toEqual({
      guidance_requests: [{ id: "guidance-external", work_package_id: "wp-external" }],
      total_count: 1,
    });
    expect(patched?.linked_work_package_ids).toEqual(["wp-external"]);
    expect(patched?.work_packages).toEqual([{ id: "wp-external" }]);
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
      work_request_details: [{ work_request: { id: "wr-1", title: "Hydrated" }, work_packages: [{ id: "slice-1", work_request_id: "wr-1" }] }],
    });

    expect(merged?.work_requests?.work_requests?.[0]).toMatchObject({ id: "wr-1", title: "Hydrated" });
    expect(merged).toMatchObject({
      archived_work_requests: { work_requests: [{ id: "wr-old" }] },
      deferred: { dashboard_sections: false },
      solo_sessions: { solo_sessions: [{ id: "solo-1" }] },
      work_request_details: [{ work_packages: [{ id: "slice-1" }] }],
    });
  });

  it("preserves lazy surfaces and drops stale active details during a priority refresh", () => {
    const dashboard = {
      ...dashboardWithRequest({ id: "wr-1", title: "Hydrated" }),
      archived_work_requests: { work_requests: [{ id: "wr-old", title: "Archived" }], total_count: 1 },
      solo_sessions: { solo_sessions: [{ id: "solo-1" }], total_count: 1 },
      work_request_details: [
        { work_request: { id: "wr-1", title: "Hydrated" } },
        { work_request: { id: "wr-stale", title: "No longer active" } },
      ],
      deferred: { dashboard_sections: false },
    } satisfies DashboardPayload;

    const merged = mergeDashboardPayload(dashboard, {
      work_requests: { work_requests: [{ id: "wr-1", title: "Fresh card" }], total_count: 1 },
      deferred: { dashboard_sections: true },
    });

    expect(merged?.work_requests?.work_requests?.[0]).toMatchObject({ title: "Fresh card" });
    expect(merged?.archived_work_requests).toBe(dashboard.archived_work_requests);
    expect(merged?.solo_sessions).toBe(dashboard.solo_sessions);
    expect(merged?.work_request_details).toEqual([{ work_request: { id: "wr-1", title: "Hydrated" } }]);
    expect(merged?.deferred).toEqual({ dashboard_sections: true });

    const lazyMerged = mergeDashboardPayload(merged, { solo_sessions: { solo_sessions: [{ id: "solo-2" }], total_count: 1 } });
    expect(lazyMerged?.work_requests?.work_requests?.[0]).toMatchObject({ title: "Fresh card" });
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
