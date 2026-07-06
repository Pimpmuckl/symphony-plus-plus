defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Completion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryCloseout
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type error :: Repository.error() | DeliveryCloseout.error()

  @spec create(Repository.repo(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def create(repo, attrs), do: notify_dashboard(Repository.create(repo, attrs))

  @spec get(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def get(repo, id), do: Repository.get(repo, id)

  @spec list(Repository.repo()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  @spec list(Repository.repo(), map()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  def list(repo, filters \\ %{}), do: Repository.list(repo, filters)

  @spec update(Repository.repo(), String.t(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def update(repo, id, attrs), do: notify_dashboard(Repository.update(repo, id, attrs))

  @spec update_status(Repository.repo(), String.t(), String.t(), String.t()) ::
          {:ok, WorkRequest.t()} | {:error, error()}
  def update_status(repo, id, current_status, next_status), do: notify_dashboard(Repository.update_status(repo, id, current_status, next_status))

  @spec prepare_for_planned_slices(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def prepare_for_planned_slices(repo, id), do: notify_dashboard(Repository.prepare_for_planned_slices(repo, id))

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

  @spec add_planned_slice(Repository.repo(), String.t(), map()) :: {:ok, PlannedSlice.t()} | {:error, error()}
  def add_planned_slice(repo, work_request_id, attrs), do: notify_dashboard(Repository.add_planned_slice(repo, work_request_id, attrs))

  @spec add_planned_slice_for_authoring(Repository.repo(), String.t(), map()) :: {:ok, PlannedSlice.t()} | {:error, error()}
  def add_planned_slice_for_authoring(repo, work_request_id, attrs),
    do: notify_dashboard(Repository.add_planned_slice_for_authoring(repo, work_request_id, attrs))

  @spec list_planned_slices(Repository.repo(), String.t()) :: {:ok, [PlannedSlice.t()]} | {:error, error()}
  def list_planned_slices(repo, work_request_id), do: Repository.list_planned_slices(repo, work_request_id)

  @spec get_planned_slice(Repository.repo(), String.t(), String.t()) :: {:ok, PlannedSlice.t()} | {:error, error()}
  def get_planned_slice(repo, work_request_id, id), do: Repository.get_planned_slice(repo, work_request_id, id)

  @spec record_planned_slice_delivery(Repository.repo(), String.t(), String.t(), map()) ::
          {:ok, PlannedSliceDelivery.t()} | {:error, error()}
  def record_planned_slice_delivery(repo, work_request_id, planned_slice_id, attrs),
    do: notify_dashboard(DeliveryCloseout.record(repo, work_request_id, planned_slice_id, attrs))

  @spec approve_planned_slice(Repository.repo(), String.t(), String.t(), String.t()) ::
          {:ok, PlannedSlice.t()} | {:error, error()}
  def approve_planned_slice(repo, work_request_id, id, current_status),
    do: notify_dashboard(Repository.approve_planned_slice(repo, work_request_id, id, current_status))

  @spec skip_planned_slice(Repository.repo(), String.t(), String.t(), String.t()) ::
          {:ok, PlannedSlice.t()} | {:error, error()}
  def skip_planned_slice(repo, work_request_id, id, current_status),
    do: notify_dashboard(Repository.skip_planned_slice(repo, work_request_id, id, current_status))

  @spec dispatch_planned_slice(Repository.repo(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, PlannedSlice.t()} | {:error, error()}
  def dispatch_planned_slice(repo, work_request_id, id, current_status, work_package_id),
    do: notify_dashboard(Repository.dispatch_planned_slice(repo, work_request_id, id, current_status, work_package_id))

  @spec mark_sliced(Repository.repo(), String.t(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def mark_sliced(repo, id, current_status), do: notify_dashboard(Repository.mark_sliced(repo, id, current_status))

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

  @spec retention_pass(Repository.repo()) ::
          {:ok, Completion.retention_summary()}
          | {:error, error() | :invalid_archive_after_days | :invalid_delete_after_days | :not_completed}
  @spec retention_pass(Repository.repo(), keyword()) ::
          {:ok, Completion.retention_summary()}
          | {:error, error() | :invalid_archive_after_days | :invalid_delete_after_days | :not_completed}
  def retention_pass(repo, opts \\ []), do: Completion.retention_pass(repo, opts)

  defp notify_dashboard({:ok, _value} = result) do
    :ok = DashboardPubSub.broadcast_changed()
    result
  end

  defp notify_dashboard(result), do: result
end
