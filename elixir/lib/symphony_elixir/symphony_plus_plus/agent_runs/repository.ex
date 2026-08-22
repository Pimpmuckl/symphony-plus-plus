defmodule SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository do
  @moduledoc false

  import Bitwise, only: [<<<: 2]
  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Completion, as: WorkRequestCompletion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository

  @active_run_statuses AgentRun.active_statuses()
  @terminal_work_package_statuses ["skipped", "merged", "closed", "abandoned"]

  @type repo :: module()
  @type error ::
          :active_run_exists
          | :agent_run_work_package_mismatch
          | :database_busy
          | :id_already_exists
          | :not_active
          | :not_found
          | :work_package_terminal
          | {:constraint_failed, String.t()}
          | {:migration_failed, term()}
          | {:storage_failed, String.t()}
          | Changeset.t()

  @spec migrate(repo()) :: :ok | {:error, error()}
  def migrate(repo) when is_atom(repo) do
    Ecto.Migrator.run(repo, Migrations.all(), :up, all: true, log: false)
    :ok
  rescue
    error -> {:error, {:migration_failed, error}}
  end

  @spec start_run(repo(), map(), keyword()) :: {:ok, AgentRun.t()} | {:error, error()}
  def start_run(repo, attrs, opts \\ []) when is_atom(repo) and is_map(attrs) and is_list(opts) do
    case repo.transaction(fn -> start_run_or_rollback(repo, attrs, opts) end) do
      {:ok, %AgentRun{} = agent_run} ->
        {:ok, agent_run}

      {:ok, {:error, :work_package_terminal}} ->
        maybe_schedule_terminal_worktree_cleanup(repo, work_package_id(attrs))
        {:error, :work_package_terminal}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec get(repo(), String.t()) :: {:ok, AgentRun.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(AgentRun, id) do
      nil -> {:error, :not_found}
      agent_run -> {:ok, agent_run}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_for_work_package(repo(), String.t()) :: {:ok, [AgentRun.t()]} | {:error, error()}
  def list_for_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    agent_runs =
      repo.all(
        from(agent_run in AgentRun,
          where: agent_run.work_package_id == ^work_package_id,
          order_by: [asc: agent_run.started_at, asc: agent_run.id]
        )
      )

    {:ok, agent_runs}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_active(repo()) :: {:ok, [AgentRun.t()]} | {:error, error()}
  def list_active(repo) when is_atom(repo) do
    agent_runs =
      repo.all(
        from(agent_run in AgentRun,
          where: agent_run.status in ^AgentRun.active_statuses(),
          order_by: [asc: agent_run.started_at, asc: agent_run.id]
        )
      )

    {:ok, agent_runs}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec active_for_work_package(repo(), String.t()) :: {:ok, AgentRun.t()} | {:error, error()}
  def active_for_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    query =
      from(agent_run in AgentRun,
        where: agent_run.work_package_id == ^work_package_id,
        where: agent_run.status in ^AgentRun.active_statuses(),
        order_by: [desc: agent_run.started_at, asc: agent_run.id],
        limit: 1
      )

    case repo.one(query) do
      nil -> {:error, :not_found}
      agent_run -> {:ok, agent_run}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec heartbeat(repo(), String.t(), map()) :: {:ok, AgentRun.t()} | {:error, error()}
  def heartbeat(repo, id, attrs \\ %{}) when is_atom(repo) and is_binary(id) and is_map(attrs) do
    update_run(repo, id, Map.put(attrs, :last_seen_at, DateTime.utc_now(:microsecond)))
  end

  @spec mark_retrying(repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_retrying(repo, id, reason \\ nil), do: update_active_status(repo, id, "retrying", reason)

  @spec mark_running(repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_running(repo, id, reason \\ nil), do: update_active_status(repo, id, "running", reason)

  @spec mark_completed(repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_completed(repo, id, reason \\ nil), do: update_terminal_status(repo, id, "completed", reason)

  @spec mark_failed(repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_failed(repo, id, reason \\ nil), do: update_terminal_status(repo, id, "failed", reason)

  @spec mark_stopped(repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_stopped(repo, id, reason \\ nil), do: update_terminal_status(repo, id, "stopped", reason)

  defp update_terminal_status(repo, id, status, reason) do
    now = DateTime.utc_now(:microsecond)
    update_run(repo, id, %{status: status, reason: reason, last_seen_at: now, finished_at: now})
  end

  defp update_active_status(repo, id, status, reason) do
    update_run(repo, id, %{status: status, reason: reason, last_seen_at: DateTime.utc_now(:microsecond)})
  end

  defp start_run_or_rollback(repo, attrs, opts) do
    case start_run_transaction(repo, attrs, opts) do
      {:ok, agent_run} -> agent_run
      {:error, :work_package_terminal} -> preserve_previous_attempt_on_terminal_rejection(repo, attrs, opts)
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp preserve_previous_attempt_on_terminal_rejection(repo, attrs, opts) do
    opts = Keyword.put(opts, :replacement_reason, "work package became terminal before retry dispatch")

    case release_previous_attempt(repo, Keyword.get(opts, :replace_agent_run_id), work_package_id(attrs), opts) do
      :ok -> {:error, :work_package_terminal}
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp start_run_transaction(repo, attrs, opts) do
    work_package_id = work_package_id(attrs)

    with :ok <- reject_terminal_work_package(repo, work_package_id),
         :ok <- release_previous_attempt(repo, Keyword.get(opts, :replace_agent_run_id), work_package_id, opts),
         {:ok, %AgentRun{} = agent_run} <- insert_run_with_recovery(repo, attrs, work_package_id, opts),
         :ok <- clear_completion_for_active_run(repo, agent_run) do
      {:ok, agent_run}
    end
  end

  defp reject_terminal_work_package(repo, work_package_id) when is_binary(work_package_id) do
    case repo.get(WorkPackage, work_package_id) do
      %WorkPackage{status: status} when status in @terminal_work_package_statuses -> {:error, :work_package_terminal}
      %WorkPackage{} -> reject_terminal_delivery(repo, work_package_id)
      nil -> :ok
    end
  end

  defp reject_terminal_work_package(_repo, _work_package_id), do: :ok

  defp reject_terminal_delivery(repo, work_package_id) do
    if repo.one(
         from(delivery in WorkPackageDelivery,
           where: delivery.work_package_id == ^work_package_id,
           select: 1,
           limit: 1
         )
       ) do
      {:error, :work_package_terminal}
    else
      :ok
    end
  end

  defp insert_run(repo, attrs) do
    attrs
    |> AgentRun.create_changeset()
    |> repo.insert()
    |> normalize_insert_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp insert_run_with_recovery(repo, attrs, work_package_id, opts) do
    case insert_run(repo, attrs) do
      {:error, :active_run_exists} ->
        repo
        |> release_retrying_reservation(work_package_id, opts)
        |> maybe_release_stale_starting_run(repo, work_package_id, Keyword.get(opts, :starting_stale_after_ms))
        |> maybe_insert_after_stale_release(repo, attrs)

      result ->
        result
    end
  end

  defp release_previous_attempt(_repo, previous_agent_run_id, _work_package_id, _opts)
       when previous_agent_run_id in [nil, ""],
       do: :ok

  defp release_previous_attempt(repo, previous_agent_run_id, work_package_id, opts)
       when is_binary(previous_agent_run_id) and is_binary(work_package_id) do
    case get(repo, previous_agent_run_id) do
      {:ok, %AgentRun{} = agent_run} ->
        release_previous_agent_run(repo, agent_run, work_package_id, opts)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release_previous_attempt(_repo, _previous_agent_run_id, _work_package_id, _opts), do: :ok

  defp release_previous_agent_run(repo, %AgentRun{work_package_id: work_package_id, status: status, id: id}, work_package_id, opts)
       when status in ["starting", "retrying"] do
    mark_previous_attempt_failed(repo, id, status, Keyword.get(opts, :replacement_reason, "replaced by retry dispatch"))
  end

  defp release_previous_agent_run(repo, %AgentRun{work_package_id: work_package_id, status: "running", id: id}, work_package_id, opts) do
    release_confirmed_dead_running_attempt(repo, id, opts)
  end

  defp release_previous_agent_run(_repo, %AgentRun{work_package_id: work_package_id}, work_package_id, _opts), do: :ok
  defp release_previous_agent_run(_repo, %AgentRun{}, _work_package_id, _opts), do: {:error, :agent_run_work_package_mismatch}

  defp release_confirmed_dead_running_attempt(repo, previous_agent_run_id, opts) do
    if Keyword.get(opts, :replace_confirmed_dead_worker) == true do
      reason = Keyword.get(opts, :replacement_reason, "replaced after confirmed worker exit")
      mark_previous_attempt_failed(repo, previous_agent_run_id, "running", reason)
    else
      :ok
    end
  end

  defp mark_previous_attempt_failed(repo, previous_agent_run_id, expected_status, reason) do
    now = DateTime.utc_now(:microsecond)

    {updated_count, _rows} =
      repo.update_all(
        from(agent_run in AgentRun,
          where: agent_run.id == ^previous_agent_run_id,
          where: agent_run.status == ^expected_status
        ),
        set: [
          status: "failed",
          reason: reason,
          last_seen_at: now,
          finished_at: now,
          updated_at: now
        ]
      )

    case updated_count do
      0 -> :ok
      1 -> :ok
      _count -> {:error, {:constraint_failed, "multiple_previous_agent_runs"}}
    end
  end

  defp release_retrying_reservation(repo, work_package_id, opts) when is_binary(work_package_id) and is_list(opts) do
    with %AgentRun{} = agent_run <- retrying_for_work_package(repo, work_package_id),
         recover_after_ms when is_integer(recover_after_ms) and recover_after_ms >= 0 <-
           retry_recovery_delay_ms(agent_run, opts) do
      release_retrying_reservation(repo, agent_run, recover_after_ms)
    else
      nil -> {:ok, :active}
      _recover_after_ms -> {:ok, :active}
    end
  end

  defp release_retrying_reservation(repo, %AgentRun{} = agent_run, recover_after_ms) do
    now = DateTime.utc_now(:microsecond)
    recovery_cutoff = DateTime.add(now, -recover_after_ms, :millisecond)

    {updated_count, _rows} =
      repo.update_all(
        from(agent_run in AgentRun,
          where: agent_run.id == ^agent_run.id,
          where: agent_run.status == "retrying",
          where: agent_run.last_seen_at <= ^recovery_cutoff
        ),
        set: [
          status: "failed",
          reason: "retry reservation recovered by dispatch",
          last_seen_at: now,
          finished_at: now,
          updated_at: now
        ]
      )

    case updated_count do
      0 ->
        {:ok, :active}

      1 ->
        {:ok, :released}

      _count ->
        {:error, {:constraint_failed, "multiple_retrying_agent_runs"}}
    end
  end

  defp release_retrying_reservation(_repo, _work_package_id, _opts), do: {:ok, :active}

  defp retrying_for_work_package(repo, work_package_id) do
    repo.one(
      from(agent_run in AgentRun,
        where: agent_run.work_package_id == ^work_package_id,
        where: agent_run.status == "retrying",
        order_by: [desc: agent_run.started_at, asc: agent_run.id],
        limit: 1
      )
    )
  end

  defp retry_recovery_delay_ms(%AgentRun{} = agent_run, opts) do
    with base_ms when is_integer(base_ms) and base_ms >= 0 <- Keyword.get(opts, :retry_recovery_base_ms),
         max_ms when is_integer(max_ms) and max_ms >= 0 <- Keyword.get(opts, :retry_recovery_max_ms) do
      next_attempt =
        case agent_run.attempt do
          attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
          _attempt -> 1
        end

      max_delay_power = min(next_attempt - 1, 10)
      min(base_ms * (1 <<< max_delay_power), max_ms)
    end
  end

  defp maybe_release_stale_starting_run({:ok, :released}, _repo, _work_package_id, _stale_after_ms), do: {:ok, :released}

  defp maybe_release_stale_starting_run({:ok, :active}, repo, work_package_id, stale_after_ms) do
    release_stale_status(repo, work_package_id, "starting", stale_after_ms, "stale starting AgentRun released before dispatch")
  end

  defp maybe_release_stale_starting_run({:error, reason}, _repo, _work_package_id, _stale_after_ms), do: {:error, reason}

  defp release_stale_status(_repo, _work_package_id, _statuses, stale_after_ms, _reason)
       when not is_integer(stale_after_ms) or stale_after_ms <= 0,
       do: {:ok, :active}

  defp release_stale_status(repo, work_package_id, statuses, stale_after_ms, reason)
       when is_binary(work_package_id) and is_list(statuses) do
    now = DateTime.utc_now(:microsecond)
    stale_cutoff = DateTime.add(now, -stale_after_ms, :millisecond)

    {updated_count, _rows} =
      repo.update_all(
        from(agent_run in AgentRun,
          where: agent_run.work_package_id == ^work_package_id,
          where: agent_run.status in ^statuses,
          where: agent_run.last_seen_at <= ^stale_cutoff
        ),
        set: [
          status: "failed",
          reason: reason,
          last_seen_at: now,
          finished_at: now,
          updated_at: now
        ]
      )

    case updated_count do
      0 ->
        {:ok, :active}

      1 ->
        with :ok <- WorkRequestRepository.clear_completion_for_work_package(repo, work_package_id) do
          {:ok, :released}
        end

      _count ->
        {:error, {:constraint_failed, "multiple_active_agent_runs"}}
    end
  end

  defp release_stale_status(repo, work_package_id, status, stale_after_ms, reason)
       when is_binary(status) do
    release_stale_status(repo, work_package_id, [status], stale_after_ms, reason)
  end

  defp maybe_insert_after_stale_release({:ok, :released}, repo, attrs), do: insert_run(repo, attrs)
  defp maybe_insert_after_stale_release({:ok, :active}, _repo, _attrs), do: {:error, :active_run_exists}
  defp maybe_insert_after_stale_release({:error, reason}, _repo, _attrs), do: {:error, reason}

  defp work_package_id(attrs), do: Map.get(attrs, :work_package_id) || Map.get(attrs, "work_package_id")

  defp update_run(repo, id, attrs) do
    case repo.transaction(fn -> update_run_or_rollback(repo, id, attrs) end) do
      {:ok, agent_run} ->
        maybe_schedule_terminal_worktree_cleanup(repo, agent_run)
        {:ok, agent_run}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp update_run_or_rollback(repo, id, attrs) do
    case update_run_transaction(repo, id, attrs) do
      {:ok, agent_run} -> agent_run
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp update_run_transaction(repo, id, attrs) do
    with {:ok, agent_run} <- get(repo, id),
         :ok <- active_agent_run?(agent_run),
         {:ok, changes} <- update_changes(agent_run, attrs),
         :ok <- revalidate_running_transition(repo, agent_run, changes) do
      persist_active_update(repo, id, changes)
    end
  end

  defp revalidate_running_transition(repo, %AgentRun{work_package_id: work_package_id}, %{status: "running"}) do
    reject_terminal_work_package(repo, work_package_id)
  end

  defp revalidate_running_transition(_repo, %AgentRun{}, _changes), do: :ok

  defp update_changes(%AgentRun{} = agent_run, attrs) do
    changeset = AgentRun.update_changeset(agent_run, attrs)

    if changeset.valid? do
      {:ok, Map.put(changeset.changes, :updated_at, DateTime.utc_now(:microsecond))}
    else
      {:error, changeset}
    end
  end

  defp persist_active_update(repo, id, changes) when map_size(changes) > 0 do
    {updated_count, _rows} =
      repo.update_all(
        from(agent_run in AgentRun,
          where: agent_run.id == ^id,
          where: agent_run.status in ^AgentRun.active_statuses()
        ),
        set: Map.to_list(changes)
      )

    case updated_count do
      1 ->
        with {:ok, %AgentRun{} = agent_run} <- get(repo, id),
             :ok <- clear_completion_for_active_run(repo, agent_run) do
          {:ok, agent_run}
        end

      0 ->
        {:error, :not_active}

      _count ->
        {:error, {:constraint_failed, "multiple_agent_run_updates"}}
    end
  end

  defp clear_completion_for_active_run(repo, %AgentRun{status: status, work_package_id: work_package_id})
       when status in @active_run_statuses and is_binary(work_package_id) do
    if repo.one(
         from(delivery in WorkPackageDelivery,
           where: delivery.work_package_id == ^work_package_id,
           select: 1,
           limit: 1
         )
       ) do
      :ok
    else
      WorkRequestRepository.clear_completion_for_work_package(repo, work_package_id)
    end
  end

  defp clear_completion_for_active_run(_repo, %AgentRun{}), do: :ok

  defp maybe_schedule_terminal_worktree_cleanup(repo, %AgentRun{status: status, work_package_id: work_package_id})
       when status in ["completed", "failed", "stopped"] and is_binary(work_package_id) do
    maybe_schedule_terminal_worktree_cleanup(repo, work_package_id)
  end

  defp maybe_schedule_terminal_worktree_cleanup(_repo, %AgentRun{}), do: :ok

  defp maybe_schedule_terminal_worktree_cleanup(repo, work_package_id) when is_binary(work_package_id) do
    WorkRequestCompletion.schedule_terminal_agent_run_worktree_cleanup(repo, work_package_id)
  end

  defp maybe_schedule_terminal_worktree_cleanup(_repo, _work_package_id), do: :ok

  defp active_agent_run?(%AgentRun{status: status}) when status in ["starting", "running", "retrying"], do: :ok
  defp active_agent_run?(%AgentRun{}), do: {:error, :not_active}

  defp normalize_insert_result({:ok, agent_run}), do: {:ok, agent_run}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    cond do
      duplicate_id?(changeset) -> {:error, :id_already_exists}
      active_run_conflict?(changeset) -> {:error, :active_run_exists}
      true -> {:error, changeset}
    end
  end

  defp duplicate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp active_run_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:work_package_id, {_message, options}} ->
        constraint_name = Keyword.get(options, :constraint_name)

        constraint_name in [
          "sympp_agent_runs_one_active_per_work_package_index",
          "sympp_agent_runs_work_package_id_index"
        ] or Keyword.get(options, :constraint) == :unique

      _error ->
        false
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_agent_runs_id_unique_index"}) do
    {:error, :id_already_exists}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_agent_runs_one_active_per_work_package_index"}) do
    {:error, :active_run_exists}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_agent_runs_work_package_id_index"}) do
    {:error, :active_run_exists}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    {:error, {:constraint_failed, constraint}}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}) do
    {:error, {:constraint_failed, Atom.to_string(type)}}
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    if String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end
end
