import type { ActiveBlockingEdge, GuidanceItem, WorkPackageCard, WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";
import type { BoardRowStateKind } from "./workstream-row-state";
import type { CardDetailSelection } from "./runtime";
import { clarificationGuidanceItem } from "./dashboard-data";
import { activeBlockerEdgesForRequest } from "./workstream-progress";
import { sliceBlockerCount, sliceGuidanceCount } from "./workstream-row-state";

export type RequestAttentionTarget =
  | { kind: "guidance"; item: GuidanceItem }
  | { kind: "card"; selection: CardDetailSelection };

export function requestAttentionTarget(
  detail: WorkRequestDetail,
  packageById: Map<string, WorkPackageCard>,
  activeBlockingEdges: ActiveBlockingEdge[],
  stateKind: BoardRowStateKind,
): RequestAttentionTarget | null {
  if (stateKind === "guidance") {
    const question = detail.clarification_questions?.find((item) => item.status === "open");
    if (question) return { kind: "guidance", item: clarificationGuidanceItem(detail, question) };

    const slice = detail.work_packages?.find((item) => sliceGuidanceCount(item, packageForSlice(item, packageById)) > 0);
    return { kind: "card", selection: slice ? sliceSelection(detail, slice, packageById) : { kind: "request", detail } };
  }

  if (stateKind === "blocked") {
    const blocker = activeBlockerEdgesForRequest(activeBlockingEdges, detail)[0];
    if (blocker) {
      const slice = blockerSlice(detail, blocker);
      const pkg = packageById.get(blocker.work_package_id || "") ?? packageById.get(blocker.to.id);
      return { kind: "card", selection: { kind: "blocker", blocker, detail, slice, pkg } };
    }

    const slice = detail.work_packages?.find((item) => sliceNeedsAttention(item, packageForSlice(item, packageById)));
    return { kind: "card", selection: slice ? sliceSelection(detail, slice, packageById) : { kind: "request", detail } };
  }

  return null;
}

function blockerSlice(detail: WorkRequestDetail, blocker: ActiveBlockingEdge) {
  const ids = new Set([blocker.work_package_id, blocker.to.id].filter(Boolean));
  return detail.work_packages?.find((slice) => ids.has(slice.id) || ids.has(slice.work_package_id));
}

function packageForSlice(slice: WorkRequestPackage, packageById: Map<string, WorkPackageCard>) {
  return packageById.get(slice.work_package_id || slice.id);
}

function sliceNeedsAttention(slice: WorkRequestPackage, pkg?: WorkPackageCard) {
  return slice.review_signal?.status === "failed"
    || slice.pr_signal?.checks?.status === "failing"
    || sliceBlockerCount(slice, pkg, new Map()) > 0;
}

function sliceSelection(detail: WorkRequestDetail, slice: WorkRequestPackage, packageById: Map<string, WorkPackageCard>): CardDetailSelection {
  return { kind: "slice", detail, slice, pkg: packageForSlice(slice, packageById) };
}
