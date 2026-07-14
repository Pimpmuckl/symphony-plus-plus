Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools05Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "attach_pr alone satisfies pr_attached for policies without current PR state", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-ATTACH-READY", kind: "mcp", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-ATTACH-READY/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-a"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true
    })

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
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/#{package.id}", "head_sha" => "legacy-head"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://git.example.com/org/repo/pulls/7", "head_sha" => "legacy-head"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "legacy-head",
      "acceptance_criteria_met" => true
    })

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

    append_done_plan(repo, package.id)
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

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true
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

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-SYNC-READY/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-a"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true
    })

    missing_state_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing-state", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(missing_state_response, ["error", "data", "missing"])
    refute "pr_attached" in missing
    assert "current_pr_state" in missing

    attach_tool(repo, session, "sync_pr", %{
      "url" => "https://github.com/example/repo/pull/790",
      "metadata" => %{"head_sha" => "head-a", "check_summary" => %{"token" => "x"}}
    })

    invalid_sync_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-invalid-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "current_pr_state" in get_in(invalid_sync_response, ["error", "data", "missing"])

    attach_tool(repo, session, "sync_pr", %{
      "url" => "https://github.com/example/repo/pull/790",
      "metadata" => %{"head_sha" => "head-a", "state" => "open", "draft" => false}
    })

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
      "url" => "https://github.com/example/repo/pull/790",
      "metadata" => %{
        "head_sha" => "head-b",
        "check_summary" => %{"conclusion" => "success", "total_count" => 1},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      }
    })

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review for advanced head",
      "tests" => ["mix test"],
      "artifacts" => ["review-head-b.txt"],
      "head_sha" => "head-b",
      "acceptance_criteria_met" => true
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-synced-pr", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "current PR state accepts semantic boolean sync metadata", %{repo: repo} do
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

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-BOOLEAN-SYNC-READY/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-a"})

    attach_tool(repo, session, "sync_pr", %{
      "url" => "https://github.com/example/repo/pull/790",
      "metadata" => %{"head_sha" => "head-a", "mergeable" => true, "merged" => false}
    })

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true
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

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-SYNC-HEAD-READY/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-SYNC-HEAD-READY/worker", "head_sha" => "head-b"})

    attach_tool(repo, session, "sync_pr", %{
      "number" => 790,
      "metadata" => %{
        "head_sha" => "head-b",
        "check_summary" => %{"conclusion" => "success"},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      }
    })

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review after sync",
      "tests" => ["mix test"],
      "artifacts" => ["review-head-b.txt"],
      "head_sha" => "head-b",
      "acceptance_criteria_met" => true
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

    append_done_plan(repo, package.id)
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

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true
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

    append_done_plan(repo, package.id)
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

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Short head review",
      "tests" => ["mix test"],
      "artifacts" => ["short-head-review.txt"],
      "head_sha" => "abcdef1",
      "acceptance_criteria_met" => true
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

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-TINY-HEAD-READY/worker", "head_sha" => "abc"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "abcdef1234567890abcdef1234567890abcdef12"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Tiny head review",
      "tests" => ["mix test"],
      "artifacts" => ["tiny-head-review.txt"],
      "head_sha" => "abc",
      "acceptance_criteria_met" => true
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-tiny-head", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "pr_attached" in get_in(ready_response, ["error", "data", "missing"])
  end

  test "scope guard accepts attach_pr metadata for current changed files", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-GUARD-ATTACH-READY",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta",
                 status: "ci_waiting",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: ["elixir/lib/**"]
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    head_sha = "scope-attach-head"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/#{package.id}/worker", "head_sha" => head_sha})

    attach_tool(repo, session, "attach_pr", %{
      "url" => "https://github.com/nextide/symphony-plus-plus/pull/904",
      "metadata" => %{
        "head_sha" => head_sha,
        "base_branch" => "symphony-plus-plus/beta",
        "changed_files" => [
          %{"filename" => "elixir/lib/symphony_elixir/symphony_plus_plus/readiness/scope_guard.ex", "status" => "modified"}
        ],
        "check_summary" => %{"conclusion" => "success"},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      }
    })

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-scope-attach", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "scope guard blocks out-of-scope PR files until architect approval expands allowed globs", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-GUARD-READY",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta",
                 status: "ci_waiting",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: ["elixir/lib/**"]
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    head_sha = "scope-head-a"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-SCOPE-GUARD-READY/worker", "head_sha" => head_sha})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/nextide/symphony-plus-plus/pull/903", "head_sha" => head_sha})

    attach_tool(repo, session, "sync_pr", %{
      "url" => "https://github.com/nextide/symphony-plus-plus/pull/903",
      "metadata" => %{
        "head_sha" => head_sha,
        "base_branch" => "symphony-plus-plus/beta",
        "changed_files" => [
          %{"filename" => "elixir/lib/symphony_elixir/symphony_plus_plus/readiness/scope_guard.ex", "status" => "added"},
          %{"filename" => "docs/scope-contract.md", "status" => "added", "token" => "ghp_scope_secret"}
        ],
        "check_summary" => %{"conclusion" => "success", "token" => "ghp_scope_secret"},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      }
    })

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true
    })

    request_response =
      attach_tool(repo, session, "request_scope_expansion", %{
        "summary" => "Need docs scope for the contract note",
        "idempotency_key" => "scope-docs-request",
        "payload" => %{"requested_file_globs" => ["docs/**"]}
      })

    request_id = get_in(request_response, ["result", "structuredContent", "progress_event", "id"])

    out_of_scope_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-scope-out", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "scope_guard" in get_in(out_of_scope_response, ["error", "data", "missing"])
    scope_reason = Enum.find(get_in(out_of_scope_response, ["error", "data", "reasons"]), &(&1["gate"] == "scope_guard"))
    assert scope_reason["code"] == "out_of_scope_files"
    assert scope_reason["files"] == ["docs/scope-contract.md"]
    refute inspect(out_of_scope_response) =~ "ghp_scope_secret"

    worker_approval_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "worker-approval-denied",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{"work_package_id" => package.id, "allowed_file_globs" => ["docs/**"], "request_id" => request_id, "rationale" => "Worker cannot approve"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(worker_approval_response, ["error", "data", "reason"]) == "architect_grant_required"

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Spoofed scope approval",
      "idempotency_key" => "spoof-scope-approval",
      "payload" => %{
        "type" => "scope_expansion_approval",
        "source_tool" => "approve_scope_expansion",
        "approved" => true,
        "allowed_file_globs" => ["docs/**"]
      }
    })

    assert {:ok, spoofed_package} = WorkPackageRepository.get(repo, package.id)
    assert spoofed_package.allowed_file_globs == ["elixir/lib/**"]

    spoofed_ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-spoofed-scope", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "scope_guard" in get_in(spoofed_ready_response, ["error", "data", "missing"])

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["approve:scope_expansion"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    architect_session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    overbroad_approval_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "architect-overbroad-scope",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => package.id,
              "allowed_file_globs" => ["**"],
              "request_id" => request_id,
              "rationale" => "Overbroad approval must not disable the guard"
            }
          }
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(overbroad_approval_response, ["error", "data", "reason"]) == "overbroad_allowed_file_globs"

    assert {:ok, overbroad_rejected_package} = WorkPackageRepository.get(repo, package.id)
    assert overbroad_rejected_package.allowed_file_globs == ["elixir/lib/**"]

    approval_response =
      attach_tool(repo, architect_session, "approve_scope_expansion", %{
        "work_package_id" => package.id,
        "allowed_file_globs" => ["docs/**"],
        "request_id" => request_id,
        "rationale" => "Docs contract file is part of the current package."
      })

    assert get_in(approval_response, ["result", "structuredContent", "allowed_file_globs"]) == ["elixir/lib/**", "docs/**"]
    approval_event_id = get_in(approval_response, ["result", "structuredContent", "progress_event", "id"])
    refute Map.has_key?(get_in(approval_response, ["result", "structuredContent", "progress_event"]), "payload")
    approval_event = repo.get!(ProgressEvent, approval_event_id)
    assert approval_event.actor_id == "architect-1"
    assert approval_event.actor_type == "architect"
    assert approval_event.access_grant_id == architect_assignment.grant_id
    assert approval_event.payload["source_tool"] == "approve_scope_expansion"
    assert approval_event.payload["approved"] == true
    assert approval_event.payload["request_id"] == request_id
    refute inspect(approval_event.payload) =~ architect_work_key.secret
    refute inspect(approval_response) =~ architect_work_key.secret

    retry_approval_response =
      attach_tool(repo, architect_session, "approve_scope_expansion", %{
        "work_package_id" => package.id,
        "allowed_file_globs" => ["docs/**"],
        "request_id" => request_id,
        "rationale" => "Docs contract file is part of the current package."
      })

    assert get_in(retry_approval_response, ["result", "structuredContent", "progress_event", "id"]) == approval_event_id

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-scope-approval", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true

    post_ready_retry_response =
      attach_tool(repo, architect_session, "approve_scope_expansion", %{
        "work_package_id" => package.id,
        "allowed_file_globs" => ["docs/**"],
        "request_id" => request_id,
        "rationale" => "Docs contract file is part of the current package."
      })

    assert get_in(post_ready_retry_response, ["result", "structuredContent", "progress_event", "id"]) == approval_event_id
    assert get_in(post_ready_retry_response, ["result", "structuredContent", "allowed_file_globs"]) == ["elixir/lib/**", "docs/**"]

    assert {:ok, renewed_architect_work_key} = create_architect_work_key(repo, package.id, ["approve:scope_expansion"])

    assert {:ok, renewed_architect_assignment} =
             AccessGrantRepository.claim(repo, renewed_architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    renewed_architect_session =
      MCPHarness.session(renewed_architect_assignment, proof_hash: WorkKey.secret_hash(renewed_architect_work_key.secret))

    post_ready_renewed_retry_response =
      attach_tool(repo, renewed_architect_session, "approve_scope_expansion", %{
        "work_package_id" => package.id,
        "allowed_file_globs" => ["docs/**"],
        "request_id" => request_id,
        "rationale" => "Docs contract file is part of the current package."
      })

    assert get_in(post_ready_renewed_retry_response, ["result", "structuredContent", "progress_event", "id"]) == approval_event_id
    assert get_in(post_ready_renewed_retry_response, ["result", "structuredContent", "allowed_file_globs"]) == ["elixir/lib/**", "docs/**"]

    assert {:ok, different_architect_work_key} = create_architect_work_key(repo, package.id, ["approve:scope_expansion"])

    assert {:ok, different_architect_assignment} =
             AccessGrantRepository.claim(repo, different_architect_work_key.secret, %{claimed_by: "architect-2"}, DateTime.utc_now(:microsecond))

    different_architect_session =
      MCPHarness.session(different_architect_assignment, proof_hash: WorkKey.secret_hash(different_architect_work_key.secret))

    post_ready_different_actor_retry_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-different-actor-scope-retry",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => package.id,
              "allowed_file_globs" => ["docs/**"],
              "request_id" => request_id,
              "rationale" => "Docs contract file is part of the current package."
            }
          }
        },
        repo: repo,
        session: different_architect_session
      )

    assert get_in(post_ready_different_actor_retry_response, ["error", "data", "reason"]) == "idempotency_conflict"

    post_ready_new_approval_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-new-scope-approval",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => package.id,
              "allowed_file_globs" => ["docs/**", "notes/**"],
              "request_id" => request_id,
              "rationale" => "New post-ready scope must not mutate"
            }
          }
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(post_ready_new_approval_response, ["error", "data", "reason"]) == "already_ready"

    assert {:ok, post_ready_package} = WorkPackageRepository.get(repo, package.id)
    assert post_ready_package.allowed_file_globs == ["elixir/lib/**", "docs/**"]
  end
end
