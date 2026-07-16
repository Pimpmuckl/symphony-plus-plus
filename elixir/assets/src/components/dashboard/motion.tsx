import { Children, isValidElement, useEffect, useLayoutEffect, useReducer, useRef, useState } from "react";
import type { ComponentProps, CSSProperties, ReactNode, RefObject } from "react";

import { Badge } from "@/components/ui/badge";
import {
  clearMotionTimers,
  dashboardPrefersReducedMotion,
  later,
  measureElementHeight,
  nextFrame,
} from "@/components/dashboard/motion-utils";
import { cn } from "@/lib/utils";

export const TOP_PANEL_RESIZE_MS = 210;
export const TOP_PANEL_SLIDE_MS = 360;
export const WORKSPACE_TAB_SLIDE_MS = 360;
export const UPDATE_ANIMATION_TTL_MS = 4000;

const CARD_BODY_RESIZE_MS = TOP_PANEL_RESIZE_MS;
const CARD_BODY_CONTENT_MS = TOP_PANEL_SLIDE_MS;
const STATUS_SCRAMBLE_CHARACTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!?+-*/";
const STATUS_SCRAMBLE_MIN_MS = 360;
const STATUS_SCRAMBLE_MAX_MS = 680;
const STATUS_SCRAMBLE_TEST_MS = 1200;
const DASHBOARD_ANIMATION_TEST_EVENT = "sympp:test-animations";

export type UpdateMotionKind = "added" | "changed" | "guidance" | "blocker" | "finished" | "removed";
export type UpdateMotion = { kind: UpdateMotionKind | "settled"; token: number };

type CardBodySizePhase = "idle" | "pre-grow" | "enter" | "pre-shrink" | "post-shrink";

type AnimatedCardBodyState = {
  targetKey: string;
  renderedChildren: ReactNode;
  phase: CardBodySizePhase;
  height: number | "auto";
};

type AnimatedCardBodyAction =
  | { type: "replace"; state: AnimatedCardBodyState }
  | { type: "patch"; state: Partial<AnimatedCardBodyState> };

export function useCountMotion(value: number) {
  const currentRef = useRef(value);
  const tokenRef = useRef(0);
  const [motion, setMotion] = useState({
    active: false,
    direction: "idle" as "idle" | "up" | "down",
    previous: value,
    token: 0,
  });

  useEffect(() => {
    const previous = currentRef.current;
    if (previous === value) return;

    currentRef.current = value;
    const token = (tokenRef.current += 1);
    const direction = value >= previous ? "up" : "down";

    setMotion({ active: true, direction, previous, token });

    const timer = window.setTimeout(() => {
      setMotion({ active: false, direction: "idle", previous: value, token });
    }, 760);

    return () => window.clearTimeout(timer);
  }, [value]);

  return motion;
}

export function NumberWheel({
  value,
  motion,
  compact = false,
}: {
  value: number;
  motion: ReturnType<typeof useCountMotion>;
  compact?: boolean;
}) {
  return (
    <span
      key={motion.token}
      className={cn("number-wheel", compact && "number-wheel-compact")}
      data-direction={motion.active ? motion.direction : undefined}
      data-animating={motion.active ? "true" : undefined}
    >
      <span className="number-wheel-value number-wheel-old">{motion.previous}</span>
      <span className="number-wheel-value number-wheel-new">{value}</span>
    </span>
  );
}

export function AnimatedTopGrid({ children, className }: { children: ReactNode; className?: string }) {
  const layoutKey = Children.toArray(children)
    .map((child, index) => (isValidElement(child) ? child.key ?? index : index))
    .join("|");
  const flipRef = useFlipList(layoutKey);

  return (
    <div className={className} ref={flipRef}>
      {children}
    </div>
  );
}

