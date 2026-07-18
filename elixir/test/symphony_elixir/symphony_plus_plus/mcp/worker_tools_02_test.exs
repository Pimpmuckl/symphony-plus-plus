Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools02Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "update_task_plan patches existing nodes with expected version", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PLAN-PATCH", kind: "mcp"))
    assert {:ok, plan_node} = PlanningRepository.append_plan_node(repo, %{"work_package_id" => package.id, "title" => "Original", "status" => "pending"})
    assert {:ok, second_node} = PlanningRepository.append_plan_node(repo, %{"work_package_id" => package.id, "title" => "Second", "status" => "pending"})
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    read_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "read-plan", "method" => "tools/call", "params" => %{"name" => "read_task_plan"}},
        repo: repo,
        session: session
      )

    version = get_in(read_response, ["result", "structuredContent", "version"])

    invalid_patch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{
              "expected_version" => version,
              "patch" => %{"nodes" => [%{"id" => plan_node.id, "status" => "done"}, %{"id" => second_node.id, "status" => "invalid"}]}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_patch_response, ["error", "code"]) == -32_602
    assert get_in(invalid_patch_response, ["error", "data", "reason"]) == "invalid_status"

    assert get_in(invalid_patch_response, ["error", "data", "validation_errors"]) == [
             %{"field" => "status", "reason" => "invalid_value", "allowed_values" => ["pending", "done", "skipped"]}
           ]

    assert {:ok, unchanged_nodes} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert Enum.find(unchanged_nodes, &(&1.id == plan_node.id)).status == "pending"

    malformed_patch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "malformed-patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => %{"nodes" => ["bad"]}}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(malformed_patch_response, ["error", "data", "reason"]) == "invalid_patch_node"

    malformed_patch_shape_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "malformed-patch-shape-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => "bad", "title" => "Do not append"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(malformed_patch_shape_response, ["error", "data", "reason"]) == "invalid_patch"
    assert {:ok, unchanged_after_bad_patch} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert length(unchanged_after_bad_patch) == 2

    blank_title_patch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "blank-title-patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => %{"nodes" => [%{"id" => plan_node.id, "title" => "   "}]}}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(blank_title_patch_response, ["error", "code"]) == -32_602
    assert {:ok, unchanged_after_blank_title} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert Enum.find(unchanged_after_blank_title, &(&1.id == plan_node.id)).title == "Original"

    mixed_patch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "mixed-patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => %{"nodes" => [%{"id" => plan_node.id, "status" => "done"}]}, "title" => "Ignored"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(mixed_patch_response, ["error", "data", "reason"]) == "invalid_update_task_plan"
    assert {:ok, unchanged_after_mixed_patch} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert Enum.find(unchanged_after_mixed_patch, &(&1.id == plan_node.id)).status == "pending"

    malformed_id_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "malformed-id-patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => %{"nodes" => [%{"id" => 123, "title" => "Duplicate"}]}}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(malformed_id_response, ["error", "data", "reason"]) == "invalid_patch_node"
    assert {:ok, unchanged_after_bad_id} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert length(unchanged_after_bad_id) == 2

    no_op_patch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "no-op-patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => %{"nodes" => [%{"id" => plan_node.id}]}}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(no_op_patch_response, ["error", "data", "reason"]) == "invalid_patch_node"

    unknown_patch_key_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "unknown-patch-key-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => %{"nodes" => [%{"id" => plan_node.id, "titel" => "Typo", "status" => "done"}]}}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(unknown_patch_key_response, ["error", "data", "reason"]) == "invalid_patch_node"

    patch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{
              "expected_version" => version,
              "work_package_id" => package.id,
              "patch" => %{"nodes" => [%{"id" => " #{plan_node.id} ", "status" => "done", "body" => "Complete"}]}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(patch_response, ["result", "structuredContent", "plan_nodes", Access.at(0), "status"]) == "done"
    assert {:ok, nodes} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert length(nodes) == 2
    assert Enum.find(nodes, &(&1.id == plan_node.id)).body == "Complete"

    read_after_patch_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "read-plan-after-patch", "method" => "tools/call", "params" => %{"name" => "read_task_plan"}},
        repo: repo,
        session: session
      )

    body_only_patch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "body-only-patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{
              "expected_version" => get_in(read_after_patch_response, ["result", "structuredContent", "version"]),
              "patch" => %{"nodes" => [%{"id" => plan_node.id, "body" => "Body-only update"}]}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(body_only_patch_response, ["result", "structuredContent", "plan_nodes", Access.at(0), "id"]) == plan_node.id
    assert {:ok, body_only_nodes} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert Enum.find(body_only_nodes, &(&1.id == plan_node.id)).body == "Body-only update"

    stale_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "stale-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => %{"nodes" => [%{"id" => plan_node.id, "status" => "pending"}]}}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_response, ["error", "data", "reason"]) == "stale_plan_version"
  end

  test "update_task_plan patch can append a new node with caller id", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PLAN-PATCH-ID", kind: "mcp"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    read_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "read-plan", "method" => "tools/call", "params" => %{"name" => "read_task_plan"}},
        repo: repo,
        session: session
      )

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "patch-plan-with-id",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{
              "expected_version" => get_in(read_response, ["result", "structuredContent", "version"]),
              "patch" => %{"nodes" => [%{"id" => " caller-node-1 ", "title" => "Deterministic node", "status" => "pending"}]}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["result", "structuredContent", "plan_nodes", Access.at(0), "id"]) == "caller-node-1"
    assert {:ok, nodes} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert Enum.any?(nodes, &(&1.id == "caller-node-1" and &1.title == "Deterministic node"))
  end
end
