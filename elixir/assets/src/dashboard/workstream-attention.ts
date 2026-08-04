import type { ActiveBlockingEdge, GuidanceItem, WorkPackageCard, WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";
import { terminalWorkPackageIds, workPackageIsTerminal, workRequestIsTerminal, type BoardRowStateKind } from "./workstream-row-state";
import type { CardDetailSelection } from "./runtime";
import type { BlockerItem } from "./dashboard-state";
import { clarificationGuidanceItem } from "./dashboard-data";
import { repoDisplayName } from "./dashboard-persistence";
import { activePackageBlockers, packageBlockerEdge } from "./blocker-selection";
import { activeBlockerEdgesForRequest } from "./workstream-progress";

type AttentionContextSelection = Extract<CardDetailSelection, { kind: "request" | "slice" | "package" }>;
type BlockerSelection = Extract<CardDetailSelection, { kind: "blocker" }>;

export type AttentionItem =
  | { kind: "guidance"; key: string; label: string; tone: "guidance"; item: GuidanceItem }
  | { kind: "blocker"; key: string; label: string; tone: "blocked"; selection: BlockerSelection }
  | {
      kind: "status";
      key: string;
      label: string;
      tone: "blocked" | "guidance";
      title: string;
      detail: string;
      since?: string | null;
      preRun?: boolean;
      selection: AttentionContextSelection;
    };

export type AttentionTarget = { items: AttentionItem[] };
export type AttentionSelect = (target: AttentionTarget) => void;
export type RequestAttentionTarget = AttentionTarget;

export type DirectAttention = {
  label: string;
  tone: "blocked" | "guidance";
  target: AttentionTarget;
};

export type AttentionLocation = {
  repo: string;
  request?: { id: string; label: string };
  groups: Array<{ id: string; label: string }>;
  workPackage?: { id: string; label: string };
};

export type AttentionJumpDestination = {
  requestId: string;
  groupIds: string[];
  workPackageId?: string;
};

export type AttentionJumpTarget = AttentionJumpDestination & { token: number };
export type AttentionLocationLevel = "request" | "group" | "work_package";

export function requestAttentionTarget(
  detail: WorkRequestDetail,
  packageById: Map<string, WorkPackageCard>,
  activeBlockingEdges: ActiveBlockingEdge[],
  stateKind: BoardRowStateKind,
  guidanceItems: GuidanceItem[] = [],
): RequestAttentionTarget | null {
  if (stateKind === "guidance") {
    return attentionTarget(requestGuidanceAttentionItems(detail, packageById, guidanceItems));
  }
  if (stateKind === "blocked") {
    return attentionTarget(requestBlockerAttentionItems(detail, packageById, activeBlockingEdges));
  }
  return null;
}

export function workPackageDirectAttention(
  detail: WorkRequestDetail,
  slice: WorkRequestPackage,
  pkg: WorkPackageCard | undefined,
  activeBlockingEdges: ActiveBlockingEdge[],
  guidanceItems: GuidanceItem[],
): DirectAttention | null {
  return directAttention([
    ...blockerAttentionItemsForSlice(detail, slice, pkg, activeBlockingEdges),
    ...guidanceAttentionItemsForSlice(detail, slice, pkg, guidanceItems),
  ]);
}

export function groupDirectAttention(
  detail: WorkRequestDetail,
  groupId: string,
  packageById: Map<string, WorkPackageCard>,
  activeBlockingEdges: ActiveBlockingEdge[],
  guidanceItems: GuidanceItem[],
): DirectAttention | null {
  const groupIds = descendantGroupIds(detail, groupId);
  const targets = (detail.work_packages ?? [])
    .filter((slice) => groupIds.has(sliceGroupId(detail, slice) ?? ""))
    .map((slice) => workPackageDirectAttention(detail, slice, packageForSlice(slice, packageById), activeBlockingEdges, guidanceItems))
    .filter((target): target is DirectAttention => Boolean(target));

  return directAttention(targets.flatMap((target) => target.target.items));
}

export function dashboardAttentionItems(
  details: WorkRequestDetail[],
  packageById: Map<string, WorkPackageCard>,
  activeBlockingEdges: ActiveBlockingEdge[],
  guidanceItems: GuidanceItem[],
  blockerItems: BlockerItem[],
) {
  const terminalDetails = details.filter((detail) => workRequestIsTerminal(detail));
  const terminalRequestIds = new Set(terminalDetails.map((detail) => detail.work_request.id));
  const terminalPackageIds = terminalWorkPackageIds(details, packageById);
  const projected = [
    ...blockerItems.map(attentionItemForBlocker),
    ...guidanceItems.map(attentionItemForGuidance),
  ].filter((item) => !attentionBelongsToTerminalRequest(item, terminalRequestIds, terminalPackageIds));
  const workstream = details
    .filter((detail) => !workRequestIsTerminal(detail))
    .flatMap((detail) => requestAllAttentionItems(detail, packageById, activeBlockingEdges, guidanceItems));
  return uniqueAttentionItems([...projected, ...workstream]).filter((item) => item.kind !== "status" || !item.preRun);
}

function attentionBelongsToTerminalRequest(
  item: AttentionItem,
  terminalRequestIds: Set<string>,
  terminalPackageIds: Set<string>,
) {
  if (item.kind === "guidance") {
    return item.item.source === "clarification"
      ? terminalRequestIds.has(item.item.workRequestId)
      : terminalPackageIds.has(item.item.packageId);
  }

  const selection = item.selection;
  if (selection.kind === "request") return terminalRequestIds.has(selection.detail.work_request.id);
  if (selection.detail && terminalRequestIds.has(selection.detail.work_request.id)) return true;
  if (selection.kind === "slice") return [...sliceIds(selection.slice, selection.pkg)].some((id) => terminalPackageIds.has(id));
  if (selection.kind === "package") return terminalPackageIds.has(selection.pkg.id);
  return [selection.pkg?.id, selection.slice?.id, selection.slice?.work_package_id, selection.blocker.work_package_id, selection.blocker.to.id]
    .some((id) => Boolean(id && terminalPackageIds.has(id)));
}

export function attentionTargetForGuidance(item: GuidanceItem): AttentionTarget {
  return { items: [attentionItemForGuidance(item)] };
}

export function attentionTargetForBlocker(item: BlockerItem): AttentionTarget {
  return { items: [attentionItemForBlocker(item)] };
}

export function attentionLocationForItem(item: AttentionItem, details: WorkRequestDetail[]): AttentionLocation {
  return item.kind === "guidance"
    ? attentionLocationForGuidance(item.item, details)
    : attentionLocationForSelection(item.selection, details);
}

export function attentionItemTitle(item: AttentionItem) {
  if (item.kind === "guidance") return item.item.prompt?.tl_dr || item.item.title;
  if (item.kind === "blocker") return item.selection.blocker.summary || item.selection.pkg?.title || item.label;
  return item.title;
}

export function attentionItemDetail(item: AttentionItem) {
  if (item.kind === "guidance") return item.item.prompt?.details || item.item.detail;
  if (item.kind === "blocker") return item.selection.blocker.body || item.selection.blocker.summary || "";
  return item.detail;
}

export function attentionItemSince(item: AttentionItem) {
  if (item.kind === "blocker") return item.selection.blocker.updated_at;
  return item.kind === "status" ? item.since : null;
}

export function attentionLocationForGuidance(item: GuidanceItem, details: WorkRequestDetail[]): AttentionLocation {
  if (item.source === "clarification") {
    return attentionLocation(details.find((detail) => detail.work_request.id === item.workRequestId), undefined, undefined, item.repo);
  }

  const context = linkedAttentionContext(details, new Set([item.packageId]));
  return attentionLocation(context?.detail, context?.slice, undefined, item.repo, item.guidance.work_package_title);
}

export function attentionLocationForSelection(selection: CardDetailSelection, details: WorkRequestDetail[]): AttentionLocation {
  if (selection.kind === "request") return attentionLocation(selection.detail, undefined, undefined);
  if (selection.kind === "slice") return attentionLocation(selection.detail, selection.slice, selection.pkg);
  if (selection.kind === "package") return packageAttentionLocation(selection, details);
  if (selection.kind === "blocker") return blockerAttentionLocation(selection, details);
  return { repo: "Solo session", groups: [] };
}

export function attentionJumpDestination(location: AttentionLocation, level: AttentionLocationLevel): AttentionJumpDestination | null {
  if (!location.request) return null;
  const groupIds = level === "request" ? [] : location.groups.map((group) => group.id);
  const workPackageId = level === "work_package" ? location.workPackage?.id : undefined;
  return { requestId: location.request.id, groupIds, workPackageId };
}

function requestAllAttentionItems(
  detail: WorkRequestDetail,
  packageById: Map<string, WorkPackageCard>,
  activeBlockingEdges: ActiveBlockingEdge[],
  guidanceItems: GuidanceItem[],
) {
  const items = (detail.work_packages ?? []).flatMap((slice) => {
    const pkg = packageForSlice(slice, packageById);
    return [
      ...blockerAttentionItemsForSlice(detail, slice, pkg, activeBlockingEdges),
      ...guidanceAttentionItemsForSlice(detail, slice, pkg, guidanceItems),
    ];
  });
  const clarificationItems = requestClarificationItems(detail, guidanceItems);
  const requestStatuses = [
    ...requestStatusFallback(detail, items, "blocked"),
    ...requestStatusFallback(detail, [...items, ...clarificationItems], "guidance"),
  ];
  return uniqueAttentionItems([...items, ...clarificationItems, ...requestStatuses]);
}

function requestGuidanceAttentionItems(
  detail: WorkRequestDetail,
  packageById: Map<string, WorkPackageCard>,
  guidanceItems: GuidanceItem[],
) {
  const clarificationItems = requestClarificationItems(detail, guidanceItems);
  const packageItems = (detail.work_packages ?? []).flatMap((slice) =>
    guidanceAttentionItemsForSlice(detail, slice, packageForSlice(slice, packageById), guidanceItems),
  );
  const items = uniqueAttentionItems([...clarificationItems, ...packageItems]);
  return items.length > 0 ? items : [requestStatusAttentionItem(detail, "guidance")];
}

function requestBlockerAttentionItems(
  detail: WorkRequestDetail,
  packageById: Map<string, WorkPackageCard>,
  activeBlockingEdges: ActiveBlockingEdge[],
) {
  const terminalPackageIds = terminalWorkPackageIds([detail], packageById);
  const sliceItems = (detail.work_packages ?? []).flatMap((slice) =>
    blockerAttentionItemsForSlice(detail, slice, packageForSlice(slice, packageById), activeBlockingEdges),
  );
  const unmatchedEdges = activeBlockerEdgesForRequest(activeBlockingEdges, detail)
    .filter((blocker) => ![blocker.work_package_id, blocker.to.id].some((id) => id && terminalPackageIds.has(id)))
    .map((blocker) => attentionItemForBlockerSelection({ kind: "blocker", blocker, detail }))
    .filter((item) => !sliceItems.some((candidate) => candidate.key === item.key));
  const items = uniqueAttentionItems([...sliceItems, ...unmatchedEdges]);
  return items.length > 0 ? items : [requestStatusAttentionItem(detail, "blocked")];
}

function requestClarificationItems(detail: WorkRequestDetail, guidanceItems: GuidanceItem[]) {
  const questions = (detail.clarification_questions ?? [])
    .filter((question) => question.status === "open")
    .map((question) => attentionItemForGuidance(clarificationGuidanceItem(detail, question)));
  const projected = guidanceItems
    .filter((item) => item.source === "clarification" && item.workRequestId === detail.work_request.id)
    .map(attentionItemForGuidance);
  return uniqueAttentionItems([...questions, ...projected]);
}

function guidanceAttentionItemsForSlice(
  detail: WorkRequestDetail,
  slice: WorkRequestPackage,
  pkg: WorkPackageCard | undefined,
  guidanceItems: GuidanceItem[],
) {
  if (workPackageIsTerminal(slice, pkg)) return [];
  const ids = sliceIds(slice, pkg);
  const guidance = guidanceItems
    .filter((item) => item.source === "guidance" && ids.has(item.packageId))
    .map(attentionItemForGuidance);
  if (guidance.length > 0) return guidance;
  return sliceNeedsGuidance(slice, pkg) ? [statusAttentionItem(detail, slice, pkg, "guidance")] : [];
}

function blockerAttentionItemsForSlice(
  detail: WorkRequestDetail,
  slice: WorkRequestPackage,
  pkg: WorkPackageCard | undefined,
  activeBlockingEdges: ActiveBlockingEdge[],
) {
  if (workPackageIsTerminal(slice, pkg)) return [];
  const ids = sliceIds(slice, pkg);
  const edges = activeBlockerEdgesForRequest(activeBlockingEdges, detail)
    .filter((candidate) => [candidate.work_package_id, candidate.to.id].some((id) => id && ids.has(id)))
    .map((blocker) => attentionItemForBlockerSelection({ kind: "blocker", blocker, detail, slice, pkg }));
  const edgeBlockerIds = new Set(edges.map((item) => item.selection.blocker.blocker_id).filter(Boolean));
  const embedded = pkg
    ? activePackageBlockers(pkg)
        .filter((blocker) => !blocker.id || !edgeBlockerIds.has(blocker.id))
        .map((blocker) => attentionItemForBlockerSelection({
          kind: "blocker",
          blocker: packageBlockerEdge(blocker, pkg, { detail, slice }),
          detail,
          slice,
          pkg,
        }))
    : [];
  const items = uniqueAttentionItems([...edges, ...embedded]);
  if (items.length > 0) return items;
  return sliceNeedsBlockerAttention(slice, pkg) ? [statusAttentionItem(detail, slice, pkg, "blocked")] : [];
}

function requestStatusFallback(detail: WorkRequestDetail, items: AttentionItem[], tone: AttentionItem["tone"]) {
  if (items.some((item) => item.tone === tone)) return [];
  const operational = detail.work_request.operational_state;
  const status = firstText(operational?.key, detail.work_request.status);
  const needed = tone === "guidance" ? statusIsGuidance(status) : status === "blocked";
  return needed ? [requestStatusAttentionItem(detail, tone)] : [];
}

function requestStatusAttentionItem(detail: WorkRequestDetail, tone: AttentionItem["tone"]): AttentionItem {
  const operational = detail.work_request.operational_state;
  const projected = projectedAttentionItem(operational, tone);
  const label = operational?.label || (tone === "guidance" ? "Human Info Needed" : "Blocked");
  return {
    kind: "status",
    key: `status:${tone}:request:${detail.work_request.id}`,
    label,
    tone,
    title: detail.work_request.title || detail.work_request.id,
    detail: operational?.reason || missingAttentionDetail(tone),
    preRun: statusAttentionIsPreRun(tone, projected, operational?.key, detail.work_request.status),
    since: operational?.last_activity_at || detail.work_request.updated_at,
    selection: { kind: "request", detail },
  };
}

function statusAttentionItem(
  detail: WorkRequestDetail,
  slice: WorkRequestPackage,
  pkg: WorkPackageCard | undefined,
  tone: AttentionItem["tone"],
): AttentionItem {
  const operational = slice.operational_state ?? pkg?.operational_state;
  const projected = projectedAttentionItem(operational, tone);
  const label = firstText(projected?.label, operational?.label, statusFallbackLabel(tone, slice));
  return {
    kind: "status",
    key: `status:${tone}:package:${firstText(pkg?.id, slice.work_package_id, slice.id)}`,
    label,
    tone,
    title: firstText(slice.title, pkg?.title, label),
    detail: firstText(projected?.reason, operational?.reason, missingAttentionDetail(tone)),
    preRun: statusPreRunForSlice(tone, projected, operational, slice, pkg),
    since: firstText(operational?.last_activity_at, slice.updated_at, pkg?.updated_at),
    selection: { kind: "slice", detail, slice, pkg },
  };
}

function projectedAttentionItem(operational: WorkPackageCard["operational_state"] | undefined, tone: AttentionItem["tone"]) {
  const predicate = tone === "guidance" ? attentionItemIsGuidance : attentionItemIsBlocker;
  return operational?.attention_items?.find(predicate);
}

function statusFallbackLabel(tone: AttentionItem["tone"], slice: WorkRequestPackage) {
  return tone === "guidance" ? "Human Info Needed" : failedAttentionLabel(slice);
}

function statusAttentionIsPreRun(
  tone: AttentionItem["tone"],
  projected: ReturnType<typeof projectedAttentionItem>,
  ...statuses: Array<string | null | undefined>
) {
  return tone === "guidance"
    && !projected
    && ["clarifying", "ready_for_clarification"].includes(firstText(...statuses));
}

function statusPreRunForSlice(
  tone: AttentionItem["tone"],
  projected: ReturnType<typeof projectedAttentionItem>,
  operational: WorkPackageCard["operational_state"] | undefined,
  slice: WorkRequestPackage,
  pkg: WorkPackageCard | undefined,
) {
  return statusAttentionIsPreRun(tone, projected, operational?.key, slice.work_package_status, slice.status, pkg?.status);
}

function attentionItemForGuidance(item: GuidanceItem): AttentionItem {
  return { kind: "guidance", key: `guidance:${item.source}:${item.id}`, label: item.source === "clarification" ? "Human Info Needed" : "Guidance Needed", tone: "guidance", item };
}

function attentionItemForBlocker(item: BlockerItem): AttentionItem {
  if (item.selection.kind === "blocker") {
    return { ...attentionItemForBlockerSelection(item.selection), key: `blocker:${item.id}` };
  }
  return {
    kind: "status",
    key: `status:blocked:package:${item.id}`,
    label: "Blocked",
    tone: "blocked",
    title: item.title,
    detail: item.detail,
    since: item.since,
    selection: item.selection as AttentionContextSelection,
  };
}

function attentionItemForBlockerSelection(selection: BlockerSelection): Extract<AttentionItem, { kind: "blocker" }> {
  const blocker = selection.blocker;
  return {
    kind: "blocker",
    key: `blocker:${blocker.id}`,
    label: "Blocked",
    tone: "blocked",
    selection,
  };
}

function attentionTarget(items: AttentionItem[]) {
  const unique = uniqueAttentionItems(items);
  return unique.length > 0 ? { items: unique } : null;
}

function directAttention(items: AttentionItem[]): DirectAttention | null {
  const target = attentionTarget(sortAttentionItems(items));
  const first = target?.items[0];
  return first && target ? { label: first.label, tone: first.tone, target } : null;
}

function uniqueAttentionItems(items: AttentionItem[]) {
  return [...new Map(items.map((item) => [item.key, item])).values()];
}

function sortAttentionItems(items: AttentionItem[]) {
  return [...items].sort((left, right) => Number(left.tone !== "blocked") - Number(right.tone !== "blocked"));
}

function missingAttentionDetail(tone: AttentionItem["tone"]) {
  return tone === "guidance"
    ? "This item needs human input, but no question is attached yet."
    : "This item is blocked, but no blocker detail is attached yet.";
}

function firstText(...values: Array<string | null | undefined>) {
  return values.find((value): value is string => Boolean(value)) ?? "";
}

function failedAttentionLabel(slice: WorkRequestPackage) {
  if (slice.review_signal?.status === "failed") return "Review Failed";
  if (slice.pr_signal?.checks?.status === "failing") return "CI Failed";
  return "Blocked";
}

function sliceNeedsBlockerAttention(slice: WorkRequestPackage, pkg?: WorkPackageCard) {
  const operational = slice.operational_state ?? pkg?.operational_state;
  const statuses = [operational?.key, slice.work_package_status, slice.status, pkg?.status];
  return [
    reviewFailed(slice),
    ciFailed(slice),
    packageHasActiveBlocker(pkg),
    statuses.includes("blocked"),
    operationalAttentionIncludesBlocker(operational),
  ].some(Boolean);
}

function sliceNeedsGuidance(slice: WorkRequestPackage, pkg?: WorkPackageCard) {
  const operationalStates = [slice.operational_state, pkg?.operational_state];
  const statuses = [slice.work_package_status, slice.status, pkg?.status, ...operationalStates.map((state) => state?.key)];
  return statuses.some(statusIsGuidance) || operationalStates.some((state) => (state?.attention_items ?? []).some(attentionItemIsGuidance));
}

function attentionItemIsBlocker(item: NonNullable<NonNullable<WorkPackageCard["operational_state"]>["attention_items"]>[number]) {
  const text = `${item.key || ""} ${item.label || ""}`.toLowerCase();
  return text.includes("blocker") || (item.blocker_ids?.length ?? 0) > 0;
}

function attentionItemIsGuidance(item: NonNullable<NonNullable<WorkPackageCard["operational_state"]>["attention_items"]>[number]) {
  const text = `${item.key || ""} ${item.label || ""}`.toLowerCase();
  return ["guidance", "question", "human_info", "decision"].some((value) => text.includes(value));
}

function statusIsGuidance(status?: string | null) {
  return ["human_info_needed", "ready_for_clarification", "clarifying"].includes(status || "");
}

function sliceIds(slice: WorkRequestPackage, pkg?: WorkPackageCard) {
  return new Set([slice.id, slice.work_package_id, pkg?.id].filter((id): id is string => Boolean(id)));
}

function packageForSlice(slice: WorkRequestPackage, packageById: Map<string, WorkPackageCard>) {
  return packageById.get(slice.work_package_id || slice.id);
}

function descendantGroupIds(detail: WorkRequestDetail, groupId: string) {
  const ids = new Set([groupId]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const group of detail.product_tree?.nodes ?? []) {
      if (group.parent_id && ids.has(group.parent_id) && !ids.has(group.id)) {
        ids.add(group.id);
        changed = true;
      }
    }
  }
  return ids;
}

