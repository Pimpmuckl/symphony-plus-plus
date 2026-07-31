import { TOP_PANEL_RESIZE_MS, TOP_PANEL_SLIDE_MS } from "@/components/dashboard/motion";
import { clearMotionTimers, later, measureElementHeight, nextFrame } from "@/components/dashboard/motion-utils";
import { useEffect, useLayoutEffect, useReducer, useRef } from "react";
import type { CSSProperties, Dispatch, MutableRefObject } from "react";
import { topPanelDirection } from "./dashboard-persistence";
import type { TopPanelKey } from "./runtime";
import type { TopPanelCarouselAction, TopPanelCarouselState, TopPanelContentProps } from "./status-rail-types";
import { TopPanelContent } from "./top-panel-content";

export function TopPanelCarousel({
  activePanel,
  attentionItems,
  requestDetails,
  now,
  onJumpToAttention,
  onSelectAttention,
  updateAnimations,
}: Omit<TopPanelContentProps, "panel" | "interactive"> & {
  activePanel: TopPanelKey | null;
}) {
  const [state, dispatch] = useReducer(topPanelCarouselReducer, activePanel, initialTopPanelCarouselState);
  const viewportRef = useRef<HTMLDivElement | null>(null);
  const visibleRef = useRef<HTMLDivElement | null>(null);
  const measureRef = useRef<HTMLDivElement | null>(null);
  const latestPanelRef = useRef<TopPanelKey | null>(activePanel);
  const timersRef = useRef<number[]>([]);
  const framesRef = useRef<number[]>([]);
  const contentProps = {
    attentionItems,
    requestDetails,
    now,
    onJumpToAttention,
    onSelectAttention,
    updateAnimations,
  };

  useEffect(
    () => () => {
      clearMotionTimers(timersRef, framesRef);
    },
    [],
  );

  useLayoutEffect(() => {
    const oldPanel = latestPanelRef.current;
    clearMotionTimers(timersRef, framesRef);

    const oldHeight = measureElementHeight(visibleRef.current) || measureElementHeight(viewportRef.current);
    const newHeight = activePanel ? measureElementHeight(measureRef.current) : 0;
    const transition = topPanelTransition(oldPanel, activePanel, oldHeight, newHeight);
    if (!transition) return;

    latestPanelRef.current = transition.latestPanel;
    dispatch({ type: "replace", state: transition.state });
    scheduleTopPanelTransition(transition, dispatch, timersRef, framesRef);
  }, [activePanel]);

  const view = topPanelView(state);
  const viewportStyle = {
    height: topPanelViewportHeight(view.panes.length > 0, state.height),
    "--top-panel-next-height": `${Math.max(state.transitionHeights.to, 0)}px`,
  } as CSSProperties;

  return (
    <>
      <div className="top-panel-measure" ref={measureRef} aria-hidden="true">
        {activePanel ? (
          <div className="top-panel-motion-frame">
            <div className="top-panel-pane-inner">
              <TopPanelContent {...contentProps} panel={activePanel} interactive={false} />
            </div>
          </div>
        ) : null}
      </div>
      <div
        ref={viewportRef}
        className="top-panel-viewport"
        data-phase={state.phase}
        data-resize={view.resizeMode}
        data-has-content={view.panes.length > 0}
        style={viewportStyle}
      >
        {view.showStaticPrevious ? (
          <div ref={visibleRef} className="top-panel-static" data-motion="hold">
            <div className="top-panel-motion-frame">
              <div className="top-panel-pane-inner">
                {state.previousPanel ? <TopPanelContent {...contentProps} panel={state.previousPanel} /> : null}
              </div>
            </div>
          </div>
        ) : null}
        {view.showTrackCurrent ? (
          <div className="top-panel-track" data-direction={state.direction} data-phase={view.showSwapping ? "swapping" : "idle"}>
            {view.panes.map(({ panel, current }) => (
              <div
                key={panel}
                ref={current ? visibleRef : undefined}
                className="top-panel-pane"
                data-pane={current ? "current" : "previous"}
                aria-hidden={!current}
              >
                <div className="top-panel-motion-frame">
                  <div className="top-panel-pane-inner">
                    <TopPanelContent {...contentProps} panel={panel} />
                  </div>
                </div>
              </div>
            ))}
          </div>
        ) : null}
        {view.showStaticCurrent ? (
          <div
            ref={visibleRef}
            className="top-panel-static"
            data-motion={state.phase === "opening" ? "open" : state.phase === "closing" ? "close" : "idle"}
            data-direction={state.direction}
          >
            <div className="top-panel-motion-frame">
              <div className="top-panel-pane-inner">
                {state.visiblePanel ? <TopPanelContent {...contentProps} panel={state.visiblePanel} /> : null}
              </div>
            </div>
          </div>
        ) : null}
      </div>
    </>
  );
}

type TopPanelTransition = {
  kind: "opening" | "closing" | "pre-resize" | "swapping";
  latestPanel: TopPanelKey | null;
  state: TopPanelCarouselState;
  targetHeight: number;
};

