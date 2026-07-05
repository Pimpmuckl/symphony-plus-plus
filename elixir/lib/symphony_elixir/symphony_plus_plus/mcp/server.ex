defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Server do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      architect_tool_arguments: 2,
      assignment_release_tool_arguments: 1,
      bootstrap_tool_arguments: 2,
      local_operator_tool_arguments: 2,
      optional_argument: 3,
      optional_list_argument: 2,
      optional_object_argument: 2,
      optional_string_argument: 2,
      optional_string_argument: 3,
      required_argument: 2,
      solo_tool_arguments: 2,
      worker_tool_arguments: 2
    ]

  import SymphonyElixir.SymphonyPlusPlus.MCP.Payloads,
    only: [
      comment_payload: 1,
      dispatch_link_recovery_payload: 1,
      dispatch_work_request_planned_slice_payload: 2,
      guidance_request_cards: 1,
      guidance_request_payload: 1,
      json_safe_payload: 1,
      optional_payload: 1,
      work_package_payload: 1,
      worktree_lifecycle_payload: 3
    ]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.ActorResolver
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.BranchPattern
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Service, as: CommentService
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Service, as: GuidanceRequestService
  alias SymphonyElixir.SymphonyPlusPlus.HumanDecisionPrompt
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    ArchitectDeliveryTools,
    ArchitectProductTreeTools,
    Auth,
    Config,
    CurrentWorkRequest,
    ErrorDetails,
    HandleStateStore,
    HandoffDatabase,
    Health,
    LocalAssignmentClaims,
    LocalClaimLeases,
    LocalTrustedTools,
    Payloads,
    PhaseChildTools,
    ProgressEvents,
    PullRequestMetadata,
    Repository,
    Response,
    ReviewReadiness,
    Session,
    SoloTools,
    Surface,
    TaskPlanTools,
    ToolCatalog,
    ToolResult,
    WorkRequestPayloads,
    WorkRequestScope,
    WorktreeScope
  }

  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer, as: PlanningRenderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.ReviewProfiles
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Service, as: WorkPackageService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDispatch
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceLinkage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ScopeConstraints
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @protocol_version "2025-03-26"
  @health_tool ToolCatalog.health_tool()
  @solo_tools ToolCatalog.solo_tools()
  @assignment_release_tool ToolCatalog.assignment_release_tool()
  @local_operator_tools ToolCatalog.local_operator_tools()
  @local_trusted_work_request_read_tools [
    "list_work_requests",
    "read_work_request",
    "read_work_request_product_tree",
    "read_work_request_delivery_board"
  ]
  @terminal_work_package_statuses ["merged", "merged_into_phase", "closed", "abandoned"]
  @local_assignment_claim_tool ToolCatalog.local_assignment_claim_tool()
  @local_architect_assignment_claim_tool ToolCatalog.local_architect_assignment_claim_tool()
  @session_claim_tools ToolCatalog.session_claim_tools()
  @worker_tools ToolCatalog.worker_tools()
  @architect_tools ToolCatalog.architect_tools()
  @architect_product_tree_tools ArchitectProductTreeTools.tools()
  @work_request_policy_tools ToolCatalog.work_request_policy_tools()
  @delivery_policy_tools ToolCatalog.delivery_policy_tools()
  @work_request_product_tree_views ToolCatalog.work_request_product_tree_views()
  @phase7_stub_architect_tools ToolCatalog.phase7_stub_architect_tools()
  @version_resource "sympp://health/version"
  @assignment_resource "sympp://assignment/current"
  @finding_replay_retry_attempts 50
  @local_assignment_claim_stale_after_ms :timer.minutes(5)
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
  defdelegate mcp_contract_identity, to: Health

  @doc false
  @spec mcp_timestamp(DateTime.t() | NaiveDateTime.t() | nil) :: String.t() | nil
  defdelegate mcp_timestamp(timestamp), to: Payloads

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
        {Response.error(nil, -32_600, "Invalid Request", %{"reason" => "empty_batch"}), server}

      Enum.any?(payloads, &initialize_request?/1) ->
        {Response.error(nil, -32_600, "Invalid Request", %{"reason" => "initialize_must_be_standalone"}), server}

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
    Response.error(nil, -32_600, "Invalid Request", %{"reason" => "empty_batch"})
  end

  defp do_handle(payloads, %__MODULE__{} = server) when is_list(payloads) do
    if Enum.any?(payloads, &initialize_request?/1) do
      Response.error(nil, -32_600, "Invalid Request", %{"reason" => "initialize_must_be_standalone"})
    else
      handle_batch(payloads, server)
      |> elem(0)
    end
  end

  defp do_handle(%{"id" => id}, %__MODULE__{}) when invalid_request_id(id) do
    Response.error(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id}, %__MODULE__{}) when invalid_request_id(id) do
    Response.error(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => method}, %__MODULE__{initialized: false})
       when is_binary(method) and method != "initialize" and valid_request_id(id) do
    Response.error(id, -32_000, "Server error", %{"reason" => "server_not_initialized"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => "initialize"}, %__MODULE__{initialized: true})
       when valid_request_id(id) do
    Response.error(id, -32_600, "Invalid Request", %{"reason" => "already_initialized"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => method} = request, %__MODULE__{} = server)
       when is_binary(method) and valid_request_id(id) do
    request
    |> request_params()
    |> dispatch_request(method, id, server)
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => _id, "method" => method}, %__MODULE__{}) when is_binary(method) do
    Response.error(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => _method}, %__MODULE__{}) when valid_request_id(id) do
    Response.error(id, -32_600, "Invalid Request", %{"reason" => "invalid_method"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "method" => "initialize"}, %__MODULE__{}) do
    Response.error(nil, -32_600, "Invalid Request", %{"reason" => "initialize_requires_id"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "method" => method} = notification, %__MODULE__{}) when is_binary(method) do
    if Map.has_key?(notification, "id") do
      Response.error(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
    end
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id}, %__MODULE__{}) when valid_request_id(id) do
    Response.error(id, -32_600, "Invalid Request", %{"reason" => "missing_method"})
  end

  defp do_handle(%{"jsonrpc" => version, "id" => id}, %__MODULE__{}) when version != "2.0" and valid_request_id(id) do
    Response.error(id, -32_600, "Invalid Request", %{"reason" => "invalid_jsonrpc_version"})
  end

  defp do_handle(%{"jsonrpc" => version}, %__MODULE__{}) when version != "2.0" do
    Response.error(nil, -32_600, "Invalid Request", %{"reason" => "invalid_jsonrpc_version"})
  end

  defp do_handle(%{"id" => id, "method" => method}, %__MODULE__{}) when is_binary(method) do
    Response.error(id, -32_600, "Invalid Request", %{"reason" => "invalid_jsonrpc_version"})
  end

  defp do_handle(%{"id" => id, "method" => _method}, %__MODULE__{}) when valid_request_id(id) do
    Response.error(id, -32_600, "Invalid Request", %{"reason" => "invalid_method"})
  end

  defp do_handle(%{"id" => id}, %__MODULE__{}) do
    Response.error(id, -32_600, "Invalid Request", %{"reason" => "missing_method"})
  end

  defp do_handle(_payload, %__MODULE__{}) do
    Response.error(nil, -32_600, "Invalid Request", %{"reason" => "request_must_be_object"})
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
    case Surface.tool_specs_for_server(server) do
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
        result = Health.health(server)

        {:ok, ToolResult.tool_result(result)}

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
        {:ok, ToolResult.claim_tool_result(result), %{server | session: session, session_refresh_required: false}}

      {:error, code, message, data} ->
        {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => @local_architect_assignment_claim_tool} = params, %__MODULE__{} = server) do
    case claim_local_architect_assignment(params, server) do
      {:ok, result, session} ->
        {:ok, ToolResult.claim_tool_result(result), %{server | session: session, session_refresh_required: false}}

      {:error, code, message, data} ->
        {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => @assignment_release_tool} = params, %__MODULE__{} = server) do
    with {:ok, arguments} <- prepare_assignment_release_tool_call(server, params),
         {:ok, result, updated_server} <- release_current_assignment(arguments, server) do
      {:ok, ToolResult.release_tool_result(result), updated_server}
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
    if Surface.local_trusted_tools_enabled?(server) do
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
    case Surface.resource_specs_for_session(session, config.repo) do
      {:ok, resources} -> {:ok, %{"resources" => resources}}
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("resources/list", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}
  end

  defp dispatch("resources/read", %{"uri" => @version_resource}, %__MODULE__{config: %Config{} = config}) do
    payload = %{
      "version" => config.version,
      "source" => Health.source_identity(config),
      "mode" => Atom.to_string(config.mode)
    }

    {:ok, Response.json_resource(@version_resource, payload)}
  end

  defp dispatch("resources/read", %{"uri" => @assignment_resource}, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         :ok <- require_assignment_introspection(session.assignment) do
      {:ok, Response.json_resource(@assignment_resource, Session.public_assignment(session))}
    else
      {:error, :unsupported_grant_role} -> auth_error({:unauthorized, :unsupported_grant_role}, @assignment_resource)
      {:error, reason} -> auth_error(reason, @assignment_resource)
    end
  end

  defp dispatch("resources/read", %{"uri" => "sympp://work-packages/" <> rest = uri}, %__MODULE__{
         config: config,
         session: session
       }) do
    case Surface.work_package_resource_id(rest) do
      {:ok, work_package_id, file_name} ->
        Surface.read_work_package_virtual_resource(config.repo, session, work_package_id, file_name, uri)

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

  defp normalize_optional_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_value(nil), do: nil
  defp normalize_optional_value(value), do: value

  defp handle_assignment_release_tool(params, id, %__MODULE__{} = server) do
    case prepare_assignment_release_tool_call(server, params) do
      {:ok, arguments} ->
        case release_current_assignment(arguments, server) do
          {:ok, result, updated_server} ->
            {Response.response(id, ToolResult.release_tool_result(result)), updated_server}

          {:tool_error, reason} ->
            {:error, code, message, data} = invalid_params_error(@assignment_release_tool, reason)
            {Response.error(id, code, message, data), server}
        end

      {:error, code, message, data} ->
        {Response.error(id, code, message, data), server}
    end
  end

  defp handle_session_claim_tool(@local_assignment_claim_tool, params, id, %__MODULE__{} = server) do
    case claim_local_assignment(params, server) do
      {:ok, result, session} ->
        {
          Response.response(id, ToolResult.claim_tool_result(result)),
          %{server | session: session, session_refresh_required: false}
        }

      {:error, code, message, data} ->
        {Response.error(id, code, message, data), server}
    end
  end

  defp handle_session_claim_tool(@local_architect_assignment_claim_tool, params, id, %__MODULE__{} = server) do
    case claim_local_architect_assignment(params, server) do
      {:ok, result, session} ->
        {
          Response.response(id, ToolResult.claim_tool_result(result)),
          %{server | session: session, session_refresh_required: false}
        }

      {:error, code, message, data} ->
        {Response.error(id, code, message, data), server}
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

  defp claim_local_assignment(params, %__MODULE__{} = server) do
    LocalAssignmentClaims.claim_local_assignment(params, server, local_assignment_claim_callbacks())
  end

  defp claim_local_architect_assignment(params, %__MODULE__{} = server) do
    LocalAssignmentClaims.claim_local_architect_assignment(params, server, local_assignment_claim_callbacks())
  end

  defp local_assignment_claim_callbacks do
    %{
      current_assignment_summary: &current_assignment_summary/2,
      release_current_assignment: &release_current_assignment/2,
      create_work_request_handoff_opts: &create_work_request_handoff_opts/2
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

  defp require_local_assignment_claim_mode(%__MODULE__{}), do: :ok

  defp require_local_architect_assignment_claim_mode(%__MODULE__{config: config} = server) do
    with :ok <- require_local_assignment_claim_mode(server) do
      LocalTrustedTools.require_database(config)
    end
  end

  defp default_claimed_by(%__MODULE__{config: %Config{claimed_by: claimed_by}}) do
    case normalize_optional_value(claimed_by) do
      claimed_by when is_binary(claimed_by) -> claimed_by
      nil -> "local-agent"
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
      WorkRequestScope.authorize_work_request_tool_policy_preauthorization(config.repo, session, name)
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
      if WorkRequestScope.architect_session?(session), do: :ok, else: require_architect_assignment(session.assignment)
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

      {:ok, ToolResult.architect_agent_tool_result(payload, :create_work_request_handoff)}
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
          "work_request" => WorkRequestPayloads.work_request(work_request),
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
      "work_request" => WorkRequestPayloads.work_request(work_request),
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
    case HandoffDatabase.resolve(config.database, config.repo) do
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
       ToolResult.tool_result(%{
         "comment" => comment_payload(comment),
         "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
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
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
         "decision_log_entry" => WorkRequestPayloads.decision_log_entry(decision_record),
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
      {:ok, payload} -> {:ok, ToolResult.tool_result(payload)}
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "list_comments", "reason" => reason}}
      {:error, :not_found} -> not_found_error("list_comments")
      {:error, reason} -> architect_error(reason, "list_comments")
    end
  end

  defp architect_tool("list_work_requests", arguments, %__MODULE__{config: config, session: nil} = server) do
    with :ok <- authorize_local_trusted_work_request_read_tool_call(server, "list_work_requests"),
         {:ok, status} <- optional_work_request_status(arguments),
         filters = WorkRequestScope.work_request_list_filters(%{}, status),
         {:ok, work_requests} <- WorkRequestService.list(config.repo, WorkRequestScope.work_request_repository_filters(filters)) do
      cards = WorkRequestPayloads.work_request_cards(work_requests)

      {:ok,
       ToolResult.agent_tool_result(%{
         "work_requests" => cards,
         "total_count" => length(cards),
         "scope" => %{"visibility" => "local_ledger"},
         "filters" => WorkRequestPayloads.work_request_filter(status)
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "list_work_requests", "reason" => reason}}
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "list_work_requests")
    end
  end

  defp architect_tool("list_work_requests", arguments, %__MODULE__{config: config, session: session}) do
    repo_scope_opts = WorkRequestScope.work_request_repo_scope_opts(config)

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, status} <- optional_work_request_status(arguments),
         {:ok, filters, scope} <-
           WorkRequestScope.scoped_work_request_filters(config.repo, session, handoff_phase_scope?: false),
         policy_session = WorkRequestScope.read_scoped_work_request_session(config.repo, session, scope, :work_request_read),
         :ok <- WorkRequestScope.authorize_work_request_list_policy(policy_session, scope, "list_work_requests", repo_scope_opts),
         filters = WorkRequestScope.work_request_list_filters(filters, status),
         {:ok, work_requests} <- WorkRequestService.list(config.repo, WorkRequestScope.work_request_repository_filters(filters)),
         {:ok, work_requests} <-
           WorkRequestScope.filter_scoped_work_requests(config.repo, work_requests, filters, policy_session, repo_scope_opts) do
      cards = WorkRequestPayloads.work_request_cards(work_requests)

      {:ok,
       ToolResult.agent_tool_result(%{
         "work_requests" => cards,
         "total_count" => length(cards),
         "scope" => scope,
         "filters" => WorkRequestPayloads.work_request_filter(status)
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "list_work_requests", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "list_work_requests")
    end
  end

  defp architect_tool("read_work_request", arguments, %__MODULE__{config: config, session: nil} = server) do
    with :ok <- authorize_local_trusted_work_request_read_tool_call(server, "read_work_request"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, work_request, _filters} <- WorkRequestScope.local_trusted_work_request_read_scope(config.repo, work_request_id),
         {:ok, payload} <- WorkRequestPayloads.work_request_detail(config.repo, work_request, []) do
      payload = Map.put(payload, "scope", WorkRequestPayloads.redacted_work_request_scope(work_request))
      {:ok, ToolResult.architect_agent_tool_result(payload, :work_request_read)}
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
           WorkRequestScope.authorized_work_request_scope(
             config.repo,
             session,
             work_request_id,
             :work_request_read,
             "read_work_request",
             WorkRequestScope.work_request_repo_scope_opts(config)
           ),
         {:ok, payload} <- WorkRequestPayloads.work_request_detail(config.repo, work_request, []) do
      payload = Map.put(payload, "scope", scope)
      {:ok, ToolResult.architect_agent_tool_result(payload, :work_request_read)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_work_request", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_work_request")
      {:error, reason} -> architect_error(reason, "read_work_request")
    end
  end

  defp architect_tool("read_work_request_product_tree", arguments, %__MODULE__{config: config, session: nil} = server) do
    with :ok <- authorize_local_trusted_work_request_read_tool_call(server, "read_work_request_product_tree"),
         {:ok, work_request_id, view} <- read_work_request_product_tree_arguments(arguments),
         {:ok, work_request, scope} <- WorkRequestScope.local_trusted_work_request_read_scope(config.repo, work_request_id),
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
    repo_scope_opts = WorkRequestScope.work_request_repo_scope_opts(config)

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id, view} <- read_work_request_product_tree_arguments(arguments),
         {:ok, work_request, filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(
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
      {:ok, ToolResult.tool_result(%{"progress_event" => ProgressEvents.payload(event)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "resolve_blocker", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "resolve_blocker")
    end
  end

  defp architect_tool("read_work_request_delivery_board", arguments, %__MODULE__{config: config, session: %Session{} = session}) do
    repo_scope_opts = WorkRequestScope.work_request_repo_scope_opts(config)

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, work_request, filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(
             config.repo,
             session,
             work_request_id,
             :delivery_board_read,
             "read_work_request_delivery_board",
             repo_scope_opts
           ),
         {:ok, planned_slices} <- WorkRequestService.list_planned_slices(config.repo, work_request_id),
         {:ok, delivery_board} <- WorkRequestScope.scoped_delivery_board(config.repo, work_request, planned_slices, filters, repo_scope_opts) do
      payload = %{
        "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
        "delivery_board" => WorkRequestPayloads.delivery_board(delivery_board),
        "scope" => scope
      }

      {:ok, ToolResult.architect_agent_tool_result(payload, :work_request_delivery_board)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_work_request_delivery_board", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_work_request_delivery_board")
      {:error, reason} -> architect_error(reason, "read_work_request_delivery_board")
    end
  end

  defp architect_tool("read_work_request_delivery_board", arguments, %__MODULE__{config: config, session: nil} = server) do
    with :ok <- authorize_local_trusted_work_request_read_tool_call(server, "read_work_request_delivery_board"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, work_request, filters} <- WorkRequestScope.local_trusted_work_request_read_scope(config.repo, work_request_id),
         {:ok, planned_slices} <- WorkRequestService.list_planned_slices(config.repo, work_request_id),
         {:ok, delivery_board} <- WorkRequestScope.scoped_delivery_board(config.repo, work_request, planned_slices, filters) do
      payload = %{
        "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
        "delivery_board" => WorkRequestPayloads.delivery_board(delivery_board),
        "scope" => WorkRequestPayloads.redacted_work_request_scope(work_request)
      }

      {:ok, ToolResult.architect_agent_tool_result(payload, :work_request_delivery_board)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_work_request_delivery_board", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_work_request_delivery_board")
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "read_work_request_delivery_board")
    end
  end

  defp architect_tool(name, arguments, %__MODULE__{config: config, session: session})
       when name in [
              "reconcile_work_request",
              "record_planned_slice_delivery",
              "cleanup_work_request_planned_slice_runtime",
              "revoke_planned_slice_worker_key"
            ],
       do: ArchitectDeliveryTools.call(name, config, session, arguments)

  defp architect_tool("list_guidance_requests", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "read:guidance_request"),
         {:ok, status} <- optional_guidance_request_status(arguments),
         {:ok, work_package_id} <- optional_string_argument(arguments, "work_package_id"),
         {:ok, requested_work_request_id} <- optional_string_argument(arguments, "work_request_id"),
         {:ok, work_request_id} <-
           guidance_work_request_id_argument(requested_work_request_id, session, work_package_id),
         :ok <- WorkRequestScope.maybe_require_guidance_work_request_filter_scope(config.repo, session, requested_work_request_id),
         {:ok, filters, scope} <- WorkRequestScope.scoped_guidance_request_filters(config.repo, session),
         {:ok, filters} <- guidance_request_list_filters(config.repo, filters, status, work_package_id, work_request_id),
         {:ok, guidance_requests} <- GuidanceRequestService.list_visible_to_architect(config.repo, filters) do
      cards = guidance_request_cards(guidance_requests)

      payload = %{
        "guidance_requests" => cards,
        "total_count" => length(cards),
        "scope" => scope,
        "filters" => guidance_request_filter_payload(status, work_package_id, work_request_id)
      }

      {:ok, ToolResult.architect_agent_tool_result(payload, :guidance_request_list)}
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
         {:ok, filters, scope} <- WorkRequestScope.scoped_guidance_request_filters(config.repo, session),
         {:ok, visible_guidance_request} <- GuidanceRequestService.get_visible_to_architect(config.repo, guidance_request_id, filters),
         :ok <- authorize_guidance_request_for_session(config.repo, session, :guidance_request_answer, visible_guidance_request),
         {:ok, guidance_request} <-
           GuidanceRequestService.answer(config.repo, guidance_request_id, %{
             "answer" => answer,
             "answered_by" => answered_by,
             "answered_at" => DateTime.utc_now(:microsecond)
           }) do
      {:ok,
       ToolResult.tool_result(%{
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
      {:ok, ToolResult.tool_result(result)}
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
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :work_request_update, "set_work_request_status"),
         {:ok, updated_work_request} <- WorkRequestService.update_status(config.repo, work_request_id, current_status, next_status) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
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

  defp architect_tool(name, arguments, %__MODULE__{config: config, session: session}) when name in @architect_product_tree_tools do
    ArchitectProductTreeTools.call(name, config, session, arguments)
  end

  defp architect_tool("answer_work_request_question", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, question_id} <- required_argument(arguments, "question_id"),
         {:ok, expected_question_status} <- expected_question_status_argument(arguments),
         {:ok, answer} <- required_argument(arguments, "answer"),
         {:ok, answered_by} <- optional_string_argument(arguments, "answered_by", session_claimed_by(session)),
         {:ok, _work_request, filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :question_answer, "answer_work_request_question"),
         {:ok, _question} <- WorkRequestScope.scoped_work_request_question(config.repo, work_request_id, question_id),
         {:ok, question_record} <-
           WorkRequestService.answer_question(config.repo, question_id, expected_question_status, %{
             "answer" => answer,
             "answered_by" => answered_by
           }),
         {:ok, updated_work_request} <- WorkRequestScope.scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
         "clarification_question" => WorkRequestPayloads.clarification_question(question_record),
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
           WorkRequestScope.authorized_work_request_scope(
             config.repo,
             session,
             work_request_id,
             :question_answer,
             "answer_work_request_question_and_record_decision"
           ),
         :ok <-
           WorkRequestScope.authorize_work_request_policy(
             config.repo,
             session,
             :decision_record,
             work_request,
             "answer_work_request_question_and_record_decision"
           ),
         {:ok, _question} <- WorkRequestScope.scoped_work_request_question(config.repo, work_request_id, question_id),
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
         {:ok, updated_work_request} <- WorkRequestScope.scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
         "clarification_question" => WorkRequestPayloads.clarification_question(question_record),
         "decision_log_entry" => WorkRequestPayloads.decision_log_entry(decision_record),
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
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :question_close, "close_work_request_question"),
         {:ok, _question} <- WorkRequestScope.scoped_work_request_question(config.repo, work_request_id, question_id),
         {:ok, question_record} <- WorkRequestService.close_question(config.repo, question_id, expected_question_status),
         {:ok, updated_work_request} <- WorkRequestScope.scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
         "clarification_question" => WorkRequestPayloads.clarification_question(question_record),
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

  defp architect_tool("mark_work_request_sliced", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, current_status} <- required_argument(arguments, "current_status"),
         {:ok, _work_request, _filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :work_request_update, "mark_work_request_sliced"),
         {:ok, updated_work_request} <- WorkRequestService.mark_sliced(config.repo, work_request_id, current_status) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
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
           WorkRequestScope.authorized_planned_slice_scope(
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
      {:ok, ToolResult.tool_result(dispatch_work_request_planned_slice_payload(dispatch, scope))}
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
         {:ok, explicit_root} <- optional_string_argument(arguments, "target_repo_root"),
         {:ok, target_repo_root} <- WorktreeScope.target_repo_root_argument(explicit_root, work_package, config),
         {:ok, branch_arg} <- optional_string_argument(arguments, "branch"),
         {:ok, branch} <- WorktreeScope.prepare_branch(work_package, branch_arg),
         :ok <- WorktreeScope.require_target_repo_root_scope(target_repo_root, work_package, config),
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
      {:ok, ToolResult.tool_result(worktree_lifecycle_payload(result, scope, audit_event))}
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
         {:ok, cleanup_target_repo_root} <-
           WorktreeScope.cleanup_target_repo_root(
             target_repo_root,
             work_package,
             config
           ),
         :ok <-
           WorktreeScope.require_cleanup_target_repo_root_scope(
             cleanup_target_repo_root,
             work_package,
             config
           ),
         {:ok, result} <-
           WorkPackageService.cleanup_worktree(
             config.repo,
             work_package_id,
             cleanup_worktree_opts(cleanup_target_repo_root)
           ),
         {:ok, _runtime_cleanup} <- ArchitectDeliveryTools.cleanup_worktree_runtime(config.repo, session, work_package),
         {:ok, audit_event} <- maybe_append_cleanup_worktree_audit(config.repo, session, work_package_id, result) do
      {:ok, ToolResult.tool_result(worktree_lifecycle_payload(result, scope, audit_event))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "cleanup_work_package_worktree", "reason" => reason}}
      {:error, :not_found} -> not_found_error("cleanup_work_package_worktree")
      {:error, reason} -> architect_error(reason, "cleanup_work_package_worktree")
    end
  end

  defp architect_tool(name, arguments, %__MODULE__{config: config, session: session})
       when name in [
              "read_child_status",
              "create_child_work_package",
              "mint_child_worker_key",
              "revoke_child_worker_key",
              "read_phase_board",
              "approve_child_ready_state",
              "merge_child_into_phase"
            ] do
    PhaseChildTools.call(name, config, session, arguments)
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
      {:ok, ToolResult.tool_result(result)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "approve_scope_expansion", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "approve_scope_expansion")
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
    with {:ok, planned_slices} <- WorkRequestService.list_planned_slices(repo, work_request.id),
         {:ok, delivery_board} <-
           WorkRequestScope.scoped_delivery_board(repo, work_request, planned_slices, filters, Keyword.put(repo_scope_opts, :slice_projection, :operational_state)) do
      payload = WorkRequestPayloads.work_request_product_tree(repo, work_request, planned_slices, delivery_board, view)
      payload = Map.put(payload, "scope", scope)
      {:ok, ToolResult.architect_agent_tool_result(payload, :work_request_product_tree)}
    end
  end

  defp dispatch_planned_slice_bootstrap_opts(%Config{} = config, claimed_by) do
    with {:ok, database} <- HandoffDatabase.resolve(config.database, config.repo) do
      {:ok, [claimed_by: claimed_by, database: database], []}
    end
  end

  defp cleanup_worktree_opts(nil), do: []
  defp cleanup_worktree_opts(target_repo_root), do: [target_repo_root: target_repo_root]

  defp require_approved_dispatch_planned_slice(%PlannedSlice{status: "approved"}), do: :ok

  defp require_approved_dispatch_planned_slice(%PlannedSlice{status: status}),
    do: {:error, {:invalid_planned_slice_status, status}}

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
    with {:ok, filters} <- WorkRequestScope.maybe_put_work_request_guidance_filter(repo, filters, work_request_id) do
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

  defp optional_put(attrs, _key, nil), do: attrs
  defp optional_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp maybe_prepare_work_package_status_blocker_closeout(repo, %Session{} = session, status, arguments)
       when status in @terminal_work_package_statuses do
    ArchitectDeliveryTools.prepare_scoped_blocker_closeout(
      repo,
      session,
      [Session.work_package_id(session)],
      arguments,
      "set_status"
    )
  end

  defp maybe_prepare_work_package_status_blocker_closeout(_repo, %Session{}, _status, _arguments) do
    {:ok, :not_needed}
  end

  defp session_claimed_by(%Session{assignment: %{claimed_by: claimed_by}}) when is_binary(claimed_by) do
    case String.trim(claimed_by) do
      "" -> "architect"
      trimmed -> trimmed
    end
  end

  defp session_claimed_by(%Session{}), do: "architect"

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

  defp authorize_guidance_request_for_session(repo, %Session{} = session, action, %GuidanceRequest{} = guidance_request) do
    GuidanceRequestService.authorize_for_assignment(repo, session.assignment, action, guidance_request)
  end

  defp scoped_worktree_work_package(repo, %Session{} = session, work_package_id) do
    with {:ok, %WorkPackage{} = work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, filters, scope} <- WorkRequestScope.scoped_work_request_filters(repo, session),
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
    with :ok <- WorkRequestScope.require_work_package_repo_scope(work_package, work_request, planned_slice),
         :ok <- WorkRequestScope.require_work_package_delivery_base_scope(work_package, planned_slice),
         :ok <- WorkRequestScope.require_work_request_scope(repo, work_request, filters) do
      WorkRequestScope.require_delivery_work_package_filter_scope(repo, work_package, work_request, filters)
    end
  end

  defp linked_planned_slice_work_request_for_work_package(repo, work_package_id) do
    PlannedSliceLinkage.linked_work_request_for_work_package(repo, work_package_id)
  end

  defp require_architect_target_scope(repo, %Session{} = session, %{"work_package_id" => work_package_id}) do
    with :ok <- require_architect_work_package_scope(session, work_package_id) do
      require_architect_current_phase_anchor(repo, session)
    end
  end

  defp require_architect_target_scope(repo, %Session{} = session, %{"phase_id" => phase_id}) do
    with :ok <- WorkRequestScope.require_architect_phase_scope(repo, session, phase_id) do
      WorkRequestScope.require_architect_phase_anchor(repo, session, phase_id)
    end
  end

  defp require_architect_target_scope(repo, %Session{} = session, _arguments) do
    require_architect_current_phase_anchor(repo, session)
  end

  defp require_architect_current_phase_anchor(repo, %Session{} = session) do
    case WorkRequestScope.architect_phase_scope(repo, session) do
      {:ok, phase_id} -> WorkRequestScope.require_architect_phase_anchor(repo, session, phase_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_optional_handoff_opt(opts, _key, nil), do: opts
  defp put_optional_handoff_opt(opts, _key, value) when is_binary(value) and value == "", do: opts
  defp put_optional_handoff_opt(opts, key, value), do: Keyword.put(opts, key, value)

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
      {:ok, ToolResult.agent_tool_result(%{"assignment" => Session.public_assignment(session)})}
    else
      {:error, reason} -> worker_error(reason, "get_current_assignment")
    end
  end

  defp worker_tool("read_context", _arguments, %__MODULE__{config: config, session: session}) do
    read_current_virtual_file(config.repo, session, "context.md")
  end

  defp worker_tool("read_task_plan", _arguments, %__MODULE__{config: config, session: session}) do
    case TaskPlanTools.read_task_plan(config.repo, session) do
      {:error, reason} -> worker_error(reason, "read_task_plan.md")
      result -> result
    end
  end

  defp worker_tool("update_task_plan", arguments, %__MODULE__{config: config, session: session}) do
    case scoped_session(config.repo, session, arguments) do
      {:ok, session} ->
        case authorize_current_package_policy(config.repo, session, :task_plan_update, :task_plan, "update_task_plan") do
          :ok ->
            normalize_update_task_plan_result(TaskPlanTools.update_task_plan(config.repo, session, arguments))

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
      {:ok, ToolResult.tool_result(%{"work_package" => work_package_payload(work_package), "blocker_closeout" => blocker_closeout})}
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
      {:ok, ToolResult.read_tool_result(%{"guidance_request" => guidance_request_payload(guidance_request)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "create_guidance_request", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "create_guidance_request")
    end
  end

  defp worker_tool("request_scope_expansion", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         :ok <- require_worker_assignment(session.assignment),
         {:ok, payload} <- ProgressEvents.request_scope_expansion_payload(config.repo, session) do
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
      ProgressEvents.append_metadata(config.repo, session, arguments, "attach_branch", "branch_attached", %{"type" => "branch", "branch" => branch, "head_sha" => head_sha})
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
         {:ok, payload} <- PullRequestMetadata.payload(config.repo, session, arguments, "attach_pr") do
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
         {:ok, payload} <- PullRequestMetadata.payload(config.repo, session, arguments, "sync_pr") do
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
         {:ok, result} <- ReviewReadiness.submit_review_package(config.repo, session, arguments) do
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
         {:ok, result} <- ReviewReadiness.attach_review_suite_result(config.repo, session, arguments) do
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
         {:ok, review_suite_result} <- ReviewReadiness.mark_ready_review_suite_result(arguments, session),
         {:ok, blocker_closeout_plan} <- ArchitectDeliveryTools.prepare_scoped_blocker_closeout(config.repo, session, [Session.work_package_id(session)], arguments, "mark_ready"),
         {:ok, {work_package, blocker_closeout, warnings}} <-
           ReviewReadiness.mark_ready(config.repo, session, blocker_closeout_plan, review_suite_result, &ArchitectDeliveryTools.apply_prepared_blocker_closeout/3) do
      {:ok,
       ToolResult.tool_result(
         %{"work_package" => work_package_payload(work_package), "ready" => true, "blocker_closeout" => blocker_closeout}
         |> ReviewReadiness.maybe_put_readiness_warnings(warnings)
       )}
    else
      {:tool_error, reason} ->
        invalid_params_error("mark_ready", reason)

      {:error, {:readiness_failed, missing, reasons, warnings}} ->
        {:error, -32_602, "Invalid params",
         %{"tool" => "mark_ready", "reason" => "readiness_failed", "missing" => missing, "reasons" => reasons}
         |> ReviewReadiness.maybe_put_readiness_warnings(warnings)}

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
      {:ok, ToolResult.agent_tool_result(%{"finding" => %{"id" => finding.id, "title" => finding.title, "severity" => finding.severity}})}
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

  defp inferred_literal_branch(branch),
    do: if(WorktreeScope.local_branch_template_pattern?(branch), do: {:tool_error, "missing_branch"}, else: {:ok, branch})

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
      {:ok, ToolResult.read_tool_result(%{"guidance_request" => guidance_request_payload(guidance_request)})}
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
         {:ok, filters, scope} <- WorkRequestScope.scoped_guidance_request_filters(repo, session),
         {:ok, guidance_request} <-
           GuidanceRequestService.get_visible_to_architect(repo, guidance_request_id, filters),
         :ok <- authorize_guidance_request_for_session(repo, session, :guidance_request_read, guidance_request),
         :ok <- require_guidance_request_work_package(guidance_request, work_package_id) do
      {:ok, ToolResult.read_tool_result(%{"guidance_request" => guidance_request_payload(guidance_request), "scope" => scope})}
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

  defp metadata_tool_response({:ok, _result} = result, _tool), do: result
  defp metadata_tool_response({:error, _code, _message, _data} = error, _tool), do: error
  defp metadata_tool_response({:tool_error, reason}, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
  defp metadata_tool_response({:error, reason}, tool), do: worker_error(reason, tool)

  defp append_pr_metadata(repo, %Session{} = session, arguments, tool, status, payload) do
    with {:ok, idempotency_key, attrs} <- ProgressEvents.metadata_attrs(session, arguments, tool, status, payload),
         {:ok, replay?} <- ProgressEvents.replay?(repo, session, idempotency_key),
         :ok <-
           PullRequestMetadata.validate_sync_target_unless_replay(
             repo,
             session,
             arguments,
             payload,
             tool,
             replay?
           ) do
      run_worker_transaction(repo, fn ->
        append_pr_metadata_event(repo, session, attrs, idempotency_key, tool, payload, replay?)
      end)
    end
  end

  defp append_pr_metadata_event(repo, session, attrs, idempotency_key, tool, payload, replay?) do
    with {:ok, event_result} <- ProgressEvents.append_or_replay(repo, session, attrs, idempotency_key, tool),
         :ok <- PullRequestMetadata.maybe_upsert_artifact(repo, session, payload, replay?) do
      {:ok, event_result}
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
           {:ok, blocker_closeout} <-
             ArchitectDeliveryTools.apply_prepared_blocker_closeout(repo, session, blocker_closeout_plan) do
        {:ok, {work_package, blocker_closeout}}
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
      with {:ok, filters, scope} <- WorkRequestScope.scoped_guidance_request_filters(repo, session),
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
        with {:ok, event} <- ProgressEvents.existing_for_work_package(repo, work_package_id, idempotency_key) do
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
      "progress_event" => ProgressEvents.payload(event)
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
    |> ProgressEvents.metadata_idempotency_key()
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
         {:ok, grant} <- WorkRequestScope.require_live_architect_grant(repo, session),
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
    with {:ok, grant} <- WorkRequestScope.require_live_architect_grant(repo, session),
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
      {:ok, ToolResult.agent_tool_result(%{"uri" => uri, "text" => markdown}, toon)}
    else
      {:error, reason} -> worker_error(reason, "read_#{file_name}")
    end
  end

  defp normalize_update_task_plan_result({:tool_error, reason}),
    do: {:error, -32_602, "Invalid params", %{"tool" => "update_task_plan", "reason" => reason}}

  defp normalize_update_task_plan_result({:error, reason}),
    do: worker_error(reason, "update_task_plan")

  defp normalize_update_task_plan_result(result), do: result

  defp lock_work_package(repo, work_package_id) do
    query = from(work_package in WorkPackage, where: work_package.id == ^work_package_id)

    case repo.update_all(query, set: [id: work_package_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

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
         :ok <- ProgressEvents.reject_ready_evidence_mutation(repo, session, "append_finding") do
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

  defp append_scoped_progress(repo, session, arguments, tool, payload) do
    with {:ok, session} <- scoped_session(repo, session, arguments),
         {action, resource_type} <- progress_tool_policy(tool),
         :ok <- authorize_current_package_policy(repo, session, action, resource_type, tool),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, caller_payload} <- optional_payload(arguments) do
      idempotency_key = ProgressEvents.scoped_idempotency_key(tool, String.trim(idempotency_key), session)

      attrs = %{
        "summary" => summary,
        "body" => optional_argument(arguments, "body", nil),
        "status" => optional_argument(arguments, "status", "recorded"),
        "idempotency_key" => idempotency_key,
        "payload" => ProgressEvents.merge_payload(tool, caller_payload, payload)
      }

      ProgressEvents.append_or_replay(repo, session, attrs, idempotency_key, tool)
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
        "idempotency_key" => ProgressEvents.metadata_idempotency_key(Map.put(idempotency_payload, "reason", reason))
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

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp create_work_request_error(%Ecto.Changeset{} = changeset) do
    changeset_invalid_params_error("create_work_request", "invalid_work_request", changeset)
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

  defp changeset_invalid_params_error(tool, reason, %Ecto.Changeset{} = changeset) do
    ErrorDetails.changeset_invalid_params_error(tool, reason, changeset)
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
      {:ok, ToolResult.tool_result(%{"comment" => comment_payload(comment)})}
    end
  end

  defp comment_tool_result("list_comments", repo, %Session{} = session, arguments, source_type, _author_name) do
    with {:ok, target_kind, target_id} <- comment_target_arguments(arguments, session, source_type),
         {:ok, comments} <- CommentService.list_for_assignment(repo, session.assignment, target_kind, target_id) do
      {:ok,
       ToolResult.tool_result(%{
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
      {:ok, ToolResult.tool_result(%{"comment" => comment_payload(resolved)})}
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

  defp optional_decision_prompt_argument(arguments, key) do
    with {:ok, prompt} <- optional_object_argument(arguments, key) do
      case HumanDecisionPrompt.normalize(prompt) do
        {:ok, normalized} -> {:ok, normalized}
        {:error, reason} -> {:tool_error, "#{key} #{HumanDecisionPrompt.error_message(reason)}"}
      end
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

  defp actor(%Session{} = session) do
    %{
      grant_id: session.assignment.grant_id,
      grant_role: session.assignment.grant_role,
      capabilities: session.assignment.capabilities,
      work_package_id: session.assignment.work_package_id
    }
  end

  defp not_found_error(tool) do
    {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}
  end

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

  defp request_params(%{"params" => params}) when is_map(params) or is_list(params), do: {:ok, params}

  defp request_params(%{"params" => _params}),
    do: {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object_or_array"}}

  defp request_params(_request), do: {:ok, %{}}

  defp dispatch_request({:ok, params}, method, id, %__MODULE__{} = server) do
    dispatch_request_state({:ok, params}, method, id, server)
    |> elem(0)
  end

  defp dispatch_request({:error, code, message, data}, _method, id, %__MODULE__{}) do
    Response.error(id, code, message, data)
  end

  defp dispatch_request_state({:ok, params}, method, id, %__MODULE__{} = server) do
    case require_current_session_claim_for_bound_call(server, method, params) do
      {:ok, server} ->
        case dispatch(method, params, server) do
          {:ok, result} ->
            {Response.response(id, result), server}

          {:ok, result, %__MODULE__{} = updated_server} ->
            {Response.response(id, result), updated_server}

          {:error, code, message, data} ->
            {Response.error(id, code, message, data), server}
        end

      {:error, code, message, data, %__MODULE__{} = updated_server} ->
        {Response.error(id, code, message, data), updated_server}
    end
  end

  defp dispatch_request_state({:error, code, message, data}, _method, id, %__MODULE__{} = server) do
    {Response.error(id, code, message, data), server}
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
    {Response.error(nil, -32_600, "Invalid Request", %{"reason" => "request_must_be_object"}), server}
  end
end
