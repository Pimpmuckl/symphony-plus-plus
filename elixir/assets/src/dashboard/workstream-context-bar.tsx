import { FileText, GitBranch, Layers3 } from "lucide-react";
import type { RefObject } from "react";
import { useEffect, useMemo, useState } from "react";
import type { ContextPathPart } from "./workstream-context-path";

const STICKY_CONTEXT_ACTIVE_THRESHOLD = 122;
const STICKY_CONTEXT_VISIBILITY_THRESHOLD = 150;
const MAX_CONTEXT_PLAN_NODES = 2;
type ContextPartKind = "plan" | "repo" | "request";
type RollDirection = "down" | "up";
type ContextState = {
  path: ContextPathPart[];
  direction: RollDirection;
  previousDisplayPath: ContextPart[];
  rollingParts: boolean[];
};
type RenderedContextPart = {
  current?: string;
  kind: ContextPartKind;
  previous?: string;
  rolling: boolean;
  separator: boolean;
  slot: string;
};
type ContextPart = {
  id: string;
  kind: ContextPartKind;
  label: string;
};

export function WorkstreamContextBar({
  boardRef,
  repoLabel,
  signature,
}: {
  boardRef: RefObject<HTMLDivElement | null>;
  repoLabel: string;
  signature: string;
}) {
  const [context, setContext] = useState<ContextState>({ path: [], direction: "down", previousDisplayPath: [], rollingParts: [] });
  const displayPath = useMemo(() => contextDisplayPath(repoLabel, context.path), [context.path, repoLabel]);
  const renderedPath = useMemo(() => {
    const length = Math.max(displayPath.length, context.previousDisplayPath.length);
    const parts: RenderedContextPart[] = [];

    for (let index = 0; index < length; index += 1) {
      const current = displayPath[index];
      const previous = context.previousDisplayPath[index];
      const part = {
        current: current?.label,
        kind: current?.kind ?? previous?.kind ?? contextPartKind(index),
        previous: previous?.label,
        rolling: context.rollingParts[index] === true,
        separator: index > 0,
        slot: contextPartSlot(index),
      };

      if (part.current || (part.rolling && part.previous)) {
        parts.push(part);
      }
    }

    return parts;
  }, [context.previousDisplayPath, context.rollingParts, displayPath]);

  useEffect(() => {
    let frame = 0;
    let lastScrollY = window.scrollY;
    const update = () => {
      window.cancelAnimationFrame(frame);
      frame = window.requestAnimationFrame(() => {
        const scrollY = window.scrollY;
        const direction = scrollY >= lastScrollY ? "down" : "up";
        const path = activeContextPath(boardRef.current);
        lastScrollY = scrollY;
        setContext((current) => {
          if (samePath(current.path, path)) return current;

          const previousDisplayPath = contextDisplayPath(repoLabel, current.path);
          const nextDisplayPath = contextDisplayPath(repoLabel, path);
          const length = Math.max(previousDisplayPath.length, nextDisplayPath.length);
          return {
            path,
            direction,
            previousDisplayPath,
            rollingParts: Array.from({ length }, (_, index) => !sameContextPart(previousDisplayPath[index], nextDisplayPath[index])),
          };
        });
      });
    };
    const resizeObserver = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(update);
    const mutationObserver = typeof MutationObserver === "undefined" ? null : new MutationObserver(update);

    update();
    window.addEventListener("scroll", update, { passive: true });
    window.addEventListener("resize", update);
    const board = boardRef.current;
    if (board) {
      board.addEventListener("scroll", update, { capture: true, passive: true });
      resizeObserver?.observe(board);
      mutationObserver?.observe(board, {
        attributeFilter: ["data-v3-context-path", "hidden"],
        attributes: true,
        childList: true,
        subtree: true,
      });
    }

    return () => {
      window.cancelAnimationFrame(frame);
      window.removeEventListener("scroll", update);
      window.removeEventListener("resize", update);
      board?.removeEventListener("scroll", update, true);
      resizeObserver?.disconnect();
      mutationObserver?.disconnect();
    };
  }, [boardRef, repoLabel, signature]);

  useEffect(() => {
    if (!context.rollingParts.some(Boolean)) return;

    const timeout = window.setTimeout(() => {
      setContext((current) => (
        samePath(current.path, context.path)
          ? { ...current, previousDisplayPath: [], rollingParts: [] }
          : current
      ));
    }, 260);

    return () => window.clearTimeout(timeout);
  }, [context.path, context.rollingParts]);

  if (context.path.length === 0 || displayPath.length === 0) return null;

  return (
    <div className="v3-workstream-context-slot">
      <div className="v3-workstream-context-bar" aria-label={`Current board position: ${displayPath.map((part) => part.label).join(" / ")}`}>
        <GitBranch className="v3-workstream-context-leading-icon" aria-hidden="true" />
        <span className="v3-workstream-context-path" data-roll-direction={context.direction}>
          {renderedPath.map((part) => (
            <span key={part.slot} className="v3-workstream-context-part">
              <RollingCrumb
                current={part.current}
                previous={part.previous}
                rolling={part.rolling}
                direction={context.direction}
                separator={part.separator}
                kind={part.kind}
              />
            </span>
          ))}
        </span>
      </div>
    </div>
  );
}

