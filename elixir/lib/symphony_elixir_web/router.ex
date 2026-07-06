defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :operator_dashboard_api do
    plug(:put_local_operator_cors_headers)
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:require_operator_csrf_header)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    get("/", ReactDashboardController, :index)
    get("/sympp", ReactDashboardController, :index)
    get("/sympp/*path", ReactDashboardController, :index)

    post("/sympp/board/session", SymppDashboardApiController, :board_session)
    post("/sympp/work-packages/:work_package_id/session", SymppDashboardApiController, :package_session)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:operator_dashboard_api)

    options("/api/v1/sympp/operator/*path", SymppDashboardApiController, :operator_options)
    get("/api/v1/sympp/operator/config", SymppDashboardApiController, :operator_config)
    get("/api/v1/sympp/operator/dashboard", SymppDashboardApiController, :operator_dashboard)
    get("/api/v1/sympp/operator/dashboard/deferred", SymppDashboardApiController, :operator_dashboard_deferred)
    get("/api/v1/sympp/operator/dashboard/events", SymppDashboardApiController, :operator_dashboard_events)
    post("/api/v1/sympp/operator/settings", SymppDashboardApiController, :operator_update_settings)
    post("/api/v1/sympp/operator/github/sync-prs", SymppDashboardApiController, :operator_sync_github_prs)
    get("/api/v1/sympp/operator/work-packages/:work_package_id", SymppDashboardApiController, :operator_package_detail)
    get("/api/v1/sympp/operator/solo-sessions/:solo_session_id", SymppDashboardApiController, :operator_solo_session_detail)
    post("/api/v1/sympp/operator/work-requests", SymppDashboardApiController, :operator_create_work_request)
    get("/api/v1/sympp/operator/work-requests/:work_request_id", SymppDashboardApiController, :operator_work_request_detail)
    post("/api/v1/sympp/operator/work-requests/:work_request_id/state", SymppDashboardApiController, :operator_update_work_request_state)
    post("/api/v1/sympp/operator/work-requests/:work_request_id/archive", SymppDashboardApiController, :operator_archive_work_request)
    post("/api/v1/sympp/operator/work-requests/:work_request_id/restore", SymppDashboardApiController, :operator_restore_work_request)
    post("/api/v1/sympp/operator/work-packages/:work_package_id/state", SymppDashboardApiController, :operator_update_work_package_state)
    post("/api/v1/sympp/operator/work-packages/:work_package_id/blockers/:blocker_id/clear", SymppDashboardApiController, :operator_clear_work_package_blocker)
    post("/api/v1/sympp/operator/work-packages/:work_package_id/archive", SymppDashboardApiController, :operator_archive_work_package)
    post("/api/v1/sympp/operator/comments", SymppDashboardApiController, :operator_create_comment)
    post("/api/v1/sympp/operator/comments/:comment_id/resolve", SymppDashboardApiController, :operator_resolve_comment)

    post(
      "/api/v1/sympp/operator/work-requests/:work_request_id/questions/:question_id/answer",
      SymppDashboardApiController,
      :operator_answer_question
    )

    post(
      "/api/v1/sympp/operator/work-packages/:work_package_id/guidance/:guidance_request_id/answer",
      SymppDashboardApiController,
      :operator_answer_guidance
    )

    post(
      "/api/v1/sympp/operator/work-requests/:work_request_id/architect-handoff",
      SymppDashboardApiController,
      :operator_create_architect_handoff
    )

    post(
      "/api/v1/sympp/operator/work-requests/:work_request_id/planned-slices/:planned_slice_id/dispatch",
      SymppDashboardApiController,
      :operator_dispatch_planned_slice
    )
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)

    get("/api/v1/sympp/board", SymppDashboardApiController, :board)
    get("/api/v1/sympp/work-requests", SymppDashboardApiController, :work_requests)
    get("/api/v1/sympp/work-requests/:work_request_id", SymppDashboardApiController, :work_request_detail)
    get("/api/v1/sympp/work-packages/:work_package_id", SymppDashboardApiController, :detail)
    get("/api/v1/sympp/work-packages/:work_package_id/timeline", SymppDashboardApiController, :timeline)
    get("/api/v1/sympp/work-packages/:work_package_id/artifacts", SymppDashboardApiController, :artifacts)
    get("/api/v1/sympp/work-packages/:work_package_id/blockers", SymppDashboardApiController, :blockers)
    get("/api/v1/sympp/work-packages/:work_package_id/grants", SymppDashboardApiController, :grants)
    get("/api/v1/sympp/work-packages/:work_package_id/agent-runs", SymppDashboardApiController, :agent_runs)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/config", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/board", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/dashboard", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/dashboard/deferred", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/dashboard/events", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/settings", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-requests/:work_request_id/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-packages/:work_package_id/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-packages/:work_package_id/blockers/:blocker_id/clear", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-packages/:work_package_id/archive", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/github/sync-prs", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-packages/:work_package_id", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/solo-sessions/:solo_session_id", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-requests", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-requests/:work_request_id", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-requests/:work_request_id/archive", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-requests/:work_request_id/restore", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/comments", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/comments/:comment_id/resolve", ObservabilityApiController, :method_not_allowed)

    match(:*, "/api/v1/sympp/work-requests", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/work-requests/:work_request_id", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/work-packages/:work_package_id", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/work-packages/:work_package_id/timeline", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/work-packages/:work_package_id/artifacts", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/work-packages/:work_package_id/blockers", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/work-packages/:work_package_id/grants", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/work-packages/:work_package_id/agent-runs", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end

  defp require_operator_csrf_header(%Plug.Conn{method: method} = conn, _opts)
       when method in ["POST", "PUT", "PATCH", "DELETE"] do
    case Plug.Conn.get_req_header(conn, "x-csrf-token") do
      [_token | _rest] -> conn
      [] -> raise Plug.CSRFProtection.InvalidCSRFTokenError
    end
  end

  defp require_operator_csrf_header(conn, _opts), do: conn

  defp put_local_operator_cors_headers(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [origin | _rest] when is_binary(origin) ->
        if local_operator_cors_origin?(conn, origin) do
          conn
          |> Plug.Conn.put_resp_header("access-control-allow-origin", origin)
          |> Plug.Conn.put_resp_header("access-control-allow-credentials", "true")
          |> Plug.Conn.put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
          |> Plug.Conn.put_resp_header("access-control-allow-headers", "accept, content-type, x-csrf-token")
          |> Plug.Conn.put_resp_header("vary", "origin")
        else
          conn
        end

      _origin ->
        conn
    end
  end

  defp local_operator_cors_origin?(conn, origin) do
    local_operator_enabled?() and
      loopback_request?(conn.remote_ip) and
      local_host?(conn.host) and
      direct_local_request?(conn) and
      configured_dashboard_origin_matches?(origin)
  end

  defp local_operator_enabled? do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

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

  defp direct_local_request?(conn) do
    Enum.all?(["forwarded", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "x-real-ip"], fn header ->
      Plug.Conn.get_req_header(conn, header) == []
    end)
  end

  defp configured_dashboard_origin_matches?(origin) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    with %URI{} = expected <- configured_dashboard_origin(Keyword.get(endpoint_config, :sympp_dashboard_origin)),
         %URI{} = actual <- configured_dashboard_origin(origin) do
      origin_matches?(expected, actual)
    else
      _value -> false
    end
  end

  defp configured_dashboard_origin(origin) when is_binary(origin) do
    case URI.parse(String.trim_trailing(origin, "/")) do
      %URI{scheme: "http", host: host} = parsed when is_binary(host) ->
        if local_host?(host), do: parsed

      _parsed ->
        nil
    end
  end

  defp configured_dashboard_origin(_origin), do: nil

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

  defp normalize_origin_port("http", nil), do: 80
  defp normalize_origin_port(_scheme, port), do: port
end
