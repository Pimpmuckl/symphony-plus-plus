export type WorkPackageWorkerSignal = {
  status: "active" | "idle" | "paused" | "stale" | "unavailable";
  active_since?: string | null;
  last_activity?: string | null;
  run_label?: string | null;
};

export type WorkPackagePrSignal = {
  status: "none" | "open" | "merged" | "unavailable";
  url?: string | null;
  number?: number | null;
  repository?: string | null;
  head_sha?: string | null;
  current_head_sha?: string | null;
  head_matches?: boolean | null;
  checks?: {
    status: "pending" | "passing" | "failing" | "unavailable";
    current?: number | null;
    total?: number | null;
  } | null;
};

export type WorkPackageReviewSignal = {
  type?: string | null;
  args?: Record<string, unknown> | null;
  status: "pending" | "in_progress" | "passed" | "failed" | "unavailable";
  current?: number | null;
  total?: number | null;
  step?: string | null;
  evidence_id?: string | null;
  reviewed_head?: string | null;
};

export type WorkPackageDependencySignal = {
  satisfied: number;
  required: number;
  active: number;
  blocked: number;
  unmet_work_package_ids: string[];
  inputs: Array<{
    work_package_id: string;
    status: "satisfied" | "active" | "blocked" | "waiting";
  }>;
};

export type DeliveryBoardWorkPackageSummary = {
  id: string;
  title?: string | null;
  kind?: string | null;
  repo?: string | null;
  base_branch?: string | null;
  branch_pattern?: string | null;
  raw_status?: string | null;
  status?: string | null;
  worker_signal?: WorkPackageWorkerSignal | null;
  pr_signal?: WorkPackagePrSignal | null;
  review_signal?: WorkPackageReviewSignal | null;
  dependency_signal?: WorkPackageDependencySignal | null;
};
