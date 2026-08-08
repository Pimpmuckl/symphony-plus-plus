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
export type ActionableAttentionCounts = { blockerCount: number; guidanceCount: number };

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
  const items = requestActionableAttentionItems(detail, packageById, activeBlockingEdges, guidanceItems);
  if (stateKind === "guidance") {
    return attentionTarget(items.filter((item) => item.tone === "guidance"));
  }
  if (stateKind === "blocked") {
    return attentionTarget(items.filter((item) => item.tone === "blocked"));
  }
  return null;
}

export function requestActionableAttentionCounts(
  detail: WorkRequestDetail,
  packageById: Map<string, WorkPackageCard>,
  activeBlockingEdges: ActiveBlockingEdge[],
  guidanceItems: GuidanceItem[],
): ActionableAttentionCounts {
  const items = requestActionableAttentionItems(detail, packageById, activeBlockingEdges, guidanceItems);
  return {
    blockerCount: items.filter((item) => item.tone === "blocked").length,
    guidanceCount: items.filter((item) => item.tone === "guidance").length,
  };
}

export function requestActionableAttentionItems(
  detail: WorkRequestDetail,
  packageById: Map<string, WorkPackageCard>,
  activeBlockingEdges: ActiveBlockingEdge[],
  guidanceItems: GuidanceItem[],
) {
  if (workRequestIsTerminal(detail)) return [];
  return requestAllAttentionItems(detail, packageById, activeBlockingEdges, guidanceItems);
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
    ...guidanceAttentionItemsForSlice(slice, pkg, guidanceItems),
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
    .flatMap((detail) => requestActionableAttentionItems(detail, packageById, activeBlockingEdges, guidanceItems));
  return uniqueAttentionItems([...projected, ...workstream]).filter((item) => item.kind !== "status");
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
  if (selection.kind === "blocker") {
    const targetId = blockerTargetPackageId(selection.blocker);
    return Boolean(targetId && terminalPackageIds.has(targetId));
  }
  if (selection.detail && terminalRequestIds.has(selection.detail.work_request.id)) return true;
  if (selection.kind === "slice") return [...sliceIds(selection.slice, selection.pkg)].some((id) => terminalPackageIds.has(id));
  if (selection.kind === "package") return terminalPackageIds.has(selection.pkg.id);
  return false;
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
      ...guidanceAttentionItemsForSlice(slice, pkg, guidanceItems),
    ];
  });
  const clarificationItems = requestClarificationItems(detail, guidanceItems);
  const terminalPackageIds = terminalWorkPackageIds([detail], packageById);
  const unmatchedEdges = activeBlockerEdgesForRequest(activeBlockingEdges, detail)
    .filter(blockerIsActionable)
    .filter((blocker) => !terminalPackageIds.has(blockerTargetPackageId(blocker) ?? ""))
    .map((blocker) => attentionItemForBlockerSelection({ kind: "blocker", blocker, detail }))
    .filter((item) => !items.some((candidate) => candidate.key === item.key));
  return uniqueAttentionItems([...items, ...clarificationItems, ...unmatchedEdges]);
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
  slice: WorkRequestPackage,
  pkg: WorkPackageCard | undefined,
  guidanceItems: GuidanceItem[],
) {
  if (workPackageIsTerminal(slice, pkg)) return [];
  const ids = sliceIds(slice, pkg);
  const guidance = guidanceItems
    .filter((item) => item.source === "guidance" && ids.has(item.packageId))
    .map(attentionItemForGuidance);
  return guidance;
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
    .filter(blockerIsActionable)
    .filter((candidate) => ids.has(blockerTargetPackageId(candidate) ?? ""))
    .map((blocker) => attentionItemForBlockerSelection({ kind: "blocker", blocker, detail, slice, pkg }));
  const edgeBlockerIds = new Set(edges.map((item) => item.selection.blocker.blocker_id).filter(Boolean));
  const embedded = pkg
    ? activePackageBlockers(pkg)
        .filter((blocker) => Boolean(blocker.id && !edgeBlockerIds.has(blocker.id)))
        .map((blocker) => attentionItemForBlockerSelection({
          kind: "blocker",
          blocker: packageBlockerEdge(blocker, pkg, { detail, slice }),
          detail,
          slice,
          pkg,
        }))
    : [];
  return uniqueAttentionItems([...edges, ...embedded]);
}

const blockerTargetPackageId = (blocker: ActiveBlockingEdge) => blocker.to.kind === "work_package" && blocker.to.id ? blocker.to.id : blocker.work_package_id;

function blockerIsActionable(blocker: ActiveBlockingEdge) {
  return Boolean(blocker.blocker_id && blockerTargetPackageId(blocker));
}

function attentionItemForGuidance(item: GuidanceItem): AttentionItem {
  return { kind: "guidance", key: `guidance:${item.source}:${item.id}`, label: item.source === "clarification" ? "Human Info Needed" : "Guidance Needed", tone: "guidance", item };
}

function attentionItemForBlocker(item: BlockerItem): AttentionItem {
  if (item.selection.kind === "blocker" && blockerIsActionable(item.selection.blocker)) {
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
