import type { ActiveBlockingEdge, GuidanceItem, WorkPackageCard, WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";
import { AlertTriangle, ChevronRight, Copy, GitBranch } from "lucide-react";
import type { CSSProperties } from "react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { copyTextToClipboard, CardDetailSelect, DashboardUpdateAnimations } from "./runtime";
import { clarificationGuidanceItem } from "./dashboard-data";
import { finishedRequestChildrenStorageKey, sortWorkRequestPackages, sortWorkRequestDetails } from "./workstream-data";
import { activeBlockerEntityCounts, productTreeCounts, requestProgress } from "./workstream-progress";
import { requestBoardState, sliceBlockerCount, sliceGuidanceCount, type BoardRowStateKind } from "./workstream-row-state";
import { RequestInfoButton, RequestProgressBar, RowBadgeSlot } from "./workstream-row-ui";
import { requestUpdateKey } from "./update-animations";
import { dashboardPrefersReducedMotion, updateMotionAttributes } from "@/components/dashboard/motion-utils";
import { useAutoCollapseWhenDone } from "./workstream-auto-collapse";
import { WorkstreamContextBar } from "./workstream-context-bar";
import { contextPathValue, type ContextPathPart } from "./workstream-context-path";
import { workRequestExecutionGraphModel } from "./execution-graph/adapter";
import { isFinishedBoardStatus, operationalLabel, operationalStatusIsRunning, sliceOperationalState } from "@/lib/operational-state";
import { PullRequestBadge, WorkRequestExecutionGraph } from "./work-request-execution-graph";
import { requestBadgeLabel } from "./workstream-row-age";

const REQUEST_EXIT_MOTION_MS = 320;
const NO_SLICE_BLOCKERS = new Map<string, number>();

export type RequestFrontierMode = "attention" | "active" | "next" | "recent" | "waiting";

export function WorkstreamBoard({
  repoLabel,
  repoDetails,
  now,
  packages,
  activeBlockingEdges,
  onSelectGuidance,
  onSelectCard,
  primaryBranch,
  expandedFinishedRequests,
  finishedRequestScopeKey,
  onSetFinishedRequestChildrenOpen,
  showContextBar,
  updateAnimations,
}: {
  repoLabel: string;
  repoDetails: WorkRequestDetail[];
  now?: string;
  packages: WorkPackageCard[];
  activeBlockingEdges: ActiveBlockingEdge[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  primaryBranch?: string;
  expandedFinishedRequests: Record<string, boolean>;
  finishedRequestScopeKey: string;
  onSetFinishedRequestChildrenOpen: (workRequestId: string, open: boolean) => void;
  showContextBar: boolean;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const [renderDetails, exitingRequestIds] = useExitingRequestDetails(repoDetails);
  const sortedDetails = useMemo(() => sortWorkRequestDetails(renderDetails), [renderDetails]);
  const sortedActiveDetails = useMemo(() => sortWorkRequestDetails(repoDetails), [repoDetails]);
  const packageById = useMemo(() => new Map(packages.map((pkg) => [pkg.id, pkg])), [packages]);
  const blockerCounts = useMemo(() => activeBlockerEntityCounts(activeBlockingEdges, repoDetails), [activeBlockingEdges, repoDetails]);
  const boardRef = useRef<HTMLDivElement | null>(null);
  const contextSignature = useMemo(() => workstreamContextSignature(sortedActiveDetails), [sortedActiveDetails]);

  return (
    <div className="workstream-board-shell">
      {showContextBar ? <WorkstreamContextBar boardRef={boardRef} repoLabel={repoLabel} signature={contextSignature} /> : null}
      <div ref={boardRef} className="v3-workstream-board">
        {sortedDetails.map((detail, index) => {
          const stateKey = finishedRequestChildrenStorageKey(finishedRequestScopeKey, detail.work_request.id);
          const expanded = expandedFinishedRequests[stateKey] === true;
          const exiting = exitingRequestIds.has(detail.work_request.id);

          return (
            <ProductRequestRow
              key={exiting ? `${detail.work_request.id}:exiting` : detail.work_request.id}
              detail={detail}
              now={now}
              exiting={exiting}
              packageById={packageById}
              activeBlockerCount={blockerCounts.requests.get(detail.work_request.id) ?? 0}
              expanded={expanded}
              index={index}
              onSetOpen={(open) => onSetFinishedRequestChildrenOpen(detail.work_request.id, open)}
              onSelectGuidance={onSelectGuidance}
              onSelectCard={onSelectCard}
              primaryBranch={primaryBranch}
              updateAnimations={updateAnimations}
            />
          );
        })}
      </div>
    </div>
  );
}

function useExitingRequestDetails(currentDetails: WorkRequestDetail[]) {
  const previousDetailsRef = useRef(currentDetails);
  const timersRef = useRef<number[]>([]);
  const [exitingDetails, setExitingDetails] = useState<WorkRequestDetail[]>([]);

  useLayoutEffect(() => {
    const currentIds = new Set(currentDetails.map(requestDetailId));
    const removedDetails = previousDetailsRef.current.filter((detail) => !currentIds.has(requestDetailId(detail)));
    previousDetailsRef.current = currentDetails;

    if (removedDetails.length === 0 || dashboardPrefersReducedMotion()) return;

    const removedIds = new Set(removedDetails.map(requestDetailId));
    setExitingDetails((current) => mergeRequestDetailsWithExiting(current, removedDetails));

    const timer = window.setTimeout(() => {
      setExitingDetails((current) => current.filter((detail) => !removedIds.has(requestDetailId(detail))));
    }, REQUEST_EXIT_MOTION_MS);

    timersRef.current.push(timer);
  }, [currentDetails]);

  useEffect(
    () => () => {
      timersRef.current.forEach((timer) => window.clearTimeout(timer));
      timersRef.current = [];
    },
    [],
  );

  const currentIds = useMemo(() => new Set(currentDetails.map(requestDetailId)), [currentDetails]);
  const renderDetails = useMemo(() => mergeRequestDetailsWithExiting(currentDetails, exitingDetails), [currentDetails, exitingDetails]);
  const exitingIds = useMemo(
    () => new Set(exitingDetails.map(requestDetailId).filter((id) => !currentIds.has(id))),
    [currentIds, exitingDetails],
  );

  return [renderDetails, exitingIds] as const;
}

export function mergeRequestDetailsWithExiting(currentDetails: WorkRequestDetail[], exitingDetails: WorkRequestDetail[]) {
  const currentIds = new Set(currentDetails.map(requestDetailId));
  return [...currentDetails, ...exitingDetails.filter((detail) => !currentIds.has(requestDetailId(detail)))];
}

function requestDetailId(detail: WorkRequestDetail) {
  return detail.work_request.id;
}

function workstreamContextSignature(details: WorkRequestDetail[]) {
  return JSON.stringify(
    details.map((detail) => ({
      nodes: (detail.product_tree?.nodes ?? []).map((node) => ({
        id: node.id,
        label: node.title || node.id,
        parentId: node.parent_id || null,
        sliceIds: node.work_package_ids ?? [],
      })),
      request: {
        id: detail.work_request.id,
        label: detail.work_request.title || detail.work_request.id,
      },
      rootNodeIds: detail.product_tree?.root_node_ids ?? [],
      rootSliceIds: detail.product_tree?.root_work_package_ids ?? [],
    })),
  );
}

export function ProductRequestRow({
  detail,
  now,
  exiting = false,
  packageById,
  activeBlockerCount,
  expanded,
  index,
  onSetOpen,
  onSelectGuidance,
  onSelectCard,
  primaryBranch,
  frontierMode,
  autoCollapseWhenDone = true,
  updateAnimations,
}: {
  detail: WorkRequestDetail;
  now?: string;
  exiting?: boolean;
  packageById: Map<string, WorkPackageCard>;
  activeBlockerCount: number;
  expanded: boolean;
  index: number;
  onSetOpen: (open: boolean) => void;
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  primaryBranch?: string;
  frontierMode?: RequestFrontierMode;
  autoCollapseWhenDone?: boolean;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const request = detail.work_request;
  const requestTitle = request.title || request.id;
  const requestPath = [{ id: request.id, label: requestTitle }];
  const slices = sortWorkRequestPackages(detail.work_packages ?? []);
  const progress = requestProgress(detail, packageById);
  const counts = productTreeCounts(detail, activeBlockerCount);
  const openQuestion = detail.clarification_questions?.find((question) => question.status === "open");
  const branch = visibleRequestBranch(request.base_branch, primaryBranch);
  const requestState = requestBoardState(detail, packageById, counts, progress);
  const tone = requestState.tone;
  const requestLabel = requestState.label;
  const frontier = requestFrontier(detail, slices, packageById, frontierMode ?? requestFrontierMode(requestState.kind), requestLabel);
  const badgeLabel = requestBadgeLabel(requestLabel, detail, packageById, now);
  const rowStyle = {
    animationDelay: `${index * 30}ms`,
  } as CSSProperties;
  const requestFinished = requestState.kind === "done";
  const collapseRequest = useCallback(() => onSetOpen(false), [onSetOpen]);
  useAutoCollapseWhenDone(requestFinished, expanded, collapseRequest, requestFinished && autoCollapseWhenDone);
  const updateMotion = requestRowUpdateMotion(exiting, detail, updateAnimations);

  return (
    <section
      className="v3-request-row stagger-item"
      aria-hidden={exiting}
      inert={exiting}
      data-expanded={expanded ? "true" : "false"}
      data-v3-context-path={contextPathValue(requestPath)}
      data-tone={tone}
      style={rowStyle}
      {...updateMotionAttributes(updateMotion)}
    >
      <div className="v3-request-header v3-entity-row" data-tone={tone}>
        <button type="button" className="v3-request-chevron-button" aria-expanded={expanded} aria-label={`${expanded ? "Collapse" : "Expand"} ${requestTitle}`} onClick={() => onSetOpen(!expanded)}>
          <ChevronRight className={cn("size-4 transition-transform duration-200", expanded && "rotate-90")} />
        </button>
        <RequestInfoButton detail={detail} onSelectCard={onSelectCard} />
        <button type="button" className="v3-request-main" aria-expanded={expanded} onClick={() => onSetOpen(!expanded)}>
          <RequestIdentity detail={detail} branch={branch} />
        </button>
        <RequestProgressBar progress={progress} />
        <RowBadgeSlot active={requestState.kind === "active"} label={badgeLabel} variant={requestState.badgeVariant} />
        <RequestFrontier summary={frontier} />
      </div>
      {expanded ? <RequestExpandedBody detail={detail} now={now} packageById={packageById} openQuestion={openQuestion} onSelectGuidance={onSelectGuidance} onSelectCard={onSelectCard} requestPath={requestPath} /> : null}
    </section>
  );
}

function RequestIdentity({ detail, branch }: { detail: WorkRequestDetail; branch?: string }) {
  const request = detail.work_request;
  return (
    <span className="v3-request-title-group">
      <span className="v3-request-title">{request.title || request.id}</span>
      <span className="v3-request-meta">
        <GitBranch className="size-3.5" />
        <span>{request.repo_display || request.repo || "repo"}</span>
        {branch ? <span className="v3-request-branch">{branch}</span> : null}
      </span>
    </span>
  );
}

function RequestExpandedBody({
  detail,
  now,
  packageById,
  openQuestion,
  onSelectGuidance,
  onSelectCard,
  requestPath,
}: {
  detail: WorkRequestDetail;
  now?: string;
  packageById: Map<string, WorkPackageCard>;
  openQuestion?: NonNullable<WorkRequestDetail["clarification_questions"]>[number];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  requestPath: ContextPathPart[];
}) {
  return (
    <div className="v3-request-body">
      {requestHasWork(detail) ? <>
        <RequestActions detail={detail} openQuestion={openQuestion} onSelectGuidance={onSelectGuidance} />
        <ExecutionGraphBody detail={detail} now={now} packageById={packageById} onSelectCard={onSelectCard} requestPath={requestPath} />
      </> : <EmptyWorkRequest workRequestId={detail.work_request.id} />}
    </div>
  );
}

function requestRowUpdateMotion(exiting: boolean, detail: WorkRequestDetail, updateAnimations: DashboardUpdateAnimations) {
  if (exiting) return { kind: "removed" as const, token: 0 };
  return updateAnimations.motionFor(requestUpdateKey(detail));
}

type RequestFrontierItem = {
  activity?: string;
  id: string;
  pr?: WorkRequestPackage["pr_signal"];
  title: string;
};

type RequestFrontierGroup = {
  id: string;
  items: RequestFrontierItem[];
  title?: string;
};

type RequestFrontierSummary = {
  groups: RequestFrontierGroup[];
  moreLabel?: string;
};

function RequestFrontier({ summary }: { summary: RequestFrontierSummary | null }) {
  if (!summary) return <div className="v3-request-frontier" />;

  return (
    <div className="v3-request-frontier">
      {summary.groups.map((group) => (
        <div className="v3-request-frontier-group" data-grouped={group.title ? "true" : "false"} role={group.title ? "group" : undefined} aria-label={group.title} key={group.id}>
          {group.title ? (
            <span className="v3-request-frontier-group-title" title={group.title}>
              <span className="v3-request-frontier-group-title-label" data-frontier-measure="group">{group.title}</span>
              <span className="v3-request-frontier-source" data-frontier-wire-source="true" aria-hidden="true" />
            </span>
          ) : null}
          <div className="v3-request-frontier-packages" data-frontier-wire-trunk={group.title ? "true" : undefined} role="list">
            {group.items.map((item, index) => (
              <div className="v3-request-frontier-package" data-first={group.title && index === 0 ? "true" : undefined} data-last={group.title && index === group.items.length - 1 ? "true" : undefined} role="listitem" key={item.id}>
                {group.title ? <span className="v3-request-frontier-wire" data-frontier-wire="true" aria-hidden="true" /> : null}
                <span className="v3-request-frontier-title" data-frontier-measure="title" title={item.title}>{item.title}</span>
                <PullRequestBadge signal={item.pr} layout="frontier" />
                {item.activity ? <span className="v3-request-frontier-activity" data-frontier-measure="state">{item.activity}</span> : null}
              </div>
            ))}
          </div>
        </div>
      ))}
      {summary.moreLabel ? <span className="v3-request-frontier-more">{summary.moreLabel}</span> : null}
    </div>
  );
}

function requestFrontier(
  detail: WorkRequestDetail,
  slices: WorkRequestPackage[],
  packageById: Map<string, WorkPackageCard>,
  mode: RequestFrontierMode,
  overallLabel: string,
): RequestFrontierSummary | null {
  const relevant = slices.filter((slice) => frontierSliceMatches(mode, slice, packageById.get(slice.work_package_id || slice.id)));
  if (!relevant.length) return null;

  const visible = mode === "active" ? relevant : relevant.slice(0, 3);
  const groups = frontierGroups(detail, visible, packageById, overallLabel);
  const hiddenCount = relevant.length - visible.length;
  return { groups, moreLabel: hiddenCount ? `+${hiddenCount} more ${frontierMoreNoun(mode)}` : undefined };
}

function frontierGroups(
  detail: WorkRequestDetail,
  slices: WorkRequestPackage[],
  packageById: Map<string, WorkPackageCard>,
  overallLabel: string,
) {
  const groups = new Map<string, RequestFrontierGroup>();
  for (const slice of slices) {
    const identity = frontierGroupIdentity(detail, slice);
    let entry = groups.get(identity.id);
    if (!entry) {
      entry = { ...identity, items: [] };
      groups.set(identity.id, entry);
    }
    entry.items.push(frontierItem(slice, packageById, overallLabel));
  }
  return [...groups.values()];
}

function frontierGroupIdentity(detail: WorkRequestDetail, slice: WorkRequestPackage) {
  const group = workPackageOwnerNode(detail, slice);
  return { id: group?.id ?? "ungrouped", title: group?.title?.trim() || undefined };
}

function frontierItem(slice: WorkRequestPackage, packageById: Map<string, WorkPackageCard>, overallLabel: string): RequestFrontierItem {
  const pkg = packageById.get(slice.work_package_id || slice.id);
  return {
    activity: frontierActivity(slice, pkg, overallLabel),
    id: slice.id,
    pr: slice.pr_signal ?? undefined,
    title: slice.title?.trim() || slice.id,
  };
}

function workPackageOwnerNode(detail: WorkRequestDetail, slice: WorkRequestPackage) {
  const nodes = detail.product_tree?.nodes ?? [];
  return slice.product_tree_node_id
    ? nodes.find((node) => node.id === slice.product_tree_node_id)
    : nodes.find((node) => node.work_package_ids?.some((id) => id === slice.id || id === slice.work_package_id));
}

function requestFrontierMode(kind: BoardRowStateKind): RequestFrontierMode {
  if (kind === "active") return "active";
  if (kind === "blocked" || kind === "guidance") return "attention";
  if (kind === "done") return "recent";
  if (["not_started", "planned", "ready"].includes(kind)) return "next";
  return "waiting";
}

function frontierSliceMatches(mode: RequestFrontierMode, slice: WorkRequestPackage, pkg?: WorkPackageCard) {
  if (mode === "attention") return sliceNeedsAttention(slice, pkg);
  if (mode === "active") return sliceIsRunning(slice, pkg);
  if (mode === "recent") return sliceIsFinished(slice, pkg);
  if (mode === "waiting") return sliceIsWaiting(slice, pkg);
  return !sliceIsFinished(slice, pkg) && !sliceIsRunning(slice, pkg) && !sliceNeedsAttention(slice, pkg) && !sliceIsWaiting(slice, pkg);
}

function sliceNeedsAttention(slice: WorkRequestPackage, pkg?: WorkPackageCard) {
  const dependencyWaiting = sliceHasUnsatisfiedDependencies(slice);
  return slice.review_signal?.status === "failed"
    || slice.pr_signal?.checks?.status === "failing"
    || sliceGuidanceCount(slice, pkg) > 0
    || (sliceBlockerCount(slice, pkg, NO_SLICE_BLOCKERS) > 0 && (!dependencyWaiting || (pkg?.active_blocker_count ?? 0) > 0));
}

function sliceIsWaiting(slice: WorkRequestPackage, pkg?: WorkPackageCard) {
  if (sliceHasUnsatisfiedDependencies(slice)) return true;
  const status = sliceStatus(slice, pkg).toLowerCase();
  return /blocked|deferred|paused|pending|queued|waiting/.test(status);
}

function sliceHasUnsatisfiedDependencies(slice: WorkRequestPackage) {
  const dependency = slice.dependency_signal;
  return Boolean(dependency && (dependency.required > dependency.satisfied || dependency.blocked > 0));
}

function frontierActivity(slice: WorkRequestPackage, pkg: WorkPackageCard | undefined, overallLabel: string) {
  const review = slice.review_signal;
  const checks = slice.pr_signal?.checks;
  const status = sliceStatus(slice, pkg);
  const activity = frontierFailureActivity(review, checks)
    ?? frontierCurrentActivity(slice, review, checks, status)
    ?? frontierWaitingActivity(slice)
    ?? frontierCompletionActivity(slice, review, checks)
    ?? operationalLabel(sliceOperationalState(slice, pkg), status);
  return activity.trim().toLowerCase() === overallLabel.trim().toLowerCase() ? undefined : activity;
}

function frontierFailureActivity(review: WorkRequestPackage["review_signal"], checks: NonNullable<WorkRequestPackage["pr_signal"]>["checks"]) {
  if (review?.status === "failed") return `Review${signalProgress(review.current, review.total)} failed`;
  if (checks?.status === "failing") return `CI${signalProgress(checks.current, checks.total)} failed`;
  return undefined;
}

function frontierCurrentActivity(
  slice: WorkRequestPackage,
  review: WorkRequestPackage["review_signal"],
  checks: NonNullable<WorkRequestPackage["pr_signal"]>["checks"],
  status: string,
) {
  if (review?.status === "in_progress") return `Review${signalProgress(review.current, review.total)}`;
  if (checks?.status === "pending") return `CI${signalProgress(checks.current, checks.total)}`;
  if (["merge_ready", "ready_for_merge", "ready_for_architect_merge", "ready_for_human_merge"].includes(status)) return "Ready to merge";
  if (slice.worker_signal?.status === "active") return "Implementing";
  return undefined;
}

function frontierWaitingActivity(slice: WorkRequestPackage) {
  if (sliceHasUnsatisfiedDependencies(slice)) {
    const dependency = slice.dependency_signal!;
    return `Waiting ${dependency.satisfied}/${dependency.required}`;
  }
  return undefined;
}

function frontierCompletionActivity(
  slice: WorkRequestPackage,
  review: WorkRequestPackage["review_signal"],
  checks: NonNullable<WorkRequestPackage["pr_signal"]>["checks"],
) {
  if (slice.pr_signal?.status === "merged") return "Merged";
  if (review?.status === "passed") return "Review passed";
  if (checks?.status === "passing") return "CI passed";
  return undefined;
}

function sliceStatus(slice: WorkRequestPackage, pkg?: WorkPackageCard) {
  return sliceOperationalState(slice, pkg)?.key || slice.work_package_status || pkg?.operational_state?.key || pkg?.status || slice.status || "planned";
}

function signalProgress(current?: number | null, total?: number | null) {
  return current == null || total == null ? "" : ` ${current}/${total}`;
}

function frontierMoreNoun(mode: RequestFrontierMode) {
  if (mode === "attention") return "needing attention";
  if (mode === "recent") return "finished";
  if (mode === "waiting") return "waiting";
  if (mode === "next") return "ready";
  return "active";
}

function sliceIsRunning(slice: WorkRequestPackage, pkg?: WorkPackageCard) {
  if (sliceIsFinished(slice, pkg)) return false;
  const status = slice.work_package_status || slice.status;
  return operationalStatusIsRunning(sliceOperationalState(slice, pkg), status)
    || slice.worker_signal?.status === "active"
    || slice.review_signal?.status === "in_progress"
    || slice.pr_signal?.checks?.status === "pending";
}

function sliceIsFinished(slice: WorkRequestPackage, pkg?: WorkPackageCard) {
  return [slice.delivery?.outcome, slice.work_package_status, slice.status, slice.operational_state?.key, pkg?.status, pkg?.operational_state?.key]
    .some(isFinishedBoardStatus);
}

export function visibleRequestBranch(branch?: string | null, primaryBranch?: string | null) {
  const value = branch?.trim();
  if (!value || ["main", "master", primaryBranch?.trim().toLowerCase()].includes(value.toLowerCase())) return undefined;
  return value;
}

function requestHasWork(detail: WorkRequestDetail) {
  return Boolean(detail.product_tree?.nodes?.length || detail.work_packages?.length);
}

export function architectStartPrompt(workRequestId: string) {
  return `Take a look at WorkRequest ${workRequestId} using $symphony-plus-plus-mcp:symphony-architect. Check it out, bring me any questions if there are any, then let's go.`;
}

function EmptyWorkRequest({ workRequestId }: { workRequestId: string }) {
  const prompt = architectStartPrompt(workRequestId);
  return (
    <div className="flex flex-wrap items-center justify-between gap-3 px-3 py-3">
      <p className="text-sm text-muted-foreground">No work has been created yet. Copy a prompt to start this WorkRequest with an architect agent.</p>
      <Button type="button" variant="outline" size="sm" onClick={() => void copyTextToClipboard(prompt)}>
        <Copy className="size-4" />
        <span>Copy</span>
      </Button>
    </div>
  );
}

function RequestActions({
  detail,
  openQuestion,
  onSelectGuidance,
}: {
  detail: WorkRequestDetail;
  openQuestion?: NonNullable<WorkRequestDetail["clarification_questions"]>[number];
  onSelectGuidance: (item: GuidanceItem) => void;
}) {
  if (!openQuestion) return null;

  return (
    <div className="v3-request-actions">
      <Button type="button" variant="outline" size="sm" onClick={() => onSelectGuidance(clarificationGuidanceItem(detail, openQuestion))}>
        <AlertTriangle className="size-4" />
        <span>Open Question</span>
      </Button>
    </div>
  );
}

function ExecutionGraphBody({
  detail,
  now,
  packageById,
  onSelectCard,
  requestPath,
}: {
  detail: WorkRequestDetail;
  now?: string;
  packageById: Map<string, WorkPackageCard>;
  onSelectCard: CardDetailSelect;
  requestPath: ContextPathPart[];
}) {
  const slicesById = useMemo(() => new Map((detail.work_packages ?? []).map((slice) => [slice.id, slice])), [detail.work_packages]);
  const model = useMemo(() => workRequestExecutionGraphModel(detail, { includeHistorical: true }), [detail]);
  const selectWorkPackage = (workPackageId: string) => {
    const slice = slicesById.get(workPackageId);
    const pkg = packageById.get(slice?.work_package_id || workPackageId);
    if (slice) onSelectCard({ kind: "slice", detail, slice, pkg });
    else if (pkg) onSelectCard({ kind: "package", detail, pkg });
  };

  return (
    <div className="v3-execution-graph">
      <WorkRequestExecutionGraph model={model} now={now} onSelectWorkPackage={selectWorkPackage} contextPath={requestPath} />
    </div>
  );
}
