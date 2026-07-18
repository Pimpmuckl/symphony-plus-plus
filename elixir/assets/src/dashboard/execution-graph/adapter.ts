import type { WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";
import type { ProductTreeExecutionGraph, ProductTreeNode } from "@/types/product-tree";

import type { WorkRequestExecutionGraphModel } from "./model";

const historicalStates = new Set(["skipped", "canceled", "cancelled", "abandoned", "superseded"]);
type DeliveryItem = NonNullable<NonNullable<WorkRequestDetail["delivery_board"]>["work_packages"]>[number];
type DeliverySignal = NonNullable<DeliveryItem["work_package"]>;

export function workRequestExecutionGraphModel(
  detail: WorkRequestDetail,
  { includeHistorical = false }: { includeHistorical?: boolean } = {},
): WorkRequestExecutionGraphModel {
  const productTree = detail.product_tree;
  const graph = productTree?.execution_graph;
  const slices = new Map(list(detail.work_packages).map((slice) => [slice.id, slice]));
  const delivery = new Map(list(detail.delivery_board?.work_packages).map((item) => [item.id, item]));
  const workPackageIds = list(graph?.work_package_ids).filter(
    (id) => includeHistorical || !isHistoricalWorkPackage(slices.get(id), delivery.get(id)),
  );

  return {
    available: graphAvailable(graph),
    groups: list(productTree?.nodes).map(mapGroup),
    work_packages: workPackageIds.map((id) => mapWorkPackage(id, slices.get(id), delivery.get(id))),
    effective_edges: list(graph?.effective_edges),
    topological_order: list(graph?.topological_order),
    cycles: list(graph?.cycles),
  };
}

function mapGroup(group: ProductTreeNode) {
  return {
    id: group.id,
    parent_group_id: group.parent_id,
    title: group.title,
    description: group.description,
    position: group.position,
    work_package_ids: group.work_package_ids,
  };
}

function mapWorkPackage(id: string, slice?: WorkRequestPackage, item?: DeliveryItem) {
  return {
    id,
    ...workPackageReference(slice, item),
    ...workPackageSignals(item),
  };
}

function workPackageReference(slice?: WorkRequestPackage, item?: DeliveryItem) {
  const signal = item?.work_package;
  return {
    ...sliceReference(slice),
    title: firstValue(signal?.title, slice?.title),
    status: firstValue(signal?.status, slice?.status),
    raw_status: projectedRawStatus(signal, item, slice),
    operational_state: projectedOperationalState(item, slice),
  };
}

function sliceReference(slice?: WorkRequestPackage) {
  return { group_id: slice?.product_tree_node_id, sequence: slice?.sequence };
}

function projectedRawStatus(signal?: DeliverySignal | null, item?: DeliveryItem, slice?: WorkRequestPackage) {
  return firstValue(signal?.raw_status, item?.raw_status, slice?.work_package_status, slice?.status);
}

function projectedOperationalState(item?: DeliveryItem, slice?: WorkRequestPackage) {
  return firstValue(item?.operational_state, slice?.operational_state);
}

function workPackageSignals(item?: DeliveryItem) {
  const signal = item?.work_package;
  return {
    worker_signal: signal?.worker_signal,
    pr_signal: signal?.pr_signal,
    review_signal: signal?.review_signal,
    dependency_signal: signal?.dependency_signal,
  };
}

function isHistoricalWorkPackage(slice?: WorkRequestPackage, item?: DeliveryItem) {
  return [...sliceHistoryStates(slice), ...deliveryHistoryStates(item)].some(isHistoricalState);
}

function sliceHistoryStates(slice?: WorkRequestPackage) {
  return [
    slice?.status,
    slice?.work_package_status,
    slice?.delivery?.outcome,
    slice?.operational_state?.key,
    slice?.operational_state?.delivery_outcome,
  ];
}

function deliveryHistoryStates(item?: DeliveryItem) {
  return [
    item?.raw_status,
    item?.delivery_outcome,
    item?.delivery?.outcome,
    item?.operational_state?.key,
    item?.operational_state?.delivery_outcome,
    ...deliverySignalHistoryStates(item?.work_package),
  ];
}

function deliverySignalHistoryStates(signal?: DeliverySignal | null) {
  return [signal?.raw_status, signal?.status];
}

function graphAvailable(graph?: ProductTreeExecutionGraph) {
  return graph?.available ?? false;
}

function list<T>(values?: T[] | null) {
  return values ?? [];
}

function firstValue<T>(...values: Array<T | null | undefined>) {
  return values.find((value): value is T => value != null);
}

function isHistoricalState(value: string | null | undefined) {
  return historicalStates.has(value?.trim().toLowerCase() ?? "");
}