function RollingCrumb({
  current,
  previous,
  rolling,
  direction,
  separator,
  kind,
}: {
  current?: string;
  previous?: string;
  rolling: boolean;
  direction: RollDirection;
  separator: boolean;
  kind: ContextPartKind;
}) {
  const shouldRoll = rolling && previous !== current;
  const hasPrevious = shouldRoll && Boolean(previous);
  const hasCurrent = Boolean(current);
  const rollMode = !shouldRoll ? "static" : hasPrevious && hasCurrent ? "replace" : hasCurrent ? "enter" : "exit";

  return (
    <span className="v3-workstream-context-wheel" data-roll-mode={rollMode} data-rolling={shouldRoll ? "true" : "false"} data-roll-direction={direction}>
      {hasPrevious ? (
        <span className="v3-workstream-context-line v3-workstream-context-line-previous" title={previous} aria-hidden="true">
          {separator ? <span className="v3-workstream-context-separator">/</span> : null}
          <ContextPartIcon kind={kind} />
          <span className="v3-workstream-context-crumb">{previous}</span>
        </span>
      ) : null}
      {hasCurrent ? (
        <span className="v3-workstream-context-line v3-workstream-context-line-current" title={current}>
          {separator ? <span className="v3-workstream-context-separator">/</span> : null}
          <ContextPartIcon kind={kind} />
          <span className="v3-workstream-context-crumb">{current}</span>
        </span>
      ) : null}
    </span>
  );
}

function ContextPartIcon({ kind }: { kind: ContextPartKind }) {
  if (kind === "repo") return null;
  const Icon = kind === "request" ? FileText : Layers3;
  return <Icon className="v3-workstream-context-kind-icon" aria-hidden="true" />;
}

function contextPartKind(index: number): ContextPartKind {
  if (index === 0) return "repo";
  return index === 1 ? "request" : "plan";
}

function contextPartSlot(index: number) {
  if (index === 0) return "repo";
  if (index === 1) return "request";
  return `plan-${index - 2}`;
}

export function activeContextPath(board: HTMLDivElement | null) {
  if (!board) return [];

  const markers = [...board.querySelectorAll<HTMLElement>("[data-v3-context-path]")]
    .map((element) => contextMarker(element))
    .filter((marker) => elementIsVisible(marker.element) && markerIsWithinGraphViewport(marker));
  if (markers.length === 0) return [];

  const boardRect = board.getBoundingClientRect();
  if (boardRect.top > STICKY_CONTEXT_VISIBILITY_THRESHOLD || boardRect.bottom <= STICKY_CONTEXT_VISIBILITY_THRESHOLD) return [];

  const reachedMarkers = markers.filter((marker) => marker.rect.top <= STICKY_CONTEXT_ACTIVE_THRESHOLD);
  const activeTop = reachedMarkers.length
    ? Math.max(...reachedMarkers.map((marker) => marker.rect.top))
    : Math.min(...markers.map((marker) => marker.rect.top));
  const active = (reachedMarkers.length ? reachedMarkers : markers)
    .filter((marker) => marker.rect.top === activeTop)
    .reduce((closest, marker) => markerLeadingDistance(marker) < markerLeadingDistance(closest) ? marker : closest);

  return parseContextPath(active.element.dataset.v3ContextPath);
}

type ContextMarker = {
  element: HTMLElement;
  rect: DOMRect;
  viewportRect?: DOMRect;
};

function contextMarker(element: HTMLElement): ContextMarker {
  const viewport = element.closest<HTMLElement>(".execution-graph__viewport");
  return {
    element,
    rect: element.getBoundingClientRect(),
    viewportRect: viewport?.getBoundingClientRect(),
  };
}

function markerIsWithinGraphViewport({ rect, viewportRect }: ContextMarker) {
  return !viewportRect || (rect.right > viewportRect.left && rect.left < viewportRect.right);
}

function markerLeadingDistance({ rect, viewportRect }: ContextMarker) {
  return viewportRect ? Math.max(0, rect.left - viewportRect.left) : rect.left;
}

function elementIsVisible(element: HTMLElement) {
  if (element.closest("[hidden]")) return false;

  const rect = element.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0;
}

function parseContextPath(value?: string) {
  if (!value) return [];

  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.map(parseContextPathPart).filter((part): part is ContextPathPart => Boolean(part)) : [];
  } catch {
    return [];
  }
}

function parseContextPathPart(part: unknown): ContextPathPart | null {
  if (!part || typeof part !== "object") return null;

  const record = part as Record<string, unknown>;
  const id = typeof record.id === "string" ? record.id.trim() : "";
  const label = typeof record.label === "string" ? record.label.trim() : "";
  return id && label ? { id, label } : null;
}

function uniquePathParts(parts: ContextPart[]) {
  return parts.filter((part, index) => part.label && !sameContextPart(part, parts[index - 1]));
}

function contextDisplayPath(repoLabel: string, path: ContextPathPart[]) {
  const [request, ...planNodes] = path;
  const parts: ContextPart[] = [
    { id: "repo", kind: "repo", label: repoLabel },
    ...(request ? [{ id: request.id, kind: "request" as const, label: request.label }] : []),
    ...planNodes.slice(-MAX_CONTEXT_PLAN_NODES).map((part) => ({ id: part.id, kind: "plan" as const, label: part.label })),
  ];

  return uniquePathParts(parts);
}

function sameContextPart(left?: ContextPart, right?: ContextPart) {
  return left?.id === right?.id && left?.kind === right?.kind && left?.label === right?.label;
}

function samePath(left: ContextPathPart[], right: ContextPathPart[]) {
  return left.length === right.length && left.every((part, index) => part.id === right[index]?.id && part.label === right[index]?.label);
}
