import type { SoloSessionDetailPayload, WorkPackageDetailPayload, WorkRequestDetail } from "@/types/dashboard";
import type { CardDetailSelection } from "./runtime";

export type DetailResourceState<T> = {
  payload: T | null;
  loading: boolean;
  error: string | null;
  resourceKey?: string | null;
};

export type CardDetailDialogState = {
  package: DetailResourceState<WorkPackageDetailPayload>;
  request: DetailResourceState<WorkRequestDetail>;
  solo: DetailResourceState<SoloSessionDetailPayload>;
};

export function cardDetailPackageId(selection: CardDetailSelection | null) {
  if (selection?.kind === "package") return selection.pkg.id;
  if (selection?.kind !== "blocker") return null;

  return (
    selection.pkg?.id ||
    selection.blocker.work_package_id ||
    (selection.blocker.to.kind === "work_package" ? selection.blocker.to.id : null)
  );
}

export function cardDetailRequestResourceKey(selection: CardDetailSelection | null) {
  if (selection?.kind === "request") return selection.detail.work_request.id;
  if (selection?.kind === "slice") return `${selection.detail.work_request.id}:${selection.slice.id}`;
  return null;
}

export function matchingPackageResource(selection: CardDetailSelection, state: CardDetailDialogState) {
  const packageId = cardDetailPackageId(selection);
  return state.package.resourceKey === packageId
    ? state.package
    : { payload: null, loading: Boolean(packageId), error: null, resourceKey: packageId };
}

export function matchingRequestResource(selection: CardDetailSelection, state: CardDetailDialogState) {
  const resourceKey = cardDetailRequestResourceKey(selection);
  return state.request.resourceKey === resourceKey
    ? state.request
    : { payload: null, loading: Boolean(resourceKey), error: null, resourceKey };
}

export function mergeRequestDetail(summary: WorkRequestDetail, enrichment: WorkRequestDetail): WorkRequestDetail {
  return {
    ...summary,
    ...enrichment,
    work_request: {
      ...summary.work_request,
      ...enrichment.work_request,
      open_question_count:
        enrichment.summary?.open_question_count ?? enrichment.work_request.open_question_count ?? summary.work_request.open_question_count,
    },
    work_packages:
      summary.work_packages?.map((workPackage) => {
        const enriched = enrichment.work_packages?.find((candidate) => candidate.id === workPackage.id);
        return enriched
          ? { ...workPackage, ...enriched, delivery: { ...workPackage.delivery, ...enriched.delivery } }
          : workPackage;
      }) ?? enrichment.work_packages,
    summary: { ...summary.summary, ...enrichment.summary },
  };
}

export function cardDetailContentReady(selection: CardDetailSelection | null, state: CardDetailDialogState) {
  if (!selection) return false;

  switch (selection.kind) {
    case "request":
    case "slice":
    case "package":
    case "blocker":
      return true;
    case "solo": {
      if (state.solo.error) return true;
      const payload = state.solo.payload;
      if (!payload) return false;
      const payloadId = payload.solo_session?.id;
      return !payloadId || payloadId === selection.session.id;
    }
  }
}
