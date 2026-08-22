defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDispatch do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.BranchPattern
  alias SymphonyElixir.SymphonyPlusPlus.CreateWork
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.ExecutionGraph
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDeliveryScope
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @mcp_worker_skill "symphony-plus-plus-mcp:symphony-worker"
  @mcp_work_package_skill "symphony-plus-plus-mcp:symphony-work-package"
  @preferred_worker_skill_set [@mcp_worker_skill, @mcp_work_package_skill]

  @type dispatch_result :: %{
          work_request: WorkRequest.t(),
          work_package: WorkPackage.t(),
          creation: CreateWork.creation(),
          worker_bootstrap: map()
        }

  @spec dispatch(module(), String.t(), String.t(), keyword()) ::
          {:ok, dispatch_result()} | {:error, term()}
  def dispatch(repo, work_request_id, work_package_id, handoff_opts)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(work_package_id) and is_list(handoff_opts) do
    repo.transaction(
      fn ->
        case dispatch_transaction(repo, work_request_id, work_package_id, handoff_opts) do
          {:ok, result} -> result
          {:error, reason} -> repo.rollback(reason)
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
    |> DashboardPubSub.broadcast_changed_on_success()
  end

  defp dispatch_transaction(repo, work_request_id, work_package_id, handoff_opts) do
    with {:ok, %WorkRequest{status: "sliced"} = work_request} <- Repository.get(repo, work_request_id),
         {:ok, %WorkPackage{status: "planned"} = work_package} <-
           Repository.get_work_package(repo, work_request_id, work_package_id),
         {:ok, execution_graph} <- ExecutionGraph.evaluate(repo, work_request_id),
         :ok <- ExecutionGraph.require_ready(execution_graph, work_package_id),
         :ok <- validate_contract(repo, work_request, work_package),
         {:ok, creation} <- CreateWork.activate(repo, work_package, broadcast?: false) do
      activated = creation.work_package
      bootstrap = worker_bootstrap(work_request, activated, handoff_opts)

      {:ok,
       %{
         work_request: work_request,
         work_package: activated,
         creation: creation,
         worker_bootstrap: bootstrap
       }}
    else
      {:ok, %WorkRequest{}} -> {:error, :invalid_work_request_status}
      {:ok, %WorkPackage{}} -> {:error, :invalid_work_package_status}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec response_payload(dispatch_result()) :: map()
  def response_payload(%{work_package: work_package, creation: creation, worker_bootstrap: bootstrap}) do
    %{
      work_package: work_package_payload(work_package),
      dispatch: CreateWork.response_payload(creation, worker_bootstrap: bootstrap)
    }
  end

  @spec error_message(term()) :: String.t()
  def error_message(:not_found), do: "WorkRequest or WorkPackage was not found"
  def error_message(:invalid_work_request_status), do: "Parent WorkRequest must be sliced before dispatch"
  def error_message(:invalid_work_package_status), do: "WorkPackage must be planned before dispatch"

  def error_message({:execution_graph_cycle, cycles}),
    do: "WorkRequest execution graph contains a cycle across WorkPackages: #{inspect(cycles)}"

  def error_message({:unmet_work_package_dependencies, work_package_id, prerequisite_ids}) do
    "WorkPackage #{work_package_id} has unmet dependencies: #{Enum.join(prerequisite_ids, ", ")}"
  end

  def error_message({:unsupported_branch_pattern, branch_pattern, reason}) do
    "WorkPackage branch_pattern #{inspect(branch_pattern)} is unsupported: #{BranchPattern.error_message(reason)}"
  end

  def error_message(reason), do: CreateWork.error_message(reason)

  defp validate_contract(repo, %WorkRequest{} = work_request, %WorkPackage{} = work_package) do
    with :ok <- require_supported_branch_pattern(work_package.branch_pattern),
         do: WorkPackageDeliveryScope.validate(repo, work_request, work_package)
  end

  defp require_supported_branch_pattern(branch_pattern) do
    case BranchPattern.validate(branch_pattern) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unsupported_branch_pattern, branch_pattern, reason}}
    end
  end

  defp worker_bootstrap(%WorkRequest{} = work_request, %WorkPackage{} = work_package, handoff_opts) do
    claimed_by = Keyword.get(handoff_opts, :claimed_by)

    claim_arguments =
      %{work_package_id: work_package.id, claimed_by: claimed_by}
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    %{
      type: "ledger_claim",
      mode: "local_assignment",
      ledger: ledger_bootstrap(Keyword.get(handoff_opts, :database)),
      claim: %{
        tool: "claim_local_assignment",
        arguments: claim_arguments,
        required_runtime_arguments: []
      },
      coordinates: %{
        primary_execution: %{kind: "work_package", work_package_id: work_package.id},
        product_parent: %{kind: "work_request", work_request_id: work_request.id}
      },
      required_skills: @preferred_worker_skill_set,
      preferred_skill_set: @preferred_worker_skill_set,
      supported_skill_sets: [@preferred_worker_skill_set],
      launch_prompt: worker_launch_prompt(work_request, work_package, claim_arguments)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp worker_launch_prompt(%WorkRequest{} = work_request, %WorkPackage{} = work_package, claim_arguments) do
    claim_arguments = claim_arguments |> Map.new(fn {key, value} -> {to_string(key), value} end) |> Jason.encode!()

    """
    WorkPackage #{prompt_data(work_package.id)}: #{prompt_data(work_package.title)}
    Parent WorkRequest: #{prompt_data(work_request.id)}.

    Skills: `#{@mcp_worker_skill}` + `#{@mcp_work_package_skill}`.
    Start: call `claim_local_assignment` with #{claim_arguments}; stop on paused, owned, or scope failure.
    Then call `get_current_assignment()`, read package resources, and update the task plan before coding.
    Track progress, findings, blockers, validation, and review evidence. Stay inside this WorkPackage and never request or expose raw secrets.
    """
    |> String.trim()
    |> Redactor.redact_text()
  end

  defp work_package_payload(%WorkPackage{} = work_package) do
    %{
      id: work_package.id,
      work_request_id: work_package.work_request_id,
      group_id: work_package.product_tree_node_id,
      sequence: work_package.sequence,
      kind: work_package.kind,
      title: work_package.title,
      status: work_package.status,
      contract_revision: work_package.contract_revision,
      dispatched_at: timestamp(work_package.dispatched_at)
    }
  end

  defp ledger_bootstrap(nil), do: nil
  defp ledger_bootstrap(database), do: %{database: database}
  defp prompt_data(value), do: value |> to_string() |> Jason.encode!()
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(nil), do: nil
end
