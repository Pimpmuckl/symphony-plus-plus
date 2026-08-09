Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools02Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog.InputSchemas

  test "update_task_plan exposes one atomic node-list contract" do
    schema = ToolCatalog.worker_tool_input_schema("update_task_plan")

    assert schema == InputSchemas.unbound_worker_tool_input_schema("update_task_plan")
    assert schema["required"] == ["expected_version", "nodes"]
    assert Map.keys(schema["properties"]) |> Enum.sort() == ["expected_version", "nodes"]
    assert schema["properties"]["nodes"]["minItems"] == 1

    node_schema = schema["properties"]["nodes"]["items"]
    assert Map.keys(node_schema["properties"]) |> Enum.sort() == ["body", "id", "status", "title"]
    assert node_schema["properties"]["status"]["enum"] == ["pending", "in_progress", "done", "skipped"]
  end

  test "update_task_plan updates same-package nodes and creates server-owned ids", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PLAN-WRITE", kind: "mcp"))
    assert {:ok, existing} = PlanningRepository.append_plan_node(repo, %{"work_package_id" => package.id, "title" => "Original"})
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    read_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "read", "method" => "tools/call", "params" => %{"name" => "read_task_plan"}},
        repo: repo,
        session: session
      )

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "write",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{
              "expected_version" => get_in(read_response, ["result", "structuredContent", "version"]),
              "nodes" => [
                %{"id" => existing.id, "body" => "Working", "status" => "in_progress"},
                %{"title" => "Finished", "status" => "done"}
              ]
            }
          }
        },
        repo: repo,
        session: session
      )

    [updated, created] = get_in(response, ["result", "structuredContent", "plan_nodes"])
    assert updated == %{"id" => existing.id, "title" => "Original", "status" => "in_progress"}
    assert created["id"] =~ ~r/^plan_/
    assert created["title"] == "Finished"

    assert {:ok, nodes} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert Enum.find(nodes, &(&1.id == existing.id)).body == "Working"
    assert Enum.any?(nodes, &(&1.id == created["id"] and &1.status == "done"))

    rendered =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "rendered", "method" => "tools/call", "params" => %{"name" => "read_task_plan"}},
        repo: repo,
        session: session
      )

    assert get_in(rendered, ["result", "structuredContent", "text"]) =~ "Original` _(in progress)_"
  end

  test "update_task_plan rejects stale, unknown, cross-package, and invalid nodes atomically", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PLAN-ATOMIC", kind: "mcp"))
    assert {:ok, sibling} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PLAN-SIBLING", kind: "mcp"))
    assert {:ok, own_node} = PlanningRepository.append_plan_node(repo, %{"work_package_id" => package.id, "title" => "Own"})
    assert {:ok, sibling_node} = PlanningRepository.append_plan_node(repo, %{"work_package_id" => sibling.id, "title" => "Sibling"})
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    read_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "read", "method" => "tools/call", "params" => %{"name" => "read_task_plan"}},
        repo: repo,
        session: session
      )

    version = get_in(read_response, ["result", "structuredContent", "version"])

    for {id, attempted_id} <- [{"cross", sibling_node.id}, {"unknown", "plan_missing"}] do
      response =
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => id,
            "method" => "tools/call",
            "params" => %{
              "name" => "update_task_plan",
              "arguments" => %{
                "expected_version" => version,
                "nodes" => [%{"id" => own_node.id, "status" => "done"}, %{"id" => attempted_id, "title" => "Do not create"}]
              }
            }
          },
          repo: repo,
          session: session
        )

      assert get_in(response, ["error", "data", "reason"]) == "unknown_plan_node"
      assert {:ok, [unchanged]} = PlanningRepository.list_plan_nodes(repo, package.id)
      assert unchanged.status == "pending"
    end

    invalid_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "nodes" => [%{"id" => own_node.id, "status" => "invalid"}]}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_response, ["error", "data", "reason"]) == "invalid_status"
    assert {:ok, [unchanged]} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert unchanged.status == "pending"

    assert {:ok, _concurrent_node} = PlanningRepository.append_plan_node(repo, %{"work_package_id" => package.id, "title" => "Concurrent"})

    stale_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "stale",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "nodes" => [%{"id" => own_node.id, "status" => "done"}]}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_response, ["error", "data", "reason"]) == "stale_plan_version"
    assert {:ok, nodes} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert Enum.find(nodes, &(&1.id == own_node.id)).status == "pending"
    assert {:ok, [unchanged_sibling]} = PlanningRepository.list_plan_nodes(repo, sibling.id)
    assert unchanged_sibling.status == "pending"
  end
end
