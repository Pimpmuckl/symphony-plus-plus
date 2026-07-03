defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Server do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.ArchitectContext
  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.ActorResolver
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Policy
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Target
  alias SymphonyElixir.SymphonyPlusPlus.BranchPattern
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Service, as: CommentService
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.MetadataProjection
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{Client, DryClient, PullRequest, PullRequestArtifact}
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Service, as: GuidanceRequestService
  alias SymphonyElixir.SymphonyPlusPlus.HumanDecisionPrompt
  alias SymphonyElixir.SymphonyPlusPlus.Id
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Auth,
    ClaimToolText,
    Config,
    CurrentWorkRequest,
    HandleStateStore,
    LocalArchitectGrantClaim,
    LocalClaimLeases,
    LocalTrustedTools,
    PlannedSliceWorkerRevoke,
    Repository,
    Session,
    SoloTools,
    ToolCatalog
  }

  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer, as: PlanningRenderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.{Node, SliceLink}
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ReviewLanes
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.ReviewProfiles
  alias SymphonyElixir.SymphonyPlusPlus.ReviewSuiteRounds
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Service, as: WorkPackageService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreePath
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeTargetRoot
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryReconciler
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDispatch
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceLinkage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.RuntimeCleanup, as: WorkRequestRuntimeCleanup
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ScopeConstraints
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @protocol_version "2025-03-26"
  @health_tool ToolCatalog.health_tool()
  @mcp_contract_schema_version ToolCatalog.mcp_contract_schema_version()
  @mcp_contract_health_fields ToolCatalog.mcp_contract_health_fields()
  @agent_text_mime_type "text/vnd.toon"
  @solo_tools ToolCatalog.solo_tools()
  @assignment_release_tool ToolCatalog.assignment_release_tool()
  @bootstrap_tools ToolCatalog.bootstrap_tools()
  @local_operator_tools ToolCatalog.local_operator_tools()
  @local_trusted_work_request_read_tools [
    "list_work_requests",
    "read_work_request",
    "read_work_request_product_tree",
    "read_work_request_delivery_board"
  ]
  @blocker_closeout_decisions ToolCatalog.blocker_closeout_decisions()
  @complete_plan_statuses ["done", "completed", "skipped"]
  @terminal_product_tree_completion_marks ["done", "deferred"]
  @terminal_work_package_statuses ["merged", "merged_into_phase", "closed", "abandoned"]
  @local_assignment_claim_tool ToolCatalog.local_assignment_claim_tool()
  @local_architect_assignment_claim_tool ToolCatalog.local_architect_assignment_claim_tool()
  @session_claim_tools ToolCatalog.session_claim_tools()
  @worker_tools ToolCatalog.worker_tools()
  @architect_tools ToolCatalog.architect_tools()
  @work_request_policy_tools ToolCatalog.work_request_policy_tools()
  @delivery_policy_tools ToolCatalog.delivery_policy_tools()
  @work_request_product_tree_views ToolCatalog.work_request_product_tree_views()
  @phase7_stub_architect_tools ToolCatalog.phase7_stub_architect_tools()
  @review_promotable_work_package_statuses ["ready_for_worker", "claimed", "planning", "implementing"]
  @child_work_package_keys [
    "acceptance_criteria",
    "allowed_file_globs",
    "base_branch",
    "branch_pattern",
    "engineering_scope",
    "id",
    "kind",
    "owner_id",
    "parent_id",
    "phase_id",
    "policy_template",
    "product_description",
    "repo",
    "status",
    "title"
  ]
  @child_worker_template_keys ["capabilities", "expires_at", "claimed_by"]
  @child_worker_capabilities ["worker:claim", "worker:lifecycle.transition"]
  @child_worker_ready_status "ready_for_worker"
  @child_worker_resettable_statuses ["claimed", "planning", "implementing", "reviewing", "ci_waiting", "blocked"]
  @child_worker_recyclable_statuses [@child_worker_ready_status | @child_worker_resettable_statuses]
  @child_worker_grant_provenance "child_worker_delegation"
  @version_resource "sympp://health/version"
  @assignment_resource "sympp://assignment/current"
  @finding_replay_retry_attempts 50
  @local_assignment_claim_stale_after_ms :timer.minutes(5)
  @scope_guard_gate "scope_guard"
  @plan_append_argument_keys ["body", "expected_version", "id", "status", "title", "work_package_id"]
  @plan_patch_argument_keys ["expected_version", "patch", "work_package_id"]
  @plan_node_patch_keys ["body", "id", "status", "title"]
  @enforce_keys [:config]
  defstruct [
    :config,
    :session,
    :state_key,
    :state_key_version,
    local_daemon_trusted: false,
    state_key_explicit: false,
    session_refresh_required: false,
    initialized: false
  ]

  @type t :: %__MODULE__{
          config: Config.t(),
          session: Session.t() | nil,
          state_key: term(),
          state_key_version: integer() | nil,
          local_daemon_trusted: boolean(),
          state_key_explicit: boolean(),
          session_refresh_required: boolean(),
          initialized: boolean()
        }

  defguardp valid_request_id(id) when is_binary(id) or is_number(id) or is_nil(id)
  defguardp invalid_request_id(id) when not is_binary(id) and not is_number(id) and not is_nil(id)

  @spec new(Config.t(), keyword()) :: t()
  def new(%Config{} = config, opts \\ []) do
    {state_key, state_key_explicit?} = state_key_option(opts)

    %__MODULE__{
      config: config,
      session: Keyword.get(opts, :session),
      state_key: state_key,
      state_key_version: nil,
      local_daemon_trusted: Keyword.get(opts, :local_daemon_trusted, config.local_daemon_trusted),
      state_key_explicit: state_key_explicit?,
      session_refresh_required: false,
      initialized: Keyword.get(opts, :initialized, false)
    }
  end

  defp state_key_option(opts) do
    case Keyword.fetch(opts, :state_key) do
      {:ok, state_key} -> explicit_state_key_option(state_key)
      :error -> {make_ref(), false}
    end
  end

  defp explicit_state_key_option(nil), do: {make_ref(), false}

  defp explicit_state_key_option(state_key) when is_binary(state_key) do
    if String.trim(state_key) == "", do: {make_ref(), false}, else: {state_key, true}
  end

  defp explicit_state_key_option(state_key), do: {state_key, true}

  @spec handle(term(), t()) :: map() | [map()] | nil
  def handle(payload, %__MODULE__{} = server) do
    payload
    |> handle_response_state(server)
    |> elem(0)
  end

  @doc false
  @spec mcp_contract_identity() :: map()
  def mcp_contract_identity do
    %{
      "fingerprint" => mcp_contract_fingerprint(mcp_contract_material()),
      "schema_version" => @mcp_contract_schema_version
    }
  end

  @doc false
  @spec handle_response_state(term(), t()) :: {map() | [map()] | nil, t()}
  def handle_response_state(payload, %__MODULE__{} = server) do
    HandleStateStore.cleanup_default_handle_states()
    server = HandleStateStore.restore(payload, server)
    {response, updated_server} = handle_state(payload, server)
    updated_server = HandleStateStore.persist(payload, response, server, updated_server)
    {response, updated_server}
  end

  @spec handle_state(term(), t()) :: {map() | [map()] | nil, t()}
  def handle_state(%{"jsonrpc" => "2.0", "method" => "initialize"} = payload, %__MODULE__{} = server) do
    response = do_handle(payload, server)

    case response do
      %{"result" => _result} -> {response, %{server | initialized: true}}
      _response -> {response, server}
    end
  end

  def handle_state(payloads, %__MODULE__{} = server) when is_list(payloads) do
    cond do
      payloads == [] ->
        {error_response(nil, -32_600, "Invalid Request", %{"reason" => "empty_batch"}), server}

      Enum.any?(payloads, &initialize_request?/1) ->
        {error_response(nil, -32_600, "Invalid Request", %{"reason" => "initialize_must_be_standalone"}), server}

      true ->
        handle_batch(payloads, server)
    end
  end

  def handle_state(
        %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call"} = payload,
        %__MODULE__{initialized: true} = server
      )
      when valid_request_id(id) do
    payload
    |> request_params()
    |> handle_tool_call_request(id, server)
  end

  def handle_state(%{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call"} = payload, %__MODULE__{initialized: true} = server)
      when invalid_request_id(id) do
    {do_handle(payload, server), server}
  end

  def handle_state(%{"jsonrpc" => "2.0", "method" => "tools/call"} = payload, %__MODULE__{initialized: true} = server) do
    payload
    |> request_params()
    |> handle_tool_call_notification(server)
  end

  def handle_state(%{"jsonrpc" => "2.0", "id" => id, "method" => method} = payload, %__MODULE__{initialized: true} = server)
      when is_binary(method) and valid_request_id(id) do
    payload
    |> request_params()
    |> dispatch_request_state(method, id, server)
  end

  def handle_state(payload, %__MODULE__{} = server), do: {do_handle(payload, server), server}

  defp handle_tool_call_request({:ok, %{"name" => name} = params}, id, %__MODULE__{} = server) when name in @session_claim_tools,
    do: handle_session_claim_tool(name, params, id, server)

  defp handle_tool_call_request({:ok, %{"name" => @assignment_release_tool} = params}, id, %__MODULE__{} = server),
    do: handle_assignment_release_tool(params, id, server)

  defp handle_tool_call_request(params_result, id, %__MODULE__{} = server),
    do: dispatch_request_state(params_result, "tools/call", id, server)

  defp handle_tool_call_notification({:ok, %{"name" => name} = params}, %__MODULE__{} = server) when name in @session_claim_tools,
    do: handle_session_claim_tool_notification(name, params, server)

  defp handle_tool_call_notification({:ok, %{"name" => @assignment_release_tool} = params}, %__MODULE__{} = server),
    do: handle_assignment_release_tool_notification(params, server)

  defp handle_tool_call_notification(params_result, %__MODULE__{} = server),
    do: {nil, dispatch_notification(params_result, "tools/call", server)}

  defp do_handle([], %__MODULE__{}) do
    error_response(nil, -32_600, "Invalid Request", %{"reason" => "empty_batch"})
  end

  defp do_handle(payloads, %__MODULE__{} = server) when is_list(payloads) do
    if Enum.any?(payloads, &initialize_request?/1) do
      error_response(nil, -32_600, "Invalid Request", %{"reason" => "initialize_must_be_standalone"})
    else
      handle_batch(payloads, server)
      |> elem(0)
    end
  end

  defp do_handle(%{"id" => id}, %__MODULE__{}) when invalid_request_id(id) do
    error_response(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id}, %__MODULE__{}) when invalid_request_id(id) do
    error_response(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => method}, %__MODULE__{initialized: false})
       when is_binary(method) and method != "initialize" and valid_request_id(id) do
    error_response(id, -32_000, "Server error", %{"reason" => "server_not_initialized"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => "initialize"}, %__MODULE__{initialized: true})
       when valid_request_id(id) do
    error_response(id, -32_600, "Invalid Request", %{"reason" => "already_initialized"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => method} = request, %__MODULE__{} = server)
       when is_binary(method) and valid_request_id(id) do
    request
    |> request_params()
    |> dispatch_request(method, id, server)
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => _id, "method" => method}, %__MODULE__{}) when is_binary(method) do
    error_response(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => _method}, %__MODULE__{}) when valid_request_id(id) do
    error_response(id, -32_600, "Invalid Request", %{"reason" => "invalid_method"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "method" => "initialize"}, %__MODULE__{}) do
    error_response(nil, -32_600, "Invalid Request", %{"reason" => "initialize_requires_id"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "method" => method} = notification, %__MODULE__{}) when is_binary(method) do
    if Map.has_key?(notification, "id") do
      error_response(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
    end
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id}, %__MODULE__{}) when valid_request_id(id) do
    error_response(id, -32_600, "Invalid Request", %{"reason" => "missing_method"})
  end

  defp do_handle(%{"jsonrpc" => version, "id" => id}, %__MODULE__{}) when version != "2.0" and valid_request_id(id) do
    error_response(id, -32_600, "Invalid Request", %{"reason" => "invalid_jsonrpc_version"})
  end

  defp do_handle(%{"jsonrpc" => version}, %__MODULE__{}) when version != "2.0" do
    error_response(nil, -32_600, "Invalid Request", %{"reason" => "invalid_jsonrpc_version"})
  end

  defp do_handle(%{"id" => id, "method" => method}, %__MODULE__{}) when is_binary(method) do
    error_response(id, -32_600, "Invalid Request", %{"reason" => "invalid_jsonrpc_version"})
  end

  defp do_handle(%{"id" => id, "method" => _method}, %__MODULE__{}) when valid_request_id(id) do
    error_response(id, -32_600, "Invalid Request", %{"reason" => "invalid_method"})
  end

  defp do_handle(%{"id" => id}, %__MODULE__{}) do
    error_response(id, -32_600, "Invalid Request", %{"reason" => "missing_method"})
  end

  defp do_handle(_payload, %__MODULE__{}) do
    error_response(nil, -32_600, "Invalid Request", %{"reason" => "request_must_be_object"})
  end

  defp handle_batch(payloads, %__MODULE__{} = server) do
    {items, {_claimed?, updated_server, claimed_server}} =
      Enum.map_reduce(payloads, {false, server, nil}, &handle_batch_claim_state/2)

    responses =
      items
      |> Enum.map(fn {_payload, {response, _server}} -> response end)
      |> Enum.reject(&is_nil/1)

    {if(responses == [], do: nil, else: responses), claimed_server || updated_server}
  end

  defp handle_batch_claim_state(payload, {true, %__MODULE__{} = current_server, claimed_server} = claim_state) do
    if batch_session_claim_request?(payload, current_server) do
      item = handle_batch_item(payload, claimed_server || current_server)
      {_response, %__MODULE__{} = item_server} = item

      claimed_server =
        if batch_session_claim_success?(item, claimed_server || current_server),
          do: item_server,
          else: claimed_server

      {{payload, item}, {true, current_server, claimed_server}}
    else
      handle_unblocked_batch_item(payload, claim_state)
    end
  end

  defp handle_batch_claim_state(payload, claim_state) do
    handle_unblocked_batch_item(payload, claim_state)
  end

  defp handle_unblocked_batch_item(payload, {claimed?, %__MODULE__{} = current_server, claimed_server}) do
    item = handle_batch_item(payload, current_server)
    {_response, %__MODULE__{} = item_server} = item

    claim_succeeded? =
      batch_session_claim_request?(payload, current_server) and batch_session_claim_success?(item, current_server)

    updated_server =
      if claim_succeeded? do
        current_server
      else
        if batch_server_state_changed?(current_server, item_server), do: item_server, else: current_server
      end

    claimed_server = if claim_succeeded?, do: item_server, else: claimed_server

    {{payload, item}, {claimed? or claim_succeeded?, updated_server, claimed_server}}
  end

  defp batch_server_state_changed?(%__MODULE__{} = server, %__MODULE__{} = updated_server) do
    server.initialized != updated_server.initialized or
      server.session != updated_server.session or
      server.session_refresh_required != updated_server.session_refresh_required
  end

  defp batch_session_claim_success?(
         {%{"result" => %{"structuredContent" => %{"assignment" => _assignment}}}, %__MODULE__{}},
         %__MODULE__{}
       ),
       do: true

  defp batch_session_claim_success?({nil, %__MODULE__{session: %Session{} = updated_session}}, %__MODULE__{session: original_session}) do
    original_session == nil or updated_session != original_session
  end

  defp batch_session_claim_success?(_item, %__MODULE__{}), do: false

  defp batch_session_claim_request?(
         %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => name}},
         %__MODULE__{initialized: true}
       )
       when name in @session_claim_tools and valid_request_id(id),
       do: true

  defp batch_session_claim_request?(%{"jsonrpc" => "2.0", "id" => _id, "method" => "tools/call"}, %__MODULE__{initialized: true}),
    do: false

  defp batch_session_claim_request?(
         %{"jsonrpc" => "2.0", "method" => "tools/call", "params" => %{"name" => name}},
         %__MODULE__{initialized: true}
       )
       when name in @session_claim_tools,
       do: true

  defp batch_session_claim_request?(_payload, %__MODULE__{}), do: false

  defp dispatch(
         "initialize",
         %{"protocolVersion" => protocol_version, "clientInfo" => client_info, "capabilities" => capabilities},
         %__MODULE__{config: config}
       )
       when is_binary(protocol_version) and is_map(client_info) and is_map(capabilities) do
    {:ok,
     %{
       "protocolVersion" => @protocol_version,
       "capabilities" => %{
         "tools" => %{},
         "resources" => %{}
       },
       "serverInfo" => %{
         "name" => "symphony-plus-plus",
         "version" => config.version
       }
     }}
  end

  defp dispatch(
         "initialize",
         %{"protocolVersion" => protocol_version, "clientInfo" => client_info, "capabilities" => capabilities},
         _server
       )
       when is_binary(protocol_version) and (not is_map(client_info) or not is_map(capabilities)) do
    {:error, -32_602, "Invalid params", %{"reason" => "invalid_initialize_params"}}
  end

  defp dispatch("initialize", %{"protocolVersion" => protocol_version}, _server) when is_binary(protocol_version) do
    {:error, -32_602, "Invalid params", %{"reason" => "invalid_initialize_params"}}
  end

  defp dispatch("initialize", params, _server) when not is_map(params) do
    {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}
  end

  defp dispatch("initialize", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "missing_protocol_version", "supported" => @protocol_version}}
  end

  defp dispatch("tools/list", params, %__MODULE__{} = server) when is_map(params) do
    case tool_specs_for_server(server) do
      {:ok, tools} -> {:ok, %{"tools" => tools}}
      {:error, reason} -> worker_error(reason, "tools/list")
    end
  end

  defp dispatch("tools/list", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}
  end

  defp dispatch("tools/call", %{"name" => @health_tool} = params, %__MODULE__{} = server) do
    case Map.get(params, "arguments", %{}) do
      arguments when arguments == %{} ->
        result = health(server)

        {:ok, tool_result(result)}

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => @health_tool, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when name in @solo_tools do
    with :ok <- authorize_solo_tool_call(server, name),
         {:ok, arguments} <- solo_tool_arguments(params, name) do
      solo_tool(name, arguments, server)
    else
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => @local_assignment_claim_tool} = params, %__MODULE__{} = server) do
    case claim_local_assignment(params, server) do
      {:ok, result, session} ->
        {:ok, claim_tool_result(result), %{server | session: session, session_refresh_required: false}}

      {:error, code, message, data} ->
        {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => @local_architect_assignment_claim_tool} = params, %__MODULE__{} = server) do
    case claim_local_architect_assignment(params, server) do
      {:ok, result, session} ->
        {:ok, claim_tool_result(result), %{server | session: session, session_refresh_required: false}}

      {:error, code, message, data} ->
        {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => @assignment_release_tool} = params, %__MODULE__{} = server) do
    with {:ok, arguments} <- prepare_assignment_release_tool_call(server, params),
         {:ok, result, updated_server} <- release_current_assignment(arguments, server) do
      {:ok, release_tool_result(result), updated_server}
    else
      {:error, code, message, data} -> {:error, code, message, data}
      {:tool_error, reason} -> invalid_params_error(@assignment_release_tool, reason)
    end
  end

  defp dispatch("tools/call", %{"name" => "create_work_request"} = params, %__MODULE__{} = server) do
    case prepare_bootstrap_tool_call(server, params, "create_work_request") do
      {:ok, arguments} -> bootstrap_tool("create_work_request", arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when name in @local_operator_tools do
    case prepare_local_operator_tool_call(server, params, name) do
      {:ok, arguments} -> local_operator_tool(name, arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> local_operator_error(reason, name)
    end
  end

  defp dispatch(
         "tools/call",
         %{"name" => "read_guidance_request"} = params,
         %__MODULE__{session: %Session{assignment: %{grant_role: "architect"}}} = server
       ) do
    case prepare_architect_tool_call(server, params, "read_guidance_request") do
      {:ok, arguments} -> read_guidance_request_tool(arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "read_guidance_request")
    end
  end

  defp dispatch("tools/call", %{"name" => "read_guidance_request"} = params, %__MODULE__{session: nil} = server) do
    case prepare_architect_tool_call(server, params, "read_guidance_request") do
      {:ok, arguments} -> read_guidance_request_tool(arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "read_guidance_request")
    end
  end

  defp dispatch("tools/call", %{"name" => "read_guidance_request"} = params, %__MODULE__{} = server) do
    case prepare_worker_tool_call(server, params, "read_guidance_request") do
      {:ok, arguments} -> read_guidance_request_tool(arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> worker_error(reason, "read_guidance_request")
    end
  end

  defp dispatch("tools/call", %{"name" => "list_comments"} = params, %__MODULE__{session: %Session{}} = server) do
    dispatch_scoped_list_comments(params, server)
  end

  defp dispatch("tools/call", %{"name" => "list_comments"} = params, %__MODULE__{} = server) do
    if local_trusted_tools_enabled?(server) do
      case prepare_local_trusted_list_comments_tool_call(server, params) do
        {:ok, arguments} -> local_trusted_list_comments_tool(arguments, server)
        {:error, code, message, data} -> {:error, code, message, data}
      end
    else
      dispatch_scoped_list_comments(params, server)
    end
  end

  defp dispatch(
         "tools/call",
         %{"name" => name} = params,
         %__MODULE__{session: %Session{assignment: %{grant_role: "architect"}}} = server
       )
       when name in ["add_comment", "resolve_comment", "resolve_blocker"] do
    case prepare_architect_tool_call(server, params, name) do
      {:ok, arguments} -> architect_tool(name, arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, name)
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when name in @worker_tools do
    case prepare_worker_tool_call(server, params, name) do
      {:ok, arguments} -> worker_tool(name, arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> worker_error(reason, name)
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when name in @architect_tools do
    case prepare_architect_tool_call(server, params, name) do
      {:ok, arguments} -> architect_tool(name, arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, name)
    end
  end

  defp dispatch("tools/call", %{"name" => name}, _server) when is_binary(name) do
    {:error, -32_601, "Method not found", %{"tool" => name}}
  end

  defp dispatch("tools/call", params, _server) when is_map(params) do
    {:error, -32_602, "Invalid params", %{"reason" => "missing_tool_name"}}
  end

  defp dispatch("tools/call", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}
  end

  defp dispatch("resources/list", params, %__MODULE__{config: config, session: session}) when is_map(params) do
    case assignment_resources(session, config.repo) do
      {:ok, resources} -> {:ok, %{"resources" => base_resource_specs() ++ resources}}
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("resources/list", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}
  end

  defp dispatch("resources/read", %{"uri" => @version_resource}, %__MODULE__{config: %Config{} = config}) do
    payload = %{
      "version" => config.version,
      "source" => source_identity(config),
      "mode" => Atom.to_string(config.mode)
    }

    {:ok, json_resource(@version_resource, payload)}
  end

  defp dispatch("resources/read", %{"uri" => @assignment_resource}, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         :ok <- require_assignment_introspection(session.assignment) do
      {:ok, json_resource(@assignment_resource, Session.public_assignment(session))}
    else
      {:error, :unsupported_grant_role} -> auth_error({:unauthorized, :unsupported_grant_role}, @assignment_resource)
      {:error, reason} -> auth_error(reason, @assignment_resource)
    end
  end

  defp dispatch("resources/read", %{"uri" => "sympp://work-packages/" <> rest = uri}, %__MODULE__{
         config: config,
         session: session
       }) do
    case work_package_resource_id(rest) do
      {:ok, work_package_id, file_name} ->
        read_work_package_virtual_resource(config.repo, session, work_package_id, file_name, uri)

      :error ->
        {:error, -32_602, "Invalid params", %{"resource" => uri, "reason" => "invalid_work_package_resource_uri"}}
    end
  end

  defp dispatch("resources/read", %{"uri" => uri}, _server) when is_binary(uri) do
    {:error, -32_601, "Method not found", %{"resource" => uri}}
  end

  defp dispatch("resources/read", params, _server) when not is_map(params) do
    {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}
  end

  defp dispatch("resources/read", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "missing_resource_uri"}}
  end

  defp dispatch(_method, _params, _server) do
    {:error, -32_601, "Method not found", %{}}
  end

  defp dispatch_scoped_list_comments(params, %__MODULE__{session: %Session{assignment: %{grant_role: "architect"}}} = server) do
    case prepare_architect_tool_call(server, params, "list_comments") do
      {:ok, arguments} -> architect_tool("list_comments", arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "list_comments")
    end
  end

  defp dispatch_scoped_list_comments(params, %__MODULE__{session: nil} = server) do
    case prepare_architect_tool_call(server, params, "list_comments") do
      {:ok, arguments} -> architect_tool("list_comments", arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "list_comments")
    end
  end

  defp dispatch_scoped_list_comments(params, %__MODULE__{} = server) do
    case prepare_worker_tool_call(server, params, "list_comments") do
      {:ok, arguments} -> worker_tool("list_comments", arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> worker_error(reason, "list_comments")
    end
  end

  defp health(%__MODULE__{config: %Config{health_ledger_mode: :configured_identity} = config}) do
    ledger = configured_identity_ledger_health(config)

    %{
      "status" => if(ledger["reachable"], do: "ok", else: "degraded"),
      "version" => config.version,
      "source" => source_identity(config),
      "mode" => Atom.to_string(config.mode),
      "ledger" => ledger
    }
  end

  defp health(%__MODULE__{config: %Config{} = config}) do
    ledger = ledger_health(config)

    %{
      "status" => if(ledger["reachable"], do: "ok", else: "degraded"),
      "version" => config.version,
      "source" => source_identity(config),
      "mode" => Atom.to_string(config.mode),
      "ledger" => ledger
    }
  end

  defp source_identity(%Config{source_revision: revision}) when is_binary(revision) and revision != "" do
    %{"revision" => String.downcase(revision), "mcp_contract" => mcp_contract_identity()}
  end

  defp source_identity(%Config{}), do: %{"revision" => nil, "mcp_contract" => mcp_contract_identity()}

  defp mcp_contract_material do
    config = %Config{mode: :http, repo: Repo, version: "contract", source_revision: nil}

    %{
      "capabilities" => %{
        "resources" => %{},
        "tools" => %{}
      },
      "health_result_fields" => @mcp_contract_health_fields,
      "client_lease_protocol" => 1,
      "protocol_version" => @protocol_version,
      "resources" => resource_contract_material(),
      "schema_version" => @mcp_contract_schema_version,
      "tool_sets" => %{
        "architect" => ToolCatalog.architect_session_tool_specs(current_work_request?: false),
        "architect_current_work_request" => ToolCatalog.architect_session_tool_specs(current_work_request?: true),
        "claimable" => claimable_tool_specs(config),
        "local_operator" => LocalTrustedTools.tool_specs(config),
        "unbound" => hide_trusted_local_tool_specs(unbound_tool_specs_for_config(config)),
        "worker" => worker_session_tool_specs()
      }
    }
  end

  defp resource_contract_material do
    %{
      "list_sets" => %{
        "architect" => base_resource_specs() ++ current_assignment_resource_specs(),
        "unbound" => base_resource_specs(),
        "worker" => base_resource_specs() ++ current_assignment_resource_specs() ++ work_package_resource_template_specs()
      },
      "read_payloads" => %{
        @assignment_resource => %{
          "fields" => Session.public_assignment_fields(),
          "mimeType" => "application/json"
        },
        @version_resource => %{
          "fields" => [
            "mode",
            "source.mcp_contract.fingerprint",
            "source.mcp_contract.schema_version",
            "source.revision",
            "version"
          ],
          "mimeType" => "application/json"
        },
        "sympp://work-packages/{work_package_id}/{file_name}" => %{
          "file_names" => PlanningRenderer.virtual_files(),
          "mimeType" => "text/markdown"
        }
      }
    }
  end

  defp mcp_contract_fingerprint(material) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(canonical_contract_term(material)))
    |> Base.encode16(case: :lower)
  end

  defp canonical_contract_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical_contract_term(nested)} end)
    |> Enum.sort_by(fn {key, _nested} -> key end)
  end

  defp canonical_contract_term(value) when is_list(value), do: Enum.map(value, &canonical_contract_term/1)
  defp canonical_contract_term(value), do: value

  defp ledger_health(%Config{repo: repo, database: database}) do
    case normalized_database(database) do
      nil -> default_ledger_health(repo)
      database -> configured_ledger_health(repo, database)
    end
  end

  defp configured_identity_ledger_health(%Config{repo: repo, database: database}) do
    case normalized_database(database) do
      nil -> configured_identity_default_ledger_health(repo)
      database -> configured_identity_database_ledger_health(database, "explicit")
    end
  end

  defp configured_identity_default_ledger_health(repo) do
    case repo_configured_database_for_identity(repo) || default_repo_database_for_identity(repo) do
      database when is_binary(database) -> configured_identity_database_ledger_health(database, "default")
      _database -> unavailable_ledger_health(unknown_ledger_identity("default"))
    end
  end

  defp default_repo_database_for_identity(Repo), do: Repo.database_path_if_present() || Repo.database_path_without_side_effects()
  defp default_repo_database_for_identity(_repo), do: nil

  defp configured_identity_database_ledger_health(database, source) do
    case configured_ledger(database, source) do
      {:sqlite, ":memory:", identity} ->
        %{"reachable" => true, "identity" => identity}

      {:sqlite, path, identity} when is_binary(path) ->
        if File.exists?(Path.expand(path)) do
          %{"reachable" => true, "identity" => identity}
        else
          unavailable_ledger_health(identity)
        end

      {:server, identity} ->
        unavailable_ledger_health(identity)
    end
  end

  defp default_ledger_health(repo) do
    case live_main_database_path(repo) do
      {:ok, path} -> %{"reachable" => true, "identity" => sqlite_ledger_identity(path, "default")}
      :memory -> %{"reachable" => true, "identity" => sqlite_ledger_identity(":memory:", "default")}
      :error -> generic_default_ledger_health(repo)
    end
  end

  defp generic_default_ledger_health(repo) do
    identity = repo_configured_ledger_identity(repo, "default")

    try do
      case HandleStateStore.repo_query(repo, "SELECT 1", [], log: false) do
        {:ok, _result} -> %{"reachable" => true, "identity" => identity}
        {:error, _reason} -> %{"reachable" => false, "error" => "ledger_unavailable", "identity" => identity}
      end
    rescue
      _error -> %{"reachable" => false, "error" => "ledger_unavailable", "identity" => identity}
    end
  end

  defp configured_ledger_health(repo, database) do
    case configured_ledger(database, "explicit") do
      {:sqlite, path, identity} ->
        case configured_server_ledger_for_explicit_database(repo, database, "explicit") do
          {:server, identity} -> repo_reachable_ledger_health(repo, identity)
          nil -> configured_sqlite_ledger_health(repo, path, identity)
        end

      {:server, identity} ->
        if explicit_database_matches_repo_config?(repo, database) do
          repo_reachable_ledger_health(repo, identity)
        else
          unavailable_ledger_health(identity)
        end
    end
  end

  defp configured_sqlite_ledger_health(repo, path, identity) do
    case {path, live_main_database_path(repo)} do
      {":memory:", :memory} ->
        %{"reachable" => true, "identity" => identity}

      {path, {:ok, live_path}} when is_binary(path) ->
        if Repo.same_database_path?(path, live_path) do
          %{"reachable" => true, "identity" => identity}
        else
          unavailable_ledger_health(identity)
        end

      _unmatched ->
        unavailable_ledger_health(identity)
    end
  end

  defp repo_reachable_ledger_health(repo, identity) do
    case HandleStateStore.repo_query(repo, "SELECT 1", [], log: false) do
      {:ok, _result} -> %{"reachable" => true, "identity" => identity}
      {:error, _reason} -> unavailable_ledger_health(identity)
    end
  rescue
    _error -> unavailable_ledger_health(identity)
  end

  defp unavailable_ledger_health(identity),
    do: %{"reachable" => false, "error" => "ledger_unavailable", "identity" => identity}

  defp configured_ledger(database, source) do
    cond do
      Repo.memory_database?(database) ->
        {:sqlite, ":memory:", sqlite_ledger_identity(":memory:", source)}

      sqlite_file_uri?(database) ->
        {:sqlite, Repo.sqlite_file_uri_path(database), sqlite_file_uri_identity(database, source)}

      remote_database_identity?(database) ->
        {:server, server_ledger_identity(database, source)}

      true ->
        {:sqlite, database, sqlite_ledger_identity(database, source)}
    end
  end

  defp configured_ledger_identity(database, source), do: database |> configured_ledger(source) |> ledger_identity()

  defp ledger_identity({:sqlite, _path, identity}), do: identity
  defp ledger_identity({:server, identity}), do: identity

  defp repo_configured_ledger_identity(repo, source) do
    case repo_configured_database_for_identity(repo) do
      database when is_binary(database) -> configured_ledger_identity(database, source)
      _database -> unknown_ledger_identity(source)
    end
  end

  defp configured_server_ledger_for_explicit_database(repo, database, source) do
    with config when is_list(config) <- repo_config_for_identity(repo),
         true <- explicit_database_name_matches_repo_config?(config, database),
         identity_database when is_binary(identity_database) <- configured_server_database_for_identity(config) do
      {:server, server_ledger_identity(identity_database, source)}
    else
      _unmatched -> nil
    end
  end

  defp sqlite_file_uri_identity(database, source) do
    case Repo.sqlite_file_uri_path(database) do
      path when is_binary(path) and path != "" -> sqlite_ledger_identity(path, source)
      _path -> %{"kind" => "sqlite", "source" => source, "display_path" => "file:[redacted]", "default_home" => false}
    end
  end

  defp sqlite_ledger_identity(path, source) do
    %{
      "kind" => "sqlite",
      "source" => source,
      "display_path" => sqlite_display_path(path),
      "default_home" => default_home_database_path?(path)
    }
  end

  defp server_ledger_identity(database, source) do
    %{
      "kind" => "server",
      "source" => source,
      "endpoint" => safe_server_endpoint(database)
    }
  end

  defp live_main_database_path(repo) do
    case HandleStateStore.repo_query(repo, "PRAGMA database_list", [], log: false) do
      {:ok, %{rows: rows}} ->
        case Enum.find(rows, &match?([_seq, "main", _path], &1)) do
          [_seq, "main", path] when is_binary(path) and path != "" -> {:ok, path}
          [_seq, "main", ""] -> :memory
          _row -> :error
        end

      _result ->
        :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp normalized_database(database) when is_binary(database) do
    case String.trim(database) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalized_database(_database), do: nil

  defp normalize_optional_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_value(nil), do: nil
  defp normalize_optional_value(value), do: value

  defp sqlite_file_uri?("file:" <> _uri), do: true
  defp sqlite_file_uri?(_database), do: false

  defp remote_database_identity?(database) when is_binary(database) do
    remote_database_uri?(database) or server_database_dsn?(database) or credential_bearing_database_string?(database)
  end

  defp remote_database_uri?(database) do
    case URI.parse(database) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and scheme != "file" and is_binary(host) -> true
      %URI{scheme: scheme} when scheme in ["http", "https", "postgres", "postgresql", "mysql", "mssql"] -> true
      _uri -> false
    end
  rescue
    _error -> false
  end

  defp credential_bearing_database_string?(database) do
    database =~ ~r/(^|[;?\s])(password|passwd|pwd|secret|token|api[_-]?key)=/i
  end

  defp safe_server_endpoint(database) do
    case URI.parse(database) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        port_part = if is_integer(port), do: ":#{port}", else: ""
        "#{safe_endpoint_part(scheme)}://#{safe_endpoint_host(host)}#{port_part}"

      %URI{scheme: scheme} when is_binary(scheme) ->
        "#{safe_endpoint_part(scheme)}://[redacted]"

      _uri ->
        safe_server_dsn_endpoint(database)
    end
  rescue
    _error -> safe_server_dsn_endpoint(database)
  end

  defp safe_endpoint_part(part) do
    if part =~ ~r/\A[a-zA-Z][a-zA-Z0-9+.-]*\z/, do: String.downcase(part), else: "server"
  end

  defp safe_endpoint_host(host) do
    host = String.downcase(host)

    if host =~ ~r/\A[0-9a-z.:\-]+\z/ do
      if String.contains?(host, ":") and not String.starts_with?(host, "["),
        do: "[#{host}]",
        else: host
    else
      "[redacted]"
    end
  end

  defp safe_server_dsn_endpoint(database) do
    with values when map_size(values) > 0 <- server_database_dsn_values(database),
         host when is_binary(host) <- server_database_dsn_host(values) do
      {dsn_host, embedded_port} = split_server_dsn_host_port(host)
      port = server_database_dsn_port(values)
      "server://#{safe_endpoint_host(dsn_host)}#{if(port == "", do: embedded_port, else: port)}"
    else
      _missing_host -> "server"
    end
  end

  defp server_database_dsn?(database) do
    values = server_database_dsn_values(database)

    Enum.any?(["host", "hostname", "server", "addr", "address", "datasource"], &Map.has_key?(values, &1)) or
      Map.has_key?(values, "dbname") or
      (Map.has_key?(values, "database") and (Map.has_key?(values, "port") or Map.has_key?(values, "trustedconnection")))
  end

  defp server_database_dsn_values(database) do
    case normalized_database(database) do
      nil ->
        %{}

      database ->
        ~r/(?:^|[;\s])([A-Za-z][A-Za-z _-]*)\s*=\s*([^;\s]+)/
        |> Regex.scan(database)
        |> Map.new(fn [_match, key, value] -> {normalize_server_dsn_key(key), trim_server_dsn_value(value)} end)
    end
  end

  defp normalize_server_dsn_key(key) do
    key
    |> String.downcase()
    |> String.replace(~r/[\s_-]/, "")
  end

  defp trim_server_dsn_value(value) do
    value
    |> String.trim()
    |> String.trim("\"'")
  end

  defp server_database_dsn_host(values) do
    Enum.find_value(["host", "hostname", "server", "addr", "address", "datasource"], &Map.get(values, &1))
  end

  defp server_database_dsn_port(values), do: Map.get(values, "port") |> safe_endpoint_port()

  defp split_server_dsn_host_port(host) do
    host =
      host
      |> String.trim()
      |> String.replace(~r/\A(?:tcp|udp):/i, "")

    case String.split(host, ",", parts: 2) do
      [dsn_host, port] -> {dsn_host, safe_endpoint_port(port)}
      [dsn_host] -> {dsn_host, ""}
    end
  end

  defp safe_endpoint_port(port) when is_binary(port) do
    port = String.trim(port)

    if port =~ ~r/\A\d{1,5}\z/ and String.to_integer(port) <= 65_535 do
      ":#{port}"
    else
      ""
    end
  end

  defp safe_endpoint_port(port) when is_integer(port) and port >= 0 and port <= 65_535, do: ":#{port}"

  defp safe_endpoint_port(_port), do: ""

  defp repo_config_for_identity(repo) when is_atom(repo) do
    if Code.ensure_loaded?(repo) and function_exported?(repo, :config, 0) do
      repo.config()
    else
      []
    end
  rescue
    _error -> []
  end

  defp repo_configured_database_for_identity(repo) do
    repo
    |> repo_config_for_identity()
    |> configured_database_for_identity()
  end

  defp explicit_database_matches_repo_config?(repo, database) do
    case repo_configured_database_for_identity(repo) do
      repo_database when is_binary(repo_database) -> repo_database == database
      _database -> false
    end
  end

  defp configured_database_for_identity(config) when is_list(config) do
    configured_database_url_for_identity(config) ||
      configured_database_host_for_identity(config) ||
      config |> Keyword.get(:database) |> normalized_database()
  end

  defp configured_server_database_for_identity(config) when is_list(config) do
    configured_database_url_for_identity(config) || configured_database_host_for_identity(config)
  end

  defp configured_database_url_for_identity(config) do
    config
    |> Keyword.get(:url)
    |> normalized_database()
  end

  defp configured_database_host_for_identity(config) do
    host =
      config
      |> Keyword.get(:hostname)
      |> case do
        host when is_binary(host) and host != "" -> host
        _missing -> Keyword.get(config, :host)
      end
      |> normalized_database()

    if is_binary(host) do
      port = Keyword.get(config, :port) |> safe_endpoint_port()
      "server://#{safe_endpoint_host(host)}#{port}"
    end
  end

  defp explicit_database_name_matches_repo_config?(config, database) do
    config
    |> Keyword.get(:database)
    |> normalized_database()
    |> Kernel.==(database)
  end

  defp sqlite_display_path(":memory:"), do: ":memory:"

  defp sqlite_display_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> normalize_display_separator()
    |> display_home_relative_path()
  end

  defp normalize_display_separator(path), do: String.replace(path, "\\", "/")

  defp display_home_relative_path(path) do
    with home when is_binary(home) and home != "" <- System.user_home(),
         normalized_home <- home |> Path.expand() |> normalize_display_separator(),
         true <- path == normalized_home or String.starts_with?(path, normalized_home <> "/") do
      relative = binary_part(path, byte_size(normalized_home), byte_size(path) - byte_size(normalized_home))

      case String.trim_leading(relative, "/") do
        "" -> "$HOME"
        relative -> "$HOME/" <> relative
      end
    else
      _not_home -> path
    end
  end

  defp default_home_database_path?(path) do
    with path when is_binary(path) <- normalized_database(path),
         home when is_binary(home) and home != "" <- System.user_home() do
      default_home_database =
        [home, ".agents", "splusplus", "symphony_plus_plus.sqlite3"]
        |> Path.join()
        |> Path.expand()

      Repo.same_database_path?(path, default_home_database)
    else
      _unmatched -> false
    end
  end

  defp unknown_ledger_identity(source), do: %{"kind" => "unknown", "source" => source}

  defp tool_specs_for_session(%Config{} = config, nil) do
    {:ok, unbound_tool_specs(config)}
  end

  defp tool_specs_for_session(%Config{repo: repo} = config, session) do
    with :ok <- prepare_mcp_repository(repo) do
      session
      |> Auth.require_session(repo)
      |> tool_specs_for_session_result(config)
    end
  end

  defp tool_specs_for_session_result({:ok, %Session{assignment: %{grant_role: "architect"}} = session}, %Config{}) do
    {:ok, architect_session_tool_specs(session)}
  end

  defp tool_specs_for_session_result({:ok, %Session{assignment: %{grant_role: "worker"}} = session}, %Config{repo: repo}),
    do: {:ok, worker_session_tool_specs(repo, session)}

  defp tool_specs_for_session_result({:ok, %Session{}}, %Config{}), do: {:error, {:unauthorized, :unsupported_grant_role}}

  defp tool_specs_for_session_result({:error, {:service_unavailable, _reason} = reason}, %Config{}), do: {:error, reason}

  defp tool_specs_for_session_result({:error, _reason}, %Config{} = config) do
    {:ok, claimable_tool_specs(config)}
  end

  defp claimable_tool_specs(%Config{} = config), do: ToolCatalog.claimable_tool_specs(config)
  defp unbound_tool_specs(%Config{} = config), do: ToolCatalog.unbound_tool_specs_for_config(config)
  defp unbound_tool_specs_for_config(%Config{} = config), do: ToolCatalog.unbound_tool_specs_for_config(config)

  defp architect_session_tool_specs(%Session{} = session) do
    ToolCatalog.architect_session_tool_specs(current_work_request?: CurrentWorkRequest.single_scope?(session))
  end

  defp worker_session_tool_specs, do: ToolCatalog.worker_session_tool_specs()

  defp worker_session_tool_specs(repo, %Session{} = session) do
    ToolCatalog.worker_session_tool_specs()
    |> maybe_advertise_compact_attach_branch(repo, session)
  end

  defp maybe_advertise_compact_attach_branch(specs, repo, %Session{} = session) do
    if compact_attach_branch_available?(repo, session) do
      map_tool_spec(specs, "attach_branch", &put_in(&1, ["inputSchema", "required"], ["head_sha"]))
    else
      specs
    end
  end

  defp compact_attach_branch_available?(repo, %Session{} = session) do
    with {:ok, %WorkPackage{} = work_package} <- WorkPackageRepository.get(repo, Session.work_package_id(session)),
         branch when is_binary(branch) <- normalize_optional_value(work_package.branch_pattern) do
      not local_branch_template_pattern?(branch)
    else
      _missing_or_template -> false
    end
  end

  defp map_tool_spec(specs, name, fun) do
    Enum.map(specs, fn
      %{"name" => ^name} = spec -> fun.(spec)
      spec -> spec
    end)
  end

  defp tool_specs_for_server(%__MODULE__{session_refresh_required: true, config: config} = server) do
    {:ok, dedupe_tool_specs(claimable_tool_specs(config) ++ local_trusted_tool_specs(server))}
  end

  defp tool_specs_for_server(%__MODULE__{config: config, session: session} = server) do
    with {:ok, specs} <- tool_specs_for_session(config, session) do
      {:ok, dedupe_tool_specs(advertised_tool_specs(specs, server) ++ local_trusted_tool_specs(server))}
    end
  end

  defp advertised_tool_specs(specs, %__MODULE__{} = server) do
    if local_trusted_tools_enabled?(server) do
      specs
    else
      hide_trusted_local_tool_specs(specs)
    end
  end

  defp hide_trusted_local_tool_specs(specs) do
    Enum.reject(specs, &(&1["name"] in @bootstrap_tools))
  end

  defp dedupe_tool_specs(specs) do
    Enum.uniq_by(specs, & &1["name"])
  end

  defp local_trusted_tool_specs(%__MODULE__{} = server) do
    if local_trusted_tools_enabled?(server) do
      LocalTrustedTools.tool_specs(server.config)
    else
      []
    end
  end

  defp local_trusted_tools_enabled?(%__MODULE__{} = server), do: LocalTrustedTools.enabled?(server)

  defp solo_tool_input_schema(name), do: ToolCatalog.solo_tool_input_schema(name)
  defp bootstrap_tool_input_schema(name), do: ToolCatalog.bootstrap_tool_input_schema(name)
  defp local_operator_tool_input_schema(name), do: ToolCatalog.local_operator_tool_input_schema(name)
  defp local_architect_assignment_claim_tool_input_schema, do: ToolCatalog.local_architect_assignment_claim_tool_input_schema()
  defp assignment_release_tool_input_schema, do: ToolCatalog.assignment_release_tool_input_schema()
  defp worker_tool_input_schema(name), do: ToolCatalog.worker_tool_input_schema(name)
  defp architect_tool_input_schema(name), do: ToolCatalog.architect_tool_input_schema(name)

  defp work_package_resource_id(rest) when is_binary(rest) do
    case String.split(rest, "/", parts: 2) do
      [work_package_id, resource_path] ->
        if String.trim(work_package_id) != "" and valid_resource_path?(resource_path) do
          {:ok, work_package_id, resource_path}
        else
          :error
        end

      _parts ->
        :error
    end
  end

  defp valid_resource_path?(resource_path) when is_binary(resource_path) do
    String.trim(resource_path) != "" and not String.contains?(resource_path, "/")
  end

  defp assignment_resources(nil, _repo), do: {:ok, []}

  defp assignment_resources(%Session{} = session, repo) do
    case Auth.require_session(session, repo) do
      {:ok, %Session{} = session} ->
        assignment_resources_for_session(session)

      {:error, {:service_unavailable, reason}} ->
        service_error(reason, @assignment_resource)

      {:error, _reason} ->
        {:ok, []}
    end
  end

  defp assignment_resources(_session, _repo), do: {:ok, []}

  defp assignment_resources_for_session(%Session{assignment: %{grant_role: "worker"}} = session) do
    case require_worker_assignment(session.assignment) do
      :ok -> listed_assignment_resources(session)
      {:error, _reason} -> {:ok, []}
    end
  end

  defp assignment_resources_for_session(%Session{assignment: %{grant_role: "architect"}} = session) do
    case require_assignment_introspection(session.assignment) do
      :ok -> listed_current_assignment_resource(session)
      {:error, _reason} -> {:ok, []}
    end
  end

  defp assignment_resources_for_session(%Session{}), do: {:ok, []}

  defp listed_assignment_resources(%Session{} = session) do
    work_package_id = Session.work_package_id(session)

    with {:ok, assignment_resources} <- listed_current_assignment_resource(session) do
      {:ok, assignment_resources ++ work_package_resources(work_package_id)}
    end
  end

  defp listed_current_assignment_resource(%Session{}) do
    {:ok, current_assignment_resource_specs()}
  end

  defp work_package_resources(work_package_id) do
    Enum.map(PlanningRenderer.virtual_files(), fn file_name ->
      %{
        "uri" => "sympp://work-packages/#{work_package_id}/#{file_name}",
        "name" => file_name,
        "mimeType" => "text/markdown"
      }
    end)
  end

  defp base_resource_specs do
    [
      %{
        "uri" => @version_resource,
        "name" => "Symphony++ version",
        "mimeType" => "application/json"
      }
    ]
  end

  defp current_assignment_resource_specs do
    [
      %{
        "uri" => @assignment_resource,
        "name" => "Current Symphony++ assignment",
        "mimeType" => "application/json"
      }
    ]
  end

  defp work_package_resource_template_specs do
    Enum.map(PlanningRenderer.virtual_files(), fn file_name ->
      %{
        "uri_template" => "sympp://work-packages/{work_package_id}/#{file_name}",
        "name" => file_name,
        "mimeType" => "text/markdown"
      }
    end)
  end

  defp read_virtual_resource(repo, work_package_id, file_name, uri, opts) do
    with true <- file_name in PlanningRenderer.virtual_files(),
         {:ok, state} <- PlanningRepository.get_render_state(repo, work_package_id),
         {:ok, markdown} <- PlanningRenderer.render_state(state, file_name),
         {:ok, resource} <- virtual_resource_result(uri, markdown, state, file_name, opts) do
      {:ok, resource}
    else
      false -> {:error, -32_601, "Method not found", %{"resource" => uri, "reason" => "unknown_virtual_file"}}
      {:error, reason} -> service_error(reason, uri)
    end
  end

  defp virtual_resource_result(uri, markdown, state, file_name, opts) do
    if Keyword.get(opts, :agent_text?, false) do
      with {:ok, toon} <- WorkerContext.encode_virtual_file(state, file_name, uri: uri) do
        {:ok, agent_text_resource(uri, markdown, toon, "text/markdown")}
      end
    else
      {:ok, text_resource(uri, markdown, "text/markdown")}
    end
  end

  defp read_work_package_virtual_resource(repo, session, work_package_id, file_name, uri) do
    resource_type = resource_type_for_virtual_file(file_name)
    action = action_for_virtual_file(file_name)

    with {:ok, session} <- Auth.require_session(session, repo),
         {:ok, actor} <- actor_for_package_resource(repo, session, resource_type, work_package_id),
         :ok <- PlanningService.authorize_package_action(repo, actor, action, work_package_id, resource_type) do
      read_virtual_resource(repo, work_package_id, file_name, uri, agent_text?: worker_session?(session))
    else
      {:error, {:authorization_policy_denied, %Decision{} = decision}} -> MCPError.from_decision(decision, uri)
      {:error, reason} -> auth_error(reason, uri)
    end
  end

  defp worker_session?(%Session{assignment: %{grant_role: "worker"}}), do: true
  defp worker_session?(%Session{}), do: false

  defp handle_assignment_release_tool(params, id, %__MODULE__{} = server) do
    case prepare_assignment_release_tool_call(server, params) do
      {:ok, arguments} ->
        case release_current_assignment(arguments, server) do
          {:ok, result, updated_server} ->
            {response(id, release_tool_result(result)), updated_server}

          {:tool_error, reason} ->
            {:error, code, message, data} = invalid_params_error(@assignment_release_tool, reason)
            {error_response(id, code, message, data), server}
        end

      {:error, code, message, data} ->
        {error_response(id, code, message, data), server}
    end
  end

  defp handle_session_claim_tool(@local_assignment_claim_tool, params, id, %__MODULE__{} = server) do
    case claim_local_assignment(params, server) do
      {:ok, result, session} ->
        {response(id, claim_tool_result(result)), %{server | session: session, session_refresh_required: false}}

      {:error, code, message, data} ->
        {error_response(id, code, message, data), server}
    end
  end

  defp handle_session_claim_tool(@local_architect_assignment_claim_tool, params, id, %__MODULE__{} = server) do
    case claim_local_architect_assignment(params, server) do
      {:ok, result, session} ->
        {response(id, claim_tool_result(result)), %{server | session: session, session_refresh_required: false}}

      {:error, code, message, data} ->
        {error_response(id, code, message, data), server}
    end
  end

  defp handle_assignment_release_tool_notification(params, %__MODULE__{} = server) do
    case prepare_assignment_release_tool_call(server, params) do
      {:ok, arguments} ->
        case release_current_assignment(arguments, server) do
          {:ok, _result, updated_server} -> {nil, updated_server}
          {:tool_error, _reason} -> {nil, server}
        end

      {:error, _code, _message, _data} ->
        {nil, server}
    end
  end

  defp handle_session_claim_tool_notification(@local_assignment_claim_tool, params, %__MODULE__{} = server) do
    case claim_local_assignment(params, server) do
      {:ok, _result, session} -> {nil, %{server | session: session, session_refresh_required: false}}
      {:error, _code, _message, _data} -> {nil, server}
    end
  end

  defp handle_session_claim_tool_notification(@local_architect_assignment_claim_tool, params, %__MODULE__{} = server) do
    case claim_local_architect_assignment(params, server) do
      {:ok, _result, session} -> {nil, %{server | session: session, session_refresh_required: false}}
      {:error, _code, _message, _data} -> {nil, server}
    end
  end

  defp claim_local_assignment(params, %__MODULE__{config: config, session: session} = server) do
    with {:ok, arguments} <- worker_tool_arguments(params, @local_assignment_claim_tool),
         {:ok, claim} <- local_assignment_claim_arguments(arguments, server),
         :ok <- require_local_assignment_claim_mode(server),
         :ok <- prepare_mcp_repository(config.repo),
         {:ok, work_package} <- WorkPackageRepository.get(config.repo, claim.work_package_id),
         claim <- hydrate_local_assignment_claim(config.repo, work_package, claim),
         :ok <- validate_local_assignment_scope(config.repo, work_package, claim),
         {:ok, lease, lease_action} <- ensure_local_assignment_claim_lease(config.repo, work_package, claim) do
      case claim_local_assignment_session(config.repo, work_package, claim, lease, lease_action) do
        {:ok, result, new_session, grant_action} ->
          finalize_local_assignment_rebind(config.repo, server, session, claim, lease, lease_action, {result, new_session, grant_action})

        {:error, reason} ->
          release_failed_local_assignment_lease(config.repo, lease, lease_action, reason)
          local_assignment_claim_error(reason)
      end
    else
      {:error, code, message, data} -> {:error, code, message, data}
      {:tool_error, reason} -> invalid_params_error(@local_assignment_claim_tool, reason)
      {:error, reason} -> local_assignment_claim_error(reason)
    end
  rescue
    _error -> {:error, -32_000, "Server error", %{"tool" => @local_assignment_claim_tool, "reason" => "ledger_unavailable"}}
  end

  defp finalize_local_assignment_rebind(
         repo,
         %__MODULE__{} = server,
         old_session,
         claim,
         lease,
         lease_action,
         {result, new_session, grant_action}
       ) do
    with {:ok, result, new_session} <-
           finalize_local_assignment_claim(repo, result, new_session, claim, lease, lease_action, grant_action),
         {:ok, _released_server} <- release_local_assignment_rebind(repo, server, old_session, claim) do
      {:ok, result, new_session}
    else
      {:error, code, message, data} ->
        {:error, code, message, data}

      {:error, reason} ->
        rollback_failed_local_assignment_claim(repo, new_session, lease, lease_action, grant_action, reason)
        local_assignment_claim_error(reason)
    end
  end

  defp local_assignment_claim_arguments(arguments, %__MODULE__{} = server) do
    with {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, repo} <- optional_string_argument(arguments, "repo"),
         {:ok, base_branch} <- optional_string_argument(arguments, "base_branch"),
         {:ok, work_request_id} <- optional_string_argument(arguments, "work_request_id"),
         {:ok, branch} <- optional_string_argument(arguments, "branch"),
         {:ok, worktree_path} <- optional_string_argument(arguments, "worktree_path"),
         {:ok, caller_id} <- optional_string_argument(arguments, "caller_id", default_caller_id(server)),
         {:ok, claimed_by} <- optional_string_argument(arguments, "claimed_by", default_claimed_by(server)) do
      {:ok,
       %{
         repo: repo,
         base_branch: base_branch,
         work_package_id: work_package_id,
         work_request_id: work_request_id,
         branch: branch,
         worktree_path: normalize_optional_local_assignment_path(worktree_path),
         mode: local_claim_transport_mode(server),
         caller_id: caller_id,
         claimed_by: claimed_by
       }}
    end
  end

  defp hydrate_local_assignment_claim(repo, %WorkPackage{} = work_package, claim) do
    worktree_path = claim.worktree_path || normalize_optional_local_assignment_path(work_package.worktree_path)
    branch = claim.branch || local_assignment_worktree_branch_or_nil(worktree_path)

    %{
      claim
      | repo: claim.repo || work_package.repo,
        base_branch: claim.base_branch || work_package.base_branch,
        work_request_id: claim.work_request_id || local_assignment_work_request_id(repo, work_package.id),
        branch: branch,
        worktree_path: worktree_path
    }
  end

  defp require_local_assignment_claim_mode(%__MODULE__{initialized: false}), do: {:error, :local_mcp_session_required}

  defp require_local_assignment_claim_mode(%__MODULE__{
         config: %Config{mode: :http, local_daemon_trusted: true} = config,
         local_daemon_trusted: true,
         state_key_explicit: true
       }) do
    LocalTrustedTools.require_database(config)
  end

  defp require_local_assignment_claim_mode(%__MODULE__{config: %Config{mode: :http}, state_key_explicit: false}),
    do: {:error, :local_mcp_session_required}

  defp require_local_assignment_claim_mode(%__MODULE__{config: %Config{mode: :http}}), do: {:error, :local_daemon_trust_required}

  # STDIO MCP servers are local agent processes; HTTP local claims require the
  # explicit trusted-state checks above because that transport has ambient reach.
  defp require_local_assignment_claim_mode(%__MODULE__{}), do: :ok

  defp release_local_assignment_rebind(_repo, %__MODULE__{} = server, nil, _claim), do: {:ok, server}

  defp release_local_assignment_rebind(_repo, %__MODULE__{} = server, %Session{} = session, claim) do
    if same_local_assignment_claim?(session, claim) do
      {:ok, server}
    else
      release_bound_session_for_claim_rebind(server, session, @local_assignment_claim_tool)
    end
  end

  defp same_local_assignment_claim?(%Session{assignment: assignment}, claim) do
    assignment.grant_role == "worker" and assignment.work_package_id == claim.work_package_id
  end

  defp validate_local_assignment_scope(repo, %WorkPackage{} = work_package, claim) do
    with :ok <- require_local_repo_scope_match(work_package.repo, claim.repo, :repo_scope_mismatch),
         :ok <- require_local_value_match(work_package.base_branch, claim.base_branch, :base_branch_scope_mismatch),
         :ok <- require_optional_local_worktree_scope(work_package, claim.worktree_path),
         :ok <- require_optional_local_branch_scope(work_package, claim.branch, claim.worktree_path),
         :ok <- require_live_local_work_package(work_package) do
      validate_local_work_request_scope(repo, work_package, claim.work_request_id)
    end
  end

  defp require_local_value_match(value, value, _reason) when is_binary(value), do: :ok
  defp require_local_value_match(_expected, _actual, reason), do: {:error, reason}

  defp require_local_repo_scope_match(expected_repo, actual_repo, reason) do
    if repo_scope_name_matches?(expected_repo, actual_repo, []), do: :ok, else: {:error, reason}
  end

  defp require_optional_local_branch_scope(%WorkPackage{}, nil, _worktree_path), do: :ok
  defp require_optional_local_branch_scope(%WorkPackage{} = work_package, branch, worktree_path), do: require_local_branch_scope(work_package, branch, worktree_path)

  defp require_local_branch_scope(%WorkPackage{} = work_package, branch, worktree_path) do
    case local_assignment_worktree_branch(worktree_path) do
      {:ok, ^branch} ->
        require_local_branch_pattern_scope(work_package, branch, prepared_worktree?: true)

      {:ok, _branch} ->
        {:error, :branch_scope_mismatch}

      {:error, :git_metadata_missing} ->
        require_local_branch_pattern_scope(work_package, branch, prepared_worktree?: false)

      {:error, _reason} ->
        {:error, :branch_scope_mismatch}
    end
  end

  defp require_local_branch_pattern_scope(%WorkPackage{branch_pattern: branch_pattern} = work_package, branch, opts) do
    case normalize_optional_value(branch_pattern) do
      nil ->
        :ok

      pattern ->
        case require_supported_branch_pattern(pattern) do
          :ok -> require_local_supported_branch_pattern_scope(work_package, pattern, branch, opts)
          error -> error
        end
    end
  end

  defp require_local_supported_branch_pattern_scope(%WorkPackage{} = work_package, pattern, branch, opts) do
    cond do
      pattern == branch and not local_branch_template_pattern?(pattern) ->
        :ok

      Keyword.get(opts, :prepared_worktree?, false) and local_branch_template_matches?(work_package, pattern, branch) ->
        :ok

      true ->
        {:error, :branch_scope_mismatch}
    end
  end

  defp local_branch_template_pattern?(pattern) when is_binary(pattern) do
    Regex.match?(~r/\{\{\s*[a-zA-Z0-9_]+\s*\}\}/, pattern)
  end

  defp local_branch_template_pattern?(_pattern), do: false

  defp local_branch_template_matches?(%WorkPackage{} = work_package, pattern, branch)
       when is_binary(pattern) and is_binary(branch) do
    case Regex.scan(~r/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/, pattern, return: :index) do
      [] ->
        false

      matches ->
        source = "^" <> local_branch_template_regex_source(pattern, matches, work_package) <> "$"
        Regex.match?(Regex.compile!(source), branch)
    end
  end

  defp local_branch_template_matches?(%WorkPackage{}, _pattern, _branch), do: false

  defp local_branch_template_regex_source(pattern, matches, work_package) do
    {parts, cursor} =
      Enum.reduce(matches, {[], 0}, fn [{match_start, match_length}, {capture_start, capture_length}], {parts, cursor} ->
        literal = pattern |> binary_part(cursor, match_start - cursor) |> Regex.escape()
        placeholder = binary_part(pattern, capture_start, capture_length)
        replacement = local_branch_template_placeholder_regex(work_package, placeholder)

        {[replacement, literal | parts], match_start + match_length}
      end)

    suffix = pattern |> binary_part(cursor, byte_size(pattern) - cursor) |> Regex.escape()
    IO.iodata_to_binary(Enum.reverse([suffix | parts]))
  end

  defp local_branch_template_placeholder_regex(%WorkPackage{} = work_package, placeholder) do
    case placeholder do
      "work_package_id" -> local_branch_template_literal_regex(work_package.id)
      "id" -> local_branch_template_literal_regex(work_package.id)
      "phase_id" -> local_branch_template_literal_regex(work_package.phase_id)
      "parent_id" -> local_branch_template_literal_regex(work_package.parent_id)
      "owner_id" -> local_branch_template_literal_regex(work_package.owner_id)
      _placeholder -> "[^/]+"
    end
  end

  defp local_branch_template_literal_regex(value) do
    case normalize_optional_value(value) do
      nil -> "[^/]+"
      value -> Regex.escape(value)
    end
  end

  @dialyzer {:nowarn_function, local_assignment_worktree_branch: 1}
  @spec local_assignment_worktree_branch(term()) :: {:ok, String.t()} | {:error, atom()}
  defp local_assignment_worktree_branch(worktree_path) do
    case normalize_optional_value(worktree_path) do
      path when is_binary(path) -> local_assignment_worktree_branch_from_path(path)
      _missing -> {:error, :git_metadata_missing}
    end
  end

  defp local_assignment_worktree_branch_from_path(worktree_path) do
    case File.dir?(worktree_path) do
      true ->
        with {:ok, git_dir} <- local_assignment_git_dir(worktree_path),
             {:ok, head} <- File.read(Path.join(git_dir, "HEAD")),
             {:ok, branch} <- local_assignment_head_branch(head) do
          {:ok, branch}
        else
          {:error, :enoent} -> {:error, :git_metadata_missing}
          {:error, reason} -> {:error, reason}
        end

      false ->
        {:error, :git_metadata_missing}
    end
  end

  defp local_assignment_git_dir(worktree_path) do
    dot_git = Path.join(worktree_path, ".git")

    cond do
      File.dir?(dot_git) ->
        {:ok, dot_git}

      File.regular?(dot_git) ->
        dot_git
        |> File.read()
        |> local_assignment_git_dir_from_file(worktree_path)

      true ->
        {:error, :git_metadata_missing}
    end
  end

  defp local_assignment_git_dir_from_file({:ok, contents}, worktree_path) do
    case contents |> String.trim() |> String.split(":", parts: 2) do
      ["gitdir", git_dir] -> {:ok, Path.expand(String.trim(git_dir), worktree_path)}
      _contents -> {:error, :git_metadata_invalid}
    end
  end

  defp local_assignment_git_dir_from_file({:error, reason}, _worktree_path), do: {:error, reason}

  defp local_assignment_head_branch(head) when is_binary(head) do
    case String.trim(head) do
      "ref: refs/heads/" <> branch when branch != "" -> {:ok, branch}
      _detached_or_invalid -> {:error, :git_head_invalid}
    end
  end

  defp require_local_worktree_scope(%WorkPackage{worktree_path: worktree_path}, claim_worktree_path) do
    case normalize_optional_value(worktree_path) do
      nil ->
        {:error, :worktree_scope_required}

      expected_worktree_path ->
        if normalize_local_assignment_path(expected_worktree_path) == claim_worktree_path do
          :ok
        else
          {:error, :worktree_scope_mismatch}
        end
    end
  end

  defp require_optional_local_worktree_scope(%WorkPackage{}, nil), do: :ok
  defp require_optional_local_worktree_scope(%WorkPackage{} = work_package, claim_worktree_path), do: require_local_worktree_scope(work_package, claim_worktree_path)

  defp require_live_local_work_package(%WorkPackage{status: status})
       when status in ["merged", "merged_into_phase", "closed", "abandoned"] do
    {:error, :work_package_terminal}
  end

  defp require_live_local_work_package(%WorkPackage{}), do: :ok

  defp validate_local_work_request_scope(_repo, %WorkPackage{}, nil), do: :ok

  defp validate_local_work_request_scope(repo, %WorkPackage{} = work_package, work_request_id) do
    with {:ok, work_request} <- WorkRequestRepository.get(repo, work_request_id),
         {:ok, planned_slice} <- local_work_request_package_link(repo, work_request_id, work_package.id),
         :ok <-
           require_local_value_match(
             PlannedSlice.delivery_repo(work_request, planned_slice),
             work_package.repo,
             :work_request_repo_scope_mismatch
           ),
         :ok <-
           require_local_value_match(
             planned_slice.target_base_branch,
             work_package.base_branch,
             :package_delivery_base_mismatch
           ) do
      :ok
    else
      {:error, :not_found} -> {:error, :work_request_scope_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp local_work_request_package_link(repo, work_request_id, work_package_id) do
    case repo.one(
           from(planned_slice in PlannedSlice,
             where: planned_slice.work_request_id == ^work_request_id,
             where: planned_slice.work_package_id == ^work_package_id,
             limit: 1
           )
         ) do
      %PlannedSlice{} = planned_slice -> {:ok, planned_slice}
      nil -> {:error, :work_request_package_link_mismatch}
    end
  end

  defp ensure_local_assignment_claim_lease(repo, %WorkPackage{} = work_package, claim) do
    LocalClaimLeases.ensure(
      repo,
      work_package.id,
      LocalClaimLeases.worker_actor(claim),
      @local_assignment_claim_stale_after_ms,
      "local_assignment_claim_stale"
    )
  end

  defp claim_local_assignment_session(repo, %WorkPackage{} = work_package, claim, %ClaimLease{} = lease, lease_action) do
    claim_now = DateTime.utc_now(:microsecond)
    existing_grant_ids = local_assignment_active_worker_grant_ids(repo, work_package.id, claim.claimed_by, claim_now)

    with {:ok, grant, grant_action} <-
           LocalClaimLeases.claim_worker_grant(repo, work_package.id, claim, lease, lease_action, existing_grant_ids, claim_now),
         {:ok, session} <- Auth.session_from_grant(repo, grant, proof_hash: grant.secret_hash),
         :ok <- require_worker_assignment(session.assignment) do
      assignment = %{"assignment" => Session.public_assignment(session)}
      {:ok, assignment, session, grant_action}
    end
  end

  @spec local_assignment_active_worker_grant_ids(module(), String.t(), String.t(), DateTime.t()) :: [String.t()]
  defp local_assignment_active_worker_grant_ids(repo, work_package_id, claimed_by, %DateTime{} = now)
       when is_atom(repo) and is_binary(work_package_id) and is_binary(claimed_by) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.grant_role == "worker",
        where: grant.claimed_by == ^claimed_by,
        where: not is_nil(grant.claimed_at),
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        select: grant.id
      )

    repo.all(query)
  end

  defp local_assignment_active_worker_grant_ids(_repo, _work_package_id, _claimed_by, %DateTime{}), do: []

  defp finalize_local_assignment_claim(repo, result, %Session{} = session, claim, %ClaimLease{} = lease, lease_action, grant_action) do
    session = Session.with_claim_lease(session, lease)

    case append_local_assignment_claim_event(repo, session, claim, lease, lease_action) do
      {:ok, claim_event} ->
        {:ok, Map.put(result, "local_claim", local_assignment_claim_payload(claim, lease, lease_action, claim_event)), session}

      {:error, reason} ->
        rollback_failed_local_assignment_claim(repo, session, lease, lease_action, grant_action, reason)
        local_assignment_claim_error(reason)
    end
  end

  defp rollback_failed_local_assignment_claim(repo, %Session{} = session, %ClaimLease{} = lease, lease_action, grant_action, reason) do
    release_failed_local_assignment_lease(repo, lease, lease_action, reason)
    revoke_failed_local_assignment_grant(repo, session, lease_action, grant_action)
  end

  defp revoke_failed_local_assignment_grant(repo, %Session{assignment: %{grant_id: grant_id}}, lease_action, :claimed)
       when lease_action in [:created, :reclaimed] and is_binary(grant_id) do
    _result = AccessGrantService.revoke(repo, grant_id)
    :ok
  end

  defp revoke_failed_local_assignment_grant(repo, %Session{}, :reclaimed, {:recovered, recovery}) do
    _result = LocalClaimLeases.rollback_worker_grant_recovery(repo, recovery)
    :ok
  end

  defp revoke_failed_local_assignment_grant(_repo, %Session{}, _lease_action, _grant_action), do: :ok

  defp local_assignment_claim_payload(claim, %ClaimLease{} = lease, lease_action, claim_event) do
    %{
      "tool" => @local_assignment_claim_tool,
      "mode" => claim.mode,
      "repo" => claim.repo,
      "base_branch" => claim.base_branch,
      "work_package_id" => claim.work_package_id,
      "work_request_id" => claim.work_request_id,
      "branch" => claim.branch,
      "worktree_path" => claim.worktree_path,
      "caller_id" => claim.caller_id,
      "claimed_by" => claim.claimed_by,
      "claim_lease_id" => lease.id,
      "claim_lease_status" => lease.status,
      "claim_lease_action" => Atom.to_string(lease_action),
      "lifecycle_state" => "active",
      "reason_codes" => local_assignment_claim_reason_codes(lease_action, lease)
    }
    |> drop_nil_values()
    |> maybe_put_claim_event(claim_event)
  end

  defp append_local_assignment_claim_event(_repo, %Session{}, _claim, %ClaimLease{}, lease_action) when lease_action != :reclaimed, do: {:ok, nil}

  defp append_local_assignment_claim_event(repo, %Session{} = session, claim, %ClaimLease{} = lease, :reclaimed) do
    payload = local_assignment_claim_reclaim_payload(claim, lease)

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, claim.work_package_id, %{
      "summary" => "Local assignment claim lease reclaimed",
      "body" => "Local assignment claim lease was reclaimed for #{claim.claimed_by}.",
      "status" => "claim_lease_reclaimed",
      "idempotency_key" => metadata_idempotency_key(payload),
      "payload" => payload
    })
  end

  defp local_assignment_claim_reclaim_payload(claim, %ClaimLease{} = lease) do
    %{
      "type" => "claim_lease_reclaim",
      "source_tool" => @local_assignment_claim_tool,
      "work_package_id" => claim.work_package_id,
      "work_request_id" => claim.work_request_id,
      "claim_lease_id" => lease.id,
      "claim_group_id" => lease.claim_group_id,
      "previous_claim_id" => lease.previous_claim_id,
      "claim_lease_status" => lease.status,
      "claim_lease_action" => "reclaimed",
      "claimed_by" => claim.claimed_by,
      "caller_id" => claim.caller_id,
      "lifecycle_state" => "active",
      "reason_codes" => local_assignment_claim_reason_codes(:reclaimed, lease)
    }
    |> drop_nil_values()
  end

  defp maybe_put_claim_event(payload, nil), do: payload

  defp maybe_put_claim_event(payload, %ProgressEvent{} = event) do
    Map.put(payload, "claim_event", progress_event_payload(event))
  end

  defp local_assignment_claim_reason_codes(lease_action, %ClaimLease{} = lease) do
    [
      "claim_lease_#{lease_action}",
      if(lease.previous_claim_id, do: "worker_recycled")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp release_failed_local_assignment_lease(repo, %ClaimLease{} = lease, lease_action, _reason)
       when lease_action in [:created, :reclaimed] do
    _result = ClaimLeaseService.release(repo, lease.id, reason: "local_assignment_claim_failed")
    :ok
  end

  defp release_failed_local_assignment_lease(repo, %ClaimLease{} = lease, :heartbeat, reason)
       when reason in [:expired, :revoked, :worker_grant_required] do
    _result = ClaimLeaseService.release(repo, lease.id, reason: "local_assignment_claim_failed")
    :ok
  end

  defp release_failed_local_assignment_lease(_repo, %ClaimLease{}, _lease_action, _reason), do: :ok

  defp claim_local_architect_assignment(params, %__MODULE__{config: config, session: session} = server) do
    with {:ok, arguments} <- local_architect_assignment_claim_tool_arguments(params),
         {:ok, claim} <- local_architect_assignment_claim_arguments(arguments, server),
         :ok <- require_local_architect_assignment_claim_mode(server),
         :ok <- prepare_mcp_repository(config.repo),
         {:ok, work_request} <- WorkRequestRepository.get(config.repo, claim.work_request_id),
         :ok <- require_local_architect_assignment_work_request_claimable(work_request),
         claim <- hydrate_local_architect_assignment_claim(work_request, claim),
         {:ok, anchor} <- require_local_architect_handoff_anchor(config, work_request, claim),
         :ok <- validate_local_architect_assignment_scope(work_request, anchor, claim),
         {:ok, lease, lease_action} <- ensure_local_architect_assignment_claim_lease(config.repo, anchor, claim) do
      case claim_local_architect_assignment_session(config.repo, anchor, claim, lease_action) do
        {:ok, result, new_session, grant_action} ->
          finalize_local_architect_assignment_rebind(config.repo, server, session, claim, lease, lease_action, {result, new_session, grant_action})

        {:error, reason} ->
          release_failed_local_architect_assignment_lease(config.repo, lease, lease_action, reason)
          local_architect_assignment_claim_error(reason)
      end
    else
      {:error, code, message, data} -> {:error, code, message, data}
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => @local_architect_assignment_claim_tool, "reason" => reason}}
      {:error, reason} -> local_architect_assignment_claim_error(reason)
    end
  rescue
    _error -> {:error, -32_000, "Server error", %{"tool" => @local_architect_assignment_claim_tool, "reason" => "ledger_unavailable"}}
  end

  defp finalize_local_architect_assignment_rebind(
         repo,
         %__MODULE__{} = server,
         old_session,
         claim,
         lease,
         lease_action,
         {result, new_session, grant_action}
       ) do
    with {:ok, result, new_session} <-
           finalize_local_architect_assignment_claim(
             repo,
             result,
             new_session,
             claim,
             lease,
             lease_action,
             grant_action
           ),
         {:ok, _released_server} <- release_local_architect_assignment_rebind(repo, server, old_session, claim) do
      {:ok, result, new_session}
    else
      {:error, code, message, data} ->
        {:error, code, message, data}

      {:error, reason} ->
        rollback_failed_local_architect_assignment_claim(repo, new_session, lease, lease_action, grant_action, reason)
        local_architect_assignment_claim_error(reason)
    end
  end

  defp local_architect_assignment_claim_arguments(arguments, %__MODULE__{} = server) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, anchor_id} <- optional_string_argument(arguments, "architect_anchor_work_package_id"),
         {:ok, repo} <- optional_string_argument(arguments, "repo"),
         {:ok, base_branch} <- optional_string_argument(arguments, "base_branch"),
         {:ok, phase_id} <- optional_string_argument(arguments, "phase_id"),
         {:ok, caller_id} <- optional_string_argument(arguments, "caller_id", default_caller_id(server)),
         {:ok, claimed_by} <- optional_string_argument(arguments, "claimed_by", default_architect_claimed_by(server)) do
      {:ok,
       %{
         work_request_id: work_request_id,
         architect_anchor_work_package_id: anchor_id,
         repo: repo,
         base_branch: base_branch,
         phase_id: phase_id,
         mode: local_claim_transport_mode(server),
         caller_id: caller_id,
         claimed_by: claimed_by
       }}
    end
  end

  defp hydrate_local_architect_assignment_claim(%WorkRequest{} = work_request, claim) do
    anchor_id = claim.architect_anchor_work_package_id || ArchitectHandoff.anchor_id_for_work_request(work_request)

    %{
      claim
      | architect_anchor_work_package_id: anchor_id,
        repo: claim.repo || work_request.repo,
        base_branch: claim.base_branch || work_request.base_branch,
        phase_id: claim.phase_id || ArchitectHandoff.phase_id_for_work_request(work_request)
    }
  end

  defp require_local_architect_assignment_work_request_claimable(%WorkRequest{archived_at: %DateTime{}}),
    do: {:error, {:work_request_terminal, :archived}}

  defp require_local_architect_assignment_work_request_claimable(%WorkRequest{
         completed_at: %DateTime{},
         completion_source: "operator"
       }),
       do: {:error, {:work_request_terminal, :completed}}

  defp require_local_architect_assignment_work_request_claimable(%WorkRequest{}), do: :ok

  defp require_local_architect_assignment_claim_mode(%__MODULE__{config: config} = server) do
    with :ok <- require_local_assignment_claim_mode(server) do
      LocalTrustedTools.require_database(config)
    end
  end

  defp release_local_architect_assignment_rebind(_repo, %__MODULE__{} = server, nil, _claim), do: {:ok, server}

  defp release_local_architect_assignment_rebind(_repo, %__MODULE__{} = server, %Session{} = session, claim) do
    if same_local_architect_assignment_claim?(session, claim) do
      {:ok, server}
    else
      release_bound_session_for_claim_rebind(server, session, @local_architect_assignment_claim_tool)
    end
  end

  defp same_local_architect_assignment_claim?(%Session{assignment: assignment}, claim) do
    assignment.grant_role == "architect" and assignment.work_package_id == claim.architect_anchor_work_package_id
  end

  defp release_bound_session_for_claim_rebind(%__MODULE__{} = server, %Session{} = session, tool) do
    current_assignment = current_assignment_summary(server.config.repo, session)

    case release_current_assignment(%{"reason" => tool}, server) do
      {:ok, result, %__MODULE__{} = released_server} ->
        if auto_rebind_release_cleared?(result),
          do: {:ok, released_server},
          else: {:error, {:session_already_bound, current_assignment}}

      {:tool_error, reason} ->
        {:error, reason}
    end
  end

  defp auto_rebind_release_cleared?(%{"binding_cleared" => true, "fresh_mcp_session_required" => false}), do: true
  defp auto_rebind_release_cleared?(_result), do: false

  defp validate_local_architect_assignment_scope(%WorkRequest{} = work_request, %WorkPackage{} = anchor, claim) do
    expected_phase_id = ArchitectHandoff.phase_id_for_work_request(work_request)

    with :ok <- require_local_repo_scope_match(work_request.repo, claim.repo, :repo_scope_mismatch),
         :ok <- require_local_value_match(work_request.base_branch, claim.base_branch, :base_branch_scope_mismatch),
         :ok <- require_local_repo_scope_match(anchor.repo, work_request.repo, :architect_anchor_scope_mismatch),
         :ok <-
           require_local_value_match(
             anchor.base_branch,
             work_request.base_branch,
             :architect_anchor_scope_mismatch
           ),
         :ok <-
           require_local_value_match(
             anchor.id,
             ArchitectHandoff.anchor_id_for_work_request(work_request),
             :architect_anchor_scope_mismatch
           ),
         :ok <- require_local_value_match(anchor.phase_id, expected_phase_id, :phase_scope_mismatch),
         :ok <- require_optional_phase_scope(claim.phase_id, expected_phase_id),
         :ok <- require_architect_handoff_anchor_kind(anchor) do
      require_live_local_work_package(anchor)
    end
  end

  defp require_local_architect_handoff_anchor(%Config{} = config, %WorkRequest{} = work_request, claim) do
    repo = config.repo
    expected_anchor_id = ArchitectHandoff.anchor_id_for_work_request(work_request)
    expected_phase_id = ArchitectHandoff.phase_id_for_work_request(work_request)

    with :ok <- require_local_repo_scope_match(work_request.repo, claim.repo, :repo_scope_mismatch),
         :ok <- require_local_value_match(work_request.base_branch, claim.base_branch, :base_branch_scope_mismatch),
         :ok <-
           require_local_value_match(
             expected_anchor_id,
             claim.architect_anchor_work_package_id,
             :architect_anchor_scope_mismatch
           ),
         :ok <- require_optional_phase_scope(claim.phase_id, expected_phase_id) do
      case WorkPackageRepository.get(repo, expected_anchor_id) do
        {:ok, %WorkPackage{} = anchor} ->
          {:ok, anchor}

        {:error, :not_found} ->
          create_local_architect_handoff_anchor(config, work_request, claim, expected_anchor_id)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp create_local_architect_handoff_anchor(%Config{} = config, %WorkRequest{} = work_request, claim, expected_anchor_id) do
    with {:ok, handoff_opts} <- create_work_request_handoff_opts(config, claim.claimed_by),
         {:ok, _handoff} <-
           ArchitectHandoff.create_or_replay(config.repo, work_request.id,
             local_operator?: true,
             local_architect_claim?: true,
             handoff_opts: handoff_opts
           ) do
      WorkPackageRepository.get(config.repo, expected_anchor_id)
    end
  end

  defp require_optional_phase_scope(nil, _expected_phase_id), do: :ok
  defp require_optional_phase_scope(phase_id, phase_id) when is_binary(phase_id), do: :ok
  defp require_optional_phase_scope(_phase_id, _expected_phase_id), do: {:error, :phase_scope_mismatch}

  defp require_architect_handoff_anchor_kind(%WorkPackage{kind: "delegation"}), do: :ok
  defp require_architect_handoff_anchor_kind(%WorkPackage{}), do: {:error, :architect_anchor_scope_mismatch}

  defp ensure_local_architect_assignment_claim_lease(repo, %WorkPackage{} = anchor, claim) do
    LocalClaimLeases.ensure(
      repo,
      anchor.id,
      LocalClaimLeases.architect_actor(claim),
      @local_assignment_claim_stale_after_ms,
      "local_architect_assignment_claim_stale"
    )
  end

  defp claim_local_architect_assignment_session(repo, %WorkPackage{} = anchor, claim, lease_action) do
    validate_grant = &validate_local_architect_assignment_grant(repo, &1, anchor, claim)

    with {:ok, grant, grant_action} <- LocalArchitectGrantClaim.claim(repo, anchor, claim, lease_action, validate_grant),
         :ok <- validate_local_architect_assignment_grant(repo, grant, anchor, claim),
         {:ok, session} <- Auth.session_from_grant(repo, grant, proof_hash: grant.secret_hash),
         :ok <- require_architect_assignment(session.assignment) do
      assignment = %{"assignment" => Session.public_assignment(session)}
      {:ok, assignment, session, grant_action}
    end
  end

  defp validate_local_architect_assignment_grant(repo, %AccessGrant{} = grant, %WorkPackage{} = anchor, claim) do
    with :ok <- require_local_value_match(grant.work_package_id, anchor.id, :architect_grant_scope_mismatch),
         :ok <- require_local_value_match(grant.phase_id, anchor.phase_id, :architect_grant_scope_mismatch),
         :ok <- require_local_repo_scope_match(grant.scope_repo, claim.repo, :architect_grant_scope_mismatch),
         :ok <- require_local_value_match(grant.scope_base_branch, claim.base_branch, :architect_grant_scope_mismatch),
         :ok <- AccessGrantService.require_live_package_authority(repo, grant) do
      require_local_architect_handoff_grant(repo, grant)
    end
  end

  defp require_local_architect_handoff_grant(repo, %AccessGrant{} = grant) do
    case ArchitectHandoff.handoff_phase_grant?(repo, grant) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :architect_grant_scope_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finalize_local_architect_assignment_claim(repo, result, %Session{} = session, claim, %ClaimLease{} = lease, lease_action, grant_action) do
    session = Session.with_claim_lease(session, lease)

    case append_local_architect_assignment_claim_event(repo, session, claim, lease, lease_action) do
      {:ok, claim_event} ->
        {:ok, Map.put(result, "local_claim", local_architect_assignment_claim_payload(claim, lease, lease_action, claim_event)), session}

      {:error, reason} ->
        rollback_failed_local_architect_assignment_claim(repo, session, lease, lease_action, grant_action, reason)
        local_architect_assignment_claim_error(reason)
    end
  end

  defp rollback_failed_local_architect_assignment_claim(repo, %Session{} = session, %ClaimLease{} = lease, lease_action, grant_action, reason) do
    LocalArchitectGrantClaim.rollback_failed_claim(repo, grant_action)
    release_failed_local_architect_assignment_lease(repo, lease, lease_action, reason)
    revoke_failed_local_architect_assignment_grant(repo, session, lease_action, grant_action)
  end

  defp revoke_failed_local_architect_assignment_grant(repo, %Session{assignment: %{grant_id: grant_id}}, lease_action, :claimed)
       when lease_action in [:created, :reclaimed] and is_binary(grant_id) do
    _result = AccessGrantService.revoke(repo, grant_id)
    :ok
  end

  defp revoke_failed_local_architect_assignment_grant(_repo, %Session{}, _lease_action, _grant_action), do: :ok

  defp local_architect_assignment_claim_payload(claim, %ClaimLease{} = lease, lease_action, claim_event) do
    %{
      "tool" => @local_architect_assignment_claim_tool,
      "mode" => claim.mode,
      "repo" => claim.repo,
      "base_branch" => claim.base_branch,
      "work_request_id" => claim.work_request_id,
      "architect_anchor_work_package_id" => claim.architect_anchor_work_package_id,
      "phase_id" => claim.phase_id,
      "caller_id" => claim.caller_id,
      "claimed_by" => claim.claimed_by,
      "claim_lease_id" => lease.id,
      "claim_lease_status" => lease.status,
      "claim_lease_action" => Atom.to_string(lease_action),
      "lifecycle_state" => "active",
      "reason_codes" => local_architect_assignment_claim_reason_codes(lease_action, lease)
    }
    |> drop_nil_values()
    |> maybe_put_claim_event(claim_event)
  end

  defp append_local_architect_assignment_claim_event(_repo, %Session{}, _claim, %ClaimLease{}, lease_action) when lease_action != :reclaimed,
    do: {:ok, nil}

  defp append_local_architect_assignment_claim_event(repo, %Session{} = session, claim, %ClaimLease{} = lease, :reclaimed) do
    payload = local_architect_assignment_claim_reclaim_payload(claim, lease)

    PlanningRepository.append_audit_progress_event_for_work_package(
      repo,
      session.assignment,
      claim.architect_anchor_work_package_id,
      %{
        "summary" => "Local architect assignment claim lease reclaimed",
        "body" => "Local architect assignment claim lease was reclaimed for #{claim.claimed_by}.",
        "status" => "claim_lease_reclaimed",
        "idempotency_key" => metadata_idempotency_key(payload),
        "payload" => payload
      }
    )
  end

  defp local_architect_assignment_claim_reclaim_payload(claim, %ClaimLease{} = lease) do
    %{
      "type" => "claim_lease_reclaim",
      "source_tool" => @local_architect_assignment_claim_tool,
      "work_request_id" => claim.work_request_id,
      "architect_anchor_work_package_id" => claim.architect_anchor_work_package_id,
      "phase_id" => claim.phase_id,
      "claim_lease_id" => lease.id,
      "claim_group_id" => lease.claim_group_id,
      "previous_claim_id" => lease.previous_claim_id,
      "claim_lease_status" => lease.status,
      "claim_lease_action" => "reclaimed",
      "claimed_by" => claim.claimed_by,
      "caller_id" => claim.caller_id,
      "lifecycle_state" => "active",
      "reason_codes" => local_architect_assignment_claim_reason_codes(:reclaimed, lease)
    }
    |> drop_nil_values()
  end

  defp local_architect_assignment_claim_reason_codes(lease_action, %ClaimLease{} = lease) do
    [
      "claim_lease_#{lease_action}",
      if(lease.previous_claim_id, do: "architect_recycled")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp release_failed_local_architect_assignment_lease(repo, %ClaimLease{} = lease, lease_action, _reason)
       when lease_action in [:created, :reclaimed] do
    _result = ClaimLeaseService.release(repo, lease.id, reason: "local_architect_assignment_claim_failed")
    :ok
  end

  defp release_failed_local_architect_assignment_lease(repo, %ClaimLease{} = lease, :heartbeat, reason)
       when reason in [:expired, :revoked, :architect_grant_required, :already_claimed] do
    _result = ClaimLeaseService.release(repo, lease.id, reason: "local_architect_assignment_claim_failed")
    :ok
  end

  defp release_failed_local_architect_assignment_lease(_repo, %ClaimLease{}, _lease_action, _reason), do: :ok

  defp default_claimed_by(%__MODULE__{config: %Config{claimed_by: claimed_by}}) do
    case normalize_optional_value(claimed_by) do
      claimed_by when is_binary(claimed_by) -> claimed_by
      nil -> "local-agent"
    end
  end

  defp default_architect_claimed_by(%__MODULE__{}), do: ArchitectHandoff.claimed_by()

  defp default_caller_id(%__MODULE__{state_key_explicit: true} = server) do
    material =
      :erlang.term_to_binary({server.config.mode, server.state_key})

    "mcp-state:" <> LocalClaimLeases.actor_hash(material)
  end

  defp default_caller_id(%__MODULE__{config: %Config{mode: mode}}), do: "mcp-#{mode}:default"

  defp local_claim_transport_mode(%__MODULE__{config: %Config{mode: :http}}), do: "local-http"
  defp local_claim_transport_mode(%__MODULE__{config: %Config{mode: :stdio}}), do: "stdio"

  defp local_assignment_work_request_id(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    repo.one(
      from(planned_slice in PlannedSlice,
        where: planned_slice.work_package_id == ^work_package_id,
        order_by: [desc: planned_slice.dispatched_at, desc: planned_slice.updated_at, asc: planned_slice.id],
        select: planned_slice.work_request_id,
        limit: 1
      )
    )
  end

  defp local_assignment_worktree_branch_or_nil(nil), do: nil

  defp local_assignment_worktree_branch_or_nil(worktree_path) do
    case local_assignment_worktree_branch(worktree_path) do
      {:ok, branch} -> branch
      {:error, _reason} -> nil
    end
  end

  defp normalize_optional_local_assignment_path(nil), do: nil

  defp normalize_optional_local_assignment_path(path) when is_binary(path) do
    path
    |> normalize_optional_value()
    |> case do
      nil -> nil
      normalized -> normalize_local_assignment_path(normalized)
    end
  end

  defp normalize_local_assignment_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> Path.expand()
    |> normalize_local_assignment_path_case()
  end

  defp normalize_local_assignment_path_case(path) do
    case :os.type() do
      {:win32, _name} -> String.downcase(path)
      _type -> path
    end
  end

  defp require_worker_assignment(%{grant_role: "worker"}), do: :ok
  defp require_worker_assignment(_assignment), do: {:error, :worker_grant_required}

  defp require_architect_assignment(%{grant_role: "architect"}), do: :ok
  defp require_architect_assignment(_assignment), do: {:error, :architect_grant_required}

  defp require_assignment_introspection(%{grant_role: role}) when role in ["worker", "architect"], do: :ok
  defp require_assignment_introspection(_assignment), do: {:error, :unsupported_grant_role}

  defp require_architect_capability(%{capabilities: capabilities}, capability) when is_list(capabilities) do
    if capability in capabilities do
      :ok
    else
      {:error, :insufficient_capability}
    end
  end

  defp require_architect_capability(_assignment, _capability), do: {:error, :insufficient_capability}

  defp authorize_architect_tool_call(%__MODULE__{session: nil}, name) do
    {:error, -32_001, "Unauthorized", %{"resource" => name, "reason" => "claim_required", "action" => @local_architect_assignment_claim_tool}}
  end

  defp authorize_architect_tool_call(%__MODULE__{config: config, session: session}, "approve_scope_expansion") do
    with {:ok, _session} <- approve_scope_expansion_session(config.repo, session) do
      :ok
    end
  end

  defp authorize_architect_tool_call(%__MODULE__{config: config, session: session}, name) do
    with {:ok, _session} <- architect_session(config.repo, session, architect_tool_required_capabilities(name)) do
      :ok
    end
  end

  defp architect_tool_required_capabilities("read_child_status"), do: ["read:child_progress", "read:child_findings"]
  defp architect_tool_required_capabilities(name), do: [architect_tool_capability(name)]

  defp local_assignment_claim_error(:database_busy), do: service_error(:database_busy, @local_assignment_claim_tool)
  defp local_assignment_claim_error({:service_unavailable, _reason} = reason), do: service_error(reason, @local_assignment_claim_tool)
  defp local_assignment_claim_error({:storage_failed, _reason} = reason), do: service_error(reason, @local_assignment_claim_tool)
  defp local_assignment_claim_error({:migration_failed, _reason} = reason), do: service_error(reason, @local_assignment_claim_tool)

  defp local_assignment_claim_error({:session_already_bound, current_assignment}) do
    {:error, -32_001, "Unauthorized", session_already_bound_data(@local_assignment_claim_tool, current_assignment)}
  end

  defp local_assignment_claim_error(:claim_lease_active_for_other_actor) do
    {:error, -32_001, "Unauthorized",
     claim_lease_active_for_other_actor_data(
       @local_assignment_claim_tool,
       "Reuse the same work_package_id and claimed_by. If the live claim belongs to another owner or is stale, ask the architect or operator to recycle it."
     )}
  end

  defp local_assignment_claim_error(reason) do
    {:error, -32_001, "Unauthorized", %{"tool" => @local_assignment_claim_tool, "reason" => reason_text(reason)}}
  end

  defp local_architect_assignment_claim_error(:database_busy), do: service_error(:database_busy, @local_architect_assignment_claim_tool)

  defp local_architect_assignment_claim_error({:service_unavailable, _reason} = reason),
    do: service_error(reason, @local_architect_assignment_claim_tool)

  defp local_architect_assignment_claim_error({:storage_failed, _reason} = reason),
    do: service_error(reason, @local_architect_assignment_claim_tool)

  defp local_architect_assignment_claim_error({:migration_failed, _reason} = reason),
    do: service_error(reason, @local_architect_assignment_claim_tool)

  defp local_architect_assignment_claim_error({:session_already_bound, current_assignment}) do
    {:error, -32_001, "Unauthorized", session_already_bound_data(@local_architect_assignment_claim_tool, current_assignment)}
  end

  defp local_architect_assignment_claim_error(:claim_lease_active_for_other_actor) do
    {:error, -32_001, "Unauthorized",
     claim_lease_active_for_other_actor_data(
       @local_architect_assignment_claim_tool,
       "Reuse the same work_request_id and claimed_by. If the live claim belongs to another owner or is stale, ask the operator to recycle it."
     )}
  end

  defp local_architect_assignment_claim_error({:phase_scope_not_available, missing_evidence}) do
    {:error, -32_001, "Unauthorized", local_architect_phase_scope_not_available_data(missing_evidence)}
  end

  defp local_architect_assignment_claim_error(:phase_scope_not_available) do
    {:error, -32_001, "Unauthorized", local_architect_phase_scope_not_available_data([:architect_handoff_scope])}
  end

  defp local_architect_assignment_claim_error(:ambiguous_phase_scope) do
    {:error, -32_001, "Unauthorized",
     %{
       "tool" => @local_architect_assignment_claim_tool,
       "reason" => "ambiguous_phase_scope",
       "action" => "repair_local_architect_handoff_scope",
       "missing_evidence" => ["single_work_request_scope"],
       "hint" => "Keep exactly one WorkRequest scope on the architect handoff grant, or replay architect handoff from the local operator for the intended WorkRequest."
     }}
  end

  defp local_architect_assignment_claim_error({:work_request_terminal, terminal_state}) do
    {:error, -32_001, "Unauthorized",
     %{
       "tool" => @local_architect_assignment_claim_tool,
       "reason" => "work_request_terminal",
       "terminal_state" => reason_text(terminal_state),
       "action" => "restore_work_request_or_start_new_work_request",
       "hint" => "Restore the WorkRequest from the local operator if this lane should continue, or start a new WorkRequest for follow-up work."
     }}
  end

  defp local_architect_assignment_claim_error(reason) do
    {:error, -32_001, "Unauthorized", %{"tool" => @local_architect_assignment_claim_tool, "reason" => reason_text(reason)}}
  end

  defp local_architect_phase_scope_not_available_data(missing_evidence) do
    %{
      "tool" => @local_architect_assignment_claim_tool,
      "reason" => "phase_scope_not_available",
      "action" => "repair_local_architect_handoff_scope",
      "missing_evidence" => Enum.map(List.wrap(missing_evidence), &reason_text/1),
      "hint" =>
        "Use the local operator to restore the WorkRequest if it was archived, or replay architect handoff so the anchor package, grant, repo, base branch, phase id, and WorkRequest scope agree."
    }
  end

  defp claim_lease_active_for_other_actor_data(tool, hint) do
    %{
      "tool" => tool,
      "reason" => "claim_lease_active_for_other_actor",
      "action" => "reuse_claim_identity_or_recycle_stale_claim",
      "hint" => hint
    }
  end

  defp session_already_bound_data(tool, %__MODULE__{session: %Session{}} = server) do
    session_already_bound_data(tool, current_assignment_summary(server))
  end

  defp session_already_bound_data(tool, %__MODULE__{}) do
    session_already_bound_data(tool, nil)
  end

  defp session_already_bound_data(tool, current_assignment) when is_map(current_assignment) do
    tool
    |> session_already_bound_data(nil)
    |> Map.put("current_assignment", current_assignment)
  end

  defp session_already_bound_data(tool, _current_assignment) do
    %{
      "tool" => tool,
      "reason" => "session_already_bound",
      "action" => "use_fresh_mcp_session_or_release_current_assignment",
      "hint" => "This MCP session is already bound. Start a fresh MCP session for a different assignment, or call release_current_assignment only if abandoning the current binding."
    }
  end

  defp prepare_worker_tool_call(%__MODULE__{} = server, params, name) do
    with :ok <- require_tool_arguments_object(params, name),
         :ok <- preauthorize_worker_tool_call(server, name),
         :ok <- prepare_mcp_repository_for_tool(server.config.repo, name),
         :ok <- authorize_worker_tool_call(server, name) do
      worker_tool_arguments(params, name)
    end
  end

  defp prepare_architect_tool_call(%__MODULE__{} = server, params, name) do
    with :ok <- require_tool_arguments_object(params, name),
         :ok <- preauthorize_architect_tool_call(server, name),
         :ok <- prepare_mcp_repository_for_tool(server.config.repo, name),
         :ok <- maybe_authorize_architect_tool_call(server, name) do
      architect_tool_arguments(params, name)
    end
  end

  defp maybe_authorize_architect_tool_call(%__MODULE__{session: nil} = server, name) when name in @local_trusted_work_request_read_tools do
    authorize_local_trusted_work_request_read_tool_call(server, name)
  end

  defp maybe_authorize_architect_tool_call(%__MODULE__{config: config, session: session}, name) when name in @work_request_policy_tools do
    with {:ok, session} <- Auth.require_session(session, config.repo) do
      authorize_work_request_tool_policy_preauthorization(config.repo, session, name)
    end
  end

  defp maybe_authorize_architect_tool_call(%__MODULE__{config: config, session: session}, name) when name in @delivery_policy_tools do
    with {:ok, live_session} <- Auth.require_session(session, config.repo) do
      if name == "reconcile_work_request" do
        :ok
      else
        require_architect_capability(live_session.assignment, architect_tool_capability(name))
      end
    end
  end

  defp maybe_authorize_architect_tool_call(%__MODULE__{} = server, name), do: authorize_architect_tool_call(server, name)

  defp prepare_bootstrap_tool_call(%__MODULE__{} = server, params, name) do
    with :ok <- require_tool_arguments_object(params, name),
         :ok <- authorize_bootstrap_tool_call(server, name),
         :ok <- prepare_mcp_repository_for_tool(server.config.repo, name) do
      bootstrap_tool_arguments(params, name)
    end
  end

  defp prepare_assignment_release_tool_call(%__MODULE__{} = server, params) do
    with :ok <- require_tool_arguments_object(params, @assignment_release_tool),
         :ok <- prepare_mcp_repository_for_tool(server.config.repo, @assignment_release_tool) do
      assignment_release_tool_arguments(params)
    end
  end

  defp prepare_local_operator_tool_call(%__MODULE__{} = server, params, name) do
    with :ok <- require_tool_arguments_object(params, name),
         :ok <- authorize_local_operator_tool_call(server, name),
         :ok <- prepare_mcp_repository_for_tool(server.config.repo, name) do
      local_operator_tool_arguments(params, name)
    end
  end

  defp prepare_local_trusted_list_comments_tool_call(%__MODULE__{} = server, params) do
    with :ok <- require_tool_arguments_object(params, "list_comments"),
         :ok <- authorize_trusted_local_tool_call(server, "list_comments"),
         :ok <- prepare_mcp_repository_for_tool(server.config.repo, "list_comments") do
      architect_tool_arguments(params, "list_comments")
    end
  end

  defp require_tool_arguments_object(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) -> :ok
      _arguments -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp preauthorize_worker_tool_call(%__MODULE__{session: nil} = server, name) do
    {:error, -32_001, "Unauthorized", %{"resource" => name, "reason" => "claim_required", "action" => worker_claim_action(server)}}
  end

  defp preauthorize_worker_tool_call(%__MODULE__{session: session}, "get_current_assignment") do
    with {:ok, session} <- Auth.require_session(session) do
      require_assignment_introspection(session.assignment)
    end
  end

  defp preauthorize_worker_tool_call(%__MODULE__{session: session}, _name) do
    with {:ok, session} <- Auth.require_session(session) do
      require_worker_assignment(session.assignment)
    end
  end

  defp worker_claim_action(%__MODULE__{}) do
    @local_assignment_claim_tool
  end

  defp preauthorize_architect_tool_call(%__MODULE__{session: nil} = server, name) when name in @local_trusted_work_request_read_tools do
    authorize_local_trusted_work_request_read_tool_call(server, name)
  end

  defp preauthorize_architect_tool_call(%__MODULE__{session: nil} = server, name) do
    authorize_architect_tool_call(server, name)
  end

  defp preauthorize_architect_tool_call(%__MODULE__{session: session}, name) when name in @work_request_policy_tools do
    with {:ok, _session} <- Auth.require_session(session) do
      :ok
    end
  end

  defp preauthorize_architect_tool_call(%__MODULE__{session: session}, name) when name in @delivery_policy_tools do
    with {:ok, session} <- Auth.require_session(session) do
      if architect_session?(session), do: :ok, else: require_architect_assignment(session.assignment)
    end
  end

  defp preauthorize_architect_tool_call(%__MODULE__{session: session}, _name) do
    with {:ok, session} <- Auth.require_session(session) do
      require_architect_assignment(session.assignment)
    end
  end

  defp authorize_bootstrap_tool_call(%__MODULE__{} = server, tool), do: authorize_trusted_local_tool_call(server, tool)

  defp authorize_local_trusted_work_request_read_tool_call(%__MODULE__{} = server, tool) do
    authorize_local_operator_tool_call(server, tool)
  end

  defp authorize_local_operator_tool_call(%__MODULE__{} = server, tool), do: authorize_trusted_local_tool_call(server, tool)

  defp authorize_trusted_local_tool_call(%__MODULE__{} = server, tool), do: LocalTrustedTools.authorize(server, tool)

  defp prepare_mcp_repository(repo), do: Repository.ensure_migrated(repo)

  defp prepare_mcp_repository_for_tool(repo, tool) do
    case prepare_mcp_repository(repo) do
      :ok -> :ok
      {:error, reason} -> service_error(reason, tool)
    end
  end

  defp bootstrap_tool("create_work_request", arguments, %__MODULE__{config: config} = server) do
    with {:ok, requested_claimed_by} <- create_work_request_requested_claimed_by(arguments),
         {:ok, attrs} <- create_work_request_attrs(arguments, requested_claimed_by),
         {:ok, work_request} <- WorkRequestService.create(config.repo, attrs) do
      effective_claimed_by = requested_claimed_by || ArchitectHandoff.claimed_by()
      payload = create_work_request_handoff_payload(server, work_request, effective_claimed_by)

      {:ok, architect_agent_tool_result(payload, :create_work_request_handoff)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "create_work_request", "reason" => reason}}
      {:error, reason} -> create_work_request_error(reason)
    end
  end

  defp create_work_request_attrs(arguments, claimed_by) do
    with {:ok, repo} <- required_argument(arguments, "repo"),
         {:ok, base_branch} <- required_argument(arguments, "base_branch"),
         {:ok, title} <- required_argument(arguments, "title"),
         {:ok, request_kind} <- required_argument(arguments, "request_kind"),
         {:ok, description} <- create_work_request_description(arguments),
         {:ok, workflow_mode} <- optional_string_argument(arguments, "workflow_mode", "architect_led_feature_branch"),
         {:ok, repo_scopes} <- optional_list_argument(arguments, "repo_scopes"),
         {:ok, constraints} <- optional_object_argument(arguments, "constraints"),
         {:ok, status} <- optional_string_argument(arguments, "status", "ready_for_clarification"),
         {:ok, creator_kind} <- create_work_request_creator_kind(arguments),
         {:ok, creator_name} <- create_work_request_creator_name(arguments, claimed_by),
         {:ok, created_via} <- optional_string_argument(arguments, "created_via", "mcp") do
      {:ok,
       %{
         "repo" => repo,
         "base_branch" => base_branch,
         "title" => title,
         "work_type" => request_kind,
         "human_description" => description,
         "desired_dispatch_shape" => workflow_mode,
         "repo_scopes" => repo_scopes || [],
         "constraints" => constraints || %{},
         "status" => status,
         "creator_kind" => creator_kind,
         "creator_name" => creator_name,
         "created_via" => created_via
       }}
    end
  end

  defp create_work_request_description(arguments) do
    result =
      case optional_string_argument(arguments, "human_description") do
        {:ok, nil} -> optional_string_argument(arguments, "description")
        {:ok, description} -> {:ok, description}
        {:tool_error, reason} -> {:tool_error, reason}
      end

    case result do
      {:ok, nil} -> {:tool_error, "missing_description"}
      other -> other
    end
  end

  defp create_work_request_requested_claimed_by(arguments) do
    optional_string_argument(arguments, "claimed_by")
  end

  defp create_work_request_creator_kind(arguments) do
    case optional_string_argument(arguments, "creator_kind") do
      {:ok, nil} -> optional_string_argument(arguments, "created_by_kind", "agent")
      {:ok, kind} -> {:ok, kind}
      {:tool_error, reason} -> {:tool_error, reason}
    end
  end

  defp create_work_request_creator_name(arguments, claimed_by) do
    case optional_string_argument(arguments, "creator_name") do
      {:ok, nil} ->
        case optional_string_argument(arguments, "created_by_name") do
          {:ok, nil} -> {:ok, claimed_by || "mcp-agent"}
          result -> result
        end

      result ->
        result
    end
  end

  defp create_work_request_handoff_payload(%__MODULE__{} = server, %WorkRequest{} = work_request, claimed_by) do
    case create_work_request_architect_handoff(server, work_request, claimed_by) do
      {:ok, handoff} ->
        %{
          "status" => "created",
          "work_request" => work_request_payload(work_request),
          "architect_handoff" => json_safe_payload(handoff),
          "launch_prompt" => Map.get(handoff, :prompt)
        }
        |> drop_nil_values()

      {:error, reason} ->
        create_work_request_partial_handoff_payload(work_request, reason)
    end
  end

  defp create_work_request_partial_handoff_payload(%WorkRequest{} = work_request, reason) do
    %{
      "status" => "partial_success",
      "work_request" => work_request_payload(work_request),
      "architect_handoff" => nil,
      "handoff_error" => %{
        "reason" => reason_text(reason),
        "message" => ArchitectHandoff.error_message(reason)
      },
      "retry" => %{
        "type" => "manual_architect_handoff_replay",
        "work_request_id" => work_request.id,
        "operator_action" => "prepare_architect_handoff"
      }
    }
  end

  defp create_work_request_architect_handoff(%__MODULE__{config: config} = server, %WorkRequest{} = work_request, claimed_by) do
    with {:ok, handoff_opts} <- create_work_request_handoff_opts(config, claimed_by) do
      ArchitectHandoff.create_or_replay(config.repo, work_request.id,
        local_operator?: true,
        local_architect_claim?: local_architect_claim_handoff_enabled?(server),
        handoff_opts: handoff_opts
      )
    end
  end

  defp local_architect_claim_handoff_enabled?(%__MODULE__{} = server) do
    require_local_architect_assignment_claim_mode(server) == :ok
  end

  defp create_work_request_handoff_opts(%Config{} = config, claimed_by) do
    {:ok,
     [claimed_by: claimed_by]
     |> put_optional_handoff_opt(:database, create_work_request_handoff_database(config))}
  end

  defp create_work_request_handoff_database(%Config{} = config) do
    case dispatch_handoff_database(config.database, config.repo) do
      {:ok, database} -> database
      _result -> nil
    end
  end

  defp local_operator_tool("add_work_request_comment", arguments, %__MODULE__{config: config}) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, body} <- required_argument(arguments, "body"),
         {:ok, created_by} <- required_argument(arguments, "created_by"),
         {:ok, work_request} <- WorkRequestService.get(config.repo, work_request_id),
         {:ok, comment} <-
           CommentService.create(config.repo, %{
             "target_kind" => "work_request",
             "target_id" => work_request.id,
             "body" => Redactor.redact_text(body),
             "source_type" => "operator",
             "author_name" => Redactor.redact_text(created_by)
           }) do
      {:ok,
       tool_result(%{
         "comment" => comment_payload(comment),
         "work_request" => work_request_mutation_payload(work_request),
         "provenance" => local_operator_note_provenance(created_by)
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "add_work_request_comment", "reason" => reason}}
      {:error, :not_found} -> not_found_error("add_work_request_comment")
      {:error, reason} -> local_operator_error(reason, "add_work_request_comment")
    end
  end

  defp local_operator_tool("record_work_request_operator_decision", arguments, %__MODULE__{config: config}) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, decision} <- required_argument(arguments, "decision"),
         {:ok, rationale} <- required_argument(arguments, "rationale"),
         {:ok, scope_impact} <- required_argument(arguments, "scope_impact"),
         {:ok, created_by} <- required_argument(arguments, "created_by"),
         {:ok, source_id} <- optional_string_argument(arguments, "source_id"),
         {:ok, work_request} <- WorkRequestService.get(config.repo, work_request_id),
         {:ok, decision_record} <-
           WorkRequestService.record_decision(
             config.repo,
             work_request.id,
             local_operator_decision_attrs(decision, rationale, scope_impact, created_by, source_id)
           ) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(work_request),
         "decision_log_entry" => decision_log_entry_payload(decision_record),
         "provenance" => local_operator_note_provenance(created_by, source_id),
         "status" => %{"work_request_status" => work_request.status}
       })}
    else
      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => "record_work_request_operator_decision", "reason" => reason}}

      {:error, :not_found} ->
        not_found_error("record_work_request_operator_decision")

      {:error, reason} ->
        local_operator_error(reason, "record_work_request_operator_decision")
    end
  end

  defp local_operator_decision_attrs(decision, rationale, scope_impact, created_by, source_id) do
    %{
      "source_type" => "operator",
      "decision" => Redactor.redact_text(decision),
      "rationale" => Redactor.redact_text(rationale),
      "scope_impact" => Redactor.redact_text(scope_impact),
      "created_by" => Redactor.redact_text(created_by)
    }
    |> optional_put("source_id", Redactor.redact_text(source_id))
  end

  defp local_operator_note_provenance(created_by, source_id \\ nil) do
    %{"source_type" => "operator", "created_by" => Redactor.redact_text(created_by)}
    |> optional_put("source_id", Redactor.redact_text(source_id))
  end

  defp local_trusted_list_comments_tool(arguments, %__MODULE__{config: config}) do
    case LocalTrustedTools.list_comments(config.repo, arguments, &comment_payload/1) do
      {:ok, payload} -> {:ok, tool_result(payload)}
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "list_comments", "reason" => reason}}
      {:error, :not_found} -> not_found_error("list_comments")
      {:error, reason} -> architect_error(reason, "list_comments")
    end
  end

  defp architect_tool("list_work_requests", arguments, %__MODULE__{config: config, session: nil} = server) do
    with :ok <- authorize_local_trusted_work_request_read_tool_call(server, "list_work_requests"),
         {:ok, status} <- optional_work_request_status(arguments),
         filters = work_request_list_filters(%{}, status),
         {:ok, work_requests} <- WorkRequestService.list(config.repo, work_request_repository_filters(filters)) do
      cards = work_request_cards(work_requests)

      {:ok,
       agent_tool_result(%{
         "work_requests" => cards,
         "total_count" => length(cards),
         "scope" => %{"visibility" => "local_ledger"},
         "filters" => work_request_filter_payload(status)
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "list_work_requests", "reason" => reason}}
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "list_work_requests")
    end
  end

  defp architect_tool("list_work_requests", arguments, %__MODULE__{config: config, session: session}) do
    repo_scope_opts = work_request_repo_scope_opts(config)

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, status} <- optional_work_request_status(arguments),
         {:ok, filters, scope} <-
           scoped_work_request_filters(config.repo, session, handoff_phase_scope?: false),
         policy_session = read_scoped_work_request_session(config.repo, session, scope, :work_request_read),
         :ok <- authorize_work_request_list_policy(policy_session, scope, "list_work_requests", repo_scope_opts),
         filters = work_request_list_filters(filters, status),
         {:ok, work_requests} <- WorkRequestService.list(config.repo, work_request_repository_filters(filters)),
         {:ok, work_requests} <-
           filter_scoped_work_requests(config.repo, work_requests, filters, policy_session, repo_scope_opts) do
      cards = work_request_cards(work_requests)

      {:ok,
       agent_tool_result(%{
         "work_requests" => cards,
         "total_count" => length(cards),
         "scope" => scope,
         "filters" => work_request_filter_payload(status)
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "list_work_requests", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "list_work_requests")
    end
  end

  defp architect_tool("read_work_request", arguments, %__MODULE__{config: config, session: nil} = server) do
    with :ok <- authorize_local_trusted_work_request_read_tool_call(server, "read_work_request"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, work_request, _filters} <- local_trusted_work_request_read_scope(config.repo, work_request_id),
         {:ok, payload} <- work_request_detail_payload(config.repo, work_request, []) do
      payload = Map.put(payload, "scope", redacted_work_request_scope(work_request))
      {:ok, architect_agent_tool_result(payload, :work_request_read)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_work_request", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_work_request")
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "read_work_request")
    end
  end

  defp architect_tool("read_work_request", arguments, %__MODULE__{config: config, session: %Session{} = session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, work_request, _filters, scope} <-
           authorized_work_request_scope(
             config.repo,
             session,
             work_request_id,
             :work_request_read,
             "read_work_request",
             work_request_repo_scope_opts(config)
           ),
         {:ok, payload} <- work_request_detail_payload(config.repo, work_request, []) do
      payload = Map.put(payload, "scope", scope)
      {:ok, architect_agent_tool_result(payload, :work_request_read)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_work_request", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_work_request")
      {:error, reason} -> architect_error(reason, "read_work_request")
    end
  end

  defp architect_tool("read_work_request_product_tree", arguments, %__MODULE__{config: config, session: nil} = server) do
    with :ok <- authorize_local_trusted_work_request_read_tool_call(server, "read_work_request_product_tree"),
         {:ok, work_request_id, view} <- read_work_request_product_tree_arguments(arguments),
         {:ok, work_request, scope} <- local_trusted_work_request_read_scope(config.repo, work_request_id),
         {:ok, result} <-
           read_work_request_product_tree_result(
             config.repo,
             work_request,
             scope,
             scope,
             view
           ) do
      {:ok, result}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_work_request_product_tree", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_work_request_product_tree")
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "read_work_request_product_tree")
    end
  end

  defp architect_tool("read_work_request_product_tree", arguments, %__MODULE__{config: config, session: %Session{} = session}) do
    repo_scope_opts = work_request_repo_scope_opts(config)

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id, view} <- read_work_request_product_tree_arguments(arguments),
         {:ok, work_request, filters, scope} <-
           authorized_work_request_scope(
             config.repo,
             session,
             work_request_id,
             :work_request_read,
             "read_work_request_product_tree",
             repo_scope_opts
           ),
         {:ok, result} <- read_work_request_product_tree_result(config.repo, work_request, filters, scope, view, repo_scope_opts) do
      {:ok, result}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_work_request_product_tree", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_work_request_product_tree")
      {:error, reason} -> architect_error(reason, "read_work_request_product_tree")
    end
  end

  defp architect_tool(name, arguments, %__MODULE__{config: config, session: %Session{} = session})
       when name in ["add_comment", "list_comments", "resolve_comment"] do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, result} <- comment_tool_result(name, config.repo, session, arguments, :architect, session_claimed_by(session)) do
      {:ok, result}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => reason}}
      {:error, :not_found} -> not_found_error(name)
      {:error, reason} -> architect_error(reason, name)
    end
  end

  defp architect_tool("resolve_blocker", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_package_id} <- optional_string_argument(arguments, "work_package_id", Session.work_package_id(session)),
         {:ok, blocker_id} <- required_argument(arguments, "blocker_id"),
         {:ok, resolution} <- required_argument(arguments, "resolution"),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, caller_payload} <- optional_payload(arguments),
         {:ok, actor} <- actor_for_package_resource(config.repo, session, :blocker, work_package_id),
         :ok <- PlanningService.authorize_package_action(config.repo, actor, :blocker_resolve, work_package_id, :blocker),
         attrs = %{
           "summary" => summary,
           "body" => optional_argument(arguments, "body", nil),
           "status" => optional_argument(arguments, "status", "resolved"),
           "idempotency_key" => ["resolve_blocker", work_package_id, String.trim(idempotency_key)] |> Enum.join(":"),
           "payload" =>
             Map.merge(caller_payload, %{
               "type" => "blocker",
               "source_tool" => "resolve_blocker",
               "blocker_id" => blocker_id,
               "resolution" => resolution,
               "active" => false
             })
         },
         {:ok, event} <- PlanningRepository.append_audit_progress_event_for_work_package(config.repo, session.assignment, work_package_id, attrs) do
      {:ok, tool_result(%{"progress_event" => progress_event_payload(event)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "resolve_blocker", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "resolve_blocker")
    end
  end

  defp architect_tool("read_work_request_delivery_board", arguments, %__MODULE__{config: config, session: %Session{} = session}) do
    repo_scope_opts = work_request_repo_scope_opts(config)

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, work_request, filters, scope} <-
           authorized_work_request_scope(
             config.repo,
             session,
             work_request_id,
             :delivery_board_read,
             "read_work_request_delivery_board",
             repo_scope_opts
           ),
         {:ok, planned_slices} <- WorkRequestService.list_planned_slices(config.repo, work_request_id),
         {:ok, delivery_board} <- scoped_delivery_board(config.repo, work_request, planned_slices, filters, repo_scope_opts) do
      payload = %{
        "work_request" => work_request_mutation_payload(work_request),
        "delivery_board" => delivery_board_payload(delivery_board),
        "scope" => scope
      }

      {:ok, architect_agent_tool_result(payload, :work_request_delivery_board)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_work_request_delivery_board", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_work_request_delivery_board")
      {:error, reason} -> architect_error(reason, "read_work_request_delivery_board")
    end
  end

  defp architect_tool("read_work_request_delivery_board", arguments, %__MODULE__{config: config, session: nil} = server) do
    with :ok <- authorize_local_trusted_work_request_read_tool_call(server, "read_work_request_delivery_board"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, work_request, filters} <- local_trusted_work_request_read_scope(config.repo, work_request_id),
         {:ok, planned_slices} <- WorkRequestService.list_planned_slices(config.repo, work_request_id),
         {:ok, delivery_board} <- scoped_delivery_board(config.repo, work_request, planned_slices, filters) do
      payload = %{
        "work_request" => work_request_mutation_payload(work_request),
        "delivery_board" => delivery_board_payload(delivery_board),
        "scope" => redacted_work_request_scope(work_request)
      }

      {:ok, architect_agent_tool_result(payload, :work_request_delivery_board)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_work_request_delivery_board", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_work_request_delivery_board")
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "read_work_request_delivery_board")
    end
  end

  defp architect_tool("reconcile_work_request", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, apply?} <- optional_boolean(arguments, "apply", false),
         {:ok, live_session} <- Auth.require_session(session, config.repo),
         :ok <- require_delivery_reconcile_capability(live_session, apply?),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, live_session),
         {:ok, recorded_by} <- optional_string_argument(arguments, "recorded_by", session_claimed_by(live_session)),
         {:ok, work_request, filters, scope} <-
           authorized_work_request_scope(config.repo, live_session, work_request_id, reconcile_work_request_action(apply?), "reconcile_work_request"),
         {:ok, planned_slices} <- WorkRequestService.list_planned_slices(config.repo, work_request_id),
         {visible_work_package_ids, work_package_contexts} <-
           visible_delivery_board_work_package_contexts(config.repo, work_request, planned_slices, filters),
         {:ok, reconciliation} <-
           reconcile_work_request(config.repo, live_session, work_request_id, apply?, recorded_by,
             mode: reconcile_work_request_mode(apply?),
             work_request: work_request,
             planned_slices: planned_slices,
             visible_work_package_ids: visible_work_package_ids,
             work_package_contexts: work_package_contexts
           ) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(work_request),
         "reconciliation" => reconciliation_payload(reconciliation),
         "delivery_board" => delivery_board_payload(Map.fetch!(reconciliation, :delivery_board)),
         "scope" => scope
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "reconcile_work_request", "reason" => reason}}
      {:error, :not_found} -> not_found_error("reconcile_work_request")
      {:error, reason} -> architect_error(reason, "reconcile_work_request")
    end
  end

  defp architect_tool("record_planned_slice_delivery", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, live_session} <- Auth.require_session(session, config.repo),
         :ok <- require_delivery_write_capability(live_session),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, live_session),
         {:ok, planned_slice_id} <- required_argument(arguments, "planned_slice_id"),
         {:ok, outcome} <- required_planned_slice_delivery_outcome(arguments),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, recorded_by} <- optional_string_argument(arguments, "recorded_by", session_claimed_by(live_session)),
         {:ok, attrs} <- planned_slice_delivery_attrs(arguments, outcome, idempotency_key, recorded_by),
         {:ok, work_request, planned_slice, filters, scope} <-
           authorized_planned_slice_scope(
             config.repo,
             live_session,
             work_request_id,
             planned_slice_id,
             :delivery_closeout_record,
             "record_planned_slice_delivery"
           ),
         :ok <- require_planned_slice_delivery_scope(config.repo, work_request, planned_slice, attrs, filters),
         {:ok, attrs, blocker_closeout_plan} <-
           maybe_prepare_slice_delivery_blocker_closeout(config.repo, live_session, planned_slice, arguments, attrs),
         {:ok, {delivery, blocker_closeout}} <-
           mutate_product_tree(
             config.repo,
             work_request_id,
             "record_planned_slice_delivery",
             recorded_by,
             fn ->
               record_planned_slice_delivery_with_blocker_closeout(
                 config.repo,
                 live_session,
                 work_request_id,
                 planned_slice_id,
                 attrs,
                 blocker_closeout_plan
               )
             end
           ),
         {:ok, planned_slices} <- WorkRequestService.list_planned_slices(config.repo, work_request_id),
         {:ok, delivery_board} <- scoped_delivery_board(config.repo, work_request, planned_slices, filters) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(work_request),
         "planned_slice_delivery" => planned_slice_delivery_payload(delivery),
         "blocker_closeout" => blocker_closeout,
         "delivery_board" => delivery_board_payload(delivery_board),
         "scope" => scope
       })}
    else
      {:tool_error, reason} -> invalid_params_error("record_planned_slice_delivery", reason)
      {:error, :not_found} -> not_found_error("record_planned_slice_delivery")
      {:error, reason} -> record_planned_slice_delivery_error(reason)
    end
  end

  defp architect_tool(name, arguments, %__MODULE__{} = server) when name in ["cleanup_work_request_planned_slice_runtime", "revoke_planned_slice_worker_key"],
    do: delivery_runtime_architect_tool(name, arguments, server)

  defp architect_tool("list_guidance_requests", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "read:guidance_request"),
         {:ok, status} <- optional_guidance_request_status(arguments),
         {:ok, work_package_id} <- optional_string_argument(arguments, "work_package_id"),
         {:ok, requested_work_request_id} <- optional_string_argument(arguments, "work_request_id"),
         {:ok, work_request_id} <-
           guidance_work_request_id_argument(requested_work_request_id, session, work_package_id),
         :ok <- maybe_require_guidance_work_request_filter_scope(config.repo, session, requested_work_request_id),
         {:ok, filters, scope} <- scoped_guidance_request_filters(config.repo, session),
         {:ok, filters} <- guidance_request_list_filters(config.repo, filters, status, work_package_id, work_request_id),
         {:ok, guidance_requests} <- GuidanceRequestService.list_visible_to_architect(config.repo, filters) do
      cards = guidance_request_cards(guidance_requests)

      payload = %{
        "guidance_requests" => cards,
        "total_count" => length(cards),
        "scope" => scope,
        "filters" => guidance_request_filter_payload(status, work_package_id, work_request_id)
      }

      {:ok, architect_agent_tool_result(payload, :guidance_request_list)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "list_guidance_requests", "reason" => reason}}
      {:error, :not_found} -> not_found_error("list_guidance_requests")
      {:error, reason} -> architect_error(reason, "list_guidance_requests")
    end
  end

  defp architect_tool("answer_guidance_request", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "write:guidance_request"),
         {:ok, guidance_request_id} <- required_argument(arguments, "guidance_request_id"),
         {:ok, answer} <- required_argument(arguments, "answer"),
         {:ok, answered_by} <- optional_string_argument(arguments, "answered_by", session_claimed_by(session)),
         {:ok, filters, scope} <- scoped_guidance_request_filters(config.repo, session),
         {:ok, visible_guidance_request} <- GuidanceRequestService.get_visible_to_architect(config.repo, guidance_request_id, filters),
         :ok <- authorize_guidance_request_for_session(config.repo, session, :guidance_request_answer, visible_guidance_request),
         {:ok, guidance_request} <-
           GuidanceRequestService.answer(config.repo, guidance_request_id, %{
             "answer" => answer,
             "answered_by" => answered_by,
             "answered_at" => DateTime.utc_now(:microsecond)
           }) do
      {:ok,
       tool_result(%{
         "guidance_request" => guidance_request_payload(guidance_request),
         "scope" => scope,
         "status" => %{"guidance_request_status" => guidance_request.status}
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "answer_guidance_request", "reason" => reason}}
      {:error, :not_found} -> not_found_error("answer_guidance_request")
      {:error, reason} -> architect_error(reason, "answer_guidance_request")
    end
  end

  defp architect_tool("escalate_guidance_request", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "write:guidance_request"),
         {:ok, guidance_request_id} <- required_argument(arguments, "guidance_request_id"),
         {:ok, reason} <- required_argument(arguments, "reason"),
         {:ok, recommended_language} <- required_argument(arguments, "recommended_language"),
         {:ok, decision_prompt} <- optional_decision_prompt_argument(arguments, "decision_prompt"),
         {:ok, result} <-
           escalate_guidance_request_transaction(
             config.repo,
             session,
             guidance_request_id,
             reason,
             recommended_language,
             decision_prompt
           ) do
      {:ok, tool_result(result)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "escalate_guidance_request", "reason" => reason}}
      {:error, :not_found} -> not_found_error("escalate_guidance_request")
      {:error, reason} -> architect_error(reason, "escalate_guidance_request")
    end
  end

  defp architect_tool("set_work_request_status", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, current_status} <- required_argument(arguments, "current_status"),
         {:ok, next_status} <- required_argument(arguments, "next_status"),
         {:ok, _work_request, _filters, scope} <-
           authorized_work_request_scope(config.repo, session, work_request_id, :work_request_update, "set_work_request_status"),
         {:ok, updated_work_request} <- WorkRequestService.update_status(config.repo, work_request_id, current_status, next_status) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "scope" => scope,
         "status" => %{
           "previous_status" => current_status,
           "current_status" => updated_work_request.status
         }
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "set_work_request_status", "reason" => reason}}
      {:error, :not_found} -> not_found_error("set_work_request_status")
      {:error, reason} -> architect_error(reason, "set_work_request_status")
    end
  end

  defp architect_tool("ask_work_request_question", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, category} <- required_argument(arguments, "category"),
         {:ok, question} <- required_argument(arguments, "question"),
         {:ok, why_needed} <- required_argument(arguments, "why_needed"),
         {:ok, decision_prompt} <- optional_decision_prompt_argument(arguments, "decision_prompt"),
         {:ok, asked_by_agent_run_id} <- optional_string_argument(arguments, "asked_by_agent_run_id"),
         {:ok, _work_request, filters, scope} <-
           authorized_work_request_scope(config.repo, session, work_request_id, :question_create, "ask_work_request_question"),
         {:ok, question_record} <-
           WorkRequestService.ask_question(
             config.repo,
             work_request_id,
             optional_put(
               %{
                 "category" => category,
                 "question" => question,
                 "why_needed" => why_needed
               },
               "decision_prompt",
               decision_prompt
             )
             |> optional_put(
               "asked_by_agent_run_id",
               asked_by_agent_run_id
             )
           ),
         {:ok, updated_work_request} <- scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "clarification_question" => clarification_question_payload(question_record),
         "scope" => scope,
         "status" => %{
           "work_request_status" => updated_work_request.status,
           "question_status" => question_record.status
         }
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "ask_work_request_question", "reason" => reason}}
      {:error, :not_found} -> not_found_error("ask_work_request_question")
      {:error, reason} -> architect_error(reason, "ask_work_request_question")
    end
  end

  defp architect_tool("answer_work_request_question", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, question_id} <- required_argument(arguments, "question_id"),
         {:ok, expected_question_status} <- expected_question_status_argument(arguments),
         {:ok, answer} <- required_argument(arguments, "answer"),
         {:ok, answered_by} <- optional_string_argument(arguments, "answered_by", session_claimed_by(session)),
         {:ok, _work_request, filters, scope} <-
           authorized_work_request_scope(config.repo, session, work_request_id, :question_answer, "answer_work_request_question"),
         {:ok, _question} <- scoped_work_request_question(config.repo, work_request_id, question_id),
         {:ok, question_record} <-
           WorkRequestService.answer_question(config.repo, question_id, expected_question_status, %{
             "answer" => answer,
             "answered_by" => answered_by
           }),
         {:ok, updated_work_request} <- scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "clarification_question" => clarification_question_payload(question_record),
         "scope" => scope,
         "status" => %{
           "work_request_status" => updated_work_request.status,
           "previous_question_status" => expected_question_status,
           "question_status" => question_record.status
         }
       })}
    else
      {:tool_error, reason} -> invalid_params_error("answer_work_request_question", reason)
      {:error, :not_found} -> not_found_error("answer_work_request_question")
      {:error, reason} -> architect_error(reason, "answer_work_request_question")
    end
  end

  defp architect_tool("answer_work_request_question_and_record_decision", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, question_id} <- required_argument(arguments, "question_id"),
         {:ok, expected_question_status} <- expected_question_status_argument(arguments),
         {:ok, answer} <- required_argument(arguments, "answer"),
         {:ok, answered_by} <- optional_string_argument(arguments, "answered_by", session_claimed_by(session)),
         {:ok, source_type} <- required_argument(arguments, "source_type"),
         {:ok, decision} <- required_argument(arguments, "decision"),
         {:ok, rationale} <- required_argument(arguments, "rationale"),
         {:ok, scope_impact} <- required_argument(arguments, "scope_impact"),
         {:ok, created_by} <- optional_string_argument(arguments, "created_by", answered_by),
         {:ok, source_id} <- optional_string_argument(arguments, "source_id", question_id),
         {:ok, work_request, filters, scope} <-
           authorized_work_request_scope(
             config.repo,
             session,
             work_request_id,
             :question_answer,
             "answer_work_request_question_and_record_decision"
           ),
         :ok <-
           authorize_work_request_policy(
             config.repo,
             session,
             :decision_record,
             work_request,
             "answer_work_request_question_and_record_decision"
           ),
         {:ok, _question} <- scoped_work_request_question(config.repo, work_request_id, question_id),
         {:ok, %{decision: decision_record, question: question_record}} <-
           answer_question_and_record_decision_transaction(config.repo, work_request_id, question_id, expected_question_status, %{
             "answer" => answer,
             "answered_by" => answered_by,
             "source_type" => source_type,
             "source_id" => source_id,
             "decision" => decision,
             "rationale" => rationale,
             "scope_impact" => scope_impact,
             "created_by" => created_by
           }),
         {:ok, updated_work_request} <- scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "clarification_question" => clarification_question_payload(question_record),
         "decision_log_entry" => decision_log_entry_payload(decision_record),
         "scope" => scope,
         "status" => %{
           "work_request_status" => updated_work_request.status,
           "previous_question_status" => expected_question_status,
           "question_status" => question_record.status
         }
       })}
    else
      {:tool_error, reason} -> invalid_params_error("answer_work_request_question_and_record_decision", reason)
      {:error, :not_found} -> not_found_error("answer_work_request_question_and_record_decision")
      {:error, reason} -> architect_error(reason, "answer_work_request_question_and_record_decision")
    end
  end

  defp architect_tool("close_work_request_question", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, question_id} <- required_argument(arguments, "question_id"),
         {:ok, expected_question_status} <- expected_question_status_argument(arguments),
         {:ok, _work_request, filters, scope} <-
           authorized_work_request_scope(config.repo, session, work_request_id, :question_close, "close_work_request_question"),
         {:ok, _question} <- scoped_work_request_question(config.repo, work_request_id, question_id),
         {:ok, question_record} <- WorkRequestService.close_question(config.repo, question_id, expected_question_status),
         {:ok, updated_work_request} <- scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "clarification_question" => clarification_question_payload(question_record),
         "scope" => scope,
         "status" => %{
           "work_request_status" => updated_work_request.status,
           "previous_question_status" => expected_question_status,
           "question_status" => question_record.status
         }
       })}
    else
      {:tool_error, reason} -> invalid_params_error("close_work_request_question", reason)
      {:error, :not_found} -> not_found_error("close_work_request_question")
      {:error, reason} -> architect_error(reason, "close_work_request_question")
    end
  end

  defp architect_tool("record_work_request_decision", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, source_type} <- required_argument(arguments, "source_type"),
         {:ok, decision} <- required_argument(arguments, "decision"),
         {:ok, rationale} <- required_argument(arguments, "rationale"),
         {:ok, scope_impact} <- required_argument(arguments, "scope_impact"),
         {:ok, created_by} <- required_argument(arguments, "created_by"),
         {:ok, source_id} <- optional_string_argument(arguments, "source_id"),
         {:ok, _work_request, filters, scope} <-
           authorized_work_request_scope(config.repo, session, work_request_id, :decision_record, "record_work_request_decision"),
         {:ok, decision_record} <-
           WorkRequestService.record_decision(
             config.repo,
             work_request_id,
             optional_put(
               %{
                 "source_type" => source_type,
                 "decision" => decision,
                 "rationale" => rationale,
                 "scope_impact" => scope_impact,
                 "created_by" => created_by
               },
               "source_id",
               source_id
             )
           ),
         {:ok, updated_work_request} <- scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "decision_log_entry" => decision_log_entry_payload(decision_record),
         "scope" => scope,
         "status" => %{"work_request_status" => updated_work_request.status}
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "record_work_request_decision", "reason" => reason}}
      {:error, :not_found} -> not_found_error("record_work_request_decision")
      {:error, reason} -> architect_error(reason, "record_work_request_decision")
    end
  end

  defp architect_tool("add_work_request_planned_slice", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, title} <- required_argument(arguments, "title"),
         {:ok, goal} <- required_argument(arguments, "goal"),
         {:ok, work_package_kind} <- required_argument(arguments, "work_package_kind"),
         {:ok, delivery_repo} <- optional_string_argument(arguments, "delivery_repo"),
         {:ok, target_base_branch} <- required_argument(arguments, "target_base_branch"),
         {:ok, owned_file_globs} <- required_string_array(arguments, "owned_file_globs"),
         {:ok, forbidden_file_globs} <- required_string_array(arguments, "forbidden_file_globs"),
         {:ok, acceptance_criteria} <- required_string_array(arguments, "acceptance_criteria"),
         {:ok, validation_steps} <- required_string_array(arguments, "validation_steps"),
         {:ok, review_lanes} <- required_string_array(arguments, "review_lanes"),
         {:ok, stop_conditions} <- required_string_array(arguments, "stop_conditions"),
         {:ok, branch_pattern} <- optional_string_argument(arguments, "branch_pattern"),
         :ok <- require_supported_branch_pattern(branch_pattern),
         {:ok, work_request, filters, scope} <-
           authorized_work_request_scope(config.repo, session, work_request_id, :planned_slice_create, "add_work_request_planned_slice"),
         :ok <- validate_planned_slice_scope_for_tool(work_request, work_package_kind, owned_file_globs),
         attrs =
           optional_put(
             %{
               "title" => title,
               "goal" => goal,
               "work_package_kind" => work_package_kind,
               "delivery_repo" => delivery_repo,
               "target_base_branch" => target_base_branch,
               "owned_file_globs" => owned_file_globs,
               "forbidden_file_globs" => forbidden_file_globs,
               "acceptance_criteria" => acceptance_criteria,
               "validation_steps" => validation_steps,
               "review_lanes" => review_lanes,
               "stop_conditions" => stop_conditions
             },
             "branch_pattern",
             branch_pattern
           ),
         {:ok, {planned_slice, updated_work_request}} <-
           mutate_product_tree(
             config.repo,
             work_request_id,
             "add_work_request_planned_slice",
             session_claimed_by(session),
             fn -> add_planned_slice_and_reload_work_request(config.repo, work_request_id, attrs, filters) end
           ) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "planned_slice" => planned_slice_payload(planned_slice),
         "scope" => scope,
         "status" => %{
           "work_request_status" => updated_work_request.status,
           "planned_slice_status" => planned_slice.status
         }
       })}
    else
      {:tool_error, reason} ->
        invalid_params_error("add_work_request_planned_slice", reason)

      {:error, %Ecto.Changeset{}} ->
        {:error, -32_602, "Invalid params", %{"tool" => "add_work_request_planned_slice", "reason" => "invalid_planned_slice"}}

      {:error, :not_found} ->
        not_found_error("add_work_request_planned_slice")

      {:error, reason} ->
        architect_error(reason, "add_work_request_planned_slice")
    end
  end

  defp architect_tool("upsert_work_request_product_plan_node_content", arguments, %__MODULE__{config: config, session: session}) do
    tool = "upsert_work_request_product_plan_node_content"

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, product_tree_node_id} <- optional_string_argument(arguments, "product_tree_node_id"),
         {:ok, title} <- optional_string_argument(arguments, "title"),
         {:ok, description} <- optional_string_argument(arguments, "description"),
         {:ok, node_kind} <- optional_string_argument(arguments, "node_kind"),
         {:ok, created_by} <- optional_string_argument(arguments, "created_by", session_claimed_by(session)),
         :ok <- require_product_plan_node_content(product_tree_node_id, title, description, node_kind),
         {:ok, work_request, _filters, scope} <-
           authorized_work_request_scope(config.repo, session, work_request_id, :work_request_update, tool),
         :ok <- require_planned_slice_authoring_status(work_request.status),
         {:ok, current_parent_id} <- product_plan_node_current_parent_id(config.repo, work_request_id, product_tree_node_id),
         attrs =
           %{
             "work_request_id" => work_request_id
           }
           |> optional_put("id", product_tree_node_id)
           |> optional_put("parent_id", current_parent_id)
           |> optional_put("title", title)
           |> optional_put("description", description)
           |> optional_put("node_kind", node_kind)
           |> optional_put("created_by", created_by),
         {:ok, {{product_tree_node, blocker_closeout}, detail}} <-
           mutate_product_plan_node(config.repo, session, work_request_id, tool, created_by, attrs, :not_needed) do
      {:ok, product_plan_node_tool_result(work_request, product_tree_node, blocker_closeout, detail, scope)}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, %Ecto.Changeset{}} -> invalid_params_error(tool, "invalid_product_plan_node")
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  defp architect_tool("move_work_request_product_plan_node", arguments, %__MODULE__{config: config, session: session}) do
    tool = "move_work_request_product_plan_node"
    parent_id_supplied? = Map.has_key?(arguments, "parent_id")

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, product_tree_node_id} <- required_argument(arguments, "product_tree_node_id"),
         {:ok, parent_id} <- optional_string_argument(arguments, "parent_id"),
         {:ok, position} <- optional_nonnegative_integer_argument(arguments, "position"),
         {:ok, created_by} <- optional_string_argument(arguments, "created_by", session_claimed_by(session)),
         :ok <- require_product_plan_node_topology(parent_id_supplied?, position),
         {:ok, work_request, _filters, scope} <-
           authorized_work_request_scope(config.repo, session, work_request_id, :work_request_update, tool),
         :ok <- require_planned_slice_authoring_status(work_request.status),
         attrs =
           %{
             "work_request_id" => work_request_id,
             "id" => product_tree_node_id
           }
           |> optional_put_present("parent_id", parent_id, parent_id_supplied?)
           |> optional_put("position", position)
           |> optional_put("created_by", created_by),
         {:ok, {{product_tree_node, blocker_closeout}, detail}} <-
           mutate_product_plan_node(config.repo, session, work_request_id, tool, created_by, attrs, :not_needed) do
      {:ok, product_plan_node_tool_result(work_request, product_tree_node, blocker_closeout, detail, scope)}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, %Ecto.Changeset{}} -> invalid_params_error(tool, "invalid_product_plan_node")
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  defp architect_tool("set_work_request_product_plan_node_completion", arguments, %__MODULE__{config: config, session: session}) do
    tool = "set_work_request_product_plan_node_completion"

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, product_tree_node_id} <- required_argument(arguments, "product_tree_node_id"),
         {:ok, completion_mark} <- required_argument(arguments, "completion_mark"),
         :ok <- require_product_tree_completion_mark(completion_mark),
         {:ok, created_by} <- optional_string_argument(arguments, "created_by", session_claimed_by(session)),
         {:ok, work_request, _filters, scope} <-
           authorized_work_request_scope(config.repo, session, work_request_id, :work_request_update, tool),
         :ok <- require_planned_slice_authoring_status(work_request.status),
         attrs =
           %{
             "work_request_id" => work_request_id,
             "id" => product_tree_node_id,
             "completion_mark" => completion_mark
           }
           |> optional_put("created_by", created_by),
         {:ok, blocker_closeout_plan} <-
           maybe_prepare_product_plan_node_blocker_closeout(
             config.repo,
             session,
             work_request_id,
             product_tree_node_id,
             completion_mark,
             arguments,
             tool
           ),
         {:ok, {{product_tree_node, blocker_closeout}, detail}} <-
           mutate_product_plan_node(config.repo, session, work_request_id, tool, created_by, attrs, blocker_closeout_plan) do
      {:ok, product_plan_node_tool_result(work_request, product_tree_node, blocker_closeout, detail, scope)}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, %Ecto.Changeset{}} -> invalid_params_error(tool, "invalid_product_plan_node")
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  defp architect_tool("move_work_request_planned_slice_to_product_node", arguments, %__MODULE__{config: config, session: session}) do
    tool = "move_work_request_planned_slice_to_product_node"

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, planned_slice_id} <- required_argument(arguments, "planned_slice_id"),
         {:ok, product_tree_node_id} <- optional_string_argument(arguments, "product_tree_node_id"),
         {:ok, role} <- optional_string_argument(arguments, "role"),
         {:ok, position} <- optional_nonnegative_integer_argument(arguments, "position"),
         {:ok, created_by} <- optional_string_argument(arguments, "created_by", session_claimed_by(session)),
         {:ok, work_request, _filters, scope} <-
           authorized_work_request_scope(config.repo, session, work_request_id, :work_request_update, tool),
         :ok <- require_planned_slice_authoring_status(work_request.status),
         attrs =
           %{
             "work_request_id" => work_request_id,
             "planned_slice_id" => planned_slice_id
           }
           |> optional_put("product_tree_node_id", product_tree_node_id)
           |> optional_put("role", role)
           |> optional_put("position", position)
           |> optional_put("created_by", created_by),
         {:ok, {slice_link, detail}} <-
           mutate_product_tree_with_projection(config.repo, work_request_id, tool, created_by, fn ->
             ProductTree.move_slice_link(config.repo, attrs)
           end) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(work_request),
         "product_tree_slice_link" => product_tree_slice_link_payload(slice_link),
         "product_tree" => json_safe_payload(detail.product_tree),
         "scope" => scope,
         "status" => %{
           "work_request_status" => work_request.status,
           "slice_product_tree_location" => if(is_nil(slice_link), do: "direct", else: "product_plan_node")
         }
       })}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, %Ecto.Changeset{}} -> invalid_params_error(tool, "invalid_product_tree_slice_link")
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  defp architect_tool("approve_work_request_planned_slice", arguments, %__MODULE__{config: config, session: session}) do
    mutate_work_request_planned_slice_status(
      "approve_work_request_planned_slice",
      arguments,
      config.repo,
      session,
      "approved",
      :planned_slice_approve
    )
  end

  defp architect_tool("skip_work_request_planned_slice", arguments, %__MODULE__{config: config, session: session}) do
    mutate_work_request_planned_slice_status(
      "skip_work_request_planned_slice",
      arguments,
      config.repo,
      session,
      "skipped",
      :planned_slice_skip
    )
  end

  defp architect_tool("mark_work_request_sliced", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, current_status} <- required_argument(arguments, "current_status"),
         {:ok, _work_request, _filters, scope} <-
           authorized_work_request_scope(config.repo, session, work_request_id, :work_request_update, "mark_work_request_sliced"),
         {:ok, updated_work_request} <- WorkRequestService.mark_sliced(config.repo, work_request_id, current_status) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "scope" => scope,
         "status" => %{
           "previous_status" => current_status,
           "current_status" => updated_work_request.status
         }
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "mark_work_request_sliced", "reason" => reason}}
      {:error, :not_found} -> not_found_error("mark_work_request_sliced")
      {:error, reason} -> architect_error(reason, "mark_work_request_sliced")
    end
  end

  defp architect_tool("dispatch_work_request_planned_slice", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, planned_slice_id} <- required_argument(arguments, "planned_slice_id"),
         {:ok, claimed_by} <- optional_string_argument(arguments, "claimed_by", default_claimed_by(%__MODULE__{config: config})),
         {:ok, _work_request, planned_slice, _filters, scope} <-
           authorized_planned_slice_scope(
             config.repo,
             session,
             work_request_id,
             planned_slice_id,
             :planned_slice_dispatch,
             "dispatch_work_request_planned_slice"
           ),
         :ok <- require_approved_dispatch_planned_slice(planned_slice),
         {:ok, handoff_opts, dispatch_opts} <- dispatch_planned_slice_bootstrap_opts(config, claimed_by),
         {:ok, dispatch} <- PlannedSliceDispatch.dispatch(config.repo, work_request_id, planned_slice_id, handoff_opts, dispatch_opts) do
      {:ok, tool_result(dispatch_work_request_planned_slice_payload(dispatch, scope))}
    else
      {:tool_error, reason} -> invalid_params_error("dispatch_work_request_planned_slice", reason)
      {:error, :not_found} -> not_found_error("dispatch_work_request_planned_slice")
      {:error, reason} -> dispatch_work_request_planned_slice_error(reason)
    end
  end

  defp architect_tool("prepare_work_package_worktree", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "dispatch:work_request"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, work_package, scope} <- scoped_worktree_work_package(config.repo, session, work_package_id),
         {:ok, target_repo_root} <- worktree_target_repo_root_argument(arguments, work_package, config),
         {:ok, branch_arg} <- optional_string_argument(arguments, "branch"),
         {:ok, branch} <- worktree_prepare_branch(work_package, branch_arg),
         :ok <- require_target_repo_root_scope(target_repo_root, work_package, config),
         {:ok, result} <-
           WorkPackageService.prepare_worktree(
             config.repo,
             work_package_id,
             %{
               "target_repo_root" => target_repo_root,
               "base_branch" => work_package.base_branch,
               "branch" => branch
             }
           ),
         {:ok, audit_event} <- append_worktree_lifecycle_audit(config.repo, session, work_package_id, "prepare_work_package_worktree", result) do
      {:ok, tool_result(worktree_lifecycle_payload(result, scope, audit_event))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "prepare_work_package_worktree", "reason" => reason}}
      {:error, :not_found} -> not_found_error("prepare_work_package_worktree")
      {:error, reason} -> architect_error(reason, "prepare_work_package_worktree")
    end
  end

  defp architect_tool("cleanup_work_package_worktree", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "dispatch:work_request"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, target_repo_root} <- optional_string_argument(arguments, "target_repo_root"),
         {:ok, work_package, scope} <- scoped_worktree_work_package(config.repo, session, work_package_id),
         {:ok, cleanup_target_repo_root} <- cleanup_worktree_target_repo_root(target_repo_root, work_package, config),
         :ok <- require_cleanup_target_repo_root_scope(cleanup_target_repo_root, work_package, config),
         {:ok, result} <-
           WorkPackageService.cleanup_worktree(
             config.repo,
             work_package_id,
             cleanup_worktree_opts(cleanup_target_repo_root)
           ),
         {:ok, _runtime_cleanup} <- cleanup_worktree_runtime(config.repo, session, work_package),
         {:ok, audit_event} <- maybe_append_cleanup_worktree_audit(config.repo, session, work_package_id, result) do
      {:ok, tool_result(worktree_lifecycle_payload(result, scope, audit_event))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "cleanup_work_package_worktree", "reason" => reason}}
      {:error, :not_found} -> not_found_error("cleanup_work_package_worktree")
      {:error, reason} -> architect_error(reason, "cleanup_work_package_worktree")
    end
  end

  defp architect_tool("read_child_status", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, ["read:child_progress", "read:child_findings"]),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         :ok <- require_architect_child_status_scope(config.repo, session, work_package_id),
         {:ok, summary} <- PlanningRepository.get_status_summary(config.repo, work_package_id) do
      {:ok,
       tool_result(%{
         "work_package" => work_package_payload(summary.work_package),
         "plan_version" => plan_version(summary.plan_nodes),
         "finding_count" => summary.finding_count,
         "progress_event_count" => summary.progress_event_count,
         "artifact_count" => summary.artifact_count
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_child_status", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "read_child_status")
    end
  end

  defp architect_tool("create_child_work_package", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "create:child_work_package"),
         {:ok, package} <- required_object(arguments, "package"),
         {:ok, work_package} <- create_child_work_package_transaction(config.repo, session, package) do
      {:ok, tool_result(%{"work_package" => child_work_package_payload(work_package)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "create_child_work_package", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "create_child_work_package")
    end
  end

  defp architect_tool("mint_child_worker_key", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "mint:child_worker_key"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, template} <- optional_object_argument(arguments, "template"),
         {:ok, payload} <- mint_child_worker_key(config, session, work_package_id, template) do
      {:ok, tool_result(payload)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "mint_child_worker_key", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "mint_child_worker_key")
    end
  end

  defp architect_tool("revoke_child_worker_key", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "revoke:child_worker_key"),
         {:ok, grant_id} <- required_revoke_child_worker_string(arguments, "grant_id"),
         {:ok, reason} <- required_revoke_child_worker_string(arguments, "reason"),
         {:ok, payload} <- revoke_child_worker_key_transaction(config.repo, session, grant_id, reason) do
      {:ok, tool_result(payload)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "revoke_child_worker_key", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "revoke_child_worker_key")
    end
  end

  defp architect_tool("approve_scope_expansion", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- approve_scope_expansion_session(config.repo, session),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, work_package, work_request} <- approve_scope_expansion_work_package(config.repo, session, work_package_id),
         {:ok, allowed_file_globs} <- required_string_list(arguments, "allowed_file_globs"),
         :ok <- require_scope_expansion_work_request_scope(work_request, allowed_file_globs),
         {:ok, rationale} <- required_argument(arguments, "rationale"),
         {:ok, result} <-
           approve_scope_expansion_transaction(
             config.repo,
             session,
             work_package,
             work_request,
             arguments,
             allowed_file_globs,
             rationale
           ) do
      {:ok, tool_result(result)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "approve_scope_expansion", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "approve_scope_expansion")
    end
  end

  defp architect_tool("read_phase_board", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "read:phase"),
         {:ok, phase_id} <- required_argument(arguments, "phase_id"),
         :ok <- require_architect_phase_scope(config.repo, session, phase_id),
         {:ok, grant} <- require_architect_phase_board_grant(config.repo, session, phase_id),
         {:ok, board} <- Dashboard.phase_board_for_grant(config.repo, phase_id, grant) do
      {:ok, tool_result(json_safe_payload(board))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_phase_board", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "read_phase_board")
    end
  end

  defp architect_tool("approve_child_ready_state", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "approve:child_ready_state"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, rationale} <- required_argument(arguments, "rationale"),
         {:ok, request_id} <- optional_request_id(arguments, "request_id"),
         {:ok, result} <-
           approve_child_ready_state_transaction(config.repo, session, work_package_id, rationale, request_id) do
      {:ok, tool_result(result)}
    else
      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => "approve_child_ready_state", "reason" => reason}}

      {:error, {:readiness_failed, missing, reasons}} ->
        {:error, -32_602, "Invalid params", %{"tool" => "approve_child_ready_state", "reason" => "readiness_failed", "missing" => missing, "reasons" => reasons}}

      {:error, reason} ->
        architect_error(reason, "approve_child_ready_state")
    end
  end

  defp architect_tool("merge_child_into_phase", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "merge:child_into_phase"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, merge_artifact} <- required_object(arguments, "merge_artifact"),
         {:ok, result} <- merge_child_into_phase_transaction(config.repo, session, work_package_id, merge_artifact) do
      {:ok, tool_result(result)}
    else
      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => "merge_child_into_phase", "reason" => reason}}

      {:error, reason} ->
        architect_error(reason, "merge_child_into_phase")
    end
  end

  defp architect_tool(name, arguments, %__MODULE__{config: config, session: session}) when name in @phase7_stub_architect_tools do
    with {:ok, session} <- architect_session(config.repo, session, architect_tool_capability(name)),
         :ok <- require_architect_target_scope(config.repo, session, arguments) do
      phase7_not_implemented(name)
    else
      {:error, reason} -> architect_error(reason, name)
    end
  end

  defp cleanup_work_request_planned_slice_runtime_tool(arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, live_session} <- Auth.require_session(session, config.repo),
         :ok <- require_delivery_write_capability(live_session),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, live_session),
         {:ok, planned_slice_id} <- required_argument(arguments, "planned_slice_id"),
         {:ok, outcome} <- required_runtime_cleanup_delivery_outcome(arguments),
         {:ok, reason} <- required_argument(arguments, "reason"),
         {:ok, delivery_evidence} <-
           runtime_cleanup_delivery_evidence_attrs(arguments, outcome, work_request_id, planned_slice_id),
         {:ok, work_request, planned_slice, filters, scope} <-
           authorized_planned_slice_scope(
             config.repo,
             live_session,
             work_request_id,
             planned_slice_id,
             :work_package_repair_state,
             "cleanup_work_request_planned_slice_runtime"
           ),
         :ok <- require_planned_slice_delivery_scope(config.repo, work_request, planned_slice, delivery_evidence, filters),
         {:ok, work_package_id} <- planned_slice_work_package_id(config.repo, work_request, planned_slice),
         {:ok, cleanup} <-
           run_architect_transaction(config.repo, fn ->
             cleanup_work_request_planned_slice_runtime_in_transaction(
               config.repo,
               live_session,
               work_request,
               planned_slice,
               work_package_id,
               reason,
               delivery_evidence,
               filters
             )
           end) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(work_request),
         "planned_slice" => planned_slice_payload(planned_slice),
         "work_package" => child_work_package_payload(Map.fetch!(cleanup, :work_package)),
         "runtime_cleanup" => Map.fetch!(cleanup, :runtime_cleanup),
         "audit_event" => progress_event_payload(Map.fetch!(cleanup, :audit_event)),
         "scope" => scope
       })}
    else
      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => "cleanup_work_request_planned_slice_runtime", "reason" => reason}}

      {:error, :not_found} ->
        not_found_error("cleanup_work_request_planned_slice_runtime")

      {:error, reason} ->
        work_request_runtime_cleanup_error(reason)
    end
  end

  defp delivery_runtime_architect_tool("cleanup_work_request_planned_slice_runtime", arguments, %__MODULE__{} = server),
    do: cleanup_work_request_planned_slice_runtime_tool(arguments, server)

  defp delivery_runtime_architect_tool("revoke_planned_slice_worker_key", arguments, %__MODULE__{} = server),
    do: revoke_planned_slice_worker_key_tool(arguments, server)

  defp revoke_planned_slice_worker_key_tool(arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, live_session} <- Auth.require_session(session, config.repo),
         :ok <- require_delivery_write_capability(live_session),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, live_session),
         {:ok, planned_slice_id} <- required_argument(arguments, "planned_slice_id"),
         {:ok, grant_id} <- required_argument(arguments, "grant_id"),
         {:ok, reason} <- required_argument(arguments, "reason"),
         {:ok, work_request, planned_slice, filters, scope} <-
           authorized_planned_slice_scope(
             config.repo,
             live_session,
             work_request_id,
             planned_slice_id,
             :work_package_repair_state,
             "revoke_planned_slice_worker_key"
           ),
         {:ok, work_package_id} <- planned_slice_work_package_id(config.repo, work_request, planned_slice),
         {:ok, payload} <-
           run_architect_transaction(config.repo, fn ->
             revoke_planned_slice_worker_key_in_transaction(
               config.repo,
               live_session,
               work_request,
               planned_slice,
               work_package_id,
               grant_id,
               reason,
               filters
             )
           end) do
      {:ok, tool_result(Map.put(payload, "scope", scope))}
    else
      {:tool_error, reason} ->
        planned_slice_worker_revoke_tool_error(reason)

      {:error, :not_found} ->
        not_found_error("revoke_planned_slice_worker_key")

      {:error, reason} ->
        architect_error(reason, "revoke_planned_slice_worker_key")
    end
  end

  defp read_work_request_product_tree_arguments(arguments) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, view} <- optional_product_tree_view(arguments) do
      {:ok, work_request_id, view}
    end
  end

  defp read_work_request_product_tree_result(
         repo,
         %WorkRequest{} = work_request,
         filters,
         scope,
         view,
         repo_scope_opts \\ []
       ) do
    with {:ok, payload} <-
           work_request_product_tree_payload(
             repo,
             work_request,
             filters,
             Keyword.merge(repo_scope_opts, view: view)
           ) do
      payload = Map.put(payload, "scope", scope)
      {:ok, architect_agent_tool_result(payload, :work_request_product_tree)}
    end
  end

  defp add_planned_slice_and_reload_work_request(repo, work_request_id, attrs, filters) do
    with {:ok, planned_slice} <- WorkRequestService.add_planned_slice_for_authoring(repo, work_request_id, attrs),
         {:ok, updated_work_request} <- scoped_work_request(repo, work_request_id, filters) do
      {:ok, {planned_slice, updated_work_request}}
    end
  end

  defp mutate_work_request_planned_slice_status(tool, arguments, repo, session, next_status, action) do
    with {:ok, session} <- Auth.require_session(session, repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, planned_slice_id} <- required_argument(arguments, "planned_slice_id"),
         {:ok, current_status} <- required_argument(arguments, "current_status"),
         {:ok, work_request, planned_slice_for_validation, filters, scope} <-
           authorized_planned_slice_scope(repo, session, work_request_id, planned_slice_id, action, tool),
         :ok <- require_planned_slice_authoring_status(work_request.status),
         :ok <-
           maybe_validate_planned_slice_scope_for_approval(next_status, work_request, planned_slice_for_validation),
         {:ok, {planned_slice, updated_work_request}} <-
           mutate_product_tree(
             repo,
             work_request_id,
             tool,
             session_claimed_by(session),
             fn ->
               update_planned_slice_and_work_request(
                 repo,
                 work_request_id,
                 planned_slice_id,
                 current_status,
                 next_status,
                 filters
               )
             end
           ) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "planned_slice" => planned_slice_payload(planned_slice),
         "scope" => scope,
         "status" => %{
           "work_request_status" => updated_work_request.status,
           "previous_planned_slice_status" => current_status,
           "planned_slice_status" => planned_slice.status
         }
       })}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  defp update_planned_slice_and_work_request(
         repo,
         work_request_id,
         planned_slice_id,
         current_status,
         next_status,
         filters
       ) do
    with {:ok, planned_slice} <-
           update_work_request_planned_slice_status(
             repo,
             work_request_id,
             planned_slice_id,
             current_status,
             next_status
           ),
         {:ok, updated_work_request} <- scoped_work_request(repo, work_request_id, filters) do
      {:ok, {planned_slice, updated_work_request}}
    end
  end

  defp update_work_request_planned_slice_status(repo, work_request_id, planned_slice_id, current_status, "approved") do
    WorkRequestService.approve_planned_slice(repo, work_request_id, planned_slice_id, current_status)
  end

  defp update_work_request_planned_slice_status(repo, work_request_id, planned_slice_id, current_status, "skipped") do
    WorkRequestService.skip_planned_slice(repo, work_request_id, planned_slice_id, current_status)
  end

  defp validate_planned_slice_scope_for_tool(%WorkRequest{} = work_request, work_package_kind, owned_file_globs) do
    with :ok <- ScopeConstraints.validate_owned_file_globs(work_request, owned_file_globs),
         :ok <- validate_docs_planned_slice_scope(work_package_kind, owned_file_globs) do
      :ok
    else
      {:error, errors} -> {:tool_error, {:planned_slice_scope_violation, errors}}
    end
  end

  defp maybe_validate_planned_slice_scope_for_approval("approved", %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice) do
    validate_planned_slice_scope_for_tool(
      work_request,
      planned_slice.work_package_kind,
      planned_slice.owned_file_globs || []
    )
  end

  defp maybe_validate_planned_slice_scope_for_approval(_next_status, %WorkRequest{}, %PlannedSlice{}), do: :ok

  defp validate_docs_planned_slice_scope("docs", owned_file_globs), do: ScopeConstraints.validate_docs_owned_file_globs(owned_file_globs)
  defp validate_docs_planned_slice_scope(_work_package_kind, _owned_file_globs), do: :ok

  defp dispatch_planned_slice_bootstrap_opts(%Config{} = config, claimed_by) do
    with {:ok, database} <- dispatch_handoff_database(config.database, config.repo) do
      {:ok, [claimed_by: claimed_by, database: database], []}
    end
  end

  defp cleanup_worktree_opts(nil), do: []
  defp cleanup_worktree_opts(target_repo_root), do: [target_repo_root: target_repo_root]

  defp cleanup_worktree_runtime(repo, %Session{} = session, %WorkPackage{} = work_package) do
    run_architect_transaction(repo, fn ->
      cleanup_worktree_runtime_in_transaction(repo, session, work_package.id)
    end)
  end

  defp cleanup_worktree_runtime_in_transaction(repo, %Session{} = session, work_package_id) do
    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, _architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, work_request, planned_slice} <- cleanup_worktree_runtime_scope(repo, work_package_id),
         true <- cleanup_worktree_claim_only_runtime?(repo, work_package_id) do
      WorkRequestRuntimeCleanup.cleanup(
        repo,
        work_request,
        planned_slice,
        work_package,
        session.assignment,
        reason: "cleanup_work_package_worktree",
        delivery_evidence: %{"outcome" => "worktree_cleanup"}
      )
    else
      false -> {:ok, nil}
      {:error, :not_found} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_worktree_runtime_scope(repo, work_package_id) do
    query =
      from(planned_slice in PlannedSlice,
        join: work_request in WorkRequest,
        on: work_request.id == planned_slice.work_request_id,
        where: planned_slice.work_package_id == ^work_package_id,
        select: {work_request, planned_slice},
        limit: 1
      )

    case repo.one(query) do
      {%WorkRequest{} = work_request, %PlannedSlice{} = planned_slice} -> {:ok, work_request, planned_slice}
      nil -> {:error, :not_found}
    end
  end

  defp cleanup_worktree_claim_only_runtime?(repo, work_package_id) do
    now = DateTime.utc_now(:microsecond)
    context = WorkPackageActivity.context(repo, work_package_id)
    reason_codes = List.wrap(get_in(context, [:runtime_state, :reason_codes]))

    with {:ok, grants} <- AccessGrantRepository.list_for_work_package(repo, work_package_id) do
      not Enum.any?(grants, &live_worker_grant?(&1, now)) and get_in(context, [:runtime_state, :paused?]) != true and
        reason_codes -- ["claim_lease_active", "claim_lease_stale", "worker_recycled", "package_terminal"] == []
    end
  end

  defp live_worker_grant?(%AccessGrant{grant_role: "worker", revoked_at: nil, expires_at: nil}, _now), do: true

  defp live_worker_grant?(%AccessGrant{grant_role: "worker", revoked_at: nil, expires_at: %DateTime{} = expires_at}, now) do
    DateTime.compare(expires_at, now) == :gt
  end

  defp live_worker_grant?(%AccessGrant{}, _now), do: false

  defp cleanup_worktree_target_repo_root(target_repo_root, %WorkPackage{}, %Config{}) when is_binary(target_repo_root),
    do: {:ok, target_repo_root}

  defp cleanup_worktree_target_repo_root(nil, %WorkPackage{worktree_path: nil}, %Config{}), do: {:ok, nil}

  defp cleanup_worktree_target_repo_root(nil, %WorkPackage{worktree_target_repo_root: target_repo_root}, %Config{})
       when is_binary(target_repo_root),
       do: {:ok, target_repo_root}

  defp cleanup_worktree_target_repo_root(nil, %WorkPackage{} = work_package, %Config{} = config) do
    resolve_worktree_target_repo_root(nil, work_package, config)
  end

  defp worktree_target_repo_root_argument(arguments, %WorkPackage{} = work_package, %Config{} = config) do
    with {:ok, explicit_root} <- optional_string_argument(arguments, "target_repo_root") do
      resolve_worktree_target_repo_root(explicit_root, work_package, config)
    end
  end

  defp resolve_worktree_target_repo_root(target_repo_root, %WorkPackage{}, %Config{}) when is_binary(target_repo_root), do: {:ok, target_repo_root}

  defp resolve_worktree_target_repo_root(nil, %WorkPackage{worktree_path: worktree_path} = work_package, %Config{} = config)
       when is_binary(worktree_path) do
    work_package
    |> recorded_worktree_target_repo_root_candidates(config, worktree_path)
    |> scoped_worktree_target_repo_root(work_package, config)
  end

  defp resolve_worktree_target_repo_root(nil, %WorkPackage{} = work_package, %Config{} = config) do
    work_package
    |> worktree_target_repo_root_candidates(config)
    |> scoped_worktree_target_repo_root(work_package, config)
  end

  defp scoped_worktree_target_repo_root(candidates, %WorkPackage{} = work_package, %Config{} = config) do
    candidates
    |> Enum.find_value(fn target_repo_root ->
      case require_target_repo_root_scope(target_repo_root, work_package, config) do
        :ok -> {:ok, target_repo_root}
        _error -> nil
      end
    end)
    |> case do
      nil -> {:tool_error, "target_repo_root_required"}
      result -> result
    end
  end

  defp worktree_target_repo_root_candidates(%WorkPackage{repo: repo}, %Config{repo_root: repo_root}) do
    WorktreeTargetRoot.checkout_candidates(repo, repo_root)
  end

  defp recorded_worktree_target_repo_root_candidates(%WorkPackage{} = work_package, %Config{} = config, worktree_path) do
    [live_worktree_target_repo_root(worktree_path) | worktree_target_repo_root_candidates(work_package, config)]
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn target_repo_root ->
      with {:ok, target_repo_root} <- PathSafety.canonicalize(target_repo_root),
           true <- recorded_worktree_matches_target_repo_root?(target_repo_root, work_package, worktree_path) do
        [target_repo_root]
      else
        _result -> []
      end
    end)
    |> Enum.uniq()
  end

  defp recorded_worktree_matches_target_repo_root?(target_repo_root, %WorkPackage{} = work_package, worktree_path) do
    WorktreeTargetRoot.target_root_matches_worktree?(target_repo_root, work_package, worktree_path) or
      recorded_flat_worktree_matches_target_repo_root?(target_repo_root, work_package, worktree_path)
  end

  defp recorded_flat_worktree_matches_target_repo_root?(target_repo_root, %WorkPackage{} = work_package, worktree_path) do
    case worktree_prepare_branch(work_package, nil) do
      {:ok, branch} -> WorktreePath.current_worktree_path?(target_repo_root, work_package.id, branch, worktree_path)
      _result -> false
    end
  end

  defp live_worktree_target_repo_root(worktree_path) do
    with true <- File.dir?(worktree_path),
         true <- WorktreeTargetRoot.git_metadata_present?(worktree_path),
         {:ok, repo_root} <- WorktreeTargetRoot.from_live_worktree(worktree_path, []) do
      repo_root
    else
      _result -> nil
    end
  end

  defp worktree_prepare_branch(%WorkPackage{} = work_package, branch) when is_binary(branch) do
    case require_local_branch_pattern_scope(work_package, branch, prepared_worktree?: true) do
      :ok -> {:ok, branch}
      {:error, :branch_scope_mismatch} -> {:tool_error, "branch_scope_mismatch"}
      {:tool_error, reason} -> {:tool_error, reason}
    end
  end

  defp worktree_prepare_branch(%WorkPackage{branch_pattern: branch_pattern}, nil) do
    case normalize_optional_value(branch_pattern) do
      nil ->
        {:tool_error, "branch_required"}

      pattern ->
        if local_branch_template_pattern?(pattern) do
          {:tool_error, "branch_required"}
        else
          {:ok, pattern}
        end
    end
  end

  defp dispatch_handoff_database(nil, repo) do
    with {:ok, live_database} <- live_file_backed_dispatch_database(repo),
         configured_database <- configured_repo_dispatch_database(repo) do
      dispatch_handoff_database_for_default_config(configured_database, live_database)
    end
  end

  defp dispatch_handoff_database(database, repo) when is_binary(database) do
    database
    |> String.trim()
    |> dispatch_handoff_database_for_trimmed_config(database, repo)
  end

  defp dispatch_handoff_database_for_default_config({:ok, configured_database}, live_database) do
    cond do
      configured_dispatch_database_matches_live?(configured_database, live_database) and
          writable_dispatch_database?(configured_database) ->
        {:ok, configured_database}

      configured_dispatch_database_matches_live?(configured_database, live_database) ->
        {:tool_error, "read_only_database"}

      true ->
        {:ok, live_database}
    end
  end

  defp dispatch_handoff_database_for_default_config(:none, live_database), do: {:ok, live_database}

  defp dispatch_handoff_database_for_trimmed_config("", _database, repo), do: dispatch_handoff_database(nil, repo)

  defp dispatch_handoff_database_for_trimmed_config(_trimmed_database, database, repo) do
    dispatch_handoff_database_for_configured_path(database, repo)
  end

  defp dispatch_handoff_database_for_configured_path(database, repo) when is_binary(database) do
    with false <- Repo.memory_database?(database),
         {:ok, live_database} <- live_file_backed_dispatch_database(repo) do
      database
      |> normalize_configured_dispatch_database()
      |> configured_dispatch_database_result(live_database)
    else
      true -> {:tool_error, "file_backed_database_required"}
      error -> error
    end
  end

  defp configured_dispatch_database_result(configured_database, live_database) do
    if configured_dispatch_database_matches_live?(configured_database, live_database) and
         writable_dispatch_database?(configured_database) do
      {:ok, configured_database}
    else
      configured_dispatch_database_error(configured_database, live_database)
    end
  end

  defp normalize_configured_dispatch_database("file:" <> _uri = database) do
    normalize_sqlite_file_uri(database)
  end

  defp normalize_configured_dispatch_database(database) when is_binary(database) do
    if Path.type(database) == :absolute do
      database
    else
      Path.expand(database)
    end
  end

  defp normalize_sqlite_file_uri(database) do
    case Repo.sqlite_file_uri_path(database) do
      path when is_binary(path) and path != "" ->
        put_sqlite_file_uri_path(database, Path.expand(path))

      _path ->
        database
    end
  end

  defp put_sqlite_file_uri_path("file:" <> uri, expanded_path) do
    encoded_path = encode_sqlite_file_uri_path(expanded_path)

    case String.split(uri, "?", parts: 2) do
      [_uri_path, query] -> "file:" <> encoded_path <> "?" <> query
      [_uri_path] -> "file:" <> encoded_path
    end
  end

  defp encode_sqlite_file_uri_path(path) do
    path
    |> String.replace("\\", "/")
    |> URI.encode(&sqlite_file_uri_path_char?/1)
  end

  defp sqlite_file_uri_path_char?(char), do: URI.char_unreserved?(char) or char in [?/, ?:]

  defp writable_dispatch_database?("file:" <> _uri = database) do
    query_params = sqlite_file_uri_query_params(database)
    mode = query_params |> Map.get("mode", "") |> String.downcase()

    mode not in ["ro", "memory"] and not truthy_sqlite_uri_param?(Map.get(query_params, "immutable"))
  end

  defp writable_dispatch_database?(_database), do: true

  defp configured_dispatch_database_error(configured_database, live_database) do
    if configured_dispatch_database_matches_live?(configured_database, live_database) do
      {:tool_error, "read_only_database"}
    else
      {:tool_error, "database_scope_mismatch"}
    end
  end

  defp configured_dispatch_database_matches_live?("file:" <> _uri = database, live_database) do
    case Repo.sqlite_file_uri_path(database) do
      path when is_binary(path) and path != "" ->
        Repo.same_database_path?(path, live_database)

      _path ->
        false
    end
  end

  defp configured_dispatch_database_matches_live?(database, live_database) do
    Repo.same_database_path?(database, live_database)
  end

  defp configured_repo_dispatch_database(repo) when is_atom(repo) do
    cond do
      function_exported?(repo, :database_path_if_present, 0) ->
        repo.database_path_if_present()
        |> configured_repo_dispatch_database_value()

      function_exported?(repo, :database_path, 0) ->
        repo.database_path()
        |> configured_repo_dispatch_database_value()

      true ->
        :none
    end
  rescue
    _error -> :none
  catch
    _kind, _reason -> :none
  end

  defp configured_repo_dispatch_database(_repo), do: :none

  defp configured_repo_dispatch_database_value(database) when is_binary(database) do
    if String.trim(database) == "" do
      :none
    else
      configured_repo_dispatch_database_path_value(database)
    end
  end

  defp configured_repo_dispatch_database_value(_database), do: :none

  defp configured_repo_dispatch_database_path_value(database) when is_binary(database) do
    if Repo.memory_database?(database) do
      :none
    else
      {:ok, normalize_configured_dispatch_database(database)}
    end
  end

  defp sqlite_file_uri_query_params("file:" <> uri) do
    case String.split(uri, "?", parts: 2) do
      [_path, query] -> URI.decode_query(query)
      [_path] -> %{}
    end
  end

  defp truthy_sqlite_uri_param?(value) when is_binary(value), do: String.downcase(value) in ["1", "true", "yes", "on"]
  defp truthy_sqlite_uri_param?(_value), do: false

  defp live_file_backed_dispatch_database(repo) do
    case live_main_database_path(repo) do
      {:ok, path} -> {:ok, path}
      :memory -> {:tool_error, "file_backed_database_required"}
      :error -> {:tool_error, "database_required"}
    end
  end

  defp require_approved_dispatch_planned_slice(%PlannedSlice{status: "approved"}), do: :ok

  defp require_approved_dispatch_planned_slice(%PlannedSlice{status: status}),
    do: {:error, {:invalid_planned_slice_status, status}}

  defp require_supported_branch_pattern(branch_pattern) do
    case BranchPattern.validate(branch_pattern) do
      :ok -> :ok
      {:error, reason} -> {:tool_error, {:branch_pattern, branch_pattern, reason}}
    end
  end

  defp dispatch_work_request_planned_slice_error({:invalid_planned_slice_status, _status}) do
    {:error, -32_602, "Invalid params", %{"tool" => "dispatch_work_request_planned_slice", "reason" => "invalid_planned_slice_status"}}
  end

  defp dispatch_work_request_planned_slice_error({:invalid_work_request_status, _status}) do
    {:error, -32_602, "Invalid params", %{"tool" => "dispatch_work_request_planned_slice", "reason" => "invalid_work_request_status"}}
  end

  defp dispatch_work_request_planned_slice_error({:planned_slice_scope_violation, errors}) do
    invalid_params_error("dispatch_work_request_planned_slice", {:planned_slice_scope_violation, errors})
  end

  defp dispatch_work_request_planned_slice_error({:unsupported_branch_pattern, branch_pattern, reason}) do
    invalid_params_error("dispatch_work_request_planned_slice", {:branch_pattern, branch_pattern, reason})
  end

  defp dispatch_work_request_planned_slice_error({:kind_not_dispatchable, _kind}) do
    {:error, -32_602, "Invalid params", %{"tool" => "dispatch_work_request_planned_slice", "reason" => "kind_not_dispatchable"}}
  end

  defp dispatch_work_request_planned_slice_error({:dispatch_link_failed, _reason, recovery}) do
    {:error, -32_000, "Server error",
     %{
       "tool" => "dispatch_work_request_planned_slice",
       "reason" => "dispatch_link_failed",
       "recovery" => dispatch_link_recovery_payload(recovery)
     }}
  end

  defp dispatch_work_request_planned_slice_error(reason), do: architect_error(reason, "dispatch_work_request_planned_slice")

  defp record_planned_slice_delivery_error(%Ecto.Changeset{}) do
    {:error, -32_602, "Invalid params", %{"tool" => "record_planned_slice_delivery", "reason" => "invalid_planned_slice_delivery"}}
  end

  defp record_planned_slice_delivery_error(reason)
       when reason in [:delivery_outcome_conflict, :missing_strong_pr_evidence, :idempotency_key_conflict] do
    {:error, -32_602, "Invalid params", %{"tool" => "record_planned_slice_delivery", "reason" => Atom.to_string(reason)}}
  end

  defp record_planned_slice_delivery_error(reason) when reason in [:active_runtime, :claim_not_current, :work_package_not_abandonable] do
    delivery_closeout_precondition_error("record_planned_slice_delivery", reason)
  end

  defp record_planned_slice_delivery_error(reason), do: architect_error(reason, "record_planned_slice_delivery")

  defp work_request_runtime_cleanup_error(reason) do
    if runtime_cleanup_precondition_error?(reason) do
      delivery_closeout_precondition_error(
        "cleanup_work_request_planned_slice_runtime",
        runtime_cleanup_precondition_reason(reason)
      )
    else
      architect_error(reason, "cleanup_work_request_planned_slice_runtime")
    end
  end

  defp runtime_cleanup_precondition_error?(reason) do
    reason in [:active_runtime, :claim_not_current, :worker_grant_revoke_conflict, :mcp_session_binding_conflict]
  end

  defp runtime_cleanup_precondition_reason(:worker_grant_revoke_conflict), do: :claim_not_current
  defp runtime_cleanup_precondition_reason(:mcp_session_binding_conflict), do: :claim_not_current
  defp runtime_cleanup_precondition_reason(reason), do: reason

  defp planned_slice_worker_revoke_tool_error(reason)
       when reason == "planned_slice_worker_revoke_conflict" do
    delivery_closeout_precondition_error("revoke_planned_slice_worker_key", :claim_not_current)
  end

  defp planned_slice_worker_revoke_tool_error(reason) do
    {:error, -32_602, "Invalid params", %{"tool" => "revoke_planned_slice_worker_key", "reason" => reason}}
  end

  defp delivery_closeout_precondition_error(tool, :claim_not_current) do
    precondition_error(tool, "runtime_lease_conflict")
  end

  defp delivery_closeout_precondition_error(tool, reason) when is_atom(reason) do
    precondition_error(tool, Atom.to_string(reason))
  end

  defp precondition_error(tool, reason) do
    {:error, -32_009, "Precondition Failed",
     %{
       "tool" => tool,
       "reason" => reason,
       "reason_code" => reason,
       "decision_reason" => "precondition_denied"
     }}
  end

  defp append_worktree_lifecycle_audit(repo, %Session{} = session, work_package_id, source_tool, result) do
    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, work_package_id, %{
      "summary" => worktree_lifecycle_summary(source_tool, result.status),
      "status" => result.status,
      "idempotency_key" => worktree_lifecycle_idempotency_key(work_package_id, source_tool, result),
      "payload" => %{
        "type" => "worktree_lifecycle",
        "source_tool" => source_tool,
        "work_package_id" => work_package_id,
        "worktree_path" => audit_local_path(result.worktree_path),
        "target_repo_root" => audit_local_path(result.target_repo_root || result.repo_root),
        "branch" => result.branch,
        "base_branch" => result.base_branch,
        "status" => result.status
      }
    })
  end

  defp maybe_append_cleanup_worktree_audit(_repo, _session, _work_package_id, %{status: "already_clean"}), do: {:ok, nil}

  defp maybe_append_cleanup_worktree_audit(repo, %Session{} = session, work_package_id, result) do
    append_worktree_lifecycle_audit(repo, session, work_package_id, "cleanup_work_package_worktree", result)
  end

  defp audit_local_path(nil), do: nil
  defp audit_local_path(_path), do: "[REDACTED]"

  defp worktree_lifecycle_summary("prepare_work_package_worktree", "already_prepared"), do: "WorkPackage worktree already prepared"
  defp worktree_lifecycle_summary("prepare_work_package_worktree", _status), do: "Prepared WorkPackage worktree"
  defp worktree_lifecycle_summary("cleanup_work_package_worktree", _status), do: "Success removing worktree. Subagent can be closed now."

  defp worktree_lifecycle_idempotency_key(work_package_id, source_tool, result) do
    fingerprint =
      :sha256
      |> :crypto.hash([to_string(result.status), "\0", to_string(result.worktree_path), "\0", to_string(result.branch)])
      |> Base.url_encode64(padding: false)

    "worktree_lifecycle:#{source_tool}:#{work_package_id}:#{fingerprint}"
  end

  defp require_architect_phase_board_grant(repo, %Session{} = session, phase_id) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, anchor} <- architect_anchor_work_package(repo, session),
         :ok <- require_architect_anchor_scope(anchor, grant, phase_id),
         {:ok, _filters} <- Dashboard.phase_board_filters_for_grant(grant) do
      {:ok, grant}
    else
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, :forbidden} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scoped_work_request_filters(repo, %Session{} = session, opts \\ []) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, filters} <- work_request_filters_for_architect_grant(repo, session, grant),
         {:ok, scope} <- work_request_scope_payload(filters),
         {:ok, scope} <- maybe_put_handoff_phase_scope(repo, scope, grant, opts) do
      {:ok, work_request_filters_from_scope(scope), scope}
    else
      {:error, :forbidden} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp work_request_filters_for_architect_grant(repo, %Session{} = session, %AccessGrant{} = grant) do
    case frozen_work_request_filters_for_architect_grant(repo, session, grant) do
      {:ok, filters} ->
        {:ok, filters}

      {:error, reason} = error when reason in [:forbidden, :phase_scope_not_available] ->
        if missing_frozen_work_request_scope?(grant) do
          legacy_handoff_work_request_filters(repo, session, grant)
        else
          error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp frozen_work_request_filters_for_architect_grant(repo, %Session{} = session, %AccessGrant{} = grant) do
    with :ok <- require_work_request_anchor_scope(repo, session, grant) do
      Dashboard.phase_board_filters_for_grant(grant)
    end
  end

  defp legacy_handoff_work_request_filters(repo, %Session{} = session, %AccessGrant{} = grant) do
    with {:ok, true} <- ArchitectHandoff.handoff_phase_grant?(repo, grant),
         {:ok, anchor} <- architect_anchor_work_package(repo, session),
         true <- grant.work_package_id == anchor.id,
         true <- grant.phase_id == anchor.phase_id,
         {:ok, work_request} <- legacy_handoff_work_request(repo, grant, anchor),
         {:ok, repo_name} <- required_scope_value(work_request.repo),
         {:ok, base_branch} <- required_scope_value(work_request.base_branch) do
      {:ok, repo: repo_name, base_branch: base_branch}
    else
      false -> {:error, :phase_scope_not_available}
      {:ok, false} -> {:error, :phase_scope_not_available}
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_handoff_work_request(repo, %AccessGrant{} = grant, %WorkPackage{} = anchor) do
    with {:ok, repo_name} <- required_scope_value(anchor.repo),
         {:ok, base_branch} <- required_scope_value(anchor.base_branch),
         {:ok, work_requests} <- WorkRequestRepository.list(repo, %{"repo" => repo_name, "base_branch" => base_branch}) do
      case Enum.find(work_requests, &legacy_handoff_work_request?(&1, grant, anchor)) do
        %WorkRequest{} = work_request -> {:ok, work_request}
        nil -> {:error, :phase_scope_not_available}
      end
    end
  end

  defp legacy_handoff_work_request?(%WorkRequest{} = work_request, %AccessGrant{} = grant, %WorkPackage{} = anchor) do
    ArchitectHandoff.eligible_status?(work_request.status) and
      ArchitectHandoff.eligible_scope?(work_request) and
      grant.work_package_id == anchor.id and
      grant.phase_id == anchor.phase_id and
      ArchitectHandoff.anchor_id_for_work_request(work_request) == anchor.id and
      ArchitectHandoff.phase_id_for_work_request(work_request) == anchor.phase_id
  end

  defp scoped_guidance_request_filters(repo, %Session{} = session) do
    with {:ok, filters, scope} <- scoped_work_request_filters(repo, session),
         {:ok, phase_id} <- architect_phase_scope(repo, session) do
      scope = Map.put(scope, "phase_id", phase_id)

      filters =
        filters
        |> Map.put("phase_id", phase_id)
        |> maybe_put_work_request_guidance_package_ids(repo)

      {:ok, filters, scope}
    end
  end

  defp maybe_put_work_request_guidance_package_ids(%{"repo" => repo_name, "base_branch" => base_branch, "phase_id" => phase_id} = filters, repo) do
    work_package_ids =
      repo.all(
        from(planned_slice in PlannedSlice,
          join: work_request in WorkRequest,
          on: work_request.id == planned_slice.work_request_id,
          where: work_request.base_branch == ^base_branch,
          where: not is_nil(planned_slice.work_package_id),
          select: {work_request, planned_slice.work_package_id}
        )
      )
      |> Enum.filter(fn {work_request, _work_package_id} ->
        ArchitectHandoff.phase_id_for_work_request(work_request) == phase_id and
          repo_scope_name_matches?(repo_name, work_request.repo, [])
      end)
      |> Enum.map(fn {_work_request, work_package_id} -> work_package_id end)
      |> Enum.uniq()

    case work_package_ids do
      [] -> filters
      ids -> Map.put(filters, "work_package_ids", ids)
    end
  end

  defp maybe_put_work_request_guidance_package_ids(filters, _repo), do: filters

  defp require_work_request_anchor_scope(repo, %Session{} = session, %AccessGrant{} = grant) do
    if architect_explicit_phase_grant?(grant) do
      require_architect_phase_anchor(repo, session, grant.phase_id)
    else
      {:error, :phase_scope_not_available}
    end
  end

  defp missing_frozen_work_request_scope?(%AccessGrant{} = grant) do
    not filled_string?(grant.scope_repo) and not filled_string?(grant.scope_base_branch)
  end

  defp required_scope_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :phase_scope_not_available}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_scope_value(_value), do: {:error, :phase_scope_not_available}

  defp work_request_scope_payload(filters) when is_list(filters) do
    repo = Keyword.get(filters, :repo)
    base_branch = Keyword.get(filters, :base_branch)

    if filled_string?(repo) and filled_string?(base_branch) do
      {:ok, %{"repo" => String.trim(repo), "base_branch" => String.trim(base_branch)}}
    else
      {:error, :phase_scope_not_available}
    end
  end

  defp work_request_filters_from_scope(%{"repo" => repo, "base_branch" => base_branch, "phase_id" => phase_id}) do
    %{"repo" => repo, "base_branch" => base_branch, "phase_id" => phase_id}
  end

  defp work_request_filters_from_scope(%{"repo" => repo, "base_branch" => base_branch}) do
    %{"repo" => repo, "base_branch" => base_branch}
  end

  defp maybe_put_handoff_phase_scope(repo, scope, %AccessGrant{} = grant) do
    case ArchitectHandoff.handoff_phase_grant?(repo, grant) do
      {:ok, true} -> {:ok, Map.put(scope, "phase_id", grant.phase_id)}
      {:ok, false} -> {:ok, scope}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_handoff_phase_scope(repo, scope, %AccessGrant{} = grant, opts) do
    if Keyword.get(opts, :handoff_phase_scope?, true) do
      maybe_put_handoff_phase_scope(repo, scope, grant)
    else
      {:ok, scope}
    end
  end

  defp work_request_list_filters(filters, nil), do: filters
  defp work_request_list_filters(filters, status), do: Map.put(filters, "status", status)

  defp work_request_repository_filters(filters) do
    Map.take(filters, ["status"])
  end

  defp filter_scoped_work_requests(repo, work_requests, filters, %Session{} = session, opts) do
    Enum.reduce_while(work_requests, {:ok, []}, fn work_request, {:ok, scoped} ->
      case work_request_matches_filters?(repo, work_request, filters, opts) do
        {:ok, true} ->
          filter_policy_allowed_work_request(repo, session, work_request, scoped, opts)

        {:ok, false} ->
          {:cont, {:ok, scoped}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, scoped} -> {:ok, Enum.reverse(scoped)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp filter_policy_allowed_work_request(repo, %Session{} = session, %WorkRequest{} = work_request, scoped, opts) do
    case authorize_work_request_policy(repo, session, :work_request_read, work_request, "list_work_requests", opts) do
      :ok ->
        {:cont, {:ok, [work_request | scoped]}}

      {:error, {:authorization_policy_denied, _code, _message, %{"reason_code" => "scope_mismatch"}}} ->
        {:cont, {:ok, scoped}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp work_request_filter_payload(nil), do: %{}
  defp work_request_filter_payload(status), do: %{"status" => status}

  defp optional_work_request_status(arguments) do
    case Map.fetch(arguments, "status") do
      :error ->
        {:ok, nil}

      {:ok, status} when is_binary(status) ->
        status = String.trim(status)

        if status in WorkRequest.statuses() do
          {:ok, status}
        else
          {:tool_error, "invalid_status"}
        end

      {:ok, _status} ->
        {:tool_error, "invalid_status"}
    end
  end

  defp optional_guidance_request_status(arguments) do
    case Map.fetch(arguments, "status") do
      :error ->
        {:ok, nil}

      {:ok, status} when is_binary(status) ->
        status = String.trim(status)

        if status in GuidanceRequest.statuses() do
          {:ok, status}
        else
          {:tool_error, "invalid_status"}
        end

      {:ok, _status} ->
        {:tool_error, "invalid_status"}
    end
  end

  defp optional_product_tree_view(arguments) do
    case Map.fetch(arguments, "view") do
      :error ->
        {:ok, "nodes_with_slice_refs"}

      {:ok, view} when is_binary(view) ->
        view = String.trim(view)

        if view in @work_request_product_tree_views do
          {:ok, view}
        else
          {:tool_error, "invalid_view"}
        end

      {:ok, _view} ->
        {:tool_error, "invalid_view"}
    end
  end

  defp guidance_request_list_filters(repo, filters, status, work_package_id, work_request_id) do
    with {:ok, filters} <- maybe_put_work_request_guidance_filter(repo, filters, work_request_id) do
      {:ok,
       filters
       |> maybe_put_guidance_status_filter(status)
       |> maybe_put_guidance_work_package_filter(work_package_id)}
    end
  end

  defp guidance_work_request_id_argument(work_request_id, %Session{} = session, nil), do: infer_guidance_work_request_id(work_request_id, session)

  defp guidance_work_request_id_argument(work_request_id, %Session{}, _work_package_id), do: {:ok, work_request_id}

  defp infer_guidance_work_request_id(nil, %Session{} = session) do
    case CurrentWorkRequest.id_argument(%{}, session) do
      {:ok, work_request_id} -> {:ok, work_request_id}
      {:tool_error, _reason} -> {:ok, nil}
    end
  end

  defp infer_guidance_work_request_id(work_request_id, %Session{}), do: {:ok, work_request_id}

  defp maybe_put_work_request_guidance_filter(_repo, filters, nil), do: {:ok, filters}

  defp maybe_put_work_request_guidance_filter(repo, filters, work_request_id) when is_binary(work_request_id) do
    with {:ok, _work_request} <- scoped_work_request(repo, work_request_id, filters, repo_scopes?: true),
         {:ok, planned_slices} <- WorkRequestService.list_planned_slices(repo, work_request_id) do
      work_package_ids =
        planned_slices
        |> Enum.map(& &1.work_package_id)
        |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
        |> Enum.uniq()

      {:ok, Map.put(filters, "filter_work_package_ids", work_package_ids)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_require_guidance_work_request_filter_scope(_repo, %Session{}, nil), do: :ok

  defp maybe_require_guidance_work_request_filter_scope(repo, %Session{} = session, work_request_id) when is_binary(work_request_id) do
    authorize_work_request_tool_policy_preauthorization(repo, session, "read_work_request")
  end

  defp maybe_put_guidance_status_filter(filters, nil), do: filters
  defp maybe_put_guidance_status_filter(filters, status) when is_binary(status), do: Map.put(filters, "status", status)

  defp maybe_put_guidance_work_package_filter(filters, nil), do: filters

  defp maybe_put_guidance_work_package_filter(filters, work_package_id) when is_binary(work_package_id) do
    Map.put(filters, "work_package_id", work_package_id)
  end

  defp guidance_request_filter_payload(status, work_package_id, work_request_id) do
    %{}
    |> optional_put("status", status)
    |> optional_put("work_package_id", work_package_id)
    |> optional_put("work_request_id", work_request_id)
  end

  defp optional_string_argument(arguments, key, default \\ nil) do
    case Map.fetch(arguments, key) do
      :error ->
        {:ok, default}

      {:ok, nil} ->
        {:ok, default}

      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, default}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _value} ->
        {:tool_error, "invalid_#{key}"}
    end
  end

  defp optional_put(attrs, _key, nil), do: attrs
  defp optional_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp optional_put_present(attrs, key, value, true), do: Map.put(attrs, key, value)
  defp optional_put_present(attrs, _key, _value, false), do: attrs

  defp required_planned_slice_delivery_outcome(arguments) do
    with {:ok, outcome} <- required_argument(arguments, "outcome") do
      if outcome in PlannedSliceDelivery.outcomes() do
        {:ok, outcome}
      else
        {:tool_error, "invalid_outcome"}
      end
    end
  end

  defp required_runtime_cleanup_delivery_outcome(arguments) do
    with {:ok, outcome} <- required_argument(arguments, "outcome") do
      if outcome in ["superseded", "abandoned"] do
        {:ok, outcome}
      else
        {:tool_error, "invalid_outcome"}
      end
    end
  end

  defp runtime_cleanup_delivery_evidence_attrs(arguments, outcome, work_request_id, planned_slice_id) do
    with {:ok, successor_planned_slice_id} <- optional_string_argument(arguments, "successor_planned_slice_id"),
         {:ok, successor_work_package_id} <- optional_string_argument(arguments, "successor_work_package_id"),
         {:ok, superseded_reason} <- optional_string_argument(arguments, "superseded_reason"),
         {:ok, abandoned_rationale} <- optional_string_argument(arguments, "abandoned_rationale") do
      attrs =
        %{
          "work_request_id" => work_request_id,
          "planned_slice_id" => planned_slice_id,
          "outcome" => outcome,
          "idempotency_key" => "runtime-cleanup-evidence"
        }
        |> optional_put("successor_planned_slice_id", successor_planned_slice_id)
        |> optional_put("successor_work_package_id", successor_work_package_id)
        |> optional_put("superseded_reason", superseded_reason)
        |> optional_put("abandoned_rationale", abandoned_rationale)

      validate_runtime_cleanup_delivery_evidence(attrs)
    end
  end

  defp validate_runtime_cleanup_delivery_evidence(attrs) do
    case attrs |> PlannedSliceDelivery.create_changeset() |> Ecto.Changeset.apply_action(:insert) do
      {:ok, _delivery} -> {:ok, attrs}
      {:error, _changeset} -> {:tool_error, "invalid_delivery_evidence"}
    end
  end

  defp planned_slice_delivery_attrs(arguments, outcome, idempotency_key, recorded_by) do
    with {:ok, evidence} <- required_object(arguments, "evidence"),
         {:ok, evidence_attrs} <- planned_slice_delivery_evidence_attrs(evidence, outcome) do
      {:ok,
       Map.merge(
         %{
           "outcome" => outcome,
           "idempotency_key" => idempotency_key,
           "recorded_by" => recorded_by
         },
         evidence_attrs
       )}
    end
  end

  defp planned_slice_delivery_evidence_attrs(evidence, outcome) do
    case Map.keys(evidence) do
      [^outcome] ->
        with {:ok, typed_evidence} <- required_object(evidence, outcome) do
          planned_slice_delivery_typed_evidence_attrs(outcome, typed_evidence)
        end

      [] ->
        {:tool_error, "missing_evidence"}

      _keys ->
        {:tool_error, "conflicting_delivery_evidence"}
    end
  end

  defp planned_slice_delivery_typed_evidence_attrs(outcome, evidence) do
    field_specs = planned_slice_delivery_evidence_field_specs(outcome)
    allowed_keys = Enum.map(field_specs, &elem(&1, 0))

    with :ok <- require_planned_slice_delivery_evidence_fields(evidence, allowed_keys) do
      collect_planned_slice_delivery_evidence_attrs(evidence, field_specs)
    end
  end

  defp planned_slice_delivery_evidence_field_specs("pr_merged"),
    do: [
      {"pr_url", :string},
      {"pr_number", :positive_integer},
      {"pr_repository", :string},
      {"pr_merged_at", :string},
      {"merge_commit_sha", :string}
    ]

  defp planned_slice_delivery_evidence_field_specs("completed_no_pr"), do: [{"no_pr_evidence", :string}]

  defp planned_slice_delivery_evidence_field_specs("superseded"),
    do: [
      {"successor_planned_slice_id", :string},
      {"successor_work_package_id", :string},
      {"superseded_reason", :string}
    ]

  defp planned_slice_delivery_evidence_field_specs("abandoned"), do: [{"abandoned_rationale", :string}]

  defp collect_planned_slice_delivery_evidence_attrs(evidence, field_specs) do
    Enum.reduce_while(field_specs, {:ok, %{}}, fn {field, type}, {:ok, attrs} ->
      case planned_slice_delivery_evidence_field(evidence, field, type) do
        {:ok, value} -> {:cont, {:ok, optional_put(attrs, field, value)}}
        {:tool_error, reason} -> {:halt, {:tool_error, reason}}
      end
    end)
  end

  defp planned_slice_delivery_evidence_field(evidence, field, :string), do: optional_string_argument(evidence, field)
  defp planned_slice_delivery_evidence_field(evidence, field, :positive_integer), do: optional_positive_integer_argument(evidence, field)

  defp require_planned_slice_delivery_evidence_fields(evidence, allowed_keys) do
    case Map.keys(evidence) -- allowed_keys do
      [] -> :ok
      _unexpected -> {:tool_error, "invalid_evidence"}
    end
  end

  defp maybe_prepare_slice_delivery_blocker_closeout(
         repo,
         %Session{} = session,
         %PlannedSlice{work_package_id: work_package_id},
         arguments,
         attrs
       ) do
    case prepare_scoped_blocker_closeout(repo, session, [work_package_id], arguments, "record_planned_slice_delivery") do
      {:ok, closeout_plan} ->
        attrs =
          if blocker_closeout_decision(closeout_plan) == "still_active" do
            Map.put(attrs, "allow_active_blocker_closeout", true)
          else
            attrs
          end

        {:ok, attrs, closeout_plan}

      {:tool_error, reason} ->
        {:tool_error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_planned_slice_delivery_with_blocker_closeout(
         repo,
         %Session{} = session,
         work_request_id,
         planned_slice_id,
         attrs,
         blocker_closeout_plan
       ) do
    with {:ok, blocker_closeout} <- apply_prepared_blocker_closeout(repo, session, blocker_closeout_plan),
         {:ok, delivery} <-
           WorkRequestService.record_planned_slice_delivery(
             repo,
             work_request_id,
             planned_slice_id,
             attrs
           ) do
      {:ok, {delivery, blocker_closeout}}
    end
  end

  defp upsert_product_plan_node_with_blocker_closeout(repo, %Session{} = session, attrs, blocker_closeout_plan) do
    with {:ok, product_tree_node} <- ProductTree.upsert_node(repo, attrs),
         {:ok, blocker_closeout} <- apply_prepared_blocker_closeout(repo, session, blocker_closeout_plan) do
      {:ok, {product_tree_node, blocker_closeout}}
    end
  end

  defp mutate_product_plan_node(repo, %Session{} = session, work_request_id, tool, created_by, attrs, blocker_closeout_plan) do
    mutate_product_tree_with_projection(repo, work_request_id, tool, created_by, fn ->
      upsert_product_plan_node_with_blocker_closeout(repo, session, attrs, blocker_closeout_plan)
    end)
  end

  defp product_plan_node_tool_result(work_request, product_tree_node, blocker_closeout, detail, scope) do
    tool_result(%{
      "work_request" => work_request_mutation_payload(work_request),
      "product_plan_node" => product_tree_node_payload(product_tree_node),
      "blocker_closeout" => blocker_closeout,
      "product_tree" => json_safe_payload(detail.product_tree),
      "scope" => scope,
      "status" => %{"work_request_status" => work_request.status}
    })
  end

  defp product_plan_node_current_parent_id(_repo, _work_request_id, nil), do: {:ok, nil}

  defp product_plan_node_current_parent_id(repo, work_request_id, product_tree_node_id) do
    with {:ok, tree} <- ProductTree.tree_for_work_request(repo, work_request_id) do
      case Enum.find(tree.nodes, &(&1.id == product_tree_node_id)) do
        %Node{} = node -> {:ok, node.parent_id}
        nil -> {:error, :not_found}
      end
    end
  end

  defp maybe_prepare_work_package_status_blocker_closeout(repo, %Session{} = session, status, arguments)
       when status in @terminal_work_package_statuses do
    prepare_scoped_blocker_closeout(repo, session, [Session.work_package_id(session)], arguments, "set_status")
  end

  defp maybe_prepare_work_package_status_blocker_closeout(_repo, %Session{}, _status, _arguments) do
    {:ok, :not_needed}
  end

  defp maybe_prepare_product_plan_node_blocker_closeout(_repo, %Session{}, _work_request_id, _node_id, completion_mark, _arguments, _tool)
       when completion_mark not in @terminal_product_tree_completion_marks do
    {:ok, :not_needed}
  end

  defp maybe_prepare_product_plan_node_blocker_closeout(repo, %Session{} = session, work_request_id, product_tree_node_id, _completion_mark, arguments, tool) do
    with {:ok, work_package_ids} <- product_plan_node_work_package_ids(repo, work_request_id, product_tree_node_id) do
      prepare_scoped_blocker_closeout(repo, session, work_package_ids, arguments, tool)
    end
  end

  defp prepare_scoped_blocker_closeout(repo, %Session{}, work_package_ids, arguments, tool) do
    with {:ok, closeout} <- optional_blocker_closeout_argument(arguments),
         {:ok, active_blockers} <- active_blockers_for_work_packages(repo, work_package_ids) do
      cond do
        active_blockers == [] ->
          {:ok, :not_needed}

        is_nil(closeout) ->
          {:tool_error, {:blocker_closeout_required, active_blocker_payloads(active_blockers)}}

        true ->
          prepare_active_blocker_closeout(active_blockers, closeout, tool)
      end
    end
  end

  defp prepare_active_blocker_closeout(active_blockers, closeout, tool) do
    with :ok <- require_blocker_closeout_covers_active_blockers(active_blockers, closeout.blocker_ids) do
      {:ok, %{active_blockers: active_blockers, closeout: closeout, tool: tool}}
    end
  end

  defp blocker_closeout_decision(%{closeout: %{decision: decision}}), do: decision
  defp blocker_closeout_decision(:not_needed), do: nil

  defp apply_prepared_blocker_closeout(_repo, %Session{}, :not_needed), do: {:ok, blocker_closeout_not_needed()}

  defp apply_prepared_blocker_closeout(repo, %Session{} = session, %{active_blockers: active_blockers, closeout: closeout, tool: tool}) do
    apply_blocker_closeout_decision(repo, session, active_blockers, closeout, tool)
  end

  defp optional_blocker_closeout_argument(arguments) do
    with {:ok, closeout} <- optional_object_argument(arguments, "blocker_closeout") do
      normalize_blocker_closeout(closeout)
    end
  end

  defp normalize_blocker_closeout(nil), do: {:ok, nil}

  defp normalize_blocker_closeout(closeout) when is_map(closeout) do
    with {:ok, decision} <- required_argument(closeout, "decision"),
         :ok <- require_blocker_closeout_decision(decision),
         {:ok, blocker_ids} <- optional_string_list_argument(closeout, "blocker_ids"),
         {:ok, resolution} <- optional_string_argument(closeout, "resolution"),
         {:ok, summary} <- optional_string_argument(closeout, "summary"),
         :ok <- require_blocker_closeout_resolution(decision, resolution) do
      {:ok, %{decision: decision, blocker_ids: blocker_ids, resolution: resolution, summary: summary}}
    end
  end

  defp require_blocker_closeout_decision(decision) do
    if decision in @blocker_closeout_decisions, do: :ok, else: {:tool_error, "invalid_blocker_closeout_decision"}
  end

  defp require_blocker_closeout_resolution("resolved", resolution) when is_binary(resolution), do: :ok
  defp require_blocker_closeout_resolution("resolved", _resolution), do: {:tool_error, "missing_blocker_closeout_resolution"}
  defp require_blocker_closeout_resolution("still_active", _resolution), do: :ok

  defp optional_string_list_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error ->
        {:ok, []}

      {:ok, nil} ->
        {:ok, []}

      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &is_binary/1) do
          values =
            values
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.uniq()

          {:ok, values}
        else
          {:tool_error, "invalid_#{key}"}
        end

      {:ok, _value} ->
        {:tool_error, "invalid_#{key}"}
    end
  end

  defp apply_blocker_closeout_decision(repo, %Session{} = session, active_blockers, closeout, tool) do
    with :ok <- require_blocker_closeout_covers_active_blockers(active_blockers, closeout.blocker_ids) do
      case closeout.decision do
        "resolved" -> resolve_active_blockers(repo, session, active_blockers, closeout, tool)
        "still_active" -> preserve_active_blockers(repo, session, active_blockers, closeout, tool)
      end
    end
  end

  defp require_blocker_closeout_covers_active_blockers(_active_blockers, []), do: :ok

  defp require_blocker_closeout_covers_active_blockers(active_blockers, blocker_ids) do
    active_ids = active_blockers |> Enum.map(& &1.id) |> Enum.sort()
    requested_ids = Enum.sort(blocker_ids)

    if requested_ids == active_ids do
      :ok
    else
      {:tool_error, {:blocker_closeout_scope_mismatch, active_ids, requested_ids}}
    end
  end

  defp resolve_active_blockers(repo, %Session{} = session, active_blockers, closeout, tool) do
    with {:ok, events} <-
           append_blocker_closeout_events(active_blockers, fn blocker ->
             append_blocker_closeout_resolution(repo, session, blocker, closeout, tool)
           end) do
      {:ok,
       %{
         "decision" => "resolved",
         "active_blockers_before" => active_blocker_payloads(active_blockers),
         "resolved_blocker_ids" => Enum.map(active_blockers, & &1.id),
         "progress_event_ids" => events |> Enum.reverse() |> Enum.map(& &1.id)
       }}
    end
  end

  defp preserve_active_blockers(repo, %Session{} = session, active_blockers, closeout, tool) do
    with {:ok, events} <-
           append_blocker_closeout_events(active_blockers, fn blocker ->
             append_blocker_closeout_preservation(repo, session, blocker, closeout, tool)
           end) do
      {:ok,
       %{
         "decision" => "still_active",
         "active_blockers" => active_blocker_payloads(active_blockers),
         "progress_event_ids" => events |> Enum.reverse() |> Enum.map(& &1.id)
       }}
    end
  end

  defp append_blocker_closeout_events(active_blockers, append_fun) do
    Enum.reduce_while(active_blockers, {:ok, []}, fn blocker, {:ok, events} ->
      append_blocker_closeout_event(append_fun, blocker, events)
    end)
  end

  defp append_blocker_closeout_event(append_fun, blocker, events) do
    case append_fun.(blocker) do
      {:ok, event} -> {:cont, {:ok, [event | events]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp append_blocker_closeout_resolution(repo, %Session{} = session, blocker, closeout, tool) do
    PlanningRepository.append_audit_progress_event_for_work_package(
      repo,
      session.assignment,
      blocker.work_package_id,
      %{
        "summary" => closeout.summary || "Resolved blocker during #{tool}",
        "body" => closeout.resolution,
        "status" => "resolved",
        "idempotency_key" => blocker_closeout_idempotency_key(tool, blocker, "resolved"),
        "payload" => %{
          "type" => "blocker",
          "source_tool" => "resolve_blocker",
          "blocker_id" => blocker.id,
          "resolution" => closeout.resolution,
          "active" => false,
          "closeout_tool" => tool
        }
      }
    )
  end

  defp append_blocker_closeout_preservation(repo, %Session{} = session, blocker, closeout, tool) do
    PlanningRepository.append_audit_progress_event_for_work_package(
      repo,
      session.assignment,
      blocker.work_package_id,
      %{
        "summary" => closeout.summary || "Preserved active blocker during #{tool}",
        "body" => closeout.resolution || blocker.body || blocker.summary,
        "status" => "blocked",
        "idempotency_key" => blocker_closeout_idempotency_key(tool, blocker, "still_active"),
        "payload" => %{
          "type" => "blocker_closeout_decision",
          "source_tool" => tool,
          "blocker_id" => blocker.id,
          "decision" => "still_active"
        }
      }
    )
  end

  defp blocker_closeout_idempotency_key(tool, blocker, decision) do
    ["blocker_closeout", tool, blocker.work_package_id, blocker.id, blocker.event_id, decision]
    |> Enum.join(":")
  end

  defp active_blockers_for_work_packages(repo, work_package_ids) do
    work_package_ids =
      work_package_ids
      |> Enum.filter(&filled_string?/1)
      |> Enum.uniq()

    Enum.reduce_while(work_package_ids, {:ok, []}, fn work_package_id, {:ok, blockers} ->
      case active_blockers_for_work_package(repo, work_package_id) do
        {:ok, package_blockers} -> {:cont, {:ok, blockers ++ package_blockers}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp active_blockers_for_work_package(repo, work_package_id) do
    with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, work_package_id) do
      blockers =
        progress_events
        |> BlockerProjection.blockers()
        |> Enum.filter(& &1.active)
        |> Enum.map(&Map.put(&1, :work_package_id, work_package_id))

      {:ok, blockers}
    end
  end

  defp product_plan_node_work_package_ids(repo, work_request_id, product_tree_node_id) do
    with {:ok, tree} <- ProductTree.tree_for_work_request(repo, work_request_id),
         {:ok, planned_slices} <- WorkRequestService.list_planned_slices(repo, work_request_id) do
      subtree_node_ids = product_tree_subtree_node_ids(tree.nodes, product_tree_node_id)
      slice_ids = product_tree_subtree_slice_ids(tree.slice_links, subtree_node_ids)
      package_ids = planned_slices |> Enum.filter(&(&1.id in slice_ids)) |> Enum.map(& &1.work_package_id)

      {:ok, package_ids}
    end
  end

  defp product_tree_subtree_node_ids(nodes, product_tree_node_id) do
    children_by_parent = Enum.group_by(nodes, & &1.parent_id)

    Stream.unfold([product_tree_node_id], fn
      [] ->
        nil

      [node_id | rest] ->
        child_ids = children_by_parent |> Map.get(node_id, []) |> Enum.map(& &1.id)
        {node_id, rest ++ child_ids}
    end)
    |> Enum.to_list()
  end

  defp product_tree_subtree_slice_ids(slice_links, subtree_node_ids) do
    subtree_node_ids = MapSet.new(subtree_node_ids)

    slice_links
    |> Enum.filter(&MapSet.member?(subtree_node_ids, &1.product_tree_node_id))
    |> Enum.map(& &1.planned_slice_id)
    |> Enum.uniq()
  end

  defp active_blocker_payloads(blockers), do: Enum.map(blockers, &active_blocker_payload/1)

  defp active_blocker_payload(blocker) do
    %{
      "blocker_id" => blocker.id,
      "work_package_id" => blocker.work_package_id,
      "summary" => blocker.summary,
      "body" => blocker.body,
      "status" => blocker.status,
      "updated_at" => blocker.updated_at
    }
  end

  defp blocker_closeout_not_needed, do: %{"decision" => "none", "active_blockers" => []}

  defp optional_positive_integer_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp optional_nonnegative_integer_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp session_claimed_by(%Session{assignment: %{claimed_by: claimed_by}}) when is_binary(claimed_by) do
    case String.trim(claimed_by) do
      "" -> "architect"
      trimmed -> trimmed
    end
  end

  defp session_claimed_by(%Session{}), do: "architect"

  defp authorized_work_request_scope(repo, %Session{} = session, work_request_id, action, tool, opts \\ []) do
    if architect_session?(session) do
      authorized_architect_work_request_scope(repo, session, work_request_id, action, tool, opts)
    else
      authorized_actor_work_request_scope(repo, session, work_request_id, action, tool)
    end
  end

  defp authorized_architect_work_request_scope(repo, %Session{} = session, work_request_id, action, tool, opts) do
    repo_scope_opts = if repo_scope_read_action?(action), do: opts, else: []

    with {:ok, filters, scope} <-
           scoped_work_request_filters(repo, session, handoff_phase_scope?: not repo_scope_read_action?(action)),
         {:ok, work_request} <-
           scoped_work_request(
             repo,
             work_request_id,
             filters,
             Keyword.put(repo_scope_opts, :repo_scopes?, repo_scope_read_action?(action))
           ),
         policy_session = read_scoped_work_request_session(repo, session, scope, action),
         :ok <-
           authorize_work_request_policy(repo, policy_session, action, work_request, tool, repo_scope_opts)
           |> mask_architect_scope_denial() do
      {:ok, work_request, filters, scope}
    end
  end

  defp authorized_actor_work_request_scope(repo, %Session{} = session, work_request_id, action, tool) do
    with {:ok, work_request} <- WorkRequestService.get(repo, work_request_id),
         :ok <- authorize_work_request_policy(repo, session, action, work_request, tool),
         {:ok, filters, scope} <- scoped_work_request_filters(repo, session),
         :ok <-
           require_work_request_scope(
             repo,
             work_request,
             filters,
             repo_scopes?: repo_scope_read_action?(action)
           ) do
      {:ok, work_request, filters, scope}
    end
  end

  defp authorized_planned_slice_scope(repo, %Session{} = session, work_request_id, planned_slice_id, action, tool) do
    if architect_session?(session) do
      authorized_architect_planned_slice_scope(repo, session, work_request_id, planned_slice_id, action, tool)
    else
      authorized_actor_planned_slice_scope(repo, session, work_request_id, planned_slice_id, action, tool)
    end
  end

  defp authorized_architect_planned_slice_scope(repo, %Session{} = session, work_request_id, planned_slice_id, action, tool) do
    with {:ok, filters, scope} <- scoped_work_request_filters(repo, session),
         {:ok, work_request} <- scoped_work_request(repo, work_request_id, filters),
         {:ok, planned_slice} <- scoped_work_request_planned_slice(repo, work_request_id, planned_slice_id),
         :ok <-
           authorize_planned_slice_policy(session, action, work_request, planned_slice, tool)
           |> mask_architect_scope_denial() do
      {:ok, work_request, planned_slice, filters, scope}
    end
  end

  defp authorized_actor_planned_slice_scope(repo, %Session{} = session, work_request_id, planned_slice_id, action, tool) do
    with {:ok, work_request} <- WorkRequestService.get(repo, work_request_id),
         {:ok, planned_slice} <- WorkRequestService.get_planned_slice(repo, work_request_id, planned_slice_id),
         :ok <- authorize_planned_slice_policy(session, action, work_request, planned_slice, tool),
         {:ok, filters, scope} <- scoped_work_request_filters(repo, session),
         :ok <- require_work_request_scope(repo, work_request, filters) do
      {:ok, work_request, planned_slice, filters, scope}
    end
  end

  defp authorize_work_request_list_policy(%Session{} = session, scope, tool, opts) do
    case authorize_work_request_repo_policy(session, :work_request_read, scope, tool, opts) do
      :ok ->
        :ok

      {:error, {:authorization_policy_denied, _code, _message, %{"reason_code" => "scope_mismatch"}}} = error ->
        if work_request_scoped_session?(session), do: :ok, else: error

      {:error, _reason} = error ->
        error
    end
  end

  defp authorize_work_request_tool_policy_preauthorization(repo, %Session{} = session, tool) do
    target = Target.repo("policy-preauthorization", nil)

    case authorize_policy(session, work_request_policy_action(tool), target, tool) do
      :ok ->
        :ok

      {:error, {:authorization_policy_denied, _code, _message, %{"reason_code" => "scope_mismatch"}}} ->
        with {:ok, _filters, _scope} <- scoped_work_request_filters(repo, session), do: :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp work_request_policy_action("list_work_requests"), do: :work_request_read
  defp work_request_policy_action("read_work_request"), do: :work_request_read
  defp work_request_policy_action("read_work_request_product_tree"), do: :work_request_read
  defp work_request_policy_action("read_work_request_delivery_board"), do: :delivery_board_read
  defp work_request_policy_action("set_work_request_status"), do: :work_request_update
  defp work_request_policy_action("ask_work_request_question"), do: :question_create
  defp work_request_policy_action("answer_work_request_question"), do: :question_answer
  defp work_request_policy_action("answer_work_request_question_and_record_decision"), do: :question_answer
  defp work_request_policy_action("close_work_request_question"), do: :question_close
  defp work_request_policy_action("record_work_request_decision"), do: :decision_record
  defp work_request_policy_action("add_work_request_planned_slice"), do: :planned_slice_create
  defp work_request_policy_action("upsert_work_request_product_plan_node_content"), do: :work_request_update
  defp work_request_policy_action("move_work_request_product_plan_node"), do: :work_request_update
  defp work_request_policy_action("set_work_request_product_plan_node_completion"), do: :work_request_update
  defp work_request_policy_action("move_work_request_planned_slice_to_product_node"), do: :work_request_update
  defp work_request_policy_action("approve_work_request_planned_slice"), do: :planned_slice_approve
  defp work_request_policy_action("skip_work_request_planned_slice"), do: :planned_slice_skip
  defp work_request_policy_action("mark_work_request_sliced"), do: :work_request_update
  defp work_request_policy_action("dispatch_work_request_planned_slice"), do: :planned_slice_dispatch

  defp repo_scope_read_action?(action), do: action in [:work_request_read, :delivery_board_read]

  defp read_scoped_work_request_session(repo, %Session{} = session, %{"repo" => repo_name, "base_branch" => base_branch}, action)
       when action in [:work_request_read, :delivery_board_read] and is_binary(repo_name) and is_binary(base_branch) do
    if handoff_work_request_read_scope?(repo, session) do
      put_assignment_scope(session, Scope.repo(repo_name, base_branch, metadata: %{source: :work_request_read_scope}))
    else
      session
    end
  end

  defp read_scoped_work_request_session(_repo, %Session{} = session, _scope, _action), do: session

  defp handoff_work_request_read_scope?(repo, %Session{} = session) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, true} <- ArchitectHandoff.handoff_phase_grant?(repo, grant) do
      true
    else
      _reason -> false
    end
  end

  defp put_assignment_scope(%Session{assignment: %Assignment{} = assignment} = session, %Scope{} = scope) do
    scopes = List.wrap(assignment.scopes)

    if Enum.any?(scopes, &(assignment_scope_key(&1) == assignment_scope_key(scope))) do
      session
    else
      %{session | assignment: %{assignment | scopes: scopes ++ [scope]}}
    end
  end

  defp assignment_scope_key(%Scope{type: :repo, repo: repo, base_branch: base_branch}), do: {:repo, repo, base_branch}
  defp assignment_scope_key(%Scope{type: type, id: id}), do: {type, id}

  defp authorize_work_request_repo_policy(%Session{} = session, action, %{"repo" => repo, "base_branch" => base_branch} = scope, tool, opts) do
    target =
      Target.repo(repo, base_branch,
        phase_id: Map.get(scope, "phase_id"),
        metadata: work_request_repo_scope_metadata(opts)
      )

    authorize_policy(session, action, target, tool)
  end

  defp authorize_work_request_policy(repo, %Session{} = session, action, %WorkRequest{} = work_request, tool, opts \\ []) do
    with {:ok, repo_scopes} <- work_request_repo_scope_payloads(repo, work_request) do
      target =
        Target.work_request(work_request.id,
          repo: work_request.repo,
          base_branch: work_request.base_branch,
          phase_id: ArchitectHandoff.phase_id_for_work_request(work_request),
          repo_scopes: repo_scopes,
          metadata: work_request_repo_scope_metadata(opts)
        )

      authorize_policy(session, action, target, tool)
    end
  end

  defp authorize_planned_slice_policy(%Session{} = session, action, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, tool) do
    target =
      Target.planned_slice(planned_slice.id, work_request.id,
        repo: PlannedSlice.delivery_repo(work_request, planned_slice),
        base_branch: planned_slice.target_base_branch || work_request.base_branch,
        phase_id: ArchitectHandoff.phase_id_for_work_request(work_request),
        work_package_id: planned_slice.work_package_id
      )

    authorize_policy(session, action, target, tool)
  end

  defp authorize_policy(%Session{} = session, action, %Target{} = target, tool) do
    with {:ok, actor} <- ActorResolver.from_session(session, actor_resolver_opts(target)) do
      actor
      |> Policy.decide(action, target)
      |> MCPError.from_decision(tool)
      |> wrap_authorization_policy_denial()
    end
  end

  defp wrap_authorization_policy_denial(:ok), do: :ok

  defp wrap_authorization_policy_denial({:error, code, message, data}) do
    {:error, {:authorization_policy_denied, code, message, data}}
  end

  defp actor_resolver_opts(%Target{} = target) do
    [
      work_request_id: target.work_request_id || target_work_request_id(target),
      repo: target.repo,
      base_branch: target.base_branch,
      phase_id: target.phase_id
    ]
  end

  defp target_work_request_id(%Target{type: :work_request, id: id}) when is_binary(id), do: id
  defp target_work_request_id(%Target{}), do: nil

  defp actor_for_package_resource(repo, %Session{} = session, resource_type, work_package_id) do
    with {:ok, target} <- PlanningService.package_resource_target(repo, work_package_id, resource_type) do
      ActorResolver.from_session(session, PlanningService.package_surface_actor_opts(session.assignment, target))
    end
  end

  defp authorize_current_package_policy(repo, %Session{} = session, action, resource_type, _tool) do
    work_package_id = Session.work_package_id(session)

    with {:ok, actor} <- actor_for_package_resource(repo, session, resource_type, work_package_id) do
      case PlanningService.authorize_package_action(repo, actor, action, work_package_id, resource_type) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp progress_tool_policy("report_blocker"), do: {:blocker_report, :blocker}
  defp progress_tool_policy("resolve_blocker"), do: {:blocker_resolve, :blocker}
  defp progress_tool_policy("set_status"), do: {:work_package_update, :work_package}
  defp progress_tool_policy(_tool), do: {:progress_append, :progress}

  defp action_for_virtual_file("task_plan.md"), do: :task_plan_read
  defp action_for_virtual_file(_file_name), do: :work_package_read

  defp resource_type_for_virtual_file("task_plan.md"), do: :task_plan
  defp resource_type_for_virtual_file("findings.md"), do: :finding
  defp resource_type_for_virtual_file("progress.md"), do: :progress
  defp resource_type_for_virtual_file("review_suite.md"), do: :review_evidence
  defp resource_type_for_virtual_file(_file_name), do: :work_package

  defp authorize_guidance_request_for_session(repo, %Session{} = session, action, %GuidanceRequest{} = guidance_request) do
    GuidanceRequestService.authorize_for_assignment(repo, session.assignment, action, guidance_request)
  end

  defp mask_architect_scope_denial({:error, {:authorization_policy_denied, _code, _message, %{"reason_code" => "scope_mismatch"}}}) do
    {:error, :not_found}
  end

  defp mask_architect_scope_denial(result), do: result

  defp architect_session?(%Session{assignment: %{grant_role: "architect"}}), do: true
  defp architect_session?(%Session{}), do: false

  defp work_request_scoped_session?(%Session{assignment: %{scopes: scopes}}) when is_list(scopes) do
    Enum.any?(scopes, &match?(%Scope{type: :work_request}, &1))
  end

  defp scoped_work_request(repo, work_request_id, filters, opts \\ []) do
    with {:ok, %WorkRequest{} = work_request} <- WorkRequestService.get(repo, work_request_id),
         :ok <- require_work_request_scope(repo, work_request, filters, opts) do
      {:ok, work_request}
    else
      {:error, :forbidden} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp local_trusted_work_request_read_scope(repo, work_request_id) do
    with {:ok, %WorkRequest{} = work_request} <- WorkRequestService.get(repo, work_request_id) do
      {:ok, work_request, %{"repo" => work_request.repo, "base_branch" => work_request.base_branch}}
    end
  end

  defp scoped_work_request_question(repo, work_request_id, question_id) do
    with {:ok, questions} <- WorkRequestService.list_questions(repo, work_request_id) do
      case Enum.find(questions, &(&1.id == question_id)) do
        %ClarificationQuestion{} = question -> {:ok, question}
        nil -> {:error, :not_found}
      end
    end
  end

  defp scoped_work_request_planned_slice(repo, work_request_id, planned_slice_id) do
    WorkRequestService.get_planned_slice(repo, work_request_id, planned_slice_id)
  end

  defp planned_slice_work_package_id(repo, %WorkRequest{id: work_request_id}, %PlannedSlice{id: planned_slice_id}) do
    case PlannedSliceLinkage.linked_work_package_for_planned_slice(repo, work_request_id, planned_slice_id) do
      {:ok, {%PlannedSlice{}, %WorkPackage{id: work_package_id}}} -> {:ok, work_package_id}
      {:error, :planned_slice_not_dispatched} -> {:tool_error, "planned_slice_not_dispatched"}
      {:error, :ambiguous_planned_slice_link} -> {:tool_error, "ambiguous_planned_slice_link"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scoped_delivery_board(repo, %WorkRequest{} = work_request, planned_slices, filters, opts \\ []) when is_list(planned_slices) do
    {visible_work_package_ids, work_package_contexts} =
      visible_delivery_board_work_package_contexts(repo, work_request, planned_slices, filters, opts)

    project_opts =
      [
        work_request: work_request,
        planned_slices: planned_slices,
        visible_work_package_ids: visible_work_package_ids,
        work_package_contexts: work_package_contexts,
        slice_projection: Keyword.get(opts, :slice_projection)
      ]
      |> Keyword.reject(fn {_key, value} -> is_nil(value) end)

    DeliveryBoard.project(repo, work_request.id, project_opts)
  end

  defp reconcile_work_request_action(true), do: :delivery_reconcile_apply
  defp reconcile_work_request_action(false), do: :delivery_reconcile_dry_run

  defp require_delivery_reconcile_capability(%Session{} = session, apply?) do
    if architect_session?(session) do
      require_architect_capability(session.assignment, reconcile_work_request_capability(apply?))
    else
      :ok
    end
  end

  defp require_delivery_write_capability(%Session{} = session) do
    if architect_session?(session) do
      require_architect_capability(session.assignment, "write:work_request")
    else
      :ok
    end
  end

  defp reconcile_work_request_capability(true), do: "write:work_request"
  defp reconcile_work_request_capability(false), do: "read:work_request"

  defp reconcile_work_request_mode(true), do: :apply
  defp reconcile_work_request_mode(false), do: :dry_run

  defp reconcile_work_request(repo, %Session{} = session, work_request_id, true = _apply?, recorded_by, opts) do
    opts = Keyword.put(opts, :recorded_by, recorded_by)
    opts = Keyword.put(opts, :append_blocker_closeout_event, reconcile_blocker_closeout_appender(session))

    run_architect_transaction(repo, fn ->
      with {:ok, reconciliation} <- DeliveryReconciler.reconcile(repo, work_request_id, opts) do
        record_reconcile_product_tree_revision_after_apply(repo, work_request_id, recorded_by, reconciliation)
      end
    end)
  end

  defp reconcile_work_request(repo, %Session{}, work_request_id, false = _apply?, recorded_by, opts) do
    opts = Keyword.put(opts, :recorded_by, recorded_by)

    DeliveryReconciler.reconcile(repo, work_request_id, opts)
  end

  defp record_reconcile_product_tree_revision_after_apply(
         repo,
         work_request_id,
         recorded_by,
         reconciliation
       ) do
    with {:ok, _revision} <-
           maybe_record_reconcile_product_tree_revision(
             repo,
             work_request_id,
             recorded_by,
             reconciliation
           ) do
      {:ok, reconciliation}
    end
  end

  defp reconcile_blocker_closeout_appender(%Session{} = session) do
    fn repo, work_package_id, attrs ->
      PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, work_package_id, attrs)
    end
  end

  defp maybe_record_reconcile_product_tree_revision(repo, work_request_id, recorded_by, reconciliation) do
    if reconcile_product_tree_revision_required?(reconciliation) do
      record_current_product_tree_revision(repo, work_request_id, "reconcile_work_request", recorded_by)
    else
      {:ok, nil}
    end
  end

  defp reconcile_product_tree_revision_required?(%{applied_count: count}) when count > 0, do: true

  defp reconcile_product_tree_revision_required?(%{results: results}) when is_list(results) do
    Enum.any?(results, &reconcile_result_has_delivery_closeout?/1)
  end

  defp reconcile_result_has_delivery_closeout?(%{reason: "already_closeout", work_package_status: status}) when is_binary(status), do: true
  defp reconcile_result_has_delivery_closeout?(_result), do: false

  defp visible_delivery_board_work_package_contexts(repo, %WorkRequest{} = work_request, planned_slices, filters, opts \\ []) do
    planned_slice_ids = Enum.map(planned_slices, & &1.id)

    work_package_ids =
      repo.all(
        from(delivery in PlannedSliceDelivery,
          where: delivery.work_request_id == ^work_request.id,
          where: delivery.planned_slice_id in ^planned_slice_ids,
          select: delivery.successor_work_package_id
        )
      )
      |> Enum.concat(Enum.map(planned_slices, & &1.work_package_id))
      |> Enum.filter(&filled_string?/1)
      |> Enum.uniq()

    work_package_contexts =
      work_package_ids
      |> scoped_delivery_work_packages_by_id(repo, work_request, planned_slices, filters, opts)
      |> Map.new(fn {id, work_package} -> {id, %{work_package: work_package}} end)

    {Map.keys(work_package_contexts), work_package_contexts}
  end

  defp scoped_delivery_work_packages_by_id([], _repo, %WorkRequest{}, _planned_slices, _filters, _opts), do: %{}

  defp scoped_delivery_work_packages_by_id(work_package_ids, repo, %WorkRequest{} = work_request, planned_slices, filters, opts) do
    primary_scope? = primary_work_request_scope?(repo, work_request, filters)
    filter_opts = if primary_scope?, do: [], else: opts

    planned_slices_by_work_package_id =
      planned_slices
      |> Enum.filter(&filled_string?(&1.work_package_id))
      |> Map.new(&{&1.work_package_id, &1})

    repo.all(from(work_package in WorkPackage, where: work_package.id in ^work_package_ids))
    |> Enum.filter(fn work_package ->
      case Map.fetch(planned_slices_by_work_package_id, work_package.id) do
        {:ok, planned_slice} ->
          require_delivery_work_package_scope(work_package, work_request, planned_slice) == :ok and
            delivery_work_package_visible_to_filters?(work_package, primary_scope?, filters, filter_opts)

        :error ->
          false
      end
    end)
    |> Map.new(&{&1.id, &1})
  end

  defp primary_work_request_scope?(repo, %WorkRequest{} = work_request, filters, opts \\ []) do
    {:ok, matches?} = work_request_matches_primary_filters?(repo, work_request, filters, opts)
    matches?
  end

  defp delivery_work_package_visible_to_filters?(_work_package, true, _filters, _opts), do: true

  defp delivery_work_package_visible_to_filters?(%WorkPackage{} = work_package, false, filters, opts) do
    work_package_matches_filters?(work_package, filters, opts)
  end

  defp require_planned_slice_delivery_scope(repo, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, attrs, filters) do
    primary_scope? = primary_work_request_scope?(repo, work_request, filters)

    with :ok <- require_linked_delivery_work_package_scope(repo, work_request, planned_slice, primary_scope?, filters),
         :ok <- require_successor_planned_slice_scope(repo, work_request, attrs) do
      require_successor_work_package_scope(repo, work_request, attrs, primary_scope?, filters)
    end
  end

  defp require_linked_delivery_work_package_scope(
         _repo,
         %WorkRequest{},
         %PlannedSlice{work_package_id: work_package_id},
         _primary_scope?,
         _filters
       )
       when work_package_id in [nil, ""],
       do: :ok

  defp require_linked_delivery_work_package_scope(
         repo,
         %WorkRequest{} = work_request,
         %PlannedSlice{work_package_id: work_package_id} = planned_slice,
         primary_scope?,
         filters
       ) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
      require_scoped_delivery_work_package_visibility(
        work_package,
        work_request,
        planned_slice,
        primary_scope?,
        filters
      )
    end
  end

  defp require_successor_work_package_scope(repo, %WorkRequest{} = work_request, attrs, primary_scope?, filters) do
    case Map.get(attrs, "successor_work_package_id") do
      nil ->
        :ok

      successor_work_package_id ->
        with {:ok, successor_work_package} <- WorkPackageRepository.get(repo, successor_work_package_id),
             {:ok, successor_slice} <-
               scoped_work_request_work_package_planned_slice(repo, work_request.id, successor_work_package_id) do
          require_scoped_delivery_work_package_visibility(
            successor_work_package,
            work_request,
            successor_slice,
            primary_scope?,
            filters
          )
        else
          {:tool_error, reason} -> {:tool_error, reason}
          {:error, :not_found} -> {:tool_error, "successor_work_package_out_of_scope"}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp require_successor_planned_slice_scope(_repo, %WorkRequest{}, %{"outcome" => outcome}) when outcome != "superseded", do: :ok

  defp require_successor_planned_slice_scope(repo, %WorkRequest{} = work_request, attrs) do
    case Map.get(attrs, "successor_planned_slice_id") do
      nil ->
        {:tool_error, "missing_successor_planned_slice_id"}

      successor_planned_slice_id ->
        case scoped_work_request_planned_slice(repo, work_request.id, successor_planned_slice_id) do
          {:ok, successor_slice} -> require_successor_work_package_matches_slice(successor_slice, attrs)
          {:error, :not_found} -> {:tool_error, "successor_planned_slice_out_of_scope"}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp require_successor_work_package_matches_slice(%PlannedSlice{} = successor_slice, attrs) do
    case Map.get(attrs, "successor_work_package_id") do
      nil -> :ok
      successor_work_package_id when successor_work_package_id == successor_slice.work_package_id -> :ok
      _successor_work_package_id -> {:tool_error, "successor_work_package_slice_mismatch"}
    end
  end

  defp scoped_work_request_work_package_planned_slice(repo, work_request_id, work_package_id) do
    case PlannedSliceLinkage.linked_slice_for_work_package(repo, work_request_id, work_package_id) do
      {:ok, %PlannedSlice{} = planned_slice} -> {:ok, planned_slice}
      {:error, :ambiguous_planned_slice_link} -> {:tool_error, "ambiguous_planned_slice_link"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scoped_worktree_work_package(repo, %Session{} = session, work_package_id) do
    with {:ok, %WorkPackage{} = work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, filters, scope} <- scoped_work_request_filters(repo, session),
         :ok <- require_worktree_work_package_scope(repo, work_package, filters) do
      {:ok, work_package, scope}
    else
      {:error, :forbidden} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_worktree_work_package_scope(repo, %WorkPackage{} = work_package, filters) do
    case PlannedSliceLinkage.linked_work_requests_for_work_package(repo, work_package.id) do
      {:ok, []} ->
        {:error, :forbidden}

      {:ok, links} ->
        with :ok <- require_unique_worktree_work_request_link(links) do
          require_any_worktree_work_package_link_scope(repo, work_package, links, filters)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_unique_worktree_work_request_link(links) do
    case Enum.uniq_by(links, fn {%PlannedSlice{}, %WorkRequest{id: work_request_id}} -> work_request_id end) do
      [_single] -> :ok
      [] -> {:error, :forbidden}
      [_first | _rest] -> {:error, :ambiguous_planned_slice_link}
    end
  end

  defp require_any_worktree_work_package_link_scope(repo, %WorkPackage{} = work_package, links, filters) do
    Enum.reduce_while(links, {:error, :forbidden}, fn
      {%PlannedSlice{} = planned_slice, %WorkRequest{} = work_request}, _error ->
        case require_worktree_work_package_link_scope(repo, work_package, planned_slice, work_request, filters) do
          :ok -> {:halt, :ok}
          {:error, reason} when reason in [:forbidden, :not_found] -> {:cont, {:error, :forbidden}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  defp require_worktree_work_package_link_scope(
         repo,
         %WorkPackage{} = work_package,
         %PlannedSlice{} = planned_slice,
         %WorkRequest{} = work_request,
         filters
       ) do
    with :ok <- require_work_package_repo_scope(work_package, work_request, planned_slice),
         :ok <- require_work_package_delivery_base_scope(work_package, planned_slice),
         :ok <- require_work_request_scope(repo, work_request, filters) do
      require_delivery_work_package_filter_scope(repo, work_package, work_request, filters)
    end
  end

  defp require_scoped_delivery_work_package_visibility(
         %WorkPackage{} = work_package,
         %WorkRequest{} = work_request,
         %PlannedSlice{} = planned_slice,
         primary_scope?,
         filters
       ) do
    with :ok <- require_delivery_work_package_scope(work_package, work_request, planned_slice) do
      require_delivery_work_package_filter_scope(work_package, primary_scope?, filters)
    end
  end

  defp require_delivery_work_package_filter_scope(repo, %WorkPackage{} = work_package, %WorkRequest{} = work_request, filters) do
    primary_scope? = primary_work_request_scope?(repo, work_request, filters)
    require_delivery_work_package_filter_scope(work_package, primary_scope?, filters)
  end

  defp require_delivery_work_package_filter_scope(%WorkPackage{} = work_package, primary_scope?, filters) do
    if delivery_work_package_visible_to_filters?(work_package, primary_scope?, filters, []) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp require_target_repo_root_scope(target_repo_root, %WorkPackage{repo: expected_repo}, %Config{} = config) do
    with {:ok, target_repo_root} <- PathSafety.canonicalize(target_repo_root),
         true <- File.dir?(target_repo_root) do
      if target_repo_root_matches_repo_scope?(target_repo_root, expected_repo, config) do
        :ok
      else
        {:tool_error, "target_repo_root_scope_mismatch"}
      end
    else
      false -> {:error, :invalid_target_repo_root}
      {:error, _reason} -> {:error, :invalid_target_repo_root}
    end
  end

  defp require_cleanup_target_repo_root_scope(nil, %WorkPackage{}, %Config{}), do: :ok
  defp require_cleanup_target_repo_root_scope(_target_repo_root, %WorkPackage{worktree_path: nil}, %Config{}), do: :ok
  defp require_cleanup_target_repo_root_scope(target_repo_root, %WorkPackage{} = work_package, %Config{} = config), do: require_target_repo_root_scope(target_repo_root, work_package, config)

  defp target_repo_root_matches_repo_scope?(target_repo_root, expected_repo, %Config{} = config) when is_binary(expected_repo) do
    origin = RepoIdentity.local_git_origin_remote(target_repo_root)

    same_existing_path?(target_repo_root, expected_repo) or
      local_repo_checkout_matches_scope?(target_repo_root, expected_repo, origin, config) or
      origin_matches_repo_scope?(origin, expected_repo, target_repo_root, config)
  end

  defp target_repo_root_matches_repo_scope?(_target_repo_root, _expected_repo, _config), do: false

  defp local_repo_checkout_matches_scope?(
         target_repo_root,
         expected_repo,
         origin,
         %Config{repo_root: repo_root} = config
       )
       when is_binary(target_repo_root) and is_binary(expected_repo) and is_binary(origin) do
    expected_repo = String.trim(expected_repo)
    trusted_remotes = [origin | repo_scope_trusted_remotes(config, target_repo_root)]

    bare_repo_name?(expected_repo) and
      expected_repo
      |> WorktreeTargetRoot.checkout_candidates(repo_root)
      |> Enum.reject(&same_existing_path?(&1, repo_root))
      |> Enum.any?(&same_existing_path?(target_repo_root, &1)) and
      RepoIdentity.scope_match?(expected_repo, origin, trusted_remotes: trusted_remotes)
  end

  defp local_repo_checkout_matches_scope?(_target_repo_root, _expected_repo, _origin, _config), do: false

  defp origin_matches_repo_scope?(origin, expected_repo, target_repo_root, %Config{} = config) when is_binary(origin) do
    trusted_remotes = repo_scope_trusted_remotes(config, target_repo_root)

    same_existing_path?(origin, expected_repo) or
      same_owner_bare_repo_origin_match?(expected_repo, origin, config) or
      RepoIdentity.scope_match?(expected_repo, origin, trusted_remotes: trusted_remotes)
  end

  defp origin_matches_repo_scope?(_origin, _expected_repo, _target_repo_root, _config), do: false

  defp repo_scope_trusted_remotes(%Config{repo_root: repo_root}, target_repo_root) do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_identity_trusted_remotes, [])
    |> List.wrap()
    |> Kernel.++([same_checkout_origin_remote(repo_root, target_repo_root)])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp same_owner_bare_repo_origin_match?(expected_repo, target_origin, %Config{repo_root: repo_root})
       when is_binary(expected_repo) and is_binary(repo_root) do
    with true <- bare_repo_name?(expected_repo),
         %{owner: target_owner, repo: ^expected_repo, host: target_host} <- remote_owner_repo_parts(target_origin),
         host_origin when is_binary(host_origin) <- RepoIdentity.local_git_origin_remote(repo_root),
         %{owner: ^target_owner, host: host_host} <- remote_owner_repo_parts(host_origin),
         true <- same_remote_host?(target_host, host_host) do
      true
    else
      _result -> false
    end
  end

  defp same_owner_bare_repo_origin_match?(_expected_repo, _target_origin, _config), do: false

  defp bare_repo_name?(repo) when is_binary(repo) do
    repo = String.trim(repo)
    repo != "" and not String.contains?(repo, ["/", "\\", ":"])
  end

  defp remote_owner_repo_parts(remote) when is_binary(remote) do
    remote = remote |> String.trim() |> String.replace_suffix(".git", "")

    cond do
      scp_remote = Regex.run(~r/^[^@]+@([^:]+):([^\/\\]+)[\/\\]([^\/\\]+)$/, remote) ->
        [_match, host, owner, repo] = scp_remote
        %{host: normalize_remote_host(host), owner: String.downcase(owner), repo: repo}

      parts = uri_owner_repo_parts(remote) ->
        parts

      owner_repo = Regex.run(~r/^([^\/\\]+)[\/\\]([^\/\\]+)$/, remote) ->
        [_match, owner, repo] = owner_repo
        %{host: nil, owner: String.downcase(owner), repo: repo}

      true ->
        nil
    end
  end

  defp uri_owner_repo_parts(remote) do
    uri = URI.parse(remote)

    with host when is_binary(host) <- uri.host,
         path when is_binary(path) <- uri.path,
         [owner, repo | _rest] <- path |> String.trim_leading("/") |> String.split(~r/[\/\\]/, trim: true) do
      %{host: normalize_remote_host(host), owner: String.downcase(owner), repo: repo}
    else
      _result -> nil
    end
  end

  defp normalize_remote_host(host) when is_binary(host), do: String.downcase(host)
  defp normalize_remote_host(_host), do: nil

  defp same_remote_host?(nil, nil), do: true
  defp same_remote_host?(host, host) when is_binary(host), do: true
  defp same_remote_host?(_target_host, _host_host), do: false

  defp same_checkout_origin_remote(repo_root, target_repo_root) when is_binary(repo_root) and is_binary(target_repo_root) do
    if same_existing_path?(repo_root, target_repo_root), do: RepoIdentity.local_git_origin_remote(repo_root)
  end

  defp same_checkout_origin_remote(_repo_root, _target_repo_root), do: nil

  defp same_existing_path?(left, right) when is_binary(left) and is_binary(right) do
    with {:ok, left} <- PathSafety.canonicalize(left),
         {:ok, right} <- PathSafety.canonicalize(right) do
      same_filesystem_path?(left, right)
    else
      _result -> false
    end
  end

  defp same_existing_path?(_left, _right), do: false

  defp same_filesystem_path?(left, right), do: comparable_filesystem_path(left) == comparable_filesystem_path(right)

  defp comparable_filesystem_path(path) do
    path =
      path
      |> Path.expand()
      |> String.replace("\\", "/")
      |> String.trim_trailing("/")

    if match?({:win32, _name}, :os.type()), do: String.downcase(path), else: path
  end

  defp linked_planned_slice_work_request_for_work_package(repo, work_package_id) do
    PlannedSliceLinkage.linked_work_request_for_work_package(repo, work_package_id)
  end

  defp require_work_request_scope(repo, %WorkRequest{} = work_request, filters, opts \\ []) do
    match_fun = if Keyword.get(opts, :repo_scopes?, false), do: &work_request_matches_filters?/4, else: &work_request_matches_primary_filters?/4

    with {:ok, matches?} <- match_fun.(repo, work_request, filters, opts) do
      if matches?, do: :ok, else: {:error, :forbidden}
    end
  end

  defp require_work_package_repo_scope(%WorkPackage{} = work_package, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice) do
    if work_package.repo == PlannedSlice.delivery_repo(work_request, planned_slice), do: :ok, else: {:error, :forbidden}
  end

  defp require_work_package_delivery_base_scope(%WorkPackage{base_branch: base_branch}, %PlannedSlice{target_base_branch: base_branch}), do: :ok
  defp require_work_package_delivery_base_scope(%WorkPackage{}, %PlannedSlice{}), do: {:error, :forbidden}

  defp require_delivery_work_package_scope(%WorkPackage{} = work_package, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice) do
    with :ok <- require_work_package_repo_scope(work_package, work_request, planned_slice) do
      require_work_package_delivery_base_scope(work_package, planned_slice)
    end
  end

  defp require_planned_slice_authoring_status(status) when status in ["ready_for_slicing", "sliced"], do: :ok
  defp require_planned_slice_authoring_status(_status), do: {:tool_error, "invalid_status"}

  defp require_product_plan_node_content(nil, title, _description, _node_kind) do
    if filled_string?(title), do: :ok, else: {:tool_error, "missing_title"}
  end

  defp require_product_plan_node_content(_product_tree_node_id, title, description, node_kind) do
    if Enum.any?([title, description, node_kind], &filled_string?/1),
      do: :ok,
      else: {:tool_error, "missing_product_plan_node_content"}
  end

  defp require_product_plan_node_topology(parent_id_supplied?, position) do
    if parent_id_supplied? or is_integer(position),
      do: :ok,
      else: {:tool_error, "missing_product_plan_node_topology"}
  end

  defp require_product_tree_completion_mark(completion_mark) do
    if completion_mark in Node.completion_marks(),
      do: :ok,
      else: {:tool_error, "invalid_completion_mark"}
  end

  defp work_request_matches_filters?(repo, %WorkRequest{} = work_request, filters, opts) do
    with {:ok, repo_scopes} <- work_request_repo_scope_payloads(repo, work_request) do
      {:ok,
       repo_scope_matches_filters?(repo_scopes, filters, opts) and
         Enum.all?(filters, fn
           {"status", status} when is_binary(status) ->
             work_request.status == status

           {"phase_id", phase_id} when is_binary(phase_id) ->
             ArchitectHandoff.phase_id_for_work_request(work_request) == phase_id

           _filter ->
             true
         end)}
    end
  end

  defp work_request_matches_primary_filters?(_repo, %WorkRequest{} = work_request, filters, opts) do
    {:ok,
     Enum.all?(filters, fn
       {"repo", repo} when is_binary(repo) -> repo_scope_name_matches?(repo, work_request.repo, opts)
       {"base_branch", base_branch} when is_binary(base_branch) -> work_request.base_branch == base_branch
       {"status", status} when is_binary(status) -> work_request.status == status
       {"phase_id", phase_id} when is_binary(phase_id) -> ArchitectHandoff.phase_id_for_work_request(work_request) == phase_id
       _filter -> true
     end)}
  end

  defp repo_scope_matches_filters?(repo_scopes, filters, opts) do
    repo = Map.get(filters, "repo")
    base_branch = Map.get(filters, "base_branch")

    cond do
      is_binary(repo) and is_binary(base_branch) ->
        Enum.any?(repo_scopes, &(repo_scope_name_matches?(repo, &1.repo, opts) and &1.base_branch == base_branch))

      is_binary(repo) ->
        Enum.any?(repo_scopes, &repo_scope_name_matches?(repo, &1.repo, opts))

      is_binary(base_branch) ->
        Enum.any?(repo_scopes, &match?(%{base_branch: ^base_branch}, &1))

      true ->
        true
    end
  end

  defp repo_scope_name_matches?(repo, repo, _opts) when is_binary(repo), do: true

  defp repo_scope_name_matches?(expected_repo, actual_repo, opts) when is_binary(expected_repo) and is_binary(actual_repo) do
    RepoIdentity.scope_match?(expected_repo, actual_repo,
      trusted_remotes: Keyword.get(opts, :repo_scope_trusted_remotes, default_repo_scope_trusted_remotes()),
      local_path_remotes?: true
    )
  end

  defp repo_scope_name_matches?(_expected_repo, _actual_repo, _opts), do: false

  defp default_repo_scope_trusted_remotes do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_identity_trusted_remotes, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp work_request_repo_scope_opts(%Config{} = config) do
    [repo_scope_trusted_remotes: work_request_repo_scope_trusted_remotes(config)]
  end

  defp work_request_repo_scope_trusted_remotes(%Config{repo_root: repo_root} = config) when is_binary(repo_root) do
    repo_scope_trusted_remotes(config, repo_root)
  end

  defp work_request_repo_scope_trusted_remotes(%Config{}) do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_identity_trusted_remotes, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp work_request_repo_scope_metadata(opts) do
    case opts |> Keyword.get(:repo_scope_trusted_remotes, []) |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] -> %{}
      trusted_remotes -> %{repo_scope_trusted_remotes: trusted_remotes}
    end
  end

  defp work_request_repo_scope_payloads(repo, %WorkRequest{} = work_request) do
    with {:ok, repo_scopes} <- WorkRequestRepository.list_repo_scopes(repo, work_request.id) do
      scopes =
        [%{repo: work_request.repo, base_branch: work_request.base_branch} | Enum.map(repo_scopes, &%{repo: &1.repo, base_branch: &1.base_branch})]
        |> Enum.filter(&is_binary(&1.repo))
        |> Enum.uniq_by(&{&1.repo, &1.base_branch})

      {:ok, scopes}
    end
  end

  defp work_package_matches_filters?(%WorkPackage{} = work_package, filters, opts) do
    Enum.all?(filters, fn
      {"repo", repo} when is_binary(repo) -> repo_scope_name_matches?(repo, work_package.repo, opts)
      {"base_branch", base_branch} when is_binary(base_branch) -> work_package.base_branch == base_branch
      _filter -> true
    end)
  end

  defp require_architect_target_scope(repo, %Session{} = session, %{"work_package_id" => work_package_id}) do
    with :ok <- require_architect_work_package_scope(session, work_package_id) do
      require_architect_current_phase_anchor(repo, session)
    end
  end

  defp require_architect_target_scope(repo, %Session{} = session, %{"phase_id" => phase_id}) do
    with :ok <- require_architect_phase_scope(repo, session, phase_id) do
      require_architect_phase_anchor(repo, session, phase_id)
    end
  end

  defp require_architect_target_scope(repo, %Session{} = session, _arguments) do
    require_architect_current_phase_anchor(repo, session)
  end

  defp require_architect_current_phase_anchor(repo, %Session{} = session) do
    case architect_phase_scope(repo, session) do
      {:ok, phase_id} -> require_architect_phase_anchor(repo, session, phase_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_architect_child_status_scope(repo, %Session{} = session, work_package_id) do
    if Session.work_package_id(session) == work_package_id do
      require_architect_anchor_status_scope(repo, session)
    else
      case require_architect_child_work_package_scope(repo, session, work_package_id) do
        {:ok, _child} ->
          :ok

        {:error, :phase_scope_not_available} ->
          require_architect_dispatched_work_package_status_scope(repo, session, work_package_id)

        {:error, reason} ->
          {:error, reason}

        {:tool_error, "child_scope_outside_phase"} ->
          require_architect_dispatched_work_package_status_scope(repo, session, work_package_id)

        {:tool_error, _reason} ->
          {:error, :phase_scope_not_available}
      end
    end
  end

  defp require_architect_dispatched_work_package_status_scope(repo, %Session{} = session, work_package_id) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, true} <- ArchitectHandoff.handoff_phase_grant?(repo, grant),
         {:ok, _work_package, _scope} <- scoped_worktree_work_package(repo, session, work_package_id) do
      :ok
    else
      {:ok, false} -> {:error, :phase_scope_not_available}
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_architect_anchor_status_scope(repo, %Session{} = session) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, anchor} <- architect_anchor_work_package(repo, session) do
      require_anchor_status_phase_scope(repo, session, anchor, grant)
    else
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_anchor_status_phase_scope(repo, %Session{} = session, %WorkPackage{} = anchor, %AccessGrant{} = grant) do
    cond do
      architect_explicit_phase_grant?(grant) ->
        require_frozen_anchor_scope(anchor, grant)

      explicit_phase_id?(anchor.phase_id) ->
        require_child_phase_anchor_status(repo, session)

      true ->
        :ok
    end
  end

  defp require_child_phase_anchor_status(repo, %Session{} = session) do
    case architect_child_phase_anchor(repo, session) do
      {:ok, _phase_id, _anchor} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_architect_child_work_package_scope(repo, %Session{} = session, work_package_id) do
    with {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session),
         {:ok, child} <- scoped_child_work_package(repo, work_package_id),
         :ok <- require_phase_child_scope(child, anchor, phase_id) do
      {:ok, child}
    end
  end

  defp scoped_child_work_package(repo, work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, child} -> {:ok, child}
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_phase_child_scope(%WorkPackage{kind: "phase_child", phase_id: phase_id} = child, anchor, phase_id) do
    cond do
      child.parent_id != anchor.id -> {:error, :phase_scope_not_available}
      child.repo != anchor.repo -> {:tool_error, "repo_scope_mismatch"}
      child.base_branch != anchor.base_branch -> {:tool_error, "base_branch_scope_mismatch"}
      true -> require_phase_child_file_scope(child, anchor)
    end
  end

  defp require_phase_child_scope(%WorkPackage{}, _anchor, _phase_id), do: {:error, :phase_scope_not_available}

  defp require_phase_child_file_scope(%WorkPackage{} = child, %WorkPackage{} = anchor) do
    with {:ok, anchor_globs} <- normalize_child_scope_globs(anchor.allowed_file_globs || []),
         {:ok, child_globs} <- normalize_child_scope_globs(child.allowed_file_globs || []),
         :ok <- require_child_file_scope_present(child_globs),
         :ok <- reject_overbroad_child_globs(child_globs) do
      require_child_globs_within_anchor(child_globs, anchor_globs)
    end
  end

  defp create_child_work_package_transaction(repo, %Session{} = session, package) do
    case repo.transaction(fn ->
           create_child_work_package_or_rollback(repo, session, package)
         end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_child_work_package_or_rollback(repo, %Session{} = session, package) do
    case create_child_work_package_in_transaction(repo, session, package) do
      {:ok, result} -> result
      {:tool_error, reason} -> repo.rollback({:tool_error, reason})
      {:error, reason} -> repo.rollback({:error, reason})
    end
  end

  defp create_child_work_package_in_transaction(repo, %Session{} = session, package) do
    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, _architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, attrs} <- child_work_package_attrs(repo, session, package) do
      WorkPackageRepository.create(repo, attrs)
    end
  end

  defp mint_child_worker_key(%Config{} = config, %Session{} = session, work_package_id, template) do
    template = template || %{}

    with {:ok, claimed_by} <- child_worker_claimed_by(work_package_id, template),
         {:ok, {child, minted, ledger_database}} <-
           mint_child_worker_key_transaction(config, session, work_package_id, template) do
      {:ok,
       %{
         "work_package" => child_work_package_payload(child),
         "worker_grant" => child_worker_grant_payload(minted, child, claimed_by, ledger_database)
       }}
    end
  end

  defp mint_child_worker_key_transaction(%Config{repo: repo} = config, %Session{} = session, work_package_id, template) do
    case repo.transaction(fn ->
           mint_child_worker_key_or_rollback(config, session, work_package_id, template)
         end) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:tool_error, reason}} ->
        {:tool_error, reason}

      {:error, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mint_child_worker_key_or_rollback(%Config{repo: repo} = config, %Session{} = session, work_package_id, template) do
    case mint_child_worker_key_in_transaction(config, session, work_package_id, template) do
      {:ok, result} -> result
      {:tool_error, reason} -> repo.rollback({:tool_error, reason})
      {:error, reason} -> repo.rollback({:error, reason})
    end
  end

  defp mint_child_worker_key_in_transaction(%Config{repo: repo} = config, %Session{} = session, work_package_id, template) do
    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session, architect_grant),
         {:ok, grant_opts} <- child_worker_grant_opts(template, architect_grant),
         {:ok, _prechecked_child} <- require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id),
         :ok <- lock_work_package(repo, work_package_id),
         :ok <- reject_active_child_worker_grant(repo, work_package_id),
         {:ok, child} <- require_child_ready_for_mint(repo, work_package_id, anchor, phase_id),
         {:ok, ledger_database} <- dispatch_handoff_database(config.database, repo),
         {:ok, minted} <- AccessGrantService.mint_worker_grant(repo, child.id, grant_opts) do
      {:ok, {child, minted, ledger_database}}
    end
  end

  defp revoke_child_worker_key_transaction(repo, %Session{} = session, grant_id, reason) do
    run_architect_transaction(repo, fn ->
      revoke_child_worker_key_in_transaction(repo, session, grant_id, reason)
    end)
  end

  defp cleanup_work_request_planned_slice_runtime_in_transaction(
         repo,
         %Session{} = session,
         %WorkRequest{} = work_request,
         %PlannedSlice{} = planned_slice,
         work_package_id,
         reason,
         delivery_evidence,
         filters
       ) do
    primary_scope? = primary_work_request_scope?(repo, work_request, filters)

    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, _architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         :ok <-
           require_scoped_delivery_work_package_visibility(
             work_package,
             work_request,
             planned_slice,
             primary_scope?,
             filters
           ),
         :ok <- require_runtime_cleanup_delivery_state(work_package, delivery_evidence) do
      WorkRequestRuntimeCleanup.cleanup(repo, work_request, planned_slice, work_package, session.assignment,
        reason: reason,
        delivery_evidence: delivery_evidence
      )
    end
  end

  defp require_runtime_cleanup_delivery_state(%WorkPackage{}, %{"outcome" => "superseded"}), do: :ok

  defp require_runtime_cleanup_delivery_state(%WorkPackage{status: status}, %{"outcome" => "abandoned"})
       when status in ["planning", "ready_for_worker"],
       do: :ok

  defp require_runtime_cleanup_delivery_state(%WorkPackage{}, %{"outcome" => "abandoned"}), do: {:tool_error, "work_package_not_abandonable"}

  defp revoke_planned_slice_worker_key_in_transaction(
         repo,
         %Session{} = session,
         %WorkRequest{} = work_request,
         %PlannedSlice{} = planned_slice,
         work_package_id,
         grant_id,
         reason,
         filters
       ) do
    now = DateTime.utc_now(:microsecond)
    primary_scope? = primary_work_request_scope?(repo, work_request, filters)

    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, _architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         :ok <- lock_work_package(repo, work_package_id),
         :ok <- lock_access_grant(repo, grant_id),
         {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         :ok <-
           require_scoped_delivery_work_package_visibility(
             work_package,
             work_request,
             planned_slice,
             primary_scope?,
             filters
           ),
         :ok <- PlannedSliceWorkerRevoke.require_revoke_status(work_package),
         {:ok, grant} <- scoped_planned_slice_worker_grant_for_revoke(repo, grant_id, work_package_id, now),
         {:ok, recycled_work_package} <- PlannedSliceWorkerRevoke.update_status(repo, work_package, now),
         {:ok, revoked_grant} <- revoke_live_planned_slice_worker_grant(repo, grant, now),
         {:ok, event} <-
           append_planned_slice_worker_revoke_event(
             repo,
             session,
             work_request,
             planned_slice,
             work_package.status,
             recycled_work_package,
             revoked_grant,
             reason
           ) do
      {:ok,
       planned_slice_worker_revoke_result(
         work_request,
         planned_slice,
         work_package.status,
         recycled_work_package,
         revoked_grant,
         event,
         reason
       )}
    end
  end

  defp revoke_child_worker_key_in_transaction(repo, %Session{} = session, grant_id, reason) do
    now = DateTime.utc_now(:microsecond)

    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session, architect_grant),
         {:ok, candidate_grant} <- scoped_child_worker_grant_for_revoke(repo, grant_id, anchor, phase_id, now),
         :ok <- lock_work_package(repo, candidate_grant.work_package_id),
         :ok <- lock_access_grant(repo, grant_id),
         {:ok, grant} <- scoped_child_worker_grant_for_revoke(repo, grant_id, anchor, phase_id, now),
         {:ok, child} <- require_transaction_current_child_scope(repo, grant.work_package_id, anchor, phase_id),
         :ok <- require_child_worker_recyclable_status(child),
         {:ok, revoked_grant} <- revoke_live_child_worker_grant(repo, grant, now),
         {:ok, reset_child} <- reset_child_worker_for_recycle(repo, child, now),
         {:ok, event} <- append_child_worker_revoke_event(repo, session, child, reset_child, revoked_grant, reason) do
      {:ok, child_worker_revoke_result(reset_child, revoked_grant, event, reason, child.status)}
    end
  end

  defp required_revoke_child_worker_string(arguments, key) do
    case Map.fetch(arguments, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _value} ->
        {:tool_error, "invalid_#{key}"}

      :error ->
        {:tool_error, "missing_#{key}"}
    end
  end

  defp scoped_planned_slice_worker_grant_for_revoke(repo, grant_id, work_package_id, %DateTime{} = now) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, grant_id),
         :ok <- require_planned_slice_worker_grant_scope(grant, work_package_id),
         :ok <- require_live_planned_slice_worker_grant_for_revoke(grant, now) do
      {:ok, grant}
    end
  end

  defp require_planned_slice_worker_grant_scope(%AccessGrant{work_package_id: work_package_id}, work_package_id), do: :ok
  defp require_planned_slice_worker_grant_scope(%AccessGrant{}, _work_package_id), do: {:tool_error, "worker_grant_out_of_scope"}

  defp require_live_planned_slice_worker_grant_for_revoke(%AccessGrant{grant_role: "worker"} = grant, now) do
    cond do
      grant.provenance == @child_worker_grant_provenance ->
        {:tool_error, "not_planned_slice_worker_grant"}

      not child_worker_grant_capabilities?(grant.capabilities || []) ->
        {:tool_error, "not_planned_slice_worker_grant"}

      match?(%DateTime{}, grant.revoked_at) ->
        {:tool_error, "planned_slice_worker_grant_already_revoked"}

      not live_expires_at?(grant.expires_at, now) ->
        {:tool_error, "planned_slice_worker_grant_expired"}

      true ->
        :ok
    end
  end

  defp require_live_planned_slice_worker_grant_for_revoke(%AccessGrant{}, _now), do: {:tool_error, "not_planned_slice_worker_grant"}

  defp scoped_child_worker_grant_for_revoke(repo, grant_id, %WorkPackage{} = anchor, phase_id, %DateTime{} = now) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, grant_id),
         {:ok, work_package_id} <- child_worker_grant_work_package_id(grant),
         {:ok, _child} <- require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id),
         :ok <- require_live_child_worker_grant_for_revoke(grant, now) do
      {:ok, grant}
    end
  end

  defp child_worker_grant_work_package_id(%AccessGrant{work_package_id: work_package_id}) when is_binary(work_package_id) do
    case String.trim(work_package_id) do
      "" -> {:error, :phase_scope_not_available}
      trimmed -> {:ok, trimmed}
    end
  end

  defp child_worker_grant_work_package_id(%AccessGrant{}), do: {:error, :phase_scope_not_available}

  defp require_live_child_worker_grant_for_revoke(%AccessGrant{grant_role: "worker", provenance: @child_worker_grant_provenance} = grant, now) do
    cond do
      not child_worker_grant_capabilities?(grant.capabilities || []) ->
        {:tool_error, "not_child_worker_grant"}

      match?(%DateTime{}, grant.revoked_at) ->
        {:tool_error, "child_worker_grant_already_revoked"}

      not live_expires_at?(grant.expires_at, now) ->
        {:tool_error, "child_worker_grant_expired"}

      true ->
        :ok
    end
  end

  defp require_live_child_worker_grant_for_revoke(%AccessGrant{}, _now), do: {:tool_error, "not_child_worker_grant"}

  defp child_worker_grant_capabilities?(capabilities) when is_list(capabilities) do
    Enum.all?(capabilities, &(&1 in @child_worker_capabilities))
  end

  defp child_worker_grant_capabilities?(_capabilities), do: false

  defp require_child_worker_recyclable_status(%WorkPackage{status: status}) when status in @child_worker_recyclable_statuses, do: :ok
  defp require_child_worker_recyclable_status(%WorkPackage{}), do: {:tool_error, "child_not_recyclable"}

  defp revoke_live_planned_slice_worker_grant(repo, %AccessGrant{} = grant, %DateTime{} = now) do
    query =
      from(access_grant in AccessGrant,
        where:
          access_grant.id == ^grant.id and access_grant.work_package_id == ^grant.work_package_id and
            access_grant.grant_role == "worker" and is_nil(access_grant.revoked_at) and
            (is_nil(access_grant.expires_at) or access_grant.expires_at > ^now)
      )

    case repo.update_all(query, set: [revoked_at: now, updated_at: now]) do
      {1, _rows} -> AccessGrantRepository.get(repo, grant.id)
      {0, _rows} -> classify_planned_slice_worker_revoke_miss(repo, grant.id, now)
    end
  end

  defp classify_planned_slice_worker_revoke_miss(repo, grant_id, %DateTime{} = now) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, grant_id) do
      case require_live_planned_slice_worker_grant_for_revoke(grant, now) do
        :ok -> {:tool_error, "planned_slice_worker_revoke_conflict"}
        {:tool_error, reason} -> {:tool_error, reason}
      end
    end
  end

  defp revoke_live_child_worker_grant(repo, %AccessGrant{} = grant, %DateTime{} = now) do
    query =
      from(access_grant in AccessGrant,
        where:
          access_grant.id == ^grant.id and access_grant.work_package_id == ^grant.work_package_id and
            access_grant.grant_role == "worker" and access_grant.provenance == ^@child_worker_grant_provenance and
            is_nil(access_grant.revoked_at) and (is_nil(access_grant.expires_at) or access_grant.expires_at > ^now)
      )

    case repo.update_all(query, set: [revoked_at: now, updated_at: now]) do
      {1, _rows} -> AccessGrantRepository.get(repo, grant.id)
      {0, _rows} -> classify_child_worker_revoke_miss(repo, grant.id, now)
    end
  end

  defp classify_child_worker_revoke_miss(repo, grant_id, %DateTime{} = now) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, grant_id) do
      case require_live_child_worker_grant_for_revoke(grant, now) do
        :ok -> {:tool_error, "child_worker_revoke_conflict"}
        {:tool_error, reason} -> {:tool_error, reason}
      end
    end
  end

  defp reset_child_worker_for_recycle(_repo, %WorkPackage{status: @child_worker_ready_status} = child, _now), do: {:ok, child}

  defp reset_child_worker_for_recycle(repo, %WorkPackage{status: status} = child, %DateTime{} = now)
       when status in @child_worker_resettable_statuses do
    query =
      from(work_package in WorkPackage,
        where: work_package.id == ^child.id and work_package.kind == "phase_child" and work_package.status == ^status
      )

    case repo.update_all(query, set: [status: @child_worker_ready_status, updated_at: now]) do
      {1, _rows} -> WorkPackageRepository.get(repo, child.id)
      {0, _rows} -> {:tool_error, "child_worker_recycle_status_conflict"}
    end
  end

  defp reset_child_worker_for_recycle(_repo, %WorkPackage{}, _now), do: {:tool_error, "child_not_recyclable"}

  defp append_child_worker_revoke_event(
         repo,
         %Session{} = session,
         %WorkPackage{} = previous_child,
         %WorkPackage{} = reset_child,
         %AccessGrant{} = grant,
         reason
       ) do
    payload = child_worker_revoke_payload(reset_child.id, grant, reason, previous_child.status, reset_child.status)

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, reset_child.id, %{
      "summary" => "Child worker grant revoked for recycle",
      "body" => "Recycle reason: #{redacted_child_worker_revoke_reason(reason)}; child status: #{previous_child.status} -> #{reset_child.status}",
      "status" => "child_worker_key_revoked",
      "idempotency_key" => metadata_idempotency_key(payload),
      "payload" => payload
    })
  end

  defp child_worker_revoke_payload(work_package_id, %AccessGrant{} = grant, reason, previous_status, new_status) do
    reason_codes = child_worker_recycle_reason_codes(previous_status, new_status)

    %{
      "type" => "child_worker_key_revoke",
      "source_tool" => "revoke_child_worker_key",
      "work_package_id" => work_package_id,
      "grant_id" => grant.id,
      "reason" => redacted_child_worker_revoke_reason(reason),
      "revoked_at" => timestamp(grant.revoked_at),
      "previous_status" => previous_status,
      "new_status" => new_status,
      "status_reset" => previous_status != new_status,
      "lifecycle_state" => "recycled",
      "reason_codes" => reason_codes
    }
  end

  defp child_worker_revoke_result(%WorkPackage{} = child, %AccessGrant{} = grant, %ProgressEvent{} = event, reason, previous_status) do
    %{
      "work_package" => child_work_package_payload(child),
      "revoked_worker_grant" => revoked_child_worker_grant_payload(grant),
      "recycle" => %{
        "status" => "revoked",
        "reason" => redacted_child_worker_revoke_reason(reason),
        "previous_child_status" => previous_status,
        "new_child_status" => child.status,
        "status_reset" => previous_status != child.status,
        "remint_available" => true,
        "remint_precondition" => "child_status_ready_for_worker",
        "lifecycle_state" => "recycled",
        "reason_codes" => child_worker_recycle_reason_codes(previous_status, child.status)
      },
      "revocation_event" => progress_event_payload(event)
    }
  end

  defp append_planned_slice_worker_revoke_event(
         repo,
         %Session{} = session,
         %WorkRequest{} = work_request,
         %PlannedSlice{} = planned_slice,
         previous_work_package_status,
         %WorkPackage{} = work_package,
         %AccessGrant{} = grant,
         reason
       ) do
    payload =
      PlannedSliceWorkerRevoke.payload(
        work_request,
        planned_slice,
        previous_work_package_status,
        work_package,
        grant,
        reason
      )

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, work_package.id, %{
      "summary" => "WorkRequest planned-slice worker grant revoked for cleanup",
      "body" => "Cleanup reason: #{redacted_child_worker_revoke_reason(reason)}; WorkRequest: #{work_request.id}; planned slice: #{planned_slice.id}",
      "status" => "planned_slice_worker_key_revoked",
      "idempotency_key" => metadata_idempotency_key(payload),
      "payload" => payload
    })
  end

  defp planned_slice_worker_revoke_result(
         %WorkRequest{} = work_request,
         %PlannedSlice{} = planned_slice,
         previous_work_package_status,
         %WorkPackage{} = work_package,
         %AccessGrant{} = grant,
         %ProgressEvent{} = event,
         reason
       ) do
    reason_codes = PlannedSliceWorkerRevoke.reason_codes(previous_work_package_status, work_package.status)

    %{
      "work_request" => work_request_mutation_payload(work_request),
      "planned_slice" => planned_slice_payload(planned_slice),
      "work_package" => child_work_package_payload(work_package),
      "revoked_worker_grant" => revoked_child_worker_grant_payload(grant),
      "closeout_affordance" => %{
        "status" => "revoked",
        "reason" => PlannedSliceWorkerRevoke.redacted_reason(reason),
        "active_runtime_guard_bypassed" => false,
        "lifecycle_state" => "recycled",
        "previous_work_package_status" => previous_work_package_status,
        "work_package_status" => work_package.status,
        "reason_codes" => reason_codes
      },
      "revocation_event" => progress_event_payload(event)
    }
  end

  defp child_worker_recycle_reason_codes(previous_status, new_status) do
    [
      "worker_recycled",
      if(previous_status != new_status, do: "work_package_reset_for_recycle")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp revoked_child_worker_grant_payload(%AccessGrant{} = grant) do
    %{
      "id" => grant.id,
      "work_package_id" => grant.work_package_id,
      "grant_role" => grant.grant_role,
      "capabilities" => grant.capabilities || [],
      "expires_at" => timestamp(grant.expires_at),
      "revoked_at" => timestamp(grant.revoked_at),
      "secret_in_response" => false
    }
  end

  defp redacted_child_worker_revoke_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> Redactor.redact_text()
  end

  defp approve_child_ready_state_transaction(repo, %Session{} = session, work_package_id, rationale, request_id) do
    run_architect_transaction(repo, fn ->
      approve_child_ready_state_in_transaction(repo, session, work_package_id, rationale, request_id)
    end)
  end

  defp approve_child_ready_state_in_transaction(repo, %Session{} = session, work_package_id, rationale, request_id) do
    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session, architect_grant),
         {:ok, child} <- require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id),
         :ok <- lock_work_package(repo, child.id),
         {:ok, state} <- PlanningRepository.get_state(repo, child.id) do
      approve_child_ready_state_result(repo, session, state, rationale, request_id)
    end
  end

  defp approve_child_ready_state_result(repo, %Session{} = session, state, rationale, request_id) do
    case existing_child_ready_approval(repo, session, state, rationale, request_id) do
      {:ok, %ProgressEvent{} = event} ->
        replay_or_complete_child_ready_approval(repo, session, state, event)

      {:error, :not_found} ->
        with :ok <-
               require_child_status(
                 state.work_package,
                 "ready_for_architect_merge",
                 "child_not_ready_for_architect"
               ),
             :ok <- child_ready_approval_gates(repo, state),
             {:ok, event} <-
               append_child_ready_approval_event(repo, session, state.work_package, rationale, request_id),
             {:ok, approved_child} <- architect_phase_child_transition(repo, session, state.work_package, "merging_into_phase") do
          {:ok, child_ready_approval_result(approved_child, event)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_or_complete_child_ready_approval(
         repo,
         %Session{} = session,
         %{work_package: %WorkPackage{status: "ready_for_architect_merge"}} = state,
         %ProgressEvent{} = event
       ) do
    with :ok <- child_ready_approval_gates(repo, state),
         {:ok, approved_child} <- architect_phase_child_transition(repo, session, state.work_package, "merging_into_phase") do
      {:ok, child_ready_approval_result(approved_child, event)}
    end
  end

  defp replay_or_complete_child_ready_approval(_repo, %Session{}, state, %ProgressEvent{} = event) do
    {:ok, child_ready_approval_result(state.work_package, event)}
  end

  defp merge_child_into_phase_transaction(repo, %Session{} = session, work_package_id, merge_artifact) do
    run_architect_transaction(repo, fn ->
      merge_child_into_phase_in_transaction(repo, session, work_package_id, merge_artifact)
    end)
  end

  defp merge_child_into_phase_in_transaction(repo, %Session{} = session, work_package_id, merge_artifact) do
    with {:ok, merge_artifact} <- normalized_merge_artifact(merge_artifact),
         :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session, architect_grant),
         {:ok, child} <- require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id),
         :ok <- lock_work_package(repo, child.id),
         {:ok, state} <- PlanningRepository.get_state(repo, child.id) do
      merge_child_into_phase_result(repo, session, state, merge_artifact)
    end
  end

  defp merge_child_into_phase_result(repo, %Session{} = session, state, merge_artifact) do
    case existing_child_merge_record(repo, session, state.work_package.id, merge_artifact) do
      {:ok, %ProgressEvent{} = event} ->
        replay_or_complete_child_merge(repo, session, state, event, merge_artifact)

      {:error, :not_found} ->
        record_new_child_merge(repo, session, state, merge_artifact)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_or_complete_child_merge(
         repo,
         %Session{} = session,
         %{work_package: %WorkPackage{status: "merging_into_phase"}} = state,
         %ProgressEvent{} = event,
         merge_artifact
       ) do
    with :ok <- require_active_child_phase(repo, state.work_package),
         {:ok, artifact} <- record_phase_merge_artifact(repo, state.work_package, merge_artifact),
         {:ok, merged_child} <- architect_phase_child_transition(repo, session, state.work_package, "merged_into_phase") do
      {:ok, child_merge_result(merged_child, event, artifact, merge_artifact)}
    end
  end

  defp replay_or_complete_child_merge(repo, %Session{}, state, %ProgressEvent{} = event, merge_artifact) do
    with :ok <- require_active_child_phase(repo, state.work_package),
         {:ok, artifact} <- current_phase_merge_artifact(repo, state.work_package, merge_artifact) do
      {:ok, child_merge_result(state.work_package, event, artifact, current_merge_artifact(artifact))}
    end
  end

  defp record_new_child_merge(
         repo,
         %Session{} = session,
         %{work_package: %WorkPackage{status: "merging_into_phase"}} = state,
         merge_artifact
       ) do
    with :ok <- require_active_child_phase(repo, state.work_package),
         {:ok, artifact} <- record_phase_merge_artifact(repo, state.work_package, merge_artifact),
         {:ok, event} <- append_child_merge_event(repo, session, state.work_package, merge_artifact),
         {:ok, merged_child} <- architect_phase_child_transition(repo, session, state.work_package, "merged_into_phase") do
      {:ok, child_merge_result(merged_child, event, artifact, merge_artifact)}
    end
  end

  defp record_new_child_merge(
         repo,
         %Session{} = session,
         %{work_package: %WorkPackage{status: "merged_into_phase"}} = state,
         merge_artifact
       ) do
    with :ok <- require_active_child_phase(repo, state.work_package),
         {:ok, artifact} <- record_phase_merge_artifact(repo, state.work_package, merge_artifact),
         {:ok, event} <- append_child_merge_event(repo, session, state.work_package, merge_artifact) do
      {:ok, child_merge_result(state.work_package, event, artifact, merge_artifact)}
    end
  end

  defp record_new_child_merge(_repo, %Session{}, state, _merge_artifact) do
    require_child_status(state.work_package, "merging_into_phase", "child_not_approved_for_merge")
  end

  defp require_active_child_phase(repo, %WorkPackage{} = child) do
    case readiness_phase(repo, child) do
      {:ok, %{status: "active"}} -> :ok
      {:ok, _phase} -> {:tool_error, "phase_not_active"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_phase_merge_artifact(repo, %WorkPackage{} = child, merge_artifact) do
    case PlanningRepository.get_artifact(repo, phase_merge_artifact_id(child.id)) do
      {:ok, nil} ->
        with :ok <- require_active_child_phase(repo, child) do
          record_phase_merge_artifact(repo, child, merge_artifact)
        end

      {:ok, %Artifact{} = artifact} ->
        {:ok, artifact}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_child_ready_for_mint(repo, work_package_id, %WorkPackage{} = anchor, phase_id) when is_binary(work_package_id) do
    now = DateTime.utc_now(:microsecond)

    query =
      from(work_package in WorkPackage,
        where:
          work_package.id == ^work_package_id and work_package.status == "ready_for_worker" and
            work_package.kind == "phase_child" and work_package.phase_id == ^phase_id and work_package.parent_id == ^anchor.id and
            work_package.repo == ^anchor.repo and work_package.base_branch == ^anchor.base_branch
      )

    case repo.update_all(query, set: [updated_at: now]) do
      {1, _rows} -> require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id)
      {0, _rows} -> classify_child_ready_mint_miss(repo, work_package_id, anchor, phase_id)
    end
  end

  defp require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id) do
    with {:ok, child} <- scoped_child_work_package(repo, work_package_id),
         :ok <- require_phase_child_scope(child, anchor, phase_id) do
      {:ok, child}
    end
  end

  defp classify_child_ready_mint_miss(repo, work_package_id, anchor, phase_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, child} ->
        case require_phase_child_scope(child, anchor, phase_id) do
          :ok -> {:tool_error, "child_not_ready_for_worker"}
          {:error, reason} -> {:error, reason}
          {:tool_error, reason} -> {:tool_error, reason}
        end

      {:error, _reason} ->
        {:error, :phase_scope_not_available}
    end
  end

  defp require_child_status(%WorkPackage{status: status}, status, _reason), do: :ok
  defp require_child_status(%WorkPackage{}, _status, reason), do: {:tool_error, reason}

  defp child_ready_approval_gates(repo, state) do
    with {:ok, {required_review_lanes, _warnings}} <- ReviewLanes.required(repo, state.work_package),
         {:ok, reasons} <- readiness_failure_reasons(repo, state, required_review_lanes) do
      reasons = Enum.reject(reasons, &(Map.get(&1, "gate") in ["status_ci_waiting", "status_reviewing"]))
      missing = missing_readiness_gates(reasons)

      if missing == [], do: :ok, else: {:error, {:readiness_failed, missing, reasons}}
    end
  end

  defp existing_child_ready_approval(repo, %Session{} = session, %{work_package: %WorkPackage{} = child}, _rationale, request_id)
       when is_binary(request_id) do
    ready_cycle_id = child_ready_approval_ready_cycle_id(child)

    case current_cycle_child_ready_approval_event(repo, session, child.id, request_id, ready_cycle_id) do
      {:ok, %ProgressEvent{} = event} ->
        {:ok, event}

      {:error, :not_found} ->
        replay_latest_child_ready_approval_event(repo, session, child, request_id, ready_cycle_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing_child_ready_approval(_repo, %Session{}, _state, _rationale, _request_id), do: {:error, :not_found}

  defp current_cycle_child_ready_approval_event(_repo, %Session{}, _work_package_id, _request_id, nil), do: {:error, :not_found}

  defp current_cycle_child_ready_approval_event(repo, %Session{} = session, work_package_id, request_id, ready_cycle_id) do
    identity = child_ready_approval_request_identity(work_package_id, request_id, ready_cycle_id)
    idempotency_key = child_ready_approval_idempotency_key(work_package_id, request_id, nil, ready_cycle_id)

    case PlanningRepository.get_progress_event_by_idempotency_key(
           repo,
           work_package_id,
           idempotency_key,
           session.assignment.grant_id
         ) do
      {:ok, event} ->
        validate_child_ready_approval_event(event, session, identity)

      {:error, :not_found} ->
        replay_child_ready_approval_event(repo, session, work_package_id, idempotency_key, identity)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_latest_child_ready_approval_event(repo, %Session{} = session, %WorkPackage{} = child, request_id, ready_cycle_id) do
    with {:ok, event} <- latest_child_ready_approval_event(repo, child.id, request_id),
         :ok <- child_ready_approval_event_matches_current_cycle?(repo, event, child, ready_cycle_id) do
      event_ready_cycle_id = Map.get(event.payload || %{}, "ready_cycle_id")
      identity = child_ready_approval_request_identity(child.id, request_id, event_ready_cycle_id)

      validate_child_ready_approval_event(event, session, identity)
    end
  end

  defp latest_child_ready_approval_event(repo, work_package_id, request_id) do
    case PlanningRepository.list_progress_events(repo, work_package_id) do
      {:ok, progress_events} ->
        progress_events
        |> Enum.filter(&child_ready_approval_request_event?(&1, request_id))
        |> List.last()
        |> case do
          %ProgressEvent{} = event -> {:ok, event}
          nil -> {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp child_ready_approval_request_event?(%ProgressEvent{status: "child_ready_approved", payload: payload}, request_id)
       when is_map(payload) do
    Map.take(payload, ["type", "source_tool", "request_id"]) == %{
      "type" => "child_ready_approval",
      "source_tool" => "approve_child_ready_state",
      "request_id" => request_id
    }
  end

  defp child_ready_approval_request_event?(%ProgressEvent{}, _request_id), do: false

  defp latest_child_ready_approval_event(repo, work_package_id) do
    case PlanningRepository.list_progress_events(repo, work_package_id) do
      {:ok, progress_events} ->
        progress_events
        |> Enum.filter(&child_ready_approval_event?/1)
        |> List.last()
        |> case do
          %ProgressEvent{} = event -> {:ok, event}
          nil -> {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp child_ready_approval_event?(%ProgressEvent{status: "child_ready_approved", payload: payload}) when is_map(payload) do
    Map.take(payload, ["type", "source_tool"]) == %{
      "type" => "child_ready_approval",
      "source_tool" => "approve_child_ready_state"
    }
  end

  defp child_ready_approval_event?(%ProgressEvent{}), do: false

  defp child_ready_approval_event_matches_current_cycle?(
         _repo,
         %ProgressEvent{payload: payload},
         %WorkPackage{status: "ready_for_architect_merge"},
         ready_cycle_id
       )
       when is_map(payload) do
    if Map.get(payload, "ready_cycle_id") == ready_cycle_id, do: :ok, else: {:error, :not_found}
  end

  defp child_ready_approval_event_matches_current_cycle?(repo, %ProgressEvent{} = event, %WorkPackage{id: child_id, status: status}, _ready_cycle_id)
       when status in ["merging_into_phase", "merged_into_phase", "blocked"] do
    with {:ok, latest_event} <- latest_child_ready_approval_event(repo, child_id) do
      if latest_event.id == event.id, do: :ok, else: {:error, :not_found}
    end
  end

  defp child_ready_approval_event_matches_current_cycle?(_repo, %ProgressEvent{}, %WorkPackage{}, _ready_cycle_id), do: {:error, :not_found}

  defp append_child_ready_approval_event(repo, %Session{} = session, %WorkPackage{} = child, rationale, request_id) do
    operation_id = if is_binary(request_id), do: nil, else: child_ready_approval_operation_id()
    ready_cycle_id = child_ready_approval_ready_cycle_id(child)
    payload = child_ready_approval_payload(child.id, rationale, request_id, operation_id, ready_cycle_id)

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, child.id, %{
      "summary" => "Child ready state approved",
      "status" => "child_ready_approved",
      "idempotency_key" => child_ready_approval_idempotency_key(child.id, request_id, operation_id, ready_cycle_id),
      "payload" => payload
    })
  end

  defp child_ready_approval_payload(work_package_id, rationale, request_id, operation_id, ready_cycle_id) do
    %{
      "type" => "child_ready_approval",
      "source_tool" => "approve_child_ready_state",
      "work_package_id" => work_package_id,
      "rationale" => rationale
    }
    |> maybe_put_filled_string("request_id", request_id)
    |> maybe_put_filled_string("operation_id", operation_id)
    |> maybe_put_filled_string("ready_cycle_id", ready_cycle_id)
  end

  defp child_ready_approval_idempotency_key(work_package_id, request_id, _operation_id, ready_cycle_id) when is_binary(request_id) do
    child_ready_approval_request_identity(work_package_id, request_id, ready_cycle_id)
    |> metadata_idempotency_key()
  end

  defp child_ready_approval_idempotency_key(work_package_id, _request_id, operation_id, _ready_cycle_id) do
    child_ready_approval_operation_payload(work_package_id)
    |> Map.put("operation_id", operation_id)
    |> metadata_idempotency_key()
  end

  defp child_ready_approval_operation_payload(work_package_id) do
    %{
      "type" => "child_ready_approval",
      "source_tool" => "approve_child_ready_state",
      "work_package_id" => work_package_id
    }
  end

  defp child_ready_approval_request_identity(work_package_id, request_id, ready_cycle_id) do
    work_package_id
    |> child_ready_approval_operation_payload()
    |> Map.put("request_id", request_id)
    |> maybe_put_filled_string("ready_cycle_id", ready_cycle_id)
  end

  defp child_ready_approval_ready_cycle_id(%WorkPackage{status: "ready_for_architect_merge", updated_at: %DateTime{} = updated_at}) do
    DateTime.to_iso8601(updated_at)
  end

  defp child_ready_approval_ready_cycle_id(%WorkPackage{}), do: nil

  defp child_ready_approval_operation_id do
    Id.random("approval")
  end

  defp child_ready_approval_result(%WorkPackage{} = child, %ProgressEvent{} = event) do
    %{
      "work_package" => child_work_package_payload(child),
      "approval" => progress_event_payload(event)
    }
  end

  defp normalized_merge_artifact(merge_artifact) when is_map(merge_artifact) do
    with {:ok, status} <- merge_artifact_string(merge_artifact, "status"),
         :ok <- require_merge_artifact_status(status),
         {:ok, uri} <- merge_artifact_string(merge_artifact, "uri") do
      merge_artifact =
        merge_artifact
        |> trim_string_values()
        |> Map.put("status", status)
        |> Map.put("uri", uri)

      {:ok, merge_artifact}
    end
  end

  defp merge_artifact_string(merge_artifact, key) do
    case Map.get(merge_artifact, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_merge_artifact_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "missing_merge_artifact_#{key}"}
    end
  end

  defp require_merge_artifact_status("merged_into_phase"), do: :ok
  defp require_merge_artifact_status(_status), do: {:tool_error, "invalid_merge_artifact_status"}

  defp trim_string_values(value) when is_map(value) do
    Map.new(value, fn
      {key, string} when is_binary(string) -> {key, String.trim(string)}
      {key, nested} -> {key, trim_string_values(nested)}
    end)
  end

  defp trim_string_values(values) when is_list(values), do: Enum.map(values, &trim_string_values/1)
  defp trim_string_values(value), do: value

  defp existing_child_merge_record(repo, %Session{} = session, work_package_id, merge_artifact) do
    payload = child_merge_payload(work_package_id, merge_artifact)
    idempotency_key = metadata_idempotency_key(payload)

    case PlanningRepository.get_progress_event_by_idempotency_key(
           repo,
           work_package_id,
           idempotency_key,
           session.assignment.grant_id
         ) do
      {:ok, event} -> validate_child_merge_event(event, session, payload)
      {:error, :not_found} -> replay_child_merge_event(repo, session, work_package_id, idempotency_key, payload)
      {:error, reason} -> {:error, reason}
    end
  end

  defp replay_child_ready_approval_event(repo, %Session{} = session, work_package_id, idempotency_key, expected_identity) do
    with {:ok, event} <- existing_child_progress_event(repo, work_package_id, idempotency_key) do
      validate_child_ready_approval_event(event, session, expected_identity)
    end
  end

  defp replay_child_merge_event(repo, %Session{} = session, work_package_id, idempotency_key, expected_payload) do
    with {:ok, event} <- existing_child_progress_event(repo, work_package_id, idempotency_key) do
      validate_child_merge_event(event, session, expected_payload)
    end
  end

  defp existing_child_progress_event(repo, work_package_id, idempotency_key) do
    case PlanningRepository.list_progress_events(repo, work_package_id) do
      {:ok, progress_events} -> matching_progress_event(progress_events, idempotency_key)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_child_ready_approval_event(event, session, expected_identity) do
    if event.status == "child_ready_approved" and child_ready_approval_identity_matches?(event.payload, expected_identity) do
      with :ok <- child_progress_event_actor_matches?(event, session), do: {:ok, event}
    else
      {:error, :idempotency_conflict}
    end
  end

  defp child_ready_approval_identity_matches?(payload, expected_identity) when is_map(payload) do
    payload
    |> Map.take(["type", "source_tool", "work_package_id", "request_id", "ready_cycle_id"])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Kernel.==(expected_identity)
  end

  defp child_ready_approval_identity_matches?(_payload, _expected_identity), do: false

  defp validate_child_merge_event(event, session, expected_payload) do
    if event.status == "merged_into_phase" and event.payload == expected_payload do
      with :ok <- child_progress_event_actor_role_matches?(event, session), do: {:ok, event}
    else
      {:error, :idempotency_conflict}
    end
  end

  defp child_progress_event_actor_matches?(%ProgressEvent{actor_id: event_actor_id, actor_type: event_actor_type}, %Session{} = session) do
    current_actor_id = session.assignment.claimed_by
    current_actor_type = session.assignment.grant_role

    cond do
      filled_string?(event_actor_type) and event_actor_type != current_actor_type ->
        {:error, :idempotency_conflict}

      filled_string?(event_actor_id) and filled_string?(current_actor_id) ->
        if String.trim(event_actor_id) == String.trim(current_actor_id), do: :ok, else: {:error, :idempotency_conflict}

      filled_string?(event_actor_id) ->
        {:error, :idempotency_conflict}

      true ->
        :ok
    end
  end

  defp child_progress_event_actor_role_matches?(%ProgressEvent{actor_type: event_actor_type}, %Session{} = session) do
    current_actor_type = session.assignment.grant_role

    if filled_string?(event_actor_type) and event_actor_type != current_actor_type do
      {:error, :idempotency_conflict}
    else
      :ok
    end
  end

  defp append_child_merge_event(repo, %Session{} = session, %WorkPackage{} = child, merge_artifact) do
    payload = child_merge_payload(child.id, merge_artifact)

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, child.id, %{
      "summary" => Map.get(merge_artifact, "summary") || "Child merged into phase",
      "status" => "merged_into_phase",
      "idempotency_key" => metadata_idempotency_key(payload),
      "payload" => payload
    })
  end

  defp child_merge_payload(work_package_id, merge_artifact) do
    %{
      "type" => "phase_child_merge",
      "source_tool" => "merge_child_into_phase",
      "work_package_id" => work_package_id,
      "merge_artifact" => merge_artifact
    }
  end

  defp record_phase_merge_artifact(repo, %WorkPackage{} = child, merge_artifact) do
    attrs = %{
      id: phase_merge_artifact_id(child.id),
      work_package_id: child.id,
      path: "phase-merge.json",
      title: "Phase merge record",
      kind: "phase_merge",
      uri: Map.fetch!(merge_artifact, "uri"),
      metadata: merge_artifact
    }

    case PlanningRepository.get_artifact(repo, attrs.id) do
      {:ok, nil} -> PlanningRepository.append_artifact(repo, attrs)
      {:ok, %Artifact{} = artifact} -> PlanningRepository.update_artifact(repo, artifact, Map.drop(attrs, [:id, :work_package_id]))
      {:error, reason} -> {:error, reason}
    end
  end

  defp phase_merge_artifact_id(work_package_id) do
    material = [work_package_id, "phase-merge.json"] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp child_merge_result(%WorkPackage{} = child, %ProgressEvent{} = event, %Artifact{} = artifact, merge_artifact) do
    %{
      "work_package" => child_work_package_payload(child),
      "merge" => progress_event_payload(event),
      "artifact" => artifact_payload(artifact),
      "merge_artifact" => merge_artifact
    }
  end

  defp current_merge_artifact(%Artifact{} = artifact) do
    artifact
    |> artifact_metadata()
    |> Map.put("status", "merged_into_phase")
    |> Map.put("uri", artifact.uri)
  end

  defp artifact_metadata(%Artifact{metadata: metadata}) when is_map(metadata), do: metadata
  defp artifact_metadata(%Artifact{}), do: %{}

  defp architect_phase_child_transition(repo, %Session{} = session, %WorkPackage{} = child, next_status) do
    actor =
      session
      |> actor()
      |> Map.put(:work_package_id, child.id)
      |> Map.update!(:capabilities, &Enum.uniq(["architect:lifecycle.transition" | &1]))

    with :ok <- StateMachine.validate_transition(child, next_status, actor) do
      WorkPackageRepository.update_status(repo, child.id, child.status, next_status)
    end
  end

  defp reject_active_child_worker_grant(repo, work_package_id) do
    now = DateTime.utc_now(:microsecond)

    query =
      from(grant in AccessGrant,
        where:
          grant.work_package_id == ^work_package_id and grant.grant_role == "worker" and is_nil(grant.revoked_at) and
            grant.provenance == ^@child_worker_grant_provenance and
            (is_nil(grant.expires_at) or grant.expires_at > ^now),
        select: count(grant.id)
      )

    case repo.one(query) do
      0 -> :ok
      nil -> :ok
      _active_count -> {:tool_error, "active_child_worker_grant_exists"}
    end
  end

  defp architect_anchor_work_package(repo, %Session{} = session) do
    case Session.work_package_id(session) do
      work_package_id when is_binary(work_package_id) -> WorkPackageRepository.get(repo, work_package_id)
      _work_package_id -> {:error, :phase_scope_not_available}
    end
  end

  defp child_work_package_attrs(repo, %Session{} = session, package) do
    with {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session),
         :ok <- validate_child_work_package_keys(package),
         {:ok, title} <- required_argument(package, "title"),
         {:ok, acceptance_criteria} <- required_string_list(package, "acceptance_criteria"),
         {:ok, allowed_file_globs} <- child_allowed_file_globs(package, anchor),
         :ok <- require_child_field_match(package, "kind", "phase_child", "invalid_child_kind"),
         :ok <- require_child_field_match(package, "policy_template", "phase_child", "invalid_policy_template"),
         :ok <- require_child_field_match(package, "status", "ready_for_worker", "invalid_child_status"),
         :ok <- require_child_field_match(package, "repo", anchor.repo, "repo_scope_mismatch"),
         :ok <- require_child_field_match(package, "base_branch", anchor.base_branch, "base_branch_scope_mismatch"),
         :ok <- require_child_field_match(package, "phase_id", phase_id, :phase_scope_not_available),
         :ok <- require_child_field_match(package, "parent_id", anchor.id, "parent_scope_mismatch"),
         {:ok, branch_pattern} <- optional_child_string(package, "branch_pattern"),
         {:ok, product_description} <- optional_child_string(package, "product_description", anchor.product_description),
         {:ok, engineering_scope} <- optional_child_string(package, "engineering_scope", anchor.engineering_scope),
         {:ok, owner_id} <- optional_child_string(package, "owner_id") do
      attrs =
        %{
          "acceptance_criteria" => acceptance_criteria,
          "allowed_file_globs" => allowed_file_globs,
          "base_branch" => anchor.base_branch,
          "kind" => "phase_child",
          "parent_id" => anchor.id,
          "phase_id" => phase_id,
          "policy_template" => "phase_child",
          "repo" => anchor.repo,
          "status" => "ready_for_worker",
          "title" => title
        }
        |> maybe_put_id(package)
        |> put_optional_child_value("branch_pattern", branch_pattern)
        |> put_optional_child_value("product_description", product_description)
        |> put_optional_child_value("engineering_scope", engineering_scope)
        |> put_optional_child_value("owner_id", owner_id)

      {:ok, attrs}
    end
  end

  defp validate_child_work_package_keys(package) do
    unexpected = package |> Map.keys() |> Enum.reject(&(&1 in @child_work_package_keys))

    cond do
      "context_slice" in unexpected -> {:tool_error, "unsupported_context_slice"}
      unexpected == [] -> :ok
      true -> {:tool_error, "unexpected_package_field"}
    end
  end

  defp child_allowed_file_globs(package, %WorkPackage{} = anchor) do
    with {:ok, default_globs} <- normalize_child_scope_globs(anchor.allowed_file_globs || []),
         {:ok, globs} <- optional_child_string_list(package, "allowed_file_globs", default_globs),
         :ok <- require_child_file_scope_present(globs),
         :ok <- reject_overbroad_child_globs(globs),
         :ok <- require_child_globs_within_anchor(globs, default_globs) do
      {:ok, globs}
    end
  end

  defp require_child_file_scope_present([]), do: {:tool_error, "missing_allowed_file_globs"}
  defp require_child_file_scope_present(_globs), do: :ok

  defp reject_overbroad_child_globs(globs) do
    if Enum.any?(globs, &ScopeGuard.overbroad_glob?/1) do
      {:tool_error, "overbroad_allowed_file_globs"}
    else
      :ok
    end
  end

  defp require_child_globs_within_anchor(_child_globs, []), do: :ok

  defp require_child_globs_within_anchor(child_globs, anchor_globs) do
    if Enum.all?(child_globs, &glob_within_any_anchor?(&1, anchor_globs)) do
      :ok
    else
      {:tool_error, "child_scope_outside_phase"}
    end
  end

  defp glob_within_any_anchor?(child_glob, anchor_globs) do
    Enum.any?(anchor_globs, &glob_within_anchor?(child_glob, &1))
  end

  defp glob_within_anchor?(child_glob, anchor_glob) do
    with {:ok, child_segments} <- child_glob_segments(child_glob),
         {:ok, anchor_segments} <- child_glob_segments(anchor_glob) do
      glob_segments_within?(child_segments, anchor_segments)
    else
      {:tool_error, _reason} -> false
    end
  end

  defp child_glob_segments(glob) do
    glob = normalize_child_glob(glob)

    cond do
      glob == "" -> {:tool_error, "missing_allowed_file_globs"}
      traversal_glob?(glob) -> {:tool_error, "path_traversal_allowed_file_globs"}
      encoded_separator_glob?(glob) -> {:tool_error, "invalid_allowed_file_globs"}
      true -> {:ok, String.split(glob, "/", trim: true)}
    end
  end

  defp glob_segments_within?([], []), do: true
  defp glob_segments_within?([], _anchor_segments), do: false
  defp glob_segments_within?(_child_segments, []), do: false
  defp glob_segments_within?(child_segments, ["**"]), do: not Enum.any?(child_segments, &traversal_segment?/1)

  defp glob_segments_within?(["**" | child_tail], ["**" | anchor_tail]) do
    glob_segments_within?(child_tail, ["**" | anchor_tail])
  end

  defp glob_segments_within?([_child_head | child_tail] = child_segments, ["**" | anchor_tail]) do
    glob_segments_within?(child_segments, anchor_tail) or
      glob_segments_within?(child_tail, ["**" | anchor_tail])
  end

  defp glob_segments_within?(["**" | _child_tail], [_anchor_head | _anchor_tail]), do: false

  defp glob_segments_within?([child_head | child_tail], [anchor_head | anchor_tail]) do
    segment_within_anchor?(child_head, anchor_head) and glob_segments_within?(child_tail, anchor_tail)
  end

  defp segment_within_anchor?(child_segment, anchor_segment) do
    cond do
      child_segment == anchor_segment -> true
      anchor_segment == "*" -> child_segment != "**"
      child_segment == "**" -> false
      literal_glob?(child_segment) -> ScopeGuard.glob_match?(anchor_segment, child_segment)
      simple_star_segment_subset?(child_segment, anchor_segment) -> true
      true -> false
    end
  end

  defp literal_glob?(glob), do: not String.contains?(glob, ["*", "?", "["])

  defp simple_star_segment_subset?(child_segment, anchor_segment) do
    with {:ok, {anchor_prefix, anchor_suffix}} <- simple_star_bounds(anchor_segment),
         {child_prefix, child_suffix} <- segment_literal_bounds(child_segment) do
      String.starts_with?(child_prefix, anchor_prefix) and String.ends_with?(child_suffix, anchor_suffix)
    else
      :error -> false
    end
  end

  defp simple_star_bounds(segment) do
    cond do
      String.contains?(segment, ["?", "["]) -> :error
      segment |> String.graphemes() |> Enum.count(&(&1 == "*")) != 1 -> :error
      true -> {:ok, segment |> String.split("*", parts: 2) |> List.to_tuple()}
    end
  end

  defp segment_literal_bounds(segment) do
    tokens = segment_tokens(String.graphemes(segment), [])

    prefix =
      tokens
      |> Enum.take_while(&match?({:literal, _char}, &1))
      |> literal_token_string()

    suffix =
      tokens
      |> Enum.reverse()
      |> Enum.take_while(&match?({:literal, _char}, &1))
      |> Enum.reverse()
      |> literal_token_string()

    {prefix, suffix}
  end

  defp segment_tokens([], acc), do: Enum.reverse(acc)
  defp segment_tokens(["*" | rest], acc), do: segment_tokens(rest, [:wildcard | acc])
  defp segment_tokens(["?" | rest], acc), do: segment_tokens(rest, [:wildcard | acc])

  defp segment_tokens(["[" | rest], acc) do
    case drop_character_class(rest, false) do
      {:ok, rest} -> segment_tokens(rest, [:wildcard | acc])
      :error -> segment_tokens(rest, [{:literal, "["} | acc])
    end
  end

  defp segment_tokens([char | rest], acc), do: segment_tokens(rest, [{:literal, char} | acc])

  defp drop_character_class([], _has_content?), do: :error
  defp drop_character_class(["]" | _rest], false), do: :error
  defp drop_character_class(["]" | rest], true), do: {:ok, rest}
  defp drop_character_class([_char | rest], _has_content?), do: drop_character_class(rest, true)

  defp literal_token_string(tokens) do
    Enum.map_join(tokens, "", fn {:literal, char} -> char end)
  end

  defp require_child_field_match(package, key, expected, reason) do
    case Map.fetch(package, key) do
      :error -> :ok
      {:ok, nil} -> {:tool_error, "invalid_#{key}"}
      {:ok, value} when is_binary(value) -> require_nonblank_field_match(value, key, expected, reason)
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp require_nonblank_field_match(value, key, expected, reason) do
    case String.trim(value) do
      "" -> {:tool_error, "invalid_#{key}"}
      trimmed -> reject_null_string_field(trimmed, key, expected, reason)
    end
  end

  defp reject_null_string_field(trimmed, key, expected, reason) do
    if String.downcase(trimmed) == "null" do
      {:tool_error, "invalid_#{key}"}
    else
      require_optional_field_match(trimmed, expected, reason)
    end
  end

  defp require_optional_field_match(expected, expected, _reason), do: :ok
  defp require_optional_field_match(_value, _expected, reason) when is_atom(reason), do: {:error, reason}
  defp require_optional_field_match(_value, _expected, reason), do: {:tool_error, reason}

  defp optional_child_string(package, key, default \\ nil) do
    case Map.fetch(package, key) do
      :error -> {:ok, default}
      {:ok, nil} -> {:ok, default}
      {:ok, value} when is_binary(value) -> {:ok, blank_default(value, default)}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp optional_child_string_list(package, key, default) do
    case Map.fetch(package, key) do
      :error -> {:ok, default}
      {:ok, nil} -> {:ok, default}
      {:ok, values} when is_list(values) -> normalize_child_string_list(values, key)
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp normalize_child_string_list([], key), do: {:tool_error, "missing_#{key}"}

  defp normalize_child_string_list(values, key) do
    if Enum.all?(values, &(is_binary(&1) and normalize_child_glob(&1) != "")) do
      case normalize_child_scope_globs(values) do
        {:ok, []} -> {:tool_error, "missing_#{key}"}
        {:ok, globs} -> {:ok, globs}
        {:tool_error, reason} -> {:tool_error, reason}
      end
    else
      {:tool_error, "invalid_#{key}"}
    end
  end

  defp normalize_child_scope_globs(globs) when is_list(globs) do
    normalized_globs =
      globs
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&normalize_child_glob/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      Enum.any?(normalized_globs, &traversal_glob?/1) ->
        {:tool_error, "path_traversal_allowed_file_globs"}

      Enum.any?(normalized_globs, &encoded_separator_glob?/1) ->
        {:tool_error, "invalid_allowed_file_globs"}

      true ->
        {:ok, normalized_globs}
    end
  end

  defp normalize_child_scope_globs(_globs), do: {:ok, []}

  defp normalize_child_glob(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.replace(~r/\A\.\//, "")
  end

  defp normalize_child_glob(_value), do: ""

  defp traversal_glob?(glob) when is_binary(glob) do
    glob
    |> String.split("/", trim: true)
    |> Enum.any?(&traversal_segment?/1)
  end

  defp traversal_glob?(_glob), do: false

  defp encoded_separator_glob?(glob) when is_binary(glob) do
    glob
    |> String.split("/", trim: true)
    |> Enum.any?(&encoded_separator_segment?/1)
  end

  defp encoded_separator_glob?(_glob), do: false

  defp encoded_separator_segment?(segment) when is_binary(segment) do
    segment
    |> String.trim()
    |> String.downcase()
    |> encoded_separator_segment?(0)
  end

  defp encoded_separator_segment?(_segment), do: false

  defp encoded_separator_segment?(segment, depth) do
    cond do
      String.contains?(segment, ["/", "\\"]) ->
        true

      depth >= 3 ->
        false

      true ->
        decoded_segment = URI.decode(segment)

        decoded_segment != segment and encoded_separator_segment?(decoded_segment, depth + 1)
    end
  rescue
    ArgumentError -> false
  end

  defp traversal_segment?(segment) when is_binary(segment) do
    segment
    |> String.trim()
    |> String.downcase()
    |> traversal_segment?(0)
  end

  defp traversal_segment?(_segment), do: false

  defp traversal_segment?(segment, depth) do
    cond do
      segment in [".", ".."] ->
        true

      segment |> path_separator_segments() |> Enum.any?(&(&1 in [".", ".."])) ->
        true

      depth >= 3 ->
        false

      true ->
        decoded_segment = segment |> URI.decode() |> String.replace("\\", "/")

        decoded_segment != segment and traversal_segment?(decoded_segment, depth + 1)
    end
  rescue
    ArgumentError -> false
  end

  defp path_separator_segments(segment) do
    segment
    |> String.replace("\\", "/")
    |> String.split("/", trim: true)
  end

  defp blank_default(value, default) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp put_optional_child_value(attrs, _key, nil), do: attrs
  defp put_optional_child_value(attrs, key, value), do: Map.put(attrs, key, value)

  defp child_worker_grant_opts(template, %AccessGrant{} = architect_grant) do
    with :ok <- validate_child_worker_template_keys(template),
         {:ok, capabilities} <- child_worker_capabilities(template),
         {:ok, expires_at} <- child_worker_expires_at(template, architect_grant) do
      {:ok, [capabilities: capabilities, expires_at: expires_at, provenance: @child_worker_grant_provenance]}
    end
  end

  defp validate_child_worker_template_keys(template) do
    unexpected = template |> Map.keys() |> Enum.reject(&(&1 in @child_worker_template_keys))
    if unexpected == [], do: :ok, else: {:tool_error, "unexpected_template_field"}
  end

  defp child_worker_claimed_by(work_package_id, template) do
    with :ok <- validate_child_worker_template_keys(template) do
      case Map.fetch(template, "claimed_by") do
        :error -> {:ok, default_child_worker_claimed_by(work_package_id)}
        {:ok, nil} -> {:ok, default_child_worker_claimed_by(work_package_id)}
        {:ok, claimed_by} when is_binary(claimed_by) -> normalize_child_worker_claimed_by(claimed_by)
        {:ok, _claimed_by} -> {:tool_error, "invalid_claimed_by"}
      end
    end
  end

  defp normalize_child_worker_claimed_by(claimed_by) do
    case String.trim(claimed_by) do
      "" -> {:tool_error, "invalid_claimed_by"}
      claimed_by -> {:ok, claimed_by}
    end
  end

  defp default_child_worker_claimed_by(work_package_id), do: "sympp-child-worker:#{work_package_id}"

  defp put_optional_handoff_opt(opts, _key, nil), do: opts
  defp put_optional_handoff_opt(opts, _key, value) when is_binary(value) and value == "", do: opts
  defp put_optional_handoff_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp child_worker_capabilities(template) do
    case Map.fetch(template, "capabilities") do
      :error -> {:ok, @child_worker_capabilities}
      {:ok, nil} -> {:ok, @child_worker_capabilities}
      {:ok, capabilities} when is_list(capabilities) -> normalize_child_worker_capabilities(capabilities)
      {:ok, _capabilities} -> {:tool_error, "invalid_capabilities"}
    end
  end

  defp normalize_child_worker_capabilities([_head | _tail] = capabilities) do
    if Enum.all?(capabilities, &(is_binary(&1) and String.trim(&1) != "")) do
      capabilities = capabilities |> Enum.map(&String.trim/1) |> Enum.uniq()

      if Enum.all?(capabilities, &(&1 in @child_worker_capabilities)) do
        {:ok, capabilities}
      else
        {:tool_error, "broader_child_grant"}
      end
    else
      {:tool_error, "invalid_capabilities"}
    end
  end

  defp normalize_child_worker_capabilities(_capabilities), do: {:tool_error, "invalid_capabilities"}

  defp child_worker_expires_at(template, %{expires_at: %DateTime{} = architect_expires_at}) do
    with {:ok, expires_at} <- optional_child_worker_expires_at(template, architect_expires_at),
         :ok <- require_child_expires_before_architect(expires_at, architect_expires_at) do
      {:ok, expires_at}
    end
  end

  defp child_worker_expires_at(template, %{expires_at: nil}) do
    with {:ok, expires_at} <- optional_child_worker_expires_at(template, nil),
         :ok <- require_child_expiry_live(expires_at) do
      {:ok, expires_at}
    end
  end

  defp optional_child_worker_expires_at(template, default) do
    case Map.fetch(template, "expires_at") do
      :error -> {:ok, default}
      {:ok, nil} -> {:ok, default}
      {:ok, value} when is_binary(value) -> parse_child_worker_expires_at(value)
      {:ok, _value} -> {:tool_error, "invalid_expires_at"}
    end
  end

  defp parse_child_worker_expires_at(value) do
    case String.trim(value) do
      "" ->
        {:tool_error, "invalid_expires_at"}

      trimmed ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
          {:error, _reason} -> {:tool_error, "invalid_expires_at"}
        end
    end
  end

  defp require_child_expires_before_architect(expires_at, architect_expires_at) do
    cond do
      is_nil(expires_at) -> {:tool_error, "broader_child_grant"}
      DateTime.compare(expires_at, architect_expires_at) == :gt -> {:tool_error, "broader_child_grant"}
      DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) != :gt -> {:tool_error, "invalid_expires_at"}
      true -> :ok
    end
  end

  defp require_child_expiry_live(nil), do: :ok

  defp require_child_expiry_live(%DateTime{} = expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) == :gt,
      do: :ok,
      else: {:tool_error, "invalid_expires_at"}
  end

  defp release_current_assignment(arguments, %__MODULE__{session: nil} = server) do
    with {:ok, reason} <- optional_string_argument(arguments, "reason", @assignment_release_tool) do
      reason = Redactor.redact_text(reason)

      result = %{
        "action" => @assignment_release_tool,
        "status" => "ok",
        "binding_cleared" => true,
        "solo_tools_available" => true,
        "fresh_mcp_session_required" => false,
        "released_assignment" => nil,
        "claim_lease_release" => %{"status" => "skipped", "reason" => "not_bound"},
        "recovery" => %{
          "next_action" => "retry_solo_tool",
          "fresh_mcp_session_required" => false,
          "release_reason" => reason
        }
      }

      {:ok, result, %{server | session_refresh_required: false}}
    end
  end

  defp release_current_assignment(arguments, %__MODULE__{config: config, session: %Session{} = session} = server) do
    with {:ok, reason} <- optional_string_argument(arguments, "reason", @assignment_release_tool) do
      reason = Redactor.redact_text(reason)
      context = current_assignment_context(config.repo, session)
      {lease_release, released_context, binding_cleared?} = release_current_assignment_lease(config.repo, session, reason, context)
      fresh_mcp_session_required? = release_requires_fresh_session?(lease_release, binding_cleared?)

      result = %{
        "action" => @assignment_release_tool,
        "status" => if(binding_cleared?, do: "ok", else: "blocked"),
        "binding_cleared" => binding_cleared?,
        "solo_tools_available" => binding_cleared?,
        "fresh_mcp_session_required" => fresh_mcp_session_required?,
        "released_assignment" => released_context,
        "claim_lease_release" => lease_release,
        "recovery" => %{
          "next_action" => release_recovery_next_action(binding_cleared?, fresh_mcp_session_required?),
          "fresh_mcp_session_required" => fresh_mcp_session_required?
        }
      }

      updated_server =
        if binding_cleared?,
          do: %{server | session: nil, session_refresh_required: false},
          else: %{server | session_refresh_required: server.session_refresh_required or fresh_mcp_session_required?}

      {:ok, result, updated_server}
    end
  end

  defp release_current_assignment_lease(repo, %Session{} = session, reason, context) do
    case current_matching_claim_lease(repo, session) do
      {:ok, %ClaimLease{} = lease} ->
        release_matching_claim_lease(repo, lease, reason, context)

      {:error, reason} ->
        binding_cleared? = claim_lease_error_allows_binding_clear?(reason)
        status = if binding_cleared?, do: "skipped", else: "not_released"
        {%{"status" => status, "reason" => reason_text(reason)}, context, binding_cleared?}
    end
  rescue
    _error -> {%{"status" => "not_released", "reason" => "ledger_unavailable"}, context, false}
  end

  defp release_matching_claim_lease(repo, %ClaimLease{} = lease, reason, context) do
    case ClaimLeaseService.release(repo, lease.id, reason: reason) do
      {:ok, %ClaimLease{} = released} ->
        release = %{
          "status" => "released",
          "claim_lease_id" => released.id,
          "claim_lease_status" => released.status
        }

        {release, context_with_claim_lease(context, released), true}

      {:error, :not_found} ->
        release = %{
          "status" => "skipped",
          "reason" => "not_found",
          "claim_lease_id" => lease.id
        }

        {release, context_with_claim_lease_status(context, lease.id, "not_found"), true}

      {:error, reason} ->
        binding_cleared? = claim_lease_error_allows_binding_clear?(reason)
        status = if binding_cleared?, do: "skipped", else: "not_released"

        {%{"status" => status, "reason" => reason_text(reason)}, context, binding_cleared?}
    end
  end

  defp release_requires_fresh_session?(%{"reason" => reason}, false)
       when reason in ["claim_lease_identity_unavailable", "claim_stale", "claim_lease_mismatch"],
       do: true

  defp release_requires_fresh_session?(_lease_release, _binding_cleared?), do: false

  defp release_recovery_next_action(true, _fresh_mcp_session_required?), do: "retry_solo_tool"
  defp release_recovery_next_action(false, true), do: "start_fresh_mcp_session"
  defp release_recovery_next_action(false, false), do: "retry_release_current_assignment"

  defp claim_lease_error_allows_binding_clear?(reason) do
    reason in [:not_applicable, :not_found, :claim_stale, :claim_lease_mismatch, :claim_lease_identity_unavailable]
  end

  defp current_assignment_context(%__MODULE__{config: %Config{repo: repo}, session: %Session{} = session}) do
    current_assignment_context(repo, session)
  end

  defp current_assignment_summary(%__MODULE__{config: %Config{repo: repo}, session: %Session{} = session}) do
    current_assignment_summary(repo, session)
  end

  defp current_assignment_context(repo, %Session{assignment: assignment} = session) do
    package_context = assignment_work_package_context(repo, assignment.work_package_id)
    repo_scope = assignment_repo_scope(assignment)

    %{
      "role" => assignment.grant_role,
      "work_package_id" => assignment.work_package_id,
      "phase_id" => assignment.phase_id,
      "claimed_by" => assignment.claimed_by
    }
    |> optional_put("repo", package_context["repo"] || repo_scope["repo"])
    |> optional_put("base_branch", package_context["base_branch"] || repo_scope["base_branch"])
    |> optional_put("work_request_id", assignment_work_request_id(repo, assignment))
    |> put_safe_claim_lease(repo, session)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp current_assignment_summary(repo, %Session{assignment: assignment}) do
    package_context = assignment_work_package_context(repo, assignment.work_package_id)
    repo_scope = assignment_repo_scope(assignment)

    %{
      "grant_role" => assignment.grant_role,
      "work_package_id" => assignment.work_package_id,
      "claimed_by" => assignment.claimed_by,
      "phase_id" => assignment.phase_id
    }
    |> optional_put("repo", package_context["repo"] || repo_scope["repo"])
    |> optional_put("base_branch", package_context["base_branch"] || repo_scope["base_branch"])
    |> optional_put("work_request_id", assignment_work_request_id(repo, assignment))
    |> drop_nil_values()
  end

  defp assignment_work_package_context(repo, work_package_id) when is_binary(work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %WorkPackage{} = work_package} ->
        %{"repo" => work_package.repo, "base_branch" => work_package.base_branch}

      _result ->
        %{}
    end
  rescue
    _error -> %{}
  end

  defp assignment_work_package_context(_repo, _work_package_id), do: %{}

  defp assignment_repo_scope(%{scopes: scopes}) when is_list(scopes) do
    case Enum.find(scopes, &match?(%Scope{type: :repo}, &1)) do
      %Scope{} = scope -> %{"repo" => scope.repo, "base_branch" => scope.base_branch}
      nil -> %{}
    end
  end

  defp assignment_repo_scope(_assignment), do: %{}

  defp assignment_work_request_id(repo, %{scopes: scopes, work_package_id: work_package_id}) do
    work_request_scope_id(scopes) || work_request_id_for_work_package(repo, work_package_id)
  end

  defp work_request_scope_id(scopes) when is_list(scopes) do
    case Enum.find(scopes, &match?(%Scope{type: :work_request, id: id} when is_binary(id), &1)) do
      %Scope{id: id} -> id
      nil -> nil
    end
  end

  defp work_request_scope_id(_scopes), do: nil

  defp work_request_id_for_work_package(repo, work_package_id) when is_binary(work_package_id) do
    query =
      from(planned_slice in PlannedSlice,
        where: planned_slice.work_package_id == ^work_package_id,
        order_by: [asc: planned_slice.inserted_at, asc: planned_slice.id],
        select: planned_slice.work_request_id,
        limit: 1
      )

    case repo.one(query) do
      work_request_id when is_binary(work_request_id) -> work_request_id
      _value -> nil
    end
  rescue
    _error -> nil
  end

  defp work_request_id_for_work_package(_repo, _work_package_id), do: nil

  defp put_safe_claim_lease(context, repo, %Session{} = session) do
    case current_matching_claim_lease(repo, session) do
      {:ok, %ClaimLease{} = lease} -> context_with_claim_lease(context, lease)
      {:error, _reason} -> context
    end
  rescue
    _error -> context
  end

  defp context_with_claim_lease(context, %ClaimLease{} = lease) do
    context
    |> Map.put("claim_lease_id", lease.id)
    |> Map.put("claim_lease_status", lease.status)
  end

  defp context_with_claim_lease_status(context, claim_lease_id, status) do
    context
    |> Map.put("claim_lease_id", claim_lease_id)
    |> Map.put("claim_lease_status", status)
  end

  defp current_matching_claim_lease(_repo, %Session{assignment: %{work_package_id: work_package_id}}) when not is_binary(work_package_id),
    do: {:error, :not_applicable}

  defp current_matching_claim_lease(
         repo,
         %Session{
           assignment: assignment,
           claim_lease_id: claim_lease_id,
           claim_actor_kind: actor_kind,
           claim_actor_id: actor_id,
           claim_actor_display_name: actor_display_name
         }
       )
       when is_binary(claim_lease_id) and is_binary(actor_kind) and is_binary(actor_id) do
    work_package_id = assignment.work_package_id

    case ClaimLeaseService.current_for_work_package(repo, work_package_id) do
      {:ok, %ClaimLease{} = lease} ->
        require_current_session_claim_lease(lease, assignment, claim_lease_id, actor_kind, actor_id, actor_display_name)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_matching_claim_lease(repo, %Session{assignment: %{work_package_id: work_package_id}}) when is_binary(work_package_id) do
    case ClaimLeaseService.current_for_work_package(repo, work_package_id) do
      {:error, :not_found} -> {:error, :not_found}
      {:ok, %ClaimLease{}} -> {:error, :claim_lease_identity_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_matching_claim_lease(_repo, %Session{}), do: {:error, :claim_lease_identity_unavailable}

  defp require_current_session_claim_lease(
         %ClaimLease{} = lease,
         assignment,
         claim_lease_id,
         actor_kind,
         actor_id,
         actor_display_name
       ) do
    cond do
      lease.id != claim_lease_id ->
        {:error, :claim_lease_mismatch}

      lease.work_package_id != assignment.work_package_id ->
        {:error, :claim_lease_mismatch}

      claim_lease_assignment_mismatch?(lease, assignment) ->
        {:error, :claim_lease_mismatch}

      lease.actor_kind != actor_kind ->
        {:error, :claim_lease_mismatch}

      lease.actor_id != actor_id ->
        {:error, :claim_lease_mismatch}

      lease.actor_display_name != actor_display_name ->
        {:error, :claim_lease_mismatch}

      true ->
        {:ok, lease}
    end
  end

  defp claim_lease_assignment_mismatch?(%ClaimLease{} = lease, assignment) do
    is_binary(lease.access_grant_id) and
      is_binary(assignment.grant_id) and
      lease.access_grant_id != assignment.grant_id
  end

  defp solo_tool(name, arguments, %__MODULE__{config: config}) do
    SoloTools.call(name, arguments, config, &worker_error/2)
  end

  defp worker_tool("get_current_assignment", _arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         :ok <- require_assignment_introspection(session.assignment) do
      {:ok, agent_tool_result(%{"assignment" => Session.public_assignment(session)})}
    else
      {:error, reason} -> worker_error(reason, "get_current_assignment")
    end
  end

  defp worker_tool("read_context", _arguments, %__MODULE__{config: config, session: session}) do
    read_current_virtual_file(config.repo, session, "context.md")
  end

  defp worker_tool("read_task_plan", _arguments, %__MODULE__{config: config, session: session}) do
    read_task_plan_file(config.repo, session)
  end

  defp worker_tool("update_task_plan", arguments, %__MODULE__{config: config, session: session}) do
    case scoped_session(config.repo, session, arguments) do
      {:ok, session} ->
        case authorize_current_package_policy(config.repo, session, :task_plan_update, :task_plan, "update_task_plan") do
          :ok ->
            normalize_update_task_plan_result(update_task_plan(config.repo, session, arguments))

          {:error, reason} ->
            worker_error(reason, "update_task_plan")
        end

      {:error, reason} ->
        worker_error(reason, "update_task_plan")
    end
  end

  defp worker_tool("append_finding", arguments, %__MODULE__{config: config, session: session}), do: append_finding_tool(config.repo, session, arguments)

  defp worker_tool("append_progress", arguments, %__MODULE__{config: config, session: session}) do
    append_scoped_progress(config.repo, session, arguments, "append_progress", %{})
  end

  defp worker_tool("set_status", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         {:ok, status} <- required_argument(arguments, "status"),
         {:ok, expected_status} <- required_argument(arguments, "expected_status"),
         {:ok, reason} <- optional_reason(arguments),
         :ok <- reject_ready_status(status),
         {:ok, blocker_closeout_plan} <- maybe_prepare_work_package_status_blocker_closeout(config.repo, session, status, arguments),
         {:ok, {work_package, blocker_closeout}} <- set_status_transaction(config.repo, session, expected_status, status, reason, blocker_closeout_plan) do
      {:ok, tool_result(%{"work_package" => work_package_payload(work_package), "blocker_closeout" => blocker_closeout})}
    else
      {:tool_error, reason} -> invalid_params_error("set_status", reason)
      {:error, _code, _message, _data} = error -> error
      {:error, reason} -> worker_error(reason, "set_status")
    end
  end

  defp worker_tool("report_blocker", arguments, %__MODULE__{config: config, session: session}) do
    case optional_blocker_id(arguments) do
      {:ok, blocker_id} ->
        append_scoped_progress(config.repo, session, arguments, "report_blocker", %{
          "type" => "blocker",
          "source_tool" => "report_blocker",
          "blocker_id" => blocker_id,
          "active" => true
        })

      {:error, reason} ->
        worker_error(reason, "report_blocker")
    end
  end

  defp worker_tool("resolve_blocker", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, blocker_id} <- required_argument(arguments, "blocker_id"),
         {:ok, resolution} <- required_argument(arguments, "resolution") do
      append_scoped_progress(config.repo, session, arguments, "resolve_blocker", %{
        "type" => "blocker",
        "source_tool" => "resolve_blocker",
        "blocker_id" => blocker_id,
        "resolution" => resolution,
        "active" => false
      })
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "resolve_blocker", "reason" => reason}}
    end
  end

  defp worker_tool(name, arguments, %__MODULE__{config: config, session: session})
       when name in ["add_comment", "list_comments", "resolve_comment"] do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         {:ok, result} <- comment_tool_result(name, config.repo, session, arguments, :worker, worker_comment_actor(session)) do
      {:ok, result}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => reason}}
      {:error, :not_found} -> not_found_error(name)
      {:error, reason} -> worker_error(reason, name)
    end
  end

  defp worker_tool("create_guidance_request", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, question} <- required_argument(arguments, "question"),
         {:ok, context} <- required_argument(arguments, "context"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, guidance_request} <-
           GuidanceRequestService.create_for_assignment(config.repo, session.assignment, %{
             "summary" => summary,
             "question" => question,
             "context" => context,
             "idempotency_key" => idempotency_key
           }) do
      {:ok, tool_result(%{"guidance_request" => guidance_request_payload(guidance_request)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "create_guidance_request", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "create_guidance_request")
    end
  end

  defp worker_tool("request_scope_expansion", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         :ok <- require_worker_assignment(session.assignment),
         {:ok, payload} <- request_scope_expansion_payload(config.repo, session) do
      append_scoped_progress(config.repo, session, arguments, "request_scope_expansion", payload)
    else
      {:error, reason} -> worker_error(reason, "request_scope_expansion")
    end
  end

  defp worker_tool("attach_branch", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         :ok <- authorize_current_package_policy(config.repo, session, :work_package_update, :work_package, "attach_branch"),
         {:ok, branch} <- attach_branch_argument(config.repo, session, arguments),
         {:ok, head_sha} <- required_argument(arguments, "head_sha") do
      append_metadata_event(config.repo, session, arguments, "attach_branch", "branch_attached", %{"type" => "branch", "branch" => branch, "head_sha" => head_sha})
    else
      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => "attach_branch", "reason" => reason}}

      {:error, reason} ->
        worker_error(reason, "attach_branch")
    end
  end

  defp worker_tool("attach_pr", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         :ok <- authorize_current_package_policy(config.repo, session, :review_evidence_append, :review_evidence, "attach_pr"),
         {:ok, payload} <- pr_metadata_payload(config.repo, session, arguments, "attach_pr") do
      append_pr_metadata(config.repo, session, arguments, "attach_pr", "pr_attached", payload)
      |> metadata_tool_response("attach_pr")
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "attach_pr", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "attach_pr")
    end
  end

  defp worker_tool("sync_pr", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         :ok <- authorize_current_package_policy(config.repo, session, :review_evidence_append, :review_evidence, "sync_pr"),
         {:ok, payload} <- pr_metadata_payload(config.repo, session, arguments, "sync_pr") do
      append_pr_metadata(config.repo, session, arguments, "sync_pr", "pr_synced", payload)
      |> metadata_tool_response("sync_pr")
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "sync_pr", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "sync_pr")
    end
  end

  defp worker_tool("submit_review_package", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         :ok <- authorize_current_package_policy(config.repo, session, :review_evidence_append, :review_evidence, "submit_review_package"),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, tests} <- required_string_list(arguments, "tests"),
         {:ok, artifacts} <- required_string_list(arguments, "artifacts"),
         artifacts = Enum.uniq(artifacts),
         {:ok, reviews} <- optional_review_list(arguments, "reviews"),
         {:ok, acceptance_criteria_met} <- optional_boolean(arguments, "acceptance_criteria_met", nil),
         {:ok, result} <-
           submit_review_package_transaction(config.repo, session, arguments, artifacts, %{
             "type" => "review_package",
             "summary" => summary,
             "tests" => tests,
             "artifacts" => artifacts,
             "reviews" => reviews,
             "acceptance_criteria_met" => acceptance_criteria_met
           }) do
      {:ok, result}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "submit_review_package", "reason" => reason}}
      {:error, _code, _message, _data} = error -> error
      {:error, reason} -> worker_error(reason, "submit_review_package")
    end
  end

  defp worker_tool("attach_review_suite_result", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         :ok <- authorize_current_package_policy(config.repo, session, :review_evidence_append, :review_evidence, "attach_review_suite_result"),
         {:ok, arguments, payload} <- review_suite_result_arguments(arguments, session),
         status = Map.get(payload, "status"),
         verdict = Map.get(payload, "verdict"),
         :ok <- require_passing_review_suite_result(status, verdict),
         {:ok, result} <-
           attach_review_suite_result_transaction(config.repo, session, arguments, payload) do
      {:ok, result}
    else
      {:tool_error, reason} -> invalid_params_error("attach_review_suite_result", reason)
      {:error, _code, _message, _data} = error -> error
      {:error, reason} -> worker_error(reason, "attach_review_suite_result")
    end
  end

  defp worker_tool("mark_ready", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         :ok <- require_worker_assignment(session.assignment),
         {:ok, blocker_closeout_plan} <- prepare_scoped_blocker_closeout(config.repo, session, [Session.work_package_id(session)], arguments, "mark_ready"),
         {:ok, {work_package, blocker_closeout, warnings}} <- mark_ready_transaction(config.repo, session, blocker_closeout_plan) do
      {:ok,
       tool_result(
         %{"work_package" => work_package_payload(work_package), "ready" => true, "blocker_closeout" => blocker_closeout}
         |> maybe_put_readiness_warnings(warnings)
       )}
    else
      {:tool_error, reason} ->
        invalid_params_error("mark_ready", reason)

      {:error, {:readiness_failed, missing, reasons, warnings}} ->
        {:error, -32_602, "Invalid params",
         %{"tool" => "mark_ready", "reason" => "readiness_failed", "missing" => missing, "reasons" => reasons}
         |> maybe_put_readiness_warnings(warnings)}

      {:error, {:readiness_failed, missing, reasons}} ->
        {:error, -32_602, "Invalid params", %{"tool" => "mark_ready", "reason" => "readiness_failed", "missing" => missing, "reasons" => reasons}}

      {:error, {:readiness_failed, missing}} ->
        {:error, -32_602, "Invalid params", %{"tool" => "mark_ready", "reason" => "readiness_failed", "missing" => missing}}

      {:error, reason} ->
        worker_error(reason, "mark_ready")
    end
  end

  defp append_finding_tool(repo, %Session{} = session, arguments) do
    with {:ok, session} <- scoped_session(repo, session, arguments),
         :ok <- authorize_current_package_policy(repo, session, :finding_append, :finding, "append_finding"),
         {:ok, title} <- required_argument(arguments, "title"),
         {:ok, body} <- required_argument(arguments, "body"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         idempotency_key = String.trim(idempotency_key),
         {:ok, finding_id} <- optional_finding_id(arguments, session, idempotency_key),
         attrs = %{
           "id" => finding_id,
           "work_package_id" => Session.work_package_id(session),
           "title" => title,
           "body" => body,
           "severity" => optional_argument(arguments, "severity", "info"),
           "idempotency_key" => idempotency_key,
           "access_grant_id" => session.assignment.grant_id,
           "caller_supplied_id" => Map.has_key?(arguments, "id")
         },
         {:ok, finding} <- append_authenticated_idempotent_finding(repo, session, finding_id, attrs) do
      {:ok, agent_tool_result(%{"finding" => %{"id" => finding.id, "title" => finding.title, "severity" => finding.severity}})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "append_finding", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "append_finding")
    end
  end

  defp attach_branch_argument(repo, %Session{} = session, arguments) do
    case optional_string_argument(arguments, "branch") do
      {:ok, nil} -> inferred_attach_branch(repo, session)
      result -> result
    end
  end

  defp inferred_attach_branch(repo, %Session{} = session) do
    with {:ok, %WorkPackage{} = work_package} <- WorkPackageRepository.get(repo, Session.work_package_id(session)) do
      case normalize_optional_value(work_package.branch_pattern) do
        nil -> {:tool_error, "missing_branch"}
        branch when is_binary(branch) -> inferred_literal_branch(branch)
      end
    end
  end

  defp inferred_literal_branch(branch), do: if(local_branch_template_pattern?(branch), do: {:tool_error, "missing_branch"}, else: {:ok, branch})

  defp read_guidance_request_tool(arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, guidance_request_id} <- required_argument(arguments, "guidance_request_id") do
      read_guidance_request_for_session(config.repo, session, guidance_request_id, arguments)
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_guidance_request", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "read_guidance_request")
    end
  end

  defp read_guidance_request_for_session(
         repo,
         %Session{assignment: %{grant_role: "worker"}} = session,
         guidance_request_id,
         arguments
       ) do
    with {:ok, session} <- scoped_session(repo, session, arguments),
         {:ok, guidance_request} <-
           GuidanceRequestService.get_for_assignment(repo, session.assignment, guidance_request_id) do
      {:ok, tool_result(%{"guidance_request" => guidance_request_payload(guidance_request)})}
    else
      {:error, :not_found} -> not_found_error("read_guidance_request")
      {:error, {:authorization_policy_denied, %Decision{reason_code: "scope_mismatch"}}} -> not_found_error("read_guidance_request")
      {:error, reason} -> worker_error(reason, "read_guidance_request")
    end
  end

  defp read_guidance_request_for_session(
         repo,
         %Session{assignment: %{grant_role: "architect"}} = session,
         guidance_request_id,
         arguments
       ) do
    with {:ok, session} <- architect_session(repo, session, "read:guidance_request"),
         {:ok, work_package_id} <- optional_string_argument(arguments, "work_package_id"),
         {:ok, filters, scope} <- scoped_guidance_request_filters(repo, session),
         {:ok, guidance_request} <-
           GuidanceRequestService.get_visible_to_architect(repo, guidance_request_id, filters),
         :ok <- authorize_guidance_request_for_session(repo, session, :guidance_request_read, guidance_request),
         :ok <- require_guidance_request_work_package(guidance_request, work_package_id) do
      {:ok, tool_result(%{"guidance_request" => guidance_request_payload(guidance_request), "scope" => scope})}
    else
      {:error, :not_found} -> not_found_error("read_guidance_request")
      {:error, reason} -> architect_error(reason, "read_guidance_request")
    end
  end

  defp read_guidance_request_for_session(_repo, %Session{}, _guidance_request_id, _arguments) do
    auth_error({:unauthorized, :unsupported_grant_role}, "read_guidance_request")
  end

  defp require_guidance_request_work_package(%GuidanceRequest{}, nil), do: :ok

  defp require_guidance_request_work_package(%GuidanceRequest{work_package_id: work_package_id}, work_package_id), do: :ok

  defp require_guidance_request_work_package(%GuidanceRequest{}, _work_package_id), do: {:error, :not_found}

  defp pr_metadata_payload(repo, %Session{} = session, arguments, source_tool) do
    case legacy_attach_pr_payload(arguments, source_tool) do
      {:ok, payload} -> {:ok, payload}
      {:tool_error, reason} -> {:tool_error, reason}
      :error -> github_pr_metadata_payload(repo, session, arguments, source_tool)
    end
  end

  defp github_pr_metadata_payload(repo, %Session{} = session, arguments, source_tool) do
    with {:ok, %WorkPackage{} = work_package} <- WorkPackageRepository.get(repo, Session.work_package_id(session)),
         {:ok, metadata_input} <- pr_metadata_input(repo, session, arguments, source_tool),
         {:ok, arguments} <- pr_reference_arguments(repo, session, arguments, source_tool),
         {:ok, ref} <- PullRequest.parse(arguments, work_package.repo),
         {:ok, metadata} <- Client.fetch_pull_request(DryClient, ref, metadata: metadata_input),
         {:ok, payload} <- PullRequest.metadata(metadata, ref, pr_fallback_head_sha(arguments, source_tool)),
         {:ok, attachment_repair?} <- pr_attachment_repair?(repo, session, arguments, source_tool) do
      {:ok,
       payload
       |> Map.put("source_tool", source_tool)
       |> maybe_mark_pr_attachment_repair(attachment_repair?)}
    else
      {:tool_error, reason} ->
        {:tool_error, reason}

      {:error, reason} when reason in [:database_busy] ->
        {:error, reason}

      {:error, {reason, _detail} = error} when reason in [:storage_failed, :migration_failed, :service_unavailable] ->
        {:error, error}

      {:error, :missing_repository} ->
        {:tool_error, pr_missing_repository_reason(arguments, source_tool)}

      {:error, reason} ->
        {:tool_error, reason_text(reason)}
    end
  end

  defp legacy_attach_pr_payload(arguments, "attach_pr") do
    with url when is_binary(url) <- Map.get(arguments, "url"),
         trimmed_url = String.trim(url),
         true <- trimmed_url != "",
         true <- non_github_url?(trimmed_url),
         {:ok, metadata} <- legacy_pr_metadata(arguments) do
      payload =
        metadata
        |> Map.merge(%{"type" => "pr", "source_tool" => "attach_pr", "url" => trimmed_url})
        |> maybe_put_filled_string("head_sha", Map.get(arguments, "head_sha"))

      {:ok, payload}
    else
      {:tool_error, _reason} = error -> error
      _value -> :error
    end
  end

  defp legacy_attach_pr_payload(_arguments, _source_tool), do: :error

  defp legacy_pr_metadata(%{"metadata" => metadata}) when is_map(metadata), do: {:ok, metadata}
  defp legacy_pr_metadata(%{"metadata" => nil}), do: {:ok, %{}}
  defp legacy_pr_metadata(%{"metadata" => _metadata}), do: {:tool_error, "invalid_metadata"}
  defp legacy_pr_metadata(_arguments), do: {:ok, %{}}

  defp non_github_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        String.downcase(host) != "github.com"

      _uri ->
        false
    end
  rescue
    _error in URI.Error -> false
  end

  defp maybe_put_filled_string(payload, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> payload
      trimmed -> Map.put(payload, key, trimmed)
    end
  end

  defp maybe_put_filled_string(payload, _key, _value), do: payload

  defp metadata_tool_response({:ok, _result} = result, _tool), do: result
  defp metadata_tool_response({:error, _code, _message, _data} = error, _tool), do: error
  defp metadata_tool_response({:tool_error, reason}, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
  defp metadata_tool_response({:error, reason}, tool), do: worker_error(reason, tool)

  defp pr_fallback_head_sha(arguments, tool) when tool in ["attach_pr", "sync_pr"], do: Map.get(arguments, "head_sha")

  defp pr_reference_arguments(repo, %Session{} = session, arguments, "sync_pr") do
    arguments = drop_blank_pr_identity_arguments(arguments)

    cond do
      sync_pr_recovery_arguments?(arguments) -> recovery_pr_reference_arguments(arguments)
      complete_pr_identity_argument?(arguments) -> {:ok, arguments}
      true -> infer_sync_pr_reference_arguments(repo, session, arguments)
    end
  end

  defp pr_reference_arguments(_repo, %Session{}, arguments, _source_tool), do: {:ok, arguments}

  defp infer_sync_pr_reference_arguments(repo, %Session{} = session, arguments) do
    with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, Session.work_package_id(session)) do
      sync_pr_reference_arguments_from_events(arguments, progress_events)
    end
  end

  defp sync_pr_reference_arguments_from_events(arguments, progress_events) do
    case latest_attached_pr_ref(progress_events) do
      {:ok, attached_ref} -> sync_pr_reference_arguments(arguments, attached_ref)
      {:tool_error, "missing_attached_pr"} -> fallback_pr_reference_arguments(arguments)
      {:tool_error, reason} -> {:tool_error, reason}
    end
  end

  defp sync_pr_reference_arguments(arguments, {:url, url}), do: {:ok, put_inferred_pr_argument(arguments, "url", url)}

  defp sync_pr_reference_arguments(arguments, {repository, number}) do
    {:ok,
     arguments
     |> put_inferred_pr_argument("repository", repository)
     |> put_inferred_pr_argument("number", number)}
  end

  defp explicit_pr_identity?(arguments) do
    filled_string?(Map.get(arguments, "url")) or not blank_pr_number_argument?(Map.get(arguments, "number"))
  end

  defp complete_pr_identity_argument?(arguments) do
    filled_string?(Map.get(arguments, "url")) or
      (not blank_pr_number_argument?(Map.get(arguments, "number")) and filled_string?(Map.get(arguments, "repository")))
  end

  defp fallback_pr_reference_arguments(arguments) do
    cond do
      sync_pr_recovery_arguments?(arguments) -> recovery_pr_reference_arguments(arguments)
      explicit_pr_identity?(arguments) -> {:ok, arguments}
      true -> {:tool_error, "missing_attached_pr"}
    end
  end

  defp sync_pr_recovery_arguments?(%{"recovery" => recovery}) when is_map(recovery), do: recovery_pr_identity?(recovery)
  defp sync_pr_recovery_arguments?(_arguments), do: false

  defp sync_pr_attachment_repair_arguments?(arguments) do
    sync_pr_recovery_arguments?(arguments) or explicit_pr_identity?(drop_blank_pr_identity_arguments(arguments))
  end

  defp pr_attachment_repair?(repo, %Session{} = session, arguments, "sync_pr") when is_map(arguments) do
    if sync_pr_attachment_repair_arguments?(arguments) do
      explicit_sync_pr_missing_attached_pr?(repo, session)
    else
      {:ok, false}
    end
  end

  defp pr_attachment_repair?(_repo, %Session{}, _arguments, _source_tool), do: {:ok, false}

  defp explicit_sync_pr_missing_attached_pr?(repo, %Session{} = session) do
    with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, Session.work_package_id(session)) do
      case latest_real_attached_pr_ref(progress_events) do
        {:ok, _attached_ref} -> {:ok, false}
        {:tool_error, "missing_attached_pr"} -> {:ok, true}
        {:tool_error, reason} -> {:tool_error, reason}
      end
    end
  end

  defp maybe_mark_pr_attachment_repair(payload, true), do: Map.put(payload, "attachment_repair", true)
  defp maybe_mark_pr_attachment_repair(payload, false), do: payload

  defp recovery_pr_reference_arguments(%{"recovery" => recovery} = arguments) when is_map(recovery) do
    recovery_arguments =
      %{}
      |> put_inferred_pr_argument("url", Map.get(recovery, "html_url") || Map.get(recovery, "url"))
      |> put_inferred_pr_argument("repository", recovery_repository(recovery))
      |> put_inferred_pr_argument("number", Map.get(recovery, "number"))

    if explicit_pr_identity?(recovery_arguments) do
      merge_recovery_pr_reference_arguments(arguments, recovery_arguments)
    else
      {:tool_error, "missing_attached_pr"}
    end
  end

  defp merge_recovery_pr_reference_arguments(arguments, recovery_arguments) do
    with :ok <- validate_recovery_number_argument(arguments, recovery_arguments) do
      case {pr_payload_ref(arguments), pr_payload_ref(recovery_arguments)} do
        {nil, _recovery_ref} -> {:ok, Map.merge(arguments, recovery_arguments)}
        {same_ref, same_ref} -> {:ok, Map.merge(arguments, recovery_arguments)}
        {_argument_ref, _recovery_ref} -> {:tool_error, "pr_recovery_reference_mismatch"}
      end
    end
  end

  defp validate_recovery_number_argument(arguments, recovery_arguments) do
    case {pr_number_argument(Map.get(arguments, "number")), pr_number_argument(Map.get(recovery_arguments, "number"))} do
      {nil, _recovery_number} -> :ok
      {_argument_number, nil} -> :ok
      {same_number, same_number} -> :ok
      {_argument_number, _recovery_number} -> {:tool_error, "pr_recovery_reference_mismatch"}
    end
  end

  defp recovery_pr_identity?(recovery) do
    filled_string?(Map.get(recovery, "url") || Map.get(recovery, "html_url")) or
      (not blank_pr_number_argument?(Map.get(recovery, "number")) and filled_string?(recovery_repository(recovery)))
  end

  defp pr_number_argument(value) when is_integer(value) and value > 0, do: value

  defp pr_number_argument(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number > 0 -> number
      _value -> nil
    end
  end

  defp pr_number_argument(_value), do: nil

  defp recovery_repository(recovery) do
    case Map.get(recovery, "repository") do
      repository when is_binary(repository) -> repository
      %{"full_name" => full_name} when is_binary(full_name) -> full_name
      _repository -> nested_recovery_repository(recovery, "base") || nested_recovery_repository(recovery, "head")
    end
  end

  defp nested_recovery_repository(recovery, key) do
    case Map.get(recovery, key) do
      %{"repo" => %{"full_name" => full_name}} when is_binary(full_name) -> full_name
      _value -> nil
    end
  end

  defp drop_blank_pr_identity_arguments(arguments) do
    Enum.reduce(["url", "repository", "number"], arguments, &drop_blank_pr_identity_argument/2)
  end

  defp drop_blank_pr_identity_argument(key, arguments) do
    value = Map.get(arguments, key)

    if is_binary(value) and String.trim(value) == "", do: Map.delete(arguments, key), else: arguments
  end

  defp blank_pr_number_argument?(nil), do: true

  defp blank_pr_number_argument?(value) when is_binary(value), do: String.trim(value) == ""

  defp blank_pr_number_argument?(_value), do: false

  defp put_inferred_pr_argument(arguments, _key, nil), do: arguments

  defp put_inferred_pr_argument(arguments, key, value) when is_binary(value) do
    if String.trim(value) == "" do
      arguments
    else
      put_nonblank_inferred_pr_argument(arguments, key, value)
    end
  end

  defp put_inferred_pr_argument(arguments, key, value) do
    put_nonblank_inferred_pr_argument(arguments, key, value)
  end

  defp put_nonblank_inferred_pr_argument(arguments, key, value) do
    case Map.get(arguments, key) do
      existing when is_binary(existing) ->
        if String.trim(existing) == "", do: Map.put(arguments, key, value), else: arguments

      nil ->
        Map.put(arguments, key, value)

      _existing ->
        arguments
    end
  end

  defp pr_missing_repository_reason(arguments, "attach_pr") do
    if Map.has_key?(arguments, "number") and not filled_string?(Map.get(arguments, "url")) do
      "missing_repository_use_url_or_owner_repo"
    else
      "missing_repository"
    end
  end

  defp pr_missing_repository_reason(_arguments, _source_tool), do: "missing_repository"

  defp validate_pr_sync_target(_repo, %Session{}, _ref, "attach_pr", _repair?), do: :ok

  defp validate_pr_sync_target(repo, %Session{} = session, ref, "sync_pr", repair?) do
    with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, Session.work_package_id(session)) do
      validate_pr_sync_ref_against_events(ref, progress_events, repair?)
    end
  end

  defp validate_pr_sync_ref_against_events(ref, progress_events, repair?) do
    case latest_attached_pr_ref(progress_events) do
      {:ok, attached_ref} -> validate_pr_sync_ref(ref, attached_ref, repair?)
      {:tool_error, "missing_attached_pr"} -> :ok
      {:tool_error, reason} -> {:tool_error, reason}
    end
  end

  defp validate_pr_sync_ref(ref, attached_ref, _repair?) do
    if attached_ref == normalized_pr_ref(ref.repository, ref.number), do: :ok, else: {:tool_error, "pr_mismatch"}
  end

  defp latest_attached_pr_ref(progress_events) do
    case latest_attached_pr_ref_with_ledger_boundary(progress_events) do
      {:ok, ref, _boundary} -> {:ok, ref}
      {:tool_error, reason} -> {:tool_error, reason}
    end
  end

  defp latest_real_attached_pr_ref(progress_events) do
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find_value(&attached_pr_ref_with_boundary/1)
    |> case do
      nil -> {:tool_error, "missing_attached_pr"}
      {ref, _boundary} -> {:ok, ref}
    end
  end

  defp latest_attached_pr_ref_with_ledger_boundary(progress_events) do
    # Attach selection follows event time so replay/backfill can record older PR
    # attachments later. The returned boundary preserves that selected event.
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find_value(&attached_or_repaired_pr_ref_with_boundary/1)
    |> case do
      nil -> {:tool_error, "missing_attached_pr"}
      {ref, boundary} -> {:ok, ref, boundary}
    end
  end

  defp progress_event_sequence_order(%ProgressEvent{sequence: sequence, created_at: created_at, id: id}) when is_integer(sequence) do
    {1, sequence, timestamp_sort_value(created_at), id || ""}
  end

  defp progress_event_sequence_order(%ProgressEvent{created_at: created_at, id: id}) do
    {0, timestamp_sort_value(created_at), id || ""}
  end

  defp timestamp_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp timestamp_sort_value(nil), do: -1

  defp attach_boundary(%ProgressEvent{sequence: sequence} = event) when is_integer(sequence) do
    {:sequence, progress_event_sequence_order(event)}
  end

  defp attach_boundary(%ProgressEvent{} = event) do
    {:chronological, progress_event_chronological_order(event)}
  end

  defp chronological_progress_events(progress_events) do
    Enum.sort_by(progress_events, &progress_event_chronological_order/1)
  end

  defp progress_event_chronological_order(%ProgressEvent{created_at: created_at, sequence: sequence, id: id}) do
    {timestamp_sort_value(created_at), sequence || 0, id || ""}
  end

  defp attached_or_repaired_pr_ref_with_boundary(%ProgressEvent{} = event) do
    attached_pr_ref_with_boundary(event) || repaired_pr_ref_with_boundary(event)
  end

  defp attached_pr_ref_with_boundary(%ProgressEvent{payload: payload} = event) when is_map(payload) do
    if payload_type?(event, "pr", "attach_pr"), do: pr_payload_ref_with_sequence(payload, attach_boundary(event))
  end

  defp attached_pr_ref_with_boundary(_event), do: nil

  defp repaired_pr_ref_with_boundary(%ProgressEvent{payload: payload} = event) when is_map(payload) do
    if payload_type?(event, "pr", "sync_pr") and Map.get(payload, "attachment_repair") == true do
      pr_payload_ref_with_sequence(payload, {:repair_sync, attach_boundary(event)})
    end
  end

  defp repaired_pr_ref_with_boundary(_event), do: nil

  defp pr_payload_ref_with_sequence(payload, sequence) do
    case pr_payload_ref(payload) do
      nil -> nil
      ref -> {ref, sequence}
    end
  end

  defp pr_payload_ref(%{"repository" => repository, "number" => number}) when is_binary(repository) and is_integer(number), do: normalized_pr_ref(repository, number)
  defp pr_payload_ref(%{"repository" => repository, "number" => number}) when is_binary(repository) and is_binary(number), do: normalized_pr_ref(repository, number)

  defp pr_payload_ref(%{"url" => url}) when is_binary(url) do
    case PullRequest.parse(%{"url" => url}, nil) do
      {:ok, ref} -> normalized_pr_ref(ref.repository, ref.number)
      {:error, _reason} -> legacy_url_ref(url)
    end
  end

  defp pr_payload_ref(_payload), do: nil

  defp normalized_pr_ref(repository, number) when is_binary(repository) do
    {String.downcase(repository), pr_number_argument(number) || number}
  end

  defp legacy_url_ref(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        if String.downcase(host) == "github.com", do: nil, else: {:url, url}

      _uri ->
        {:url, url}
    end
  rescue
    _error in URI.Error -> {:url, url}
  end

  defp pr_metadata_input(_repo, %Session{}, arguments, "attach_pr") do
    case Map.get(arguments, "metadata") do
      metadata when is_map(metadata) -> {:ok, metadata}
      nil -> {:ok, %{"head_sha" => Map.get(arguments, "head_sha")}}
      _metadata -> {:tool_error, "invalid_metadata"}
    end
  end

  defp pr_metadata_input(repo, %Session{} = session, arguments, "sync_pr") do
    cond do
      is_map(Map.get(arguments, "metadata")) ->
        {:ok, merge_compact_pr_metadata_fields(Map.get(arguments, "metadata"), arguments)}

      Map.has_key?(arguments, "metadata") ->
        {:tool_error, "invalid_metadata"}

      is_map(Map.get(arguments, "recovery")) ->
        {:ok, merge_compact_pr_metadata_fields(Map.get(arguments, "recovery"), arguments)}

      Map.has_key?(arguments, "recovery") ->
        {:tool_error, "invalid_recovery"}

      true ->
        compact_pr_metadata_input(repo, session, arguments)
    end
  end

  defp compact_pr_metadata_input(repo, %Session{} = session, arguments) do
    with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, Session.work_package_id(session)),
         {:ok, latest_payload} <- latest_current_attached_pr_payload(progress_events) do
      metadata =
        latest_payload
        |> discard_stale_pr_snapshot_metadata(arguments)
        |> discard_unavailable_changed_file_metadata()
        |> merge_compact_pr_metadata_fields(arguments)

      {:ok, metadata}
    else
      {:tool_error, "missing_attached_pr"} ->
        if explicit_pr_identity?(drop_blank_pr_identity_arguments(arguments)) do
          {:ok, Map.take(arguments, compact_pr_metadata_keys())}
        else
          {:tool_error, "missing_attached_pr"}
        end

      error ->
        error
    end
  end

  defp merge_compact_pr_metadata_fields(metadata, arguments) do
    Map.merge(metadata, compact_pr_metadata_fields(arguments))
  end

  defp discard_stale_pr_snapshot_metadata(metadata, arguments) do
    if compact_pr_head_changed?(metadata, arguments) do
      Map.drop(metadata, compact_pr_snapshot_metadata_keys())
    else
      metadata
    end
  end

  defp compact_pr_head_changed?(metadata, arguments) do
    case {compact_pr_head_sha(Map.get(arguments, "head_sha")), compact_pr_head_sha(Map.get(metadata, "head_sha"))} do
      {requested_head_sha, cached_head_sha} when is_binary(requested_head_sha) ->
        not PullRequest.head_sha_matches?(requested_head_sha, cached_head_sha)

      _heads ->
        false
    end
  end

  defp compact_pr_head_sha(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      head_sha -> head_sha
    end
  end

  defp compact_pr_head_sha(_value), do: nil

  defp discard_unavailable_changed_file_metadata(metadata) do
    metadata
    |> maybe_drop_unavailable_changed_files()
    |> maybe_drop_unavailable_changed_files_count()
  end

  defp maybe_drop_unavailable_changed_files(%{"changed_files_available" => true} = metadata), do: metadata
  defp maybe_drop_unavailable_changed_files(metadata), do: Map.delete(metadata, "changed_files")

  defp maybe_drop_unavailable_changed_files_count(%{"changed_files_count_available" => true} = metadata), do: metadata
  defp maybe_drop_unavailable_changed_files_count(metadata), do: Map.delete(metadata, "changed_files_count")

  defp compact_pr_metadata_keys do
    ["head_sha", "branch", "base_branch", "base_sha", "changed_files", "changed_files_count", "check_summary", "review_state", "merge_state"]
  end

  defp compact_pr_metadata_fields(arguments) do
    arguments
    |> Map.take(compact_pr_metadata_keys())
    |> Enum.reject(fn {_key, value} -> blank_argument?(value) end)
    |> Map.new()
  end

  defp compact_pr_snapshot_metadata_keys do
    [
      "base_sha",
      "base_branch",
      "changed_files",
      "changed_files_count",
      "changed_files_available",
      "changed_files_count_available",
      "check_summary",
      "review_state",
      "merge_state",
      "merged_at",
      "merge_commit_sha"
    ]
  end

  defp latest_current_attached_pr_payload(progress_events) do
    with {:ok, attached_ref, attach_boundary} <- latest_attached_pr_ref_with_ledger_boundary(progress_events) do
      latest_current_attached_pr_payload(progress_events, attached_ref, attach_boundary)
    end
  end

  defp latest_current_attached_pr_payload(progress_events, attached_ref, attach_boundary) do
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find_value(&current_attached_pr_payload(&1, attached_ref, attach_boundary))
    |> case do
      nil -> {:tool_error, "missing_attached_pr"}
      payload -> {:ok, payload}
    end
  end

  defp current_attached_pr_payload(%ProgressEvent{payload: payload} = event, attached_ref, attach_boundary) when is_map(payload) do
    if current_pr_state_event?(event, attach_boundary) and pr_payload_ref(payload) == attached_ref, do: payload
  end

  defp current_attached_pr_payload(%ProgressEvent{}, _attached_ref, _attach_boundary), do: nil

  defp append_pr_metadata(repo, %Session{} = session, arguments, tool, status, payload) do
    with {:ok, idempotency_key, attrs} <- metadata_event_attrs(session, arguments, tool, status, payload),
         {:ok, replay?} <- progress_event_replay?(repo, session, idempotency_key),
         :ok <- validate_pr_sync_target_unless_replay(repo, session, arguments, payload, tool, replay?) do
      run_worker_transaction(repo, fn ->
        append_pr_metadata_event(repo, session, attrs, idempotency_key, tool, payload, replay?)
      end)
    end
  end

  defp append_pr_metadata_event(repo, session, attrs, idempotency_key, tool, payload, replay?) do
    with {:ok, event_result} <- append_progress_event_or_replay(repo, session, attrs, idempotency_key, tool),
         :ok <- maybe_upsert_pr_artifact(repo, session, payload, replay?) do
      {:ok, event_result}
    end
  end

  defp validate_pr_sync_target_unless_replay(_repo, %Session{}, _arguments, _payload, _tool, true), do: :ok
  defp validate_pr_sync_target_unless_replay(_repo, %Session{}, _arguments, _payload, "attach_pr", false), do: :ok

  defp validate_pr_sync_target_unless_replay(repo, %Session{} = session, arguments, payload, tool, false) do
    with {:ok, ref} <- PullRequest.parse(payload, nil),
         {:ok, repair?} <- pr_attachment_repair?(repo, session, arguments, tool) do
      validate_pr_sync_target(repo, session, ref, tool, repair?)
    end
  end

  defp progress_event_replay?(repo, %Session{} = session, idempotency_key) do
    case existing_progress_event(repo, session, idempotency_key) do
      {:ok, %ProgressEvent{}} -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_upsert_pr_artifact(_repo, %Session{}, _payload, true), do: :ok

  defp maybe_upsert_pr_artifact(repo, %Session{} = session, payload, false) do
    PullRequestArtifact.upsert(repo, session.assignment.work_package_id, payload)
  end

  defp request_scope_expansion_payload(repo, %Session{} = session) do
    payload = %{
      "type" => "scope_expansion_request",
      "source_tool" => "request_scope_expansion",
      "approved" => false
    }

    case WorkPackageRepository.get(repo, session.assignment.work_package_id) do
      {:ok, %WorkPackage{kind: "investigation"} = work_package} ->
        {:ok, Map.put(payload, "recommendation_artifact_id", recommendation_artifact_id(work_package.id))}

      {:ok, %WorkPackage{}} ->
        {:ok, payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reject_ready_status(status) when status in ["ready_for_merge", "ready_for_human_merge", "ready_for_architect_merge"] do
    {:tool_error, "use_mark_ready"}
  end

  defp reject_ready_status(_status), do: :ok

  defp require_expected_status(%WorkPackage{status: expected_status}, expected_status), do: :ok
  defp require_expected_status(%WorkPackage{}, _expected_status), do: {:tool_error, "stale_status"}

  defp set_status_transaction(repo, %Session{} = session, expected_status, status, reason, blocker_closeout_plan) do
    repo
    |> run_worker_transaction(fn ->
      with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
           {:ok, state} <- PlanningRepository.get_state(repo, Session.work_package_id(session)),
           :ok <- require_expected_status(state.work_package, expected_status),
           :ok <- reject_architect_controlled_child(state.work_package, status),
           {:ok, _event} <- append_status_reason_event(repo, session, expected_status, status, reason),
           {:ok, work_package} <- LifecycleService.transition(repo, state.work_package, status, actor(session)),
           {:ok, blocker_closeout} <- apply_prepared_blocker_closeout(repo, session, blocker_closeout_plan) do
        {:ok, {work_package, blocker_closeout}}
      end
    end)
  end

  defp mark_ready_transaction(repo, %Session{} = session, blocker_closeout_plan) do
    repo
    |> run_worker_transaction(fn ->
      with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
           :ok <- lock_work_package(repo, Session.work_package_id(session)),
           {:ok, blocker_closeout} <- apply_prepared_blocker_closeout(repo, session, blocker_closeout_plan),
           {:ok, state} <- PlanningRepository.get_state(repo, Session.work_package_id(session)),
           {:ok, readiness_warnings} <- readiness_gates(repo, state),
           ready_status = StateMachine.terminal_readiness_status(state.work_package),
           :ok <- StateMachine.validate_ready_transition(state.work_package, ready_status, actor(session)),
           {:ok, work_package} <- WorkPackageRepository.update_status(repo, state.work_package.id, state.work_package.status, ready_status) do
        {:ok, {work_package, blocker_closeout, readiness_warnings}}
      end
    end)
  end

  defp escalate_guidance_request_transaction(
         repo,
         %Session{} = session,
         guidance_request_id,
         reason,
         recommended_language,
         decision_prompt
       ) do
    repo
    |> run_architect_transaction(fn ->
      with {:ok, filters, scope} <- scoped_guidance_request_filters(repo, session),
           {:ok, guidance_request} <-
             GuidanceRequestService.get_visible_to_architect(repo, guidance_request_id, filters),
           :ok <- authorize_guidance_request_for_session(repo, session, :guidance_request_escalate, guidance_request),
           :ok <- lock_work_package(repo, guidance_request.work_package_id),
           blocker_id = guidance_request_blocker_id(guidance_request.id),
           {:ok, escalated} <-
             GuidanceRequestService.escalate_human_info_needed(repo, guidance_request.id, %{
               "human_info_reason" => reason,
               "recommended_language" => recommended_language,
               "decision_prompt" => decision_prompt,
               "blocker_id" => blocker_id
             }),
           {:ok, blocker_event} <-
             PlanningRepository.append_audit_progress_event_for_work_package(
               repo,
               session.assignment,
               guidance_request.work_package_id,
               guidance_request_blocker_attrs(escalated, reason, recommended_language, blocker_id)
             ) do
        {:ok,
         %{
           "guidance_request" => guidance_request_payload(escalated),
           "blocker" => %{
             "id" => blocker_id,
             "active" => true,
             "progress_event_id" => blocker_event.id,
             "recommended_language" => recommended_language
           },
           "scope" => scope,
           "status" => %{"guidance_request_status" => escalated.status}
         }}
      end
    end)
  end

  defp guidance_request_blocker_attrs(%GuidanceRequest{} = guidance_request, reason, recommended_language, blocker_id) do
    %{
      "summary" => "Human info needed for guidance request: #{guidance_request.summary}",
      "body" => "Reason: #{reason}\n\nRecommended language: #{recommended_language}",
      "status" => "blocked",
      "idempotency_key" => "guidance_request_human_info_needed:#{guidance_request.id}",
      "payload" => %{
        "type" => "blocker",
        "source_tool" => "report_blocker",
        "blocker_id" => blocker_id,
        "active" => true,
        "guidance_request_id" => guidance_request.id,
        "guidance_request_status" => guidance_request.status,
        "human_info_needed" => true,
        "reason" => reason,
        "recommended_language" => recommended_language
      }
    }
  end

  defp guidance_request_blocker_id(guidance_request_id), do: "guidance_request:#{guidance_request_id}"

  defp approve_scope_expansion_transaction(
         repo,
         %Session{} = session,
         %WorkPackage{} = work_package,
         work_request,
         arguments,
         allowed_file_globs,
         rationale
       ) do
    repo.transaction(fn ->
      with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
           :ok <- lock_work_package(repo, work_package.id),
           {:ok, state} <- PlanningRepository.get_state(repo, work_package.id),
           :ok <- require_scope_guard_package(state.work_package),
           {:ok, result} <-
             approve_scope_expansion_result(
               repo,
               session,
               state.work_package,
               work_request,
               arguments,
               allowed_file_globs,
               rationale
             ) do
        result
      else
        {:tool_error, reason} -> repo.rollback({:tool_error, reason})
        {:error, reason} -> repo.rollback({:error, reason})
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp approve_scope_expansion_result(
         repo,
         %Session{} = session,
         %WorkPackage{} = work_package,
         work_request,
         arguments,
         allowed_file_globs,
         rationale
       ) do
    case existing_scope_expansion_approval(
           repo,
           session,
           work_package.id,
           arguments,
           allowed_file_globs,
           rationale
         ) do
      {:ok, event} ->
        {:ok, scope_expansion_approval_result(work_package, event)}

      {:error, :not_found} ->
        with :ok <- reject_ready_work_package(work_package),
             {:ok, effective_globs} <- ScopeGuard.approve_file_globs(work_package, allowed_file_globs),
             {:ok, effective_globs} <- scope_expansion_effective_work_request_globs(work_request, effective_globs),
             {:ok, updated_work_package} <-
               WorkPackageRepository.update(repo, work_package.id, %{"allowed_file_globs" => effective_globs}),
             {:ok, event} <-
               PlanningRepository.append_audit_progress_event_for_work_package(
                 repo,
                 session.assignment,
                 work_package.id,
                 scope_expansion_approval_attrs(
                   work_package,
                   updated_work_package,
                   arguments,
                   allowed_file_globs,
                   rationale
                 )
               ) do
          {:ok, scope_expansion_approval_result(updated_work_package, event)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing_scope_expansion_approval(
         repo,
         %Session{} = session,
         work_package_id,
         arguments,
         allowed_file_globs,
         rationale
       ) do
    idempotency_key =
      scope_expansion_approval_idempotency_key(
        work_package_id,
        arguments,
        allowed_file_globs,
        rationale
      )

    case PlanningRepository.get_progress_event_by_idempotency_key(
           repo,
           work_package_id,
           idempotency_key,
           session.assignment.grant_id
         ) do
      {:ok, event} ->
        validate_scope_expansion_approval_event(event, session, arguments, allowed_file_globs, rationale)

      {:error, :not_found} ->
        with {:ok, event} <- existing_work_package_progress_event(repo, work_package_id, idempotency_key) do
          validate_scope_expansion_approval_event(event, session, arguments, allowed_file_globs, rationale)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_scope_expansion_approval_event(
         %ProgressEvent{} = event,
         %Session{} = session,
         arguments,
         allowed_file_globs,
         rationale
       ) do
    with :ok <- scope_expansion_approval_actor_matches?(event, session),
         :ok <- scope_expansion_approval_payload_matches?(event, arguments, allowed_file_globs, rationale) do
      {:ok, event}
    end
  end

  defp scope_expansion_approval_actor_matches?(%ProgressEvent{actor_id: event_actor_id}, %Session{} = session) do
    current_actor_id = session.assignment.claimed_by

    cond do
      filled_string?(event_actor_id) and filled_string?(current_actor_id) ->
        if String.trim(event_actor_id) == String.trim(current_actor_id), do: :ok, else: {:error, :idempotency_conflict}

      filled_string?(event_actor_id) ->
        {:error, :idempotency_conflict}

      true ->
        :ok
    end
  end

  defp scope_expansion_approval_payload_matches?(
         %ProgressEvent{summary: summary, body: body, status: status, payload: payload},
         arguments,
         allowed_file_globs,
         rationale
       )
       when is_map(payload) do
    expected_request_id = optional_trimmed_string(arguments, "request_id")

    if summary == "Scope expansion approved" and
         body == rationale and
         status == "scope_expansion_approved" and
         Map.get(payload, "type") == "scope_expansion_approval" and
         Map.get(payload, "source_tool") == "approve_scope_expansion" and
         Map.get(payload, "approved") == true and
         Map.get(payload, "request_id") == expected_request_id and
         Map.get(payload, "approved_file_globs") == allowed_file_globs do
      :ok
    else
      {:error, :idempotency_conflict}
    end
  end

  defp scope_expansion_approval_payload_matches?(%ProgressEvent{}, _arguments, _allowed_file_globs, _rationale) do
    {:error, :idempotency_conflict}
  end

  defp scope_expansion_approval_result(%WorkPackage{} = work_package, %ProgressEvent{} = event) do
    %{
      "work_package" => work_package_payload(work_package),
      "allowed_file_globs" => Map.get(event.payload || %{}, "allowed_file_globs", work_package.allowed_file_globs),
      "progress_event" => progress_event_payload(event)
    }
  end

  defp require_scope_guard_package(%WorkPackage{} = work_package) do
    if ScopeGuard.required?(work_package), do: :ok, else: {:error, "scope_guard_not_required"}
  end

  defp scope_expansion_approval_attrs(%WorkPackage{} = previous_work_package, %WorkPackage{} = updated_work_package, arguments, allowed_file_globs, rationale) do
    request_id = optional_trimmed_string(arguments, "request_id")

    payload =
      %{
        "type" => "scope_expansion_approval",
        "source_tool" => "approve_scope_expansion",
        "approved" => true,
        "request_id" => request_id,
        "approved_file_globs" => allowed_file_globs,
        "previous_allowed_file_globs" => previous_work_package.allowed_file_globs || [],
        "allowed_file_globs" => updated_work_package.allowed_file_globs || []
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    %{
      "summary" => "Scope expansion approved",
      "body" => rationale,
      "status" => "scope_expansion_approved",
      "idempotency_key" =>
        scope_expansion_approval_idempotency_key(
          previous_work_package.id,
          arguments,
          allowed_file_globs,
          rationale
        ),
      "payload" => payload
    }
  end

  defp scope_expansion_approval_idempotency_key(
         work_package_id,
         arguments,
         allowed_file_globs,
         rationale
       ) do
    request_id = optional_trimmed_string(arguments, "request_id")

    %{
      "type" => "scope_expansion_approval",
      "source_tool" => "approve_scope_expansion",
      "work_package_id" => work_package_id,
      "request_id" => request_id,
      "approved_file_globs" => allowed_file_globs,
      "rationale" => rationale
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> metadata_idempotency_key()
  end

  defp optional_trimmed_string(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end
  end

  defp optional_request_id(arguments, key) do
    case Map.get(arguments, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "blank_request_id"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "invalid_request_id"}
    end
  end

  defp run_architect_transaction(repo, fun) do
    case repo.transaction(fn -> rollback_architect_transaction_result(repo, fun.()) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_architect_transaction_result(_repo, {:ok, result}), do: result
  defp rollback_architect_transaction_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})
  defp rollback_architect_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp run_worker_transaction(repo, fun) do
    case repo.transaction(fn -> rollback_worker_transaction_result(repo, fun.()) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:mcp_error, code, message, data}} -> {:error, code, message, data}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_worker_transaction_result(_repo, {:ok, result}), do: result
  defp rollback_worker_transaction_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})

  defp rollback_worker_transaction_result(repo, {:error, code, message, data}) do
    repo.rollback({:mcp_error, code, message, data})
  end

  defp rollback_worker_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp architect_session(repo, session, capability) when is_binary(capability) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_architect_assignment(session.assignment),
         :ok <- require_architect_capabilities(repo, session.assignment, [capability]) do
      {:ok, session}
    end
  end

  defp architect_session(repo, session, capabilities) when is_list(capabilities) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_architect_assignment(session.assignment),
         :ok <- require_architect_capabilities(repo, session.assignment, capabilities) do
      {:ok, session}
    end
  end

  defp require_live_architect_grant(repo, %Session{} = session) do
    case AccessGrantRepository.get(repo, session.assignment.grant_id) do
      {:ok, %AccessGrant{} = grant} ->
        assignment = assignment_with_live_grant_capabilities(session.assignment, grant)

        with :ok <- require_session_grant_match(assignment, grant),
             :ok <- require_live_grant(grant, DateTime.utc_now(:microsecond)),
             :ok <- require_architect_assignment(assignment) do
          {:ok, grant}
        end

      {:error, :not_found} ->
        {:error, :phase_scope_not_available}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assignment_with_live_grant_capabilities(assignment, %AccessGrant{} = grant) do
    %{assignment | capabilities: grant.capabilities || []}
  end

  defp require_session_grant_match(assignment, %AccessGrant{} = grant) do
    with {:ok, assignment_capabilities} <- comparable_capabilities(assignment.capabilities),
         {:ok, grant_capabilities} <- comparable_capabilities(grant.capabilities),
         true <- assignment.grant_id == grant.id,
         true <- assignment.work_package_id == grant.work_package_id,
         true <- assignment.phase_id == grant.phase_id,
         true <- assignment.display_key == grant.display_key,
         true <- assignment.grant_role == grant.grant_role,
         true <- assignment_capabilities == grant_capabilities,
         true <- assignment.claimed_at == grant.claimed_at,
         true <- assignment.claimed_by == grant.claimed_by do
      :ok
    else
      _mismatch -> {:error, :phase_scope_not_available}
    end
  end

  defp comparable_capabilities(capabilities) when is_list(capabilities), do: {:ok, capabilities}
  defp comparable_capabilities(nil), do: {:ok, []}

  defp require_live_grant(%AccessGrant{revoked_at: %DateTime{}}, _now), do: {:error, :assignment_revoked}

  defp require_live_grant(%AccessGrant{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    if DateTime.compare(expires_at, now) == :gt do
      :ok
    else
      {:error, :expired}
    end
  end

  defp require_live_grant(%AccessGrant{expires_at: nil}, %DateTime{}), do: :ok

  defp require_architect_capabilities(repo, assignment, capabilities) do
    with {:ok, effective_assignment} <- effective_architect_assignment(repo, assignment) do
      require_architect_capabilities(effective_assignment, capabilities)
    end
  end

  defp approve_scope_expansion_session(repo, session) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_architect_assignment(session.assignment),
         :ok <- require_scope_expansion_approval_authority(repo, session) do
      {:ok, session}
    end
  end

  defp require_scope_expansion_approval_authority(repo, %Session{} = session) do
    case require_architect_capabilities(repo, session.assignment, ["approve:scope_expansion"]) do
      :ok -> :ok
      {:error, :insufficient_capability} -> require_work_request_handoff_write_authority(repo, session)
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_work_request_handoff_write_authority(repo, %Session{} = session) do
    with :ok <- require_architect_capabilities(repo, session.assignment, ["write:work_request"]),
         {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, true} <- ArchitectHandoff.handoff_phase_grant?(repo, grant) do
      :ok
    else
      {:ok, false} -> {:error, :insufficient_capability}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_architect_capabilities(assignment, capabilities) do
    Enum.reduce_while(capabilities, :ok, fn capability, :ok ->
      case require_architect_capability(assignment, capability) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp approve_scope_expansion_work_package(repo, %Session{} = session, work_package_id) do
    if Session.work_package_id(session) == work_package_id do
      with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
           {:ok, work_request} <- optional_scope_expansion_linked_work_request(repo, work_package_id),
           :ok <- require_current_scope_expansion_work_request_scope(session, work_request) do
        {:ok, work_package, work_request}
      end
    else
      approve_scope_expansion_linked_work_package(repo, session, work_package_id)
    end
  end

  defp approve_scope_expansion_linked_work_package(repo, %Session{} = session, work_package_id) do
    with :ok <- require_scope_expansion_handoff_package_scope(repo, session),
         {:ok, work_package, _scope} <- scoped_worktree_work_package(repo, session, work_package_id),
         {:ok, work_request} <- optional_scope_expansion_linked_work_request(repo, work_package_id) do
      {:ok, work_package, work_request}
    else
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_scope_expansion_handoff_package_scope(repo, %Session{} = session) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, true} <- ArchitectHandoff.handoff_phase_grant?(repo, grant),
         :ok <- require_architect_capabilities(repo, session.assignment, ["write:work_request"]) do
      :ok
    else
      {:ok, false} -> {:error, :phase_scope_not_available}
      {:error, :insufficient_capability} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_scope_expansion_linked_work_request(repo, work_package_id) do
    case linked_planned_slice_work_request_for_work_package(repo, work_package_id) do
      {:ok, {%PlannedSlice{}, %WorkRequest{} = work_request}} -> {:ok, work_request}
      {:error, :not_found} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_current_scope_expansion_work_request_scope(%Session{}, %WorkRequest{}), do: :ok

  defp require_current_scope_expansion_work_request_scope(%Session{} = session, nil) do
    case require_architect_capability(session.assignment, "approve:scope_expansion") do
      :ok -> :ok
      {:error, :insufficient_capability} -> {:error, :phase_scope_not_available}
    end
  end

  defp require_scope_expansion_work_request_scope(nil, _allowed_file_globs), do: :ok

  defp require_scope_expansion_work_request_scope(%WorkRequest{} = work_request, allowed_file_globs) do
    case ScopeConstraints.validate_owned_file_globs(work_request, allowed_file_globs) do
      :ok -> :ok
      {:error, _errors} -> {:tool_error, "scope_expansion_outside_work_request"}
    end
  end

  defp scope_expansion_effective_work_request_globs(nil, effective_globs), do: {:ok, effective_globs}

  defp scope_expansion_effective_work_request_globs(%WorkRequest{} = work_request, effective_globs) do
    scoped_globs =
      Enum.filter(effective_globs, fn glob ->
        ScopeConstraints.validate_owned_file_globs(work_request, [glob]) == :ok
      end)

    {:ok, scoped_globs}
  end

  defp effective_architect_assignment(repo, %{grant_role: "architect", grant_id: grant_id} = assignment) do
    with {:ok, %AccessGrant{} = grant} <- AccessGrantRepository.get(repo, grant_id) do
      case ArchitectHandoff.handoff_phase_grant?(repo, grant) do
        {:ok, true} ->
          {:ok, %{assignment | capabilities: ArchitectHandoff.effective_capabilities(grant.capabilities)}}

        {:ok, false} ->
          {:ok, %{assignment | capabilities: grant.capabilities || []}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp require_architect_work_package_scope(%Session{} = session, work_package_id) do
    if Session.work_package_id(session) == work_package_id do
      :ok
    else
      {:error, :phase_scope_not_available}
    end
  end

  defp require_architect_phase_scope(repo, %Session{} = session, phase_id) do
    case architect_phase_scope(repo, session) do
      {:ok, ^phase_id} -> :ok
      {:ok, _other_phase_id} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp architect_phase_scope(repo, %Session{} = session) do
    case Session.phase_id(session) do
      phase_id when is_binary(phase_id) and phase_id != "" -> {:ok, phase_id}
      nil -> architect_session_anchor_phase_scope(repo, session)
      _phase_id -> {:error, :phase_scope_not_available}
    end
  end

  defp architect_session_anchor_phase_scope(repo, %Session{} = session) when is_atom(repo) do
    case Session.work_package_id(session) do
      work_package_id when is_binary(work_package_id) -> architect_anchor_phase_scope(repo, work_package_id)
      _work_package_id -> {:error, :phase_scope_not_available}
    end
  end

  defp architect_session_anchor_phase_scope(_repo, %Session{}), do: {:error, :phase_scope_not_available}

  defp architect_anchor_phase_scope(repo, work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %{phase_id: phase_id}} when is_binary(phase_id) and phase_id != "" -> {:ok, phase_id}
      {:ok, _work_package} -> {:error, :phase_scope_not_available}
      {:error, _reason} -> {:error, :phase_scope_not_available}
    end
  end

  defp architect_child_phase_anchor(repo, %Session{} = session) do
    with {:ok, grant} <- require_live_architect_grant(repo, session) do
      architect_child_phase_anchor(repo, session, grant)
    end
  end

  defp architect_child_phase_anchor(repo, %Session{} = session, %AccessGrant{} = grant) do
    with {:ok, phase_id} <- explicit_grant_phase_id(grant),
         {:ok, anchor} <- architect_anchor_work_package(repo, session),
         :ok <- require_frozen_anchor_scope(anchor, grant) do
      {:ok, phase_id, anchor}
    else
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp explicit_grant_phase_id(%AccessGrant{phase_id: phase_id}) when is_binary(phase_id) and phase_id != "", do: {:ok, phase_id}
  defp explicit_grant_phase_id(%AccessGrant{}), do: {:error, :phase_scope_not_available}

  defp require_architect_phase_anchor(repo, %Session{} = session, phase_id) when is_atom(repo) and is_binary(phase_id) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, anchor} <- architect_anchor_work_package(repo, session) do
      require_architect_anchor_scope(anchor, grant, phase_id)
    else
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_architect_anchor_scope(%WorkPackage{} = anchor, %AccessGrant{} = grant, phase_id) do
    cond do
      anchor.phase_id != phase_id ->
        {:error, :phase_scope_not_available}

      architect_explicit_phase_grant?(grant) ->
        require_frozen_anchor_scope(anchor, grant)

      true ->
        :ok
    end
  end

  defp architect_explicit_phase_grant?(%AccessGrant{grant_role: "architect", phase_id: phase_id}) when is_binary(phase_id) and phase_id != "",
    do: true

  defp architect_explicit_phase_grant?(%AccessGrant{}), do: false

  defp explicit_phase_id?(phase_id) when is_binary(phase_id), do: String.trim(phase_id) != ""
  defp explicit_phase_id?(_phase_id), do: false

  defp require_frozen_anchor_scope(%WorkPackage{} = anchor, %AccessGrant{} = grant) do
    if grant.phase_id == anchor.phase_id and repo_scope_name_matches?(grant.scope_repo, anchor.repo, []) and grant.scope_base_branch == anchor.base_branch do
      :ok
    else
      {:error, :phase_scope_not_available}
    end
  end

  defp architect_tool_capability("create_child_work_package"), do: "create:child_work_package"
  defp architect_tool_capability("mint_child_worker_key"), do: "mint:child_worker_key"
  defp architect_tool_capability("revoke_child_worker_key"), do: "revoke:child_worker_key"
  defp architect_tool_capability("list_work_requests"), do: "read:work_request"
  defp architect_tool_capability("read_work_request"), do: "read:work_request"
  defp architect_tool_capability("read_work_request_product_tree"), do: "read:work_request"
  defp architect_tool_capability("add_comment"), do: "write:work_request"
  defp architect_tool_capability("list_comments"), do: "read:work_request"
  defp architect_tool_capability("resolve_comment"), do: "write:work_request"
  defp architect_tool_capability("resolve_blocker"), do: "write:work_request"
  defp architect_tool_capability("read_work_request_delivery_board"), do: "read:work_request"
  defp architect_tool_capability("reconcile_work_request"), do: "read:work_request"

  defp architect_tool_capability(tool) when tool in ["cleanup_work_request_planned_slice_runtime", "record_planned_slice_delivery", "revoke_planned_slice_worker_key"],
    do: "write:work_request"

  defp architect_tool_capability("list_guidance_requests"), do: "read:guidance_request"
  defp architect_tool_capability("read_guidance_request"), do: "read:guidance_request"
  defp architect_tool_capability("answer_guidance_request"), do: "write:guidance_request"
  defp architect_tool_capability("escalate_guidance_request"), do: "write:guidance_request"
  defp architect_tool_capability("set_work_request_status"), do: "write:work_request"
  defp architect_tool_capability("ask_work_request_question"), do: "write:work_request"
  defp architect_tool_capability("answer_work_request_question"), do: "write:work_request"
  defp architect_tool_capability("answer_work_request_question_and_record_decision"), do: "write:work_request"
  defp architect_tool_capability("close_work_request_question"), do: "write:work_request"
  defp architect_tool_capability("record_work_request_decision"), do: "write:work_request"
  defp architect_tool_capability("add_work_request_planned_slice"), do: "write:work_request"
  defp architect_tool_capability("upsert_work_request_product_plan_node_content"), do: "write:work_request"
  defp architect_tool_capability("move_work_request_product_plan_node"), do: "write:work_request"
  defp architect_tool_capability("set_work_request_product_plan_node_completion"), do: "write:work_request"
  defp architect_tool_capability("move_work_request_planned_slice_to_product_node"), do: "write:work_request"
  defp architect_tool_capability("approve_work_request_planned_slice"), do: "write:work_request"
  defp architect_tool_capability("skip_work_request_planned_slice"), do: "write:work_request"
  defp architect_tool_capability("mark_work_request_sliced"), do: "write:work_request"
  defp architect_tool_capability("dispatch_work_request_planned_slice"), do: "dispatch:work_request"
  defp architect_tool_capability("prepare_work_package_worktree"), do: "dispatch:work_request"
  defp architect_tool_capability("cleanup_work_package_worktree"), do: "dispatch:work_request"
  defp architect_tool_capability("read_phase_board"), do: "read:phase"
  defp architect_tool_capability("approve_scope_expansion"), do: "approve:scope_expansion"
  defp architect_tool_capability("request_child_replan"), do: "request:child_replan"
  defp architect_tool_capability("approve_child_ready_state"), do: "approve:child_ready_state"
  defp architect_tool_capability("merge_child_into_phase"), do: "merge:child_into_phase"
  defp architect_tool_capability("split_work_package"), do: "split:child_work_package"
  defp architect_tool_capability("publish_phase_update"), do: "publish:phase_update"

  defp phase7_not_implemented(tool) do
    {:error, -32_604, "Not implemented",
     %{
       "tool" => tool,
       "reason" => "phase7_not_implemented",
       "phase" => "Phase 7",
       "detail" => "This Phase 7 architect workflow is not implemented in the current package."
     }}
  end

  defp read_current_virtual_file(repo, session, file_name) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_worker_assignment(session.assignment),
         work_package_id = Session.work_package_id(session),
         uri = "sympp://work-packages/#{work_package_id}/#{file_name}",
         {:ok, state} <- PlanningRepository.get_render_state(repo, work_package_id),
         {:ok, markdown} <- PlanningRenderer.render_state(state, file_name),
         {:ok, toon} <- WorkerContext.encode_virtual_file(state, file_name, uri: uri) do
      {:ok, agent_tool_result(%{"uri" => uri, "text" => markdown}, toon)}
    else
      {:error, reason} -> worker_error(reason, "read_#{file_name}")
    end
  end

  defp normalize_update_task_plan_result({:tool_error, reason}),
    do: {:error, -32_602, "Invalid params", %{"tool" => "update_task_plan", "reason" => reason}}

  defp normalize_update_task_plan_result({:error, reason}),
    do: worker_error(reason, "update_task_plan")

  defp normalize_update_task_plan_result(result), do: result

  defp read_task_plan_file(repo, session) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_worker_assignment(session.assignment),
         work_package_id = Session.work_package_id(session),
         {:ok, state} <- PlanningRepository.get_task_plan_render_state(repo, work_package_id),
         {:ok, markdown} <- PlanningRenderer.render_state(state, "task_plan.md"),
         uri = "sympp://work-packages/#{work_package_id}/task_plan.md",
         version = plan_version(state.plan_version_material),
         {:ok, virtual_payload} <- WorkerContext.virtual_file_payload(state, "task_plan.md", uri: uri, version: version) do
      toon = WorkerContext.encode_tool_payload(virtual_payload)

      {:ok,
       agent_tool_result(
         Map.put(virtual_payload, "text", markdown),
         toon
       )}
    else
      {:error, reason} -> worker_error(reason, "read_task_plan.md")
    end
  end

  defp update_task_plan(repo, session, arguments) do
    with {:ok, expected_version} <- required_integer(arguments, "expected_version"),
         work_package_id = Session.work_package_id(session),
         {:ok, plan_nodes, version} <-
           apply_plan_update(repo, session.assignment, work_package_id, expected_version, arguments) do
      {:ok,
       agent_tool_result(%{
         "plan_nodes" => Enum.map(plan_nodes, &plan_node_payload/1),
         "version" => version
       })}
    end
  end

  defp apply_plan_update(repo, assignment, work_package_id, expected_version, %{"patch" => patch} = arguments) when is_map(patch) do
    with :ok <- require_update_task_plan_keys(arguments, @plan_patch_argument_keys) do
      transaction_plan_update(repo, assignment, work_package_id, expected_version, fn ->
        apply_plan_patch(repo, work_package_id, patch)
      end)
    end
  end

  defp apply_plan_update(_repo, _assignment, _work_package_id, _expected_version, %{"patch" => _patch}) do
    {:tool_error, "invalid_patch"}
  end

  defp apply_plan_update(repo, assignment, work_package_id, expected_version, arguments) do
    with :ok <- require_update_task_plan_keys(arguments, @plan_append_argument_keys) do
      transaction_plan_update(repo, assignment, work_package_id, expected_version, fn ->
        append_plan_node_from_arguments(repo, work_package_id, arguments)
      end)
    end
  end

  defp transaction_plan_update(repo, assignment, work_package_id, expected_version, update_fun) do
    transaction_fun = fn ->
      transaction_result(repo, assignment, work_package_id, expected_version, update_fun)
    end

    case repo.transaction(transaction_fun) do
      {:ok, {plan_nodes, version}} -> {:ok, plan_nodes, version}
      {:error, reason} -> reason
    end
  end

  defp transaction_result(repo, assignment, work_package_id, expected_version, update_fun) do
    with :ok <- PlanningService.require_valid_assignment(repo, assignment),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package_id),
         :ok <- reject_ready_work_package(state.work_package),
         plan_nodes = state.plan_nodes,
         :ok <- require_plan_version(plan_nodes, expected_version),
         {:ok, updated_plan_nodes} <- transaction_result(repo, update_fun.()),
         {:ok, refreshed_plan_nodes} <- PlanningRepository.list_plan_nodes(repo, work_package_id) do
      {updated_plan_nodes, plan_version(refreshed_plan_nodes)}
    else
      {:tool_error, reason} -> repo.rollback({:tool_error, reason})
      {:error, reason} -> repo.rollback({:error, reason})
    end
  end

  defp transaction_result(_repo, {:ok, result}), do: {:ok, result}
  defp transaction_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})
  defp transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp lock_work_package(repo, work_package_id) do
    query = from(work_package in WorkPackage, where: work_package.id == ^work_package_id)

    case repo.update_all(query, set: [id: work_package_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

  defp lock_access_grant(repo, grant_id) do
    query = from(access_grant in AccessGrant, where: access_grant.id == ^grant_id)

    case repo.update_all(query, set: [id: grant_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :phase_scope_not_available}
    end
  end

  defp append_plan_node_from_arguments(repo, work_package_id, arguments) do
    with {:ok, title} <- required_argument(arguments, "title"),
         attrs = %{
           "work_package_id" => work_package_id,
           "title" => title,
           "body" => optional_argument(arguments, "body", nil),
           "status" => optional_argument(arguments, "status", "pending")
         },
         {:ok, plan_node} <- PlanningRepository.append_plan_node(repo, maybe_put_id(attrs, arguments)) do
      {:ok, [plan_node]}
    end
  end

  defp apply_plan_patch(repo, work_package_id, patch) do
    nodes = Map.get(patch, "nodes", [])

    cond do
      not is_list(nodes) -> {:tool_error, "missing_patch_nodes"}
      nodes == [] -> {:tool_error, "missing_patch_nodes"}
      true -> apply_plan_node_patches(repo, work_package_id, nodes)
    end
  end

  defp apply_plan_node_patches(repo, work_package_id, nodes) do
    nodes
    |> Enum.reduce_while({:ok, []}, &apply_plan_node_patch_step(repo, work_package_id, &1, &2))
    |> reverse_plan_patch_result()
  end

  defp apply_plan_node_patch_step(repo, work_package_id, node_attrs, {:ok, plan_nodes}) do
    case apply_plan_node_patch(repo, work_package_id, node_attrs) do
      {:ok, plan_node} -> {:cont, {:ok, [plan_node | plan_nodes]}}
      {:tool_error, reason} -> {:halt, {:tool_error, reason}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp reverse_plan_patch_result({:ok, plan_nodes}), do: {:ok, Enum.reverse(plan_nodes)}
  defp reverse_plan_patch_result({:tool_error, reason}), do: {:tool_error, reason}
  defp reverse_plan_patch_result({:error, reason}), do: {:error, reason}

  defp apply_plan_node_patch(repo, work_package_id, %{"id" => id} = attrs) when is_binary(id) do
    id = String.trim(id)
    updates = Map.take(attrs, ["title", "body", "status"])

    with :ok <- require_known_plan_node_patch_keys(attrs),
         true <- id != "" || {:tool_error, "invalid_patch_node"},
         {:ok, existing_nodes} <- PlanningRepository.list_plan_nodes(repo, work_package_id) do
      existing_node = Enum.find(existing_nodes, &(&1.id == id))
      patch_existing_or_append_plan_node(repo, work_package_id, existing_node, id, attrs, updates)
    else
      {:tool_error, reason} -> {:tool_error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_plan_node_patch(_repo, _work_package_id, %{"id" => _id}), do: {:tool_error, "invalid_patch_node"}

  defp apply_plan_node_patch(repo, work_package_id, attrs) when is_map(attrs) do
    with :ok <- require_known_plan_node_patch_keys(attrs),
         {:ok, title} <- required_argument(attrs, "title") do
      PlanningRepository.append_plan_node(repo, %{
        "work_package_id" => work_package_id,
        "title" => title,
        "body" => optional_argument(attrs, "body", nil),
        "status" => optional_argument(attrs, "status", "pending")
      })
    end
  end

  defp apply_plan_node_patch(_repo, _work_package_id, _attrs), do: {:tool_error, "invalid_patch_node"}

  defp patch_existing_or_append_plan_node(repo, _work_package_id, %PlanNode{}, id, _attrs, updates) do
    with :ok <- require_plan_node_updates(updates) do
      PlanningService.update_plan_node(repo, id, updates)
    end
  end

  defp patch_existing_or_append_plan_node(repo, work_package_id, nil, id, attrs, _updates) do
    with {:ok, title} <- required_argument(attrs, "title") do
      PlanningRepository.append_plan_node(repo, %{
        "id" => id,
        "work_package_id" => work_package_id,
        "title" => title,
        "body" => optional_argument(attrs, "body", nil),
        "status" => optional_argument(attrs, "status", "pending")
      })
    end
  end

  defp require_known_plan_node_patch_keys(attrs) do
    if Enum.all?(Map.keys(attrs), &(&1 in @plan_node_patch_keys)), do: :ok, else: {:tool_error, "invalid_patch_node"}
  end

  defp require_update_task_plan_keys(arguments, allowed_keys) do
    if Enum.all?(Map.keys(arguments), &(&1 in allowed_keys)), do: :ok, else: {:tool_error, "invalid_update_task_plan"}
  end

  defp require_plan_node_updates(updates) when map_size(updates) == 0, do: {:tool_error, "invalid_patch_node"}
  defp require_plan_node_updates(_updates), do: :ok

  defp require_plan_version(plan_nodes, expected_version) do
    if plan_version(plan_nodes) == expected_version, do: :ok, else: {:tool_error, "stale_plan_version"}
  end

  defp plan_version(plan_nodes) do
    material =
      Enum.map(plan_nodes, fn node ->
        %{
          id: node.id,
          title: node.title,
          body: node.body,
          status: node.status,
          position: node.position,
          updated_at: timestamp_version_part(node.updated_at)
        }
      end)

    :crypto.hash(:sha256, :erlang.term_to_binary(material))
    |> binary_part(0, 8)
    |> :binary.decode_unsigned()
    |> rem(9_007_199_254_740_991)
  end

  defp timestamp_version_part(nil), do: nil
  defp timestamp_version_part(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)

  defp append_authenticated_idempotent_finding(repo, %Session{} = session, finding_id, attrs) do
    work_package_id = Session.work_package_id(session)

    transaction_fun = fn ->
      append_authenticated_idempotent_finding_tx(repo, session, work_package_id, finding_id, attrs)
    end

    case run_worker_transaction(repo, transaction_fun) do
      {:error, :finding_insert_conflict} ->
        replay_finding_after_insert_conflict(repo, session.assignment, work_package_id, finding_id, attrs)

      result ->
        result
    end
  end

  defp append_authenticated_idempotent_finding_tx(repo, %Session{} = session, work_package_id, finding_id, attrs) do
    with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
         {:error, :id_already_exists} <-
           repo |> PlanningRepository.list_findings(work_package_id) |> find_existing_finding(finding_id, attrs),
         {:error, :id_already_exists} <-
           repo |> PlanningRepository.list_findings(work_package_id) |> find_existing_finding_by_idempotency(attrs),
         :ok <- reject_ready_evidence_mutation(repo, session, "append_finding") do
      case PlanningRepository.append_finding(repo, attrs) do
        {:ok, finding} ->
          {:ok, finding}

        {:error, reason} when reason in [:id_already_exists, :idempotency_key_conflict] ->
          {:error, :finding_insert_conflict}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp replay_finding_after_insert_conflict(repo, assignment, work_package_id, finding_id, attrs) do
    with :ok <- PlanningService.require_valid_assignment(repo, assignment) do
      replay_attempts = finding_replay_retry_attempts()

      case find_existing_finding_with_retry(repo, work_package_id, finding_id, attrs, replay_attempts) do
        {:error, :id_already_exists} ->
          find_existing_finding_by_idempotency_with_retry(repo, work_package_id, attrs, replay_attempts)

        result ->
          result
      end
    end
  end

  defp find_existing_finding_with_retry(repo, work_package_id, finding_id, attrs, attempts_left) do
    retry_fun = fn ->
      find_existing_finding_with_retry(repo, work_package_id, finding_id, attrs, attempts_left - 1)
    end

    repo
    |> PlanningRepository.list_findings(work_package_id)
    |> find_existing_finding(finding_id, attrs)
    |> retry_finding_replay_read(retry_fun, attempts_left)
  end

  defp find_existing_finding_by_idempotency_with_retry(repo, work_package_id, attrs, attempts_left) do
    retry_fun = fn ->
      find_existing_finding_by_idempotency_with_retry(repo, work_package_id, attrs, attempts_left - 1)
    end

    repo
    |> PlanningRepository.list_findings(work_package_id)
    |> find_existing_finding_by_idempotency(attrs)
    |> retry_finding_replay_read(retry_fun, attempts_left)
  end

  defp retry_finding_replay_read({:error, reason}, retry_fun, attempts_left)
       when reason in [:id_already_exists, :database_busy] and attempts_left > 0 do
    Process.sleep(5)
    retry_fun.()
  end

  defp retry_finding_replay_read(result, _retry_fun, _attempts_left), do: result

  defp find_existing_finding({:ok, findings}, finding_id, attrs) do
    case Enum.find(findings, &(&1.id == finding_id)) do
      %{} = finding ->
        if finding_idempotency_match?(finding, attrs) do
          idempotent_finding_result(finding, attrs)
        else
          {:tool_error, "idempotency_conflict"}
        end

      nil ->
        {:error, :id_already_exists}
    end
  end

  defp find_existing_finding({:error, reason}, _finding_id, _attrs), do: {:error, reason}

  defp find_existing_finding_by_idempotency({:ok, findings}, attrs) do
    case Enum.find(findings, &finding_idempotency_match?(&1, attrs)) do
      %{} = finding -> idempotent_finding_result(finding, attrs)
      nil -> {:error, :id_already_exists}
    end
  end

  defp find_existing_finding_by_idempotency({:error, reason}, _attrs), do: {:error, reason}

  defp finding_idempotency_match?(finding, attrs) do
    finding.idempotency_key == Map.get(attrs, "idempotency_key")
  end

  defp idempotent_finding_result(finding, attrs) do
    fields = if Map.get(attrs, "caller_supplied_id"), do: ["id", "title", "body", "severity"], else: ["title", "body", "severity"]
    expected = Map.take(attrs, fields)
    actual = Map.take(%{"id" => finding.id, "title" => finding.title, "body" => finding.body, "severity" => finding.severity}, fields)

    if expected == actual do
      {:ok, finding}
    else
      {:tool_error, "idempotency_conflict"}
    end
  end

  defp optional_finding_id(arguments, session, idempotency_key) do
    case Map.get(arguments, "id") do
      id when is_binary(id) ->
        case String.trim(id) do
          "" -> {:tool_error, "invalid_id"}
          trimmed -> {:ok, trimmed}
        end

      nil ->
        {:ok, generated_finding_id(session, idempotency_key)}

      _id ->
        {:tool_error, "invalid_id"}
    end
  end

  defp generated_finding_id(session, idempotency_key) do
    material = [session.assignment.work_package_id, session.assignment.grant_id, idempotency_key] |> Enum.join(":")
    "finding_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp finding_replay_retry_attempts do
    :symphony_elixir
    |> Application.get_env(:sympp_finding_replay_retry_attempts, @finding_replay_retry_attempts)
    |> max(0)
  end

  defp progress_replay_retry_attempts, do: finding_replay_retry_attempts()

  defp append_scoped_progress(repo, session, arguments, tool, payload) do
    with {:ok, session} <- scoped_session(repo, session, arguments),
         {action, resource_type} <- progress_tool_policy(tool),
         :ok <- authorize_current_package_policy(repo, session, action, resource_type, tool),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, caller_payload} <- optional_payload(arguments) do
      idempotency_key = scoped_progress_idempotency_key(tool, String.trim(idempotency_key), session)

      attrs = %{
        "summary" => summary,
        "body" => optional_argument(arguments, "body", nil),
        "status" => optional_argument(arguments, "status", "recorded"),
        "idempotency_key" => idempotency_key,
        "payload" => merge_tool_payload(tool, caller_payload, payload)
      }

      append_progress_event_or_replay(repo, session, attrs, idempotency_key, tool)
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
      {:error, reason} -> worker_error(reason, tool)
    end
  end

  defp append_status_reason_event(_repo, %Session{}, _expected_status, _status, nil), do: {:ok, nil}

  defp append_status_reason_event(repo, %Session{} = session, expected_status, status, reason) when is_binary(reason) do
    payload = %{"type" => "status_transition", "from_status" => expected_status, "to_status" => status}
    idempotency_payload = Map.put(payload, "reason_event_id", System.unique_integer([:positive, :monotonic]))

    append_scoped_progress(
      repo,
      session,
      %{
        "summary" => "Status changed to #{status}",
        "body" => reason,
        "status" => "status_changed",
        "idempotency_key" => metadata_idempotency_key(Map.put(idempotency_payload, "reason", reason))
      },
      "set_status",
      payload
    )
  end

  defp optional_reason(arguments) do
    case Map.get(arguments, "reason") do
      nil ->
        {:ok, nil}

      reason when is_binary(reason) ->
        case String.trim(reason) do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      _reason ->
        {:tool_error, "invalid_reason"}
    end
  end

  defp expected_question_status_argument(arguments) do
    cond do
      Map.has_key?(arguments, "expected_question_status") ->
        parse_question_status_guard(Map.get(arguments, "expected_question_status"))

      Map.has_key?(arguments, "current_status") ->
        parse_question_status_guard(Map.get(arguments, "current_status"))

      true ->
        {:ok, "open"}
    end
  end

  defp parse_question_status_guard(status) when is_binary(status) do
    status
    |> String.trim()
    |> require_open_question_status()
  end

  defp parse_question_status_guard(_status), do: {:tool_error, {:invalid_question_status, "non_string", ["open"]}}

  defp require_open_question_status("open"), do: {:ok, "open"}
  defp require_open_question_status(status), do: {:tool_error, {:invalid_question_status, status, ["open"]}}

  defp answer_question_and_record_decision_transaction(repo, work_request_id, question_id, expected_question_status, attrs) do
    repo.transaction(fn ->
      with {:ok, question_record} <-
             WorkRequestService.answer_question(repo, question_id, expected_question_status, %{
               "answer" => Map.fetch!(attrs, "answer"),
               "answered_by" => Map.fetch!(attrs, "answered_by")
             }),
           {:ok, decision_record} <-
             WorkRequestService.record_decision(
               repo,
               work_request_id,
               optional_put(
                 %{
                   "source_type" => Map.fetch!(attrs, "source_type"),
                   "decision" => Map.fetch!(attrs, "decision"),
                   "rationale" => Map.fetch!(attrs, "rationale"),
                   "scope_impact" => Map.fetch!(attrs, "scope_impact"),
                   "created_by" => Map.fetch!(attrs, "created_by")
                 },
                 "source_id",
                 Map.get(attrs, "source_id")
               )
             ) do
        %{question: question_record, decision: decision_record}
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp append_progress_event_or_replay(repo, %Session{} = session, attrs, idempotency_key, tool) do
    case existing_progress_event(repo, session, idempotency_key) do
      {:ok, event} ->
        replay_progress_event(repo, session, event, attrs, tool)

      {:error, :not_found} ->
        append_new_progress_event_or_replay(repo, session, attrs, idempotency_key, tool)

      {:error, reason} ->
        worker_error(reason, tool)
    end
  end

  defp append_new_progress_event_or_replay(repo, %Session{} = session, attrs, idempotency_key, tool) do
    transaction_fun = fn ->
      with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
           :ok <- reject_ready_evidence_mutation(repo, session, tool),
           {:ok, event} <- PlanningService.append_authenticated_progress_event(repo, session.assignment, attrs),
           :ok <- append_investigation_recommendation_artifact(repo, session, tool, event) do
        {:ok, event}
      end
    end

    case run_worker_transaction(repo, transaction_fun) do
      {:ok, event} ->
        {:ok, agent_tool_result(%{"progress_event" => progress_event_payload(event)})}

      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}

      {:error, :idempotency_key_conflict} ->
        replay_progress_event_with_retry(repo, session, attrs, idempotency_key, tool, progress_replay_retry_attempts())

      {:error, reason} ->
        worker_error(reason, tool)
    end
  end

  defp append_investigation_recommendation_artifact(repo, %Session{} = session, "request_scope_expansion", %ProgressEvent{} = event) do
    if Map.has_key?(event.payload || %{}, "recommendation_artifact_id") do
      append_recommendation_artifact(repo, session, event)
    else
      :ok
    end
  end

  defp append_investigation_recommendation_artifact(_repo, %Session{}, _tool, %ProgressEvent{}), do: :ok

  defp append_recommendation_artifact(repo, %Session{} = session, %ProgressEvent{}) do
    work_package_id = session.assignment.work_package_id

    attrs = %{
      "id" => recommendation_artifact_id(work_package_id),
      "work_package_id" => work_package_id,
      "path" => "recommendation.md",
      "title" => "Investigation recommendation",
      "kind" => "recommendation"
    }

    append_recommendation_artifact(attrs, repo)
  end

  defp append_recommendation_artifact(attrs, repo) do
    case PlanningRepository.get_artifact(repo, attrs["id"]) do
      {:ok, nil} ->
        case PlanningService.append_artifact(repo, attrs) do
          {:ok, _artifact} -> :ok
          {:error, :id_already_exists} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, %Artifact{} = artifact} ->
        repair_recommendation_artifact(repo, attrs, artifact)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp repair_recommendation_artifact(repo, attrs, %Artifact{} = artifact) do
    if artifact.work_package_id == attrs["work_package_id"] do
      case PlanningRepository.update_artifact(repo, artifact, recommendation_artifact_repair_attrs(attrs, artifact)) do
        {:ok, _artifact} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :id_already_exists}
    end
  end

  defp recommendation_artifact_repair_attrs(attrs, %Artifact{} = artifact) do
    %{
      work_package_id: attrs["work_package_id"],
      path: attrs["path"],
      title: attrs["title"],
      kind: attrs["kind"],
      uri: repaired_recommendation_artifact_uri(attrs, artifact)
    }
  end

  defp repaired_recommendation_artifact_uri(%{"uri" => uri}, %Artifact{}) when not is_nil(uri), do: uri

  defp repaired_recommendation_artifact_uri(attrs, %Artifact{} = artifact) do
    if artifact.work_package_id == attrs["work_package_id"] and artifact.path == attrs["path"] and artifact.title == attrs["title"] and artifact.kind == attrs["kind"] do
      artifact.uri
    else
      nil
    end
  end

  defp recommendation_artifact_id(work_package_id) do
    material = [work_package_id, "recommendation", "recommendation.md"] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp reject_ready_evidence_mutation(repo, %Session{} = session, tool)
       when tool in [
              "append_finding",
              "append_progress",
              "attach_branch",
              "attach_pr",
              "sync_pr",
              "report_blocker",
              "request_scope_expansion",
              "resolve_blocker",
              "submit_review_package",
              "attach_review_suite_result"
            ] do
    work_package_id = Session.work_package_id(session)

    with :ok <- lock_work_package(repo, work_package_id),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package_id) do
      reject_ready_work_package(state.work_package)
    end
  end

  defp reject_ready_evidence_mutation(_repo, %Session{}, _tool), do: :ok

  defp reject_ready_work_package(%WorkPackage{kind: "phase_child", status: status}) when status in ["merging_into_phase", "merged_into_phase"] do
    {:tool_error, "child_under_architect_control"}
  end

  defp reject_ready_work_package(%WorkPackage{status: status}) when status in ["ready_for_merge", "ready_for_human_merge", "ready_for_architect_merge"],
    do: {:tool_error, "already_ready"}

  defp reject_ready_work_package(%WorkPackage{}), do: :ok

  defp reject_architect_controlled_child(%WorkPackage{kind: "phase_child", status: "merging_into_phase"}, "blocked"), do: :ok

  defp reject_architect_controlled_child(%WorkPackage{kind: "phase_child", status: status}, _next_status)
       when status in ["merging_into_phase", "merged_into_phase"] do
    {:tool_error, "child_under_architect_control"}
  end

  defp reject_architect_controlled_child(%WorkPackage{}, _next_status), do: :ok

  defp replay_progress_event_with_retry(repo, %Session{} = session, attrs, idempotency_key, tool, attempts_left) do
    retry_fun = fn ->
      replay_progress_event_with_retry(repo, session, attrs, idempotency_key, tool, attempts_left - 1)
    end

    repo
    |> replay_progress_event(session, attrs, idempotency_key, tool)
    |> retry_missing_progress_event(retry_fun, attempts_left)
  end

  defp replay_progress_event(repo, %Session{} = session, %ProgressEvent{} = event, attrs, tool) do
    case PlanningService.require_valid_assignment(repo, session.assignment) do
      :ok -> replay_matching_progress_event(repo, session, event, attrs, tool)
      {:error, reason} -> worker_error(reason, tool)
    end
  end

  defp replay_progress_event(repo, %Session{} = session, attrs, idempotency_key, tool) do
    case existing_progress_event(repo, session, idempotency_key) do
      {:ok, event} -> replay_progress_event(repo, session, event, attrs, tool)
      {:error, reason} -> worker_error(reason, tool)
    end
  end

  defp existing_progress_event(repo, %Session{} = session, idempotency_key) do
    case PlanningRepository.get_progress_event_by_idempotency_key(
           repo,
           Session.work_package_id(session),
           idempotency_key,
           session.assignment.grant_id
         ) do
      {:ok, event} -> {:ok, event}
      {:error, :not_found} -> existing_work_package_progress_event(repo, session, idempotency_key)
      {:error, reason} -> {:error, reason}
    end
  end

  defp existing_work_package_progress_event(repo, %Session{} = session, idempotency_key) do
    existing_work_package_progress_event(repo, Session.work_package_id(session), idempotency_key)
  end

  defp existing_work_package_progress_event(repo, work_package_id, idempotency_key) do
    case PlanningRepository.list_progress_events(repo, work_package_id) do
      {:ok, progress_events} ->
        matching_progress_event(progress_events, idempotency_key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp matching_progress_event(progress_events, idempotency_key) do
    case Enum.find(progress_events, fn event -> event.idempotency_key == idempotency_key end) do
      %ProgressEvent{} = event -> {:ok, event}
      nil -> {:error, :not_found}
    end
  end

  defp retry_missing_progress_event({:error, _code, _message, %{"reason" => "not_found"}}, retry_fun, attempts_left) when attempts_left > 0 do
    Process.sleep(5)
    retry_fun.()
  end

  defp retry_missing_progress_event(result, _retry_fun, _attempts_left), do: result

  defp replay_matching_progress_event(_repo, %Session{} = _session, %ProgressEvent{} = event, attrs, tool) do
    if progress_replay_matches?(event, attrs) do
      {:ok, agent_tool_result(%{"progress_event" => progress_event_payload(event)})}
    else
      {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => "idempotency_conflict"}}
    end
  end

  defp progress_replay_matches?(%ProgressEvent{} = event, attrs) do
    normalized_payload = normalized_progress_payload(event, attrs)

    event.summary == Map.get(attrs, "summary") and
      event.body == Map.get(attrs, "body") and
      event.status == Map.get(attrs, "status") and
      progress_payload_replay_matches?(event.payload, normalized_payload)
  end

  defp progress_payload_replay_matches?(%{"type" => "scope_expansion_request", "source_tool" => "request_scope_expansion"} = existing, normalized) do
    existing == normalized or
      legacy_scope_expansion_replay_matches?(existing, normalized)
  end

  defp progress_payload_replay_matches?(%{"type" => "pr", "source_tool" => "attach_pr"} = existing, %{"type" => "pr", "source_tool" => "attach_pr"} = normalized) do
    existing == normalized or legacy_attach_pr_replay_matches?(existing, normalized)
  end

  defp progress_payload_replay_matches?(existing, normalized), do: existing == normalized

  defp legacy_scope_expansion_replay_matches?(existing, normalized) do
    legacy_normalized =
      case Map.fetch(existing, "recommendation_artifact_id") do
        {:ok, artifact_id} -> Map.put(normalized, "recommendation_artifact_id", artifact_id)
        :error -> Map.delete(normalized, "recommendation_artifact_id")
      end

    existing == legacy_normalized
  end

  defp legacy_attach_pr_replay_matches?(existing, normalized) do
    existing == Map.take(normalized, ["type", "source_tool", "url", "head_sha"])
  end

  defp normalized_progress_payload(%ProgressEvent{} = event, attrs) do
    attrs
    |> Map.merge(%{
      "id" => "replay_probe",
      "work_package_id" => event.work_package_id,
      "sequence" => 1,
      "created_at" => event.created_at || DateTime.utc_now(:microsecond)
    })
    |> ProgressEvent.create_changeset(trusted_audit_metadata: true)
    |> Ecto.Changeset.apply_changes()
    |> Map.get(:payload)
  end

  defp metadata_event_attrs(%Session{} = session, arguments, tool, status, payload) do
    payload = Map.put(payload, "source_tool", tool)

    arguments =
      Map.put_new(arguments, "summary", status)
      |> Map.put_new("status", status)
      |> Map.put_new("idempotency_key", metadata_idempotency_key(payload))
      |> canonical_metadata_event_status(tool, status)

    with {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, caller_payload} <- optional_payload(arguments),
         :ok <- validate_metadata_caller_payload(tool, caller_payload) do
      idempotency_key = scoped_progress_idempotency_key(tool, String.trim(idempotency_key), session)

      {:ok, idempotency_key,
       %{
         "summary" => summary,
         "body" => optional_argument(arguments, "body", nil),
         "status" => optional_argument(arguments, "status", "recorded"),
         "idempotency_key" => idempotency_key,
         "payload" => merge_tool_payload(tool, caller_payload, payload)
       }}
    end
  end

  defp canonical_metadata_event_status(arguments, "attach_review_suite_result", status), do: Map.put(arguments, "status", status)
  defp canonical_metadata_event_status(arguments, _tool, _status), do: arguments

  defp validate_metadata_caller_payload("attach_review_suite_result", caller_payload) when map_size(caller_payload) == 0, do: :ok
  defp validate_metadata_caller_payload("attach_review_suite_result", _caller_payload), do: {:tool_error, "unexpected_payload"}
  defp validate_metadata_caller_payload(_tool, _caller_payload), do: :ok

  defp append_metadata_event(repo, session, arguments, tool, status, payload) do
    case metadata_event_attrs(session, arguments, tool, status, payload) do
      {:ok, idempotency_key, attrs} -> append_progress_event_or_replay(repo, session, attrs, idempotency_key, tool)
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
    end
  end

  defp review_package_head_sha(nil, progress_events, %WorkPackage{} = work_package) do
    case latest_current_head_sha(progress_events) do
      current_head_sha when is_binary(current_head_sha) -> {:ok, current_head_sha}
      _missing_head -> missing_review_package_head_sha(work_package)
    end
  end

  defp review_package_head_sha(head_sha, progress_events, %WorkPackage{} = work_package) when is_binary(head_sha) do
    current_head_sha = latest_current_head_sha(progress_events)

    cond do
      is_binary(current_head_sha) and head_sha == current_head_sha ->
        {:ok, head_sha}

      is_binary(current_head_sha) and is_binary(head_sha) ->
        {:tool_error, "stale_head_sha"}

      merge_required?(work_package) ->
        {:tool_error, "missing_current_head_sha"}

      true ->
        {:ok, head_sha}
    end
  end

  defp missing_review_package_head_sha(%WorkPackage{} = work_package) do
    if merge_required?(work_package) do
      {:tool_error, "missing_current_head_sha"}
    else
      {:tool_error, "missing_head_sha"}
    end
  end

  defp optional_head_sha(arguments) do
    case Map.fetch(arguments, "head_sha") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, head_sha} when is_binary(head_sha) ->
        case String.trim(head_sha) do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _head_sha} ->
        {:tool_error, "invalid_head_sha"}
    end
  end

  defp submit_review_package_transaction(repo, %Session{} = session, arguments, artifacts, payload) do
    case repo.transaction(fn ->
           submit_review_package_transaction_body(repo, session, arguments, artifacts, payload)
         end) do
      {:ok, result} -> {:ok, result}
      {:error, {:mcp_error, code, message, data}} -> {:error, code, message, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp submit_review_package_transaction_body(repo, %Session{} = session, arguments, artifacts, payload) do
    work_package_id = Session.work_package_id(session)

    with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package_id),
         {:ok, requested_head_sha} <- optional_head_sha(arguments) do
      replay_head_sha = requested_head_sha || latest_current_head_sha(state.progress_events)
      arguments = maybe_put_headless_review_idempotency_key(arguments, requested_head_sha, payload)
      arguments = maybe_put_review_head_sha(arguments, replay_head_sha)
      payload = maybe_put_review_head_sha(payload, replay_head_sha)

      submit_or_replay_review_package(
        repo,
        session,
        arguments,
        artifacts,
        payload,
        replay_head_sha,
        state.work_package,
        state.progress_events
      )
    else
      {:tool_error, reason} ->
        repo.rollback({:mcp_error, -32_602, "Invalid params", %{"tool" => "submit_review_package", "reason" => reason}})

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp submit_or_replay_review_package(
         repo,
         %Session{} = session,
         arguments,
         artifacts,
         payload,
         requested_head_sha,
         work_package,
         progress_events
       ) do
    case replay_existing_metadata_event(repo, session, arguments, "submit_review_package", "review_package_submitted", payload, progress_events) do
      {:ok, result} ->
        result

      :not_found ->
        submit_new_review_package(
          repo,
          session,
          arguments,
          artifacts,
          payload,
          requested_head_sha,
          work_package,
          progress_events
        )

      {:error, code, message, data} ->
        repo.rollback({:mcp_error, code, message, data})
    end
  end

  defp submit_new_review_package(repo, %Session{} = session, arguments, artifacts, payload, requested_head_sha, work_package, progress_events) do
    case review_package_head_sha(requested_head_sha, progress_events, work_package) do
      {:ok, head_sha} ->
        case append_metadata_event(repo, session, arguments, "submit_review_package", "review_package_submitted", payload) do
          {:ok, result} ->
            persist_review_artifacts_and_promote_or_rollback(repo, session, artifacts, head_sha, result, work_package)

          {:error, code, message, data} ->
            repo.rollback({:mcp_error, code, message, data})
        end

      {:tool_error, reason} ->
        repo.rollback({:mcp_error, -32_602, "Invalid params", %{"tool" => "submit_review_package", "reason" => reason}})
    end
  end

  defp maybe_put_review_head_sha(map, head_sha) when is_binary(head_sha), do: Map.put(map, "head_sha", head_sha)
  defp maybe_put_review_head_sha(map, _head_sha), do: map

  defp maybe_put_headless_review_idempotency_key(arguments, nil, payload) do
    Map.put_new(arguments, "idempotency_key", metadata_idempotency_key(Map.put(payload, "source_tool", "submit_review_package")))
  end

  defp maybe_put_headless_review_idempotency_key(arguments, _requested_head_sha, _payload), do: arguments

  defp replay_existing_metadata_event(repo, %Session{} = session, arguments, tool, status, payload, progress_events) do
    case metadata_event_attrs(session, arguments, tool, status, payload) do
      {:ok, idempotency_key, attrs} ->
        case existing_metadata_event(repo, session, idempotency_key, tool, progress_events) do
          {:ok, event} -> replay_progress_event(repo, session, event, attrs, tool)
          {:error, :not_found} -> :not_found
          {:error, reason} -> worker_error(reason, tool)
        end

      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
    end
  end

  defp existing_metadata_event(_repo, %Session{}, idempotency_key, "submit_review_package", progress_events) when is_list(progress_events) do
    case Enum.find(progress_events, fn event -> event.idempotency_key == idempotency_key end) do
      %ProgressEvent{} = event -> {:ok, event}
      nil -> {:error, :not_found}
    end
  end

  defp existing_metadata_event(repo, %Session{} = session, idempotency_key, _tool, _progress_events) do
    PlanningRepository.get_progress_event_by_idempotency_key(
      repo,
      Session.work_package_id(session),
      idempotency_key,
      session.assignment.grant_id
    )
  end

  defp persist_review_artifacts_and_promote_or_rollback(repo, %Session{} = session, artifacts, head_sha, result, %WorkPackage{} = work_package) do
    with :ok <- append_review_artifacts(repo, session, artifacts, head_sha),
         :ok <- promote_stale_package_to_reviewing(repo, work_package) do
      result
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp append_review_artifacts(repo, %Session{} = session, artifacts, head_sha) do
    work_package_id = Session.work_package_id(session)

    case PlanningRepository.list_artifacts(repo, work_package_id) do
      {:ok, existing_artifacts} ->
        append_review_artifacts(repo, work_package_id, existing_artifacts, head_sha, artifacts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_review_artifacts(repo, work_package_id, existing_artifacts, head_sha, artifacts) do
    Enum.reduce_while(artifacts, :ok, fn artifact, :ok ->
      case append_review_artifact(repo, work_package_id, existing_artifacts, head_sha, artifact) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp append_review_artifact(repo, work_package_id, existing_artifacts, head_sha, artifact) do
    if persisted_review_artifact?(existing_artifacts, work_package_id, head_sha, artifact) do
      :ok
    else
      attrs = %{
        "id" => review_artifact_id(work_package_id, head_sha, artifact),
        "work_package_id" => work_package_id,
        "path" => artifact,
        "title" => artifact,
        "kind" => "review",
        "uri" => review_artifact_uri(artifact)
      }

      case PlanningService.append_artifact(repo, attrs) do
        {:ok, _artifact} -> :ok
        {:error, :id_already_exists} -> replay_review_artifact(repo, work_package_id, head_sha, artifact)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp replay_review_artifact(repo, work_package_id, head_sha, artifact) do
    case PlanningRepository.list_artifacts(repo, work_package_id) do
      {:ok, artifacts} ->
        if persisted_review_artifact?(artifacts, work_package_id, head_sha, artifact) do
          :ok
        else
          {:error, :id_already_exists}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp review_artifact_id(work_package_id, head_sha, artifact) do
    material = [work_package_id, head_sha || "no-head", artifact] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp review_artifact_uri(artifact) do
    if String.contains?(artifact, "://"), do: artifact, else: nil
  end

  defp review_suite_result_arguments(arguments, %Session{} = session) do
    if review_suite_round_id_argument?(arguments) do
      resolved_review_suite_result_arguments(arguments, session)
    else
      explicit_review_suite_result_arguments(arguments, session)
    end
  end

  defp review_suite_round_id_argument?(arguments) do
    case Map.get(arguments, "round_id") do
      value when is_binary(value) -> String.trim(value) != ""
      _value -> false
    end
  end

  defp explicit_review_suite_result_arguments(arguments, %Session{} = session) do
    with {:ok, work_package_id} <- optional_string_argument(arguments, "work_package_id", Session.work_package_id(session)),
         {:ok, requested_head_sha} <- required_argument(arguments, "head_sha"),
         {:ok, suite} <- required_argument(arguments, "suite"),
         {:ok, suite} <- review_suite_argument(suite),
         {:ok, anchor} <- required_argument(arguments, "anchor"),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, status} <- required_argument(arguments, "status"),
         {:ok, verdict} <- required_argument(arguments, "verdict") do
      {:ok, arguments,
       %{
         "type" => "review_suite_result",
         "source_tool" => "attach_review_suite_result",
         "work_package_id" => work_package_id,
         "head_sha" => requested_head_sha,
         "suite" => suite,
         "anchor" => anchor,
         "summary" => summary,
         "status" => normalized_review_suite_status(status),
         "verdict" => normalized_review_suite_verdict(verdict)
       }}
    end
  end

  defp resolved_review_suite_result_arguments(arguments, %Session{} = session) do
    with {:ok, work_package_id} <- optional_string_argument(arguments, "work_package_id", Session.work_package_id(session)),
         {:ok, round_id} <- required_argument(arguments, "round_id"),
         {:ok, resolved} <-
           ReviewSuiteRounds.resolve(round_id,
             lane: Map.get(arguments, "lane"),
             profile: Map.get(arguments, "profile")
           ),
         :ok <- require_review_suite_identity_match(resolved, "work_package_id", work_package_id) do
      payload =
        resolved
        |> Map.merge(%{
          "type" => "review_suite_result",
          "source_tool" => "attach_review_suite_result",
          "work_package_id" => work_package_id
        })
        |> Map.update!("status", &normalized_review_suite_status/1)
        |> Map.update!("verdict", &normalized_review_suite_verdict/1)

      resolved_arguments =
        arguments
        |> Map.put("head_sha", Map.fetch!(payload, "head_sha"))
        |> Map.put_new("summary", Map.fetch!(payload, "summary"))

      {:ok, resolved_arguments, payload}
    else
      {:tool_error, reason} -> {:tool_error, reason}
      {:error, reason} -> {:tool_error, reason}
    end
  end

  defp attach_review_suite_result_transaction(repo, %Session{} = session, arguments, payload) do
    case repo.transaction(fn ->
           attach_review_suite_result_transaction_body(repo, session, arguments, payload)
         end) do
      {:ok, result} -> {:ok, result}
      {:error, {:mcp_error, code, message, data}} -> {:error, code, message, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attach_review_suite_result_transaction_body(repo, %Session{} = session, arguments, payload) do
    case replay_existing_review_suite_result(repo, session, arguments, payload) do
      {:ok, result} ->
        result

      :new ->
        append_new_review_suite_result(repo, session, arguments, payload)

      {:error, code, message, data} ->
        repo.rollback({:mcp_error, code, message, data})
    end
  end

  defp promote_stale_package_to_reviewing(repo, %WorkPackage{status: status} = work_package)
       when status in @review_promotable_work_package_statuses do
    promote_package_status_to_reviewing(repo, work_package.id, status, 0)
  end

  defp promote_stale_package_to_reviewing(_repo, %WorkPackage{}), do: :ok

  defp promote_package_status_to_reviewing(repo, work_package_id, expected_status, attempts) do
    case WorkPackageRepository.update_status(repo, work_package_id, expected_status, "reviewing") do
      {:ok, %WorkPackage{}} ->
        :ok

      {:error, :stale_status} when attempts < 3 ->
        retry_review_promotion_from_latest_status(repo, work_package_id, attempts + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_review_promotion_from_latest_status(repo, work_package_id, attempts) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %WorkPackage{status: status}} when status in @review_promotable_work_package_statuses ->
        promote_package_status_to_reviewing(repo, work_package_id, status, attempts)

      {:ok, %WorkPackage{}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_existing_review_suite_result(repo, %Session{} = session, arguments, payload) do
    case PlanningService.require_valid_assignment(repo, session.assignment) do
      :ok -> replay_existing_review_suite_result_for_valid_assignment(repo, session, arguments, payload)
      {:error, reason} -> worker_error(reason, "attach_review_suite_result")
    end
  end

  defp replay_existing_review_suite_result_for_valid_assignment(repo, %Session{} = session, arguments, payload) do
    replay_payload = review_suite_payload(payload, arguments, Map.fetch!(payload, "head_sha"))

    case metadata_event_attrs(session, arguments, "attach_review_suite_result", "review_suite_passed", replay_payload) do
      {:ok, idempotency_key, attrs} -> replay_existing_review_suite_result_event(repo, session, idempotency_key, attrs)
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "attach_review_suite_result", "reason" => reason}}
    end
  end

  defp replay_existing_review_suite_result_event(repo, %Session{} = session, idempotency_key, attrs) do
    case existing_progress_event(repo, session, idempotency_key) do
      {:ok, event} -> replay_progress_event(repo, session, event, attrs, "attach_review_suite_result")
      {:error, :not_found} -> :new
      {:error, reason} -> worker_error(reason, "attach_review_suite_result")
    end
  end

  defp append_new_review_suite_result(repo, %Session{} = session, arguments, payload) do
    work_package_id = Session.work_package_id(session)
    requested_head_sha = Map.fetch!(payload, "head_sha")

    with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package_id),
         {:ok, head_sha} <- review_package_head_sha(requested_head_sha, state.progress_events, state.work_package),
         :ok <- reject_failed_review_suite_result_override(state.progress_events, work_package_id, head_sha),
         payload <- review_suite_payload(payload, arguments, head_sha),
         :ok <- require_review_suite_round_identity(payload, state.work_package, state.progress_events),
         {:ok, result} <- append_metadata_event(repo, session, arguments, "attach_review_suite_result", "review_suite_passed", payload),
         :ok <- append_review_suite_artifact(repo, work_package_id, head_sha),
         :ok <- promote_stale_package_to_reviewing(repo, state.work_package) do
      result
    else
      {:tool_error, {:review_suite_round_identity_mismatch, _field, _expected, _got} = reason} ->
        {:error, code, message, data} = invalid_params_error("attach_review_suite_result", reason)
        repo.rollback({:mcp_error, code, message, data})

      {:tool_error, reason} ->
        repo.rollback({:mcp_error, -32_602, "Invalid params", %{"tool" => "attach_review_suite_result", "reason" => reason}})

      {:error, code, message, data} ->
        repo.rollback({:mcp_error, code, message, data})

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp review_suite_payload(payload, arguments, head_sha) do
    payload
    |> Map.put("head_sha", head_sha)
    |> maybe_put_review_suite_field(arguments, "lane")
    |> maybe_put_review_suite_field(arguments, "profile")
    |> maybe_put_review_suite_field(arguments, "reviewer")
    |> maybe_put_review_suite_field(arguments, "round_id")
  end

  defp review_suite_argument(suite) do
    case ReviewProfiles.normalize_suite(suite) do
      "review-suite" -> {:ok, "review-suite"}
      _suite -> {:tool_error, "invalid_review_suite"}
    end
  end

  defp maybe_put_review_suite_field(payload, arguments, key) when key in ["lane", "profile"] do
    value = review_suite_profile_argument(Map.get(arguments, key))

    cond do
      not is_binary(value) -> payload
      Map.has_key?(payload, key) -> payload
      true -> Map.put(payload, key, value)
    end
  end

  defp maybe_put_review_suite_field(payload, arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "" or Map.has_key?(payload, key), do: payload, else: Map.put(payload, key, value)

      _value ->
        payload
    end
  end

  defp review_suite_profile_argument(value) when is_binary(value) do
    case ReviewProfiles.normalize_profile(value) do
      "" -> nil
      value -> value
    end
  end

  defp review_suite_profile_argument(_value), do: nil

  defp require_review_suite_round_identity(%{} = payload, %WorkPackage{} = work_package, progress_events) do
    with :ok <- require_review_suite_identity_match(payload, "repo", work_package.repo),
         :ok <- require_review_suite_identity_match(payload, "base_branch", work_package.base_branch) do
      require_review_suite_identity_match(payload, "branch", latest_current_branch(progress_events))
    end
  end

  defp require_review_suite_identity_match(payload, field, expected) do
    case review_suite_identity_value(payload, field) do
      nil ->
        :ok

      got ->
        if review_suite_identity_matches?(field, got, expected) do
          :ok
        else
          {:tool_error, {:review_suite_round_identity_mismatch, field, expected, got}}
        end
    end
  end

  defp review_suite_identity_matches?("repo", got, expected) do
    filled_string?(expected) and
      (repo_scope_name_matches?(got, expected, []) or String.downcase(String.trim(got)) == String.downcase(String.trim(expected)))
  end

  defp review_suite_identity_matches?(_field, got, expected) do
    case {normalize_review_suite_ref(got), normalize_review_suite_ref(expected)} do
      {got, expected} when is_binary(got) and is_binary(expected) -> got == expected
      _refs -> false
    end
  end

  defp normalize_review_suite_ref(value) when is_binary(value) do
    value
    |> String.trim()
    |> remove_review_suite_ref_prefix("refs/heads/")
    |> remove_review_suite_ref_prefix("origin/")
    |> empty_string_to_nil()
  end

  defp normalize_review_suite_ref(_value), do: nil

  defp remove_review_suite_ref_prefix(value, prefix) do
    if String.starts_with?(value, prefix), do: String.replace_prefix(value, prefix, ""), else: value
  end

  defp empty_string_to_nil(""), do: nil
  defp empty_string_to_nil(value), do: value

  defp review_suite_identity_value(payload, field) do
    case Map.get(payload, field) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end
  end

  defp reject_failed_review_suite_result_override(progress_events, work_package_id, head_sha) do
    failed_result? =
      progress_events
      |> MetadataProjection.current_head_review_suite_result_events(work_package_id, head_sha)
      |> Enum.any?(&failed_review_suite_result_payload?(&1, work_package_id))

    if failed_result? do
      {:tool_error, "failed_review_suite_result_exists"}
    else
      :ok
    end
  end

  defp failed_review_suite_result_payload?(%ProgressEvent{payload: payload}, work_package_id) do
    Map.get(payload, "work_package_id") == work_package_id and
      not (review_suite_status_passed?(Map.get(payload, "status")) and review_suite_verdict_passed?(Map.get(payload, "verdict")))
  end

  defp require_passing_review_suite_result(status, verdict) do
    if review_suite_status_passed?(status) and review_suite_verdict_passed?(verdict) do
      :ok
    else
      normalized_status = normalized_review_suite_status(status)
      normalized_verdict = normalized_review_suite_verdict(verdict)

      {:tool_error, {:non_passing_review_suite_result, normalized_status, normalized_verdict}}
    end
  end

  defp normalized_review_suite_status(status), do: ReviewProfiles.normalize_status(status)
  defp normalized_review_suite_verdict(verdict), do: ReviewProfiles.normalize_status(verdict)

  defp review_suite_status_passed?(status) do
    ReviewProfiles.passing_status?(status)
  end

  defp review_suite_verdict_passed?(verdict) do
    ReviewProfiles.passing_verdict?(verdict)
  end

  defp append_review_suite_artifact(repo, work_package_id, head_sha) do
    case PlanningRepository.list_artifacts(repo, work_package_id) do
      {:ok, artifacts} -> maybe_append_review_suite_artifact(repo, work_package_id, head_sha, artifacts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_append_review_suite_artifact(repo, work_package_id, head_sha, artifacts) do
    if MetadataProjection.persisted_review_suite_artifact?(artifacts, work_package_id, head_sha) do
      :ok
    else
      insert_review_suite_artifact(repo, work_package_id, head_sha)
    end
  end

  defp insert_review_suite_artifact(repo, work_package_id, head_sha) do
    attrs = %{
      "id" => review_suite_artifact_id(work_package_id, head_sha),
      "work_package_id" => work_package_id,
      "path" => "review-suite-result.json",
      "title" => "Review-suite result",
      "kind" => "review_suite"
    }

    case PlanningService.append_artifact(repo, attrs) do
      {:ok, _artifact} -> :ok
      {:error, :id_already_exists} -> replay_review_suite_artifact(repo, work_package_id, head_sha)
      {:error, reason} -> {:error, reason}
    end
  end

  defp replay_review_suite_artifact(repo, work_package_id, head_sha) do
    case PlanningRepository.list_artifacts(repo, work_package_id) do
      {:ok, artifacts} -> replay_review_suite_artifact_result(work_package_id, head_sha, artifacts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp replay_review_suite_artifact_result(work_package_id, head_sha, artifacts) do
    if MetadataProjection.persisted_review_suite_artifact?(artifacts, work_package_id, head_sha) do
      :ok
    else
      {:error, :id_already_exists}
    end
  end

  defp review_suite_artifact_id(work_package_id, head_sha) do
    material = [work_package_id, head_sha, "review-suite-result.json"] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp scoped_progress_idempotency_key("submit_review_package", idempotency_key, %Session{} = session) do
    ["submit_review_package", session.assignment.work_package_id, idempotency_key] |> Enum.join(":")
  end

  defp scoped_progress_idempotency_key("attach_review_suite_result", idempotency_key, %Session{} = session) do
    ["attach_review_suite_result", session.assignment.work_package_id, idempotency_key] |> Enum.join(":")
  end

  defp scoped_progress_idempotency_key(tool, idempotency_key, %Session{} = session) when tool in ["attach_branch", "attach_pr", "sync_pr"] do
    [tool, session.assignment.work_package_id, idempotency_key] |> Enum.join(":")
  end

  defp scoped_progress_idempotency_key(tool, idempotency_key, %Session{}), do: tool <> ":" <> idempotency_key

  defp readiness_gates(repo, state) do
    with {:ok, {required_review_lanes, warnings}} <- ReviewLanes.required(repo, state.work_package),
         {:ok, reasons} <- readiness_failure_reasons(repo, state, required_review_lanes) do
      missing = missing_readiness_gates(reasons)

      if missing == [], do: {:ok, warnings}, else: {:error, {:readiness_failed, missing, reasons, warnings}}
    end
  end

  defp missing_readiness_gates(reasons) do
    reasons
    |> Enum.map(&Map.fetch!(&1, "gate"))
    |> Enum.uniq()
  end

  defp readiness_failure_reasons(repo, state, required_review_lanes) do
    with {:ok, phase_child_reasons} <- phase_child_readiness_failure_reasons(repo, state.work_package) do
      {:ok, base_readiness_failure_reasons(state, required_review_lanes) ++ phase_child_reasons}
    end
  end

  defp base_readiness_failure_reasons(state, required_review_lanes) do
    [
      {readiness_status_missing?(state.work_package), readiness_status_gate(state.work_package)},
      {active_blocker?(state.progress_events), "no_active_blockers"},
      {incomplete_plan?(state), "plan_complete"},
      {acceptance_missing?(state), "acceptance_criteria_met"},
      {tests_missing?(state), "tests_passed"},
      {merge_metadata_missing?(state, "branch"), "branch_attached"},
      {merge_metadata_missing?(state, "pr"), "pr_attached"},
      {current_pr_state_missing?(state), "current_pr_state"},
      {review_suite_result_missing?(state), "review_suite_result"},
      {ScopeGuard.missing?(state.work_package, state.progress_events), @scope_guard_gate},
      {review_package_missing?(state, required_review_lanes), "review_package_submitted"},
      {review_artifacts_missing?(state, required_review_lanes), "review_artifacts_attached"},
      {review_lanes_missing?(state, required_review_lanes), "review_lanes_complete"},
      {investigation_findings_missing?(state), "findings_documented"},
      {investigation_recommendation_missing?(state), "recommendation_artifact_recorded"}
    ]
    |> Enum.flat_map(fn
      {true, @scope_guard_gate} -> ScopeGuard.failure_reasons(state.work_package, state.progress_events)
      {true, "review_lanes_complete"} -> [readiness_failure_reason("review_lanes_complete", state, required_review_lanes)]
      {true, gate} -> [readiness_failure_reason(gate)]
      {false, _gate} -> []
    end)
  end

  defp phase_child_readiness_failure_reasons(repo, %WorkPackage{kind: "phase_child"} = child) do
    with {:ok, phase} <- readiness_phase(repo, child),
         {:ok, parent} <- readiness_phase_parent(repo, child) do
      reasons =
        []
        |> maybe_add_readiness_reason(phase.status != "active", "phase_active")
        |> maybe_add_readiness_reason(not readiness_phase_child_scope_ok?(child, parent), "phase_child_scope")

      {:ok, Enum.reverse(reasons)}
    end
  end

  defp phase_child_readiness_failure_reasons(_repo, %WorkPackage{}), do: {:ok, []}

  defp readiness_phase(repo, %WorkPackage{phase_id: phase_id}) when is_binary(phase_id) do
    if filled_string?(phase_id) do
      case PhaseRepository.get(repo, phase_id) do
        {:ok, phase} -> {:ok, phase}
        {:error, :not_found} -> {:ok, %{status: nil}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, %{status: nil}}
    end
  end

  defp readiness_phase(_repo, %WorkPackage{}), do: {:ok, %{status: nil}}

  defp readiness_phase_parent(repo, %WorkPackage{parent_id: parent_id}) when is_binary(parent_id) do
    if filled_string?(parent_id) do
      case WorkPackageRepository.get(repo, parent_id) do
        {:ok, parent} -> {:ok, parent}
        {:error, :not_found} -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, nil}
    end
  end

  defp readiness_phase_parent(_repo, %WorkPackage{}), do: {:ok, nil}

  defp readiness_phase_child_scope_ok?(%WorkPackage{} = child, %WorkPackage{} = parent) do
    child.parent_id == parent.id and child.phase_id == parent.phase_id and child.repo == parent.repo and child.base_branch == parent.base_branch and
      require_phase_child_file_scope(child, parent) == :ok
  end

  defp readiness_phase_child_scope_ok?(%WorkPackage{}, _parent), do: false

  defp maybe_add_readiness_reason(reasons, true, gate), do: [readiness_failure_reason(gate) | reasons]
  defp maybe_add_readiness_reason(reasons, false, _gate), do: reasons

  defp readiness_failure_reason(gate) do
    %{
      "gate" => gate,
      "code" => gate,
      "message" => readiness_failure_message(gate)
    }
  end

  defp readiness_failure_reason("review_lanes_complete", state, required_lanes) do
    "review_lanes_complete"
    |> readiness_failure_reason()
    |> Map.merge(%{
      "required_lanes" => redacted_review_lanes(required_lanes),
      "latest_attached_review_round" => latest_review_suite_round_summary(state)
    })
    |> drop_nil_values()
  end

  defp redacted_review_lanes(lanes), do: Redactor.redact_output(lanes)

  defp readiness_failure_message("status_ci_waiting"), do: "Package must be waiting on validation."
  defp readiness_failure_message("status_reviewing"), do: "Package must be in review or validation."
  defp readiness_failure_message("no_active_blockers"), do: "Active blockers must be resolved."
  defp readiness_failure_message("plan_complete"), do: "Package plan is missing or still has pending items."
  defp readiness_failure_message("acceptance_criteria_met"), do: "Acceptance criteria evidence is missing."
  defp readiness_failure_message("tests_passed"), do: "Focused test evidence is missing."
  defp readiness_failure_message("branch_attached"), do: "Current branch metadata is missing."
  defp readiness_failure_message("pr_attached"), do: "Current PR metadata is missing."
  defp readiness_failure_message("current_pr_state"), do: "Current synced PR state is missing."
  defp readiness_failure_message("review_suite_result"), do: "Current-head Review Suite result is missing."
  defp readiness_failure_message("review_package_submitted"), do: "Current-head review package is missing."
  defp readiness_failure_message("review_artifacts_attached"), do: "Current-head review artifacts are missing."

  defp readiness_failure_message("review_lanes_complete"),
    do: "Required review profiles are not satisfied by a current-head passing review. Passing verdict aliases include green, clean, passed, pass, success, and approved."

  defp readiness_failure_message("findings_documented"), do: "Investigation findings are missing."
  defp readiness_failure_message("recommendation_artifact_recorded"), do: "Investigation recommendation artifact is missing."
  defp readiness_failure_message("phase_active"), do: "Phase must be active before phase child readiness."
  defp readiness_failure_message("phase_child_scope"), do: "Phase child must remain inside its parent phase repo, base branch, and file scope."
  defp readiness_failure_message(_gate), do: "Readiness gate is not satisfied."

  defp merge_metadata_missing?(state, "pr") do
    current_head_sha = latest_current_head_sha(state.progress_events)

    merge_required?(state.work_package) and
      pr_required?(state.work_package) and
      not metadata_present?(state.progress_events, "pr", current_head_sha)
  end

  defp merge_metadata_missing?(state, metadata_type) do
    current_head_sha = latest_current_head_sha(state.progress_events)

    merge_required?(state.work_package) and
      not metadata_present?(state.progress_events, metadata_type, current_head_sha)
  end

  defp current_pr_state_missing?(state) do
    current_head_sha = latest_current_head_sha(state.progress_events)

    merge_required?(state.work_package) and
      pr_required?(state.work_package) and
      required_gate?(state.work_package, "current_pr_state") and
      not current_pr_state_present?(state.progress_events, current_head_sha)
  end

  defp review_suite_result_missing?(state) do
    required_gate?(state.work_package, "review_suite_result") and
      not review_suite_result_present?(state.progress_events, state.artifacts, state.work_package.id, review_head_sha_for_readiness(state))
  end

  defp review_suite_result_present?(_progress_events, _artifacts, _work_package_id, nil), do: false

  defp review_suite_result_present?(progress_events, artifacts, work_package_id, readiness_head_sha) do
    case MetadataProjection.latest_review_suite_result_event(progress_events, work_package_id, readiness_head_sha) do
      %ProgressEvent{payload: payload} ->
        valid_persisted_review_suite_result?(payload, artifacts, work_package_id, readiness_head_sha)

      nil ->
        false
    end
  end

  defp valid_persisted_review_suite_result?(
         %{"head_sha" => head_sha} = payload,
         artifacts,
         work_package_id,
         readiness_head_sha
       )
       when is_binary(head_sha) do
    MetadataProjection.valid_review_suite_result_payload?(payload, work_package_id, readiness_head_sha) and
      MetadataProjection.persisted_review_suite_artifact?(artifacts, work_package_id, head_sha)
  end

  defp valid_persisted_review_suite_result?(_payload, _artifacts, _work_package_id, _readiness_head_sha), do: false

  defp review_package_missing?(state, required_review_lanes) do
    readiness_head_sha = review_head_sha_for_readiness(state)

    merge_required?(state.work_package) and required_review_lanes != [] and
      current_head_review_package_events(state.progress_events, readiness_head_sha) == []
  end

  defp review_artifacts_missing?(state, required_review_lanes) do
    merge_required?(state.work_package) and required_review_lanes != [] and
      not review_artifacts_present?(state, required_review_lanes)
  end

  defp review_lanes_missing?(state, required_review_lanes), do: not review_lanes_present?(state, required_review_lanes)

  defp investigation_findings_missing?(state), do: state.work_package.kind == "investigation" and state.findings == []

  defp investigation_recommendation_missing?(state) do
    state.work_package.kind == "investigation" and
      not recommendation_artifact_recorded?(state.artifacts, state.work_package.id)
  end

  defp maybe_put_readiness_warnings(payload, []), do: payload
  defp maybe_put_readiness_warnings(payload, warnings), do: Map.put(payload, "warnings", warnings)

  defp merge_required?(%WorkPackage{} = work_package) do
    work_package.kind in ["hotfix", "adapter", "mcp", "skill", "hooks", "phase_child"]
  end

  defp review_lanes_present?(_state, []), do: true

  defp review_lanes_present?(state, required_lanes) do
    if merge_required?(state.work_package) do
      review_package_lanes_present?(state.progress_events, required_lanes) or
        review_suite_result_lanes_present?(state, required_lanes)
    else
      review_package_lanes_present?(state.progress_events, required_lanes, review_head_sha_for_readiness(state)) or
        review_suite_result_lanes_present?(state, required_lanes) or
        progress_review_lanes_present?(state.progress_events, required_lanes)
    end
  end

  defp review_package_lanes_present?(progress_events, required_lanes) do
    review_package_lanes_present?(progress_events, required_lanes, latest_current_head_sha(progress_events))
  end

  defp review_package_lanes_present?(progress_events, required_lanes, readiness_head_sha) do
    readiness_head_sha = normalize_review_readiness_head_sha(readiness_head_sha)

    latest_verdicts =
      case latest_review_package_event(progress_events, readiness_head_sha) do
        %ProgressEvent{} = event ->
          event
          |> review_package_reviews(readiness_head_sha)
          |> Enum.reduce(%{}, fn review, verdicts ->
            Map.put(verdicts, ReviewProfiles.normalize_profile(Map.get(review, "lane")), Map.get(review, "verdict"))
          end)

        nil ->
          %{}
      end

    Enum.all?(required_lanes, &ReviewProfiles.profile_verdicts_pass?(&1, latest_verdicts))
  end

  defp review_suite_result_lanes_present?(state, required_lanes) do
    readiness_head_sha = review_head_sha_for_readiness(state)

    payloads =
      state.progress_events
      |> MetadataProjection.current_head_review_suite_result_events(state.work_package.id, readiness_head_sha)
      |> Enum.map(& &1.payload)
      |> Enum.filter(
        &(MetadataProjection.review_suite_result_payload_in_scope?(&1, state.work_package.id, readiness_head_sha) and
            MetadataProjection.persisted_review_suite_artifact?(
              state.artifacts,
              state.work_package.id,
              Map.fetch!(&1, "head_sha")
            ))
      )

    payloads != [] and
      Enum.all?(required_lanes, &ReviewProfiles.review_suite_payloads_satisfy_required_profile?(payloads, &1))
  end

  defp latest_review_suite_round_summary(state) do
    readiness_head_sha = review_head_sha_for_readiness(state)

    event =
      MetadataProjection.latest_review_suite_result_event(state.progress_events, state.work_package.id, readiness_head_sha) ||
        MetadataProjection.latest_review_suite_result_event(state.progress_events, state.work_package.id, :any_head)

    case event do
      %ProgressEvent{payload: payload} when is_map(payload) ->
        %{
          "round_id" => Map.get(payload, "round_id"),
          "review_suite_id" => Map.get(payload, "review_suite_id"),
          "lane" => Map.get(payload, "lane"),
          "profile" => Map.get(payload, "profile"),
          "status" => Map.get(payload, "status"),
          "verdict" => Map.get(payload, "verdict"),
          "head_sha" => Map.get(payload, "head_sha")
        }
        |> drop_nil_values()

      _event ->
        nil
    end
  end

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp progress_review_lanes_present?(progress_events, required_lanes) do
    head_boundary_sequence = latest_branch_event_sequence(progress_events)

    Enum.all?(required_lanes, &progress_review_lane_present?(progress_events, head_boundary_sequence, &1))
  end

  defp progress_review_lane_present?(progress_events, head_boundary_sequence, required_lane) do
    satisfying_profiles = ReviewProfiles.satisfying_profiles(required_lane)

    latest_statuses =
      satisfying_profiles
      |> Enum.map(&{&1, latest_generic_progress_status(progress_events, head_boundary_sequence, ReviewProfiles.statuses(&1))})
      |> Enum.reject(fn {_profile, status} -> is_nil(status) end)

    latest_statuses != [] and
      Enum.all?(latest_statuses, fn {profile, status} -> status in ReviewProfiles.green_statuses(profile) end)
  end

  defp generic_append_progress_event?(%ProgressEvent{payload: payload}) when is_map(payload) do
    Map.get(payload, "source_tool") == nil
  end

  defp generic_append_progress_event?(%ProgressEvent{payload: nil}), do: true
  defp generic_append_progress_event?(%ProgressEvent{}), do: false

  defp review_artifacts_present?(state, required_review_lanes) do
    current_head_sha = latest_current_head_sha(state.progress_events)
    artifact_references = current_head_review_artifact_references(state.progress_events, current_head_sha)

    review_package_artifacts_present =
      artifact_references != [] and
        Enum.all?(artifact_references, fn {path, artifact_head_sha} ->
          persisted_review_artifact?(state.artifacts, state.work_package.id, artifact_head_sha, path)
        end)

    review_package_artifacts_present or
      review_suite_result_lanes_present?(state, required_review_lanes)
  end

  defp current_head_review_artifact_references(progress_events, current_head_sha) do
    case latest_review_package_event(progress_events, current_head_sha) do
      %ProgressEvent{} = event -> review_package_artifact_references(event, current_head_sha)
      nil -> []
    end
  end

  defp latest_review_package_event(progress_events, current_head_sha) do
    progress_events
    |> current_head_review_package_events(current_head_sha)
    |> Enum.reverse()
    |> Enum.find(fn event -> review_package_artifact_paths(event, current_head_sha) != [] end)
  end

  defp current_head_review_package_events(progress_events, current_head_sha) do
    Enum.filter(progress_events, fn event ->
      payload_type?(event, "review_package", "submit_review_package") and current_head_review_package?(event, current_head_sha)
    end)
  end

  defp current_head_review_package?(%ProgressEvent{payload: payload}, current_head_sha) when is_map(payload) do
    review_head_matches?(payload, current_head_sha)
  end

  defp current_head_review_package?(%ProgressEvent{}, _current_head_sha), do: false

  defp review_head_matches?(payload, :any_head) when is_map(payload) do
    head_sha = Map.get(payload, "head_sha")
    is_binary(head_sha) and String.trim(head_sha) != ""
  end

  defp review_head_matches?(payload, current_head_sha) when is_map(payload) and is_binary(current_head_sha) do
    Map.get(payload, "head_sha") == current_head_sha
  end

  defp review_head_matches?(_payload, _current_head_sha), do: false

  defp review_package_artifact_paths(%ProgressEvent{payload: payload}, current_head_sha) when is_map(payload) do
    artifacts = Map.get(payload, "artifacts")

    if is_list(artifacts) and review_head_matches?(payload, current_head_sha) do
      Enum.filter(artifacts, &(is_binary(&1) and String.trim(&1) != ""))
    else
      []
    end
  end

  defp review_package_artifact_paths(%ProgressEvent{}, _current_head_sha), do: []

  defp review_package_artifact_references(%ProgressEvent{payload: payload} = event, current_head_sha) when is_map(payload) do
    event
    |> review_package_artifact_paths(current_head_sha)
    |> Enum.map(&{&1, Map.get(payload, "head_sha")})
  end

  defp review_package_artifact_references(%ProgressEvent{}, _current_head_sha), do: []

  defp persisted_review_artifact?(artifacts, work_package_id, head_sha, path) do
    expected_id = review_artifact_id(work_package_id, head_sha, path)
    Enum.any?(artifacts, &(&1.id == expected_id and &1.kind == "review" and &1.path == path))
  end

  defp review_package_reviews(%ProgressEvent{payload: payload}, current_head_sha) when is_map(payload) do
    reviews = Map.get(payload, "reviews")

    cond do
      not is_list(reviews) ->
        []

      not review_head_matches?(payload, current_head_sha) ->
        []

      true ->
        normalize_review_entries(reviews)
    end
  end

  defp review_package_reviews(%ProgressEvent{}, _current_head_sha), do: []

  defp normalize_review_entries(reviews) do
    reviews
    |> Enum.filter(&usable_review_entry?/1)
    |> Enum.map(fn review ->
      %{
        "lane" => review |> Map.get("lane", "") |> String.trim() |> String.downcase(),
        "verdict" => review |> Map.get("verdict", "") |> String.trim() |> String.downcase()
      }
    end)
  end

  defp usable_review_entry?(%{"lane" => lane, "verdict" => verdict}) do
    is_binary(lane) and String.trim(lane) != "" and is_binary(verdict) and String.trim(verdict) != ""
  end

  defp usable_review_entry?(_review), do: false

  defp latest_current_head_sha(progress_events) do
    latest_metadata_head_sha(progress_events, "branch", "attach_branch")
  end

  defp latest_current_branch(progress_events) do
    progress_events
    |> Enum.filter(&payload_type?(&1, "branch", "attach_branch"))
    |> Enum.reverse()
    |> Enum.find_value(fn
      %ProgressEvent{payload: payload} -> review_suite_identity_value(payload || %{}, "branch")
      _event -> nil
    end)
  end

  defp latest_metadata_head_sha(progress_events, type, source_tool) do
    progress_events
    |> Enum.filter(&payload_type?(&1, type, source_tool))
    |> Enum.reverse()
    |> Enum.find_value(fn
      %ProgressEvent{payload: payload} -> latest_metadata_payload_head_sha(payload)
      _event -> nil
    end)
  end

  defp latest_metadata_payload_head_sha(payload) do
    case Map.get(payload || %{}, "head_sha") do
      head_sha when is_binary(head_sha) and head_sha != "" -> head_sha
      _ -> nil
    end
  end

  defp active_blocker?(progress_events) do
    progress_events
    |> Enum.filter(&blocker_event?/1)
    |> Enum.reduce(%{}, fn event, blockers ->
      Map.put(blockers, blocker_id(event), Map.get(event.payload || %{}, "active") == true)
    end)
    |> Map.values()
    |> Enum.any?(& &1)
  end

  defp blocker_event?(%ProgressEvent{payload: payload}) when is_map(payload) do
    Map.get(payload, "type") == "blocker" and Map.get(payload, "source_tool") in ["report_blocker", "resolve_blocker"]
  end

  defp blocker_event?(%ProgressEvent{}), do: false

  defp blocker_id(%ProgressEvent{payload: payload, idempotency_key: idempotency_key, id: id}) do
    blocker_id = Map.get(payload || %{}, "blocker_id")
    normalize_blocker_id(blocker_id || idempotency_key || id)
  end

  defp incomplete_plan?(state) do
    plan_required?(state.work_package) and
      (Enum.any?(state.plan_nodes, &(&1.status not in @complete_plan_statuses)) or missing_meaningful_plan?(state))
  end

  defp missing_meaningful_plan?(%{plan_nodes: []}), do: true
  defp missing_meaningful_plan?(_state), do: false

  defp readiness_status_missing?(%WorkPackage{} = work_package) do
    if ci_waiting_required?(work_package) do
      work_package.status != "ci_waiting"
    else
      work_package.status not in ["reviewing", "ci_waiting"]
    end
  end

  defp readiness_status_gate(%WorkPackage{} = work_package), do: if(ci_waiting_required?(work_package), do: "status_ci_waiting", else: "status_reviewing")
  defp ci_waiting_required?(%WorkPackage{} = work_package), do: required_gate?(work_package, "ci_waiting")

  defp plan_required?(%WorkPackage{} = work_package) do
    case LifecycleService.policy_for(work_package) do
      {:ok, policy} -> get_in(policy, [:constraints, :planning_depth]) == "package"
      {:error, _reason} -> true
    end
  end

  defp acceptance_missing?(state) do
    required_gate?(state.work_package, "package_acceptance") and not acceptance_recorded?(state.progress_events)
  end

  defp tests_missing?(state) do
    required_gate?(state.work_package, "focused_tests") and not tests_recorded?(state)
  end

  defp required_gate?(%WorkPackage{} = work_package, gate) do
    case LifecycleService.policy_for(work_package) do
      {:ok, policy} -> gate in Map.get(policy, :required_gates, [])
      {:error, _reason} -> false
    end
  end

  defp acceptance_recorded?(progress_events) do
    current_head_sha = latest_current_head_sha(progress_events)

    case latest_review_package_event(progress_events, current_head_sha) do
      %ProgressEvent{payload: payload} when is_map(payload) -> Map.get(payload, "acceptance_criteria_met") == true
      _event -> false
    end
  end

  defp tests_recorded?(state) do
    if merge_required?(state.work_package) do
      review_package_tests_recorded?(state.progress_events)
    else
      review_package_tests_recorded?(state) or progress_status_recorded?(state.progress_events, "tests_passed")
    end
  end

  defp review_package_tests_recorded?(progress_events) when is_list(progress_events) do
    review_package_tests_recorded?(progress_events, latest_current_head_sha(progress_events))
  end

  defp review_package_tests_recorded?(%{progress_events: progress_events} = state) do
    review_package_tests_recorded?(progress_events, review_head_sha_for_readiness(state))
  end

  defp review_package_tests_recorded?(progress_events, readiness_head_sha) do
    readiness_head_sha = normalize_review_readiness_head_sha(readiness_head_sha)

    case latest_review_package_event(progress_events, readiness_head_sha) do
      %ProgressEvent{payload: payload} when is_map(payload) ->
        tests = Map.get(payload, "tests")
        is_list(tests) and Enum.any?(tests, &(is_binary(&1) and String.trim(&1) != ""))

      _event ->
        false
    end
  end

  defp review_head_sha_for_readiness(%{work_package: %WorkPackage{} = work_package, progress_events: progress_events}) do
    current_head_sha = latest_current_head_sha(progress_events)

    cond do
      is_binary(current_head_sha) -> current_head_sha
      merge_required?(work_package) -> nil
      true -> :any_head
    end
  end

  defp normalize_review_readiness_head_sha(head_sha) when is_binary(head_sha), do: head_sha
  defp normalize_review_readiness_head_sha(:any_head), do: :any_head
  defp normalize_review_readiness_head_sha(_head_sha), do: nil

  defp progress_status_recorded?(progress_events, expected_status) do
    head_boundary_sequence = latest_branch_event_sequence(progress_events)
    statuses = [expected_status, failed_status(expected_status)]

    latest_generic_progress_status(progress_events, head_boundary_sequence, statuses) == expected_status
  end

  defp latest_generic_progress_status(progress_events, head_boundary_sequence, statuses) do
    statuses = MapSet.new(statuses)

    progress_events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %ProgressEvent{status: status} = event ->
        status = normalized_status(status)

        if generic_append_progress_event?(event) and progress_after_head_boundary?(event, head_boundary_sequence) and MapSet.member?(statuses, status) do
          status
        end

      _event ->
        nil
    end)
  end

  defp failed_status("tests_passed"), do: "tests_failed"
  defp failed_status(status), do: status <> "_failed"

  defp latest_branch_event_sequence(progress_events) do
    progress_events
    |> Enum.reverse()
    |> Enum.find(&payload_type?(&1, "branch", "attach_branch"))
    |> case do
      %ProgressEvent{sequence: sequence} when is_integer(sequence) -> sequence
      _event -> nil
    end
  end

  defp progress_after_head_boundary?(%ProgressEvent{}, nil), do: true
  defp progress_after_head_boundary?(%ProgressEvent{sequence: sequence}, boundary_sequence) when is_integer(sequence), do: sequence > boundary_sequence
  defp progress_after_head_boundary?(%ProgressEvent{}, _boundary_sequence), do: false

  defp normalized_status(status) when is_binary(status), do: status |> String.trim() |> String.downcase()
  defp normalized_status(_status), do: ""

  defp pr_required?(%WorkPackage{kind: "investigation"}), do: false
  defp pr_required?(%WorkPackage{}), do: true

  defp metadata_present?(progress_events, "pr", head_sha) when is_binary(head_sha) do
    case latest_attached_pr_ref(progress_events) do
      {:ok, attached_ref} ->
        Enum.any?(progress_events, fn
          %ProgressEvent{payload: payload} = event when is_map(payload) ->
            payload_type?(event, "pr", ["attach_pr", "sync_pr"]) and head_sha_matches?(Map.get(payload, "head_sha"), head_sha) and
              pr_payload_ref(payload) == attached_ref

          %ProgressEvent{} ->
            false
        end)

      {:tool_error, _reason} ->
        false
    end
  end

  defp metadata_present?(progress_events, type, head_sha) when is_binary(head_sha) do
    Enum.any?(progress_events, fn
      %ProgressEvent{payload: payload} = event when is_map(payload) ->
        payload_type?(event, type, metadata_tool(type)) and head_sha_matches?(Map.get(payload, "head_sha"), head_sha)

      %ProgressEvent{} ->
        false
    end)
  end

  defp metadata_present?(_progress_events, _type, _head_sha), do: false

  defp current_pr_state_present?(progress_events, head_sha) when is_binary(head_sha) do
    case latest_attached_pr_ref_with_ledger_boundary(progress_events) do
      {:ok, attached_ref, attach_boundary} ->
        Enum.any?(progress_events, fn
          %ProgressEvent{payload: payload} = event when is_map(payload) ->
            current_pr_state_event?(event, attach_boundary) and
              head_sha_matches?(Map.get(payload, "head_sha"), head_sha) and
              pr_payload_ref(payload) == attached_ref and current_pr_state_payload?(payload)

          %ProgressEvent{} ->
            false
        end)

      {:tool_error, _reason} ->
        false
    end
  end

  defp current_pr_state_present?(_progress_events, _head_sha), do: false

  defp current_pr_state_event?(%ProgressEvent{} = event, {:repair_sync, repair_boundary}) do
    payload_type?(event, "pr", "sync_pr") and
      (attach_boundary(event) == repair_boundary or progress_after_pr_attach_boundary?(event, repair_boundary))
  end

  defp current_pr_state_event?(%ProgressEvent{} = event, attach_boundary) do
    (payload_type?(event, "pr", "attach_pr") and attach_boundary(event) == attach_boundary) or
      (payload_type?(event, "pr", "sync_pr") and progress_after_pr_attach_boundary?(event, attach_boundary))
  end

  defp progress_after_pr_attach_boundary?(%ProgressEvent{} = event, {:sequence, attach_boundary}) do
    progress_event_sequence_order(event) > attach_boundary
  end

  defp progress_after_pr_attach_boundary?(%ProgressEvent{} = event, {:chronological, attach_boundary}) do
    progress_event_chronological_order(event) > attach_boundary
  end

  defp progress_after_pr_attach_boundary?(%ProgressEvent{}, _attach_boundary), do: false

  defp current_pr_state_payload?(payload) when is_map(payload) do
    semantic_pr_state?(payload, "check_summary", ["conclusion", "state", "status"]) or
      semantic_pr_state?(payload, "review_state", ["decision", "state", "status"]) or
      semantic_pr_state?(payload, "merge_state", ["mergeable_state", "state", "status"]) or
      semantic_pr_boolean?(payload, "merge_state", ["mergeable", "merged"])
  end

  defp semantic_pr_state?(payload, key, semantic_keys) do
    case Map.get(payload, key) do
      value when is_map(value) ->
        Enum.any?(semantic_keys, fn semantic_key ->
          semantic_pr_value?(value, semantic_key)
        end)

      _value ->
        false
    end
  end

  defp semantic_pr_value(value, key), do: Map.get(value, key) || Map.get(value, String.to_atom(key))

  defp semantic_pr_value?(value, "state") do
    case semantic_pr_value(value, "state") do
      state when is_binary(state) ->
        normalized = state |> String.trim() |> String.downcase()
        normalized != "" and normalized not in ["open", "closed"]

      _state ->
        false
    end
  end

  defp semantic_pr_value?(value, key), do: value |> semantic_pr_value(key) |> filled_string?()

  defp semantic_pr_boolean?(payload, key, semantic_keys) do
    case Map.get(payload, key) do
      value when is_map(value) ->
        Enum.any?(semantic_keys, fn semantic_key ->
          is_boolean(Map.get(value, semantic_key)) or is_boolean(Map.get(value, String.to_atom(semantic_key)))
        end)

      _value ->
        false
    end
  end

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp recommendation_artifact_recorded?(artifacts, work_package_id) do
    artifact_id = recommendation_artifact_id(work_package_id)

    Enum.any?(
      artifacts,
      &(&1.id == artifact_id and &1.work_package_id == work_package_id and &1.path == "recommendation.md" and
          &1.title == "Investigation recommendation" and &1.kind == "recommendation")
    )
  end

  defp metadata_tool("branch"), do: "attach_branch"
  defp metadata_tool("pr"), do: "attach_pr"
  defp metadata_tool("review_package"), do: "submit_review_package"

  defp head_sha_matches?(left, right), do: PullRequest.head_sha_matches?(left, right)

  defp payload_type?(%ProgressEvent{payload: payload}, type, source_tools) when is_map(payload) and is_list(source_tools) do
    Map.get(payload, "type") == type and Map.get(payload, "source_tool") in source_tools
  end

  defp payload_type?(%ProgressEvent{payload: payload}, type, source_tool) when is_map(payload) do
    Map.get(payload, "type") == type and Map.get(payload, "source_tool") == source_tool
  end

  defp payload_type?(%ProgressEvent{}, _type, _source_tool), do: false

  defp create_work_request_error(%Ecto.Changeset{}) do
    {:error, -32_602, "Invalid params", %{"tool" => "create_work_request", "reason" => "invalid_work_request"}}
  end

  defp create_work_request_error(:id_already_exists) do
    {:error, -32_602, "Invalid params", %{"tool" => "create_work_request", "reason" => "id_already_exists"}}
  end

  defp create_work_request_error(:database_busy), do: service_error(:database_busy, "create_work_request")
  defp create_work_request_error({:storage_failed, _reason} = reason), do: service_error(reason, "create_work_request")

  defp create_work_request_error(reason) do
    {:error, -32_602, "Invalid params", %{"tool" => "create_work_request", "reason" => reason_text(reason)}}
  end

  defp worker_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)
  defp worker_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)
  defp worker_error(:expired, resource), do: auth_error({:unauthorized, :expired}, resource)
  defp worker_error(:assignment_revoked, resource), do: auth_error({:unauthorized, :revoked}, resource)
  defp worker_error(:assignment_mismatch, resource), do: auth_error({:unauthorized, :assignment_mismatch}, resource)
  defp worker_error(:worker_grant_required, resource), do: auth_error({:unauthorized, :worker_grant_required}, resource)
  defp worker_error({:authorization_policy_denied, %Decision{} = decision}, resource), do: MCPError.from_decision(decision, resource)
  defp worker_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp worker_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp worker_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp worker_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp worker_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp worker_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp local_operator_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp local_operator_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp local_operator_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp local_operator_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp architect_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)
  defp architect_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:expired, resource), do: auth_error({:unauthorized, :expired}, resource)
  defp architect_error(:assignment_revoked, resource), do: auth_error({:unauthorized, :revoked}, resource)
  defp architect_error(:architect_grant_required, resource), do: auth_error({:unauthorized, :architect_grant_required}, resource)
  defp architect_error(:insufficient_capability, resource), do: auth_error({:unauthorized, :insufficient_capability}, resource)
  defp architect_error({:authorization_policy_denied, %Decision{} = decision}, resource), do: MCPError.from_decision(decision, resource)
  defp architect_error({:authorization_policy_denied, code, message, data}, _resource), do: {:error, code, message, data}
  defp architect_error(:phase_scope_not_available, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:phase_scope_not_available, _missing_evidence}, resource), do: auth_error(:forbidden, resource)
  defp architect_error(:ambiguous_phase_scope, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:work_request_terminal, _terminal_state}, resource), do: auth_error(:forbidden, resource)
  defp architect_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp architect_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)

  defp architect_error({:planned_slice_scope_violation, errors}, tool) do
    invalid_params_error(tool, {:planned_slice_scope_violation, errors})
  end

  defp architect_error(:open_questions, tool) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "open_questions",
       "message" => "Answer or close all open clarification questions before adding planned slices."
     }}
  end

  defp architect_error(reason, tool) when reason in [:invalid_repo_root, :missing_repo_root] do
    invalid_params_error(tool, reason)
  end

  defp architect_error(reason, tool) when reason in [:invalid_target_repo_root, :missing_target_repo_root] do
    invalid_params_error(tool, reason)
  end

  defp architect_error({:git_failed, status, details}, tool) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "git_failed",
       "git" => details |> Map.put(:status, status) |> json_safe_payload() |> Redactor.redact_output()
     }}
  end

  defp architect_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp invalid_params_error(tool, {:planned_slice_scope_violation, errors}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "planned_slice_scope_violation",
       "validation_errors" => scope_validation_details(errors)
     }}
  end

  defp invalid_params_error(tool, {:branch_pattern, value, reason}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => Atom.to_string(reason),
       "validation_errors" => [
         %{
           "field" => "branch_pattern",
           "value" => value,
           "reason" => Atom.to_string(reason),
           "message" => BranchPattern.error_message(reason)
         }
       ]
     }}
  end

  defp invalid_params_error(tool, {:invalid_question_status, got, expected}) do
    expected = Enum.map(expected, &to_string/1)

    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "invalid_question_status",
       "status_domain" => "clarification_question",
       "expected_statuses" => expected,
       "got" => got,
       "message" => "expected clarification question status=#{Enum.join(expected, " or ")}, got #{got}"
     }}
  end

  defp invalid_params_error(tool, {:non_passing_review_suite_result, status, verdict}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "non_passing_review_suite_result",
       "status_domain" => "review_suite_result",
       "got" => %{"status" => status, "verdict" => verdict},
       "expected_statuses" => ReviewProfiles.passing_statuses(),
       "expected_verdicts" => ReviewProfiles.passing_verdicts()
     }}
  end

  defp invalid_params_error(tool, {:review_suite_round_unavailable, round_id, missing, fallback_fields}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "review_suite_round_unavailable",
       "round_id" => round_id,
       "missing" => missing,
       "fallback_explicit_fields" => fallback_fields,
       "message" => "Local Review Suite state for this round is unavailable. Retry with a resolvable round_id, or pass the explicit review-suite fields listed in fallback_explicit_fields."
     }}
  end

  defp invalid_params_error(tool, {:review_suite_round_ambiguous, round_id, cycle_keys, fallback_fields}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "review_suite_round_ambiguous",
       "round_id" => round_id,
       "matching_cycle_ids" => cycle_keys,
       "fallback_explicit_fields" => fallback_fields,
       "message" => "Local Review Suite round id matches multiple cycles. Retry with the Review Suite public id rvw_* or cycle id orc-*."
     }}
  end

  defp invalid_params_error(tool, {:review_suite_round_not_green, round_id, stage, fallback_fields}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "review_suite_round_not_green",
       "round_id" => round_id,
       "stage" => stage,
       "fallback_explicit_fields" => fallback_fields
     }}
  end

  defp invalid_params_error(tool, {:review_suite_round_not_passing, round_id, fallback_fields}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "review_suite_round_not_passing",
       "round_id" => round_id,
       "expected_verdicts" => ReviewProfiles.passing_verdicts(),
       "fallback_explicit_fields" => fallback_fields
     }}
  end

  defp invalid_params_error(tool, {:review_suite_round_missing_head, round_id, fallback_fields}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "review_suite_round_missing_head",
       "round_id" => round_id,
       "fallback_explicit_fields" => fallback_fields
     }}
  end

  defp invalid_params_error(tool, {:review_suite_round_missing_profile, round_id, fallback_fields}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "review_suite_round_missing_profile",
       "round_id" => round_id,
       "fallback_explicit_fields" => fallback_fields
     }}
  end

  defp invalid_params_error(tool, {:review_suite_round_profile_mismatch, round_id, resolved_profile, requested_profile, fallback_fields}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "review_suite_round_profile_mismatch",
       "round_id" => round_id,
       "resolved_profile" => resolved_profile,
       "requested_profile" => requested_profile,
       "fallback_explicit_fields" => fallback_fields
     }}
  end

  defp invalid_params_error(tool, {:review_suite_round_identity_mismatch, field, expected, got}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "review_suite_round_identity_mismatch",
       "field" => field,
       "expected" => expected,
       "got" => got,
       "message" => "Local Review Suite round identity does not match the current work package/session."
     }}
  end

  defp invalid_params_error(tool, {:review_suite_round_blocked, round_id, fallback_fields}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "review_suite_round_blocked",
       "round_id" => round_id,
       "fallback_explicit_fields" => fallback_fields
     }}
  end

  defp invalid_params_error(tool, {:review_suite_round_incomplete, round_id, status, fallback_fields}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "review_suite_round_incomplete",
       "round_id" => round_id,
       "status" => status,
       "fallback_explicit_fields" => fallback_fields
     }}
  end

  defp invalid_params_error(tool, {:blocker_closeout_required, blockers}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "blocker_closeout_required",
       "reason_code" => "blocker_closeout_required",
       "message" => "Active blockers exist in this finish scope. Pass blocker_closeout with decision resolved or still_active.",
       "active_blockers" => blockers
     }}
  end

  defp invalid_params_error(tool, {:blocker_closeout_scope_mismatch, active_ids, requested_ids}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "blocker_closeout_scope_mismatch",
       "reason_code" => "blocker_closeout_scope_mismatch",
       "active_blocker_ids" => active_ids,
       "requested_blocker_ids" => requested_ids
     }}
  end

  defp invalid_params_error(tool, reason) when reason in [:missing_repo_root, "missing_repo_root"] do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "missing_repo_root",
       "message" => "No Symphony++ helper root was provided or discoverable; pass symphony_repo_root or configure --repo-root to the Symphony++ repo containing the worker secret helper script."
     }}
  end

  defp invalid_params_error(tool, reason) when reason in [:invalid_repo_root, "invalid_repo_root"] do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "invalid_repo_root",
       "message" =>
         "symphony_repo_root must point to the Symphony++ helper/namespace repo root containing the worker secret helper script under scripts/; it is not the target product repository root."
     }}
  end

  defp invalid_params_error(tool, reason) when reason in [:missing_target_repo_root, "missing_target_repo_root"] do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "missing_target_repo_root",
       "message" => "target_repo_root must point to the target product repository root used for git worktree operations."
     }}
  end

  defp invalid_params_error(tool, reason) when reason in [:invalid_target_repo_root, "invalid_target_repo_root"] do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "invalid_target_repo_root",
       "message" => "target_repo_root must point to an existing target product repository root."
     }}
  end

  defp invalid_params_error(tool, reason) do
    {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}
  end

  defp scope_validation_details(errors) when is_list(errors), do: Enum.map(errors, &scope_validation_detail/1)
  defp scope_validation_details(error), do: scope_validation_details([error])

  defp scope_validation_detail({:invalid_constraints, field}) do
    %{"field" => Atom.to_string(field), "reason" => "invalid_constraints"}
  end

  defp scope_validation_detail({:invalid_owned_file_globs, field}) do
    %{"field" => Atom.to_string(field), "reason" => "invalid_owned_file_globs"}
  end

  defp scope_validation_detail({:invalid_path, field, value, reason}) do
    %{
      "field" => Atom.to_string(field),
      "value" => value,
      "reason" => Atom.to_string(reason)
    }
  end

  defp scope_validation_detail({:non_documentation_owned_glob, value}) do
    %{
      "field" => "owned_file_globs",
      "value" => value,
      "reason" => "non_documentation_owned_glob"
    }
  end

  defp scope_validation_detail({:outside_allowed_paths, value, allowed_paths}) do
    %{
      "field" => "owned_file_globs",
      "value" => value,
      "reason" => "outside_allowed_paths",
      "allowed_paths" => allowed_paths
    }
  end

  defp scope_validation_detail({:forbidden_path_overlap, value, forbidden_path}) do
    %{
      "field" => "owned_file_globs",
      "value" => value,
      "reason" => "forbidden_path_overlap",
      "forbidden_path" => forbidden_path
    }
  end

  defp scoped_session(repo, session, arguments) when is_map(arguments) do
    case Auth.require_session(session, repo) do
      {:ok, session} ->
        with :ok <- require_worker_assignment(session.assignment) do
          require_argument_scope(session, Map.get(arguments, "work_package_id"))
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_argument_scope(session, nil), do: {:ok, session}
  defp require_argument_scope(session, work_package_id) when work_package_id == session.assignment.work_package_id, do: {:ok, session}
  defp require_argument_scope(_session, _work_package_id), do: {:error, :forbidden}

  defp require_comment_target_kind(target_kind) do
    if target_kind in Comment.target_kinds(), do: :ok, else: {:tool_error, "invalid_target_kind"}
  end

  defp comment_tool_result("add_comment", repo, %Session{} = session, arguments, source_type, author_name) do
    with {:ok, target_kind, target_id} <- comment_target_arguments(arguments, session, source_type),
         {:ok, body} <- required_argument(arguments, "body"),
         {:ok, comment} <-
           CommentService.create_for_assignment(
             repo,
             session.assignment,
             %{
               "target_kind" => target_kind,
               "target_id" => target_id,
               "body" => body,
               "source_type" => Atom.to_string(source_type),
               "author_name" => author_name
             },
             comment_create_opts(source_type, target_kind)
           ) do
      {:ok, tool_result(%{"comment" => comment_payload(comment)})}
    end
  end

  defp comment_tool_result("list_comments", repo, %Session{} = session, arguments, source_type, _author_name) do
    with {:ok, target_kind, target_id} <- comment_target_arguments(arguments, session, source_type),
         {:ok, comments} <- CommentService.list_for_assignment(repo, session.assignment, target_kind, target_id) do
      {:ok,
       tool_result(%{
         "comments" => Enum.map(comments, &comment_payload/1),
         "target" => %{"kind" => target_kind, "id" => target_id}
       })}
    end
  end

  defp comment_tool_result("resolve_comment", repo, %Session{} = session, arguments, source_type, author_name) do
    with {:ok, comment_id} <- required_argument(arguments, "comment_id"),
         {:ok, resolved} <-
           CommentService.resolve_for_assignment(repo, session.assignment, comment_id, %{
             "resolved_by" => author_name,
             "resolved_source_type" => Atom.to_string(source_type),
             "resolution_note" => optional_argument(arguments, "resolution_note", nil)
           }) do
      {:ok, tool_result(%{"comment" => comment_payload(resolved)})}
    end
  end

  defp comment_target_arguments(arguments, %Session{} = session, :worker) do
    with {:ok, target_kind} <- optional_string_argument(arguments, "target_kind", "work_package"),
         :ok <- require_comment_target_kind(target_kind),
         {:ok, target_id} <- comment_target_id_argument(arguments, session, target_kind) do
      {:ok, target_kind, target_id}
    end
  end

  defp comment_target_arguments(arguments, %Session{}, _source_type) do
    with {:ok, target_kind} <- required_argument(arguments, "target_kind"),
         :ok <- require_comment_target_kind(target_kind),
         {:ok, target_id} <- required_argument(arguments, "target_id") do
      {:ok, target_kind, target_id}
    end
  end

  defp comment_target_id_argument(arguments, %Session{} = session, "work_package") do
    case optional_string_argument(arguments, "target_id", Session.work_package_id(session)) do
      {:ok, nil} -> {:tool_error, "missing_target_id"}
      result -> result
    end
  end

  defp comment_target_id_argument(arguments, %Session{}, _target_kind), do: required_argument(arguments, "target_id")

  defp comment_create_opts(:architect, target_kind), do: [action: architect_comment_add_action(target_kind)]
  defp comment_create_opts(_source_type, _target_kind), do: []

  defp architect_comment_add_action("work_request"), do: :external_comment_add
  defp architect_comment_add_action(_target_kind), do: :comment_add

  defp worker_comment_actor(%Session{} = session) do
    assignment = Session.public_assignment(session)
    assignment["claimed_by"] || assignment["grant_id"] || "worker"
  end

  defp authorize_solo_tool_call(%__MODULE__{session_refresh_required: true}, tool) do
    {:error, -32_001, "Unauthorized",
     %{
       "tool" => tool,
       "reason" => "claim_required",
       "action" => @local_assignment_claim_tool,
       "hint" => "This MCP state no longer has a live current assignment. Reclaim the assignment or start a fresh MCP session before using Solo tools."
     }}
  end

  defp authorize_solo_tool_call(%__MODULE__{session: nil}, _tool), do: :ok

  defp authorize_solo_tool_call(%__MODULE__{} = server, tool) do
    {:error, -32_001, "Unauthorized", bound_solo_tool_denial(tool, server)}
  end

  defp bound_solo_tool_denial(tool, %__MODULE__{} = server) do
    %{
      "tool" => tool,
      "reason" => "solo_tools_require_unbound_session",
      "action" => @assignment_release_tool,
      "current_assignment" => current_assignment_context(server),
      "recovery" => %{
        "tool" => @assignment_release_tool,
        "next_action" => "call_release_current_assignment_then_retry_solo_tool",
        "fresh_mcp_session_required" => false,
        "fallback" => "If release_current_assignment is unavailable or returns fresh_mcp_session_required=true, start a fresh MCP session before using Solo tools."
      }
    }
  end

  defp authorize_worker_tool_call(%__MODULE__{config: config, session: session}, "get_current_assignment") do
    case Auth.require_session(session, config.repo) do
      {:ok, session} -> require_assignment_introspection(session.assignment)
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_worker_tool_call(%__MODULE__{config: config, session: session}, _tool) do
    case Auth.require_session(session, config.repo) do
      {:ok, session} -> require_worker_assignment(session.assignment)
      {:error, reason} -> {:error, reason}
    end
  end

  defp solo_tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_solo_arguments(name, arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp worker_tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_worker_arguments(name, arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp local_architect_assignment_claim_tool_arguments(params) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_local_architect_assignment_claim_arguments(arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => @local_architect_assignment_claim_tool, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp assignment_release_tool_arguments(params) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_assignment_release_arguments(arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => @assignment_release_tool, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp local_operator_tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_local_operator_arguments(name, arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp architect_tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_architect_arguments(name, arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp bootstrap_tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_bootstrap_arguments(name, arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp validate_worker_arguments(name, arguments) do
    allowed = MapSet.new(allowed_worker_argument_keys(name))
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected == [] do
      {:ok, arguments}
    else
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    end
  end

  defp validate_local_architect_assignment_claim_arguments(arguments) do
    schema = local_architect_assignment_claim_tool_input_schema()
    allowed = schema |> Map.get("properties", %{}) |> Map.keys() |> MapSet.new()
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected != [] do
      {:error, -32_602, "Invalid params", %{"tool" => @local_architect_assignment_claim_tool, "reason" => "unexpected_argument", "arguments" => unexpected}}
    else
      case validate_tool_required_arguments(schema, arguments) do
        :ok -> {:ok, arguments}
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => @local_architect_assignment_claim_tool, "reason" => reason}}
      end
    end
  end

  defp validate_solo_arguments(name, arguments) do
    allowed = MapSet.new(allowed_solo_argument_keys(name))
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected == [] do
      {:ok, arguments}
    else
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    end
  end

  defp validate_assignment_release_arguments(arguments) do
    schema = assignment_release_tool_input_schema()
    allowed = schema |> Map.get("properties", %{}) |> Map.keys() |> MapSet.new()
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected != [] do
      {:error, -32_602, "Invalid params", %{"tool" => @assignment_release_tool, "reason" => "unexpected_argument", "arguments" => unexpected}}
    else
      case validate_tool_required_arguments(schema, arguments) do
        :ok -> {:ok, arguments}
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => @assignment_release_tool, "reason" => reason}}
      end
    end
  end

  defp validate_local_operator_arguments(name, arguments) do
    allowed = MapSet.new(allowed_local_operator_argument_keys(name))
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected != [] do
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    else
      schema = local_operator_tool_input_schema(name)

      case validate_tool_required_arguments(schema, arguments) do
        :ok -> validate_local_operator_argument_values(name, schema, arguments)
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => reason}}
      end
    end
  end

  defp validate_local_operator_argument_values(name, schema, arguments) do
    properties = Map.get(schema, "properties", %{})

    arguments
    |> Enum.find_value(:ok, fn {key, value} ->
      case validate_local_operator_argument_value(properties, key, value) do
        :ok -> nil
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => reason}}
      end
    end)
    |> case do
      :ok -> {:ok, arguments}
      error -> error
    end
  end

  defp validate_local_operator_argument_value(properties, key, value) do
    case Map.get(properties, key, %{}) do
      %{"type" => "string"} = property -> validate_local_operator_string_argument(key, value, property)
      _property -> :ok
    end
  end

  defp validate_local_operator_string_argument(key, value, property) when is_binary(value) do
    max_length = Map.get(property, "maxLength")

    if is_integer(max_length) and String.length(value) > max_length,
      do: {:error, "#{key}_too_long"},
      else: :ok
  end

  defp validate_local_operator_string_argument(key, _value, _property), do: {:error, "invalid_#{key}"}

  defp validate_architect_arguments(name, arguments) do
    allowed = MapSet.new(allowed_architect_argument_keys(name))
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected != [] do
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    else
      case validate_tool_required_arguments(architect_tool_input_schema(name), arguments) do
        :ok -> {:ok, arguments}
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => reason}}
      end
    end
  end

  defp validate_bootstrap_arguments(name, arguments) do
    allowed = MapSet.new(allowed_bootstrap_argument_keys(name))
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected != [] do
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    else
      validation_arguments = bootstrap_validation_arguments(name, arguments)

      case validate_tool_required_arguments(bootstrap_tool_input_schema(name), validation_arguments) do
        :ok -> {:ok, arguments}
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => reason}}
      end
    end
  end

  defp allowed_solo_argument_keys(name) do
    name
    |> solo_tool_input_schema()
    |> Map.get("properties", %{})
    |> Map.keys()
  end

  defp allowed_worker_argument_keys(name) do
    name
    |> worker_tool_input_schema()
    |> Map.get("properties", %{})
    |> Map.keys()
    |> Kernel.++(ToolCatalog.hidden_worker_argument_keys(name))
  end

  defp allowed_local_operator_argument_keys(name) do
    name
    |> local_operator_tool_input_schema()
    |> Map.get("properties", %{})
    |> Map.keys()
  end

  defp allowed_architect_argument_keys(name) do
    name
    |> architect_tool_input_schema()
    |> Map.get("properties", %{})
    |> Map.keys()
  end

  defp allowed_bootstrap_argument_keys(name) do
    name
    |> bootstrap_tool_input_schema()
    |> Map.get("properties", %{})
    |> Map.keys()
  end

  defp bootstrap_validation_arguments("create_work_request", arguments) do
    if blank_argument?(Map.get(arguments, "description")) and nonblank_argument?(Map.get(arguments, "human_description")) do
      Map.put(arguments, "description", Map.get(arguments, "human_description"))
    else
      arguments
    end
  end

  defp bootstrap_validation_arguments(_name, arguments), do: arguments

  defp blank_argument?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_argument?(nil), do: true
  defp blank_argument?(_value), do: false

  defp nonblank_argument?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank_argument?(_value), do: false

  defp validate_tool_required_arguments(schema, arguments) do
    properties = Map.get(schema, "properties", %{})

    schema
    |> Map.get("required", [])
    |> Enum.find_value(:ok, fn key ->
      case validate_required_architect_argument(arguments, properties, key) do
        :ok -> nil
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp validate_required_architect_argument(arguments, properties, key) do
    case Map.fetch(arguments, key) do
      :error -> {:error, "missing_#{key}"}
      {:ok, nil} -> {:error, "missing_#{key}"}
      {:ok, value} -> validate_required_architect_argument_value(properties, key, value)
    end
  end

  defp validate_required_architect_argument_value(properties, key, value) do
    case get_in(properties, [key, "type"]) do
      "string" -> validate_required_architect_string_argument(key, value)
      "object" -> validate_required_architect_object_argument(key, value)
      "array" -> validate_required_architect_array_argument_value(properties, key, value)
      _type -> {:error, "invalid_#{key}"}
    end
  end

  defp validate_required_architect_string_argument(key, value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, "missing_#{key}"}, else: :ok
  end

  defp validate_required_architect_string_argument(key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_architect_object_argument(_key, value) when is_map(value), do: :ok
  defp validate_required_architect_object_argument(key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_architect_array_argument_value(properties, key, values) when is_list(values) do
    validate_required_architect_array_argument(properties, key, values)
  end

  defp validate_required_architect_array_argument_value(_properties, key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_architect_array_argument(properties, key, values) do
    cond do
      properties |> Map.get(key, %{}) |> Map.get("minItems", 0) > 0 and values == [] ->
        {:error, "missing_#{key}"}

      get_in(properties, [key, "items", "type"]) == "string" ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")), do: :ok, else: {:error, "invalid_#{key}"}

      true ->
        if Enum.all?(values, &is_map/1), do: :ok, else: {:error, "invalid_#{key}"}
    end
  end

  defp required_string_array(arguments, key) do
    case Map.fetch(arguments, key) do
      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
          {:ok, Enum.map(values, &String.trim/1)}
        else
          {:tool_error, "invalid_#{key}"}
        end

      :error ->
        {:tool_error, "missing_#{key}"}

      {:ok, _values} ->
        {:tool_error, "invalid_#{key}"}
    end
  end

  defp required_argument(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "missing_#{key}"}
    end
  end

  defp required_object(arguments, key) do
    case Map.get(arguments, key) do
      value when is_map(value) -> {:ok, value}
      _value -> {:tool_error, "missing_#{key}"}
    end
  end

  defp optional_object_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp optional_list_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_list(value) -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp optional_decision_prompt_argument(arguments, key) do
    with {:ok, prompt} <- optional_object_argument(arguments, key) do
      case HumanDecisionPrompt.normalize(prompt) do
        {:ok, normalized} -> {:ok, normalized}
        {:error, reason} -> {:tool_error, "#{key} #{HumanDecisionPrompt.error_message(reason)}"}
      end
    end
  end

  defp required_integer(arguments, key) do
    case Map.get(arguments, key) do
      value when is_integer(value) -> {:ok, value}
      _value -> {:tool_error, "missing_#{key}"}
    end
  end

  defp required_list(arguments, key) do
    case Map.get(arguments, key) do
      [_head | _tail] = value -> {:ok, value}
      nil -> {:tool_error, "missing_#{key}"}
      [] -> {:tool_error, "missing_#{key}"}
      _value -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp required_string_list(arguments, key) do
    with {:ok, values} <- required_list(arguments, key) do
      if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
        {:ok, Enum.map(values, &String.trim/1)}
      else
        {:tool_error, "invalid_#{key}"}
      end
    end
  end

  defp required_review_list(arguments, key) do
    with {:ok, values} <- required_list(arguments, key) do
      reviews = normalize_review_entries(values)

      if length(reviews) == length(values) and unique_review_lanes?(reviews) do
        {:ok, reviews}
      else
        {:tool_error, "invalid_#{key}"}
      end
    end
  end

  defp unique_review_lanes?(reviews) do
    lanes =
      Enum.map(reviews, fn %{"lane" => lane} ->
        lane
      end)

    Enum.uniq(lanes) == lanes
  end

  defp optional_review_list(arguments, key) do
    case Map.get(arguments, key) do
      nil -> {:ok, []}
      [] -> {:ok, []}
      _reviews -> required_review_list(arguments, key)
    end
  end

  defp optional_boolean(arguments, key, default) do
    case Map.fetch(arguments, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
      :error -> {:ok, default}
    end
  end

  defp optional_argument(arguments, key, default) do
    case Map.get(arguments, key, default) do
      value when is_binary(value) -> if String.trim(value) == "", do: default, else: value
      nil -> default
      value -> value
    end
  end

  defp optional_blocker_id(arguments) do
    default = Map.get(arguments, "idempotency_key")

    case Map.get(arguments, "blocker_id") do
      value when is_binary(value) -> {:ok, if(String.trim(value) == "", do: normalize_blocker_id(default), else: String.trim(value))}
      nil -> {:ok, normalize_blocker_id(default)}
      _value -> {:error, :invalid_blocker_id}
    end
  end

  defp normalize_blocker_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_blocker_id(value), do: value

  defp optional_payload(arguments) do
    case Map.get(arguments, "payload", %{}) do
      payload when is_map(payload) -> {:ok, payload}
      _payload -> {:tool_error, "invalid_payload"}
    end
  end

  defp merge_tool_payload("append_progress", caller_payload, tool_payload) do
    caller_payload
    |> drop_protected_append_progress_payload()
    |> Map.merge(tool_payload)
  end

  defp merge_tool_payload("attach_review_suite_result", _caller_payload, tool_payload), do: tool_payload

  defp merge_tool_payload(_tool, caller_payload, tool_payload) when tool_payload == %{} do
    Map.drop(caller_payload, ["source_tool"])
  end

  defp merge_tool_payload(_tool, caller_payload, %{"type" => "scope_expansion_request", "source_tool" => "request_scope_expansion"} = tool_payload) do
    caller_payload
    |> Map.drop(["source_tool", "recommendation_artifact_id"])
    |> Map.merge(tool_payload)
  end

  defp merge_tool_payload(_tool, caller_payload, tool_payload), do: Map.merge(caller_payload, tool_payload)

  defp drop_protected_append_progress_payload(%{"type" => type} = caller_payload) when type in ["scope_expansion_request", "scope_expansion_approval"] do
    Map.drop(caller_payload, [
      "type",
      "source_tool",
      "recommendation_artifact_id",
      "approved",
      "requested_file_globs",
      "approved_file_globs",
      "allowed_file_globs",
      "previous_allowed_file_globs",
      "request_id"
    ])
  end

  defp drop_protected_append_progress_payload(caller_payload) do
    Map.drop(caller_payload, [
      "source_tool",
      "recommendation_artifact_id",
      "approved",
      "requested_file_globs",
      "approved_file_globs",
      "allowed_file_globs",
      "previous_allowed_file_globs",
      "request_id"
    ])
  end

  defp maybe_put_id(attrs, arguments) do
    case Map.get(arguments, "id") do
      id when is_binary(id) ->
        case String.trim(id) do
          "" -> attrs
          trimmed -> Map.put(attrs, "id", trimmed)
        end

      _id ->
        attrs
    end
  end

  defp metadata_idempotency_key(payload), do: "mcp:" <> Map.get(payload, "type", "metadata") <> ":" <> Base.url_encode64(:erlang.term_to_binary(payload), padding: false)

  defp actor(%Session{} = session) do
    %{
      grant_id: session.assignment.grant_id,
      grant_role: session.assignment.grant_role,
      capabilities: session.assignment.capabilities,
      work_package_id: session.assignment.work_package_id
    }
  end

  defp work_request_cards(work_requests) do
    Enum.map(work_requests, &work_request_card_payload/1)
  end

  defp work_request_card_payload(%WorkRequest{} = work_request) do
    scope = redacted_work_request_scope(work_request)

    %{
      "id" => work_request.id,
      "title" => Redactor.redact_text(work_request.title),
      "repo" => Map.fetch!(scope, "repo"),
      "base_branch" => Map.fetch!(scope, "base_branch"),
      "work_type" => work_request.work_type,
      "desired_dispatch_shape" => work_request.desired_dispatch_shape,
      "creator" => work_request_creator_payload(work_request),
      "status" => work_request.status,
      "inserted_at" => timestamp(work_request.inserted_at),
      "updated_at" => timestamp(work_request.updated_at)
    }
  end

  defp guidance_request_cards(guidance_requests) do
    Enum.map(guidance_requests, &guidance_request_card_payload/1)
  end

  defp comment_payload(%Comment{} = comment) do
    %{
      "id" => comment.id,
      "target_kind" => comment.target_kind,
      "target_id" => comment.target_id,
      "body" => Redactor.redact_text(comment.body),
      "source_type" => comment.source_type,
      "author_name" => Redactor.redact_text(comment.author_name),
      "status" => comment.status,
      "resolved_by" => Redactor.redact_text(comment.resolved_by),
      "resolved_source_type" => comment.resolved_source_type,
      "resolved_at" => timestamp(comment.resolved_at),
      "resolution_note" => Redactor.redact_text(comment.resolution_note),
      "inserted_at" => timestamp(comment.inserted_at),
      "updated_at" => timestamp(comment.updated_at)
    }
  end

  defp guidance_request_card_payload(%GuidanceRequest{} = guidance_request) do
    %{
      "id" => guidance_request.id,
      "work_package_id" => guidance_request.work_package_id,
      "summary" => Redactor.redact_text(guidance_request.summary),
      "status" => guidance_request.status,
      "requested_by" => guidance_request.requested_by,
      "answered_by" => guidance_request.answered_by,
      "blocker_id" => guidance_request.blocker_id,
      "inserted_at" => timestamp(guidance_request.inserted_at),
      "updated_at" => timestamp(guidance_request.updated_at)
    }
  end

  defp guidance_request_payload(%GuidanceRequest{} = guidance_request) do
    %{
      "id" => guidance_request.id,
      "work_package_id" => guidance_request.work_package_id,
      "summary" => Redactor.redact_text(guidance_request.summary),
      "question" => Redactor.redact_text(guidance_request.question),
      "context" => Redactor.redact_text(guidance_request.context),
      "status" => guidance_request.status,
      "requested_by" => guidance_request.requested_by,
      "answer" => Redactor.redact_text(guidance_request.answer),
      "answered_by" => guidance_request.answered_by,
      "answered_at" => timestamp(guidance_request.answered_at),
      "human_info_reason" => Redactor.redact_text(guidance_request.human_info_reason),
      "recommended_language" => Redactor.redact_text(guidance_request.recommended_language),
      "decision_prompt" => Redactor.redact_output(guidance_request.decision_prompt),
      "blocker_id" => guidance_request.blocker_id,
      "inserted_at" => timestamp(guidance_request.inserted_at),
      "updated_at" => timestamp(guidance_request.updated_at)
    }
  end

  defp work_request_detail_payload(repo, %WorkRequest{} = work_request, _opts) do
    with {:ok, questions} <- WorkRequestService.list_questions(repo, work_request.id),
         {:ok, decisions} <- WorkRequestService.list_decisions(repo, work_request.id),
         {:ok, planned_slices} <- WorkRequestService.list_planned_slices(repo, work_request.id),
         {:ok, slice_visibility} <- DeliveryBoard.planned_slice_visibility(repo, work_request.id, planned_slices) do
      visible_planned_slices = Map.fetch!(slice_visibility, :visible_planned_slices)

      {:ok,
       %{
         "work_request" => work_request_payload(work_request),
         "clarification_questions" => Enum.map(questions, &clarification_question_payload/1),
         "decision_log_entries" => Enum.map(decisions, &decision_log_entry_payload/1),
         "planned_slices" => Enum.map(visible_planned_slices, &planned_slice_payload/1),
         "summary" => work_request_summary_payload(questions, decisions, visible_planned_slices)
       }}
    end
  end

  defp work_request_product_tree_payload(repo, %WorkRequest{} = work_request, filters, opts) do
    view = Keyword.fetch!(opts, :view)

    with {:ok, planned_slices} <- WorkRequestService.list_planned_slices(repo, work_request.id),
         {:ok, delivery_board} <-
           scoped_delivery_board(repo, work_request, planned_slices, filters, slice_projection: :operational_state) do
      projection_slice_payloads = delivery_board |> Map.fetch!(:slices) |> json_safe_payload()
      visible_planned_slices = visible_planned_slices_from_projection(planned_slices, projection_slice_payloads)
      slice_payloads = product_tree_slice_payloads(visible_planned_slices, projection_slice_payloads)

      product_tree =
        repo
        |> ProductTree.project(work_request.id, projection_slice_payloads, product_tree_projection_opts())
        |> json_safe_payload()
        |> product_tree_view_payload(slice_payloads, view)

      {:ok,
       %{
         "work_request" => work_request_payload(work_request),
         "product_tree" => product_tree,
         "view" => view
       }}
    end
  end

  defp visible_planned_slices_from_projection(planned_slices, projection_slice_payloads) do
    visible_slice_ids =
      projection_slice_payloads
      |> Enum.map(&map_get(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.filter(planned_slices, &MapSet.member?(visible_slice_ids, &1.id))
  end

  defp product_tree_view_payload(product_tree, _slice_payloads, "nodes_only") do
    product_tree
    |> Map.put("nodes", product_tree |> Map.get("nodes", []) |> Enum.map(&product_tree_node_only_payload/1))
    |> Map.put("root_slice_ids", [])
    |> Map.put("dependency_edges", product_tree |> Map.get("dependency_edges", []) |> Enum.filter(&product_tree_node_dependency?/1))
    |> Map.update("summary", %{"root_slice_count" => 0}, &Map.put(&1, "root_slice_count", 0))
    |> Map.put("omitted_slice_count", product_tree |> Map.get("summary", %{}) |> Map.get("slice_count", 0))
  end

  defp product_tree_view_payload(product_tree, slice_payloads, "nodes_with_slices") do
    Map.put(product_tree, "slices", slice_payloads)
  end

  defp product_tree_view_payload(product_tree, slice_payloads, "nodes_with_slice_refs") do
    Map.put(product_tree, "slice_refs", Enum.map(slice_payloads, &product_tree_slice_ref_payload/1))
  end

  defp product_tree_slice_payloads(visible_planned_slices, projection_slice_payloads) do
    projection_slice_payloads_by_id = Map.new(projection_slice_payloads, &{map_get(&1, :id), &1})

    Enum.map(visible_planned_slices, fn %PlannedSlice{} = planned_slice ->
      planned_slice
      |> planned_slice_payload()
      |> Map.merge(product_tree_operational_slice_fields(Map.get(projection_slice_payloads_by_id, planned_slice.id, %{})))
    end)
  end

  defp product_tree_projection_opts, do: [visible_only?: true, include_unlinked_nodes?: true]

  defp product_tree_operational_slice_fields(projection_slice_payload) when is_map(projection_slice_payload) do
    projection_slice_payload
    |> Map.take(["raw_status", "delivery_outcome", "operational_state", "attention_reason_codes"])
    |> Map.put("status", map_get(projection_slice_payload, :raw_status))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp product_tree_node_only_payload(node) when is_map(node) do
    Map.drop(node, ["slice_ids", "attention_count", "guidance_count", "blocker_count"])
  end

  defp product_tree_node_dependency?(%{"source_kind" => "product_node", "target_kind" => "product_node"}), do: true
  defp product_tree_node_dependency?(_edge), do: false

  defp product_tree_slice_ref_payload(slice) when is_map(slice) do
    slice
    |> Map.take(["id", "sequence", "title", "status", "work_package_id"])
    |> Map.merge(product_tree_operational_slice_fields(slice))
    |> Map.put("has_full_payload", false)
  end

  defp work_request_payload(%WorkRequest{} = work_request) do
    scope = redacted_work_request_scope(work_request)

    %{
      "id" => work_request.id,
      "title" => Redactor.redact_text(work_request.title),
      "repo" => Map.fetch!(scope, "repo"),
      "base_branch" => Map.fetch!(scope, "base_branch"),
      "work_type" => work_request.work_type,
      "human_description" => Redactor.redact_text(work_request.human_description),
      "constraints" => Redactor.redact_output(work_request.constraints || %{}),
      "desired_dispatch_shape" => work_request.desired_dispatch_shape,
      "creator" => work_request_creator_payload(work_request),
      "status" => work_request.status,
      "inserted_at" => timestamp(work_request.inserted_at),
      "updated_at" => timestamp(work_request.updated_at)
    }
  end

  defp work_request_creator_payload(%WorkRequest{} = work_request) do
    %{
      "kind" => work_request.creator_kind,
      "name" => Redactor.redact_text(work_request.creator_name),
      "via" => work_request.created_via
    }
  end

  defp redacted_work_request_scope(%WorkRequest{} = work_request) do
    %{
      "repo" => Redactor.redact_text(work_request.repo),
      "base_branch" => Redactor.redact_text(work_request.base_branch)
    }
  end

  defp work_request_mutation_payload(%WorkRequest{} = work_request) do
    %{
      "id" => work_request.id,
      "status" => work_request.status,
      "updated_at" => timestamp(work_request.updated_at)
    }
  end

  defp clarification_question_payload(%ClarificationQuestion{} = question) do
    %{
      "id" => question.id,
      "work_request_id" => question.work_request_id,
      "sequence" => question.sequence,
      "category" => Redactor.redact_text(question.category),
      "question" => Redactor.redact_text(question.question),
      "why_needed" => Redactor.redact_text(question.why_needed),
      "decision_prompt" => Redactor.redact_output(question.decision_prompt),
      "status" => question.status,
      "asked_by_agent_run_id" => Redactor.redact_text(question.asked_by_agent_run_id),
      "answer" => Redactor.redact_text(question.answer),
      "answered_by" => Redactor.redact_text(question.answered_by),
      "answered_at" => timestamp(question.answered_at),
      "inserted_at" => timestamp(question.inserted_at),
      "updated_at" => timestamp(question.updated_at)
    }
  end

  defp decision_log_entry_payload(%DecisionLogEntry{} = decision) do
    %{
      "id" => decision.id,
      "work_request_id" => decision.work_request_id,
      "sequence" => decision.sequence,
      "source_type" => Redactor.redact_text(decision.source_type),
      "source_id" => Redactor.redact_text(decision.source_id),
      "decision" => Redactor.redact_text(decision.decision),
      "rationale" => Redactor.redact_text(decision.rationale),
      "scope_impact" => Redactor.redact_text(decision.scope_impact),
      "created_by" => Redactor.redact_text(decision.created_by),
      "created_at" => timestamp(decision.created_at),
      "inserted_at" => timestamp(decision.inserted_at),
      "updated_at" => timestamp(decision.updated_at)
    }
  end

  defp planned_slice_payload(%PlannedSlice{} = planned_slice) do
    %{
      "id" => planned_slice.id,
      "work_request_id" => planned_slice.work_request_id,
      "sequence" => planned_slice.sequence,
      "title" => Redactor.redact_text(planned_slice.title),
      "goal" => Redactor.redact_text(planned_slice.goal),
      "work_package_kind" => planned_slice.work_package_kind,
      "delivery_repo" => Redactor.redact_text(planned_slice.delivery_repo),
      "target_base_branch" => Redactor.redact_text(planned_slice.target_base_branch),
      "branch_pattern" => Redactor.redact_text(planned_slice.branch_pattern),
      "owned_file_globs" => Enum.map(planned_slice.owned_file_globs || [], &Redactor.redact_text/1),
      "forbidden_file_globs" => Enum.map(planned_slice.forbidden_file_globs || [], &Redactor.redact_text/1),
      "acceptance_criteria" => Enum.map(planned_slice.acceptance_criteria || [], &Redactor.redact_text/1),
      "validation_steps" => Enum.map(planned_slice.validation_steps || [], &Redactor.redact_text/1),
      "review_lanes" => Enum.map(planned_slice.review_lanes || [], &Redactor.redact_text/1),
      "stop_conditions" => Enum.map(planned_slice.stop_conditions || [], &Redactor.redact_text/1),
      "status" => planned_slice.status,
      "work_package_id" => planned_slice.work_package_id,
      "dispatched_at" => timestamp(planned_slice.dispatched_at),
      "inserted_at" => timestamp(planned_slice.inserted_at),
      "updated_at" => timestamp(planned_slice.updated_at)
    }
  end

  defp product_tree_node_payload(%Node{} = node) do
    %{
      "id" => node.id,
      "work_request_id" => node.work_request_id,
      "parent_id" => node.parent_id,
      "title" => Redactor.redact_text(node.title),
      "description" => Redactor.redact_text(node.description),
      "node_kind" => Redactor.redact_text(node.node_kind),
      "completion_mark" => node.completion_mark,
      "position" => node.position,
      "created_by" => Redactor.redact_text(node.created_by),
      "created_at" => timestamp(node.created_at),
      "inserted_at" => timestamp(node.inserted_at),
      "updated_at" => timestamp(node.updated_at)
    }
  end

  defp product_tree_slice_link_payload(nil), do: nil

  defp product_tree_slice_link_payload(%SliceLink{} = slice_link) do
    %{
      "id" => slice_link.id,
      "work_request_id" => slice_link.work_request_id,
      "product_tree_node_id" => slice_link.product_tree_node_id,
      "planned_slice_id" => slice_link.planned_slice_id,
      "role" => slice_link.role,
      "position" => slice_link.position,
      "created_by" => Redactor.redact_text(slice_link.created_by),
      "created_at" => timestamp(slice_link.created_at),
      "inserted_at" => timestamp(slice_link.inserted_at),
      "updated_at" => timestamp(slice_link.updated_at)
    }
  end

  defp mutate_product_tree(repo, work_request_id, tool, created_by, mutation_fun) do
    run_architect_transaction(repo, fn ->
      with {:ok, result} <- mutation_fun.(),
           {:ok, _revision} <- record_current_product_tree_revision(repo, work_request_id, tool, created_by) do
        {:ok, result}
      end
    end)
  end

  defp mutate_product_tree_with_projection(repo, work_request_id, tool, created_by, mutation_fun) do
    run_architect_transaction(repo, fn ->
      with {:ok, result} <- mutation_fun.(),
           {:ok, _revision} <- record_current_product_tree_revision(repo, work_request_id, tool, created_by),
           {:ok, detail} <- Dashboard.work_request_detail(repo, work_request_id) do
        {:ok, {result, detail}}
      end
    end)
  end

  defp record_current_product_tree_revision(repo, work_request_id, tool, created_by) do
    case Dashboard.work_request_detail(repo, work_request_id) do
      {:ok, detail} ->
        record_product_tree_revision(repo, work_request_id, tool, created_by, detail)

      {:error, reason} = error ->
        if missing_product_tree_schema_error?(reason), do: {:ok, nil}, else: error
    end
  end

  defp record_product_tree_revision(repo, work_request_id, tool, created_by, detail) do
    snapshot = product_tree_revision_snapshot(detail.product_tree)
    tree = ProductTree.tree_for_work_request(repo, work_request_id)

    if match?({:ok, %{latest_revision: %{tree_snapshot: ^snapshot}}}, tree) do
      {:ok, nil}
    else
      insert_product_tree_revision(repo, work_request_id, tool, created_by, snapshot)
    end
  end

  defp insert_product_tree_revision(repo, work_request_id, tool, created_by, snapshot) do
    case ProductTree.record_revision(repo, work_request_id, %{
           "reason" => product_tree_revision_reason(tool),
           "created_by" => created_by,
           "tree_snapshot" => snapshot
         }) do
      {:error, reason} = error ->
        if missing_product_tree_schema_error?(reason), do: {:ok, nil}, else: error

      result ->
        result
    end
  end

  defp missing_product_tree_schema_error?({:storage_failed, message}) when is_binary(message) do
    message
    |> String.downcase()
    |> String.contains?("no such table: sympp_product_tree_")
  end

  defp missing_product_tree_schema_error?(_reason), do: false

  defp product_tree_revision_snapshot(product_tree) do
    product_tree
    |> json_safe_payload()
    |> Map.delete("latest_revision")
  end

  defp product_tree_revision_reason("add_work_request_planned_slice"), do: "Planned slice added to product tree through MCP."
  defp product_tree_revision_reason("upsert_work_request_product_plan_node_content"), do: "Product plan node content changed through MCP."
  defp product_tree_revision_reason("move_work_request_product_plan_node"), do: "Product plan node rearranged through MCP."
  defp product_tree_revision_reason("set_work_request_product_plan_node_completion"), do: "Product plan node completion changed through MCP."
  defp product_tree_revision_reason("move_work_request_planned_slice_to_product_node"), do: "Planned slice rearranged in product tree through MCP."
  defp product_tree_revision_reason("approve_work_request_planned_slice"), do: "Planned slice approved in product tree through MCP."
  defp product_tree_revision_reason("skip_work_request_planned_slice"), do: "Planned slice skipped in product tree through MCP."
  defp product_tree_revision_reason("record_planned_slice_delivery"), do: "Planned slice delivery recorded in product tree through MCP."
  defp product_tree_revision_reason("reconcile_work_request"), do: "Planned slice delivery reconciled in product tree through MCP."

  defp planned_slice_delivery_payload(%PlannedSliceDelivery{} = delivery) do
    %{
      "id" => delivery.id,
      "work_request_id" => delivery.work_request_id,
      "planned_slice_id" => delivery.planned_slice_id,
      "outcome" => delivery.outcome,
      "idempotency_key" => Redactor.redact_text(delivery.idempotency_key),
      "recorded_by" => Redactor.redact_text(delivery.recorded_by),
      "recorded_at" => timestamp(delivery.recorded_at),
      "pr_url" => Redactor.redact_text(delivery.pr_url),
      "pr_number" => delivery.pr_number,
      "pr_repository" => Redactor.redact_text(delivery.pr_repository),
      "pr_merged_at" => timestamp(delivery.pr_merged_at),
      "merge_commit_sha" => Redactor.redact_text(delivery.merge_commit_sha),
      "no_pr_evidence" => Redactor.redact_text(delivery.no_pr_evidence),
      "successor_planned_slice_id" => delivery.successor_planned_slice_id,
      "successor_work_package_id" => delivery.successor_work_package_id,
      "superseded_reason" => Redactor.redact_text(delivery.superseded_reason),
      "abandoned_rationale" => Redactor.redact_text(delivery.abandoned_rationale),
      "inserted_at" => timestamp(delivery.inserted_at),
      "updated_at" => timestamp(delivery.updated_at)
    }
  end

  defp delivery_board_payload(delivery_board) do
    delivery_board
    |> json_safe_payload()
    |> Redactor.redact_output()
  end

  defp reconciliation_payload(reconciliation) when is_map(reconciliation) do
    reconciliation
    |> Map.drop([:delivery_board, "delivery_board"])
    |> json_safe_payload()
    |> Redactor.redact_output()
  end

  defp dispatch_work_request_planned_slice_payload(
         %{
           work_request: %WorkRequest{} = work_request,
           planned_slice: %PlannedSlice{} = planned_slice,
           creation: creation
         } = dispatch,
         scope
       ) do
    worker_bootstrap =
      dispatch_or_creation_value(dispatch, creation, :worker_bootstrap)
      |> dispatch_worker_bootstrap_payload()

    %{
      "coordinates" => worker_bootstrap && Map.get(worker_bootstrap, "coordinates"),
      "work_request" => %{"id" => work_request.id},
      "planned_slice" => %{
        "id" => planned_slice.id,
        "status" => planned_slice.status,
        "work_package_id" => planned_slice.work_package_id,
        "dispatched_at" => timestamp(planned_slice.dispatched_at)
      },
      "work_package" => dispatch_work_package_payload(Map.fetch!(creation, :work_package)),
      "worker_bootstrap" => worker_bootstrap,
      "worker_grant" => dispatch_worker_grant_payload(Map.fetch!(creation, :worker_grant)),
      "scope" => scope,
      "status" => %{"planned_slice_status" => planned_slice.status}
    }
  end

  defp dispatch_or_creation_value(dispatch, creation, key) when is_atom(key) do
    Map.get(dispatch, key) || map_get(creation, key)
  end

  defp dispatch_work_package_payload(%WorkPackage{} = work_package) do
    work_package
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> json_safe_payload()
    |> Redactor.redact_output()
  end

  defp dispatch_work_package_payload(work_package) when is_map(work_package) do
    work_package
    |> json_safe_payload()
    |> Redactor.redact_output()
  end

  defp map_get(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp map_get(_value, _key), do: nil

  defp dispatch_worker_grant_payload(worker_grant) when is_map(worker_grant) do
    worker_grant
    |> json_safe_payload()
    |> Map.drop(["display_key", "secret", "secret_hash", "secret_handoff", "secret_returned_once", "worker_secret_handoff"])
    |> Map.put("secret_in_response", false)
  end

  defp dispatch_worker_bootstrap_payload(nil), do: nil

  defp dispatch_worker_bootstrap_payload(bootstrap) when is_map(bootstrap) do
    bootstrap
    |> json_safe_payload()
    |> Redactor.redact_output()
  end

  defp dispatch_link_recovery_payload(recovery) when is_map(recovery) do
    %{}
    |> put_optional_recovery_value("work_package_id", recovery_value(recovery, :work_package_id))
    |> put_optional_recovery_value("worker_grant_id", recovery_value(recovery, :worker_grant_id))
    |> put_optional_recovery_value("cleanup", safe_recovery_value(recovery_value(recovery, :cleanup)))
  end

  defp recovery_value(recovery, key) do
    Map.get(recovery, key) || Map.get(recovery, to_string(key))
  end

  defp put_optional_recovery_value(payload, _key, nil), do: payload
  defp put_optional_recovery_value(payload, key, value), do: Map.put(payload, key, value)

  defp safe_recovery_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, map_value} -> {to_string(key), safe_recovery_value(map_value)} end)
    |> Map.new()
  end

  defp safe_recovery_value(value) when is_list(value), do: Enum.map(value, &safe_recovery_value/1)
  defp safe_recovery_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_recovery_value(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp safe_recovery_value(value), do: inspect(value)

  defp work_request_summary_payload(questions, decisions, planned_slices) do
    %{
      "open_question_count" => Enum.count(questions, &(&1.status == "open")),
      "answered_question_count" => Enum.count(questions, &(&1.status == "answered")),
      "closed_question_count" => Enum.count(questions, &(&1.status == "closed")),
      "decision_count" => length(decisions),
      "planned_slice_count" => Enum.count(planned_slices, &(&1.status == "planned")),
      "approved_slice_count" => Enum.count(planned_slices, &(&1.status == "approved")),
      "dispatched_slice_count" => Enum.count(planned_slices, &(&1.status == "dispatched")),
      "skipped_slice_count" => Enum.count(planned_slices, &(&1.status == "skipped"))
    }
  end

  @doc false
  @spec mcp_timestamp(DateTime.t() | NaiveDateTime.t() | nil) :: String.t() | nil
  def mcp_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  def mcp_timestamp(%NaiveDateTime{} = timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  def mcp_timestamp(nil), do: nil

  defp timestamp(timestamp), do: mcp_timestamp(timestamp)

  defp not_found_error(tool) do
    {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}
  end

  defp tool_result(payload) do
    payload = compact_tool_payload(payload)

    %{
      "content" => [%{"type" => "text", "text" => WorkerContext.encode_tool_payload(payload)}],
      "structuredContent" => payload,
      "isError" => false
    }
  end

  defp claim_tool_result(payload), do: agent_tool_result(payload, ClaimToolText.claim(payload))
  defp release_tool_result(payload), do: agent_tool_result(payload, ClaimToolText.release(payload))

  defp require_current_session_claim_for_bound_call(%__MODULE__{} = server, method, params) do
    if bound_session_call?(server, method, params) do
      require_current_session_claim(server)
    else
      {:ok, server}
    end
  end

  defp bound_session_call?(%__MODULE__{session: %Session{claim_lease_id: claim_lease_id}}, "tools/call", %{"name" => name})
       when name in @worker_tools or name in @architect_tools,
       do: is_binary(claim_lease_id)

  defp bound_session_call?(%__MODULE__{session: %Session{claim_lease_id: claim_lease_id}}, "resources/read", %{"uri" => "sympp://assignment/current"}),
    do: is_binary(claim_lease_id)

  defp bound_session_call?(%__MODULE__{session: %Session{claim_lease_id: claim_lease_id}}, "resources/read", %{"uri" => "sympp://work-packages/" <> _path}),
    do: is_binary(claim_lease_id)

  defp bound_session_call?(%__MODULE__{}, _method, _params), do: false

  defp require_current_session_claim(%__MODULE__{config: %Config{repo: repo}, session: %Session{} = session} = server) do
    case {Auth.require_live_session_grant(session, repo), current_matching_claim_lease(repo, session)} do
      {:ok, {:ok, %ClaimLease{status: "active"} = lease}} -> refresh_current_session_claim_lease(repo, server, lease)
      {:ok, {:ok, %ClaimLease{status: "paused"}}} -> lost_current_session_claim(server, :claim_lease_paused)
      {:ok, {:ok, %ClaimLease{}}} -> lost_current_session_claim(server, :claim_lease_not_active)
      {:ok, {:error, reason}} -> lost_current_session_claim(server, reason)
      {{:error, reason}, _claim_lease} -> lost_current_session_claim(server, reason)
    end
  rescue
    _error -> lost_current_session_claim(server, :claim_lease_check_failed)
  end

  defp refresh_current_session_claim_lease(repo, %__MODULE__{session: %Session{} = session} = server, %ClaimLease{} = lease) do
    case ClaimLeaseService.heartbeat(repo, lease.id, stale_after_ms: @local_assignment_claim_stale_after_ms) do
      {:ok, %ClaimLease{} = renewed} ->
        {:ok, %{server | session: Session.with_claim_lease(session, renewed)}}

      {:error, :claim_stale} ->
        reclaim_current_session_claim_lease(repo, server, session, lease)

      {:error, reason} ->
        lost_current_session_claim(server, reason)
    end
  end

  defp reclaim_current_session_claim_lease(repo, %__MODULE__{} = server, %Session{} = session, %ClaimLease{} = lease) do
    actor = %{
      "actor_kind" => session.claim_actor_kind,
      "actor_id" => session.claim_actor_id,
      "actor_display_name" => session.claim_actor_display_name
    }

    opts = LocalClaimLeases.reclaim_opts("mcp_session_tool_heartbeat_stale", @local_assignment_claim_stale_after_ms)

    case ClaimLeaseService.reclaim_stale(repo, lease.work_package_id, actor, opts) do
      {:ok, %ClaimLease{} = replacement} -> {:ok, %{server | session: Session.with_claim_lease(session, replacement)}}
      {:error, reason} -> lost_current_session_claim(server, reason)
    end
  end

  defp lost_current_session_claim(%__MODULE__{session: %Session{} = session} = server, reason) do
    action =
      case session.assignment.grant_role do
        "architect" -> @local_architect_assignment_claim_tool
        _role -> @local_assignment_claim_tool
      end

    updated_server = %{server | session: nil, session_refresh_required: true}

    {:error, -32_001, "Unauthorized",
     %{
       "reason" => if(Auth.live_grant_loss_reason?(reason), do: reason_text(reason), else: "claim_lease_lost"),
       "claim_lease_reason" => reason_text(reason),
       "action" => action
     }, updated_server}
  end

  defp agent_tool_result(payload) do
    agent_tool_result(payload, WorkerContext.encode_tool_payload(payload))
  end

  defp agent_tool_result(payload, agent_text) when is_binary(agent_text) do
    %{
      "content" => [%{"type" => "text", "text" => agent_text}],
      "structuredContent" => payload,
      "isError" => false
    }
  end

  defp architect_agent_tool_result(payload, kind) do
    agent_tool_result(payload, ArchitectContext.encode_tool_payload(payload, kind))
  end

  defp compact_tool_payload(%{} = payload) do
    payload
    |> compact_tool_payload_entries()
    |> put_next_action()
  end

  defp compact_tool_payload(payload), do: payload

  defp compact_tool_payload_entries(%{} = payload) do
    payload
    |> Map.drop(["product_tree", :product_tree])
    |> Enum.map(fn {key, value} -> compact_tool_entry(to_string(key), key, value) end)
    |> Map.new()
  end

  defp compact_tool_entry("work_request", key, value), do: {key, compact_status_payload(value, ["id", "status", "updated_at"])}

  defp compact_tool_entry("planned_slice", key, value),
    do:
      {key,
       compact_status_payload(value, [
         "id",
         "work_request_id",
         "status",
         "work_package_id",
         "delivery_repo",
         "target_base_branch",
         "dispatched_at",
         "updated_at"
       ])}

  defp compact_tool_entry("work_package", key, value),
    do:
      {key,
       compact_status_payload(value, [
         "id",
         "kind",
         "status",
         "repo",
         "base_branch",
         "phase_id",
         "parent_id",
         "title",
         "branch_pattern",
         "worktree_path",
         "inserted_at",
         "updated_at"
       ])}

  defp compact_tool_entry("progress_event", key, value),
    do: {key, compact_status_payload(value, ["id", "status", "summary", "idempotency_key", "payload"])}

  defp compact_tool_entry("guidance_request", key, value),
    do:
      {key,
       compact_status_payload(value, [
         "id",
         "work_package_id",
         "summary",
         "question",
         "context",
         "status",
         "requested_by",
         "answer",
         "answered_by",
         "human_info_reason",
         "recommended_language",
         "decision_prompt",
         "blocker_id"
       ])}

  defp compact_tool_entry("clarification_question", key, value),
    do: {key, compact_status_payload(value, ["id", "status", "sequence"])}

  defp compact_tool_entry("decision_log_entry", key, value),
    do: {key, compact_status_payload(value, ["id", "sequence", "source_type", "source_id", "decision", "rationale", "scope_impact", "created_by"])}

  defp compact_tool_entry("product_plan_node", key, value),
    do: {key, compact_status_payload(value, ["id", "work_request_id", "parent_id", "position", "completion_mark"])}

  defp compact_tool_entry("product_tree_slice_link", key, value),
    do: {key, compact_status_payload(value, ["id", "work_request_id", "planned_slice_id", "product_tree_node_id", "position"])}

  defp compact_tool_entry("planned_slice_delivery", key, value),
    do: {key, compact_status_payload(value, ["id", "work_request_id", "planned_slice_id", "outcome", "recorded_by", "pr_url", "successor_planned_slice_id"])}

  defp compact_tool_entry("delivery_board", key, value), do: {key, compact_status_payload(value, ["counts"])}

  defp compact_tool_entry("audit_event", key, value),
    do: {key, compact_status_payload(value, ["id", "status", "summary", "idempotency_key"])}

  defp compact_tool_entry("reconciliation", key, value) when is_map(value),
    do:
      {key,
       compact_status_payload(value, [
         "mode",
         "applied?",
         "changed?",
         "proposed_count",
         "applied_count",
         "recorded_delivery_count",
         "missing_delivery_count",
         "results"
       ])}

  defp compact_tool_entry("runtime_cleanup", key, value) when is_map(value),
    do:
      {key,
       compact_status_payload(value, [
         "status",
         "reason",
         "reason_code",
         "work_package_id",
         "revoked_worker_grant_ids",
         "released_claim_lease_ids",
         "cleared_session_binding_ids",
         "cleared_mcp_session_binding_ids",
         "reason_codes"
       ])}

  defp compact_tool_entry("worker_bootstrap", key, value) when is_map(value),
    do:
      {key,
       compact_status_payload(value, [
         "type",
         "mode",
         "work_package_id",
         "branch",
         "worktree_path",
         "coordinates",
         "claim",
         "ledger",
         "required_runtime_arguments",
         "arguments",
         "preferred_skill_set",
         "supported_skill_sets",
         "required_skills",
         "launch_prompt",
         "prompt"
       ])}

  defp compact_tool_entry("worker_grant", key, value),
    do:
      {key,
       compact_status_payload(value, [
         "id",
         "grant_role",
         "work_package_id",
         "capabilities",
         "expires_at",
         "secret_in_response",
         "worker_bootstrap"
       ])}

  defp compact_tool_entry(_name, key, value), do: {key, compact_tool_value(value)}

  defp compact_tool_value(%{} = value), do: compact_tool_payload_entries(value)
  defp compact_tool_value(values) when is_list(values), do: Enum.map(values, &compact_tool_value/1)
  defp compact_tool_value(value), do: value

  defp compact_status_payload(%{} = value, keys) do
    value
    |> json_safe_payload()
    |> Map.take(keys)
    |> drop_nil_values()
  end

  defp compact_status_payload(value, _keys), do: value

  defp put_next_action(%{} = payload) do
    Map.put_new_lazy(payload, "next_action", fn -> next_action(payload) end)
  end

  defp next_action(%{"status" => %{} = status}) do
    cond do
      present?(Map.get(status, "current_status")) -> Map.get(status, "current_status")
      present?(Map.get(status, "work_request_status")) -> Map.get(status, "work_request_status")
      present?(Map.get(status, "planned_slice_status")) -> Map.get(status, "planned_slice_status")
      present?(Map.get(status, "guidance_request_status")) -> Map.get(status, "guidance_request_status")
      true -> "inspect_status"
    end
  end

  defp next_action(%{"planned_slice_delivery" => %{"outcome" => outcome}}) when is_binary(outcome), do: outcome
  defp next_action(%{"work_package" => %{"status" => status}}) when is_binary(status), do: status
  defp next_action(%{"work_request" => %{"status" => status}}) when is_binary(status), do: status
  defp next_action(_payload), do: "done"

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp json_safe_payload(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp plan_node_payload(%PlanNode{} = plan_node) do
    %{"id" => plan_node.id, "title" => plan_node.title, "status" => plan_node.status}
  end

  defp progress_event_payload(%ProgressEvent{} = event) do
    %{
      "id" => event.id,
      "summary" => Redactor.redact_text(event.summary),
      "status" => Redactor.redact_text(event.status),
      "idempotency_key" => Redactor.redact_text(event.idempotency_key),
      "payload" => Redactor.redact_output(event.payload || %{})
    }
  end

  defp progress_event_payload(nil), do: nil

  defp artifact_payload(%Artifact{} = artifact) do
    %{
      "id" => artifact.id,
      "path" => Redactor.redact_text(artifact.path),
      "title" => Redactor.redact_text(artifact.title),
      "kind" => artifact.kind,
      "uri" => Redactor.redact_text(artifact.uri),
      "metadata" => Redactor.redact_output(artifact.metadata || %{})
    }
  end

  defp worktree_lifecycle_payload(result, scope, audit_event) do
    %{
      "work_package" => work_package_worktree_payload(result.work_package),
      "worktree" => %{
        "status" => result.status,
        "path" => Redactor.redact_text(result.worktree_path),
        "target_repo_root" => Redactor.redact_text(result.target_repo_root || result.repo_root),
        "branch" => result.branch,
        "base_branch" => result.base_branch
      },
      "worker_launch" => worktree_worker_launch_payload(result),
      "audit_event" => progress_event_payload(audit_event),
      "scope" => scope
    }
  end

  defp worktree_worker_launch_payload(%{worktree_path: worktree_path, branch: branch, base_branch: base_branch})
       when is_binary(worktree_path) and is_binary(branch) and is_binary(base_branch) do
    %{
      "workspace_path" => Redactor.redact_text(worktree_path),
      "branch" => branch,
      "base_branch" => base_branch,
      "instruction" => "Use this worktree only for the assigned WorkPackage."
    }
  end

  defp worktree_worker_launch_payload(_result), do: nil

  defp work_package_worktree_payload(%WorkPackage{} = work_package) do
    work_package
    |> work_package_payload()
    |> Map.put("worktree_path", Redactor.redact_text(work_package.worktree_path))
  end

  defp work_package_payload(%WorkPackage{} = work_package) do
    %{"id" => work_package.id, "kind" => work_package.kind, "status" => work_package.status}
  end

  defp child_work_package_payload(%WorkPackage{} = work_package) do
    work_package
    |> work_package_payload()
    |> Map.merge(%{
      "acceptance_criteria" => work_package.acceptance_criteria || [],
      "allowed_file_globs" => work_package.allowed_file_globs || [],
      "base_branch" => work_package.base_branch,
      "parent_id" => work_package.parent_id,
      "phase_id" => work_package.phase_id,
      "policy_template" => work_package.policy_template,
      "repo" => work_package.repo,
      "title" => work_package.title
    })
  end

  defp child_worker_grant_payload(%{grant: grant}, %WorkPackage{} = child, claimed_by, ledger_database) do
    %{
      "id" => grant.id,
      "work_package_id" => grant.work_package_id,
      "grant_role" => grant.grant_role,
      "capabilities" => grant.capabilities || [],
      "expires_at" => timestamp(grant.expires_at),
      "secret_in_response" => false,
      "worker_bootstrap" => child_worker_bootstrap_payload(child, claimed_by, ledger_database)
    }
  end

  defp child_worker_bootstrap_payload(%WorkPackage{} = child, claimed_by, ledger_database) do
    %{
      "type" => "ledger_claim",
      "mode" => "local_assignment",
      "ledger" => %{"database" => ledger_database},
      "claim" => %{
        "tool" => @local_assignment_claim_tool,
        "arguments" => %{"work_package_id" => child.id, "claimed_by" => claimed_by},
        "required_runtime_arguments" => []
      }
    }
  end

  defp live_expires_at?(nil, %DateTime{}), do: true
  defp live_expires_at?(%DateTime{} = expires_at, %DateTime{} = now), do: DateTime.compare(expires_at, now) == :gt

  defp json_resource(uri, payload) do
    %{
      "contents" => [
        %{
          "uri" => uri,
          "mimeType" => "application/json",
          "text" => Jason.encode!(payload)
        }
      ]
    }
  end

  defp text_resource(uri, text, mime_type) do
    %{
      "contents" => [
        %{
          "uri" => uri,
          "mimeType" => mime_type,
          "text" => text
        }
      ]
    }
  end

  defp agent_text_resource(uri, markdown, toon, mime_type) do
    %{
      "contents" => [
        %{
          "uri" => uri,
          "mimeType" => mime_type,
          "text" => markdown
        },
        %{
          "uri" => uri,
          "mimeType" => @agent_text_mime_type,
          "text" => toon
        }
      ]
    }
  end

  defp auth_error(:unauthorized, resource) do
    {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}
  end

  defp auth_error({:unauthorized, reason}, resource) do
    {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}
  end

  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)

  defp auth_error(:forbidden, resource) do
    {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}
  end

  defp service_error(_reason, resource) do
    {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  defp response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp request_params(%{"params" => params}) when is_map(params) or is_list(params), do: {:ok, params}

  defp request_params(%{"params" => _params}),
    do: {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object_or_array"}}

  defp request_params(_request), do: {:ok, %{}}

  defp dispatch_request({:ok, params}, method, id, %__MODULE__{} = server) do
    dispatch_request_state({:ok, params}, method, id, server)
    |> elem(0)
  end

  defp dispatch_request({:error, code, message, data}, _method, id, %__MODULE__{}) do
    error_response(id, code, message, data)
  end

  defp dispatch_request_state({:ok, params}, method, id, %__MODULE__{} = server) do
    case require_current_session_claim_for_bound_call(server, method, params) do
      {:ok, server} ->
        case dispatch(method, params, server) do
          {:ok, result} ->
            {response(id, result), server}

          {:ok, result, %__MODULE__{} = updated_server} ->
            {response(id, result), updated_server}

          {:error, code, message, data} ->
            {error_response(id, code, message, data), server}
        end

      {:error, code, message, data, %__MODULE__{} = updated_server} ->
        {error_response(id, code, message, data), updated_server}
    end
  end

  defp dispatch_request_state({:error, code, message, data}, _method, id, %__MODULE__{} = server) do
    {error_response(id, code, message, data), server}
  end

  defp dispatch_notification({:ok, params}, method, %__MODULE__{} = server) do
    case require_current_session_claim_for_bound_call(server, method, params) do
      {:ok, server} ->
        case dispatch(method, params, server) do
          {:ok, _result} ->
            server

          {:ok, _result, %__MODULE__{} = updated_server} ->
            updated_server

          {:error, _code, _message, _data} ->
            server
        end

      {:error, _code, _message, _data, %__MODULE__{} = updated_server} ->
        updated_server
    end
  end

  defp dispatch_notification({:error, _code, _message, _data}, _method, %__MODULE__{} = server), do: server

  defp initialize_request?(%{"jsonrpc" => "2.0", "method" => "initialize"}), do: true
  defp initialize_request?(_payload), do: false

  defp handle_batch_item(payload, %__MODULE__{} = server) when is_map(payload), do: handle_state(payload, server)

  defp handle_batch_item(_payload, %__MODULE__{} = server) do
    {error_response(nil, -32_600, "Invalid Request", %{"reason" => "request_must_be_object"}), server}
  end

  defp error_response(id, code, message, data) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message, "data" => data}}
  end
end
