import type { ActiveBlockingEdge, GuidanceItem, WorkPackageCard, WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";
import { Activity, ArrowRight, CheckCircle2, ChevronRight, CircleAlert, Clock3 } from "lucide-react";
import type { ReactNode } from "react";
import { useLayoutEffect, useMemo, useRef, useState } from "react";

import { isFinishedBoardStatus } from "@/lib/operational-state";

import type { CardDetailSelect, DashboardUpdateAnimations } from "./runtime";
import { ProductRequestRow, type RequestFrontierMode } from "./workstream-board";
import { activeBlockerEntityCounts } from "./workstream-progress";
import { repoIdentityKey } from "./dashboard-persistence";

export type FocusBoardLane = RequestFrontierMode;

export type FocusBoardItem = {
  detail: WorkRequestDetail;
  finishedAt?: string;
  id: string;
  lane: FocusBoardLane;
};

const CLARIFICATION_STATES = new Set(["clarifying", "ready_for_clarification"]);
const HUMAN_STATES = new Set(["human_info_needed", "ready_for_human_merge"]);
const ACTIVE_STATES = new Set([
  "active",
  "ci_waiting",
  "claimed",
  "dispatched",
  "implementing",
  "in_progress",
  "merge_ready",
  "merging",
  "merging_into_phase",
  "needs_closeout",
  "planning",
  "ready_for_architect_merge",
  "ready_for_merge",
  "reviewing",
]);
const READY_STATES = new Set(["approved", "ready_for_worker"]);
const RECENT_WINDOW_MS = 24 * 60 * 60 * 1000;
const FOCUS_BOARD_COLUMNS = ["pr", "state"] as const;
const FOCUS_BOARD_COLUMN_CAPS_REM = { pr: Number.POSITIVE_INFINITY, state: Number.POSITIVE_INFINITY };

export function buildFocusBoardItems(details: WorkRequestDetail[], now: string | number | Date = Date.now()): FocusBoardItem[] {
  const nowMs = new Date(now).getTime();
  const items: FocusBoardItem[] = [];

  for (const detail of details) {
    const finished = requestIsFinished(detail);
    const finishedAt = finished ? terminalTimestamp(detail) : undefined;
    if (finished) {
      if (finishedAt && timestampIsRecent(finishedAt, nowMs)) {
        items.push({ detail, finishedAt, id: detail.work_request.id, lane: "recent" });
      }
      continue;
    }

    items.push({ detail, id: detail.work_request.id, lane: requestLane(detail) });
  }

  return items;
}

export function FocusBoard({
  details,
  now,
  packages,
  activeBlockingEdges,
  onSelectGuidance,
  onSelectCard,
  primaryBranchByRepo,
  updateAnimations,
}: {
  details: WorkRequestDetail[];
  now?: string;
  packages: WorkPackageCard[];
  activeBlockingEdges: ActiveBlockingEdge[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  primaryBranchByRepo: Map<string, string | undefined>;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const items = useMemo(() => buildFocusBoardItems(details, now), [details, now]);
  const packageById = useMemo(() => new Map(packages.map((pkg) => [pkg.id, pkg])), [packages]);
  const blockerCounts = useMemo(() => activeBlockerEntityCounts(activeBlockingEdges, details), [activeBlockingEdges, details]);
  const [expandedRequestIds, setExpandedRequestIds] = useState(() => new Set<string>());
  const boardRef = useRef<HTMLElement | null>(null);

  useLayoutEffect(() => {
    const root = boardRef.current;
    if (!root) return;

    let frame: number | null = null;
    const measure = () => {
      const rootFontSize = Number.parseFloat(getComputedStyle(root).fontSize);

      for (const column of FOCUS_BOARD_COLUMNS) {
        const width = [...root.querySelectorAll<HTMLElement>(`[data-frontier-measure="${column}"]`)]
          .filter((element) => element.getClientRects().length > 0)
          .reduce((maximum, element) => {
            const previousWhiteSpace = element.style.whiteSpace;
            const previousWidth = element.style.width;
            element.style.whiteSpace = "nowrap";
            element.style.width = "max-content";
            const intrinsicWidth = element.scrollWidth;
            element.style.whiteSpace = previousWhiteSpace;
            element.style.width = previousWidth;
            return Math.max(maximum, intrinsicWidth);
          }, 0);
        const property = `--focus-frontier-${column}-width`;
        const value = `${Math.ceil(Math.min(width, FOCUS_BOARD_COLUMN_CAPS_REM[column] * rootFontSize))}px`;
        if (root.style.getPropertyValue(property) !== value) root.style.setProperty(property, value);
      }
    };
    const scheduleMeasure = () => {
      if (frame !== null) window.cancelAnimationFrame(frame);
      frame = window.requestAnimationFrame(() => {
        measure();
        frame = null;
      });
    };

    measure();
    if (typeof ResizeObserver === "undefined") return;

    const observer = new ResizeObserver(scheduleMeasure);
    observer.observe(root);

    return () => {
      observer.disconnect();
      if (frame !== null) window.cancelAnimationFrame(frame);
    };
  }, [items]);
  const renderItem = (item: FocusBoardItem, index: number) => (
    <ProductRequestRow
      key={item.id}
      detail={item.detail}
      now={now}
      packageById={packageById}
      activeBlockerCount={blockerCounts.requests.get(item.id) ?? 0}
      expanded={expandedRequestIds.has(item.id)}
      index={index}
      onSetOpen={(open) => setExpandedRequestIds((current) => updatedSet(current, item.id, open))}
      onSelectGuidance={onSelectGuidance}
      onSelectCard={onSelectCard}
      primaryBranch={primaryBranchByRepo.get(repoIdentityKey(item.detail.work_request))}
      frontierMode={item.lane}
      autoCollapseWhenDone={false}
      updateAnimations={updateAnimations}
    />
  );
  const previewQuery = import.meta.env.DEV && typeof window !== "undefined"
    ? new URLSearchParams(window.location.search).get("focus-card-preview")?.trim().toLowerCase()
    : undefined;
  const previewItem = previewQuery
    ? items.find((item) => (item.detail.work_request.title || item.id).toLowerCase().includes(previewQuery))
    : undefined;

  if (previewItem) {
    return (
      <section ref={boardRef} className="focus-card-preview" aria-label="WorkRequest card preview">
        <div className="workstream-board-shell"><div className="v3-workstream-board">{renderItem(previewItem, 0)}</div></div>
      </section>
    );
  }

  const waiting = items.filter((item) => item.lane === "waiting");
  const openCount = items.filter((item) => item.lane !== "recent").length;

  return (
    <section ref={boardRef} className="focus-board grid gap-4 rounded-lg border bg-card p-4 text-card-foreground shadow-sm" aria-labelledby="focus-board-title">
      <header className="flex items-center justify-between gap-3">
        <h2 id="focus-board-title" className="text-base font-semibold">Focus Board</h2>
        <span className="text-xs font-semibold text-muted-foreground">{openCount} open</span>
      </header>
      <div className="grid gap-4">
        <FocusSection lane="attention" label="Needs Attention" icon={<CircleAlert className="size-4" />} items={items} renderItem={renderItem} />
        <FocusSection lane="active" label="In Progress" icon={<Activity className="size-4" />} items={items} renderItem={renderItem} />
        <FocusSection lane="next" label="Up Next" icon={<ArrowRight className="size-4" />} items={items} renderItem={renderItem} />
        {items.some((item) => item.lane === "recent") ? (
          <FocusSection lane="recent" label="Recently Finished" icon={<CheckCircle2 className="size-4" />} items={items} renderItem={renderItem} />
        ) : null}
        {waiting.length > 0 ? (
          <FocusSection lane="waiting" label="Waiting" icon={<Clock3 className="size-4" />} items={items} renderItem={renderItem} />
        ) : null}
      </div>
    </section>
  );
}

function FocusSection({
  lane,
  label,
  icon,
  items,
  renderItem,
}: {
  lane: FocusBoardLane;
  label: string;
  icon: ReactNode;
  items: FocusBoardItem[];
  renderItem: (item: FocusBoardItem, index: number) => ReactNode;
}) {
  const laneItems = items.filter((item) => item.lane === lane).toSorted(compareFocusItems);

  return (
    <details className="group grid gap-2" aria-labelledby={`focus-board-${lane}`} open={lane === "attention" || lane === "active"}>
      <summary className="flex cursor-pointer list-none items-center gap-2 text-sm font-semibold [&::-webkit-details-marker]:hidden">
        <ChevronRight className="size-4 transition-transform group-open:rotate-90" aria-hidden="true" />
        <span className={lane === "recent" ? "text-emerald-600 dark:text-emerald-400" : "text-muted-foreground"} aria-hidden="true">{icon}</span>
        <h3 id={`focus-board-${lane}`}>{label}</h3>
        <span className="ml-auto text-xs text-muted-foreground">{laneItems.length}</span>
      </summary>
      {laneItems.length > 0
        ? <div className="workstream-board-shell mt-2"><div className="v3-workstream-board">{laneItems.map(renderItem)}</div></div>
        : <p className="rounded-md border border-dashed px-3 py-2 text-xs text-muted-foreground">Clear</p>}
    </details>
  );
}

function requestLane(detail: WorkRequestDetail): Exclude<FocusBoardLane, "recent"> {
  const slices = detail.work_packages ?? [];
  if (requestNeedsHumanAction(detail) || slices.some(packageNeedsAttention)) return "attention";
  if (slices.some(packageIsActive) || ACTIVE_STATES.has(requestState(detail))) return "active";
  if (CLARIFICATION_STATES.has(requestState(detail)) || slices.some(packageIsReady)) return "next";
  return "waiting";
}

function packageHasActiveLifecycle(slice: WorkRequestPackage, states: string[]) {
  return [
    slice.worker_signal?.status === "active",
    slice.review_signal?.status === "in_progress",
    slice.pr_signal?.checks?.status === "pending",
    slice.operational_state?.has_started,
    states.some((state) => ACTIVE_STATES.has(state)),
  ].some(Boolean);
}

function requestIsFinished(detail: WorkRequestDetail) {
  if (isFinishedBoardStatus(requestState(detail))) return true;
  const slices = detail.work_packages ?? [];
  if (slices.length > 0) return slices.every(packageIsFinished);
  const deliveryRows = detail.delivery_board?.work_packages ?? [];
  return deliveryRows.length > 0 && deliveryRows.every((row) => [row.raw_status, row.delivery_outcome, row.work_package?.raw_status, row.work_package?.status, row.operational_state?.key].some(isFinishedBoardStatus));
}

function terminalTimestamp(detail: WorkRequestDetail) {
  if (validTimestamp(detail.work_request.completed_at)) return detail.work_request.completed_at!;
  const packageDeliveries = (detail.work_packages ?? []).map((slice) => slice.delivery);
  const deliveryRows = (detail.delivery_board?.work_packages ?? []).map((row) => row.delivery);
  return [...packageDeliveries, ...deliveryRows]
    .flatMap((delivery) => [delivery?.pr_merged_at, delivery?.recorded_at])
    .filter((value): value is string => validTimestamp(value))
    .toSorted((left, right) => Date.parse(right) - Date.parse(left))[0];
}

function requestNeedsHumanAction(detail: WorkRequestDetail) {
  const state = requestState(detail);
  return hasOpenQuestion(detail) || HUMAN_STATES.has(state) || (detail.work_packages ?? []).some(packageHasHumanState);
}

function hasOpenQuestion(detail: WorkRequestDetail) {
  return (detail.clarification_questions ?? []).some((question) => question.status === "open")
    || (detail.summary?.open_question_count ?? detail.work_request.open_question_count ?? 0) > 0;
}

function packageNeedsAttention(slice: WorkRequestPackage) {
  return slice.review_signal?.status === "failed"
    || slice.pr_signal?.checks?.status === "failing"
    || packageHasHumanState(slice)
    || packageHasActionableBlocker(slice);
}

function packageHasHumanState(slice: WorkRequestPackage) {
  return sliceStates(slice).some((state) => HUMAN_STATES.has(state));
}

function packageHasActionableBlocker(slice: WorkRequestPackage) {
  const attentionText = [
    ...(slice.attention_reason_codes ?? []),
    ...(slice.operational_state?.attention_reason_codes ?? []),
    ...(slice.operational_state?.attention_items ?? []).flatMap((item) => [item.key, item.label, item.reason]),
  ].filter((value): value is string => Boolean(value)).join(" ").toLowerCase();
  if (/block|fail|error/.test(attentionText) && !/dependenc/.test(attentionText)) return true;
  const dependency = slice.dependency_signal;
  return sliceStates(slice).includes("blocked") && !(dependency && dependency.required > dependency.satisfied);
}

function packageIsActive(slice: WorkRequestPackage) {
  const states = sliceStates(slice);
  return !packageIsFinished(slice) && packageHasActiveLifecycle(slice, states);
}

function packageIsFinished(slice: WorkRequestPackage) {
  return [...sliceStates(slice), slice.delivery?.outcome].some(isFinishedBoardStatus);
}

function packageIsReady(slice: WorkRequestPackage) {
  return !slice.operational_state?.has_started && sliceStates(slice).some((state) => READY_STATES.has(state) || CLARIFICATION_STATES.has(state));
}

function requestState(detail: WorkRequestDetail) {
  return detail.work_request.operational_state?.key || detail.work_request.status || "created";
}

function sliceStates(slice: WorkRequestPackage) {
  return [slice.operational_state?.key, slice.work_package_status, slice.status]
    .filter((value): value is string => Boolean(value));
}

function timestampIsRecent(timestamp: string, nowMs: number) {
  const elapsed = nowMs - Date.parse(timestamp);
  return Number.isFinite(elapsed) && elapsed >= 0 && elapsed <= RECENT_WINDOW_MS;
}

function validTimestamp(value?: string | null): value is string {
  return Boolean(value && Number.isFinite(Date.parse(value)));
}

function updatedSet(current: Set<string>, id: string, included: boolean) {
  const next = new Set(current);
  if (included) next.add(id);
  else next.delete(id);
  return next;
}

function compareFocusItems(left: FocusBoardItem, right: FocusBoardItem) {
  if (left.lane === "recent" && right.lane === "recent") return Date.parse(right.finishedAt || "") - Date.parse(left.finishedAt || "");
  const leftTitle = left.detail.work_request.title || left.id;
  const rightTitle = right.detail.work_request.title || right.id;
  return leftTitle.localeCompare(rightTitle);
}
