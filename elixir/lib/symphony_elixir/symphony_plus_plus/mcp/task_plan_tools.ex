defmodule SymphonyElixir.SymphonyPlusPlus.MCP.TaskPlanTools do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Auth
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolResult
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer, as: PlanningRenderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @plan_argument_keys ["expected_version", "nodes"]
  @plan_node_keys ["body", "id", "status", "title"]

  @type repo :: module()
  @type result :: {:ok, map()} | {:tool_error, term()} | {:error, term()}

  @spec read_task_plan(repo(), Session.t() | nil) :: result()
  def read_task_plan(repo, session) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_worker_assignment(session.assignment),
         work_package_id = Session.work_package_id(session),
         {:ok, state} <- PlanningRepository.get_task_plan_render_state(repo, work_package_id),
         {:ok, markdown} <- PlanningRenderer.render_state(state, "task_plan.md"),
         uri = "sympp://work-packages/#{work_package_id}/task_plan.md",
         version = plan_version(state.plan_version_material),
         {:ok, virtual_payload} <- WorkerContext.virtual_file_payload(state, "task_plan.md", uri: uri, version: version) do
      {:ok,
       ToolResult.agent_tool_result(
         Map.put(virtual_payload, "text", markdown),
         fn -> WorkerContext.encode_tool_payload(virtual_payload) end
       )}
    end
  end

  @spec update_task_plan(repo(), Session.t(), map()) :: result()
  def update_task_plan(repo, %Session{} = session, arguments) do
    with {:ok, expected_version} <- required_integer(arguments, "expected_version"),
         {:ok, nodes} <- required_nodes(arguments),
         :ok <- require_update_task_plan_keys(arguments),
         work_package_id = Session.work_package_id(session),
         {:ok, plan_nodes, version} <-
           transaction_plan_update(repo, session.assignment, work_package_id, expected_version, nodes) do
      {:ok,
       ToolResult.agent_tool_result(%{
         "plan_nodes" => Enum.map(plan_nodes, &plan_node_payload/1),
         "version" => version
       })}
    end
  end

  defp require_worker_assignment(%{grant_role: "worker"}), do: :ok
  defp require_worker_assignment(_assignment), do: {:error, :worker_grant_required}

  defp transaction_plan_update(repo, assignment, work_package_id, expected_version, nodes) do
    transaction_fun = fn ->
      transaction_result(repo, assignment, work_package_id, expected_version, nodes)
    end

    case repo.transaction(transaction_fun) do
      {:ok, {plan_nodes, version}} -> {:ok, plan_nodes, version}
      {:error, reason} -> reason
    end
  end

  defp transaction_result(repo, assignment, work_package_id, expected_version, nodes) do
    with :ok <- PlanningService.require_valid_assignment(repo, assignment),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package_id),
         :ok <- reject_ready_work_package(state.work_package),
         plan_nodes = state.plan_nodes,
         :ok <- require_plan_version(plan_nodes, expected_version),
         {:ok, updates} <- prepare_plan_updates(nodes, plan_nodes),
         {:ok, updated_plan_nodes} <- apply_plan_updates(repo, work_package_id, updates),
         {:ok, refreshed_plan_nodes} <- PlanningRepository.list_plan_nodes(repo, work_package_id) do
      {updated_plan_nodes, plan_version(refreshed_plan_nodes)}
    else
      {:tool_error, reason} -> repo.rollback({:tool_error, reason})
      {:error, reason} -> repo.rollback({:error, reason})
    end
  end

  defp lock_work_package(repo, work_package_id) do
    query = from(work_package in WorkPackage, where: work_package.id == ^work_package_id)

    case repo.update_all(query, set: [id: work_package_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

  defp prepare_plan_updates(nodes, plan_nodes) do
    nodes
    |> Enum.reduce_while({:ok, []}, &prepare_plan_update(&1, plan_nodes, &2))
    |> reverse_plan_updates()
  end

  defp prepare_plan_update(node_attrs, plan_nodes, {:ok, updates}) do
    case prepare_plan_update(node_attrs, plan_nodes) do
      {:ok, update} -> {:cont, {:ok, [update | updates]}}
      {:tool_error, reason} -> {:halt, {:tool_error, reason}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp reverse_plan_updates({:ok, updates}), do: {:ok, Enum.reverse(updates)}
  defp reverse_plan_updates({:tool_error, reason}), do: {:tool_error, reason}
  defp reverse_plan_updates({:error, reason}), do: {:error, reason}

  defp prepare_plan_update(%{"id" => id} = attrs, plan_nodes) when is_binary(id) do
    id = String.trim(id)
    updates = Map.take(attrs, ["title", "body", "status"])

    with :ok <- require_known_plan_node_keys(attrs),
         :ok <- require_plan_node_status(attrs),
         true <- id != "" || {:tool_error, "invalid_plan_node"},
         :ok <- require_plan_node_updates(updates),
         %PlanNode{} = plan_node <- Enum.find(plan_nodes, &(&1.id == id)) || {:tool_error, "unknown_plan_node"} do
      {:ok, {:update, plan_node, updates}}
    else
      {:tool_error, reason} -> {:tool_error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_plan_update(%{"id" => _id}, _plan_nodes), do: {:tool_error, "invalid_plan_node"}

  defp prepare_plan_update(attrs, _plan_nodes) when is_map(attrs) do
    with :ok <- require_known_plan_node_keys(attrs),
         :ok <- require_plan_node_status(attrs),
         {:ok, title} <- required_argument(attrs, "title") do
      {:ok,
       {:create,
        %{
          "title" => title,
          "body" => optional_argument(attrs, "body", nil),
          "status" => optional_argument(attrs, "status", "pending")
        }}}
    end
  end

  defp prepare_plan_update(_attrs, _plan_nodes), do: {:tool_error, "invalid_plan_node"}

  defp apply_plan_updates(repo, work_package_id, updates) do
    updates
    |> Enum.reduce_while({:ok, []}, &apply_plan_update(repo, work_package_id, &1, &2))
    |> reverse_plan_updates()
  end

  defp apply_plan_update(repo, work_package_id, update, {:ok, plan_nodes}) do
    result =
      case update do
        {:create, attrs} -> PlanningRepository.append_plan_node(repo, Map.put(attrs, "work_package_id", work_package_id))
        {:update, %PlanNode{id: id}, attrs} -> PlanningService.update_plan_node(repo, id, attrs)
      end

    case result do
      {:ok, plan_node} -> {:cont, {:ok, [plan_node | plan_nodes]}}
      {:tool_error, reason} -> {:halt, {:tool_error, reason}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp require_known_plan_node_keys(attrs) do
    if Enum.all?(Map.keys(attrs), &(&1 in @plan_node_keys)), do: :ok, else: {:tool_error, "invalid_plan_node"}
  end

  defp require_update_task_plan_keys(arguments) do
    if Map.keys(arguments) |> Enum.sort() == @plan_argument_keys,
      do: :ok,
      else: {:tool_error, "invalid_update_task_plan"}
  end

  defp require_plan_node_updates(updates) when map_size(updates) == 0, do: {:tool_error, "invalid_plan_node"}
  defp require_plan_node_updates(_updates), do: :ok

  defp require_plan_node_status(arguments) do
    case Map.fetch(arguments, "status") do
      :error ->
        :ok

      {:ok, status} ->
        if status in PlanNode.statuses(),
          do: :ok,
          else: {:tool_error, {:invalid_enum, "status", PlanNode.statuses()}}
    end
  end

  defp require_plan_version(plan_nodes, expected_version) do
    if plan_version(plan_nodes) == expected_version, do: :ok, else: {:tool_error, "stale_plan_version"}
  end

  defp plan_version(plan_nodes) do
    material =
      Enum.map(plan_nodes, fn node ->
        %{
          id: node.id,
          title: node.title,
          body: node.body,
          status: node.status,
          position: node.position,
          updated_at: timestamp_version_part(node.updated_at)
        }
      end)

    :crypto.hash(:sha256, :erlang.term_to_binary(material))
    |> binary_part(0, 8)
    |> :binary.decode_unsigned()
    |> rem(9_007_199_254_740_991)
  end

  defp timestamp_version_part(nil), do: nil
  defp timestamp_version_part(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)

  defp reject_ready_work_package(%WorkPackage{kind: "phase_child", status: status}) when status in ["merging_into_phase", "merged_into_phase"] do
    {:tool_error, "child_under_architect_control"}
  end

  defp reject_ready_work_package(%WorkPackage{status: status}) when status in ["ready_for_merge", "ready_for_human_merge", "ready_for_architect_merge"],
    do: {:tool_error, "already_ready"}

  defp reject_ready_work_package(%WorkPackage{}), do: :ok

  defp required_argument(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "missing_#{key}"}
    end
  end

  defp required_integer(arguments, key) do
    case Map.get(arguments, key) do
      value when is_integer(value) -> {:ok, value}
      _value -> {:tool_error, "missing_#{key}"}
    end
  end

  defp required_nodes(arguments) do
    case Map.get(arguments, "nodes") do
      nodes when is_list(nodes) and nodes != [] -> {:ok, nodes}
      _nodes -> {:tool_error, "missing_nodes"}
    end
  end

  defp optional_argument(arguments, key, default) do
    case Map.get(arguments, key, default) do
      value when is_binary(value) -> if String.trim(value) == "", do: default, else: value
      nil -> default
      value -> value
    end
  end

  defp plan_node_payload(%PlanNode{} = plan_node) do
    %{"id" => plan_node.id, "title" => plan_node.title, "status" => plan_node.status}
  end
end
