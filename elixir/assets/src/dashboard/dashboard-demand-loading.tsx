import type { DashboardMutationPayload } from "@/types/dashboard";
import { useEffect, useMemo } from "react";

import { mutationHeaders, operatorApiUrl, operatorFetch, readDashboardApiResponse, withLocalOperatorReconnect } from "./runtime";

const BEST_EFFORT_GITHUB_SYNC_COOLDOWN_MS = 5 * 60_000;

export function useBestEffortGithubSync(
  ready: boolean,
  refreshDashboard: (payload?: DashboardMutationPayload) => Promise<void>,
) {
  const sync = useMemo(() => createBestEffortGithubSync(() => document.visibilityState), []);

  useEffect(() => {
    void sync.ready(
      ready
        ? async () => {
            const payload = await withLocalOperatorReconnect(async () => {
              const response = await operatorFetch(operatorApiUrl("/github/sync-prs"), {
                method: "POST",
                headers: await mutationHeaders(),
                body: JSON.stringify({ mode: "auto" }),
              });
              return readDashboardApiResponse(response, "GitHub sync unavailable");
            });
            await refreshDashboard(payload as DashboardMutationPayload);
          }
        : null,
    );
    return () => void sync.ready(null);
  }, [ready, refreshDashboard, sync]);

  useEffect(() => {
    document.addEventListener("visibilitychange", sync.visibilityChanged);
    return () => document.removeEventListener("visibilitychange", sync.visibilityChanged);
  }, [sync]);
}

export function createBestEffortGithubSync(
  visibilityState: () => DocumentVisibilityState,
  cooldownMs = BEST_EFFORT_GITHUB_SYNC_COOLDOWN_MS,
) {
  let run: (() => Promise<void>) | null = null;
  let active = false;
  let lastAttemptAt: number | null = null;

  const trigger = async () => {
    const now = Date.now();
    if (!run || active || visibilityState() === "hidden" || (lastAttemptAt !== null && now - lastAttemptAt < cooldownMs)) return;

    active = true;
    lastAttemptAt = now;
    try {
      await run();
    } catch {
      // Best-effort convergence must never interrupt normal dashboard use.
    } finally {
      active = false;
    }
  };

  return {
    ready(nextRun: (() => Promise<void>) | null) {
      run = nextRun;
      return trigger();
    },
    visibilityChanged: trigger,
  };
}

export function createDashboardEventRefresh(
  refresh: () => void,
  visibilityState: () => DocumentVisibilityState,
  coalesceMs = 100,
) {
  let hiddenRefreshPending = false;
  let lastRefreshAt: number | null = null;
  let trailingTimer: ReturnType<typeof setTimeout> | null = null;

  const clearTrailing = () => {
    if (trailingTimer === null) return;
    clearTimeout(trailingTimer);
    trailingTimer = null;
  };
  const runRefresh = () => {
    lastRefreshAt = Date.now();
    refresh();
  };
  const dashboardChanged = () => {
    if (visibilityState() === "hidden") {
      hiddenRefreshPending = true;
      clearTrailing();
      return;
    }

    const elapsed = lastRefreshAt === null ? coalesceMs : Date.now() - lastRefreshAt;
    if (elapsed >= coalesceMs) {
      runRefresh();
      return;
    }
    if (trailingTimer !== null) return;

    trailingTimer = setTimeout(() => {
      trailingTimer = null;
      if (visibilityState() === "hidden") {
        hiddenRefreshPending = true;
        return;
      }
      runRefresh();
    }, coalesceMs - elapsed);
  };
  const visibilityChanged = () => {
    if (visibilityState() === "hidden") {
      if (trailingTimer !== null) hiddenRefreshPending = true;
      clearTrailing();
      return;
    }
    if (!hiddenRefreshPending) return;
    hiddenRefreshPending = false;
    runRefresh();
  };

  return { dashboardChanged, visibilityChanged, dispose: clearTrailing };
}
