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

  test "WorkRequest architects manage descendant planning evidence and discover its resources", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-ARCH-DESCENDANT-PLANNING",
        status: "sliced",
        repo_scopes: [%{repo: "nextide/secondary-service", base_branch: "release"}]
      )

    assert {:ok, package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               WorkPackageFactory.attrs(
                 id: "WP-ARCH-DESCENDANT-PLANNING",
                 repo: "nextide/secondary-service",
                 base_branch: "release",
                 status: "planning"
               )
             )

    assert {:ok, existing} =
             PlanningRepository.append_plan_node(repo, %{
               "work_package_id" => package.id,
               "title" => "Inspect descendant"
             })

    {_anchor, session, grant} =
      create_work_request_handoff_architect_session(repo, work_request, ArchitectHandoff.capabilities())

    read_response = mcp_tool(repo, session, "read_task_plan", %{"work_package_id" => package.id})
    version = get_in(read_response, ["result", "structuredContent", "version"])
    assert is_integer(version)

    update_response =
      mcp_tool(repo, session, "update_task_plan", %{
        "work_package_id" => package.id,
        "expected_version" => version,
        "nodes" => [%{"id" => existing.id, "status" => "in_progress"}]
      })

    assert get_in(update_response, ["result", "structuredContent", "plan_nodes"]) == [
             %{"id" => existing.id, "title" => "Inspect descendant", "status" => "in_progress"}
           ]

    finding_response =
      mcp_tool(repo, session, "append_finding", %{
        "work_package_id" => package.id,
        "title" => "Secondary repository confirmed",
        "body" => "The descendant remains inside the claimed WorkRequest.",
        "idempotency_key" => "architect-descendant-finding"
      })

    assert get_in(finding_response, ["result", "structuredContent", "finding", "title"]) ==
             "Secondary repository confirmed"

    progress_response =
      mcp_tool(repo, session, "append_progress", %{
        "work_package_id" => package.id,
        "summary" => "Descendant plan supervised",
        "idempotency_key" => "architect-descendant-progress"
      })

    assert get_in(progress_response, ["result", "structuredContent", "progress_event", "status"]) == "recorded"

    assert {:ok, [finding]} = PlanningRepository.list_findings(repo, package.id)
    assert finding.access_grant_id == grant.id
    assert {:ok, [progress]} = PlanningRepository.list_progress_events(repo, package.id)
    assert {progress.actor_type, progress.actor_id, progress.access_grant_id} == {"architect", "architect-1", grant.id}

    assert {:ok, _active_sibling} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               WorkPackageFactory.attrs(id: "WP-ARCH-DESCENDANT-ACTIVE", status: "planning")
             )

    list_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "resources", "method" => "resources/list", "params" => %{}},
        repo: repo,
        session: session
      )

    resource_uri = "sympp://work-packages/#{package.id}/task_plan.md"
    resource_uris = list_response |> get_in(["result", "resources"]) |> Enum.map(& &1["uri"])
    assert resource_uri in resource_uris

    resource_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "resource", "method" => "resources/read", "params" => %{"uri" => resource_uri}},
        repo: repo,
        session: session
      )

    assert resource_response["error"] == nil

    other_work_request = create_work_request!(repo, id: "WR-ARCH-FOREIGN", status: "sliced")

    assert {:ok, foreign_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               other_work_request.id,
               WorkPackageFactory.attrs(id: "WP-ARCH-FOREIGN", status: "planning")
             )

    foreign_response = mcp_tool(repo, session, "read_task_plan", %{"work_package_id" => foreign_package.id})
    assert get_in(foreign_response, ["error", "data", "reason"]) == "not_found"
    refute "sympp://work-packages/#{foreign_package.id}/task_plan.md" in resource_uris

    assert {:ok, _skipped} = WorkPackageRepository.update(repo, package.id, %{status: "skipped"})

    terminal_calls = [
      {"update_task_plan", %{"work_package_id" => package.id, "expected_version" => version, "nodes" => [%{"id" => existing.id, "status" => "done"}]}},
      {"append_finding", %{"work_package_id" => package.id, "title" => "Too late", "body" => "Terminal package", "idempotency_key" => "terminal-finding"}},
      {"append_progress", %{"work_package_id" => package.id, "summary" => "Too late", "idempotency_key" => "terminal-progress"}}
    ]

    for {tool, arguments} <- terminal_calls do
      response = mcp_tool(repo, session, tool, arguments)
      assert get_in(response, ["error", "data", "reason"]) == "work_package_terminal"
    end
  end
end
