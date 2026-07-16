defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestPayloads do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Node
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type repo :: module()
  @type dashboard_error :: term()

  @spec work_request_cards([WorkRequest.t()]) :: [map()]
  def work_request_cards(work_requests) do
    Enum.map(work_requests, &work_request_card/1)
  end

  @spec work_request_card(WorkRequest.t()) :: map()
  def work_request_card(%WorkRequest{} = work_request) do
    scope = redacted_work_request_scope(work_request)

    %{
      "id" => work_request.id,
      "title" => Redactor.redact_text(work_request.title),
      "repo" => Map.fetch!(scope, "repo"),
      "base_branch" => Map.fetch!(scope, "base_branch"),
      "work_type" => work_request.work_type,
      "desired_dispatch_shape" => work_request.desired_dispatch_shape,
      "creator" => work_request_creator(work_request),
      "status" => work_request.status,
      "inserted_at" => timestamp(work_request.inserted_at),
      "updated_at" => timestamp(work_request.updated_at)
    }
  end

  @spec work_request_filter(nil | binary()) :: map()
  def work_request_filter(nil), do: %{}
  def work_request_filter(status), do: %{"status" => status}

  @spec work_request_detail(repo(), WorkRequest.t(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_request_detail(repo, %WorkRequest{} = work_request, _opts) do
    with {:ok, questions} <- WorkRequestService.list_questions(repo, work_request.id),
         {:ok, decisions} <- WorkRequestService.list_decisions(repo, work_request.id),
         {:ok, work_packages} <- WorkRequestService.list_work_packages(repo, work_request.id),
         {:ok, slice_visibility} <- DeliveryBoard.work_package_visibility(repo, work_request.id, work_packages) do
      visible_work_packages = Map.fetch!(slice_visibility, :visible_work_packages)

      {:ok,
       %{
         "work_request" => work_request(work_request),
         "clarification_questions" => Enum.map(questions, &clarification_question/1),
         "decision_log_entries" => Enum.map(decisions, &decision_log_entry/1),
         "work_packages" => Enum.map(visible_work_packages, &work_package/1),
         "summary" => work_request_summary(questions, decisions, visible_work_packages)
       }}
    end
  end

  @spec work_request_product_tree(repo(), WorkRequest.t(), [WorkPackage.t()], map(), binary()) :: map()
  def work_request_product_tree(repo, %WorkRequest{} = work_request, work_packages, delivery_board, view) do
    projection_work_package_payloads = delivery_board |> Map.fetch!(:work_packages) |> json_safe_payload()
    visible_work_packages = visible_work_packages_from_projection(work_packages, projection_work_package_payloads)
    work_package_payloads = product_tree_work_package_payloads(visible_work_packages, projection_work_package_payloads)

    product_tree =
      repo
      |> ProductTree.project(work_request.id, projection_work_package_payloads, product_tree_projection_opts())
      |> json_safe_payload()
      |> product_tree_view_payload(work_package_payloads, view)

    %{
      "work_request" => work_request(work_request),
      "product_tree" => product_tree,
      "view" => view
    }
  end

  @spec work_request(WorkRequest.t()) :: map()
  def work_request(%WorkRequest{} = work_request) do
    scope = redacted_work_request_scope(work_request)

    %{
      "id" => work_request.id,
      "title" => Redactor.redact_text(work_request.title),
      "repo" => Map.fetch!(scope, "repo"),
      "base_branch" => Map.fetch!(scope, "base_branch"),
      "work_type" => work_request.work_type,
      "human_description" => Redactor.redact_text(work_request.human_description),
      "constraints" => Redactor.redact_output(work_request.constraints || %{}),
      "desired_dispatch_shape" => work_request.desired_dispatch_shape,
      "creator" => work_request_creator(work_request),
      "status" => work_request.status,
      "inserted_at" => timestamp(work_request.inserted_at),
      "updated_at" => timestamp(work_request.updated_at)
    }
  end

  @spec redacted_work_request_scope(WorkRequest.t()) :: map()
  def redacted_work_request_scope(%WorkRequest{} = work_request) do
    %{
      "repo" => Redactor.redact_text(work_request.repo),
      "base_branch" => Redactor.redact_text(work_request.base_branch)
    }
  end

  @spec work_request_mutation(WorkRequest.t()) :: map()
  def work_request_mutation(%WorkRequest{} = work_request) do
    %{
      "id" => work_request.id,
      "status" => work_request.status,
      "updated_at" => timestamp(work_request.updated_at)
    }
  end

  @spec clarification_question(ClarificationQuestion.t()) :: map()
  def clarification_question(%ClarificationQuestion{} = question) do
    %{
      "id" => question.id,
      "work_request_id" => question.work_request_id,
      "sequence" => question.sequence,
      "category" => Redactor.redact_text(question.category),
      "question" => Redactor.redact_text(question.question),
      "why_needed" => Redactor.redact_text(question.why_needed),
      "decision_prompt" => Redactor.redact_output(question.decision_prompt),
      "status" => question.status,
      "asked_by_agent_run_id" => Redactor.redact_text(question.asked_by_agent_run_id),
      "answer" => Redactor.redact_text(question.answer),
      "answered_by" => Redactor.redact_text(question.answered_by),
      "answered_at" => timestamp(question.answered_at),
      "inserted_at" => timestamp(question.inserted_at),
      "updated_at" => timestamp(question.updated_at)
    }
  end

  @spec decision_log_entry(DecisionLogEntry.t()) :: map()
  def decision_log_entry(%DecisionLogEntry{} = decision) do
    %{
      "id" => decision.id,
      "work_request_id" => decision.work_request_id,
      "sequence" => decision.sequence,
      "source_type" => Redactor.redact_text(decision.source_type),
      "source_id" => Redactor.redact_text(decision.source_id),
      "decision" => Redactor.redact_text(decision.decision),
      "rationale" => Redactor.redact_text(decision.rationale),
      "scope_impact" => Redactor.redact_text(decision.scope_impact),
      "created_by" => Redactor.redact_text(decision.created_by),
      "created_at" => timestamp(decision.created_at),
      "inserted_at" => timestamp(decision.inserted_at),
      "updated_at" => timestamp(decision.updated_at)
    }
  end

  @spec work_package(WorkPackage.t()) :: map()
  def work_package(%WorkPackage{} = work_package) do
    %{
      "id" => work_package.id,
      "work_request_id" => work_package.work_request_id,
      "product_tree_node_id" => work_package.product_tree_node_id,
      "sequence" => work_package.sequence,
      "title" => Redactor.redact_text(work_package.title),
      "goal" => Redactor.redact_text(work_package.goal),
      "kind" => work_package.kind,
      "repo" => Redactor.redact_text(work_package.repo),
      "base_branch" => Redactor.redact_text(work_package.base_branch),
      "branch_pattern" => Redactor.redact_text(work_package.branch_pattern),
      "allowed_file_globs" => Enum.map(work_package.allowed_file_globs || [], &Redactor.redact_text/1),
      "forbidden_file_globs" => Enum.map(work_package.forbidden_file_globs || [], &Redactor.redact_text/1),
      "acceptance_criteria" => Enum.map(work_package.acceptance_criteria || [], &Redactor.redact_text/1),
      "validation_steps" => Enum.map(work_package.validation_steps || [], &Redactor.redact_text/1),
      "review" => Redactor.redact_output(work_package.review_requirement),
      "stop_conditions" => Enum.map(work_package.stop_conditions || [], &Redactor.redact_text/1),
      "status" => work_package.status,
      "contract_revision" => work_package.contract_revision,
      "dispatched_at" => timestamp(work_package.dispatched_at),
      "inserted_at" => timestamp(work_package.inserted_at),
      "updated_at" => timestamp(work_package.updated_at)
    }
  end

  @spec product_tree_node(Node.t()) :: map()
  def product_tree_node(%Node{} = node) do
    %{
      "id" => node.id,
      "work_request_id" => node.work_request_id,
      "parent_id" => node.parent_id,
      "title" => Redactor.redact_text(node.title),
      "description" => Redactor.redact_text(node.description),
      "node_kind" => Redactor.redact_text(node.node_kind),
      "completion_mark" => node.completion_mark,
      "position" => node.position,
      "created_by" => Redactor.redact_text(node.created_by),
      "created_at" => timestamp(node.created_at),
      "inserted_at" => timestamp(node.inserted_at),
      "updated_at" => timestamp(node.updated_at)
    }
  end

  @spec work_package_delivery(WorkPackageDelivery.t()) :: map()
  def work_package_delivery(%WorkPackageDelivery{} = delivery) do
    %{
      "id" => delivery.id,
      "work_request_id" => delivery.work_request_id,
      "work_package_id" => delivery.work_package_id,
      "outcome" => delivery.outcome,
      "idempotency_key" => Redactor.redact_text(delivery.idempotency_key),
      "recorded_by" => Redactor.redact_text(delivery.recorded_by),
      "recorded_at" => timestamp(delivery.recorded_at),
      "pr_url" => Redactor.redact_text(delivery.pr_url),
      "pr_number" => delivery.pr_number,
      "pr_repository" => Redactor.redact_text(delivery.pr_repository),
      "pr_merged_at" => timestamp(delivery.pr_merged_at),
      "merge_commit_sha" => Redactor.redact_text(delivery.merge_commit_sha),
      "no_pr_evidence" => Redactor.redact_text(delivery.no_pr_evidence),
      "successor_work_package_id" => delivery.successor_work_package_id,
      "superseded_reason" => Redactor.redact_text(delivery.superseded_reason),
      "abandoned_rationale" => Redactor.redact_text(delivery.abandoned_rationale),
      "inserted_at" => timestamp(delivery.inserted_at),
      "updated_at" => timestamp(delivery.updated_at)
    }
  end

  @spec delivery_board(map()) :: map()
  def delivery_board(delivery_board) do
    delivery_board
    |> json_safe_payload()
    |> Redactor.redact_output()
  end

  defp visible_work_packages_from_projection(work_packages, projection_work_package_payloads) do
    visible_work_package_ids =
      projection_work_package_payloads
      |> Enum.map(&map_get(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.filter(work_packages, &MapSet.member?(visible_work_package_ids, &1.id))
  end

  defp product_tree_view_payload(product_tree, _work_package_payloads, "nodes_only") do
    product_tree
    |> Map.put("nodes", product_tree |> Map.get("nodes", []) |> Enum.map(&product_tree_node_only_payload/1))
    |> Map.put("root_work_package_ids", [])
    |> Map.put("dependency_edges", product_tree |> Map.get("dependency_edges", []) |> Enum.filter(&product_tree_node_dependency?/1))
    |> Map.update("summary", %{"root_work_package_count" => 0}, &Map.put(&1, "root_work_package_count", 0))
    |> Map.put("omitted_work_package_count", product_tree |> Map.get("summary", %{}) |> Map.get("work_package_count", 0))
  end

  defp product_tree_view_payload(product_tree, work_package_payloads, "nodes_with_work_packages") do
    Map.put(product_tree, "work_packages", work_package_payloads)
  end

  defp product_tree_view_payload(product_tree, work_package_payloads, "nodes_with_work_package_refs") do
    Map.put(product_tree, "work_package_refs", Enum.map(work_package_payloads, &product_tree_work_package_ref_payload/1))
  end

  defp product_tree_work_package_payloads(visible_work_packages, projection_work_package_payloads) do
    projection_work_package_payloads_by_id = Map.new(projection_work_package_payloads, &{map_get(&1, :id), &1})

    Enum.map(visible_work_packages, fn %WorkPackage{} = work_package ->
      work_package
      |> work_package()
      |> Map.merge(product_tree_operational_work_package_fields(Map.get(projection_work_package_payloads_by_id, work_package.id, %{})))
    end)
  end

  defp product_tree_projection_opts, do: [visible_only?: true, include_unowned_nodes?: true]

  defp product_tree_operational_work_package_fields(projection_work_package_payload) when is_map(projection_work_package_payload) do
    projection_work_package_payload
    |> Map.take(["raw_status", "delivery_outcome", "operational_state", "attention_reason_codes"])
    |> Map.put("status", map_get(projection_work_package_payload, :raw_status))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp product_tree_node_only_payload(node) when is_map(node) do
    Map.drop(node, ["slice_ids", "attention_count", "guidance_count", "blocker_count"])
  end

  defp product_tree_node_dependency?(%{"source_kind" => "product_node", "target_kind" => "product_node"}), do: true
  defp product_tree_node_dependency?(_edge), do: false

  defp product_tree_work_package_ref_payload(work_package) when is_map(work_package) do
    work_package
    |> Map.take(["id", "sequence", "title", "status"])
    |> Map.merge(product_tree_operational_work_package_fields(work_package))
    |> Map.put("has_full_payload", false)
  end

  defp work_request_creator(%WorkRequest{} = work_request) do
    %{
      "kind" => work_request.creator_kind,
      "name" => Redactor.redact_text(work_request.creator_name),
      "via" => work_request.created_via
    }
  end

  defp work_request_summary(questions, decisions, work_packages) do
    %{
      "open_question_count" => Enum.count(questions, &(&1.status == "open")),
      "answered_question_count" => Enum.count(questions, &(&1.status == "answered")),
      "closed_question_count" => Enum.count(questions, &(&1.status == "closed")),
      "decision_count" => length(decisions),
      "work_package_count" => length(work_packages),
      "planned_work_package_count" => Enum.count(work_packages, &(&1.status == "planned")),
      "dispatched_work_package_count" => Enum.count(work_packages, &(not is_nil(&1.dispatched_at))),
      "skipped_work_package_count" => Enum.count(work_packages, &(&1.status == "skipped"))
    }
  end

  defp map_get(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp map_get(_value, _key), do: nil

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  defp timestamp(%NaiveDateTime{} = timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp timestamp(nil), do: nil

  defp json_safe_payload(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
