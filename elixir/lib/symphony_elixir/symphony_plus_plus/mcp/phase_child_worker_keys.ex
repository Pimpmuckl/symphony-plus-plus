defmodule SymphonyElixir.SymphonyPlusPlus.MCP.PhaseChildWorkerKeys do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Config,
    HandoffDatabase,
    ProgressEvents,
    Session,
    ToolCatalog
  }

  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @template_keys ["capabilities", "expires_at", "claimed_by"]
  @capabilities ["worker:claim", "worker:lifecycle.transition"]
  @ready_status "ready_for_worker"
  @resettable_statuses [
    "claimed",
    "planning",
    "implementing",
    "reviewing",
    "ci_waiting",
    "blocked"
  ]
  @recyclable_statuses [@ready_status | @resettable_statuses]
  @grant_provenance "child_worker_delegation"
  @local_assignment_claim_tool ToolCatalog.local_assignment_claim_tool()

  @spec mint(Config.t(), Session.t(), String.t(), map() | nil, map()) ::
          {:ok, map()} | {:tool_error, String.t()} | {:error, term()}
  def mint(%Config{} = config, %Session{} = session, work_package_id, template, deps) do
    template = template || %{}

    with {:ok, claimed_by} <- claimed_by(work_package_id, template),
         {:ok, {child, minted, ledger_database}} <-
           mint_transaction(config, session, work_package_id, template, deps) do
      {:ok,
       %{
         "work_package" => child_work_package_payload(child),
         "worker_grant" => grant_payload(minted, child, claimed_by, ledger_database)
       }}
    end
  end

  @spec revoke(module(), Session.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:tool_error, String.t()} | {:error, term()}
  def revoke(repo, %Session{} = session, grant_id, reason, deps) do
    transaction(repo, fn ->
      revoke_in_transaction(repo, session, grant_id, reason, deps)
    end)
  end

  @spec required_revoke_string(map(), String.t()) :: {:ok, String.t()} | {:tool_error, String.t()}
  def required_revoke_string(arguments, key) do
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

  defp mint_transaction(
         %Config{repo: repo} = config,
         %Session{} = session,
         work_package_id,
         template,
         deps
       ) do
    transaction(repo, fn ->
      mint_in_transaction(config, session, work_package_id, template, deps)
    end)
  end

  defp transaction(repo, fun) do
    case repo.transaction(fn -> rollback_result(repo, fun.()) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_result(_repo, {:ok, result}), do: result
  defp rollback_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})
  defp rollback_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp mint_in_transaction(
         %Config{repo: repo} = config,
         %Session{} = session,
         work_package_id,
         template,
         deps
       ) do
    with :ok <- deps.lock_access_grant.(repo, session.assignment.grant_id),
         {:ok, architect_grant} <- deps.require_live_architect_grant.(repo, session),
         :ok <- deps.lock_work_package.(repo, Session.work_package_id(session)),
         {:ok, phase_id, anchor} <-
           deps.architect_child_phase_anchor.(repo, session, architect_grant),
         {:ok, grant_opts} <- grant_opts(template, architect_grant),
         {:ok, _prechecked_child} <-
           deps.require_transaction_current_child_scope.(repo, work_package_id, anchor, phase_id),
         :ok <- deps.lock_work_package.(repo, work_package_id),
         :ok <- reject_active_grant(repo, work_package_id),
         {:ok, child} <-
           deps.require_child_ready_for_mint.(repo, work_package_id, anchor, phase_id),
         {:ok, ledger_database} <- HandoffDatabase.resolve(config.database, repo),
         {:ok, minted} <- AccessGrantService.mint_worker_grant(repo, child.id, grant_opts) do
      {:ok, {child, minted, ledger_database}}
    end
  end

  defp revoke_in_transaction(repo, %Session{} = session, grant_id, reason, deps) do
    now = DateTime.utc_now(:microsecond)

    with :ok <- deps.lock_access_grant.(repo, session.assignment.grant_id),
         {:ok, architect_grant} <- deps.require_live_architect_grant.(repo, session),
         :ok <- deps.lock_work_package.(repo, Session.work_package_id(session)),
         {:ok, phase_id, anchor} <-
           deps.architect_child_phase_anchor.(repo, session, architect_grant),
         {:ok, candidate_grant} <-
           scoped_grant_for_revoke(repo, grant_id, anchor, phase_id, now, deps),
         :ok <- deps.lock_work_package.(repo, candidate_grant.work_package_id),
         :ok <- deps.lock_access_grant.(repo, grant_id),
         {:ok, grant} <- scoped_grant_for_revoke(repo, grant_id, anchor, phase_id, now, deps),
         {:ok, child} <-
           deps.require_transaction_current_child_scope.(
             repo,
             grant.work_package_id,
             anchor,
             phase_id
           ),
         :ok <- require_recyclable_status(child),
         {:ok, revoked_grant} <- revoke_live_grant(repo, grant, now),
         {:ok, reset_child} <- reset_for_recycle(repo, child, now),
         {:ok, event} <-
           append_revoke_event(repo, session, child, reset_child, revoked_grant, reason) do
      {:ok, revoke_result(reset_child, revoked_grant, event, reason, child.status)}
    end
  end

  defp scoped_grant_for_revoke(
         repo,
         grant_id,
         %WorkPackage{} = anchor,
         phase_id,
         %DateTime{} = now,
         deps
       ) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, grant_id),
         {:ok, work_package_id} <- grant_work_package_id(grant),
         {:ok, _child} <-
           deps.require_transaction_current_child_scope.(repo, work_package_id, anchor, phase_id),
         :ok <- require_live_grant_for_revoke(grant, now) do
      {:ok, grant}
    end
  end

  defp grant_work_package_id(%AccessGrant{work_package_id: work_package_id})
       when is_binary(work_package_id) do
    case String.trim(work_package_id) do
      "" -> {:error, :phase_scope_not_available}
      trimmed -> {:ok, trimmed}
    end
  end

  defp grant_work_package_id(%AccessGrant{}), do: {:error, :phase_scope_not_available}

  defp require_live_grant_for_revoke(
         %AccessGrant{grant_role: "worker", provenance: @grant_provenance} = grant,
         now
       ) do
    cond do
      not grant_capabilities?(grant.capabilities || []) -> {:tool_error, "not_child_worker_grant"}
      match?(%DateTime{}, grant.revoked_at) -> {:tool_error, "child_worker_grant_already_revoked"}
      not live_expires_at?(grant.expires_at, now) -> {:tool_error, "child_worker_grant_expired"}
      true -> :ok
    end
  end

  defp require_live_grant_for_revoke(%AccessGrant{}, _now),
    do: {:tool_error, "not_child_worker_grant"}

  defp grant_capabilities?(capabilities) when is_list(capabilities),
    do: Enum.all?(capabilities, &(&1 in @capabilities))

  defp grant_capabilities?(_capabilities), do: false

  defp require_recyclable_status(%WorkPackage{status: status})
       when status in @recyclable_statuses, do: :ok

  defp require_recyclable_status(%WorkPackage{}), do: {:tool_error, "child_not_recyclable"}

  defp revoke_live_grant(repo, %AccessGrant{} = grant, %DateTime{} = now) do
    query =
      from(access_grant in AccessGrant,
        where:
          access_grant.id == ^grant.id and access_grant.work_package_id == ^grant.work_package_id and
            access_grant.grant_role == "worker" and access_grant.provenance == ^@grant_provenance and
            is_nil(access_grant.revoked_at) and
            (is_nil(access_grant.expires_at) or access_grant.expires_at > ^now)
      )

    case repo.update_all(query, set: [revoked_at: now, updated_at: now]) do
      {1, _rows} -> AccessGrantRepository.get(repo, grant.id)
      {0, _rows} -> classify_revoke_miss(repo, grant.id, now)
    end
  end

  defp classify_revoke_miss(repo, grant_id, %DateTime{} = now) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, grant_id) do
      case require_live_grant_for_revoke(grant, now) do
        :ok -> {:tool_error, "child_worker_revoke_conflict"}
        {:tool_error, reason} -> {:tool_error, reason}
      end
    end
  end

  defp reset_for_recycle(_repo, %WorkPackage{status: @ready_status} = child, _now),
    do: {:ok, child}

  defp reset_for_recycle(repo, %WorkPackage{status: status} = child, %DateTime{} = now)
       when status in @resettable_statuses do
    query =
      from(work_package in WorkPackage,
        where:
          work_package.id == ^child.id and work_package.kind == "phase_child" and
            work_package.status == ^status
      )

    case repo.update_all(query, set: [status: @ready_status, updated_at: now]) do
      {1, _rows} -> WorkPackageRepository.get(repo, child.id)
      {0, _rows} -> {:tool_error, "child_worker_recycle_status_conflict"}
    end
  end

  defp reset_for_recycle(_repo, %WorkPackage{}, _now), do: {:tool_error, "child_not_recyclable"}

  defp append_revoke_event(
         repo,
         %Session{} = session,
         %WorkPackage{} = previous_child,
         %WorkPackage{} = reset_child,
         %AccessGrant{} = grant,
         reason
       ) do
    payload =
      revoke_payload(reset_child.id, grant, reason, previous_child.status, reset_child.status)

    PlanningRepository.append_audit_progress_event_for_work_package(
      repo,
      session.assignment,
      reset_child.id,
      %{
        "summary" => "Child worker grant revoked for recycle",
        "body" => "Recycle reason: #{redacted_reason(reason)}; child status: #{previous_child.status} -> #{reset_child.status}",
        "status" => "child_worker_key_revoked",
        "idempotency_key" => ProgressEvents.metadata_idempotency_key(payload),
        "payload" => payload
      }
    )
  end

  defp revoke_payload(
         work_package_id,
         %AccessGrant{} = grant,
         reason,
         previous_status,
         new_status
       ) do
    reason_codes = recycle_reason_codes(previous_status, new_status)

    %{
      "type" => "child_worker_key_revoke",
      "source_tool" => "revoke_child_worker_key",
      "work_package_id" => work_package_id,
      "grant_id" => grant.id,
      "reason" => redacted_reason(reason),
      "revoked_at" => timestamp(grant.revoked_at),
      "previous_status" => previous_status,
      "new_status" => new_status,
      "status_reset" => previous_status != new_status,
      "lifecycle_state" => "recycled",
      "reason_codes" => reason_codes
    }
  end

  defp revoke_result(
         %WorkPackage{} = child,
         %AccessGrant{} = grant,
         %ProgressEvent{} = event,
         reason,
         previous_status
       ) do
    %{
      "work_package" => child_work_package_payload(child),
      "revoked_worker_grant" => revoked_grant_payload(grant),
      "recycle" => %{
        "status" => "revoked",
        "reason" => redacted_reason(reason),
        "previous_child_status" => previous_status,
        "new_child_status" => child.status,
        "status_reset" => previous_status != child.status,
        "remint_available" => true,
        "remint_precondition" => "child_status_ready_for_worker",
        "lifecycle_state" => "recycled",
        "reason_codes" => recycle_reason_codes(previous_status, child.status)
      },
      "revocation_event" => ProgressEvents.payload(event)
    }
  end

  defp recycle_reason_codes(previous_status, new_status) do
    [
      "worker_recycled",
      if(previous_status != new_status, do: "work_package_reset_for_recycle")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp revoked_grant_payload(%AccessGrant{} = grant) do
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

  defp redacted_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> Redactor.redact_text()
  end

  defp reject_active_grant(repo, work_package_id) do
    now = DateTime.utc_now(:microsecond)

    query =
      from(grant in AccessGrant,
        where:
          grant.work_package_id == ^work_package_id and grant.grant_role == "worker" and
            is_nil(grant.revoked_at) and
            grant.provenance == ^@grant_provenance and
            (is_nil(grant.expires_at) or grant.expires_at > ^now),
        select: count(grant.id)
      )

    case repo.one(query) do
      0 -> :ok
      nil -> :ok
      _active_count -> {:tool_error, "active_child_worker_grant_exists"}
    end
  end

  defp grant_opts(template, %AccessGrant{} = architect_grant) do
    with :ok <- validate_template_keys(template),
         {:ok, capabilities} <- capabilities(template),
         {:ok, expires_at} <- expires_at(template, architect_grant) do
      {:ok, [capabilities: capabilities, expires_at: expires_at, provenance: @grant_provenance]}
    end
  end

  defp validate_template_keys(template) do
    unexpected = template |> Map.keys() |> Enum.reject(&(&1 in @template_keys))
    if unexpected == [], do: :ok, else: {:tool_error, "unexpected_template_field"}
  end

  defp claimed_by(work_package_id, template) do
    with :ok <- validate_template_keys(template) do
      case Map.fetch(template, "claimed_by") do
        :error -> {:ok, default_claimed_by(work_package_id)}
        {:ok, nil} -> {:ok, default_claimed_by(work_package_id)}
        {:ok, claimed_by} when is_binary(claimed_by) -> normalize_claimed_by(claimed_by)
        {:ok, _claimed_by} -> {:tool_error, "invalid_claimed_by"}
      end
    end
  end

  defp normalize_claimed_by(claimed_by) do
    case String.trim(claimed_by) do
      "" -> {:tool_error, "invalid_claimed_by"}
      claimed_by -> {:ok, claimed_by}
    end
  end

  defp default_claimed_by(work_package_id), do: "sympp-child-worker:#{work_package_id}"

  defp capabilities(template) do
    case Map.fetch(template, "capabilities") do
      :error -> {:ok, @capabilities}
      {:ok, nil} -> {:ok, @capabilities}
      {:ok, capabilities} when is_list(capabilities) -> normalize_capabilities(capabilities)
      {:ok, _capabilities} -> {:tool_error, "invalid_capabilities"}
    end
  end

  defp normalize_capabilities([_head | _tail] = capabilities) do
    if Enum.all?(capabilities, &(is_binary(&1) and String.trim(&1) != "")) do
      capabilities = capabilities |> Enum.map(&String.trim/1) |> Enum.uniq()

      if Enum.all?(capabilities, &(&1 in @capabilities)) do
        {:ok, capabilities}
      else
        {:tool_error, "broader_child_grant"}
      end
    else
      {:tool_error, "invalid_capabilities"}
    end
  end

  defp normalize_capabilities(_capabilities), do: {:tool_error, "invalid_capabilities"}

  defp expires_at(template, %{expires_at: %DateTime{} = architect_expires_at}) do
    with {:ok, expires_at} <- optional_expires_at(template, architect_expires_at),
         :ok <- require_expires_before_architect(expires_at, architect_expires_at) do
      {:ok, expires_at}
    end
  end

  defp expires_at(template, %{expires_at: nil}) do
    with {:ok, expires_at} <- optional_expires_at(template, nil),
         :ok <- require_expiry_live(expires_at) do
      {:ok, expires_at}
    end
  end

  defp optional_expires_at(template, default) do
    case Map.fetch(template, "expires_at") do
      :error -> {:ok, default}
      {:ok, nil} -> {:ok, default}
      {:ok, value} when is_binary(value) -> parse_expires_at(value)
      {:ok, _value} -> {:tool_error, "invalid_expires_at"}
    end
  end

  defp parse_expires_at(value) do
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

  defp require_expires_before_architect(expires_at, architect_expires_at) do
    cond do
      is_nil(expires_at) ->
        {:tool_error, "broader_child_grant"}

      DateTime.compare(expires_at, architect_expires_at) == :gt ->
        {:tool_error, "broader_child_grant"}

      DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) != :gt ->
        {:tool_error, "invalid_expires_at"}

      true ->
        :ok
    end
  end

  defp require_expiry_live(nil), do: :ok

  defp require_expiry_live(%DateTime{} = expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) == :gt,
      do: :ok,
      else: {:tool_error, "invalid_expires_at"}
  end

  defp child_work_package_payload(%WorkPackage{} = work_package) do
    %{
      "id" => work_package.id,
      "kind" => work_package.kind,
      "status" => work_package.status,
      "acceptance_criteria" => work_package.acceptance_criteria || [],
      "allowed_file_globs" => work_package.allowed_file_globs || [],
      "base_branch" => work_package.base_branch,
      "parent_id" => work_package.parent_id,
      "phase_id" => work_package.phase_id,
      "policy_template" => work_package.policy_template,
      "repo" => work_package.repo,
      "title" => work_package.title
    }
  end

  defp grant_payload(%{grant: grant}, %WorkPackage{} = child, claimed_by, ledger_database) do
    %{
      "id" => grant.id,
      "work_package_id" => grant.work_package_id,
      "grant_role" => grant.grant_role,
      "capabilities" => grant.capabilities || [],
      "expires_at" => timestamp(grant.expires_at),
      "secret_in_response" => false,
      "worker_bootstrap" => bootstrap_payload(child, claimed_by, ledger_database)
    }
  end

  defp bootstrap_payload(%WorkPackage{} = child, claimed_by, ledger_database) do
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

  defp live_expires_at?(%DateTime{} = expires_at, %DateTime{} = now),
    do: DateTime.compare(expires_at, now) == :gt

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp timestamp(nil), do: nil
end