export function AnimatedBadge({
  active = false,
  label,
  variant,
  className,
}: {
  active?: boolean;
  label: string;
  variant?: ComponentProps<typeof Badge>["variant"];
  className?: string;
}) {
  const badgeRef = useRef<HTMLDivElement | null>(null);
  const { displayLabel, testToken } = useScrambledStatus(label, badgeRef);
  const shimmerDuration = `${Math.max(1.8, label.length * 0.12).toFixed(2)}s`;
  const textStyle = { "--status-shimmer-duration": shimmerDuration } as CSSProperties;

  return (
    <Badge
      ref={badgeRef}
      variant={variant}
      className={cn("status-text-badge", className)}
      aria-label={label}
      data-running={active ? "true" : undefined}
    >
      <span
        key={`${label}:${testToken}`}
        className={cn("status-badge-text", active && "status-badge-text-running")}
        aria-hidden="true"
        style={textStyle}
      >
        {displayLabel}
      </span>
    </Badge>
  );
}

export function triggerDashboardAnimationTest() {
  if (typeof window !== "undefined") window.dispatchEvent(new Event(DASHBOARD_ANIMATION_TEST_EVENT));
}

export function scrambleStatusText(from: string, to: string, progress: number, random = Math.random) {
  if (progress <= 0) return from;
  if (progress >= 1) return to;

  const revealProgress = Math.max(0, (progress - 0.08) / 0.92);
  const revealedCharacters = Math.floor(to.length * revealProgress);
  const width = Math.max(from.length, to.length);

  return Array.from({ length: width }, (_, index) => {
    const targetCharacter = to[index] || "";
    if (index < revealedCharacters) return targetCharacter;
    if (targetCharacter === " ") return " ";
    if (progress < 0.16 && from[index]) return from[index];
    return STATUS_SCRAMBLE_CHARACTERS[Math.floor(random() * STATUS_SCRAMBLE_CHARACTERS.length)];
  }).join("").trimEnd();
}

function useScrambledStatus(label: string, badgeRef: RefObject<HTMLDivElement | null>) {
  const [displayLabel, setDisplayLabel] = useState(label);
  const [testToken, retrigger] = useReducer((token: number) => token + 1, 0);
  const displayRef = useRef(label);
  const reducedMotion = dashboardPrefersReducedMotion();

  useEffect(() => {
    const handleTest = () => {
      const bounds = badgeRef.current?.getBoundingClientRect();
      if (bounds && bounds.bottom >= 0 && bounds.top <= window.innerHeight) retrigger();
    };
    window.addEventListener(DASHBOARD_ANIMATION_TEST_EVENT, handleTest);
    return () => window.removeEventListener(DASHBOARD_ANIMATION_TEST_EVENT, handleTest);
  }, [badgeRef]);

  useEffect(() => {
    const from = displayRef.current;
    if (from === label && testToken === 0) return;

    if (reducedMotion) {
      displayRef.current = label;
      return;
    }

    const duration = from === label && testToken > 0
      ? STATUS_SCRAMBLE_TEST_MS
      : Math.min(STATUS_SCRAMBLE_MAX_MS, Math.max(STATUS_SCRAMBLE_MIN_MS, label.length * 38));
    let frame = 0;
    let startedAt: number | null = null;

    const animate = (time: number) => {
      startedAt ??= time;
      const progress = Math.min(1, (time - startedAt) / duration);
      const nextLabel = scrambleStatusText(from, label, progress);
      displayRef.current = nextLabel;
      setDisplayLabel(nextLabel);
      if (progress < 1) frame = window.requestAnimationFrame(animate);
    };

    frame = window.requestAnimationFrame(animate);
    return () => window.cancelAnimationFrame(frame);
  }, [label, reducedMotion, testToken]);

  return { displayLabel: reducedMotion ? label : displayLabel, testToken };
}

