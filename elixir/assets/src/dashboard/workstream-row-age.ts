import type { WorkPackageCard, WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";

import { elapsedLabel } from "./work-request-execution-graph";

export function requestBadgeLabel(label: string, detail: WorkRequestDetail, packageById: Map<string, WorkPackageCard>, now?: string) {
  const packageUpdatedAt = latestTimestampAtOrBefore(now, (detail.work_packages ?? []).flatMap((slice) => [
    slice.updated_at,
    linkedPackage(slice, packageById)?.updated_at,
  ]));
  const latestAt = packageUpdatedAt ?? latestTimestampAtOrBefore(now, [detail.work_request.updated_at]);
  const age = elapsedLabel(latestAt, now);
  return age ? `${label} · ${age}` : label;
}

function linkedPackage(slice: WorkRequestPackage, packageById: Map<string, WorkPackageCard>) {
  return slice.work_package_id ? packageById.get(slice.work_package_id) : undefined;
}

function latestTimestampAtOrBefore(now: string | undefined, values: Array<string | null | undefined>) {
  if (!now) return undefined;
  const nowMs = Date.parse(now);
  if (!Number.isFinite(nowMs)) return undefined;
  return values
    .filter((value): value is string => Boolean(value && Number.isFinite(Date.parse(value)) && Date.parse(value) <= nowMs))
    .toSorted((left, right) => Date.parse(right) - Date.parse(left))[0];
}
