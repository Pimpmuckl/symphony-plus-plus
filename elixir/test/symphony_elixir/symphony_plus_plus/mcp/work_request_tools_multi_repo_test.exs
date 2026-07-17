Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestToolsMultiRepoTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "WorkRequest MCP work-package mutations preserve secondary delivery repo scopes", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-DELIVERY-REPO", [
        "write:work_request",
        "read:work_request"
      ])

    target_repo = "nextide/secondary-service"
    delivery_base = "feature/secondary-delivery"

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-DELIVERY-REPO",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing",
        repo_scopes: [%{repo: target_repo}]
      )

    grant_work_request_scope!(repo, session, work_request.id)

    package = %{
      "title" => "Secondary repo delivery",
      "goal" => "Prepare a worker from a secondary repository in the same WorkRequest.",
      "kind" => "mcp",
      "repo" => target_repo,
      "base_branch" => delivery_base,
      "allowed_file_globs" => ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
      "forbidden_file_globs" => [],
      "acceptance_criteria" => ["Delivery repo is preserved on the WorkPackage."],
      "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp"],
      "review" => %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      "stop_conditions" => ["Stop before unrelated scope."]
    }

    missing_base_response =
      mcp_tool(repo, session, "slice_work_request", %{
        "work_request_id" => work_request.id,
        "work_packages" => [Map.delete(package, "base_branch")]
      })

    assert get_in(missing_base_response, ["error", "data", "reason"]) ==
             "work_package_delivery_scope_out_of_scope"

    response =
      mcp_tool(repo, session, "slice_work_request", %{
        "work_request_id" => work_request.id,
        "work_packages" => [package]
      })

    payload = get_in(response, ["result", "structuredContent"])
    assert [work_package_id] = payload["work_package_ids"]
    assert payload["product_tree_revision"]["revision_number"] == 1

    assert {:ok, [work_package]} = WorkRequestRepository.list_work_packages(repo, work_request.id)
    assert work_package.id == work_package_id
    assert work_package.repo == target_repo
    assert work_package.base_branch == delivery_base
    assert work_package.status == "planned"
  end
end
