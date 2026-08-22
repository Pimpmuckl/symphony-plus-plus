defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree.Projection do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.Sanitizer
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.{DependencyEdge, ExecutionGraph, Node, Revision}

  @terminal_completion_keys ["merged", "delivered", "completed_no_pr", "closed", "completed"]
  @guidance_completion_keys ["human_info_needed", "ready_for_clarification", "clarifying"]
  @not_started_completion_keys ["approved", "planned", "ready_for_worker"]
  @partial_completion_keys [
    "active",
    "blocked",
    "ci_waiting",
    "claimed",
    "dispatched",
    "implementing",
    "in_progress",
    "merge_ready",
    "merging",
    "needs_attention",
    "needs_closeout",
    "planning",
    "ready_to_finish",
    "ready_for_merge",
    "reviewing",
    "started_paused"
  ]

  @spec project(module(), String.t(), [map()], keyword()) :: map()
  def project(repo, work_request_id, work_package_payloads, opts \\ [])
      when is_atom(repo) and is_binary(work_request_id) and is_list(work_package_payloads) and is_list(opts) do
    case ProductTree.tree_for_work_request(repo, work_request_id) do
      {:ok, tree} ->
        execution_graph = ExecutionGraph.evaluate(tree, work_package_payloads, [])
        project_tree(tree, execution_graph, work_package_payloads, opts)

      {:error, reason} ->
        unavailable_projection(reason, work_package_payloads)
    end
  end

  defp project_tree(
         %{
           nodes: nodes,
           dependency_edges: dependency_edges,
           latest_revision: latest_revision
         },
         execution_graph,
         work_package_payloads,
         opts
       ) do
    work_package_ids = Enum.map(work_package_payloads, &map_value(&1, "id"))
    visible_work_package_ids = work_package_ids |> Enum.reject(&is_nil/1) |> MapSet.new()

    {nodes, work_package_payloads, dependency_edges} =
      scope_tree_records(
        nodes,
        work_package_payloads,
        dependency_edges,
        visible_work_package_ids,
        opts
      )

    execution_graph = scope_execution_graph(execution_graph, visible_work_package_ids, opts)

    node_work_package_ids =
      work_package_payloads
      |> Enum.filter(&(group_id(&1) not in [nil, ""]))
      |> Enum.map(&map_value(&1, "id"))
      |> MapSet.new()

    projected_nodes =
      nodes
      |> Enum.map(&node_payload(&1, work_package_payloads))
      |> rollup_node_completion()
      |> Enum.map(&put_child_counts(&1, nodes))

    root_work_package_ids =
      Enum.reject(work_package_ids, &(is_nil(&1) or MapSet.member?(node_work_package_ids, &1)))

    %{
      available: true,
      schema_version: "product_tree.v4",
      mode: if(nodes == [], do: "direct_work_packages", else: "product_tree"),
      root_node_ids: root_node_ids(projected_nodes),
      root_work_package_ids: root_work_package_ids,
      nodes: projected_nodes,
      dependency_edges: Enum.map(dependency_edges, &dependency_edge_payload/1),
      execution_graph: execution_graph,
      summary: summary(projected_nodes, root_work_package_ids, work_package_payloads),
      latest_revision: revision_payload(latest_revision)
    }
  end

  defp scope_execution_graph(execution_graph, visible_work_package_ids, opts) do
    if Keyword.get(opts, :visible_only?, false) do
      ExecutionGraph.scope(execution_graph, visible_work_package_ids)
    else
      execution_graph
    end
  end

  defp scope_tree_records(nodes, work_packages, dependency_edges, visible_work_package_ids, opts) when is_list(opts) do
    if Keyword.get(opts, :visible_only?, false) do
      scope_visible_tree_records(nodes, work_packages, dependency_edges, visible_work_package_ids, opts)
    else
      {nodes, work_packages, dependency_edges}
    end
  end

  defp scope_visible_tree_records(nodes, work_packages, dependency_edges, visible_work_package_ids, opts) do
    visible_work_packages = Enum.filter(work_packages, &MapSet.member?(visible_work_package_ids, map_value(&1, "id")))
    node_ids_by_id = Map.new(nodes, &{&1.id, &1})

    visible_node_ids =
      visible_work_packages
      |> Enum.reduce(MapSet.new(), fn work_package, node_ids ->
        add_node_with_ancestors(node_ids, node_ids_by_id, group_id(work_package))
      end)
      |> maybe_add_unowned_node_ids(nodes, visible_work_packages, node_ids_by_id, opts)

    nodes = Enum.filter(nodes, &MapSet.member?(visible_node_ids, &1.id))

    dependency_edges =
      Enum.filter(dependency_edges, fn edge ->
        visible_dependency_endpoint?(edge.source_kind, edge.source_id, visible_node_ids, visible_work_package_ids) and
          visible_dependency_endpoint?(edge.target_kind, edge.target_id, visible_node_ids, visible_work_package_ids)
      end)

    {nodes, visible_work_packages, dependency_edges}
  end

  defp maybe_add_unowned_node_ids(node_ids, nodes, work_packages, nodes_by_id, opts) do
    if Keyword.get(opts, :include_unowned_nodes?, false) do
      owned_node_ids = work_packages |> Enum.map(&group_id/1) |> MapSet.new()

      nodes
      |> Enum.reject(&MapSet.member?(owned_node_ids, &1.id))
      |> Enum.reduce(node_ids, fn node, acc -> add_node_with_ancestors(acc, nodes_by_id, node.id) end)
    else
      node_ids
    end
  end

  defp add_node_with_ancestors(node_ids, _nodes_by_id, nil), do: node_ids
  defp add_node_with_ancestors(node_ids, _nodes_by_id, ""), do: node_ids

  defp add_node_with_ancestors(node_ids, nodes_by_id, node_id) when is_binary(node_id) do
    case Map.get(nodes_by_id, node_id) do
      nil ->
        node_ids

      %Node{} = node ->
        node_ids
        |> MapSet.put(node.id)
        |> add_node_with_ancestors(nodes_by_id, node.parent_id)
    end
  end

  defp visible_dependency_endpoint?("product_node", id, visible_node_ids, _visible_work_package_ids) do
    MapSet.member?(visible_node_ids, id)
  end

  defp visible_dependency_endpoint?("work_package", id, _visible_node_ids, visible_work_package_ids) do
    MapSet.member?(visible_work_package_ids, id)
  end

  defp visible_dependency_endpoint?(_kind, _id, _visible_node_ids, _visible_work_package_ids), do: false

  defp node_payload(%Node{} = node, work_packages) do
    node_work_packages =
      work_packages
      |> Enum.filter(&(group_id(&1) == node.id))
      |> Enum.sort_by(&{map_value(&1, "sequence") || 0, map_value(&1, "id") || ""})

    work_package_ids = Enum.map(node_work_packages, &map_value(&1, "id"))
    computed_mark = computed_completion_mark(node_work_packages)

    %{
      id: node.id,
      parent_id: node.parent_id,
      title: Sanitizer.redacted_text(node.title),
      description: Sanitizer.redacted_text(node.description),
      node_kind: Sanitizer.redacted_text(node.node_kind),
      completion_mark: node.completion_mark,
      computed_completion_mark: computed_mark,
      completion_label: completion_label(computed_mark),
      work_package_ids: work_package_ids,
      child_node_count: 0,
      work_package_count: length(work_package_ids),
      attention_count: attention_count(node_work_packages),
      guidance_count: guidance_count(node_work_packages),
      blocker_count: blocker_count(node_work_packages),
      position: node.position || 0,
      metadata: Sanitizer.redacted_json(node.metadata || %{}),
      created_by: Sanitizer.redacted_text(node.created_by),
      created_at: timestamp(node.created_at),
      updated_at: timestamp(node.updated_at)
    }
  end

  defp rollup_node_completion(nodes) do
    children_by_parent_id = Enum.group_by(nodes, & &1.parent_id)

    Enum.map(nodes, &rollup_node(&1, children_by_parent_id, []))
  end

  @spec rollup_node(map(), map(), [String.t()]) :: map()
  defp rollup_node(%{id: id} = node, children_by_parent_id, ancestors) when is_binary(id) do
    if id in ancestors do
      node
    else
      ancestors = [id | ancestors]
      children = children_by_parent_id |> Map.get(id, []) |> Enum.map(&rollup_node(&1, children_by_parent_id, ancestors))
      child_marks = Enum.map(children, & &1.computed_completion_mark)
      mark = rollup_completion_mark(node, child_marks)

      node
      |> Map.put(:computed_completion_mark, mark)
      |> Map.put(:completion_label, completion_label(mark))
      |> Map.put(:attention_count, (node.attention_count || 0) + Enum.sum(Enum.map(children, &(&1.attention_count || 0))))
      |> Map.put(:guidance_count, (node.guidance_count || 0) + Enum.sum(Enum.map(children, &(&1.guidance_count || 0))))
      |> Map.put(:blocker_count, (node.blocker_count || 0) + Enum.sum(Enum.map(children, &(&1.blocker_count || 0))))
    end
  end

  defp rollup_node(node, _children_by_parent_id, _ancestors), do: node

  defp rollup_completion_mark(node, child_marks) do
    self_marks = if (node.work_package_count || 0) > 0, do: [node.computed_completion_mark], else: []

    case self_marks ++ child_marks do
      [] -> node.computed_completion_mark
      marks -> aggregate_completion_marks(marks)
    end
  end

  defp aggregate_completion_marks(marks) do
    marks = Enum.reject(marks, &is_nil/1)

    terminal_completion_mark(marks) || mixed_completion_mark(marks)
  end

  defp terminal_completion_mark(marks) do
    cond do
      marks == [] -> "unknown"
      Enum.all?(marks, &(&1 == "done")) -> "done"
      Enum.all?(marks, &(&1 == "deferred")) -> "deferred"
      Enum.all?(marks, &(&1 == "not_done")) -> "not_done"
      Enum.all?(marks, &(&1 in ["done", "deferred"])) -> "done"
      true -> nil
    end
  end

  defp mixed_completion_mark(marks) do
    cond do
      Enum.any?(marks, &(&1 == "partial")) -> "partial"
      Enum.any?(marks, &(&1 == "done")) -> "partial"
      Enum.any?(marks, &(&1 == "not_done")) -> "not_done"
      Enum.any?(marks, &(&1 == "deferred")) -> "deferred"
      true -> "unknown"
    end
  end

  defp put_child_counts(node, nodes) do
    Map.put(node, :child_node_count, Enum.count(nodes, &(&1.parent_id == node.id)))
  end

  defp computed_completion_mark([]), do: "unknown"

  defp computed_completion_mark(work_packages) do
    states = Enum.map(work_packages, &work_package_state/1)

    cond do
      Enum.all?(states, &terminal_completion_state?/1) -> "done"
      Enum.any?(states, &partial_completion_state?/1) -> "partial"
      Enum.any?(states, &terminal_completion_state?/1) and Enum.any?(states, &not_started_completion_state?/1) -> "partial"
      Enum.any?(states, &not_started_completion_state?/1) -> "not_done"
      true -> "unknown"
    end
  end

  defp terminal_completion_state?(state), do: state in @terminal_completion_keys or state == "skipped"
  defp partial_completion_state?(state), do: state in @partial_completion_keys
  defp not_started_completion_state?(state), do: state in @not_started_completion_keys

  defp dependency_edge_payload(%DependencyEdge{} = edge) do
    %{
      id: edge.id,
      source: %{kind: edge.source_kind, id: edge.source_id},
      target: %{kind: edge.target_kind, id: edge.target_id},
      kind: edge.kind,
      reason: Sanitizer.redacted_text(edge.reason),
      decision_ref: Sanitizer.redacted_json(edge.decision_ref),
      created_by: Sanitizer.redacted_text(edge.created_by),
      created_at: timestamp(edge.created_at)
    }
  end

  defp revision_payload(nil), do: nil

  defp revision_payload(%Revision{} = revision) do
    %{
      id: revision.id,
      revision_number: revision.revision_number,
      reason: Sanitizer.redacted_text(revision.reason),
      decision_ref: Sanitizer.redacted_json(revision.decision_ref),
      created_by: Sanitizer.redacted_text(revision.created_by),
      created_at: timestamp(revision.created_at)
    }
  end

  defp summary(nodes, root_work_package_ids, work_package_payloads) do
    marks = Enum.map(nodes, & &1.computed_completion_mark)

    %{
      node_count: length(nodes),
      root_node_count: length(root_node_ids(nodes)),
      root_work_package_count: length(root_work_package_ids),
      work_package_count: length(work_package_payloads),
      node_work_package_count: Enum.sum(Enum.map(nodes, & &1.work_package_count)),
      done_count: Enum.count(marks, &(&1 == "done")),
      partial_count: Enum.count(marks, &(&1 == "partial")),
      not_done_count: Enum.count(marks, &(&1 == "not_done")),
      deferred_count: Enum.count(marks, &(&1 == "deferred")),
      unknown_count: Enum.count(marks, &(&1 == "unknown")),
      attention_count: Enum.count(work_package_payloads, &work_package_attention?/1),
      guidance_count: Enum.count(work_package_payloads, &work_package_guidance?/1),
      blocker_count: Enum.count(work_package_payloads, &work_package_blocker?/1)
    }
  end

  defp unavailable_projection(reason, work_package_payloads) do
    %{
      available: false,
      schema_version: "product_tree.v4",
      mode: "unavailable",
      root_node_ids: [],
      root_work_package_ids: work_package_payloads |> Enum.map(&map_value(&1, "id")) |> Enum.reject(&is_nil/1),
      nodes: [],
      dependency_edges: [],
      execution_graph: %{
        available: false,
        work_package_ids: work_package_payloads |> Enum.map(&map_value(&1, "id")) |> Enum.reject(&is_nil/1),
        effective_edges: [],
        topological_order: [],
        cycles: [],
        unmet_dependencies: [],
        dependency_ready_work_package_ids: [],
        resolutions: []
      },
      summary: %{
        node_count: 0,
        root_node_count: 0,
        root_work_package_count: length(work_package_payloads),
        work_package_count: length(work_package_payloads),
        node_work_package_count: 0,
        done_count: 0,
        partial_count: 0,
        not_done_count: 0,
        deferred_count: 0,
        unknown_count: 0,
        attention_count: 0,
        guidance_count: 0,
        blocker_count: 0
      },
      attention_items: [
        %{
          key: "product_tree_unavailable",
          label: "Product tree unavailable",
          tone: "warning",
          reason: inspect(reason)
        }
      ]
    }
  end

  defp root_node_ids(nodes) do
    nodes
    |> Enum.filter(&(Map.get(&1, :parent_id) in [nil, ""]))
    |> Enum.sort_by(&{Map.get(&1, :position) || 0, Map.get(&1, :title) || "", Map.get(&1, :id) || ""})
    |> Enum.map(& &1.id)
  end

  defp attention_count(work_packages), do: Enum.count(work_packages, &work_package_attention?/1)
  defp guidance_count(work_packages), do: Enum.count(work_packages, &work_package_guidance?/1)
  defp blocker_count(work_packages), do: Enum.count(work_packages, &work_package_blocker?/1)

  defp work_package_attention?(work_package) do
    state = map_value(work_package, "operational_state") || %{}

    map_value(state, "key") in ["blocked", "needs_attention"] or
      (map_value(state, "attention_items") || []) != [] or
      (map_value(work_package, "attention_reason_codes") || []) != []
  end

  defp work_package_blocker?(work_package) do
    state = map_value(work_package, "operational_state") || %{}
    reason_codes = map_value(work_package, "attention_reason_codes") || map_value(state, "attention_reason_codes") || []

    "active_blocker" in reason_codes or
      Enum.any?(map_value(state, "attention_items") || [], &(map_value(&1, "key") == "active_blocker"))
  end

  defp work_package_guidance?(work_package) do
    state = map_value(work_package, "operational_state") || %{}
    attention_items = map_value(state, "attention_items") || []

    [map_value(state, "key"), map_value(work_package, "status"), map_value(work_package, "work_package_status")]
    |> Enum.any?(&(&1 in @guidance_completion_keys)) or Enum.any?(attention_items, &attention_item_guidance?/1)
  end

  defp attention_item_guidance?(item) do
    key = item |> map_value("key") |> downcased()
    label = item |> map_value("label") |> downcased()

    key in @guidance_completion_keys or
      String.contains?(key, "guidance") or
      String.contains?(key, "question") or
      String.contains?(label, "guidance") or
      String.contains?(label, "question")
  end

  defp downcased(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp downcased(_value), do: ""

  defp work_package_state(work_package) do
    state = map_value(work_package, "operational_state") || %{}

    map_value(state, "key") ||
      map_value(work_package, "work_package_status") ||
      map_value(work_package, "status")
  end

  defp completion_label("done"), do: "Done"
  defp completion_label("partial"), do: "Partial"
  defp completion_label("not_done"), do: "Not done"
  defp completion_label("deferred"), do: "Deferred"
  defp completion_label(_mark), do: "Unknown"

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, maybe_atom(key))
  defp map_value(_map, _key), do: nil

  defp group_id(work_package), do: map_value(work_package, "group_id") || map_value(work_package, "product_tree_node_id")

  defp maybe_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp(_datetime), do: nil
end
