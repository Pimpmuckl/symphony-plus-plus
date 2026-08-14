defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Service, as: WorkPackageService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Completion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryCloseout
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type error ::
          Repository.error()
          | DeliveryCloseout.error()
          | WorkPackageService.error()
          | {:worktree_cleanup_failed, WorkPackageService.error()}

  @spec create(Repository.repo(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def create(repo, attrs), do: notify_dashboard(Repository.create(repo, attrs))

  @spec get(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def get(repo, id), do: Repository.get(repo, id)

  @spec list(Repository.repo()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  @spec list(Repository.repo(), map()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  def list(repo, filters \\ %{}), do: Repository.list(repo, filters)

  @spec list_page(Repository.repo(), map() | keyword(), pos_integer(), nil | {DateTime.t(), String.t()}) ::
          {:ok, [WorkRequest.t()]} | {:error, error()}
  def list_page(repo, filters, limit, cursor), do: Repository.list_page(repo, filters, limit, cursor)

  @spec update(Repository.repo(), String.t(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def update(repo, id, attrs), do: notify_dashboard(Repository.update(repo, id, attrs))

  @spec update_status(Repository.repo(), String.t(), String.t(), String.t()) ::
          {:ok, WorkRequest.t()} | {:error, error()}
  def update_status(repo, id, current_status, next_status), do: notify_dashboard(Repository.update_status(repo, id, current_status, next_status))

  @spec prepare_for_work_packages(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def prepare_for_work_packages(repo, id), do: notify_dashboard(Repository.prepare_for_work_packages(repo, id))

  @spec ask_question(Repository.repo(), String.t(), map()) :: {:ok, ClarificationQuestion.t()} | {:error, error()}
  def ask_question(repo, work_request_id, attrs), do: notify_dashboard(Repository.ask_question(repo, work_request_id, attrs))

  @spec list_questions(Repository.repo(), String.t()) :: {:ok, [ClarificationQuestion.t()]} | {:error, error()}
  def list_questions(repo, work_request_id), do: Repository.list_questions(repo, work_request_id)

  @spec answer_question(Repository.repo(), String.t(), String.t(), map()) ::
          {:ok, ClarificationQuestion.t()} | {:error, error()}
  def answer_question(repo, id, current_status, attrs), do: notify_dashboard(Repository.answer_question(repo, id, current_status, attrs))

  @spec close_question(Repository.repo(), String.t(), String.t()) :: {:ok, ClarificationQuestion.t()} | {:error, error()}
  def close_question(repo, id, current_status), do: notify_dashboard(Repository.close_question(repo, id, current_status))

  @spec record_decision(Repository.repo(), String.t(), map()) :: {:ok, DecisionLogEntry.t()} | {:error, error()}
  def record_decision(repo, work_request_id, attrs), do: notify_dashboard(Repository.record_decision(repo, work_request_id, attrs))

  @spec slice_work_request(Repository.repo(), String.t(), [map()]) ::
          {:ok, %{work_request: WorkRequest.t(), work_packages: [WorkPackage.t()]}} | {:error, error()}
  def slice_work_request(repo, work_request_id, work_packages),
    do: notify_dashboard(Repository.slice_work_request(repo, work_request_id, work_packages))

  @spec list_work_packages(Repository.repo(), String.t()) :: {:ok, [WorkPackage.t()]} | {:error, error()}
  def list_work_packages(repo, work_request_id), do: Repository.list_work_packages(repo, work_request_id)

  @spec get_work_package(Repository.repo(), String.t(), String.t()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def get_work_package(repo, work_request_id, id), do: Repository.get_work_package(repo, work_request_id, id)

  @spec update_work_package(Repository.repo(), String.t(), String.t(), pos_integer(), map()) ::
          {:ok, WorkPackage.t()} | {:error, error()}
  def update_work_package(repo, work_request_id, id, expected_revision, attrs),
    do: notify_dashboard(Repository.update_work_package(repo, work_request_id, id, expected_revision, attrs))

  @spec record_work_package_delivery(Repository.repo(), String.t(), String.t(), map()) ::
          {:ok, WorkPackageDelivery.t()} | {:error, error()}
  def record_work_package_delivery(repo, work_request_id, work_package_id, attrs),
    do: notify_dashboard(DeliveryCloseout.record(repo, work_request_id, work_package_id, attrs))

  @spec skip_work_package(Repository.repo(), String.t(), String.t(), String.t()) ::
          {:ok, WorkPackage.t()} | {:error, error()}
  def skip_work_package(repo, work_request_id, id, current_status) do
    repo.transaction(fn ->
      with {:ok, work_package} <- Repository.skip_work_package(repo, work_request_id, id, current_status),
           {:ok, _work_request} <- Completion.refresh_in_transaction(repo, work_request_id) do
        work_package
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
    |> notify_dashboard()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_decisions(Repository.repo(), String.t()) :: {:ok, [DecisionLogEntry.t()]} | {:error, error()}
  def list_decisions(repo, work_request_id), do: Repository.list_decisions(repo, work_request_id)

  @spec refresh_completion(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def refresh_completion(repo, work_request_id), do: notify_dashboard(Completion.refresh(repo, work_request_id))

  @spec force_complete(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def force_complete(repo, work_request_id), do: notify_dashboard(Completion.force_complete(repo, work_request_id))

  @spec archive(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error() | :not_completed}
  def archive(repo, work_request_id), do: notify_dashboard(Completion.archive(repo, work_request_id))

  @spec restore(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def restore(repo, work_request_id), do: notify_dashboard(Completion.restore(repo, work_request_id))

  @spec delete(Repository.repo(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def delete(repo, work_request_id), do: notify_dashboard(Completion.delete(repo, work_request_id))

  @spec retention_pass(Repository.repo()) ::
          {:ok, Completion.retention_summary()}
          | {:error, error() | :invalid_archive_after_days | :invalid_delete_after_days | :not_completed}
  @spec retention_pass(Repository.repo(), keyword()) ::
          {:ok, Completion.retention_summary()}
          | {:error, error() | :invalid_archive_after_days | :invalid_delete_after_days | :not_completed}
  def retention_pass(repo, opts \\ []), do: Completion.retention_pass(repo, opts)

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    if String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end

  defp notify_dashboard({:ok, _value} = result) do
    :ok = DashboardPubSub.broadcast_changed()
    result
  end

  defp notify_dashboard(result), do: result
end
