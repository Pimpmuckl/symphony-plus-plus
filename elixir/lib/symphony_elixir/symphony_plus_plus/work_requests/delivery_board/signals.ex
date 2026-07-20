defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard.Signals do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.Sanitizer
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequest
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequestProgress
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.{DependencyEdge, ExecutionGraph, Node}
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @request_chunk_size 400
  @string_limit 240

  @spec execution_graphs(module(), [WorkRequest.t()], map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execution_graphs(_repo, [], _work_packages_by_request, _deliveries_by_slice_id, _opts), do: {:ok, %{}}

  def execution_graphs(repo, work_requests, work_packages_by_request, deliveries_by_slice_id, opts) do
    load_execution_graphs(repo, work_requests, work_packages_by_request, deliveries_by_slice_id, opts)
  end

  defp load_execution_graphs(repo, work_requests, work_packages_by_request, deliveries_by_slice_id, opts) do
    work_request_ids = Enum.map(work_requests, & &1.id)

    nodes_by_request =
      work_request_ids
      |> Enum.chunk_every(@request_chunk_size)
      |> Enum.flat_map(fn request_id_chunk ->
        repo.all(
          from(node in Node,
            where: node.work_request_id in ^request_id_chunk,
            order_by: [asc: node.work_request_id, asc: node.parent_id, asc: node.position, asc: node.created_at, asc: node.id]
          )
        )
      end)
      |> Enum.group_by(& &1.work_request_id)

    edges_by_request =
      work_request_ids
      |> Enum.chunk_every(@request_chunk_size)
      |> Enum.flat_map(fn request_id_chunk ->
        repo.all(
          from(edge in DependencyEdge,
            where: edge.work_request_id in ^request_id_chunk,
            order_by: [asc: edge.work_request_id, asc: edge.kind, asc: edge.created_at, asc: edge.id]
          )
        )
      end)
      |> Enum.group_by(& &1.work_request_id)

    deliveries_by_request =
      deliveries_by_slice_id
      |> Map.values()
      |> Enum.group_by(& &1.work_request_id)

    graphs =
      Map.new(work_requests, fn %WorkRequest{} = work_request ->
        work_packages = Map.get(work_packages_by_request, work_request.id, [])
        deliveries = Map.get(deliveries_by_request, work_request.id, [])

        graph =
          ExecutionGraph.evaluate(
            %{
              nodes: Map.get(nodes_by_request, work_request.id, []),
              dependency_edges: Map.get(edges_by_request, work_request.id, [])
            },
            work_packages,
            deliveries
          )

        {work_request.id, scope_execution_graph(graph, work_packages, opts)}
      end)

    {:ok, graphs}
  rescue
    error in Exqlite.Error ->
      if missing_product_tree_schema_error?(error), do: {:ok, %{}}, else: normalize_exqlite_error(error)
  end

  @spec pr(map()) :: map()
  def pr(metadata) do
    case map_value(metadata, "pr") do
      nil ->
        %{status: "none"}

      %{} = pr ->
        raw_head_sha = map_value(pr, "head_sha")

        raw_current_head_sha =
          map_value(pr, "current_head_sha") ||
            metadata |> map_value("branch") |> map_value("head_sha")

        head_sha = bounded_string(raw_head_sha)
        current_head_sha = bounded_string(raw_current_head_sha)

        %{
          status: pr_status(pr),
          url: bounded_string(map_value(pr, "url")),
          number: integer_value(first_map_value(pr, ["number", "pr_number"])),
          repository: bounded_string(first_map_value(pr, ["repository", "pr_repository"])),
          head_sha: head_sha,
          current_head_sha: current_head_sha,
          head_matches:
            if(filled_string?(raw_head_sha) and filled_string?(raw_current_head_sha),
              do: PullRequest.head_sha_matches?(raw_head_sha, raw_current_head_sha)
            ),
          checks: checks(map_value(pr, "check_summary"))
        }
        |> reject_nil_values()

      _invalid ->
        %{status: "unavailable"}
    end
  end

  @spec review(WorkPackage.t(), map()) :: map() | nil
  def review(%WorkPackage{review_requirement: nil}, _metadata), do: nil

  def review(%WorkPackage{review_requirement: requirement}, metadata) when is_map(requirement) do
    type = bounded_string(map_value(requirement, "type"))
    args = map_value(requirement, "args")
    review_package = map_value(metadata, "review_package")
    completion = map_value(metadata, "review_completion")
    evidence = [completion, review_package, args]

    %{
      type: type,
      args: if(is_map(args), do: Sanitizer.redacted_json(args)),
      status: review_status(type, review_package, completion),
      current: evidence |> signal_value(["current", "completed", "completed_count"]) |> integer_value(),
      total: evidence |> signal_value(["total", "total_count"]) |> integer_value(),
      step: evidence |> signal_value(["step", "stage"]) |> bounded_string(),
      evidence_id: evidence |> signal_value(["evidence_id", "reference", "id"]) |> bounded_string()
    }
    |> reject_nil_values()
  end

  def review(%WorkPackage{}, _metadata), do: %{status: "unavailable"}

  @spec dependency(WorkPackage.t(), map()) :: map() | nil
  def dependency(%WorkPackage{} = work_package, context) do
    graph = get_in(context, [:execution_graphs, work_package.work_request_id])

    incoming_ids =
      graph
      |> map_value("effective_edges")
      |> List.wrap()
      |> Enum.filter(&(map_value(&1, "dependent_work_package_id") == work_package.id))
      |> Enum.map(&map_value(&1, "prerequisite_work_package_id"))
      |> Enum.filter(&filled_string?/1)
      |> Enum.uniq()
      |> Enum.sort()

    if incoming_ids == [] do
      nil
    else
      unmet_ids =
        graph
        |> map_value("unmet_dependencies")
        |> List.wrap()
        |> Enum.find(&(map_value(&1, "work_package_id") == work_package.id))
        |> map_value("prerequisite_work_package_ids")
        |> List.wrap()
        |> MapSet.new()

      inputs =
        Enum.map(incoming_ids, fn prerequisite_id ->
          %{
            work_package_id: prerequisite_id,
            status: dependency_input_status(prerequisite_id, unmet_ids, context)
          }
        end)

      %{
        satisfied: Enum.count(inputs, &(&1.status == "satisfied")),
        required: length(inputs),
        active: Enum.count(inputs, &(&1.status == "active")),
        blocked: Enum.count(inputs, &(&1.status == "blocked")),
        unmet_work_package_ids:
          inputs
          |> Enum.reject(&(&1.status == "satisfied"))
          |> Enum.map(& &1.work_package_id),
        inputs: inputs
      }
    end
  end

  defp scope_execution_graph(graph, work_packages, opts) do
    case Keyword.get(opts, :visible_work_package_ids, :all) do
      visible_ids when is_list(visible_ids) ->
        visible_ids = MapSet.new(visible_ids)

        work_packages
        |> Enum.map(& &1.id)
        |> Enum.filter(&MapSet.member?(visible_ids, &1))
        |> then(&ExecutionGraph.scope(graph, &1))

      _all ->
        graph
    end
  end

  defp pr_status(pr) do
    cond do
      PullRequestProgress.merged?(pr) -> "merged"
      filled_string?(map_value(pr, "url")) or is_integer(first_map_value(pr, ["number", "pr_number"])) -> "open"
      true -> "unavailable"
    end
  end

  defp checks(nil), do: nil
  defp checks(value) when not is_map(value), do: %{status: "unavailable"}

  defp checks(value) do
    %{
      status: value |> first_map_value(["conclusion", "state", "status"]) |> check_status(),
      current: integer_value(first_map_value(value, ["current", "completed", "completed_count"])),
      total: integer_value(first_map_value(value, ["total", "total_count", "check_count"]))
    }
    |> reject_nil_values()
  end

  defp check_status(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      status when status in ["success", "succeeded", "passed", "passing", "complete", "completed"] -> "passing"
      status when status in ["failure", "failed", "failing", "error", "cancelled", "timed_out"] -> "failing"
      status when status in ["pending", "queued", "running", "in_progress", "in progress", "waiting"] -> "pending"
      _status -> "unavailable"
    end
  end

  defp check_status(_value), do: "unavailable"

  defp review_status(type, review_package, completion) do
    verdict = signal_value([completion, review_package], ["verdict", "conclusion", "status"])

    cond do
      not filled_string?(type) -> "unavailable"
      normalized(verdict) in ["failure", "failed", "failing", "error", "cancelled"] -> "failed"
      normalized(verdict) in ["success", "succeeded", "passed", "passing", "approved"] -> "passed"
      is_map(completion) -> "passed"
      is_map(review_package) -> "in_progress"
      true -> "pending"
    end
  end

  defp dependency_input_status(work_package_id, unmet_ids, context) do
    activity = get_in(context, [:activity_contexts, work_package_id]) || WorkPackageActivity.empty_context()

    cond do
      not MapSet.member?(unmet_ids, work_package_id) -> "satisfied"
      get_in(activity, [:blocker_state, :active?]) == true -> "blocked"
      get_in(activity, [:runtime_state, :active?]) == true -> "active"
      true -> "waiting"
    end
  end

  defp signal_value(maps, keys) do
    Enum.find_value(maps, fn
      %{} = map -> first_map_value(map, keys)
      _value -> nil
    end)
  end

  defp normalized(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalized(_value), do: nil

  defp bounded_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @string_limit)
    end
  end

  defp bounded_string(_value), do: nil
  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: nil

  defp first_map_value(map, keys), do: Enum.find_value(keys, &map_value(map, &1))

  defp map_value(%{} = map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> atom_map_value(map, key)
    end
  end

  defp map_value(_value, _key), do: nil

  defp atom_map_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    _error in ArgumentError -> nil
  end

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp missing_product_tree_schema_error?(error) do
    error
    |> Exception.message()
    |> String.downcase()
    |> String.contains?("no such table: sympp_product_tree_")
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
