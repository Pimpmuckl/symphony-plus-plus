Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools05Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "attach_pr alone satisfies pr_attached for policies without current PR state", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-ATTACH-READY", kind: "mcp", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-ATTACH-READY/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-a"})

    attach_only_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-attach-only", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(attach_only_response, ["result", "structuredContent", "ready"]) == true
  end

  test "legacy attached PR URL still satisfies pr_attached evidence", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-LEGACY-URL-READY", kind: "mcp", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/#{package.id}", "head_sha" => "legacy-head"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://git.example.com/org/repo/pulls/7", "head_sha" => "legacy-head"})

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-legacy-pr-url", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "legacy attach_pr metadata satisfies current PR state", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-LEGACY-STATE-READY",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_current_pr_state"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    head_sha = "legacy-state-head"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/#{package.id}", "head_sha" => head_sha})

    attach_tool(repo, session, "attach_pr", %{
      "url" => "https://git.example.com/org/repo/pulls/8",
      "head_sha" => head_sha,
      "metadata" => %{
        "check_summary" => %{"conclusion" => "success"},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      }
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-legacy-pr-state", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "current PR state policy fails missing, invalid, and stale sync state", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-SYNC-READY",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_current_pr_state"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-SYNC-READY/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-a"})

    missing_state_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing-state", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(missing_state_response, ["error", "data", "missing"])
    refute "pr_attached" in missing
    assert "current_pr_state" in missing

    invalid_recovery =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-recovery-state",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{
              "recovery" => %{
                "url" => "https://github.com/example/repo/pull/790",
                "head_sha" => "head-a",
                "check_summary" => %{"status" => "green"}
              }
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_recovery, ["error", "data", "reason"]) == "invalid_recovery"

    invalid_sync_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-invalid-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "current_pr_state" in get_in(invalid_sync_response, ["error", "data", "missing"])

    inconsistent_recovery =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "inconsistent-recovery-state",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{
              "recovery" => %{
                "url" => "https://github.com/example/repo/pull/790",
                "head_sha" => "head-a",
                "merge_state" => %{"status" => "clean", "merged" => true}
              }
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(inconsistent_recovery, ["error", "data", "reason"]) == "invalid_recovery"

    raw_state_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-raw-state-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "current_pr_state" in get_in(raw_state_response, ["error", "data", "missing"])

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-SYNC-READY/worker", "head_sha" => "head-b"})

    stale_sync_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-stale-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "current_pr_state" in get_in(stale_sync_response, ["error", "data", "missing"])

    sync_pr_state(repo, session, "https://github.com/example/repo/pull/790", "head-b")

    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-b"})

    reattach_after_sync_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-reattach-after-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "current_pr_state" in get_in(reattach_after_sync_response, ["error", "data", "missing"])

    attach_tool(repo, session, "sync_pr", %{
      "recovery" => %{
        "url" => "https://github.com/example/repo/pull/790",
        "head_sha" => "head-b",
        "check_summary" => %{"status" => "passing"},
        "review_state" => %{"status" => "approved"},
        "merge_state" => %{"status" => "clean", "merged" => false}
      }
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-synced-pr", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "current PR state accepts canonical recovery state", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-BOOLEAN-SYNC-READY",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_current_pr_state"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-BOOLEAN-SYNC-READY/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-a"})

    attach_tool(repo, session, "sync_pr", %{
      "recovery" => %{
        "url" => "https://github.com/example/repo/pull/790",
        "head_sha" => "head-a",
        "check_summary" => %{"status" => "passing"},
        "review_state" => %{"status" => "approved"},
        "merge_state" => %{"status" => "clean", "merged" => false}
      }
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-boolean-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "sync_pr refresh for current head satisfies PR attachment evidence", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-SYNC-HEAD-READY",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_current_pr_state"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-SYNC-HEAD-READY/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-SYNC-HEAD-READY/worker", "head_sha" => "head-b"})

    attach_tool(repo, session, "sync_pr", %{
      "recovery" => %{
        "url" => "https://github.com/example/repo/pull/790",
        "head_sha" => "head-b",
        "check_summary" => %{"status" => "passing"},
        "review_state" => %{"status" => "approved"},
        "merge_state" => %{"status" => "clean", "merged" => false}
      }
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-sync-head", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "attach_pr with full current state satisfies current PR readiness", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-ATTACH-STATE-READY",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_current_pr_state"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-ATTACH-STATE-READY/worker", "head_sha" => "head-a"})

    attach_tool(repo, session, "attach_pr", %{
      "url" => "https://github.com/example/repo/pull/790",
      "metadata" => %{
        "head_sha" => "head-a",
        "check_summary" => %{"conclusion" => "success"},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      }
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-attach-state", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "abbreviated branch head satisfies full PR head readiness", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PR-SHORT-HEAD-READY", kind: "mcp", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{
      "branch" => "agent/SYMPP-PR-SHORT-HEAD-READY/worker",
      "head_sha" => "abcdef1"
    })

    attach_tool(repo, session, "attach_pr", %{
      "url" => "https://github.com/example/repo/pull/790",
      "head_sha" => "abcdef1234567890abcdef1234567890abcdef12"
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-short-head", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "overly short branch head does not satisfy full PR head readiness", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PR-TINY-HEAD-READY", kind: "mcp", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-TINY-HEAD-READY/worker", "head_sha" => "abc"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "abcdef1234567890abcdef1234567890abcdef12"})

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-tiny-head", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "pr_attached" in get_in(ready_response, ["error", "data", "missing"])
  end
end
