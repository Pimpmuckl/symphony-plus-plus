defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.BulkRepository do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @query_chunk_size 500

  @spec get_many(Repository.repo(), [String.t()]) ::
          {:ok, %{optional(String.t()) => WorkRequest.t()}} | {:error, Repository.error()}
  def get_many(repo, ids) when is_atom(repo) and is_list(ids) do
    ids = Enum.uniq(ids)

    work_requests =
      ids
      |> Enum.chunk_every(@query_chunk_size)
      |> Enum.flat_map(fn id_chunk ->
        repo.all(from(work_request in WorkRequest, where: work_request.id in ^id_chunk))
      end)

    {:ok, Map.new(work_requests, &{&1.id, &1})}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_questions_many(Repository.repo(), [String.t()]) ::
          {:ok, %{optional(String.t()) => [ClarificationQuestion.t()]}} | {:error, Repository.error()}
  def list_questions_many(repo, work_request_ids) when is_atom(repo) and is_list(work_request_ids) do
    {:ok, list_sequence_records_by_work_request_id(repo, ClarificationQuestion, work_request_ids)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_work_packages_many(Repository.repo(), [String.t()]) ::
          {:ok, %{optional(String.t()) => [WorkPackage.t()]}} | {:error, Repository.error()}
  def list_work_packages_many(repo, work_request_ids) when is_atom(repo) and is_list(work_request_ids) do
    {:ok, list_sequence_records_by_work_request_id(repo, WorkPackage, work_request_ids)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_decisions_many(Repository.repo(), [String.t()]) ::
          {:ok, %{optional(String.t()) => [DecisionLogEntry.t()]}} | {:error, Repository.error()}
  def list_decisions_many(repo, work_request_ids) when is_atom(repo) and is_list(work_request_ids) do
    {:ok, list_sequence_records_by_work_request_id(repo, DecisionLogEntry, work_request_ids)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp list_sequence_records_by_work_request_id(_repo, _schema, []), do: %{}

  defp list_sequence_records_by_work_request_id(repo, schema, work_request_ids) do
    work_request_ids
    |> Enum.uniq()
    |> Enum.chunk_every(@query_chunk_size)
    |> Enum.flat_map(fn id_chunk ->
      repo.all(
        from(record in schema,
          where: record.work_request_id in ^id_chunk,
          order_by: [asc: record.work_request_id, asc: record.sequence, asc: record.id]
        )
      )
    end)
    |> Enum.group_by(& &1.work_request_id)
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
