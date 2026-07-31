import type { ActiveBlockingEdge, ClarificationQuestion, DashboardPayload, GuidanceItem, WorkRequestPackage, SoloSession, WorkPackageCard, WorkRequestCard, WorkRequestDetail } from "@/types/dashboard";
import { operationalLabel, packageLane, sliceLane, sliceOperationalState, workRequestLane } from "@/lib/operational-state";
import { sortedCopy } from "@/lib/collections";
import type { BlockerItem, FinishedHighlight } from "./dashboard-state";
import type { CardDetailSelection } from "./runtime";
import { stripMarkdown } from "./dashboard-text";
import { operatorApiUrl } from "./runtime";
import type { RepoIdentitySource } from "./dashboard-persistence";
import { addBranch, repoDisplayName, repoIdentityKey, repoRemoteName } from "./dashboard-persistence";
import { activePackageBlockers, packageBlockerEdge } from "./blocker-selection";
import { packageHasActiveBlocker } from "./workstream-data";

export const FINISHED_HIGHLIGHT_LIMIT = 80;

export function dashboardContentFingerprint(payload: DashboardPayload | null) {
  if (!payload) return "null";

  const content = { ...payload } as Record<string, unknown>;
  delete content.generated_at;
  return JSON.stringify(content);
}

export type RepoSummary = {
  repoKey: string;
  repo: string;
  repoRemote?: string | null;
  baseBranches: string[];
  requested: number;
  active: number;
  implementing: number;
  finished: number;
  guidanceCount: number;
  blockerCount: number;
  packages: WorkPackageCard[];
  requests: WorkRequestCard[];
};

export function allPackages(dashboard: DashboardPayload | null): WorkPackageCard[] {
  const signals = new Map((dashboard?.work_packages ?? []).map((pkg) => [pkg.id, pkg]));
  const packages = new Map<string, WorkPackageCard>();

  (dashboard?.work_request_details ?? []).forEach((detail) => {
    (detail.work_packages ?? []).forEach((slice) => {
      if (!slice.work_package_id) return;

      packages.set(slice.work_package_id, {
        id: slice.work_package_id,
        title: slice.title,
        kind: slice.kind,
        status: slice.work_package_status || slice.status,
        repo: slice.repo || detail.work_request.repo,
        repo_key: detail.work_request.repo_key,
        repo_display: detail.work_request.repo_display,
        repo_remote: detail.work_request.repo_remote,
        repo_aliases: detail.work_request.repo_aliases,
        base_branch: slice.base_branch || detail.work_request.base_branch,
        operational_state: slice.operational_state,
        inserted_at: slice.inserted_at,
        updated_at: slice.updated_at,
        ...signals.get(slice.work_package_id),
      });
    });
  });

  return [...packages.values()];
}

export function allGuidanceItems(dashboard: DashboardPayload | null): GuidanceItem[] {
  const guidance = (dashboard?.guidance_requests?.guidance_requests || []).map<GuidanceItem>((item) => ({
    source: "guidance",
    id: item.id,
    repo: repoDisplayName(item),
    repoKey: repoIdentityKey(item),
    repoRemote: repoRemoteName(item),
    title: item.decision_prompt?.tl_dr || item.summary || stripMarkdown(item.question) || item.id,
    packageId: item.work_package_id,
    prompt: item.decision_prompt,
    detail: item.decision_prompt?.details || item.context || item.question || "",
    guidance: item,
  }));

  const details = dashboard?.work_request_details || [];
  const clarifications = details.flatMap<GuidanceItem>((detail) => {
    const items: GuidanceItem[] = [];
    (detail.clarification_questions || []).forEach((question) => {
      if (question.status === "open") items.push(clarificationGuidanceItem(detail, question));
    });
    return items;
  });

  return [...guidance, ...clarifications];
}

export function clarificationGuidanceItem(detail: WorkRequestDetail, question: ClarificationQuestion): GuidanceItem {
  return {
    source: "clarification",
    id: question.id,
    repo: repoDisplayName(detail.work_request),
    repoKey: repoIdentityKey(detail.work_request),
    repoRemote: repoRemoteName(detail.work_request),
    title: question.decision_prompt?.tl_dr || stripMarkdown(question.question) || question.id,
    workRequestId: detail.work_request.id,
    prompt: question.decision_prompt,
    detail: question.decision_prompt?.details || question.why_needed || question.question || "",
    question,
    request: detail.work_request,
  };
}

