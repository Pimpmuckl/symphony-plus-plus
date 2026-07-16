export type ProductTreeCompletionMark = "done" | "partial" | "not_done" | "deferred" | "unknown";

export type ProductTreeNode = {
  id: string;
  parent_id?: string | null;
  title?: string | null;
  description?: string | null;
  node_kind?: string | null;
  completion_mark?: ProductTreeCompletionMark | null;
  computed_completion_mark?: ProductTreeCompletionMark | null;
  completion_label?: string | null;
  work_package_ids?: string[];
  child_node_count?: number;
  work_package_count?: number;
  attention_count?: number;
  guidance_count?: number;
  blocker_count?: number;
  position?: number;
  metadata?: Record<string, unknown>;
  created_by?: string | null;
  created_at?: string | null;
  updated_at?: string | null;
};

export type ProductTreeDependencyEndpoint = {
  kind?: "product_node" | "work_package" | string | null;
  id?: string | null;
};

export type ProductTreeDependencyEdge = {
  id: string;
  source?: ProductTreeDependencyEndpoint;
  target?: ProductTreeDependencyEndpoint;
  kind?: string | null;
  reason?: string | null;
  decision_ref?: Record<string, unknown> | null;
  created_by?: string | null;
  created_at?: string | null;
};

export type ProductTreeProjection = {
  available?: boolean;
  schema_version?: string;
  mode?: "product_tree" | "direct_work_packages" | "unavailable" | string;
  root_node_ids?: string[];
  root_work_package_ids?: string[];
  nodes?: ProductTreeNode[];
  dependency_edges?: ProductTreeDependencyEdge[];
  summary?: {
    node_count?: number;
    root_node_count?: number;
    root_work_package_count?: number;
    work_package_count?: number;
    linked_work_package_count?: number;
    done_count?: number;
    partial_count?: number;
    not_done_count?: number;
    deferred_count?: number;
    unknown_count?: number;
    attention_count?: number;
    guidance_count?: number;
    blocker_count?: number;
  };
  latest_revision?: {
    id?: string | null;
    revision_number?: number;
    reason?: string | null;
    decision_ref?: Record<string, unknown> | null;
    created_by?: string | null;
    created_at?: string | null;
  } | null;
  attention_items?: Array<Record<string, unknown>>;
};
