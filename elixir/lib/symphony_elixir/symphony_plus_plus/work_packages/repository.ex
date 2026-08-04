defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository do
  @moduledoc false

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @terminal_statuses ["skipped", "merged", "merged_into_phase", "closed", "abandoned"]
  @delivery_closeout_terminal_statuses ["merged", "closed", "abandoned"]
  @legacy_ready_status "ready_for_human_merge"
  @ready_status "ready_for_merge"
  @phase_child_kind "phase_child"

  import Ecto.Query, only: [from: 2]

  @type repo :: module()
  @type error ::
          :database_busy
          | :active_blocker
          | :active_runtime
          | :not_found
          | :id_already_exists
          | :invalid_status
          | :stale_status
          | :work_package_mismatch
          | :phase_child_pr_merged_requires_merge_child_into_phase
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

  @spec create(repo(), map()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def create(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs
    |> WorkPackage.create_changeset()
    |> repo.insert()
    |> normalize_insert_result()
    |> notify_dashboard(repo)
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec get(repo(), String.t()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(WorkPackage, id) do
      nil -> {:error, :not_found}
      work_package -> {:ok, work_package}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list(repo()) :: {:ok, [WorkPackage.t()]} | {:error, error()}
  def list(repo) when is_atom(repo) do
    work_packages =
      repo.all(
        from(work_package in WorkPackage,
          order_by: [asc: work_package.inserted_at, asc: work_package.id]
        )
      )

    {:ok, work_packages}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_for_phase(repo(), String.t()) :: {:ok, [WorkPackage.t()]} | {:error, error()}
  def list_for_phase(repo, phase_id) when is_atom(repo) and is_binary(phase_id) do
    work_packages =
      repo.all(
        from(work_package in WorkPackage,
          where: work_package.phase_id == ^phase_id,
          order_by: [asc: work_package.inserted_at, asc: work_package.id]
        )
      )

    {:ok, work_packages}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec update(repo(), String.t(), map()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def update(repo, id, attrs) when is_atom(repo) and is_binary(id) and is_map(attrs) do
    result =
      if terminal_status_update?(attrs) do
        update_with_terminal_cleanup(repo, id, attrs)
      else
        update_directly(repo, id, attrs)
      end

    notify_dashboard(result, repo)
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp update_with_terminal_cleanup(repo, id, attrs) do
    repo.transaction(fn ->
      with {:ok, work_package} <- get(repo, id),
           {:ok, updated} <- work_package |> WorkPackage.update_changeset(attrs) |> repo.update(),
           :ok <- clear_terminal_attention(repo, updated) do
        updated
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  end

  defp update_directly(repo, id, attrs) do
    with {:ok, work_package} <- get(repo, id) do
      work_package
      |> WorkPackage.update_changeset(attrs)
      |> repo.update()
    end
  end

  @spec update_status(repo(), String.t(), String.t(), String.t()) :: {:ok, WorkPackage.t()} | {:error, error()}
  @spec update_status(repo(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, WorkPackage.t()} | {:error, error()}
  def update_status(repo, id, current_status, next_status, opts \\ [])
      when is_atom(repo) and is_binary(id) and is_binary(current_status) and is_binary(next_status) and is_list(opts) do
    with :ok <- validate_persisted_status(current_status),
         :ok <- validate_status(next_status),
         {:ok, expected_contract_revision} <- expected_contract_revision(opts) do
      update_valid_status(repo, id, current_status, next_status, expected_contract_revision)
      |> notify_dashboard(repo)
    end
  end

  @doc false
  @spec close_delivery_work_package(repo(), WorkRequest.t(), WorkPackage.t(), String.t()) ::
          {:ok, map() | nil} | {:error, error()}
  @spec close_delivery_work_package(repo(), WorkRequest.t(), WorkPackage.t(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, error()}
  def close_delivery_work_package(repo, %WorkRequest{} = work_request, %WorkPackage{} = work_package, next_status, opts \\ [])
      when is_atom(repo) and is_binary(next_status) and is_list(opts) do
    repo.transaction(fn ->
      with {:ok, closeout} <- close_delivery_package(repo, work_request, work_package, next_status, opts),
           :ok <- clear_terminal_attention(repo, closeout.work_package) do
        closeout
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @doc false
  @spec clear_terminal_attention(repo(), WorkPackage.t()) :: :ok | {:error, error()}
  def clear_terminal_attention(repo, %WorkPackage{id: work_package_id})
      when is_atom(repo) and is_binary(work_package_id) do
    now = DateTime.utc_now(:microsecond)

    repo.update_all(
      from(request in GuidanceRequest,
        where: request.work_package_id == ^work_package_id,
        where: request.status in ["open", "human_info_needed"]
      ),
      set: [
        status: "answered",
        answer: "Cleared because the owning work reached a terminal state.",
        answered_by: "terminal-cleanup",
        answered_at: now,
        updated_at: now
      ]
    )

    resolve_active_blockers(repo, work_package_id)
  end

  defp close_delivery_package(repo, %WorkRequest{} = work_request, %WorkPackage{} = work_package, next_status, opts) do
    with :ok <- validate_delivery_closeout_status(next_status),
         :ok <- validate_delivery_closeout_package(work_package, work_request, next_status) do
      update_delivery_package(repo, work_package, work_request, next_status, opts)
    end
  end

  defp update_delivery_package(repo, %WorkPackage{status: next_status} = work_package, work_request, next_status, _opts) do
    update_delivery_closeout_status(repo, work_package, work_request, next_status)
  end

  defp update_delivery_package(repo, %WorkPackage{} = work_package, work_request, next_status, opts) do
    with :ok <- reject_active_delivery_closeout_context(repo, work_package.id, opts) do
      update_delivery_closeout_status(repo, work_package, work_request, next_status)
    end
  end

  defp update_valid_status(repo, id, current_status, next_status, expected_contract_revision) do
    now = DateTime.utc_now(:microsecond)

    repo.transaction(fn ->
      id
      |> status_update_query(current_status, expected_contract_revision)
      |> repo.update_all(set: [status: next_status, updated_at: now])
      |> case do
        {1, _rows} ->
          return_status_updated_work_package_or_rollback(repo, id, next_status)

        {0, _rows} ->
          repo.rollback(stale_status_error(repo, id))
      end
    end)
    |> case do
      {:ok, work_package} -> {:ok, work_package}
      {:error, error} -> error
    end
  end

  defp return_status_updated_work_package_or_rollback(repo, id, next_status) when next_status in @terminal_statuses do
    work_package = repo.get!(WorkPackage, id)

    case clear_terminal_attention(repo, work_package) do
      :ok -> work_package
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp return_status_updated_work_package_or_rollback(repo, id, _next_status) do
    case WorkRequestRepository.clear_completion_for_work_package(repo, id) do
      :ok -> repo.get!(WorkPackage, id)
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp notify_dashboard({:ok, %WorkPackage{}} = result, repo) do
    unless repo.in_transaction?(), do: DashboardPubSub.broadcast_changed()
    result
  end

  defp notify_dashboard(result, _repo), do: result

  defp validate_status(status) do
    if status in WorkPackage.statuses() do
      :ok
    else
      {:error, :invalid_status}
    end
  end

  defp validate_persisted_status(@legacy_ready_status), do: :ok
  defp validate_persisted_status(status), do: validate_status(status)

  defp expected_contract_revision(opts) do
    case Keyword.get(opts, :expected_contract_revision) do
      nil -> {:ok, nil}
      revision when is_integer(revision) and revision > 0 -> {:ok, revision}
      _revision -> {:error, :stale_status}
    end
  end

  defp validate_delivery_closeout_status(status) do
    if status in @delivery_closeout_terminal_statuses do
      :ok
    else
      {:error, :invalid_status}
    end
  end

  defp validate_delivery_closeout_package(%WorkPackage{} = work_package, %WorkRequest{} = work_request, next_status) do
    with :ok <- validate_phase_child_delivery_closeout(work_package, next_status),
         :ok <- validate_delivery_package_compatibility(work_package, work_request) do
      validate_delivery_terminal_status_compatibility(work_package, next_status)
    end
  end

  defp validate_phase_child_delivery_closeout(%WorkPackage{kind: @phase_child_kind, status: "merged_into_phase"}, "merged"), do: :ok

  defp validate_phase_child_delivery_closeout(%WorkPackage{kind: @phase_child_kind}, "merged") do
    {:error, :phase_child_pr_merged_requires_merge_child_into_phase}
  end

  defp validate_phase_child_delivery_closeout(%WorkPackage{}, _next_status), do: :ok

  defp validate_delivery_package_compatibility(%WorkPackage{} = work_package, %WorkRequest{} = work_request) do
    if work_package.work_request_id == work_request.id do
      :ok
    else
      {:error, :work_package_mismatch}
    end
  end

  defp validate_delivery_terminal_status_compatibility(%WorkPackage{kind: @phase_child_kind, status: "merged_into_phase"}, "merged"), do: :ok

  defp validate_delivery_terminal_status_compatibility(%WorkPackage{status: status}, next_status)
       when status in @terminal_statuses and status != next_status do
    {:error, :stale_status}
  end

  defp validate_delivery_terminal_status_compatibility(%WorkPackage{}, _next_status), do: :ok

  defp update_delivery_closeout_status(_repo, %WorkPackage{kind: @phase_child_kind, status: "merged_into_phase"} = work_package, _work_request, "merged") do
    {:ok, %{work_package: work_package, previous_status: work_package.status, next_status: work_package.status, changed?: false}}
  end

  defp update_delivery_closeout_status(repo, %WorkPackage{} = work_package, %WorkRequest{} = work_request, next_status) do
    now = DateTime.utc_now(:microsecond)
    previous_status = work_package.status

    repo.update_all(
      delivery_closeout_update_query(work_package, work_request),
      set: [status: next_status, updated_at: now]
    )
    |> case do
      {1, _rows} ->
        {:ok,
         %{
           work_package: repo.get!(WorkPackage, work_package.id),
           previous_status: previous_status,
           next_status: next_status,
           changed?: true
         }}

      {0, _rows} ->
        stale_delivery_closeout_error(repo, work_package.id, previous_status, next_status)
    end
  end

  defp delivery_closeout_update_query(%WorkPackage{} = work_package, %WorkRequest{} = work_request) do
    from(package in WorkPackage,
      where: package.id == ^work_package.id,
      where: package.status == ^work_package.status,
      where: package.work_request_id == ^work_request.id
    )
  end

  defp stale_delivery_closeout_error(repo, id, previous_status, next_status) do
    case get(repo, id) do
      {:ok, %WorkPackage{status: ^next_status} = work_package} ->
        {:ok,
         %{
           work_package: work_package,
           previous_status: previous_status,
           next_status: next_status,
           changed?: false
         }}

      {:ok, %WorkPackage{status: @ready_status} = work_package} when next_status == @legacy_ready_status ->
        {:ok,
         %{
           work_package: work_package,
           previous_status: previous_status,
           next_status: @ready_status,
           changed?: false
         }}

      {:ok, %WorkPackage{status: status}} when status != previous_status ->
        {:error, :stale_status}

      {:ok, %WorkPackage{}} ->
        {:error, :work_package_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reject_active_delivery_closeout_context(repo, work_package_id, opts) do
    context = WorkPackageActivity.context(repo, work_package_id)
    allow_active_blockers? = Keyword.get(opts, :allow_active_blockers?, false)

    cond do
      get_in(context, [:blocker_state, :active?]) == true and not allow_active_blockers? -> {:error, :active_blocker}
      get_in(context, [:runtime_state, :active?]) == true -> {:error, :active_runtime}
      true -> :ok
    end
  end

  defp resolve_active_blockers(repo, work_package_id) do
    with {:ok, owned_events} <- PlanningRepository.list_progress_events(repo, work_package_id),
         {:ok, targeting_events} <-
           PlanningRepository.list_progress_events_for_blockers_targeting_work_package(
             repo,
             work_package_id
           ) do
      (owned_events ++ targeting_events)
      |> Enum.uniq_by(& &1.id)
      |> Enum.group_by(& &1.work_package_id)
      |> Enum.sort_by(fn {owner_id, _events} -> owner_id end)
      |> Enum.reduce_while(:ok, &resolve_targeted_blocker_group(repo, work_package_id, &1, &2))
    end
  end

  defp resolve_targeted_blocker_group(repo, terminal_work_package_id, {owner_id, events}, :ok) do
    events
    |> BlockerProjection.blockers()
    |> Enum.filter(&terminal_cleanup_blocker?(&1, owner_id, terminal_work_package_id))
    |> Enum.reduce_while(:ok, &resolve_active_blocker(repo, owner_id, &1, &2))
    |> case do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp terminal_cleanup_blocker?(blocker, owner_id, terminal_work_package_id) do
    blocker.active and
      (owner_id == terminal_work_package_id or
         blocker.blocked_item == %{kind: "work_package", id: terminal_work_package_id})
  end

  defp resolve_active_blocker(repo, work_package_id, blocker, :ok) do
    case PlanningRepository.append_progress_event(repo, %{
           work_package_id: work_package_id,
           summary: "Cleared blocker after terminal transition: #{blocker.summary || blocker.id}",
           body: "The WorkPackage or its owning WorkRequest reached a terminal state.",
           status: "resolved",
           idempotency_key: "terminal-cleanup:#{work_package_id}:#{blocker.id}:#{blocker.event_id}",
           payload: %{
             type: "blocker",
             source_tool: "resolve_blocker",
             blocker_id: blocker.id,
             resolution: "Owning work reached a terminal state.",
             active: false
           }
         }) do
      {:ok, _event} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp terminal_status_update?(attrs), do: (Map.get(attrs, :status) || Map.get(attrs, "status")) in @terminal_statuses

  defp normalize_transaction_result({:ok, result}), do: {:ok, result}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp normalize_insert_result({:ok, work_package}), do: {:ok, work_package}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    if duplicate_id?(changeset) do
      {:error, :id_already_exists}
    else
      {:error, changeset}
    end
  end

  defp duplicate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_work_packages_id_unique_index"}) do
    {:error, :id_already_exists}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_work_packages_id_index"}) do
    {:error, :id_already_exists}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    {:error, {:constraint_failed, constraint}}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}) do
    {:error, {:constraint_failed, Atom.to_string(type)}}
  end

  defp stale_status_error(repo, id) do
    case get(repo, id) do
      {:ok, _work_package} -> {:error, :stale_status}
      {:error, :not_found} = error -> error
      {:error, reason} -> {:error, reason}
    end
  end

  defp status_update_query(id, current_status, nil) do
    from(work_package in WorkPackage,
      where: work_package.id == ^id and work_package.status == ^current_status
    )
  end

  defp status_update_query(id, current_status, expected_contract_revision) do
    from(work_package in WorkPackage,
      where: work_package.id == ^id and work_package.status == ^current_status,
      where: work_package.contract_revision == ^expected_contract_revision
    )
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