function sliceGroupId(detail: WorkRequestDetail, slice: WorkRequestPackage) {
  if (slice.product_tree_node_id) return slice.product_tree_node_id;
  return detail.product_tree?.nodes?.find((node) => node.work_package_ids?.some((id) => sliceIds(slice).has(id)))?.id;
}

function linkedAttentionContext(details: WorkRequestDetail[], ids: Set<string>) {
  for (const detail of details) {
    const slice = detail.work_packages?.find((candidate) => [...sliceIds(candidate)].some((id) => ids.has(id)));
    if (slice) return { detail, slice };
  }
  return undefined;
}

function attentionLocation(
  detail?: WorkRequestDetail,
  slice?: WorkRequestPackage,
  pkg?: WorkPackageCard,
  fallbackRepo = "Repository unavailable",
  fallbackPackageTitle?: string | null,
): AttentionLocation {
  const request = detail?.work_request;
  return {
    repo: attentionRepo(request, pkg, fallbackRepo),
    request: attentionRequest(request),
    groups: attentionGroups(detail, slice),
    workPackage: attentionWorkPackage(slice, pkg, fallbackPackageTitle),
  };
}

function packageAttentionLocation(selection: Extract<CardDetailSelection, { kind: "package" }>, details: WorkRequestDetail[]) {
  const context = selection.detail && selection.slice
    ? { detail: selection.detail, slice: selection.slice }
    : linkedAttentionContext(details, new Set([selection.pkg.id]));
  return attentionLocation(context?.detail, context?.slice, selection.pkg, repoDisplayName(selection.pkg));
}

