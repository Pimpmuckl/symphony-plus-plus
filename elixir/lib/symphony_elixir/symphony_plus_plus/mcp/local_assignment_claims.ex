defmodule SymphonyElixir.SymphonyPlusPlus.MCP.LocalAssignmentClaims do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.BranchPattern
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Auth,
    Config,
    LocalArchitectGrantClaim,
    LocalClaimLeases,
    LocalTrustedTools,
    Repository,
    Session,
    ToolCatalog
  }

  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @local_assignment_claim_tool ToolCatalog.local_assignment_claim_tool()
  @local_architect_assignment_claim_tool ToolCatalog.local_architect_assignment_claim_tool()
  @local_assignment_claim_stale_after_ms :timer.minutes(5)

  @spec claim_local_assignment(map(), map(), map()) ::
          {:ok, map(), Session.t()} | {:error, integer(), String.t(), map()}
  def claim_local_assignment(params, %{config: config, session: session} = server, callbacks) do
    with {:ok, arguments} <- worker_tool_arguments(params, @local_assignment_claim_tool),
         {:ok, claim} <- local_assignment_claim_arguments(arguments, server),
         :ok <- require_local_assignment_claim_mode(server),
         :ok <- prepare_mcp_repository(config.repo),
         {:ok, work_package} <- WorkPackageRepository.get(config.repo, claim.work_package_id),
         claim <- hydrate_local_assignment_claim(config.repo, work_package, claim),
         :ok <- validate_local_assignment_scope(config.repo, work_package, claim),
         {:ok, lease, lease_action} <- ensure_local_assignment_claim_lease(config.repo, work_package, claim) do
      case claim_local_assignment_session(config.repo, work_package, claim, lease, lease_action) do
        {:ok, result, new_session, grant_action} ->
          finalize_local_assignment_rebind(config.repo, server, session, claim, lease, lease_action, {result, new_session, grant_action}, callbacks)

        {:error, reason} ->
          release_failed_local_assignment_lease(config.repo, lease, lease_action, reason)
          local_assignment_claim_error(reason)
      end
    else
      {:error, code, message, data} -> {:error, code, message, data}
      {:tool_error, reason} -> invalid_params_error(@local_assignment_claim_tool, reason)
      {:error, reason} -> local_assignment_claim_error(reason)
    end
  rescue
    _error -> {:error, -32_000, "Server error", %{"tool" => @local_assignment_claim_tool, "reason" => "ledger_unavailable"}}
  end

  defp finalize_local_assignment_rebind(
         repo,
         %{} = server,
         old_session,
         claim,
         lease,
         lease_action,
         {result, new_session, grant_action},
         callbacks
       ) do
    with {:ok, result, new_session} <-
           finalize_local_assignment_claim(repo, result, new_session, claim, lease, lease_action, grant_action),
         {:ok, _released_server} <- release_local_assignment_rebind(repo, server, old_session, claim, callbacks) do
      {:ok, result, new_session}
    else
      {:error, code, message, data} ->
        {:error, code, message, data}

      {:error, reason} ->
        rollback_failed_local_assignment_claim(repo, new_session, lease, lease_action, grant_action, reason)
        local_assignment_claim_error(reason)
    end
  end

  defp local_assignment_claim_arguments(arguments, %{} = server) do
    with {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, repo} <- optional_string_argument(arguments, "repo"),
         {:ok, base_branch} <- optional_string_argument(arguments, "base_branch"),
         {:ok, work_request_id} <- optional_string_argument(arguments, "work_request_id"),
         {:ok, branch} <- optional_string_argument(arguments, "branch"),
         {:ok, worktree_path} <- optional_string_argument(arguments, "worktree_path"),
         {:ok, caller_id} <- optional_string_argument(arguments, "caller_id", default_caller_id(server)),
         {:ok, claimed_by} <- optional_string_argument(arguments, "claimed_by", default_claimed_by(server)) do
      {:ok,
       %{
         repo: repo,
         base_branch: base_branch,
         work_package_id: work_package_id,
         work_request_id: work_request_id,
         branch: branch,
         worktree_path: normalize_optional_local_assignment_path(worktree_path),
         mode: local_claim_transport_mode(server),
         caller_id: caller_id,
         claimed_by: claimed_by
       }}
    end
  end

  defp hydrate_local_assignment_claim(repo, %WorkPackage{} = work_package, claim) do
    worktree_path = claim.worktree_path || normalize_optional_local_assignment_path(work_package.worktree_path)
    branch = claim.branch || local_assignment_worktree_branch_or_nil(worktree_path)

    %{
      claim
      | repo: claim.repo || work_package.repo,
        base_branch: claim.base_branch || work_package.base_branch,
        work_request_id: claim.work_request_id || local_assignment_work_request_id(repo, work_package.id),
        branch: branch,
        worktree_path: worktree_path
    }
  end

  defp require_local_assignment_claim_mode(%{initialized: false}), do: {:error, :local_mcp_session_required}

  defp require_local_assignment_claim_mode(%{
         config: %Config{mode: :http, local_daemon_trusted: true} = config,
         local_daemon_trusted: true,
         state_key_explicit: true
       }) do
    LocalTrustedTools.require_database(config)
  end

  defp require_local_assignment_claim_mode(%{config: %Config{mode: :http}, state_key_explicit: false}),
    do: {:error, :local_mcp_session_required}

  defp require_local_assignment_claim_mode(%{config: %Config{mode: :http}}), do: {:error, :local_daemon_trust_required}

  # STDIO MCP servers are local agent processes; HTTP local claims require the
  # explicit trusted-state checks above because that transport has ambient reach.
  defp require_local_assignment_claim_mode(%{}), do: :ok

  defp release_local_assignment_rebind(_repo, %{} = server, nil, _claim, _callbacks), do: {:ok, server}

  defp release_local_assignment_rebind(_repo, %{} = server, %Session{} = session, claim, callbacks) do
    if same_local_assignment_claim?(session, claim) do
      {:ok, server}
    else
      release_bound_session_for_claim_rebind(server, session, @local_assignment_claim_tool, callbacks)
    end
  end

  defp same_local_assignment_claim?(%Session{assignment: assignment}, claim) do
    assignment.grant_role == "worker" and assignment.work_package_id == claim.work_package_id
  end

  defp validate_local_assignment_scope(repo, %WorkPackage{} = work_package, claim) do
    with :ok <- require_local_repo_scope_match(work_package.repo, claim.repo, :repo_scope_mismatch),
         :ok <- require_local_value_match(work_package.base_branch, claim.base_branch, :base_branch_scope_mismatch),
         :ok <- require_optional_local_worktree_scope(work_package, claim.worktree_path),
         :ok <- require_optional_local_branch_scope(work_package, claim.branch, claim.worktree_path),
         :ok <- require_live_local_work_package(work_package) do
      validate_local_work_request_scope(repo, work_package, claim.work_request_id)
    end
  end

  defp require_local_value_match(value, value, _reason) when is_binary(value), do: :ok
  defp require_local_value_match(_expected, _actual, reason), do: {:error, reason}

  defp require_local_repo_scope_match(expected_repo, actual_repo, reason) do
    if repo_scope_name_matches?(expected_repo, actual_repo, []), do: :ok, else: {:error, reason}
  end

  defp require_optional_local_branch_scope(%WorkPackage{}, nil, _worktree_path), do: :ok
  defp require_optional_local_branch_scope(%WorkPackage{} = work_package, branch, worktree_path), do: require_local_branch_scope(work_package, branch, worktree_path)

  defp require_local_branch_scope(%WorkPackage{} = work_package, branch, worktree_path) do
    case local_assignment_worktree_branch(worktree_path) do
      {:ok, ^branch} ->
        require_local_branch_pattern_scope(work_package, branch, prepared_worktree?: true)

      {:ok, _branch} ->
        {:error, :branch_scope_mismatch}

      {:error, :git_metadata_missing} ->
        require_local_branch_pattern_scope(work_package, branch, prepared_worktree?: false)

      {:error, _reason} ->
        {:error, :branch_scope_mismatch}
    end
  end

  defp require_local_branch_pattern_scope(%WorkPackage{branch_pattern: branch_pattern} = work_package, branch, opts) do
    case normalize_optional_value(branch_pattern) do
      nil ->
        :ok

      pattern ->
        case require_supported_branch_pattern(pattern) do
          :ok -> require_local_supported_branch_pattern_scope(work_package, pattern, branch, opts)
          error -> error
        end
    end
  end

  defp require_local_supported_branch_pattern_scope(%WorkPackage{} = work_package, pattern, branch, opts) do
    cond do
      pattern == branch and not local_branch_template_pattern?(pattern) ->
        :ok

      Keyword.get(opts, :prepared_worktree?, false) and local_branch_template_matches?(work_package, pattern, branch) ->
        :ok

      true ->
        {:error, :branch_scope_mismatch}
    end
  end

  defp local_branch_template_pattern?(pattern) when is_binary(pattern) do
    Regex.match?(~r/\{\{\s*[a-zA-Z0-9_]+\s*\}\}/, pattern)
  end

  defp local_branch_template_pattern?(_pattern), do: false

  defp require_supported_branch_pattern(branch_pattern) do
    case BranchPattern.validate(branch_pattern) do
      :ok -> :ok
      {:error, reason} -> {:tool_error, {:branch_pattern, branch_pattern, reason}}
    end
  end

  defp local_branch_template_matches?(%WorkPackage{} = work_package, pattern, branch)
       when is_binary(pattern) and is_binary(branch) do
    case Regex.scan(~r/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/, pattern, return: :index) do
      [] ->
        false

      matches ->
        source = "^" <> local_branch_template_regex_source(pattern, matches, work_package) <> "$"
        Regex.match?(Regex.compile!(source), branch)
    end
  end

  defp local_branch_template_matches?(%WorkPackage{}, _pattern, _branch), do: false

  defp local_branch_template_regex_source(pattern, matches, work_package) do
    {parts, cursor} =
      Enum.reduce(matches, {[], 0}, fn [{match_start, match_length}, {capture_start, capture_length}], {parts, cursor} ->
        literal = pattern |> binary_part(cursor, match_start - cursor) |> Regex.escape()
        placeholder = binary_part(pattern, capture_start, capture_length)
        replacement = local_branch_template_placeholder_regex(work_package, placeholder)

        {[replacement, literal | parts], match_start + match_length}
      end)

    suffix = pattern |> binary_part(cursor, byte_size(pattern) - cursor) |> Regex.escape()
    IO.iodata_to_binary(Enum.reverse([suffix | parts]))
  end

  defp local_branch_template_placeholder_regex(%WorkPackage{} = work_package, placeholder) do
    case placeholder do
      "work_package_id" -> local_branch_template_literal_regex(work_package.id)
      "id" -> local_branch_template_literal_regex(work_package.id)
      "phase_id" -> local_branch_template_literal_regex(work_package.phase_id)
      "parent_id" -> local_branch_template_literal_regex(work_package.parent_id)
      "owner_id" -> local_branch_template_literal_regex(work_package.owner_id)
      _placeholder -> "[^/]+"
    end
  end

  defp local_branch_template_literal_regex(value) do
    case normalize_optional_value(value) do
      nil -> "[^/]+"
      value -> Regex.escape(value)
    end
  end

  @dialyzer {:nowarn_function, local_assignment_worktree_branch: 1}
  @spec local_assignment_worktree_branch(term()) :: {:ok, String.t()} | {:error, atom()}
  defp local_assignment_worktree_branch(worktree_path) do
    case normalize_optional_value(worktree_path) do
      path when is_binary(path) -> local_assignment_worktree_branch_from_path(path)
      _missing -> {:error, :git_metadata_missing}
    end
  end

  defp local_assignment_worktree_branch_from_path(worktree_path) do
    case File.dir?(worktree_path) do
      true ->
        with {:ok, git_dir} <- local_assignment_git_dir(worktree_path),
             {:ok, head} <- File.read(Path.join(git_dir, "HEAD")),
             {:ok, branch} <- local_assignment_head_branch(head) do
          {:ok, branch}
        else
          {:error, :enoent} -> {:error, :git_metadata_missing}
          {:error, reason} -> {:error, reason}
        end

      false ->
        {:error, :git_metadata_missing}
    end
  end

  defp local_assignment_git_dir(worktree_path) do
    dot_git = Path.join(worktree_path, ".git")

    cond do
      File.dir?(dot_git) ->
        {:ok, dot_git}

      File.regular?(dot_git) ->
        dot_git
        |> File.read()
        |> local_assignment_git_dir_from_file(worktree_path)

      true ->
        {:error, :git_metadata_missing}
    end
  end

  defp local_assignment_git_dir_from_file({:ok, contents}, worktree_path) do
    case contents |> String.trim() |> String.split(":", parts: 2) do
      ["gitdir", git_dir] -> {:ok, Path.expand(String.trim(git_dir), worktree_path)}
      _contents -> {:error, :git_metadata_invalid}
    end
  end

  defp local_assignment_git_dir_from_file({:error, reason}, _worktree_path), do: {:error, reason}

  defp local_assignment_head_branch(head) when is_binary(head) do
    case String.trim(head) do
      "ref: refs/heads/" <> branch when branch != "" -> {:ok, branch}
      _detached_or_invalid -> {:error, :git_head_invalid}
    end
  end

  defp require_local_worktree_scope(%WorkPackage{worktree_path: worktree_path}, claim_worktree_path) do
    case normalize_optional_value(worktree_path) do
      nil ->
        {:error, :worktree_scope_required}

      expected_worktree_path ->
        if normalize_local_assignment_path(expected_worktree_path) == claim_worktree_path do
          :ok
        else
          {:error, :worktree_scope_mismatch}
        end
    end
  end

  defp require_optional_local_worktree_scope(%WorkPackage{}, nil), do: :ok
  defp require_optional_local_worktree_scope(%WorkPackage{} = work_package, claim_worktree_path), do: require_local_worktree_scope(work_package, claim_worktree_path)

  defp require_live_local_work_package(%WorkPackage{status: status})
       when status in ["merged", "merged_into_phase", "closed", "abandoned"] do
    {:error, :work_package_terminal}
  end

  defp require_live_local_work_package(%WorkPackage{}), do: :ok

  defp validate_local_work_request_scope(_repo, %WorkPackage{}, nil), do: :ok

  defp validate_local_work_request_scope(repo, %WorkPackage{} = work_package, work_request_id) do
    with {:ok, work_request} <- WorkRequestRepository.get(repo, work_request_id),
         {:ok, work_package} <- local_work_request_package_link(repo, work_request_id, work_package.id),
         :ok <-
           require_local_value_match(
             WorkPackage.repo(work_request, work_package),
             work_package.repo,
             :work_request_repo_scope_mismatch
           ),
         :ok <-
           require_local_value_match(
             work_package.base_branch,
             work_package.base_branch,
             :package_delivery_base_mismatch
           ) do
      :ok
    else
      {:error, :not_found} -> {:error, :work_request_scope_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp local_work_request_package_link(repo, work_request_id, work_package_id) do
    case repo.one(
           from(work_package in WorkPackage,
             where: work_package.work_request_id == ^work_request_id,
             where: work_package.id == ^work_package_id,
             limit: 1
           )
         ) do
      %WorkPackage{} = work_package -> {:ok, work_package}
      nil -> {:error, :work_request_package_link_mismatch}
    end
  end

  defp ensure_local_assignment_claim_lease(repo, %WorkPackage{} = work_package, claim) do
    LocalClaimLeases.ensure(
      repo,
      work_package.id,
      LocalClaimLeases.worker_actor(claim),
      @local_assignment_claim_stale_after_ms,
      "local_assignment_claim_stale"
    )
  end

  defp claim_local_assignment_session(repo, %WorkPackage{} = work_package, claim, %ClaimLease{} = lease, lease_action) do
    claim_now = DateTime.utc_now(:microsecond)
    existing_grant_ids = local_assignment_active_worker_grant_ids(repo, work_package.id, claim.claimed_by, claim_now)

    with {:ok, grant, grant_action} <-
           LocalClaimLeases.claim_worker_grant(repo, work_package.id, claim, lease, lease_action, existing_grant_ids, claim_now),
         {:ok, session} <- Auth.session_from_grant(repo, grant, proof_hash: grant.secret_hash),
         :ok <- require_worker_assignment(session.assignment) do
      assignment = %{"assignment" => Session.public_assignment(session)}
      {:ok, assignment, session, grant_action}
    end
  end

  @spec local_assignment_active_worker_grant_ids(module(), String.t(), String.t(), DateTime.t()) :: [String.t()]
  defp local_assignment_active_worker_grant_ids(repo, work_package_id, claimed_by, %DateTime{} = now)
       when is_atom(repo) and is_binary(work_package_id) and is_binary(claimed_by) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.grant_role == "worker",
        where: grant.claimed_by == ^claimed_by,
        where: not is_nil(grant.claimed_at),
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        select: grant.id
      )

    repo.all(query)
  end

  defp local_assignment_active_worker_grant_ids(_repo, _work_package_id, _claimed_by, %DateTime{}), do: []

  defp finalize_local_assignment_claim(repo, result, %Session{} = session, claim, %ClaimLease{} = lease, lease_action, grant_action) do
    session = Session.with_claim_lease(session, lease)

    case append_local_assignment_claim_event(repo, session, claim, lease, lease_action) do
      {:ok, claim_event} ->
        {:ok, Map.put(result, "local_claim", local_assignment_claim_payload(claim, lease, lease_action, claim_event)), session}

      {:error, reason} ->
        rollback_failed_local_assignment_claim(repo, session, lease, lease_action, grant_action, reason)
        local_assignment_claim_error(reason)
    end
  end

  defp rollback_failed_local_assignment_claim(repo, %Session{} = session, %ClaimLease{} = lease, lease_action, grant_action, reason) do
    release_failed_local_assignment_lease(repo, lease, lease_action, reason)
    revoke_failed_local_assignment_grant(repo, session, lease_action, grant_action)
  end

  defp revoke_failed_local_assignment_grant(repo, %Session{assignment: %{grant_id: grant_id}}, lease_action, :claimed)
       when lease_action in [:created, :reclaimed] and is_binary(grant_id) do
    _result = AccessGrantService.revoke(repo, grant_id)
    :ok
  end

  defp revoke_failed_local_assignment_grant(repo, %Session{}, :reclaimed, {:recovered, recovery}) do
    _result = LocalClaimLeases.rollback_worker_grant_recovery(repo, recovery)
    :ok
  end

  defp revoke_failed_local_assignment_grant(_repo, %Session{}, _lease_action, _grant_action), do: :ok

  defp local_assignment_claim_payload(claim, %ClaimLease{} = lease, lease_action, claim_event) do
    %{
      "tool" => @local_assignment_claim_tool,
      "mode" => claim.mode,
      "repo" => claim.repo,
      "base_branch" => claim.base_branch,
      "work_package_id" => claim.work_package_id,
      "work_request_id" => claim.work_request_id,
      "branch" => claim.branch,
      "worktree_path" => claim.worktree_path,
      "caller_id" => claim.caller_id,
      "claimed_by" => claim.claimed_by,
      "claim_lease_id" => lease.id,
      "claim_lease_status" => lease.status,
      "claim_lease_action" => Atom.to_string(lease_action),
      "lifecycle_state" => "active",
      "reason_codes" => local_assignment_claim_reason_codes(lease_action, lease)
    }
    |> drop_nil_values()
    |> maybe_put_claim_event(claim_event)
  end

  defp append_local_assignment_claim_event(_repo, %Session{}, _claim, %ClaimLease{}, lease_action) when lease_action != :reclaimed, do: {:ok, nil}

  defp append_local_assignment_claim_event(repo, %Session{} = session, claim, %ClaimLease{} = lease, :reclaimed) do
    payload = local_assignment_claim_reclaim_payload(claim, lease)

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, claim.work_package_id, %{
      "summary" => "Local assignment claim lease reclaimed",
      "body" => "Local assignment claim lease was reclaimed for #{claim.claimed_by}.",
      "status" => "claim_lease_reclaimed",
      "idempotency_key" => metadata_idempotency_key(payload),
      "payload" => payload
    })
  end

  defp local_assignment_claim_reclaim_payload(claim, %ClaimLease{} = lease) do
    %{
      "type" => "claim_lease_reclaim",
      "source_tool" => @local_assignment_claim_tool,
      "work_package_id" => claim.work_package_id,
      "work_request_id" => claim.work_request_id,
      "claim_lease_id" => lease.id,
      "claim_group_id" => lease.claim_group_id,
      "previous_claim_id" => lease.previous_claim_id,
      "claim_lease_status" => lease.status,
      "claim_lease_action" => "reclaimed",
      "claimed_by" => claim.claimed_by,
      "caller_id" => claim.caller_id,
      "lifecycle_state" => "active",
      "reason_codes" => local_assignment_claim_reason_codes(:reclaimed, lease)
    }
    |> drop_nil_values()
  end

  defp maybe_put_claim_event(payload, nil), do: payload

  defp maybe_put_claim_event(payload, %ProgressEvent{} = event) do
    Map.put(payload, "claim_event", progress_event_payload(event))
  end

  defp local_assignment_claim_reason_codes(lease_action, %ClaimLease{} = lease) do
    [
      "claim_lease_#{lease_action}",
      if(lease.previous_claim_id, do: "worker_recycled")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp release_failed_local_assignment_lease(repo, %ClaimLease{} = lease, lease_action, _reason)
       when lease_action in [:created, :reclaimed] do
    _result = ClaimLeaseService.release(repo, lease.id, reason: "local_assignment_claim_failed")
    :ok
  end

  defp release_failed_local_assignment_lease(repo, %ClaimLease{} = lease, :heartbeat, reason)
       when reason in [:expired, :revoked, :worker_grant_required] do
    _result = ClaimLeaseService.release(repo, lease.id, reason: "local_assignment_claim_failed")
    :ok
  end

  defp release_failed_local_assignment_lease(_repo, %ClaimLease{}, _lease_action, _reason), do: :ok

  @spec claim_local_architect_assignment(map(), map(), map()) ::
          {:ok, map(), Session.t()} | {:error, integer(), String.t(), map()}
  def claim_local_architect_assignment(params, %{config: config, session: session} = server, callbacks) do
    with {:ok, arguments} <- local_architect_assignment_claim_tool_arguments(params),
         {:ok, claim} <- local_architect_assignment_claim_arguments(arguments, server),
         :ok <- require_local_architect_assignment_claim_mode(server),
         :ok <- prepare_mcp_repository(config.repo),
         {:ok, work_request} <- WorkRequestRepository.get(config.repo, claim.work_request_id),
         :ok <- require_local_architect_assignment_work_request_claimable(work_request),
         claim <- hydrate_local_architect_assignment_claim(work_request, claim),
         {:ok, anchor} <- require_local_architect_handoff_anchor(config, work_request, claim, callbacks),
         :ok <- validate_local_architect_assignment_scope(work_request, anchor, claim),
         {:ok, lease, lease_action} <- ensure_local_architect_assignment_claim_lease(config.repo, anchor, claim) do
      case claim_local_architect_assignment_session(config.repo, anchor, claim, lease_action) do
        {:ok, result, new_session, grant_action} ->
          finalize_local_architect_assignment_rebind(config.repo, server, session, claim, lease, lease_action, {result, new_session, grant_action}, callbacks)

        {:error, reason} ->
          release_failed_local_architect_assignment_lease(config.repo, lease, lease_action, reason)
          local_architect_assignment_claim_error(reason)
      end
    else
      {:error, code, message, data} -> {:error, code, message, data}
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => @local_architect_assignment_claim_tool, "reason" => reason}}
      {:error, reason} -> local_architect_assignment_claim_error(reason)
    end
  rescue
    _error -> {:error, -32_000, "Server error", %{"tool" => @local_architect_assignment_claim_tool, "reason" => "ledger_unavailable"}}
  end

  defp finalize_local_architect_assignment_rebind(
         repo,
         %{} = server,
         old_session,
         claim,
         lease,
         lease_action,
         {result, new_session, grant_action},
         callbacks
       ) do
    with {:ok, result, new_session} <-
           finalize_local_architect_assignment_claim(
             repo,
             result,
             new_session,
             claim,
             lease,
             lease_action,
             grant_action
           ),
         {:ok, _released_server} <-
           release_local_architect_assignment_rebind(repo, server, old_session, claim, callbacks) do
      {:ok, result, new_session}
    else
      {:error, code, message, data} ->
        {:error, code, message, data}

      {:error, reason} ->
        rollback_failed_local_architect_assignment_claim(repo, new_session, lease, lease_action, grant_action, reason)
        local_architect_assignment_claim_error(reason)
    end
  end

  defp local_architect_assignment_claim_arguments(arguments, %{} = server) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, anchor_id} <- optional_string_argument(arguments, "architect_anchor_work_package_id"),
         {:ok, repo} <- optional_string_argument(arguments, "repo"),
         {:ok, base_branch} <- optional_string_argument(arguments, "base_branch"),
         {:ok, phase_id} <- optional_string_argument(arguments, "phase_id"),
         {:ok, caller_id} <- optional_string_argument(arguments, "caller_id", default_caller_id(server)),
         {:ok, claimed_by} <- optional_string_argument(arguments, "claimed_by", default_architect_claimed_by(server)) do
      {:ok,
       %{
         work_request_id: work_request_id,
         architect_anchor_work_package_id: anchor_id,
         repo: repo,
         base_branch: base_branch,
         phase_id: phase_id,
         mode: local_claim_transport_mode(server),
         caller_id: caller_id,
         claimed_by: claimed_by
       }}
    end
  end

  defp hydrate_local_architect_assignment_claim(%WorkRequest{} = work_request, claim) do
    anchor_id = claim.architect_anchor_work_package_id || ArchitectHandoff.anchor_id_for_work_request(work_request)

    %{
      claim
      | architect_anchor_work_package_id: anchor_id,
        repo: claim.repo || work_request.repo,
        base_branch: claim.base_branch || work_request.base_branch,
        phase_id: claim.phase_id || ArchitectHandoff.phase_id_for_work_request(work_request)
    }
  end

  defp require_local_architect_assignment_work_request_claimable(%WorkRequest{archived_at: %DateTime{}}),
    do: {:error, {:work_request_terminal, :archived}}

  defp require_local_architect_assignment_work_request_claimable(%WorkRequest{
         completed_at: %DateTime{},
         completion_source: "operator"
       }),
       do: {:error, {:work_request_terminal, :completed}}

  defp require_local_architect_assignment_work_request_claimable(%WorkRequest{}), do: :ok

  defp require_local_architect_assignment_claim_mode(%{config: config} = server) do
    with :ok <- require_local_assignment_claim_mode(server) do
      LocalTrustedTools.require_database(config)
    end
  end

  defp release_local_architect_assignment_rebind(_repo, %{} = server, nil, _claim, _callbacks), do: {:ok, server}

  defp release_local_architect_assignment_rebind(_repo, %{} = server, %Session{} = session, claim, callbacks) do
    if same_local_architect_assignment_claim?(session, claim) do
      {:ok, server}
    else
      release_bound_session_for_claim_rebind(server, session, @local_architect_assignment_claim_tool, callbacks)
    end
  end

  defp same_local_architect_assignment_claim?(%Session{assignment: assignment}, claim) do
    assignment.grant_role == "architect" and assignment.work_package_id == claim.architect_anchor_work_package_id
  end

  defp release_bound_session_for_claim_rebind(%{} = server, %Session{} = session, tool, callbacks) do
    current_assignment = current_assignment_summary(callbacks, server.config.repo, session)

    case release_current_assignment(callbacks, %{"reason" => tool}, server) do
      {:ok, result, %{} = released_server} ->
        if auto_rebind_release_cleared?(result),
          do: {:ok, released_server},
          else: {:error, {:session_already_bound, current_assignment}}

      {:tool_error, reason} ->
        {:error, reason}
    end
  end

  defp auto_rebind_release_cleared?(%{"binding_cleared" => true, "fresh_mcp_session_required" => false}), do: true
  defp auto_rebind_release_cleared?(_result), do: false

  defp validate_local_architect_assignment_scope(%WorkRequest{} = work_request, %WorkPackage{} = anchor, claim) do
    expected_phase_id = ArchitectHandoff.phase_id_for_work_request(work_request)

    with :ok <- require_local_repo_scope_match(work_request.repo, claim.repo, :repo_scope_mismatch),
         :ok <- require_local_value_match(work_request.base_branch, claim.base_branch, :base_branch_scope_mismatch),
         :ok <- require_local_repo_scope_match(anchor.repo, work_request.repo, :architect_anchor_scope_mismatch),
         :ok <-
           require_local_value_match(
             anchor.base_branch,
             work_request.base_branch,
             :architect_anchor_scope_mismatch
           ),
         :ok <-
           require_local_value_match(
             anchor.id,
             ArchitectHandoff.anchor_id_for_work_request(work_request),
             :architect_anchor_scope_mismatch
           ),
         :ok <- require_local_value_match(anchor.phase_id, expected_phase_id, :phase_scope_mismatch),
         :ok <- require_optional_phase_scope(claim.phase_id, expected_phase_id),
         :ok <- require_architect_handoff_anchor_kind(anchor) do
      require_live_local_work_package(anchor)
    end
  end

  defp require_local_architect_handoff_anchor(%Config{} = config, %WorkRequest{} = work_request, claim, callbacks) do
    repo = config.repo
    expected_anchor_id = ArchitectHandoff.anchor_id_for_work_request(work_request)
    expected_phase_id = ArchitectHandoff.phase_id_for_work_request(work_request)

    with :ok <- require_local_repo_scope_match(work_request.repo, claim.repo, :repo_scope_mismatch),
         :ok <- require_local_value_match(work_request.base_branch, claim.base_branch, :base_branch_scope_mismatch),
         :ok <-
           require_local_value_match(
             expected_anchor_id,
             claim.architect_anchor_work_package_id,
             :architect_anchor_scope_mismatch
           ),
         :ok <- require_optional_phase_scope(claim.phase_id, expected_phase_id) do
      case WorkPackageRepository.get(repo, expected_anchor_id) do
        {:ok, %WorkPackage{} = anchor} ->
          {:ok, anchor}

        {:error, :not_found} ->
          create_local_architect_handoff_anchor(config, work_request, claim, expected_anchor_id, callbacks)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp create_local_architect_handoff_anchor(%Config{} = config, %WorkRequest{} = work_request, claim, expected_anchor_id, callbacks) do
    with {:ok, handoff_opts} <- create_work_request_handoff_opts(callbacks, config, claim.claimed_by),
         {:ok, _handoff} <-
           ArchitectHandoff.create_or_replay(config.repo, work_request.id,
             local_operator?: true,
             local_architect_claim?: true,
             handoff_opts: handoff_opts
           ) do
      WorkPackageRepository.get(config.repo, expected_anchor_id)
    end
  end

  defp require_optional_phase_scope(nil, _expected_phase_id), do: :ok
  defp require_optional_phase_scope(phase_id, phase_id) when is_binary(phase_id), do: :ok
  defp require_optional_phase_scope(_phase_id, _expected_phase_id), do: {:error, :phase_scope_mismatch}

  defp require_architect_handoff_anchor_kind(%WorkPackage{kind: "delegation"}), do: :ok
  defp require_architect_handoff_anchor_kind(%WorkPackage{}), do: {:error, :architect_anchor_scope_mismatch}

  defp ensure_local_architect_assignment_claim_lease(repo, %WorkPackage{} = anchor, claim) do
    LocalClaimLeases.ensure(
      repo,
      anchor.id,
      LocalClaimLeases.architect_actor(claim),
      @local_assignment_claim_stale_after_ms,
      "local_architect_assignment_claim_stale"
    )
  end

  defp claim_local_architect_assignment_session(repo, %WorkPackage{} = anchor, claim, lease_action) do
    validate_grant = &validate_local_architect_assignment_grant(repo, &1, anchor, claim)

    with {:ok, grant, grant_action} <- LocalArchitectGrantClaim.claim(repo, anchor, claim, lease_action, validate_grant),
         :ok <- validate_local_architect_assignment_grant(repo, grant, anchor, claim),
         {:ok, session} <- Auth.session_from_grant(repo, grant, proof_hash: grant.secret_hash),
         :ok <- require_architect_assignment(session.assignment) do
      assignment = %{"assignment" => Session.public_assignment(session)}
      {:ok, assignment, session, grant_action}
    end
  end

  defp validate_local_architect_assignment_grant(repo, %AccessGrant{} = grant, %WorkPackage{} = anchor, claim) do
    with :ok <- require_local_value_match(grant.work_package_id, anchor.id, :architect_grant_scope_mismatch),
         :ok <- require_local_value_match(grant.phase_id, anchor.phase_id, :architect_grant_scope_mismatch),
         :ok <- require_local_repo_scope_match(grant.scope_repo, claim.repo, :architect_grant_scope_mismatch),
         :ok <- require_local_value_match(grant.scope_base_branch, claim.base_branch, :architect_grant_scope_mismatch),
         :ok <- AccessGrantService.require_live_package_authority(repo, grant) do
      require_local_architect_handoff_grant(repo, grant)
    end
  end

  defp require_local_architect_handoff_grant(repo, %AccessGrant{} = grant) do
    case ArchitectHandoff.handoff_phase_grant?(repo, grant) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :architect_grant_scope_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finalize_local_architect_assignment_claim(repo, result, %Session{} = session, claim, %ClaimLease{} = lease, lease_action, grant_action) do
    session = Session.with_claim_lease(session, lease)

    case append_local_architect_assignment_claim_event(repo, session, claim, lease, lease_action) do
      {:ok, claim_event} ->
        {:ok, Map.put(result, "local_claim", local_architect_assignment_claim_payload(claim, lease, lease_action, claim_event)), session}

      {:error, reason} ->
        rollback_failed_local_architect_assignment_claim(repo, session, lease, lease_action, grant_action, reason)
        local_architect_assignment_claim_error(reason)
    end
  end

  defp rollback_failed_local_architect_assignment_claim(repo, %Session{} = session, %ClaimLease{} = lease, lease_action, grant_action, reason) do
    LocalArchitectGrantClaim.rollback_failed_claim(repo, grant_action)
    release_failed_local_architect_assignment_lease(repo, lease, lease_action, reason)
    revoke_failed_local_architect_assignment_grant(repo, session, lease_action, grant_action)
  end

  defp revoke_failed_local_architect_assignment_grant(repo, %Session{assignment: %{grant_id: grant_id}}, lease_action, :claimed)
       when lease_action in [:created, :reclaimed] and is_binary(grant_id) do
    _result = AccessGrantService.revoke(repo, grant_id)
    :ok
  end

  defp revoke_failed_local_architect_assignment_grant(_repo, %Session{}, _lease_action, _grant_action), do: :ok

  defp local_architect_assignment_claim_payload(claim, %ClaimLease{} = lease, lease_action, claim_event) do
    %{
      "tool" => @local_architect_assignment_claim_tool,
      "mode" => claim.mode,
      "repo" => claim.repo,
      "base_branch" => claim.base_branch,
      "work_request_id" => claim.work_request_id,
      "architect_anchor_work_package_id" => claim.architect_anchor_work_package_id,
      "phase_id" => claim.phase_id,
      "caller_id" => claim.caller_id,
      "claimed_by" => claim.claimed_by,
      "claim_lease_id" => lease.id,
      "claim_lease_status" => lease.status,
      "claim_lease_action" => Atom.to_string(lease_action),
      "lifecycle_state" => "active",
      "reason_codes" => local_architect_assignment_claim_reason_codes(lease_action, lease)
    }
    |> drop_nil_values()
    |> maybe_put_claim_event(claim_event)
  end

  defp append_local_architect_assignment_claim_event(_repo, %Session{}, _claim, %ClaimLease{}, lease_action) when lease_action != :reclaimed,
    do: {:ok, nil}

  defp append_local_architect_assignment_claim_event(repo, %Session{} = session, claim, %ClaimLease{} = lease, :reclaimed) do
    payload = local_architect_assignment_claim_reclaim_payload(claim, lease)

    PlanningRepository.append_audit_progress_event_for_work_package(
      repo,
      session.assignment,
      claim.architect_anchor_work_package_id,
      %{
        "summary" => "Local architect assignment claim lease reclaimed",
        "body" => "Local architect assignment claim lease was reclaimed for #{claim.claimed_by}.",
        "status" => "claim_lease_reclaimed",
        "idempotency_key" => metadata_idempotency_key(payload),
        "payload" => payload
      }
    )
  end

  defp local_architect_assignment_claim_reclaim_payload(claim, %ClaimLease{} = lease) do
    %{
      "type" => "claim_lease_reclaim",
      "source_tool" => @local_architect_assignment_claim_tool,
      "work_request_id" => claim.work_request_id,
      "architect_anchor_work_package_id" => claim.architect_anchor_work_package_id,
      "phase_id" => claim.phase_id,
      "claim_lease_id" => lease.id,
      "claim_group_id" => lease.claim_group_id,
      "previous_claim_id" => lease.previous_claim_id,
      "claim_lease_status" => lease.status,
      "claim_lease_action" => "reclaimed",
      "claimed_by" => claim.claimed_by,
      "caller_id" => claim.caller_id,
      "lifecycle_state" => "active",
      "reason_codes" => local_architect_assignment_claim_reason_codes(:reclaimed, lease)
    }
    |> drop_nil_values()
  end

  defp local_architect_assignment_claim_reason_codes(lease_action, %ClaimLease{} = lease) do
    [
      "claim_lease_#{lease_action}",
      if(lease.previous_claim_id, do: "architect_recycled")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp release_failed_local_architect_assignment_lease(repo, %ClaimLease{} = lease, lease_action, _reason)
       when lease_action in [:created, :reclaimed] do
    _result = ClaimLeaseService.release(repo, lease.id, reason: "local_architect_assignment_claim_failed")
    :ok
  end

  defp release_failed_local_architect_assignment_lease(repo, %ClaimLease{} = lease, :heartbeat, reason)
       when reason in [:expired, :revoked, :architect_grant_required, :already_claimed] do
    _result = ClaimLeaseService.release(repo, lease.id, reason: "local_architect_assignment_claim_failed")
    :ok
  end

  defp release_failed_local_architect_assignment_lease(_repo, %ClaimLease{}, _lease_action, _reason), do: :ok

  defp default_claimed_by(%{config: %Config{claimed_by: claimed_by}}) do
    case normalize_optional_value(claimed_by) do
      claimed_by when is_binary(claimed_by) -> claimed_by
      nil -> "local-agent"
    end
  end

  defp default_architect_claimed_by(%{}), do: ArchitectHandoff.claimed_by()

  defp default_caller_id(%{state_key_explicit: true} = server) do
    material =
      :erlang.term_to_binary({server.config.mode, server.state_key})

    "mcp-state:" <> LocalClaimLeases.actor_hash(material)
  end

  defp default_caller_id(%{config: %Config{mode: mode}}), do: "mcp-#{mode}:default"

  defp local_claim_transport_mode(%{config: %Config{mode: :http}}), do: "local-http"
  defp local_claim_transport_mode(%{config: %Config{mode: :stdio}}), do: "stdio"

  defp local_assignment_work_request_id(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    repo.one(
      from(work_package in WorkPackage,
        where: work_package.id == ^work_package_id,
        order_by: [desc: work_package.dispatched_at, desc: work_package.updated_at, asc: work_package.id],
        select: work_package.work_request_id,
        limit: 1
      )
    )
  end

  defp local_assignment_worktree_branch_or_nil(nil), do: nil

  defp local_assignment_worktree_branch_or_nil(worktree_path) do
    case local_assignment_worktree_branch(worktree_path) do
      {:ok, branch} -> branch
      {:error, _reason} -> nil
    end
  end

  defp normalize_optional_local_assignment_path(nil), do: nil

  defp normalize_optional_local_assignment_path(path) when is_binary(path) do
    path
    |> normalize_optional_value()
    |> case do
      nil -> nil
      normalized -> normalize_local_assignment_path(normalized)
    end
  end

  defp normalize_local_assignment_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> Path.expand()
    |> normalize_local_assignment_path_case()
  end

  defp normalize_local_assignment_path_case(path) do
    case :os.type() do
      {:win32, _name} -> String.downcase(path)
      _type -> path
    end
  end

  defp local_assignment_claim_error(:database_busy), do: service_error(:database_busy, @local_assignment_claim_tool)
  defp local_assignment_claim_error({:service_unavailable, _reason} = reason), do: service_error(reason, @local_assignment_claim_tool)
  defp local_assignment_claim_error({:storage_failed, _reason} = reason), do: service_error(reason, @local_assignment_claim_tool)
  defp local_assignment_claim_error({:migration_failed, _reason} = reason), do: service_error(reason, @local_assignment_claim_tool)

  defp local_assignment_claim_error({:session_already_bound, current_assignment}) do
    {:error, -32_001, "Unauthorized", session_already_bound_data(@local_assignment_claim_tool, current_assignment)}
  end

  defp local_assignment_claim_error(:claim_lease_active_for_other_actor) do
    {:error, -32_001, "Unauthorized",
     claim_lease_active_for_other_actor_data(
       @local_assignment_claim_tool,
       "Reuse the same work_package_id and claimed_by. If the live claim belongs to another owner or is stale, ask the architect or operator to recycle it."
     )}
  end

  defp local_assignment_claim_error(reason) do
    {:error, -32_001, "Unauthorized", %{"tool" => @local_assignment_claim_tool, "reason" => reason_text(reason)}}
  end

  defp local_architect_assignment_claim_error(:database_busy), do: service_error(:database_busy, @local_architect_assignment_claim_tool)

  defp local_architect_assignment_claim_error({:service_unavailable, _reason} = reason),
    do: service_error(reason, @local_architect_assignment_claim_tool)

  defp local_architect_assignment_claim_error({:storage_failed, _reason} = reason),
    do: service_error(reason, @local_architect_assignment_claim_tool)

  defp local_architect_assignment_claim_error({:migration_failed, _reason} = reason),
    do: service_error(reason, @local_architect_assignment_claim_tool)

  defp local_architect_assignment_claim_error({:session_already_bound, current_assignment}) do
    {:error, -32_001, "Unauthorized", session_already_bound_data(@local_architect_assignment_claim_tool, current_assignment)}
  end

  defp local_architect_assignment_claim_error(:claim_lease_active_for_other_actor) do
    {:error, -32_001, "Unauthorized",
     claim_lease_active_for_other_actor_data(
       @local_architect_assignment_claim_tool,
       "Reuse the same work_request_id and claimed_by. If the live claim belongs to another owner or is stale, ask the operator to recycle it."
     )}
  end

  defp local_architect_assignment_claim_error({:phase_scope_not_available, missing_evidence}) do
    {:error, -32_001, "Unauthorized", local_architect_phase_scope_not_available_data(missing_evidence)}
  end

  defp local_architect_assignment_claim_error(:phase_scope_not_available) do
    {:error, -32_001, "Unauthorized", local_architect_phase_scope_not_available_data([:architect_handoff_scope])}
  end

  defp local_architect_assignment_claim_error(:ambiguous_phase_scope) do
    {:error, -32_001, "Unauthorized",
     %{
       "tool" => @local_architect_assignment_claim_tool,
       "reason" => "ambiguous_phase_scope",
       "action" => "repair_local_architect_handoff_scope",
       "missing_evidence" => ["single_work_request_scope"],
       "hint" => "Keep exactly one WorkRequest scope on the architect handoff grant, or replay architect handoff from the local operator for the intended WorkRequest."
     }}
  end

  defp local_architect_assignment_claim_error({:work_request_terminal, terminal_state}) do
    {:error, -32_001, "Unauthorized",
     %{
       "tool" => @local_architect_assignment_claim_tool,
       "reason" => "work_request_terminal",
       "terminal_state" => reason_text(terminal_state),
       "action" => "restore_work_request_or_start_new_work_request",
       "hint" => "Restore the WorkRequest from the local operator if this lane should continue, or start a new WorkRequest for follow-up work."
     }}
  end

  defp local_architect_assignment_claim_error(reason) do
    {:error, -32_001, "Unauthorized", %{"tool" => @local_architect_assignment_claim_tool, "reason" => reason_text(reason)}}
  end

  defp local_architect_phase_scope_not_available_data(missing_evidence) do
    %{
      "tool" => @local_architect_assignment_claim_tool,
      "reason" => "phase_scope_not_available",
      "action" => "repair_local_architect_handoff_scope",
      "missing_evidence" => Enum.map(List.wrap(missing_evidence), &reason_text/1),
      "hint" =>
        "Use the local operator to restore the WorkRequest if it was archived, or replay architect handoff so the anchor package, grant, repo, base branch, phase id, and WorkRequest scope agree."
    }
  end

  defp claim_lease_active_for_other_actor_data(tool, hint) do
    %{
      "tool" => tool,
      "reason" => "claim_lease_active_for_other_actor",
      "action" => "reuse_claim_identity_or_recycle_stale_claim",
      "hint" => hint
    }
  end

  defp session_already_bound_data(tool, current_assignment) when is_map(current_assignment) do
    tool
    |> session_already_bound_data(nil)
    |> Map.put("current_assignment", current_assignment)
  end

  defp session_already_bound_data(tool, _current_assignment) do
    %{
      "tool" => tool,
      "reason" => "session_already_bound",
      "action" => "use_fresh_mcp_session_or_release_current_assignment",
      "hint" => "This MCP session is already bound. Start a fresh MCP session for a different assignment, or call release_current_assignment only if abandoning the current binding."
    }
  end

  defp worker_tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) -> validate_worker_arguments(name, arguments)
      _arguments -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp local_architect_assignment_claim_tool_arguments(params) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) -> validate_local_architect_assignment_claim_arguments(arguments)
      _arguments -> {:error, -32_602, "Invalid params", %{"tool" => @local_architect_assignment_claim_tool, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp validate_worker_arguments(name, arguments) do
    allowed = MapSet.new(allowed_worker_argument_keys(name))
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected == [] do
      {:ok, arguments}
    else
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    end
  end

  defp validate_local_architect_assignment_claim_arguments(arguments) do
    schema = ToolCatalog.local_architect_assignment_claim_tool_input_schema()
    allowed = schema |> Map.get("properties", %{}) |> Map.keys() |> MapSet.new()
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected != [] do
      {:error, -32_602, "Invalid params", %{"tool" => @local_architect_assignment_claim_tool, "reason" => "unexpected_argument", "arguments" => unexpected}}
    else
      case validate_tool_required_arguments(schema, arguments) do
        :ok -> {:ok, arguments}
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => @local_architect_assignment_claim_tool, "reason" => reason}}
      end
    end
  end

  defp allowed_worker_argument_keys(name) do
    name
    |> ToolCatalog.worker_tool_input_schema()
    |> Map.get("properties", %{})
    |> Map.keys()
    |> Kernel.++(ToolCatalog.hidden_worker_argument_keys(name))
  end

  defp validate_tool_required_arguments(schema, arguments) do
    properties = Map.get(schema, "properties", %{})

    schema
    |> Map.get("required", [])
    |> Enum.find_value(:ok, fn key ->
      case validate_required_argument(arguments, properties, key) do
        :ok -> nil
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp validate_required_argument(arguments, properties, key) do
    case Map.fetch(arguments, key) do
      :error -> {:error, "missing_#{key}"}
      {:ok, nil} -> {:error, "missing_#{key}"}
      {:ok, value} -> validate_required_argument_value(properties, key, value)
    end
  end

  defp validate_required_argument_value(properties, key, value) do
    case get_in(properties, [key, "type"]) do
      "string" -> validate_required_string_argument(key, value)
      "object" -> validate_required_object_argument(key, value)
      "array" -> validate_required_array_argument_value(properties, key, value)
      _type -> {:error, "invalid_#{key}"}
    end
  end

  defp validate_required_string_argument(key, value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, "missing_#{key}"}, else: :ok
  end

  defp validate_required_string_argument(key, _value), do: {:error, "invalid_#{key}"}
  defp validate_required_object_argument(_key, value) when is_map(value), do: :ok
  defp validate_required_object_argument(key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_array_argument_value(properties, key, values) when is_list(values) do
    validate_required_array_argument(properties, key, values)
  end

  defp validate_required_array_argument_value(_properties, key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_array_argument(properties, key, values) do
    cond do
      properties |> Map.get(key, %{}) |> Map.get("minItems", 0) > 0 and values == [] ->
        {:error, "missing_#{key}"}

      get_in(properties, [key, "items", "type"]) == "string" ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")), do: :ok, else: {:error, "invalid_#{key}"}

      true ->
        if Enum.all?(values, &is_map/1), do: :ok, else: {:error, "invalid_#{key}"}
    end
  end

  defp required_argument(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "missing_#{key}"}
    end
  end

  defp optional_string_argument(arguments, key, default \\ nil) do
    case Map.fetch(arguments, key) do
      :error ->
        {:ok, default}

      {:ok, nil} ->
        {:ok, default}

      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, default}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _value} ->
        {:tool_error, "invalid_#{key}"}
    end
  end

  defp require_worker_assignment(%{grant_role: "worker"}), do: :ok
  defp require_worker_assignment(_assignment), do: {:error, :worker_grant_required}

  defp require_architect_assignment(%{grant_role: "architect"}), do: :ok
  defp require_architect_assignment(_assignment), do: {:error, :architect_grant_required}

  defp prepare_mcp_repository(repo), do: Repository.ensure_migrated(repo)

  defp invalid_params_error(tool, {:branch_pattern, value, reason}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => Atom.to_string(reason),
       "validation_errors" => [
         %{
           "field" => "branch_pattern",
           "value" => value,
           "reason" => Atom.to_string(reason),
           "message" => BranchPattern.error_message(reason)
         }
       ]
     }}
  end

  defp invalid_params_error(tool, reason) do
    {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}
  end

  defp service_error(_reason, resource) do
    {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp metadata_idempotency_key(payload),
    do: "mcp:" <> Map.get(payload, "type", "metadata") <> ":" <> Base.url_encode64(:erlang.term_to_binary(payload), padding: false)

  defp progress_event_payload(%ProgressEvent{} = event) do
    %{
      "id" => event.id,
      "sequence" => event.sequence,
      "status" => event.status,
      "summary" => event.summary
    }
    |> drop_nil_values()
  end

  defp normalize_optional_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_value(nil), do: nil
  defp normalize_optional_value(value), do: value

  defp repo_scope_name_matches?(repo, repo, _opts) when is_binary(repo), do: true

  defp repo_scope_name_matches?(expected_repo, actual_repo, opts) when is_binary(expected_repo) and is_binary(actual_repo) do
    RepoIdentity.scope_match?(expected_repo, actual_repo,
      trusted_remotes: Keyword.get(opts, :repo_scope_trusted_remotes, default_repo_scope_trusted_remotes()),
      local_path_remotes?: true
    )
  end

  defp repo_scope_name_matches?(_expected_repo, _actual_repo, _opts), do: false

  defp default_repo_scope_trusted_remotes do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_identity_trusted_remotes, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp current_assignment_summary(callbacks, repo, %Session{} = session), do: Map.fetch!(callbacks, :current_assignment_summary).(repo, session)
  defp release_current_assignment(callbacks, arguments, server), do: Map.fetch!(callbacks, :release_current_assignment).(arguments, server)
  defp create_work_request_handoff_opts(callbacks, %Config{} = config, claimed_by), do: Map.fetch!(callbacks, :create_work_request_handoff_opts).(config, claimed_by)
end
