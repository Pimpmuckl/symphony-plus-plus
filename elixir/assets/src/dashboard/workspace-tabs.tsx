import type { ActiveBlockingEdge, GuidanceItem, WorkRequestDetail } from "@/types/dashboard";
import type * as React from "react";
import { WORKSPACE_TAB_SLIDE_MS } from "@/components/dashboard/motion";
import { clearMotionTimers, dashboardPrefersReducedMotion, later, measureElementHeight, nextFrame } from "@/components/dashboard/motion-utils";
import { useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState } from "react";
import { ChevronRight } from "lucide-react";
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
import { FocusBoard } from "./focus-board";

const ALL_REPOSITORIES_REVEAL_MS = 240;

export function WorkstreamsPane({
  repos,
  hiddenRepoCount,
  searchActive,
  requestDetailsByRepo,
  now,
  activeBlockingEdges,
  onSelectGuidance,
  onSelectCard,
  showWorkstreamContextBar,
  updateAnimations,
}: {
  repos: RepoSummary[];
  hiddenRepoCount: number;
  searchActive: boolean;
  requestDetailsByRepo: Map<string, WorkRequestDetail[]>;
  now?: string;
  activeBlockingEdges: ActiveBlockingEdge[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
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
  const primaryBranchByRepo = useMemo(
    () => new Map(repos.map((repo) => [repo.repoKey, repositoryPrimaryBranch(repo.baseBranches)] as const)),
    [repos],
  );
  const paneStyle = {
    ...repoSummaryPlateWidthVars,
    "--v3-row-badge-width": rowStatusBadgeWidth,
  } as React.CSSProperties;
  const [repositoriesOpen, setRepositoriesOpen] = useState(false);
  const [repositoriesRevealed, setRepositoriesRevealed] = useState(false);
  const repositoriesRef = useRef<HTMLElement | null>(null);
  const repositoriesCameraFrameRef = useRef<number | null>(null);

  useEffect(() => () => {
    if (repositoriesCameraFrameRef.current !== null) window.cancelAnimationFrame(repositoriesCameraFrameRef.current);
  }, []);

  const toggleRepositories = () => {
    const nextOpen = !repositoriesOpen;
    setRepositoriesOpen(nextOpen);
    setRepositoriesRevealed(false);
    if (repositoriesCameraFrameRef.current !== null) window.cancelAnimationFrame(repositoriesCameraFrameRef.current);
    repositoriesCameraFrameRef.current = null;
    if (!nextOpen) return;
    window.requestAnimationFrame(() => {
      window.requestAnimationFrame(() => {
        const target = repositoriesRef.current;
        if (target?.dataset.open !== "true") return;
        setRepositoriesRevealed(true);
        const top = window.scrollY + target.getBoundingClientRect().top - window.innerHeight * 0.25;
        const destination = Math.max(0, top);
        if (dashboardPrefersReducedMotion()) {
          window.scrollTo({ top: destination, behavior: "auto" });
          return;
        }
        const start = window.scrollY;
        const distance = destination - start;
        const startedAt = performance.now();
        const step = (now: number) => {
          const progress = Math.min(1, (now - startedAt) / ALL_REPOSITORIES_REVEAL_MS);
          window.scrollTo({ top: start + distance * (1 - ((1 - progress) ** 3)), behavior: "auto" });
          repositoriesCameraFrameRef.current = progress < 1 ? window.requestAnimationFrame(step) : null;
        };
        repositoriesCameraFrameRef.current = window.requestAnimationFrame(step);
      });
    });
  };

  if (repos.length === 0) {
    return <EmptyPanel title={searchActive ? "No matches" : hiddenRepoCount > 0 ? "No active repositories" : "No repositories yet"} />;
  }

  const focusDetails = Array.from(requestDetailsByRepo.values()).flat();

  return (
    <div className="v3-workstreams-pane grid gap-5" style={paneStyle}>
      <FocusBoard
        details={focusDetails}
        now={now}
        packages={repos.flatMap((repo) => repo.packages)}
        activeBlockingEdges={activeBlockingEdges}
        onSelectGuidance={onSelectGuidance}
        onSelectCard={onSelectCard}
        primaryBranchByRepo={primaryBranchByRepo}
        updateAnimations={updateAnimations}
      />
      <section ref={repositoriesRef} className="all-repositories rounded-lg border bg-card text-card-foreground shadow-sm" data-open={repositoriesOpen ? "true" : "false"} data-revealed={repositoriesRevealed ? "true" : "false"}>
        <button type="button" className="all-repositories__toggle flex w-full cursor-pointer items-center gap-2 px-4 py-3 text-sm font-semibold" aria-expanded={repositoriesOpen} aria-controls="all-repositories-board" onClick={toggleRepositories}>
          <ChevronRight className="all-repositories__chevron size-4" aria-hidden="true" />
          <span>All Repositories</span>
          <span className="ml-auto text-xs text-muted-foreground">{repos.length} {repos.length === 1 ? "repository" : "repositories"}</span>
        </button>
        <div id="all-repositories-board" className="all-repositories__reveal" aria-hidden={!repositoriesOpen} inert={!repositoriesOpen}>
          <div className="all-repositories__reveal-inner grid gap-5 border-t p-4">
            {repos.map((repo) => (
              <RepoWorkstream
                key={repoWorkstreamStateKey(repo)}
                repo={repo}
                requestDetailsByRepo={requestDetailsByRepo}
                now={now}
                activeBlockingEdges={activeBlockingEdges}
                onSelectGuidance={onSelectGuidance}
                onSelectCard={onSelectCard}
                primaryBranch={primaryBranchByRepo.get(repo.repoKey)}
                showWorkstreamContextBar={showWorkstreamContextBar}
                updateAnimations={updateAnimations}
              />
            ))}
          </div>
        </div>
      </section>
    </div>
  );
}

function repositoryPrimaryBranch(branches: string[]) {
  return branches.find((branch) => ["main", "master"].includes(branch.trim().toLowerCase())) ?? branches[0];
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
