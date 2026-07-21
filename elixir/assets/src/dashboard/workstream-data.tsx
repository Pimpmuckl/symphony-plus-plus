import type { DashboardPayload, WorkRequestPackage, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import { sliceLane } from "@/lib/operational-state";
import { sortedCopy } from "@/lib/collections";
import type { CardDetailSelection } from "./runtime";
import type { WorkstreamCategoryCounts } from "./dashboard-state";
import { repoIdentityKey } from "./dashboard-persistence";

export function requestDetailsByRepoKey(details: WorkRequestDetail[]) {
  return details.reduce<Map<string, WorkRequestDetail[]>>((byRepo, detail) => {
    const repoKey = repoIdentityKey(detail.work_request);
    const repoDetails = byRepo.get(repoKey) || [];
    repoDetails.push(detail);
    byRepo.set(repoKey, repoDetails);
    return byRepo;
  }, new Map());
}

export function activeWorkRequestDetails(dashboard: DashboardPayload | null): WorkRequestDetail[] {
  const detailsById = new Map((dashboard?.work_request_details ?? []).map((detail) => [detail.work_request.id, detail]));

  return (dashboard?.work_requests?.work_requests ?? []).map((request) => {
    const detail = detailsById.get(request.id);
    return {
      ...detail,
      work_request: { ...detail?.work_request, ...request },
      summary: priorityRequestSummary(request, detail?.summary),
    };
  });
}

function priorityRequestSummary(request: WorkRequestDetail["work_request"], current: WorkRequestDetail["summary"] = {}) {
  return {
    ...current,
    open_question_count: request.open_question_count ?? current.open_question_count,
    answered_question_count: request.answered_question_count ?? current.answered_question_count,
    work_package_count: request.work_package_count ?? current.work_package_count,
    planned_work_package_count: request.planned_work_package_count ?? current.planned_work_package_count,
    dispatched_work_package_count: request.dispatched_work_package_count ?? current.dispatched_work_package_count,
    skipped_work_package_count: request.skipped_work_package_count ?? current.skipped_work_package_count,
    comment_count: request.comment_count ?? current.comment_count,
    open_comment_count: request.open_comment_count ?? current.open_comment_count,
  };
}

export function packageSelectionIndex(details: WorkRequestDetail[], packages: WorkPackageCard[]) {
  const packageById = new Map(packages.map((pkg) => [pkg.id, pkg]));
  const selections = new Map<string, CardDetailSelection>();

  details.forEach((detail) => {
    (detail.work_packages || []).forEach((slice) => {
      if (!slice.work_package_id || selections.has(slice.work_package_id)) return;

      const pkg = packageById.get(slice.work_package_id);
      if (!pkg) return;

      selections.set(slice.work_package_id, sliceLane(slice, pkg) === "slices" ? { kind: "slice", detail, slice, pkg } : { kind: "package", pkg, detail, slice });
    });
  });

  return selections;
}

export function packageHasActiveBlocker(pkg: WorkPackageCard) {
  return (pkg.active_blocker_count || 0) > 0 || (pkg.active_blockers || []).some((blocker) => blocker.active !== false);
}

export function sliceSuccessorLabel(slice: WorkRequestPackage) {
  return [
    slice.successor?.work_package?.title,
    slice.successor?.work_package_id,
    slice.successor?.work_package?.title,
    slice.successor?.work_package_id,
    slice.delivery?.successor_work_package_id,
    slice.delivery?.successor_work_package_id,
  ].find(Boolean) || null;
}

export function sortWorkRequestDetails(details: WorkRequestDetail[]) {
  return sortedCopy(details, (left, right) => {
    const leftTime = sortableTime(left.work_request.inserted_at || left.work_request.updated_at);
    const rightTime = sortableTime(right.work_request.inserted_at || right.work_request.updated_at);
    if (leftTime !== rightTime) return leftTime - rightTime;
    return (left.work_request.title || left.work_request.id).localeCompare(right.work_request.title || right.work_request.id);
  });
}

export function sortWorkRequestPackages(slices: WorkRequestPackage[]) {
  return sortedCopy(slices, compareWorkRequestPackages);
}

function compareWorkRequestPackages(left: WorkRequestPackage, right: WorkRequestPackage) {
  const sequenceDelta = sortableSequence(left.sequence) - sortableSequence(right.sequence);
  if (sequenceDelta !== 0) return sequenceDelta;

  const leftTime = sortableTime(left.inserted_at || left.updated_at);
  const rightTime = sortableTime(right.inserted_at || right.updated_at);
  if (leftTime !== rightTime) return leftTime - rightTime;

  return (left.title || left.id).localeCompare(right.title || right.id);
}

function sortableSequence(sequence?: number | null) {
  return typeof sequence === "number" && Number.isFinite(sequence) ? sequence : Number.MAX_SAFE_INTEGER;
}

export function sortableTime(value?: string | null) {
  const timestamp = value ? Date.parse(value) : 0;
  return Number.isNaN(timestamp) ? 0 : timestamp;
}

export function workstreamCategoryCounts(details: WorkRequestDetail[]): WorkstreamCategoryCounts {
  let planNodes = 0;
  let slices = 0;

  details.forEach((detail) => {
    const summary = detail.product_tree?.summary;
    planNodes += summary?.node_count ?? detail.product_tree?.nodes?.length ?? 0;
    slices += summary?.work_package_count ?? detail.work_packages?.length ?? 0;
  });

  return {
    requests: details.length,
    planNodes,
    slices,
  };
}

export function finishedRequestChildrenStorageKey(scopeKey: string, workRequestId: string) {
  return `${scopeKey}::${workRequestId}`;
}
