defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree.ExecutionGraph do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Repository, as: ProductTreeRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository

  @resolved_statuses ["skipped", "merged", "merged_into_phase", "closed", "abandoned"]
  @hard_edge_kinds ["depends_on", "blocks"]

  @type graph :: %{
          available: boolean(),
          work_package_ids: [String.t()],
          effective_edges: [map()],
          topological_order: [String.t()],
          cycles: [[String.t()]],
          unmet_dependencies: [map()],
          dependency_ready_work_package_ids: [String.t()],
          resolutions: [map()]
        }

  @spec evaluate(module(), String.t()) :: {:ok, graph()} | {:error, term()}
  def evaluate(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    with {:ok, tree} <- ProductTreeRepository.tree_for_work_request(repo, work_request_id),
         {:ok, work_packages} <- WorkRequestRepository.list_work_packages(repo, work_request_id) do
      deliveries =
        repo.all(
          from(delivery in WorkPackageDelivery,
            where: delivery.work_request_id == ^work_request_id
          )
        )

      {:ok, evaluate(tree, work_packages, deliveries)}
    end
  rescue
    error in Exqlite.Error -> {:error, {:storage_failed, Exception.message(error)}}
  end

  @spec evaluate(map(), [map() | struct()], [map() | struct()]) :: graph()
  def evaluate(%{nodes: nodes, dependency_edges: dependency_edges}, work_packages, deliveries)
      when is_list(nodes) and is_list(dependency_edges) and is_list(work_packages) and is_list(deliveries) do
    work_packages = Enum.sort_by(work_packages, &value(&1, :id))
    work_package_ids = Enum.map(work_packages, &value(&1, :id))
    work_package_id_set = MapSet.new(work_package_ids)
    group_members = group_members(nodes, work_packages)

    effective_edges =
      dependency_edges
      |> effective_edges(group_members)
      |> Enum.filter(
        &(MapSet.member?(work_package_id_set, &1.prerequisite_work_package_id) and
            MapSet.member?(work_package_id_set, &1.dependent_work_package_id))
      )

    deliveries_by_work_package_id = Map.new(deliveries, &{value(&1, :work_package_id), &1})
    resolutions = Enum.map(work_packages, &resolution(&1, deliveries_by_work_package_id))

    build_graph(work_package_ids, effective_edges, resolutions)
  end

  @spec scope(graph(), Enumerable.t()) :: graph()
  def scope(%{available: true} = graph, visible_work_package_ids) do
    visible_ids = MapSet.new(visible_work_package_ids)
    visible? = &MapSet.member?(visible_ids, &1)
    work_package_ids = Enum.filter(graph.work_package_ids, visible?)

    effective_edges =
      Enum.filter(graph.effective_edges, fn edge ->
        visible?.(edge.prerequisite_work_package_id) and visible?.(edge.dependent_work_package_id)
      end)

    resolutions = Enum.filter(graph.resolutions, &visible?.(&1.work_package_id))

    build_graph(work_package_ids, effective_edges, resolutions)
  end

  def scope(graph, _visible_work_package_ids), do: graph

  defp build_graph(work_package_ids, effective_edges, resolutions) do
    pairs = Enum.map(effective_edges, &{&1.prerequisite_work_package_id, &1.dependent_work_package_id})
    {topological_order, cycles} = topology(work_package_ids, pairs)
    resolved_ids = resolutions |> Enum.filter(& &1.resolved) |> Enum.map(& &1.work_package_id) |> MapSet.new()
    unmet_dependencies = unmet_dependencies(work_package_ids, effective_edges, resolved_ids)
    unmet_ids = unmet_dependencies |> Enum.map(& &1.work_package_id) |> MapSet.new()

    %{
      available: true,
      work_package_ids: work_package_ids,
      effective_edges: effective_edges,
      topological_order: topological_order,
      cycles: cycles,
      unmet_dependencies: unmet_dependencies,
      dependency_ready_work_package_ids: if(cycles == [], do: Enum.reject(work_package_ids, &MapSet.member?(unmet_ids, &1)), else: []),
      resolutions: resolutions
    }
  end

  @spec require_ready(graph(), String.t()) :: :ok | {:error, term()}
  def require_ready(%{cycles: [_ | _] = cycles}, _work_package_id),
    do: {:error, {:execution_graph_cycle, cycles}}

  def require_ready(%{unmet_dependencies: unmet_dependencies}, work_package_id) do
    case Enum.find(unmet_dependencies, &(&1.work_package_id == work_package_id)) do
      nil -> :ok
      evidence -> {:error, {:unmet_work_package_dependencies, work_package_id, evidence.prerequisite_work_package_ids}}
    end
  end

  defp group_members(nodes, work_packages) do
    direct_members = Enum.group_by(work_packages, &package_group_id/1, &value(&1, :id))
    children = Enum.group_by(nodes, &value(&1, :parent_id), &value(&1, :id))

    Map.new(nodes, fn node ->
      id = value(node, :id)
      {id, descendant_members(id, children, direct_members, [])}
    end)
  end

  defp package_group_id(work_package), do: value(work_package, :group_id) || value(work_package, :product_tree_node_id)

  defp descendant_members(group_id, children, direct_members, visited) do
    if group_id in visited do
      []
    else
      visited = [group_id | visited]

      (Map.get(direct_members, group_id, []) ++
         Enum.flat_map(Map.get(children, group_id, []), &descendant_members(&1, children, direct_members, visited)))
      |> Enum.uniq()
      |> Enum.sort()
    end
  end

  defp effective_edges(dependency_edges, group_members) do
    dependency_edges
    |> Enum.filter(&(value(&1, :kind) in @hard_edge_kinds))
    |> Enum.sort_by(&{value(&1, :created_at), value(&1, :id)})
    |> Enum.reduce(%{}, fn edge, acc ->
      {prerequisite_endpoint, dependent_endpoint} =
        case value(edge, :kind) do
          "depends_on" -> {endpoint(edge, :target), endpoint(edge, :source)}
          "blocks" -> {endpoint(edge, :source), endpoint(edge, :target)}
        end

      prerequisite_ids = expand_endpoint(prerequisite_endpoint, group_members)
      dependent_ids = expand_endpoint(dependent_endpoint, group_members)
      shared_ids = Enum.filter(prerequisite_ids, &(&1 in dependent_ids))

      for prerequisite_id <- prerequisite_ids,
          dependent_id <- dependent_ids,
          not (prerequisite_id in shared_ids and dependent_id in shared_ids),
          reduce: acc do
        edges ->
          Map.update(edges, {prerequisite_id, dependent_id}, [value(edge, :id)], fn ids ->
            [value(edge, :id) | ids]
          end)
      end
    end)
    |> Enum.map(fn {{prerequisite_id, dependent_id}, dependency_ids} ->
      %{
        prerequisite_work_package_id: prerequisite_id,
        dependent_work_package_id: dependent_id,
        dependency_ids: dependency_ids |> Enum.uniq() |> Enum.sort()
      }
    end)
    |> Enum.sort_by(&{&1.prerequisite_work_package_id, &1.dependent_work_package_id})
  end

  defp endpoint(edge, side), do: {value(edge, String.to_atom("#{side}_kind")), value(edge, String.to_atom("#{side}_id"))}
  defp expand_endpoint({"work_package", id}, _group_members), do: [id]
  defp expand_endpoint({"product_node", id}, group_members), do: Map.get(group_members, id, [])
  defp expand_endpoint(_endpoint, _group_members), do: []

  defp topology(work_package_ids, pairs) do
    graph = :digraph.new()
    Enum.each(work_package_ids, &:digraph.add_vertex(graph, &1))
    Enum.each(Enum.uniq(pairs), fn {from, to} -> :digraph.add_edge(graph, from, to) end)

    topological_order = deterministic_topological_order(work_package_ids, Enum.uniq(pairs))

    self_edges = MapSet.new(Enum.filter(pairs, fn {from, to} -> from == to end) |> Enum.map(&elem(&1, 0)))

    cycles =
      graph
      |> :digraph_utils.strong_components()
      |> Enum.filter(fn component -> length(component) > 1 or MapSet.member?(self_edges, hd(component)) end)
      |> Enum.map(&Enum.sort/1)
      |> Enum.sort()

    :digraph.delete(graph)
    {topological_order, cycles}
  end

  defp deterministic_topological_order(work_package_ids, pairs) do
    successors = Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))
    indegrees = Enum.reduce(pairs, Map.new(work_package_ids, &{&1, 0}), fn {_from, to}, acc -> Map.update!(acc, to, &(&1 + 1)) end)
    ready = indegrees |> Enum.filter(&(elem(&1, 1) == 0)) |> Enum.map(&elem(&1, 0)) |> :gb_sets.from_list()
    {order, indegrees} = take_ready(ready, successors, indegrees, [])

    if length(order) == map_size(indegrees), do: Enum.reverse(order), else: []
  end

  defp take_ready(ready, successors, indegrees, order) do
    if :gb_sets.is_empty(ready) do
      {order, indegrees}
    else
      {work_package_id, ready} = :gb_sets.take_smallest(ready)
      {ready, indegrees} = decrement_successors(Map.get(successors, work_package_id, []), ready, indegrees)
      take_ready(ready, successors, indegrees, [work_package_id | order])
    end
  end

  defp decrement_successors(successor_ids, ready, indegrees) do
    successor_ids
    |> Enum.sort()
    |> Enum.reduce({ready, indegrees}, fn successor_id, {ready, indegrees} ->
      indegrees = Map.update!(indegrees, successor_id, &(&1 - 1))
      ready = if Map.fetch!(indegrees, successor_id) == 0, do: :gb_sets.add(successor_id, ready), else: ready
      {ready, indegrees}
    end)
  end

  defp resolution(work_package, deliveries_by_work_package_id) do
    work_package_id = value(work_package, :id)
    status = value(work_package, :status) || value(work_package, :raw_status)

    delivery_outcome =
      value(work_package, :delivery_outcome) ||
        work_package |> value(:operational_state) |> value(:delivery_outcome) ||
        deliveries_by_work_package_id |> Map.get(work_package_id) |> value(:outcome)

    resolved = status in @resolved_statuses or delivery_outcome in WorkPackageDelivery.outcomes()

    %{
      work_package_id: work_package_id,
      status: status,
      delivery_outcome: delivery_outcome,
      resolved: resolved
    }
  end

  defp unmet_dependencies(work_package_ids, effective_edges, resolved_ids) do
    prerequisites = Enum.group_by(effective_edges, & &1.dependent_work_package_id, & &1.prerequisite_work_package_id)

    work_package_ids
    |> Enum.flat_map(fn work_package_id ->
      unmet = prerequisites |> Map.get(work_package_id, []) |> Enum.reject(&MapSet.member?(resolved_ids, &1)) |> Enum.uniq() |> Enum.sort()

      if unmet == [] do
        []
      else
        [%{work_package_id: work_package_id, prerequisite_work_package_ids: unmet}]
      end
    end)
  end

  defp value(nil, _key), do: nil
  defp value(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
