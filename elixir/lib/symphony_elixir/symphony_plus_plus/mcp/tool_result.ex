defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolResult do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.ArchitectContext
  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ClaimToolText

  @spec tool_result(term()) :: map()
  def tool_result(payload) do
    payload = compact_tool_payload(payload)

    %{
      "content" => [%{"type" => "text", "text" => WorkerContext.encode_tool_payload(payload)}],
      "structuredContent" => payload,
      "isError" => false
    }
  end

  @spec claim_tool_result(term()) :: map()
  def claim_tool_result(payload), do: agent_tool_result(payload, ClaimToolText.claim(payload))

  @spec release_tool_result(term()) :: map()
  def release_tool_result(payload), do: agent_tool_result(payload, ClaimToolText.release(payload))

  @spec agent_tool_result(term()) :: map()
  def agent_tool_result(payload) do
    payload = compact_tool_payload(payload)
    agent_tool_result(payload, WorkerContext.encode_tool_payload(payload))
  end

  @spec read_tool_result(term()) :: map()
  def read_tool_result(payload), do: agent_tool_result(payload, WorkerContext.encode_tool_payload(payload))

  @spec agent_tool_result(term(), String.t()) :: map()
  def agent_tool_result(payload, agent_text) when is_binary(agent_text) do
    %{
      "content" => [%{"type" => "text", "text" => agent_text}],
      "structuredContent" => payload,
      "isError" => false
    }
  end

  @spec architect_agent_tool_result(term(), atom()) :: map()
  def architect_agent_tool_result(payload, kind) do
    agent_tool_result(payload, ArchitectContext.encode_tool_payload(payload, kind))
  end

  defp compact_tool_payload(%{} = payload) do
    payload
    |> compact_tool_payload_entries()
    |> put_next_action()
  end

  defp compact_tool_payload(payload), do: payload

  defp compact_tool_payload_entries(%{} = payload) do
    payload
    |> Map.drop(["product_tree", :product_tree])
    |> Enum.map(fn {key, value} -> compact_tool_entry(to_string(key), key, value) end)
    |> Map.new()
  end

  defp compact_tool_entry("work_request", key, value), do: {key, compact_status_payload(value, ["id", "status", "updated_at"])}

  defp compact_tool_entry("planned_slice", key, value),
    do:
      {key,
       compact_status_payload(value, [
         "id",
         "work_request_id",
         "status",
         "work_package_id",
         "delivery_repo",
         "target_base_branch",
         "dispatched_at",
         "updated_at"
       ])}

  defp compact_tool_entry("work_package", key, value),
    do:
      {key,
       compact_status_payload(value, [
         "id",
         "kind",
         "status",
         "repo",
         "base_branch",
         "phase_id",
         "parent_id",
         "title",
         "branch_pattern",
         "worktree_path",
         "inserted_at",
         "updated_at"
       ])}

  defp compact_tool_entry("progress_event", key, value),
    do: {key, compact_status_payload(value, ["id", "status", "summary", "idempotency_key"])}

  defp compact_tool_entry("guidance_request", key, value),
    do:
      {key,
       compact_status_payload(value, [
         "id",
         "work_package_id",
         "summary",
         "question",
         "status",
         "requested_by",
         "answered_by",
         "human_info_reason",
         "recommended_language",
         "blocker_id"
       ])}

  defp compact_tool_entry("clarification_question", key, value),
    do: {key, compact_status_payload(value, ["id", "status", "sequence"])}

  defp compact_tool_entry("decision_log_entry", key, value),
    do: {key, compact_status_payload(value, ["id", "sequence", "source_type", "source_id", "decision", "created_by"])}

  defp compact_tool_entry("product_plan_node", key, value),
    do: {key, compact_status_payload(value, ["id", "work_request_id", "parent_id", "position", "completion_mark"])}

  defp compact_tool_entry("product_tree_slice_link", key, value),
    do: {key, compact_status_payload(value, ["id", "work_request_id", "planned_slice_id", "product_tree_node_id", "position"])}

  defp compact_tool_entry("planned_slice_delivery", key, value),
    do:
      {key,
       compact_status_payload(value, [
         "id",
         "work_request_id",
         "planned_slice_id",
         "outcome",
         "recorded_by",
         "pr_url",
         "successor_planned_slice_id",
         "successor_work_package_id"
       ])}

  defp compact_tool_entry("delivery_board", key, value), do: {key, compact_status_payload(value, ["counts"])}

  defp compact_tool_entry("audit_event", key, value),
    do: {key, compact_status_payload(value, ["id", "status", "summary", "idempotency_key"])}

  defp compact_tool_entry("reconciliation", key, value) when is_map(value),
    do:
      {key,
       compact_status_payload(value, [
         "mode",
         "applied?",
         "changed?",
         "proposed_count",
         "applied_count",
         "recorded_delivery_count",
         "missing_delivery_count",
         "results"
       ])}

  defp compact_tool_entry("runtime_cleanup", key, value) when is_map(value),
    do:
      {key,
       compact_status_payload(value, [
         "status",
         "reason",
         "reason_code",
         "work_package_id",
         "revoked_worker_grant_ids",
         "released_claim_lease_ids",
         "cleared_session_binding_ids",
         "cleared_mcp_session_binding_ids",
         "reason_codes"
       ])}

  defp compact_tool_entry("worker_bootstrap", key, value) when is_map(value),
    do:
      {key,
       compact_status_payload(value, [
         "type",
         "mode",
         "work_package_id",
         "branch",
         "worktree_path",
         "coordinates",
         "claim",
         "ledger",
         "required_runtime_arguments",
         "arguments",
         "preferred_skill_set",
         "supported_skill_sets",
         "required_skills"
       ])}

  defp compact_tool_entry("worker_grant", key, value),
    do:
      {key,
       compact_status_payload(value, [
         "id",
         "grant_role",
         "work_package_id",
         "capabilities",
         "expires_at",
         "secret_in_response",
         "worker_bootstrap"
       ])}

  defp compact_tool_entry(_name, key, value), do: {key, compact_tool_value(value)}

  defp compact_tool_value(%{} = value), do: compact_tool_payload_entries(value)
  defp compact_tool_value(values) when is_list(values), do: Enum.map(values, &compact_tool_value/1)
  defp compact_tool_value(value), do: value

  defp compact_status_payload(%{} = value, keys) do
    value
    |> json_safe_payload()
    |> Map.take(keys)
    |> drop_nil_values()
  end

  defp compact_status_payload(value, _keys), do: value

  defp put_next_action(%{} = payload) do
    Map.put_new_lazy(payload, "next_action", fn -> next_action(payload) end)
  end

  defp next_action(%{"status" => %{} = status}) do
    cond do
      present?(Map.get(status, "current_status")) -> Map.get(status, "current_status")
      present?(Map.get(status, "work_request_status")) -> Map.get(status, "work_request_status")
      present?(Map.get(status, "planned_slice_status")) -> Map.get(status, "planned_slice_status")
      present?(Map.get(status, "guidance_request_status")) -> Map.get(status, "guidance_request_status")
      true -> "inspect_status"
    end
  end

  defp next_action(%{"planned_slice_delivery" => %{"outcome" => outcome}}) when is_binary(outcome), do: outcome
  defp next_action(%{"work_package" => %{"status" => status}}) when is_binary(status), do: status
  defp next_action(%{"work_request" => %{"status" => status}}) when is_binary(status), do: status
  defp next_action(_payload), do: "done"

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp json_safe_payload(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