export function AnimatedCardBody({ motionKey, children }: { motionKey: string; children: ReactNode }) {
  const visibleRef = useRef<HTMLDivElement | null>(null);
  const frameRef = useRef<HTMLDivElement | null>(null);
  const measureRef = useRef<HTMLDivElement | null>(null);
  const timersRef = useRef<number[]>([]);
  const framesRef = useRef<number[]>([]);
  const [state, dispatch] = useReducer(animatedCardBodyReducer, {
    targetKey: motionKey,
    renderedChildren: children,
    phase: "idle",
    height: "auto",
  });

  useEffect(
    () => () => {
      clearMotionTimers(timersRef, framesRef);
    },
    [],
  );

  useLayoutEffect(() => {
    if (motionKey === state.targetKey) return;

    clearMotionTimers(timersRef, framesRef);

    if (dashboardPrefersReducedMotion()) {
      dispatch({ type: "replace", state: { targetKey: motionKey, renderedChildren: children, phase: "idle", height: "auto" } });
      return;
    }

    const oldHeight = measureElementHeight(frameRef.current) || measureElementHeight(visibleRef.current);
    const newHeight = measureElementHeight(measureRef.current);

    if (Math.abs(newHeight - oldHeight) <= 2) {
      dispatch({ type: "replace", state: { targetKey: motionKey, renderedChildren: children, phase: "idle", height: "auto" } });
      return;
    }

    if (newHeight > oldHeight) {
      dispatch({
        type: "replace",
        state: {
          targetKey: motionKey,
          renderedChildren: state.renderedChildren,
          phase: "pre-grow",
          height: oldHeight,
        },
      });
      nextFrame(framesRef, () => dispatch({ type: "patch", state: { height: newHeight } }));
      later(timersRef, CARD_BODY_RESIZE_MS, () => {
        dispatch({ type: "patch", state: { renderedChildren: children, phase: "enter", height: newHeight } });
        later(timersRef, CARD_BODY_CONTENT_MS, () => {
          dispatch({ type: "patch", state: { phase: "idle", height: "auto" } });
        });
      });
      return;
    }

    dispatch({
      type: "replace",
      state: {
        targetKey: motionKey,
        renderedChildren: children,
        phase: "pre-shrink",
        height: oldHeight,
      },
    });
    later(timersRef, CARD_BODY_CONTENT_MS, () => {
      dispatch({ type: "patch", state: { phase: "post-shrink" } });
      nextFrame(framesRef, () => dispatch({ type: "patch", state: { height: newHeight } }));
      later(timersRef, CARD_BODY_RESIZE_MS, () => {
        dispatch({ type: "patch", state: { phase: "idle", height: "auto" } });
      });
    });
  }, [children, motionKey, state.renderedChildren, state.targetKey]);

  const renderedChildren = state.phase === "idle" && state.targetKey === motionKey ? children : state.renderedChildren;
  const renderMeasure = motionKey !== state.targetKey || state.phase !== "idle";

  return (
    <div className="state-card-size-shell">
      {renderMeasure ? (
        <div ref={measureRef} className="state-card-size-measure" aria-hidden="true">
          <div className="state-card-size-inner">{children}</div>
        </div>
      ) : null}
      <div
        ref={frameRef}
        className="state-card-size-frame"
        data-card-size-phase={state.phase === "enter" ? "enter" : state.phase === "idle" ? "idle" : "sizing"}
        style={state.height === "auto" ? undefined : { height: `${Math.max(state.height, 0)}px` }}
      >
        <div ref={visibleRef} className="state-card-size-inner">
          {renderedChildren}
        </div>
      </div>
    </div>
  );
}

function useFlipList(layoutKey: string) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const previousRectsRef = useRef<Map<string, DOMRect> | null>(null);

  useLayoutEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const previousRects = previousRectsRef.current ?? new Map<string, DOMRect>();
    const nextRects = new Map<string, DOMRect>();
    const nodes = Array.from(container.querySelectorAll<HTMLElement>("[data-flip-id]"));

    nodes.forEach((node) => {
      const id = node.dataset.flipId;
      if (!id) return;

      const rect = node.getBoundingClientRect();
      const previous = previousRects.get(id);
      nextRects.set(id, rect);

      if (!previous) return;

      const deltaX = previous.left - rect.left;
      const deltaY = previous.top - rect.top;
      if (Math.abs(deltaX) < 1 && Math.abs(deltaY) < 1) return;

      node.animate(
        [
          { transform: `translate3d(${deltaX}px, ${deltaY}px, 0)` },
          { transform: "translate3d(0, 0, 0)" },
        ],
        {
          duration: 360,
          easing: "cubic-bezier(0.16, 1, 0.3, 1)",
        },
      );
    });

    previousRectsRef.current = nextRects;
  }, [layoutKey]);

  return containerRef;
}

function animatedCardBodyReducer(state: AnimatedCardBodyState, action: AnimatedCardBodyAction): AnimatedCardBodyState {
  if (action.type === "replace") return action.state;
  return { ...state, ...action.state };
}
