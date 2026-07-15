defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository do
  @moduledoc false

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.CompletionRecovery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDeliveryScope
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.RepoScope
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @completion_blocking_statuses ["human_info_needed"]
  @planned_slice_delivery_replay_fields [
    :work_request_id,
    :planned_slice_id,
    :outcome,
    :idempotency_key,
    :recorded_by,
    :pr_url,
    :pr_number,
    :pr_repository,
    :pr_merged_at,
    :merge_commit_sha,
    :no_pr_evidence,
    :successor_planned_slice_id,
    :successor_work_package_id,
    :superseded_reason,
    :abandoned_rationale
  ]

  import Ecto.Query, only: [from: 2]

  @default_sequence_retry_attempts 200
  @question_create_ignored_attrs [
    "answer",
    "answered_at",
    "answered_by",
    "created_at",
    "inserted_at",
    "sequence",
    "status",
    "updated_at"
  ]
  @planned_slice_create_ignored_attrs [
    "created_at",
    "dispatched_at",
    "inserted_at",
    "sequence",
    "updated_at",
    "work_package_id"
  ]

  @type repo :: module()
  @type error ::
          :already_answered
          | :already_closed
          | :database_busy
          | :delivery_outcome_conflict
          | :last_approved_slice
          | :no_approved_slices
          | :open_questions
          | :not_found
          | :invalid_work_package_id
          | :work_package_already_linked
          | :work_package_mismatch
          | :work_package_not_found
          | :id_already_exists
          | :invalid_status
          | :planned_slice_delivery_scope_out_of_scope
          | :sequence_conflict
          | :stale_status
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

  @spec create(repo(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def create(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs = normalize_keys(attrs)

    repo.transaction(fn ->
      with {:ok, work_request} <-
             attrs
             |> WorkRequest.create_changeset()
             |> repo.insert()
             |> normalize_insert_result(),
           :ok <- replace_repo_scopes(repo, work_request, repo_scope_attrs(attrs, work_request)) do
        work_request
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec get(repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(WorkRequest, id) do
      nil -> {:error, :not_found}
      work_request -> {:ok, work_request}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list(repo()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  @spec list(repo(), map() | keyword()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  def list(repo, filters \\ %{}) when is_atom(repo) and (is_map(filters) or is_list(filters)) do
    work_requests =
      repo.all(
        filters
        |> normalize_keys()
        |> list_query()
      )

    {:ok, work_requests}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_page(repo(), map() | keyword(), pos_integer(), nil | {DateTime.t(), String.t()}) ::
          {:ok, [WorkRequest.t()]} | {:error, error()}
  def list_page(repo, filters, limit, cursor)
      when is_atom(repo) and (is_map(filters) or is_list(filters)) and is_integer(limit) and limit > 0 do
    work_requests =
      filters
      |> normalize_keys()
      |> list_query()
      |> page_after(cursor)
      |> then(&repo.all(from(work_request in &1, limit: ^limit)))

    {:ok, work_requests}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_repo_scopes(repo(), String.t()) :: {:ok, [RepoScope.t()]} | {:error, error()}
  def list_repo_scopes(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    repo_scopes =
      repo.all(
        from(scope in RepoScope,
          where: scope.work_request_id == ^work_request_id,
          order_by: [asc: scope.scope_key, asc: scope.id]
        )
      )

    {:ok, repo_scopes}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_repo_scopes_by_work_request(repo(), [String.t()]) ::
          {:ok, %{optional(String.t()) => [RepoScope.t()]}} | {:error, error()}
  def list_repo_scopes_by_work_request(_repo, []), do: {:ok, %{}}

  def list_repo_scopes_by_work_request(repo, work_request_ids) when is_atom(repo) and is_list(work_request_ids) do
    repo_scopes =
      repo.all(
        from(scope in RepoScope,
          where: scope.work_request_id in ^work_request_ids,
          order_by: [asc: scope.work_request_id, asc: scope.scope_key, asc: scope.id]
        )
      )

    {:ok, Enum.group_by(repo_scopes, & &1.work_request_id)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec clear_completion_for_work_package(repo(), String.t()) :: :ok | {:error, error()}
  def clear_completion_for_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    now = DateTime.utc_now(:microsecond)

    repo.update_all(
      CompletionRecovery.clearable_query(work_package_id),
      set: [completed_at: nil, completion_source: nil, archived_at: nil, archive_reason: nil, updated_at: now]
    )

    :ok
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec update(repo(), String.t(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def update(repo, id, attrs) when is_atom(repo) and is_binary(id) and is_map(attrs) do
    attrs = normalize_keys(attrs)

    case get(repo, id) do
      {:ok, work_request} -> update_existing_work_request(repo, work_request, attrs)
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec update_status(repo(), String.t(), String.t(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def update_status(repo, id, current_status, next_status)
      when is_atom(repo) and is_binary(id) and is_binary(current_status) and is_binary(next_status) do
    with :ok <- validate_status(current_status),
         :ok <- validate_status(next_status) do
      update_valid_status(repo, id, current_status, next_status)
    end
  end

  @spec prepare_for_planned_slices(repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def prepare_for_planned_slices(repo, id) when is_atom(repo) and is_binary(id) do
    case get(repo, id) do
      {:ok, %WorkRequest{status: status} = work_request} when status in ["ready_for_slicing", "sliced"] ->
        case ensure_no_open_questions(repo, work_request.id) do
          :ok -> {:ok, work_request}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %WorkRequest{status: status} = work_request} when status in ["ready_for_clarification", "clarifying", "human_info_needed"] ->
        advance_ready_for_slicing(repo, work_request)

      {:ok, %WorkRequest{}} ->
        {:error, :invalid_status}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec ask_question(repo(), String.t(), map()) :: {:ok, ClarificationQuestion.t()} | {:error, error()}
  def ask_question(repo, work_request_id, attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_map(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.drop(@question_create_ignored_attrs)
      |> Map.put("work_request_id", work_request_id)
      |> Map.put("status", "open")

    changeset_fun = &ClarificationQuestion.create_changeset/1
    insert_with_sequence(repo, attrs, &next_question_sequence/2, changeset_fun, clear_completion?: true)
  end

  @spec list_questions(repo(), String.t()) :: {:ok, [ClarificationQuestion.t()]} | {:error, error()}
  def list_questions(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    questions =
      repo.all(
        from(question in ClarificationQuestion,
          where: question.work_request_id == ^work_request_id,
          order_by: [asc: question.sequence, asc: question.id]
        )
      )

    {:ok, questions}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec answer_question(repo(), String.t(), String.t(), map()) :: {:ok, ClarificationQuestion.t()} | {:error, error()}
  def answer_question(repo, id, current_status, attrs)
      when is_atom(repo) and is_binary(id) and is_binary(current_status) and is_map(attrs) do
    with :ok <- validate_question_status(current_status),
         {:ok, answer} <- normalize_answer(attrs) do
      answer_valid_question(repo, id, current_status, answer)
    end
  end

  @spec close_question(repo(), String.t(), String.t()) :: {:ok, ClarificationQuestion.t()} | {:error, error()}
  def close_question(repo, id, current_status)
      when is_atom(repo) and is_binary(id) and is_binary(current_status) do
    with :ok <- validate_question_status(current_status) do
      close_valid_question(repo, id, current_status)
    end
  end

  @spec record_decision(repo(), String.t(), map()) :: {:ok, DecisionLogEntry.t()} | {:error, error()}
  def record_decision(repo, work_request_id, attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_map(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.drop(["sequence", "inserted_at", "updated_at"])
      |> Map.put("work_request_id", work_request_id)

    insert_with_sequence(repo, attrs, &next_decision_sequence/2, &DecisionLogEntry.create_changeset/1)
  end

  @spec add_planned_slice(repo(), String.t(), map()) :: {:ok, PlannedSlice.t()} | {:error, error()}
  def add_planned_slice(repo, work_request_id, attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_map(attrs) do
    add_planned_slice(repo, work_request_id, attrs, [])
  end

  @spec add_planned_slice_for_authoring(repo(), String.t(), map()) :: {:ok, PlannedSlice.t()} | {:error, error()}
  def add_planned_slice_for_authoring(repo, work_request_id, attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_map(attrs) do
    add_planned_slice(repo, work_request_id, attrs, prepare_for_planned_slices?: true)
  end

  defp add_planned_slice(repo, work_request_id, attrs, opts) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.drop(@planned_slice_create_ignored_attrs)
      |> Map.put("work_request_id", work_request_id)

    changeset_fun = &PlannedSlice.create_changeset/1

    with {:ok, attrs} <- PlannedSliceDeliveryScope.normalize_explicit(repo, work_request_id, attrs) do
      insert_with_sequence(repo, attrs, &next_planned_slice_sequence/2, changeset_fun, Keyword.put(opts, :clear_completion?, true))
    end
  end

  @spec list_planned_slices(repo(), String.t()) :: {:ok, [PlannedSlice.t()]} | {:error, error()}
  def list_planned_slices(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    planned_slices =
      repo.all(
        from(planned_slice in PlannedSlice,
          where: planned_slice.work_request_id == ^work_request_id,
          order_by: [asc: planned_slice.sequence, asc: planned_slice.id]
        )
      )

    {:ok, planned_slices}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec get_planned_slice(repo(), String.t(), String.t()) :: {:ok, PlannedSlice.t()} | {:error, error()}
  def get_planned_slice(repo, work_request_id, id)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(id) do
    case repo.get(PlannedSlice, id) do
      nil -> {:error, :not_found}
      %PlannedSlice{work_request_id: ^work_request_id} = planned_slice -> {:ok, planned_slice}
      %PlannedSlice{} -> {:error, :not_found}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec record_planned_slice_delivery(repo(), String.t(), String.t(), map()) ::
          {:ok, PlannedSliceDelivery.t()} | {:error, error()}
  def record_planned_slice_delivery(repo, work_request_id, planned_slice_id, attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(planned_slice_id) and is_map(attrs) do
    repo.transaction(fn ->
      case record_planned_slice_delivery_in_transaction(repo, work_request_id, planned_slice_id, attrs) do
        {:ok, delivery} -> delivery
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @doc false
  @spec record_planned_slice_delivery_in_transaction(repo(), String.t(), String.t(), map()) ::
          {:ok, PlannedSliceDelivery.t()} | {:error, error()}
  def record_planned_slice_delivery_in_transaction(repo, work_request_id, planned_slice_id, attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(planned_slice_id) and is_map(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.drop(["id", "inserted_at", "recorded_at", "updated_at"])
      |> Map.put("work_request_id", work_request_id)
      |> Map.put("planned_slice_id", planned_slice_id)

    changeset = PlannedSliceDelivery.create_changeset(attrs)

    with {:ok, candidate} <- Changeset.apply_action(changeset, :insert),
         :ok <- validate_planned_slice_delivery_scope(repo, work_request_id, planned_slice_id, candidate) do
      {:ok, insert_or_replay_scoped_planned_slice_delivery(repo, planned_slice_id, changeset, candidate)}
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec approve_planned_slice(repo(), String.t(), String.t(), String.t()) ::
          {:ok, PlannedSlice.t()} | {:error, error()}
  def approve_planned_slice(repo, work_request_id, id, current_status)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(id) and is_binary(current_status) do
    update_planned_slice_status(repo, work_request_id, id, current_status, "approved", ["planned"])
  end

  @spec skip_planned_slice(repo(), String.t(), String.t(), String.t()) :: {:ok, PlannedSlice.t()} | {:error, error()}
  def skip_planned_slice(repo, work_request_id, id, current_status)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(id) and is_binary(current_status) do
    update_planned_slice_status(repo, work_request_id, id, current_status, "skipped", ["planned", "approved"])
  end

  @spec dispatch_planned_slice(repo(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, PlannedSlice.t()} | {:error, error()}
  def dispatch_planned_slice(repo, work_request_id, id, current_status, work_package_id)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(id) and is_binary(current_status) do
    with :ok <- validate_planned_slice_status(current_status),
         :ok <- require_status(current_status, ["approved"]),
         {:ok, work_package_id} <- normalize_dispatch_work_package_id(work_package_id) do
      dispatch_valid_planned_slice(repo, work_request_id, id, current_status, work_package_id)
    end
  end

  @spec mark_sliced(repo(), String.t(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def mark_sliced(repo, id, current_status)
      when is_atom(repo) and is_binary(id) and is_binary(current_status) do
    with :ok <- validate_status(current_status),
         :ok <- require_status(current_status, ["ready_for_slicing"]) do
      mark_valid_sliced(repo, id, current_status)
    end
  end

  @spec list_decisions(repo(), String.t()) :: {:ok, [DecisionLogEntry.t()]} | {:error, error()}
  def list_decisions(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    decisions =
      repo.all(
        from(decision in DecisionLogEntry,
          where: decision.work_request_id == ^work_request_id,
          order_by: [asc: decision.sequence, asc: decision.id]
        )
      )

    {:ok, decisions}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp list_query(filters) do
    filters = normalize_keys(filters)

    base_query =
      from(work_request in WorkRequest,
        order_by: [asc: work_request.inserted_at, asc: work_request.id]
      )

    base_query =
      if include_archived?(filters) do
        base_query
      else
        from(work_request in base_query, where: is_nil(work_request.archived_at))
      end

    Enum.reduce(filters, base_query, fn
      {"include_archived", _include_archived}, query ->
        query

      {:include_archived, _include_archived}, query ->
        query

      {"status", status}, query when is_binary(status) and status != "" ->
        from(work_request in query, where: work_request.status == ^status)

      {"repo", repo}, query when is_binary(repo) and repo != "" ->
        from(work_request in query, where: work_request.repo == ^repo)

      {"base_branch", base_branch}, query when is_binary(base_branch) and base_branch != "" ->
        from(work_request in query, where: work_request.base_branch == ^base_branch)

      _filter, query ->
        query
    end)
  end

  defp page_after(query, nil), do: query

  defp page_after(query, {%DateTime{} = inserted_at, id}) when is_binary(id) do
    from(work_request in query,
      where:
        work_request.inserted_at > ^inserted_at or
          (work_request.inserted_at == ^inserted_at and work_request.id > ^id)
    )
  end

  defp include_archived?(filters) do
    (Map.get(filters, "include_archived") || Map.get(filters, :include_archived)) in [true, "true", "1"]
  end

  defp update_valid_status(repo, id, current_status, next_status) do
    now = DateTime.utc_now(:microsecond)

    repo.transaction(fn ->
      id
      |> status_update_query(current_status)
      |> repo.update_all(set: status_update_values(next_status, now))
      |> case do
        {1, _rows} -> repo.get!(WorkRequest, id)
        {0, _rows} -> repo.rollback(stale_status_error(repo, id))
      end
    end)
    |> case do
      {:ok, work_request} -> {:ok, work_request}
      {:error, error} -> error
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp advance_ready_for_slicing(repo, %WorkRequest{} = work_request) do
    repo.transaction(fn ->
      case advance_ready_for_slicing_in_transaction(repo, work_request) do
        :ok -> repo.get!(WorkRequest, work_request.id)
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp prepare_for_planned_slices_in_transaction(repo, work_request_id) do
    case get(repo, work_request_id) do
      {:ok, %WorkRequest{status: status} = work_request} when status in ["ready_for_slicing", "sliced"] ->
        ensure_no_open_questions(repo, work_request.id)

      {:ok, %WorkRequest{status: status} = work_request} when status in ["ready_for_clarification", "clarifying", "human_info_needed"] ->
        advance_ready_for_slicing_in_transaction(repo, work_request)

      {:ok, %WorkRequest{}} ->
        {:error, :invalid_status}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp advance_ready_for_slicing_in_transaction(repo, %WorkRequest{} = work_request) do
    now = DateTime.utc_now(:microsecond)

    work_request.id
    |> ready_for_slicing_update_query(work_request.status)
    |> repo.update_all(set: [status: "ready_for_slicing", updated_at: now])
    |> case do
      {1, _rows} -> :ok
      {0, _rows} -> ready_for_slicing_result(repo, work_request)
    end
  end

  defp ready_for_slicing_update_query(work_request_id, current_status) do
    from(work_request in WorkRequest,
      where: work_request.id == ^work_request_id and work_request.status == ^current_status,
      where:
        fragment(
          """
          NOT EXISTS (
            SELECT 1
            FROM sympp_work_request_clarification_questions AS question
            WHERE question.work_request_id = ? AND question.status = 'open'
          )
          """,
          work_request.id
        )
    )
  end

  defp ready_for_slicing_result(repo, work_request) do
    cond do
      open_questions?(repo, work_request.id) -> {:error, :open_questions}
      work_request_ready_for_slicing?(repo, work_request.id) -> :ok
      stale_work_request_status?(repo, work_request) -> {:error, :stale_status}
      true -> {:error, :not_found}
    end
  end

  defp ensure_no_open_questions(repo, work_request_id) do
    if open_questions?(repo, work_request_id) do
      {:error, :open_questions}
    else
      :ok
    end
  end

  defp status_update_values(next_status, now) when next_status in @completion_blocking_statuses do
    [
      status: next_status,
      completed_at: nil,
      completion_source: nil,
      archived_at: nil,
      archive_reason: nil,
      updated_at: now
    ]
  end

  defp status_update_values(next_status, now), do: [status: next_status, updated_at: now]

  defp validate_status(status) do
    if status in WorkRequest.statuses() do
      :ok
    else
      {:error, :invalid_status}
    end
  end

  defp validate_question_status(status) do
    if status in ClarificationQuestion.statuses() do
      :ok
    else
      {:error, :invalid_status}
    end
  end

  defp validate_planned_slice_status(status) do
    if status in PlannedSlice.statuses() do
      :ok
    else
      {:error, :invalid_status}
    end
  end

  defp require_status(status, allowed_statuses) do
    if status in allowed_statuses do
      :ok
    else
      {:error, :invalid_status}
    end
  end

  defp stale_status_error(repo, id) do
    case get(repo, id) do
      {:ok, _work_request} -> {:error, :stale_status}
      {:error, :not_found} = error -> error
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_questions?(repo, work_request_id) do
    repo.exists?(
      from(question in ClarificationQuestion,
        where: question.work_request_id == ^work_request_id and question.status == "open"
      )
    )
  end

  defp work_request_ready_for_slicing?(repo, work_request_id) do
    case repo.get(WorkRequest, work_request_id) do
      %WorkRequest{status: status} when status in ["ready_for_slicing", "sliced"] -> true
      _work_request -> false
    end
  end

  defp stale_work_request_status?(repo, work_request) do
    case repo.get(WorkRequest, work_request.id) do
      %WorkRequest{status: status} -> status != work_request.status
      nil -> false
    end
  end

  defp status_update_query(id, current_status) do
    from(work_request in WorkRequest,
      where: work_request.id == ^id and work_request.status == ^current_status
    )
  end

  defp insert_with_sequence(repo, attrs, next_sequence, changeset_fun, opts \\ []) do
    do_insert_with_sequence(repo, attrs, next_sequence, changeset_fun, opts, sequence_retry_attempts())
  end

  defp do_insert_with_sequence(repo, attrs, next_sequence, changeset_fun, opts, attempts_left) do
    repo
    |> insert_sequence_transaction(attrs, next_sequence, changeset_fun, opts)
    |> handle_sequence_insert_result(repo, attrs, next_sequence, changeset_fun, opts, attempts_left)
  end

  defp insert_sequence_transaction(repo, attrs, next_sequence, changeset_fun, opts) do
    repo.transaction(fn ->
      case maybe_prepare_for_planned_slices(repo, attrs, opts) do
        :ok ->
          attrs = Map.put(attrs, "sequence", next_sequence.(repo, Map.fetch!(attrs, "work_request_id")))

          attrs
          |> changeset_fun.()
          |> repo.insert()
          |> normalize_insert_result()
          |> return_inserted_record_or_rollback(repo, attrs, opts)

        {:error, reason} ->
          repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp return_inserted_record_or_rollback({:ok, record}, repo, attrs, opts) do
    case maybe_clear_completion_state(repo, attrs, opts) do
      :ok -> record
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp return_inserted_record_or_rollback({:error, reason}, repo, _attrs, _opts), do: repo.rollback(reason)

  defp handle_sequence_insert_result({:ok, record}, _repo, _attrs, _next_sequence, _changeset_fun, _opts, _attempts_left) do
    {:ok, record}
  end

  defp handle_sequence_insert_result(
         {:error, {:constraint_failed, constraint}},
         repo,
         attrs,
         next_sequence,
         changeset_fun,
         opts,
         attempts_left
       ) do
    if sequence_constraint?(constraint) do
      retry_or_error(repo, attrs, next_sequence, changeset_fun, opts, attempts_left, :sequence_conflict)
    else
      {:error, {:constraint_failed, constraint}}
    end
  end

  defp handle_sequence_insert_result({:error, :database_busy}, repo, attrs, next_sequence, changeset_fun, opts, attempts_left) do
    retry_or_error(repo, attrs, next_sequence, changeset_fun, opts, attempts_left, :database_busy)
  end

  defp handle_sequence_insert_result({:error, reason}, _repo, _attrs, _next_sequence, _changeset_fun, _opts, _attempts_left) do
    {:error, reason}
  end

  defp retry_or_error(_repo, _attrs, _next_sequence, _changeset_fun, _opts, 0, terminal_error), do: {:error, terminal_error}

  defp retry_or_error(repo, attrs, next_sequence, changeset_fun, opts, attempts_left, _terminal_error) do
    Process.sleep(retry_delay_ms(attempts_left, sequence_retry_attempts()))
    do_insert_with_sequence(repo, attrs, next_sequence, changeset_fun, opts, attempts_left - 1)
  end

  defp maybe_clear_completion_state(repo, %{"work_request_id" => work_request_id}, clear_completion?: true) do
    now = DateTime.utc_now(:microsecond)

    repo.update_all(
      from(work_request in WorkRequest,
        where: work_request.id == ^work_request_id,
        where: not is_nil(work_request.completed_at) or not is_nil(work_request.archived_at)
      ),
      set: [completed_at: nil, completion_source: nil, archived_at: nil, archive_reason: nil, updated_at: now]
    )

    :ok
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp maybe_clear_completion_state(_repo, _attrs, _opts), do: :ok

  defp maybe_prepare_for_planned_slices(repo, %{"work_request_id" => work_request_id}, opts) do
    if Keyword.get(opts, :prepare_for_planned_slices?, false) do
      prepare_for_planned_slices_in_transaction(repo, work_request_id)
    else
      :ok
    end
  end

  defp maybe_prepare_for_planned_slices(_repo, _attrs, _opts), do: :ok

  defp retry_delay_ms(attempts_left, total_attempts) do
    used_attempts = max(total_attempts - attempts_left, 0)
    min(100, 5 + used_attempts * 5)
  end

  defp sequence_retry_attempts do
    :symphony_elixir
    |> Application.get_env(:sympp_work_request_sequence_retry_attempts, @default_sequence_retry_attempts)
    |> max(0)
  end

  defp next_question_sequence(repo, work_request_id) do
    next_sequence(repo, ClarificationQuestion, work_request_id)
  end

  defp next_decision_sequence(repo, work_request_id) do
    next_sequence(repo, DecisionLogEntry, work_request_id)
  end

  defp next_planned_slice_sequence(repo, work_request_id) do
    next_sequence(repo, PlannedSlice, work_request_id)
  end

  defp next_sequence(repo, schema, work_request_id) do
    max_sequence =
      repo.one(
        from(record in schema,
          where: record.work_request_id == ^work_request_id,
          select: max(record.sequence)
        )
      )

    (max_sequence || 0) + 1
  end

  defp normalize_answer(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> put_new_value("answered_at", DateTime.utc_now(:microsecond))

    attrs
    |> ClarificationQuestion.answer_changeset()
    |> Changeset.apply_action(:update)
  end

  defp answer_valid_question(repo, id, current_status, answer) do
    now = DateTime.utc_now(:microsecond)

    repo.transaction(fn ->
      id
      |> answer_question_query(current_status)
      |> repo.update_all(
        set: [
          status: "answered",
          answer: answer.answer,
          answered_by: answer.answered_by,
          answered_at: answer.answered_at,
          updated_at: now
        ]
      )
      |> case do
        {1, _rows} -> repo.get!(ClarificationQuestion, id)
        {0, _rows} -> repo.rollback(question_terminal_error(repo, id, current_status))
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp close_valid_question(repo, id, current_status) do
    now = DateTime.utc_now(:microsecond)

    repo.transaction(fn ->
      id
      |> close_question_query(current_status)
      |> repo.update_all(set: [status: "closed", updated_at: now])
      |> case do
        {1, _rows} -> repo.get!(ClarificationQuestion, id)
        {0, _rows} -> repo.rollback(question_terminal_error(repo, id, current_status))
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp answer_question_query(id, current_status) do
    from(question in ClarificationQuestion,
      where:
        question.id == ^id and question.status == ^current_status and question.status == "open" and
          is_nil(question.answer)
    )
  end

  defp close_question_query(id, current_status) do
    from(question in ClarificationQuestion,
      where:
        question.id == ^id and question.status == ^current_status and question.status == "open" and
          is_nil(question.answer)
    )
  end

  defp question_terminal_error(repo, id, current_status) do
    case repo.get(ClarificationQuestion, id) do
      nil -> :not_found
      %ClarificationQuestion{status: "closed"} -> :already_closed
      %ClarificationQuestion{status: "answered"} -> :already_answered
      %ClarificationQuestion{answer: answer} when not is_nil(answer) -> :already_answered
      %ClarificationQuestion{status: status} when status != current_status -> :stale_status
      %ClarificationQuestion{} -> :stale_status
    end
  end

  defp validate_planned_slice_delivery_scope(
         repo,
         work_request_id,
         planned_slice_id,
         %PlannedSliceDelivery{outcome: "superseded"} = candidate
       ) do
    with true <- planned_slice_in_scope?(repo, work_request_id, planned_slice_id),
         %PlannedSlice{work_request_id: ^work_request_id} = successor_slice <-
           repo.get(PlannedSlice, candidate.successor_planned_slice_id) do
      if candidate.successor_work_package_id in [nil, successor_slice.work_package_id] do
        :ok
      else
        {:error, :not_found}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp validate_planned_slice_delivery_scope(repo, work_request_id, planned_slice_id, %PlannedSliceDelivery{}) do
    if planned_slice_in_scope?(repo, work_request_id, planned_slice_id), do: :ok, else: {:error, :not_found}
  end

  defp insert_or_replay_scoped_planned_slice_delivery(repo, planned_slice_id, changeset, candidate) do
    case existing_planned_slice_delivery(repo, planned_slice_id) do
      %PlannedSliceDelivery{} = existing -> replay_planned_slice_delivery(repo, existing, candidate)
      nil -> insert_planned_slice_delivery(repo, planned_slice_id, changeset, candidate)
    end
  end

  defp insert_planned_slice_delivery(repo, planned_slice_id, changeset, candidate) do
    case repo.insert(changeset) do
      {:ok, delivery} ->
        delivery

      {:error, %Changeset{} = changeset} ->
        replay_unique_planned_slice_delivery(repo, planned_slice_id, candidate, changeset)

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp planned_slice_in_scope?(repo, work_request_id, planned_slice_id) do
    repo.exists?(
      from(planned_slice in PlannedSlice,
        where: planned_slice.id == ^planned_slice_id and planned_slice.work_request_id == ^work_request_id
      )
    )
  end

  defp existing_planned_slice_delivery(repo, planned_slice_id) do
    repo.one(
      from(delivery in PlannedSliceDelivery,
        where: delivery.planned_slice_id == ^planned_slice_id,
        limit: 1
      )
    )
  end

  defp replay_unique_planned_slice_delivery(repo, planned_slice_id, candidate, changeset) do
    cond do
      not planned_slice_delivery_unique_conflict?(changeset) ->
        repo.rollback(changeset)

      existing = existing_planned_slice_delivery(repo, planned_slice_id) ->
        replay_planned_slice_delivery(repo, existing, candidate)

      true ->
        repo.rollback(changeset)
    end
  end

  defp replay_planned_slice_delivery(repo, existing, candidate) do
    if planned_slice_delivery_replay?(existing, candidate) do
      existing
    else
      repo.rollback(:delivery_outcome_conflict)
    end
  end

  defp planned_slice_delivery_replay?(%PlannedSliceDelivery{} = existing, %PlannedSliceDelivery{} = candidate) do
    Enum.all?(@planned_slice_delivery_replay_fields, fn field ->
      Map.get(existing, field) == Map.get(candidate, field)
    end)
  end

  defp planned_slice_delivery_unique_conflict?(%Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:planned_slice_id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp update_planned_slice_status(repo, work_request_id, id, current_status, next_status, allowed_current_statuses) do
    with :ok <- validate_planned_slice_status(current_status),
         :ok <- validate_planned_slice_status(next_status),
         :ok <- require_status(current_status, allowed_current_statuses) do
      update_valid_planned_slice_status(
        repo,
        work_request_id,
        id,
        current_status,
        next_status,
        allowed_current_statuses
      )
    end
  end

  defp update_valid_planned_slice_status(
         repo,
         work_request_id,
         id,
         current_status,
         next_status,
         allowed_current_statuses
       ) do
    now = DateTime.utc_now(:microsecond)

    repo.transaction(fn ->
      work_request_id
      |> planned_slice_status_update_query(id, current_status, next_status, allowed_current_statuses)
      |> repo.update_all(set: [status: next_status, updated_at: now])
      |> case do
        {1, _rows} ->
          repo.get!(PlannedSlice, id)

        {0, _rows} ->
          repo.rollback(planned_slice_terminal_error(repo, work_request_id, id, current_status, next_status))
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp planned_slice_status_update_query(work_request_id, id, current_status, next_status, allowed_current_statuses) do
    from(planned_slice in PlannedSlice,
      join: work_request in WorkRequest,
      on: work_request.id == planned_slice.work_request_id,
      where:
        planned_slice.id == ^id and planned_slice.work_request_id == ^work_request_id and
          planned_slice.status == ^current_status and planned_slice.status in ^allowed_current_statuses,
      where: work_request.status in ["ready_for_slicing", "sliced"]
    )
    |> preserve_sliced_approved_slice(next_status)
  end

  defp preserve_sliced_approved_slice(query, "skipped") do
    from([planned_slice, work_request] in query,
      where:
        planned_slice.status != "approved" or work_request.status != "sliced" or
          fragment(
            """
            EXISTS (
              SELECT 1
              FROM sympp_work_request_planned_slices AS sibling
              WHERE sibling.work_request_id = ?
                AND sibling.id != ?
                AND (
                  sibling.status = 'approved'
                  OR (
                    sibling.status = 'dispatched'
                    AND sibling.work_package_id IS NOT NULL
                    AND sibling.dispatched_at IS NOT NULL
                  )
                )
            )
            """,
            planned_slice.work_request_id,
            planned_slice.id
          )
    )
  end

  defp preserve_sliced_approved_slice(query, _next_status), do: query

  defp dispatch_valid_planned_slice(repo, work_request_id, id, current_status, work_package_id) do
    now = DateTime.utc_now(:microsecond)

    repo.transaction(fn ->
      work_request_id
      |> planned_slice_dispatch_query(id, current_status, work_package_id)
      |> repo.update_all(
        set: [
          status: "dispatched",
          work_package_id: work_package_id,
          dispatched_at: now,
          updated_at: now
        ]
      )
      |> case do
        {1, _rows} ->
          repo.get!(PlannedSlice, id)

        {0, _rows} ->
          error = planned_slice_dispatch_terminal_error(repo, work_request_id, id, current_status, work_package_id)
          repo.rollback(error)
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp planned_slice_dispatch_query(work_request_id, id, current_status, work_package_id) do
    from(planned_slice in PlannedSlice,
      join: work_request in WorkRequest,
      on: work_request.id == planned_slice.work_request_id,
      join: work_package in WorkPackage,
      on: work_package.id == ^work_package_id,
      where: planned_slice.id == ^id,
      where: planned_slice.work_request_id == ^work_request_id,
      where: planned_slice.status == ^current_status,
      where: planned_slice.status == "approved",
      where: is_nil(planned_slice.work_package_id),
      where: is_nil(planned_slice.dispatched_at),
      where: work_request.status in ["ready_for_slicing", "sliced"],
      where: work_package.repo == fragment("COALESCE(NULLIF(?, ''), ?)", planned_slice.delivery_repo, work_request.repo),
      where: work_package.base_branch == planned_slice.target_base_branch,
      where: work_package.kind == planned_slice.work_package_kind,
      where: work_package.title == planned_slice.title,
      where: work_package.product_description == work_request.human_description,
      where: work_package.allowed_file_globs == planned_slice.owned_file_globs,
      where: work_package.acceptance_criteria == planned_slice.acceptance_criteria,
      where: fragment("COALESCE(?, '') = COALESCE(?, '')", work_package.branch_pattern, planned_slice.branch_pattern),
      where:
        fragment(
          """
          NOT EXISTS (
            SELECT 1
            FROM sympp_work_request_planned_slices AS linked_slice
            WHERE linked_slice.work_package_id = ?
          )
          """,
          ^work_package_id
        )
    )
  end

  defp planned_slice_dispatch_terminal_error(repo, work_request_id, id, current_status, work_package_id) do
    case repo.get(PlannedSlice, id) do
      nil ->
        :not_found

      %PlannedSlice{work_request_id: slice_work_request_id} when slice_work_request_id != work_request_id ->
        :not_found

      %PlannedSlice{status: status} when status != current_status ->
        :stale_status

      %PlannedSlice{status: status} when status != "approved" ->
        :invalid_status

      %PlannedSlice{work_package_id: linked_work_package_id} when not is_nil(linked_work_package_id) ->
        :work_package_already_linked

      %PlannedSlice{dispatched_at: %DateTime{}} ->
        :stale_status

      %PlannedSlice{} ->
        dispatch_context_error(repo, work_request_id, id, work_package_id)
    end
  end

  defp dispatch_context_error(repo, work_request_id, id, work_package_id) do
    case get(repo, work_request_id) do
      {:ok, %WorkRequest{status: status}} when status in ["ready_for_slicing", "sliced"] ->
        cond do
          not work_package_exists?(repo, work_package_id) -> :work_package_not_found
          work_package_linked?(repo, work_package_id) -> :work_package_already_linked
          not work_package_matches_planned_slice?(repo, work_request_id, id, work_package_id) -> :work_package_mismatch
          true -> :stale_status
        end

      {:ok, %WorkRequest{}} ->
        :invalid_status

      {:error, reason} ->
        reason
    end
  end

  defp planned_slice_terminal_error(repo, work_request_id, id, current_status, next_status) do
    case repo.get(PlannedSlice, id) do
      nil -> :not_found
      %PlannedSlice{work_request_id: slice_work_request_id} when slice_work_request_id != work_request_id -> :not_found
      %PlannedSlice{status: status} when status != current_status -> :stale_status
      %PlannedSlice{} -> parent_planned_slice_status_error(repo, work_request_id, id, current_status, next_status)
    end
  end

  defp parent_planned_slice_status_error(repo, work_request_id, planned_slice_id, current_status, next_status) do
    case get(repo, work_request_id) do
      {:ok, %WorkRequest{status: "sliced"}}
      when current_status == "approved" and next_status == "skipped" ->
        if other_active_planned_slice?(repo, work_request_id, planned_slice_id) do
          :invalid_status
        else
          :last_approved_slice
        end

      {:ok, %WorkRequest{status: status}} when status in ["ready_for_slicing", "sliced"] ->
        :invalid_status

      {:ok, %WorkRequest{}} ->
        :invalid_status

      {:error, reason} ->
        reason
    end
  end

  defp other_active_planned_slice?(repo, work_request_id, planned_slice_id) do
    not is_nil(
      repo.one(
        from(planned_slice in PlannedSlice,
          where:
            planned_slice.work_request_id == ^work_request_id and planned_slice.id != ^planned_slice_id and
              (planned_slice.status == "approved" or
                 (planned_slice.status == "dispatched" and not is_nil(planned_slice.work_package_id) and
                    not is_nil(planned_slice.dispatched_at))),
          select: 1,
          limit: 1
        )
      )
    )
  end

  defp mark_valid_sliced(repo, id, current_status) do
    now = DateTime.utc_now(:microsecond)

    repo.transaction(fn ->
      id
      |> sliced_status_update_query(current_status)
      |> repo.update_all(set: [status: "sliced", updated_at: now])
      |> case do
        {1, _rows} -> repo.get!(WorkRequest, id)
        {0, _rows} -> repo.rollback(sliced_status_terminal_error(repo, id, current_status))
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp sliced_status_update_query(id, current_status) do
    from(work_request in WorkRequest,
      where: work_request.id == ^id and work_request.status == ^current_status,
      where:
        fragment(
          """
          EXISTS (
            SELECT 1
            FROM sympp_work_request_planned_slices AS planned_slice
            WHERE planned_slice.work_request_id = ?
              AND (
                planned_slice.status = 'approved'
                OR (
                  planned_slice.status = 'dispatched'
                  AND planned_slice.work_package_id IS NOT NULL
                  AND planned_slice.dispatched_at IS NOT NULL
                )
              )
          )
          """,
          work_request.id
        )
    )
  end

  defp sliced_status_terminal_error(repo, id, current_status) do
    case get(repo, id) do
      {:error, reason} ->
        reason

      {:ok, %WorkRequest{status: status}} when status != current_status ->
        :stale_status

      {:ok, %WorkRequest{}} ->
        if active_planned_slice?(repo, id), do: :stale_status, else: :no_approved_slices
    end
  end

  defp active_planned_slice?(repo, work_request_id) do
    not is_nil(
      repo.one(
        from(planned_slice in PlannedSlice,
          where:
            planned_slice.work_request_id == ^work_request_id and
              (planned_slice.status == "approved" or
                 (planned_slice.status == "dispatched" and not is_nil(planned_slice.work_package_id) and
                    not is_nil(planned_slice.dispatched_at))),
          select: 1,
          limit: 1
        )
      )
    )
  end

  defp work_package_exists?(repo, work_package_id), do: not is_nil(repo.get(WorkPackage, work_package_id))

  defp work_package_matches_planned_slice?(repo, work_request_id, id, work_package_id) do
    repo.exists?(
      from(planned_slice in PlannedSlice,
        join: work_request in WorkRequest,
        on: work_request.id == planned_slice.work_request_id,
        join: work_package in WorkPackage,
        on: work_package.id == ^work_package_id,
        where: planned_slice.id == ^id and planned_slice.work_request_id == ^work_request_id,
        where: work_package.repo == fragment("COALESCE(NULLIF(?, ''), ?)", planned_slice.delivery_repo, work_request.repo),
        where: work_package.base_branch == planned_slice.target_base_branch,
        where: work_package.kind == planned_slice.work_package_kind,
        where: work_package.title == planned_slice.title,
        where: work_package.product_description == work_request.human_description,
        where: work_package.allowed_file_globs == planned_slice.owned_file_globs,
        where: work_package.acceptance_criteria == planned_slice.acceptance_criteria,
        where: fragment("COALESCE(?, '') = COALESCE(?, '')", work_package.branch_pattern, planned_slice.branch_pattern),
        select: 1,
        limit: 1
      )
    )
  end

  defp work_package_linked?(repo, work_package_id) do
    repo.exists?(
      from(planned_slice in PlannedSlice,
        where: planned_slice.work_package_id == ^work_package_id
      )
    )
  end

  defp update_existing_work_request(repo, %WorkRequest{} = work_request, attrs) do
    repo.transaction(fn ->
      with {:ok, updated} <-
             work_request
             |> WorkRequest.update_changeset(attrs)
             |> repo.update(),
           :ok <- sync_repo_scopes_after_update(repo, work_request, updated, attrs) do
        updated
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  end

  defp sync_repo_scopes_after_update(repo, %WorkRequest{} = previous, %WorkRequest{} = updated, attrs) do
    cond do
      Map.has_key?(attrs, "repo_scopes") ->
        replace_repo_scopes(repo, updated, repo_scope_attrs(attrs, updated))

      primary_repo_scope_sync_required?(attrs) ->
        replace_primary_repo_scope(repo, previous, updated)

      true ->
        :ok
    end
  end

  defp primary_repo_scope_sync_required?(attrs) do
    Enum.any?(["repo", "base_branch"], &Map.has_key?(attrs, &1))
  end

  defp replace_repo_scopes(repo, %WorkRequest{} = work_request, repo_scope_attrs) do
    repo.delete_all(from(scope in RepoScope, where: scope.work_request_id == ^work_request.id))

    insert_repo_scopes(repo, repo_scope_attrs)
  end

  defp replace_primary_repo_scope(repo, %WorkRequest{} = previous, %WorkRequest{} = updated) do
    scope_keys =
      [primary_repo_scope_attrs(previous), primary_repo_scope_attrs(updated)]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&RepoScope.scope_key/1)
      |> Enum.uniq()

    repo.delete_all(
      from(scope in RepoScope,
        where: scope.work_request_id == ^updated.id,
        where: scope.scope_key in ^scope_keys
      )
    )

    case primary_repo_scope_attrs(updated) do
      nil -> :ok
      attrs -> insert_repo_scopes(repo, [attrs])
    end
  end

  defp insert_repo_scopes(repo, repo_scope_attrs) do
    Enum.reduce_while(repo_scope_attrs, :ok, fn attrs, :ok ->
      case insert_repo_scope(repo, attrs) do
        {:ok, %RepoScope{}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_repo_scope(repo, attrs) do
    attrs
    |> RepoScope.create_changeset()
    |> repo.insert()
  end

  defp repo_scope_attrs(attrs, %WorkRequest{} = work_request) do
    ([primary_repo_scope_attrs(work_request)] ++ explicit_repo_scopes(attrs, work_request.id))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Map.put(&1, "work_request_id", work_request.id))
    |> Enum.uniq_by(&RepoScope.scope_key/1)
  end

  defp primary_repo_scope_attrs(%WorkRequest{id: id, repo: repo, base_branch: base_branch})
       when is_binary(id) and is_binary(repo) do
    RepoScope.primary_attrs(id, repo, base_branch)
  end

  defp primary_repo_scope_attrs(%WorkRequest{}), do: nil

  defp explicit_repo_scopes(%{"repo_scopes" => scopes}, work_request_id) when is_list(scopes) do
    Enum.map(scopes, fn
      %{} = scope ->
        scope
        |> normalize_keys()
        |> Map.take(["repo", "base_branch"])
        |> Map.put("work_request_id", work_request_id)

      _scope ->
        %{"work_request_id" => work_request_id}
    end)
  end

  defp explicit_repo_scopes(%{"repo_scopes" => _scopes}, work_request_id), do: [%{"work_request_id" => work_request_id}]
  defp explicit_repo_scopes(_attrs, _work_request_id), do: []

  defp normalize_insert_result({:ok, work_request}), do: {:ok, work_request}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    if duplicate_id?(changeset) do
      {:error, :id_already_exists}
    else
      {:error, changeset}
    end
  end

  defp normalize_transaction_result({:ok, record}), do: {:ok, record}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp duplicate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    cond do
      duplicate_id_constraint?(constraint) -> {:error, :id_already_exists}
      constraint == "sympp_work_request_planned_slices_work_package_id_unique_index" -> {:error, :work_package_already_linked}
      true -> {:error, {:constraint_failed, constraint}}
    end
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}) do
    {:error, {:constraint_failed, Atom.to_string(type)}}
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    cond do
      String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") ->
        {:error, :database_busy}

      String.contains?(normalized_message, "sympp_work_request_planned_slices.work_package_id") ->
        {:error, :work_package_already_linked}

      true ->
        {:error, {:storage_failed, message}}
    end
  end

  defp duplicate_id_constraint?(constraint) do
    constraint in [
      "sympp_work_requests_id_unique_index",
      "sympp_work_requests_id_index",
      "sympp_work_request_questions_id_unique_index",
      "sympp_work_request_clarification_questions_id_index",
      "sympp_work_request_decision_logs_id_unique_index",
      "sympp_work_request_decision_logs_id_index",
      "sympp_work_request_planned_slices_id_unique_index",
      "sympp_work_request_planned_slices_id_index"
    ] or
      (String.contains?(constraint, "sympp_work_requests") and String.contains?(constraint, ".id")) or
      (String.contains?(constraint, "sympp_work_request_clarification_questions") and
         String.contains?(constraint, ".id")) or
      (String.contains?(constraint, "sympp_work_request_decision_logs") and String.contains?(constraint, ".id")) or
      (String.contains?(constraint, "sympp_work_request_planned_slices") and String.contains?(constraint, ".id"))
  end

  defp sequence_constraint?(constraint) do
    constraint in [
      "sympp_work_request_questions_work_request_sequence_unique_index",
      "sympp_work_request_decision_logs_work_request_sequence_unique_index",
      "sympp_work_request_planned_slices_work_request_sequence_unique_index"
    ] or
      (String.contains?(constraint, "sympp_work_request_clarification_questions") and
         String.contains?(constraint, "sequence")) or
      (String.contains?(constraint, "sympp_work_request_decision_logs") and String.contains?(constraint, "sequence")) or
      (String.contains?(constraint, "sympp_work_request_planned_slices") and String.contains?(constraint, "sequence"))
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_keys(attrs) when is_list(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp normalize_dispatch_work_package_id(work_package_id) when is_binary(work_package_id) do
    work_package_id = String.trim(work_package_id)

    if work_package_id == "" do
      {:error, :invalid_work_package_id}
    else
      {:ok, work_package_id}
    end
  end

  defp normalize_dispatch_work_package_id(_work_package_id), do: {:error, :invalid_work_package_id}

  defp put_new_value(attrs, key, value) do
    if Map.get(attrs, key) in [nil, ""] do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end
end
