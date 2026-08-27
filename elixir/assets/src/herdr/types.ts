import type { WorkRequestExecutionGraphModel } from "@/dashboard/execution-graph/model";

export type HerdrAgentSession = {
  agent?: string;
  value?: string;
};

export type HerdrPane = {
  pane_id: string;
  tab_id: string;
  workspace_id: string;
  focused?: boolean;
  tokens?: Record<string, string>;
  agent_session?: HerdrAgentSession;
};

export type HerdrSnapshot = {
  focused_pane_id?: string;
  panes: HerdrPane[];
  layouts?: Array<{ tab_id: string; focused_pane_id?: string }>;
  tabs?: Array<{ tab_id: string; workspace_id: string }>;
};

export type HerdrEvent = {
  event?: string;
  data?: Record<string, unknown>;
};

export type SymppBinding = {
  paneId: string;
  tabId: string;
  workspaceId: string;
  role: "architect" | "coordinator";
  workRequestId: string;
  workPackageId?: string;
  endpoint: string;
  agentSessionId: string;
};

export type WorkerSession = {
  work_package_id: string;
  agent_session_id: string;
};

export type WorkRequestDetail = {
  work_request: {
    id: string;
    title?: string | null;
    repo?: string | null;
    status?: string | null;
  };
  work_packages?: WorkRequestExecutionGraphModel["work_packages"];
  product_tree?: Record<string, unknown>;
  execution_graph: WorkRequestExecutionGraphModel;
  attention_keys?: string[];
  worker_sessions?: WorkerSession[];
};

export type InspectorState = {
  binding: SymppBinding;
  pinned: boolean;
  detail?: WorkRequestDetail;
  error?: string;
  selectedId?: string;
  snapshot?: HerdrSnapshot;
};
