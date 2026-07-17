Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionTransport07Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{HTTPStateStore, HTTPTransport}

  test "HTTP batch release then claim persists the latest bound recovery state", %{repo: repo} do
    {package, work_request} = create_http_local_claim_package!(repo, "SYMPP-HTTP-RELEASE-THEN-CLAIM")
    config = local_mcp_config(repo)
    client_key = "client-http-release-then-claim-batch"

    {:ok, init_result} =
      HTTPTransport.handle(config, %{"jsonrpc" => "2.0", "id" => "init-release-then-claim", "method" => "initialize", "params" => initialize_params()}, client_key: client_key)

    {:ok, claim_result} =
      HTTPTransport.handle(
        config,
        %{
          "jsonrpc" => "2.0",
          "id" => "initial-claim-release-then-claim",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => local_assignment_claim_args(package, %{"work_request_id" => work_request.id})
          }
        },
        client_key: client_key,
        state_key: init_result.state_key
      )

    lease_id = get_in(claim_result.response, ["result", "structuredContent", "local_claim", "claim_lease_id"])
    assert get_in(claim_result.response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id

    {:ok, batch_result} =
      HTTPTransport.handle(
        config,
        [
          %{
            "jsonrpc" => "2.0",
            "id" => "release-before-reclaim",
            "method" => "tools/call",
            "params" => %{"name" => "release_current_assignment", "arguments" => %{"reason" => "done"}}
          },
          %{
            "jsonrpc" => "2.0",
            "id" => "reclaim-after-release",
            "method" => "tools/call",
            "params" => %{
              "name" => "claim_local_assignment",
              "arguments" => local_assignment_claim_args(package, %{"work_request_id" => work_request.id})
            }
          }
        ],
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert [release_response, reclaim_response] = batch_result.response
    assert get_in(release_response, ["result", "structuredContent", "binding_cleared"]) == true
    assert get_in(release_response, ["result", "structuredContent", "claim_lease_release", "claim_lease_id"]) == lease_id
    release_text = assert_toon_tool_text!(release_response)
    assert release_text =~ "binding_cleared: true"
    assert release_text =~ "claim_lease_release:"
    refute release_text =~ "claim_lease_id"
    refute release_text =~ ~s("binding_cleared")

    assert get_in(reclaim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    reclaim_text = assert_toon_tool_text!(reclaim_response)
    assert reclaim_text =~ "status: ok"
    assert reclaim_text =~ "work_package_id: #{package.id}"
    refute reclaim_text =~ "grant_id"
    refute reclaim_text =~ "claim_lease_id"
    refute reclaim_text =~ "caller_id"
    assert {:ok, %ClaimLease{status: "active"}} = ClaimLeaseService.current_for_work_package(repo, package.id)

    HTTPStateStore.reset!()

    {:ok, assignment_result} =
      HTTPTransport.handle(
        config,
        %{"jsonrpc" => "2.0", "id" => "assignment-after-release-then-claim", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert get_in(assignment_result.response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
  end

  defp create_http_local_claim_package!(repo, id) do
    package = create_local_claim_package!(repo, id, base_branch: "main")

    work_request =
      create_work_request!(repo,
        id: "WR-#{id}",
        repo: package.repo,
        base_branch: package.base_branch,
        status: "ready_for_slicing"
      )

    package =
      repo.update!(
        Ecto.Changeset.change(package,
          work_request_id: work_request.id,
          sequence: 1,
          goal: package.engineering_scope,
          status: "ready_for_worker",
          dispatched_at: DateTime.utc_now(:microsecond)
        )
      )

    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    {package, work_request}
  end
end
