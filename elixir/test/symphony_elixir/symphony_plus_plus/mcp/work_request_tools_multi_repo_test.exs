Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestToolsMultiRepoTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "WorkRequest MCP planned-slice mutations preserve secondary delivery repo scopes", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-DELIVERY-REPO", [
        "write:work_request",
        "read:work_request"
      ])

    delivery_repo = "nextide/secondary-service"
    delivery_base = "feature/secondary-delivery"

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-DELIVERY-REPO",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing",
        repo_scopes: [%{repo: delivery_repo}]
      )

    grant_work_request_scope!(repo, session, work_request.id)

    add_args = %{
      "work_request_id" => work_request.id,
      "title" => "Secondary repo delivery",
      "goal" => "Prepare a worker from a secondary repository in the same WorkRequest.",
      "work_package_kind" => "mcp",
      "delivery_repo" => delivery_repo,
      "target_base_branch" => delivery_base,
      "owned_file_globs" => ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
      "forbidden_file_globs" => [],
      "acceptance_criteria" => ["Delivery repo is preserved on the planned slice."],
      "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp"],
      "review_lanes" => ["normal"],
      "stop_conditions" => ["Stop before unrelated scope."]
    }

    missing_base_response =
      mcp_tool(repo, session, "add_work_request_planned_slice", Map.delete(add_args, "target_base_branch"))

    assert get_in(missing_base_response, ["error", "data", "reason"]) == "missing_target_base_branch"

    add_response = mcp_tool(repo, session, "add_work_request_planned_slice", add_args)

    add_payload = get_in(add_response, ["result", "structuredContent"])
    planned_slice_id = get_in(add_payload, ["planned_slice", "id"])

    assert get_in(add_payload, ["planned_slice", "delivery_repo"]) == delivery_repo
    assert get_in(add_payload, ["planned_slice", "target_base_branch"]) == delivery_base

    approve_response =
      mcp_tool(repo, session, "approve_work_request_planned_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice_id,
        "current_status" => "planned"
      })

    assert get_in(approve_response, ["result", "structuredContent", "planned_slice", "status"]) == "approved"

    assert {:ok, [planned_slice]} = WorkRequestRepository.list_planned_slices(repo, work_request.id)
    assert planned_slice.delivery_repo == delivery_repo
    assert planned_slice.target_base_branch == delivery_base
  end
end
