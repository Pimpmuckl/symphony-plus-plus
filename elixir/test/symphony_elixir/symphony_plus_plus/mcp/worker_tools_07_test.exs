Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools07Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "docs mark_ready does not require manufactured delivery evidence", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-DOCS", kind: "docs", status: "reviewing"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "docs-worker")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-docs", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "kind"]) == "docs"
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"
  end

  test "hotfix mark_ready uses provider-backed delivery evidence", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-HOTFIX", kind: "hotfix", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-HOTFIX/worker", "head_sha" => "hotfix-head"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/812", "head_sha" => "hotfix-head"})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/812", "hotfix-head")

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-hotfix", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"
  end

  test "investigation accepts headless evidence and findings without manufacturing a recommendation artifact", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INVESTIGATION-READY", kind: "investigation", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    finding_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "finding",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Recommendation", "body" => "No code change needed.", "idempotency_key" => "investigation-finding"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(finding_response, ["result", "structuredContent", "finding", "title"]) == "Recommendation"

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "mark_ready rejects spoofed provider metadata", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-SPOOF", kind: "mcp", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    Enum.each(["branch", "pr"], fn type ->
      response =
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "spoof-#{type}",
            "method" => "tools/call",
            "params" => %{
              "name" => "append_progress",
              "arguments" => %{
                "summary" => "Spoof #{type}",
                "idempotency_key" => "spoof-#{type}",
                "payload" => %{"type" => type, "source_tool" => "attach_#{type}"}
              }
            }
          },
          repo: repo,
          session: session
        )

      assert get_in(response, ["result", "structuredContent", "progress_event", "id"])
    end)

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["error", "data", "reason"]) == "readiness_failed"

    assert get_in(ready_response, ["error", "data", "missing"]) == [
             "branch_attached",
             "pr_attached"
           ]
  end

  test "append_progress rejects non-map payloads", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PAYLOAD", kind: "mcp"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    invalid_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "bad-payload",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_progress",
            "arguments" => %{"summary" => "Bad", "idempotency_key" => "bad-payload", "payload" => false}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_response, ["error", "code"]) == -32_602
    assert get_in(invalid_response, ["error", "data", "reason"]) == "invalid_payload"
  end

  test "mark_ready uses lifecycle capability checks", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-CAP", kind: "mcp", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id, capabilities: ["worker:claim"])
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-CAP/worker", "head_sha" => "abc124"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/124", "head_sha" => "abc124"})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/124", "abc124")

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "data", "reason"]) == "missing_lifecycle_capability"
  end

  test "worker surface omits general lifecycle mutation, grant minting, and package listing", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-DENIALS", kind: "adapter", status: "ready_for_merge"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    tools_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "worker-tools",
          "method" => "tools/list",
          "params" => %{}
        },
        repo: repo,
        session: session
      )

    refute Enum.any?(get_in(tools_response, ["result", "tools"]), &(&1["name"] == "set_status"))

    Enum.each(["mint_worker_grant", "list_work_packages"], fn tool ->
      response =
        MCPHarness.request(
          %{"jsonrpc" => "2.0", "id" => tool, "method" => "tools/call", "params" => %{"name" => tool, "arguments" => %{}}},
          repo: repo,
          session: session
        )

      assert get_in(response, ["error", "code"]) == -32_601
    end)
  end
end
