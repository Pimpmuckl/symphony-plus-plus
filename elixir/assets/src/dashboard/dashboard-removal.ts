import type { ActiveBlockingEdge, DashboardPayload } from "@/types/dashboard";

export function removeDashboardWorkRequest(dashboard: DashboardPayload | null, workRequestId: string): DashboardPayload | null {
  if (!dashboard) return dashboard;

  const packageIds = deletedPackageIds(dashboard, workRequestId);
  const guidanceRequests = dashboard.guidance_requests?.guidance_requests?.filter((request) => !packageIds.has(request.work_package_id));
  return {
    ...dashboard,
    active_blocking_edges: dashboard.active_blocking_edges?.filter((edge) => !edgeBelongsToRequest(edge, workRequestId, packageIds)),
    archived_work_requests: removeRequestSection(dashboard.archived_work_requests, workRequestId),
    guidance_requests: dashboard.guidance_requests
      ? { ...dashboard.guidance_requests, guidance_requests: guidanceRequests, total_count: guidanceRequests?.length ?? 0 }
      : dashboard.guidance_requests,
    linked_work_package_ids: dashboard.linked_work_package_ids?.filter((id) => !packageIds.has(id)),
    work_packages: dashboard.work_packages?.filter((pkg) => !packageIds.has(pkg.id)),
    work_request_details: dashboard.work_request_details?.filter((detail) => detail.work_request.id !== workRequestId),
    work_requests: removeRequestSection(dashboard.work_requests, workRequestId),
  };
}

function deletedPackageIds(dashboard: DashboardPayload, workRequestId: string) {
  const detail = dashboard.work_request_details?.find((candidate) => candidate.work_request.id === workRequestId);
  const ids = new Set(
    detail?.work_packages?.flatMap((pkg) => [pkg.id, pkg.work_package_id].filter((id): id is string => Boolean(id))) ?? [],
  );
  for (const edge of dashboard.active_blocking_edges ?? []) {
    if (edge.work_request_id === workRequestId) {
      [edge.work_package_id, edge.from.id, edge.to.id].forEach((id) => id && ids.add(id));
    }
  }
  return ids;
}

function edgeBelongsToRequest(edge: ActiveBlockingEdge, workRequestId: string, packageIds: Set<string>) {
  return edge.work_request_id === workRequestId ||
    [edge.work_package_id, edge.from.id, edge.to.id].some((id) => Boolean(id && packageIds.has(id)));
}

function removeRequestSection(section: DashboardPayload["work_requests"], workRequestId: string) {
  if (!section) return section;
  const workRequests = (section.work_requests ?? []).filter((card) => card.id !== workRequestId);
  return { ...section, work_requests: workRequests, total_count: workRequests.length };
}
