defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.TokenAccounting

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @worker_task_runtime_id Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil,
      codex_update_recipient: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil,
      codex_update_recipient: codex_update_recipient(opts)
    }

    state = reconcile_persisted_active_agent_runs(state)
    sweep_unmatched_waiting_worker_tasks(state)
    run_terminal_workspace_cleanup(state)
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_cast({:worker_message, message}, state), do: handle_info(message, state)

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)
        agent_run_id = Map.get(running_entry, :agent_run_id)

        state =
          case reason do
            :normal ->
              completed_result = record_agent_run_completed(agent_run_id, "worker task completed")

              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

              retry_metadata =
                %{
                  identifier: running_entry.identifier,
                  delay_type: :continuation,
                  worker_host: Map.get(running_entry, :worker_host),
                  workspace_path: Map.get(running_entry, :workspace_path),
                  confirmed_worker_down: true
                }
                |> maybe_put_retry_agent_run_id(completed_result, agent_run_id)

              state
              |> complete_issue(issue_id)
              |> schedule_issue_retry(issue_id, 1, retry_metadata)

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)
              retry_reason = "agent exited: #{inspect(reason)}"
              record_agent_run_retrying(agent_run_id, retry_reason)

              retry_metadata = %{
                identifier: running_entry.identifier,
                error: retry_reason,
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path),
                confirmed_worker_down: true,
                agent_run_id: agent_run_id
              }

              schedule_issue_retry(state, issue_id, next_attempt, retry_metadata)
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:agent_runner_started, pid}, %{running: running} = state) when is_pid(pid) do
    case find_issue_id_for_pid(running, pid) do
      nil ->
        {:noreply, state}

      issue_id ->
        running_entry = Map.fetch!(running, issue_id)
        agent_run_id = Map.get(running_entry, :agent_run_id)

        case record_agent_run_running(agent_run_id, "worker task started") do
          :ok ->
            {:noreply, state}

          {:error, reason} ->
            {running_entry, state} = pop_running_entry(state, issue_id)
            terminate_task(pid)
            Process.demonitor(Map.get(running_entry, :ref), [:flush])

            retry_reason = "failed to promote AgentRun after worker start: #{inspect(reason)}"
            record_agent_run_failed(agent_run_id, retry_reason)

            state =
              state
              |> schedule_issue_retry(issue_id, next_retry_attempt_from_running(running_entry), %{
                identifier: Map.get(running_entry, :identifier, issue_id),
                error: retry_reason,
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path),
                agent_run_id: agent_run_id
              })
              |> claim_issue(issue_id)

            notify_dashboard()
            {:noreply, state}
        end
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        record_agent_run_heartbeat(Map.get(updated_running_entry, :agent_run_id), %{
          worker_host: Map.get(updated_running_entry, :worker_host),
          workspace_path: Map.get(updated_running_entry, :workspace_path)
        })

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = TokenAccounting.integrate_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        record_agent_run_heartbeat(Map.get(updated_running_entry, :agent_run_id), %{
          session_id: Map.get(updated_running_entry, :session_id),
          worker_host: Map.get(updated_running_entry, :worker_host),
          workspace_path: Map.get(updated_running_entry, :workspace_path),
          codex_input_tokens: Map.get(updated_running_entry, :codex_input_tokens),
          codex_output_tokens: Map.get(updated_running_entry, :codex_output_tokens),
          codex_total_tokens: Map.get(updated_running_entry, :codex_total_tokens),
          turn_count: Map.get(updated_running_entry, :turn_count)
        })

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_symphony_plus_plus_dispatch_filter, field, values}} ->
        Logger.error(workflow_config_error_message({:invalid_symphony_plus_plus_dispatch_filter, field, values}))

        state

      {:error, {:unsupported_symphony_plus_plus_work_kinds, work_kinds}} ->
        Logger.error(workflow_config_error_message({:unsupported_symphony_plus_plus_work_kinds, work_kinds}))

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec dispatch_issue_for_test(term(), Issue.t(), term(), String.t() | nil) :: term()
  def dispatch_issue_for_test(%State{} = state, %Issue{} = issue, attempt \\ nil, preferred_worker_host \\ nil) do
    dispatch_issue(state, issue, attempt, preferred_worker_host)
  end

  @doc false
  @spec dispatch_issue_for_test(term(), Issue.t(), term(), String.t() | nil, keyword()) :: term()
  def dispatch_issue_for_test(%State{} = state, %Issue{} = issue, attempt, preferred_worker_host, opts) when is_list(opts) do
    dispatch_issue(state, issue, attempt, preferred_worker_host, opts)
  end

  @doc false
  @spec stop_terminal_package_dispatch_for_test(term(), Issue.t()) :: term()
  def stop_terminal_package_dispatch_for_test(%State{} = state, %Issue{} = issue) do
    stop_terminal_package_dispatch(state, issue)
  end

  @doc false
  @spec reconcile_persisted_active_agent_runs_for_test(term()) :: term()
  def reconcile_persisted_active_agent_runs_for_test(%State{} = state), do: reconcile_persisted_active_agent_runs(state)

  @doc false
  @spec worker_task_handle_for_test(pid()) :: String.t()
  def worker_task_handle_for_test(pid) when is_pid(pid), do: worker_task_handle(pid, "test-token")

  @doc false
  @spec start_worker_task_for_test((-> term())) :: {:ok, pid(), String.t()} | {:error, term()}
  def start_worker_task_for_test(fun) when is_function(fun, 0) do
    worker_task_token = worker_task_token()

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           Process.put(:sympp_worker_task_token, worker_task_token)
           fun.()
         end) do
      {:ok, pid} -> {:ok, pid, worker_task_handle(pid, worker_task_token)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec workflow_config_error_message_for_test(term()) :: String.t() | nil
  def workflow_config_error_message_for_test(reason), do: workflow_config_error_message(reason)

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)
        record_agent_run_stopped(Map.get(running_entry, :agent_run_id), "orchestrator stopped active worker")

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp terminate_running_issue_for_retry(%State{} = state, issue_id, running_entry, reason)
       when is_map(running_entry) do
    state = record_session_completion_totals(state, running_entry)
    pid = Map.get(running_entry, :pid)
    ref = Map.get(running_entry, :ref)

    record_agent_run_retrying(Map.get(running_entry, :agent_run_id), reason)

    if is_pid(pid) do
      terminate_task(pid)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue_for_retry(issue_id, running_entry, "stalled for #{elapsed_ms}ms without codex activity")
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without codex activity",
        agent_run_id: Map.get(running_entry, :agent_run_id)
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp start_agent_runner_task(pid) when is_pid(pid) do
    send(pid, {:start_agent_runner, self()})
    :ok
  end

  defp codex_update_recipient(opts) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      name when is_atom(name) -> name
      name when is_tuple(name) -> name
      _name -> self()
    end
  end

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil, opts \\ []) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        if dispatch_filters_allow_issue?(state, refreshed_issue, attempt, preferred_worker_host) do
          do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, opts)
        else
          Logger.info("Skipping dispatch; issue outside configured dispatch filters: #{issue_context(refreshed_issue)}")
          clear_issue_retry(state, refreshed_issue.id)
        end

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, opts) do
    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, state.codex_update_recipient, worker_host, opts)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, opts) do
    case start_agent_run_for_issue(issue, attempt, worker_host, opts) do
      {:ok, agent_run} ->
        do_spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, agent_run_id(agent_run))

      {:error, :active_run_exists} ->
        Logger.info("Deferring dispatch; active AgentRun already exists for #{issue_context(issue)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: 1

        state
        |> schedule_issue_retry(issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "active AgentRun already exists",
          worker_host: worker_host,
          agent_run_id: Keyword.get(opts, :replace_agent_run_id)
        })
        |> claim_issue(issue.id)

      {:error, :work_package_terminal} ->
        Logger.info("Stopping dispatch; WorkPackage became terminal for #{issue_context(issue)}")
        stop_terminal_package_dispatch(state, issue)

      {:error, reason} ->
        Logger.warning("Skipping dispatch; failed to create AgentRun for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        state
        |> schedule_issue_retry(issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to create AgentRun: #{inspect(reason)}",
          worker_host: worker_host
        })
        |> claim_issue(issue.id)
    end
  end

  defp stop_terminal_package_dispatch(%State{} = state, %Issue{id: issue_id}) do
    state
    |> complete_issue(issue_id)
    |> release_issue_claim(issue_id)
  end

  defp do_spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, agent_run_id) do
    worker_task_token = worker_task_token()

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           Process.put(:sympp_worker_task_token, worker_task_token)
           Process.put(:sympp_worker_task_state, :waiting)

           receive do
             {:start_agent_runner, starter} ->
               Process.put(:sympp_worker_task_state, :running)
               send(starter, {:agent_runner_started, self()})
               AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host)
           end
         end) do
      {:ok, pid} ->
        handle_spawned_worker(state, issue, attempt, worker_host, agent_run_id, pid, worker_task_token)

      {:error, reason} ->
        record_agent_run_failed(agent_run_id, "failed to spawn agent: #{inspect(reason)}")
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host,
          agent_run_id: agent_run_id
        })
    end
  end

  defp handle_spawned_worker(state, issue, attempt, worker_host, agent_run_id, pid, worker_task_token) do
    ref = Process.monitor(pid)
    worker_task_handle = worker_task_handle(pid, worker_task_token)

    case record_agent_run_heartbeat(agent_run_id, %{worker_task_handle: worker_task_handle}) do
      :ok ->
        original_state = state

        state =
          bind_running_issue(
            original_state,
            issue,
            attempt,
            worker_host,
            pid,
            ref,
            agent_run_id,
            worker_task_handle
          )

        with :ok <- start_agent_runner_task(pid),
             :ok <- record_agent_run_running(agent_run_id, "worker task started") do
          state
        else
          {:error, reason} ->
            fail_spawned_worker_bind(original_state, issue, attempt, worker_host, agent_run_id, pid, ref, reason)
        end

      {:error, reason} ->
        fail_spawned_worker_bind(state, issue, attempt, worker_host, agent_run_id, pid, ref, reason)
    end
  end

  defp fail_spawned_worker_bind(state, issue, attempt, worker_host, agent_run_id, pid, ref, reason) do
    terminate_task(pid)
    Process.demonitor(ref, [:flush])
    Logger.warning("Skipping dispatch; failed to bind AgentRun worker task for #{issue_context(issue)}: #{inspect(reason)}")

    record_agent_run_failed(agent_run_id, "failed to bind worker task: #{inspect(reason)}")

    next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

    state
    |> schedule_issue_retry(issue.id, next_attempt, %{
      identifier: issue.identifier,
      error: "failed to bind AgentRun worker task: #{inspect(reason)}",
      worker_host: worker_host,
      agent_run_id: agent_run_id
    })
    |> claim_issue(issue.id)
  end

  defp bind_running_issue(state, issue, attempt, worker_host, pid, ref, agent_run_id, worker_task_handle) do
    Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

    running =
      Map.put(
        state.running,
        issue.id,
        running_entry(issue, attempt, worker_host, pid, ref, agent_run_id, %{
          worker_task_handle: worker_task_handle,
          started_at: DateTime.utc_now()
        })
      )

    %{
      state
      | running: running,
        claimed: MapSet.put(state.claimed, issue.id),
        retry_attempts: Map.delete(state.retry_attempts, issue.id)
    }
  end

  defp start_agent_run_for_issue(issue, attempt, worker_host, opts) do
    Tracker.start_agent_run(
      issue,
      attempt: attempt,
      worker_host: worker_host,
      status: "starting",
      replace_agent_run_id: Keyword.get(opts, :replace_agent_run_id),
      retry_recovery_base_ms: retrying_recovery_base_ms(opts),
      retry_recovery_max_ms: retrying_recovery_max_ms(opts),
      starting_stale_after_ms: @failure_retry_base_ms
    )
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp workflow_config_error_message({:invalid_symphony_plus_plus_dispatch_filter, field, values}) do
    "Invalid WORKFLOW.md config: invalid Symphony++ dispatch filter #{field}: #{inspect(values)}"
  end

  defp workflow_config_error_message({:unsupported_symphony_plus_plus_work_kinds, work_kinds}) do
    "Invalid WORKFLOW.md config: unsupported Symphony++ work kinds: #{inspect(work_kinds)}"
  end

  defp workflow_config_error_message(_reason), do: nil

  @doc false
  @spec dispatch_filters_allow_issue_for_test(term(), Issue.t(), term(), String.t() | nil) :: boolean()
  def dispatch_filters_allow_issue_for_test(%State{} = state, %Issue{} = issue, attempt \\ nil, preferred_worker_host \\ nil) do
    dispatch_filters_allow_issue?(state, issue, attempt, preferred_worker_host)
  end

  defp dispatch_filters_allow_issue?(%State{} = state, %Issue{} = issue, _attempt, _preferred_worker_host) do
    issue_owned_by_orchestrator?(state, issue.id) or Tracker.dispatch_filters_match?(issue)
  end

  defp issue_owned_by_orchestrator?(%State{} = state, issue_id) when is_binary(issue_id) do
    MapSet.member?(state.claimed, issue_id) or Map.has_key?(state.running, issue_id)
  end

  defp issue_owned_by_orchestrator?(_state, _issue_id), do: false

  defp clear_issue_retry(%State{} = state, issue_id) when is_binary(issue_id) do
    %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
  end

  defp clear_issue_retry(%State{} = state, _issue_id), do: state

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    scheduled_at_ms = System.monotonic_time(:millisecond)
    due_at_ms = scheduled_at_ms + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    confirmed_worker_down = pick_retry_confirmed_worker_down(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            scheduled_at_ms: scheduled_at_ms,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path,
            agent_run_id: Map.get(metadata, :agent_run_id),
            confirmed_worker_down: confirmed_worker_down
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          agent_run_id: Map.get(retry_entry, :agent_run_id),
          confirmed_worker_down: Map.get(retry_entry, :confirmed_worker_down)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        record_agent_run_stopped(metadata[:agent_run_id], "issue reached terminal state before retry")
        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        record_agent_run_stopped(metadata[:agent_run_id], "issue left active state before retry")
        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    record_agent_run_stopped(metadata[:agent_run_id], "issue disappeared before retry")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp reconcile_persisted_active_agent_runs(%State{} = state) do
    case Tracker.list_active_agent_runs() do
      {:ok, agent_runs} when is_list(agent_runs) ->
        Enum.reduce(agent_runs, state, &reconcile_persisted_active_agent_run/2)

      {:error, reason} ->
        Logger.warning("Skipping AgentRun restart reconciliation; failed to list active AgentRuns: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_persisted_active_agent_run(agent_run, %State{} = state) do
    work_package_id = agent_run_value(agent_run, :work_package_id)

    cond do
      not is_binary(work_package_id) ->
        state

      Map.has_key?(state.running, work_package_id) ->
        state

      agent_run_value(agent_run, :status) == "retrying" ->
        claim_retrying_agent_run_after_restart(state, agent_run)

      true ->
        case verified_worker_task_pid(agent_run_value(agent_run, :worker_task_handle)) do
          {:ok, pid} ->
            reattach_running_agent_run(state, agent_run, pid)

          :error ->
            release_unverifiable_active_agent_run(state, agent_run)
        end
    end
  end

  defp reattach_running_agent_run(%State{} = state, agent_run, pid) when is_pid(pid) do
    work_package_id = agent_run_value(agent_run, :work_package_id)

    if is_pid(state.codex_update_recipient) do
      Logger.info("Skipping AgentRun reattach for pid-bound orchestrator recipient work_package_id=#{work_package_id}")
      terminate_task(pid)
      release_unverifiable_active_agent_run(state, agent_run)
    else
      case fetch_issue_for_agent_run(work_package_id) do
        {:ok, %Issue{} = issue} ->
          reattach_running_agent_run_issue(state, agent_run, issue, pid)

        {:error, reason} ->
          Logger.warning("Unable to reattach running AgentRun; issue lookup failed work_package_id=#{work_package_id}: #{inspect(reason)}")
          release_unverifiable_active_agent_run(state, agent_run)
      end
    end
  end

  defp reattach_running_agent_run_issue(%State{} = state, agent_run, %Issue{} = issue, pid) when is_pid(pid) do
    if retry_candidate_issue?(issue, terminal_state_set()) do
      bind_reattached_agent_run(state, agent_run, issue, pid)
    else
      agent_run_id = agent_run_value(agent_run, :id)

      Logger.info("Skipping AgentRun reattach for inactive issue: #{issue_context(issue)} agent_run_id=#{agent_run_id}")
      terminate_task(pid)
      record_agent_run_stopped(agent_run_id, "issue not active during restart reconciliation")
      state
    end
  end

  defp bind_reattached_agent_run(%State{} = state, agent_run, %Issue{} = issue, pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    worker_host = agent_run_value(agent_run, :worker_host)
    agent_run_id = agent_run_value(agent_run, :id)
    reattached_at = DateTime.utc_now()

    worker_waiting = waiting_worker_task?(pid)

    with :ok <- maybe_start_reattached_worker(agent_run, pid),
         :ok <- maybe_mark_reattached_agent_run_running(agent_run, worker_waiting) do
      Logger.info("Reattached running AgentRun after restart: #{issue_context(issue)} pid=#{inspect(pid)} agent_run_id=#{agent_run_id}")

      running_entry =
        running_entry(
          issue,
          agent_run_value(agent_run, :attempt),
          worker_host,
          pid,
          ref,
          agent_run_id,
          reattached_attrs(agent_run, reattached_at)
        )

      bind_reattached_running_entry(state, issue, running_entry)
    else
      {:error, reason} ->
        Process.demonitor(ref, [:flush])
        Logger.warning("Unable to reattach AgentRun for #{issue_context(issue)} agent_run_id=#{agent_run_id}: #{inspect(reason)}")
        terminate_task(pid)
        release_unverifiable_active_agent_run(state, agent_run)
    end
  end

  defp bind_reattached_running_entry(%State{} = state, %Issue{} = issue, running_entry) do
    %{
      state
      | running: Map.put(state.running, issue.id, running_entry),
        claimed: MapSet.put(state.claimed, issue.id),
        retry_attempts: Map.delete(state.retry_attempts, issue.id)
    }
  end

  defp reattached_attrs(agent_run, reattached_at) do
    input_tokens = agent_run_value(agent_run, :codex_input_tokens) || 0
    output_tokens = agent_run_value(agent_run, :codex_output_tokens) || 0
    total_tokens = agent_run_value(agent_run, :codex_total_tokens) || 0

    %{
      worker_task_handle: agent_run_value(agent_run, :worker_task_handle),
      workspace_path: agent_run_value(agent_run, :workspace_path),
      session_id: agent_run_value(agent_run, :session_id),
      started_at: agent_run_value(agent_run, :started_at) || reattached_at,
      last_codex_timestamp: agent_run_value(agent_run, :last_seen_at) || reattached_at,
      last_codex_event: :reattached,
      codex_input_tokens: input_tokens,
      codex_output_tokens: output_tokens,
      codex_total_tokens: total_tokens,
      restored_codex_input_tokens: input_tokens,
      restored_codex_output_tokens: output_tokens,
      restored_codex_total_tokens: total_tokens,
      codex_last_reported_input_tokens: input_tokens,
      codex_last_reported_output_tokens: output_tokens,
      codex_last_reported_total_tokens: total_tokens,
      turn_count: agent_run_value(agent_run, :turn_count) || 0
    }
  end

  defp maybe_start_reattached_worker(agent_run, pid) do
    if agent_run_value(agent_run, :status) in ["starting", "running"] and waiting_worker_task?(pid) do
      start_agent_runner_task(pid)
    else
      :ok
    end
  end

  defp maybe_mark_reattached_agent_run_running(_agent_run, true), do: :ok
  defp maybe_mark_reattached_agent_run_running(agent_run, false), do: ensure_agent_run_marked_running(agent_run)

  defp claim_retrying_agent_run_after_restart(%State{} = state, agent_run) do
    work_package_id = agent_run_value(agent_run, :work_package_id)
    issue = fetch_issue_for_agent_run(work_package_id)

    state
    |> schedule_issue_retry(work_package_id, next_retry_attempt_from_agent_run(agent_run), %{
      identifier: retry_identifier_for_agent_run(agent_run, issue),
      error: agent_run_value(agent_run, :reason),
      worker_host: agent_run_value(agent_run, :worker_host),
      workspace_path: agent_run_value(agent_run, :workspace_path),
      agent_run_id: agent_run_value(agent_run, :id)
    })
    |> claim_issue(work_package_id)
  end

  defp release_unverifiable_active_agent_run(%State{} = state, agent_run) do
    work_package_id = agent_run_value(agent_run, :work_package_id)
    agent_run_id = agent_run_value(agent_run, :id)
    reason = "worker task handle not live after orchestrator restart"

    case record_agent_run_retrying(agent_run_id, reason) do
      :ok ->
        issue = fetch_issue_for_agent_run(work_package_id)
        identifier = retry_identifier_for_agent_run(agent_run, issue)

        state
        |> schedule_issue_retry(work_package_id, next_retry_attempt_from_agent_run(agent_run), %{
          identifier: identifier,
          error: reason,
          worker_host: agent_run_value(agent_run, :worker_host),
          workspace_path: agent_run_value(agent_run, :workspace_path),
          agent_run_id: agent_run_id
        })
        |> claim_issue(work_package_id)

      {:error, reason} ->
        Logger.warning("Failed to release unverifiable active AgentRun agent_run_id=#{agent_run_id}: #{inspect(reason)}")
        state
    end
  end

  defp sweep_unmatched_waiting_worker_tasks(%State{} = state) do
    running_pids =
      state.running
      |> Map.values()
      |> Enum.map(&Map.get(&1, :pid))
      |> MapSet.new()

    SymphonyElixir.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.reject(&MapSet.member?(running_pids, &1))
    |> Enum.filter(&waiting_worker_task?/1)
    |> Enum.each(&terminate_task/1)
  rescue
    error -> Logger.warning("Skipping waiting worker sweep after restart: #{inspect(error)}")
  catch
    :exit, reason -> Logger.warning("Skipping waiting worker sweep after restart: #{inspect(reason)}")
  end

  defp ensure_agent_run_marked_running(agent_run) do
    if agent_run_value(agent_run, :status) == "starting" do
      record_agent_run_running(agent_run_value(agent_run, :id), "worker task reattached after restart")
    else
      :ok
    end
  end

  defp fetch_issue_for_agent_run(work_package_id) when is_binary(work_package_id) do
    case Tracker.fetch_issue_states_by_ids([work_package_id]) do
      {:ok, [%Issue{} = issue | _]} -> {:ok, issue}
      {:ok, []} -> {:error, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_issue_for_agent_run(_work_package_id), do: {:error, :missing}

  defp retry_identifier_for_agent_run(_agent_run, {:ok, %Issue{identifier: identifier}}) when is_binary(identifier), do: identifier
  defp retry_identifier_for_agent_run(agent_run, _issue), do: agent_run_value(agent_run, :work_package_id)

  defp verified_worker_task_pid(worker_task_handle) when is_binary(worker_task_handle) do
    with {:ok, pid, worker_task_token} <- parse_worker_task_handle(worker_task_handle),
         true <- Process.alive?(pid),
         true <- supervised_worker_task?(pid),
         true <- worker_task_token_matches?(pid, worker_task_token) do
      {:ok, pid}
    else
      _ -> :error
    end
  end

  defp verified_worker_task_pid(_worker_task_handle), do: :error

  defp parse_worker_task_handle("local-task:" <> handle) do
    case String.split(handle, ":", parts: 3) do
      [runtime_id, worker_task_token, pid_text] ->
        if runtime_id == worker_task_runtime_id() do
          {:ok, :erlang.list_to_pid(String.to_charlist(pid_text)), worker_task_token}
        else
          :error
        end

      _ ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_worker_task_handle(_worker_task_handle), do: :error

  defp supervised_worker_task?(pid) when is_pid(pid) do
    SymphonyElixir.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.member?(pid)
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  defp worker_task_token_matches?(pid, worker_task_token) when is_pid(pid) and is_binary(worker_task_token) do
    worker_task_process_value(pid, :sympp_worker_task_token) == worker_task_token
  end

  defp worker_task_token_matches?(_pid, _worker_task_token), do: false

  defp waiting_worker_task?(pid) when is_pid(pid) do
    worker_task_process_value(pid, :sympp_worker_task_state) == :waiting
  end

  defp waiting_worker_task?(_pid), do: false

  defp worker_task_process_value(pid, key) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, key)
      _ -> nil
    end
  end

  defp worker_task_handle(pid, worker_task_token) when is_pid(pid) and is_binary(worker_task_token) do
    "local-task:" <>
      worker_task_runtime_id() <> ":" <> worker_task_token <> ":" <> List.to_string(:erlang.pid_to_list(pid))
  end

  defp worker_task_token do
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp worker_task_runtime_id, do: @worker_task_runtime_id

  defp run_terminal_workspace_cleanup(%State{} = state) do
    running_issue_ids = Map.keys(state.running) |> MapSet.new()

    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        Enum.each(issues, &cleanup_terminal_issue_workspace(&1, running_issue_ids))

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp cleanup_terminal_issue_workspace(%Issue{id: issue_id, identifier: identifier}, running_issue_ids)
       when is_binary(identifier) do
    unless is_binary(issue_id) and MapSet.member?(running_issue_ids, issue_id) do
      cleanup_issue_workspace(identifier)
    end
  end

  defp cleanup_terminal_issue_workspace(_issue, _running_issue_ids), do: :ok

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      retry_opts = [
        replace_agent_run_id: metadata[:agent_run_id],
        replace_confirmed_dead_worker: metadata[:confirmed_worker_down] == true
      ]

      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host], retry_opts)}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp claim_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    %{state | claimed: MapSet.put(state.claimed, issue_id)}
  end

  defp maybe_put_retry_agent_run_id(metadata, {:error, _reason}, agent_run_id) when is_binary(agent_run_id) do
    Map.put(metadata, :agent_run_id, agent_run_id)
  end

  defp maybe_put_retry_agent_run_id(metadata, _result, _agent_run_id), do: metadata

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp retrying_recovery_base_ms(opts) do
    if is_binary(Keyword.get(opts, :replace_agent_run_id)) do
      nil
    else
      @failure_retry_base_ms
    end
  end

  defp retrying_recovery_max_ms(opts) do
    if is_binary(Keyword.get(opts, :replace_agent_run_id)) do
      nil
    else
      Config.settings!().agent.max_retry_backoff_ms
    end
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp next_retry_attempt_from_agent_run(agent_run) do
    case agent_run_value(agent_run, :attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> 1
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_confirmed_worker_down(previous_retry, metadata) do
    metadata[:confirmed_worker_down] == true or Map.get(previous_retry, :confirmed_worker_down) == true
  end

  defp agent_run_id(%{id: id}) when is_binary(id), do: id
  defp agent_run_id(_agent_run), do: nil

  defp agent_run_value(agent_run, key) when is_map(agent_run), do: Map.get(agent_run, key) || Map.get(agent_run, Atom.to_string(key))
  defp agent_run_value(_agent_run, _key), do: nil

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp find_issue_id_for_pid(running, pid) do
    running
    |> Enum.find_value(fn {issue_id, %{pid: running_pid}} ->
      if running_pid == pid, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp running_entry(issue, attempt, worker_host, pid, ref, agent_run_id, attrs) do
    %{
      pid: pid,
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      worker_host: worker_host,
      worker_task_handle: Map.get(attrs, :worker_task_handle),
      workspace_path: Map.get(attrs, :workspace_path),
      session_id: Map.get(attrs, :session_id),
      last_codex_message: nil,
      last_codex_timestamp: Map.get(attrs, :last_codex_timestamp),
      last_codex_event: Map.get(attrs, :last_codex_event),
      codex_app_server_pid: nil,
      codex_input_tokens: Map.get(attrs, :codex_input_tokens, 0),
      codex_output_tokens: Map.get(attrs, :codex_output_tokens, 0),
      codex_total_tokens: Map.get(attrs, :codex_total_tokens, 0),
      restored_codex_input_tokens: Map.get(attrs, :restored_codex_input_tokens, 0),
      restored_codex_output_tokens: Map.get(attrs, :restored_codex_output_tokens, 0),
      restored_codex_total_tokens: Map.get(attrs, :restored_codex_total_tokens, 0),
      codex_last_reported_input_tokens: Map.get(attrs, :codex_last_reported_input_tokens, 0),
      codex_last_reported_output_tokens: Map.get(attrs, :codex_last_reported_output_tokens, 0),
      codex_last_reported_total_tokens: Map.get(attrs, :codex_last_reported_total_tokens, 0),
      turn_count: Map.get(attrs, :turn_count, 0),
      retry_attempt: normalize_retry_attempt(attempt),
      agent_run_id: agent_run_id,
      started_at: Map.get(attrs, :started_at) || DateTime.utc_now()
    }
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: TokenAccounting.running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = TokenAccounting.running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      TokenAccounting.apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: Map.get(running_entry, :restored_codex_input_tokens, 0),
          output_tokens: Map.get(running_entry, :restored_codex_output_tokens, 0),
          total_tokens: Map.get(running_entry, :restored_codex_total_tokens, 0),
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: TokenAccounting.apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case TokenAccounting.rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp record_agent_run_heartbeat(agent_run_id, attrs) do
    log_agent_run_result(agent_run_id, Tracker.heartbeat_agent_run(agent_run_id, attrs), "heartbeat")
  end

  defp record_agent_run_running(agent_run_id, reason) do
    log_agent_run_result(agent_run_id, Tracker.mark_agent_run_running(agent_run_id, reason), "mark running")
  end

  defp record_agent_run_retrying(agent_run_id, reason) do
    log_agent_run_result(agent_run_id, Tracker.mark_agent_run_retrying(agent_run_id, reason), "mark retrying")
  end

  defp record_agent_run_completed(agent_run_id, reason) do
    log_agent_run_result(agent_run_id, Tracker.mark_agent_run_completed(agent_run_id, reason), "mark completed")
  end

  defp record_agent_run_failed(agent_run_id, reason) do
    log_agent_run_result(agent_run_id, Tracker.mark_agent_run_failed(agent_run_id, reason), "mark failed")
  end

  defp record_agent_run_stopped(agent_run_id, reason) do
    log_agent_run_result(agent_run_id, Tracker.mark_agent_run_stopped(agent_run_id, reason), "mark stopped")
  end

  defp log_agent_run_result(nil, _result, _action), do: :ok
  defp log_agent_run_result(_agent_run_id, {:ok, _result}, _action), do: :ok

  defp log_agent_run_result(agent_run_id, {:error, reason}, action) do
    Logger.warning("Failed to #{action} AgentRun agent_run_id=#{agent_run_id}: #{inspect(reason)}")
    {:error, reason}
  end
end
