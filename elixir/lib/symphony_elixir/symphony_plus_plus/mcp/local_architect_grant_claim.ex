defmodule SymphonyElixir.SymphonyPlusPlus.MCP.LocalArchitectGrantClaim do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.GrantScope
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.BaseBranch
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.CompletionRecovery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ScopeConstraints
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type recovered_grant :: %{
          id: String.t(),
          previous_claimed_at: DateTime.t() | nil,
          previous_claimed_by: String.t() | nil,
          recovered_claimed_by: String.t(),
          completion_snapshots: [map()]
        }
  @type grant_action :: :claimed | :reconnected | {:recovered, recovered_grant()}
  @type grant_validator :: (AccessGrant.t() -> :ok | {:error, term()})

  @spec claim(module(), WorkPackage.t(), map(), :created | :heartbeat | :reclaimed, grant_validator()) ::
          {:ok, AccessGrant.t(), grant_action()} | {:error, term()}
  def claim(repo, %WorkPackage{} = anchor, claim, lease_action, validate_grant)
      when is_atom(repo) and is_map(claim) and lease_action in [:created, :heartbeat, :reclaimed] and
             is_function(validate_grant, 1) do
    now = DateTime.utc_now(:microsecond)
    do_claim(repo, anchor, claim, now, active_grant_ids(repo, anchor, claim, now), lease_action, validate_grant)
  end

  @spec claim(module(), WorkPackage.t(), map(), :created | :heartbeat | :reclaimed) ::
          {:ok, AccessGrant.t(), grant_action()} | {:error, term()}
  def claim(repo, %WorkPackage{} = anchor, claim, lease_action)
      when is_atom(repo) and is_map(claim) and lease_action in [:created, :heartbeat, :reclaimed] do
    claim(repo, anchor, claim, lease_action, fn _grant -> :ok end)
  end

  @spec rollback_failed_claim(module(), grant_action()) :: :ok
  def rollback_failed_claim(repo, {:recovered, recovery}) when is_atom(repo) and is_map(recovery) do
    _result = restore_recovered_completion(repo, recovery)
    _result = restore_recovered_handoff_owner(repo, recovery)
    :ok
  end

  def rollback_failed_claim(_repo, _action), do: :ok

  defp do_claim(repo, %WorkPackage{} = anchor, claim, %DateTime{} = now, existing_grant_ids, lease_action, validate_grant) do
    with :ok <- repair_recoverable_work_request_scope(repo, anchor, claim, now, validate_grant) do
      case claim_grant(repo, anchor, claim, now) do
        {:ok, %AccessGrant{} = grant} ->
          {:ok, grant, grant_action(grant, existing_grant_ids)}

        {:error, :already_claimed} when lease_action in [:created, :reclaimed] ->
          recover_released_handoff_owner(repo, anchor, claim, now, validate_grant)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp claim_grant(repo, %WorkPackage{} = anchor, claim, %DateTime{} = now) do
    AccessGrantService.claim_local_architect_grant(repo, anchor.id, anchor.phase_id,
      claimed_by: claim.claimed_by,
      scope_repo: claim.repo,
      scope_base_branch: claim.base_branch,
      work_request_id: claim.work_request_id,
      now: now
    )
  end

  defp repair_recoverable_work_request_scope(repo, %WorkPackage{} = anchor, %{work_request_id: work_request_id} = claim, %DateTime{} = now, _validate_grant)
       when is_binary(work_request_id) do
    repo
    |> recoverable_work_request_scope_candidates(anchor, claim, now)
    |> Enum.filter(&(stale_work_request_scope?(repo, &1, work_request_id) and recoverable_work_request_scope_candidate?(repo, &1, anchor, claim)))
    |> case do
      [grant] -> replace_work_request_scope(repo, grant, work_request_id)
      _candidates -> :ok
    end
  end

  defp repair_recoverable_work_request_scope(_repo, %WorkPackage{}, _claim, %DateTime{}, _validate_grant), do: :ok

  defp recoverable_work_request_scope_candidates(repo, %WorkPackage{} = anchor, claim, %DateTime{} = now) do
    scope_base_branches = BaseBranch.equivalent_refs(claim.base_branch)

    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^anchor.id,
        where: grant.phase_id == ^anchor.phase_id,
        where: grant.grant_role == "architect",
        where: grant.scope_base_branch in ^scope_base_branches,
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        order_by: [desc: grant.claimed_at, desc: grant.updated_at, asc: grant.id]
      )

    query
    |> repo.all()
    |> Enum.filter(&grant_repo_scope_matches?(&1, claim.repo))
  end

  defp stale_work_request_scope?(repo, %AccessGrant{} = grant, work_request_id) when is_binary(work_request_id) do
    work_request_scope_key = "work_request:#{work_request_id}"

    case AccessGrantRepository.list_scopes(repo, grant.id) do
      {:ok, scopes} ->
        Enum.any?(scopes, fn
          %GrantScope{scope_type: "work_request", scope_id: scope_id, scope_key: scope_key} ->
            scope_id != work_request_id or scope_key != work_request_scope_key

          %GrantScope{} ->
            false
        end)

      {:error, _reason} ->
        false
    end
  end

  defp recoverable_work_request_scope_candidate?(repo, %AccessGrant{} = grant, %WorkPackage{} = anchor, claim) do
    with true <- grant.work_package_id == anchor.id,
         true <- grant.phase_id == anchor.phase_id,
         true <- BaseBranch.equivalent?(grant.scope_base_branch, claim.base_branch),
         true <- grant_repo_scope_matches?(grant, claim.repo),
         {:ok, %WorkRequest{} = work_request} <- WorkRequestRepository.get(repo, claim.work_request_id),
         true <- recoverable_work_request?(work_request, anchor, claim) do
      true
    else
      _reason -> false
    end
  end

  defp recoverable_work_request?(%WorkRequest{} = work_request, %WorkPackage{} = anchor, claim) do
    recoverable_work_request_status?(work_request) and
      recoverable_work_request_identity?(work_request, anchor, claim) and
      work_request_file_scope_matches?(work_request, anchor) and
      work_request_repo_scope_matches?(work_request, claim)
  end

  defp recoverable_work_request_status?(%WorkRequest{} = work_request) do
    is_nil(work_request.archived_at) and
      not (match?(%DateTime{}, work_request.completed_at) and work_request.completion_source == "operator") and
      ArchitectHandoff.eligible_status?(work_request.status)
  end

  defp recoverable_work_request_identity?(%WorkRequest{} = work_request, %WorkPackage{} = anchor, claim) do
    anchor.kind == "delegation" and
      ArchitectHandoff.anchor_id_for_work_request(work_request) == anchor.id and
      ArchitectHandoff.phase_id_for_work_request(work_request) == anchor.phase_id and
      BaseBranch.equivalent?(work_request.base_branch, claim.base_branch)
  end

  defp work_request_repo_scope_matches?(%WorkRequest{} = work_request, claim) do
    RepoIdentity.scope_match?(work_request.repo, claim.repo,
      trusted_remotes: repo_scope_trusted_remotes(),
      local_path_remotes?: true
    )
  end

  defp work_request_file_scope_matches?(%WorkRequest{} = work_request, %WorkPackage{} = anchor) do
    case work_request_allowed_file_globs(work_request) do
      {:ok, allowed_file_globs} -> normalized_strings(anchor.allowed_file_globs || []) == allowed_file_globs
      {:error, _reason} -> false
    end
  end

  defp work_request_allowed_file_globs(%WorkRequest{constraints: constraints}) when is_map(constraints) do
    case work_request_constraint_value(constraints, :allowed_paths) do
      :missing -> validate_allowed_file_globs(constraints, [])
      values when is_list(values) -> normalize_allowed_file_globs(constraints, values)
      _values -> {:error, :invalid_scope}
    end
  end

  defp work_request_allowed_file_globs(%WorkRequest{}), do: {:ok, []}

  defp work_request_constraint_value(constraints, key) when is_map(constraints) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(constraints, string_key) -> Map.fetch!(constraints, string_key)
      Map.has_key?(constraints, key) -> Map.fetch!(constraints, key)
      true -> :missing
    end
  end

  defp normalize_allowed_file_globs(constraints, values) do
    case normalized_nonblank_strings(values) do
      {:ok, allowed_paths} ->
        allowed_file_globs = allowed_paths_to_file_globs(allowed_paths)
        validate_allowed_file_globs(constraints, allowed_file_globs)

      {:error, :invalid_scope} ->
        {:error, :invalid_scope}
    end
  end

  defp allowed_paths_to_file_globs(allowed_paths) do
    allowed_paths
    |> Enum.flat_map(&allowed_path_to_file_globs/1)
    |> normalized_strings()
  end

  defp allowed_path_to_file_globs(allowed_path) do
    if String.contains?(allowed_path, ["*", "?", "["]) do
      [allowed_path]
    else
      [allowed_path, "#{allowed_path}/**"]
    end
  end

  defp validate_allowed_file_globs(constraints, allowed_file_globs) do
    case ScopeConstraints.validate_allowed_file_globs(constraints, allowed_file_globs) do
      :ok -> {:ok, allowed_file_globs}
      {:error, _errors} -> {:error, :invalid_scope}
    end
  end

  defp normalized_nonblank_strings(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, normalized_strings(values)}
    else
      {:error, :invalid_scope}
    end
  end

  defp normalized_nonblank_strings(_values), do: {:error, :invalid_scope}

  defp normalized_strings(values) when is_list(values) do
    values
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalized_strings(_values), do: []

  defp replace_work_request_scope(repo, %AccessGrant{} = grant, work_request_id) when is_binary(work_request_id) do
    repo.transaction(fn ->
      repo.delete_all(
        from(scope in GrantScope,
          where: scope.access_grant_id == ^grant.id,
          where: scope.scope_type == "work_request"
        )
      )

      case AccessGrantRepository.ensure_grant_scopes(repo, grant, %{"work_request_id" => work_request_id}) do
        {:ok, _scopes} -> :ok
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp active_grant_ids(repo, %WorkPackage{} = anchor, claim, %DateTime{} = now) do
    scope_base_branches = BaseBranch.equivalent_refs(claim.base_branch)

    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^anchor.id,
        where: grant.phase_id == ^anchor.phase_id,
        where: grant.grant_role == "architect",
        where: grant.scope_base_branch in ^scope_base_branches,
        where: grant.claimed_by == ^claim.claimed_by,
        where: not is_nil(grant.claimed_at),
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        select: grant
      )

    query
    |> repo.all()
    |> Enum.filter(&grant_repo_scope_matches?(&1, claim.repo))
    |> Enum.map(& &1.id)
  end

  defp recover_released_handoff_owner(repo, %WorkPackage{} = anchor, claim, %DateTime{} = now, validate_grant) do
    repo.transaction(fn ->
      with %AccessGrant{} = recovered_owner <- released_handoff_owner_candidate(repo, anchor, claim, now),
           {1, _rows} <- recover_released_handoff_owner_id(repo, recovered_owner.id, claim, now),
           {:ok, %AccessGrant{} = grant} <- claim_grant(repo, anchor, claim, now),
           :ok <- validate_grant.(grant),
           {:ok, completion_snapshots} <- CompletionRecovery.snapshots_for_work_package(repo, anchor.id),
           :ok <- WorkRequestRepository.clear_completion_for_work_package(repo, anchor.id) do
        {:ok, grant, {:recovered, recovered_owner_snapshot(recovered_owner, claim, completion_snapshots)}}
      else
        nil -> repo.rollback(:already_claimed)
        {0, _rows} -> repo.rollback(:already_claimed)
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:ok, %AccessGrant{} = grant, action}} -> {:ok, grant, action}
      {:error, reason} -> {:error, reason}
    end
  end

  defp released_handoff_owner_candidate(repo, %WorkPackage{} = anchor, claim, %DateTime{} = now) do
    scope_base_branches = BaseBranch.equivalent_refs(claim.base_branch)

    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^anchor.id,
        where: grant.phase_id == ^anchor.phase_id,
        where: grant.grant_role == "architect",
        where: grant.scope_base_branch in ^scope_base_branches,
        where: not is_nil(grant.claimed_at),
        where: grant.claimed_by != ^claim.claimed_by,
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        order_by: [desc: grant.claimed_at, desc: grant.updated_at, asc: grant.id]
      )

    query
    |> repo.all()
    |> Enum.find(&grant_repo_scope_matches?(&1, claim.repo))
  end

  defp grant_repo_scope_matches?(%AccessGrant{scope_repo: scope_repo}, expected_repo) when is_binary(scope_repo) and is_binary(expected_repo) do
    RepoIdentity.scope_match?(scope_repo, expected_repo,
      trusted_remotes: repo_scope_trusted_remotes(),
      local_path_remotes?: true
    )
  end

  defp grant_repo_scope_matches?(%AccessGrant{}, _expected_repo), do: false

  defp repo_scope_trusted_remotes do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_identity_trusted_remotes, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp recover_released_handoff_owner_id(repo, id, claim, %DateTime{} = now) when is_binary(id) do
    query = from(grant in AccessGrant, where: grant.id == ^id, where: grant.claimed_by != ^claim.claimed_by)

    repo.update_all(query, set: [claimed_at: now, claimed_by: claim.claimed_by, updated_at: now])
  end

  defp recovered_owner_snapshot(%AccessGrant{} = recovered_owner, claim, completion_snapshots) do
    %{
      id: recovered_owner.id,
      previous_claimed_at: recovered_owner.claimed_at,
      previous_claimed_by: recovered_owner.claimed_by,
      recovered_claimed_by: claim.claimed_by,
      completion_snapshots: completion_snapshots
    }
  end

  defp restore_recovered_completion(repo, %{completion_snapshots: snapshots}) when is_list(snapshots) do
    now = DateTime.utc_now(:microsecond)

    Enum.each(snapshots, fn snapshot ->
      repo.update_all(
        from(work_request in WorkRequest, where: work_request.id == ^snapshot.id),
        set: [
          completed_at: snapshot.completed_at,
          completion_source: snapshot.completion_source,
          archived_at: snapshot.archived_at,
          archive_reason: snapshot.archive_reason,
          updated_at: now
        ]
      )
    end)
  end

  defp restore_recovered_completion(_repo, _recovery), do: :ok

  defp restore_recovered_handoff_owner(repo, %{id: id, recovered_claimed_by: recovered_claimed_by} = recovery)
       when is_binary(id) and is_binary(recovered_claimed_by) do
    now = DateTime.utc_now(:microsecond)

    query =
      from(grant in AccessGrant,
        where: grant.id == ^id,
        where: grant.claimed_by == ^recovered_claimed_by,
        where: is_nil(grant.revoked_at)
      )

    repo.update_all(query,
      set: [
        claimed_at: Map.get(recovery, :previous_claimed_at),
        claimed_by: Map.get(recovery, :previous_claimed_by),
        updated_at: now
      ]
    )
  end

  defp grant_action(%AccessGrant{id: id}, existing_grant_ids) when is_binary(id) do
    if id in existing_grant_ids, do: :reconnected, else: :claimed
  end
end
