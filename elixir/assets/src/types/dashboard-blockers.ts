export type ActiveBlockingEdgeEndpoint = {
  kind: "work_package";
  id: string;
};

export type BlockerActor = {
  id?: string | null;
  type?: string | null;
  access_grant_id?: string | null;
};

export type ActiveBlockingEdge = {
  id: string;
  blocker_id: string;
  from: ActiveBlockingEdgeEndpoint;
  to: ActiveBlockingEdgeEndpoint;
  summary?: string | null;
  body?: string | null;
  updated_at?: string | null;
  work_request_id?: string | null;
  work_package_id?: string | null;
};

export type WorkPackageBlocker = {
  id?: string;
  active?: boolean;
  summary?: string | null;
  body?: string | null;
  status?: string | null;
  resolution?: string | null;
  blocked_by?: ActiveBlockingEdgeEndpoint | null;
  blocked_item?: ActiveBlockingEdgeEndpoint | null;
  actor?: BlockerActor | null;
  event_id?: string | null;
  source_tool?: string | null;
  updated_at?: string | null;
};
