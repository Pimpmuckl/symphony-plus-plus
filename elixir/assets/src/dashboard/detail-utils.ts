import type { ContextComment, PackageAlertIndicator, PackageOperationalAttention, WorkRequestPackage, WorkPackageCard, WorkPackageDetailPayload, WorkRequestDetail } from "@/types/dashboard";
import { attentionTone, operationalLabel } from "@/lib/operational-state";
import { formatStatus, statusLabel } from "@/lib/status-labels";
import { packageReviewLabel, planProgressLabel } from "@/lib/review-signals";
import { sortedCopy } from "@/lib/collections";
import type { CommentStats, PackageLineageProjection } from "./runtime";
import { formatDate } from "./dashboard-persistence";
import { sliceSuccessorLabel, sortableTime } from "./workstream-data";

export function detailActivityRows(items: Array<{ title?: string | null; body?: string | null; at?: string | null }>) {
  const seen = new Map<string, number>();

  return items.slice(0, 3).map((item) => {
    const baseKey = detailActivityKey(item);
    const occurrence = seen.get(baseKey) || 0;
    seen.set(baseKey, occurrence + 1);
    return { item, key: occurrence === 0 ? baseKey : `${baseKey}:${occurrence}` };
  });
}

function detailActivityKey(item: { title?: string | null; body?: string | null; at?: string | null }) {
  return `activity:${hashText([item.title, item.body, item.at].filter(Boolean).join("|"))}`;
}

function hashText(text: string) {
  let hash = 0;
  for (let index = 0; index < text.length; index += 1) {
    hash = (hash * 31 + text.charCodeAt(index)) | 0;
  }
  return Math.abs(hash).toString(36);
}

export function requestOpenQuestions(detail: WorkRequestDetail) {
  return (detail.clarification_questions || []).filter((question) => question.status === "open");
}

export function requestSliceCounts(detail: WorkRequestDetail) {
  const summary = detail.summary || {};
  const planned = summary.planned_work_package_count ?? detail.work_request.planned_work_package_count ?? 0;
  const dispatched = summary.dispatched_work_package_count ?? detail.work_request.dispatched_work_package_count ?? 0;
  const skipped = summary.skipped_work_package_count ?? detail.work_request.skipped_work_package_count ?? 0;
  const total = summary.work_package_count ?? detail.work_request.work_package_count ?? detail.work_packages?.length ?? 0;

  return { planned, dispatched, skipped, total };
}

export function commentStatLabel(openCount?: number | null, totalCount?: number | null) {
  const open = openCount ?? 0;
  const total = totalCount ?? open;
  return open > 0 ? `${open} open / ${total} total` : String(total);
}

export function commentStats(comments: ContextComment[]): CommentStats {
  const commentCount = comments.length;
  const openCommentCount = comments.filter((comment) => comment.status !== "resolved").length;
  return { comment_count: commentCount, open_comment_count: openCommentCount };
}

function serverCommentStats(counts: { comment_count?: number | null; open_comment_count?: number | null } | null | undefined, fallbackComments: ContextComment[]): CommentStats {
  const fallbackStats = commentStats(fallbackComments);

  return {
    comment_count: counts?.comment_count ?? fallbackStats.comment_count,
    open_comment_count: counts?.open_comment_count ?? fallbackStats.open_comment_count,
  };
}

export function targetCommentStats(
  counts: { comment_count?: number | null; open_comment_count?: number | null } | null | undefined,
  initialComments: ContextComment[],
  currentComments: ContextComment[],
): CommentStats {
  const base = serverCommentStats(counts, initialComments);
  const initialStats = commentStats(initialComments);
  const currentStats = commentStats(currentComments);

  return {
    comment_count: Math.max(0, base.comment_count + currentStats.comment_count - initialStats.comment_count),
    open_comment_count: Math.max(0, base.open_comment_count + currentStats.open_comment_count - initialStats.open_comment_count),
  };
}

