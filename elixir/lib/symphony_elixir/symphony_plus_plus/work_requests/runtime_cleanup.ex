defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.RuntimeCleanup do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.MCP.SessionBinding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @source_tool "cleanup_work_request_work_package_runtime"
  @release_reason "work_request_runtime_cleanup"

  @type cleanup_result :: %{
          required(:work_package) => WorkPackage.t(),
          required(:runtime_cleanup) => map(),
          required(:audit_event) => ProgressEvent.t()
        }

  @spec source_tool() :: String.t()
  def source_tool, do: @source_tool

  @spec cleanup(module(), WorkRequest.t(), WorkPackage.t(), Assignment.t(), keyword()) ::
          {:ok, cleanup_result()} | {:error, term()}
  def cleanup(repo, %WorkRequest{} = work_request, %WorkPackage{} = work_package, %Assignment{} = assignment, opts \\ [])
      when is_atom(repo) and is_list(opts) do
    now = DateTime.utc_now(:microsecond)
    reason = opts |> Keyword.get(:reason, "") |> redacted_reason()
    delivery_evidence = opts |> Keyword.get(:delivery_evidence, %{}) |> normalize_delivery_evidence()
    before_context = WorkPackageActivity.context(repo, work_package.id)

    with :ok <- reject_paused_claim_leases(before_context),
         :ok <- reject_fresh_active_agent_runs(before_context),
         {:ok, revoked_worker_grants} <- revoke_live_worker_grants(repo, work_package.id, now),
         {:ok, released_claim_leases} <- release_current_claim_leases(repo, work_package.id, now),
         {:ok, cleared_session_bindings} <- clear_recoverable_session_bindings(repo, work_package.id),
         payload <-
           runtime_cleanup_payload(%{
             work_request: work_request,
             work_package: work_package,
             reason: reason,
             delivery_evidence: delivery_evidence,
             before_context: before_context,
             revoked_worker_grants: revoked_worker_grants,
             released_claim_leases: released_claim_leases,
             cleared_session_bindings: cleared_session_bindings,
             cleaned_at: now
           }),
         {:ok, audit_event} <- append_runtime_cleanup_event(repo, assignment, work_package.id, payload, reason) do
      {:ok,
       %{
         work_package: work_package,
         runtime_cleanup: runtime_cleanup_result(payload),
         audit_event: audit_event
       }}
    end
  end

  defp reject_paused_claim_leases(context) do
    if get_in(context, [:runtime_state, :paused?]) == true do
      {:error, :active_runtime}
    else
      :ok
    end
  end

  defp reject_fresh_active_agent_runs(context) do
    case List.wrap(get_in(context, [:runtime_state, :active_agent_run_ids])) do
      [] -> :ok
      _active_agent_run_ids -> {:error, :active_runtime}
    end
  end

  defp revoke_live_worker_grants(repo, work_package_id, %DateTime{} = now) do
    grants = repo.all(live_worker_grant_query(work_package_id, now))
    grant_ids = Enum.map(grants, & &1.id)

    if grant_ids == [] do
      {:ok, []}
    else
      query = live_worker_grant_update_query(work_package_id, now, grant_ids)

      case repo.update_all(query, set: [revoked_at: now, updated_at: now]) do
        {count, _rows} when count == length(grant_ids) ->
          {:ok, repo.all(from(grant in AccessGrant, where: grant.id in ^grant_ids, order_by: [asc: grant.inserted_at, asc: grant.id]))}

        {_count, _rows} ->
          {:error, :worker_grant_revoke_conflict}
      end
    end
  end

  defp live_worker_grant_query(work_package_id, %DateTime{} = now) do
    from(grant in live_worker_grant_base_query(work_package_id, now),
      order_by: [asc: grant.inserted_at, asc: grant.id]
    )
  end

  defp live_worker_grant_update_query(work_package_id, %DateTime{} = now, grant_ids) do
    from(grant in live_worker_grant_base_query(work_package_id, now),
      where: grant.id in ^grant_ids
    )
  end

  defp live_worker_grant_base_query(work_package_id, %DateTime{} = now) do
    from(grant in AccessGrant,
      where: grant.work_package_id == ^work_package_id,
      where: grant.grant_role == "worker",
      where: is_nil(grant.revoked_at),
      where: is_nil(grant.expires_at) or grant.expires_at > ^now
    )
  end

  defp release_current_claim_leases(repo, work_package_id, %DateTime{} = now) do
    current_claim_leases = repo.all(current_claim_lease_query(work_package_id))

    case Enum.filter(current_claim_leases, &(&1.status == "paused")) do
      [] -> release_active_claim_leases(repo, current_claim_leases, now)
      _paused_claim_leases -> {:error, :active_runtime}
    end
  end

  defp current_claim_lease_query(work_package_id) do
    from(claim_lease in ClaimLease,
      where: claim_lease.work_package_id == ^work_package_id,
      where: claim_lease.status in ^ClaimLease.active_statuses(),
      order_by: [asc: claim_lease.inserted_at, asc: claim_lease.id]
    )
  end

  defp release_active_claim_leases(repo, current_claim_leases, %DateTime{} = now) do
    active_ids =
      current_claim_leases
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.map(& &1.id)

    if active_ids == [] do
      {:ok, []}
    else
      query =
        from(claim_lease in ClaimLease,
          where: claim_lease.id in ^active_ids,
          where: claim_lease.status == "active"
        )

      case repo.update_all(query,
             set: [
               status: "released",
               released_at: now,
               release_reason: @release_reason,
               last_seen_at: now,
               updated_at: now
             ]
           ) do
        {count, _rows} when count == length(active_ids) ->
          {:ok, repo.all(from(claim_lease in ClaimLease, where: claim_lease.id in ^active_ids, order_by: [asc: claim_lease.inserted_at, asc: claim_lease.id]))}

        {_count, _rows} ->
          {:error, :claim_not_current}
      end
    end
  end

  defp clear_recoverable_session_bindings(repo, work_package_id) do
    bindings =
      repo.all(
        from(binding in SessionBinding,
          where: binding.work_package_id == ^work_package_id,
          where: binding.grant_role == "worker",
          where: binding.recoverable == true,
          order_by: [asc: binding.inserted_at, asc: binding.id]
        )
      )

    binding_ids = Enum.map(bindings, & &1.id)

    if binding_ids == [] do
      {:ok, []}
    else
      query =
        from(binding in SessionBinding,
          where: binding.id in ^binding_ids,
          where: binding.grant_role == "worker",
          where: binding.recoverable == true
        )

      case repo.delete_all(query) do
        {count, _rows} when count == length(binding_ids) -> {:ok, bindings}
        {_count, _rows} -> {:error, :mcp_session_binding_conflict}
      end
    end
  end

  defp append_runtime_cleanup_event(repo, %Assignment{} = assignment, work_package_id, payload, reason) do
    PlanningRepository.append_audit_progress_event_for_work_package(repo, assignment, work_package_id, %{
      "summary" => "WorkRequest work-package runtime cleaned up",
      "body" => "Cleanup reason: #{reason}; WorkRequest: #{payload["work_request_id"]}; WorkPackage: #{payload["work_package_id"]}",
      "status" => "work_request_runtime_cleanup",
      "idempotency_key" => metadata_idempotency_key(payload),
      "payload" => payload
    })
  end

  defp runtime_cleanup_payload(context) do
    %WorkRequest{} = work_request = Map.fetch!(context, :work_request)
    %WorkPackage{} = work_package = Map.fetch!(context, :work_package)
    %DateTime{} = now = Map.fetch!(context, :cleaned_at)
    before_context = Map.fetch!(context, :before_context)
    cleared_session_bindings = Map.fetch!(context, :cleared_session_bindings)
    delivery_evidence = Map.fetch!(context, :delivery_evidence)
    reason = Map.fetch!(context, :reason)
    released_claim_leases = Map.fetch!(context, :released_claim_leases)
    revoked_worker_grants = Map.fetch!(context, :revoked_worker_grants)

    %{
      "type" => "work_request_work_package_runtime_cleanup",
      "source_tool" => @source_tool,
      "work_request_id" => work_request.id,
      "work_package_id" => work_package.id,
      "reason" => reason,
      "cleaned_at" => timestamp(now),
      "delivery_evidence" => delivery_evidence,
      "work_package_status" => work_package.status,
      "lifecycle_state" => "recycled",
      "runtime_reason_codes_before_cleanup" => List.wrap(get_in(before_context, [:runtime_state, :reason_codes])),
      "ignored_stale_agent_run_ids" => List.wrap(get_in(before_context, [:runtime_state, :stale_agent_run_ids])),
      "revoked_worker_grant_ids" => ids(revoked_worker_grants),
      "released_claim_lease_ids" => ids(released_claim_leases),
      "cleared_mcp_session_binding_ids" => ids(cleared_session_bindings),
      "reason_codes" => cleanup_reason_codes(revoked_worker_grants, released_claim_leases, cleared_session_bindings, before_context)
    }
  end

  defp runtime_cleanup_result(payload) do
    payload
    |> Map.take([
      "reason",
      "delivery_evidence",
      "lifecycle_state",
      "work_package_status",
      "runtime_reason_codes_before_cleanup",
      "ignored_stale_agent_run_ids",
      "revoked_worker_grant_ids",
      "released_claim_lease_ids",
      "cleared_mcp_session_binding_ids",
      "reason_codes"
    ])
    |> Map.put("status", "cleaned")
  end

  defp cleanup_reason_codes(revoked_worker_grants, released_claim_leases, cleared_session_bindings, before_context) do
    [
      "worker_recycled",
      if(revoked_worker_grants != [], do: "worker_grants_revoked"),
      if(released_claim_leases != [], do: "claim_leases_released"),
      if(cleared_session_bindings != [], do: "mcp_session_bindings_cleared"),
      if(List.wrap(get_in(before_context, [:runtime_state, :stale_agent_run_ids])) != [], do: "stale_agent_runs_preserved"),
      if(revoked_worker_grants == [] and released_claim_leases == [] and cleared_session_bindings == [], do: "runtime_cleanup_noop")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp ids(records), do: Enum.map(records, & &1.id)

  defp metadata_idempotency_key(payload) do
    idempotency_payload =
      Map.take(payload, [
        "type",
        "source_tool",
        "work_request_id",
        "work_package_id",
        "work_package_id",
        "reason",
        "revoked_worker_grant_ids",
        "released_claim_lease_ids",
        "cleared_mcp_session_binding_ids"
      ])

    "mcp:" <> Map.get(payload, "type", "metadata") <> ":" <> Base.url_encode64(:erlang.term_to_binary(idempotency_payload), padding: false)
  end

  defp redacted_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> Redactor.redact_text()
  end

  defp redacted_reason(_reason), do: ""

  defp normalize_delivery_evidence(delivery_evidence) when is_map(delivery_evidence) do
    delivery_evidence
    |> Map.take([
      "outcome",
      "successor_work_package_id",
      "successor_work_package_id",
      "superseded_reason",
      "abandoned_rationale"
    ])
    |> redact_delivery_evidence_text("superseded_reason")
    |> redact_delivery_evidence_text("abandoned_rationale")
  end

  defp normalize_delivery_evidence(_delivery_evidence), do: %{}

  defp redact_delivery_evidence_text(evidence, key) do
    Map.update(evidence, key, nil, fn
      value when is_binary(value) -> Redactor.redact_text(value)
      value -> value
    end)
    |> drop_nil_value(key)
  end

  defp drop_nil_value(evidence, key) do
    if is_nil(Map.get(evidence, key)), do: Map.delete(evidence, key), else: evidence
  end

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
end
