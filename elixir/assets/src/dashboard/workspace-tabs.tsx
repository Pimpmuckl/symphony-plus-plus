import type { ActiveBlockingEdge, GuidanceItem, WorkRequestDetail } from "@/types/dashboard";
import { WORKSPACE_TAB_SLIDE_MS } from "@/components/dashboard/motion";
import { clearMotionTimers, later, measureElementHeight, nextFrame } from "@/components/dashboard/motion-utils";
import { useEffect, useLayoutEffect, useMemo, useReducer, useRef } from "react";
import { CardDetailSelect, DashboardUpdateAnimations, TopPanelDirection, WorkspaceTab, WorkspaceTabPhase } from "./runtime";
import { EmptyPanel } from "./empty-panel";
import { RepoSummary } from "./dashboard-data";
import { RepoWorkstream } from "./repo-workstream";
import { repoWorkstreamStateKey, useStoredUseFocusBoard, workspaceTabDirection } from "./dashboard-persistence";
import { FocusBoard, FocusBoardLoading } from "./focus-board";
import type { AttentionJumpTarget, AttentionSelect } from "./workstream-attention";

export function WorkstreamsPane({
  repos,
  hiddenRepoCount,
  searchActive,
  requestDetailsByRepo,
  focusBoardReady,
  now,
  activeBlockingEdges,
  guidanceItems,
  jumpTarget,
  onSelectAttention,
  onSelectGuidance,
  onSelectCard,
  showWorkstreamContextBar,
  updateAnimations,
}: {
  repos: RepoSummary[];
  hiddenRepoCount: number;
  searchActive: boolean;
  requestDetailsByRepo: Map<string, WorkRequestDetail[]>;
  focusBoardReady: boolean;
  now?: string;
  activeBlockingEdges: ActiveBlockingEdge[];
  guidanceItems: GuidanceItem[];
  jumpTarget?: AttentionJumpTarget | null;
  onSelectAttention: AttentionSelect;
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  showWorkstreamContextBar: boolean;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const primaryBranchByRepo = useMemo(
    () => new Map(repos.map((repo) => [repo.repoKey, repositoryPrimaryBranch(repo.baseBranches)] as const)),
    [repos],
  );
  const useFocusBoard = useStoredUseFocusBoard();

  if (repos.length === 0) {
    return <EmptyPanel title={searchActive ? "No matches" : hiddenRepoCount > 0 ? "No active repositories" : "No repositories yet"} />;
  }

  const focusDetails = Array.from(requestDetailsByRepo.values()).flat();

  return (
    <div className="v3-workstreams-pane grid gap-5">
      {useFocusBoard && focusBoardReady ? <FocusBoard
        details={focusDetails}
        now={now}
        packages={repos.flatMap((repo) => repo.packages)}
        activeBlockingEdges={activeBlockingEdges}
        guidanceItems={guidanceItems}
        jumpTarget={jumpTarget}
        onSelectAttention={onSelectAttention}
        onSelectGuidance={onSelectGuidance}
        onSelectCard={onSelectCard}
        primaryBranchByRepo={primaryBranchByRepo}
        updateAnimations={updateAnimations}
      /> : useFocusBoard ? <FocusBoardLoading /> : null}
      {repos.map((repo) => (
        <RepoWorkstream
          key={repoWorkstreamStateKey(repo)}
          repo={repo}
          requestDetailsByRepo={requestDetailsByRepo}
          now={now}
          activeBlockingEdges={activeBlockingEdges}
          guidanceItems={guidanceItems}
          jumpTarget={jumpTarget}
          onSelectAttention={onSelectAttention}
          onSelectGuidance={onSelectGuidance}
          onSelectCard={onSelectCard}
          primaryBranch={primaryBranchByRepo.get(repo.repoKey)}
          showWorkstreamContextBar={showWorkstreamContextBar}
          updateAnimations={updateAnimations}
        />
      ))}
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
