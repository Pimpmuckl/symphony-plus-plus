defmodule SymphonyElixirWeb.SymppBoardLive do
  @moduledoc """
  Read-only Symphony++ work package board.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.TrackerAdapter
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixirWeb.Endpoint
  alias SymphonyElixirWeb.SymppDashboardApiController

  @empty_filter "all"
  @migrated_databases_key :sympp_board_live_migrated_databases

  @impl true
  def mount(params, session, socket) do
    board_grant_id = Map.get(session, "sympp_board_grant_id")

    operator_mode? = local_operator_mode?(session, socket)

    authorization = board_grant_authorization(board_grant_id)
    board_grant = authorized_grant(authorization)

    {:ok,
     socket
     |> assign(:board_grant_id, board_grant_id)
     |> assign(:board_grant, board_grant)
     |> assign(:operator_mode?, operator_mode?)
     |> assign(:authorized?, operator_mode? or not is_nil(board_grant))
     |> assign(:empty_filter, @empty_filter)
     |> assign(:filters, filters(params))
     |> assign_new(:board, fn -> unauthorized_board(authorization) end)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :filters, filters(params))

    if socket.assigns.operator_mode? do
      {:noreply, assign_board(socket)}
    else
      case board_grant_authorization(socket.assigns.board_grant_id) do
        {:ok, grant} ->
          {:noreply, socket |> assign(:board_grant, grant) |> assign(:authorized?, true) |> assign_board()}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:board_grant, nil)
           |> assign(:authorized?, false)
           |> assign(:board, unauthorized_board({:error, reason}))}
      end
    end
  end

  @impl true
  def render(assigns) do
    assigns = Map.put_new(assigns, :operator_mode?, false)

    ~H"""
    <section class="sympp-board-shell">
      <header class="sympp-board-header">
        <div>
          <p class="eyebrow">Symphony++</p>
          <h1 class="sympp-board-title"><%= if @operator_mode?, do: "Local operator cockpit", else: "Work package board" %></h1>
        </div>

        <div class="sympp-board-header-side">
          <nav class="sympp-surface-nav" aria-label="Symphony++ surfaces">
            <a class="active" href="board"><%= if @operator_mode?, do: "Cockpit", else: "Work packages" %></a>
            <a href="work-requests">WorkRequests</a>
            <a :if={@operator_mode?} href="board?auth=work_key">Use work key</a>
          </nav>

          <div class="sympp-board-summary">
            <div>
              <span class="sympp-board-count numeric"><%= Map.get(@board, :operation_total_count, @board.total_count) %></span>
              <span class="muted"><%= if @operator_mode?, do: "operation total", else: "total" %></span>
            </div>
            <div>
              <span class="sympp-board-count numeric"><%= Map.get(@board, :operation_visible_count, @board.visible_count) %></span>
              <span class="muted"><%= if @operator_mode?, do: "operation shown", else: "shown" %></span>
            </div>
            <div :if={@operator_mode?}>
              <span class="sympp-board-count numeric"><%= @board.visible_count %></span>
              <span class="muted">packages shown</span>
            </div>
            <div :if={@operator_mode?}>
              <span class="sympp-board-count numeric"><%= Map.get(@board, :work_request_visible_count, 0) %></span>
              <span class="muted">requests shown</span>
            </div>
            <div :if={phase_progress(Map.get(@board, :phase_summary, %{}))}>
              <span class="sympp-board-count numeric"><%= phase_progress(Map.get(@board, :phase_summary, %{})) %> children merged</span>
            </div>
          </div>
        </div>
      </header>

      <%= if @board.error do %>
        <section class="error-card">
          <h2 class="error-title">Board unavailable</h2>
          <p class="error-copy"><%= @board.error %></p>
        </section>
      <% else %>
        <section class="sympp-board-toolbar" aria-label="Board filters">
          <form class="sympp-board-filters" method="get">
            <label>
              <span>Kind</span>
              <select name="kind">
                <option value={@empty_filter} selected={@filters.kind == @empty_filter}>All</option>
                <option :for={kind <- @board.filter_options.kinds} value={kind} selected={@filters.kind == kind}>
                  <%= kind %>
                </option>
              </select>
            </label>

            <label>
              <span>Repo</span>
              <select name="repo">
                <option value={@empty_filter} selected={@filters.repo == @empty_filter}>All</option>
                <option :for={repo <- @board.filter_options.repos} value={repo} selected={@filters.repo == repo}>
                  <%= repo %>
                </option>
              </select>
            </label>

            <label>
              <span>Base Branch</span>
              <input name="base_branch" value={filter_input_value(stream_base_branch(@filters))} placeholder="All" />
            </label>

            <label>
              <span>Phase</span>
              <select name="phase">
                <option value={@empty_filter} selected={@filters.phase == @empty_filter}>All</option>
                <option :for={phase <- @board.filter_options.phases} value={phase} selected={@filters.phase == phase}>
                  <%= phase %>
                </option>
              </select>
            </label>

            <button class="subtle-button" type="submit">Apply</button>
            <a class="sympp-clear-link" href="board">Clear</a>
          </form>
        </section>

        <section
          :if={@operator_mode? and Map.get(@board, :work_streams, []) != []}
          class="sympp-project-rail"
          data-sympp-project-rail
          aria-label="Projects and Work Streams"
        >
          <header>
            <div>
              <h2>Projects</h2>
              <p>Focus a repo/base stream. Kind and phase reset; use toolbar filters after selecting for intersections.</p>
            </div>
            <a
              class={["sympp-stream-show-all", if(all_filters_clear?(@filters), do: "active")]}
              href="board"
            >
              Show All
            </a>
          </header>

          <div class="sympp-stream-list">
            <article
              :for={stream <- @board.work_streams}
              id={"sympp-stream-#{stream.id}"}
              class={["sympp-stream-item", if(stream.selected?, do: "selected")]}
              data-sympp-stream-id={stream.id}
              data-sympp-stream-order={stream.order}
              data-sympp-pinned="false"
            >
              <a href={stream.href}>
                <strong><%= stream.repo %></strong>
                <span><%= stream.base_branch %></span>
                <small>
                  <%= stream.package_count %> pkg / <%= stream.work_request_count %> req / <%= stream.solo_session_count %> solo
                </small>
              </a>
              <button
                class="sympp-stream-pin"
                type="button"
                data-sympp-stream-pin
                aria-pressed="false"
                title="Pin stream"
              >
                Pin
              </button>
            </article>
          </div>
        </section>

        <section :if={@operator_mode?} class="sympp-operator-priority" aria-label="Operator priorities">
          <div>
            <span class="muted">Guidance needed</span>
            <strong class="numeric"><%= length(@board.guidance_items) %></strong>
            <p>Open questions, human-info-needed WorkRequests, and product decisions waiting on the machine owner.</p>
          </div>
          <div>
            <span class="muted">Active blockers</span>
            <strong class="numeric"><%= length(@board.blocker_items) %></strong>
            <p>Packages with unresolved blocker events in the ledger-backed progress stream.</p>
          </div>
          <div>
            <span class="muted">Review or ready</span>
            <strong class="numeric"><%= @board.review_ready_count %></strong>
            <p>Work that is reviewing, ready for merge, or already carrying review evidence.</p>
          </div>
          <div>
            <span class="muted">Work streams</span>
            <strong class="numeric"><%= @board.work_stream_count %></strong>
            <p>Repo/base streams represented by current WorkPackages and WorkRequests.</p>
          </div>
        </section>

        <section :if={@operator_mode? and @board.solo_session_lanes != []} class="sympp-solo-session-panel" aria-label="Solo Sessions">
          <header>
            <div>
              <h2>Solo Sessions</h2>
              <p>Local single-agent planning sessions, separate from orchestrated work.</p>
            </div>
            <span class="numeric"><%= @board.solo_session_visible_count %> shown</span>
          </header>

          <div class="sympp-solo-session-lanes">
            <section :for={lane <- @board.solo_session_lanes} class="sympp-solo-session-lane">
              <header>
                <h3><%= lane.label %></h3>
                <span class="numeric"><%= lane.count %></span>
              </header>

              <a :for={session <- lane.items} class="sympp-solo-session-row" href={solo_session_detail_path(session)}>
                <div class="sympp-solo-session-topline">
                  <strong><%= session.title %></strong>
                  <span class="state-badge"><%= status_label(session.status) %></span>
                </div>
                <div class="sympp-solo-session-meta">
                  <span><%= session.id %></span>
                  <span><%= repo_base(session) %></span>
                  <span><%= session.caller_id || "unknown caller" %></span>
                  <span class="numeric"><%= relative_time(session.last_activity_at) %></span>
                </div>
                <p :if={session.latest_entry} class="sympp-solo-session-latest">
                  <span><%= session.latest_entry.kind_label %></span>
                  <%= session.latest_entry.title || session.latest_entry.body || "No entry summary" %>
                </p>
                <div :if={session.entry_counts != []} class="sympp-solo-session-counts">
                  <span :for={entry_count <- session.entry_counts}>
                    <%= entry_count.label %> <%= entry_count.count %>
                  </span>
                </div>
              </a>
              <p :if={lane.more_count > 0} class="sympp-solo-session-more"><%= lane.more_count %> more <%= lane.label %> sessions</p>
            </section>
          </div>
        </section>

        <section :if={@operator_mode? and @board.work_request_lanes != []} class="sympp-board-request-panel" aria-label="WorkRequests">
          <header>
            <div>
              <h2>WorkRequests</h2>
              <p>Status lanes for clarification, slicing, and dispatch readiness.</p>
            </div>
            <a href="work-requests">Open all</a>
          </header>

          <div class="sympp-board-request-lanes">
            <section :for={lane <- @board.work_request_lanes} class="sympp-board-request-lane">
              <header>
                <h3><%= lane.label %></h3>
                <span class="numeric"><%= lane.count %></span>
              </header>

              <div class="sympp-board-request-list">
                <a :for={request <- lane.items} href={request.href} class="sympp-board-request-row">
                  <span class={request.state_class}><%= request.state %></span>
                  <strong><%= request.title %></strong>
                  <span class="sympp-board-request-hint"><%= request.action_hint %></span>
                  <span class="muted"><%= request.repo_base %></span>
                  <span class="numeric"><%= request.questions %></span>
                  <span class="muted"><%= request.work_package_signal %></span>
                </a>
              </div>
            </section>
          </div>
        </section>

        <section :if={@operator_mode? and (@board.guidance_items != [] or @board.blocker_items != [])} class="sympp-operator-watchlist">
          <div>
            <h2>Product Guidance Needed</h2>
            <a :for={item <- @board.guidance_items} href={item.href} class="sympp-watch-row">
              <span class="state-badge state-badge-warning"><%= item.state %></span>
              <strong><%= item.title %></strong>
              <span class="muted"><%= item.detail %></span>
            </a>
            <p :if={@board.guidance_items == []} class="sympp-empty-inline">No product guidance is waiting.</p>
          </div>
          <div>
            <h2>Blockers</h2>
            <a :for={item <- @board.blocker_items} href={item.href} class="sympp-watch-row">
              <span class={item.state_class}><%= item.state %></span>
              <strong><%= item.title %></strong>
              <span class="muted"><%= item.detail %></span>
            </a>
            <p :if={@board.blocker_items == []} class="sympp-empty-inline">No active blockers are recorded.</p>
          </div>
        </section>

        <%= if @board.visible_count == 0 and Map.get(@board, :work_request_visible_count, 0) == 0 and Map.get(@board, :solo_session_visible_count, 0) == 0 do %>
          <p class="sympp-empty-state">No work packages match the current board filters.</p>
        <% end %>

        <%= if @board.visible_count > 0 do %>
          <div class="sympp-board-columns" style={"--sympp-column-count: #{@board.column_count};"}>
            <section :for={column <- @board.columns} class="sympp-board-column">
              <header class="sympp-column-header">
                <h2><%= status_label(column.status) %></h2>
                <span class="numeric"><%= length(column.cards) %></span>
              </header>

              <div class="sympp-card-list">
                <article :for={card <- column.cards} class={card_class(card)}>
                  <header class="sympp-card-header">
                    <span class="sympp-card-id"><%= card.id %></span>
                    <span class="state-badge"><%= card.kind || "unknown" %></span>
                  </header>

                  <h3 class="sympp-card-title">
                    <a href={package_detail_path(card)}><%= card.title || "Untitled package" %></a>
                  </h3>

                  <dl class="sympp-card-meta">
                    <div>
                      <dt>Repo</dt>
                      <dd><%= repo_base(card) %></dd>
                    </div>
                    <div>
                      <dt>Updated</dt>
                      <dd class="numeric"><%= relative_time(card.latest_progress_at || card.updated_at) %></dd>
                    </div>
                    <div>
                      <dt>Blockers</dt>
                      <dd class="numeric"><%= card.active_blocker_count || 0 %></dd>
                    </div>
                  </dl>

                  <ol class="sympp-progress-pipeline" aria-label="Package progress">
                    <li :for={step <- progress_pipeline(card)} class={step.class}>
                      <span><%= step.label %></span>
                      <strong><%= step.value %></strong>
                    </li>
                  </ol>

                  <div :if={active_alerts(card) != []} class="sympp-alert-row">
                    <span :for={alert <- active_alerts(card)} class={alert_class(alert)}>
                      <%= alert.label %>
                    </span>
                  </div>

                  <footer class="sympp-card-footer">
                    <a :if={pr_url(card)} href={pr_url(card)} target="_blank" rel="noopener noreferrer">PR</a>
                    <span :if={active_agent_run?(card)} class="sympp-live-pill"><%= runtime_label(card) %></span>
                  </footer>
                </article>
              </div>
            </section>
          </div>
        <% end %>
      <% end %>
    </section>
    """
  end

  defp local_operator_mode?(session, socket) do
    SymppDashboardApiController.local_operator_session?(session) and
      if connected?(socket) do
        SymppDashboardApiController.local_operator_live_connect_info?(%{
          peer_data: get_connect_info(socket, :peer_data),
          uri: get_connect_info(socket, :uri),
          x_headers: get_connect_info(socket, :x_headers)
        })
      else
        SymppDashboardApiController.local_operator_enabled?()
      end
  end

  defp assign_board(socket) do
    source = if socket.assigns.operator_mode?, do: :local_operator, else: socket.assigns.board_grant
    assign(socket, :board, load_board(socket.assigns.filters, source))
  end

  defp board_grant_authorization(grant_id) do
    case SymppDashboardApiController.authorize_board_grant_id(grant_id) do
      {:ok, grant} -> {:ok, grant}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_board(filters, %AccessGrant{} = grant) do
    case with_dashboard_repo(&phase_board_for_grant(&1, grant)) do
      {:ok, payload} -> board_view(payload, filters)
      {:error, reason} when reason in [:unauthorized, :forbidden] -> unauthorized_board({:error, reason})
      {:error, reason} -> empty_board(error_message(reason))
    end
  end

  defp load_board(filters, :local_operator) do
    with_dashboard_repo(
      fn repo ->
        with {:ok, repo_identity_catalog} <- Dashboard.local_operator_repo_identity_catalog(repo),
             opts = [repo_identity_catalog: repo_identity_catalog],
             {:ok, board} <- Dashboard.board(repo, opts),
             {:ok, work_requests} <- Dashboard.work_requests(repo, opts),
             {:ok, guidance_requests} <- Dashboard.human_guidance_requests(repo, opts),
             {:ok, solo_sessions} <- Dashboard.solo_sessions(repo, solo_session_dashboard_filters(filters), opts),
             {:ok, solo_session_repos} <- Dashboard.solo_session_repos(repo),
             {:ok, solo_session_streams} <- Dashboard.solo_session_streams(repo),
             {:ok, solo_session_total_count} <- Dashboard.solo_session_count(repo) do
          {:ok,
           %{
             board: board,
             work_requests: work_requests,
             guidance_requests: guidance_requests,
             solo_sessions: solo_sessions,
             solo_session_repos: solo_session_repos,
             solo_session_streams: solo_session_streams,
             solo_session_total_count: solo_session_total_count
           }}
        end
      end,
      initialize_missing?: true
    )
    |> case do
      {:ok, payload} -> operator_board_view(payload, filters)
      {:error, reason} -> empty_board(error_message(reason))
    end
  end

  defp load_board(_filters, _grant), do: empty_board("Board access expired. Reload and enter a current board work key.")

  defp solo_session_dashboard_filters(filters) do
    filters
    |> Map.take([:repo, :base_branch])
    |> Enum.reject(fn {_key, value} -> value == @empty_filter end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp phase_board_for_grant(repo, %AccessGrant{} = grant) do
    with {:ok, phase_id} <- phase_scope(repo, grant) do
      Dashboard.phase_board_for_grant(repo, phase_id, grant)
    end
  end

  defp phase_scope(repo, %AccessGrant{phase_id: phase_id, work_package_id: work_package_id} = grant)
       when is_binary(phase_id) and is_binary(work_package_id) do
    if phase_id == "" do
      {:error, :forbidden}
    else
      require_anchor_phase(repo, work_package_id, phase_id, grant)
    end
  end

  defp phase_scope(repo, %AccessGrant{phase_id: nil, work_package_id: work_package_id}) when is_binary(work_package_id) do
    anchor_phase_scope(repo, work_package_id)
  end

  defp phase_scope(_repo, %AccessGrant{}), do: {:error, :forbidden}

  defp require_anchor_phase(repo, work_package_id, phase_id, %AccessGrant{} = grant) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, work_package} ->
        with :ok <- Dashboard.require_phase_board_anchor_scope(work_package, grant, phase_id) do
          {:ok, phase_id}
        end

      {:error, reason} ->
        phase_scope_lookup_error(reason)
    end
  end

  defp anchor_phase_scope(repo, work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %{phase_id: phase_id}} when is_binary(phase_id) and phase_id != "" -> {:ok, phase_id}
      {:ok, _work_package} -> {:error, :forbidden}
      {:error, reason} -> phase_scope_lookup_error(reason)
    end
  end

  defp phase_scope_lookup_error(:database_busy), do: {:error, :database_busy}
  defp phase_scope_lookup_error({:storage_failed, _reason} = reason), do: {:error, reason}
  defp phase_scope_lookup_error(_reason), do: {:error, :forbidden}

  defp authorized_grant({:ok, grant}), do: grant
  defp authorized_grant(_authorization), do: nil

  @spec with_dashboard_repo((module() -> {:ok, map()} | {:error, term()}), keyword()) :: {:ok, map()} | {:error, term()}
  def with_dashboard_repo(fun, opts \\ []) when is_function(fun, 1) and is_list(opts) do
    case configured_dashboard_repo() do
      repo when is_atom(repo) and not is_nil(repo) and repo != Repo ->
        with_custom_dashboard_repo(repo, fun, opts)

      _repo ->
        with_default_dashboard_repo(fun, opts)
    end
  end

  defp configured_dashboard_repo do
    :symphony_elixir
    |> Application.get_env(Endpoint, [])
    |> Keyword.get(:sympp_repo)
    |> Kernel.||(Endpoint.config(:sympp_repo))
  end

  defp with_custom_dashboard_repo(repo, fun, opts) do
    if ecto_repo?(repo) do
      with_configured_ecto_custom_dashboard_repo(repo, fun, opts)
    else
      fun.(repo)
    end
  end

  defp with_configured_ecto_custom_dashboard_repo(repo, fun, opts) do
    case custom_repo_database_path(repo, opts) do
      database_path when is_binary(database_path) -> with_ecto_custom_dashboard_repo(repo, database_path, fun)
      _missing -> {:error, :not_found}
    end
  end

  defp with_ecto_custom_dashboard_repo(repo, database_path, fun) do
    case Process.whereis(repo) do
      pid when is_pid(pid) ->
        if custom_repo_uses_database?(repo, database_path) do
          call_dynamic_custom_repo(pid, repo, database_path, fun)
        else
          {:error, {:repo_database_mismatch, repo}}
        end

      nil ->
        start_custom_dashboard_repo(database_path, repo, fun)
    end
  end

  defp ecto_repo?(repo) do
    Code.ensure_loaded?(repo) and function_exported?(repo, :__adapter__, 0) and function_exported?(repo, :start_link, 1)
  end

  defp custom_repo_database_path(repo, opts) do
    database_path =
      repo.config()
      |> Keyword.get(:database)
      |> normalize_custom_repo_database_config()
      |> Kernel.||(Repo.database_path())

    if Keyword.get(opts, :initialize_missing?, false) do
      existing_database_path(database_path) || initializable_database_path(database_path)
    else
      existing_database_path(database_path)
    end
  rescue
    _error -> nil
  end

  defp normalize_custom_repo_database_config(database_path) when is_binary(database_path) do
    if String.trim(database_path) == "", do: nil, else: database_path
  end

  defp normalize_custom_repo_database_config(database_path), do: database_path

  defp custom_repo_uses_database?(repo, database_path) do
    case repo.query("PRAGMA database_list", []) do
      {:ok, %{rows: rows}} -> Enum.any?(rows, &main_database_row?(&1, database_path))
      {:error, _reason} -> false
    end
  rescue
    _error in Exqlite.Error -> false
  end

  defp start_custom_dashboard_repo(database_path, repo, fun) do
    case repo.start_link(database: database_path, name: nil) do
      {:ok, pid} -> call_owned_custom_repo(unlink_transient_repo(pid), repo, database_path, fun)
      {:error, {:already_started, pid}} -> call_existing_custom_repo(pid, repo, database_path, fun)
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp call_existing_custom_repo(pid, repo, database_path, fun) do
    if custom_repo_uses_database?(pid, repo, database_path) do
      call_dynamic_custom_repo(pid, repo, database_path, fun)
    else
      {:error, {:repo_database_mismatch, repo}}
    end
  end

  defp call_owned_custom_repo(pid, repo, database_path, fun) do
    call_dynamic_custom_repo(pid, repo, database_path, fun)
  after
    stop_transient_repo(pid)
  end

  defp custom_repo_uses_database?(pid, repo, database_path) do
    call_dynamic_custom_repo(pid, repo, database_path, false, fn dynamic_repo ->
      custom_repo_uses_database?(dynamic_repo, database_path)
    end)
  end

  defp call_dynamic_custom_repo(pid, repo, database_path, fun) do
    call_dynamic_custom_repo(pid, repo, database_path, true, fun)
  end

  defp call_dynamic_custom_repo(pid, repo, database_path, migrate?, fun) do
    original_repo = repo.put_dynamic_repo(pid)

    try do
      if migrate? do
        with :ok <- migrate_dashboard_repo(repo, pid, database_path) do
          fun.(repo)
        end
      else
        fun.(repo)
      end
    after
      repo.put_dynamic_repo(original_repo)
    end
  end

  defp with_default_dashboard_repo(fun, opts) do
    if explicit_database_configured?() do
      read_configured_default_dashboard_repo(fun, opts)
    else
      case Process.whereis(Repo) do
        pid when is_pid(pid) -> read_running_default_dashboard_repo(pid, fun)
        nil -> read_configured_default_dashboard_repo(fun, opts)
      end
    end
  end

  defp read_configured_default_dashboard_repo(fun, opts) do
    case configured_default_dashboard_database_path(opts) do
      database_path when is_binary(database_path) -> read_existing_dashboard_repo(database_path, fun)
      _missing -> {:error, :not_found}
    end
  end

  defp configured_default_dashboard_database_path(opts) do
    if Keyword.get(opts, :initialize_missing?, false) do
      Repo.database_path_if_present() || initializable_default_database_path()
    else
      Repo.database_path_if_present()
    end
  end

  defp initializable_default_database_path do
    Repo.database_path()
    |> initializable_database_path()
  rescue
    _error -> nil
  end

  defp initializable_database_path(database_path) do
    cond do
      Repo.filesystem_database_path?(database_path) ->
        database_path = Path.expand(database_path)
        File.mkdir_p!(Path.dirname(database_path))
        database_path

      sqlite_file_uri_database_path?(database_path) ->
        ensure_sqlite_file_uri_parent(database_path)

      true ->
        nil
    end
  end

  defp sqlite_file_uri_database_path?(database_path) do
    case Repo.sqlite_file_uri_path(database_path) do
      path when is_binary(path) ->
        String.trim(path) != "" and writable_sqlite_file_uri?(database_path)

      _path ->
        false
    end
  end

  defp ensure_sqlite_file_uri_parent(database_path) do
    case Repo.sqlite_file_uri_path(database_path) do
      path when is_binary(path) ->
        path
        |> Path.expand()
        |> Path.dirname()
        |> File.mkdir_p!()

        database_path

      _path ->
        nil
    end
  end

  defp writable_sqlite_file_uri?(database_path) do
    not Repo.memory_database?(database_path) and
      database_path
      |> sqlite_file_uri_query_params()
      |> read_write_sqlite_file_uri?()
  end

  defp sqlite_file_uri_query_params("file:" <> uri) do
    case String.split(uri, "?", parts: 2) do
      [_path, query] -> URI.decode_query(query)
      _parts -> %{}
    end
  end

  defp sqlite_file_uri_query_params(_database_path), do: %{}

  defp read_write_sqlite_file_uri?(query_params) do
    mode = query_params |> Map.get("mode", "") |> String.downcase()
    immutable = query_params |> Map.get("immutable", "") |> String.downcase()
    mode in ["", "rwc"] and immutable not in ["1", "true"]
  end

  defp read_running_default_dashboard_repo(pid, fun) do
    case running_repo_database_path(pid) do
      {:ok, database_path} -> call_dynamic_repo(pid, database_path, fun)
      :error -> {:error, :not_found}
    end
  end

  defp running_repo_database_path(pid) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      case Repo.query("PRAGMA database_list", []) do
        {:ok, %{rows: rows}} -> persistent_main_database_path(rows)
        {:error, _reason} -> :error
      end
    rescue
      _error in Exqlite.Error -> :error
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp persistent_main_database_path(rows) do
    Enum.find_value(rows, :error, fn
      [_seq, "main", path] when is_binary(path) and path != "" ->
        if File.exists?(path), do: {:ok, path}

      _row ->
        nil
    end)
  end

  defp explicit_database_configured? do
    Application.get_env(:symphony_elixir, :sympp_repo_database) != nil or
      :symphony_elixir
      |> Application.get_env(Repo, [])
      |> Keyword.get(:database)
      |> configured_database_value?()
  end

  defp configured_database_value?(database_path) when is_binary(database_path), do: String.trim(database_path) != ""
  defp configured_database_value?(nil), do: false
  defp configured_database_value?(_database_path), do: true

  defp existing_database_path(nil), do: nil
  defp existing_database_path(database_path) when not is_binary(database_path), do: nil

  defp existing_database_path(database_path) do
    cond do
      Repo.memory_database?(database_path) ->
        database_path

      Repo.filesystem_database_path?(database_path) ->
        database_path = Path.expand(database_path)
        if File.exists?(database_path), do: database_path

      true ->
        existing_sqlite_uri_path(database_path)
    end
  end

  defp existing_sqlite_uri_path("file:" <> _uri = database_path) do
    case Repo.sqlite_file_uri_path(database_path) do
      path when is_binary(path) and path != "" -> if(File.exists?(path), do: database_path)
      _missing -> nil
    end
  end

  defp existing_sqlite_uri_path(database_path), do: database_path

  defp read_existing_dashboard_repo(database_path, fun) do
    case default_repo_pid(database_path) do
      pid when is_pid(pid) -> call_dynamic_repo(pid, database_path, fun)
      :undefined -> start_transient_repo(database_path, fun)
    end
  end

  defp default_repo_pid(database_path) do
    case :global.whereis_name(Repo.process_key(database_path)) do
      pid when is_pid(pid) -> pid
      :undefined -> named_repo_pid(database_path)
    end
  end

  defp named_repo_pid(database_path) do
    case Process.whereis(Repo) do
      pid when is_pid(pid) -> if(repo_uses_database?(pid, database_path), do: pid, else: :undefined)
      nil -> :undefined
    end
  end

  defp repo_uses_database?(pid, database_path) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      case Repo.query("PRAGMA database_list", []) do
        {:ok, %{rows: rows}} -> Enum.any?(rows, &main_database_row?(&1, database_path))
        {:error, _reason} -> false
      end
    rescue
      _error in Exqlite.Error -> false
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp main_database_row?([_seq, "main", path], database_path) when is_binary(path) and is_binary(database_path) do
    cond do
      path == "" -> Repo.memory_database?(database_path)
      Repo.filesystem_database_path?(database_path) -> Repo.same_database_path?(path, database_path)
      true -> sqlite_database_uri_matches_path?(database_path, path)
    end
  end

  defp main_database_row?(_row, _database_path), do: false

  defp sqlite_database_uri_matches_path?("file:" <> _uri = database_path, path) do
    case Repo.sqlite_file_uri_path(database_path) do
      uri_path when is_binary(uri_path) and uri_path != "" -> Repo.same_database_path?(uri_path, path)
      _missing -> false
    end
  end

  defp sqlite_database_uri_matches_path?(_database_path, _path), do: false

  defp start_transient_repo(database_path, fun) do
    options = Repo.child_options(database: database_path, name: nil)

    case Repo.start_link(options) do
      {:ok, pid} -> call_owned_repo(unlink_transient_repo(pid), database_path, fun)
      {:error, {:already_started, pid}} -> call_dynamic_repo(pid, database_path, fun)
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp call_owned_repo(pid, database_path, fun) do
    call_dynamic_repo(pid, database_path, fun)
  after
    stop_transient_repo(pid)
  end

  defp unlink_transient_repo(pid) do
    Process.unlink(pid)
    pid
  end

  defp call_dynamic_repo(pid, database_path, fun) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      with :ok <- migrate_dashboard_repo(Repo, pid, database_path) do
        fun.(Repo)
      end
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp migrate_dashboard_repo(repo, pid, database_path) do
    database_key = {repo, Repo.database_key(database_path)}

    if migrated_dashboard_database?(database_key) and dashboard_schema_migrated?(repo) do
      :ok
    else
      TrackerAdapter.run_with_migration_file_lock(database_path, fn ->
        migrate_dashboard_repo_if_needed(repo, pid, database_key)
      end)
    end
  end

  defp migrate_dashboard_repo_if_needed(repo, pid, database_key) do
    if migrated_dashboard_database?(database_key) and dashboard_schema_migrated?(repo) do
      :ok
    else
      Ecto.Migrator.run(repo, Migrations.all(), :up,
        all: true,
        dynamic_repo: pid,
        log: false
      )

      mark_dashboard_database_migrated(database_key)
    end
  rescue
    error in Exqlite.Error -> {:error, {:migration_failed, error}}
    error -> {:error, {:migration_failed, error}}
  end

  defp dashboard_schema_migrated?(repo) do
    with {:ok, %{rows: rows}} <- repo.query("SELECT version FROM schema_migrations", []),
         expected_versions when expected_versions != [] <- expected_migration_versions() do
      migrated_versions = rows |> Enum.map(&migration_version/1) |> MapSet.new()
      MapSet.subset?(MapSet.new(expected_versions), migrated_versions)
    else
      _missing -> false
    end
  rescue
    _error in Exqlite.Error -> false
  end

  defp expected_migration_versions do
    Migrations.version_strings()
  end

  defp migration_version([version]) when is_integer(version), do: Integer.to_string(version)
  defp migration_version([version]) when is_binary(version), do: version
  defp migration_version(_row), do: nil

  defp migrated_dashboard_database?(database_key), do: MapSet.member?(migrated_dashboard_databases(), database_key)

  defp mark_dashboard_database_migrated(database_key) do
    migrated_databases = MapSet.put(migrated_dashboard_databases(), database_key)
    Application.put_env(:symphony_elixir, @migrated_databases_key, migrated_databases)
    :ok
  end

  defp migrated_dashboard_databases do
    case Application.get_env(:symphony_elixir, @migrated_databases_key, MapSet.new()) do
      %MapSet{} = migrated_databases -> migrated_databases
      _invalid -> MapSet.new()
    end
  end

  defp stop_transient_repo(pid) when is_pid(pid) do
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

  defp board_view(payload, filters) do
    statuses = Map.get(payload, :statuses, [])
    groups = Map.get(payload, :groups, %{})
    all_cards = Enum.flat_map(statuses, &Map.get(groups, &1, []))

    filtered_groups =
      Map.new(statuses, fn status ->
        {status, groups |> Map.get(status, []) |> Enum.filter(&matches_filters?(&1, filters))}
      end)

    columns =
      statuses
      |> Enum.map(&%{status: &1, cards: Map.get(filtered_groups, &1, [])})
      |> Enum.reject(&(&1.cards == []))

    visible_count = filtered_groups |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

    %{
      error: nil,
      total_count: Map.get(payload, :total_count, length(all_cards)),
      phase_summary: Map.get(payload, :summary, %{}),
      visible_count: visible_count,
      column_count: max(length(columns), 1),
      columns: columns,
      filter_options: filter_options(all_cards)
    }
  end

  defp operator_board_view(%{board: board, work_requests: work_requests, guidance_requests: guidance_requests} = payload, filters) do
    all_requests = Map.get(work_requests, :work_requests, [])
    all_solo_sessions = payload |> Map.get(:solo_sessions, %{}) |> Map.get(:solo_sessions, [])
    solo_session_repos = Map.get(payload, :solo_session_repos, [])
    solo_session_streams = Map.get(payload, :solo_session_streams, [])
    solo_session_total_count = Map.get(payload, :solo_session_total_count, length(all_solo_sessions))
    view = board |> board_view(filters) |> operator_filter_options(all_requests, solo_session_repos)
    visible_cards = visible_cards(view)
    visible_streams = visible_cards |> Enum.map(&stream_key/1) |> Enum.reject(&is_nil/1) |> MapSet.new()
    visible_requests = filter_work_requests(all_requests, filters, visible_streams)
    all_guidance_requests = Map.get(guidance_requests, :guidance_requests, [])
    visible_guidance_requests = filter_guidance_requests(all_guidance_requests, visible_cards)
    visible_solo_sessions = filter_solo_sessions(all_solo_sessions, filters)
    solo_session_lanes = solo_session_lanes(visible_solo_sessions)
    solo_session_shown_count = solo_session_shown_count(solo_session_lanes)
    stream_work_requests = visible_requests ++ visible_guidance_requests

    Map.merge(view, %{
      operation_total_count: view.total_count + length(all_requests) + solo_session_total_count,
      operation_visible_count: view.visible_count + length(visible_requests) + solo_session_shown_count,
      work_request_visible_count: length(visible_requests),
      work_request_lanes: work_request_lanes(visible_requests, :local_operator),
      guidance_items: guidance_items(visible_requests) ++ package_guidance_items(visible_guidance_requests),
      blocker_items: blocker_items(visible_cards),
      review_ready_count: review_ready_count(visible_cards),
      work_streams: work_streams(board, all_requests ++ all_guidance_requests, solo_session_streams, filters),
      work_stream_count: work_stream_count(visible_cards, stream_work_requests, visible_solo_sessions),
      solo_session_total_count: solo_session_total_count,
      solo_session_visible_count: solo_session_shown_count,
      solo_session_lanes: solo_session_lanes
    })
  end

  defp visible_cards(%{columns: columns}) when is_list(columns), do: Enum.flat_map(columns, & &1.cards)

  defp operator_filter_options(view, work_requests, solo_session_repos) when is_list(work_requests) and is_list(solo_session_repos) do
    request_repos = sorted_present_values(work_requests, &Map.get(&1, :repo))

    filter_options =
      Map.update!(view.filter_options, :repos, fn repos ->
        ((repos || []) ++ request_repos ++ solo_session_repos)
        |> Enum.uniq()
        |> Enum.sort()
      end)

    %{view | filter_options: filter_options}
  end

  defp solo_session_lanes(solo_sessions) when is_list(solo_sessions) do
    grouped = Enum.group_by(solo_sessions, &Map.get(&1, :status))

    ["active", "paused", "completed", "archived"]
    |> Enum.map(fn status ->
      all_items = Map.get(grouped, status, [])
      items = Enum.take(all_items, 8)

      %{
        status: status,
        label: status_label(status),
        count: length(all_items),
        items: items,
        more_count: max(length(all_items) - length(items), 0)
      }
    end)
    |> Enum.reject(&(&1.items == []))
  end

  defp solo_session_shown_count(lanes) when is_list(lanes) do
    Enum.reduce(lanes, 0, fn lane, count -> count + length(Map.get(lane, :items, [])) end)
  end

  defp work_request_lanes(work_requests, mode) when is_list(work_requests) do
    grouped = Enum.group_by(work_requests, &work_request_lane_key/1)

    work_request_lane_order()
    |> Enum.map(fn {key, label} ->
      %{
        label: label,
        count: grouped |> Map.get(key, []) |> length(),
        items: grouped |> Map.get(key, []) |> work_request_items(mode)
      }
    end)
    |> Enum.reject(&(&1.items == []))
  end

  defp work_request_lane_order do
    [
      draft: "Draft",
      clarifying: "Clarifying",
      human_info_needed: "Human Info Needed",
      ready_for_slicing: "Ready For Slicing",
      sliced: "Sliced/Dispatching"
    ]
  end

  defp work_request_lane_key(request) do
    case item_operational_key(request) || Map.get(request, :status) do
      "draft" ->
        :draft

      status when status in ["ready_for_clarification", "clarifying"] ->
        :clarifying

      "human_info_needed" ->
        :human_info_needed

      "ready_for_slicing" ->
        :ready_for_slicing

      status
      when status in [
             "sliced",
             "planned",
             "ready_for_worker",
             "active",
             "needs_attention",
             "started_paused",
             "reviewing",
             "ci_waiting",
             "merge_ready",
             "merging",
             "merged",
             "closed",
             "abandoned",
             "skipped"
           ] ->
        :sliced

      _status ->
        :draft
    end
  end

  defp work_request_items(work_requests, mode) when is_list(work_requests) do
    Enum.map(work_requests, &work_request_item(&1, mode))
  end

  defp work_request_item(request, mode) do
    %{
      href: "work-requests/#{path_segment(Map.get(request, :id))}",
      title: Map.get(request, :title) || Map.get(request, :id) || "Untitled WorkRequest",
      state: item_operational_label(request),
      state_class: state_badge_class(item_operational_key(request) || Map.get(request, :status)),
      repo_base: repo_base(request),
      questions: "#{Map.get(request, :open_question_count) || 0} Q",
      action_hint: work_request_action_hint(request, mode),
      work_package_signal: work_package_signal(request)
    }
  end

  defp work_request_action_hint(%{status: status} = request, _mode)
       when status in ["ready_for_clarification", "clarifying"] do
    if (Map.get(request, :open_question_count) || 0) > 0 do
      "Answer open questions"
    else
      "Prepare architect handoff"
    end
  end

  defp work_request_action_hint(%{status: "draft"}, :local_operator), do: "Start agent questions"
  defp work_request_action_hint(%{status: "draft"}, _mode), do: "Prepare clarification"
  defp work_request_action_hint(%{status: "human_info_needed"}, _mode), do: "Provide product guidance"

  defp work_request_action_hint(%{operational_state: %{key: key}}, _mode)
       when key in ["active", "started_paused", "needs_attention"],
       do: "Monitor active packages"

  defp work_request_action_hint(%{operational_state: %{key: key}}, _mode)
       when key in ["reviewing", "ci_waiting", "merge_ready", "merging"],
       do: "Monitor validation and merge"

  defp work_request_action_hint(%{operational_state: %{key: "merged"}}, _mode), do: "Review merged delivery"

  defp work_request_action_hint(%{status: "ready_for_slicing"} = request, _mode) do
    if (Map.get(request, :work_package_count) || 0) > 0,
      do: "Review architect plan",
      else: "Waiting for architect WorkPackages"
  end

  defp work_request_action_hint(%{status: "sliced"} = request, _mode) do
    cond do
      (Map.get(request, :planned_work_package_count) || 0) > 0 -> "Dispatch planned WorkPackages"
      (Map.get(request, :dispatched_work_package_count) || 0) > 0 -> "Monitor dispatched packages"
      true -> "No dispatchable WorkPackages"
    end
  end

  defp work_request_action_hint(_request, _mode), do: "Prepare clarification"

  defp guidance_items(work_requests) when is_list(work_requests) do
    work_requests
    |> Enum.filter(&(guidance_request?(&1) or (Map.get(&1, :open_question_count) || 0) > 0))
    |> Enum.map(fn request ->
      open_questions = Map.get(request, :open_question_count) || 0

      %{
        href: "work-requests/#{path_segment(Map.get(request, :id))}",
        title: Map.get(request, :title) || Map.get(request, :id) || "Untitled WorkRequest",
        state: item_operational_label(request),
        state_class: state_badge_class(item_operational_key(request) || Map.get(request, :status)),
        detail: "#{open_questions} open questions / #{work_package_total(request)} WorkPackages"
      }
    end)
  end

  defp guidance_request?(%{status: status}) when status in ["human_info_needed", "ready_for_clarification", "clarifying"], do: true
  defp guidance_request?(_request), do: false

  defp filter_guidance_requests(guidance_requests, visible_cards) when is_list(guidance_requests) and is_list(visible_cards) do
    visible_package_ids =
      visible_cards
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.filter(guidance_requests, &MapSet.member?(visible_package_ids, Map.get(&1, :work_package_id)))
  end

  defp filter_guidance_requests(_guidance_requests, _visible_cards), do: []

  defp package_guidance_items(guidance_requests) when is_list(guidance_requests) do
    Enum.map(guidance_requests, fn guidance_request ->
      work_package_id = Map.get(guidance_request, :work_package_id)

      %{
        href: "work-packages/#{path_segment(work_package_id)}#guidance-requests",
        title: Map.get(guidance_request, :summary) || Map.get(guidance_request, :work_package_title) || work_package_id || "Guidance request",
        state: status_label(Map.get(guidance_request, :status)),
        detail: "#{Map.get(guidance_request, :requested_by) || "unknown requester"} / #{repo_base(guidance_request)}"
      }
    end)
  end

  defp blocker_items(cards) when is_list(cards) do
    cards
    |> Enum.filter(&((Map.get(&1, :active_blocker_count) || 0) > 0))
    |> Enum.map(fn card ->
      %{
        href: package_detail_path(card),
        title: Map.get(card, :title) || Map.get(card, :id) || "Untitled package",
        state: item_operational_label(card),
        state_class: state_badge_class(item_operational_key(card) || Map.get(card, :status)),
        detail: "#{Map.get(card, :active_blocker_count) || 0} active blockers / #{repo_base(card)}"
      }
    end)
  end

  defp review_ready_count(cards) when is_list(cards) do
    cards
    |> Enum.count(fn card ->
      Map.get(card, :status) in ["reviewing", "ready_for_merge", "ready_for_human_merge", "ready_for_architect_merge", "merged_into_phase"] or review_present?(card)
    end)
  end

  defp work_streams(board, work_requests, solo_sessions, filters) do
    cards = board |> board_view(stream_option_filters(filters)) |> visible_cards()

    (cards ++ work_requests ++ solo_sessions)
    |> Enum.reduce(%{}, fn item, streams ->
      case stream_key(item) do
        nil ->
          streams

        {repo, base_branch} = key ->
          Map.update(streams, key, stream_counts(item, repo, base_branch), &merge_stream_counts(&1, item))
      end
    end)
    |> Map.values()
    |> Enum.sort_by(&{&1.repo, &1.base_branch})
    |> Enum.with_index()
    |> Enum.map(fn {stream, index} -> stream_item(stream, filters, index) end)
  end

  defp stream_option_filters(filters) do
    filters
    |> Map.put(:kind, @empty_filter)
    |> Map.put(:repo, @empty_filter)
    |> Map.put(:base_branch, @empty_filter)
    |> Map.put(:phase, @empty_filter)
  end

  defp all_filters_clear?(filters) do
    Map.get(filters, :kind, @empty_filter) == @empty_filter and
      Map.get(filters, :repo, @empty_filter) == @empty_filter and
      stream_base_branch(filters) == @empty_filter and
      Map.get(filters, :phase, @empty_filter) == @empty_filter
  end

  defp stream_base_branch(filters), do: Map.get(filters, :base_branch, @empty_filter)

  defp stream_counts(item, repo, base_branch) do
    %{
      id: stream_id(repo, base_branch),
      repo: repo,
      base_branch: base_branch,
      package_count: 0,
      work_request_count: 0,
      solo_session_count: 0
    }
    |> merge_stream_counts(item)
  end

  defp merge_stream_counts(stream, item) do
    cond do
      Map.has_key?(item, :solo_session_count) ->
        Map.update!(stream, :solo_session_count, &(&1 + Map.get(item, :solo_session_count, 0)))

      Map.has_key?(item, :caller_id) ->
        Map.update!(stream, :solo_session_count, &(&1 + 1))

      stream_request_item?(item) ->
        Map.update!(stream, :work_request_count, &(&1 + 1))

      true ->
        Map.update!(stream, :package_count, &(&1 + 1))
    end
  end

  defp stream_request_item?(item) do
    Map.has_key?(item, :work_type) or Map.has_key?(item, :desired_dispatch_shape) or
      (Map.has_key?(item, :work_package_id) and Map.has_key?(item, :requested_by))
  end

  defp stream_item(stream, filters, order) do
    %{
      id: stream.id,
      repo: stream.repo,
      base_branch: stream.base_branch,
      order: order,
      package_count: stream.package_count,
      work_request_count: stream.work_request_count,
      solo_session_count: stream.solo_session_count,
      href: stream_filter_path(stream, filters),
      selected?: filters.repo == stream.repo and filters.base_branch == stream.base_branch
    }
  end

  defp stream_filter_path(stream, filters) do
    filters
    |> Map.put(:kind, @empty_filter)
    |> Map.put(:repo, stream.repo)
    |> Map.put(:base_branch, stream.base_branch)
    |> Map.put(:phase, @empty_filter)
    |> board_path()
  end

  defp board_path(filters) do
    params =
      [:kind, :repo, :base_branch, :phase]
      |> Enum.map(&{to_string(&1), Map.get(filters, &1)})
      |> Enum.reject(fn {_key, value} -> value == @empty_filter end)

    case URI.encode_query(params) do
      "" -> "board"
      query -> "board?#{query}"
    end
  end

  defp stream_id(repo, base_branch), do: Base.url_encode64("#{repo}\0#{base_branch}", padding: false)

  defp work_stream_count(cards, work_requests, solo_sessions) when is_list(cards) and is_list(work_requests) and is_list(solo_sessions) do
    package_streams = Enum.map(cards, &stream_key/1)
    request_streams = Enum.map(work_requests, &stream_key/1)
    solo_session_streams = Enum.map(solo_sessions, &stream_key/1)

    (package_streams ++ request_streams ++ solo_session_streams)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
  end

  defp filter_work_requests(work_requests, filters, visible_streams) when is_list(work_requests) do
    Enum.filter(work_requests, &matches_work_request_filters?(&1, filters, visible_streams))
  end

  defp filter_solo_sessions(solo_sessions, filters) when is_list(solo_sessions) do
    Enum.filter(solo_sessions, &(matches_filter?(Map.get(&1, :repo), filters.repo) and matches_filter?(Map.get(&1, :base_branch), filters.base_branch)))
  end

  defp matches_work_request_filters?(request, filters, visible_streams) do
    matches_filter?(Map.get(request, :repo), filters.repo) and
      matches_filter?(Map.get(request, :base_branch), filters.base_branch) and
      matches_package_scope?(request, filters, visible_streams)
  end

  defp matches_package_scope?(request, %{kind: @empty_filter, phase: @empty_filter}, _visible_streams) do
    not is_nil(stream_key(request))
  end

  defp matches_package_scope?(_request, _filters, _visible_streams), do: false

  defp stream_key(item) do
    repo = Map.get(item, :repo)
    base_branch = Map.get(item, :base_branch)

    if is_binary(repo) and repo != "" and is_binary(base_branch) and base_branch != "" do
      {repo, base_branch}
    end
  end

  defp work_package_total(item), do: Map.get(item, :work_package_count) || 0

  defp work_package_signal(item) do
    total = work_package_total(item)

    item
    |> work_package_signal_counts()
    |> Enum.find(fn {_label, count} -> count > 0 end)
    |> case do
      {label, count} -> "#{count} #{label} / #{total} WorkPackages"
      nil -> "0 WorkPackages"
    end
  end

  defp work_package_signal_counts(item) do
    [
      {"planned", Map.get(item, :planned_work_package_count) || 0},
      {"dispatched", Map.get(item, :dispatched_work_package_count) || 0},
      {"skipped", Map.get(item, :skipped_work_package_count) || 0}
    ]
  end

  defp empty_board(error) do
    %{
      error: error,
      total_count: 0,
      phase_summary: %{},
      visible_count: 0,
      column_count: 1,
      columns: [],
      filter_options: %{kinds: [], repos: [], phases: []},
      operation_total_count: 0,
      operation_visible_count: 0,
      work_request_visible_count: 0,
      work_request_lanes: [],
      guidance_items: [],
      blocker_items: [],
      review_ready_count: 0,
      work_streams: [],
      work_stream_count: 0,
      solo_session_total_count: 0,
      solo_session_visible_count: 0,
      solo_session_lanes: []
    }
  end

  defp unauthorized_board({:ok, _grant}), do: empty_board(nil)

  defp unauthorized_board({:error, reason}) when reason in [:unauthorized, :forbidden] do
    empty_board("Board access expired. Reload and enter a current board work key.")
  end

  defp unauthorized_board({:error, reason}), do: empty_board(error_message(reason))

  defp phase_progress(%{merged_child_count: merged_count, child_count: child_count}) when child_count > 0 do
    "#{merged_count}/#{child_count}"
  end

  defp phase_progress(_summary), do: nil

  defp filters(params) when is_map(params) do
    %{
      kind: filter_value(params["kind"]),
      repo: filter_value(params["repo"]),
      base_branch: filter_value(params["base_branch"]),
      phase: filter_value(params["phase"])
    }
  end

  defp filter_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: @empty_filter, else: value
  end

  defp filter_value(_value), do: @empty_filter

  defp filter_input_value(@empty_filter), do: ""
  defp filter_input_value(value), do: value

  defp matches_filters?(card, filters) do
    matches_filter?(card.kind, filters.kind) and
      matches_filter?(card.repo, filters.repo) and
      matches_filter?(card.base_branch, filters.base_branch) and
      matches_filter?(phase(card), filters.phase)
  end

  defp matches_filter?(_value, @empty_filter), do: true
  defp matches_filter?(value, filter), do: value == filter

  defp filter_options(cards) do
    %{
      kinds: sorted_present_values(cards, & &1.kind),
      repos: sorted_present_values(cards, & &1.repo),
      phases: sorted_present_values(cards, &phase/1)
    }
  end

  defp sorted_present_values(cards, fun) do
    cards
    |> Enum.map(fun)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp phase(%{id: id}) when is_binary(id) do
    case Regex.run(~r/^SYMPP-(P\d+)-/, id) do
      [_, phase] -> phase
      _match -> nil
    end
  end

  defp phase(_card), do: nil

  defp status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp status_label(status), do: to_string(status)

  defp item_operational_key(%{operational_state: %{key: key}}) when is_binary(key), do: key
  defp item_operational_key(%{operational_state: %{"key" => key}}) when is_binary(key), do: key
  defp item_operational_key(_item), do: nil

  defp item_operational_label(%{operational_state: %{label: label}}) when is_binary(label), do: label
  defp item_operational_label(%{operational_state: %{"label" => label}}) when is_binary(label), do: label
  defp item_operational_label(item), do: status_label(Map.get(item, :status))

  defp state_badge_class(status) when status in ["blocked", "needs_attention"], do: "state-badge state-badge-danger"

  defp state_badge_class(status)
       when status in [
              "human_info_needed",
              "ready_for_clarification",
              "clarifying",
              "started_paused"
            ],
       do: "state-badge state-badge-warning"

  defp state_badge_class(status)
       when status in [
              "active",
              "ready_for_slicing",
              "sliced",
              "planned",
              "ready_for_worker",
              "reviewing",
              "ci_waiting",
              "merge_ready",
              "merging",
              "merged",
              "merged_into_phase",
              "closed",
              "approved",
              "dispatched"
            ],
       do: "state-badge state-badge-active"

  defp state_badge_class(_status), do: "state-badge"

  defp card_class(card) do
    base = "sympp-work-card"

    cond do
      (card.active_blocker_count || 0) > 0 -> "#{base} sympp-work-card-blocked"
      active_alert_type?(card, "stale_heartbeat") -> "#{base} sympp-work-card-warning"
      active_agent_run?(card) -> "#{base} sympp-work-card-active"
      true -> base
    end
  end

  defp repo_base(card) do
    [card.repo, card.base_branch]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" / ")
    |> case do
      "" -> "n/a"
      value -> value
    end
  end

  defp progress_pipeline(card) do
    [implementation_pipeline_step(card), review_pipeline_step(card), merge_pipeline_step(card)]
  end

  defp implementation_pipeline_step(card) do
    cond do
      implementation_done?(card) ->
        pipeline_step("Implementation", "done", :ready)

      (Map.get(card, :active_blocker_count) || 0) > 0 ->
        pipeline_step("Implementation", "blocked", :danger)

      active_agent_run?(card) ->
        pipeline_step("Implementation", runtime_label(card), :active)

      Map.get(card, :status) == "implementing" ->
        pipeline_step("Implementation", "active", :active)

      true ->
        pipeline_step("Implementation", status_label(Map.get(card, :status)), :muted)
    end
  end

  defp implementation_done?(card) do
    Map.get(card, :status) in [
      "reviewing",
      "ci_waiting",
      "ready_for_merge",
      "ready_for_human_merge",
      "ready_for_architect_merge",
      "merging_into_phase",
      "merged",
      "merged_into_phase"
    ]
  end

  defp review_pipeline_step(card) do
    case current_review_evidence(card) do
      {:complete, type} ->
        pipeline_step("Review", "#{type} complete", :ready)

      nil ->
        cond do
          review_present?(card) ->
            pipeline_step("Review", "Review attached", :active)

          Map.get(card, :status) == "reviewing" ->
            pipeline_step("Review", "Reviewing", :active)

          true ->
            pipeline_step("Review", "not started", :muted)
        end
    end
  end

  defp merge_pipeline_step(card) do
    case Map.get(card, :status) do
      "merged" -> pipeline_step("Merge", "merged", :ready)
      "merged_into_phase" -> pipeline_step("Merge", "merged", :ready)
      "merging_into_phase" -> pipeline_step("Merge", "merging", :active)
      status when status in ["ready_for_merge", "ready_for_human_merge", "ready_for_architect_merge"] -> pipeline_step("Merge", "ready", :ready)
      "ci_waiting" -> pipeline_step("Merge", "CI waiting", :active)
      "blocked" -> pipeline_step("Merge", "blocked", :danger)
      _status -> pipeline_step("Merge", "not ready", :muted)
    end
  end

  defp pipeline_step(label, value, state) do
    %{label: label, value: value, class: "sympp-progress-step sympp-progress-step-#{state}"}
  end

  defp current_review_evidence(card) do
    case metadata_value(card, :review_completion, "review_completion") do
      %{} = completion ->
        review = Map.get(completion, :review) || Map.get(completion, "review") || %{}
        type = Map.get(review, :type) || Map.get(review, "type") || "Review"
        {:complete, type}

      _completion ->
        nil
    end
  end

  defp review_present?(card) do
    not is_nil(metadata_value(card, :review_completion, "review_completion"))
  end

  defp pr_url(card) do
    case metadata_value(card, :pr, "pr") do
      %{} = pr -> Map.get(pr, "url") || Map.get(pr, :url)
      _missing -> nil
    end
    |> case do
      url when is_binary(url) and url != "[REDACTED]" -> public_http_url(url)
      _url -> nil
    end
  end

  defp public_http_url(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      url
    end
  rescue
    _error in URI.Error -> nil
  end

  defp metadata_value(%{metadata: %{} = metadata}, atom_key, string_key) do
    Map.get(metadata, atom_key) || Map.get(metadata, string_key)
  end

  defp metadata_value(_card, _atom_key, _string_key), do: nil

  defp active_agent_run?(card), do: not is_nil(card.active_agent_run)

  defp active_alerts(card) do
    case Map.get(card, :alert_indicators) || Map.get(card, "alert_indicators") do
      alerts when is_list(alerts) -> Enum.filter(alerts, &alert_active?/1)
      _alerts -> []
    end
  end

  defp active_alert_type?(card, type) do
    Enum.any?(active_alerts(card), &((Map.get(&1, :type) || Map.get(&1, "type")) == type))
  end

  defp alert_active?(alert), do: Map.get(alert, :active) == true or Map.get(alert, "active") == true

  defp alert_class(alert) do
    case Map.get(alert, :severity) || Map.get(alert, "severity") do
      "critical" -> "sympp-alert-pill sympp-alert-critical"
      "warning" -> "sympp-alert-pill sympp-alert-warning"
      _severity -> "sympp-alert-pill"
    end
  end

  defp runtime_label(%{active_agent_run: run}) when is_map(run) do
    cond do
      Map.get(run, :stale) == true or Map.get(run, "stale") == true -> "stale run"
      (Map.get(run, :runtime_state) || Map.get(run, "runtime_state")) == "queued" -> "queued run"
      true -> "active run"
    end
  end

  defp runtime_label(_card), do: "active run"

  defp package_detail_path(%{id: id}), do: "work-packages/#{path_segment(id)}"

  defp solo_session_detail_path(%{id: id}), do: "solo-sessions/#{path_segment(id)}"

  defp path_segment("."), do: "%2E"
  defp path_segment(".."), do: "%2E%2E"

  defp path_segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  defp relative_time(nil), do: "n/a"

  defp relative_time(%DateTime{} = datetime), do: relative_time(datetime, DateTime.utc_now())

  defp relative_time(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> relative_time(datetime, DateTime.utc_now())
      _error -> timestamp
    end
  end

  defp relative_time(%DateTime{} = datetime, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, datetime, :second), 0)

    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  @spec error_message(term()) :: String.t()
  def error_message(:not_found), do: "No Symphony++ work package ledger was found."
  def error_message(:database_busy), do: "The Symphony++ ledger is busy. Refresh shortly."
  def error_message({:repo_database_mismatch, _repo}), do: "The configured Symphony++ repo does not match the selected ledger."
  def error_message({:storage_failed, _reason}), do: "The Symphony++ ledger could not be read."
  def error_message(_reason), do: "The Symphony++ board could not be loaded."
end
