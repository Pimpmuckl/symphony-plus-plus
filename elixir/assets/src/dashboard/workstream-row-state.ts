import type { WorkRequestPackage, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { ProductTreeCompletionMark, ProductTreeNode } from "@/types/product-tree";
import { isFinishedBoardStatus, operationalLabel, sliceOperationalState } from "@/lib/operational-state";
import type { BadgeTone } from "@/lib/operational-state";
import type { StateCardTone } from "@/components/dashboard/state-card-style";

const MIN_STATUS_LABEL_LENGTH = 8;
const MIN_STATUS_BADGE_WIDTH_REM = 6.1;
const MAX_STATUS_BADGE_WIDTH_REM = 11;

export type BoardRowStateKind = "active" | "blocked" | "deferred" | "done" | "guidance" | "not_started" | "partial" | "planned" | "ready" | "unknown";
export type BoardRowState = {
  badgeVariant: BadgeTone;
  kind: BoardRowStateKind;
  label: string;
  tone: StateCardTone;
};

const BOARD_ROW_STATES: Record<BoardRowStateKind, BoardRowState> = {
  active: { badgeVariant: "info", kind: "active", label: "Active", tone: "implementing" },
  blocked: { badgeVariant: "danger", kind: "blocked", label: "Blocked", tone: "blocked" },
  deferred: { badgeVariant: "secondary", kind: "deferred", label: "Deferred", tone: "muted" },
  done: { badgeVariant: "success", kind: "done", label: "Done", tone: "finished" },
  guidance: { badgeVariant: "guidance", kind: "guidance", label: "Guidance Needed", tone: "guidance" },
  not_started: { badgeVariant: "secondary", kind: "not_started", label: "Not started", tone: "muted" },
  partial: { badgeVariant: "secondary", kind: "partial", label: "Partial", tone: "muted" },
  planned: { badgeVariant: "secondary", kind: "planned", label: "Planned", tone: "muted" },
  ready: { badgeVariant: "ready", kind: "ready", label: "Ready", tone: "ready" },
  unknown: { badgeVariant: "secondary", kind: "unknown", label: "Unknown", tone: "slice" },
};

export function statusBadgeWidthForLabels(labels: Iterable<string | null | undefined>) {
  const width = Math.min(MAX_STATUS_BADGE_WIDTH_REM, Math.max(MIN_STATUS_BADGE_WIDTH_REM, longestStatusLabelLength(labels) * 0.3 + 3.2));
  return `${Number(width.toFixed(2))}rem`;
}

export function statusBadgeWidthForRequestDetails(details: WorkRequestDetail[], packageById: Map<string, WorkPackageCard>) {
  return statusBadgeWidthForLabels(details.flatMap((detail) => requestStatusLabels(detail, packageById)));
}

export function workRequestIsTerminal(detail: WorkRequestDetail) {
  const request = detail.work_request;
  return Boolean(request.completed_at || request.archived_at || [request.status, request.operational_state?.key].includes("completed"));
}

export function workPackageIsTerminal(slice: WorkRequestPackage, pkg?: WorkPackageCard) {
  const operational = slice.operational_state ?? pkg?.operational_state;
  return Boolean(slice.delivery?.outcome || operational?.delivery_outcome)
    || isFinishedBoardStatus(operational?.key || slice.work_package_status || pkg?.status || slice.status);
}

export function terminalWorkPackageIds(details: WorkRequestDetail[], packageById: Map<string, WorkPackageCard>) {
  const detailIds = details.flatMap((detail) => (detail.work_packages ?? [])
    .filter((slice) => workRequestIsTerminal(detail) || workPackageIsTerminal(slice, packageById.get(slice.work_package_id || slice.id)))
    .flatMap((slice) => [slice.id, slice.work_package_id].filter((id): id is string => Boolean(id))));
  const packageIds = [...packageById.values()]
    .filter((pkg) => Boolean(pkg.operational_state?.delivery_outcome) || isFinishedBoardStatus(pkg.operational_state?.key || pkg.status))
    .map((pkg) => pkg.id);
  return new Set([...detailIds, ...packageIds]);
}

export function requestBoardState(
  detail: WorkRequestDetail,
  packageById: Map<string, WorkPackageCard>,
  counts: { blockerCount: number; guidanceCount: number },
  progress: number,
): BoardRowState {
  const request = detail.work_request;
  const rawStatus = request.operational_state?.key || request.status;
  return aggregateBoardRowState({
    blockerCount: counts.blockerCount,
    childrenComplete: productTreeIsComplete(detail),
    completionDone: isFinishedBoardStatus(rawStatus),
    fallbackLabel: operationalLabel(request.operational_state, request.status),
    fallbackStatus: rawStatus,
    guidanceCount: counts.guidanceCount,
    progress,
    slices: detail.work_packages ?? [],
    packageById,
  });
}

export function requestStatusLabels(detail: WorkRequestDetail, packageById: Map<string, WorkPackageCard>) {
  const request = detail.work_request;
  const labels = [operationalLabel(request.operational_state, request.status)];

  for (const node of detail.product_tree?.nodes ?? []) {
    labels.push(productNodeStatusLabel(node));
  }

  for (const slice of detail.work_packages ?? []) {
    const pkg = packageById.get(slice.work_package_id || "");
    labels.push(operationalLabel(sliceOperationalState(slice, pkg), slice.work_package_status || slice.status));
  }

  return labels;
}

function longestStatusLabelLength(labels: Iterable<string | null | undefined>) {
  let longest = MIN_STATUS_LABEL_LENGTH;

  for (const label of labels) {
    longest = Math.max(longest, label?.trim().length ?? 0);
  }

  return longest;
}

function productNodeStatusLabel(node: ProductTreeNode, mark = node.computed_completion_mark || node.completion_mark || "unknown") {
  return node.completion_label || completionMarkLabel(mark);
}

function aggregateBoardRowState({
  blockerCount,
  childrenComplete = true,
  completionDeferred = false,
  completionDone = false,
  fallbackLabel,
  fallbackStatus,
  guidanceCount,
  packageById,
  progress,
  slices,
}: {
  blockerCount: number;
  childrenComplete?: boolean;
  completionDeferred?: boolean;
  completionDone?: boolean;
  fallbackLabel?: string | null;
  fallbackStatus?: string | null;
  guidanceCount: number;
  packageById: Map<string, WorkPackageCard>;
  progress: number;
  slices: WorkRequestPackage[];
}): BoardRowState {
  const childState = aggregateChildSliceState(slices, packageById);
  const derived = firstMatchingBoardRowState([
    [completionDone, "done", finishedFallbackLabel(fallbackLabel)],
    [completionDeferred, "deferred", fallbackLabel],
    [blockerCount > 0 || childState.blocked, "blocked"],
    [guidanceCount > 0 || childState.guidance, "guidance"],
    [childState.active, "active"],
    [childState.ready, "ready"],
    [childState.planned, "planned"],
    [childState.done && childrenComplete, "done", finishedFallbackLabel(fallbackLabel)],
    [progress > 0 || fallbackStatus === "partial", "partial"],
    [childState.deferred, "deferred", fallbackLabel],
    [childState.notStarted, "not_started"],
  ]);

  return derived ?? boardRowStateFromStatus(fallbackStatus, fallbackLabel);
}

type AggregateChildSliceState = {
  active: boolean;
  blocked: boolean;
  deferred: boolean;
  done: boolean;
  guidance: boolean;
  notStarted: boolean;
  planned: boolean;
  ready: boolean;
};

function aggregateChildSliceState(slices: WorkRequestPackage[], packageById: Map<string, WorkPackageCard>): AggregateChildSliceState {
  const state: AggregateChildSliceState = {
    active: false,
    blocked: false,
    deferred: false,
    done: slices.length > 0,
    guidance: false,
    notStarted: false,
    planned: slices.length > 0,
    ready: false,
  };

  for (const slice of slices) {
    const kind = sliceBoardStateKind(slice, packageById.get(slice.work_package_id || ""));
    state.active ||= kind === "active";
    state.blocked ||= kind === "blocked";
    state.deferred ||= kind === "deferred";
    state.guidance ||= kind === "guidance";
    state.notStarted ||= kind === "not_started";
    state.planned &&= kind === "planned";
    state.ready ||= kind === "ready";
    state.done &&= kind === "done";
  }

  return state;
}

function sliceBoardStateKind(slice: WorkRequestPackage, pkg?: WorkPackageCard): BoardRowStateKind {
  const operational = sliceOperationalState(slice, pkg);
  const status = operational?.key || slice.work_package_status || pkg?.operational_state?.key || pkg?.status || slice.status;
  return firstMatchingBoardRowKind([
    [sliceHasFailedGate(slice), "blocked"],
    [sliceHasActiveWork(slice, pkg, status), "active"],
    [isFinishedBoardStatus(status), "done"],
    [sliceIsBlocked(slice, pkg, status), "blocked"],
    [sliceGuidanceCount(slice, pkg) > 0, "guidance"],
    [statusIn(READY_STATUSES, status), "ready"],
    [statusIn(PLANNED_STATUSES, status), "planned"],
    [statusIn(DEFERRED_STATUSES, status), "deferred"],
    [statusIn(NOT_STARTED_STATUSES, status), "not_started"],
  ]) ?? "unknown";
}

function sliceHasFailedGate(slice: WorkRequestPackage) {
  return slice.review_signal?.status === "failed" || slice.pr_signal?.checks?.status === "failing";
}

function sliceIsBlocked(slice: WorkRequestPackage, pkg: WorkPackageCard | undefined, status?: string | null) {
  return status === "blocked" || sliceBlockerCount(slice, pkg, new Map()) > 0;
}

function productTreeIsComplete(detail: WorkRequestDetail) {
  const nodes = detail.product_tree?.nodes ?? [];
  return nodes.length === 0 || nodes.every((node) => ["done", "deferred"].includes(node.computed_completion_mark || node.completion_mark || "unknown"));
}

function sliceHasActiveWork(slice: WorkRequestPackage, pkg: WorkPackageCard | undefined, status?: string | null) {
  return Boolean(packageHasActiveRuntime(pkg) || ACTIVE_WORK_STATUSES.has(status || "") || slice.operational_state?.has_active_worker);
}

function packageHasActiveRuntime(pkg?: WorkPackageCard) {
  return Boolean(pkg?.active_agent_run || (typeof pkg?.runtime?.active_count === "number" && pkg.runtime.active_count > 0));
}

function boardRowState(kind: BoardRowStateKind, label?: string | null): BoardRowState {
  const state = BOARD_ROW_STATES[kind];
  return label?.trim() ? { ...state, label: label.trim() } : state;
}

function boardRowStateFromStatus(status?: string | null, label?: string | null): BoardRowState {
  return firstMatchingBoardRowState([
    [statusIn(ACTIVE_WORK_STATUSES, status), "active"],
    [isFinishedBoardStatus(status), "done", finishedFallbackLabel(label)],
    [status === "blocked", "blocked"],
    [statusIsGuidance(status), "guidance", label],
    [statusIn(READY_STATUSES, status), "ready", label],
    [statusIn(PLANNED_STATUSES, status), "planned", label],
    [statusIn(DEFERRED_STATUSES, status), "deferred", label],
    [statusIn(NOT_STARTED_STATUSES, status), "not_started", label],
    [status === "partial", "partial", label],
    [status === "in_progress", "active", label],
  ]) ?? boardRowState("unknown", label);
}

type BoardRowStateRule = [boolean, BoardRowStateKind, (string | null)?];

function firstMatchingBoardRowState(rules: BoardRowStateRule[]) {
  const rule = rules.find(([matches]) => matches);
  return rule ? boardRowState(rule[1], rule[2]) : null;
}

function firstMatchingBoardRowKind(rules: Array<[boolean, BoardRowStateKind]>) {
  return rules.find(([matches]) => matches)?.[1] ?? null;
}

function statusIn(statuses: Set<string>, status?: string | null) {
  return statuses.has(status || "");
}

function finishedFallbackLabel(label?: string | null) {
  const text = label?.trim();
  return text && !["Finished", "Unknown"].includes(text) ? text : "Done";
}

const ACTIVE_WORK_STATUSES = new Set([
  "active",
  "ci_waiting",
  "claimed",
  "dispatched",
  "implementing",
  "in_progress",
  "merge_ready",
  "merging",
  "merging_into_phase",
  "planning",
  "needs_closeout",
  "ready_for_architect_merge",
  "ready_for_merge",
  "ready_for_human_merge",
  "reviewing",
]);

const READY_STATUSES = new Set(["approved", "ready_for_slicing", "ready_for_worker", "ready_to_finish", "sliced"]);
const PLANNED_STATUSES = new Set(["planned"]);
const NOT_STARTED_STATUSES = new Set(["created", "not_done"]);
const DEFERRED_STATUSES = new Set(["abandoned", "deferred", "skipped", "superseded"]);

function completionMarkLabel(mark: ProductTreeCompletionMark) {
  switch (mark) {
    case "done":
      return "Done";
    case "partial":
      return "Partial";
    case "not_done":
      return "Not started";
    case "deferred":
      return "Deferred";
    default:
      return "Unknown";
  }
}

export function sliceBlockerCount(
  slice: WorkRequestPackage,
  pkg: WorkPackageCard | undefined,
  activeBlockerCountBySliceId: Map<string, number>,
) {
  const activeCount = sliceActionableBlockerCount(slice, pkg, activeBlockerCountBySliceId);
  if (activeCount > 0) return activeCount;

  const operational = sliceOperationalState(slice, pkg);
  return [operational?.key, slice.work_package_status, slice.status, pkg?.status].includes("blocked") ? 1 : 0;
}

export function sliceActionableBlockerCount(
  slice: WorkRequestPackage,
  pkg: WorkPackageCard | undefined,
  activeBlockerCountBySliceId: Map<string, number>,
) {
  const operational = sliceOperationalState(slice, pkg);
  const activeCount = Math.max(activeBlockerCountBySliceId.get(slice.id) ?? 0, pkg?.active_blocker_count ?? 0);

  if (activeCount > 0) return activeCount;
  return attentionBlockerCount(operational);
}

export function sliceGuidanceCount(slice: WorkRequestPackage, pkg: WorkPackageCard | undefined) {
  const operational = sliceOperationalState(slice, pkg);
  const guidanceAttention = (operational?.attention_items ?? []).filter(attentionItemIsGuidance).length;
  const stateNeedsGuidance = [operational?.key, slice.status, slice.work_package_status, pkg?.status].some((status) =>
    statusIsGuidance(status),
  );

  return Math.max(guidanceAttention, stateNeedsGuidance ? 1 : 0);
}

function attentionBlockerCount(operational?: WorkPackageCard["operational_state"]) {
  const blockerIds = new Set<string>();
  let fallbackCount = 0;

  for (const item of operational?.attention_items ?? []) {
    if (!attentionItemIsBlocker(item)) continue;

    fallbackCount += 1;
    for (const blockerId of item.blocker_ids ?? []) blockerIds.add(blockerId);
  }

  return blockerIds.size || fallbackCount;
}

function attentionItemIsBlocker(item: NonNullable<NonNullable<WorkPackageCard["operational_state"]>["attention_items"]>[number]) {
  const key = (item.key || "").toLowerCase();
  const label = (item.label || "").toLowerCase();
  return key.includes("blocker") || label.includes("blocker") || (item.blocker_ids?.length ?? 0) > 0;
}

function attentionItemIsGuidance(item: NonNullable<NonNullable<WorkPackageCard["operational_state"]>["attention_items"]>[number]) {
  const key = (item.key || "").toLowerCase();
  const label = (item.label || "").toLowerCase();
  return statusIsGuidance(key) || key.includes("guidance") || key.includes("question") || label.includes("guidance") || label.includes("question");
}

function statusIsGuidance(status?: string | null) {
  return status === "human_info_needed" || status === "ready_for_clarification" || status === "clarifying";
}
