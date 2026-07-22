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
