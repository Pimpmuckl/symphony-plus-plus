Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionTransport07Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{HTTPStateStore, HTTPTransport}

  test "HTTP worker client introspects, claims, re-lists, releases, and reclaims only callable tools", %{repo: repo} do
    {package, work_request} = create_http_local_claim_package!(repo, "SYMPP-HTTP-RELEASE-THEN-CLAIM")
    config = %{local_mcp_config(repo) | surface_profile: :worker}
    client_key = "client-http-release-then-claim-batch"

    {:ok, init_result} =
      HTTPTransport.handle(config, %{"jsonrpc" => "2.0", "id" => "init-release-then-claim", "method" => "initialize", "params" => initialize_params()}, client_key: client_key)

    state_key = init_result.state_key

    unbound_tools = http!(config, client_key, state_key, "unbound-tools", "tools/list", %{})

    assert tool_names(unbound_tools) ==
             MapSet.new(["sympp.health", "release_current_assignment", "get_current_assignment", "claim_local_assignment"])

    introspection =
      http!(config, client_key, state_key, "unbound-assignment", "tools/call", %{
        "name" => "get_current_assignment",
        "arguments" => %{}
      })

    assert get_in(introspection.response, ["result", "structuredContent", "assignment"]) == nil
    assert get_in(introspection.response, ["result", "structuredContent", "binding", "state"]) == "unbound"
    assert get_in(introspection.response, ["result", "structuredContent", "recovery", "tools"]) == ["claim_local_assignment"]

    invalid_introspection =
      http!(config, client_key, state_key, "invalid-unbound-assignment", "tools/call", %{
        "name" => "get_current_assignment",
        "arguments" => %{"unexpected" => true}
      })

    assert get_in(invalid_introspection.response, ["error", "code"]) == -32_602
    assert get_in(invalid_introspection.response, ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(invalid_introspection.response, ["error", "data", "arguments"]) == ["unexpected"]

    claim_result =
      http!(config, client_key, state_key, "initial-claim", "tools/call", %{
        "name" => "claim_local_assignment",
        "arguments" => local_assignment_claim_args(package, %{"work_request_id" => work_request.id})
      })

    claim_payload = get_in(claim_result.response, ["result", "structuredContent"])
    assert get_in(claim_payload, ["assignment", "work_package_id"]) == package.id
    assert claim_payload["surface_revision"] =~ ~r/^sha256:[A-Za-z0-9_-]{43}$/
    assert claim_payload["relist"] == %{"next_action" => "list_tools"}

    bound_tools = http!(config, client_key, state_key, "bound-tools", "tools/list", %{})
    bound_names = tool_names(bound_tools)
    assert MapSet.member?(bound_names, "read_context")
    assert MapSet.member?(bound_names, "get_current_assignment")
    assert MapSet.member?(bound_names, "claim_local_assignment")
    refute MapSet.member?(bound_names, "claim_local_architect_assignment")

    refute Enum.any?(
             ["read_work_request", "update_work_package", "record_work_package_delivery", "create_work_request", "add_work_request_comment"],
             &MapSet.member?(bound_names, &1)
           )

    denied_architect_call =
      http!(config, client_key, state_key, "worker-record-delivery", "tools/call", %{
        "name" => "record_work_package_delivery",
        "arguments" => %{}
      })

    assert get_in(denied_architect_call.response, ["error", "data", "reason"]) == "architect_grant_required"

    assert get_in(denied_architect_call.response, ["error", "data", "recovery"]) == %{
             "next_action" => "return_to_architect",
             "next_owner" => "architect"
           }

    denied_architect_claim =
      http!(config, client_key, state_key, "worker-architect-claim", "tools/call", %{
        "name" => "claim_local_architect_assignment",
        "arguments" => %{"work_request_id" => work_request.id, "claimed_by" => "wrong-role-owner"}
      })

    assert get_in(denied_architect_claim.response, ["error", "data", "reason"]) == "tool_not_callable"

    assert get_in(
             http!(config, client_key, state_key, "still-worker", "tools/call", %{
               "name" => "get_current_assignment",
               "arguments" => %{}
             }).response,
             ["result", "structuredContent", "assignment", "grant_role"]
           ) == "worker"

    release_result =
      http!(config, client_key, state_key, "release-before-reclaim", "tools/call", %{
        "name" => "release_current_assignment",
        "arguments" => %{"reason" => "lifecycle proof"}
      })

    release_payload = get_in(release_result.response, ["result", "structuredContent"])
    assert release_payload["binding_cleared"] == true
    assert release_payload["surface_revision"] =~ ~r/^sha256:[A-Za-z0-9_-]{43}$/
    assert release_payload["surface_revision"] != claim_payload["surface_revision"]
    assert release_payload["relist"] == %{"next_action" => "list_tools"}
    assert tool_names(http!(config, client_key, state_key, "released-tools", "tools/list", %{})) == tool_names(unbound_tools)

    reclaim_result =
      http!(config, client_key, state_key, "reclaim", "tools/call", %{
        "name" => "claim_local_assignment",
        "arguments" => local_assignment_claim_args(package, %{"work_request_id" => work_request.id})
      })

    assert get_in(reclaim_result.response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert MapSet.member?(tool_names(http!(config, client_key, state_key, "reclaimed-tools", "tools/list", %{})), "read_context")
    assert {:ok, %ClaimLease{status: "active"}} = ClaimLeaseService.current_for_work_package(repo, package.id)

    HTTPStateStore.reset!()

    {:ok, assignment_result} =
      HTTPTransport.handle(
        config,
        %{"jsonrpc" => "2.0", "id" => "assignment-after-release-then-claim", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        client_key: client_key,
        state_key: state_key
      )

    assert get_in(assignment_result.response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
  end

  defp http!(config, client_key, state_key, id, method, params) do
    assert {:ok, result} =
             HTTPTransport.handle(
               config,
               %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params},
               client_key: client_key,
               state_key: state_key
             )

    result
  end

  defp tool_names(result) do
    result.response
    |> get_in(["result", "tools"])
    |> Enum.map(& &1["name"])
    |> MapSet.new()
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
