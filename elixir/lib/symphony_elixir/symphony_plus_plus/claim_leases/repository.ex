defmodule SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Repository do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @type repo :: module()
  @type error ::
          atom()
          | {:constraint_failed, String.t()}
          | {:migration_failed, term()}
          | {:storage_failed, String.t()}
          | Changeset.t()

  @id_collision_constraints [
    "sympp_claim_leases_id_index",
    "sympp_claim_leases_pkey",
    "sympp_claim_leases_id_unique_index"
  ]
  @sqlite_primary_key_message "unique constraint failed: sympp_claim_leases.id"
  @terminal_work_package_statuses ["skipped", "merged", "merged_into_phase", "closed", "abandoned"]

  @spec migrate(repo()) :: :ok | {:error, error()}
  def migrate(repo) when is_atom(repo) do
    Ecto.Migrator.run(repo, Migrations.all(), :up, all: true, log: false)
    :ok
  rescue
    error -> {:error, {:migration_failed, error}}
  end

  @spec claim(repo(), map(), keyword()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def claim(repo, attrs, opts \\ []) when is_atom(repo) and is_map(attrs) and is_list(opts) do
    repo.transaction(fn ->
      with {:ok, changeset} <- claim_changeset(repo, attrs, opts),
           {:ok, claim_lease} <- insert_claim(repo, changeset) do
        claim_lease
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, claim_lease} -> {:ok, claim_lease}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec get(repo(), String.t()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(ClaimLease, id) do
      nil -> {:error, :not_found}
      claim_lease -> {:ok, claim_lease}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec current_for_work_package(repo(), String.t()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def current_for_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    query =
      from(claim_lease in ClaimLease,
        where: claim_lease.work_package_id == ^work_package_id,
        where: claim_lease.status in ^ClaimLease.active_statuses(),
        order_by: [desc: claim_lease.inserted_at, desc: claim_lease.lease_started_at, asc: claim_lease.id],
        limit: 1
      )

    case repo.one(query) do
      nil -> {:error, :not_found}
      claim_lease -> {:ok, claim_lease}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec heartbeat(repo(), String.t(), map(), keyword()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def heartbeat(repo, id, attrs \\ %{}, opts \\ []) when is_atom(repo) and is_binary(id) and is_map(attrs) and is_list(opts) do
    now = now(opts)

    with {:ok, %ClaimLease{} = claim_lease} <- get(repo, id),
         :ok <- require_status(claim_lease, ["active"]),
         :ok <- require_not_stale(claim_lease, now, heartbeat_current_stale_after_ms(attrs, opts)) do
      update_claim_lease(
        repo,
        claim_lease,
        attrs
        |> renewal_attrs()
        |> Map.put(:last_seen_at, now),
        ["active"]
      )
    end
  end

  @spec pause(repo(), String.t(), map(), keyword()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def pause(repo, id, attrs, opts \\ []) when is_atom(repo) and is_binary(id) and is_map(attrs) and is_list(opts) do
    now = now(opts)

    with {:ok, %ClaimLease{} = claim_lease} <- get(repo, id),
         :ok <- require_status(claim_lease, ["active"]),
         :ok <- require_not_stale(claim_lease, now) do
      update_claim_lease(
        repo,
        claim_lease,
        attrs
        |> Map.take([:paused_by_actor_id, "paused_by_actor_id", :pause_reason, "pause_reason"])
        |> Map.merge(%{status: "paused", paused_at: now, last_seen_at: now}),
        ["active"]
      )
    end
  end

  @spec release(repo(), String.t(), map(), keyword()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def release(repo, id, attrs \\ %{}, opts \\ []) when is_atom(repo) and is_binary(id) and is_map(attrs) and is_list(opts) do
    now = now(opts)

    with {:ok, %ClaimLease{} = claim_lease} <- get(repo, id),
         :ok <- require_status(claim_lease, ClaimLease.active_statuses()),
         :ok <- require_releasable(claim_lease, now) do
      update_claim_lease(
        repo,
        claim_lease,
        attrs
        |> Map.take([:release_reason, "release_reason"])
        |> Map.merge(%{status: "released", released_at: now, last_seen_at: now}),
        ClaimLease.active_statuses()
      )
    end
  end

  @spec retire_current_for_work_package(repo(), String.t(), String.t(), keyword()) ::
          {:ok, [ClaimLease.t()]} | {:error, error()}
  def retire_current_for_work_package(repo, work_package_id, reason, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and is_binary(reason) and is_list(opts) do
    repo.transaction(fn ->
      case retire_current_for_work_package_transaction(repo, work_package_id, reason, opts) do
        {:ok, claim_leases} -> claim_leases
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, claim_leases} -> {:ok, claim_leases}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp retire_current_for_work_package_transaction(repo, work_package_id, reason, opts) do
    now = now(opts)

    current_query =
      from(claim_lease in ClaimLease,
        where: claim_lease.work_package_id == ^work_package_id,
        where: claim_lease.status in ^ClaimLease.active_statuses(),
        order_by: [asc: claim_lease.inserted_at, asc: claim_lease.id]
      )

    current = repo.all(current_query)
    ids = Enum.map(current, & &1.id)

    if ids == [] do
      {:ok, []}
    else
      update_query =
        from(claim_lease in ClaimLease,
          where: claim_lease.id in ^ids,
          where: claim_lease.status in ^ClaimLease.active_statuses()
        )

      case repo.update_all(update_query,
             set: [
               status: "released",
               released_at: now,
               release_reason: reason,
               last_seen_at: now,
               updated_at: now
             ]
           ) do
        {count, _rows} when count == length(ids) ->
          {:ok,
           repo.all(
             from(claim_lease in ClaimLease,
               where: claim_lease.id in ^ids,
               order_by: [asc: claim_lease.inserted_at, asc: claim_lease.id]
             )
           )}

        {_count, _rows} ->
          {:error, :claim_not_current}
      end
    end
  end

  @spec reclaim_stale(repo(), String.t(), map(), keyword()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def reclaim_stale(repo, work_package_id, attrs, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and is_map(attrs) and is_list(opts) do
    repo.transaction(fn ->
      case reclaim_stale_transaction(repo, work_package_id, attrs, opts) do
        {:ok, claim_lease} -> claim_lease
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, claim_lease} -> {:ok, claim_lease}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp reclaim_stale_transaction(repo, work_package_id, attrs, opts) do
    now = now(opts)
    current_stale_after_ms = Keyword.get(opts, :current_stale_after_ms)
    replacement_opts = opts |> Keyword.put(:now, now) |> Keyword.put(:lineage, :replacement)

    with {:ok, current} <- current_for_work_package(repo, work_package_id),
         :ok <- require_stale(current, now, current_stale_after_ms),
         replacement_attrs = replacement_attrs(current, attrs, now, opts),
         {:ok, replacement_changeset} <- claim_changeset(repo, replacement_attrs, replacement_opts),
         {:ok, _reclaimed} <- reclaim_current(repo, current, attrs, now, current_stale_after_ms) do
      insert_claim(repo, replacement_changeset)
    end
  end

  defp reclaim_current(repo, %ClaimLease{} = current, attrs, now, current_stale_after_ms) do
    actor_id = Map.get(attrs, :actor_id) || Map.get(attrs, "actor_id")
    reason = Map.get(attrs, :reclaim_reason) || Map.get(attrs, "reclaim_reason")

    changeset =
      ClaimLease.update_changeset(current, %{
        status: "reclaimed",
        stale_checked_at: now,
        stale_at: now,
        stale_reason: Map.get(attrs, :stale_reason) || Map.get(attrs, "stale_reason") || reason,
        reclaimed_at: now,
        reclaimed_by_actor_id: actor_id,
        reclaim_reason: reason,
        last_seen_at: now
      })

    if changeset.valid? do
      query = observed_current_query(current, ClaimLease.active_statuses())

      case repo.update_all(query, set: update_changes(changeset)) do
        {1, _rows} -> get(repo, current.id)
        {0, _rows} -> reclaim_conflict_error(repo, current.work_package_id, now, current_stale_after_ms)
      end
    else
      {:error, changeset}
    end
  end

  defp replacement_attrs(%ClaimLease{} = current, attrs, now, opts) do
    attrs
    |> normalize_keys()
    |> maybe_inherit_access_grant(current, opts)
    |> put_inherited_value("stale_after_ms", current.stale_after_ms)
    |> put_inherited_value("lease_expires_at", replacement_lease_expires_at(current, now))
    |> Map.put("work_package_id", current.work_package_id)
    |> Map.put("claim_group_id", current.claim_group_id || current.id)
    |> Map.put("previous_claim_id", current.id)
  end

  defp require_status(%ClaimLease{status: status}, statuses) do
    if status in statuses do
      :ok
    else
      status_error(statuses)
    end
  end

  defp status_error(["active"]), do: {:error, :not_active}
  defp status_error(_statuses), do: {:error, :claim_not_current}

  defp require_stale(%ClaimLease{} = claim_lease, now, current_stale_after_ms) do
    if ClaimLease.stale?(claim_lease, now, current_stale_after_ms), do: :ok, else: {:error, :claim_not_stale}
  end

  defp require_not_stale(%ClaimLease{} = claim_lease, now) do
    require_not_stale(claim_lease, now, nil)
  end

  defp require_not_stale(%ClaimLease{} = claim_lease, now, current_stale_after_ms) do
    if ClaimLease.stale?(claim_lease, now, current_stale_after_ms), do: {:error, :claim_stale}, else: :ok
  end

  defp require_releasable(%ClaimLease{status: "paused"}, _now), do: :ok
  defp require_releasable(%ClaimLease{} = claim_lease, now), do: require_not_stale(claim_lease, now)

  defp update_claim_lease(repo, %ClaimLease{} = claim_lease, attrs, allowed_statuses) do
    changeset = ClaimLease.update_changeset(claim_lease, attrs)

    if changeset.valid? do
      query =
        from(stored in ClaimLease,
          where: stored.id == ^claim_lease.id,
          where: stored.status in ^allowed_statuses
        )

      case repo.update_all(query, set: update_changes(changeset)) do
        {1, _rows} -> get(repo, claim_lease.id)
        {0, _rows} -> status_error(allowed_statuses)
      end
    else
      {:error, changeset}
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp normalize_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp update_changes(%Changeset{} = changeset) do
    changeset.changes
    |> Map.put(:updated_at, Map.get(changeset.changes, :last_seen_at, now([])))
    |> Map.to_list()
  end

  defp observed_current_query(%ClaimLease{} = current, allowed_statuses) do
    query =
      from(stored in ClaimLease,
        where: stored.id == ^current.id,
        where: stored.status in ^allowed_statuses
      )

    Enum.reduce([:last_seen_at, :lease_expires_at, :stale_after_ms], query, fn field_name, query ->
      where_observed(query, field_name, Map.get(current, field_name))
    end)
  end

  defp where_observed(query, field_name, nil), do: from(stored in query, where: is_nil(field(stored, ^field_name)))
  defp where_observed(query, field_name, value), do: from(stored in query, where: field(stored, ^field_name) == ^value)

  defp reclaim_conflict_error(repo, work_package_id, now, current_stale_after_ms) do
    case current_for_work_package(repo, work_package_id) do
      {:ok, %ClaimLease{} = current} ->
        if ClaimLease.stale?(current, now, current_stale_after_ms),
          do: {:error, :claim_not_current},
          else: {:error, :claim_not_stale}

      {:error, :not_found} ->
        {:error, :claim_not_current}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp renewal_attrs(attrs) do
    attrs
    |> Map.take([:lease_expires_at, "lease_expires_at", :stale_after_ms, "stale_after_ms"])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp heartbeat_current_stale_after_ms(attrs, opts) do
    Map.get(attrs, :stale_after_ms) || Map.get(attrs, "stale_after_ms") || Keyword.get(opts, :current_stale_after_ms)
  end

  defp put_inherited_value(attrs, key, value) do
    if blank?(Map.get(attrs, key)) and not is_nil(value) do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  defp maybe_inherit_access_grant(attrs, %ClaimLease{} = current, opts) do
    if Keyword.get(opts, :inherit_access_grant?, true) do
      put_inherited_value(attrs, "access_grant_id", current.access_grant_id)
    else
      attrs
    end
  end

  defp replacement_lease_expires_at(
         %ClaimLease{lease_started_at: %DateTime{} = started_at, lease_expires_at: %DateTime{} = expires_at},
         %DateTime{} = now
       ) do
    case DateTime.diff(expires_at, started_at, :microsecond) do
      duration when duration > 0 -> DateTime.add(now, duration, :microsecond)
      _duration -> expires_at
    end
  end

  defp replacement_lease_expires_at(%ClaimLease{}, %DateTime{}), do: nil

  defp validate_access_grant_scope(_repo, %Changeset{valid?: false} = changeset), do: {:error, changeset}

  defp validate_access_grant_scope(repo, %Changeset{} = changeset) do
    access_grant_id = Changeset.get_field(changeset, :access_grant_id)
    work_package_id = Changeset.get_field(changeset, :work_package_id)

    if blank?(access_grant_id) or blank?(work_package_id) do
      {:ok, changeset}
    else
      case repo.get(AccessGrant, access_grant_id) do
        nil ->
          {:error, Changeset.add_error(changeset, :access_grant_id, "does not exist")}

        %AccessGrant{work_package_id: ^work_package_id} ->
          {:ok, changeset}

        %AccessGrant{} ->
          {:error, Changeset.add_error(changeset, :access_grant_id, "must belong to work package")}
      end
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp claim_changeset(repo, attrs, opts) do
    changeset = ClaimLease.create_changeset(attrs, now: now(opts), lineage: Keyword.get(opts, :lineage))

    with {:ok, changeset} <- validate_access_grant_scope(repo, changeset),
         :ok <- require_live_work_package(repo, Changeset.get_field(changeset, :work_package_id)) do
      {:ok, changeset}
    end
  end

  defp require_live_work_package(repo, work_package_id) do
    case repo.get(WorkPackage, work_package_id) do
      %WorkPackage{status: status} when status in @terminal_work_package_statuses -> {:error, :work_package_terminal}
      %WorkPackage{} -> :ok
      nil -> {:error, :not_found}
    end
  end

  defp insert_claim(repo, %Changeset{} = changeset) do
    changeset
    |> repo.insert()
    |> normalize_insert_result()
  end

  defp normalize_insert_result({:ok, claim_lease}), do: {:ok, claim_lease}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    if active_claim_conflict?(changeset) do
      {:error, :active_claim_exists}
    else
      {:error, changeset}
    end
  end

  defp active_claim_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:work_package_id, {_message, options}} ->
        Keyword.get(options, :constraint_name) in [
          "sympp_claim_leases_one_current_per_work_package_index",
          "sympp_claim_leases_work_package_id_index"
        ] or
          Keyword.get(options, :constraint) == :unique

      _error ->
        false
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_claim_leases_one_current_per_work_package_index"}) do
    {:error, :active_claim_exists}
  end

  # SQLite reports the partial unique index by Ecto's generated column index name.
  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_claim_leases_work_package_id_index"}) do
    {:error, :active_claim_exists}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when constraint in @id_collision_constraints do
    {:error, :id_already_exists}
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

    cond do
      String.contains?(normalized_message, @sqlite_primary_key_message) ->
        {:error, :id_already_exists}

      String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") ->
        {:error, :database_busy}

      true ->
        {:error, {:storage_failed, message}}
    end
  end

  defp now(opts), do: opts |> Keyword.get(:now, DateTime.utc_now(:microsecond)) |> DateTime.truncate(:microsecond)
end
