defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ReviewReadiness do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.OperationalProjection
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @type repo :: module()
  @type mcp_error :: {:error, integer(), String.t(), map()}

  @spec mark_ready(repo(), Session.t(), term(), function()) ::
          {:ok, {WorkPackage.t(), term()}}
          | {:tool_error, term()}
          | {:error, term()}
          | mcp_error()
  def mark_ready(repo, %Session{} = session, blocker_closeout_plan, apply_blocker_closeout) do
    repo
    |> run_worker_transaction(fn ->
      with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
           :ok <- lock_work_package(repo, Session.work_package_id(session)),
           {:ok, blocker_closeout} <- apply_blocker_closeout.(repo, session, blocker_closeout_plan),
           {:ok, state} <- PlanningRepository.get_state(repo, Session.work_package_id(session)),
           :ok <- readiness_gates(state),
           ready_status = StateMachine.terminal_readiness_status(state.work_package),
           :ok <- StateMachine.validate_ready_transition(state.work_package, ready_status, actor(session)),
           {:ok, work_package} <-
             WorkPackageRepository.update_status(repo, state.work_package.id, state.work_package.status, ready_status) do
        {:ok, {work_package, blocker_closeout}}
      end
    end)
  end

  defp readiness_gates(state) do
    reasons = OperationalProjection.readiness_failure_reasons(state)
    missing = reasons |> Enum.map(&Map.fetch!(&1, "gate")) |> Enum.uniq()

    if missing == [], do: :ok, else: {:error, {:readiness_failed, missing, reasons}}
  end

  defp run_worker_transaction(repo, fun) do
    case repo.transaction(fn -> rollback_worker_transaction_result(repo, fun.()) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:mcp_error, code, message, data}} -> {:error, code, message, data}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
    |> DashboardPubSub.broadcast_changed_on_success()
  end

  defp rollback_worker_transaction_result(_repo, {:ok, result}), do: result
  defp rollback_worker_transaction_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})

  defp rollback_worker_transaction_result(repo, {:error, code, message, data}),
    do: repo.rollback({:mcp_error, code, message, data})

  defp rollback_worker_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp lock_work_package(repo, work_package_id) do
    query = from(work_package in WorkPackage, where: work_package.id == ^work_package_id)

    case repo.update_all(query, set: [id: work_package_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
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
end