function blockerAttentionLocation(selection: Extract<CardDetailSelection, { kind: "blocker" }>, details: WorkRequestDetail[]) {
  const ids = new Set([
    selection.pkg?.id,
    selection.slice?.id,
    selection.slice?.work_package_id,
    selection.blocker.work_package_id,
    selection.blocker.to.id,
  ].filter((id): id is string => Boolean(id)));
  const context = selection.detail && selection.slice
    ? { detail: selection.detail, slice: selection.slice }
    : linkedAttentionContext(details, ids);
  const fallbackRepo = selection.pkg ? repoDisplayName(selection.pkg) : undefined;
  return attentionLocation(selection.detail ?? context?.detail, selection.slice ?? context?.slice, selection.pkg, fallbackRepo);
}

function reviewFailed(slice: WorkRequestPackage) {
  return slice.review_signal?.status === "failed";
}

function ciFailed(slice: WorkRequestPackage) {
  return slice.pr_signal?.checks?.status === "failing";
}

function packageHasActiveBlocker(pkg?: WorkPackageCard) {
  return (pkg?.active_blocker_count ?? 0) > 0 || activePackageBlockers(pkg).length > 0;
}

function operationalAttentionIncludesBlocker(operational?: WorkPackageCard["operational_state"]) {
  return (operational?.attention_items ?? []).some(attentionItemIsBlocker);
}