export function requestCommentStats(detail: WorkRequestDetail, requestComments: ContextComment[]): CommentStats {
  const sliceComments = (detail.work_packages || []).flatMap((slice) => slice.comments || []);
  const base = serverCommentStats(detail.summary || detail.work_request, [...(detail.comments || []), ...sliceComments]);
  const initialRequestStats = commentStats(detail.comments || []);
  const currentRequestStats = commentStats(requestComments);

  return {
    comment_count: Math.max(0, base.comment_count + currentRequestStats.comment_count - initialRequestStats.comment_count),
    open_comment_count: Math.max(0, base.open_comment_count + currentRequestStats.open_comment_count - initialRequestStats.open_comment_count),
  };
}

export function requestProgressText(detail: WorkRequestDetail) {
  const request = detail.work_request;
  const operational = request.operational_state || null;
  const questions = requestOpenQuestions(detail);
  const slices = requestSliceCounts(detail);

  if (questions.length > 0) {
    return requestQuestionsProgressText(questions.length);
  }

  return requestSlicesProgressText(request, operational, slices) || requestStatusProgressText(request.status);
}

function requestQuestionsProgressText(count: number) {
  return `${count} open human question${count === 1 ? "" : "s"} before the architect can continue.`;
}

function requestSlicesProgressText(
  request: WorkRequestDetail["work_request"],
  operational: WorkRequestDetail["work_request"]["operational_state"] | null,
  slices: ReturnType<typeof requestSliceCounts>,
) {
  if (request.status !== "sliced" && slices.total === 0) return null;

  const state = operational?.key && operational.key !== request.status ? `${operational.label || statusLabel(operational.key)}. ` : "";
  return `${state}${slices.total} WorkPackage${slices.total === 1 ? "" : "s"} recorded: ${slices.planned} planned, ${slices.dispatched} dispatched, ${slices.skipped} skipped.`;
}

function requestStatusProgressText(status?: string | null) {
  if (status === "ready_for_slicing") return "Ready for an architecture agent to plan execution WorkPackages.";
  if (status === "clarifying" || status === "ready_for_clarification") return "Architecture intake is still clarifying the request.";
  return `Current request state: ${formatStatus(status)}.`;
}

export function sliceProgressText(slice: WorkRequestPackage, pkg?: WorkPackageCard) {
  if (pkg) {
    const progress = planProgressLabel(pkg.plan);
    const label = operationalLabel(pkg.operational_state || null, pkg.status);
    return progress ? `WorkPackage is ${label} with ${progress.toLowerCase()}.` : `WorkPackage is ${label}.`;
  }

  if (slice.status === "planned") {
    return "Planned by architecture; not dispatched yet.";
  }

  if (slice.status === "skipped") {
    return "Skipped by architecture and not expected to move forward.";
  }

  return `Current WorkPackage state: ${formatStatus(slice.status)}.`;
}

export function sliceDeliverySummary(slice: WorkRequestPackage, operational: WorkPackageCard["operational_state"]) {
  const closeoutSummary = sliceCloseoutSummary(operational);
  if (closeoutSummary) return closeoutSummary;

  switch (slice.delivery?.outcome) {
    case "completed_no_pr":
      return slice.delivery.no_pr_evidence || "Completed without PR.";
    case "superseded":
      return supersededDeliverySummary(slice);
    case "abandoned":
      return slice.delivery.abandoned_rationale || "Abandoned.";
    case "pr_merged":
      return slice.delivery.pr_url || slice.delivery.pr_repository ? "Merged PR delivery is recorded." : "Merged delivery is recorded.";
    default:
      return null;
  }
}

function sliceCloseoutSummary(operational: WorkPackageCard["operational_state"]) {
  if (operational?.key !== "needs_closeout") return null;
  return operational.attention_items?.[0]?.reason || operational.reason || "Delivery closeout is not recorded.";
}

function supersededDeliverySummary(slice: WorkRequestPackage) {
  const successor = sliceSuccessorLabel(slice);
  if (slice.delivery?.superseded_reason) return slice.delivery.superseded_reason;
  return successor ? `Successor: ${successor}.` : "Superseded.";
}

