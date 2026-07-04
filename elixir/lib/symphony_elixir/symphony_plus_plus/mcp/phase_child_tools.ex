defmodule SymphonyElixir.SymphonyPlusPlus.MCP.PhaseChildTools do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.Id
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Auth,
    Config,
    HandoffDatabase,
    PhaseChildScope,
    ProgressEvents,
    ReviewReadiness,
    Session,
    ToolCatalog,
    ToolResult
  }

  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceLinkage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @child_work_package_keys [
    "acceptance_criteria",
    "allowed_file_globs",
    "base_branch",
    "branch_pattern",
    "engineering_scope",
    "id",
    "kind",
    "owner_id",
    "parent_id",
    "phase_id",
    "policy_template",
    "product_description",
    "repo",
    "status",
    "title"
  ]
  @child_worker_template_keys ["capabilities", "expires_at", "claimed_by"]
  @child_worker_capabilities ["worker:claim", "worker:lifecycle.transition"]
  @child_worker_ready_status "ready_for_worker"
  @child_worker_resettable_statuses ["claimed", "planning", "implementing", "reviewing", "ci_waiting", "blocked"]
  @child_worker_recyclable_statuses [@child_worker_ready_status | @child_worker_resettable_statuses]
  @child_worker_grant_provenance "child_worker_delegation"
  @local_assignment_claim_tool ToolCatalog.local_assignment_claim_tool()

  @type result :: {:ok, map()} | {:error, integer(), String.t(), map()}

  @spec call(String.t(), Config.t(), Session.t() | nil, map()) :: result()
  def call("read_child_status", %Config{} = config, session, arguments) do
    with {:ok, session} <- architect_session(config.repo, session, ["read:child_progress", "read:child_findings"]),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         :ok <- require_architect_child_status_scope(config.repo, session, work_package_id),
         {:ok, summary} <- PlanningRepository.get_status_summary(config.repo, work_package_id) do
      {:ok,
       ToolResult.tool_result(%{
         "work_package" => work_package_payload(summary.work_package),
         "plan_version" => plan_version(summary.plan_nodes),
         "finding_count" => summary.finding_count,
         "progress_event_count" => summary.progress_event_count,
         "artifact_count" => summary.artifact_count
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_child_status", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "read_child_status")
    end
  end

  def call("create_child_work_package", %Config{} = config, session, arguments) do
    with {:ok, session} <- architect_session(config.repo, session, "create:child_work_package"),
         {:ok, package} <- required_object(arguments, "package"),
         {:ok, work_package} <- create_child_work_package_transaction(config.repo, session, package) do
      {:ok, ToolResult.tool_result(%{"work_package" => child_work_package_payload(work_package)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "create_child_work_package", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "create_child_work_package")
    end
  end

  def call("mint_child_worker_key", %Config{} = config, session, arguments) do
    with {:ok, session} <- architect_session(config.repo, session, "mint:child_worker_key"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, template} <- optional_object_argument(arguments, "template"),
         {:ok, payload} <- mint_child_worker_key(config, session, work_package_id, template) do
      {:ok, ToolResult.tool_result(payload)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "mint_child_worker_key", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "mint_child_worker_key")
    end
  end

  def call("revoke_child_worker_key", %Config{} = config, session, arguments) do
    with {:ok, session} <- architect_session(config.repo, session, "revoke:child_worker_key"),
         {:ok, grant_id} <- required_revoke_child_worker_string(arguments, "grant_id"),
         {:ok, reason} <- required_revoke_child_worker_string(arguments, "reason"),
         {:ok, payload} <- revoke_child_worker_key_transaction(config.repo, session, grant_id, reason) do
      {:ok, ToolResult.tool_result(payload)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "revoke_child_worker_key", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "revoke_child_worker_key")
    end
  end

  def call("read_phase_board", %Config{} = config, session, arguments) do
    with {:ok, session} <- architect_session(config.repo, session, "read:phase"),
         {:ok, phase_id} <- required_argument(arguments, "phase_id"),
         :ok <- require_architect_phase_scope(config.repo, session, phase_id),
         {:ok, grant} <- require_architect_phase_board_grant(config.repo, session, phase_id),
         {:ok, board} <- Dashboard.phase_board_for_grant(config.repo, phase_id, grant) do
      {:ok, ToolResult.tool_result(json_safe_payload(board))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_phase_board", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "read_phase_board")
    end
  end

  def call("approve_child_ready_state", %Config{} = config, session, arguments) do
    with {:ok, session} <- architect_session(config.repo, session, "approve:child_ready_state"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, rationale} <- required_argument(arguments, "rationale"),
         {:ok, request_id} <- optional_request_id(arguments, "request_id"),
         {:ok, result} <- approve_child_ready_state_transaction(config.repo, session, work_package_id, rationale, request_id) do
      {:ok, ToolResult.tool_result(result)}
    else
      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => "approve_child_ready_state", "reason" => reason}}

      {:error, {:readiness_failed, missing, reasons}} ->
        {:error, -32_602, "Invalid params", %{"tool" => "approve_child_ready_state", "reason" => "readiness_failed", "missing" => missing, "reasons" => reasons}}

      {:error, reason} ->
        architect_error(reason, "approve_child_ready_state")
    end
  end

  def call("merge_child_into_phase", %Config{} = config, session, arguments) do
    with {:ok, session} <- architect_session(config.repo, session, "merge:child_into_phase"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, merge_artifact} <- required_object(arguments, "merge_artifact"),
         {:ok, result} <- merge_child_into_phase_transaction(config.repo, session, work_package_id, merge_artifact) do
      {:ok, ToolResult.tool_result(result)}
    else
      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => "merge_child_into_phase", "reason" => reason}}

      {:error, reason} ->
        architect_error(reason, "merge_child_into_phase")
    end
  end

  defp require_architect_phase_board_grant(repo, %Session{} = session, phase_id) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, anchor} <- architect_anchor_work_package(repo, session),
         :ok <- require_architect_anchor_scope(anchor, grant, phase_id),
         {:ok, _filters} <- Dashboard.phase_board_filters_for_grant(grant) do
      {:ok, grant}
    else
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, :forbidden} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scoped_work_request_filters(repo, %Session{} = session, opts \\ []) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, filters} <- work_request_filters_for_architect_grant(repo, session, grant),
         {:ok, scope} <- work_request_scope_payload(filters),
         {:ok, scope} <- maybe_put_handoff_phase_scope(repo, scope, grant, opts) do
      {:ok, work_request_filters_from_scope(scope), scope}
    else
      {:error, :forbidden} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp work_request_filters_for_architect_grant(repo, %Session{} = session, %AccessGrant{} = grant) do
    case frozen_work_request_filters_for_architect_grant(repo, session, grant) do
      {:ok, filters} ->
        {:ok, filters}

      {:error, reason} = error when reason in [:forbidden, :phase_scope_not_available] ->
        if missing_frozen_work_request_scope?(grant) do
          legacy_handoff_work_request_filters(repo, session, grant)
        else
          error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp frozen_work_request_filters_for_architect_grant(repo, %Session{} = session, %AccessGrant{} = grant) do
    with :ok <- require_work_request_anchor_scope(repo, session, grant) do
      Dashboard.phase_board_filters_for_grant(grant)
    end
  end

  defp legacy_handoff_work_request_filters(repo, %Session{} = session, %AccessGrant{} = grant) do
    with {:ok, true} <- ArchitectHandoff.handoff_phase_grant?(repo, grant),
         {:ok, anchor} <- architect_anchor_work_package(repo, session),
         true <- grant.work_package_id == anchor.id,
         true <- grant.phase_id == anchor.phase_id,
         {:ok, work_request} <- legacy_handoff_work_request(repo, grant, anchor),
         {:ok, repo_name} <- required_scope_value(work_request.repo),
         {:ok, base_branch} <- required_scope_value(work_request.base_branch) do
      {:ok, repo: repo_name, base_branch: base_branch}
    else
      false -> {:error, :phase_scope_not_available}
      {:ok, false} -> {:error, :phase_scope_not_available}
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_handoff_work_request(repo, %AccessGrant{} = grant, %WorkPackage{} = anchor) do
    with {:ok, repo_name} <- required_scope_value(anchor.repo),
         {:ok, base_branch} <- required_scope_value(anchor.base_branch),
         {:ok, work_requests} <- WorkRequestRepository.list(repo, %{"repo" => repo_name, "base_branch" => base_branch}) do
      case Enum.find(work_requests, &legacy_handoff_work_request?(&1, grant, anchor)) do
        %WorkRequest{} = work_request -> {:ok, work_request}
        nil -> {:error, :phase_scope_not_available}
      end
    end
  end

  defp legacy_handoff_work_request?(%WorkRequest{} = work_request, %AccessGrant{} = grant, %WorkPackage{} = anchor) do
    ArchitectHandoff.eligible_status?(work_request.status) and
      ArchitectHandoff.eligible_scope?(work_request) and
      grant.work_package_id == anchor.id and
      grant.phase_id == anchor.phase_id and
      ArchitectHandoff.anchor_id_for_work_request(work_request) == anchor.id and
      ArchitectHandoff.phase_id_for_work_request(work_request) == anchor.phase_id
  end

  defp require_work_request_anchor_scope(repo, %Session{} = session, %AccessGrant{} = grant) do
    if architect_explicit_phase_grant?(grant) do
      require_architect_phase_anchor(repo, session, grant.phase_id)
    else
      {:error, :phase_scope_not_available}
    end
  end

  defp missing_frozen_work_request_scope?(%AccessGrant{} = grant) do
    not filled_string?(grant.scope_repo) and not filled_string?(grant.scope_base_branch)
  end

  defp required_scope_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :phase_scope_not_available}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_scope_value(_value), do: {:error, :phase_scope_not_available}

  defp work_request_scope_payload(filters) when is_list(filters) do
    repo = Keyword.get(filters, :repo)
    base_branch = Keyword.get(filters, :base_branch)

    if filled_string?(repo) and filled_string?(base_branch) do
      {:ok, %{"repo" => String.trim(repo), "base_branch" => String.trim(base_branch)}}
    else
      {:error, :phase_scope_not_available}
    end
  end

  defp work_request_filters_from_scope(%{"repo" => repo, "base_branch" => base_branch, "phase_id" => phase_id}) do
    %{"repo" => repo, "base_branch" => base_branch, "phase_id" => phase_id}
  end

  defp work_request_filters_from_scope(%{"repo" => repo, "base_branch" => base_branch}) do
    %{"repo" => repo, "base_branch" => base_branch}
  end

  defp maybe_put_handoff_phase_scope(repo, scope, %AccessGrant{} = grant) do
    case ArchitectHandoff.handoff_phase_grant?(repo, grant) do
      {:ok, true} -> {:ok, Map.put(scope, "phase_id", grant.phase_id)}
      {:ok, false} -> {:ok, scope}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_handoff_phase_scope(repo, scope, %AccessGrant{} = grant, opts) do
    if Keyword.get(opts, :handoff_phase_scope?, true) do
      maybe_put_handoff_phase_scope(repo, scope, grant)
    else
      {:ok, scope}
    end
  end

  defp scoped_worktree_work_package(repo, %Session{} = session, work_package_id) do
    with {:ok, %WorkPackage{} = work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, filters, scope} <- scoped_work_request_filters(repo, session),
         :ok <- require_worktree_work_package_scope(repo, work_package, filters) do
      {:ok, work_package, scope}
    else
      {:error, :forbidden} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_worktree_work_package_scope(repo, %WorkPackage{} = work_package, filters) do
    case PlannedSliceLinkage.linked_work_requests_for_work_package(repo, work_package.id) do
      {:ok, []} ->
        {:error, :forbidden}

      {:ok, links} ->
        with :ok <- require_unique_worktree_work_request_link(links) do
          require_any_worktree_work_package_link_scope(repo, work_package, links, filters)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_unique_worktree_work_request_link(links) do
    case Enum.uniq_by(links, fn {%PlannedSlice{}, %WorkRequest{id: work_request_id}} -> work_request_id end) do
      [_single] -> :ok
      [] -> {:error, :forbidden}
      [_first | _rest] -> {:error, :ambiguous_planned_slice_link}
    end
  end

  defp require_any_worktree_work_package_link_scope(repo, %WorkPackage{} = work_package, links, filters) do
    Enum.reduce_while(links, {:error, :forbidden}, fn
      {%PlannedSlice{} = planned_slice, %WorkRequest{} = work_request}, _error ->
        case require_worktree_work_package_link_scope(repo, work_package, planned_slice, work_request, filters) do
          :ok -> {:halt, :ok}
          {:error, reason} when reason in [:forbidden, :not_found] -> {:cont, {:error, :forbidden}}
        end
    end)
  end

  defp require_worktree_work_package_link_scope(
         repo,
         %WorkPackage{} = work_package,
         %PlannedSlice{} = planned_slice,
         %WorkRequest{} = work_request,
         filters
       ) do
    with :ok <- require_work_package_repo_scope(work_package, work_request, planned_slice),
         :ok <- require_work_package_delivery_base_scope(work_package, planned_slice),
         :ok <- require_work_request_scope(repo, work_request, filters) do
      require_delivery_work_package_filter_scope(repo, work_package, work_request, filters)
    end
  end

  defp require_delivery_work_package_filter_scope(repo, %WorkPackage{} = work_package, %WorkRequest{} = work_request, filters) do
    primary_scope? = primary_work_request_scope?(repo, work_request, filters)
    require_delivery_work_package_filter_scope(work_package, primary_scope?, filters)
  end

  defp require_delivery_work_package_filter_scope(%WorkPackage{} = work_package, primary_scope?, filters) do
    if delivery_work_package_visible_to_filters?(work_package, primary_scope?, filters, []) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp require_work_request_scope(repo, %WorkRequest{} = work_request, filters) do
    with {:ok, matches?} <- work_request_matches_primary_filters?(repo, work_request, filters, []) do
      if matches?, do: :ok, else: {:error, :forbidden}
    end
  end

  defp require_work_package_repo_scope(%WorkPackage{} = work_package, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice) do
    if work_package.repo == PlannedSlice.delivery_repo(work_request, planned_slice), do: :ok, else: {:error, :forbidden}
  end

  defp require_work_package_delivery_base_scope(%WorkPackage{base_branch: base_branch}, %PlannedSlice{target_base_branch: base_branch}),
    do: :ok

  defp require_work_package_delivery_base_scope(%WorkPackage{}, %PlannedSlice{}), do: {:error, :forbidden}

  defp primary_work_request_scope?(repo, %WorkRequest{} = work_request, filters) do
    {:ok, matches?} = work_request_matches_primary_filters?(repo, work_request, filters, [])
    matches?
  end

  defp delivery_work_package_visible_to_filters?(_work_package, true, _filters, _opts), do: true

  defp delivery_work_package_visible_to_filters?(%WorkPackage{} = work_package, false, filters, opts) do
    work_package_matches_filters?(work_package, filters, opts)
  end

  defp work_request_matches_primary_filters?(_repo, %WorkRequest{} = work_request, filters, opts) do
    {:ok,
     Enum.all?(filters, fn
       {"repo", repo} when is_binary(repo) -> repo_scope_name_matches?(repo, work_request.repo, opts)
       {"base_branch", base_branch} when is_binary(base_branch) -> work_request.base_branch == base_branch
       {"status", status} when is_binary(status) -> work_request.status == status
       {"phase_id", phase_id} when is_binary(phase_id) -> ArchitectHandoff.phase_id_for_work_request(work_request) == phase_id
       _filter -> true
     end)}
  end

  defp work_package_matches_filters?(%WorkPackage{} = work_package, filters, opts) do
    Enum.all?(filters, fn
      {"repo", repo} when is_binary(repo) -> repo_scope_name_matches?(repo, work_package.repo, opts)
      {"base_branch", base_branch} when is_binary(base_branch) -> work_package.base_branch == base_branch
      _filter -> true
    end)
  end

  defp require_architect_child_status_scope(repo, %Session{} = session, work_package_id) do
    if Session.work_package_id(session) == work_package_id do
      require_architect_anchor_status_scope(repo, session)
    else
      case require_architect_child_work_package_scope(repo, session, work_package_id) do
        {:ok, _child} ->
          :ok

        {:error, :phase_scope_not_available} ->
          require_architect_dispatched_work_package_status_scope(repo, session, work_package_id)

        {:error, reason} ->
          {:error, reason}

        {:tool_error, "child_scope_outside_phase"} ->
          require_architect_dispatched_work_package_status_scope(repo, session, work_package_id)

        {:tool_error, _reason} ->
          {:error, :phase_scope_not_available}
      end
    end
  end

  defp require_architect_dispatched_work_package_status_scope(repo, %Session{} = session, work_package_id) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, true} <- ArchitectHandoff.handoff_phase_grant?(repo, grant),
         {:ok, _work_package, _scope} <- scoped_worktree_work_package(repo, session, work_package_id) do
      :ok
    else
      {:ok, false} -> {:error, :phase_scope_not_available}
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_architect_anchor_status_scope(repo, %Session{} = session) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, anchor} <- architect_anchor_work_package(repo, session) do
      require_anchor_status_phase_scope(repo, session, anchor, grant)
    else
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_anchor_status_phase_scope(repo, %Session{} = session, %WorkPackage{} = anchor, %AccessGrant{} = grant) do
    cond do
      architect_explicit_phase_grant?(grant) ->
        require_frozen_anchor_scope(anchor, grant)

      explicit_phase_id?(anchor.phase_id) ->
        require_child_phase_anchor_status(repo, session)

      true ->
        :ok
    end
  end

  defp require_child_phase_anchor_status(repo, %Session{} = session) do
    case architect_child_phase_anchor(repo, session) do
      {:ok, _phase_id, _anchor} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_architect_child_work_package_scope(repo, %Session{} = session, work_package_id) do
    with {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session),
         {:ok, child} <- scoped_child_work_package(repo, work_package_id),
         :ok <- require_phase_child_scope(child, anchor, phase_id) do
      {:ok, child}
    end
  end

  defp scoped_child_work_package(repo, work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, child} -> {:ok, child}
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_phase_child_scope(%WorkPackage{kind: "phase_child", phase_id: phase_id} = child, anchor, phase_id) do
    cond do
      child.parent_id != anchor.id -> {:error, :phase_scope_not_available}
      child.repo != anchor.repo -> {:tool_error, "repo_scope_mismatch"}
      child.base_branch != anchor.base_branch -> {:tool_error, "base_branch_scope_mismatch"}
      true -> PhaseChildScope.require_file_scope(child, anchor)
    end
  end

  defp require_phase_child_scope(%WorkPackage{}, _anchor, _phase_id), do: {:error, :phase_scope_not_available}

  defp create_child_work_package_transaction(repo, %Session{} = session, package) do
    case repo.transaction(fn ->
           create_child_work_package_or_rollback(repo, session, package)
         end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_child_work_package_or_rollback(repo, %Session{} = session, package) do
    case create_child_work_package_in_transaction(repo, session, package) do
      {:ok, result} -> result
      {:tool_error, reason} -> repo.rollback({:tool_error, reason})
      {:error, reason} -> repo.rollback({:error, reason})
    end
  end

  defp create_child_work_package_in_transaction(repo, %Session{} = session, package) do
    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, _architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, attrs} <- child_work_package_attrs(repo, session, package) do
      WorkPackageRepository.create(repo, attrs)
    end
  end

  defp mint_child_worker_key(%Config{} = config, %Session{} = session, work_package_id, template) do
    template = template || %{}

    with {:ok, claimed_by} <- child_worker_claimed_by(work_package_id, template),
         {:ok, {child, minted, ledger_database}} <-
           mint_child_worker_key_transaction(config, session, work_package_id, template) do
      {:ok,
       %{
         "work_package" => child_work_package_payload(child),
         "worker_grant" => child_worker_grant_payload(minted, child, claimed_by, ledger_database)
       }}
    end
  end

  defp mint_child_worker_key_transaction(%Config{repo: repo} = config, %Session{} = session, work_package_id, template) do
    case repo.transaction(fn ->
           mint_child_worker_key_or_rollback(config, session, work_package_id, template)
         end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mint_child_worker_key_or_rollback(%Config{repo: repo} = config, %Session{} = session, work_package_id, template) do
    case mint_child_worker_key_in_transaction(config, session, work_package_id, template) do
      {:ok, result} -> result
      {:tool_error, reason} -> repo.rollback({:tool_error, reason})
      {:error, reason} -> repo.rollback({:error, reason})
    end
  end

  defp mint_child_worker_key_in_transaction(%Config{repo: repo} = config, %Session{} = session, work_package_id, template) do
    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session, architect_grant),
         {:ok, grant_opts} <- child_worker_grant_opts(template, architect_grant),
         {:ok, _prechecked_child} <- require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id),
         :ok <- lock_work_package(repo, work_package_id),
         :ok <- reject_active_child_worker_grant(repo, work_package_id),
         {:ok, child} <- require_child_ready_for_mint(repo, work_package_id, anchor, phase_id),
         {:ok, ledger_database} <- HandoffDatabase.resolve(config.database, repo),
         {:ok, minted} <- AccessGrantService.mint_worker_grant(repo, child.id, grant_opts) do
      {:ok, {child, minted, ledger_database}}
    end
  end

  defp revoke_child_worker_key_transaction(repo, %Session{} = session, grant_id, reason) do
    run_architect_transaction(repo, fn ->
      revoke_child_worker_key_in_transaction(repo, session, grant_id, reason)
    end)
  end

  defp revoke_child_worker_key_in_transaction(repo, %Session{} = session, grant_id, reason) do
    now = DateTime.utc_now(:microsecond)

    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session, architect_grant),
         {:ok, candidate_grant} <- scoped_child_worker_grant_for_revoke(repo, grant_id, anchor, phase_id, now),
         :ok <- lock_work_package(repo, candidate_grant.work_package_id),
         :ok <- lock_access_grant(repo, grant_id),
         {:ok, grant} <- scoped_child_worker_grant_for_revoke(repo, grant_id, anchor, phase_id, now),
         {:ok, child} <- require_transaction_current_child_scope(repo, grant.work_package_id, anchor, phase_id),
         :ok <- require_child_worker_recyclable_status(child),
         {:ok, revoked_grant} <- revoke_live_child_worker_grant(repo, grant, now),
         {:ok, reset_child} <- reset_child_worker_for_recycle(repo, child, now),
         {:ok, event} <- append_child_worker_revoke_event(repo, session, child, reset_child, revoked_grant, reason) do
      {:ok, child_worker_revoke_result(reset_child, revoked_grant, event, reason, child.status)}
    end
  end

  defp required_revoke_child_worker_string(arguments, key) do
    case Map.fetch(arguments, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _value} ->
        {:tool_error, "invalid_#{key}"}

      :error ->
        {:tool_error, "missing_#{key}"}
    end
  end

  defp scoped_child_worker_grant_for_revoke(repo, grant_id, %WorkPackage{} = anchor, phase_id, %DateTime{} = now) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, grant_id),
         {:ok, work_package_id} <- child_worker_grant_work_package_id(grant),
         {:ok, _child} <- require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id),
         :ok <- require_live_child_worker_grant_for_revoke(grant, now) do
      {:ok, grant}
    end
  end

  defp child_worker_grant_work_package_id(%AccessGrant{work_package_id: work_package_id}) when is_binary(work_package_id) do
    case String.trim(work_package_id) do
      "" -> {:error, :phase_scope_not_available}
      trimmed -> {:ok, trimmed}
    end
  end

  defp child_worker_grant_work_package_id(%AccessGrant{}), do: {:error, :phase_scope_not_available}

  defp require_live_child_worker_grant_for_revoke(%AccessGrant{grant_role: "worker", provenance: @child_worker_grant_provenance} = grant, now) do
    cond do
      not child_worker_grant_capabilities?(grant.capabilities || []) ->
        {:tool_error, "not_child_worker_grant"}

      match?(%DateTime{}, grant.revoked_at) ->
        {:tool_error, "child_worker_grant_already_revoked"}

      not live_expires_at?(grant.expires_at, now) ->
        {:tool_error, "child_worker_grant_expired"}

      true ->
        :ok
    end
  end

  defp require_live_child_worker_grant_for_revoke(%AccessGrant{}, _now), do: {:tool_error, "not_child_worker_grant"}

  defp child_worker_grant_capabilities?(capabilities) when is_list(capabilities) do
    Enum.all?(capabilities, &(&1 in @child_worker_capabilities))
  end

  defp child_worker_grant_capabilities?(_capabilities), do: false

  defp require_child_worker_recyclable_status(%WorkPackage{status: status}) when status in @child_worker_recyclable_statuses, do: :ok
  defp require_child_worker_recyclable_status(%WorkPackage{}), do: {:tool_error, "child_not_recyclable"}

  defp revoke_live_child_worker_grant(repo, %AccessGrant{} = grant, %DateTime{} = now) do
    query =
      from(access_grant in AccessGrant,
        where:
          access_grant.id == ^grant.id and access_grant.work_package_id == ^grant.work_package_id and
            access_grant.grant_role == "worker" and access_grant.provenance == ^@child_worker_grant_provenance and
            is_nil(access_grant.revoked_at) and (is_nil(access_grant.expires_at) or access_grant.expires_at > ^now)
      )

    case repo.update_all(query, set: [revoked_at: now, updated_at: now]) do
      {1, _rows} -> AccessGrantRepository.get(repo, grant.id)
      {0, _rows} -> classify_child_worker_revoke_miss(repo, grant.id, now)
    end
  end

  defp classify_child_worker_revoke_miss(repo, grant_id, %DateTime{} = now) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, grant_id) do
      case require_live_child_worker_grant_for_revoke(grant, now) do
        :ok -> {:tool_error, "child_worker_revoke_conflict"}
        {:tool_error, reason} -> {:tool_error, reason}
      end
    end
  end

  defp reset_child_worker_for_recycle(_repo, %WorkPackage{status: @child_worker_ready_status} = child, _now), do: {:ok, child}

  defp reset_child_worker_for_recycle(repo, %WorkPackage{status: status} = child, %DateTime{} = now)
       when status in @child_worker_resettable_statuses do
    query =
      from(work_package in WorkPackage,
        where: work_package.id == ^child.id and work_package.kind == "phase_child" and work_package.status == ^status
      )

    case repo.update_all(query, set: [status: @child_worker_ready_status, updated_at: now]) do
      {1, _rows} -> WorkPackageRepository.get(repo, child.id)
      {0, _rows} -> {:tool_error, "child_worker_recycle_status_conflict"}
    end
  end

  defp reset_child_worker_for_recycle(_repo, %WorkPackage{}, _now), do: {:tool_error, "child_not_recyclable"}

  defp append_child_worker_revoke_event(
         repo,
         %Session{} = session,
         %WorkPackage{} = previous_child,
         %WorkPackage{} = reset_child,
         %AccessGrant{} = grant,
         reason
       ) do
    payload = child_worker_revoke_payload(reset_child.id, grant, reason, previous_child.status, reset_child.status)

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, reset_child.id, %{
      "summary" => "Child worker grant revoked for recycle",
      "body" => "Recycle reason: #{redacted_child_worker_revoke_reason(reason)}; child status: #{previous_child.status} -> #{reset_child.status}",
      "status" => "child_worker_key_revoked",
      "idempotency_key" => ProgressEvents.metadata_idempotency_key(payload),
      "payload" => payload
    })
  end

  defp child_worker_revoke_payload(work_package_id, %AccessGrant{} = grant, reason, previous_status, new_status) do
    reason_codes = child_worker_recycle_reason_codes(previous_status, new_status)

    %{
      "type" => "child_worker_key_revoke",
      "source_tool" => "revoke_child_worker_key",
      "work_package_id" => work_package_id,
      "grant_id" => grant.id,
      "reason" => redacted_child_worker_revoke_reason(reason),
      "revoked_at" => timestamp(grant.revoked_at),
      "previous_status" => previous_status,
      "new_status" => new_status,
      "status_reset" => previous_status != new_status,
      "lifecycle_state" => "recycled",
      "reason_codes" => reason_codes
    }
  end

  defp child_worker_revoke_result(%WorkPackage{} = child, %AccessGrant{} = grant, %ProgressEvent{} = event, reason, previous_status) do
    %{
      "work_package" => child_work_package_payload(child),
      "revoked_worker_grant" => revoked_child_worker_grant_payload(grant),
      "recycle" => %{
        "status" => "revoked",
        "reason" => redacted_child_worker_revoke_reason(reason),
        "previous_child_status" => previous_status,
        "new_child_status" => child.status,
        "status_reset" => previous_status != child.status,
        "remint_available" => true,
        "remint_precondition" => "child_status_ready_for_worker",
        "lifecycle_state" => "recycled",
        "reason_codes" => child_worker_recycle_reason_codes(previous_status, child.status)
      },
      "revocation_event" => ProgressEvents.payload(event)
    }
  end

  defp child_worker_recycle_reason_codes(previous_status, new_status) do
    [
      "worker_recycled",
      if(previous_status != new_status, do: "work_package_reset_for_recycle")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp revoked_child_worker_grant_payload(%AccessGrant{} = grant) do
    %{
      "id" => grant.id,
      "work_package_id" => grant.work_package_id,
      "grant_role" => grant.grant_role,
      "capabilities" => grant.capabilities || [],
      "expires_at" => timestamp(grant.expires_at),
      "revoked_at" => timestamp(grant.revoked_at),
      "secret_in_response" => false
    }
  end

  defp redacted_child_worker_revoke_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> Redactor.redact_text()
  end

  defp approve_child_ready_state_transaction(repo, %Session{} = session, work_package_id, rationale, request_id) do
    run_architect_transaction(repo, fn ->
      approve_child_ready_state_in_transaction(repo, session, work_package_id, rationale, request_id)
    end)
  end

  defp approve_child_ready_state_in_transaction(repo, %Session{} = session, work_package_id, rationale, request_id) do
    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session, architect_grant),
         {:ok, child} <- require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id),
         :ok <- lock_work_package(repo, child.id),
         {:ok, state} <- PlanningRepository.get_state(repo, child.id) do
      approve_child_ready_state_result(repo, session, state, rationale, request_id)
    end
  end

  defp approve_child_ready_state_result(repo, %Session{} = session, state, rationale, request_id) do
    case existing_child_ready_approval(repo, session, state, rationale, request_id) do
      {:ok, %ProgressEvent{} = event} ->
        replay_or_complete_child_ready_approval(repo, session, state, event)

      {:error, :not_found} ->
        with :ok <-
               require_child_status(
                 state.work_package,
                 "ready_for_architect_merge",
                 "child_not_ready_for_architect"
               ),
             :ok <- child_ready_approval_gates(repo, state),
             {:ok, event} <-
               append_child_ready_approval_event(repo, session, state.work_package, rationale, request_id),
             {:ok, approved_child} <- architect_phase_child_transition(repo, session, state.work_package, "merging_into_phase") do
          {:ok, child_ready_approval_result(approved_child, event)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_or_complete_child_ready_approval(
         repo,
         %Session{} = session,
         %{work_package: %WorkPackage{status: "ready_for_architect_merge"}} = state,
         %ProgressEvent{} = event
       ) do
    with :ok <- child_ready_approval_gates(repo, state),
         {:ok, approved_child} <- architect_phase_child_transition(repo, session, state.work_package, "merging_into_phase") do
      {:ok, child_ready_approval_result(approved_child, event)}
    end
  end

  defp replay_or_complete_child_ready_approval(_repo, %Session{}, state, %ProgressEvent{} = event) do
    {:ok, child_ready_approval_result(state.work_package, event)}
  end

  defp merge_child_into_phase_transaction(repo, %Session{} = session, work_package_id, merge_artifact) do
    run_architect_transaction(repo, fn ->
      merge_child_into_phase_in_transaction(repo, session, work_package_id, merge_artifact)
    end)
  end

  defp merge_child_into_phase_in_transaction(repo, %Session{} = session, work_package_id, merge_artifact) do
    with {:ok, merge_artifact} <- normalized_merge_artifact(merge_artifact),
         :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session, architect_grant),
         {:ok, child} <- require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id),
         :ok <- lock_work_package(repo, child.id),
         {:ok, state} <- PlanningRepository.get_state(repo, child.id) do
      merge_child_into_phase_result(repo, session, state, merge_artifact)
    end
  end

  defp merge_child_into_phase_result(repo, %Session{} = session, state, merge_artifact) do
    case existing_child_merge_record(repo, session, state.work_package.id, merge_artifact) do
      {:ok, %ProgressEvent{} = event} ->
        replay_or_complete_child_merge(repo, session, state, event, merge_artifact)

      {:error, :not_found} ->
        record_new_child_merge(repo, session, state, merge_artifact)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_or_complete_child_merge(
         repo,
         %Session{} = session,
         %{work_package: %WorkPackage{status: "merging_into_phase"}} = state,
         %ProgressEvent{} = event,
         merge_artifact
       ) do
    with :ok <- require_active_child_phase(repo, state.work_package),
         {:ok, artifact} <- record_phase_merge_artifact(repo, state.work_package, merge_artifact),
         {:ok, merged_child} <- architect_phase_child_transition(repo, session, state.work_package, "merged_into_phase") do
      {:ok, child_merge_result(merged_child, event, artifact, merge_artifact)}
    end
  end

  defp replay_or_complete_child_merge(repo, %Session{}, state, %ProgressEvent{} = event, merge_artifact) do
    with :ok <- require_active_child_phase(repo, state.work_package),
         {:ok, artifact} <- current_phase_merge_artifact(repo, state.work_package, merge_artifact) do
      {:ok, child_merge_result(state.work_package, event, artifact, current_merge_artifact(artifact))}
    end
  end

  defp record_new_child_merge(
         repo,
         %Session{} = session,
         %{work_package: %WorkPackage{status: "merging_into_phase"}} = state,
         merge_artifact
       ) do
    with :ok <- require_active_child_phase(repo, state.work_package),
         {:ok, artifact} <- record_phase_merge_artifact(repo, state.work_package, merge_artifact),
         {:ok, event} <- append_child_merge_event(repo, session, state.work_package, merge_artifact),
         {:ok, merged_child} <- architect_phase_child_transition(repo, session, state.work_package, "merged_into_phase") do
      {:ok, child_merge_result(merged_child, event, artifact, merge_artifact)}
    end
  end

  defp record_new_child_merge(
         repo,
         %Session{} = session,
         %{work_package: %WorkPackage{status: "merged_into_phase"}} = state,
         merge_artifact
       ) do
    with :ok <- require_active_child_phase(repo, state.work_package),
         {:ok, artifact} <- record_phase_merge_artifact(repo, state.work_package, merge_artifact),
         {:ok, event} <- append_child_merge_event(repo, session, state.work_package, merge_artifact) do
      {:ok, child_merge_result(state.work_package, event, artifact, merge_artifact)}
    end
  end

  defp record_new_child_merge(_repo, %Session{}, state, _merge_artifact) do
    require_child_status(state.work_package, "merging_into_phase", "child_not_approved_for_merge")
  end

  defp require_active_child_phase(repo, %WorkPackage{} = child) do
    case readiness_phase(repo, child) do
      {:ok, %{status: "active"}} -> :ok
      {:ok, _phase} -> {:tool_error, "phase_not_active"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp readiness_phase(repo, %WorkPackage{phase_id: phase_id}) when is_binary(phase_id) do
    if filled_string?(phase_id) do
      case PhaseRepository.get(repo, phase_id) do
        {:ok, phase} -> {:ok, phase}
        {:error, :not_found} -> {:ok, %{status: nil}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, %{status: nil}}
    end
  end

  defp readiness_phase(_repo, %WorkPackage{}), do: {:ok, %{status: nil}}

  defp current_phase_merge_artifact(repo, %WorkPackage{} = child, merge_artifact) do
    case PlanningRepository.get_artifact(repo, phase_merge_artifact_id(child.id)) do
      {:ok, nil} ->
        with :ok <- require_active_child_phase(repo, child) do
          record_phase_merge_artifact(repo, child, merge_artifact)
        end

      {:ok, %Artifact{} = artifact} ->
        {:ok, artifact}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_child_ready_for_mint(repo, work_package_id, %WorkPackage{} = anchor, phase_id) when is_binary(work_package_id) do
    now = DateTime.utc_now(:microsecond)

    query =
      from(work_package in WorkPackage,
        where:
          work_package.id == ^work_package_id and work_package.status == "ready_for_worker" and
            work_package.kind == "phase_child" and work_package.phase_id == ^phase_id and work_package.parent_id == ^anchor.id and
            work_package.repo == ^anchor.repo and work_package.base_branch == ^anchor.base_branch
      )

    case repo.update_all(query, set: [updated_at: now]) do
      {1, _rows} -> require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id)
      {0, _rows} -> classify_child_ready_mint_miss(repo, work_package_id, anchor, phase_id)
    end
  end

  defp require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id) do
    with {:ok, child} <- scoped_child_work_package(repo, work_package_id),
         :ok <- require_phase_child_scope(child, anchor, phase_id) do
      {:ok, child}
    end
  end

  defp classify_child_ready_mint_miss(repo, work_package_id, anchor, phase_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, child} ->
        case require_phase_child_scope(child, anchor, phase_id) do
          :ok -> {:tool_error, "child_not_ready_for_worker"}
          {:error, reason} -> {:error, reason}
          {:tool_error, reason} -> {:tool_error, reason}
        end

      {:error, _reason} ->
        {:error, :phase_scope_not_available}
    end
  end

  defp require_child_status(%WorkPackage{status: status}, status, _reason), do: :ok
  defp require_child_status(%WorkPackage{}, _status, reason), do: {:tool_error, reason}

  defp child_ready_approval_gates(repo, state) do
    ReviewReadiness.child_ready_approval_gates(repo, state)
  end

  defp existing_child_ready_approval(repo, %Session{} = session, %{work_package: %WorkPackage{} = child}, _rationale, request_id)
       when is_binary(request_id) do
    ready_cycle_id = child_ready_approval_ready_cycle_id(child)

    case current_cycle_child_ready_approval_event(repo, session, child.id, request_id, ready_cycle_id) do
      {:ok, %ProgressEvent{} = event} ->
        {:ok, event}

      {:error, :not_found} ->
        replay_latest_child_ready_approval_event(repo, session, child, request_id, ready_cycle_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing_child_ready_approval(_repo, %Session{}, _state, _rationale, _request_id), do: {:error, :not_found}

  defp current_cycle_child_ready_approval_event(_repo, %Session{}, _work_package_id, _request_id, nil), do: {:error, :not_found}

  defp current_cycle_child_ready_approval_event(repo, %Session{} = session, work_package_id, request_id, ready_cycle_id) do
    identity = child_ready_approval_request_identity(work_package_id, request_id, ready_cycle_id)
    idempotency_key = child_ready_approval_idempotency_key(work_package_id, request_id, nil, ready_cycle_id)

    case PlanningRepository.get_progress_event_by_idempotency_key(
           repo,
           work_package_id,
           idempotency_key,
           session.assignment.grant_id
         ) do
      {:ok, event} ->
        validate_child_ready_approval_event(event, session, identity)

      {:error, :not_found} ->
        replay_child_ready_approval_event(repo, session, work_package_id, idempotency_key, identity)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_latest_child_ready_approval_event(repo, %Session{} = session, %WorkPackage{} = child, request_id, ready_cycle_id) do
    with {:ok, event} <- latest_child_ready_approval_event(repo, child.id, request_id),
         :ok <- child_ready_approval_event_matches_current_cycle?(repo, event, child, ready_cycle_id) do
      event_ready_cycle_id = Map.get(event.payload || %{}, "ready_cycle_id")
      identity = child_ready_approval_request_identity(child.id, request_id, event_ready_cycle_id)

      validate_child_ready_approval_event(event, session, identity)
    end
  end

  defp latest_child_ready_approval_event(repo, work_package_id, request_id) do
    case PlanningRepository.list_progress_events(repo, work_package_id) do
      {:ok, progress_events} ->
        progress_events
        |> Enum.filter(&child_ready_approval_request_event?(&1, request_id))
        |> List.last()
        |> case do
          %ProgressEvent{} = event -> {:ok, event}
          nil -> {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp child_ready_approval_request_event?(%ProgressEvent{status: "child_ready_approved", payload: payload}, request_id)
       when is_map(payload) do
    Map.take(payload, ["type", "source_tool", "request_id"]) == %{
      "type" => "child_ready_approval",
      "source_tool" => "approve_child_ready_state",
      "request_id" => request_id
    }
  end

  defp child_ready_approval_request_event?(%ProgressEvent{}, _request_id), do: false

  defp latest_child_ready_approval_event(repo, work_package_id) do
    case PlanningRepository.list_progress_events(repo, work_package_id) do
      {:ok, progress_events} ->
        progress_events
        |> Enum.filter(&child_ready_approval_event?/1)
        |> List.last()
        |> case do
          %ProgressEvent{} = event -> {:ok, event}
          nil -> {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp child_ready_approval_event?(%ProgressEvent{status: "child_ready_approved", payload: payload}) when is_map(payload) do
    Map.take(payload, ["type", "source_tool"]) == %{
      "type" => "child_ready_approval",
      "source_tool" => "approve_child_ready_state"
    }
  end

  defp child_ready_approval_event?(%ProgressEvent{}), do: false

  defp child_ready_approval_event_matches_current_cycle?(
         _repo,
         %ProgressEvent{payload: payload},
         %WorkPackage{status: "ready_for_architect_merge"},
         ready_cycle_id
       )
       when is_map(payload) do
    if Map.get(payload, "ready_cycle_id") == ready_cycle_id, do: :ok, else: {:error, :not_found}
  end

  defp child_ready_approval_event_matches_current_cycle?(repo, %ProgressEvent{} = event, %WorkPackage{id: child_id, status: status}, _ready_cycle_id)
       when status in ["merging_into_phase", "merged_into_phase", "blocked"] do
    with {:ok, latest_event} <- latest_child_ready_approval_event(repo, child_id) do
      if latest_event.id == event.id, do: :ok, else: {:error, :not_found}
    end
  end

  defp child_ready_approval_event_matches_current_cycle?(_repo, %ProgressEvent{}, %WorkPackage{}, _ready_cycle_id),
    do: {:error, :not_found}

  defp append_child_ready_approval_event(repo, %Session{} = session, %WorkPackage{} = child, rationale, request_id) do
    operation_id = if is_binary(request_id), do: nil, else: child_ready_approval_operation_id()
    ready_cycle_id = child_ready_approval_ready_cycle_id(child)
    payload = child_ready_approval_payload(child.id, rationale, request_id, operation_id, ready_cycle_id)

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, child.id, %{
      "summary" => "Child ready state approved",
      "status" => "child_ready_approved",
      "idempotency_key" => child_ready_approval_idempotency_key(child.id, request_id, operation_id, ready_cycle_id),
      "payload" => payload
    })
  end

  defp child_ready_approval_payload(work_package_id, rationale, request_id, operation_id, ready_cycle_id) do
    %{
      "type" => "child_ready_approval",
      "source_tool" => "approve_child_ready_state",
      "work_package_id" => work_package_id,
      "rationale" => rationale
    }
    |> maybe_put_filled_string("request_id", request_id)
    |> maybe_put_filled_string("operation_id", operation_id)
    |> maybe_put_filled_string("ready_cycle_id", ready_cycle_id)
  end

  defp child_ready_approval_idempotency_key(work_package_id, request_id, _operation_id, ready_cycle_id) when is_binary(request_id) do
    work_package_id
    |> child_ready_approval_request_identity(request_id, ready_cycle_id)
    |> ProgressEvents.metadata_idempotency_key()
  end

  defp child_ready_approval_idempotency_key(work_package_id, _request_id, operation_id, _ready_cycle_id) do
    work_package_id
    |> child_ready_approval_operation_payload()
    |> Map.put("operation_id", operation_id)
    |> ProgressEvents.metadata_idempotency_key()
  end

  defp child_ready_approval_operation_payload(work_package_id) do
    %{
      "type" => "child_ready_approval",
      "source_tool" => "approve_child_ready_state",
      "work_package_id" => work_package_id
    }
  end

  defp child_ready_approval_request_identity(work_package_id, request_id, ready_cycle_id) do
    work_package_id
    |> child_ready_approval_operation_payload()
    |> Map.put("request_id", request_id)
    |> maybe_put_filled_string("ready_cycle_id", ready_cycle_id)
  end

  defp child_ready_approval_ready_cycle_id(%WorkPackage{status: "ready_for_architect_merge", updated_at: %DateTime{} = updated_at}) do
    DateTime.to_iso8601(updated_at)
  end

  defp child_ready_approval_ready_cycle_id(%WorkPackage{}), do: nil

  defp child_ready_approval_operation_id do
    Id.random("approval")
  end

  defp child_ready_approval_result(%WorkPackage{} = child, %ProgressEvent{} = event) do
    %{
      "work_package" => child_work_package_payload(child),
      "approval" => ProgressEvents.payload(event)
    }
  end

  defp normalized_merge_artifact(merge_artifact) when is_map(merge_artifact) do
    with {:ok, status} <- merge_artifact_string(merge_artifact, "status"),
         :ok <- require_merge_artifact_status(status),
         {:ok, uri} <- merge_artifact_string(merge_artifact, "uri") do
      merge_artifact =
        merge_artifact
        |> trim_string_values()
        |> Map.put("status", status)
        |> Map.put("uri", uri)

      {:ok, merge_artifact}
    end
  end

  defp merge_artifact_string(merge_artifact, key) do
    case Map.get(merge_artifact, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_merge_artifact_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "missing_merge_artifact_#{key}"}
    end
  end

  defp require_merge_artifact_status("merged_into_phase"), do: :ok
  defp require_merge_artifact_status(_status), do: {:tool_error, "invalid_merge_artifact_status"}

  defp trim_string_values(value) when is_map(value) do
    Map.new(value, fn
      {key, string} when is_binary(string) -> {key, String.trim(string)}
      {key, nested} -> {key, trim_string_values(nested)}
    end)
  end

  defp trim_string_values(values) when is_list(values), do: Enum.map(values, &trim_string_values/1)
  defp trim_string_values(value), do: value

  defp existing_child_merge_record(repo, %Session{} = session, work_package_id, merge_artifact) do
    payload = child_merge_payload(work_package_id, merge_artifact)
    idempotency_key = ProgressEvents.metadata_idempotency_key(payload)

    case PlanningRepository.get_progress_event_by_idempotency_key(
           repo,
           work_package_id,
           idempotency_key,
           session.assignment.grant_id
         ) do
      {:ok, event} -> validate_child_merge_event(event, session, payload)
      {:error, :not_found} -> replay_child_merge_event(repo, session, work_package_id, idempotency_key, payload)
      {:error, reason} -> {:error, reason}
    end
  end

  defp replay_child_ready_approval_event(repo, %Session{} = session, work_package_id, idempotency_key, expected_identity) do
    with {:ok, event} <- existing_child_progress_event(repo, work_package_id, idempotency_key) do
      validate_child_ready_approval_event(event, session, expected_identity)
    end
  end

  defp replay_child_merge_event(repo, %Session{} = session, work_package_id, idempotency_key, expected_payload) do
    with {:ok, event} <- existing_child_progress_event(repo, work_package_id, idempotency_key) do
      validate_child_merge_event(event, session, expected_payload)
    end
  end

  defp existing_child_progress_event(repo, work_package_id, idempotency_key) do
    case PlanningRepository.list_progress_events(repo, work_package_id) do
      {:ok, progress_events} -> ProgressEvents.matching(progress_events, idempotency_key)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_child_ready_approval_event(event, session, expected_identity) do
    if event.status == "child_ready_approved" and child_ready_approval_identity_matches?(event.payload, expected_identity) do
      with :ok <- child_progress_event_actor_matches?(event, session), do: {:ok, event}
    else
      {:error, :idempotency_conflict}
    end
  end

  defp child_ready_approval_identity_matches?(payload, expected_identity) when is_map(payload) do
    payload
    |> Map.take(["type", "source_tool", "work_package_id", "request_id", "ready_cycle_id"])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Kernel.==(expected_identity)
  end

  defp child_ready_approval_identity_matches?(_payload, _expected_identity), do: false

  defp validate_child_merge_event(event, session, expected_payload) do
    if event.status == "merged_into_phase" and event.payload == expected_payload do
      with :ok <- child_progress_event_actor_role_matches?(event, session), do: {:ok, event}
    else
      {:error, :idempotency_conflict}
    end
  end

  defp child_progress_event_actor_matches?(%ProgressEvent{actor_id: event_actor_id, actor_type: event_actor_type}, %Session{} = session) do
    current_actor_id = session.assignment.claimed_by
    current_actor_type = session.assignment.grant_role

    cond do
      filled_string?(event_actor_type) and event_actor_type != current_actor_type ->
        {:error, :idempotency_conflict}

      filled_string?(event_actor_id) and filled_string?(current_actor_id) ->
        if String.trim(event_actor_id) == String.trim(current_actor_id), do: :ok, else: {:error, :idempotency_conflict}

      filled_string?(event_actor_id) ->
        {:error, :idempotency_conflict}

      true ->
        :ok
    end
  end

  defp child_progress_event_actor_role_matches?(%ProgressEvent{actor_type: event_actor_type}, %Session{} = session) do
    current_actor_type = session.assignment.grant_role

    if filled_string?(event_actor_type) and event_actor_type != current_actor_type do
      {:error, :idempotency_conflict}
    else
      :ok
    end
  end

  defp append_child_merge_event(repo, %Session{} = session, %WorkPackage{} = child, merge_artifact) do
    payload = child_merge_payload(child.id, merge_artifact)

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, child.id, %{
      "summary" => Map.get(merge_artifact, "summary") || "Child merged into phase",
      "status" => "merged_into_phase",
      "idempotency_key" => ProgressEvents.metadata_idempotency_key(payload),
      "payload" => payload
    })
  end

  defp child_merge_payload(work_package_id, merge_artifact) do
    %{
      "type" => "phase_child_merge",
      "source_tool" => "merge_child_into_phase",
      "work_package_id" => work_package_id,
      "merge_artifact" => merge_artifact
    }
  end

  defp record_phase_merge_artifact(repo, %WorkPackage{} = child, merge_artifact) do
    attrs = %{
      id: phase_merge_artifact_id(child.id),
      work_package_id: child.id,
      path: "phase-merge.json",
      title: "Phase merge record",
      kind: "phase_merge",
      uri: Map.fetch!(merge_artifact, "uri"),
      metadata: merge_artifact
    }

    case PlanningRepository.get_artifact(repo, attrs.id) do
      {:ok, nil} -> PlanningRepository.append_artifact(repo, attrs)
      {:ok, %Artifact{} = artifact} -> PlanningRepository.update_artifact(repo, artifact, Map.drop(attrs, [:id, :work_package_id]))
      {:error, reason} -> {:error, reason}
    end
  end

  defp phase_merge_artifact_id(work_package_id) do
    material = [work_package_id, "phase-merge.json"] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp child_merge_result(%WorkPackage{} = child, %ProgressEvent{} = event, %Artifact{} = artifact, merge_artifact) do
    %{
      "work_package" => child_work_package_payload(child),
      "merge" => ProgressEvents.payload(event),
      "artifact" => artifact_payload(artifact),
      "merge_artifact" => merge_artifact
    }
  end

  defp current_merge_artifact(%Artifact{} = artifact) do
    artifact
    |> artifact_metadata()
    |> Map.put("status", "merged_into_phase")
    |> Map.put("uri", artifact.uri)
  end

  defp artifact_metadata(%Artifact{metadata: metadata}) when is_map(metadata), do: metadata
  defp artifact_metadata(%Artifact{}), do: %{}

  defp architect_phase_child_transition(repo, %Session{} = session, %WorkPackage{} = child, next_status) do
    actor =
      session
      |> actor()
      |> Map.put(:work_package_id, child.id)
      |> Map.update!(:capabilities, &Enum.uniq(["architect:lifecycle.transition" | &1]))

    with :ok <- StateMachine.validate_transition(child, next_status, actor) do
      WorkPackageRepository.update_status(repo, child.id, child.status, next_status)
    end
  end

  defp reject_active_child_worker_grant(repo, work_package_id) do
    now = DateTime.utc_now(:microsecond)

    query =
      from(grant in AccessGrant,
        where:
          grant.work_package_id == ^work_package_id and grant.grant_role == "worker" and is_nil(grant.revoked_at) and
            grant.provenance == ^@child_worker_grant_provenance and
            (is_nil(grant.expires_at) or grant.expires_at > ^now),
        select: count(grant.id)
      )

    case repo.one(query) do
      0 -> :ok
      nil -> :ok
      _active_count -> {:tool_error, "active_child_worker_grant_exists"}
    end
  end

  defp architect_anchor_work_package(repo, %Session{} = session) do
    case Session.work_package_id(session) do
      work_package_id when is_binary(work_package_id) -> WorkPackageRepository.get(repo, work_package_id)
      _work_package_id -> {:error, :phase_scope_not_available}
    end
  end

  defp child_work_package_attrs(repo, %Session{} = session, package) do
    with {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session),
         :ok <- validate_child_work_package_keys(package),
         {:ok, title} <- required_argument(package, "title"),
         {:ok, acceptance_criteria} <- required_string_list(package, "acceptance_criteria"),
         {:ok, allowed_file_globs} <- PhaseChildScope.child_allowed_file_globs(package, anchor),
         :ok <- require_child_field_match(package, "kind", "phase_child", "invalid_child_kind"),
         :ok <- require_child_field_match(package, "policy_template", "phase_child", "invalid_policy_template"),
         :ok <- require_child_field_match(package, "status", "ready_for_worker", "invalid_child_status"),
         :ok <- require_child_field_match(package, "repo", anchor.repo, "repo_scope_mismatch"),
         :ok <- require_child_field_match(package, "base_branch", anchor.base_branch, "base_branch_scope_mismatch"),
         :ok <- require_child_field_match(package, "phase_id", phase_id, :phase_scope_not_available),
         :ok <- require_child_field_match(package, "parent_id", anchor.id, "parent_scope_mismatch"),
         {:ok, branch_pattern} <- optional_child_string(package, "branch_pattern"),
         {:ok, product_description} <- optional_child_string(package, "product_description", anchor.product_description),
         {:ok, engineering_scope} <- optional_child_string(package, "engineering_scope", anchor.engineering_scope),
         {:ok, owner_id} <- optional_child_string(package, "owner_id") do
      attrs =
        %{
          "acceptance_criteria" => acceptance_criteria,
          "allowed_file_globs" => allowed_file_globs,
          "base_branch" => anchor.base_branch,
          "kind" => "phase_child",
          "parent_id" => anchor.id,
          "phase_id" => phase_id,
          "policy_template" => "phase_child",
          "repo" => anchor.repo,
          "status" => "ready_for_worker",
          "title" => title
        }
        |> maybe_put_id(package)
        |> put_optional_child_value("branch_pattern", branch_pattern)
        |> put_optional_child_value("product_description", product_description)
        |> put_optional_child_value("engineering_scope", engineering_scope)
        |> put_optional_child_value("owner_id", owner_id)

      {:ok, attrs}
    end
  end

  defp validate_child_work_package_keys(package) do
    unexpected = package |> Map.keys() |> Enum.reject(&(&1 in @child_work_package_keys))

    cond do
      "context_slice" in unexpected -> {:tool_error, "unsupported_context_slice"}
      unexpected == [] -> :ok
      true -> {:tool_error, "unexpected_package_field"}
    end
  end

  defp require_child_field_match(package, key, expected, reason) do
    case Map.fetch(package, key) do
      :error -> :ok
      {:ok, nil} -> {:tool_error, "invalid_#{key}"}
      {:ok, value} when is_binary(value) -> require_nonblank_field_match(value, key, expected, reason)
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp require_nonblank_field_match(value, key, expected, reason) do
    case String.trim(value) do
      "" -> {:tool_error, "invalid_#{key}"}
      trimmed -> reject_null_string_field(trimmed, key, expected, reason)
    end
  end

  defp reject_null_string_field(trimmed, key, expected, reason) do
    if String.downcase(trimmed) == "null" do
      {:tool_error, "invalid_#{key}"}
    else
      require_optional_field_match(trimmed, expected, reason)
    end
  end

  defp require_optional_field_match(expected, expected, _reason), do: :ok
  defp require_optional_field_match(_value, _expected, reason) when is_atom(reason), do: {:error, reason}
  defp require_optional_field_match(_value, _expected, reason), do: {:tool_error, reason}

  defp optional_child_string(package, key, default \\ nil) do
    case Map.fetch(package, key) do
      :error -> {:ok, default}
      {:ok, nil} -> {:ok, default}
      {:ok, value} when is_binary(value) -> {:ok, blank_default(value, default)}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp blank_default(value, default) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp put_optional_child_value(attrs, _key, nil), do: attrs
  defp put_optional_child_value(attrs, key, value), do: Map.put(attrs, key, value)

  defp child_worker_grant_opts(template, %AccessGrant{} = architect_grant) do
    with :ok <- validate_child_worker_template_keys(template),
         {:ok, capabilities} <- child_worker_capabilities(template),
         {:ok, expires_at} <- child_worker_expires_at(template, architect_grant) do
      {:ok, [capabilities: capabilities, expires_at: expires_at, provenance: @child_worker_grant_provenance]}
    end
  end

  defp validate_child_worker_template_keys(template) do
    unexpected = template |> Map.keys() |> Enum.reject(&(&1 in @child_worker_template_keys))
    if unexpected == [], do: :ok, else: {:tool_error, "unexpected_template_field"}
  end

  defp child_worker_claimed_by(work_package_id, template) do
    with :ok <- validate_child_worker_template_keys(template) do
      case Map.fetch(template, "claimed_by") do
        :error -> {:ok, default_child_worker_claimed_by(work_package_id)}
        {:ok, nil} -> {:ok, default_child_worker_claimed_by(work_package_id)}
        {:ok, claimed_by} when is_binary(claimed_by) -> normalize_child_worker_claimed_by(claimed_by)
        {:ok, _claimed_by} -> {:tool_error, "invalid_claimed_by"}
      end
    end
  end

  defp normalize_child_worker_claimed_by(claimed_by) do
    case String.trim(claimed_by) do
      "" -> {:tool_error, "invalid_claimed_by"}
      claimed_by -> {:ok, claimed_by}
    end
  end

  defp default_child_worker_claimed_by(work_package_id), do: "sympp-child-worker:#{work_package_id}"

  defp child_worker_capabilities(template) do
    case Map.fetch(template, "capabilities") do
      :error -> {:ok, @child_worker_capabilities}
      {:ok, nil} -> {:ok, @child_worker_capabilities}
      {:ok, capabilities} when is_list(capabilities) -> normalize_child_worker_capabilities(capabilities)
      {:ok, _capabilities} -> {:tool_error, "invalid_capabilities"}
    end
  end

  defp normalize_child_worker_capabilities([_head | _tail] = capabilities) do
    if Enum.all?(capabilities, &(is_binary(&1) and String.trim(&1) != "")) do
      capabilities = capabilities |> Enum.map(&String.trim/1) |> Enum.uniq()

      if Enum.all?(capabilities, &(&1 in @child_worker_capabilities)) do
        {:ok, capabilities}
      else
        {:tool_error, "broader_child_grant"}
      end
    else
      {:tool_error, "invalid_capabilities"}
    end
  end

  defp normalize_child_worker_capabilities(_capabilities), do: {:tool_error, "invalid_capabilities"}

  defp child_worker_expires_at(template, %{expires_at: %DateTime{} = architect_expires_at}) do
    with {:ok, expires_at} <- optional_child_worker_expires_at(template, architect_expires_at),
         :ok <- require_child_expires_before_architect(expires_at, architect_expires_at) do
      {:ok, expires_at}
    end
  end

  defp child_worker_expires_at(template, %{expires_at: nil}) do
    with {:ok, expires_at} <- optional_child_worker_expires_at(template, nil),
         :ok <- require_child_expiry_live(expires_at) do
      {:ok, expires_at}
    end
  end

  defp optional_child_worker_expires_at(template, default) do
    case Map.fetch(template, "expires_at") do
      :error -> {:ok, default}
      {:ok, nil} -> {:ok, default}
      {:ok, value} when is_binary(value) -> parse_child_worker_expires_at(value)
      {:ok, _value} -> {:tool_error, "invalid_expires_at"}
    end
  end

  defp parse_child_worker_expires_at(value) do
    case String.trim(value) do
      "" ->
        {:tool_error, "invalid_expires_at"}

      trimmed ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
          {:error, _reason} -> {:tool_error, "invalid_expires_at"}
        end
    end
  end

  defp require_child_expires_before_architect(expires_at, architect_expires_at) do
    cond do
      is_nil(expires_at) -> {:tool_error, "broader_child_grant"}
      DateTime.compare(expires_at, architect_expires_at) == :gt -> {:tool_error, "broader_child_grant"}
      DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) != :gt -> {:tool_error, "invalid_expires_at"}
      true -> :ok
    end
  end

  defp require_child_expiry_live(nil), do: :ok

  defp require_child_expiry_live(%DateTime{} = expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) == :gt,
      do: :ok,
      else: {:tool_error, "invalid_expires_at"}
  end

  defp optional_request_id(arguments, key) do
    case Map.get(arguments, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "blank_request_id"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "invalid_request_id"}
    end
  end

  defp run_architect_transaction(repo, fun) do
    case repo.transaction(fn -> rollback_architect_transaction_result(repo, fun.()) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_architect_transaction_result(_repo, {:ok, result}), do: result
  defp rollback_architect_transaction_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})
  defp rollback_architect_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp architect_session(repo, session, capability) when is_binary(capability) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_architect_assignment(session.assignment),
         :ok <- require_architect_capabilities(repo, session.assignment, [capability]) do
      {:ok, session}
    end
  end

  defp architect_session(repo, session, capabilities) when is_list(capabilities) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_architect_assignment(session.assignment),
         :ok <- require_architect_capabilities(repo, session.assignment, capabilities) do
      {:ok, session}
    end
  end

  defp require_live_architect_grant(repo, %Session{} = session) do
    case AccessGrantRepository.get(repo, session.assignment.grant_id) do
      {:ok, %AccessGrant{} = grant} ->
        assignment = assignment_with_live_grant_capabilities(session.assignment, grant)

        with :ok <- require_session_grant_match(assignment, grant),
             :ok <- require_live_grant(grant, DateTime.utc_now(:microsecond)),
             :ok <- require_architect_assignment(assignment) do
          {:ok, grant}
        end

      {:error, :not_found} ->
        {:error, :phase_scope_not_available}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assignment_with_live_grant_capabilities(assignment, %AccessGrant{} = grant) do
    %{assignment | capabilities: grant.capabilities || []}
  end

  defp require_session_grant_match(assignment, %AccessGrant{} = grant) do
    with {:ok, assignment_capabilities} <- comparable_capabilities(assignment.capabilities),
         {:ok, grant_capabilities} <- comparable_capabilities(grant.capabilities),
         true <- assignment.grant_id == grant.id,
         true <- assignment.work_package_id == grant.work_package_id,
         true <- assignment.phase_id == grant.phase_id,
         true <- assignment.display_key == grant.display_key,
         true <- assignment.grant_role == grant.grant_role,
         true <- assignment_capabilities == grant_capabilities,
         true <- assignment.claimed_at == grant.claimed_at,
         true <- assignment.claimed_by == grant.claimed_by do
      :ok
    else
      _mismatch -> {:error, :phase_scope_not_available}
    end
  end

  defp comparable_capabilities(capabilities) when is_list(capabilities), do: {:ok, capabilities}
  defp comparable_capabilities(nil), do: {:ok, []}

  defp require_live_grant(%AccessGrant{revoked_at: %DateTime{}}, _now), do: {:error, :assignment_revoked}

  defp require_live_grant(%AccessGrant{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    if DateTime.compare(expires_at, now) == :gt do
      :ok
    else
      {:error, :expired}
    end
  end

  defp require_live_grant(%AccessGrant{expires_at: nil}, %DateTime{}), do: :ok

  defp require_architect_capabilities(repo, assignment, capabilities) do
    with {:ok, effective_assignment} <- effective_architect_assignment(repo, assignment) do
      require_architect_capabilities(effective_assignment, capabilities)
    end
  end

  defp require_architect_capabilities(assignment, capabilities) do
    Enum.reduce_while(capabilities, :ok, fn capability, :ok ->
      case require_architect_capability(assignment, capability) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp effective_architect_assignment(repo, %{grant_role: "architect", grant_id: grant_id} = assignment) do
    with {:ok, %AccessGrant{} = grant} <- AccessGrantRepository.get(repo, grant_id) do
      case ArchitectHandoff.handoff_phase_grant?(repo, grant) do
        {:ok, true} ->
          {:ok, %{assignment | capabilities: ArchitectHandoff.effective_capabilities(grant.capabilities)}}

        {:ok, false} ->
          {:ok, %{assignment | capabilities: grant.capabilities || []}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp require_architect_assignment(%{grant_role: "architect"}), do: :ok
  defp require_architect_assignment(_assignment), do: {:error, :architect_grant_required}

  defp require_architect_capability(%{capabilities: capabilities}, capability) when is_list(capabilities) do
    if capability in capabilities do
      :ok
    else
      {:error, :insufficient_capability}
    end
  end

  defp require_architect_capability(_assignment, _capability), do: {:error, :insufficient_capability}

  defp require_architect_phase_scope(repo, %Session{} = session, phase_id) do
    case architect_phase_scope(repo, session) do
      {:ok, ^phase_id} -> :ok
      {:ok, _other_phase_id} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp architect_phase_scope(repo, %Session{} = session) do
    case Session.phase_id(session) do
      phase_id when is_binary(phase_id) and phase_id != "" -> {:ok, phase_id}
      nil -> architect_session_anchor_phase_scope(repo, session)
      _phase_id -> {:error, :phase_scope_not_available}
    end
  end

  defp architect_session_anchor_phase_scope(repo, %Session{} = session) when is_atom(repo) do
    case Session.work_package_id(session) do
      work_package_id when is_binary(work_package_id) -> architect_anchor_phase_scope(repo, work_package_id)
      _work_package_id -> {:error, :phase_scope_not_available}
    end
  end

  defp architect_session_anchor_phase_scope(_repo, %Session{}), do: {:error, :phase_scope_not_available}

  defp architect_anchor_phase_scope(repo, work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %{phase_id: phase_id}} when is_binary(phase_id) and phase_id != "" -> {:ok, phase_id}
      {:ok, _work_package} -> {:error, :phase_scope_not_available}
      {:error, _reason} -> {:error, :phase_scope_not_available}
    end
  end

  defp architect_child_phase_anchor(repo, %Session{} = session) do
    with {:ok, grant} <- require_live_architect_grant(repo, session) do
      architect_child_phase_anchor(repo, session, grant)
    end
  end

  defp architect_child_phase_anchor(repo, %Session{} = session, %AccessGrant{} = grant) do
    with {:ok, phase_id} <- explicit_grant_phase_id(grant),
         {:ok, anchor} <- architect_anchor_work_package(repo, session),
         :ok <- require_frozen_anchor_scope(anchor, grant) do
      {:ok, phase_id, anchor}
    else
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp explicit_grant_phase_id(%AccessGrant{phase_id: phase_id}) when is_binary(phase_id) and phase_id != "", do: {:ok, phase_id}
  defp explicit_grant_phase_id(%AccessGrant{}), do: {:error, :phase_scope_not_available}

  defp require_architect_phase_anchor(repo, %Session{} = session, phase_id) when is_atom(repo) and is_binary(phase_id) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, anchor} <- architect_anchor_work_package(repo, session) do
      require_architect_anchor_scope(anchor, grant, phase_id)
    else
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_architect_anchor_scope(%WorkPackage{} = anchor, %AccessGrant{} = grant, phase_id) do
    cond do
      anchor.phase_id != phase_id ->
        {:error, :phase_scope_not_available}

      architect_explicit_phase_grant?(grant) ->
        require_frozen_anchor_scope(anchor, grant)

      true ->
        :ok
    end
  end

  defp architect_explicit_phase_grant?(%AccessGrant{grant_role: "architect", phase_id: phase_id}) when is_binary(phase_id) and phase_id != "",
    do: true

  defp architect_explicit_phase_grant?(%AccessGrant{}), do: false

  defp explicit_phase_id?(phase_id) when is_binary(phase_id), do: String.trim(phase_id) != ""
  defp explicit_phase_id?(_phase_id), do: false

  defp require_frozen_anchor_scope(%WorkPackage{} = anchor, %AccessGrant{} = grant) do
    if grant.phase_id == anchor.phase_id and repo_scope_name_matches?(grant.scope_repo, anchor.repo, []) and grant.scope_base_branch == anchor.base_branch do
      :ok
    else
      {:error, :phase_scope_not_available}
    end
  end

  defp lock_work_package(repo, work_package_id) do
    query = from(work_package in WorkPackage, where: work_package.id == ^work_package_id)

    case repo.update_all(query, set: [id: work_package_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

  defp lock_access_grant(repo, grant_id) do
    query = from(access_grant in AccessGrant, where: access_grant.id == ^grant_id)

    case repo.update_all(query, set: [id: grant_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :phase_scope_not_available}
    end
  end

  defp plan_version(plan_nodes) do
    material =
      Enum.map(plan_nodes, fn node ->
        %{
          id: node.id,
          title: node.title,
          body: node.body,
          status: node.status,
          position: node.position,
          updated_at: timestamp_version_part(node.updated_at)
        }
      end)

    :crypto.hash(:sha256, :erlang.term_to_binary(material))
    |> binary_part(0, 8)
    |> :binary.decode_unsigned()
    |> rem(9_007_199_254_740_991)
  end

  defp timestamp_version_part(nil), do: nil
  defp timestamp_version_part(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)

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

  defp required_object(arguments, key) do
    case Map.get(arguments, key) do
      value when is_map(value) -> {:ok, value}
      _value -> {:tool_error, "missing_#{key}"}
    end
  end

  defp optional_object_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp required_list(arguments, key) do
    case Map.get(arguments, key) do
      [_head | _tail] = value -> {:ok, value}
      nil -> {:tool_error, "missing_#{key}"}
      [] -> {:tool_error, "missing_#{key}"}
      _value -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp required_string_list(arguments, key) do
    with {:ok, values} <- required_list(arguments, key) do
      if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
        {:ok, Enum.map(values, &String.trim/1)}
      else
        {:tool_error, "invalid_#{key}"}
      end
    end
  end

  defp maybe_put_id(attrs, arguments) do
    case Map.get(arguments, "id") do
      id when is_binary(id) ->
        case String.trim(id) do
          "" -> attrs
          trimmed -> Map.put(attrs, "id", trimmed)
        end

      _id ->
        attrs
    end
  end

  defp actor(%Session{} = session) do
    %{
      grant_id: session.assignment.grant_id,
      grant_role: session.assignment.grant_role,
      capabilities: session.assignment.capabilities,
      work_package_id: session.assignment.work_package_id
    }
  end

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp maybe_put_filled_string(payload, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> payload
      trimmed -> Map.put(payload, key, trimmed)
    end
  end

  defp maybe_put_filled_string(payload, _key, _value), do: payload

  defp artifact_payload(%Artifact{} = artifact) do
    %{
      "id" => artifact.id,
      "path" => Redactor.redact_text(artifact.path),
      "title" => Redactor.redact_text(artifact.title),
      "kind" => artifact.kind,
      "uri" => Redactor.redact_text(artifact.uri),
      "metadata" => Redactor.redact_output(artifact.metadata || %{})
    }
  end

  defp work_package_payload(%WorkPackage{} = work_package) do
    %{"id" => work_package.id, "kind" => work_package.kind, "status" => work_package.status}
  end

  defp child_work_package_payload(%WorkPackage{} = work_package) do
    work_package
    |> work_package_payload()
    |> Map.merge(%{
      "acceptance_criteria" => work_package.acceptance_criteria || [],
      "allowed_file_globs" => work_package.allowed_file_globs || [],
      "base_branch" => work_package.base_branch,
      "parent_id" => work_package.parent_id,
      "phase_id" => work_package.phase_id,
      "policy_template" => work_package.policy_template,
      "repo" => work_package.repo,
      "title" => work_package.title
    })
  end

  defp child_worker_grant_payload(%{grant: grant}, %WorkPackage{} = child, claimed_by, ledger_database) do
    %{
      "id" => grant.id,
      "work_package_id" => grant.work_package_id,
      "grant_role" => grant.grant_role,
      "capabilities" => grant.capabilities || [],
      "expires_at" => timestamp(grant.expires_at),
      "secret_in_response" => false,
      "worker_bootstrap" => child_worker_bootstrap_payload(child, claimed_by, ledger_database)
    }
  end

  defp child_worker_bootstrap_payload(%WorkPackage{} = child, claimed_by, ledger_database) do
    %{
      "type" => "ledger_claim",
      "mode" => "local_assignment",
      "ledger" => %{"database" => ledger_database},
      "claim" => %{
        "tool" => @local_assignment_claim_tool,
        "arguments" => %{"work_package_id" => child.id, "claimed_by" => claimed_by},
        "required_runtime_arguments" => []
      }
    }
  end

  defp live_expires_at?(nil, %DateTime{}), do: true
  defp live_expires_at?(%DateTime{} = expires_at, %DateTime{} = now), do: DateTime.compare(expires_at, now) == :gt

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
  end

  defp architect_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)
  defp architect_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:expired, resource), do: auth_error({:unauthorized, :expired}, resource)
  defp architect_error(:assignment_revoked, resource), do: auth_error({:unauthorized, :revoked}, resource)
  defp architect_error(:architect_grant_required, resource), do: auth_error({:unauthorized, :architect_grant_required}, resource)
  defp architect_error(:insufficient_capability, resource), do: auth_error({:unauthorized, :insufficient_capability}, resource)
  defp architect_error({:authorization_policy_denied, %Decision{} = decision}, resource), do: MCPError.from_decision(decision, resource)
  defp architect_error({:authorization_policy_denied, code, message, data}, _resource), do: {:error, code, message, data}
  defp architect_error(:phase_scope_not_available, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:phase_scope_not_available, _missing_evidence}, resource), do: auth_error(:forbidden, resource)
  defp architect_error(:ambiguous_phase_scope, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:work_request_terminal, _terminal_state}, resource), do: auth_error(:forbidden, resource)
  defp architect_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp architect_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp auth_error(:unauthorized, resource) do
    {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}
  end

  defp auth_error({:unauthorized, reason}, resource) do
    {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}
  end

  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)

  defp auth_error(:forbidden, resource) do
    {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}
  end

  defp service_error(_reason, resource) do
    {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  defp timestamp(timestamp), do: mcp_timestamp(timestamp)
  defp mcp_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  defp mcp_timestamp(%NaiveDateTime{} = timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp mcp_timestamp(nil), do: nil

  defp json_safe_payload(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
