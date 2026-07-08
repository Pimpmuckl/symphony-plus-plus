import type { ActiveBlockingEdge, CopyArchitectHandoff, GuidanceItem, WorkRequestDetail } from "@/types/dashboard";
import type * as React from "react";
import { WORKSPACE_TAB_SLIDE_MS } from "@/components/dashboard/motion";
import { clearMotionTimers, later, measureElementHeight, nextFrame } from "@/components/dashboard/motion-utils";
import { useEffect, useLayoutEffect, useMemo, useReducer, useRef } from "react";
import { CardDetailSelect, DashboardUpdateAnimations, TopPanelDirection, WorkspaceTab, WorkspaceTabPhase } from "./runtime";
import { EmptyPanel } from "./empty-panel";
import { RepoSummary } from "./dashboard-data";
import { RepoWorkstream } from "./repo-workstream";
import {
  REPO_SUMMARY_METRIC_KEYS,
  REPO_SUMMARY_PLATE_WIDTH_VAR_BY_KEY,
  type RepoSummaryMetricKey,
  repoSummaryMetrics,
  repoSummaryPlateWidthForMetrics,
} from "./repo-summary-state";
import { repoWorkstreamStateKey, workspaceTabDirection } from "./dashboard-persistence";
import { statusBadgeWidthForRequestDetails } from "./workstream-row-state";
import { workstreamCategoryCounts } from "./workstream-data";

