defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.CompletionRecovery do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @operator_completion_source "operator"

  @spec clearable_query(String.t()) :: Ecto.Query.t()
  def clearable_query(work_package_id) when is_binary(work_package_id) do
    from(work_request in WorkRequest,
      join: work_package in WorkPackage,
      on: work_package.work_request_id == work_request.id,
      where: work_package.id == ^work_package_id,
      where:
        is_nil(work_request.completion_source) or
          work_request.completion_source != @operator_completion_source,
      where: not is_nil(work_request.completed_at) or not is_nil(work_request.archived_at)
    )
  end

  @spec snapshots_for_work_package(Repository.repo(), String.t()) :: {:ok, [map()]} | {:error, Repository.error()}
  def snapshots_for_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    snapshots =
      repo.all(
        from(work_request in clearable_query(work_package_id),
          select: %{
            id: work_request.id,
            completed_at: work_request.completed_at,
            completion_source: work_request.completion_source,
            archived_at: work_request.archived_at,
            archive_reason: work_request.archive_reason
          }
        )
      )

    {:ok, snapshots}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)

    if String.contains?(String.downcase(message), "busy") or String.contains?(String.downcase(message), "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end
end
