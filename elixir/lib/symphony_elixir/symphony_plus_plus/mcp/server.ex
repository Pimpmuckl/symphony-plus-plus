defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Server do
  @moduledoc false

  require Logger

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
      json_safe_payload: 1,
      work_package_payload: 1
    ]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Service, as: CommentService
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    ArchitectDeliveryTools,
    ArchitectProductTreeTools,
    ArchitectWorkRequestTools,
    Auth,
    Config,
    ErrorDetails,
    GuidanceTools,
    HandleStateStore,
    HandoffDatabase,
    Health,
    LocalAssignmentClaims,
    LocalTrustedTools,
    Payloads,
    PhaseChildTools,
    ProgressEvents,
    Repository,
    Response,
    Session,
    SessionBindingTools,
    SoloTools,
    Surface,
    ToolCatalog,
    ToolResult,
    WorkerTools,
    WorkRequestPayloads,
    WorkRequestScope
  }

  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository

  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
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
    "read_plan",
    "read_delivery_board"
  ]
  @local_assignment_claim_tool ToolCatalog.local_assignment_claim_tool()
  @local_architect_assignment_claim_tool ToolCatalog.local_architect_assignment_claim_tool()
  @session_claim_tools ToolCatalog.session_claim_tools()
  @worker_tools ToolCatalog.worker_tools()
  @worker_tool_module_tools WorkerTools.tools()
  @architect_tools ToolCatalog.architect_tools()
  @architect_work_request_tools ArchitectWorkRequestTools.tools()
  @architect_product_tree_tools ArchitectProductTreeTools.tools()
  @work_request_policy_tools ToolCatalog.work_request_policy_tools()
  @delivery_policy_tools ToolCatalog.delivery_policy_tools()
  @version_resource "sympp://health/version"
  @assignment_resource "sympp://assignment/current"
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
      {:ok, arguments} -> GuidanceTools.call("read_guidance_request", server.config, server.session, arguments)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "read_guidance_request")
    end
  end

  defp dispatch("tools/call", %{"name" => "read_guidance_request"} = params, %__MODULE__{session: nil} = server) do
    case prepare_architect_tool_call(server, params, "read_guidance_request") do
      {:ok, arguments} -> GuidanceTools.call("read_guidance_request", server.config, server.session, arguments)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "read_guidance_request")
    end
  end

  defp dispatch("tools/call", %{"name" => "read_guidance_request"} = params, %__MODULE__{} = server) do
    case prepare_worker_tool_call(server, params, "read_guidance_request") do
      {:ok, arguments} -> GuidanceTools.call("read_guidance_request", server.config, server.session, arguments)
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
        Surface.read_work_package_virtual_resource(config.repo, session, work_package_id, file_name, uri,
          surface_profile: config.surface_profile,
          mode: config.mode
        )

      :error ->
        {:error, -32_602, "Invalid params", %{"resource" => uri, "reason" => "invalid_work_package_resource_uri"}}
    end
  end

  defp dispatch("resources/read", %{"uri" => uri}, _server) when is_binary(uri) do
    {:error, -32_601, "Method not found", %{"resource" => uri}}
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

  defp handle_assignment_release_tool(params, id, %__MODULE__{} = server) do
    case prepare_assignment_release_tool_call(server, params) do
      {:ok, arguments} ->
        case release_current_assignment(arguments, server) do
          {:ok, result, updated_server} ->
            tool_result = build_release_tool_result(server, result)
            {Response.response(id, tool_result), updated_server}

          {:tool_error, reason} ->
            {:error, code, message, data} = invalid_params_error(@assignment_release_tool, reason)
            {failed_tool_response(server, params, id, code, message, data), server}
        end

      {:error, code, message, data} ->
        {failed_tool_response(server, params, id, code, message, data), server}
    end
  end

  defp handle_session_claim_tool(@local_assignment_claim_tool, params, id, %__MODULE__{} = server) do
    case claim_local_assignment(params, server) do
      {:ok, result, session} ->
        tool_result = build_tool_result(server, fn -> ToolResult.claim_tool_result(result) end)

        {
          Response.response(id, tool_result),
          %{server | session: session, session_refresh_required: false}
        }

      {:error, code, message, data} ->
        {failed_tool_response(server, params, id, code, message, data), server}
    end
  end

  defp handle_session_claim_tool(@local_architect_assignment_claim_tool, params, id, %__MODULE__{} = server) do
    case claim_local_architect_assignment(params, server) do
      {:ok, result, session} ->
        tool_result = build_tool_result(server, fn -> ToolResult.claim_tool_result(result) end)

        {
          Response.response(id, tool_result),
          %{server | session: session, session_refresh_required: false}
        }

      {:error, code, message, data} ->
        {failed_tool_response(server, params, id, code, message, data), server}
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

  defp architect_tool(name, arguments, %__MODULE__{config: config, session: session} = server) when name in @architect_work_request_tools do
    ArchitectWorkRequestTools.call(name, config, session, arguments, server: server)
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

  defp architect_tool("resolve_blocker", arguments, %__MODULE__{config: config, session: session}),
    do: GuidanceTools.call("resolve_blocker", config, session, arguments)

  defp architect_tool(name, arguments, %__MODULE__{config: config, session: session})
       when name in [
              "reconcile_work_request",
              "record_work_package_delivery",
              "cleanup_work_request_work_package_runtime",
              "revoke_work_package_worker_key"
            ],
       do: ArchitectDeliveryTools.call(name, config, session, arguments)

  defp architect_tool(name, arguments, %__MODULE__{config: config, session: session})
       when name in ["list_guidance_requests", "answer_guidance_request", "escalate_guidance_request"],
       do: GuidanceTools.call(name, config, session, arguments)

  defp architect_tool(name, arguments, %__MODULE__{config: config, session: session}) when name in @architect_product_tree_tools do
    ArchitectProductTreeTools.call(name, config, session, arguments)
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

  defp optional_put(attrs, _key, nil), do: attrs
  defp optional_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp session_claimed_by(%Session{assignment: %{claimed_by: claimed_by}}) when is_binary(claimed_by) do
    case String.trim(claimed_by) do
      "" -> "architect"
      trimmed -> trimmed
    end
  end

  defp session_claimed_by(%Session{}), do: "architect"

  defp put_optional_handoff_opt(opts, _key, nil), do: opts
  defp put_optional_handoff_opt(opts, _key, value) when is_binary(value) and value == "", do: opts
  defp put_optional_handoff_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp release_current_assignment(arguments, %__MODULE__{} = server),
    do: SessionBindingTools.release_current_assignment(arguments, server)

  defp current_assignment_context(%__MODULE__{} = server), do: SessionBindingTools.current_assignment_context(server)

  defp current_assignment_summary(repo, %Session{} = session), do: SessionBindingTools.current_assignment_summary(repo, session)

  defp solo_tool(name, arguments, %__MODULE__{config: config}) do
    SoloTools.call(name, arguments, config, &worker_error/2)
  end

  defp worker_tool(name, arguments, %__MODULE__{config: config, session: session}) when name in @worker_tool_module_tools,
    do: WorkerTools.call(name, config, session, arguments)

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
    |> DashboardPubSub.broadcast_changed_on_success()
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
           {:ok, work_request} <- optional_scope_expansion_work_request(repo, work_package),
           :ok <- require_current_scope_expansion_work_request_scope(session, work_request) do
        {:ok, work_package, work_request}
      end
    else
      approve_scope_expansion_scoped_work_package(repo, session, work_package_id)
    end
  end

  defp approve_scope_expansion_scoped_work_package(repo, %Session{} = session, work_package_id) do
    with :ok <- require_scope_expansion_handoff_package_scope(repo, session),
         {:ok, work_package, _scope} <-
           ArchitectWorkRequestTools.scoped_worktree_work_package(repo, session, work_package_id),
         {:ok, work_request} <- optional_scope_expansion_work_request(repo, work_package) do
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

  defp optional_scope_expansion_work_request(_repo, %WorkPackage{work_request_id: nil}), do: {:ok, nil}

  defp optional_scope_expansion_work_request(repo, %WorkPackage{work_request_id: work_request_id}) do
    case repo.get(WorkRequest, work_request_id) do
      %WorkRequest{} = work_request -> {:ok, work_request}
      nil -> {:error, :not_found}
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
    case ScopeConstraints.validate_allowed_file_globs(work_request, allowed_file_globs) do
      :ok -> :ok
      {:error, _errors} -> {:tool_error, "scope_expansion_outside_work_request"}
    end
  end

  defp scope_expansion_effective_work_request_globs(nil, effective_globs), do: {:ok, effective_globs}

  defp scope_expansion_effective_work_request_globs(%WorkRequest{} = work_request, effective_globs) do
    scoped_globs =
      Enum.filter(effective_globs, fn glob ->
        ScopeConstraints.validate_allowed_file_globs(work_request, [glob]) == :ok
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

  defp architect_tool_capability("create_child_work_package"), do: "create:child_work_package"
  defp architect_tool_capability("mint_child_worker_key"), do: "mint:child_worker_key"
  defp architect_tool_capability("revoke_child_worker_key"), do: "revoke:child_worker_key"
  defp architect_tool_capability("list_work_requests"), do: "read:work_request"
  defp architect_tool_capability("read_work_request"), do: "read:work_request"
  defp architect_tool_capability("read_plan"), do: "read:work_request"
  defp architect_tool_capability("add_comment"), do: "write:work_request"
  defp architect_tool_capability("list_comments"), do: "read:work_request"
  defp architect_tool_capability("resolve_comment"), do: "write:work_request"
  defp architect_tool_capability("resolve_blocker"), do: "write:work_request"
  defp architect_tool_capability("read_delivery_board"), do: "read:work_request"
  defp architect_tool_capability("reconcile_work_request"), do: "read:work_request"

  defp architect_tool_capability(tool) when tool in ["cleanup_work_request_work_package_runtime", "record_work_package_delivery", "revoke_work_package_worker_key"],
    do: "write:work_request"

  defp architect_tool_capability("list_guidance_requests"), do: "read:guidance_request"
  defp architect_tool_capability("read_guidance_request"), do: "read:guidance_request"
  defp architect_tool_capability("answer_guidance_request"), do: "write:guidance_request"
  defp architect_tool_capability("escalate_guidance_request"), do: "write:guidance_request"
  defp architect_tool_capability("set_work_request_status"), do: "write:work_request"
  defp architect_tool_capability("ask_question"), do: "write:work_request"
  defp architect_tool_capability("answer_question"), do: "write:work_request"
  defp architect_tool_capability("answer_question_and_record_decision"), do: "write:work_request"
  defp architect_tool_capability("close_question"), do: "write:work_request"
  defp architect_tool_capability("record_decision"), do: "write:work_request"
  defp architect_tool_capability("slice_work_request"), do: "write:work_request"
  defp architect_tool_capability("update_work_package"), do: "write:work_request"

  defp architect_tool_capability(tool) when tool in ["upsert_group", "delete_group", "upsert_dependency", "delete_dependency"],
    do: "write:work_request"

  defp architect_tool_capability("skip_work_package"), do: "write:work_request"
  defp architect_tool_capability("dispatch_work_package"), do: "dispatch:work_request"
  defp architect_tool_capability("prepare_work_package_worktree"), do: "dispatch:work_request"
  defp architect_tool_capability("cleanup_work_package_worktree"), do: "dispatch:work_request"
  defp architect_tool_capability("read_phase_board"), do: "read:phase"
  defp architect_tool_capability("approve_scope_expansion"), do: "approve:scope_expansion"
  defp architect_tool_capability("approve_child_ready_state"), do: "approve:child_ready_state"
  defp architect_tool_capability("merge_child_into_phase"), do: "merge:child_into_phase"

  defp lock_work_package(repo, work_package_id) do
    query = from(work_package in WorkPackage, where: work_package.id == ^work_package_id)

    case repo.update_all(query, set: [id: work_package_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

  defp reject_ready_work_package(%WorkPackage{kind: "phase_child", status: status}) when status in ["merging_into_phase", "merged_into_phase"] do
    {:tool_error, "child_under_architect_control"}
  end

  defp reject_ready_work_package(%WorkPackage{status: status}) when status in ["ready_for_merge", "ready_for_human_merge", "ready_for_architect_merge"],
    do: {:tool_error, "already_ready"}

  defp reject_ready_work_package(%WorkPackage{}), do: :ok

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

  defp architect_error({:work_package_scope_violation, errors}, tool) do
    invalid_params_error(tool, {:work_package_scope_violation, errors})
  end

  defp architect_error(:open_questions, tool) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "open_questions",
       "message" => "Answer or close all open clarification questions before adding WorkPackages."
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

  defp invalid_params_error(tool, {:work_package_scope_violation, errors}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "work_package_scope_violation",
       "validation_errors" => scope_validation_details(errors)
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

  defp scope_validation_detail({:invalid_allowed_file_globs, field}) do
    %{"field" => Atom.to_string(field), "reason" => "invalid_allowed_file_globs"}
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
      "field" => "allowed_file_globs",
      "value" => value,
      "reason" => "non_documentation_owned_glob"
    }
  end

  defp scope_validation_detail({:outside_allowed_paths, value, allowed_paths}) do
    %{
      "field" => "allowed_file_globs",
      "value" => value,
      "reason" => "outside_allowed_paths",
      "allowed_paths" => allowed_paths
    }
  end

  defp scope_validation_detail({:forbidden_path_overlap, value, forbidden_path}) do
    %{
      "field" => "allowed_file_globs",
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

  # Claim preflight and these handlers both revalidate live authority; avoid a third
  # grant/package/scope lookup between them.
  defp authorize_worker_tool_call(%__MODULE__{}, tool) when tool in ["get_current_assignment", "append_progress"], do: :ok

  defp authorize_worker_tool_call(%__MODULE__{config: config, session: session}, "sync_pr") do
    case Auth.require_session(session, config.repo) do
      {:ok, session} ->
        require_worker_assignment(session.assignment)

      {:error, {:unauthorized, :work_package_terminal}} ->
        with {:ok, session} <- Auth.require_terminal_session(session, config.repo) do
          require_worker_assignment(session.assignment)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authorize_worker_tool_call(%__MODULE__{config: config, session: session}, _tool) do
    case Auth.require_session(session, config.repo) do
      {:ok, session} -> require_worker_assignment(session.assignment)
      {:error, reason} -> {:error, reason}
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

  defp not_found_error(tool) do
    {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}
  end

  defp require_current_session_claim_for_bound_call(%__MODULE__{} = server, method, params),
    do: SessionBindingTools.require_current_session_claim_for_bound_call(server, method, params)

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

  defp request_params(%{"params" => params}) when is_map(params), do: {:ok, params}

  defp request_params(%{"params" => params}) when is_list(params),
    do: {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}

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
        case dispatch_with_text_profile(method, params, server) do
          {:ok, result} ->
            {Response.response(id, result), server}

          {:ok, result, %__MODULE__{} = updated_server} ->
            {Response.response(id, result), updated_server}

          {:error, code, message, data} ->
            {failed_dispatch_response(server, method, params, id, code, message, data), server}
        end

      {:error, code, message, data, %__MODULE__{} = updated_server} ->
        {failed_dispatch_response(server, method, params, id, code, message, data), updated_server}
    end
  end

  defp dispatch_request_state({:error, code, message, data}, _method, id, %__MODULE__{} = server) do
    {Response.error(id, code, message, data), server}
  end

  defp failed_dispatch_response(server, "tools/call", params, id, code, message, data),
    do: failed_tool_response(server, params, id, code, message, data)

  defp failed_dispatch_response(_server, _method, _params, id, code, message, data),
    do: Response.error(id, code, message, data)

  defp failed_tool_response(%__MODULE__{} = server, %{"name" => tool_name} = params, id, code, message, data)
       when is_binary(tool_name) and is_map(data) do
    case failed_tool_diagnostic(server, params, tool_name, code) do
      nil -> Response.error(id, code, message, data)
      diagnostic_id -> Response.error(id, code, message, Map.put(data, "diagnostic_id", diagnostic_id))
    end
  end

  defp failed_tool_response(_server, _params, id, code, message, data), do: Response.error(id, code, message, data)

  defp failed_tool_diagnostic(%__MODULE__{config: %Config{repo: repo} = config} = server, params, tool_name, code) do
    case OperatorSettingsRepository.get(repo) do
      {:ok, %{capture_failed_mcp_calls: true}} ->
        diagnostic_id = "mcpdiag_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        {safe_tool_name, safe_argument_keys} = safe_tool_metadata(params, tool_name, server)

        Logger.warning(
          Jason.encode!(%{
            "argument_keys" => safe_argument_keys,
            "diagnostic_id" => diagnostic_id,
            "error_classification" => error_classification(code),
            "event" => "sympp_failed_mcp_call",
            "source" => Health.source_identity(config),
            "tool_name" => safe_tool_name
          })
        )

        diagnostic_id

      _disabled_or_unavailable ->
        nil
    end
  rescue
    _diagnostic_failure -> nil
  catch
    _kind, _reason -> nil
  end

  defp safe_tool_metadata(params, tool_name, %__MODULE__{} = server) do
    with {:ok, specs} <- Surface.tool_specs_for_server(server),
         %{"name" => safe_tool_name} = spec <- Enum.find(specs, &(&1["name"] == tool_name)) do
      {safe_tool_name, schema_argument_keys(params, spec)}
    else
      _unknown_or_unavailable -> {"unknown", []}
    end
  end

  defp schema_argument_keys(
         %{"arguments" => arguments},
         %{"inputSchema" => %{"properties" => properties}}
       )
       when is_map(arguments) and is_map(properties) do
    properties
    |> Map.keys()
    |> Enum.filter(&Map.has_key?(arguments, &1))
    |> Enum.sort()
  end

  defp schema_argument_keys(_params, _spec), do: []

  defp error_classification(-32_601), do: "method_not_found"
  defp error_classification(-32_602), do: "invalid_params"
  defp error_classification(-32_001), do: "unauthorized"
  defp error_classification(-32_003), do: "forbidden"
  defp error_classification(-32_004), do: "not_found"
  defp error_classification(-32_009), do: "precondition_failed"
  defp error_classification(_code), do: "server_error"

  defp dispatch_with_text_profile(method, params, %__MODULE__{} = server) do
    build_tool_result(server, fn -> dispatch(method, params, server) end)
  end

  defp build_tool_result(%__MODULE__{} = server, fun) when is_function(fun, 0) do
    ToolResult.with_text_profile(response_text_profile(server), fun)
  end

  defp build_release_tool_result(%__MODULE__{} = server, result) do
    build_tool_result(server, fn -> ToolResult.release_tool_result(result) end)
  end

  defp response_text_profile(%__MODULE__{config: %Config{mode: :stdio, surface_profile: :full}}), do: :full
  defp response_text_profile(%__MODULE__{}), do: :canonical

  defp dispatch_notification({:ok, params}, method, %__MODULE__{} = server) do
    case require_current_session_claim_for_bound_call(server, method, params) do
      {:ok, server} ->
        case dispatch_with_text_profile(method, params, server) do
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