export function activeBlockerItems(
  packages: WorkPackageCard[],
  packageSelections: ReadonlyMap<string, CardDetailSelection> = new Map(),
  activeBlockingEdges: ActiveBlockingEdge[] = [],
): BlockerItem[] {
  const edgesByPackageId = activeBlockingEdges.reduce<Map<string, ActiveBlockingEdge[]>>((edgesById, edge) => {
    for (const packageId of activeBlockerPackageIds(edge)) {
      const edges = edgesById.get(packageId) ?? [];
      edges.push(edge);
      edgesById.set(packageId, edges);
    }

    return edgesById;
  }, new Map());

  return sortedCopy(
    packages.flatMap((pkg) => activeBlockerItemsForPackage(pkg, packageSelections, edgesByPackageId)),
    compareBlockerItems,
  );
}

function activeBlockerPackageIds(edge: ActiveBlockingEdge) {
  return [...new Set([
    edge.work_package_id,
    edge.to.kind === "work_package" ? edge.to.id : null,
  ].filter((id): id is string => Boolean(id)))];
}

function activeBlockerItemsForPackage(pkg: WorkPackageCard, packageSelections: ReadonlyMap<string, CardDetailSelection>, edgesByPackageId: ReadonlyMap<string, ActiveBlockingEdge[]>): BlockerItem[] {
  const context = packageBlockerContext(pkg, packageSelections);
  const blockerEdges = edgesByPackageId.get(pkg.id) ?? [];
  if (!packageHasActiveBlocker(pkg) && blockerEdges.length === 0) return [];

  const status = packageBlockerStatus(pkg);
  const reason = pkg.operational_state?.reason;
  const edgeItems = blockerEdgeItems(pkg, blockerEdges, status, reason, context);
  const packageItems = packageBlockerItems(pkg, activePackageBlockers(pkg), blockerEdges, status, reason, context);
  const items = [...edgeItems, ...packageItems];

  if (items.length > 0) return items;

  return [fallbackPackageBlockerItem(pkg, context.selection, status, reason)];
}

type PackageBlockerContext = {
  selection: CardDetailSelection;
  detail?: WorkRequestDetail;
  slice?: WorkRequestPackage;
};

function packageBlockerContext(pkg: WorkPackageCard, packageSelections: ReadonlyMap<string, CardDetailSelection>): PackageBlockerContext {
  const selection = packageSelections.get(pkg.id) ?? { kind: "package" as const, pkg };
  if (selection.kind !== "package") return { selection };
  return { selection, detail: selection.detail, slice: selection.slice };
}

function packageBlockerStatus(pkg: WorkPackageCard) {
  return pkg.operational_state?.key || pkg.status;
}

function fallbackPackageBlockerItem(
  pkg: WorkPackageCard,
  selection: CardDetailSelection,
  status: string | null | undefined,
  operationalReason: string | null | undefined,
): BlockerItem {
  return {
    id: pkg.id,
    title: pkg.title || pkg.id,
    repo: repoDisplayName(pkg),
    since: pkg.latest_progress_at || pkg.updated_at || pkg.inserted_at,
    status,
    blockerCount: fallbackPackageBlockerCount(pkg, pkg.operational_state?.key),
    detail: packageBlockerSummary(pkg, operationalReason),
    selection,
  };
}

function blockerEdgeItems(
  pkg: WorkPackageCard,
  blockerEdges: ActiveBlockingEdge[],
  status: string | null | undefined,
  operationalReason: string | null | undefined,
  context: { detail?: WorkRequestDetail; slice?: WorkRequestPackage },
): BlockerItem[] {
  return uniqueBlockerEdges(blockerEdges).map((edge) => blockerItem(pkg, edge, status, operationalReason, context));
}

function packageBlockerItems(
  pkg: WorkPackageCard,
  packageBlockers: ReturnType<typeof activePackageBlockers>,
  blockerEdges: ActiveBlockingEdge[],
  status: string | null | undefined,
  operationalReason: string | null | undefined,
  context: { detail?: WorkRequestDetail; slice?: WorkRequestPackage },
): BlockerItem[] {
  const edgeBlockerIds = new Set(blockerEdges.map((edge) => edge.blocker_id).filter(Boolean));

  return packageBlockers.flatMap((blocker, index) => {
    if (blocker.id && edgeBlockerIds.has(blocker.id)) return [];

    const edge = packageBlockerEdge(blocker, pkg, { ...context, fallbackKey: index });
    return [blockerItem(pkg, edge, status, operationalReason, context)];
  });
}

