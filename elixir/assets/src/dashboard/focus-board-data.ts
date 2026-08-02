import type { WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";

import type { RequestFrontierMode } from "./workstream-board";
import { isFinishedBoardStatus, sliceOperationalState } from "@/lib/operational-state";
import { productTreeCounts, requestProgress } from "./workstream-progress";
import { requestBoardState, sliceActionableBlockerCount, type BoardRowStateKind } from "./workstream-row-state";

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
const NO_ACTIVE_BLOCKERS = new Map<string, number>();

export function buildFocusBoardItems(
  details: WorkRequestDetail[],
  now: string | number | Date = Date.now(),
  packageById = new Map<string, WorkPackageCard>(),
  blockerCountByRequestId = new Map<string, number>(),
): FocusBoardItem[] {
  const nowMs = new Date(now).getTime();
  const items: FocusBoardItem[] = [];
  for (const detail of details) {
    const requestId = detail.work_request.id;
    const blockerCount = blockerCountByRequestId.get(requestId) ?? 0;
    const counts = productTreeCounts(detail, blockerCount);
    const state = requestBoardState(detail, packageById, counts, requestProgress(detail, packageById));
    if (state.kind === "done") {
      const finishedAt = terminalTimestamp(detail);
      if (finishedAt && timestampIsRecent(finishedAt, nowMs)) items.push({ detail, finishedAt, id: requestId, lane: "recent" });
    } else {
      items.push({ detail, id: requestId, lane: requestLane(detail, state.kind, blockerCount, packageById) });
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

function requestLane(detail: WorkRequestDetail, kind: BoardRowStateKind, blockerCount: number, packageById: Map<string, WorkPackageCard>): Exclude<FocusBoardLane, "recent"> {
  if (kind === "blocked") return blockedRequestLane(detail, blockerCount, packageById);
  if (kind === "guidance") return requestOnlyNeedsClarification(detail) ? "waiting" : "attention";
  const requestState = detail.work_request.operational_state?.key || detail.work_request.status || "created";
  if (PRE_RUN_STATES.has(requestState)) return "waiting";
  if (kind === "active") return "active";
  if (kind === "ready") return "next";
  return "waiting";
}

function blockedRequestLane(detail: WorkRequestDetail, blockerCount: number, packageById: Map<string, WorkPackageCard>): Exclude<FocusBoardLane, "recent"> {
  if (blockerCount > 0) return "attention";
  return requestOnlyWaitsOnDependencies(detail, packageById) ? "waiting" : "attention";
}

function requestOnlyNeedsClarification(detail: WorkRequestDetail) {
  const hasOpenQuestion = (detail.clarification_questions ?? []).some((question) => question.status === "open")
    || (detail.summary?.open_question_count ?? detail.work_request.open_question_count ?? 0) > 0;
  if (hasOpenQuestion) return false;
  const states = [
    detail.work_request.operational_state?.key,
    detail.work_request.status,
    ...(detail.work_packages ?? []).flatMap((slice) => [slice.operational_state?.key, slice.work_package_status, slice.status]),
  ];
  return states.some((state) => state && CLARIFICATION_STATES.has(state));
}

function requestOnlyWaitsOnDependencies(detail: WorkRequestDetail, packageById: Map<string, WorkPackageCard>) {
  const slices = (detail.work_packages ?? []).filter((slice) => {
    const pkg = packageById.get(slice.work_package_id || "");
    const operational = sliceOperationalState(slice, pkg);
    const status = operational?.key || slice.work_package_status || pkg?.operational_state?.key || pkg?.status || slice.status || slice.delivery?.outcome;
    return !isFinishedBoardStatus(status);
  });
  return slices.length > 0 && slices.every((slice) => {
    const dependency = slice.dependency_signal;
    const pkg = packageById.get(slice.work_package_id || "");
    return dependency && (dependency.required > dependency.satisfied || dependency.blocked > 0)
      && sliceActionableBlockerCount(slice, pkg, NO_ACTIVE_BLOCKERS) === 0
      && slice.review_signal?.status !== "failed"
      && slice.pr_signal?.checks?.status !== "failing";
  });
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