export function sliceDeliveryFacts(slice: WorkRequestPackage): Array<[string, string | null | undefined]> {
  return presentDetailFacts([...deliveryFacts(slice.delivery), ...successorDeliveryFacts(slice), attentionReasonCodesFact(slice.attention_reason_codes)]);
}

function deliveryFacts(delivery: WorkRequestPackage["delivery"]) {
  if (!delivery) return [];

  return presentDetailFacts([
    ["Outcome", statusLabel(delivery.outcome)],
    ["PR", delivery.pr_url],
    ["Merge Commit", delivery.merge_commit_sha],
    ["Recorded By", delivery.recorded_by],
    ["Recorded", delivery.recorded_at ? detailDate(delivery.recorded_at) : null],
  ]);
}

function successorDeliveryFacts(slice: WorkRequestPackage) {
  return presentDetailFacts([
    ["Successor WorkPackage", slice.successor?.work_package_id || slice.delivery?.successor_work_package_id],
  ]);
}

function attentionReasonCodesFact(reasonCodes?: string[] | null): [string, string | null] {
  return ["Reason Codes", reasonCodes?.length ? reasonCodes.map(statusLabel).join(", ") : null];
}

function presentDetailFacts(facts: Array<[string, string | null | undefined]>) {
  return facts.filter((fact): fact is [string, string] => Boolean(fact[1]));
}

export function latestPackageProgress(payload: WorkPackageDetailPayload | null) {
  return sortedCopy(payload?.progress || [], (left, right) => {
    const sequenceDelta = (right.sequence || 0) - (left.sequence || 0);
    if (sequenceDelta !== 0) return sequenceDelta;
    return sortableTime(right.created_at) - sortableTime(left.created_at);
  });
}

export function planSummaryText(plan?: WorkPackageCard["plan"] | null) {
  return planProgressLabel(plan) || "No plan";
}

export function packageRuntimeText(summary: WorkPackageDetailPayload["summary"] | undefined, pkg: WorkPackageCard) {
  const summaryText = packageRuntimeSummaryText(summary);
  if (summaryText) return summaryText;

  if (pkg.active_agent_run?.stale) return "Stale run";
  if (pkg.active_agent_run?.runtime_state === "queued") return "Queued";
  if (pkg.active_agent_run || (typeof pkg.runtime?.active_count === "number" && pkg.runtime.active_count > 0)) return "Active";
  return "No active run";
}

function packageRuntimeSummaryText(summary: WorkPackageDetailPayload["summary"] | undefined) {
  const runtimeCount = [
    [summary?.stale_agent_run_count, "stale"],
    [summary?.failed_agent_run_count, "failed"],
    [summary?.active_agent_run_count, "active"],
    [summary?.queued_agent_run_count, "queued"],
  ].find(([count]) => Boolean(count));

  return runtimeCount ? `${runtimeCount[0]} ${runtimeCount[1]}` : null;
}

export function packageOperationalFallbackText(pkg: WorkPackageCard) {
  const review = packageReviewLabel(pkg);
  if (review) return `Review signal: ${review}.`;

  const progress = planProgressLabel(pkg.plan);
  if (progress) return `Plan is ${progress.toLowerCase()}.`;

  return `Raw lifecycle status is ${statusLabel(pkg.status)}.`;
}

export function attentionBorderClassName(attention: PackageOperationalAttention) {
  switch (attentionTone(attention)) {
    case "danger":
      return "border-l-rose-400";
    case "warning":
      return "border-l-amber-400";
    case "success":
      return "border-l-emerald-400";
    case "info":
      return "border-l-sky-400";
    default:
      return "border-l-slate-300";
  }
}

export function activeAlertLabels(alerts: PackageAlertIndicator[]) {
  return alerts.reduce<string[]>((items, item) => {
    if (item.active !== false) items.push(item.detail || item.label || item.type || "Alert");
    return items;
  }, []);
}

