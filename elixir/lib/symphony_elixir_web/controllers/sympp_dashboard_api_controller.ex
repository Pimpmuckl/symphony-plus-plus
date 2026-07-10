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
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Service, as: CommentService
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.MergeReconciler
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Service, as: GuidanceRequestService
  alias SymphonyElixir.SymphonyPlusPlus.OperatorAudit
  alias SymphonyElixir.SymphonyPlusPlus.OperatorDashboardOpener
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDispatch
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixirWeb.Endpoint
  alias SymphonyElixirWeb.SymppDashboardApi.LocalOperatorActions
  alias SymphonyElixirWeb.SymppDashboardApi.Runtime
  alias SymphonyElixirWeb.SymppDashboardApi.ScopeProjection

  alias SymphonyElixirWeb.SymppDashboardAPI.LocalOperatorDashboard

  @type auth_context :: {:grant, AccessGrant.t()}
  @board_session_key "sympp_board_grant_id"
  @package_session_key "sympp_package_grant_ids"
  @package_session_order_key "sympp_package_grant_order"
  @operator_session_key "sympp_local_operator"
  @operator_bootstrap_param "operator_bootstrap"
  @operator_bootstrap_config_key :sympp_local_operator_bootstrap_token
  @max_package_sessions 8
  @local_operator_actor "local-operator"

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
    case Runtime.with_dashboard_repo(fn repo -> WorkPackageRepository.get(repo, work_package_id) end) do
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

  @spec operator_dashboard_deferred(Conn.t(), map()) :: Conn.t()
  def operator_dashboard_deferred(conn, _params) do
    send_local_operator_response(conn, :dashboard_read, Target.new(:dashboard), :operator_dashboard_deferred, fn repo ->
      with {:ok, payload} <- LocalOperatorDashboard.operator_dashboard_deferred_payload(repo) do
        json(conn, payload)
      end
    end)
  end

  @spec operator_dashboard_events(Conn.t(), map()) :: Conn.t()
  def operator_dashboard_events(conn, _params) do
    with true <- local_operator_api_request?(conn),
         {:ok, %Decision{}} <- authorize_local_operator_policy(conn, :dashboard_read, Target.new(:dashboard)),
         :ok <- OperatorDashboardOpener.ensure_started(),
         :ok <- DashboardPubSub.subscribe() do
      conn =
        conn
        |> Conn.put_resp_header("cache-control", "no-cache")
        |> Conn.put_resp_header("connection", "keep-alive")
        |> Conn.put_resp_content_type("text/event-stream")
        |> Conn.send_chunked(200)

      OperatorDashboardOpener.dashboard_connected()

      try do
        stream_dashboard_events(conn)
      after
        OperatorDashboardOpener.dashboard_disconnected()
      end
    else
      false -> error_response(conn, :unauthorized)
      {:error, reason} -> error_response(conn, reason)
    end
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
      with {:ok, sync} <- MergeReconciler.reconcile(repo, LocalOperatorActions.github_sync_opts(params)) do
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

  @spec operator_delete_work_request(Conn.t(), map()) :: Conn.t()
  def operator_delete_work_request(conn, %{"work_request_id" => work_request_id}) do
    send_local_operator_response(
      conn,
      :dangerous_delete,
      work_request_target(work_request_id),
      :operator_delete_work_request,
      fn repo ->
        with {:ok, deleted_id} <- WorkRequestService.delete(repo, work_request_id) do
          json(conn, mutation_success_payload(%{work_request: %{id: deleted_id}}, %{work_request_id: deleted_id}))
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
        with {:ok, "completed"} <- LocalOperatorActions.local_operator_work_request_state(params),
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
        with {:ok, action} <- LocalOperatorActions.local_operator_work_package_status(params),
             {:ok, work_package} <-
               LocalOperatorActions.change_work_package_for_local_operator(
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

        with {:ok, event} <-
               LocalOperatorActions.clear_work_package_blocker_for_local_operator(
                 repo,
                 work_package_id,
                 blocker_id,
                 params
               ) do
          json(
            conn,
            mutation_success_payload(
              %{progress_event: %{id: event.id, blocker_id: blocker_id}},
              %{work_package_id: work_package_id}
            )
          )
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

        with {:ok, work_package} <- LocalOperatorActions.hide_work_package_for_local_operator(repo, work_package_id) do
          json(conn, mutation_success_payload(%{work_package_id: work_package.id}, %{work_package_id: work_package.id}))
        end
      end
    )
  end

  @spec operator_create_comment(Conn.t(), map()) :: Conn.t()
  def operator_create_comment(conn, params) do
    send_local_operator_response(conn, :comment_add, comment_target(params), :operator_create_comment, fn repo ->
      with {:ok, comment} <- CommentService.create(repo, LocalOperatorActions.local_operator_comment_attrs(params)) do
        refresh = %{comment_target_kind: comment.target_kind, comment_target_id: comment.target_id}

        conn
        |> put_status(201)
        |> json(mutation_success_payload(%{comment: LocalOperatorActions.comment_payload(comment)}, refresh))
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
               CommentService.resolve(
                 repo,
                 comment_id,
                 LocalOperatorActions.local_operator_comment_resolution_attrs(params)
               ) do
          refresh = %{comment_target_kind: comment.target_kind, comment_target_id: comment.target_id}

          json(conn, mutation_success_payload(%{comment: LocalOperatorActions.comment_payload(comment)}, refresh))
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
        with {:ok, question} <- LocalOperatorActions.scoped_question(repo, work_request_id, question_id),
             :ok <- LocalOperatorActions.require_open_question(question),
             {:ok, attrs} <- LocalOperatorActions.local_operator_question_answer_attrs(question, params),
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
                 handoff_opts: LocalOperatorActions.architect_handoff_opts(repo)
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
               PlannedSliceDispatch.dispatch(
                 repo,
                 work_request_id,
                 planned_slice_id,
                 LocalOperatorActions.dispatch_handoff_opts(repo)
               ) do
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
      Runtime.with_dashboard_repo(fn repo ->
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
      case fun.(repo) do
        %Conn{} = conn ->
          maybe_broadcast_dashboard_change(action)
          conn

        other ->
          other
      end
    end
  end

  defp maybe_broadcast_dashboard_change(:dashboard_read), do: :ok
  defp maybe_broadcast_dashboard_change(:work_package_read), do: :ok
  defp maybe_broadcast_dashboard_change(_action), do: DashboardPubSub.broadcast_changed()

  defp stream_dashboard_events(conn) do
    receive do
      :operator_dashboard_changed ->
        case Conn.chunk(conn, "event: dashboard_changed\ndata: {}\n\n") do
          {:ok, conn} -> stream_dashboard_events(conn)
          {:error, _reason} -> conn
        end
    after
      30_000 ->
        case Conn.chunk(conn, ": keep-alive\n\n") do
          {:ok, conn} -> stream_dashboard_events(conn)
          {:error, _reason} -> conn
        end
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
    target_id = LocalOperatorActions.text_param(params, "target_id")
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
    with true <- WorkKey.secret_shape?(secret) and Runtime.dashboard_storage_present?(),
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
      with true <- WorkKey.secret_shape?(secret) and Runtime.dashboard_storage_present?(),
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
    with true <- Runtime.dashboard_storage_present?(),
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
      with true <- Runtime.dashboard_storage_present?(),
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
    if WorkKey.secret_shape?(secret) and Runtime.dashboard_storage_present?() do
      send_after_repo_auth(secret, fun)
    else
      {:error, :unauthorized}
    end
  end

  defp send_after_repo_auth(secret, fun) do
    with {:ok, {:grant, %AccessGrant{}}} <- authenticate_with_existing_repo(secret) do
      Runtime.with_dashboard_repo(fn repo -> fun.(repo, secret) end)
    end
  end

  defp authenticate_with_existing_repo(secret) do
    authenticate_existing_repo(fn repo -> grant_auth_context(repo, secret) end)
  end

  defp authenticate_grant_id_with_existing_repo(grant_id) do
    authenticate_existing_repo(fn repo -> grant_id_auth_context(repo, grant_id) end)
  end

  defp authenticate_existing_repo(auth_fun) when is_function(auth_fun, 1) do
    case Runtime.with_dashboard_repo(auth_fun, migrate?: false) do
      {:error, {:storage_failed, message}} when is_binary(message) ->
        handle_existing_auth_storage_error(auth_fun, message)

      result ->
        result
    end
  end

  defp handle_existing_auth_storage_error(auth_fun, message) do
    cond do
      Runtime.missing_schema_message?(message) ->
        {:error, :unauthorized}

      Runtime.missing_access_grant_migration_column_message?(message) ->
        Runtime.with_dashboard_repo(auth_fun, migrate?: true)

      true ->
        {:error, {:storage_failed, message}}
    end
  end

  defp auth_context(_conn, repo, secret) do
    grant_auth_context(repo, secret)
  end

  defp grant_auth_context(repo, secret) do
    Runtime.normalize_storage_errors(fn ->
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
    Runtime.normalize_storage_errors(fn ->
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
    case Runtime.with_dashboard_repo(auth_fun, migrate?: false) do
      {:error, {:storage_failed, message}} when is_binary(message) ->
        handle_existing_phase_column_storage_error(auth_fun, message)

      result ->
        result
    end
  end

  defp handle_existing_phase_column_storage_error(auth_fun, message) do
    if Runtime.missing_access_grant_migration_column_message?(message) do
      Runtime.with_dashboard_repo(auth_fun, migrate?: true)
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
end
