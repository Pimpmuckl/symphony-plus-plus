import type { WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";

import type { RequestFrontierMode } from "./workstream-board";
import { requestProgress } from "./workstream-progress";
import { requestBoardState, type BoardRowStateKind } from "./workstream-row-state";
import type { ActionableAttentionCounts } from "./workstream-attention";

export type FocusBoardLane = RequestFrontierMode;
export type FocusBoardItem = { detail: WorkRequestDetail; finishedAt?: string; id: string; lane: FocusBoardLane };

export function scrollFocusLane(lane: Pick<HTMLElement, "clientWidth" | "scrollLeft" | "scrollWidth">, deltaX: number, deltaY: number) {
  const delta = Math.abs(deltaX) > Math.abs(deltaY) ? deltaX : deltaY;
  const maximum = Math.max(0, lane.scrollWidth - lane.clientWidth);
  if (!delta || (delta < 0 && lane.scrollLeft <= 0) || (delta > 0 && lane.scrollLeft >= maximum - 1)) return false;
  lane.scrollLeft = Math.max(0, Math.min(maximum, lane.scrollLeft + delta));
  return true;
}

const CLARIFICATION_STATES = new Set(["clarifying", "ready_for_clarification"]);
const PRE_RUN_STATES = new Set([...CLARIFICATION_STATES, "ready_for_slicing"]);
const RECENT_WINDOW_MS = 24 * 60 * 60 * 1000;

export function buildFocusBoardItems(
  details: WorkRequestDetail[],
  now: string | number | Date = Date.now(),
  packageById = new Map<string, WorkPackageCard>(),
  attentionCountsByRequestId = new Map<string, ActionableAttentionCounts>(),
): FocusBoardItem[] {
  const nowMs = new Date(now).getTime();
  const items: FocusBoardItem[] = [];
  for (const detail of details) {
    const requestId = detail.work_request.id;
    const counts = attentionCountsByRequestId.get(requestId) ?? { blockerCount: 0, guidanceCount: 0 };
    const state = requestBoardState(detail, packageById, counts, requestProgress(detail, packageById));
    if (state.kind === "done") {
      const finishedAt = terminalTimestamp(detail);
      if (finishedAt && timestampIsRecent(finishedAt, nowMs)) items.push({ detail, finishedAt, id: requestId, lane: "recent" });
    } else {
      items.push({ detail, id: requestId, lane: requestLane(detail, state.kind) });
    }
  }
  return items;
}

export function requestHasExecutionBoard(detail: WorkRequestDetail) {
  if (!detail.product_tree) return (detail.summary?.work_package_count ?? detail.work_request.work_package_count ?? 0) > 0;
  const graph = detail.product_tree.execution_graph;
  return graph?.available === true
    && !graph.cycles?.length
    && Boolean(detail.product_tree.nodes?.length || graph.work_package_ids?.length);
}

function requestLane(detail: WorkRequestDetail, kind: BoardRowStateKind): Exclude<FocusBoardLane, "recent"> {
  if (kind === "blocked" || kind === "guidance") return "attention";
  const requestState = detail.work_request.operational_state?.key || detail.work_request.status || "created";
  if (PRE_RUN_STATES.has(requestState)) return "waiting";
  if (kind === "active") return "active";
  if (kind === "ready") return "next";
  return "waiting";
}

function terminalTimestamp(detail: WorkRequestDetail) {
  if (validTimestamp(detail.work_request.completed_at)) return detail.work_request.completed_at!;
  const packageDeliveries = (detail.work_packages ?? []).map((slice) => slice.delivery);
  const deliveryRows = (detail.delivery_board?.work_packages ?? []).map((row) => row.delivery);
  let latest: string | undefined;
  for (const delivery of [...packageDeliveries, ...deliveryRows]) {
    for (const value of [delivery?.pr_merged_at, delivery?.recorded_at]) {
      if (validTimestamp(value) && (!latest || Date.parse(value) > Date.parse(latest))) latest = value;
    }
  }
  return latest;
}

function timestampIsRecent(timestamp: string, nowMs: number) {
  const elapsed = nowMs - Date.parse(timestamp);
  return Number.isFinite(elapsed) && elapsed >= 0 && elapsed <= RECENT_WINDOW_MS;
}

function validTimestamp(value?: string | null): value is string {
  return Boolean(value && Number.isFinite(Date.parse(value)));
}