function blockerItem(
  pkg: WorkPackageCard,
  edge: ActiveBlockingEdge,
  status: string | null | undefined,
  operationalReason: string | null | undefined,
  context: Pick<Extract<CardDetailSelection, { kind: "blocker" }>, "detail" | "slice">,
): BlockerItem {
  return {
    id: edge.id,
    title: edge.summary || pkg.title || edge.blocker_id || edge.id,
    repo: repoDisplayName(pkg),
    since: edge.updated_at,
    status,
    blockerCount: 1,
    detail: edge.body || operationalReason || "This work package has an active blocker attached to its execution path.",
    selection: { kind: "blocker", blocker: edge, pkg, detail: context.detail, slice: context.slice },
  };
}

function fallbackPackageBlockerCount(pkg: WorkPackageCard, operationalKey: string | null | undefined) {
  return Math.max(pkg.active_blocker_count || 0, pkg.status === "blocked" || operationalKey === "blocked" ? 1 : 0);
}

function packageBlockerSummary(pkg: WorkPackageCard, operationalReason: string | null | undefined) {
  if (operationalReason) return operationalReason;
  if (pkg.status === "blocked") return "This work package is blocked and needs another condition or dependency cleared before it can move.";
  return "This work package has active blockers attached to its execution path.";
}

