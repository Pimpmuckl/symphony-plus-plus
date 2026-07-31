import type { ProductTreeNode } from "@/types/product-tree";

export type TreeIndex = {
  childrenByParent: Map<string, ProductTreeNode[]>;
  rootNodes: ProductTreeNode[];
};

export function buildTreeIndex(nodes: ProductTreeNode[], rootNodeIds: string[]): TreeIndex {
  const sortedNodes = nodes.toSorted(compareProductNodes);
  const nodeById = new Map(sortedNodes.map((node) => [node.id, node]));
  const childrenByParent = new Map<string, ProductTreeNode[]>();
  const explicitRoots = rootNodeIds.map((id) => nodeById.get(id)).filter((node): node is ProductTreeNode => Boolean(node));

  sortedNodes.forEach((node) => {
    if (!node.parent_id) return;
    const children = childrenByParent.get(node.parent_id) ?? [];
    children.push(node);
    childrenByParent.set(node.parent_id, children);
  });

  return {
    childrenByParent,
    rootNodes: explicitRoots.length > 0 ? explicitRoots : sortedNodes.filter((node) => !node.parent_id),
  };
}

function compareProductNodes(left: ProductTreeNode, right: ProductTreeNode) {
  const leftPosition = Number.isFinite(left.position) ? left.position ?? 0 : 0;
  const rightPosition = Number.isFinite(right.position) ? right.position ?? 0 : 0;
  if (leftPosition !== rightPosition) return leftPosition - rightPosition;
  return (left.title || left.id).localeCompare(right.title || right.id);
}
