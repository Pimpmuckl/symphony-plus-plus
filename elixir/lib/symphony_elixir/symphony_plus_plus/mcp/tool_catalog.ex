defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, SoloTools}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog.InputSchemas
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry

  @health_tool "sympp.health"
  @mcp_contract_schema_version "sympp-mcp-contract.v1"
  @mcp_contract_health_fields [
    "ledger",
    "mode",
    "source.mcp_contract.fingerprint",
    "source.mcp_contract.schema_version",
    "source.revision",
    "status",
    "version"
  ]
  @solo_tools SoloTools.tool_names()
  @assignment_release_tool "release_current_assignment"
  @bootstrap_tools ["create_work_request"]
  @local_operator_tools ["add_work_request_comment", "record_work_request_operator_decision"]
  @blocker_closeout_decisions ["resolved", "still_active"]
  @local_assignment_claim_tool "claim_local_assignment"
  @local_architect_assignment_claim_tool "claim_local_architect_assignment"
  @session_claim_tools [@local_assignment_claim_tool, @local_architect_assignment_claim_tool]
  @local_assignment_claim_hidden_worker_arguments ["repo", "base_branch", "work_request_id", "branch", "worktree_path", "caller_id"]
  @session_scoped_worker_tools [
    "update_task_plan",
    "append_finding",
    "append_progress",
    "set_status",
    "report_blocker",
    "resolve_blocker",
    "add_comment",
    "list_comments",
    "resolve_comment",
    "create_guidance_request",
    "read_guidance_request",
    "request_scope_expansion",
    "attach_branch",
    "attach_pr",
    "sync_pr",
    "submit_review_package",
    "complete_review"
  ]
  @worker_tools [
    "get_current_assignment",
    "read_context",
    "read_task_plan",
    "update_task_plan",
    "append_finding",
    "append_progress",
    "set_status",
    "report_blocker",
    "resolve_blocker",
    "add_comment",
    "list_comments",
    "resolve_comment",
    "create_guidance_request",
    "read_guidance_request",
    "request_scope_expansion",
    "attach_branch",
    "attach_pr",
    "sync_pr",
    "submit_review_package",
    "complete_review",
    "mark_ready"
  ]
  @shared_worker_architect_tools ["add_comment", "list_comments", "resolve_comment", "resolve_blocker", "read_guidance_request"]
  @architect_tools [
    "create_child_work_package",
    "mint_child_worker_key",
    "revoke_child_worker_key",
    "list_work_requests",
    "read_work_request",
    "read_plan",
    "add_comment",
    "list_comments",
    "resolve_comment",
    "resolve_blocker",
    "read_delivery_board",
    "reconcile_work_request",
    "cleanup_work_request_work_package_runtime",
    "record_work_package_delivery",
    "revoke_work_package_worker_key",
    "list_guidance_requests",
    "read_guidance_request",
    "answer_guidance_request",
    "escalate_guidance_request",
    "set_work_request_status",
    "ask_question",
    "answer_question",
    "answer_question_and_record_decision",
    "close_question",
    "record_decision",
    "slice_work_request",
    "update_work_package",
    "upsert_group",
    "delete_group",
    "upsert_dependency",
    "delete_dependency",
    "skip_work_package",
    "dispatch_work_package",
    "prepare_work_package_worktree",
    "cleanup_work_package_worktree",
    "read_child_status",
    "approve_scope_expansion",
    "read_phase_board",
    "approve_child_ready_state",
    "merge_child_into_phase"
  ]
  @work_request_policy_tools [
    "list_work_requests",
    "read_work_request",
    "read_plan",
    "read_delivery_board",
    "set_work_request_status",
    "ask_question",
    "answer_question",
    "answer_question_and_record_decision",
    "close_question",
    "record_decision",
    "slice_work_request",
    "update_work_package",
    "upsert_group",
    "delete_group",
    "upsert_dependency",
    "delete_dependency",
    "skip_work_package",
    "dispatch_work_package"
  ]
  @current_work_request_write_tools [
    "slice_work_request",
    "update_work_package",
    "upsert_group",
    "delete_group",
    "upsert_dependency",
    "delete_dependency",
    "skip_work_package"
  ]
  @current_work_request_tools @current_work_request_write_tools ++
                                [
                                  "read_delivery_board",
                                  "reconcile_work_request",
                                  "cleanup_work_request_work_package_runtime",
                                  "record_work_package_delivery",
                                  "revoke_work_package_worker_key",
                                  "dispatch_work_package"
                                ]
  @delivery_policy_tools [
    "reconcile_work_request",
    "cleanup_work_request_work_package_runtime",
    "record_work_package_delivery",
    "revoke_work_package_worker_key"
  ]
  @work_request_product_tree_views ["groups_only", "groups_with_work_package_refs", "groups_with_work_packages"]
  @type tool_name :: String.t()
  @type input_schema :: map()
  @type tool_spec :: map()

  @spec health_tool() :: tool_name()
  def health_tool, do: @health_tool

  @spec mcp_contract_schema_version() :: String.t()
  def mcp_contract_schema_version, do: @mcp_contract_schema_version

  @spec mcp_contract_health_fields() :: [String.t()]
  def mcp_contract_health_fields, do: @mcp_contract_health_fields

  @spec solo_tools() :: [tool_name()]
  def solo_tools, do: @solo_tools

  @spec assignment_release_tool() :: tool_name()
  def assignment_release_tool, do: @assignment_release_tool

  @spec bootstrap_tools() :: [tool_name()]
  def bootstrap_tools, do: @bootstrap_tools

  @spec local_operator_tools() :: [tool_name()]
  def local_operator_tools, do: @local_operator_tools

  @spec blocker_closeout_decisions() :: [String.t()]
  def blocker_closeout_decisions, do: @blocker_closeout_decisions

  @spec local_assignment_claim_tool() :: tool_name()
  def local_assignment_claim_tool, do: @local_assignment_claim_tool

  @spec local_architect_assignment_claim_tool() :: tool_name()
  def local_architect_assignment_claim_tool, do: @local_architect_assignment_claim_tool

  @spec session_claim_tools() :: [tool_name()]
  def session_claim_tools, do: @session_claim_tools

  @spec worker_tools() :: [tool_name()]
  def worker_tools, do: @worker_tools

  @spec contract_unbound_tools() :: [tool_name()]
  def contract_unbound_tools, do: [@health_tool, @assignment_release_tool] ++ @solo_tools ++ @session_claim_tools

  @spec contract_trusted_local_http_extra_tools() :: [tool_name()]
  def contract_trusted_local_http_extra_tools, do: @bootstrap_tools ++ ["add_work_request_comment", "list_comments", "record_work_request_operator_decision"]

  @spec contract_bound_worker_tools() :: [tool_name()]
  def contract_bound_worker_tools, do: [@health_tool, @assignment_release_tool] ++ @worker_tools

  @spec contract_bound_architect_tools() :: [tool_name()]
  def contract_bound_architect_tools, do: [@health_tool, @assignment_release_tool, "get_current_assignment"] ++ @architect_tools

  @spec hidden_worker_argument_keys(tool_name()) :: [String.t()]
  def hidden_worker_argument_keys(@local_assignment_claim_tool), do: @local_assignment_claim_hidden_worker_arguments
  def hidden_worker_argument_keys(name) when name in @session_scoped_worker_tools, do: ["work_package_id"]
  def hidden_worker_argument_keys(_name), do: []

  @spec shared_worker_architect_tools() :: [tool_name()]
  def shared_worker_architect_tools, do: @shared_worker_architect_tools

  @spec architect_tools() :: [tool_name()]
  def architect_tools, do: @architect_tools

  @spec work_request_policy_tools() :: [tool_name()]
  def work_request_policy_tools, do: @work_request_policy_tools

  @spec delivery_policy_tools() :: [tool_name()]
  def delivery_policy_tools, do: @delivery_policy_tools

  @spec work_request_product_tree_views() :: [String.t()]
  def work_request_product_tree_views, do: @work_request_product_tree_views

  defp health_tool_spec do
    %{
      "name" => @health_tool,
      "title" => "Symphony++ health",
      "description" => "Returns server version, ledger reachability, and safe ledger identity without exposing package data.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{}
      }
    }
  end

  defp worker_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => "Symphony++ worker tool #{name}.",
      "inputSchema" => worker_tool_input_schema(name)
    }
  end

  defp unbound_worker_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => "Symphony++ worker tool #{name}.",
      "inputSchema" => InputSchemas.unbound_worker_tool_input_schema(name)
    }
  end

  defp assignment_release_tool_spec do
    %{
      "name" => @assignment_release_tool,
      "title" => @assignment_release_tool,
      "description" => "Release only the current MCP session assignment binding and its matching current claim lease when available, without exposing secrets.",
      "inputSchema" => assignment_release_tool_input_schema()
    }
  end

  defp solo_tool_spec(name) do
    SoloTools.tool_spec(name)
  end

  defp bootstrap_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => bootstrap_tool_description(name),
      "inputSchema" => bootstrap_tool_input_schema(name)
    }
  end

  defp local_architect_assignment_claim_tool_spec do
    %{
      "name" => @local_architect_assignment_claim_tool,
      "title" => @local_architect_assignment_claim_tool,
      "description" => local_architect_assignment_claim_tool_description(),
      "inputSchema" => local_architect_assignment_claim_tool_input_schema()
    }
  end

  defp local_operator_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => local_operator_tool_description(name),
      "inputSchema" => local_operator_tool_input_schema(name)
    }
  end

  defp bootstrap_tool_description("create_work_request") do
    "Create a local Symphony++ WorkRequest with creator provenance and return a redacted architect handoff."
  end

  defp local_architect_assignment_claim_tool_description do
    "Claim or reconnect a ledger-backed local WorkRequest architect assignment without private handoff files."
  end

  defp local_operator_tool_description("add_work_request_comment") do
    "Append a redacted local-operator comment to a WorkRequest by id. Requires an unbound trusted local HTTP MCP session with an explicit state key and a file-backed local ledger; grants no dispatch or lifecycle authority."
  end

  defp local_operator_tool_description("record_work_request_operator_decision") do
    "Record a redacted local-operator decision on a WorkRequest by id. Requires an unbound trusted local HTTP MCP session with an explicit state key and a file-backed local ledger; does not require ownership of that WorkRequest."
  end

  defp architect_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => architect_tool_description(name),
      "inputSchema" => architect_tool_input_schema(name)
    }
  end

  defp architect_tool_description("read_child_status"), do: "Read the architect grant's scoped child work-package status without Phase 7 delegation."
  defp architect_tool_description("create_child_work_package"), do: "Create a phase-child work package inside the architect grant's current phase."
  defp architect_tool_description("mint_child_worker_key"), do: "Mint a narrower worker grant for a phase-child work package in the architect grant's current phase."
  defp architect_tool_description("revoke_child_worker_key"), do: "Revoke one live child-worker grant for a same-phase child package in the architect grant's current phase."
  defp architect_tool_description("list_work_requests"), do: "List WorkRequests scoped to the architect grant's repo and base branch."
  defp architect_tool_description("read_work_request"), do: "Read a scoped WorkRequest with clarification questions, decisions, visible WorkPackages, and status summaries."

  defp architect_tool_description("read_plan"),
    do: "Read the scoped WorkRequest execution graph, Groups, effective WorkPackage dependencies, and optional WorkPackage payloads."

  defp architect_tool_description("add_comment"), do: "Add a policy-scoped comment to a claimed WorkRequest descendant package surface, or a narrow external comment to a visible WorkRequest."
  defp architect_tool_description("list_comments"), do: "List comments attached to a scoped WorkRequest or WorkPackage."
  defp architect_tool_description("resolve_comment"), do: "Resolve a policy-scoped comment attached to a claimed WorkRequest descendant package surface."
  defp architect_tool_description("resolve_blocker"), do: "Resolve a blocker event for a policy-scoped descendant WorkPackage."
  defp architect_tool_description("read_delivery_board"), do: "Read the scoped WorkRequest delivery-board projection for visible work-package closeout without broad package visibility."
  defp architect_tool_description("reconcile_work_request"), do: "Dry-run or apply deterministic WorkRequest delivery closeout repairs from structured PR/GitHub evidence."

  defp architect_tool_description("record_work_package_delivery") do
    "Record an idempotent work-package delivery closeout. Required evidence depends on outcome: pr_merged needs PR evidence, completed_no_pr needs direct evidence, superseded needs successor and reason, and abandoned needs rationale. Use abandoned for cleaned no-code failed dispatches that never reached implementation. If the WorkPackage has active blockers, answer blocker_closeout to say whether those blockers are resolved or intentionally still active."
  end

  defp architect_tool_description(tool) when tool in ["cleanup_work_request_work_package_runtime", "revoke_work_package_worker_key"],
    do: delivery_runtime_tool_description(tool)

  defp architect_tool_description("list_guidance_requests"), do: "List package-scoped guidance requests visible to the architect grant's phase, repo, and base branch."
  defp architect_tool_description("read_guidance_request"), do: "Read one package-scoped guidance request visible to the architect grant."
  defp architect_tool_description("answer_guidance_request"), do: "Answer an open package-scoped guidance request."
  defp architect_tool_description("escalate_guidance_request"), do: "Escalate an open guidance request to human_info_needed and project it as an active package blocker."
  defp architect_tool_description("set_work_request_status"), do: "Move a scoped WorkRequest between valid statuses with optimistic current-status checking."
  defp architect_tool_description("ask_question"), do: "Add a clarification question to a scoped WorkRequest."
  defp architect_tool_description("answer_question"), do: "Answer an open clarification question that belongs to a scoped WorkRequest."
  defp architect_tool_description("answer_question_and_record_decision"), do: "Answer an open clarification question and atomically record the resulting WorkRequest decision."
  defp architect_tool_description("close_question"), do: "Close an open clarification question that belongs to a scoped WorkRequest without recording an answer."

  defp architect_tool_description("record_decision"),
    do: "Record a durable decision log entry on a scoped WorkRequest. source_type must be one of: #{Enum.join(DecisionLogEntry.source_types(), ", ")}."

  defp architect_tool_description("slice_work_request"),
    do: "Atomically slice the claimed WorkRequest into canonical WorkPackages."

  defp architect_tool_description("update_work_package"),
    do: "Update one canonical WorkPackage contract using its optimistic contract revision."

  defp architect_tool_description("upsert_group") do
    "Create, rename, reparent, or reorder an optional Group inside the claimed current WorkRequest. Groups organize WorkPackages and have no lifecycle."
  end

  defp architect_tool_description("delete_group"),
    do: "Remove a Group, move its direct child Groups and WorkPackages to its parent, and remove dependencies that name it."

  defp architect_tool_description("upsert_dependency"),
    do: "Create or edit one dependency intent between WorkPackage or Group endpoints; the backend derives effective WorkPackage edges."

  defp architect_tool_description("delete_dependency"), do: "Remove one dependency intent from the claimed current WorkRequest."

  defp architect_tool_description("skip_work_package") do
    "Skip a WorkPackage that belongs to the claimed current WorkRequest."
  end

  defp architect_tool_description("dispatch_work_package") do
    "Activate one planned WorkPackage and return its redacted ledger-backed worker claim bootstrap."
  end

  defp architect_tool_description("prepare_work_package_worktree") do
    "Prepare a scoped WorkPackage git worktree and record only its worktree_path."
  end

  defp architect_tool_description("cleanup_work_package_worktree") do
    "Clean up a scoped WorkPackage git worktree after validating the recorded path and dirty state."
  end

  defp architect_tool_description("approve_scope_expansion"), do: "Approve additional allowed file globs for this scoped work package."
  defp architect_tool_description("read_phase_board"), do: "Read the architect grant's scoped phase board."
  defp architect_tool_description("approve_child_ready_state"), do: "Approve a ready phase-child package for merge into the architect's phase."
  defp architect_tool_description("merge_child_into_phase"), do: "Record a local phase merge artifact and mark a phase child merged into the architect's phase."

  @spec solo_tool_input_schema(tool_name()) :: input_schema()
  defdelegate solo_tool_input_schema(name), to: InputSchemas

  @spec bootstrap_tool_input_schema(tool_name()) :: input_schema()
  defdelegate bootstrap_tool_input_schema(name), to: InputSchemas

  @spec local_operator_tool_input_schema(tool_name()) :: input_schema()
  defdelegate local_operator_tool_input_schema(name), to: InputSchemas

  @spec local_architect_assignment_claim_tool_input_schema() :: input_schema()
  defdelegate local_architect_assignment_claim_tool_input_schema(), to: InputSchemas

  @spec assignment_release_tool_input_schema() :: input_schema()
  defdelegate assignment_release_tool_input_schema(), to: InputSchemas

  @spec worker_tool_input_schema(tool_name()) :: input_schema()
  defdelegate worker_tool_input_schema(name), to: InputSchemas

  @spec architect_tool_input_schema(tool_name()) :: input_schema()
  defdelegate architect_tool_input_schema(name), to: InputSchemas

  @spec claimable_tool_specs(Config.t()) :: [tool_spec()]
  def claimable_tool_specs(%Config{} = config) do
    [health_tool_spec()] ++
      local_assignment_claim_tool_specs(config) ++
      local_architect_assignment_claim_tool_specs(config)
  end

  @spec unbound_tool_specs_for_config(Config.t()) :: [tool_spec()]
  def unbound_tool_specs_for_config(%Config{} = config) do
    [health_tool_spec(), assignment_release_tool_spec()] ++
      Enum.map(@solo_tools, &solo_tool_spec/1) ++
      unbound_scoped_tool_specs() ++
      local_assignment_claim_tool_specs(config) ++
      local_architect_assignment_claim_tool_specs(config) ++
      Enum.map(@bootstrap_tools, &bootstrap_tool_spec/1)
  end

  @spec startup_tool_specs(:full | :worker | :architect | :coordinator | :solo, Config.t()) :: [tool_spec()]
  def startup_tool_specs(:full, %Config{} = config), do: config |> unbound_tool_specs_for_config() |> lean_tool_specs()

  def startup_tool_specs(:worker, %Config{}) do
    [worker_tool_spec(@local_assignment_claim_tool) | worker_session_tool_specs()]
    |> lean_tool_specs()
  end

  def startup_tool_specs(:architect, %Config{}) do
    [local_architect_assignment_claim_tool_spec() | architect_session_tool_specs(current_work_request?: true)]
    |> lean_tool_specs()
  end

  def startup_tool_specs(profile, %Config{}) when profile in [:coordinator, :solo] do
    [health_tool_spec(), assignment_release_tool_spec() | Enum.map(@solo_tools, &solo_tool_spec/1)]
    |> lean_tool_specs()
  end

  defp local_assignment_claim_tool_specs(%Config{}), do: [worker_tool_spec(@local_assignment_claim_tool)]

  defp local_architect_assignment_claim_tool_specs(%Config{}), do: [local_architect_assignment_claim_tool_spec()]

  defp architect_tool_specs(current_work_request?), do: Enum.map(@architect_tools, &architect_tool_spec(&1, current_work_request?))

  @spec architect_session_tool_specs(keyword()) :: [tool_spec()]
  def architect_session_tool_specs(opts \\ []) do
    current_work_request? = Keyword.get(opts, :current_work_request?, false)

    [
      health_tool_spec(),
      assignment_release_tool_spec(),
      worker_tool_spec("get_current_assignment")
      | architect_tool_specs(current_work_request?)
    ]
  end

  @spec worker_session_tool_specs() :: [tool_spec()]
  def worker_session_tool_specs do
    [health_tool_spec(), assignment_release_tool_spec() | Enum.map(@worker_tools, &worker_tool_spec/1)]
  end

  defp unbound_scoped_tool_specs do
    Enum.map(@architect_tools -- @shared_worker_architect_tools, &unbound_architect_tool_spec/1) ++
      Enum.map(@worker_tools -- @shared_worker_architect_tools, &unbound_worker_tool_spec/1) ++
      Enum.map(@shared_worker_architect_tools, &shared_worker_architect_tool_spec/1)
  end

  defp architect_tool_spec(name, true), do: architect_tool_spec(name)
  defp architect_tool_spec(name, false), do: explicit_work_request_architect_tool_spec(name)

  defp explicit_work_request_architect_tool_spec(name) when name in @current_work_request_tools do
    spec = architect_tool_spec(name)

    spec
    |> Map.put("description", unbound_current_work_request_description(name))
    |> Map.put("inputSchema", InputSchemas.explicit_work_request_architect_tool_input_schema(name))
  end

  defp explicit_work_request_architect_tool_spec(name), do: architect_tool_spec(name)

  defp unbound_architect_tool_spec(name), do: explicit_work_request_architect_tool_spec(name)

  defp unbound_current_work_request_description(name) do
    name
    |> architect_tool_description()
    |> String.replace("the claimed current WorkRequest", "the explicit WorkRequest")
    |> String.replace("claimed current WorkRequest", "explicit WorkRequest")
  end

  defp shared_worker_architect_tool_spec(name), do: architect_tool_spec(name)

  @spec lean_tool_specs([tool_spec()]) :: [tool_spec()]
  def lean_tool_specs(specs), do: Enum.map(specs, &lean_tool_spec/1)

  defp lean_tool_spec(%{"name" => name, "description" => "Symphony++ worker tool " <> name_and_period} = spec) do
    if name_and_period == name <> ".", do: Map.drop(spec, ["title", "description"]), else: Map.delete(spec, "title")
  end

  defp lean_tool_spec(spec), do: Map.delete(spec, "title")

  @spec local_operator_tool_specs() :: [tool_spec()]
  def local_operator_tool_specs, do: Enum.map(@local_operator_tools, &local_operator_tool_spec/1)

  defp delivery_runtime_tool_description("cleanup_work_request_work_package_runtime"),
    do:
      "Recycle stale or superseded runtime authority for the WorkPackage linked to a scoped WorkRequest WorkPackage after superseded or abandoned delivery evidence is supplied. Revokes linked worker grants, releases non-paused local claim leases, clears recoverable worker MCP session bindings, and records audit evidence before delivery closeout."

  defp delivery_runtime_tool_description("revoke_work_package_worker_key"),
    do: "Revoke one live worker grant for the WorkPackage linked to a scoped WorkRequest WorkPackage during in-progress recycle or delivery closeout cleanup."
end
