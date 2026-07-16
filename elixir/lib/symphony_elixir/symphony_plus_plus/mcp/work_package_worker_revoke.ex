defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkPackageWorkerRevoke do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @block_on_revoke_statuses ["claimed", "implementing", "reviewing", "ci_waiting"]
  @recycle_statuses @block_on_revoke_statuses ++ ["blocked"]
  @closeout_statuses ["ready_for_merge", "ready_for_human_merge", "ready_for_architect_merge", "merged", "merged_into_phase", "closed", "abandoned"]
  @revoke_statuses @recycle_statuses ++ @closeout_statuses

  @spec require_revoke_status(WorkPackage.t()) :: :ok | {:tool_error, String.t()}
  def require_revoke_status(%WorkPackage{status: status}) when status in @revoke_statuses, do: :ok
  def require_revoke_status(%WorkPackage{}), do: {:tool_error, "work_package_not_closeout_ready"}

  @spec update_status(module(), WorkPackage.t(), DateTime.t()) ::
          {:ok, WorkPackage.t()} | {:tool_error, String.t()} | {:error, term()}
  def update_status(repo, %WorkPackage{status: status} = work_package, %DateTime{})
      when status in @block_on_revoke_statuses do
    case WorkPackageRepository.update_status(repo, work_package.id, status, "blocked") do
      {:ok, %WorkPackage{} = blocked} -> {:ok, blocked}
      {:error, :stale_status} -> {:tool_error, "work_package_worker_revoke_conflict"}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_status(_repo, %WorkPackage{} = work_package, %DateTime{}), do: {:ok, work_package}

  @spec payload(WorkRequest.t(), WorkPackage.t(), String.t() | nil, AccessGrant.t(), term()) :: map()
  def payload(%WorkRequest{} = work_request, %WorkPackage{} = work_package, previous_status, %AccessGrant{} = grant, reason) do
    %{
      "type" => "work_package_worker_key_revoke",
      "source_tool" => "revoke_work_package_worker_key",
      "work_request_id" => work_request.id,
      "work_package_id" => work_package.id,
      "grant_id" => grant.id,
      "reason" => redacted_reason(reason),
      "revoked_at" => timestamp(grant.revoked_at),
      "previous_work_package_status" => previous_status,
      "work_package_status" => work_package.status,
      "lifecycle_state" => "recycled",
      "reason_codes" => reason_codes(previous_status, work_package.status)
    }
  end

  @spec reason_codes(String.t() | nil, String.t() | nil) :: [String.t()]
  def reason_codes(previous_status, new_status) when previous_status == new_status, do: ["worker_recycled", "work_package_worker_key_revoked"]

  def reason_codes(_previous_status, _new_status), do: ["worker_recycled", "work_package_worker_key_revoked", "work_package_blocked_for_recycle"]

  @spec redacted_reason(term()) :: String.t()
  def redacted_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> Redactor.redact_text()
  end

  def redacted_reason(_reason), do: ""

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  defp timestamp(%NaiveDateTime{} = timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp timestamp(nil), do: nil
end
