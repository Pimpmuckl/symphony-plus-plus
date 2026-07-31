import type { WorkPackageCard, WorkRequestDetail, WorkRequestPackage } from "@/types/dashboard";

export function requestBadgeLabel(label: string, detail: WorkRequestDetail, packageById: Map<string, WorkPackageCard>, now?: string) {
  const latestAt = latestTimestampAtOrBefore(now, [detail.work_request.updated_at, ...(detail.work_packages ?? []).flatMap((slice) => [
    slice.updated_at,
    linkedPackage(slice, packageById)?.updated_at,
  ])]);
  const age = elapsedLabel(latestAt, now)?.split(" ", 1)[0];
  return age ? `${label} · ${age}` : label;
}

export function elapsedLabel(activeSince: string | null | undefined, now?: string | number | Date) {
  if (!activeSince || now == null) return undefined;
  const elapsed = new Date(now).getTime() - Date.parse(activeSince);
  if (!Number.isFinite(elapsed) || elapsed < 0) return undefined;
  const seconds = Math.floor(elapsed / 1_000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
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
