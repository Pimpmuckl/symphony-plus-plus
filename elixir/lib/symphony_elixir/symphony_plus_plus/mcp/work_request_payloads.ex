defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestPayloads do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.{Node, SliceLink}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
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
         {:ok, planned_slices} <- WorkRequestService.list_planned_slices(repo, work_request.id),
         {:ok, slice_visibility} <- DeliveryBoard.planned_slice_visibility(repo, work_request.id, planned_slices) do
      visible_planned_slices = Map.fetch!(slice_visibility, :visible_planned_slices)

      {:ok,
       %{
         "work_request" => work_request(work_request),
         "clarification_questions" => Enum.map(questions, &clarification_question/1),
         "decision_log_entries" => Enum.map(decisions, &decision_log_entry/1),
         "planned_slices" => Enum.map(visible_planned_slices, &planned_slice/1),
         "summary" => work_request_summary(questions, decisions, visible_planned_slices)
       }}
    end
  end

  @spec work_request_product_tree(repo(), WorkRequest.t(), [PlannedSlice.t()], map(), binary()) :: map()
  def work_request_product_tree(repo, %WorkRequest{} = work_request, planned_slices, delivery_board, view) do
    projection_slice_payloads = delivery_board |> Map.fetch!(:slices) |> json_safe_payload()
    visible_planned_slices = visible_planned_slices_from_projection(planned_slices, projection_slice_payloads)
    slice_payloads = product_tree_slice_payloads(visible_planned_slices, projection_slice_payloads)

    product_tree =
      repo
      |> ProductTree.project(work_request.id, projection_slice_payloads, product_tree_projection_opts())
      |> json_safe_payload()
      |> product_tree_view_payload(slice_payloads, view)

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

  @spec planned_slice(PlannedSlice.t()) :: map()
  def planned_slice(%PlannedSlice{} = planned_slice) do
    %{
      "id" => planned_slice.id,
      "work_request_id" => planned_slice.work_request_id,
      "sequence" => planned_slice.sequence,
      "title" => Redactor.redact_text(planned_slice.title),
      "goal" => Redactor.redact_text(planned_slice.goal),
      "work_package_kind" => planned_slice.work_package_kind,
      "delivery_repo" => Redactor.redact_text(planned_slice.delivery_repo),
      "target_base_branch" => Redactor.redact_text(planned_slice.target_base_branch),
      "branch_pattern" => Redactor.redact_text(planned_slice.branch_pattern),
      "owned_file_globs" => Enum.map(planned_slice.owned_file_globs || [], &Redactor.redact_text/1),
      "forbidden_file_globs" => Enum.map(planned_slice.forbidden_file_globs || [], &Redactor.redact_text/1),
      "acceptance_criteria" => Enum.map(planned_slice.acceptance_criteria || [], &Redactor.redact_text/1),
      "validation_steps" => Enum.map(planned_slice.validation_steps || [], &Redactor.redact_text/1),
      "review" => Redactor.redact_output(planned_slice.review_requirement),
      "stop_conditions" => Enum.map(planned_slice.stop_conditions || [], &Redactor.redact_text/1),
      "status" => planned_slice.status,
      "work_package_id" => planned_slice.work_package_id,
      "dispatched_at" => timestamp(planned_slice.dispatched_at),
      "inserted_at" => timestamp(planned_slice.inserted_at),
      "updated_at" => timestamp(planned_slice.updated_at)
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

  @spec product_tree_slice_link(SliceLink.t() | nil) :: map() | nil
  def product_tree_slice_link(nil), do: nil

  def product_tree_slice_link(%SliceLink{} = slice_link) do
    %{
      "id" => slice_link.id,
      "work_request_id" => slice_link.work_request_id,
      "product_tree_node_id" => slice_link.product_tree_node_id,
      "planned_slice_id" => slice_link.planned_slice_id,
      "role" => slice_link.role,
      "position" => slice_link.position,
      "created_by" => Redactor.redact_text(slice_link.created_by),
      "created_at" => timestamp(slice_link.created_at),
      "inserted_at" => timestamp(slice_link.inserted_at),
      "updated_at" => timestamp(slice_link.updated_at)
    }
  end

  @spec planned_slice_delivery(PlannedSliceDelivery.t()) :: map()
  def planned_slice_delivery(%PlannedSliceDelivery{} = delivery) do
    %{
      "id" => delivery.id,
      "work_request_id" => delivery.work_request_id,
      "planned_slice_id" => delivery.planned_slice_id,
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
      "successor_planned_slice_id" => delivery.successor_planned_slice_id,
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

  defp visible_planned_slices_from_projection(planned_slices, projection_slice_payloads) do
    visible_slice_ids =
      projection_slice_payloads
      |> Enum.map(&map_get(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.filter(planned_slices, &MapSet.member?(visible_slice_ids, &1.id))
  end

  defp product_tree_view_payload(product_tree, _slice_payloads, "nodes_only") do
    product_tree
    |> Map.put("nodes", product_tree |> Map.get("nodes", []) |> Enum.map(&product_tree_node_only_payload/1))
    |> Map.put("root_slice_ids", [])
    |> Map.put("dependency_edges", product_tree |> Map.get("dependency_edges", []) |> Enum.filter(&product_tree_node_dependency?/1))
    |> Map.update("summary", %{"root_slice_count" => 0}, &Map.put(&1, "root_slice_count", 0))
    |> Map.put("omitted_slice_count", product_tree |> Map.get("summary", %{}) |> Map.get("slice_count", 0))
  end

  defp product_tree_view_payload(product_tree, slice_payloads, "nodes_with_slices") do
    Map.put(product_tree, "slices", slice_payloads)
  end

  defp product_tree_view_payload(product_tree, slice_payloads, "nodes_with_slice_refs") do
    Map.put(product_tree, "slice_refs", Enum.map(slice_payloads, &product_tree_slice_ref_payload/1))
  end

  defp product_tree_slice_payloads(visible_planned_slices, projection_slice_payloads) do
    projection_slice_payloads_by_id = Map.new(projection_slice_payloads, &{map_get(&1, :id), &1})

    Enum.map(visible_planned_slices, fn %PlannedSlice{} = planned_slice ->
      planned_slice
      |> planned_slice()
      |> Map.merge(product_tree_operational_slice_fields(Map.get(projection_slice_payloads_by_id, planned_slice.id, %{})))
    end)
  end

  defp product_tree_projection_opts, do: [visible_only?: true, include_unlinked_nodes?: true]

  defp product_tree_operational_slice_fields(projection_slice_payload) when is_map(projection_slice_payload) do
    projection_slice_payload
    |> Map.take(["raw_status", "delivery_outcome", "operational_state", "attention_reason_codes"])
    |> Map.put("status", map_get(projection_slice_payload, :raw_status))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp product_tree_node_only_payload(node) when is_map(node) do
    Map.drop(node, ["slice_ids", "attention_count", "guidance_count", "blocker_count"])
  end

  defp product_tree_node_dependency?(%{"source_kind" => "product_node", "target_kind" => "product_node"}), do: true
  defp product_tree_node_dependency?(_edge), do: false

  defp product_tree_slice_ref_payload(slice) when is_map(slice) do
    slice
    |> Map.take(["id", "sequence", "title", "status", "work_package_id"])
    |> Map.merge(product_tree_operational_slice_fields(slice))
    |> Map.put("has_full_payload", false)
  end

  defp work_request_creator(%WorkRequest{} = work_request) do
    %{
      "kind" => work_request.creator_kind,
      "name" => Redactor.redact_text(work_request.creator_name),
      "via" => work_request.created_via
    }
  end

  defp work_request_summary(questions, decisions, planned_slices) do
    %{
      "open_question_count" => Enum.count(questions, &(&1.status == "open")),
      "answered_question_count" => Enum.count(questions, &(&1.status == "answered")),
      "closed_question_count" => Enum.count(questions, &(&1.status == "closed")),
      "decision_count" => length(decisions),
      "planned_slice_count" => Enum.count(planned_slices, &(&1.status == "planned")),
      "approved_slice_count" => Enum.count(planned_slices, &(&1.status == "approved")),
      "dispatched_slice_count" => Enum.count(planned_slices, &(&1.status == "dispatched")),
      "skipped_slice_count" => Enum.count(planned_slices, &(&1.status == "skipped"))
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
