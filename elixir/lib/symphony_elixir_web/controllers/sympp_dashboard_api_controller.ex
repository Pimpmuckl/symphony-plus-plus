defmodule SymphonyElixirWeb.SymppDashboardApiController do
  @moduledoc """
  Read-oriented JSON API for Symphony++ dashboard state.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.ActorResolver
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Policy
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Target
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Service, as: CommentService
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{DefaultClient, MergeReconciler}
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Service, as: GuidanceRequestService
  alias SymphonyElixir.SymphonyPlusPlus.HumanDecisionPrompt
  alias SymphonyElixir.SymphonyPlusPlus.OperatorAudit
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.TrackerAdapter
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDispatch
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixirWeb.Endpoint
  alias SymphonyElixirWeb.SymppDashboardAPI.LocalOperatorDashboard
  alias SymphonyElixirWeb.SymppDashboardApi.ScopeProjection

  import Ecto.Query, only: [from: 2]

  @type auth_context :: {:grant, AccessGrant.t()}
  @board_session_key "sympp_board_grant_id"
  @package_session_key "sympp_package_grant_ids"
  @package_session_order_key "sympp_package_grant_order"
  @operator_session_key "sympp_local_operator"
  @operator_bootstrap_param "operator_bootstrap"
  @operator_bootstrap_config_key :sympp_local_operator_bootstrap_token
  @max_package_sessions 8
  @access_grant_lazy_migration_columns ["phase_id", "scope_repo", "scope_base_branch", "provenance"]
  @local_operator_actor "local-operator"
  @local_operator_worker "local-operator-worker"
  @local_operator_nonmergeable_terminal_package_statuses ["merged_into_phase", "closed", "abandoned"]
  @local_operator_noncloseable_terminal_package_statuses ["merged", "merged_into_phase", "abandoned"]
  @local_operator_hideable_package_statuses ["merged", "merged_into_phase", "closed", "abandoned"]

  @spec authorize_board_browser(Conn.t(), term()) :: Conn.t()
  def authorize_board_browser(conn, _opts) do
    cond do
      work_key_login_requested?(conn) ->
        conn
        |> board_login_response()
        |> Conn.halt()

      local_operator_browser?(conn) and active_local_operator_session?(conn) ->
        authorize_active_operator_board_browser(conn)

      true ->
        authorize_board_browser_request(conn)
    end
  end

  @spec authorize_package_browser(Conn.t(), term()) :: Conn.t()
  def authorize_package_browser(conn, _opts) do
    work_package_id = conn.path_params |> Map.get("work_package_id") |> normalize_package_route_id()

    cond do
      not valid_package_route_id?(work_package_id) ->
        conn |> package_not_found_response() |> Conn.halt()

      work_key_login_requested?(conn) ->
        conn
        |> package_login_response(work_package_id: work_package_id)
        |> Conn.halt()

      local_operator_browser?(conn) and active_local_operator_session?(conn) ->
        authorize_active_operator_package_browser(conn, work_package_id)

      true ->
        authorize_package_browser_request(conn, work_package_id)
    end
  end

  defp authorize_board_browser_request(conn) do
    case authorize_board_request(conn) do
      {:ok, %AccessGrant{} = grant} ->
        put_board_browser_session(conn, grant)

      {:error, :unauthorized} ->
        if explicit_bearer_request?(conn) do
          conn |> board_browser_error_response(:unauthorized) |> Conn.halt()
        else
          maybe_put_local_operator_session(conn)
        end

      {:error, reason} ->
        conn |> board_browser_error_response(reason) |> Conn.halt()
    end
  end

  defp authorize_active_operator_board_browser(conn) do
    if is_binary(bearer_secret(conn)) do
      authorize_board_browser_request(conn)
    else
      put_local_operator_session(conn)
    end
  end

  defp maybe_put_local_operator_session(conn) do
    if local_operator_browser?(conn) do
      put_local_operator_session(conn)
    else
      conn |> board_login_response() |> Conn.halt()
    end
  end

  defp authorize_active_operator_package_browser(conn, work_package_id) do
    conn
    |> authorize_package_request(work_package_id)
    |> handle_active_operator_package_authorization(conn, work_package_id)
  end

  defp handle_active_operator_package_authorization({:ok, %AccessGrant{} = grant}, conn, work_package_id) do
    put_package_browser_session(conn, grant, work_package_id)
  end

  defp handle_active_operator_package_authorization({:error, :unauthorized}, conn, work_package_id) do
    if explicit_bearer_request?(conn) do
      conn |> package_browser_error_response(:unauthorized, work_package_id) |> Conn.halt()
    else
      authorize_operator_package_route(conn, work_package_id)
    end
  end

  defp handle_active_operator_package_authorization({:error, reason}, conn, work_package_id) do
    conn |> package_browser_error_response(reason, work_package_id) |> Conn.halt()
  end

  defp authorize_package_browser_request(conn, work_package_id) do
    conn
    |> authorize_package_request(work_package_id)
    |> handle_package_browser_authorization(conn, work_package_id)
  end

  defp handle_package_browser_authorization({:ok, %AccessGrant{} = grant}, conn, work_package_id) do
    put_package_browser_session(conn, grant, work_package_id)
  end

  defp handle_package_browser_authorization({:error, :unauthorized}, conn, work_package_id) do
    cond do
      explicit_bearer_request?(conn) ->
        conn |> package_browser_error_response(:unauthorized, work_package_id) |> Conn.halt()

      local_operator_browser?(conn) ->
        authorize_operator_package_route(conn, work_package_id)

      true ->
        conn |> package_login_response(work_package_id: work_package_id) |> Conn.halt()
    end
  end

  defp handle_package_browser_authorization({:error, reason}, conn, work_package_id) do
    conn |> package_browser_error_response(reason, work_package_id) |> Conn.halt()
  end

  @spec local_operator_session?(map()) :: boolean()
  def local_operator_session?(session) when is_map(session), do: Map.get(session, @operator_session_key) == true
  def local_operator_session?(_session), do: false

  @spec local_operator_browser?(Conn.t()) :: boolean()
  def local_operator_browser?(%Conn{} = conn) do
    local_operator_session_browser?(conn) and
      same_origin_browser_request?(conn) and
      local_operator_session_bootstrapped?(conn)
  end

  @spec local_operator_live_connect_info?(map()) :: boolean()
  def local_operator_live_connect_info?(connect_info) when is_map(connect_info) do
    peer_data = Map.get(connect_info, :peer_data) || Map.get(connect_info, "peer_data")
    uri = Map.get(connect_info, :uri) || Map.get(connect_info, "uri")
    x_headers = Map.get(connect_info, :x_headers) || Map.get(connect_info, "x_headers") || []

    local_operator_enabled?() and
      loopback_request?(peer_address(peer_data)) and
      local_host?(uri_host(uri)) and
      no_forwarded_x_headers?(x_headers)
  end

  def local_operator_live_connect_info?(_connect_info), do: false

  defp local_operator_session_browser?(%Conn{} = conn) do
    local_operator_enabled?() and loopback_request?(conn.remote_ip) and local_host?(conn.host) and direct_local_request?(conn)
  end

  @spec local_operator_enabled?() :: boolean()
  def local_operator_enabled? do
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])

    truthy_config?(Keyword.get(endpoint_config, :sympp_local_operator)) or
      truthy_config?(Application.get_env(:symphony_elixir, :sympp_local_operator))
  end

  defp truthy_config?(value), do: value in [true, :enabled, "enabled", "true", "1", 1]

  defp loopback_request?({127, _second, _third, _fourth}), do: true
  defp loopback_request?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_request?(_remote_ip), do: false

  defp local_host?(host) when is_binary(host) do
    host = String.downcase(host)
    host in ["localhost", "127.0.0.1", "::1", "[::1]"] or String.ends_with?(host, ".localhost")
  end

  defp local_host?(_host), do: false

  defp peer_address(%{address: address}), do: address
  defp peer_address(%{"address" => address}), do: address
  defp peer_address(_peer_data), do: nil

  defp uri_host(%URI{host: host}), do: host
  defp uri_host(%{host: host}), do: host
  defp uri_host(%{"host" => host}), do: host
  defp uri_host(_uri), do: nil

  defp no_forwarded_x_headers?(headers) when is_list(headers) do
    Enum.all?(headers, fn
      {name, _value} when is_binary(name) -> not forwarded_x_header?(name)
      _header -> true
    end)
  end

  defp no_forwarded_x_headers?(_headers), do: false

  defp forwarded_x_header?(name) do
    name |> String.downcase() |> then(&(&1 in ["x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "x-real-ip"]))
  end

  defp direct_local_request?(conn) do
    not forwarded_request?(conn)
  end

  defp forwarded_request?(conn) do
    Enum.any?(["forwarded", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "x-real-ip"], fn header ->
      Conn.get_req_header(conn, header) != []
    end)
  end

  defp same_origin_browser_request?(conn) do
    fetch_site = conn |> Conn.get_req_header("sec-fetch-site") |> List.first()

    case conn |> Conn.get_req_header("origin") |> List.first() do
      origin when is_binary(origin) ->
        trusted_origin_header?(conn, origin, fetch_site)

      nil ->
        browser_same_origin_metadata?(conn, fetch_site)
    end
  end

  defp trusted_origin_header?(conn, origin, fetch_site) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        origin = %URI{scheme: scheme, host: host, port: port}

        cond do
          same_request_origin?(conn, origin) -> fetch_site in [nil, "none", "same-origin"]
          configured_dashboard_origin?(origin) -> fetch_site in [nil, "none", "same-origin", "same-site"]
          true -> false
        end

      _parsed ->
        false
    end
  end

  defp same_request_origin?(conn, %URI{scheme: scheme, host: host, port: port}) do
    local_host?(host) and String.downcase(host) == String.downcase(conn.host) and scheme == Atom.to_string(conn.scheme) and
      normalize_origin_port(scheme, port) == conn.port
  end

  defp configured_dashboard_origin?(%URI{} = origin) do
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])

    endpoint_config
    |> Keyword.get(:sympp_dashboard_origin)
    |> configured_dashboard_origin()
    |> origin_matches?(origin)
  end

  defp configured_dashboard_origin(origin) when is_binary(origin) do
    case URI.parse(String.trim_trailing(origin, "/")) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) and scheme == "http" ->
        %URI{scheme: scheme, host: host, port: port}
        |> require_local_origin()

      _parsed ->
        nil
    end
  end

  defp configured_dashboard_origin(_origin), do: nil

  defp require_local_origin(%URI{host: host} = origin) do
    if local_host?(host), do: origin
  end

  defp origin_matches?(%URI{scheme: expected_scheme, host: expected_host, port: expected_port}, %URI{
         scheme: actual_scheme,
         host: actual_host,
         port: actual_port
       })
       when is_binary(actual_scheme) and is_binary(actual_host) do
    String.downcase(actual_scheme) == String.downcase(expected_scheme) and
      local_hosts_match?(actual_host, expected_host) and
      normalize_origin_port(actual_scheme, actual_port) == normalize_origin_port(expected_scheme, expected_port)
  end

  defp origin_matches?(_expected_origin, _actual_origin), do: false

  defp local_hosts_match?(actual_host, expected_host) do
    actual_host = String.downcase(actual_host)
    expected_host = String.downcase(expected_host)

    actual_host == expected_host or (local_host?(actual_host) and local_host?(expected_host))
  end

  defp browser_navigation_request?(conn) do
    mode = conn |> Conn.get_req_header("sec-fetch-mode") |> List.first()
    is_nil(mode) or mode == "navigate"
  end

  defp browser_same_origin_metadata?(conn, "none"), do: browser_navigation_request?(conn)

  defp browser_same_origin_metadata?(conn, "same-origin") do
    mode = conn |> Conn.get_req_header("sec-fetch-mode") |> List.first()
    destination = conn |> Conn.get_req_header("sec-fetch-dest") |> List.first()

    mode in ["cors", "same-origin"] and destination in [nil, "empty"]
  end

  defp browser_same_origin_metadata?(_conn, _fetch_site), do: false

  defp normalize_origin_port("http", nil), do: 80
  defp normalize_origin_port("https", nil), do: 443
  defp normalize_origin_port(_scheme, port), do: port

  defp local_operator_session_bootstrapped?(conn) do
    fetched_active_local_operator_session?(conn) or
      valid_local_operator_bootstrap?(conn) or
      local_operator_config_request?(conn)
  end

  defp local_operator_config_request?(conn) do
    conn.method == "GET" and
      conn.request_path == prefixed_path(conn, "/api/v1/sympp/operator/config")
  end

  defp valid_local_operator_bootstrap?(conn) do
    with expected when is_binary(expected) <- configured_operator_bootstrap_token(),
         supplied when is_binary(supplied) <- request_param(conn, @operator_bootstrap_param),
         true <- byte_size(supplied) == byte_size(expected) do
      Plug.Crypto.secure_compare(supplied, expected)
    else
      _value -> false
    end
  end

  defp configured_operator_bootstrap_token do
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])

    case Keyword.get(endpoint_config, @operator_bootstrap_config_key) do
      token when is_binary(token) and token != "" -> token
      _token -> nil
    end
  end

  defp request_param(conn, key) do
    conn
    |> Conn.fetch_query_params()
    |> then(&(Map.get(&1.params, key) || Map.get(&1.query_params, key)))
  end

  defp active_local_operator_session?(conn), do: Conn.get_session(conn, @operator_session_key) == true

  defp work_key_login_requested?(conn), do: Map.get(conn.params, "auth") == "work_key"

  defp authorize_operator_package_route(conn, work_package_id) do
    case package_route_status(work_package_id) do
      :exists -> put_local_operator_session(conn)
      :missing -> conn |> package_not_found_response() |> Conn.halt()
      {:error, reason} -> conn |> package_browser_error_response(reason, work_package_id) |> Conn.halt()
    end
  end

  defp package_route_status(work_package_id) do
    case with_dashboard_repo(fn repo -> WorkPackageRepository.get(repo, work_package_id) end) do
      {:ok, _work_package} -> :exists
      {:error, :not_found} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  @spec put_local_operator_session(Conn.t()) :: Conn.t()
  def put_local_operator_session(conn) do
    conn
    |> clear_board_session()
    |> Conn.put_session(@operator_session_key, true)
  end

  @spec authorize_board_request(Conn.t()) :: {:ok, AccessGrant.t()} | {:error, term()}
  def authorize_board_request(conn) do
    with {:error, :unauthorized} <- conn |> Conn.get_session(@board_session_key) |> authorize_board_grant_id() do
      case bearer_secret(conn) do
        nil -> {:error, :unauthorized}
        secret -> authorize_board_secret(secret)
      end
    end
  end

  @spec authorize_package_request(Conn.t(), term()) :: {:ok, AccessGrant.t()} | {:error, term()}
  def authorize_package_request(_conn, work_package_id) when not is_binary(work_package_id), do: {:error, :not_found}

  def authorize_package_request(conn, work_package_id) do
    cond do
      not valid_package_route_id?(work_package_id) -> {:error, :not_found}
      is_binary(bearer_secret(conn)) -> authorize_package_secret(bearer_secret(conn), work_package_id)
      true -> authorize_package_session(conn, work_package_id)
    end
  end

  @spec authorize_board_session(map()) :: :ok | {:error, term()}
  def authorize_board_session(session) when is_map(session) do
    session
    |> Map.get(@board_session_key)
    |> authorize_board_grant_id()
    |> case do
      {:ok, %AccessGrant{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec normalize_package_route_id(term()) :: term()
  def normalize_package_route_id(work_package_id) when is_binary(work_package_id), do: work_package_id
  def normalize_package_route_id(work_package_id), do: work_package_id

  @spec board_session(Conn.t(), map()) :: Conn.t()
  def board_session(conn, %{"work_key" => secret}) when is_binary(secret) do
    secret = String.trim(secret)

    case authorize_board_secret(secret) do
      {:ok, %AccessGrant{} = grant} ->
        conn
        |> Conn.put_session(@board_session_key, grant.id)
        |> Conn.delete_session(@operator_session_key)
        |> redirect(to: prefixed_path(conn, "/sympp/board"))

      {:error, :forbidden} ->
        conn
        |> clear_board_session()
        |> board_login_response(status: 403, message: "The work key is not allowed to open the board.")
        |> Conn.halt()

      {:error, :database_busy} ->
        conn |> clear_board_session() |> board_login_response(status: 503, message: "The dashboard ledger is busy. Try again.") |> Conn.halt()

      {:error, {:storage_failed, _reason}} ->
        conn |> clear_board_session() |> board_login_response(status: 503, message: "The board ledger could not be read.") |> Conn.halt()

      {:error, {:repo_start_failed, _reason}} ->
        conn |> clear_board_session() |> board_login_response(status: 503, message: "The board ledger could not be opened.") |> Conn.halt()

      {:error, _reason} ->
        conn |> clear_board_session() |> board_login_response(status: 401, message: "The work key could not access the board.") |> Conn.halt()
    end
  end

  def board_session(conn, _params) do
    conn |> board_login_response(status: 400, message: "Enter a work key to open the board.") |> Conn.halt()
  end

  @spec package_session(Conn.t(), map()) :: Conn.t()
  def package_session(conn, %{"work_package_id" => work_package_id, "work_key" => secret})
      when is_binary(work_package_id) and is_binary(secret) do
    work_package_id = normalize_package_route_id(work_package_id)
    secret = String.trim(secret)

    case authorize_package_secret(secret, work_package_id) do
      {:ok, %AccessGrant{} = grant} ->
        conn
        |> put_package_browser_session(grant, work_package_id)
        |> Conn.delete_session(@operator_session_key)
        |> redirect(to: package_detail_path(conn, work_package_id))

      {:error, :forbidden} ->
        conn
        |> clear_package_session(work_package_id)
        |> package_login_response(status: 403, message: "The work key is not allowed to open this package.", work_package_id: work_package_id)
        |> Conn.halt()

      {:error, :database_busy} ->
        conn
        |> clear_package_session(work_package_id)
        |> package_login_response(status: 503, message: "The dashboard ledger is busy. Try again.", work_package_id: work_package_id)
        |> Conn.halt()

      {:error, {:storage_failed, _reason}} ->
        conn
        |> clear_package_session(work_package_id)
        |> package_login_response(status: 503, message: "The package ledger could not be read.", work_package_id: work_package_id)
        |> Conn.halt()

      {:error, {:repo_start_failed, _reason}} ->
        conn
        |> clear_package_session(work_package_id)
        |> package_login_response(status: 503, message: "The package ledger could not be opened.", work_package_id: work_package_id)
        |> Conn.halt()

      {:error, :not_found} ->
        conn
        |> clear_package_session(work_package_id)
        |> package_not_found_response()
        |> Conn.halt()

      {:error, _reason} ->
        conn
        |> clear_package_session(work_package_id)
        |> package_login_response(status: 401, message: "The work key could not access this package.", work_package_id: work_package_id)
        |> Conn.halt()
    end
  end

  def package_session(conn, %{"work_package_id" => work_package_id}) do
    work_package_id = normalize_package_route_id(work_package_id)

    if valid_package_route_id?(work_package_id) do
      conn
      |> clear_package_session(work_package_id)
      |> package_login_response(status: 400, message: "Enter a work key to open this package.", work_package_id: work_package_id)
      |> Conn.halt()
    else
      conn
      |> clear_package_session(work_package_id)
      |> package_not_found_response()
      |> Conn.halt()
    end
  end

  def package_session(conn, _params) do
    conn
    |> package_login_response(status: 400, message: "Enter a work key to open this package.", work_package_id: nil)
    |> Conn.halt()
  end

  @spec board(Conn.t(), map()) :: Conn.t()
  def board(conn, _params) do
    send_repo_response(conn, fn repo, secret ->
      with {:ok, auth_context} <- auth_context(conn, repo, secret),
           {:ok, payload} <- board_payload(repo, auth_context) do
        json(conn, payload)
      end
    end)
  end

  @spec work_requests(Conn.t(), map()) :: Conn.t()
  def work_requests(conn, _params) do
    send_repo_response(conn, fn repo, secret ->
      with {:ok, {:grant, %AccessGrant{} = grant} = auth_context} <- auth_context(conn, repo, secret),
           :ok <- require_work_request_board(repo, auth_context),
           {:ok, payload} <- Dashboard.work_requests_for_grant(repo, grant) do
        json(conn, payload)
      end
    end)
  end

  @spec work_request_detail(Conn.t(), map()) :: Conn.t()
  def work_request_detail(conn, %{"work_request_id" => work_request_id}) do
    send_repo_response(conn, fn repo, secret ->
      with {:ok, {:grant, %AccessGrant{} = grant} = auth_context} <- auth_context(conn, repo, secret),
           :ok <- require_work_request_board(repo, auth_context),
           {:ok, payload} <- Dashboard.work_request_detail_for_grant(repo, work_request_id, grant) do
        json(conn, payload)
      end
    end)
  end

  @spec detail(Conn.t(), map()) :: Conn.t()
  def detail(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, normalize_package_route_id(work_package_id), &Dashboard.detail/2)
  end

  @spec timeline(Conn.t(), map()) :: Conn.t()
  def timeline(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, normalize_package_route_id(work_package_id), &Dashboard.timeline/2)
  end

  @spec artifacts(Conn.t(), map()) :: Conn.t()
  def artifacts(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, normalize_package_route_id(work_package_id), &Dashboard.artifacts/2)
  end

  @spec blockers(Conn.t(), map()) :: Conn.t()
  def blockers(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, normalize_package_route_id(work_package_id), &Dashboard.blockers/2)
  end

  @spec grants(Conn.t(), map()) :: Conn.t()
  def grants(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, normalize_package_route_id(work_package_id), &Dashboard.grants/2)
  end

  @spec agent_runs(Conn.t(), map()) :: Conn.t()
  def agent_runs(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, normalize_package_route_id(work_package_id), &Dashboard.agent_runs/2)
  end

  @spec operator_dashboard(Conn.t(), map()) :: Conn.t()
  def operator_dashboard(conn, _params) do
    send_local_operator_response(conn, :dashboard_read, Target.new(:dashboard), :operator_dashboard, fn repo ->
      with {:ok, payload} <- LocalOperatorDashboard.operator_dashboard_payload(repo) do
        json(conn, payload)
      end
    end)
  end

  @spec operator_config(Conn.t(), map()) :: Conn.t()
  def operator_config(conn, _params) do
    with {:ok, conn} <- ensure_local_operator_api_session(conn),
         {:ok, %Decision{}} <- authorize_local_operator_policy(conn, :dashboard_read, Target.new(:dashboard)) do
      json(conn, operator_runtime_config(conn))
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  @spec operator_options(Conn.t(), map()) :: Conn.t()
  def operator_options(conn, _params) do
    send_resp(conn, 204, "")
  end

  @spec operator_package_detail(Conn.t(), map()) :: Conn.t()
  def operator_package_detail(conn, %{"work_package_id" => work_package_id}) do
    send_local_operator_response(
      conn,
      :work_package_read,
      work_package_target(work_package_id),
      :operator_package_detail,
      fn repo ->
        with {:ok, repo_identity_catalog} <- Dashboard.local_operator_repo_identity_catalog(repo),
             {:ok, payload} <-
               Dashboard.detail(repo, normalize_package_route_id(work_package_id), repo_identity_catalog: repo_identity_catalog) do
          json(conn, payload)
        end
      end
    )
  end

  @spec operator_work_request_detail(Conn.t(), map()) :: Conn.t()
  def operator_work_request_detail(conn, %{"work_request_id" => work_request_id}) do
    send_local_operator_response(
      conn,
      :dashboard_read,
      Target.new(:dashboard),
      :operator_work_request_detail,
      fn repo ->
        with {:ok, repo_identity_catalog} <- Dashboard.local_operator_repo_identity_catalog(repo),
             detail_opts = [repo_identity_catalog: repo_identity_catalog],
             {:ok, payload} <- Dashboard.work_request_detail(repo, work_request_id, detail_opts) do
          json(conn, payload)
        end
      end
    )
  end

  @spec operator_sync_github_prs(Conn.t(), map()) :: Conn.t()
  def operator_sync_github_prs(conn, params) do
    send_local_operator_response(conn, :delivery_reconcile_apply, Target.new(:dashboard), :operator_sync_github_prs, fn repo ->
      with {:ok, sync} <- MergeReconciler.reconcile(repo, github_sync_opts(params)) do
        json(conn, mutation_success_payload(%{sync: sync}))
      end
    end)
  end

  @spec operator_solo_session_detail(Conn.t(), map()) :: Conn.t()
  def operator_solo_session_detail(conn, %{"solo_session_id" => solo_session_id}) do
    send_local_operator_response(conn, :dashboard_read, Target.new(:dashboard), :operator_solo_session_detail, fn repo ->
      with {:ok, repo_identity_catalog} <- Dashboard.local_operator_repo_identity_catalog(repo),
           {:ok, payload} <-
             Dashboard.solo_session_detail(repo, solo_session_id, repo_identity_catalog: repo_identity_catalog) do
        json(conn, payload)
      end
    end)
  end

  @spec operator_create_work_request(Conn.t(), map()) :: Conn.t()
  def operator_create_work_request(conn, params) do
    send_local_operator_response(conn, :work_request_update, Target.ledger(), :operator_create_work_request, fn repo ->
      attrs = LocalOperatorDashboard.work_request_attrs(params)

      with {:ok, work_request} <- WorkRequestService.create(repo, attrs),
           {:ok, detail} <- LocalOperatorDashboard.operator_work_request_detail_payload(repo, work_request.id) do
        conn
        |> put_status(201)
        |> json(mutation_success_payload(%{work_request: detail}, %{work_request_id: work_request.id}))
      end
    end)
  end

  @spec operator_update_settings(Conn.t(), map()) :: Conn.t()
  def operator_update_settings(conn, params) do
    send_local_operator_response(conn, :dangerous_override, Target.ledger(), :operator_update_settings, fn repo ->
      with {:ok, settings} <- OperatorSettingsRepository.update(repo, LocalOperatorDashboard.operator_settings_attrs(params)),
           :ok <- LocalOperatorDashboard.run_operator_retention(repo, settings, force: true) do
        json(conn, mutation_success_payload(%{settings: LocalOperatorDashboard.operator_settings_payload(settings)}))
      end
    end)
  end

  @spec operator_archive_work_request(Conn.t(), map()) :: Conn.t()
  def operator_archive_work_request(conn, %{"work_request_id" => work_request_id}) do
    send_local_operator_response(
      conn,
      :dangerous_delete,
      work_request_target(work_request_id),
      :operator_archive_work_request,
      fn repo ->
        with {:ok, work_request} <- WorkRequestService.archive(repo, work_request_id) do
          json(conn, mutation_success_payload(%{work_request: LocalOperatorDashboard.work_request_mutation_payload(work_request)}, %{work_request_id: work_request.id}))
        end
      end
    )
  end

  @spec operator_restore_work_request(Conn.t(), map()) :: Conn.t()
  def operator_restore_work_request(conn, %{"work_request_id" => work_request_id}) do
    send_local_operator_response(
      conn,
      :dangerous_override,
      work_request_target(work_request_id),
      :operator_restore_work_request,
      fn repo ->
        with {:ok, work_request} <- WorkRequestService.restore(repo, work_request_id) do
          json(conn, mutation_success_payload(%{work_request: LocalOperatorDashboard.archived_work_request_payload(work_request)}, %{work_request_id: work_request.id}))
        end
      end
    )
  end

  @spec operator_update_work_request_state(Conn.t(), map()) :: Conn.t()
  def operator_update_work_request_state(conn, %{"work_request_id" => work_request_id} = params) do
    send_local_operator_response(
      conn,
      :dangerous_override,
      work_request_target(work_request_id),
      :operator_update_work_request_state,
      fn repo ->
        with {:ok, "completed"} <- local_operator_work_request_state(params),
             {:ok, work_request} <- WorkRequestService.force_complete(repo, work_request_id) do
          json(conn, mutation_success_payload(%{work_request: LocalOperatorDashboard.work_request_mutation_payload(work_request)}, %{dashboard: false, work_request_id: work_request.id}))
        end
      end
    )
  end

  @spec operator_update_work_package_state(Conn.t(), map()) :: Conn.t()
  def operator_update_work_package_state(conn, %{"work_package_id" => work_package_id} = params) do
    send_local_operator_response(
      conn,
      :dangerous_override,
      work_package_target(work_package_id),
      :operator_update_work_package_state,
      fn repo ->
        with {:ok, action} <- local_operator_work_package_status(params),
             {:ok, work_package} <-
               change_work_package_for_local_operator(
                 repo,
                 normalize_package_route_id(work_package_id),
                 action,
                 params
               ) do
          json(conn, mutation_success_payload(%{work_package_id: work_package.id}, %{work_package_id: work_package.id}))
        end
      end
    )
  end

  @spec operator_clear_work_package_blocker(Conn.t(), map()) :: Conn.t()
  def operator_clear_work_package_blocker(conn, %{"work_package_id" => work_package_id, "blocker_id" => blocker_id} = params) do
    send_local_operator_response(
      conn,
      :dangerous_override,
      work_package_target(work_package_id),
      :operator_clear_work_package_blocker,
      fn repo ->
        work_package_id = normalize_package_route_id(work_package_id)

        with {:ok, event} <- clear_work_package_blocker_for_local_operator(repo, work_package_id, blocker_id, params) do
          json(conn, mutation_success_payload(%{progress_event: %{id: event.id, blocker_id: blocker_id}}, %{work_package_id: work_package_id}))
        end
      end
    )
  end

  @spec operator_archive_work_package(Conn.t(), map()) :: Conn.t()
  def operator_archive_work_package(conn, %{"work_package_id" => work_package_id}) do
    send_local_operator_response(
      conn,
      :dangerous_delete,
      work_package_target(work_package_id),
      :operator_archive_work_package,
      fn repo ->
        work_package_id = normalize_package_route_id(work_package_id)

        with {:ok, work_package} <- hide_work_package_for_local_operator(repo, work_package_id) do
          json(conn, mutation_success_payload(%{work_package_id: work_package.id}, %{work_package_id: work_package.id}))
        end
      end
    )
  end

  @spec operator_create_comment(Conn.t(), map()) :: Conn.t()
  def operator_create_comment(conn, params) do
    send_local_operator_response(conn, :comment_add, comment_target(params), :operator_create_comment, fn repo ->
      with {:ok, comment} <- CommentService.create(repo, local_operator_comment_attrs(params)) do
        refresh = %{comment_target_kind: comment.target_kind, comment_target_id: comment.target_id}

        conn
        |> put_status(201)
        |> json(mutation_success_payload(%{comment: comment_payload(comment)}, refresh))
      end
    end)
  end

  @spec operator_resolve_comment(Conn.t(), map()) :: Conn.t()
  def operator_resolve_comment(conn, %{"comment_id" => comment_id} = params) do
    send_local_operator_response(
      conn,
      :comment_resolve,
      Target.new(:comment, comment_id),
      :operator_resolve_comment,
      fn repo ->
        with {:ok, comment} <-
               CommentService.resolve(repo, comment_id, local_operator_comment_resolution_attrs(params)) do
          refresh = %{comment_target_kind: comment.target_kind, comment_target_id: comment.target_id}

          json(conn, mutation_success_payload(%{comment: comment_payload(comment)}, refresh))
        end
      end
    )
  end

  @spec operator_answer_question(Conn.t(), map()) :: Conn.t()
  def operator_answer_question(conn, %{"work_request_id" => work_request_id, "question_id" => question_id} = params) do
    send_local_operator_response(
      conn,
      :question_answer,
      work_request_target(work_request_id),
      :operator_answer_question,
      fn repo ->
        with {:ok, question} <- scoped_question(repo, work_request_id, question_id),
             :ok <- require_open_question(question),
             {:ok, attrs} <- local_operator_question_answer_attrs(question, params),
             {:ok, _answered} <- WorkRequestService.answer_question(repo, question.id, question.status, attrs) do
          json(conn, mutation_success_payload(%{work_request_id: work_request_id, question_id: question.id}, %{work_request_id: work_request_id}))
        end
      end
    )
  end

  @spec operator_answer_guidance(Conn.t(), map()) :: Conn.t()
  def operator_answer_guidance(conn, %{"work_package_id" => work_package_id, "guidance_request_id" => guidance_request_id} = params) do
    send_local_operator_response(
      conn,
      :guidance_request_answer,
      guidance_request_target(work_package_id, guidance_request_id),
      :operator_answer_guidance,
      fn repo ->
        attrs = Map.put(params, "work_package_id", work_package_id)

        with {:ok, result} <-
               GuidanceRequestService.answer_human_info_needed_for_local_operator(
                 repo,
                 :local_operator,
                 guidance_request_id,
                 attrs
               ) do
          json(conn, mutation_success_payload(%{guidance_request_id: result.guidance_request.id}, %{work_package_id: work_package_id}))
        end
      end
    )
  end

  @spec operator_create_architect_handoff(Conn.t(), map()) :: Conn.t()
  def operator_create_architect_handoff(conn, %{"work_request_id" => work_request_id}) do
    send_local_operator_response(
      conn,
      :dangerous_rekey,
      work_request_target(work_request_id),
      :operator_create_architect_handoff,
      fn repo ->
        with {:ok, handoff} <-
               ArchitectHandoff.create_or_replay(repo, work_request_id,
                 local_operator?: true,
                 handoff_opts: architect_handoff_opts(repo)
               ) do
          json(conn, mutation_success_payload(%{architect_handoff: handoff}, %{work_request_id: work_request_id}))
        end
      end
    )
  end

  @spec operator_dispatch_planned_slice(Conn.t(), map()) :: Conn.t()
  def operator_dispatch_planned_slice(conn, %{"work_request_id" => work_request_id, "planned_slice_id" => planned_slice_id}) do
    send_local_operator_response(
      conn,
      :planned_slice_dispatch,
      planned_slice_target(work_request_id, planned_slice_id),
      :operator_dispatch_planned_slice,
      fn repo ->
        with {:ok, dispatch} <-
               PlannedSliceDispatch.dispatch(repo, work_request_id, planned_slice_id, dispatch_handoff_opts(repo)) do
          refresh = %{work_request_id: work_request_id, planned_slice_id: planned_slice_id}
          payload = %{dispatch: PlannedSliceDispatch.response_payload(dispatch)}

          json(conn, mutation_success_payload(payload, refresh))
        end
      end
    )
  end

  defp send_package_response(conn, work_package_id, fetch_fun) do
    send_repo_response(conn, fn repo, secret ->
      with {:ok, auth_context} <- auth_context(conn, repo, secret),
           :ok <- require_work_package(repo, auth_context, work_package_id),
           {:ok, payload} <- fetch_fun.(repo, work_package_id) do
        json(conn, ScopeProjection.scoped_package_payload(auth_context, payload))
      end
    end)
  end

  defp send_repo_response(conn, fun) when is_function(fun, 2) do
    case bearer_secret(conn) do
      nil -> {:error, :unauthorized}
      secret -> send_authenticated_repo_response(secret, fun)
    end
    |> case do
      {:error, reason} -> error_response(conn, reason)
      %Conn{} = conn -> conn
    end
  end

  defp send_local_operator_response(conn, action, %Target{} = target, tool_name, fun)
       when is_atom(action) and is_atom(tool_name) and is_function(fun, 1) do
    if local_operator_api_request?(conn) do
      with_dashboard_repo(fn repo ->
        local_operator_response(repo, conn, action, target, tool_name, fun)
      end)
      |> case do
        {:error, reason} -> error_response(conn, reason)
        %Conn{} = conn -> conn
      end
    else
      error_response(conn, :unauthorized)
    end
  end

  defp local_operator_response(repo, conn, action, %Target{} = target, tool_name, fun) do
    decision = local_operator_actor(conn) |> Policy.decide(action, target)

    with :ok <- maybe_append_operator_audit(repo, conn, decision, tool_name),
         :ok <- require_allowed_local_operator_decision(decision) do
      fun.(repo)
    end
  end

  defp authorize_local_operator_policy(conn, action, %Target{} = target) when is_atom(action) do
    conn
    |> local_operator_actor()
    |> Policy.decide(action, target)
    |> case do
      %Decision{allowed?: true} = decision -> {:ok, decision}
      %Decision{} = decision -> {:error, {:authorization_policy_denied, decision}}
    end
  end

  defp require_allowed_local_operator_decision(%Decision{allowed?: true}), do: :ok
  defp require_allowed_local_operator_decision(%Decision{} = decision), do: {:error, {:authorization_policy_denied, decision}}

  defp maybe_append_operator_audit(repo, conn, %Decision{} = decision, tool_name) do
    if dangerous_audit_decision?(decision) do
      case OperatorAudit.append(repo, decision, operator_request_metadata(conn), operator_tool_metadata(tool_name)) do
        {:ok, %OperatorAudit{}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp dangerous_audit_decision?(%Decision{} = decision) do
    case Map.get(decision, :audit) do
      audit when is_map(audit) ->
        Map.get(audit, :dangerous_action) == true or Map.get(audit, "dangerous_action") == true

      _audit ->
        false
    end
  end

  defp local_operator_actor(%Conn{} = conn) do
    ActorResolver.local_operator(@local_operator_actor,
      metadata: %{
        source: :dashboard,
        request_path: conn.request_path
      }
    )
  end

  defp operator_request_metadata(%Conn{} = conn) do
    %{
      method: conn.method,
      path: conn.request_path,
      host: conn.host,
      remote_ip: conn |> Map.get(:remote_ip) |> remote_ip_string()
    }
  end

  defp operator_tool_metadata(tool_name) when is_atom(tool_name) do
    %{name: Atom.to_string(tool_name)}
  end

  defp remote_ip_string(remote_ip) when is_tuple(remote_ip) do
    remote_ip
    |> :inet.ntoa()
    |> to_string()
  rescue
    _error -> nil
  end

  defp remote_ip_string(_remote_ip), do: nil

  defp work_request_target(work_request_id), do: Target.work_request(work_request_id)

  defp work_package_target(work_package_id) do
    work_package_id
    |> normalize_package_route_id()
    |> Target.work_package()
  end

  defp planned_slice_target(work_request_id, planned_slice_id), do: Target.planned_slice(planned_slice_id, work_request_id)

  defp guidance_request_target(work_package_id, guidance_request_id) do
    work_package_id
    |> normalize_package_route_id()
    |> then(&Target.package_resource(:guidance_request, &1, id: guidance_request_id))
  end

  defp comment_target(params) do
    target_id = text_param(params, "target_id")
    Target.new(:comment, target_id)
  end

  defp local_operator_api_request?(conn) do
    local_operator_browser?(conn) and fetched_active_local_operator_session?(conn)
  end

  defp ensure_local_operator_api_session(conn) do
    cond do
      local_operator_api_request?(conn) -> {:ok, conn}
      local_operator_browser?(conn) -> {:ok, put_local_operator_session(conn)}
      true -> {:error, :unauthorized}
    end
  end

  defp operator_runtime_config(conn) do
    %{
      apiBase: prefixed_path(conn, "/api/v1/sympp/operator"),
      basePath: script_name_prefix(conn),
      csrfToken: Plug.CSRFProtection.get_csrf_token(),
      logoUrl: prefixed_path(conn, "/splusplus-logo.png"),
      operatorMode: local_operator_api_request?(conn)
    }
  end

  defp mutation_success_payload(payload, refresh \\ %{}) when is_map(payload) and is_map(refresh) do
    payload
    |> Map.put(:ok, true)
    |> Map.put(:refresh, Map.merge(%{dashboard: true}, refresh))
  end

  defp script_name_prefix(%Conn{script_name: []}), do: ""
  defp script_name_prefix(%Conn{script_name: script_name}), do: "/" <> Enum.join(script_name, "/")

  defp fetched_active_local_operator_session?(conn) do
    conn
    |> Conn.fetch_session()
    |> active_local_operator_session?()
  end

  defp local_operator_work_request_state(params) do
    case text_param(params, "state") || text_param(params, "status") do
      "completed" -> {:ok, "completed"}
      _state -> {:error, :invalid_status}
    end
  end

  defp local_operator_work_package_status(params) do
    case text_param(params, "status") do
      "merged" -> {:ok, :merged}
      "merged_and_archive" -> {:ok, :merged_and_archive}
      "closed_and_archive" -> {:ok, :closed_and_archive}
      "completed_no_pr" -> {:ok, :completed_no_pr}
      _status -> {:error, :invalid_status}
    end
  end

  defp change_work_package_for_local_operator(repo, work_package_id, :merged, _params) do
    mark_work_package_merged_and_refresh_for_local_operator(repo, work_package_id)
  end

  defp change_work_package_for_local_operator(repo, work_package_id, :merged_and_archive, _params) do
    local_operator_transaction(repo, fn ->
      with {:ok, work_package} <- mark_work_package_merged_for_local_operator(repo, work_package_id),
           :ok <- refresh_work_requests_for_work_package(repo, work_package.id),
           {:ok, _hidden_package} <- hide_work_package_for_local_operator_in_transaction(repo, work_package) do
        {:ok, work_package}
      end
    end)
  end

  defp change_work_package_for_local_operator(repo, work_package_id, :closed_and_archive, _params) do
    local_operator_transaction(repo, fn ->
      with {:ok, work_package} <- close_work_package_for_local_operator(repo, work_package_id),
           {:ok, _hidden_package} <- hide_work_package_for_local_operator_in_transaction(repo, work_package) do
        {:ok, work_package}
      end
    end)
  end

  defp change_work_package_for_local_operator(repo, work_package_id, :completed_no_pr, params) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         :ok <- require_closeable_work_package(work_package),
         {:ok, no_pr_evidence} <- required_no_pr_evidence(params),
         {:ok, planned_slice} <- linked_planned_slice_for_work_package(repo, work_package_id),
         {:ok, _delivery} <-
           WorkRequestService.record_planned_slice_delivery(repo, planned_slice.work_request_id, planned_slice.id, %{
             outcome: "completed_no_pr",
             idempotency_key: completed_no_pr_idempotency_key(planned_slice.id),
             no_pr_evidence: no_pr_evidence,
             recorded_by: @local_operator_actor
           }) do
      WorkPackageRepository.get(repo, work_package_id)
    end
  end

  defp mark_work_package_merged_and_refresh_for_local_operator(repo, work_package_id) do
    local_operator_transaction(repo, fn ->
      with {:ok, work_package} <- mark_work_package_merged_for_local_operator(repo, work_package_id),
           :ok <- refresh_work_requests_for_work_package(repo, work_package.id) do
        {:ok, work_package}
      end
    end)
  end

  defp mark_work_package_merged_for_local_operator(repo, work_package_id) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
      case work_package.status do
        "merged" ->
          {:ok, work_package}

        status when status in @local_operator_nonmergeable_terminal_package_statuses ->
          {:error, :invalid_status}

        status when is_binary(status) ->
          WorkPackageRepository.update_status(repo, work_package.id, status, "merged")

        _status ->
          {:error, :invalid_status}
      end
    end
  end

  defp close_work_package_for_local_operator(repo, work_package_id) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
      case work_package.status do
        "closed" ->
          {:ok, work_package}

        status when status in @local_operator_noncloseable_terminal_package_statuses ->
          {:error, :invalid_status}

        status when is_binary(status) ->
          WorkPackageRepository.update_status(repo, work_package.id, status, "closed")

        _status ->
          {:error, :invalid_status}
      end
    end
  end

  defp require_closeable_work_package(%WorkPackage{status: status})
       when status in @local_operator_noncloseable_terminal_package_statuses do
    {:error, :invalid_status}
  end

  defp require_closeable_work_package(%WorkPackage{status: status}) when is_binary(status), do: :ok
  defp require_closeable_work_package(%WorkPackage{}), do: {:error, :invalid_status}

  defp hide_work_package_for_local_operator(repo, work_package_id) do
    local_operator_transaction(repo, fn ->
      with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
        hide_work_package_for_local_operator_in_transaction(repo, work_package)
      end
    end)
  end

  defp hide_work_package_for_local_operator_in_transaction(repo, %WorkPackage{} = work_package) do
    with :ok <- require_hideable_work_package(work_package),
         :ok <- require_unlinked_work_package(repo, work_package.id),
         {:ok, _settings} <- append_hidden_work_package_id_for_local_operator(repo, work_package.id) do
      {:ok, work_package}
    end
  end

  defp require_hideable_work_package(%WorkPackage{status: status}) do
    if status in @local_operator_hideable_package_statuses, do: :ok, else: {:error, :not_delivered}
  end

  defp require_unlinked_work_package(repo, work_package_id) do
    linked? =
      repo.exists?(
        from(planned_slice in PlannedSlice,
          where: planned_slice.work_package_id == ^work_package_id
        )
      )

    if linked?, do: {:error, :linked_work_package}, else: :ok
  end

  defp linked_planned_slice_for_work_package(repo, work_package_id) do
    repo.one(
      from(planned_slice in PlannedSlice,
        where: planned_slice.work_package_id == ^work_package_id
      )
    )
    |> case do
      %PlannedSlice{} = planned_slice -> {:ok, planned_slice}
      nil -> {:error, :linked_work_package_required}
    end
  end

  defp required_no_pr_evidence(params) do
    case text_param(params, "no_pr_evidence") do
      nil -> {:error, :missing_no_pr_evidence}
      evidence -> {:ok, evidence}
    end
  end

  defp completed_no_pr_idempotency_key(planned_slice_id), do: "local-operator-completed-no-pr:#{planned_slice_id}"

  defp clear_work_package_blocker_for_local_operator(repo, work_package_id, blocker_id, params) do
    blocker_id = String.trim(to_string(blocker_id || ""))

    with true <- valid_package_route_id?(work_package_id),
         true <- blocker_id != "",
         {:ok, _work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, work_package_id),
         {:ok, blocker} <- active_blocker(progress_events, blocker_id) do
      PlanningRepository.append_progress_event(repo, %{
        work_package_id: work_package_id,
        summary: "Cleared blocker: #{blocker.summary || blocker.id}",
        body: text_param(params, "resolution") || "Cleared by local operator from the blocker detail modal.",
        status: "resolved",
        idempotency_key: "local-operator-clear-blocker:#{work_package_id}:#{blocker.id}:#{blocker.event_id}",
        payload: %{
          type: "blocker",
          source_tool: "resolve_blocker",
          blocker_id: blocker.id,
          resolution: text_param(params, "resolution") || "Cleared by local operator.",
          active: false
        }
      })
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp active_blocker(progress_events, blocker_id) do
    progress_events
    |> BlockerProjection.blockers()
    |> Enum.find(&(&1.id == blocker_id and &1.active))
    |> case do
      nil -> {:error, :not_found}
      blocker -> {:ok, blocker}
    end
  end

  defp append_hidden_work_package_id_for_local_operator(_repo, work_package_id)
       when not is_binary(work_package_id) or byte_size(work_package_id) == 0 do
    {:error, :not_found}
  end

  defp append_hidden_work_package_id_for_local_operator(repo, work_package_id) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, _settings} <- ensure_operator_settings_for_local_operator(repo),
         {:ok, _settings} <- OperatorSettingsRepository.get(repo),
         {1, _rows} <-
           repo.update_all(append_hidden_work_package_id_query(work_package_id, now), []),
         %OperatorSettings{} = settings <- repo.get(OperatorSettings, OperatorSettings.settings_id()) do
      {:ok, settings}
    else
      {0, _rows} -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_operator_settings_for_local_operator(repo) do
    repo.insert(OperatorSettings.default(), on_conflict: :nothing, conflict_target: :id)
  end

  defp append_hidden_work_package_id_query(work_package_id, now) do
    from(settings in OperatorSettings,
      where: settings.id == ^OperatorSettings.settings_id(),
      update: [
        set: [
          hidden_work_package_ids:
            fragment(
              """
              CASE
                WHEN EXISTS (
                  SELECT 1
                  FROM json_each(COALESCE(?, '[]'))
                  WHERE value IS NOT NULL
                    AND value = ?
                )
                THEN COALESCE((
                  SELECT json_group_array(value)
                  FROM (
                    SELECT DISTINCT value
                    FROM json_each(COALESCE(?, '[]'))
                    WHERE value IS NOT NULL
                  )
                ), '[]')
                ELSE json_insert(
                  COALESCE((
                    SELECT json_group_array(value)
                    FROM (
                      SELECT DISTINCT value
                      FROM json_each(COALESCE(?, '[]'))
                      WHERE value IS NOT NULL
                    )
                  ), '[]'),
                  '$[#]',
                  ?
                )
              END
              """,
              settings.hidden_work_package_ids,
              ^work_package_id,
              settings.hidden_work_package_ids,
              settings.hidden_work_package_ids,
              ^work_package_id
            ),
          updated_at: ^now
        ]
      ]
    )
  end

  defp local_operator_transaction(repo, fun) when is_function(fun, 0) do
    repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_local_operator_transaction_result()
  end

  defp normalize_local_operator_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_local_operator_transaction_result({:error, reason}), do: {:error, reason}

  defp refresh_work_requests_for_work_package(repo, work_package_id) do
    with {:ok, work_requests} <- WorkRequestService.list(repo, %{include_archived: true}) do
      refresh_linked_work_requests(repo, work_requests, work_package_id)
    end
  end

  defp refresh_linked_work_requests(repo, work_requests, work_package_id) do
    Enum.reduce_while(work_requests, :ok, fn work_request, :ok ->
      repo
      |> refresh_work_request_if_linked_to_package(work_request, work_package_id)
      |> reduce_linked_work_request_refresh()
    end)
  end

  defp reduce_linked_work_request_refresh(:ok), do: {:cont, :ok}
  defp reduce_linked_work_request_refresh({:error, reason}), do: {:halt, {:error, reason}}

  defp refresh_work_request_if_linked_to_package(repo, work_request, work_package_id) do
    with {:ok, planned_slices} <- WorkRequestService.list_planned_slices(repo, work_request.id),
         true <- Enum.any?(planned_slices, &(&1.work_package_id == work_package_id)) do
      refresh_work_request_completion(repo, work_request.id)
    else
      false -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_work_request_completion(repo, work_request_id) do
    case WorkRequestService.refresh_completion(repo, work_request_id) do
      {:ok, _work_request} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp local_operator_comment_attrs(params) do
    %{
      "target_kind" => text_param(params, "target_kind"),
      "target_id" => text_param(params, "target_id"),
      "body" => text_param(params, "body"),
      "source_type" => "operator",
      "author_name" => @local_operator_actor
    }
  end

  defp local_operator_comment_resolution_attrs(params) do
    %{
      "resolved_by" => @local_operator_actor,
      "resolved_source_type" => "operator",
      "resolution_note" => text_param(params, "resolution_note", "")
    }
  end

  defp comment_payload(%Comment{} = comment) do
    %{
      id: comment.id,
      target_kind: comment.target_kind,
      target_id: comment.target_id,
      body: Redactor.redact_text(comment.body),
      source_type: comment.source_type,
      author_name: Redactor.redact_text(comment.author_name),
      status: comment.status,
      resolved_by: Redactor.redact_text(comment.resolved_by),
      resolved_source_type: comment.resolved_source_type,
      resolved_at: timestamp(comment.resolved_at),
      resolution_note: Redactor.redact_text(comment.resolution_note),
      inserted_at: timestamp(comment.inserted_at),
      updated_at: timestamp(comment.updated_at)
    }
  end

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp timestamp(nil), do: nil

  defp scoped_question(repo, work_request_id, question_id) when is_binary(work_request_id) and is_binary(question_id) do
    with {:ok, questions} <- WorkRequestService.list_questions(repo, work_request_id) do
      case Enum.find(questions, &(&1.id == question_id)) do
        %ClarificationQuestion{} = question -> {:ok, question}
        nil -> {:error, :not_found}
      end
    end
  end

  defp scoped_question(_repo, _work_request_id, _question_id), do: {:error, :not_found}

  defp require_open_question(%ClarificationQuestion{status: "open"}), do: :ok
  defp require_open_question(%ClarificationQuestion{status: "answered"}), do: {:error, :already_answered}
  defp require_open_question(%ClarificationQuestion{status: "closed"}), do: {:error, :already_closed}
  defp require_open_question(%ClarificationQuestion{}), do: {:error, :invalid_status}

  defp local_operator_question_answer_attrs(%ClarificationQuestion{} = question, params) do
    case HumanDecisionPrompt.answer_text_result(question.decision_prompt, params) do
      {:ok, answer} ->
        case String.trim(answer) do
          "" -> {:error, :missing_answer}
          answer -> {:ok, %{"answer" => answer, "answered_by" => @local_operator_actor}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp text_param(params, key, default \\ nil) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: default, else: value

      nil ->
        default

      value ->
        to_string(value)
    end
  end

  defp github_sync_opts(%{"mode" => "auto"}) do
    [
      client: Application.get_env(:symphony_elixir, :sympp_github_client, DefaultClient),
      require_authenticated_client?: true
    ]
  end

  defp github_sync_opts(_params), do: []

  defp architect_handoff_opts(repo) do
    [
      database: dashboard_ledger_database(repo),
      claimed_by: ArchitectHandoff.claimed_by(),
      local_architect_claim?: true
    ]
  end

  defp dispatch_handoff_opts(repo) do
    [
      database: dashboard_ledger_database(repo),
      claimed_by: @local_operator_worker
    ]
  end

  defp dashboard_ledger_database(repo) do
    Repo.operator_database_path(repo)
  end

  defp authorize_package_session(conn, work_package_id) do
    package_result =
      conn
      |> Conn.get_session(@package_session_key)
      |> package_session_grant_id(work_package_id)
      |> authorize_package_grant_id(work_package_id)

    board_result =
      conn
      |> Conn.get_session(@board_session_key)
      |> authorize_package_grant_id(work_package_id)

    case {package_result, board_result} do
      {_package_result, {:ok, %AccessGrant{}} = authorized} -> authorized
      {{:ok, %AccessGrant{}} = authorized, _board_result} -> authorized
      {{:error, _package_reason}, {:error, :not_found}} -> {:error, :not_found}
      {{:error, :unauthorized}, {:error, reason}} -> {:error, reason}
      {{:error, reason}, _board_result} -> {:error, reason}
    end
  end

  defp package_session_grant_id(sessions, work_package_id) when is_map(sessions) and is_binary(work_package_id) do
    Map.get(sessions, work_package_id)
  end

  defp package_session_grant_id(_sessions, _work_package_id), do: nil

  defp put_board_browser_session(conn, %AccessGrant{} = grant) do
    conn
    |> Conn.delete_session(@operator_session_key)
    |> Conn.put_session(@board_session_key, grant.id)
  end

  defp put_package_browser_session(conn, %AccessGrant{} = grant, work_package_id) do
    if phase_reader?(grant) do
      maybe_put_board_session(conn, grant)
    else
      {sessions, order} =
        conn
        |> Conn.get_session(@package_session_key)
        |> package_sessions()
        |> put_limited_package_session(package_session_order(conn, work_package_id), work_package_id, grant.id)

      conn
      |> Conn.put_session(@package_session_key, sessions)
      |> Conn.put_session(@package_session_order_key, order)
      |> Conn.delete_session(@board_session_key)
      |> Conn.delete_session(@operator_session_key)
    end
  end

  defp maybe_put_board_session(conn, %AccessGrant{capabilities: capabilities} = grant) when is_list(capabilities) do
    if "read:phase" in capabilities do
      conn
      |> Conn.delete_session(@operator_session_key)
      |> Conn.put_session(@board_session_key, grant.id)
    else
      conn
    end
  end

  defp maybe_put_board_session(conn, %AccessGrant{}), do: conn

  defp phase_reader?(%AccessGrant{capabilities: capabilities}) when is_list(capabilities), do: "read:phase" in capabilities
  defp phase_reader?(_grant), do: false

  defp authorize_board_secret(secret) do
    with true <- auth_storage_ready?(secret),
         {:ok, {:grant, %AccessGrant{} = grant} = auth_context} <- authenticate_with_existing_repo(secret),
         :ok <- require_phase_board_with_existing_repo(auth_context) do
      {:ok, grant}
    else
      false -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_package_secret(secret, work_package_id) do
    if valid_package_route_id?(work_package_id) do
      with true <- auth_storage_ready?(secret),
           {:ok, {:grant, %AccessGrant{} = grant} = auth_context} <- authenticate_with_existing_repo(secret),
           :ok <- require_work_package_with_existing_repo(auth_context, work_package_id) do
        {:ok, grant}
      else
        false -> {:error, :unauthorized}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  @spec authorize_board_grant_id(term()) :: {:ok, AccessGrant.t()} | {:error, term()}
  def authorize_board_grant_id(grant_id) when is_binary(grant_id) do
    with true <- dashboard_storage_present?(),
         {:ok, {:grant, %AccessGrant{} = grant} = auth_context} <- authenticate_grant_id_with_existing_repo(grant_id),
         :ok <- require_phase_board_with_existing_repo(auth_context) do
      {:ok, grant}
    else
      false -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  def authorize_board_grant_id(_grant_id), do: {:error, :unauthorized}

  @spec authorize_package_grant_id(term(), String.t()) :: {:ok, AccessGrant.t()} | {:error, term()}
  def authorize_package_grant_id(grant_id, work_package_id) when is_binary(grant_id) and is_binary(work_package_id) do
    if valid_package_route_id?(work_package_id) do
      with true <- dashboard_storage_present?(),
           {:ok, {:grant, %AccessGrant{} = grant} = auth_context} <- authenticate_grant_id_with_existing_repo(grant_id),
           :ok <- require_work_package_with_existing_repo(auth_context, work_package_id) do
        {:ok, grant}
      else
        false -> {:error, :unauthorized}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  def authorize_package_grant_id(_grant_id, _work_package_id), do: {:error, :unauthorized}

  @spec scope_package_payload_for_grant(AccessGrant.t(), map()) :: map()
  def scope_package_payload_for_grant(%AccessGrant{} = grant, payload) when is_map(payload) do
    ScopeProjection.scope_package_payload_for_grant(grant, payload)
  end

  defp send_authenticated_repo_response(secret, fun) do
    if auth_storage_ready?(secret) do
      send_after_repo_auth(secret, fun)
    else
      {:error, :unauthorized}
    end
  end

  defp send_after_repo_auth(secret, fun) do
    with {:ok, {:grant, %AccessGrant{}}} <- authenticate_with_existing_repo(secret) do
      with_dashboard_repo(fn repo -> fun.(repo, secret) end)
    end
  end

  defp auth_storage_ready?(secret), do: WorkKey.secret_shape?(secret) and dashboard_storage_present?()

  defp authenticate_with_existing_repo(secret) do
    authenticate_existing_repo(fn repo -> grant_auth_context(repo, secret) end)
  end

  defp authenticate_grant_id_with_existing_repo(grant_id) do
    authenticate_existing_repo(fn repo -> grant_id_auth_context(repo, grant_id) end)
  end

  defp authenticate_existing_repo(auth_fun) when is_function(auth_fun, 1) do
    case with_dashboard_repo(auth_fun, migrate?: false) do
      {:error, {:storage_failed, message}} when is_binary(message) ->
        handle_existing_auth_storage_error(auth_fun, message)

      result ->
        result
    end
  end

  defp handle_existing_auth_storage_error(auth_fun, message) do
    cond do
      missing_schema_message?(message) -> {:error, :unauthorized}
      missing_access_grant_migration_column_message?(message) -> with_dashboard_repo(auth_fun, migrate?: true)
      true -> {:error, {:storage_failed, message}}
    end
  end

  defp dashboard_storage_present? do
    case configured_repo() do
      Repo -> configured_repo_storage_present?()
      nil -> configured_repo_storage_present?()
      configured_repo -> custom_repo_storage_present?(configured_repo)
    end
  end

  defp configured_repo_storage_present? do
    configured_repo_storage_present?(Repo.database_path_if_present(), Process.whereis(Repo))
  end

  defp configured_repo_storage_present?(nil, pid) when is_pid(pid), do: local_repo_storage_present?(pid)
  defp configured_repo_storage_present?(nil, nil), do: false

  defp configured_repo_storage_present?(path, pid) when is_pid(pid) do
    local_repo_storage_present?(pid) or repo_matches_database?(pid, path) or
      :global.whereis_name(Repo.process_key(path)) != :undefined or persistent_database_present?(path)
  end

  defp configured_repo_storage_present?(path, nil), do: persistent_database_present?(path)

  defp local_repo_storage_present?(pid), do: not explicit_database_configured?() and repo_persistent_storage_present?(pid)

  defp explicit_database_configured? do
    Application.get_env(:symphony_elixir, :sympp_repo_database) != nil or configured_repo_database_configured?()
  end

  defp configured_repo_database_configured? do
    :symphony_elixir
    |> Application.get_env(Repo, [])
    |> Keyword.get(:database)
    |> configured_database_value?()
  end

  defp configured_database_value?(database_path) when is_binary(database_path), do: String.trim(database_path) != ""
  defp configured_database_value?(nil), do: false
  defp configured_database_value?(_database_path), do: true

  defp custom_repo_storage_present?(repo) do
    if ecto_repo?(repo) do
      custom_ecto_repo_storage_present?(repo)
    else
      true
    end
  end

  defp custom_ecto_repo_storage_present?(repo) do
    database_path = custom_repo_database_path(repo)

    case Process.whereis(repo) do
      pid when is_pid(pid) ->
        persistent_database_present?(database_path) and custom_repo_matches_database?(repo, database_path)

      nil ->
        persistent_database_present?(database_path)
    end
  end

  defp persistent_database_present?(database_path) do
    cond do
      Repo.memory_database?(database_path) -> false
      is_binary(database_path) -> filesystem_database_present?(database_path)
      true -> false
    end
  end

  defp filesystem_database_present?(database_path) do
    case filesystem_database_path(database_path) do
      path when is_binary(path) -> String.trim(path) != "" and File.exists?(path)
      _path -> false
    end
  end

  defp repo_persistent_storage_present?(pid) when is_pid(pid) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      case Repo.query("PRAGMA database_list", []) do
        {:ok, %{rows: rows}} ->
          Enum.any?(rows, fn
            [_seq, "main", path] when is_binary(path) and path != "" -> File.exists?(path)
            _row -> false
          end)

        {:error, _reason} ->
          false
      end
    rescue
      _error in Exqlite.Error -> false
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp filesystem_database_path("file:" <> _rest = database_path) do
    case Repo.sqlite_file_uri_path(database_path) do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _path -> nil
    end
  end

  defp filesystem_database_path(database_path), do: Path.expand(database_path)

  defp auth_context(_conn, repo, secret) do
    grant_auth_context(repo, secret)
  end

  defp grant_auth_context(repo, secret) do
    normalize_storage_errors(fn ->
      with secret_hash <- WorkKey.secret_hash(secret),
           {:ok, %AccessGrant{} = grant} <- AccessGrantRepository.find_by_secret_hash(repo, secret_hash),
           true <- Plug.Crypto.secure_compare(secret_hash, grant.secret_hash),
           :ok <- live_grant?(grant),
           :ok <- require_dashboard_package_authority(repo, grant) do
        {:ok, {:grant, grant}}
      else
        false -> {:error, :unauthorized}
        {:error, reason} -> secret_auth_error(reason)
      end
    end)
  end

  @doc false
  @spec secret_auth_error(term()) :: {:error, term()}
  def secret_auth_error(reason) when reason in [:invalid_secret, :not_found, :work_package_terminal], do: {:error, :unauthorized}
  def secret_auth_error(reason), do: {:error, reason}

  defp grant_id_auth_context(repo, grant_id) do
    normalize_storage_errors(fn ->
      with {:ok, %AccessGrant{} = grant} <- AccessGrantRepository.get(repo, grant_id),
           :ok <- live_grant?(grant),
           :ok <- require_dashboard_package_authority(repo, grant) do
        {:ok, {:grant, grant}}
      else
        {:error, :not_found} -> {:error, :unauthorized}
        {:error, :work_package_terminal} -> {:error, :unauthorized}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp bearer_secret(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> case do
      header when is_binary(header) -> bearer_secret_from_header(header)
      nil -> nil
    end
    |> case do
      "" -> nil
      secret -> secret
    end
  end

  defp bearer_secret_from_header(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, secret] when is_binary(secret) ->
        if String.downcase(scheme) == "bearer", do: String.trim(secret), else: nil

      _invalid ->
        nil
    end
  end

  defp explicit_bearer_request?(conn), do: is_binary(bearer_secret(conn))

  defp live_grant?(%AccessGrant{revoked_at: %DateTime{}}), do: {:error, :unauthorized}
  defp live_grant?(%AccessGrant{claimed_at: nil}), do: {:error, :unauthorized}
  defp live_grant?(%AccessGrant{claimed_by: nil}), do: {:error, :unauthorized}
  defp live_grant?(%AccessGrant{expires_at: nil}), do: :ok

  defp live_grant?(%AccessGrant{expires_at: %DateTime{} = expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) == :gt do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp require_dashboard_package_authority(_repo, %AccessGrant{phase_id: phase_id})
       when not is_binary(phase_id) and not is_nil(phase_id) do
    :ok
  end

  defp require_dashboard_package_authority(repo, %AccessGrant{} = grant) do
    AccessGrantService.require_live_package_authority(repo, grant)
  end

  defp board_payload(repo, {:grant, %AccessGrant{} = grant} = auth_context) do
    with :ok <- require_phase_board(repo, auth_context),
         {:ok, phase_id} <- phase_scope(repo, grant) do
      Dashboard.phase_board_for_grant(repo, phase_id, grant)
    end
  end

  defp require_phase_board(repo, {:grant, %AccessGrant{capabilities: capabilities} = grant}) do
    with :ok <- require_capability(capabilities, "read:phase"),
         {:ok, phase_id} <- phase_scope(repo, grant),
         :ok <- require_phase_board_anchor(repo, grant, phase_id),
         {:ok, _filters} <- Dashboard.phase_board_filters_for_grant(grant) do
      :ok
    end
  end

  defp require_work_request_board(repo, {:grant, %AccessGrant{} = grant} = auth_context) do
    with :ok <- require_phase_board(repo, auth_context),
         {:ok, _filters} <- Dashboard.work_request_filters_for_grant(repo, grant) do
      :ok
    end
  end

  defp require_phase_board_with_existing_repo(auth_context) do
    phase_board_auth_fun = fn repo -> require_phase_board(repo, auth_context) end

    retry_existing_phase_column_read(phase_board_auth_fun)
  end

  defp retry_existing_phase_column_read(auth_fun) when is_function(auth_fun, 1) do
    case with_dashboard_repo(auth_fun, migrate?: false) do
      {:error, {:storage_failed, message}} when is_binary(message) ->
        handle_existing_phase_column_storage_error(auth_fun, message)

      result ->
        result
    end
  end

  defp handle_existing_phase_column_storage_error(auth_fun, message) do
    if missing_access_grant_migration_column_message?(message) do
      with_dashboard_repo(auth_fun, migrate?: true)
    else
      {:error, {:storage_failed, message}}
    end
  end

  defp require_work_package(repo, {:grant, %AccessGrant{} = grant}, work_package_id) do
    cond do
      has_capability?(grant.capabilities, "read:phase") ->
        require_phase_work_package(repo, grant, work_package_id)

      grant.grant_role == "worker" and grant.work_package_id == work_package_id ->
        require_existing_work_package(repo, work_package_id)

      has_capability?(grant.capabilities, "read:package") and grant.work_package_id == work_package_id ->
        require_existing_work_package(repo, work_package_id)

      true ->
        {:error, :forbidden}
    end
  end

  defp require_work_package_with_existing_repo(auth_context, work_package_id) when is_binary(work_package_id) do
    work_package_auth_fun = fn repo -> require_work_package(repo, auth_context, work_package_id) end

    retry_existing_phase_column_read(work_package_auth_fun)
  end

  defp require_existing_work_package(repo, work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, _work_package} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_phase_work_package(repo, %AccessGrant{} = grant, work_package_id) do
    with {:ok, phase_id} <- phase_scope(repo, grant),
         :ok <- require_architect_phase_anchor(repo, grant, phase_id),
         {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
      if work_package.phase_id == phase_id do
        Dashboard.require_phase_board_work_package_scope(work_package, grant)
      else
        {:error, :forbidden}
      end
    end
  end

  defp require_architect_phase_anchor(repo, %AccessGrant{work_package_id: work_package_id} = grant, phase_id)
       when is_binary(work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, work_package} -> Dashboard.require_phase_board_anchor_scope(work_package, grant, phase_id)
      {:error, reason} -> forbidden_or_storage_error(reason)
    end
  end

  defp require_architect_phase_anchor(_repo, %AccessGrant{}, _phase_id), do: {:error, :forbidden}

  defp require_phase_board_anchor(repo, %AccessGrant{work_package_id: work_package_id} = grant, phase_id)
       when is_binary(work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, work_package} -> Dashboard.require_phase_board_anchor_scope(work_package, grant, phase_id)
      {:error, reason} -> forbidden_or_storage_error(reason)
    end
  end

  defp require_phase_board_anchor(_repo, %AccessGrant{}, _phase_id), do: {:error, :forbidden}

  defp phase_scope(_repo, %AccessGrant{phase_id: phase_id}) when is_binary(phase_id) do
    if phase_id == "", do: {:error, :forbidden}, else: {:ok, phase_id}
  end

  defp phase_scope(repo, %AccessGrant{phase_id: nil, work_package_id: work_package_id}) when is_binary(work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %{phase_id: phase_id}} when is_binary(phase_id) and phase_id != "" -> {:ok, phase_id}
      {:ok, _work_package} -> {:error, :forbidden}
      {:error, reason} -> forbidden_or_storage_error(reason)
    end
  end

  defp phase_scope(_repo, %AccessGrant{}), do: {:error, :forbidden}

  defp forbidden_or_storage_error(:database_busy), do: {:error, :database_busy}
  defp forbidden_or_storage_error({:storage_failed, _reason} = reason), do: {:error, reason}
  defp forbidden_or_storage_error(_reason), do: {:error, :forbidden}

  defp require_capability(capabilities, capability) when is_list(capabilities) do
    if capability in capabilities, do: :ok, else: {:error, :forbidden}
  end

  defp has_capability?(capabilities, capability), do: ScopeProjection.has_capability?(capabilities, capability)

  defp error_response(conn, :not_found), do: error_response(conn, 404, "not_found", "Work package not found")
  defp error_response(conn, :unauthorized), do: error_response(conn, 401, "unauthorized", "Unauthorized")
  defp error_response(conn, :forbidden), do: error_response(conn, 403, "forbidden", "Forbidden")
  defp error_response(conn, :database_busy), do: error_response(conn, 503, "database_busy", "Dashboard ledger is busy")
  defp error_response(conn, :already_answered), do: error_response(conn, 409, "already_answered", "Question is already answered")
  defp error_response(conn, :already_closed), do: error_response(conn, 409, "already_closed", "Question is already closed")
  defp error_response(conn, :already_resolved), do: error_response(conn, 409, "already_resolved", "Comment is already resolved")
  defp error_response(conn, :invalid_answer_choice), do: error_response(conn, 422, "invalid_answer_choice", "Answer choice is invalid")
  defp error_response(conn, :invalid_archive_after_days), do: error_response(conn, 422, "invalid_archive_after_days", "Archive cutoff is invalid")
  defp error_response(conn, :missing_answer), do: error_response(conn, 422, "missing_answer", "Answer is required")
  defp error_response(conn, :invalid_target), do: error_response(conn, 422, "invalid_target", "Comment target is invalid")
  defp error_response(conn, :not_completed), do: error_response(conn, 422, "not_completed", "WorkRequest is not complete")
  defp error_response(conn, :not_delivered), do: error_response(conn, 422, "not_delivered", "WorkPackage is not delivered")
  defp error_response(conn, :linked_work_package), do: error_response(conn, 422, "linked_work_package", "WorkPackage is linked to a WorkRequest")
  defp error_response(conn, :linked_work_package_required), do: error_response(conn, 422, "linked_work_package_required", "WorkPackage is not linked to a WorkRequest")
  defp error_response(conn, :missing_no_pr_evidence), do: error_response(conn, 422, "missing_no_pr_evidence", "No-PR evidence is required")
  defp error_response(conn, :active_blocker), do: error_response(conn, 412, "active_blocker", "Closeout is blocked by active blockers")
  defp error_response(conn, :active_runtime), do: error_response(conn, 412, "active_runtime", "Closeout is blocked by active worker state")
  defp error_response(conn, :claim_not_current), do: error_response(conn, 412, "runtime_lease_conflict", "Closeout runtime state changed; retry the action")
  defp error_response(conn, :stale_status), do: error_response(conn, 409, "stale_status", "WorkPackage status changed; refresh and retry")
  defp error_response(conn, :work_package_mismatch), do: error_response(conn, 409, "work_package_mismatch", "WorkPackage no longer matches its planned slice")
  defp error_response(conn, :work_package_not_abandonable), do: error_response(conn, 412, "work_package_not_abandonable", "WorkPackage cannot be abandoned from its current history")

  defp error_response(conn, :missing_custom_redirect_note) do
    error_response(conn, 422, "missing_custom_redirect_note", "A note is required for the custom answer")
  end

  defp error_response(conn, {:authorization_policy_denied, %Decision{} = decision}) do
    error_response(conn, 403, decision.reason_code, "Forbidden")
  end

  defp error_response(conn, :invalid_status), do: error_response(conn, 422, "invalid_status", "Action is not valid for the current status")

  defp error_response(conn, %Ecto.Changeset{} = changeset) do
    error_response(conn, 422, "invalid_request", changeset_error_message(changeset))
  end

  defp error_response(conn, {:invalid_work_request_status, _status}) do
    error_response(conn, 422, "invalid_work_request_status", "WorkRequest is not ready for this action")
  end

  defp error_response(conn, {:invalid_planned_slice_status, _status}) do
    error_response(conn, 422, "invalid_planned_slice_status", "Planned slice is not ready for this action")
  end

  defp error_response(conn, {:storage_failed, _reason}) do
    error_response(conn, 503, "storage_failed", "Dashboard ledger storage failed")
  end

  defp error_response(conn, _reason), do: error_response(conn, 500, "dashboard_unavailable", "Dashboard API unavailable")

  defp changeset_error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
    |> case do
      "" -> "Request did not pass validation"
      message -> message
    end
  end

  defp board_browser_error_response(conn, :forbidden) do
    board_login_response(conn, status: 403, message: "The work key is not allowed to open the board.")
  end

  defp board_browser_error_response(conn, :unauthorized) do
    board_login_response(conn, status: 401, message: "The work key could not access the board.")
  end

  defp board_browser_error_response(conn, :database_busy) do
    board_login_response(conn, status: 503, message: "The dashboard ledger is busy. Try again.")
  end

  defp board_browser_error_response(conn, {:storage_failed, _reason}) do
    board_login_response(conn, status: 503, message: "The board ledger could not be read.")
  end

  defp board_browser_error_response(conn, {:repo_start_failed, _reason}) do
    board_login_response(conn, status: 503, message: "The board ledger could not be opened.")
  end

  defp board_browser_error_response(conn, _reason) do
    board_login_response(conn, status: 500, message: "The board is temporarily unavailable.")
  end

  defp package_browser_error_response(conn, :forbidden, work_package_id) do
    package_login_response(conn,
      status: 403,
      message: "The current work key is not allowed to open this package.",
      work_package_id: work_package_id
    )
  end

  defp package_browser_error_response(conn, :unauthorized, work_package_id) do
    package_login_response(conn, status: 401, message: "The work key could not access this package.", work_package_id: work_package_id)
  end

  defp package_browser_error_response(conn, :not_found, _work_package_id), do: package_not_found_response(conn)

  defp package_browser_error_response(conn, :database_busy, work_package_id) do
    package_login_response(conn, status: 503, message: "The dashboard ledger is busy. Try again.", work_package_id: work_package_id)
  end

  defp package_browser_error_response(conn, {:storage_failed, _reason}, work_package_id) do
    package_login_response(conn, status: 503, message: "The package ledger could not be read.", work_package_id: work_package_id)
  end

  defp package_browser_error_response(conn, {:repo_start_failed, _reason}, work_package_id) do
    package_login_response(conn, status: 503, message: "The package ledger could not be opened.", work_package_id: work_package_id)
  end

  defp package_browser_error_response(conn, _reason, work_package_id) do
    package_login_response(conn, status: 500, message: "The package is temporarily unavailable.", work_package_id: work_package_id)
  end

  defp clear_board_session(conn), do: Conn.delete_session(conn, @board_session_key)

  defp clear_package_session(conn, work_package_id) when is_binary(work_package_id) do
    sessions =
      conn
      |> Conn.get_session(@package_session_key)
      |> package_sessions()
      |> Map.delete(work_package_id)

    order =
      conn
      |> package_session_order(work_package_id)
      |> Enum.reject(&(&1 == work_package_id))

    if map_size(sessions) == 0 do
      conn
      |> Conn.delete_session(@package_session_key)
      |> Conn.delete_session(@package_session_order_key)
    else
      conn
      |> Conn.put_session(@package_session_key, sessions)
      |> Conn.put_session(@package_session_order_key, order)
    end
  end

  defp clear_package_session(conn, _work_package_id) do
    conn
    |> Conn.delete_session(@package_session_key)
    |> Conn.delete_session(@package_session_order_key)
  end

  defp package_sessions(sessions) when is_map(sessions), do: sessions
  defp package_sessions(_sessions), do: %{}

  defp package_session_order(conn, work_package_id) do
    order =
      conn
      |> Conn.get_session(@package_session_order_key)
      |> case do
        order when is_list(order) -> order
        _order -> conn |> Conn.get_session(@package_session_key) |> package_sessions() |> Map.keys()
      end

    Enum.filter(order, &(is_binary(&1) and (&1 == work_package_id or Map.has_key?(package_sessions(Conn.get_session(conn, @package_session_key)), &1))))
  end

  defp put_limited_package_session(sessions, order, work_package_id, grant_id) do
    sessions = Map.put(sessions, work_package_id, grant_id)
    order = order |> Enum.reject(&(&1 == work_package_id)) |> Kernel.++([work_package_id])
    drop_count = max(length(order) - @max_package_sessions, 0)
    {drop, keep} = Enum.split(order, drop_count)

    {Map.drop(sessions, drop), keep}
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp board_login_response(conn, opts \\ []) do
    status = Keyword.get(opts, :status, 401)
    message = Keyword.get(opts, :message, "Enter a board work key to continue.")
    csrf_token = Plug.CSRFProtection.get_csrf_token()
    board_session_path = prefixed_path(conn, "/sympp/board/session")

    body = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Symphony++ board access</title>
    </head>
    <body>
      <main class="sympp-board-shell sympp-auth-shell">
        <section class="error-card">
          <p class="eyebrow">Symphony++</p>
          <h1 class="error-title">Board access</h1>
          <p class="error-copy">#{html_escape(message)}</p>
          <form class="sympp-board-filters" method="post" action="#{board_session_path}">
            <input type="hidden" name="_csrf_token" value="#{csrf_token}">
            <label>
              <span>Work key</span>
              <input type="password" name="work_key" autocomplete="current-password" required>
            </label>
            <button class="subtle-button" type="submit">Open board</button>
          </form>
        </section>
      </main>
    </body>
    </html>
    """

    conn
    |> Conn.put_resp_content_type("text/html")
    |> Conn.send_resp(status, body)
  end

  defp package_login_response(conn, opts) do
    status = Keyword.get(opts, :status, 401)
    message = Keyword.get(opts, :message, "Enter a package work key to continue.")
    work_package_id = Keyword.fetch!(opts, :work_package_id)
    csrf_token = Plug.CSRFProtection.get_csrf_token()
    package_session_path = package_session_path(conn, work_package_id)

    body = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Symphony++ package access</title>
    </head>
    <body>
      <main class="sympp-board-shell sympp-auth-shell">
        <section class="error-card">
          <p class="eyebrow">Symphony++</p>
          <h1 class="error-title">Package access</h1>
          <p class="error-copy">#{html_escape(message)}</p>
          <form class="sympp-board-filters" method="post" action="#{html_escape(package_session_path)}">
            <input type="hidden" name="_csrf_token" value="#{csrf_token}">
            <label>
              <span>Work key</span>
              <input type="password" name="work_key" autocomplete="current-password" required>
            </label>
            <button class="subtle-button" type="submit">Open package</button>
          </form>
        </section>
      </main>
    </body>
    </html>
    """

    conn
    |> Conn.put_resp_content_type("text/html")
    |> Conn.send_resp(status, body)
  end

  defp package_not_found_response(conn) do
    body = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Symphony++ package not found</title>
    </head>
    <body>
      <main class="sympp-board-shell sympp-auth-shell">
        <section class="error-card">
          <p class="eyebrow">Symphony++</p>
          <h1 class="error-title">Package not found</h1>
          <p class="error-copy">The requested work package could not be found.</p>
        </section>
      </main>
    </body>
    </html>
    """

    conn
    |> Conn.put_resp_content_type("text/html")
    |> Conn.send_resp(404, body)
  end

  defp prefixed_path(%Conn{script_name: []}, path), do: path

  defp prefixed_path(%Conn{script_name: script_name}, path) do
    "/" <> Enum.join(script_name ++ [String.trim_leading(path, "/")], "/")
  end

  defp package_detail_path(conn, work_package_id) do
    prefixed_path(conn, "/sympp/work-packages/#{path_segment(work_package_id)}")
  end

  defp package_session_path(conn, work_package_id) do
    prefixed_path(conn, "/sympp/work-packages/#{path_segment(work_package_id)}/session")
  end

  defp path_segment("."), do: "%2E"
  defp path_segment(".."), do: "%2E%2E"

  defp path_segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  defp valid_package_route_id?(work_package_id) when is_binary(work_package_id) do
    String.trim(work_package_id) != "" and not String.contains?(work_package_id, ["\0", "\n", "\r", "\t"])
  end

  defp valid_package_route_id?(_work_package_id), do: false

  defp html_escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp normalize_storage_errors(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)

    if message |> String.downcase() |> busy_message?() do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end

  defp busy_message?(message) do
    String.contains?(message, "busy") or String.contains?(message, "locked")
  end

  defp missing_schema_message?(message) do
    message
    |> String.downcase()
    |> String.contains?("no such table")
  end

  defp missing_access_grant_migration_column_message?(message) do
    message = String.downcase(message)

    String.contains?(message, "no such column") and
      Enum.any?(@access_grant_lazy_migration_columns, &String.contains?(message, &1))
  end

  defp with_dashboard_repo(fun, opts \\ []) when is_function(fun, 1) and is_list(opts) do
    migrate? = Keyword.get(opts, :migrate?, true)

    case configured_repo() do
      Repo -> with_configured_sympp_repo(fun, migrate?)
      repo when is_atom(repo) and not is_nil(repo) -> with_custom_repo(repo, fun, migrate?)
      nil -> with_dynamic_dashboard_repo(fun, migrate?)
    end
  end

  defp configured_repo do
    :symphony_elixir
    |> Application.get_env(Endpoint, [])
    |> Keyword.get(:sympp_repo)
    |> Kernel.||(Endpoint.config(:sympp_repo))
  end

  defp with_configured_sympp_repo(fun, migrate?) do
    database_path = Repo.database_path()

    with {:ok, pid, owner} <- configured_sympp_repo(database_path) do
      with_optional_migrated_repo(
        migrate?,
        pid,
        owner,
        database_path,
        fn -> ensure_configured_repo_migrated(pid, owner, database_path) end,
        fn -> call_configured_repo(pid, owner, fun) end
      )
    end
  end

  defp configured_sympp_repo(database_path) do
    case Process.whereis(Repo) do
      pid when is_pid(pid) -> local_configured_repo(pid, database_path)
      nil -> global_or_started_configured_repo(database_path)
    end
  end

  defp local_configured_repo(pid, database_path) do
    if not explicit_database_configured?() or repo_matches_database?(pid, database_path) do
      {:ok, pid, :local}
    else
      global_or_started_configured_repo(database_path)
    end
  end

  defp global_or_started_configured_repo(database_path) do
    case :global.whereis_name(Repo.process_key(database_path)) do
      pid when is_pid(pid) -> {:ok, pid, :dynamic}
      :undefined -> start_linked_repo(database_path)
    end
  end

  defp ensure_configured_repo_migrated(pid, :local, database_path) do
    ensure_repo_migrated(Repo, pid, local_repo_database_path(database_path))
  end

  defp ensure_configured_repo_migrated(pid, _owner, database_path), do: ensure_repo_migrated(Repo, pid, database_path)

  defp local_repo_database_path(fallback) do
    Repo.config()
    |> Keyword.get(:database)
    |> Kernel.||(fallback)
  end

  defp repo_matches_database?(pid, database_path) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      case Repo.query("PRAGMA database_list", []) do
        {:ok, %{rows: rows}} ->
          database_rows_match?(rows, database_path)

        {:error, _reason} ->
          false
      end
    rescue
      _error in Exqlite.Error -> false
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp call_configured_repo(pid, :dynamic, fun), do: call_dynamic_repo(pid, fun)
  defp call_configured_repo(pid, {:direct, _direct_pid}, fun), do: call_dynamic_repo(pid, fun)
  defp call_configured_repo(_pid, _owner, fun), do: fun.(Repo)

  defp call_dynamic_repo(pid, fun) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      fun.(Repo)
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp with_dynamic_dashboard_repo(fun, migrate?) do
    case Process.whereis(Repo) do
      pid when is_pid(pid) ->
        if explicit_database_configured?() do
          with_started_dynamic_dashboard_repo(fun, migrate?)
        else
          with_running_dynamic_dashboard_repo(pid, fun, migrate?)
        end

      nil ->
        with_started_dynamic_dashboard_repo(fun, migrate?)
    end
  end

  defp with_started_dynamic_dashboard_repo(fun, migrate?) do
    database_path = Repo.database_path()

    with {:ok, pid, owner} <- ensure_repo_started(database_path) do
      with_optional_migrated_repo(
        migrate?,
        pid,
        owner,
        database_path,
        fn -> ensure_repo_migrated(Repo, pid, database_path) end,
        fn -> call_dynamic_repo(pid, fun) end
      )
    end
  end

  defp with_running_dynamic_dashboard_repo(pid, fun, migrate?) do
    database_path = local_repo_database_path(Repo.database_path())

    with_optional_migrated_repo(
      migrate?,
      pid,
      :local,
      database_path,
      fn -> ensure_repo_migrated(Repo, pid, database_path) end,
      fn -> call_dynamic_repo(pid, fun) end
    )
  end

  defp ensure_repo_started(database_path) do
    case :global.whereis_name(Repo.process_key(database_path)) do
      pid when is_pid(pid) -> {:ok, pid, :shared}
      :undefined -> start_repo(database_path)
    end
  end

  defp start_repo(database_path) do
    child_spec =
      Supervisor.child_spec(
        {Repo, Repo.child_options(database: database_path, name: Repo.process_name(database_path))},
        id: Repo.child_id(database_path)
      )

    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) -> start_supervised_repo(child_spec)
      nil -> start_linked_repo(database_path)
    end
  end

  defp start_supervised_repo(child_spec) do
    case Supervisor.start_child(SymphonyElixir.Supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid, :shared}
      {:ok, pid, _info} -> {:ok, pid, :shared}
      {:error, {:already_started, pid}} -> {:ok, pid, :shared}
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp start_linked_repo(database_path) do
    options = Repo.child_options(database: database_path, name: nil)

    case Repo.start_link(options) do
      {:ok, pid} -> unlink_started_repo(pid, {:direct, pid})
      {:error, {:already_started, pid}} -> {:ok, pid, :shared}
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp unlink_started_repo(pid, owner) do
    Process.unlink(pid)
    {:ok, pid, owner}
  end

  defp stop_owned_repo(_pid, {:direct, direct_pid}, _database_path), do: stop_direct_repo(direct_pid)

  defp stop_owned_repo(_pid, _owner, _database_path), do: :ok

  defp stop_direct_repo(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp with_custom_repo(repo, fun, migrate?) do
    if ecto_repo?(repo) do
      with_ecto_custom_repo(repo, fun, migrate?)
    else
      fun.(repo)
    end
  end

  defp with_ecto_custom_repo(repo, fun, migrate?) do
    :global.trans({{__MODULE__, :custom_repo}, repo}, fn ->
      with_ecto_custom_repo_locked(repo, fun, migrate?)
    end)
  end

  defp with_ecto_custom_repo_locked(repo, fun, migrate?) do
    database_path = custom_repo_database_path(repo)

    with {:ok, pid, owner} <- ensure_custom_repo_started(repo, database_path) do
      with_optional_migrated_repo(
        migrate?,
        pid,
        owner,
        database_path,
        fn -> ensure_repo_migrated(repo, pid, database_path) end,
        fn -> fun.(repo) end
      )
    end
  end

  defp with_optional_migrated_repo(true, pid, owner, database_path, migrate_fun, call_fun) do
    with_migrated_repo(pid, owner, database_path, migrate_fun, call_fun)
  end

  defp with_optional_migrated_repo(false, pid, owner, database_path, _migrate_fun, call_fun) do
    call_unmigrated_repo(pid, owner, database_path, call_fun)
  end

  defp call_unmigrated_repo(pid, owner, database_path, call_fun) do
    call_fun.()
  after
    stop_owned_repo(pid, owner, database_path)
  end

  defp ecto_repo?(repo) do
    Code.ensure_loaded?(repo) and function_exported?(repo, :__adapter__, 0) and function_exported?(repo, :start_link, 1)
  end

  defp custom_repo_database_path(repo) do
    repo.config()
    |> Keyword.get(:database)
    |> normalize_custom_repo_database_config()
    |> Kernel.||(Repo.database_path())
  end

  defp normalize_custom_repo_database_config(database_path) when is_binary(database_path) do
    if String.trim(database_path) == "", do: nil, else: database_path
  end

  defp normalize_custom_repo_database_config(database_path), do: database_path

  defp ensure_custom_repo_started(repo, database_path) do
    case Process.whereis(repo) do
      pid when is_pid(pid) -> reuse_custom_repo(repo, pid, database_path)
      nil -> start_custom_repo(repo, database_path)
    end
  end

  defp reuse_custom_repo(repo, pid, database_path) do
    if custom_repo_matches_database?(repo, database_path) do
      {:ok, pid, :local}
    else
      {:error, {:storage_failed, :database_mismatch}}
    end
  end

  defp custom_repo_matches_database?(repo, database_path) do
    case repo.query("PRAGMA database_list", []) do
      {:ok, %{rows: rows}} ->
        database_rows_match?(rows, database_path)

      {:error, _reason} ->
        false
    end
  rescue
    _error in Exqlite.Error -> false
  end

  defp database_rows_match?(rows, database_path) do
    Enum.any?(rows, fn
      [_seq, "main", path] when path in [nil, ""] -> Repo.memory_database?(database_path)
      [_seq, _name, path] when is_binary(path) and path != "" -> database_row_path_matches?(path, database_path)
      _row -> false
    end)
  end

  defp database_row_path_matches?(path, "file:" <> _rest = database_path) do
    Repo.same_database_path?(path, Repo.sqlite_file_uri_path(database_path))
  end

  defp database_row_path_matches?(path, database_path), do: Repo.same_database_path?(path, database_path)

  defp start_custom_repo(repo, database_path) do
    case repo.start_link(database: database_path, name: repo) do
      {:ok, pid} -> unlink_started_repo(pid, {:direct, pid})
      {:error, {:already_started, pid}} -> {:ok, pid, :local}
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp with_migrated_repo(pid, owner, database_path, migrate_fun, call_fun) do
    case migrate_fun.() do
      :ok ->
        try do
          call_fun.()
        after
          stop_owned_repo(pid, owner, database_path)
        end

      {:error, _reason} = error ->
        stop_owned_repo(pid, owner, database_path)
        error
    end
  end

  defp ensure_repo_migrated(repo, pid, database_path) when is_atom(repo) and is_pid(pid) do
    database_key = {repo, Repo.database_key(database_path)}

    if migrated_database?(database_key) and migrated_schema?(repo, pid) do
      :ok
    else
      migrate_with_lock(repo, pid, database_path, database_key)
    end
  end

  defp migrate_with_lock(repo, pid, database_path, database_key) do
    TrackerAdapter.run_with_migration_file_lock(database_path, fn ->
      migrate_if_needed(repo, pid, database_key)
    end)
  end

  defp migrate_if_needed(repo, pid, database_key) do
    if migrated_database?(database_key) and migrated_schema?(repo, pid) do
      :ok
    else
      migrate_repo(repo, pid, database_key)
    end
  end

  defp migrate_repo(Repo, pid, database_key) do
    migration_opts = [all: true, dynamic_repo: pid, log: false]

    Ecto.Migrator.run(Repo, Migrations.all(), :up, migration_opts)

    mark_database_migrated(database_key)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
    error -> {:error, {:migration_failed, error}}
  end

  defp migrate_repo(repo, _pid, database_key) do
    Ecto.Migrator.run(repo, Migrations.all(), :up, all: true, log: false)

    mark_database_migrated(database_key)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
    error -> {:error, {:migration_failed, error}}
  end

  defp migrated_database?(database_key), do: MapSet.member?(migrated_databases(), database_key)

  defp migrated_schema?(Repo, pid) when is_pid(pid) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      repo_schema_migrated?(Repo)
    rescue
      _error in Exqlite.Error -> false
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp migrated_schema?(repo, _pid), do: repo_schema_migrated?(repo)

  defp repo_schema_migrated?(repo) do
    expected_versions = migration_versions()

    case repo.query("SELECT version FROM schema_migrations", []) do
      {:ok, %{rows: rows}} ->
        migrated_versions =
          rows
          |> Enum.map(fn [version] -> to_string(version) end)
          |> MapSet.new()

        expected_versions != [] and MapSet.subset?(MapSet.new(expected_versions), migrated_versions)

      {:error, _reason} ->
        false
    end
  rescue
    _error in Exqlite.Error -> false
  end

  defp migration_versions do
    Migrations.version_strings()
  end

  defp mark_database_migrated(database_key) do
    migrated_databases = MapSet.put(migrated_databases(), database_key)
    Application.put_env(:symphony_elixir, :sympp_dashboard_api_migrated_databases, migrated_databases)
    :ok
  end

  defp migrated_databases do
    case Application.get_env(:symphony_elixir, :sympp_dashboard_api_migrated_databases, MapSet.new()) do
      %MapSet{} = migrated_databases -> migrated_databases
      _invalid -> MapSet.new()
    end
  end
end