function attentionRepo(request: WorkRequestDetail["work_request"] | undefined, pkg: WorkPackageCard | undefined, fallback: string) {
  if (request) return repoDisplayName(request);
  if (pkg) return repoDisplayName(pkg);
  return fallback;
}

function attentionRequest(request?: WorkRequestDetail["work_request"]) {
  return request ? { id: request.id, label: request.title || request.id } : undefined;
}

function attentionGroups(detail?: WorkRequestDetail, slice?: WorkRequestPackage) {
  return detail && slice ? groupAncestry(detail, slice) : [];
}

function attentionWorkPackage(slice?: WorkRequestPackage, pkg?: WorkPackageCard, fallbackTitle?: string | null) {
  return slice ? { id: slice.id, label: slice.title || pkg?.title || fallbackTitle || slice.id } : undefined;
}

function groupAncestry(detail: WorkRequestDetail, slice: WorkRequestPackage) {
  const nodes = detail.product_tree?.nodes ?? [];
  const byId = new Map(nodes.map((node) => [node.id, node]));
  const path: Array<{ id: string; label: string }> = [];
  const seen = new Set<string>();
  let current = sliceGroupId(detail, slice);
  while (current && !seen.has(current)) {
    seen.add(current);
    const group = byId.get(current);
    if (!group) break;
    path.unshift({ id: group.id, label: group.title?.trim() || group.id });
    current = group.parent_id || undefined;
  }
  return path;
}
