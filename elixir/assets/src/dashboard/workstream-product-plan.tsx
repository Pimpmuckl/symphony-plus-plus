import type { ActiveBlockingEdge, GuidanceItem, WorkPackageCard, WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";
import type { ProductTreeNode } from "@/types/product-tree";
import { ChevronRight, CircleDashed } from "lucide-react";
import { type CSSProperties, useCallback, useId, useMemo, useState } from "react";
import { cn } from "@/lib/utils";
import type { CardDetailSelect, DashboardUpdateAnimations } from "./runtime";
import { firstParagraph, stripMarkdown } from "./dashboard-text";
import { rootProductSliceIds } from "./workstream-progress";
import { contextPathValue, type ContextPathPart } from "./workstream-context-path";
import { groupDirectAttention, type AttentionSelect, type DirectAttention } from "./workstream-attention";
import { RowBadgeSlot } from "./workstream-row-ui";
import { DirectSliceGroup, ProductSliceRow } from "./workstream-slice-row";
import { buildTreeIndex, type TreeIndex } from "./workstream-tree-index";
import { useAutoCollapseWhenDone } from "./workstream-auto-collapse";

type ProductTreeRenderContext = {
  detail: WorkRequestDetail;
  treeIndex: TreeIndex;
  slicesById: Map<string, WorkRequestPackage>;
  packageById: Map<string, WorkPackageCard>;
  activeBlockingEdges: ActiveBlockingEdge[];
  guidanceItems: GuidanceItem[];
  onSelectAttention: AttentionSelect;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
};

export function ProductPlanBody({ detail, packageById, slices, guidanceItems, onSelectAttention, onSelectCard, updateAnimations, requestPath, activeBlockingEdges }: {
  detail: WorkRequestDetail;
  packageById: Map<string, WorkPackageCard>;
  slices: WorkRequestPackage[];
  guidanceItems: GuidanceItem[];
  onSelectAttention: AttentionSelect;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
  requestPath: ContextPathPart[];
  activeBlockingEdges: ActiveBlockingEdge[];
}) {
  const treeIndex = useMemo(() => buildTreeIndex(detail.product_tree?.nodes ?? [], detail.product_tree?.root_node_ids ?? []), [detail.product_tree]);
  const slicesById = useMemo(() => new Map(slices.map((slice) => [slice.id, slice])), [slices]);
  const rootSliceIds = useMemo(() => rootProductSliceIds(detail, slices), [detail, slices]);
  const hasVisiblePlan = treeIndex.rootNodes.length > 0 || rootSliceIds.some((sliceId) => slicesById.has(sliceId));
  const context: ProductTreeRenderContext = { detail, treeIndex, slicesById, packageById, activeBlockingEdges, guidanceItems, onSelectAttention, onSelectCard, updateAnimations };

  return (
    <div className="v3-product-plan">
      {treeIndex.rootNodes.length > 0 ? <div className="v3-product-tree">{treeIndex.rootNodes.map((node) => <ProductTreeNodeRow key={node.id} node={node} depth={0} path={requestPath} context={context} />)}</div> : null}
      <DirectSliceGroup detail={detail} sliceIds={rootSliceIds} slicesById={slicesById} packageById={packageById} activeBlockingEdges={activeBlockingEdges} guidanceItems={guidanceItems} onSelectAttention={onSelectAttention} onSelectCard={onSelectCard} requestPath={requestPath} updateAnimations={updateAnimations} />
      {!hasVisiblePlan ? <UnplannedRequestNote /> : null}
    </div>
  );
}

function UnplannedRequestNote() {
  return <div className="v3-empty-plan-note"><CircleDashed className="size-4" /><span>No product plan or WorkPackages attached yet.</span></div>;
}

function ProductTreeNodeRow({ node, depth, context, path }: { node: ProductTreeNode; depth: number; path: ContextPathPart[]; context: ProductTreeRenderContext }) {
  const childNodes = context.treeIndex.childrenByParent.get(node.id) ?? [];
  const nodeTitle = node.title || node.id;
  const nodePath = [...path, { id: node.id, label: nodeTitle }];
  const nodeSlices = (node.work_package_ids ?? []).map((sliceId) => context.slicesById.get(sliceId)).filter((slice): slice is WorkRequestPackage => Boolean(slice));
  const nodeFinished = (node.computed_completion_mark || node.completion_mark) === "done";
  const contentId = useId();
  const hasDisclosureContent = productNodeHasDisclosureContent(node, nodeSlices, childNodes);
  const [expanded, setExpanded] = useState(() => !nodeFinished);
  const collapseNode = useCallback(() => setExpanded(false), [setExpanded]);
  useAutoCollapseWhenDone(nodeFinished, expanded, collapseNode, nodeFinished);
  const attention = groupDirectAttention(context.detail, node.id, context.packageById, context.activeBlockingEdges, context.guidanceItems);

  return (
    <div className="v3-product-node" style={{ "--tree-depth": depth } as CSSProperties} data-tone={attention?.tone} data-v3-context-path={contextPathValue(nodePath)}>
      <ProductNodeHeader node={node} nodeSliceCount={nodeSlices.length} attention={attention} collapsible={hasDisclosureContent} expanded={expanded} contentId={hasDisclosureContent ? contentId : undefined} onSelectAttention={context.onSelectAttention} onToggle={() => setExpanded((open) => !open)} />
      {hasDisclosureContent ? <div className="v3-disclosure-reveal" data-open={expanded ? "true" : "false"} aria-hidden={!expanded} inert={!expanded}><ProductTreeNodeContent contentId={contentId} node={node} nodeSlices={nodeSlices} childNodes={childNodes} depth={depth} path={nodePath} context={context} /></div> : null}
    </div>
  );
}

function productNodeHasDisclosureContent(node: ProductTreeNode, nodeSlices: WorkRequestPackage[], childNodes: ProductTreeNode[]) {
  return Boolean(node.description) || nodeSlices.length > 0 || childNodes.length > 0;
}

function ProductTreeNodeContent({ contentId, node, nodeSlices, childNodes, depth, context, path }: {
  contentId: string;
  node: ProductTreeNode;
  nodeSlices: WorkRequestPackage[];
  childNodes: ProductTreeNode[];
  depth: number;
  context: ProductTreeRenderContext;
  path: ContextPathPart[];
}) {
  return (
    <div id={contentId} className="v3-product-node-content">
      {node.description ? <p className="v3-product-node-description">{stripMarkdown(firstParagraph(node.description) || node.description)}</p> : null}
      {nodeSlices.length > 0 ? <div className="v3-slice-list">{nodeSlices.map((slice) => <ProductSliceRow key={slice.id} detail={context.detail} slice={slice} pkg={context.packageById.get(slice.work_package_id || "")} activeBlockingEdges={context.activeBlockingEdges} guidanceItems={context.guidanceItems} onSelectAttention={context.onSelectAttention} onSelectCard={context.onSelectCard} updateAnimations={context.updateAnimations} />)}</div> : null}
      {childNodes.length > 0 ? <div className="v3-product-node-children">{childNodes.map((child) => <ProductTreeNodeRow key={child.id} node={child} depth={depth + 1} path={path} context={context} />)}</div> : null}
    </div>
  );
}

function ProductNodeHeader({ node, nodeSliceCount, attention, collapsible, expanded, contentId, onSelectAttention, onToggle }: {
  node: ProductTreeNode;
  nodeSliceCount: number;
  attention: DirectAttention | null;
  collapsible: boolean;
  expanded: boolean;
  contentId?: string;
  onSelectAttention: AttentionSelect;
  onToggle: () => void;
}) {
  const title = node.title || node.id;
  const fallback = node.completion_label || completionLabel(node);
  return (
    <div className="v3-product-node-header v3-entity-row">
      <ProductNodeDisclosure collapsible={collapsible} contentId={contentId} expanded={expanded} onToggle={onToggle} title={title} />
      <button type="button" className="v3-product-node-main" disabled={!collapsible} onClick={onToggle}><span className="v3-product-node-title">{title}</span><span className="v3-product-node-meta">{nodeSliceCount} {nodeSliceCount === 1 ? "WorkPackage" : "WorkPackages"}</span></button>
      <ProductNodeAttention attention={attention} fallback={fallback} onSelectAttention={onSelectAttention} title={title} />
    </div>
  );
}

function ProductNodeDisclosure({ collapsible, contentId, expanded, onToggle, title }: { collapsible: boolean; contentId?: string; expanded: boolean; onToggle: () => void; title: string }) {
  if (!collapsible) return <span className="v3-product-node-chevron-placeholder" aria-hidden="true" />;
  return <button type="button" className="v3-product-node-chevron-button" aria-controls={contentId} aria-expanded={expanded} aria-label={`${expanded ? "Collapse" : "Expand"} ${title}`} data-expanded={expanded ? "true" : "false"} onClick={onToggle}><ChevronRight className={cn("size-4 transition-transform duration-200", expanded && "rotate-90")} /></button>;
}

function ProductNodeAttention({ attention, fallback, onSelectAttention, title }: { attention: DirectAttention | null; fallback: string; onSelectAttention: AttentionSelect; title: string }) {
  const onClick = attention ? () => onSelectAttention(attention.target) : undefined;
  const variant = attention?.tone === "blocked" ? "danger" : attention ? "guidance" : "secondary";
  return <RowBadgeSlot actionLabel={onClick ? `Open attention details for ${title}` : undefined} label={attention?.label || fallback} onClick={onClick} variant={variant} />;
}

function completionLabel(node: ProductTreeNode) {
  const mark = node.computed_completion_mark || node.completion_mark;
  if (mark === "done") return "Done";
  if (mark === "partial") return "Partial";
  if (mark === "deferred") return "Deferred";
  return "Planned";
}
