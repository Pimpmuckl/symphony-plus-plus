import type { ActiveBlockingEdge, CopyArchitectHandoff, GuidanceItem, WorkRequestPackage, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { ProductTreeNode } from "@/types/product-tree";
import { AlertTriangle, ChevronRight, CircleDashed, GitBranch, Layers3, MessageSquareText, Split } from "lucide-react";
import type { CSSProperties } from "react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { CardDetailSelect, DashboardUpdateAnimations } from "./runtime";
import { clarificationGuidanceItem } from "./dashboard-data";
import { firstParagraph, stripMarkdown } from "./dashboard-text";
import { finishedRequestChildrenStorageKey, sortWorkRequestPackages, sortWorkRequestDetails } from "./workstream-data";
import { activeBlockerEntityCounts, productTreeCounts, requestProgress, rootProductSliceIds } from "./workstream-progress";
import { productNodeState, requestBoardState, rowProgressAttentionState, rowProgressIconState } from "./workstream-row-state";
import { EntityCountChips, EntityKindSlot, ProductNodeHeader, ProgressPill, RequestHeaderActions, RowBadgeSlot } from "./workstream-row-ui";
import { openBlockersForRequest, openBlockersForSlices, openGuidanceForSlices, productNodeSubtreeSlices, requestGuidanceItem } from "./workstream-board-actions";
import { requestUpdateKey } from "./update-animations";
import { dashboardPrefersReducedMotion, updateMotionAttributes } from "@/components/dashboard/motion-utils";
import { useAutoCollapseWhenDone } from "./workstream-auto-collapse";
import { WorkstreamContextBar } from "./workstream-context-bar";
import { contextPathValue } from "./workstream-context-path";
import type { ContextPathPart } from "./workstream-context-path";
import { DirectSliceGroup, ProductSliceRow } from "./workstream-slice-row";
import { buildTreeIndex } from "./workstream-tree-index";
import type { TreeIndex } from "./workstream-tree-index";

const REQUEST_EXIT_MOTION_MS = 320;

type ProductTreeRenderContext = {
  detail: WorkRequestDetail;
  treeIndex: TreeIndex;
  slicesById: Map<string, WorkRequestPackage>;
  packageById: Map<string, WorkPackageCard>;
  activeBlockerCountBySliceId: Map<string, number>;
  activeBlockerKeysBySliceId: Map<string, Set<string>>;
  activeBlockingEdges: ActiveBlockingEdge[];
  guidanceItems: GuidanceItem[];
  onSelectCard: CardDetailSelect;
  onSelectGuidance: (item: GuidanceItem) => void;
  updateAnimations: DashboardUpdateAnimations;
};

export function WorkstreamBoard({
  repoLabel,
  repoDetails,
  packages,
  activeBlockingEdges,
  guidanceItems,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  canMutateOperatorActions,
  expandedFinishedRequests,
  finishedRequestScopeKey,
  onSetFinishedRequestChildrenOpen,
  showContextBar,
  updateAnimations,
}: {
  repoLabel: string;
  repoDetails: WorkRequestDetail[];
  packages: WorkPackageCard[];
  activeBlockingEdges: ActiveBlockingEdge[];
  guidanceItems: GuidanceItem[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  canMutateOperatorActions: boolean;
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
              exiting={exiting}
              packageById={packageById}
              activeBlockerCount={blockerCounts.requests.get(detail.work_request.id) ?? 0}
              activeBlockingEdges={activeBlockingEdges}
              activeBlockerCountBySliceId={blockerCounts.slices}
              activeBlockerKeysBySliceId={blockerCounts.sliceBlockerKeys}
              guidanceItems={guidanceItems}
              expanded={expanded}
              index={index}
              onSetOpen={(open) => onSetFinishedRequestChildrenOpen(detail.work_request.id, open)}
              onSelectGuidance={onSelectGuidance}
              onSelectCard={onSelectCard}
              onCopyArchitectHandoff={onCopyArchitectHandoff}
              canMutateOperatorActions={canMutateOperatorActions}
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

function ProductRequestRow({
  detail,
  exiting = false,
  packageById,
  activeBlockerCount,
  activeBlockingEdges,
  activeBlockerCountBySliceId,
  activeBlockerKeysBySliceId,
  guidanceItems,
  expanded,
  index,
  onSetOpen,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  canMutateOperatorActions,
  updateAnimations,
}: {
  detail: WorkRequestDetail;
  exiting?: boolean;
  packageById: Map<string, WorkPackageCard>;
  activeBlockerCount: number;
  activeBlockingEdges: ActiveBlockingEdge[];
  activeBlockerCountBySliceId: Map<string, number>;
  activeBlockerKeysBySliceId: Map<string, Set<string>>;
  guidanceItems: GuidanceItem[];
  expanded: boolean;
  index: number;
  onSetOpen: (open: boolean) => void;
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  canMutateOperatorActions: boolean;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const request = detail.work_request;
  const requestTitle = request.title || request.id;
  const requestPath = [{ id: request.id, label: requestTitle }];
  const slices = sortWorkRequestPackages(detail.work_packages ?? []);
  const progress = requestProgress(detail, packageById);
  const counts = productTreeCounts(detail, activeBlockerCount);
  const openQuestion = detail.clarification_questions?.find((question) => question.status === "open");
  const openGuidance = () => {
    const item = requestGuidanceItem(detail, guidanceItems) ?? (openQuestion ? clarificationGuidanceItem(detail, openQuestion) : null);
    if (item) {
      onSelectGuidance(item);
      return;
    }

    onSelectCard({ kind: "request", detail });
  };
  const openBlockers = () => openBlockersForRequest(detail, slices, packageById, activeBlockerCountBySliceId, activeBlockingEdges, onSelectCard);
  const requestState = requestBoardState(detail, packageById, counts, progress);
  const tone = requestState.tone;
  const requestLabel = requestState.label;
  const rowStyle = {
    animationDelay: `${index * 30}ms`,
  } as CSSProperties;
  const requestFinished = requestState.kind === "done";
  const collapseRequest = useCallback(() => onSetOpen(false), [onSetOpen]);
  useAutoCollapseWhenDone(requestFinished, expanded, collapseRequest, requestFinished);
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
        <RequestHeaderActions
          detail={detail}
          progress={progress}
          progressAttentionState={rowProgressAttentionState({ blockerCount: counts.blockerCount, guidanceCount: counts.guidanceCount, tone })}
          progressIconState={rowProgressIconState({ blockerCount: counts.blockerCount, guidanceCount: counts.guidanceCount, progress, tone })}
          progressLabel={requestLabel}
          onSelectCard={onSelectCard}
          onCopyArchitectHandoff={onCopyArchitectHandoff}
          canMutateOperatorActions={canMutateOperatorActions}
        />
        <button type="button" className="v3-request-main" aria-expanded={expanded} onClick={() => onSetOpen(!expanded)}>
          <span className="v3-request-title-group">
            <span className="v3-request-title">{requestTitle}</span>
            <span className="v3-request-meta">
              <GitBranch className="size-3.5" />
              <span>{request.repo_display || request.repo || "repo"}</span>
              <span>{request.base_branch || "main"}</span>
            </span>
          </span>
        </button>
        <RequestProgressSummary counts={counts} onOpenGuidance={openGuidance} onOpenBlockers={openBlockers} />
        <span className="v3-row-status">
          <ProgressPill progress={progress} />
          <RowBadgeSlot active={requestState.kind === "active"} label={requestLabel} variant={requestState.badgeVariant} />
        </span>
        <RequestScopeSlot counts={counts} />
      </div>
      {expanded ? (
        <div className="v3-request-body">
          <RequestActions
            detail={detail}
            openQuestion={openQuestion}
            onSelectGuidance={onSelectGuidance}
          />
          <ProductPlanBody
            detail={detail}
            packageById={packageById}
            slices={slices}
            activeBlockerCountBySliceId={activeBlockerCountBySliceId}
            activeBlockerKeysBySliceId={activeBlockerKeysBySliceId}
            activeBlockingEdges={activeBlockingEdges}
            guidanceItems={guidanceItems}
            onSelectGuidance={onSelectGuidance}
            onSelectCard={onSelectCard}
            updateAnimations={updateAnimations}
            requestPath={requestPath}
          />
        </div>
      ) : null}
    </section>
  );
}

function requestRowUpdateMotion(exiting: boolean, detail: WorkRequestDetail, updateAnimations: DashboardUpdateAnimations) {
  if (exiting) return { kind: "removed" as const, token: 0 };
  return updateAnimations.motionFor(requestUpdateKey(detail));
}

function RequestProgressSummary({
  counts,
  onOpenGuidance,
  onOpenBlockers,
}: {
  counts: ReturnType<typeof productTreeCounts>;
  onOpenGuidance: () => void;
  onOpenBlockers: () => void;
}) {
  return (
    <EntityCountChips
      className="v3-request-summary"
      items={[
        { key: "nodes", icon: <Layers3 className="size-3.5" />, count: counts.nodeCount, label: "plan nodes", showZero: true },
        { key: "slices", icon: <Split className="size-3.5" />, count: counts.sliceCount, label: "WorkPackages", showZero: true },
        { key: "guidance", icon: <MessageSquareText className="size-3.5" />, count: counts.guidanceCount, label: "guidance needed", onClick: counts.guidanceCount > 0 ? onOpenGuidance : undefined, tone: "guidance", showZero: true },
        { key: "blockers", icon: <AlertTriangle className="size-3.5" />, count: counts.blockerCount, label: "active blockers", onClick: counts.blockerCount > 0 ? onOpenBlockers : undefined, tone: "blocker", showZero: true },
      ]}
    />
  );
}

function RequestScopeSlot({ counts }: { counts: ReturnType<typeof productTreeCounts> }) {
  if (counts.nodeCount > 0) {
    return <EntityKindSlot icon={<Layers3 className="size-3.5" />} value={counts.nodeCount} title={`${counts.nodeCount} plan nodes`} />;
  }

  if (counts.sliceCount > 0) {
    return <EntityKindSlot icon={<Split className="size-3.5" />} value={counts.sliceCount} title={`${counts.sliceCount} WorkPackages`} />;
  }

  return <EntityKindSlot icon={<CircleDashed className="size-3.5" />} title="No product plan or WorkPackages attached" muted />;
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

function ProductPlanBody({
  detail,
  packageById,
  slices,
  guidanceItems,
  onSelectGuidance,
  onSelectCard,
  updateAnimations,
  requestPath,
  activeBlockerCountBySliceId,
  activeBlockerKeysBySliceId,
  activeBlockingEdges,
}: {
  detail: WorkRequestDetail;
  packageById: Map<string, WorkPackageCard>;
  slices: WorkRequestPackage[];
  guidanceItems: GuidanceItem[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
  requestPath: ContextPathPart[];
  activeBlockerCountBySliceId: Map<string, number>;
  activeBlockerKeysBySliceId: Map<string, Set<string>>;
  activeBlockingEdges: ActiveBlockingEdge[];
}) {
  const treeIndex = useMemo(() => buildTreeIndex(detail.product_tree?.nodes ?? [], detail.product_tree?.root_node_ids ?? []), [detail.product_tree]);
  const slicesById = useMemo(() => new Map(slices.map((slice) => [slice.id, slice])), [slices]);
  const rootSliceIds = useMemo(() => rootProductSliceIds(detail, slices), [detail, slices]);
  const hasVisiblePlan = treeIndex.rootNodes.length > 0 || rootSliceIds.some((sliceId) => slicesById.has(sliceId));
  const treeContext: ProductTreeRenderContext = {
    detail,
    treeIndex,
    slicesById,
    packageById,
    activeBlockerCountBySliceId,
    activeBlockerKeysBySliceId,
    activeBlockingEdges,
    guidanceItems,
    onSelectCard,
    onSelectGuidance,
    updateAnimations,
  };

  return (
    <div className="v3-product-plan">
      {treeIndex.rootNodes.length > 0 ? (
        <div className="v3-product-tree">
          {treeIndex.rootNodes.map((node) => (
            <ProductTreeNodeRow
              key={node.id}
              node={node}
              depth={0}
              path={requestPath}
              context={treeContext}
            />
          ))}
        </div>
      ) : null}
      <DirectSliceGroup
        detail={detail}
        sliceIds={rootSliceIds}
        slicesById={slicesById}
        packageById={packageById}
        activeBlockerCountBySliceId={activeBlockerCountBySliceId}
        activeBlockingEdges={activeBlockingEdges}
        guidanceItems={guidanceItems}
        onSelectGuidance={onSelectGuidance}
        onSelectCard={onSelectCard}
        requestPath={requestPath}
        updateAnimations={updateAnimations}
      />
      {!hasVisiblePlan ? <UnplannedRequestNote /> : null}
    </div>
  );
}

function UnplannedRequestNote() {
  return (
    <div className="v3-empty-plan-note">
      <CircleDashed className="size-4" />
      <span>No product plan or slices attached yet.</span>
    </div>
  );
}

function ProductTreeNodeRow({
  node,
  depth,
  context,
  path,
}: {
  node: ProductTreeNode;
  depth: number;
  path: ContextPathPart[];
  context: ProductTreeRenderContext;
}) {
  const { activeBlockerCountBySliceId, activeBlockerKeysBySliceId, activeBlockingEdges, detail, guidanceItems, onSelectCard, onSelectGuidance, packageById, treeIndex, slicesById } = context;
  const childNodes = treeIndex.childrenByParent.get(node.id) ?? [];
  const nodeTitle = node.title || node.id;
  const nodePath = [...path, { id: node.id, label: nodeTitle }];
  const nodeSlices = (node.work_package_ids ?? []).map((sliceId) => slicesById.get(sliceId)).filter((slice): slice is WorkRequestPackage => Boolean(slice));
  const nodeSubtreeSlices = productNodeSubtreeSlices(node, treeIndex, slicesById);
  const nodeState = productNodeState(node, nodeSlices.length, treeIndex, activeBlockerCountBySliceId, activeBlockerKeysBySliceId, nodeSubtreeSlices, packageById);
  const nodeFinished = nodeState.statusKind === "done";
  const contentId = useId();
  const hasDisclosureContent = productNodeHasDisclosureContent(node, nodeSlices, childNodes);
  const [expanded, setExpanded] = useState(() => !nodeFinished);
  const openGuidance = () => openGuidanceForSlices(detail, nodeSubtreeSlices, packageById, guidanceItems, onSelectGuidance, onSelectCard);
  const openBlockers = () => openBlockersForSlices(detail, nodeSubtreeSlices, packageById, activeBlockerCountBySliceId, activeBlockingEdges, onSelectCard);
  const collapseNode = useCallback(() => setExpanded(false), [setExpanded]);
  useAutoCollapseWhenDone(nodeFinished, expanded, collapseNode, nodeFinished);

  return (
    <div className="v3-product-node" style={{ "--tree-depth": depth } as CSSProperties} data-tone={nodeState.tone} data-v3-context-path={contextPathValue(nodePath)}>
      <ProductNodeHeader
        node={node}
        nodeSliceCount={nodeState.nodeSliceCount}
        visibleNodeKind={nodeState.visibleNodeKind}
        progress={nodeState.progress}
        statusBadgeVariant={nodeState.badgeVariant}
        statusActive={nodeState.statusKind === "active"}
        tone={nodeState.tone}
        statusLabel={nodeState.statusLabel}
        guidanceCount={nodeState.guidanceCount}
        blockerCount={nodeState.blockerCount}
        collapsible={hasDisclosureContent}
        expanded={expanded}
        contentId={hasDisclosureContent ? contentId : undefined}
        onOpenGuidance={openGuidance}
        onOpenBlockers={openBlockers}
        onToggle={() => setExpanded((open) => !open)}
      />
      {hasDisclosureContent ? (
        <ProductTreeNodeContent
          contentId={contentId}
          hidden={!expanded}
          node={node}
          nodeSlices={nodeSlices}
          childNodes={childNodes}
          depth={depth}
          path={nodePath}
          context={context}
        />
      ) : null}
    </div>
  );
}

function productNodeHasDisclosureContent(node: ProductTreeNode, nodeSlices: WorkRequestPackage[], childNodes: ProductTreeNode[]) {
  return Boolean(node.description) || nodeSlices.length > 0 || childNodes.length > 0;
}

function ProductTreeNodeContent({
  contentId,
  hidden,
  node,
  nodeSlices,
  childNodes,
  depth,
  context,
  path,
}: {
  contentId: string;
  hidden: boolean;
  node: ProductTreeNode;
  nodeSlices: WorkRequestPackage[];
  childNodes: ProductTreeNode[];
  depth: number;
  path: ContextPathPart[];
  context: ProductTreeRenderContext;
}) {
  const { activeBlockerCountBySliceId, activeBlockingEdges, detail, guidanceItems, packageById, onSelectCard, onSelectGuidance, updateAnimations } = context;

  return (
    <div id={contentId} className="v3-product-node-content" hidden={hidden}>
      {node.description ? <p className="v3-product-node-description">{stripMarkdown(firstParagraph(node.description) || node.description)}</p> : null}
      {nodeSlices.length > 0 ? (
        <div className="v3-slice-list">
          {nodeSlices.map((slice) => (
            <ProductSliceRow
              key={slice.id}
              detail={detail}
              slice={slice}
              pkg={packageById.get(slice.work_package_id || "")}
              activeBlockerCountBySliceId={activeBlockerCountBySliceId}
              activeBlockingEdges={activeBlockingEdges}
              guidanceItems={guidanceItems}
              onSelectGuidance={onSelectGuidance}
              onSelectCard={onSelectCard}
              updateAnimations={updateAnimations}
            />
          ))}
        </div>
      ) : null}
      {childNodes.length > 0 ? (
        <div className="v3-product-node-children">
          {childNodes.map((child) => (
            <ProductTreeNodeRow
              key={child.id}
              node={child}
              depth={depth + 1}
              path={path}
              context={context}
            />
          ))}
        </div>
      ) : null}
    </div>
  );
}