function uniqueBlockerEdges(edges: ActiveBlockingEdge[]) {
  const seen = new Set<string>();
  return edges.filter((edge) => {
    const key = edge.blocker_id || edge.id;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function compareBlockerItems(left: BlockerItem, right: BlockerItem) {
  const leftRank = left.selection.kind === "blocker" ? 0 : 1;
  const rightRank = right.selection.kind === "blocker" ? 0 : 1;
  if (leftRank !== rightRank) return leftRank - rightRank;

  const recency = blockerItemTimestamp(right) - blockerItemTimestamp(left);
  if (recency !== 0) return recency;

  return left.repo.localeCompare(right.repo) || left.title.localeCompare(right.title) || left.id.localeCompare(right.id);
}

function blockerItemTimestamp(item: BlockerItem) {
  const selection = item.selection;
  const value =
    selection.kind === "blocker"
      ? selection.blocker.updated_at || selection.pkg?.latest_progress_at || selection.pkg?.updated_at
      : selection.kind === "package"
        ? selection.pkg.latest_progress_at || selection.pkg.updated_at
        : null;

  return value ? Date.parse(value) || 0 : 0;
}

export function recentFinishedHighlights(
  packages: WorkPackageCard[],
  requests: WorkRequestCard[],
  details: WorkRequestDetail[],
  packageSelections: ReadonlyMap<string, CardDetailSelection> = new Map(),
  limit: number | null = FINISHED_HIGHLIGHT_LIMIT,
): FinishedHighlight[] {
  const detailByRequestId = new Map(details.map((detail) => [detail.work_request.id, detail]));
  const packageById = new Map(packages.map((pkg) => [pkg.id, pkg]));

  const packageHighlights = packages.reduce<FinishedHighlight[]>((items, pkg) => {
    if (packageLane(pkg) === "finished") {
      const operational = pkg.operational_state || null;
      items.push({
        id: pkg.id,
        title: pkg.title || pkg.id,
        repo: repoDisplayName(pkg),
        kind: "WorkPackage",
        state: operationalLabel(operational, pkg.status),
        at: latestTimestamp(pkg.latest_progress_at, pkg.updated_at, pkg.inserted_at),
        selection: packageSelections.get(pkg.id) ?? { kind: "package", pkg },
      });
    }

    return items;
  }, []);
  const visiblePackageHighlights = limit === null ? packageHighlights : sortedCopy(packageHighlights, compareHighlightRecency).slice(0, limit);

  const requestHighlights = requests.reduce<FinishedHighlight[]>((items, request) => {
    if (workRequestLane(request) === "finished") {
      const detail = detailByRequestId.get(request.id);
      if (!detail) return items;

      const operational = request.operational_state || null;
      items.push({
        id: request.id,
        title: request.title || request.id,
        repo: repoDisplayName(request),
        kind: "Request",
        state: operationalLabel(operational, request.status),
        at: request.updated_at || request.inserted_at,
        selection: { kind: "request", detail },
      });
    }

    return items;
  }, []);

  const sliceHighlights = details.flatMap<FinishedHighlight>((detail) => {
    const items: FinishedHighlight[] = [];
    (detail.work_packages || []).forEach((slice) => {
      const pkg = slice.work_package_id ? packageById.get(slice.work_package_id) : undefined;

      if (sliceLane(slice, pkg) === "finished") {
        const operational = sliceOperationalState(slice, pkg);
        items.push({
          id: slice.id,
          title: slice.title || slice.id,
          repo: repoDisplayName(detail.work_request),
          kind: "WorkPackage",
          state: operationalLabel(operational, slice.work_package_status || slice.status),
          at: detail.work_request.updated_at || detail.work_request.inserted_at,
          selection: pkg ? { kind: "package", pkg, detail, slice } : { kind: "slice", detail, slice },
        });
      }
    });
    return items;
  });

  return sortedCopy([...visiblePackageHighlights, ...requestHighlights, ...sliceHighlights], compareHighlightRecency);
}

function compareHighlightRecency(a: FinishedHighlight, b: FinishedHighlight) {
  const left = a.at ? Date.parse(a.at) : 0;
  const right = b.at ? Date.parse(b.at) : 0;
  return right - left;
}

function latestTimestamp(...values: (string | null | undefined)[]) {
  return sortedCopy(values.filter((value): value is string => Boolean(value)), (a, b) => Date.parse(b) - Date.parse(a))[0] ?? null;
}

export function repoSummaries(
  packages: WorkPackageCard[],
  requests: WorkRequestCard[],
  guidance: GuidanceItem[],
  sessions: SoloSession[],
  details: WorkRequestDetail[],
): RepoSummary[] {
  const repos = new Map<string, RepoSummary>();
  const packageById = new Map(packages.map((pkg) => [pkg.id, pkg]));
  const packageOwner = new Map<string, WorkRequestCard>();

  details.forEach((detail) => {
    (detail.work_packages || []).forEach((slice) => {
      if (slice.work_package_id) packageOwner.set(slice.work_package_id, detail.work_request);
    });
  });

  const ensure = (identity: RepoIdentitySource): RepoSummary => {
    const repoKey = repoIdentityKey(identity);
    const repo = repoDisplayName(identity);
    if (!repos.has(repoKey)) {
      repos.set(repoKey, {
        repoKey,
        repo,
        repoRemote: repoRemoteName(identity),
        baseBranches: [],
        requested: 0,
        active: 0,
        implementing: 0,
        finished: 0,
        guidanceCount: 0,
        blockerCount: 0,
        packages: [],
        requests: [],
      });
    }
    const summary = repos.get(repoKey)!;
    summary.repoRemote ||= repoRemoteName(identity);
    return summary;
  };

  requests.forEach((request) => {
    const summary = ensure(request);
    summary.requests.push(request);
    addBranch(summary, request.base_branch);
  });

  packages.forEach((pkg) => {
    const owner = packageOwner.get(pkg.id);
    if (!owner) return;

    const summary = ensure(owner);
    summary.packages.push(pkg);
  });

  sessions.forEach((session) => {
    const summary = ensure(session);
    addBranch(summary, session.base_branch);
  });

  guidance.forEach((item) => {
    ensure({ repo: item.repo, repo_key: item.repoKey, repo_display: item.repo, repo_remote: item.repoRemote }).guidanceCount += 1;
  });

  repos.forEach((summary) => {
    summary.requests.forEach((request) => {
      const lane = workRequestLane(request);
      if (lane === "requested") summary.requested += 1;
      if (lane === "slices") summary.active += 1;
    });

    summary.packages.forEach((pkg) => {
      const lane = packageLane(pkg);
      if (lane === "slices") summary.active += 1;
      if (lane === "implementing") summary.implementing += 1;
      if (lane === "finished") summary.finished += 1;
      if (packageHasActiveBlocker(pkg)) summary.blockerCount += 1;
    });
  });

  details.forEach((detail) => {
    const summary = ensure(detail.work_request);
    (detail.work_packages || []).forEach((slice) => {
      if (slice.work_package_id && packageById.has(slice.work_package_id)) return;
      const lane = sliceLane(slice, slice.work_package_id ? packageById.get(slice.work_package_id) : undefined);
      if (lane === "slices") summary.active += 1;
      if (lane === "implementing") summary.implementing += 1;
      if (lane === "finished") summary.finished += 1;
    });
  });

  return sortedCopy([...repos.values()], (a, b) => a.repo.localeCompare(b.repo));
}

export function guidanceAnswerUrl(item: GuidanceItem) {
  if (item.source === "guidance") {
    return operatorApiUrl(`/work-packages/${encodeURIComponent(item.packageId)}/guidance/${encodeURIComponent(item.id)}/answer`);
  }

  return operatorApiUrl(`/work-requests/${encodeURIComponent(item.workRequestId)}/questions/${encodeURIComponent(item.id)}/answer`);
}
