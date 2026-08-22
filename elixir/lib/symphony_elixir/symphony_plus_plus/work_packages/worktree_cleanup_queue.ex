defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeCleanupQueue do
  @moduledoc false

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle

  @base_backoff_ms 1_000
  @idle_poll_ms 60_000
  @max_backoff_ms 60_000

  defmodule Entry do
    @moduledoc false

    use Ecto.Schema

    @primary_key {:worktree_path, :string, autogenerate: false}

    schema "sympp_worktree_cleanup_queue" do
      field(:work_package_id, :string)
      field(:target_repo_root, :string)
      field(:cleanup_proof, :string)
      field(:attempts, :integer, default: 0)
      field(:next_attempt_at, :utc_datetime_usec)
      field(:last_error, :string)

      timestamps(type: :utc_datetime_usec)
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @spec enqueue_terminal(module(), WorkPackage.t() | [WorkPackage.t()], keyword()) :: :ok | {:error, term()}
  def enqueue_terminal(repo, work_packages, opts \\ []) do
    case work_packages do
      work_packages when is_list(work_packages) ->
        enqueue_each(work_packages, &enqueue_terminal(repo, &1, opts))

      %WorkPackage{status: status} = work_package ->
        if status in ["skipped", "merged", "closed", "abandoned"],
          do: enqueue(repo, work_package, opts),
          else: :ok
    end
  end

  @spec enqueue_for_deletion(module(), [WorkPackage.t()], keyword()) :: :ok | {:error, term()}
  def enqueue_for_deletion(repo, work_packages, opts \\ []) when is_list(work_packages) do
    enqueue_each(work_packages, &enqueue(repo, &1, opts))
  end

  defp enqueue_each(work_packages, enqueue) do
    Enum.reduce_while(work_packages, :ok, fn work_package, :ok ->
      case enqueue.(work_package) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec wake(GenServer.server()) :: :ok
  def wake(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.cast(server, :wake)
    :ok
  end

  @doc false
  @spec reconcile(module(), keyword()) :: :ok | {:error, term()}
  def reconcile(repo, opts \\ []) do
    now = DateTime.utc_now(:microsecond)

    repo.all(
      from(entry in Entry,
        where: is_nil(entry.next_attempt_at) or entry.next_attempt_at <= ^now,
        order_by: [asc: entry.inserted_at, asc: entry.worktree_path]
      )
    )
    |> Enum.each(&reconcile_entry(repo, &1, opts, now))

    :ok
  rescue
    error in Exqlite.Error -> {:error, error}
  end

  @impl true
  def init(opts) do
    state = %{
      repo: Keyword.fetch!(opts, :repo),
      cleanup_opts: Keyword.get(opts, :cleanup_opts, []),
      base_backoff_ms: Keyword.get(opts, :base_backoff_ms, @base_backoff_ms),
      idle_poll_ms: Keyword.get(opts, :idle_poll_ms, @idle_poll_ms),
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, @max_backoff_ms),
      timer: nil
    }

    {:ok, state, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, state) do
    case Repository.migrate(state.repo) do
      :ok ->
        {:noreply, run_and_schedule(state)}

      {:error, reason} ->
        Logger.warning("Worktree cleanup queue startup failed: #{inspect(reason)}")
        {:noreply, schedule(state, state.base_backoff_ms)}
    end
  end

  @impl true
  def handle_cast(:wake, state), do: {:noreply, run_and_schedule(cancel_timer(state))}

  @impl true
  def handle_info(:reconcile, state), do: {:noreply, run_and_schedule(%{state | timer: nil})}

  defp enqueue(_repo, %WorkPackage{worktree_path: nil}, _opts), do: :ok

  defp enqueue(repo, %WorkPackage{} = work_package, opts) do
    case WorktreeLifecycle.cleanup_obligation(work_package, opts) do
      {:ok, attrs} ->
        now = DateTime.utc_now(:microsecond)

        repo.insert_all(
          Entry,
          [Map.merge(attrs, %{attempts: 0, inserted_at: now, updated_at: now})],
          on_conflict: :nothing,
          conflict_target: [:worktree_path]
        )

        wake(Keyword.get(opts, :reconciler, __MODULE__))

      {:error, :unsafe_worktree_path} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in Exqlite.Error -> {:error, error}
  end

  defp run_and_schedule(state) do
    opts =
      state.cleanup_opts ++
        [base_backoff_ms: state.base_backoff_ms, max_backoff_ms: state.max_backoff_ms]

    case reconcile(state.repo, opts) do
      :ok ->
        schedule_next(state)

      {:error, reason} ->
        Logger.warning("Worktree cleanup reconciliation failed: #{Exception.message(reason)}")
        schedule(state, state.base_backoff_ms)
    end
  end

  defp reconcile_entry(repo, %Entry{} = entry, opts, now) do
    cleanup_opts = Keyword.put_new(opts, :force, true)

    result =
      case Repository.get(repo, entry.work_package_id) do
        {:ok, %WorkPackage{worktree_path: path} = work_package} when path == entry.worktree_path ->
          if cleanup_deferred?(repo, work_package),
            do: {:error, :active_runtime},
            else: WorktreeLifecycle.cleanup(repo, work_package.id, cleanup_opts)

        _missing_or_changed ->
          WorktreeLifecycle.cleanup_obligation(repo, entry, cleanup_opts)
      end

    case result do
      {:ok, _cleanup} -> repo.delete_all(from(queued in Entry, where: queued.worktree_path == ^entry.worktree_path))
      {:error, reason} -> postpone(repo, entry, reason, opts, now)
    end
  end

  defp cleanup_deferred?(repo, %WorkPackage{} = work_package) do
    context = WorkPackageActivity.context(repo, work_package.id)
    worker_status = get_in(context, [:worker_signal, :status])
    runtime_active? = get_in(context, [:runtime_state, :active?]) == true
    worker_status in ["active", "paused"] or runtime_active?
  end

  defp postpone(repo, entry, reason, opts, now) do
    attempts = entry.attempts + 1
    base = Keyword.get(opts, :base_backoff_ms, @base_backoff_ms)
    maximum = Keyword.get(opts, :max_backoff_ms, @max_backoff_ms)
    delay = min(base * attempts, maximum)

    repo.update_all(
      from(queued in Entry, where: queued.worktree_path == ^entry.worktree_path),
      set: [
        attempts: attempts,
        next_attempt_at: DateTime.add(now, delay, :millisecond),
        last_error: sanitize_error(reason),
        updated_at: now
      ]
    )
  end

  defp schedule_next(state) do
    case state.repo.one(from(entry in Entry, select: min(entry.next_attempt_at))) do
      nil -> schedule(state, state.idle_poll_ms)
      next_attempt_at -> schedule(state, max(DateTime.diff(next_attempt_at, DateTime.utc_now(), :millisecond), 0))
    end
  rescue
    _error in Exqlite.Error -> schedule(state, state.base_backoff_ms)
  end

  defp schedule(state, delay_ms) do
    %{state | timer: Process.send_after(self(), :reconcile, delay_ms)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp sanitize_error(reason) do
    reason
    |> inspect()
    |> Redactor.redact_text()
    |> String.slice(0, 1_000)
  end
end
