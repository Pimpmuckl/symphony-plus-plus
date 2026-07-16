import type { ActiveBlockingEdge, ActiveBlockingEdgeEndpoint, WorkRequestPackage, WorkPackageBlocker, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";

export function activePackageBlockers(pkg: WorkPackageCard | undefined) {
  return (pkg?.active_blockers || []).filter((blocker) => blocker.active !== false);
}

export function packageBlockerEdge(
  blocker: WorkPackageBlocker,
  pkg: WorkPackageCard,
  context: {
    detail?: WorkRequestDetail;
    slice?: WorkRequestPackage;
    fallbackKey?: string | number;
  } = {},
): ActiveBlockingEdge {
  const { from, to } = packageBlockerEndpoints(blocker, pkg, context.slice);
  const blockerId = blocker.id || "";
  const edgeKey = blockerEdgeKey(blocker, context.fallbackKey);

  return {
    id: `active_blocking_edge:${pkg.id}:${edgeKey}`,
    blocker_id: blockerId,
    from,
    to,
    summary: blocker.summary,
    body: blocker.body,
    updated_at: blocker.updated_at,
    work_request_id: context.detail?.work_request.id || context.slice?.work_request_id || null,
    work_package_id: pkg.id,
  };
}

export function pendingPackageBlockerEdge(
  pkg: WorkPackageCard,
  context: {
    detail?: WorkRequestDetail;
    slice?: WorkRequestPackage;
  } = {},
): ActiveBlockingEdge {
  const fallbackPackageEndpoint = packageEndpoint(pkg);
  const fallbackSliceEndpoint = sliceEndpoint(context.slice);

  return {
    id: `active_blocking_edge:${pkg.id}:pending`,
    blocker_id: "",
    from: fallbackSliceEndpoint || fallbackPackageEndpoint,
    to: fallbackPackageEndpoint,
    summary: "Active blocker",
    body: null,
    updated_at: pkg.latest_progress_at || pkg.updated_at || null,
    work_request_id: context.detail?.work_request.id || context.slice?.work_request_id || null,
    work_package_id: pkg.id,
  };
}

function packageBlockerEndpoints(blocker: WorkPackageBlocker, pkg: WorkPackageCard, slice?: WorkRequestPackage) {
  const fallbackPackageEndpoint = packageEndpoint(pkg);
  const fallbackSliceEndpoint = sliceEndpoint(slice);

  return {
    from: blocker.blocked_by || fallbackSliceEndpoint || fallbackPackageEndpoint,
    to: blocker.blocked_item || fallbackPackageEndpoint,
  };
}

function packageEndpoint(pkg: WorkPackageCard): ActiveBlockingEdgeEndpoint {
  return { kind: "work_package", id: pkg.id };
}

function sliceEndpoint(slice: WorkRequestPackage | undefined): ActiveBlockingEdgeEndpoint | null {
  return slice ? { kind: "work_package", id: slice.id } : null;
}

function blockerEdgeKey(blocker: WorkPackageBlocker, fallbackKey: string | number | undefined) {
  const key = blocker.id || blocker.event_id || blocker.updated_at || fallbackKey;
  return String(key ?? "blocker");
}