function topPanelTransition(
  oldPanel: TopPanelKey | null,
  activePanel: TopPanelKey | null,
  oldHeight: number,
  newHeight: number,
): TopPanelTransition | null {
  if (oldPanel === activePanel) return null;

  const direction = topPanelDirection(oldPanel, activePanel);
  const transitionHeights = { from: oldHeight, to: newHeight };

  if (!oldPanel && activePanel) {
    return {
      kind: "opening",
      latestPanel: activePanel,
      targetHeight: newHeight,
      state: { visiblePanel: activePanel, previousPanel: null, phase: "opening", direction, height: 0, transitionHeights },
    };
  }

  if (oldPanel && !activePanel) {
    return {
      kind: "closing",
      latestPanel: null,
      targetHeight: 0,
      state: { visiblePanel: oldPanel, previousPanel: null, phase: "closing", direction, height: oldHeight, transitionHeights },
    };
  }

  if (!oldPanel || !activePanel) return null;

  const growing = newHeight > oldHeight + 2;
  return {
    kind: growing ? "pre-resize" : "swapping",
    latestPanel: activePanel,
    targetHeight: newHeight,
    state: {
      visiblePanel: activePanel,
      previousPanel: oldPanel,
      phase: growing ? "pre-resize" : "swapping",
      direction,
      height: oldHeight,
      transitionHeights,
    },
  };
}

function scheduleTopPanelTransition(
  transition: TopPanelTransition,
  dispatch: Dispatch<TopPanelCarouselAction>,
  timersRef: MutableRefObject<number[]>,
  framesRef: MutableRefObject<number[]>,
) {
  if (transition.kind === "opening") {
    nextFrame(framesRef, () => {
      dispatch({ type: "patch", state: { height: transition.targetHeight } });
      later(timersRef, TOP_PANEL_SLIDE_MS, () => dispatch({ type: "patch", state: { phase: "idle", height: "auto" } }));
    });
    return;
  }

  if (transition.kind === "closing") {
    nextFrame(framesRef, () => {
      dispatch({ type: "patch", state: { height: 0 } });
      later(timersRef, TOP_PANEL_SLIDE_MS, () => dispatch({ type: "patch", state: { visiblePanel: null, phase: "idle", height: 0 } }));
    });
    return;
  }

  if (transition.kind === "pre-resize") {
    nextFrame(framesRef, () => {
      dispatch({ type: "patch", state: { height: transition.targetHeight } });
      later(timersRef, TOP_PANEL_RESIZE_MS, () => {
        dispatch({ type: "patch", state: { phase: "swapping" } });
        later(timersRef, TOP_PANEL_SLIDE_MS, () => dispatch({ type: "patch", state: { previousPanel: null, phase: "idle", height: "auto" } }));
      });
    });
    return;
  }

  if (transition.targetHeight < transition.state.transitionHeights.from - 2) {
    later(timersRef, TOP_PANEL_SLIDE_MS, () => {
      dispatch({ type: "patch", state: { phase: "post-resize", height: transition.targetHeight, previousPanel: null } });
      later(timersRef, TOP_PANEL_RESIZE_MS, () => dispatch({ type: "patch", state: { phase: "idle", height: "auto" } }));
    });
    return;
  }
  later(timersRef, TOP_PANEL_SLIDE_MS, () => dispatch({ type: "patch", state: { previousPanel: null, phase: "idle", height: "auto" } }));
}

function topPanelView(state: TopPanelCarouselState) {
  const showStaticPrevious = state.phase === "pre-resize" && state.previousPanel;
  const showSwapping = state.phase === "swapping" && state.previousPanel !== null && state.visiblePanel !== null;
  const showTrackCurrent = showSwapping;
  const showStaticCurrent = state.visiblePanel && !showStaticPrevious && !showTrackCurrent;

  return {
    panes: topPanelPanes(state, showSwapping),
    resizeMode: topPanelResizeMode(state),
    showStaticCurrent,
    showStaticPrevious,
    showSwapping,
    showTrackCurrent,
  };
}

function topPanelPanes(state: TopPanelCarouselState, showSwapping: boolean) {
  if (showSwapping && state.previousPanel !== null && state.visiblePanel !== null) {
    const current = { panel: state.visiblePanel, current: true };
    const previous = { panel: state.previousPanel, current: false };
    return state.direction === "forward" ? [previous, current] : [current, previous];
  }

  return state.visiblePanel ? [{ panel: state.visiblePanel, current: true }] : [];
}

function topPanelResizeMode(state: TopPanelCarouselState) {
  if (state.phase !== "swapping") return "steady";
  if (state.transitionHeights.to < state.transitionHeights.from - 2) return "shrinking";
  if (state.transitionHeights.to > state.transitionHeights.from + 2) return "growing";
  return "steady";
}

function initialTopPanelCarouselState(activePanel: TopPanelKey | null): TopPanelCarouselState {
  return {
    visiblePanel: activePanel,
    previousPanel: null,
    phase: "idle",
    direction: "forward",
    height: activePanel ? "auto" : 0,
    transitionHeights: { from: 0, to: 0 },
  };
}

function topPanelCarouselReducer(state: TopPanelCarouselState, action: TopPanelCarouselAction): TopPanelCarouselState {
  if (action.type === "replace") return action.state;
  return { ...state, ...action.state };
}

function topPanelViewportHeight(hasPanes: boolean, height: TopPanelCarouselState["height"]) {
  if (!hasPanes) return "0px";
  if (height === "auto") return undefined;
  return `${Math.max(height, 0)}px`;
}