export function WorkstreamsPane({
  repos,
  hiddenRepoCount,
  searchActive,
  requestDetailsByRepo,
  activeBlockingEdges,
  guidanceItems,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  canMutateOperatorActions,
  showWorkstreamContextBar,
  updateAnimations,
}: {
  repos: RepoSummary[];
  hiddenRepoCount: number;
  searchActive: boolean;
  requestDetailsByRepo: Map<string, WorkRequestDetail[]>;
  activeBlockingEdges: ActiveBlockingEdge[];
  guidanceItems: GuidanceItem[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  canMutateOperatorActions: boolean;
  showWorkstreamContextBar: boolean;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const repoSummaryPlateWidthVars = useMemo<Record<string, string>>(() => {
    const metricsByKey = new Map<RepoSummaryMetricKey, ReturnType<typeof repoSummaryMetrics>>(
      REPO_SUMMARY_METRIC_KEYS.map((key) => [key, []]),
    );

    for (const repo of repos) {
      const categoryCounts = workstreamCategoryCounts(requestDetailsByRepo.get(repo.repoKey) ?? []);
      for (const metric of repoSummaryMetrics(repo, categoryCounts)) {
        metricsByKey.get(metric.key)?.push(metric);
      }
    }

    return Object.fromEntries(
      REPO_SUMMARY_METRIC_KEYS.map((key) => [REPO_SUMMARY_PLATE_WIDTH_VAR_BY_KEY[key], repoSummaryPlateWidthForMetrics(key, metricsByKey.get(key) ?? [])]),
    );
  }, [repos, requestDetailsByRepo]);
  const rowStatusBadgeWidth = useMemo(() => {
    const details = Array.from(requestDetailsByRepo.values()).flat();
    const packageById = new Map(repos.flatMap((repo) => repo.packages.map((pkg) => [pkg.id, pkg] as const)));
    return statusBadgeWidthForRequestDetails(details, packageById);
  }, [repos, requestDetailsByRepo]);
  const paneStyle = {
    ...repoSummaryPlateWidthVars,
    "--v3-row-badge-width": rowStatusBadgeWidth,
  } as React.CSSProperties;

  if (repos.length === 0) {
    return <EmptyPanel title={searchActive ? "No matches" : hiddenRepoCount > 0 ? "No active repositories" : "No repositories yet"} />;
  }

  return (
    <div className="v3-workstreams-pane grid gap-5" style={paneStyle}>
      {repos.map((repo) => (
        <RepoWorkstream
          key={repoWorkstreamStateKey(repo)}
          repo={repo}
          requestDetailsByRepo={requestDetailsByRepo}
          activeBlockingEdges={activeBlockingEdges}
          guidanceItems={guidanceItems}
          onSelectGuidance={onSelectGuidance}
          onSelectCard={onSelectCard}
          onCopyArchitectHandoff={onCopyArchitectHandoff}
          canMutateOperatorActions={canMutateOperatorActions}
          showWorkstreamContextBar={showWorkstreamContextBar}
          updateAnimations={updateAnimations}
        />
      ))}
    </div>
  );
}

export type WorkspaceTabCarouselState = {
  visibleTab: WorkspaceTab;
  previousTab: WorkspaceTab | null;
  phase: WorkspaceTabPhase;
  direction: TopPanelDirection;
  height: number | "auto";
};

export type WorkspaceTabCarouselAction =
  | { type: "start"; from: WorkspaceTab; to: WorkspaceTab; height: number }
  | { type: "height"; height: number | "auto" }
  | { type: "finish" };

function initialWorkspaceTabCarouselState(activeTab: WorkspaceTab): WorkspaceTabCarouselState {
  return {
    visibleTab: activeTab,
    previousTab: null,
    phase: "idle",
    direction: "forward",
    height: "auto",
  };
}

function workspaceTabCarouselReducer(state: WorkspaceTabCarouselState, action: WorkspaceTabCarouselAction): WorkspaceTabCarouselState {
  switch (action.type) {
    case "start":
      return {
        visibleTab: action.to,
        previousTab: action.from,
        phase: "swapping",
        direction: workspaceTabDirection(action.from, action.to),
        height: action.height,
      };
    case "height":
      return { ...state, height: action.height };
    case "finish":
      return { ...state, previousTab: null, phase: "idle", height: "auto" };
  }
}

export function WorkspaceTabCarousel({
  activeTab,
  paneContent,
}: {
  activeTab: WorkspaceTab;
  paneContent: Record<WorkspaceTab, React.ReactNode>;
}) {
  const [state, dispatch] = useReducer(workspaceTabCarouselReducer, activeTab, initialWorkspaceTabCarouselState);
  const viewportRef = useRef<HTMLDivElement | null>(null);
  const visibleRef = useRef<HTMLDivElement | null>(null);
  const latestTabRef = useRef<WorkspaceTab>(activeTab);
  const transitionTokenRef = useRef(0);
  const timersRef = useRef<number[]>([]);
  const framesRef = useRef<number[]>([]);

  useEffect(
    () => () => {
      clearMotionTimers(timersRef, framesRef);
    },
    [],
  );

  useLayoutEffect(() => {
    const oldTab = latestTabRef.current;
    if (oldTab === activeTab) return;

    clearMotionTimers(timersRef, framesRef);

    latestTabRef.current = activeTab;
    transitionTokenRef.current += 1;

    dispatch({
      type: "start",
      from: oldTab,
      to: activeTab,
      height: measureElementHeight(visibleRef.current) || measureElementHeight(viewportRef.current),
    });
  }, [activeTab]);

  useLayoutEffect(() => {
    if (state.phase !== "swapping") return;

    const token = transitionTokenRef.current;
    const nextHeight = measureElementHeight(visibleRef.current);

    nextFrame(framesRef, () => {
      if (transitionTokenRef.current === token) {
        dispatch({ type: "height", height: nextHeight });
      }
    });

    later(timersRef, WORKSPACE_TAB_SLIDE_MS, () => {
      if (transitionTokenRef.current !== token) return;

      dispatch({ type: "finish" });
    });
  }, [state.phase, state.visibleTab]);

  const showSwapping = state.phase === "swapping" && state.previousTab !== null;
  const panes =
    showSwapping && state.previousTab !== null
      ? state.direction === "forward"
        ? [
            { tab: state.previousTab, current: false },
            { tab: state.visibleTab, current: true },
          ]
        : [
            { tab: state.visibleTab, current: true },
            { tab: state.previousTab, current: false },
          ]
      : [{ tab: state.visibleTab, current: true }];
  const viewportStyle = {
    height: state.height === "auto" ? undefined : `${Math.max(state.height, 0)}px`,
  } as React.CSSProperties;

  return (
    <div ref={viewportRef} className="workspace-tab-viewport" data-phase={state.phase} style={viewportStyle}>
      <div className="workspace-tab-track" data-direction={state.direction} data-phase={showSwapping ? "swapping" : "idle"}>
        {panes.map(({ tab, current }) => (
          <div
            key={tab}
            ref={current ? visibleRef : undefined}
            className="workspace-tab-pane"
            data-pane={current ? "current" : "previous"}
            aria-hidden={!current}
          >
            <div className="workspace-tab-motion-frame">
              <div className="workspace-tab-pane-inner">{paneContent[tab]}</div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
