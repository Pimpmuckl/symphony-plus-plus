defmodule SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry

  @default_current_session_retry_attempts 50
  @default_entry_append_retry_attempts 200
  @archive_after_days 7
  @delete_after_days 14
  @archivable_statuses ["active", "paused", "completed"]
  @solo_session_migrations [
    {20_260_515_150_000, SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppSoloSessions, "20260515150000_create_sympp_solo_sessions.exs"},
    {20_260_515_153_000, SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppSoloSessionEntries, "20260515153000_create_sympp_solo_session_entries.exs"}
  ]

  @type repo :: module()
  @type error ::
          :current_session_conflict
          | :database_busy
          | :id_already_exists
          | :idempotency_key_conflict
          | :invalid_entry_idempotency_key
          | :invalid_status
          | :invalid_transition
          | :invalid_workspace_path
          | :not_found
          | :sequence_conflict
          | :session_not_mutable
          | :stale_status
          | {:constraint_failed, String.t()}
          | {:migration_failed, term()}
          | {:storage_failed, String.t()}
          | Changeset.t()

  @spec migrate(repo()) :: :ok | {:error, error()}
  def migrate(repo) when is_atom(repo) do
    :ok = load_solo_session_migrations()

    migrations = Enum.map(@solo_session_migrations, fn {version, module, _file} -> {version, module} end)
    Ecto.Migrator.run(repo, migrations, :up, all: true, log: false)

    :ok
  rescue
    error -> {:error, {:migration_failed, error}}
  end

  @spec create_or_attach_current(repo(), map()) :: {:ok, SoloSession.t()} | {:error, error()}
  def create_or_attach_current(repo, attrs) when is_atom(repo) and is_map(attrs) do
    with {:ok, attrs} <- normalize_session_attrs(attrs) do
      do_create_or_attach_current(repo, attrs, current_session_retry_attempts())
    end
  end

  @spec get(repo(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(SoloSession, id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list(repo()) :: {:ok, [SoloSession.t()]} | {:error, error()}
  @spec list(repo(), map()) :: {:ok, [SoloSession.t()]} | {:error, error()}
  def list(repo, filters \\ %{}) when is_atom(repo) and is_map(filters) do
    with {:ok, filters} <- normalize_session_filters(filters) do
      sessions =
        filters
        |> list_query()
        |> repo.all()

      {:ok, sessions}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec update_status(repo(), String.t(), String.t(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def update_status(repo, id, current_status, next_status)
      when is_atom(repo) and is_binary(id) and is_binary(current_status) and is_binary(next_status) do
    current_status = String.trim(current_status)
    next_status = String.trim(next_status)

    with :ok <- validate_status(current_status),
         :ok <- validate_status(next_status),
         :ok <- validate_transition(current_status, next_status) do
      update_valid_status(repo, id, current_status, next_status)
    end
  end

  @spec archive_stale(repo()) :: {:ok, non_neg_integer()} | {:error, error()}
  def archive_stale(repo) when is_atom(repo) do
    archive_stale(repo, DateTime.utc_now(:microsecond))
  end

  @spec archive_stale(repo(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, error()}
  def archive_stale(repo, %DateTime{} = now) when is_atom(repo) do
    cutoff = DateTime.add(now, -@archive_after_days * 24 * 60 * 60, :second)

    {count, _rows} =
      repo.update_all(
        from(session in SoloSession,
          where: session.status in ^@archivable_statuses,
          where: session.last_activity_at <= ^cutoff
        ),
        set: [status: "archived", archived_at: now, updated_at: now]
      )

    {:ok, count}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec delete_archived(repo()) :: {:ok, non_neg_integer()} | {:error, error()}
  def delete_archived(repo) when is_atom(repo) do
    delete_archived(repo, DateTime.utc_now(:microsecond))
  end

  @spec delete_archived(repo(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, error()}
  def delete_archived(repo, %DateTime{} = now) when is_atom(repo) do
    cutoff = DateTime.add(now, -@delete_after_days * 24 * 60 * 60, :second)

    repo.transaction(fn ->
      archived_ids =
        repo.all(
          from(session in SoloSession,
            where: session.status == "archived",
            where: session.last_activity_at <= ^cutoff,
            select: session.id
          )
        )

      if archived_ids == [] do
        0
      else
        repo.delete_all(from(entry in SoloSessionEntry, where: entry.solo_session_id in ^archived_ids))

        {count, _rows} =
          repo.delete_all(
            from(session in SoloSession,
              where: session.id in ^archived_ids
            )
          )

        count
      end
    end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec append_entry(repo(), String.t(), map()) :: {:ok, SoloSessionEntry.t()} | {:error, error()}
  def append_entry(repo, solo_session_id, attrs) when is_atom(repo) and is_binary(solo_session_id) and is_map(attrs) do
    with {:ok, attrs} <- normalize_entry_attrs(attrs) do
      do_append_entry(repo, solo_session_id, attrs, entry_append_retry_attempts())
    end
  end

  @spec get_entry(repo(), String.t(), String.t()) :: {:ok, SoloSessionEntry.t()} | {:error, error()}
  def get_entry(repo, solo_session_id, entry_id)
      when is_atom(repo) and is_binary(solo_session_id) and is_binary(entry_id) do
    case repo.one(entry_by_id_query(solo_session_id, entry_id)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_entries(repo(), String.t()) :: {:ok, [SoloSessionEntry.t()]} | {:error, error()}
  def list_entries(repo, solo_session_id) when is_atom(repo) and is_binary(solo_session_id) do
    entries =
      repo.all(
        from(entry in SoloSessionEntry,
          where: entry.solo_session_id == ^solo_session_id,
          order_by: [asc: entry.sequence, asc: entry.id]
        )
      )

    {:ok, entries}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp do_append_entry(repo, solo_session_id, attrs, attempts_left) do
    repo
    |> append_entry_transaction(solo_session_id, attrs)
    |> handle_append_entry_result(repo, solo_session_id, attrs, attempts_left)
  end

  defp append_entry_transaction(repo, solo_session_id, attrs) do
    repo.transaction(fn ->
      case append_entry_in_transaction(repo, solo_session_id, attrs) do
        {:ok, entry} -> entry
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp append_entry_in_transaction(repo, solo_session_id, attrs) do
    with :not_found <- existing_entry_by_idempotency_key(repo, solo_session_id, attrs),
         :ok <- ensure_mutable_session(repo, solo_session_id),
         :ok <- touch_mutable_session(repo, solo_session_id),
         sequence <- next_entry_sequence(repo, solo_session_id),
         {:ok, entry} <- insert_entry(repo, solo_session_id, attrs, sequence) do
      {:ok, entry}
    else
      {:ok, %SoloSessionEntry{} = entry} -> {:ok, entry}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_append_entry_result({:ok, entry}, _repo, _solo_session_id, _attrs, _attempts_left), do: {:ok, entry}

  defp handle_append_entry_result({:error, :idempotency_key_conflict}, repo, solo_session_id, attrs, attempts_left) do
    replay_entry_after_idempotency_conflict(repo, solo_session_id, attrs, attempts_left)
  end

  defp handle_append_entry_result({:error, :session_not_mutable}, repo, solo_session_id, attrs, attempts_left) do
    replay_entry_after_session_not_mutable(repo, solo_session_id, attrs, attempts_left)
  end

  defp handle_append_entry_result({:error, reason}, repo, solo_session_id, attrs, attempts_left)
       when reason in [:database_busy, :sequence_conflict] do
    retry_append_entry_or_error(repo, solo_session_id, attrs, attempts_left, reason)
  end

  defp handle_append_entry_result({:error, reason}, _repo, _solo_session_id, _attrs, _attempts_left), do: {:error, reason}

  defp replay_entry_after_idempotency_conflict(repo, solo_session_id, attrs, attempts_left) do
    case existing_entry_by_idempotency_key(repo, solo_session_id, attrs) do
      {:ok, entry} ->
        {:ok, entry}

      {:error, :database_busy} ->
        retry_append_entry_or_error(repo, solo_session_id, attrs, attempts_left, :database_busy)

      _result ->
        retry_append_entry_or_error(repo, solo_session_id, attrs, attempts_left, :idempotency_key_conflict)
    end
  end

  defp replay_entry_after_session_not_mutable(repo, solo_session_id, attrs, attempts_left) do
    case existing_entry_by_idempotency_key(repo, solo_session_id, attrs) do
      {:ok, entry} ->
        {:ok, entry}

      {:error, :database_busy} ->
        retry_append_entry_or_error(repo, solo_session_id, attrs, attempts_left, :database_busy)

      _result ->
        {:error, :session_not_mutable}
    end
  end

  defp retry_append_entry_or_error(_repo, _solo_session_id, _attrs, 0, terminal_error), do: {:error, terminal_error}

  defp retry_append_entry_or_error(repo, solo_session_id, attrs, attempts_left, _terminal_error) do
    Process.sleep(retry_delay_ms(attempts_left, entry_append_retry_attempts()))
    do_append_entry(repo, solo_session_id, attrs, attempts_left - 1)
  end

  defp ensure_mutable_session(repo, solo_session_id) do
    case get(repo, solo_session_id) do
      {:ok, %SoloSession{status: status}} when status in ["active", "paused"] -> :ok
      {:ok, %SoloSession{}} -> {:error, :session_not_mutable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp touch_mutable_session(repo, solo_session_id) do
    now = DateTime.utc_now(:microsecond)

    solo_session_id
    |> current_session_update_query()
    |> repo.update_all(set: [last_activity_at: now, updated_at: now])
    |> case do
      {1, _rows} -> :ok
      {0, _rows} -> mutable_session_error(repo, solo_session_id)
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp mutable_session_error(repo, solo_session_id) do
    case get(repo, solo_session_id) do
      {:ok, %SoloSession{}} -> {:error, :session_not_mutable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_entry(repo, solo_session_id, attrs, sequence) do
    attrs
    |> SoloSessionEntry.create_changeset(solo_session_id: solo_session_id, sequence: sequence)
    |> repo.insert()
    |> normalize_entry_insert_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp next_entry_sequence(repo, solo_session_id) do
    current_max =
      repo.one(
        from(entry in SoloSessionEntry,
          where: entry.solo_session_id == ^solo_session_id,
          select: max(entry.sequence)
        )
      )

    (current_max || 0) + 1
  end

  defp existing_entry_by_idempotency_key(_repo, _solo_session_id, %{"idempotency_key" => nil}), do: :not_found
  defp existing_entry_by_idempotency_key(_repo, _solo_session_id, attrs) when not is_map_key(attrs, "idempotency_key"), do: :not_found

  defp existing_entry_by_idempotency_key(repo, solo_session_id, %{"idempotency_key" => idempotency_key})
       when is_binary(idempotency_key) do
    case repo.one(entry_by_idempotency_key_query(solo_session_id, idempotency_key)) do
      nil -> :not_found
      entry -> {:ok, entry}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp entry_by_id_query(solo_session_id, entry_id) do
    from(entry in SoloSessionEntry,
      where: entry.solo_session_id == ^solo_session_id,
      where: entry.id == ^entry_id,
      limit: 1
    )
  end

  defp entry_by_idempotency_key_query(solo_session_id, idempotency_key) do
    from(entry in SoloSessionEntry,
      where: entry.solo_session_id == ^solo_session_id,
      where: entry.idempotency_key == ^idempotency_key,
      limit: 1
    )
  end

  defp do_create_or_attach_current(repo, attrs, attempts_left) do
    repo
    |> create_or_attach_current_transaction(attrs)
    |> handle_create_or_attach_result(repo, attrs, attempts_left)
  end

  defp create_or_attach_current_transaction(repo, attrs) do
    repo.transaction(fn ->
      case current_or_insert_session(repo, attrs) do
        {:ok, session} -> session
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp handle_create_or_attach_result({:ok, session}, _repo, _attrs, _attempts_left), do: {:ok, session}

  defp handle_create_or_attach_result({:error, reason}, repo, attrs, attempts_left)
       when reason in [:current_session_conflict, :database_busy] do
    retry_create_or_attach_or_error(repo, attrs, attempts_left, reason)
  end

  defp handle_create_or_attach_result({:error, reason}, _repo, _attrs, _attempts_left), do: {:error, reason}

  defp retry_create_or_attach_or_error(_repo, _attrs, 0, terminal_error), do: {:error, terminal_error}

  defp retry_create_or_attach_or_error(repo, attrs, attempts_left, _terminal_error) do
    Process.sleep(retry_delay_ms(attempts_left, current_session_retry_attempts()))
    do_create_or_attach_current(repo, attrs, attempts_left - 1)
  end

  defp current_or_insert_session(repo, attrs) do
    case current_by_scope(repo, attrs) do
      %SoloSession{} = session -> touch_current_session(repo, session)
      nil -> insert_current_session(repo, attrs)
    end
  end

  defp current_by_scope(repo, attrs) do
    with repo_name when is_binary(repo_name) <- Map.get(attrs, "repo"),
         base_branch when is_binary(base_branch) <- Map.get(attrs, "base_branch"),
         workspace_path when is_binary(workspace_path) <- Map.get(attrs, "workspace_path"),
         caller_id when is_binary(caller_id) <- Map.get(attrs, "caller_id") do
      repo.one(
        from(session in SoloSession,
          where: session.repo == ^repo_name,
          where: session.base_branch == ^base_branch,
          where: session.workspace_path == ^workspace_path,
          where: session.caller_id == ^caller_id,
          where: session.status in ^SoloSession.current_statuses(),
          order_by: [desc: session.last_activity_at, desc: session.inserted_at, desc: session.id],
          limit: 1
        )
      )
    else
      _value -> nil
    end
  end

  defp touch_current_session(repo, %SoloSession{id: id}) do
    now = DateTime.utc_now(:microsecond)

    id
    |> current_session_update_query()
    |> repo.update_all(set: [last_activity_at: now, updated_at: now])
    |> case do
      {1, _rows} -> {:ok, repo.get!(SoloSession, id)}
      {0, _rows} -> {:error, current_session_stale_error(repo, id)}
    end
  end

  defp insert_current_session(repo, attrs) do
    attrs
    |> SoloSession.create_changeset()
    |> repo.insert()
    |> normalize_session_insert_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp update_valid_status(repo, id, current_status, next_status) do
    now = DateTime.utc_now(:microsecond)

    updates = [
      status: next_status,
      last_activity_at: now,
      updated_at: now
    ]

    updates =
      if next_status == "archived" do
        Keyword.put(updates, :archived_at, now)
      else
        updates
      end

    repo.transaction(fn ->
      id
      |> status_update_query(current_status)
      |> repo.update_all(set: updates)
      |> case do
        {1, _rows} -> repo.get!(SoloSession, id)
        {0, _rows} -> repo.rollback(stale_status_error(repo, id, current_status))
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp validate_status(status) do
    if status in SoloSession.statuses() do
      :ok
    else
      {:error, :invalid_status}
    end
  end

  defp validate_transition(status, status), do: {:error, :invalid_transition}
  defp validate_transition("active", next_status) when next_status in ["paused", "completed", "archived"], do: :ok
  defp validate_transition("paused", next_status) when next_status in ["active", "completed", "archived"], do: :ok
  defp validate_transition("completed", "archived"), do: :ok
  defp validate_transition(_current_status, _next_status), do: {:error, :invalid_transition}

  defp current_session_update_query(id) do
    from(session in SoloSession,
      where: session.id == ^id,
      where: session.status in ^SoloSession.current_statuses()
    )
  end

  defp status_update_query(id, current_status) do
    from(session in SoloSession,
      where: session.id == ^id,
      where: session.status == ^current_status
    )
  end

  defp list_query(filters) do
    base_query =
      from(session in SoloSession,
        order_by: [desc: session.last_activity_at, desc: session.inserted_at, asc: session.id]
      )

    Enum.reduce(filters, base_query, fn
      {"repo", repo_name}, query when is_binary(repo_name) and repo_name != "" ->
        from(session in query, where: session.repo == ^repo_name)

      {"base_branch", base_branch}, query when is_binary(base_branch) and base_branch != "" ->
        from(session in query, where: session.base_branch == ^base_branch)

      {"workspace_path", workspace_path}, query when is_binary(workspace_path) and workspace_path != "" ->
        from(session in query, where: session.workspace_path == ^workspace_path)

      {"caller_id", caller_id}, query when is_binary(caller_id) and caller_id != "" ->
        from(session in query, where: session.caller_id == ^caller_id)

      {"status", status}, query when is_binary(status) and status != "" ->
        from(session in query, where: session.status == ^status)

      _filter, query ->
        query
    end)
  end

  defp current_session_stale_error(repo, id) do
    case get(repo, id) do
      {:ok, %SoloSession{}} -> :current_session_conflict
      {:error, reason} -> reason
    end
  end

  defp stale_status_error(repo, id, current_status) do
    case get(repo, id) do
      {:ok, %SoloSession{status: status}} when status != current_status -> :stale_status
      {:ok, %SoloSession{}} -> :stale_status
      {:error, reason} -> reason
    end
  end

  defp normalize_session_insert_result({:ok, session}), do: {:ok, session}

  defp normalize_session_insert_result({:error, %Changeset{} = changeset}) do
    cond do
      changeset_constraint_error?(changeset, :id, :unique) -> {:error, :id_already_exists}
      changeset_constraint_error?(changeset, :repo, :unique) -> {:error, :current_session_conflict}
      true -> {:error, changeset}
    end
  end

  defp normalize_entry_insert_result({:ok, entry}), do: {:ok, entry}

  defp normalize_entry_insert_result({:error, %Changeset{} = changeset}) do
    cond do
      changeset_constraint_error?(changeset, :id, :unique) -> {:error, :id_already_exists}
      changeset_constraint_error?(changeset, :sequence, :unique) -> {:error, :sequence_conflict}
      changeset_constraint_error?(changeset, :idempotency_key, :unique) -> {:error, :idempotency_key_conflict}
      true -> {:error, changeset}
    end
  end

  defp changeset_constraint_error?(changeset, field, constraint) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, options}} -> Keyword.get(options, :constraint) == constraint
      _error -> false
    end)
  end

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    cond do
      entry_idempotency_constraint?(constraint) -> {:error, :idempotency_key_conflict}
      entry_sequence_constraint?(constraint) -> {:error, :sequence_conflict}
      solo_session_entry_id_constraint?(constraint) -> {:error, :id_already_exists}
      solo_session_id_constraint?(constraint) -> {:error, :id_already_exists}
      current_scope_constraint?(constraint) -> {:error, :current_session_conflict}
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

      entry_idempotency_constraint?(message) ->
        {:error, :idempotency_key_conflict}

      entry_sequence_constraint?(message) ->
        {:error, :sequence_conflict}

      solo_session_entry_id_constraint?(message) ->
        {:error, :id_already_exists}

      current_scope_constraint?(message) ->
        {:error, :current_session_conflict}

      solo_session_id_constraint?(message) ->
        {:error, :id_already_exists}

      true ->
        {:error, {:storage_failed, message}}
    end
  end

  defp solo_session_id_constraint?(constraint) do
    constraint in ["sympp_solo_sessions_id_unique_index", "sympp_solo_sessions_id_index"] or
      (String.contains?(constraint, "sympp_solo_sessions") and String.contains?(constraint, ".id"))
  end

  defp current_scope_constraint?(constraint) do
    constraint in [
      "sympp_solo_sessions_current_scope_unique_index",
      "sympp_solo_sessions_repo_base_branch_workspace_path_caller_id_index"
    ] or
      (String.contains?(constraint, "sympp_solo_sessions") and String.contains?(constraint, ".repo") and
         String.contains?(constraint, ".base_branch") and String.contains?(constraint, ".workspace_path") and
         String.contains?(constraint, ".caller_id"))
  end

  defp solo_session_entry_id_constraint?(constraint) do
    constraint in ["sympp_solo_session_entries_id_unique_index", "sympp_solo_session_entries_id_index"] or
      (String.contains?(constraint, "sympp_solo_session_entries") and String.contains?(constraint, ".id"))
  end

  defp entry_sequence_constraint?(constraint) do
    constraint == "sympp_solo_session_entries_session_sequence_unique_index" or
      (String.contains?(constraint, "sympp_solo_session_entries") and String.contains?(constraint, ".sequence")) or
      (String.contains?(constraint, "sympp_solo_session_entries") and String.contains?(constraint, "sequence"))
  end

  defp entry_idempotency_constraint?(constraint) do
    constraint == "sympp_solo_session_entries_session_idempotency_key_unique_index" or
      (String.contains?(constraint, "sympp_solo_session_entries") and String.contains?(constraint, "idempotency_key"))
  end

  defp normalize_entry_attrs(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> trim_text_fields(["entry_kind", "title", "body", "status", "idempotency_key"])
      |> normalize_entry_idempotency_key()

    case Map.get(attrs, "idempotency_key") do
      value when is_binary(value) ->
        if secret_like_text?(value), do: {:error, :invalid_entry_idempotency_key}, else: {:ok, attrs}

      nil ->
        {:ok, attrs}

      _value ->
        {:error, :invalid_entry_idempotency_key}
    end
  end

  defp normalize_entry_idempotency_key(attrs) do
    Map.update(attrs, "idempotency_key", nil, fn
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end)
  end

  defp secret_like_text?(value) when is_binary(value), do: Redactor.redact_text(value) != value

  defp normalize_session_attrs(attrs) do
    attrs
    |> normalize_keys()
    |> trim_text_fields(["repo", "base_branch", "caller_id", "title"])
    |> normalize_workspace_path()
  end

  defp normalize_session_filters(filters) do
    filters
    |> normalize_keys()
    |> trim_text_fields(["repo", "base_branch", "caller_id", "status"])
    |> normalize_workspace_path()
  end

  defp normalize_workspace_path(attrs) do
    case Map.fetch(attrs, "workspace_path") do
      {:ok, workspace_path} ->
        with {:ok, workspace_path} <- canonical_workspace_path(workspace_path) do
          {:ok, Map.put(attrs, "workspace_path", workspace_path)}
        end

      :error ->
        {:ok, attrs}
    end
  end

  defp canonical_workspace_path(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:ok, value}

      Path.type(value) != :absolute ->
        {:error, :invalid_workspace_path}

      true ->
        workspace_path =
          value
          |> Path.expand()
          |> canonicalize_existing_segments()
          |> normalize_host_path_key()

        {:ok, workspace_path}
    end
  end

  defp canonical_workspace_path(value), do: {:ok, value}

  defp load_solo_session_migrations do
    Enum.each(@solo_session_migrations, fn {_version, module, file} ->
      unless Code.ensure_loaded?(module) do
        file
        |> solo_session_migration_file()
        |> Code.compile_file()
      end
    end)

    :ok
  end

  defp solo_session_migration_file(file) do
    Path.join(migrations_path(), file)
  end

  defp canonicalize_existing_segments(path) do
    case PathSafety.canonicalize(path) do
      {:ok, canonical_path} -> canonical_path
      {:error, _reason} -> path
    end
  end

  defp normalize_host_path_key(path) do
    case :os.type() do
      {:win32, _name} ->
        path
        |> String.replace("\\", "/")
        |> String.downcase()

      _type ->
        path
    end
  end

  defp trim_text_fields(attrs, fields) do
    Enum.reduce(fields, attrs, fn field, acc ->
      Map.update(acc, field, nil, &trim_text/1)
    end)
  end

  defp trim_text(value) when is_binary(value), do: String.trim(value)
  defp trim_text(value), do: value

  defp retry_delay_ms(attempts_left, total_attempts) do
    used_attempts = max(total_attempts - attempts_left, 0)
    min(100, 5 + used_attempts * 5)
  end

  defp current_session_retry_attempts do
    :symphony_elixir
    |> Application.get_env(:sympp_solo_session_current_retry_attempts, @default_current_session_retry_attempts)
    |> max(0)
  end

  defp entry_append_retry_attempts do
    :symphony_elixir
    |> Application.get_env(:sympp_solo_session_entry_retry_attempts, @default_entry_append_retry_attempts)
    |> max(0)
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  @doc false
  @spec migrations_path() :: Path.t()
  def migrations_path do
    Application.app_dir(:symphony_elixir, "priv/symphony_plus_plus/repo/migrations")
  end
end
