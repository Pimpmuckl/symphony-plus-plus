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

  test "non-merge readiness accepts branchless validation packages when branch metadata is not required", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BRANCHLESS-REVIEW", kind: "quick_fix", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    response =
      attach_tool(repo, session, "submit_review_package", %{
        "summary" => "Branchless quick-fix review",
        "tests" => ["mix test"],
        "artifacts" => ["branchless-review.txt"]
      })

    refute Map.has_key?(response_progress_payload(repo, response), "head_sha")
    assert get_in(response, ["result", "structuredContent", "remaining_readiness_gates"]) == []

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-branchless-review", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
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

  test "review package head policy covers no-PR, PR, and review-required work", %{repo: repo} do
    cases = [
      {"quick_fix", nil, false},
      {"docs", nil, false},
      {"investigation", nil, false},
      {"standard_pr", nil, true},
      {"mcp", nil, true},
      {"hotfix", nil, true},
      {"quick_fix", %{"type" => "human"}, true}
    ]

    for {kind, review_requirement, head_required?} <- cases do
      id = "SYMPP-HEAD-POLICY-#{kind}-#{if review_requirement, do: "review", else: "plain"}"

      assert {:ok, package} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(id: id, kind: kind, review_requirement: review_requirement)
               )

      assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
      assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: id)
      session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

      response =
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => id,
            "method" => "tools/call",
            "params" => %{
              "name" => "submit_review_package",
              "arguments" => %{"summary" => "Policy matrix", "tests" => ["mix test"], "artifacts" => ["policy-matrix.txt"]}
            }
          },
          repo: repo,
          session: session
        )

      if head_required? do
        assert get_in(response, ["error", "data", "reason"]) == "missing_current_head_sha"
      else
        assert get_in(response, ["result", "structuredContent", "progress_event", "id"])
      end
    end

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-HEAD-POLICY-UNBOUND", kind: "quick_fix")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: package.id)
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => package.id,
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Unbound head",
              "tests" => ["mix test"],
              "artifacts" => ["policy-matrix.txt"],
              "head_sha" => "not-an-attached-head"
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "data", "reason"]) == "unbound_head_sha"
  end

  test "non-investigation scope requests do not emit recommendation artifact references", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-HOTFIX-SCOPE-REQUEST", kind: "hotfix"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "request_scope_expansion", %{
      "summary" => "Need extra file",
      "body" => "Worker recommends expanding allowed files.",
      "idempotency_key" => "hotfix-scope-request",
      "payload" => %{
        "requested_file_globs" => ["lib/other/**"],
        "source_tool" => "caller"
      }
    })

    assert {:ok, [event]} = PlanningRepository.list_progress_events(repo, package.id)
    assert event.payload["type"] == "scope_expansion_request"
    assert event.payload["source_tool"] == "request_scope_expansion"
    assert event.payload["requested_file_globs"] == ["lib/other/**"]
    assert {:ok, []} = PlanningRepository.list_artifacts(repo, package.id)
  end

  test "request_scope_expansion without a session returns an auth error", %{repo: repo} do
    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "scope-without-session",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_scope_expansion",
            "arguments" => %{"summary" => "Need more scope", "idempotency_key" => "missing-session-scope"}
          }
        },
        repo: repo
      )

    assert get_in(response, ["error", "data", "reason"]) == "claim_required"
  end

  test "mark_ready rejects spoofed provider metadata", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-SPOOF", kind: "mcp", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    Enum.each(["branch", "pr", "review_package"], fn type ->
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
