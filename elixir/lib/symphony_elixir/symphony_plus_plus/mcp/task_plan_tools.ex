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

  @plan_append_argument_keys ["body", "expected_version", "id", "status", "title", "work_package_id"]
  @plan_patch_argument_keys ["expected_version", "patch", "work_package_id"]
  @plan_node_patch_keys ["body", "id", "status", "title"]

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
         work_package_id = Session.work_package_id(session),
         {:ok, plan_nodes, version} <-
           apply_plan_update(repo, session.assignment, work_package_id, expected_version, arguments) do
      {:ok,
       ToolResult.agent_tool_result(%{
         "plan_nodes" => Enum.map(plan_nodes, &plan_node_payload/1),
         "version" => version
       })}
    end
  end

  defp require_worker_assignment(%{grant_role: "worker"}), do: :ok
  defp require_worker_assignment(_assignment), do: {:error, :worker_grant_required}

  defp apply_plan_update(repo, assignment, work_package_id, expected_version, %{"patch" => patch} = arguments) when is_map(patch) do
    with :ok <- require_update_task_plan_keys(arguments, @plan_patch_argument_keys) do
      transaction_plan_update(repo, assignment, work_package_id, expected_version, fn ->
        apply_plan_patch(repo, work_package_id, patch)
      end)
    end
  end

  defp apply_plan_update(_repo, _assignment, _work_package_id, _expected_version, %{"patch" => _patch}) do
    {:tool_error, "invalid_patch"}
  end

  defp apply_plan_update(repo, assignment, work_package_id, expected_version, arguments) do
    with :ok <- require_update_task_plan_keys(arguments, @plan_append_argument_keys) do
      transaction_plan_update(repo, assignment, work_package_id, expected_version, fn ->
        append_plan_node_from_arguments(repo, work_package_id, arguments)
      end)
    end
  end

  defp transaction_plan_update(repo, assignment, work_package_id, expected_version, update_fun) do
    transaction_fun = fn ->
      transaction_result(repo, assignment, work_package_id, expected_version, update_fun)
    end

    case repo.transaction(transaction_fun) do
      {:ok, {plan_nodes, version}} -> {:ok, plan_nodes, version}
      {:error, reason} -> reason
    end
  end

  defp transaction_result(repo, assignment, work_package_id, expected_version, update_fun) do
    with :ok <- PlanningService.require_valid_assignment(repo, assignment),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package_id),
         :ok <- reject_ready_work_package(state.work_package),
         plan_nodes = state.plan_nodes,
         :ok <- require_plan_version(plan_nodes, expected_version),
         {:ok, updated_plan_nodes} <- transaction_result(repo, update_fun.()),
         {:ok, refreshed_plan_nodes} <- PlanningRepository.list_plan_nodes(repo, work_package_id) do
      {updated_plan_nodes, plan_version(refreshed_plan_nodes)}
    else
      {:tool_error, reason} -> repo.rollback({:tool_error, reason})
      {:error, reason} -> repo.rollback({:error, reason})
    end
  end

  defp transaction_result(_repo, {:ok, result}), do: {:ok, result}
  defp transaction_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})
  defp transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp lock_work_package(repo, work_package_id) do
    query = from(work_package in WorkPackage, where: work_package.id == ^work_package_id)

    case repo.update_all(query, set: [id: work_package_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

  defp append_plan_node_from_arguments(repo, work_package_id, arguments) do
    with {:ok, title} <- required_argument(arguments, "title"),
         attrs = %{
           "work_package_id" => work_package_id,
           "title" => title,
           "body" => optional_argument(arguments, "body", nil),
           "status" => optional_argument(arguments, "status", "pending")
         },
         {:ok, plan_node} <- PlanningRepository.append_plan_node(repo, maybe_put_id(attrs, arguments)) do
      {:ok, [plan_node]}
    end
  end

  defp apply_plan_patch(repo, work_package_id, patch) do
    nodes = Map.get(patch, "nodes", [])

    cond do
      not is_list(nodes) -> {:tool_error, "missing_patch_nodes"}
      nodes == [] -> {:tool_error, "missing_patch_nodes"}
      true -> apply_plan_node_patches(repo, work_package_id, nodes)
    end
  end

  defp apply_plan_node_patches(repo, work_package_id, nodes) do
    nodes
    |> Enum.reduce_while({:ok, []}, &apply_plan_node_patch_step(repo, work_package_id, &1, &2))
    |> reverse_plan_patch_result()
  end

  defp apply_plan_node_patch_step(repo, work_package_id, node_attrs, {:ok, plan_nodes}) do
    case apply_plan_node_patch(repo, work_package_id, node_attrs) do
      {:ok, plan_node} -> {:cont, {:ok, [plan_node | plan_nodes]}}
      {:tool_error, reason} -> {:halt, {:tool_error, reason}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp reverse_plan_patch_result({:ok, plan_nodes}), do: {:ok, Enum.reverse(plan_nodes)}
  defp reverse_plan_patch_result({:tool_error, reason}), do: {:tool_error, reason}
  defp reverse_plan_patch_result({:error, reason}), do: {:error, reason}

  defp apply_plan_node_patch(repo, work_package_id, %{"id" => id} = attrs) when is_binary(id) do
    id = String.trim(id)
    updates = Map.take(attrs, ["title", "body", "status"])

    with :ok <- require_known_plan_node_patch_keys(attrs),
         true <- id != "" || {:tool_error, "invalid_patch_node"},
         {:ok, existing_nodes} <- PlanningRepository.list_plan_nodes(repo, work_package_id) do
      existing_node = Enum.find(existing_nodes, &(&1.id == id))
      patch_existing_or_append_plan_node(repo, work_package_id, existing_node, id, attrs, updates)
    else
      {:tool_error, reason} -> {:tool_error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_plan_node_patch(_repo, _work_package_id, %{"id" => _id}), do: {:tool_error, "invalid_patch_node"}

  defp apply_plan_node_patch(repo, work_package_id, attrs) when is_map(attrs) do
    with :ok <- require_known_plan_node_patch_keys(attrs),
         {:ok, title} <- required_argument(attrs, "title") do
      PlanningRepository.append_plan_node(repo, %{
        "work_package_id" => work_package_id,
        "title" => title,
        "body" => optional_argument(attrs, "body", nil),
        "status" => optional_argument(attrs, "status", "pending")
      })
    end
  end

  defp apply_plan_node_patch(_repo, _work_package_id, _attrs), do: {:tool_error, "invalid_patch_node"}

  defp patch_existing_or_append_plan_node(repo, _work_package_id, %PlanNode{}, id, _attrs, updates) do
    with :ok <- require_plan_node_updates(updates) do
      PlanningService.update_plan_node(repo, id, updates)
    end
  end

  defp patch_existing_or_append_plan_node(repo, work_package_id, nil, id, attrs, _updates) do
    with {:ok, title} <- required_argument(attrs, "title") do
      PlanningRepository.append_plan_node(repo, %{
        "id" => id,
        "work_package_id" => work_package_id,
        "title" => title,
        "body" => optional_argument(attrs, "body", nil),
        "status" => optional_argument(attrs, "status", "pending")
      })
    end
  end

  defp require_known_plan_node_patch_keys(attrs) do
    if Enum.all?(Map.keys(attrs), &(&1 in @plan_node_patch_keys)), do: :ok, else: {:tool_error, "invalid_patch_node"}
  end

  defp require_update_task_plan_keys(arguments, allowed_keys) do
    if Enum.all?(Map.keys(arguments), &(&1 in allowed_keys)), do: :ok, else: {:tool_error, "invalid_update_task_plan"}
  end

  defp require_plan_node_updates(updates) when map_size(updates) == 0, do: {:tool_error, "invalid_patch_node"}
  defp require_plan_node_updates(_updates), do: :ok

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

  defp optional_argument(arguments, key, default) do
    case Map.get(arguments, key, default) do
      value when is_binary(value) -> if String.trim(value) == "", do: default, else: value
      nil -> default
      value -> value
    end
  end

  defp maybe_put_id(attrs, arguments) do
    case Map.get(arguments, "id") do
      id when is_binary(id) ->
        case String.trim(id) do
          "" -> attrs
          trimmed -> Map.put(attrs, "id", trimmed)
        end

      _id ->
        attrs
    end
  end

  defp plan_node_payload(%PlanNode{} = plan_node) do
    %{"id" => plan_node.id, "title" => plan_node.title, "status" => plan_node.status}
  end
end
