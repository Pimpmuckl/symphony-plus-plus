Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionTransport05Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity

  test "claim_local_assignment releases the old package before rebinding a server", %{repo: repo} do
    first_package = create_local_claim_package!(repo, "SYMPP-LOCAL-REBIND-ONE")
    second_package = create_local_claim_package!(repo, "SYMPP-LOCAL-REBIND-TWO")
    assert {:ok, _first_minted} = AccessGrantService.mint_worker_grant(repo, first_package.id)
    assert {:ok, _second_minted} = AccessGrantService.mint_worker_grant(repo, second_package.id)

    {first_response, claimed_server} =
      Server.handle_response_state(
        tool_call("claim-one", "claim_local_assignment", local_assignment_claim_args(first_package)),
        local_mcp_server(local_mcp_config(repo), "local-rebind-state")
      )

    {same_response, same_server} =
      Server.handle_response_state(
        tool_call("claim-one-again", "claim_local_assignment", local_assignment_claim_args(first_package)),
        claimed_server
      )

    {rebind_response, rebound_server} =
      Server.handle_response_state(
        tool_call("claim-two", "claim_local_assignment", local_assignment_claim_args(second_package, %{"claimed_by" => "local-worker-2"})),
        same_server
      )

    assert get_in(first_response, ["result", "structuredContent", "assignment", "work_package_id"]) == first_package.id
    assert get_in(same_response, ["result", "structuredContent", "assignment", "work_package_id"]) == first_package.id
    assert get_in(rebind_response, ["result", "structuredContent", "assignment", "work_package_id"]) == second_package.id
    assert rebound_server.session.assignment.work_package_id == second_package.id
    assert {:error, :not_found} = ClaimLeaseService.current_for_work_package(repo, first_package.id)
  end

  test "claim_local_assignment keeps the old binding when the new target is invalid", %{repo: repo} do
    first_package = create_local_claim_package!(repo, "SYMPP-LOCAL-REBIND-VALID")
    second_package = create_local_claim_package!(repo, "SYMPP-LOCAL-REBIND-BAD-SCOPE")
    assert {:ok, _first_minted} = AccessGrantService.mint_worker_grant(repo, first_package.id)
    assert {:ok, _second_minted} = AccessGrantService.mint_worker_grant(repo, second_package.id)

    {_first_response, claimed_server} =
      Server.handle_response_state(
        tool_call("claim-valid", "claim_local_assignment", local_assignment_claim_args(first_package)),
        local_mcp_server(local_mcp_config(repo), "local-rebind-invalid-state")
      )

    {rebind_response, server} =
      Server.handle_response_state(
        tool_call("claim-bad-scope", "claim_local_assignment", local_assignment_claim_args(second_package, %{"repo" => "other/repo"})),
        claimed_server
      )

    assert get_in(rebind_response, ["error", "data", "reason"]) == "repo_scope_mismatch"
    assert server.session.assignment.work_package_id == first_package.id
    assert {:ok, _lease} = ClaimLeaseService.current_for_work_package(repo, first_package.id)
  end

  test "claim_local_assignment keeps the old binding when the new target is leased by another worker", %{repo: repo} do
    first_package = create_local_claim_package!(repo, "SYMPP-LOCAL-REBIND-LEASED-OLD")
    second_package = create_local_claim_package!(repo, "SYMPP-LOCAL-REBIND-LEASED-NEW")
    assert {:ok, _first_minted} = AccessGrantService.mint_worker_grant(repo, first_package.id)
    assert {:ok, _second_minted} = AccessGrantService.mint_worker_grant(repo, second_package.id)

    {_other_response, _other_server} =
      Server.handle_response_state(
        tool_call("claim-other-worker", "claim_local_assignment", local_assignment_claim_args(second_package, %{"claimed_by" => "other-worker"})),
        local_mcp_server(local_mcp_config(repo), "local-rebind-leased-other-state")
      )

    {_first_response, claimed_server} =
      Server.handle_response_state(
        tool_call("claim-old-worker", "claim_local_assignment", local_assignment_claim_args(first_package)),
        local_mcp_server(local_mcp_config(repo), "local-rebind-leased-old-state")
      )

    {rebind_response, server} =
      Server.handle_response_state(
        tool_call("claim-leased-target", "claim_local_assignment", local_assignment_claim_args(second_package, %{"claimed_by" => "local-worker-2"})),
        claimed_server
      )

    assert get_in(rebind_response, ["error", "data", "reason"]) == "claim_lease_active_for_other_actor"
    assert server.session.assignment.work_package_id == first_package.id
    assert {:ok, _lease} = ClaimLeaseService.current_for_work_package(repo, first_package.id)
  end

  test "claim_local_assignment keeps the old binding when the new target has no claimable grant", %{repo: repo} do
    first_package = create_local_claim_package!(repo, "SYMPP-LOCAL-REBIND-GRANT-OLD")
    second_package = create_local_claim_package!(repo, "SYMPP-LOCAL-REBIND-GRANT-MISSING")
    assert {:ok, _first_minted} = AccessGrantService.mint_worker_grant(repo, first_package.id)

    {_first_response, claimed_server} =
      Server.handle_response_state(
        tool_call("claim-grant-old", "claim_local_assignment", local_assignment_claim_args(first_package)),
        local_mcp_server(local_mcp_config(repo), "local-rebind-grant-missing-state")
      )

    {rebind_response, server} =
      Server.handle_response_state(
        tool_call("claim-grant-missing", "claim_local_assignment", local_assignment_claim_args(second_package, %{"claimed_by" => "local-worker-2"})),
        claimed_server
      )

    assert get_in(rebind_response, ["error", "data", "reason"]) == "worker_grant_required"
    assert get_in(rebind_response, ["error", "message"]) == "Worker grant required for WorkPackage #{second_package.id}"
    assert get_in(rebind_response, ["error", "data", "work_package_id"]) == second_package.id
    assert get_in(rebind_response, ["error", "data", "action"]) == "dispatch_work_package"
    assert get_in(rebind_response, ["error", "data", "remediation"]) =~ second_package.id
    assert server.session.assignment.work_package_id == first_package.id
    assert {:ok, _lease} = ClaimLeaseService.current_for_work_package(repo, first_package.id)
    assert {:error, :not_found} = ClaimLeaseService.current_for_work_package(repo, second_package.id)
    assert is_nil(WorkPackageActivity.context(repo, second_package.id).worker_signal)
  end

  test "stdio local claim binds by WorkPackage id only", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STDIO-ID-ONLY-CLAIM")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, claimed_server} =
      Server.handle_response_state(
        tool_call("stdio-id-only-claim", "claim_local_assignment", %{"work_package_id" => package.id}),
        Server.new(test_mcp_config(repo), initialized: true)
      )

    assert get_in(response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(response, ["result", "structuredContent", "local_claim", "mode"]) == "stdio"
    assert claimed_server.session.assignment.work_package_id == package.id

    {reconnect_response, _server} =
      Server.handle_response_state(
        tool_call("stdio-id-only-reconnect", "claim_local_assignment", %{"work_package_id" => package.id}),
        Server.new(test_mcp_config(repo), initialized: true)
      )

    assert get_in(reconnect_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(reconnect_response, ["result", "structuredContent", "local_claim", "mode"]) == "stdio"
    assert get_in(reconnect_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "heartbeat"
  end

  test "batch local claim does not bind sibling batch items", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-BATCH-THREAD")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {responses, _server} =
      Server.handle_response_state(
        [
          tool_call("invalid-local-claim", "claim_local_assignment", Map.put(local_assignment_claim_args(package), "unexpected", "value")),
          tool_call("progress-before-claim", "append_progress", %{
            "summary" => "should not append",
            "idempotency_key" => "progress-before-local-claim"
          }),
          tool_call("valid-local-claim", "claim_local_assignment", local_assignment_claim_args(package)),
          tool_call("progress-after-claim", "append_progress", %{
            "summary" => "should append",
            "idempotency_key" => "progress-after-local-claim"
          })
        ],
        local_mcp_server(local_mcp_config(repo), "local-batch-thread-state")
      )

    assert get_in(Enum.at(responses, 0), ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(Enum.at(responses, 1), ["error", "data", "reason"]) == "claim_required"
    assert get_in(Enum.at(responses, 2), ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(Enum.at(responses, 3), ["error", "data", "reason"]) == "claim_required"
  end

  test "single-item batch preserves local claim session for later requests", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-SINGLE-BATCH")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    state_key = make_ref()
    server = local_mcp_server(local_mcp_config(repo), state_key)

    {responses, claimed_server} =
      Server.handle_response_state(
        [
          tool_call("single-batch-claim", "claim_local_assignment", local_assignment_claim_args(package))
        ],
        server
      )

    {read_response, _server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "assignment-after-single-batch", "method" => "tools/call", "params" => %{"name" => "get_current_assignment", "arguments" => %{}}},
        claimed_server
      )

    assert [claim_response] = responses
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(read_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
  end

  test "batch calls persist local claim session only after the batch completes", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-BATCH-NO-LEAK")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    server = local_mcp_server(local_mcp_config(repo), make_ref())

    {responses, claimed_server} =
      Server.handle_response_state(
        [
          tool_call("batch-claim", "claim_local_assignment", local_assignment_claim_args(package)),
          tool_call("batch-progress", "append_progress", %{
            "summary" => "in-batch progress",
            "idempotency_key" => "local-batch-progress"
          })
        ],
        server
      )

    assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment-outside-batch", "method" => "tools/call", "params" => %{"name" => "get_current_assignment", "arguments" => %{}}},
        server
      )

    assert get_in(Enum.at(responses, 0), ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(Enum.at(responses, 1), ["error", "data", "reason"]) == "claim_required"
    assert claimed_server.session.assignment.work_package_id == package.id
    assert get_in(assignment_response, ["error", "data", "reason"]) == "claim_required"
  end

  defp tool_call(id, name, arguments) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}}
  end
end
