defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkPackageClaimRelease do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.{AccessGrant, Assignment, WorkKey}
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.MCP.SessionBinding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @spec release(module(), WorkPackage.t(), Assignment.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def release(repo, %WorkPackage{} = work_package, %Assignment{} = assignment, reason) do
    now = DateTime.utc_now(:microsecond)
    reason = Redactor.redact_text(reason)
    grants = repo.all(from(grant in AccessGrant, where: grant.work_package_id == ^work_package.id and grant.grant_role == "worker"))
    worker_grant_ids = Enum.map(grants, & &1.id)

    leases =
      repo.all(
        from(lease in ClaimLease,
          where: lease.work_package_id == ^work_package.id and lease.status in ^ClaimLease.active_statuses(),
          where: is_nil(lease.access_grant_id) or lease.access_grant_id in ^worker_grant_ids
        )
      )

    with {:ok, reset_grant_ids} <- reset_worker_grants(repo, grants, now),
         released_lease_ids <- release_leases(repo, leases, now, reason),
         {cleared_bindings, _} <-
           repo.delete_all(from(binding in SessionBinding, where: binding.work_package_id == ^work_package.id and binding.grant_role == "worker")),
         payload = %{
           "source_tool" => "force_release_work_package_claim",
           "work_package_id" => work_package.id,
           "reason" => reason,
           "reset_worker_grant_ids" => reset_grant_ids,
           "released_claim_lease_ids" => released_lease_ids,
           "cleared_session_bindings" => cleared_bindings
         },
         {:ok, event} <-
           PlanningRepository.append_audit_progress_event_for_work_package(repo, assignment, work_package.id, %{
             "summary" => "Architect force-released worker claim",
             "body" => reason,
             "status" => "worker_claim_released",
             "payload" => payload
           }) do
      {:ok, Map.merge(payload, %{"audit_event" => %{"id" => event.id}, "next_action" => "claim_local_assignment"})}
    end
  end

  defp reset_worker_grants(repo, grants, now) do
    grants
    |> Enum.filter(&(is_nil(&1.revoked_at) and not is_nil(&1.claimed_at) and (is_nil(&1.expires_at) or DateTime.compare(&1.expires_at, now) == :gt)))
    |> Enum.reduce_while({:ok, []}, fn grant, {:ok, ids} ->
      # Rotate the proof as well as the owner: old sessions must not inherit the replacement's authority.
      secret_hash = WorkKey.secret_hash(WorkKey.generate().secret)

      case grant |> Ecto.Changeset.change(claimed_at: nil, claimed_by: nil, secret_hash: secret_hash, updated_at: now) |> repo.update() do
        {:ok, _grant} -> {:cont, {:ok, [grant.id | ids]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp release_leases(repo, leases, now, reason) do
    ids = Enum.map(leases, & &1.id)

    repo.update_all(from(lease in ClaimLease, where: lease.id in ^ids),
      set: [status: "released", released_at: now, release_reason: reason, last_seen_at: now, updated_at: now]
    )

    ids
  end
end
