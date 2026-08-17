defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog.SurfaceSpecs do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, SoloTools, ToolCatalog}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog.InputSchemas
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry

  @spec claimable_tool_specs(Config.t()) :: [ToolCatalog.tool_spec()]
  def claimable_tool_specs(%Config{} = config) do
    [health_tool_spec()] ++
      local_assignment_claim_tool_specs(config) ++
      local_architect_assignment_claim_tool_specs(config)
  end

  @spec callable_claim_tool_specs(Config.t()) :: [ToolCatalog.tool_spec()]
  def callable_claim_tool_specs(%Config{} = config) do
    introspection_tool_specs() ++ profile_claim_tool_specs(config)
  end

  @spec unbound_tool_specs_for_config(Config.t()) :: [ToolCatalog.tool_spec()]
  def unbound_tool_specs_for_config(%Config{} = config) do
    [health_tool_spec(), assignment_release_tool_spec()] ++
      Enum.map(ToolCatalog.solo_tools(), &SoloTools.tool_spec/1) ++
      unbound_scoped_tool_specs() ++
      local_assignment_claim_tool_specs(config) ++
      local_architect_assignment_claim_tool_specs(config) ++
      Enum.map(ToolCatalog.bootstrap_tools(), &bootstrap_tool_spec/1)
  end

  @spec callable_unbound_tool_specs_for_config(Config.t()) :: [ToolCatalog.tool_spec()]
  def callable_unbound_tool_specs_for_config(%Config{} = config) do
    introspection_tool_specs() ++
      unbound_profile_tool_specs(config) ++ Enum.map(ToolCatalog.bootstrap_tools(), &bootstrap_tool_spec/1)
  end

  @spec startup_tool_specs(:full | :worker | :architect | :coordinator | :solo, Config.t()) :: [ToolCatalog.tool_spec()]
  def startup_tool_specs(profile, %Config{} = config),
    do: config |> Map.put(:surface_profile, profile) |> callable_unbound_tool_specs_for_config() |> lean_tool_specs()

  defp introspection_tool_specs,
    do: [health_tool_spec(), assignment_release_tool_spec(), worker_tool_spec("get_current_assignment")]

  defp unbound_profile_tool_specs(%Config{surface_profile: profile}) when profile in [:coordinator, :solo],
    do: Enum.map(ToolCatalog.solo_tools(), &SoloTools.tool_spec/1)

  defp unbound_profile_tool_specs(%Config{surface_profile: :worker} = config), do: local_assignment_claim_tool_specs(config)
  defp unbound_profile_tool_specs(%Config{surface_profile: :architect} = config), do: local_architect_assignment_claim_tool_specs(config)

  defp unbound_profile_tool_specs(%Config{surface_profile: :full} = config) do
    Enum.map(ToolCatalog.solo_tools(), &SoloTools.tool_spec/1) ++ profile_claim_tool_specs(config)
  end

  defp profile_claim_tool_specs(%Config{surface_profile: :worker} = config), do: local_assignment_claim_tool_specs(config)
  defp profile_claim_tool_specs(%Config{surface_profile: :architect} = config), do: local_architect_assignment_claim_tool_specs(config)
  defp profile_claim_tool_specs(%Config{surface_profile: profile}) when profile in [:coordinator, :solo], do: []

  defp profile_claim_tool_specs(%Config{} = config),
    do: local_assignment_claim_tool_specs(config) ++ local_architect_assignment_claim_tool_specs(config)

  @spec architect_session_tool_specs(keyword()) :: [ToolCatalog.tool_spec()]
  def architect_session_tool_specs(opts) do
    current_work_request? = Keyword.get(opts, :current_work_request?, false)

    [
      health_tool_spec(),
      assignment_release_tool_spec(),
      worker_tool_spec("get_current_assignment")
      | Enum.map(ToolCatalog.architect_tools(), &architect_tool_spec(&1, current_work_request?))
    ]
  end

  @spec worker_session_tool_specs() :: [ToolCatalog.tool_spec()]
  def worker_session_tool_specs do
    [health_tool_spec(), assignment_release_tool_spec() | Enum.map(ToolCatalog.worker_tools(), &worker_tool_spec/1)]
  end

  @spec lean_tool_specs([ToolCatalog.tool_spec()]) :: [ToolCatalog.tool_spec()]
  def lean_tool_specs(specs), do: Enum.map(specs, &lean_tool_spec/1)

  @spec local_operator_tool_specs() :: [ToolCatalog.tool_spec()]
  def local_operator_tool_specs, do: Enum.map(ToolCatalog.local_operator_tools(), &local_operator_tool_spec/1)

  defp health_tool_spec do
    %{
      "name" => ToolCatalog.health_tool(),
      "title" => "Symphony++ health",
      "description" => "Returns server version, ledger reachability, and safe ledger identity without exposing package data.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    }
  end

  defp worker_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => "Symphony++ worker tool #{name}.",
      "inputSchema" => InputSchemas.worker_tool_input_schema(name)
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
    name = ToolCatalog.assignment_release_tool()

    %{
      "name" => name,
      "title" => name,
      "description" => "Release only the current MCP session assignment binding and its matching current claim lease when available, without exposing secrets.",
      "inputSchema" => InputSchemas.assignment_release_tool_input_schema()
    }
  end

  defp bootstrap_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => "Create a local Symphony++ WorkRequest with creator provenance and return a redacted architect handoff.",
      "inputSchema" => InputSchemas.bootstrap_tool_input_schema(name)
    }
  end

  defp local_architect_assignment_claim_tool_spec do
    name = ToolCatalog.local_architect_assignment_claim_tool()

    %{
      "name" => name,
      "title" => name,
      "description" => "Claim or reconnect a ledger-backed local WorkRequest architect assignment without private handoff files.",
      "inputSchema" => InputSchemas.local_architect_assignment_claim_tool_input_schema()
    }
  end

  defp local_operator_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => local_operator_tool_description(name),
      "inputSchema" => InputSchemas.local_operator_tool_input_schema(name)
    }
  end

  defp local_operator_tool_description("add_work_request_comment") do
    "Append a redacted local-operator comment to a WorkRequest by id. Requires an unbound trusted local HTTP MCP session with an explicit state key and a file-backed local ledger; grants no dispatch or lifecycle authority."
  end

  defp local_operator_tool_description("record_work_request_operator_decision") do
    "Record a redacted local-operator decision on a WorkRequest by id. Requires an unbound trusted local HTTP MCP session with an explicit state key and a file-backed local ledger; does not require ownership of that WorkRequest."
  end

  defp local_operator_tool_description("summarize_failed_mcp_calls") do
    "Summarize process-local redacted failed MCP call envelopes without exposing raw requests or durable history. Requires an unbound trusted local HTTP MCP session."
  end

  defp unbound_scoped_tool_specs do
    shared = ToolCatalog.shared_worker_architect_tools()

    Enum.map(ToolCatalog.architect_tools() -- shared, &explicit_work_request_architect_tool_spec/1) ++
      Enum.map(ToolCatalog.worker_tools() -- shared, &unbound_worker_tool_spec/1) ++
      Enum.map(shared, &architect_tool_spec/1)
  end

  defp architect_tool_spec(name, true), do: architect_tool_spec(name)
  defp architect_tool_spec(name, false), do: explicit_work_request_architect_tool_spec(name)

  defp explicit_work_request_architect_tool_spec(name) do
    spec = architect_tool_spec(name)

    if ToolCatalog.current_work_request_tool?(name) do
      spec
      |> Map.put("description", unbound_current_work_request_description(name))
      |> Map.put("inputSchema", InputSchemas.explicit_work_request_architect_tool_input_schema(name))
    else
      spec
    end
  end

  defp unbound_current_work_request_description(name) do
    name
    |> architect_tool_description()
    |> String.replace("the claimed current WorkRequest", "the explicit WorkRequest")
    |> String.replace("claimed current WorkRequest", "explicit WorkRequest")
  end

  defp lean_tool_spec(%{"name" => name, "description" => "Symphony++ worker tool " <> name_and_period} = spec) do
    if name_and_period == name <> ".", do: Map.drop(spec, ["title", "description"]), else: Map.delete(spec, "title")
  end

  defp lean_tool_spec(spec), do: Map.delete(spec, "title")

  defp local_assignment_claim_tool_specs(%Config{}), do: [worker_tool_spec(ToolCatalog.local_assignment_claim_tool())]
  defp local_architect_assignment_claim_tool_specs(%Config{}), do: [local_architect_assignment_claim_tool_spec()]

  defp architect_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => architect_tool_description(name),
      "inputSchema" => InputSchemas.architect_tool_input_schema(name)
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

  defp architect_tool_description("accept_review_rework") do
    "Accept one verified typed changes-required finding for an ordinary ready-for-merge WorkPackage's current attached PR and exact head, preserve immutable evidence, and atomically return it to active rework."
  end

  defp architect_tool_description("record_work_package_delivery") do
    "Record an idempotent work-package delivery closeout. Required evidence depends on outcome: pr_merged needs PR evidence, completed_no_pr needs direct evidence, superseded needs successor and reason, and abandoned needs rationale. Use abandoned for cleaned no-code failed dispatches that never reached implementation. Terminal delivery clears any active blocker residue."
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

  defp architect_tool_description("slice_work_request"), do: "Atomically slice the claimed WorkRequest into canonical WorkPackages."
  defp architect_tool_description("update_work_package"), do: "Update one canonical WorkPackage contract using its optimistic contract revision."

  defp architect_tool_description("upsert_group") do
    "Create, rename, reparent, or reorder an optional Group inside the claimed current WorkRequest. Groups organize WorkPackages and have no lifecycle."
  end

  defp architect_tool_description("delete_group"),
    do: "Remove a Group, move its direct child Groups and WorkPackages to its parent, and remove dependencies that name it."

  defp architect_tool_description("upsert_dependency"),
    do: "Create or edit one dependency intent between WorkPackage or Group endpoints; the backend derives effective WorkPackage edges."

  defp architect_tool_description("delete_dependency"), do: "Remove one dependency intent from the claimed current WorkRequest."
  defp architect_tool_description("skip_work_package"), do: "Skip a WorkPackage that belongs to the claimed current WorkRequest."
  defp architect_tool_description("dispatch_work_package"), do: "Activate one planned WorkPackage and return its redacted ledger-backed worker claim bootstrap."
  defp architect_tool_description("prepare_work_package_worktree"), do: "Prepare a scoped WorkPackage git worktree and record only its worktree_path."
  defp architect_tool_description("cleanup_work_package_worktree"), do: "Clean up a scoped WorkPackage git worktree after validating the recorded path and dirty state."
  defp architect_tool_description("approve_scope_expansion"), do: "Approve additional allowed file globs for this scoped work package."
  defp architect_tool_description("read_phase_board"), do: "Read the architect grant's scoped phase board."
  defp architect_tool_description("approve_child_ready_state"), do: "Approve a ready phase-child package for merge into the architect's phase."
  defp architect_tool_description("merge_child_into_phase"), do: "Record a local phase merge artifact and mark a phase child merged into the architect's phase."

  defp delivery_runtime_tool_description("cleanup_work_request_work_package_runtime"),
    do:
      "Recycle stale or superseded runtime authority for the WorkPackage linked to a scoped WorkRequest WorkPackage after superseded or abandoned delivery evidence is supplied. Revokes linked worker grants, releases non-paused local claim leases, clears recoverable worker MCP session bindings, and records audit evidence before delivery closeout."

  defp delivery_runtime_tool_description("revoke_work_package_worker_key"),
    do: "Revoke one live worker grant for the WorkPackage linked to a scoped WorkRequest WorkPackage during in-progress recycle or delivery closeout cleanup."
end
