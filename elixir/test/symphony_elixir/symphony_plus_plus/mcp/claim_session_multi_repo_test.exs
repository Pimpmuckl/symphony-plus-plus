Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionMultiRepoTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "claim_local_assignment accepts linked WorkRequest with secondary delivery repo", %{repo: repo} do
    package =
      create_local_claim_package!(repo, "SYMPP-LOCAL-WR-DELIVERY-REPO",
        repo: "nextide/secondary-service",
        base_branch: "feature/secondary-delivery"
      )

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-DELIVERY-REPO",
        repo: "nextide/primary-service",
        base_branch: "main",
        status: "ready_for_slicing",
        repo_scopes: [%{repo: package.repo, base_branch: package.base_branch}]
      )

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(
                 id: "WRS-MCP-LOCAL-DELIVERY-REPO",
                 repo: package.repo,
                 base_branch: package.base_branch,
                 branch_pattern: package.branch_pattern
               )
             )

    assert {:ok, _canonical_package} =
             CanonicalWorkPackageFixtures.dispatch_work_package(
               repo,
               work_request.id,
               work_package.id,
               "planned",
               package.id
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-wr-delivery-repo",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "local-wr-delivery-repo-state")
      )

    assert get_in(response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert claimed_server.session.assignment.work_package_id == package.id
    assert {:ok, claimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert claimed_grant.claimed_at != nil
    refute inspect(response) =~ minted.work_key.secret
  end
end
