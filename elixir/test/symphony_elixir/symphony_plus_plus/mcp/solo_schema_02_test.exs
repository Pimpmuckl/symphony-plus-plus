Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.SoloSchema02Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "worker tools reject arguments outside their advertised schemas", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-STRICT-ARGS", kind: "mcp", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "strict-args",
          "method" => "tools/call",
          "params" => %{"name" => "mark_ready", "arguments" => %{"work_package_id" => package.id}}
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(response, ["error", "data", "arguments"]) == ["work_package_id"]
  end

  test "direct calls fail closed for tools outside the session surface before argument validation", %{repo: repo} do
    unbound_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "unbound-worker-call",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"unexpected" => "value"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(unbound_response, ["error", "code"]) == -32_001
    assert get_in(unbound_response, ["error", "data", "resource"]) == "append_progress"
    assert get_in(unbound_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(unbound_response, ["error", "data", "action"]) == "claim_local_assignment"

    unbound_guidance_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "unbound-guidance-call",
          "method" => "tools/call",
          "params" => %{"name" => "read_guidance_request", "arguments" => %{"unexpected" => "value"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(unbound_guidance_response, ["error", "code"]) == -32_001
    assert get_in(unbound_guidance_response, ["error", "data", "resource"]) == "read_guidance_request"
    assert get_in(unbound_guidance_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(unbound_guidance_response, ["error", "data", "action"]) == "claim_local_architect_assignment"

    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-WORKER-CALL", kind: "mcp"))
    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["read:phase"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    architect_session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    architect_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "architect-worker-call",
          "method" => "tools/call",
          "params" => %{"name" => "attach_pr", "arguments" => %{"unexpected" => "value"}}
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(architect_response, ["error", "code"]) == -32_001
    assert get_in(architect_response, ["error", "data", "resource"]) == "attach_pr"
    assert get_in(architect_response, ["error", "data", "reason"]) == "worker_grant_required"
    assert {:ok, []} = PlanningRepository.list_progress_events(repo, package.id)

    hidden_shared_tool_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "architect-hidden-shared-tool-call",
          "method" => "tools/call",
          "params" => %{"name" => "read_guidance_request", "arguments" => %{"unexpected" => "value"}}
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(hidden_shared_tool_response, ["error", "code"]) == -32_001
    assert get_in(hidden_shared_tool_response, ["error", "data", "resource"]) == "read_guidance_request"
    assert get_in(hidden_shared_tool_response, ["error", "data", "reason"]) == "insufficient_capability"
  end
end
