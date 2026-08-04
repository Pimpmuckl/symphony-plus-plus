defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository do
  @moduledoc false

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Node
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDeliveryScope
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.CompletionRecovery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.RepoScope
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ScopeConstraints
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @completion_blocking_statuses ["human_info_needed"]
  @inactive_work_package_statuses ["skipped", "merged", "merged_into_phase", "closed", "abandoned"]
  @work_package_delivery_replay_fields [
    :work_request_id,
    :work_package_id,
    :outcome,
    :idempotency_key,
    :recorded_by,
    :pr_url,
    :pr_number,
    :pr_repository,
    :pr_merged_at,
    :merge_commit_sha,
    :no_pr_evidence,
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
  @work_package_create_ignored_attrs [
    "created_at",
    "dispatched_at",
    "inserted_at",
    "sequence",
    "updated_at",
    "contract_revision"
  ]

  @type repo :: module()
  @type error ::
          :already_answered
          | :already_closed
          | :database_busy
          | :delivery_outcome_conflict
          | :last_active_work_package
          | :no_work_packages
          | :open_questions
          | :not_found
          | :invalid_work_package_id
          | :id_already_exists
          | :invalid_status
          | :work_package_delivery_scope_out_of_scope
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

  @spec prepare_for_work_packages(repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def prepare_for_work_packages(repo, id) when is_atom(repo) and is_binary(id) do
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

  @spec slice_work_request(repo(), String.t(), [map()]) ::
          {:ok, %{work_request: WorkRequest.t(), work_packages: [WorkPackage.t()]}} | {:error, error()}
  def slice_work_request(repo, work_request_id, package_attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_list(package_attrs) do
    repo.transaction(fn ->
      with :ok <- prepare_for_work_packages_in_transaction(repo, work_request_id),
           {:ok, %WorkRequest{} = work_request} <- get(repo, work_request_id),
           :ok <- require_slicing_status(work_request.status),
           :ok <- require_package_batch(package_attrs),
           {:ok, work_packages} <- insert_work_package_batch(repo, work_request, package_attrs),
           {:ok, updated_work_request} <- mark_sliced_in_transaction(repo, work_request) do
        %{work_request: updated_work_request, work_packages: work_packages}
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_work_packages(repo(), String.t()) :: {:ok, [WorkPackage.t()]} | {:error, error()}
  def list_work_packages(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    {:ok,
     repo.all(
       from(work_package in WorkPackage,
         where: work_package.work_request_id == ^work_request_id,
         order_by: [asc: work_package.sequence, asc: work_package.id]
       )
     )}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec get_work_package(repo(), String.t(), String.t()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def get_work_package(repo, work_request_id, id)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(id) do
    case repo.get(WorkPackage, id) do
      %WorkPackage{work_request_id: ^work_request_id} = work_package -> {:ok, work_package}
      _work_package -> {:error, :not_found}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec update_work_package(repo(), String.t(), String.t(), pos_integer(), map()) ::
          {:ok, WorkPackage.t()} | {:error, error()}
  def update_work_package(repo, work_request_id, id, expected_revision, attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(id) and is_integer(expected_revision) and
             expected_revision > 0 and is_map(attrs) do
    with {:ok, %WorkPackage{} = work_package} <- get_work_package(repo, work_request_id, id),
         :ok <- require_contract_revision(work_package, expected_revision),
         :ok <- require_mutable_contract(work_package) do
      update_contract(repo, work_package, attrs)
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_status}
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec skip_work_package(repo(), String.t(), String.t(), String.t()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def skip_work_package(repo, work_request_id, id, current_status)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(id) and is_binary(current_status) do
    update_work_package_status(repo, work_request_id, id, current_status, "skipped", ["planned"])
  end

  @spec record_work_package_delivery(repo(), String.t(), String.t(), map()) ::
          {:ok, WorkPackageDelivery.t()} | {:error, error()}
  def record_work_package_delivery(repo, work_request_id, work_package_id, attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(work_package_id) and is_map(attrs) do
    repo.transaction(fn ->
      with {:ok, delivery} <-
             record_work_package_delivery_in_transaction(
               repo,
               work_request_id,
               work_package_id,
               attrs
             ),
           {:ok, work_package} <- get_work_package(repo, work_request_id, work_package_id),
           :ok <- WorkPackageRepository.clear_terminal_attention(repo, work_package) do
        delivery
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @doc false
  @spec record_work_package_delivery_in_transaction(repo(), String.t(), String.t(), map()) ::
          {:ok, WorkPackageDelivery.t()} | {:error, error()}
  def record_work_package_delivery_in_transaction(repo, work_request_id, work_package_id, attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(work_package_id) and is_map(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.drop(["id", "inserted_at", "recorded_at", "updated_at"])
      |> Map.put("work_request_id", work_request_id)
      |> Map.put("work_package_id", work_package_id)

    changeset = WorkPackageDelivery.create_changeset(attrs)

    with {:ok, candidate} <- Changeset.apply_action(changeset, :insert),
         :ok <- validate_work_package_delivery_scope(repo, work_request_id, work_package_id, candidate) do
      {:ok, insert_or_replay_scoped_work_package_delivery(repo, work_package_id, changeset, candidate)}
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
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
      |> status_update_query(current_status, next_status)
      |> repo.update_all(set: status_update_values(next_status, now))
      |> case do
        {1, _rows} -> repo.get!(WorkRequest, id)
        {0, _rows} -> repo.rollback(status_update_error(repo, id, current_status, next_status))
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

  defp prepare_for_work_packages_in_transaction(repo, work_request_id) do
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

  defp status_update_query(id, "human_info_needed", "ready_for_slicing"),
    do: ready_for_slicing_update_query(id, "human_info_needed")

  defp status_update_query(id, current_status, _next_status) do
    from(work_request in WorkRequest,
      where: work_request.id == ^id and work_request.status == ^current_status
    )
  end

  defp status_update_error(repo, id, "human_info_needed", "ready_for_slicing") do
    case ensure_no_open_questions(repo, id) do
      :ok -> stale_status_error(repo, id)
      {:error, _reason} = error -> error
    end
  end

  defp status_update_error(repo, id, _current_status, _next_status), do: stale_status_error(repo, id)

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
      case maybe_prepare_for_work_packages(repo, attrs, opts) do
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

  defp maybe_prepare_for_work_packages(repo, %{"work_request_id" => work_request_id}, opts) do
    if Keyword.get(opts, :prepare_for_work_packages?, false) do
      prepare_for_work_packages_in_transaction(repo, work_request_id)
    else
      :ok
    end
  end

  defp maybe_prepare_for_work_packages(_repo, _attrs, _opts), do: :ok

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

  defp validate_work_package_delivery_scope(
         repo,
         work_request_id,
         work_package_id,
         %WorkPackageDelivery{outcome: "superseded"} = candidate
       ) do
    with true <- work_package_in_scope?(repo, work_request_id, work_package_id),
         %WorkPackage{work_request_id: ^work_request_id} <- repo.get(WorkPackage, candidate.successor_work_package_id) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp validate_work_package_delivery_scope(repo, work_request_id, work_package_id, %WorkPackageDelivery{}) do
    if work_package_in_scope?(repo, work_request_id, work_package_id), do: :ok, else: {:error, :not_found}
  end

  defp insert_or_replay_scoped_work_package_delivery(repo, work_package_id, changeset, candidate) do
    case existing_work_package_delivery(repo, work_package_id) do
      %WorkPackageDelivery{} = existing -> replay_work_package_delivery(repo, existing, candidate)
      nil -> insert_work_package_delivery(repo, work_package_id, changeset, candidate)
    end
  end

  defp insert_work_package_delivery(repo, work_package_id, changeset, candidate) do
    case repo.insert(changeset) do
      {:ok, delivery} ->
        delivery

      {:error, %Changeset{} = changeset} ->
        replay_unique_work_package_delivery(repo, work_package_id, candidate, changeset)

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp work_package_in_scope?(repo, work_request_id, work_package_id) do
    repo.exists?(
      from(work_package in WorkPackage,
        where: work_package.id == ^work_package_id and work_package.work_request_id == ^work_request_id
      )
    )
  end

  defp existing_work_package_delivery(repo, work_package_id) do
    repo.one(
      from(delivery in WorkPackageDelivery,
        where: delivery.work_package_id == ^work_package_id,
        limit: 1
      )
    )
  end

  defp replay_unique_work_package_delivery(repo, work_package_id, candidate, changeset) do
    cond do
      not work_package_delivery_unique_conflict?(changeset) ->
        repo.rollback(changeset)

      existing = existing_work_package_delivery(repo, work_package_id) ->
        replay_work_package_delivery(repo, existing, candidate)

      true ->
        repo.rollback(changeset)
    end
  end

  defp replay_work_package_delivery(repo, existing, candidate) do
    if work_package_delivery_replay?(existing, candidate) do
      existing
    else
      repo.rollback(:delivery_outcome_conflict)
    end
  end

  defp work_package_delivery_replay?(%WorkPackageDelivery{} = existing, %WorkPackageDelivery{} = candidate) do
    Enum.all?(@work_package_delivery_replay_fields, fn field ->
      Map.get(existing, field) == Map.get(candidate, field)
    end)
  end

  defp work_package_delivery_unique_conflict?(%Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:work_package_id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp update_work_package_status(repo, work_request_id, id, current_status, next_status, allowed_current_statuses) do
    with :ok <- require_status(current_status, allowed_current_statuses) do
      now = DateTime.utc_now(:microsecond)

      repo.transaction(fn ->
        update_work_package_status_row(
          repo,
          work_request_id,
          id,
          current_status,
          next_status,
          allowed_current_statuses,
          now
        )
      end)
      |> normalize_transaction_result()
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp update_work_package_status_row(
         repo,
         work_request_id,
         id,
         current_status,
         next_status,
         allowed_current_statuses,
         now
       ) do
    result =
      from(work_package in WorkPackage,
        join: work_request in WorkRequest,
        on: work_request.id == work_package.work_request_id,
        where:
          work_package.id == ^id and work_package.work_request_id == ^work_request_id and
            work_package.status == ^current_status and work_package.status in ^allowed_current_statuses,
        where: work_request.status in ["ready_for_slicing", "sliced"]
      )
      |> preserve_sliced_active_work_package(next_status)
      |> repo.update_all(set: [status: next_status, updated_at: now])

    case result do
      {1, _rows} ->
        work_package = repo.get!(WorkPackage, id)

        case WorkPackageRepository.clear_terminal_attention(repo, work_package) do
          :ok -> work_package
          {:error, reason} -> repo.rollback(reason)
        end

      {0, _rows} ->
        repo.rollback(work_package_status_error(repo, work_request_id, id, current_status, next_status))
    end
  end

  defp preserve_sliced_active_work_package(query, "skipped") do
    from([work_package, work_request] in query,
      where:
        work_request.status != "sliced" or
          fragment(
            """
            EXISTS (
              SELECT 1
              FROM sympp_work_packages AS sibling
              WHERE sibling.work_request_id = ?
                AND sibling.id != ?
                AND sibling.status NOT IN ('skipped', 'merged', 'merged_into_phase', 'closed', 'abandoned')
            )
            """,
            work_package.work_request_id,
            work_package.id
          )
    )
  end

  defp preserve_sliced_active_work_package(query, _next_status), do: query

  defp work_package_status_error(repo, work_request_id, id, current_status, next_status) do
    case repo.get(WorkPackage, id) do
      %WorkPackage{work_request_id: ^work_request_id, status: ^current_status} ->
        parent_work_package_status_error(repo, work_request_id, id, current_status, next_status)

      %WorkPackage{work_request_id: ^work_request_id} ->
        :stale_status

      _work_package ->
        :not_found
    end
  end

  defp parent_work_package_status_error(repo, work_request_id, work_package_id, "planned", "skipped") do
    case get(repo, work_request_id) do
      {:ok, %WorkRequest{status: "sliced"}} ->
        if other_active_work_package?(repo, work_request_id, work_package_id),
          do: :invalid_status,
          else: :last_active_work_package

      {:ok, %WorkRequest{}} ->
        :invalid_status

      {:error, reason} ->
        reason
    end
  end

  defp parent_work_package_status_error(_repo, _work_request_id, _work_package_id, _current_status, _next_status),
    do: :invalid_status

  defp other_active_work_package?(repo, work_request_id, work_package_id) do
    repo.exists?(
      from(work_package in WorkPackage,
        where:
          work_package.work_request_id == ^work_request_id and work_package.id != ^work_package_id and
            work_package.status not in ^@inactive_work_package_statuses,
        select: 1,
        limit: 1
      )
    )
  end

  defp require_slicing_status(status) when status in ["ready_for_slicing", "sliced"], do: :ok
  defp require_slicing_status(_status), do: {:error, :invalid_status}

  defp require_package_batch([first | rest]) when is_map(first) do
    if Enum.all?(rest, &is_map/1), do: :ok, else: {:error, :invalid_work_package}
  end

  defp require_package_batch(_packages), do: {:error, :invalid_work_package}

  defp insert_work_package_batch(repo, %WorkRequest{} = work_request, package_attrs) do
    first_sequence = next_sequence(repo, WorkPackage, work_request.id)

    package_attrs
    |> Enum.with_index(first_sequence)
    |> Enum.reduce_while({:ok, []}, fn {attrs, sequence}, {:ok, packages} ->
      with {:ok, attrs} <- work_package_attrs(repo, work_request, attrs, sequence),
           {:ok, work_package} <- attrs |> WorkPackage.create_changeset() |> repo.insert() do
        {:cont, {:ok, [work_package | packages]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, packages} ->
        case maybe_clear_completion_state(repo, %{"work_request_id" => work_request.id}, clear_completion?: true) do
          :ok -> {:ok, Enum.reverse(packages)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp work_package_attrs(repo, %WorkRequest{} = work_request, attrs, sequence) do
    attrs =
      attrs
      |> normalize_keys()
      |> rename_key("review", "review_requirement")
      |> Map.drop(@work_package_create_ignored_attrs)
      |> put_new_value("repo", work_request.repo)
      |> put_primary_base_branch_default(work_request)
      |> put_new_value("kind", "standard_pr")
      |> then(&put_new_value(&1, "policy_template", Map.get(&1, "kind")))
      |> put_new_value("product_description", work_request.human_description)
      |> then(&put_new_value(&1, "engineering_scope", Map.get(&1, "goal")))
      |> put_new_value("allowed_file_globs", [])
      |> put_new_value("forbidden_file_globs", [])
      |> put_new_value("acceptance_criteria", [])
      |> put_new_value("validation_steps", [])
      |> put_new_value("stop_conditions", [])
      |> Map.put("work_request_id", work_request.id)
      |> Map.put("sequence", sequence)
      |> Map.put("status", "planned")
      |> Map.put("contract_revision", 1)

    with :ok <- validate_executable_work_package_kind(attrs),
         :ok <- WorkPackageDeliveryScope.validate(repo, work_request, attrs),
         :ok <- ScopeConstraints.validate_allowed_file_globs(work_request, Map.get(attrs, "allowed_file_globs", [])),
         :ok <- validate_docs_work_package_scope(attrs),
         :ok <- validate_product_tree_node(repo, work_request.id, Map.get(attrs, "product_tree_node_id")) do
      {:ok, attrs}
    end
  end

  defp put_primary_base_branch_default(attrs, %WorkRequest{} = work_request) do
    if Map.get(attrs, "repo") == work_request.repo do
      put_new_value(attrs, "base_branch", work_request.base_branch)
    else
      attrs
    end
  end

  defp validate_docs_work_package_scope(%{"kind" => "docs", "allowed_file_globs" => globs}) do
    ScopeConstraints.validate_docs_allowed_file_globs(globs)
  end

  defp validate_docs_work_package_scope(_attrs), do: :ok

  defp validate_executable_work_package_kind(%{"kind" => kind}) do
    if kind in WorkPackage.executable_kinds(), do: :ok, else: {:error, :invalid_work_package}
  end

  defp validate_product_tree_node(_repo, _work_request_id, nil), do: :ok
  defp validate_product_tree_node(_repo, _work_request_id, ""), do: :ok

  defp validate_product_tree_node(repo, work_request_id, node_id) when is_binary(node_id) do
    case repo.get(Node, node_id) do
      %Node{work_request_id: ^work_request_id} -> :ok
      _node -> {:error, :not_found}
    end
  end

  defp validate_product_tree_node(_repo, _work_request_id, _node_id), do: {:error, :not_found}

  defp mark_sliced_in_transaction(repo, %WorkRequest{} = work_request) do
    now = DateTime.utc_now(:microsecond)

    from(request in WorkRequest,
      where: request.id == ^work_request.id and request.status == ^work_request.status,
      where: request.status in ["ready_for_slicing", "sliced"]
    )
    |> repo.update_all(set: [status: "sliced", updated_at: now])
    |> case do
      {1, _rows} -> {:ok, repo.get!(WorkRequest, work_request.id)}
      {0, _rows} -> {:error, :stale_status}
    end
  end

  defp require_contract_revision(%WorkPackage{contract_revision: revision}, revision), do: :ok
  defp require_contract_revision(%WorkPackage{}, _expected_revision), do: {:error, :stale_status}

  defp require_mutable_contract(%WorkPackage{status: "planned"}), do: :ok
  defp require_mutable_contract(%WorkPackage{}), do: {:error, :invalid_status}

  defp update_contract(repo, %WorkPackage{} = work_package, attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> rename_key("review", "review_requirement")
      |> Map.take([
        "product_tree_node_id",
        "kind",
        "title",
        "goal",
        "repo",
        "base_branch",
        "branch_pattern",
        "allowed_file_globs",
        "forbidden_file_globs",
        "acceptance_criteria",
        "validation_steps",
        "review_requirement",
        "stop_conditions"
      ])
      |> maybe_sync_policy_template()
      |> maybe_sync_engineering_scope()
      |> maybe_invalidate_readiness(work_package)

    effective_contract =
      work_package
      |> Map.from_struct()
      |> normalize_keys()
      |> Map.merge(attrs)

    with :ok <- validate_executable_work_package_kind(effective_contract),
         :ok <- validate_product_tree_node(repo, work_package.work_request_id, Map.get(attrs, "product_tree_node_id")),
         {:ok, %WorkRequest{} = work_request} <- get(repo, work_package.work_request_id),
         :ok <- WorkPackageDeliveryScope.validate(repo, work_request, effective_contract),
         :ok <- ScopeConstraints.validate_allowed_file_globs(work_request, Map.get(effective_contract, "allowed_file_globs", [])),
         :ok <- validate_docs_work_package_scope(effective_contract) do
      work_package
      |> WorkPackage.update_changeset(attrs)
      |> Ecto.Changeset.optimistic_lock(:status, & &1)
      |> Ecto.Changeset.optimistic_lock(:contract_revision)
      |> repo.update()
    end
  end

  defp maybe_sync_policy_template(attrs) do
    case Map.fetch(attrs, "kind") do
      {:ok, kind} -> Map.put(attrs, "policy_template", kind)
      :error -> attrs
    end
  end

  defp maybe_sync_engineering_scope(attrs) do
    case Map.fetch(attrs, "goal") do
      {:ok, goal} -> Map.put(attrs, "engineering_scope", goal)
      :error -> attrs
    end
  end

  defp maybe_invalidate_readiness(attrs, %WorkPackage{status: status})
       when status in ["reviewing", "ci_waiting", "ready_for_merge", "ready_for_architect_merge"] do
    Map.put(attrs, "status", "implementing")
  end

  defp maybe_invalidate_readiness(attrs, %WorkPackage{}), do: attrs

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
    if duplicate_id_constraint?(constraint),
      do: {:error, :id_already_exists},
      else: {:error, {:constraint_failed, constraint}}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}) do
    {:error, {:constraint_failed, Atom.to_string(type)}}
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    if String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked"),
      do: {:error, :database_busy},
      else: {:error, {:storage_failed, message}}
  end

  defp duplicate_id_constraint?(constraint) do
    constraint in [
      "sympp_work_requests_id_unique_index",
      "sympp_work_requests_id_index",
      "sympp_work_request_questions_id_unique_index",
      "sympp_work_request_clarification_questions_id_index",
      "sympp_work_request_decision_logs_id_unique_index",
      "sympp_work_request_decision_logs_id_index",
      "sympp_work_packages_id_unique_index",
      "sympp_work_packages_id_index"
    ] or
      (String.contains?(constraint, "sympp_work_requests") and String.contains?(constraint, ".id")) or
      (String.contains?(constraint, "sympp_work_request_clarification_questions") and
         String.contains?(constraint, ".id")) or
      (String.contains?(constraint, "sympp_work_request_decision_logs") and String.contains?(constraint, ".id")) or
      (String.contains?(constraint, "sympp_work_packages") and String.contains?(constraint, ".id"))
  end

  defp sequence_constraint?(constraint) do
    constraint in [
      "sympp_work_request_questions_work_request_sequence_unique_index",
      "sympp_work_request_decision_logs_work_request_sequence_unique_index",
      "sympp_work_packages_work_request_sequence_unique_index"
    ] or
      (String.contains?(constraint, "sympp_work_request_clarification_questions") and
         String.contains?(constraint, "sequence")) or
      (String.contains?(constraint, "sympp_work_request_decision_logs") and String.contains?(constraint, "sequence")) or
      (String.contains?(constraint, "sympp_work_packages") and String.contains?(constraint, "sequence"))
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

  defp rename_key(attrs, source, target) do
    case Map.pop(attrs, source) do
      {nil, attrs} -> attrs
      {value, attrs} -> Map.put_new(attrs, target, value)
    end
  end

  defp put_new_value(attrs, key, value) do
    if Map.get(attrs, key) in [nil, ""] do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end
end