export function lineageHasSignal(lineage?: WorkPackageCard["lineage"] | null) {
  if (!lineage) return false;
  const rows = lineageDetailRows(lineage);
  return (
    Boolean(lineage.unavailable) ||
    (lineage.cleanup_attention || []).length > 0 ||
    rows.length > 0 ||
    Boolean(lineage.oracle_status?.preserved || lineage.oracle_status?.has_oracle)
  );
}

export function lineageSummary(lineage?: WorkPackageCard["lineage"] | null) {
  if (!lineage) return "None recorded";

  const unavailableSummary = lineageUnavailableSummary(lineage);
  if (unavailableSummary) return unavailableSummary;

  const rows = lineageDetailRows(lineage);
  if (rows.length === 0) return "None recorded";

  const parts = lineageSummaryParts(lineage);
  return parts.length > 0 ? parts.join(" / ") : relationshipCountLabel(rows.length);
}

function lineageUnavailableSummary(lineage: NonNullable<WorkPackageCard["lineage"]>) {
  if (!lineage.unavailable) return null;
  return lineage.error ? `Unavailable: ${lineage.error}` : "Unavailable";
}

function lineageSummaryParts(lineage: NonNullable<WorkPackageCard["lineage"]>) {
  return [
    lineage.recut_as?.length ? `${lineage.recut_as.length} recut` : null,
    lineage.superseded_by?.length ? `${lineage.superseded_by.length} superseded` : null,
    lineage.original_work?.length ? `${lineage.original_work.length} original` : null,
    lineage.oracle_for?.length || lineage.oracle_work?.length ? "oracle" : null,
  ].filter(Boolean);
}

function relationshipCountLabel(count: number) {
  return `${count} relationship${count === 1 ? "" : "s"}`;
}

export function lineageDetailRows(lineage?: WorkPackageCard["lineage"] | null) {
  if (!lineage) return [];
  const explicitSuccessorKeys = new Set([...(lineage.recut_as || []), ...(lineage.superseded_by || [])].map(lineageEntryKey));
  const genericSuccessors = (lineage.successor_work || []).filter((entry) => !explicitSuccessorKeys.has(lineageEntryKey(entry)));

  return [
    ...lineageEntries("Recut as", lineage.recut_as),
    ...lineageEntries("Superseded by", lineage.superseded_by),
    ...lineageEntries("Successor work", genericSuccessors),
    ...lineageEntries("Original work", lineage.original_work),
    ...lineageEntries("Oracle for", lineage.oracle_for),
    ...lineageEntries("Oracle work", lineage.oracle_work),
  ];
}

function lineageEntryKey(entry: NonNullable<PackageLineageProjection["successor_work"]>[number]) {
  return [entry.relationship, entry.work_package_id, entry.target_work_package_id, entry.source_work_package_id, entry.event_id].filter(Boolean).join(":");
}

function lineageEntries(label: string, entries?: PackageLineageProjection["successor_work"]) {
  return (entries || []).map((entry) => ({
    title: `${label} ${entry.work_package_id || entry.target_work_package_id || entry.source_work_package_id || "work package"}`,
    body: lineageEntryBody(entry),
    at: entry.recorded_at,
  }));
}

function lineageEntryBody(entry: NonNullable<PackageLineageProjection["successor_work"]>[number]) {
  const status = entry.status || entry.target_status || entry.source_status;
  const branch = entry.branch || entry.target_branch || entry.source_branch;
  const details = [status ? statusLabel(status) : null, branch, entry.oracle_preserved ? "oracle preserved" : null, entry.reason].filter(Boolean);
  return details.join(" / ");
}

export function latestDecisionLogs(detail: WorkRequestDetail) {
  return sortedCopy(detail.decision_logs || [], (left, right) => {
    const sequenceDelta = (right.sequence || 0) - (left.sequence || 0);
    if (sequenceDelta !== 0) return sequenceDelta;
    return sortableTime(right.created_at || right.inserted_at) - sortableTime(left.created_at || left.inserted_at);
  });
}

export function detailDate(value?: string | null) {
  return value ? formatDate(value) : "Not recorded";
}
