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
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDispatch
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixirWeb.Endpoint
  alias SymphonyElixirWeb.SymppDashboardApi.LocalOperatorActions
  alias SymphonyElixirWeb.SymppDashboardApi.Runtime
  alias SymphonyElixirWeb.SymppDashboardApi.ScopeProjection

  alias SymphonyElixirWeb.SymppDashboardAPI.LocalOperatorDashboard

  @type auth_context :: {:grant, AccessGrant.t()}
  @dangerous_local_operator_actions [:dangerous_override, :dangerous_rekey, :dangerous_delete]

  @spec local_operator_browser?(Conn.t()) :: boolean()
  def local_operator_browser?(%Conn{} = conn) do
    local_operator_request?(conn) and same_origin_browser_request?(conn)
  end

  defp local_operator_request?(%Conn{} = conn) do
    loopback_request?(conn.remote_ip) and local_host?(conn.host) and direct_local_request?(conn)
  end

  defp loopback_request?({127, _second, _third, _fourth}), do: true
  defp loopback_request?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_request?(_remote_ip), do: false

  defp local_host?(host) when is_binary(host) do
    host = String.downcase(host)
    host in ["localhost", "127.0.0.1", "::1", "[::1]"] or String.ends_with?(host, ".localhost")
  end

  defp local_host?(_host), do: false

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
      String.downcase(actual_host) == String.downcase(expected_host) and
      normalize_origin_port(actual_scheme, actual_port) == normalize_origin_port(expected_scheme, expected_port)
  end

  defp origin_matches?(_expected_origin, _actual_origin), do: false

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
    send_package_response(conn, work_package_id, &Dashboard.detail/2)
  end

  @spec timeline(Conn.t(), map()) :: Conn.t()
  def timeline(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, work_package_id, &Dashboard.timeline/2)
  end

  @spec artifacts(Conn.t(), map()) :: Conn.t()
  def artifacts(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, work_package_id, &Dashboard.artifacts/2)
  end

  @spec blockers(Conn.t(), map()) :: Conn.t()
  def blockers(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, work_package_id, &Dashboard.blockers/2)
  end

  @spec grants(Conn.t(), map()) :: Conn.t()
  def grants(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, work_package_id, &Dashboard.grants/2)
  end

  @spec agent_runs(Conn.t(), map()) :: Conn.t()
  def agent_runs(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, work_package_id, &Dashboard.agent_runs/2)
  end

  @spec operator_dashboard(Conn.t(), map()) :: Conn.t()
  def operator_dashboard(conn, %{"surface" => surface}) when surface in ["archived", "solo"] do
    send_local_operator_response(conn, :dashboard_read, Target.new(:dashboard), :operator_dashboard_surface, fn repo ->
      with {:ok, payload} <- LocalOperatorDashboard.operator_dashboard_surface_payload(repo, surface) do
        json(conn, payload)
      end
    end)
  end

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

  @spec operator_dashboard_hydrated(Conn.t(), map()) :: Conn.t()
  def operator_dashboard_hydrated(conn, _params) do
    send_local_operator_response(conn, :dashboard_read, Target.new(:dashboard), :operator_dashboard_hydrated, fn repo ->
      with {:ok, payload} <- LocalOperatorDashboard.operator_dashboard_hydrated_payload(repo) do
        json(conn, payload)
      end
    end)
  end

  @spec operator_dashboard_events(Conn.t(), map()) :: Conn.t()
  def operator_dashboard_events(conn, _params) do
    with true <- local_operator_browser?(conn),
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
    case local_operator_browser?(conn) do
      true -> json(conn, operator_runtime_config(conn) |> maybe_put_dashboard_bootstrap())
      false -> error_response(conn, :unauthorized)
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
               Dashboard.detail(repo, work_package_id, repo_identity_catalog: repo_identity_catalog) do
          json(conn, payload)
        end
      end
    )
  end

  @spec operator_work_request_detail(Conn.t(), map()) :: Conn.t()
  def operator_work_request_detail(conn, %{"work_request_id" => work_request_id} = params) do
    send_local_operator_response(
      conn,
      :dashboard_read,
      Target.new(:dashboard),
      :operator_work_request_detail,
      fn repo ->
        with {:ok, payload} <-
               LocalOperatorDashboard.operator_work_request_detail_payload(repo, work_request_id, work_package_id: Map.get(params, "work_package_id")) do
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
        with {:ok, state} <- LocalOperatorActions.local_operator_work_request_state(params),
             {:ok, work_request} <- update_work_request_state(repo, work_request_id, state) do
          json(conn, mutation_success_payload(%{work_request: LocalOperatorDashboard.work_request_mutation_payload(work_request)}, %{dashboard: false, work_request_id: work_request.id}))
        end
      end
    )
  end

  defp update_work_request_state(repo, work_request_id, "completed"), do: WorkRequestService.force_complete(repo, work_request_id)

  defp update_work_request_state(repo, work_request_id, "ready_for_slicing") do
    case WorkRequestService.get(repo, work_request_id) do
      {:ok, %{status: status}} when status in ["ready_for_clarification", "clarifying", "human_info_needed"] ->
        WorkRequestService.update_status(repo, work_request_id, status, "ready_for_slicing")

      {:ok, _work_request} ->
        {:error, :invalid_status}

      {:error, reason} ->
        {:error, reason}
    end
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
                 work_package_id,
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

  @spec operator_dispatch_work_package(Conn.t(), map()) :: Conn.t()
  def operator_dispatch_work_package(conn, %{"work_request_id" => work_request_id, "work_package_id" => work_package_id}) do
    send_local_operator_response(
      conn,
      :work_package_dispatch,
      work_package_target(work_request_id, work_package_id),
      :operator_dispatch_work_package,
      fn repo ->
        with {:ok, dispatch} <-
               WorkPackageDispatch.dispatch(
                 repo,
                 work_request_id,
                 work_package_id,
                 LocalOperatorActions.dispatch_handoff_opts(repo)
               ) do
          refresh = %{work_request_id: work_request_id, work_package_id: work_package_id}
          payload = %{dispatch: WorkPackageDispatch.response_payload(dispatch)}

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
    if local_operator_browser?(conn) do
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
    with :ok <- maybe_append_operator_audit(repo, conn, action, target, tool_name) do
      {result, invalidated?} = run_local_operator_action(repo, action, fun)
      finalize_local_operator_result(result, action, invalidated?)
    end
  end

  defp run_local_operator_action(repo, action, fun) when action in [:dashboard_read, :work_package_read],
    do: {fun.(repo), false}

  defp run_local_operator_action(repo, _action, fun),
    do: DashboardPubSub.coalesce_changed(fn -> fun.(repo) end)

  defp finalize_local_operator_result(%Conn{} = conn, action, false) do
    maybe_broadcast_dashboard_change(action)
    conn
  end

  defp finalize_local_operator_result(%Conn{} = conn, _action, true), do: conn
  defp finalize_local_operator_result(other, _action, _invalidated?), do: other

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

  defp maybe_append_operator_audit(repo, conn, action, %Target{} = target, tool_name) do
    if action in @dangerous_local_operator_actions do
      case OperatorAudit.append(repo, action, target, operator_request_metadata(conn), operator_tool_metadata(tool_name)) do
        {:ok, %OperatorAudit{}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
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

  defp work_package_target(work_package_id), do: Target.work_package(work_package_id)

  defp work_package_target(work_request_id, work_package_id), do: Target.work_package(work_package_id, work_request_id)

  defp guidance_request_target(work_package_id, guidance_request_id),
    do: Target.package_resource(:guidance_request, work_package_id, id: guidance_request_id)

  defp comment_target(params) do
    target_id = LocalOperatorActions.text_param(params, "target_id")
    Target.new(:comment, target_id)
  end

  defp operator_runtime_config(conn) do
    %{
      apiBase: prefixed_path(conn, "/api/v1/sympp/operator"),
      basePath: script_name_prefix(conn),
      logoUrl: prefixed_path(conn, "/splusplus-logo.png")
    }
  end

  defp maybe_put_dashboard_bootstrap(config) do
    case Runtime.with_dashboard_repo(&LocalOperatorDashboard.operator_dashboard_payload/1) do
      {:ok, dashboard} -> Map.put(config, :dashboard, dashboard)
      {:error, _reason} -> config
    end
  end

  defp mutation_success_payload(payload, refresh \\ %{}) when is_map(payload) and is_map(refresh) do
    payload
    |> Map.put(:ok, true)
    |> Map.put(:refresh, Map.merge(%{dashboard: true}, refresh))
  end

  defp script_name_prefix(%Conn{script_name: []}), do: ""
  defp script_name_prefix(%Conn{script_name: script_name}), do: "/" <> Enum.join(script_name, "/")

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
  defp error_response(conn, :work_request_package), do: error_response(conn, 422, "work_request_package", "WorkRequest WorkPackages cannot be archived independently")

  defp error_response(conn, :work_request_package_required),
    do: error_response(conn, 422, "work_request_package_required", "A WorkRequest WorkPackage is required")

  defp error_response(conn, :missing_no_pr_evidence), do: error_response(conn, 422, "missing_no_pr_evidence", "No-PR evidence is required")
  defp error_response(conn, :active_blocker), do: error_response(conn, 412, "active_blocker", "Closeout is blocked by active blockers")
  defp error_response(conn, :active_runtime), do: error_response(conn, 412, "active_runtime", "Closeout is blocked by active worker state")
  defp error_response(conn, :claim_not_current), do: error_response(conn, 412, "runtime_lease_conflict", "Closeout runtime state changed; retry the action")
  defp error_response(conn, :stale_status), do: error_response(conn, 409, "stale_status", "WorkPackage status changed; refresh and retry")
  defp error_response(conn, :work_package_mismatch), do: error_response(conn, 409, "work_package_mismatch", "WorkPackage no longer matches its WorkPackage")
  defp error_response(conn, :work_package_not_abandonable), do: error_response(conn, 412, "work_package_not_abandonable", "WorkPackage cannot be abandoned from its current history")

  defp error_response(conn, :missing_custom_redirect_note) do
    error_response(conn, 422, "missing_custom_redirect_note", "A note is required for the custom answer")
  end

  defp error_response(conn, :invalid_status), do: error_response(conn, 422, "invalid_status", "Action is not valid for the current status")

  defp error_response(conn, %Ecto.Changeset{} = changeset) do
    error_response(conn, 422, "invalid_request", changeset_error_message(changeset))
  end

  defp error_response(conn, {:invalid_work_request_status, _status}) do
    error_response(conn, 422, "invalid_work_request_status", "WorkRequest is not ready for this action")
  end

  defp error_response(conn, {:invalid_work_package_status, _status}) do
    error_response(conn, 422, "invalid_work_package_status", "WorkPackage is not ready for this action")
  end

  defp error_response(conn, :open_questions) do
    error_response(conn, 409, "open_questions", "Answer or close the open questions before clearing human info")
  end

  defp error_response(conn, {:storage_failed, _reason}) do
    error_response(conn, 503, "storage_failed", "Dashboard ledger storage failed")
  end

  defp error_response(conn, {:worktree_cleanup_failed, _reason}) do
    error_response(conn, 409, "request_delete_cleanup_failed", "Request could not be deleted safely")
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

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp prefixed_path(%Conn{script_name: []}, path), do: path

  defp prefixed_path(%Conn{script_name: script_name}, path) do
    "/" <> Enum.join(script_name ++ [String.trim_leading(path, "/")], "/")
  end
end
