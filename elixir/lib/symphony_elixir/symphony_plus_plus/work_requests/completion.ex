defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Completion do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Comments.Service, as: CommentService
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Service, as: WorkPackageService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @terminal_work_package_statuses ["skipped", "merged", "merged_into_phase", "closed", "abandoned"]
  @terminal_delivery_outcomes ["pr_merged", "completed_no_pr", "superseded", "abandoned"]
  @durable_cleanup_deferral_reasons ["claim_lease_paused", "claim_lease_active", "worker_grant_active", "architect_grant_active"]
  @completion_blocking_work_request_statuses ["human_info_needed"]
  @operator_completion_source "operator"
  @restorable_archive_reasons ["age"]
  @default_archive_after_days 14
  @completed_visible_limit 10
  @delete_work_request_chunk_size 500

  @type context :: %{optional(:work_package) => WorkPackage.t(), optional(:card) => map()}
  @type state :: %{completed?: boolean(), completed_at: DateTime.t() | nil, archived_at: DateTime.t() | nil}
  @type retention_summary :: %{
          refreshed_count: non_neg_integer(),
          archived_count: non_neg_integer(),
          archived_ids: [String.t()],
          deleted_count: non_neg_integer(),
          deleted_ids: [String.t()]
        }
  @type delete_error :: Repository.error() | WorkPackageService.error()
  @type retention_error ::
          delete_error()
          | :active_runtime
          | :invalid_archive_after_days
          | :invalid_delete_after_days
          | :not_completed

  @spec default_archive_after_days() :: pos_integer()
  def default_archive_after_days, do: @default_archive_after_days

  @spec schedule_terminal_agent_run_worktree_cleanup(module(), String.t()) :: :ok
  def schedule_terminal_agent_run_worktree_cleanup(repo, work_package_id)
      when is_atom(repo) and is_binary(work_package_id) do
    case canonical_delivery_closeout(repo, work_package_id) do
      {:ok, {delivery, _event}} ->
        opts = cleanup_env_opts()
        cleanup_terminal_agent_run_worktree(repo, work_package_id, delivery, opts)
        :ok

      {:error, _reason} ->
        :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @spec blocker_event_payload?(map()) :: boolean()
  def blocker_event_payload?(payload) when is_map(payload) do
    WorkPackageActivity.blocker_event_payload?(payload)
  end

  @spec state(WorkRequest.t(), map(), [WorkPackage.t()], %{optional(String.t()) => context()}) ::
          state()
  @spec state(WorkRequest.t(), map(), [WorkPackage.t()], %{optional(String.t()) => context()}, %{
          optional(String.t()) => WorkPackageDelivery.t()
        }) :: state()
  def state(
        %WorkRequest{} = work_request,
        question_state,
        work_packages,
        work_package_contexts,
        deliveries_by_slice_id \\ %{}
      )
      when is_map(question_state) and is_list(work_packages) and is_map(work_package_contexts) and
             is_map(deliveries_by_slice_id) do
    if operator_completed?(work_request) do
      %{
        completed?: true,
        completed_at: work_request.completed_at,
        archived_at: work_request.archived_at
      }
    else
      derived_state(work_request, question_state, work_packages, work_package_contexts, deliveries_by_slice_id)
    end
  end

  defp derived_state(
         %WorkRequest{} = work_request,
         question_state,
         work_packages,
         work_package_contexts,
         deliveries_by_slice_id
       )
       when is_map(question_state) and is_list(work_packages) and is_map(work_package_contexts) and
              is_map(deliveries_by_slice_id) do
    completed? =
      derived_completed?(
        work_request,
        question_state,
        work_packages,
        work_package_contexts,
        deliveries_by_slice_id
      )

    completed_at =
      derived_completed_at_if_complete(
        completed?,
        work_request,
        question_state,
        work_packages,
        work_package_contexts,
        deliveries_by_slice_id
      )

    %{
      completed?: completed?,
      completed_at: completed_at,
      archived_at: if(completed?, do: work_request.archived_at)
    }
  end

  defp derived_completed?(
         %WorkRequest{} = work_request,
         question_state,
         work_packages,
         work_package_contexts,
         deliveries_by_slice_id
       ) do
    completion_status_allowed?(work_request) and
      Map.get(question_state, :open_count, 0) == 0 and
      work_packages != [] and
      Enum.all?(work_packages, fn work_package ->
        terminal_slice?(
          work_package,
          Map.get(work_package_contexts, work_package.id),
          Map.get(deliveries_by_slice_id, work_package.id)
        )
      end)
  end

  defp derived_completed_at_if_complete(false, %WorkRequest{}, _question_state, _work_packages, _work_package_contexts, _deliveries_by_slice_id), do: nil

  defp derived_completed_at_if_complete(true, %WorkRequest{} = work_request, question_state, work_packages, work_package_contexts, deliveries_by_slice_id) do
    work_request.completed_at ||
      derived_completed_at(
        work_request,
        work_packages,
        work_package_contexts,
        deliveries_by_slice_id,
        Map.get(question_state, :latest_gate_at)
      )
  end

  @spec visible_state(WorkRequest.t(), map(), [WorkPackage.t()], %{optional(String.t()) => context()}) ::
          state()
  @spec visible_state(WorkRequest.t(), map(), [WorkPackage.t()], %{optional(String.t()) => context()}, map()) ::
          state()
  def visible_state(
        %WorkRequest{} = work_request,
        question_state,
        work_packages,
        work_package_contexts,
        deliveries_by_slice_id \\ %{}
      )
      when is_map(question_state) and is_list(work_packages) and is_map(work_package_contexts) and
             is_map(deliveries_by_slice_id) do
    work_request
    |> state(question_state, work_packages, work_package_contexts, deliveries_by_slice_id)
    |> preserve_persisted_visible_state(
      work_request,
      question_state,
      work_packages,
      work_package_contexts,
      deliveries_by_slice_id
    )
  end

  @spec refresh(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, Repository.error()}
  def refresh(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    repo.transaction(fn ->
      case refresh_in_transaction(repo, work_request_id) do
        {:ok, work_request} -> work_request
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @doc false
  @spec refresh_in_transaction(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, Repository.error()}
  def refresh_in_transaction(repo, work_request_id) do
    with {:ok, work_request} <- Repository.get(repo, work_request_id),
         {:ok, question_state} <- question_state(repo, work_request_id),
         {:ok, work_packages} <- Repository.list_work_packages(repo, work_request_id),
         {:ok, deliveries_by_slice_id} <- work_package_deliveries_by_id(repo, work_packages),
         :ok <- clear_terminal_work_package_attention(repo, work_packages, deliveries_by_slice_id),
         {:ok, contexts} <- work_package_contexts(repo, work_packages) do
      state = state(work_request, question_state, work_packages, contexts, deliveries_by_slice_id)
      persist_state(repo, work_request, state, work_packages)
    end
  end

  @spec force_complete(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, Repository.error()}
  def force_complete(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    repo.transaction(fn ->
      with {:ok, %WorkRequest{} = work_request} <- Repository.get(repo, work_request_id),
           {:ok, work_packages} <- Repository.list_work_packages(repo, work_request_id),
           :ok <- clear_completed_attention(repo, work_request.id, work_packages),
           {:ok, updated} <- force_complete_work_request(repo, work_request) do
        updated
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec archive(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, Repository.error() | :not_completed}
  def archive(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    with {:ok, %WorkRequest{} = work_request} <- refresh(repo, work_request_id) do
      if is_nil(work_request.completed_at) do
        {:error, :not_completed}
      else
        archive_completed(repo, work_request, "manual")
      end
    end
  end

  @spec restore(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, Repository.error()}
  def restore(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    with {:ok, %WorkRequest{} = work_request} <- refresh(repo, work_request_id) do
      restore_completed(repo, work_request)
    end
  end

  @spec delete(Repository.repo(), String.t()) :: {:ok, String.t()} | {:error, delete_error()}
  def delete(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    with {:ok, %WorkRequest{}} <- Repository.get(repo, work_request_id),
         work_package_ids <- archived_work_package_ids(repo, [work_request_id]),
         :ok <- cleanup_work_package_worktrees(repo, work_package_ids, force: true) do
      delete_work_request_with_dependents(repo, work_request_id, work_package_ids)
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec retention_pass(Repository.repo()) :: {:ok, retention_summary()} | {:error, retention_error()}
  @spec retention_pass(Repository.repo(), keyword()) :: {:ok, retention_summary()} | {:error, retention_error()}
  def retention_pass(repo, opts \\ []) when is_atom(repo) and is_list(opts) do
    now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now(:microsecond) end)

    with {:ok, archive_after_days} <- archive_after_days(opts),
         {:ok, delete_after_days} <- delete_after_days(opts),
         {:ok, age_candidates} <- retention_age_candidates(repo, now, archive_after_days),
         {:ok, refreshed} <- refresh_all(repo, age_candidates),
         {:ok, _restored_for_age} <- restore_unexpired(repo, refreshed, now, archive_after_days),
         {:ok, archived_for_age} <- archive_expired(repo, refreshed, now, archive_after_days),
         {:ok, visible_completed} <- completed_unarchived(repo),
         {:ok, archived_for_limit, overflow_refreshed_count} <- archive_overflow(repo, visible_completed),
         {:ok, deleted_ids} <- delete_expired_archived(repo, now, delete_after_days) do
      archived_ids = archived_for_age ++ archived_for_limit

      {:ok,
       %{
         refreshed_count: length(refreshed) + overflow_refreshed_count,
         archived_count: length(archived_ids),
         archived_ids: archived_ids,
         deleted_count: length(deleted_ids),
         deleted_ids: deleted_ids
       }}
    end
  end

  defp persist_state(repo, %WorkRequest{} = work_request, %{completed?: true} = state, work_packages) do
    attrs = %{
      completed_at: state.completed_at || DateTime.utc_now(:microsecond),
      completion_source: work_request.completion_source,
      archived_at: state.archived_at,
      archive_reason: if(state.archived_at, do: work_request.archive_reason)
    }

    unchanged? =
      work_request.completed_at == attrs.completed_at and work_request.archived_at == attrs.archived_at and
        work_request.archive_reason == attrs.archive_reason and
        work_request.completion_source == attrs.completion_source

    with :ok <- clear_completed_attention(repo, work_request.id, work_packages) do
      if unchanged? do
        {:ok, work_request}
      else
        work_request
        |> Ecto.Changeset.change(attrs)
        |> update_work_request(repo)
      end
    end
  end

  defp persist_state(repo, %WorkRequest{} = work_request, %{completed?: false}, _work_packages) do
    attrs = %{completed_at: nil, completion_source: nil, archived_at: nil, archive_reason: nil}

    if is_nil(work_request.completed_at) and is_nil(work_request.archived_at) and
         is_nil(work_request.completion_source) do
      {:ok, work_request}
    else
      work_request
      |> Ecto.Changeset.change(attrs)
      |> update_work_request(repo)
    end
  end

  defp preserve_persisted_visible_state(
         %{completed?: false} = state,
         %WorkRequest{completed_at: %DateTime{} = completed_at} = work_request,
         question_state,
         work_packages,
         work_package_contexts,
         deliveries_by_slice_id
       ) do
    if completion_status_allowed?(work_request) and
         filtered_completion_context?(question_state, work_packages, work_package_contexts, deliveries_by_slice_id) do
      %{state | completed?: true, completed_at: completed_at, archived_at: work_request.archived_at}
    else
      state
    end
  end

  defp preserve_persisted_visible_state(state, %WorkRequest{}, _question_state, _work_packages, _work_package_contexts, _deliveries_by_slice_id), do: state

  defp force_complete_work_request(repo, %WorkRequest{} = work_request) do
    attrs = %{
      completed_at: work_request.completed_at || DateTime.utc_now(:microsecond),
      completion_source: @operator_completion_source,
      archived_at: nil,
      archive_reason: nil
    }

    work_request
    |> Ecto.Changeset.change(attrs)
    |> update_work_request(repo)
  end

  defp clear_completed_attention(repo, work_request_id, work_packages) do
    now = DateTime.utc_now(:microsecond)

    repo.update_all(
      from(question in ClarificationQuestion,
        where: question.work_request_id == ^work_request_id and question.status == "open"
      ),
      set: [status: "closed", updated_at: now]
    )

    Enum.reduce_while(work_packages, :ok, fn work_package, :ok ->
      case WorkPackageRepository.clear_terminal_attention(repo, work_package) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp clear_terminal_work_package_attention(repo, work_packages, deliveries_by_slice_id) do
    work_packages
    |> Enum.filter(fn work_package ->
      work_package.status in @terminal_work_package_statuses or
        terminal_delivery?(Map.get(deliveries_by_slice_id, work_package.id))
    end)
    |> Enum.reduce_while(:ok, fn work_package, :ok ->
      case WorkPackageRepository.clear_terminal_attention(repo, work_package) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp operator_completed?(%WorkRequest{completed_at: %DateTime{}, completion_source: @operator_completion_source}), do: true
  defp operator_completed?(%WorkRequest{}), do: false

  defp filtered_completion_context?(question_state, work_packages, work_package_contexts, deliveries_by_slice_id) do
    Map.get(question_state, :open_count, 0) == 0 and work_packages != [] and
      Enum.all?(work_packages, &terminal_or_filtered_slice?(&1, work_package_contexts, deliveries_by_slice_id))
  end

  defp terminal_or_filtered_slice?(%WorkPackage{status: status, id: id}, work_package_contexts, deliveries_by_slice_id)
       when status in @terminal_work_package_statuses do
    context = Map.get(work_package_contexts, id)
    delivery = Map.get(deliveries_by_slice_id, id)

    not active_blocker_context?(context) and
      (terminal_delivery?(delivery) or not active_runtime_context?(context))
  end

  defp terminal_or_filtered_slice?(%WorkPackage{id: id}, _work_package_contexts, deliveries_by_slice_id),
    do: terminal_delivery?(Map.get(deliveries_by_slice_id, id))

  defp completion_status_allowed?(%WorkRequest{status: status}), do: status not in @completion_blocking_work_request_statuses

  defp refresh_all(repo, work_requests) do
    work_requests
    |> Enum.map(&refresh(repo, &1.id))
    |> collect_or_error()
  end

  defp archive_after_days(opts) do
    case Keyword.get(opts, :archive_after_days, @default_archive_after_days) do
      days when is_integer(days) and days >= 1 -> {:ok, days}
      _days -> {:error, :invalid_archive_after_days}
    end
  end

  defp delete_after_days(opts) do
    case Keyword.get(opts, :delete_after_days) do
      nil -> {:ok, nil}
      days when is_integer(days) and days >= 1 -> {:ok, days}
      _days -> {:error, :invalid_delete_after_days}
    end
  end

  defp archive_expired(repo, work_requests, now, archive_after_days) do
    cutoff = DateTime.add(now, -archive_after_days * 24 * 60 * 60, :second)

    work_requests
    |> Enum.filter(&archive_expired?(&1, cutoff))
    |> archive_all(repo)
  end

  defp archive_expired?(%WorkRequest{completed_at: %DateTime{} = completed_at, archived_at: nil}, cutoff) do
    DateTime.compare(completed_at, cutoff) in [:lt, :eq]
  end

  defp archive_expired?(%WorkRequest{}, _cutoff), do: false

  defp restore_unexpired(repo, work_requests, now, archive_after_days) do
    cutoff = DateTime.add(now, -archive_after_days * 24 * 60 * 60, :second)

    work_requests
    |> Enum.filter(&restore_unexpired?(&1, cutoff))
    |> restore_all(repo)
  end

  defp restore_unexpired?(
         %WorkRequest{
           completed_at: %DateTime{} = completed_at,
           archived_at: %DateTime{},
           archive_reason: archive_reason
         },
         cutoff
       ) do
    archive_reason in @restorable_archive_reasons and DateTime.compare(completed_at, cutoff) == :gt
  end

  defp restore_unexpired?(%WorkRequest{}, _cutoff), do: false

  defp archive_overflow(repo, work_requests) do
    work_requests
    |> Enum.group_by(&{&1.repo, &1.base_branch})
    |> Enum.reduce_while({:ok, [], 0}, fn {_scope, scoped_work_requests}, {:ok, archived_ids, refreshed_count} ->
      case archive_overflow_scope(repo, scoped_work_requests) do
        {:ok, scoped_archived_ids, scoped_refreshed_count} ->
          {:cont, {:ok, archived_ids ++ scoped_archived_ids, refreshed_count + scoped_refreshed_count}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, archived_ids, refreshed_count} -> {:ok, archived_ids, refreshed_count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp archive_overflow_scope(repo, work_requests) do
    sorted_work_requests = Enum.sort_by(work_requests, &completed_sort_key/1)
    archive_count = max(length(sorted_work_requests) - @completed_visible_limit, 0)

    archive_overflow_candidates(repo, sorted_work_requests, archive_count, [], 0)
  end

  defp archive_overflow_candidates(_repo, _work_requests, 0, archived_ids, refreshed_count),
    do: {:ok, Enum.reverse(archived_ids), refreshed_count}

  defp archive_overflow_candidates(_repo, [], _archive_count, archived_ids, refreshed_count),
    do: {:ok, Enum.reverse(archived_ids), refreshed_count}

  defp archive_overflow_candidates(repo, [work_request | rest], archive_count, archived_ids, refreshed_count) do
    case refresh(repo, work_request.id) do
      {:ok, %WorkRequest{archived_at: %DateTime{}}} ->
        archive_overflow_candidates(repo, rest, archive_count - 1, archived_ids, refreshed_count + 1)

      {:ok, %WorkRequest{completed_at: nil}} ->
        archive_overflow_candidates(repo, rest, archive_count, archived_ids, refreshed_count + 1)

      {:ok, %WorkRequest{} = refreshed} ->
        case archive_completed(repo, refreshed, "limit") do
          {:ok, %WorkRequest{id: id}} ->
            archive_overflow_candidates(repo, rest, archive_count - 1, [id | archived_ids], refreshed_count + 1)

          {:error, :not_completed} ->
            archive_overflow_candidates(repo, rest, archive_count, archived_ids, refreshed_count + 1)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp archive_all(work_requests, repo, archive_reason \\ "age") do
    work_requests
    |> Enum.reduce_while({:ok, []}, fn work_request, {:ok, archived_ids} ->
      case archive_completed(repo, work_request, archive_reason) do
        {:ok, %WorkRequest{id: id}} -> {:cont, {:ok, [id | archived_ids]}}
        {:error, :not_completed} -> {:cont, {:ok, archived_ids}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, archived_ids} -> {:ok, Enum.reverse(archived_ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_all(work_requests, repo) do
    work_requests
    |> Enum.map(&restore_completed(repo, &1, reset_completed_at?: false))
    |> collect_or_error()
    |> case do
      {:ok, restored} -> {:ok, Enum.map(restored, & &1.id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retention_age_candidates(repo, now, archive_after_days) do
    cutoff = DateTime.add(now, -archive_after_days * 24 * 60 * 60, :second)

    work_requests =
      repo.all(
        from(work_request in WorkRequest,
          where: not is_nil(work_request.completed_at),
          where:
            (is_nil(work_request.archived_at) and work_request.completed_at <= ^cutoff) or
              (not is_nil(work_request.archived_at) and
                 work_request.archive_reason in ^@restorable_archive_reasons and work_request.completed_at > ^cutoff),
          order_by: [asc: work_request.inserted_at, asc: work_request.id]
        )
      )

    {:ok, work_requests}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp completed_unarchived(repo) do
    work_requests =
      repo.all(
        from(work_request in WorkRequest,
          where: is_nil(work_request.archived_at),
          where: not is_nil(work_request.completed_at),
          order_by: [asc: work_request.completed_at, asc: work_request.inserted_at, asc: work_request.id]
        )
      )

    {:ok, work_requests}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp delete_expired_archived(_repo, _now, nil), do: {:ok, []}

  defp delete_expired_archived(repo, now, delete_after_days) do
    cutoff = DateTime.add(now, -delete_after_days * 24 * 60 * 60, :second)

    archived =
      repo.all(
        from(work_request in WorkRequest,
          where: not is_nil(work_request.archived_at),
          where: work_request.archived_at < ^cutoff,
          order_by: [asc: work_request.archived_at, asc: work_request.id],
          select: work_request.id
        )
      )

    delete_archived_work_requests_with_cleanup(repo, archived, cutoff)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp delete_archived_work_requests_with_cleanup(repo, work_request_ids, cutoff) do
    work_request_ids
    |> Enum.reduce_while({:ok, []}, fn work_request_id, {:ok, deleted_ids} ->
      case delete_archived_work_request_with_cleanup(repo, work_request_id, cutoff) do
        {:ok, nil} -> {:cont, {:ok, deleted_ids}}
        {:ok, deleted_id} -> {:cont, {:ok, [deleted_id | deleted_ids]}}
        {:error, :not_completed} -> {:cont, {:ok, deleted_ids}}
        {:error, reason} -> maybe_skip_archived_cleanup_error(reason, deleted_ids)
      end
    end)
    |> case do
      {:ok, deleted_ids} -> {:ok, Enum.reverse(deleted_ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_archived_work_request_with_cleanup(repo, work_request_id, cutoff) do
    work_package_ids = archived_work_package_ids(repo, [work_request_id])

    with {:ok, _current} <- claim_archived_before(repo, work_request_id, cutoff),
         :ok <- cleanup_work_package_worktrees(repo, work_package_ids, force: true) do
      repo.transaction(fn ->
        delete_archived_work_request_after_dependents(
          repo,
          work_request_id,
          work_package_ids,
          cutoff
        )
      end)
    end
  end

  defp delete_archived_work_request_after_dependents(repo, work_request_id, work_package_ids, cutoff) do
    case require_archived_before(repo, work_request_id, cutoff) do
      {:ok, _current} ->
        case delete_work_request_dependents(repo, [work_request_id], work_package_ids) do
          :ok -> delete_archived_work_request(repo, work_request_id, cutoff)
          {:error, reason} -> repo.rollback(reason)
        end

      {:error, :not_completed} ->
        nil

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp delete_archived_work_request(repo, work_request_id, cutoff) do
    case delete_archived_work_request_if_still_archived(repo, work_request_id, cutoff) do
      1 -> work_request_id
      0 -> nil
    end
  end

  defp delete_archived_work_request_if_still_archived(repo, work_request_id, cutoff) do
    {count, _rows} =
      repo.delete_all(
        from(work_request in WorkRequest,
          where: work_request.id == ^work_request_id,
          where: not is_nil(work_request.completed_at),
          where: not is_nil(work_request.archived_at),
          where: work_request.archived_at < ^cutoff
        )
      )

    count
  end

  defp delete_work_request_with_dependents(repo, work_request_id, work_package_ids) do
    repo.transaction(fn ->
      case delete_work_request_dependents(repo, [work_request_id], work_package_ids) do
        :ok -> delete_work_request_row(repo, work_request_id)
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp delete_work_request_row(repo, work_request_id) do
    {count, _rows} =
      repo.delete_all(
        from(work_request in WorkRequest,
          where: work_request.id == ^work_request_id
        )
      )

    case count do
      1 -> work_request_id
      0 -> repo.rollback(:not_found)
    end
  end

  defp archived_work_package_ids(repo, work_request_ids) do
    work_request_ids
    |> Enum.chunk_every(@delete_work_request_chunk_size)
    |> Enum.flat_map(fn ids ->
      repo.all(
        from(work_package in WorkPackage,
          where: work_package.work_request_id in ^ids,
          select: work_package.id
        )
      )
    end)
  end

  defp delete_work_request_dependents(repo, work_request_ids, work_package_ids) do
    with :ok <- preserve_archived_work_package_hides(repo, work_package_ids),
         :ok <- delete_archived_comments(repo, work_request_ids, work_package_ids) do
      delete_archived_grant_scopes(repo, work_request_ids, work_package_ids)
    end
  end

  defp preserve_archived_work_package_hides(_repo, []), do: :ok

  defp preserve_archived_work_package_hides(repo, work_package_ids) do
    case OperatorSettingsRepository.get(repo) do
      {:ok, settings} ->
        hidden_work_package_ids = Enum.uniq(settings.hidden_work_package_ids ++ Enum.uniq(work_package_ids))

        case OperatorSettingsRepository.update(repo, %{"hidden_work_package_ids" => hidden_work_package_ids}) do
          {:ok, _settings} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_archived_comments(repo, work_request_ids, work_package_ids) do
    targets =
      Enum.map(work_request_ids, &{"work_request", &1}) ++
        Enum.map(work_package_ids, &{"work_package", &1})

    case CommentService.delete_for_targets(repo, targets) do
      {:ok, _deleted_count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_archived_grant_scopes(repo, work_request_ids, work_package_ids) do
    with {:ok, _work_request_count} <- delete_grant_scope_ids(repo, "work_request", work_request_ids),
         {:ok, _work_package_count} <- delete_grant_scope_ids(repo, "work_package", work_package_ids) do
      :ok
    end
  end

  defp delete_grant_scope_ids(_repo, _scope_type, []), do: {:ok, 0}

  defp delete_grant_scope_ids(repo, scope_type, scope_ids) do
    scope_ids
    |> Enum.uniq()
    |> Enum.chunk_every(@delete_work_request_chunk_size)
    |> Enum.reduce({:ok, 0}, fn
      _ids, {:error, reason} ->
        {:error, reason}

      ids, {:ok, deleted_count} ->
        {count, _rows} =
          repo.delete_all(
            from(scope in "sympp_access_grant_scopes",
              where: scope.scope_type == ^scope_type,
              where: scope.scope_id in ^ids
            )
          )

        {:ok, deleted_count + count}
    end)
  end

  defp completed_sort_key(%WorkRequest{} = work_request) do
    {timestamp_sort_value(work_request.completed_at), timestamp_sort_value(work_request.inserted_at), work_request.id || ""}
  end

  defp collect_or_error(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, item}, {:ok, items} -> {:cont, {:ok, [item | items]}}
      {:error, reason}, {:ok, _items} -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp archive_completed(repo, %WorkRequest{archived_at: %DateTime{}, id: id} = work_request, archive_reason) do
    with {:ok, _current} <- claim_archived_completed(repo, id) do
      maybe_schedule_work_request_linked_worktree_cleanup(repo, id, archive_reason)
      {:ok, work_request}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp archive_completed(repo, %WorkRequest{id: id}, archive_reason) when is_binary(id) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, archived, _archived_by_this_call?} <- archive_completed_update(repo, id, archive_reason, now) do
      maybe_schedule_work_request_linked_worktree_cleanup(repo, id, archive_reason)
      {:ok, archived}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp archive_completed_update(repo, id, archive_reason, now) do
    result =
      repo.update_all(
        from(work_request in WorkRequest,
          where: work_request.id == ^id,
          where: not is_nil(work_request.completed_at),
          where: is_nil(work_request.archived_at)
        ),
        set: [archived_at: now, archive_reason: archive_reason, updated_at: now]
      )

    archive_update_result(result, repo, id)
  end

  defp claim_archived_completed(repo, work_request_id) do
    now = DateTime.utc_now(:microsecond)

    {count, _rows} =
      repo.update_all(
        from(work_request in WorkRequest,
          where: work_request.id == ^work_request_id,
          where: not is_nil(work_request.completed_at),
          where: not is_nil(work_request.archived_at)
        ),
        set: [updated_at: now]
      )

    case count do
      1 -> Repository.get(repo, work_request_id)
      0 -> require_archived_completed(repo, work_request_id)
    end
  end

  defp claim_archived_before(repo, work_request_id, %DateTime{} = cutoff) do
    now = DateTime.utc_now(:microsecond)

    {count, _rows} =
      repo.update_all(
        from(work_request in WorkRequest,
          where: work_request.id == ^work_request_id,
          where: not is_nil(work_request.completed_at),
          where: not is_nil(work_request.archived_at),
          where: work_request.archived_at < ^cutoff
        ),
        set: [updated_at: now]
      )

    case count do
      1 -> Repository.get(repo, work_request_id)
      0 -> require_archived_before(repo, work_request_id, cutoff)
    end
  end

  defp require_archived_completed(repo, work_request_id) do
    case Repository.get(repo, work_request_id) do
      {:ok, %WorkRequest{completed_at: %DateTime{}, archived_at: %DateTime{}} = current} -> {:ok, current}
      {:ok, %WorkRequest{}} -> {:error, :not_completed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_archived_before(repo, work_request_id, %DateTime{} = cutoff) do
    with {:ok, %WorkRequest{archived_at: %DateTime{} = archived_at} = current} <-
           require_archived_completed(repo, work_request_id),
         true <- DateTime.compare(archived_at, cutoff) == :lt do
      {:ok, current}
    else
      false -> {:error, :not_completed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_schedule_work_request_linked_worktree_cleanup(repo, work_request_id, "manual") do
    schedule_work_request_linked_worktree_cleanup(repo, work_request_id)
  end

  defp maybe_schedule_work_request_linked_worktree_cleanup(_repo, _work_request_id, _archive_reason), do: :ok

  defp schedule_work_request_linked_worktree_cleanup(repo, work_request_id) do
    opts = cleanup_env_opts()

    schedule_worktree_cleanup(fn ->
      best_effort_cleanup_work_request_worktrees(repo, work_request_id, opts)
    end)
  end

  defp schedule_worktree_cleanup(cleanup) when is_function(cleanup, 0) do
    task = fn ->
      # ponytail: global cleanup lock; move to per-repo workers if archive throughput matters.
      :global.trans({__MODULE__, :archive_worktree_cleanup}, cleanup)
    end

    case Process.whereis(SymphonyElixir.TaskSupervisor) do
      nil -> Task.start(task)
      _pid -> Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, task)
    end

    :ok
  end

  defp best_effort_cleanup_work_request_worktrees(repo, work_request_id, opts) do
    work_package_ids = archived_work_package_ids(repo, [work_request_id])
    activity_contexts = WorkPackageActivity.contexts(repo, work_package_ids)

    work_package_ids
    |> Enum.uniq()
    |> Enum.each(fn work_package_id ->
      unless worktree_cleanup_deferred?(repo, work_package_id, Map.get(activity_contexts, work_package_id)) do
        WorkPackageService.cleanup_worktree(repo, work_package_id, opts)
      end
    end)
  end

  defp worktree_cleanup_deferred?(repo, work_package_id, context) do
    active_worker_cleanup_owner?(context) or durable_closeout_cleanup_deferral?(repo, work_package_id, context)
  end

  defp active_worker_cleanup_owner?(%{worker_signal: %{status: status}}) when status in ["active", "paused"], do: true
  defp active_worker_cleanup_owner?(_context), do: false

  defp cleanup_terminal_agent_run_worktree(repo, work_package_id, delivery, opts) do
    context = WorkPackageActivity.contexts(repo, [work_package_id]) |> Map.get(work_package_id)

    unless worktree_cleanup_deferred?(repo, work_package_id, context) do
      case WorkPackageService.cleanup_worktree(repo, work_package_id, opts) do
        {:ok, _cleanup} -> :ok
        {:error, reason} -> audit_deferred_worktree_cleanup_failure(repo, work_package_id, delivery, reason)
      end
    end
  end

  defp audit_deferred_worktree_cleanup_failure(repo, work_package_id, delivery, reason) do
    PlanningRepository.append_progress_event(repo, %{
      work_package_id: work_package_id,
      status: "worktree_cleanup_failed",
      summary: "Worktree cleanup failed: #{inspect(closeout_worktree_cleanup_error(reason))}",
      idempotency_key: "#{closeout_idempotency_key(delivery)}:worktree_cleanup",
      payload: %{
        type: "work_request_delivery_worktree_cleanup",
        source_tool: "record_work_package_delivery",
        delivery_id: delivery.id,
        outcome: delivery.outcome,
        reason: inspect(closeout_worktree_cleanup_error(reason))
      }
    })

    :ok
  end

  defp canonical_delivery_closeout(repo, work_package_id) do
    delivery =
      repo.one(
        from(delivery in WorkPackageDelivery,
          where: delivery.work_package_id == ^work_package_id,
          limit: 1
        )
      )

    case delivery do
      %WorkPackageDelivery{} = delivery -> canonical_delivery_closeout_event(repo, delivery)
      nil -> {:error, :not_found}
    end
  end

  defp canonical_delivery_closeout_event(repo, delivery) do
    case PlanningRepository.get_progress_event_by_idempotency_key(
           repo,
           delivery.work_package_id,
           closeout_idempotency_key(delivery)
         ) do
      {:ok, event} ->
        if canonical_delivery_closeout_event?(event, delivery), do: {:ok, {delivery, event}}, else: {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp canonical_delivery_closeout_event?(event, delivery) do
    payload = Map.get(event, :payload) || %{}

    event.idempotency_key == closeout_idempotency_key(delivery) and
      map_value(payload, :type) == "work_request_delivery_closeout" and
      map_value(payload, :source_tool) == "record_work_package_delivery" and
      map_value(payload, :work_request_id) == delivery.work_request_id and
      map_value(payload, :work_package_id) == delivery.work_package_id and
      map_value(payload, :delivery_id) == delivery.id and
      map_value(payload, :outcome) == delivery.outcome
  end

  defp durable_closeout_cleanup_deferral?(repo, work_package_id, context) do
    case canonical_delivery_closeout(repo, work_package_id) do
      {:ok, {_delivery, _event}} ->
        current_reasons = List.wrap(get_in(context, [:runtime_state, :reason_codes]))

        "agent_run_active" in current_reasons or
          Enum.any?(current_reasons, &(&1 in @durable_cleanup_deferral_reasons))

      {:error, :not_found} ->
        false

      {:error, _reason} ->
        true
    end
  end

  defp cleanup_env_opts do
    case System.get_env("CODEX_HOME") do
      nil -> []
      codex_home -> [codex_home: codex_home]
    end
  end

  defp cleanup_work_package_worktrees(repo, work_package_ids, opts) do
    work_package_ids
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn work_package_id, :ok ->
      case WorkPackageService.cleanup_worktree(repo, work_package_id, opts) do
        {:ok, _cleanup} -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, closeout_worktree_cleanup_error(reason)}}
      end
    end)
  end

  defp closeout_worktree_cleanup_error(:database_busy), do: :database_busy
  defp closeout_worktree_cleanup_error({:constraint_failed, _constraint} = reason), do: reason
  defp closeout_worktree_cleanup_error({:storage_failed, _message} = reason), do: reason
  defp closeout_worktree_cleanup_error(%Ecto.Changeset{} = reason), do: reason
  defp closeout_worktree_cleanup_error(reason), do: reason

  defp closeout_idempotency_key(delivery) do
    Enum.join(
      [
        "work_request_delivery_closeout",
        delivery.work_request_id,
        delivery.work_package_id,
        delivery.idempotency_key
      ],
      ":"
    )
  end

  defp maybe_skip_archived_cleanup_error(reason, deleted_ids) do
    if hard_archived_cleanup_error?(reason) do
      {:halt, {:error, reason}}
    else
      {:cont, {:ok, deleted_ids}}
    end
  end

  defp hard_archived_cleanup_error?(:database_busy), do: true
  defp hard_archived_cleanup_error?({:constraint_failed, _constraint}), do: true
  defp hard_archived_cleanup_error?({:storage_failed, _message}), do: true
  defp hard_archived_cleanup_error?(%Ecto.Changeset{}), do: true
  defp hard_archived_cleanup_error?(_reason), do: false

  defp archive_update_result({1, _rows}, repo, id) do
    with {:ok, %WorkRequest{} = current} <- Repository.get(repo, id) do
      {:ok, current, true}
    end
  end

  defp archive_update_result({0, _rows}, repo, id) do
    with {:ok, %WorkRequest{} = current} <- Repository.get(repo, id) do
      if current.archived_at do
        {:ok, current, false}
      else
        {:error, :not_completed}
      end
    end
  end

  defp archive_update_result({_count, _rows}, _repo, _id), do: {:error, {:constraint_failed, "multiple_work_request_archives"}}

  defp restore_completed(repo, %WorkRequest{} = work_request), do: restore_completed(repo, work_request, reset_completed_at?: true)

  defp restore_completed(_repo, %WorkRequest{archived_at: nil, archive_reason: nil} = work_request, _opts), do: {:ok, work_request}

  defp restore_completed(repo, %WorkRequest{} = work_request, opts) do
    reset_completed_at? = Keyword.get(opts, :reset_completed_at?, true)
    attrs = %{archived_at: nil, archive_reason: nil}
    attrs = if reset_completed_at?, do: Map.put(attrs, :completed_at, DateTime.utc_now(:microsecond)), else: attrs

    work_request
    |> Ecto.Changeset.change(attrs)
    |> update_work_request(repo)
  end

  defp update_work_request(changeset, repo) do
    repo.update(changeset)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp question_state(repo, work_request_id) do
    questions =
      repo.all(
        from(question in ClarificationQuestion,
          where: question.work_request_id == ^work_request_id,
          select: %{status: question.status, updated_at: question.updated_at}
        )
      )

    {:ok,
     %{
       open_count: Enum.count(questions, &(&1.status == "open")),
       latest_gate_at: latest_timestamp(Enum.map(questions, & &1.updated_at))
     }}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp work_package_contexts(_repo, []), do: {:ok, %{}}

  defp work_package_contexts(repo, work_packages) do
    work_package_ids =
      work_packages
      |> Enum.map(& &1.id)
      |> Enum.filter(&filled_string?/1)
      |> Enum.uniq()

    activity_contexts = WorkPackageActivity.contexts(repo, work_package_ids)

    contexts =
      Map.new(work_packages, fn %WorkPackage{} = work_package ->
        {work_package.id,
         activity_contexts
         |> Map.get(work_package.id, WorkPackageActivity.empty_context())
         |> Map.put(:work_package, work_package)}
      end)

    {:ok, contexts}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp work_package_deliveries_by_id(_repo, []), do: {:ok, %{}}

  defp work_package_deliveries_by_id(repo, work_packages) do
    work_package_ids = Enum.map(work_packages, & &1.id)

    deliveries =
      repo.all(
        from(delivery in WorkPackageDelivery,
          where: delivery.work_package_id in ^work_package_ids
        )
      )

    {:ok, Map.new(deliveries, &{&1.work_package_id, &1})}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp terminal_slice?(work_package, context, delivery)

  defp terminal_slice?(%WorkPackage{status: status}, context, delivery) when status in @terminal_work_package_statuses do
    not active_blocker_context?(context) and
      (terminal_delivery?(delivery) or not active_runtime_context?(context))
  end

  defp terminal_slice?(%WorkPackage{}, _context, %WorkPackageDelivery{outcome: outcome})
       when outcome in @terminal_delivery_outcomes,
       do: true

  defp terminal_slice?(%WorkPackage{}, _context, delivery) when is_map(delivery),
    do: terminal_delivery?(delivery)

  defp terminal_slice?(%WorkPackage{}, _context, _delivery), do: false

  defp terminal_delivery?(%WorkPackageDelivery{outcome: outcome}), do: outcome in @terminal_delivery_outcomes

  defp terminal_delivery?(delivery) when is_map(delivery) do
    map_value(delivery, :outcome) in @terminal_delivery_outcomes
  end

  defp terminal_delivery?(_delivery), do: false

  defp active_blocker_context?(%{active_blocker?: true}), do: true
  defp active_blocker_context?(%{blocker_state: %{active?: true}}), do: true

  defp active_blocker_context?(%{card: %{operational_state: operational_state}}) when is_map(operational_state) do
    map_value(operational_state, :key) == "blocked" or
      operational_state
      |> map_value(:attention_items)
      |> List.wrap()
      |> Enum.any?(&(is_map(&1) and map_value(&1, :key) == "active_blocker"))
  end

  defp active_blocker_context?(_context), do: false

  defp active_runtime_context?(%{active_runtime?: true}), do: true
  defp active_runtime_context?(%{runtime_state: %{active?: true}}), do: true

  defp active_runtime_context?(%{card: %{operational_state: operational_state}}) when is_map(operational_state) do
    map_value(operational_state, :has_active_worker) == true
  end

  defp active_runtime_context?(_context), do: false

  defp map_value(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp derived_completed_at(%WorkRequest{} = work_request, work_packages, work_package_contexts, deliveries_by_slice_id, question_gate_at) do
    work_package_timestamps =
      work_package_contexts
      |> Map.values()
      |> Enum.map(fn
        %{work_package: %WorkPackage{} = work_package} -> work_package.updated_at
        _context -> nil
      end)

    gate_timestamps =
      work_package_contexts
      |> Map.values()
      |> Enum.flat_map(fn context ->
        [
          get_in(context, [:blocker_state, :latest_gate_at]),
          get_in(context, [:runtime_state, :latest_gate_at])
        ]
      end)

    delivery_timestamps =
      deliveries_by_slice_id
      |> Map.values()
      |> Enum.flat_map(&delivery_timestamps/1)

    latest_timestamp([work_request.updated_at, question_gate_at] ++ Enum.map(work_packages, & &1.updated_at) ++ work_package_timestamps ++ gate_timestamps ++ delivery_timestamps) ||
      DateTime.utc_now(:microsecond)
  end

  defp delivery_timestamps(%WorkPackageDelivery{} = delivery), do: [delivery.recorded_at, delivery.updated_at]

  defp delivery_timestamps(delivery) when is_map(delivery) do
    [map_value(delivery, :recorded_at), map_value(delivery, :updated_at)]
  end

  defp delivery_timestamps(_delivery), do: []

  defp latest_timestamp(timestamps) do
    timestamps
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp timestamp_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp timestamp_sort_value(_timestamp), do: -1

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)

    if String.contains?(String.downcase(message), "busy") or String.contains?(String.downcase(message), "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end
end
