defmodule SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.GrantScope
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope, as: AuthScope
  alias SymphonyElixir.SymphonyPlusPlus.BaseBranch
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository

  # Mirrors ArchitectHandoff deterministic IDs without adding a reverse module dependency from AccessGrants.
  @architect_handoff_anchor_id_prefix "SYMPP-WR-ARCH-"
  @architect_handoff_phase_id_prefix "phase-wr-architect-"
  @architect_handoff_anchor_kind "delegation"

  @type repo :: module()

  @type error ::
          :already_claimed
          | :architect_grant_required
          | :database_busy
          | :display_key_only
          | :expired
          | :id_already_exists
          | :invalid_scope
          | :invalid_secret
          | :missing_claim_identity
          | :not_found
          | :revoked
          | :worker_grant_required
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

  @spec create(repo(), map(), keyword()) :: {:ok, AccessGrant.t()} | {:error, error()}
  def create(repo, attrs, opts \\ []) when is_atom(repo) and is_map(attrs) and is_list(opts) do
    changeset = AccessGrant.create_changeset(attrs)

    with {:ok, changeset} <- validate_architect_phase_anchor(repo, changeset) do
      repo.transaction(fn -> create_in_transaction(repo, changeset, attrs, opts) end)
      |> normalize_transaction_result()
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp insert_grant_with_scopes(repo, changeset, attrs) do
    with {:ok, grant} <- changeset |> repo.insert() |> normalize_insert_result(),
         {:ok, _scopes} <- ensure_grant_scopes(repo, grant, attrs) do
      grant
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp create_in_transaction(repo, changeset, attrs, opts) do
    case reject_terminal_worker_package(repo, changeset, opts) do
      :ok -> insert_grant_with_scopes(repo, changeset, attrs)
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp reject_terminal_worker_package(repo, changeset, opts) do
    terminal_statuses = Keyword.get(opts, :terminal_work_package_statuses, [])
    work_package_id = Changeset.get_field(changeset, :work_package_id)
    grant_role = Changeset.get_field(changeset, :grant_role)

    reject_terminal_worker_package(repo, grant_role, work_package_id, terminal_statuses)
  end

  defp reject_terminal_worker_package(repo, "worker", work_package_id, [_status | _statuses] = terminal_statuses)
       when is_binary(work_package_id) do
    case repo.get(WorkPackage, work_package_id) do
      %WorkPackage{status: status} ->
        with :ok <- terminal_worker_package_status(status, terminal_statuses) do
          reject_terminal_worker_delivery(repo, work_package_id)
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp reject_terminal_worker_package(_repo, _grant_role, _work_package_id, _terminal_statuses), do: :ok

  defp terminal_worker_package_status(status, terminal_statuses) do
    if status in terminal_statuses, do: {:error, :work_package_terminal}, else: :ok
  end

  defp reject_terminal_worker_delivery(repo, work_package_id) do
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

  @spec get(repo(), String.t()) :: {:ok, AccessGrant.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(AccessGrant, id) do
      nil -> {:error, :not_found}
      access_grant -> {:ok, access_grant}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_for_work_package(repo(), String.t()) :: {:ok, [AccessGrant.t()]} | {:error, error()}
  def list_for_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    grants =
      repo.all(
        from(access_grant in AccessGrant,
          where: access_grant.work_package_id == ^work_package_id,
          order_by: [asc: access_grant.inserted_at, asc: access_grant.id]
        )
      )

    {:ok, grants}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_for_phase(repo(), String.t()) :: {:ok, [AccessGrant.t()]} | {:error, error()}
  def list_for_phase(repo, phase_id) when is_atom(repo) and is_binary(phase_id) do
    grants =
      repo.all(
        from(access_grant in AccessGrant,
          where: access_grant.phase_id == ^phase_id,
          order_by: [asc: access_grant.inserted_at, asc: access_grant.id]
        )
      )

    {:ok, grants}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec find_by_secret_hash(repo(), String.t()) :: {:ok, AccessGrant.t()} | {:error, error()}
  def find_by_secret_hash(repo, secret_hash) when is_atom(repo) and is_binary(secret_hash) do
    query = from(access_grant in AccessGrant, where: access_grant.secret_hash == ^secret_hash, limit: 1)

    case repo.one(query) do
      nil -> {:error, :invalid_secret}
      access_grant -> {:ok, access_grant}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_scopes(repo(), String.t()) :: {:ok, [GrantScope.t()]} | {:error, error()}
  def list_scopes(repo, access_grant_id) when is_atom(repo) and is_binary(access_grant_id) do
    scopes =
      repo.all(
        from(scope in GrantScope,
          where: scope.access_grant_id == ^access_grant_id,
          order_by: [asc: scope.inserted_at, asc: scope.id]
        )
      )

    {:ok, scopes}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec ensure_grant_scopes(repo(), AccessGrant.t(), map()) :: {:ok, [AuthScope.t()]} | {:error, error()}
  def ensure_grant_scopes(repo, %AccessGrant{} = access_grant, attrs \\ %{}) when is_atom(repo) and is_map(attrs) do
    with :ok <- ensure_scope_rows(repo, access_grant, attrs),
         {:ok, scope_rows} <- list_scopes(repo, access_grant.id) do
      {:ok, Enum.map(scope_rows, &GrantScope.to_authorization_scope/1)}
    end
  end

  @spec claim(repo(), String.t(), map(), DateTime.t()) :: {:ok, Assignment.t()} | {:error, error()}
  def claim(repo, secret, attrs, now)
      when is_atom(repo) and is_binary(secret) and is_map(attrs) and is_struct(now, DateTime) do
    claim(repo, secret, attrs, now, [])
  end

  @spec claim(repo(), String.t(), map(), DateTime.t(), keyword()) :: {:ok, Assignment.t()} | {:error, error()}
  def claim(repo, secret, attrs, now, opts)
      when is_atom(repo) and is_binary(secret) and is_map(attrs) and is_struct(now, DateTime) and is_list(opts) do
    normalized_now = DateTime.truncate(now, :microsecond)
    secret_hash = WorkKey.secret_hash(secret)
    terminal_statuses = Keyword.get(opts, :terminal_work_package_statuses, [])

    with :ok <- reject_display_key_only(secret),
         {:ok, access_grant} <- find_by_secret_hash(repo, secret_hash),
         true <- secure_equal?(secret_hash, access_grant.secret_hash),
         :ok <- claimable?(access_grant, normalized_now),
         {:ok, claimed_by} <- claimed_by(attrs),
         {:ok, claimed} <- persist_claim(repo, access_grant, claimed_by, normalized_now, terminal_statuses) do
      assignment(repo, claimed)
    else
      false -> {:error, :invalid_secret}
      {:error, _reason} = error -> error
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec claim_local_worker_grant(repo(), String.t(), map(), DateTime.t(), keyword()) ::
          {:ok, AccessGrant.t()} | {:error, error()}
  def claim_local_worker_grant(repo, work_package_id, attrs, now, opts)
      when is_atom(repo) and is_binary(work_package_id) and is_map(attrs) and is_struct(now, DateTime) and
             is_list(opts) do
    normalized_now = DateTime.truncate(now, :microsecond)
    terminal_statuses = Keyword.get(opts, :terminal_work_package_statuses, [])

    with {:ok, claimed_by} <- claimed_by(attrs),
         :ok <- reject_other_local_claim_owner(repo, work_package_id, claimed_by, normalized_now, terminal_statuses) do
      reconnect_or_claim_local_worker_grant(repo, work_package_id, claimed_by, normalized_now, terminal_statuses)
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec claim_local_architect_grant(repo(), String.t(), String.t(), map(), DateTime.t(), keyword()) ::
          {:ok, AccessGrant.t()} | {:error, error()}
  def claim_local_architect_grant(repo, work_package_id, phase_id, attrs, now, opts)
      when is_atom(repo) and is_binary(work_package_id) and is_binary(phase_id) and is_map(attrs) and
             is_struct(now, DateTime) and is_list(opts) do
    normalized_now = DateTime.truncate(now, :microsecond)
    terminal_statuses = Keyword.get(opts, :terminal_work_package_statuses, [])

    with {:ok, claimed_by} <- claimed_by(attrs),
         {:ok, scope_repo} <- claim_scope(attrs, :scope_repo),
         {:ok, scope_base_branch} <- claim_scope(attrs, :scope_base_branch),
         :ok <-
           reject_other_local_architect_claim_owner(
             repo,
             work_package_id,
             phase_id,
             scope_repo,
             scope_base_branch,
             claimed_by,
             normalized_now,
             terminal_statuses
           ) do
      context = %{
        work_package_id: work_package_id,
        phase_id: phase_id,
        scope_repo: scope_repo,
        scope_base_branch: scope_base_branch,
        claimed_by: claimed_by,
        now: normalized_now,
        terminal_statuses: terminal_statuses
      }

      reconnect_or_claim_local_architect_grant(
        repo,
        context,
        attrs
      )
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec revoke(repo(), String.t(), DateTime.t()) :: {:ok, AccessGrant.t()} | {:error, error()}
  def revoke(repo, id, now) when is_atom(repo) and is_binary(id) and is_struct(now, DateTime) do
    with {:ok, access_grant} <- get(repo, id) do
      access_grant
      |> AccessGrant.revoke_changeset(now)
      |> repo.update()
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec validate_work_package(repo(), String.t()) :: :ok | {:error, error()}
  def validate_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, _work_package} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec work_package_authority_state(repo(), String.t()) ::
          {:ok, %{status: String.t(), delivered?: boolean()}} | {:error, error()}
  def work_package_authority_state(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    case repo.one(
           from(work_package in WorkPackage,
             left_join: delivery in WorkPackageDelivery,
             on: delivery.work_package_id == work_package.id,
             where: work_package.id == ^work_package_id,
             select: %{status: work_package.status, delivered?: not is_nil(delivery.id)},
             limit: 1
           )
         ) do
      nil -> {:error, :not_found}
      state -> {:ok, state}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec validate_phase(repo(), String.t()) :: :ok | {:error, error()}
  def validate_phase(repo, phase_id) when is_atom(repo) and is_binary(phase_id) do
    case PhaseRepository.get(repo, phase_id) do
      {:ok, _phase} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_display_key_only(secret) do
    if String.length(secret) == 4 do
      {:error, :display_key_only}
    else
      :ok
    end
  end

  defp claimable?(%AccessGrant{revoked_at: %DateTime{}}, _now), do: {:error, :revoked}
  defp claimable?(%AccessGrant{claimed_at: %DateTime{}}, _now), do: {:error, :already_claimed}
  defp claimable?(%AccessGrant{expires_at: nil}, _now), do: :ok

  defp claimable?(%AccessGrant{expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt do
      :ok
    else
      {:error, :expired}
    end
  end

  defp persist_claim(repo, access_grant, claimed_by, now, terminal_statuses, attrs \\ %{}) do
    query =
      from(grant in AccessGrant,
        where:
          grant.id == ^access_grant.id and is_nil(grant.claimed_at) and is_nil(grant.revoked_at) and
            (is_nil(grant.expires_at) or grant.expires_at > ^now)
      )
      |> scope_live_package_authority(terminal_statuses)

    repo.transaction(fn ->
      case repo.update_all(query, set: [claimed_at: now, claimed_by: claimed_by, updated_at: now]) do
        {1, _rows} ->
          repo
          |> get(access_grant.id)
          |> clear_completion_after_grant(repo)
          |> ensure_grant_scopes_and_return(repo, attrs)
          |> return_claim_or_rollback(repo)

        {0, _rows} ->
          repo
          |> reload_claim_error(access_grant.id, now, terminal_statuses)
          |> rollback_claim_error(repo)
      end
    end)
    |> case do
      {:ok, grant} -> {:ok, grant}
      {:error, reason} -> {:error, reason}
    end
  end

  defp return_claim_or_rollback({:ok, %AccessGrant{} = grant}, _repo), do: grant
  defp return_claim_or_rollback({:error, reason}, repo), do: repo.rollback(reason)

  defp rollback_claim_error({:error, reason}, repo), do: repo.rollback(reason)

  defp clear_completion_after_grant({:ok, %AccessGrant{work_package_id: work_package_id} = grant}, repo)
       when is_binary(work_package_id) do
    case WorkRequestRepository.clear_completion_for_work_package(repo, work_package_id) do
      :ok -> {:ok, grant}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_completion_after_grant(result, _repo), do: result

  defp scope_live_package_authority(query, []), do: query

  defp scope_live_package_authority(query, terminal_statuses) do
    terminal_package_ids =
      from(work_package in WorkPackage,
        where: work_package.status in ^terminal_statuses,
        select: work_package.id
      )

    delivered_package_ids =
      from(delivery in WorkPackageDelivery,
        select: delivery.work_package_id
      )

    from(grant in query,
      where:
        is_nil(grant.work_package_id) or
          (grant.work_package_id not in subquery(terminal_package_ids) and
             grant.work_package_id not in subquery(delivered_package_ids))
    )
  end

  defp local_worker_grant_missing_reason(repo, work_package_id, terminal_statuses) do
    case terminal_work_package?(repo, work_package_id, terminal_statuses) do
      {:ok, true} -> {:error, :work_package_terminal}
      {:ok, false} -> {:error, inactive_worker_grant_reason(repo, work_package_id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp terminal_work_package?(_repo, _work_package_id, []), do: {:ok, false}

  defp terminal_work_package?(repo, work_package_id, terminal_statuses) do
    case work_package_authority_state(repo, work_package_id) do
      {:ok, %{status: status, delivered?: delivered?}} -> {:ok, delivered? or status in terminal_statuses}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inactive_worker_grant_reason(repo, work_package_id) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.grant_role == "worker",
        select: {count(grant.id), count(grant.revoked_at)}
      )

    case repo.one(query) do
      {0, _revoked_count} -> :worker_grant_required
      {grant_count, grant_count} -> :revoked
      {_grant_count, _revoked_count} -> :expired
    end
  end

  defp reject_other_local_claim_owner(repo, work_package_id, claimed_by, now, terminal_statuses) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.grant_role == "worker",
        where: not is_nil(grant.claimed_at),
        where: grant.claimed_by != ^claimed_by,
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        select: 1,
        limit: 1
      )
      |> scope_live_package_authority(terminal_statuses)

    case repo.one(query) do
      nil -> :ok
      1 -> {:error, :already_claimed}
    end
  end

  defp reject_other_local_architect_claim_owner(
         repo,
         work_package_id,
         phase_id,
         scope_repo,
         scope_base_branch,
         claimed_by,
         now,
         terminal_statuses
       ) do
    scope_base_branches = BaseBranch.equivalent_refs(scope_base_branch)

    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.phase_id == ^phase_id,
        where: grant.grant_role == "architect",
        where: grant.scope_base_branch in ^scope_base_branches,
        where: not is_nil(grant.claimed_at),
        where: grant.claimed_by != ^claimed_by,
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        select: grant
      )
      |> scope_live_package_authority(terminal_statuses)

    if query
       |> repo.all()
       |> Enum.any?(&(grant_repo_scope_matches?(&1, scope_repo) and BaseBranch.equivalent?(&1.scope_base_branch, scope_base_branch))) do
      {:error, :already_claimed}
    else
      :ok
    end
  end

  defp local_reconnect_grant(repo, work_package_id, claimed_by, now, terminal_statuses) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.grant_role == "worker",
        where: grant.claimed_by == ^claimed_by,
        where: not is_nil(grant.claimed_at),
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        order_by: [desc: grant.claimed_at, desc: grant.updated_at, asc: grant.id],
        limit: 1
      )
      |> scope_live_package_authority(terminal_statuses)

    case repo.one(query) do
      %AccessGrant{} = grant -> {:ok, grant}
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp reconnect_or_claim_local_worker_grant(repo, work_package_id, claimed_by, now, terminal_statuses) do
    case local_reconnect_grant(repo, work_package_id, claimed_by, now, terminal_statuses) do
      {:ok, grant} ->
        ensure_grant_scopes_and_return({:ok, grant}, repo, %{})

      {:error, :not_found} ->
        claim_unclaimed_local_worker_grant(repo, work_package_id, claimed_by, now, terminal_statuses)

      {:error, _reason} = error ->
        error
    end
  end

  defp reconnect_or_claim_local_architect_grant(repo, context, attrs) do
    case local_reconnect_architect_grant(
           repo,
           context.work_package_id,
           context.phase_id,
           context.scope_repo,
           context.scope_base_branch,
           context.claimed_by,
           context.now,
           context.terminal_statuses
         ) do
      {:ok, grant} ->
        ensure_grant_scopes_and_return({:ok, grant}, repo, attrs)

      {:error, :not_found} ->
        claim_unclaimed_local_architect_grant(
          repo,
          context,
          attrs
        )
    end
  end

  defp local_reconnect_architect_grant(repo, work_package_id, phase_id, scope_repo, scope_base_branch, claimed_by, now, terminal_statuses) do
    scope_base_branches = BaseBranch.equivalent_refs(scope_base_branch)

    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.phase_id == ^phase_id,
        where: grant.grant_role == "architect",
        where: grant.scope_base_branch in ^scope_base_branches,
        where: grant.claimed_by == ^claimed_by,
        where: not is_nil(grant.claimed_at),
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        order_by: [desc: grant.claimed_at, desc: grant.updated_at, asc: grant.id]
      )
      |> scope_live_package_authority(terminal_statuses)

    case query
         |> repo.all()
         |> Enum.find(&(grant_repo_scope_matches?(&1, scope_repo) and BaseBranch.equivalent?(&1.scope_base_branch, scope_base_branch))) do
      %AccessGrant{} = grant -> {:ok, grant}
      nil -> {:error, :not_found}
    end
  end

  defp claim_unclaimed_local_worker_grant(repo, work_package_id, claimed_by, now, terminal_statuses) do
    with {:ok, grant} <- local_unclaimed_worker_grant(repo, work_package_id, now, terminal_statuses) do
      persist_claim(repo, grant, claimed_by, now, terminal_statuses)
    end
  end

  defp claim_unclaimed_local_architect_grant(repo, context, attrs) do
    with {:ok, grant} <-
           local_unclaimed_architect_grant(
             repo,
             context.work_package_id,
             context.phase_id,
             context.scope_repo,
             context.scope_base_branch,
             context.now,
             context.terminal_statuses
           ) do
      persist_claim(repo, grant, context.claimed_by, context.now, context.terminal_statuses, attrs)
    end
  end

  defp local_unclaimed_worker_grant(repo, work_package_id, now, terminal_statuses) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.grant_role == "worker",
        where: is_nil(grant.claimed_at),
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        order_by: [desc: grant.inserted_at, desc: grant.id],
        limit: 1
      )
      |> scope_live_package_authority(terminal_statuses)

    case repo.one(query) do
      %AccessGrant{} = grant -> {:ok, grant}
      nil -> local_worker_grant_missing_reason(repo, work_package_id, terminal_statuses)
    end
  end

  defp local_unclaimed_architect_grant(
         repo,
         work_package_id,
         phase_id,
         scope_repo,
         scope_base_branch,
         now,
         terminal_statuses
       ) do
    scope_base_branches = BaseBranch.equivalent_refs(scope_base_branch)

    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.phase_id == ^phase_id,
        where: grant.grant_role == "architect",
        where: grant.scope_base_branch in ^scope_base_branches,
        where: is_nil(grant.claimed_at),
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        order_by: [desc: grant.inserted_at, desc: grant.id]
      )
      |> scope_live_package_authority(terminal_statuses)

    case query
         |> repo.all()
         |> Enum.find(&(grant_repo_scope_matches?(&1, scope_repo) and BaseBranch.equivalent?(&1.scope_base_branch, scope_base_branch))) do
      %AccessGrant{} = grant ->
        {:ok, grant}

      nil ->
        local_architect_grant_missing_reason(
          repo,
          work_package_id,
          phase_id,
          scope_repo,
          scope_base_branch,
          terminal_statuses
        )
    end
  end

  defp local_architect_grant_missing_reason(repo, work_package_id, phase_id, scope_repo, scope_base_branch, terminal_statuses) do
    case terminal_work_package?(repo, work_package_id, terminal_statuses) do
      {:ok, true} ->
        {:error, :work_package_terminal}

      {:ok, false} ->
        {:error, inactive_architect_grant_reason(repo, work_package_id, phase_id, scope_repo, scope_base_branch)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inactive_architect_grant_reason(repo, work_package_id, phase_id, scope_repo, scope_base_branch) do
    scope_base_branches = BaseBranch.equivalent_refs(scope_base_branch)

    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.phase_id == ^phase_id,
        where: grant.grant_role == "architect",
        where: grant.scope_base_branch in ^scope_base_branches,
        select: grant
      )

    grants =
      query
      |> repo.all()
      |> Enum.filter(&(grant_repo_scope_matches?(&1, scope_repo) and BaseBranch.equivalent?(&1.scope_base_branch, scope_base_branch)))

    revoked_count = Enum.count(grants, &match?(%DateTime{}, &1.revoked_at))

    case {length(grants), revoked_count} do
      {0, _revoked_count} -> :architect_grant_required
      {grant_count, revoked_count} when grant_count == revoked_count -> :revoked
      {_grant_count, _revoked_count} -> :expired
    end
  end

  defp reload_claim_error(repo, grant_id, now, terminal_statuses) do
    with {:ok, access_grant} <- get(repo, grant_id) do
      case claimable?(access_grant, now) do
        :ok -> package_authority_claim_error(repo, access_grant, terminal_statuses)
        {:error, _reason} = error -> error
      end
    end
  end

  defp package_authority_claim_error(_repo, _access_grant, []), do: {:error, :already_claimed}

  defp package_authority_claim_error(repo, %AccessGrant{work_package_id: work_package_id}, terminal_statuses)
       when is_binary(work_package_id) do
    case terminal_work_package?(repo, work_package_id, terminal_statuses) do
      {:ok, true} -> {:error, :work_package_terminal}
      {:ok, false} -> {:error, :already_claimed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp package_authority_claim_error(_repo, %AccessGrant{}, _terminal_statuses), do: {:error, :already_claimed}

  defp claimed_by(attrs) do
    case Map.get(attrs, :claimed_by) || Map.get(attrs, "claimed_by") do
      claimed_by when is_binary(claimed_by) ->
        if String.trim(claimed_by) == "" do
          {:error, :missing_claim_identity}
        else
          {:ok, claimed_by}
        end

      _claimed_by ->
        {:error, :missing_claim_identity}
    end
  end

  defp claim_scope(attrs, key) when is_atom(key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :invalid_scope}, else: {:ok, value}

      _value ->
        {:error, :invalid_scope}
    end
  end

  defp ensure_grant_scopes_and_return({:ok, %AccessGrant{} = grant}, repo, attrs) do
    case ensure_grant_scopes(repo, grant, normalize_attr_map(attrs)) do
      {:ok, _scopes} -> {:ok, grant}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_grant_scopes_and_return({:error, _reason} = error, _repo, _attrs), do: error

  defp ensure_scope_rows(repo, %AccessGrant{} = access_grant, attrs) do
    attrs = normalize_attr_map(attrs)

    case required_grant_scopes(repo, access_grant, attrs) do
      {:ok, scopes} -> ensure_scope_rows(repo, access_grant.id, scopes)
      {:error, _reason} = error -> error
    end
  end

  defp ensure_scope_rows(repo, access_grant_id, scopes) do
    Enum.reduce_while(scopes, :ok, fn scope, :ok ->
      case ensure_scope_row(repo, access_grant_id, scope) do
        {:ok, _scope_row} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp required_grant_scopes(repo, %AccessGrant{} = access_grant, attrs) do
    with :ok <- validate_requested_architect_scopes(repo, access_grant, attrs),
         {:ok, default_scopes} <- default_grant_scopes(repo, access_grant, attrs) do
      scopes =
        (default_scopes ++ explicit_grant_scopes(attrs))
        |> Enum.uniq_by(&GrantScope.scope_key/1)

      {:ok, scopes}
    end
  end

  defp validate_requested_architect_scopes(_repo, %AccessGrant{grant_role: grant_role}, _attrs)
       when grant_role != "architect" do
    :ok
  end

  defp validate_requested_architect_scopes(repo, %AccessGrant{} = access_grant, attrs) do
    work_request_ids = requested_scope_ids(attrs, "work_request_id", :work_request)
    work_package_ids = requested_scope_ids(attrs, "work_package_id", :work_package)

    case validate_explicit_architect_scopes(access_grant, explicit_grant_scopes(attrs)) do
      :ok ->
        case validate_requested_work_request_scopes(repo, access_grant, work_request_ids) do
          :ok -> validate_requested_work_package_scopes(repo, access_grant, work_package_ids, work_request_ids)
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_explicit_architect_scopes(%AccessGrant{} = access_grant, scopes) do
    Enum.reduce_while(scopes, :ok, fn scope, :ok ->
      case validate_explicit_architect_scope(access_grant, scope) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_explicit_architect_scope(%AccessGrant{}, %AuthScope{type: type})
       when type in [:work_request, :work_package],
       do: :ok

  defp validate_explicit_architect_scope(%AccessGrant{} = access_grant, %AuthScope{type: :repo} = scope) do
    if repo_scope_match?(scope.repo, access_grant.scope_repo) and
         BaseBranch.equivalent?(scope.base_branch, access_grant.scope_base_branch) do
      :ok
    else
      {:error, :invalid_scope}
    end
  end

  defp validate_explicit_architect_scope(%AccessGrant{}, %AuthScope{}), do: {:error, :invalid_scope}

  defp requested_scope_ids(attrs, attr_key, scope_type) do
    attr_ids = attrs |> string_attr(attr_key) |> List.wrap()
    explicit_ids = attrs |> explicit_grant_scopes() |> Enum.flat_map(&explicit_scope_id(&1, scope_type))

    Enum.uniq(attr_ids ++ explicit_ids)
  end

  defp explicit_scope_id(%AuthScope{type: type, id: id}, type) when is_binary(id), do: [id]
  defp explicit_scope_id(%AuthScope{}, _type), do: []

  defp validate_requested_work_request_scopes(_repo, %AccessGrant{}, []), do: :ok

  defp validate_requested_work_request_scopes(repo, %AccessGrant{} = access_grant, work_request_ids) do
    Enum.reduce_while(work_request_ids, :ok, fn work_request_id, :ok ->
      case validate_requested_work_request_scope(repo, access_grant, work_request_id) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_requested_work_request_scope(_repo, %AccessGrant{}, nil), do: :ok

  defp validate_requested_work_request_scope(repo, %AccessGrant{} = access_grant, work_request_id) do
    case persisted_scope_ids(repo, access_grant.id, "work_request") do
      [] ->
        if work_request_matches_anchor?(repo, access_grant, work_request_id), do: :ok, else: {:error, :invalid_scope}

      scope_ids ->
        if work_request_id in scope_ids, do: :ok, else: {:error, :invalid_scope}
    end
  end

  defp validate_requested_work_package_scopes(_repo, %AccessGrant{}, [], _work_request_ids), do: :ok

  defp validate_requested_work_package_scopes(repo, %AccessGrant{} = access_grant, work_package_ids, work_request_ids) do
    Enum.reduce_while(work_package_ids, :ok, fn work_package_id, :ok ->
      case validate_requested_work_package_scope(repo, access_grant, work_package_id, work_request_ids) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_requested_work_package_scope(repo, %AccessGrant{} = access_grant, work_package_id, work_request_ids) do
    scope_ids = persisted_scope_ids(repo, access_grant.id, "work_package")
    work_request_ids = work_package_work_request_scope_ids(repo, access_grant, work_request_ids)

    case require_matching_persisted_scope(scope_ids, work_package_id) do
      :ok -> validate_work_package_anchor(repo, access_grant, work_package_id, work_request_ids)
      {:error, _reason} = error -> error
    end
  end

  defp work_package_work_request_scope_ids(_repo, %AccessGrant{}, work_request_ids)
       when work_request_ids != [],
       do: work_request_ids

  defp work_package_work_request_scope_ids(repo, %AccessGrant{} = access_grant, []) do
    persisted_scope_ids(repo, access_grant.id, "work_request")
  end

  defp require_matching_persisted_scope([], _scope_id), do: :ok

  defp require_matching_persisted_scope(scope_ids, scope_id) do
    if scope_id in scope_ids, do: :ok, else: {:error, :invalid_scope}
  end

  defp persisted_scope_ids(repo, access_grant_id, scope_type) do
    query =
      from(scope in GrantScope,
        where: scope.access_grant_id == ^access_grant_id,
        where: scope.scope_type == ^scope_type,
        select: scope.scope_id
      )

    Enum.reject(repo.all(query), &is_nil/1)
  end

  defp work_request_matches_anchor?(repo, %AccessGrant{} = access_grant, work_request_id) do
    work_request_matches_handoff_anchor?(repo, access_grant, work_request_id) or
      work_request_has_anchor_package?(repo, access_grant, work_request_id)
  end

  defp work_request_matches_handoff_anchor?(repo, %AccessGrant{} = access_grant, work_request_id)
       when is_binary(work_request_id) do
    with :ok <- require_handoff_scope_attrs(access_grant, work_request_id),
         {:ok, anchor} <- WorkPackageRepository.get(repo, access_grant.work_package_id),
         {:ok, work_request} <- WorkRequestRepository.get(repo, work_request_id) do
      handoff_anchor_matches_grant?(anchor, access_grant) and
        work_request_matches_grant_scope?(work_request, access_grant)
    else
      _reason -> false
    end
  end

  defp work_request_matches_handoff_anchor?(_repo, %AccessGrant{}, _work_request_id), do: false

  defp require_handoff_scope_attrs(
         %AccessGrant{
           work_package_id: work_package_id,
           phase_id: phase_id,
           scope_repo: scope_repo,
           scope_base_branch: scope_base_branch
         },
         work_request_id
       )
       when is_binary(work_package_id) and is_binary(phase_id) and is_binary(scope_repo) and
              is_binary(scope_base_branch) do
    if work_package_id == architect_handoff_anchor_id(work_request_id) and
         phase_id == architect_handoff_phase_id(work_request_id) do
      :ok
    else
      {:error, :invalid_scope}
    end
  end

  defp require_handoff_scope_attrs(%AccessGrant{}, _work_request_id), do: {:error, :invalid_scope}

  defp handoff_anchor_matches_grant?(%WorkPackage{} = anchor, %AccessGrant{} = access_grant) do
    anchor.id == access_grant.work_package_id and
      anchor.phase_id == access_grant.phase_id and
      anchor.kind == @architect_handoff_anchor_kind and
      repo_scope_match?(anchor.repo, access_grant.scope_repo) and
      BaseBranch.equivalent?(anchor.base_branch, access_grant.scope_base_branch)
  end

  defp work_request_matches_grant_scope?(work_request, %AccessGrant{} = access_grant) do
    repo_scope_match?(work_request.repo, access_grant.scope_repo) and
      BaseBranch.equivalent?(work_request.base_branch, access_grant.scope_base_branch)
  end

  defp grant_repo_scope_matches?(%AccessGrant{scope_repo: scope_repo}, expected_repo), do: repo_scope_match?(scope_repo, expected_repo)

  defp repo_scope_match?(expected_repo, actual_repo) when is_binary(expected_repo) and is_binary(actual_repo) do
    RepoIdentity.scope_match?(expected_repo, actual_repo,
      trusted_remotes: repo_scope_trusted_remotes(),
      local_path_remotes?: true
    )
  end

  defp repo_scope_match?(_expected_repo, _actual_repo), do: false

  defp repo_scope_trusted_remotes do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_identity_trusted_remotes, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp architect_handoff_anchor_id(work_request_id) do
    @architect_handoff_anchor_id_prefix <> architect_handoff_stable_suffix(work_request_id)
  end

  defp architect_handoff_phase_id(work_request_id) do
    @architect_handoff_phase_id_prefix <> architect_handoff_stable_suffix(work_request_id)
  end

  defp architect_handoff_stable_suffix(work_request_id) do
    :sha256
    |> :crypto.hash([work_request_id])
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  defp work_request_has_anchor_package?(repo, %AccessGrant{work_package_id: work_package_id} = access_grant, work_request_id)
       when is_binary(work_package_id) do
    match?(%WorkPackage{work_request_id: ^work_request_id}, repo.get(WorkPackage, work_package_id)) and
      work_request_matches_grant_scope?(repo, access_grant, work_request_id)
  end

  defp work_request_has_anchor_package?(_repo, %AccessGrant{}, _work_request_id), do: false

  defp validate_work_package_anchor(repo, %AccessGrant{work_package_id: work_package_id} = access_grant, work_package_id, work_request_ids)
       when is_binary(work_package_id) do
    case repo.get(WorkPackage, work_package_id) do
      %WorkPackage{work_request_id: work_request_id} when is_binary(work_request_id) ->
        if (work_request_ids == [] or work_request_id in work_request_ids) and
             work_request_matches_grant_scope?(repo, access_grant, work_request_id) do
          :ok
        else
          {:error, :invalid_scope}
        end

      %WorkPackage{} = work_package ->
        if direct_package_anchor_matches?(repo, work_package, access_grant, work_request_ids) do
          :ok
        else
          {:error, :invalid_scope}
        end

      _work_package ->
        {:error, :invalid_scope}
    end
  end

  defp validate_work_package_anchor(_repo, %AccessGrant{}, _work_package_id, _work_request_id), do: {:error, :invalid_scope}

  defp direct_package_anchor_matches?(_repo, %WorkPackage{}, %AccessGrant{phase_id: phase_id}, [])
       when phase_id in [nil, ""],
       do: true

  defp direct_package_anchor_matches?(repo, %WorkPackage{} = work_package, %AccessGrant{} = access_grant, work_request_ids) do
    phase_anchor_matches_grant?(work_package, access_grant) and
      Enum.all?(work_request_ids, &work_request_matches_handoff_anchor?(repo, access_grant, &1))
  end

  defp phase_anchor_matches_grant?(%WorkPackage{} = work_package, %AccessGrant{} = access_grant) do
    is_binary(work_package.phase_id) and
      work_package.phase_id == access_grant.phase_id and
      repo_scope_match?(work_package.repo, access_grant.scope_repo) and
      BaseBranch.equivalent?(work_package.base_branch, access_grant.scope_base_branch)
  end

  defp work_request_matches_grant_scope?(repo, %AccessGrant{} = access_grant, work_request_id)
       when is_binary(work_request_id) do
    case WorkRequestRepository.get(repo, work_request_id) do
      {:ok, work_request} -> work_request_matches_grant_scope?(work_request, access_grant)
      {:error, _reason} -> false
    end
  end

  defp work_request_matches_grant_scope?(_repo, %AccessGrant{}, _work_request_id), do: false

  defp default_grant_scopes(_repo, %AccessGrant{grant_role: "worker", work_package_id: work_package_id}, _attrs)
       when is_binary(work_package_id) do
    {:ok, [AuthScope.work_package(work_package_id)]}
  end

  defp default_grant_scopes(repo, %AccessGrant{grant_role: "architect"} = access_grant, attrs) do
    with {:ok, work_request_scope} <- architect_work_request_scope(repo, access_grant, attrs) do
      scopes =
        [
          work_request_scope,
          explicit_work_package_scope(attrs),
          optional_work_package_scope(access_grant.work_package_id),
          optional_repo_scope(access_grant.scope_repo, access_grant.scope_base_branch)
        ]
        |> Enum.reject(&is_nil/1)

      {:ok, scopes}
    end
  end

  defp default_grant_scopes(_repo, %AccessGrant{}, _attrs), do: {:ok, []}

  defp architect_work_request_scope(repo, %AccessGrant{} = access_grant, attrs) do
    case string_attr(attrs, "work_request_id") do
      work_request_id when is_binary(work_request_id) ->
        validated_work_request_scope(repo, access_grant, work_request_id)

      nil ->
        case requested_work_package_work_request_id_from_attrs(repo, access_grant.work_package_id, attrs) do
          {:ok, work_request_id} -> validated_work_request_scope(repo, access_grant, work_request_id)
          {:error, :not_found} -> work_package_work_request_scope(repo, access_grant)
        end
    end
  end

  defp work_package_work_request_scope(repo, %AccessGrant{} = access_grant) do
    case work_request_id_for_work_package(repo, access_grant.work_package_id) do
      {:ok, work_request_id} -> validated_work_request_scope(repo, access_grant, work_request_id)
      {:error, :not_found} -> {:ok, nil}
    end
  end

  defp validated_work_request_scope(repo, %AccessGrant{} = access_grant, work_request_id) do
    if work_request_matches_grant_scope?(repo, access_grant, work_request_id) do
      {:ok, AuthScope.work_request(work_request_id)}
    else
      {:error, :invalid_scope}
    end
  end

  defp requested_work_package_work_request_id_from_attrs(repo, _work_package_id, attrs) do
    case string_attr(attrs, "work_package_id") do
      work_package_id when is_binary(work_package_id) ->
        work_request_id_for_work_package(repo, work_package_id)

      nil ->
        {:error, :not_found}
    end
  end

  defp work_request_id_for_work_package(_repo, work_package_id) when not is_binary(work_package_id), do: {:error, :not_found}

  defp work_request_id_for_work_package(repo, work_package_id) do
    case repo.get(WorkPackage, work_package_id) do
      %WorkPackage{work_request_id: work_request_id} when is_binary(work_request_id) -> {:ok, work_request_id}
      _work_package -> {:error, :not_found}
    end
  end

  defp explicit_work_package_scope(attrs) do
    case string_attr(attrs, "work_package_id") do
      work_package_id when is_binary(work_package_id) -> AuthScope.work_package(work_package_id)
      nil -> nil
    end
  end

  defp optional_work_package_scope(work_package_id) when is_binary(work_package_id), do: AuthScope.work_package(work_package_id)
  defp optional_work_package_scope(_work_package_id), do: nil

  defp optional_repo_scope(repo, base_branch) when is_binary(repo), do: AuthScope.repo(repo, base_branch)
  defp optional_repo_scope(_repo, _base_branch), do: nil

  defp explicit_grant_scopes(attrs) do
    case Map.get(attrs, "scopes") do
      scopes when is_list(scopes) -> Enum.flat_map(scopes, &explicit_grant_scope/1)
      _scopes -> []
    end
  end

  defp explicit_grant_scope(%AuthScope{} = scope), do: [scope]

  defp explicit_grant_scope(%{} = attrs) do
    attrs = normalize_attr_map(attrs)
    type = Map.get(attrs, "type") || Map.get(attrs, "scope_type")

    explicit_grant_scope_for_type(type, attrs)
  end

  defp explicit_grant_scope(_scope), do: []

  defp explicit_grant_scope_for_type(type, _attrs) when type in [:ledger, "ledger"], do: [AuthScope.ledger()]
  defp explicit_grant_scope_for_type(type, attrs) when type in [:repo, "repo"], do: explicit_repo_scope(attrs)

  defp explicit_grant_scope_for_type(type, attrs) when type in [:work_request, "work_request"],
    do: explicit_id_scope(attrs, &AuthScope.work_request/1)

  defp explicit_grant_scope_for_type(type, attrs) when type in [:work_package, "work_package"],
    do: explicit_id_scope(attrs, &AuthScope.work_package/1)

  defp explicit_grant_scope_for_type(_type, _attrs), do: []

  defp explicit_repo_scope(attrs) do
    case string_attr(attrs, "repo") do
      repo when is_binary(repo) -> [AuthScope.repo(repo, string_attr(attrs, "base_branch"))]
      nil -> []
    end
  end

  defp explicit_id_scope(attrs, build_scope) do
    case string_attr(attrs, "id") || string_attr(attrs, "scope_id") do
      id when is_binary(id) -> [build_scope.(id)]
      nil -> []
    end
  end

  defp ensure_scope_row(repo, access_grant_id, %AuthScope{} = scope) do
    attrs = GrantScope.attrs_from_scope(access_grant_id, scope)
    scope_key = GrantScope.scope_key(attrs)

    case existing_scope_row(repo, access_grant_id, scope_key) do
      {:ok, %GrantScope{} = scope_row} ->
        {:ok, scope_row}

      {:error, :not_found} ->
        insert_scope_row(repo, access_grant_id, scope_key, attrs)
    end
  end

  defp existing_scope_row(repo, access_grant_id, scope_key) do
    query =
      from(scope in GrantScope,
        where: scope.access_grant_id == ^access_grant_id,
        where: scope.scope_key == ^scope_key,
        limit: 1
      )

    case repo.one(query) do
      %GrantScope{} = scope_row -> {:ok, scope_row}
      nil -> {:error, :not_found}
    end
  end

  defp insert_scope_row(repo, access_grant_id, scope_key, attrs) do
    attrs
    |> GrantScope.create_changeset()
    |> repo.insert()
    |> case do
      {:ok, scope_row} ->
        {:ok, scope_row}

      {:error, %Changeset{} = changeset} ->
        if duplicate_scope_key?(changeset) do
          existing_scope_row(repo, access_grant_id, scope_key)
        else
          {:error, changeset}
        end
    end
  end

  defp duplicate_scope_key?(changeset) do
    Enum.any?(changeset.errors, fn
      {:scope_key, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp normalize_attr_map(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_attr_key(key), value} end)
  end

  defp normalize_attr_map(attrs) when is_list(attrs), do: attrs |> Map.new() |> normalize_attr_map()
  defp normalize_attr_map(_attrs), do: %{}

  defp normalize_attr_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_attr_key(key), do: to_string(key)

  defp string_attr(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: value

      _value ->
        nil
    end
  end

  defp assignment(repo, %AccessGrant{} = access_grant) do
    with {:ok, scope_rows} <- list_scopes(repo, access_grant.id) do
      scopes = Enum.map(scope_rows, &GrantScope.to_authorization_scope/1)

      {:ok,
       %Assignment{
         grant_id: access_grant.id,
         work_package_id: access_grant.work_package_id,
         phase_id: access_grant.phase_id,
         display_key: access_grant.display_key,
         grant_role: access_grant.grant_role,
         capabilities: access_grant.capabilities,
         claimed_at: access_grant.claimed_at,
         claimed_by: access_grant.claimed_by,
         scopes: scopes
       }}
    end
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {left_byte, right_byte}, diff ->
      Bitwise.bor(diff, Bitwise.bxor(left_byte, right_byte))
    end)
    |> Kernel.==(0)
  end

  defp secure_equal?(_left, _right), do: false

  defp normalize_insert_result({:ok, access_grant}), do: {:ok, access_grant}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    if duplicate_id?(changeset) do
      {:error, :id_already_exists}
    else
      {:error, changeset}
    end
  end

  defp normalize_transaction_result({:ok, %AccessGrant{} = grant}), do: {:ok, grant}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp validate_architect_phase_anchor(_repo, %Changeset{valid?: false} = changeset), do: {:error, changeset}

  defp validate_architect_phase_anchor(repo, %Changeset{} = changeset) do
    if architect_phase_grant?(changeset) do
      phase_id = Changeset.get_field(changeset, :phase_id)
      work_package_id = Changeset.get_field(changeset, :work_package_id)

      with :ok <- validate_phase_anchor_phase(repo, changeset, phase_id),
           {:ok, anchor} <- validate_phase_anchor_work_package(repo, changeset, work_package_id, phase_id) do
        {:ok, freeze_architect_anchor_scope(changeset, anchor)}
      else
        {:error, %Changeset{} = changeset} -> {:error, changeset}
      end
    else
      {:ok, changeset}
    end
  end

  defp architect_phase_grant?(%Changeset{} = changeset) do
    Changeset.get_field(changeset, :grant_role) == "architect" and
      explicit_phase_id?(Changeset.get_field(changeset, :phase_id))
  end

  defp explicit_phase_id?(phase_id) when is_binary(phase_id), do: String.trim(phase_id) != ""
  defp explicit_phase_id?(_phase_id), do: false

  defp validate_phase_anchor_phase(repo, changeset, phase_id) do
    case PhaseRepository.get(repo, phase_id) do
      {:ok, _phase} -> :ok
      {:error, :not_found} -> {:error, Changeset.add_error(changeset, :phase_id, "does not exist")}
      {:error, reason} -> {:error, Changeset.add_error(changeset, :phase_id, inspect(reason))}
    end
  end

  defp validate_phase_anchor_work_package(_repo, changeset, work_package_id, _phase_id)
       when not is_binary(work_package_id) do
    {:error, Changeset.add_error(changeset, :work_package_id, "architect phase grants require work package anchor")}
  end

  defp validate_phase_anchor_work_package(repo, changeset, work_package_id, phase_id) do
    if String.trim(work_package_id) == "" do
      {:error, Changeset.add_error(changeset, :work_package_id, "architect phase grants require work package anchor")}
    else
      validate_phase_anchor_work_package_id(repo, changeset, work_package_id, phase_id)
    end
  end

  defp validate_phase_anchor_work_package_id(repo, changeset, work_package_id, phase_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %{phase_id: ^phase_id} = work_package} -> {:ok, work_package}
      {:ok, _work_package} -> {:error, Changeset.add_error(changeset, :work_package_id, "must belong to architect phase")}
      {:error, :not_found} -> {:error, Changeset.add_error(changeset, :work_package_id, "does not exist")}
      {:error, reason} -> {:error, Changeset.add_error(changeset, :work_package_id, inspect(reason))}
    end
  end

  defp freeze_architect_anchor_scope(%Changeset{} = changeset, %{repo: repo, base_branch: base_branch}) do
    changeset
    |> Changeset.put_change(:scope_repo, repo)
    |> Changeset.put_change(:scope_base_branch, base_branch)
  end

  defp duplicate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_access_grants_id_unique_index"}) do
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

    if String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end
end
