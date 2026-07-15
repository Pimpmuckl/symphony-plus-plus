Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerToolsReadyGateTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.ReviewRequirement

  test "mark_ready requires plan nodes when package-depth planning is meaningful", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-PACKAGE-PLAN", kind: "mcp", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    bypass_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "ready-bypass",
          "method" => "tools/call",
          "params" => %{
            "name" => "set_status",
            "arguments" => %{"expected_status" => "ci_waiting", "status" => "ready_for_merge"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(bypass_response, ["error", "data", "reason"]) == "use_mark_ready"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-PACKAGE-PLAN/worker", "head_sha" => "abc126"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/126", "head_sha" => "abc126"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready except package plan",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc126",
      "acceptance_criteria_met" => true
    })

    missing_plan_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing-package-plan", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "plan_complete" in get_in(missing_plan_response, ["error", "data", "missing"])

    append_done_plan(repo, package.id)

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-package-plan", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "mark_ready rejects empty review packages and allows resolved blockers", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-BLOCKER", kind: "standard_pr", status: "ci_waiting")
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_merge_evidence_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "missing-merge-evidence", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "pr_attached" in get_in(missing_merge_evidence_response, ["error", "data", "missing"])
    assert "tests_passed" in get_in(missing_merge_evidence_response, ["error", "data", "missing"])

    empty_review_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "empty-review", "method" => "tools/call", "params" => %{"name" => "submit_review_package", "arguments" => %{}}},
        repo: repo,
        session: session
      )

    assert get_in(empty_review_response, ["error", "data", "reason"]) == "missing_summary"

    invalid_blocker_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-blocker",
          "method" => "tools/call",
          "params" => %{
            "name" => "report_blocker",
            "arguments" => %{"summary" => "Invalid blocker", "idempotency_key" => "invalid-blocker", "blocker_id" => 1}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_blocker_response, ["error", "data", "reason"]) == "invalid_blocker_id"

    attach_tool(repo, session, "append_progress", %{"summary" => "Progress with shared retry key", "idempotency_key" => "blocker-1"})

    blocker_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "blocker",
          "method" => "tools/call",
          "params" => %{
            "name" => "report_blocker",
            "arguments" => %{"summary" => "Temporarily blocked", "idempotency_key" => "blocker-1", "blocker_id" => "blocker-1 "}
          }
        },
        repo: repo,
        session: session
      )

    blocker_payload = response_progress_payload(repo, blocker_response)
    assert blocker_payload["active"] == true
    assert blocker_payload["blocker_id"] == "blocker-1"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-BLOCKER/worker", "head_sha" => "abc125"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/125", "head_sha" => "abc125"})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/125", "abc125")

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc125",
      "acceptance_criteria_met" => true
    })

    blocked_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-blocked", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(blocked_response, ["error", "data", "reason_code"]) == "blocker_closeout_required"
    package_id = package.id
    assert [%{"blocker_id" => "blocker-1", "work_package_id" => ^package_id}] = get_in(blocked_response, ["error", "data", "active_blockers"])

    still_blocked_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "ready-still-blocked",
          "method" => "tools/call",
          "params" => %{
            "name" => "mark_ready",
            "arguments" => %{"blocker_closeout" => %{"decision" => "still_active", "blocker_ids" => ["blocker-1"]}}
          }
        },
        repo: repo,
        session: session
      )

    assert "no_active_blockers" in get_in(still_blocked_response, ["error", "data", "missing"])
    assert Enum.any?(get_in(still_blocked_response, ["error", "data", "reasons"]), &(&1["gate"] == "no_active_blockers"))

    resolved_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "resolve",
          "method" => "tools/call",
          "params" => %{
            "name" => "resolve_blocker",
            "arguments" => %{"blocker_id" => "blocker-1", "resolution" => "Unblocked", "summary" => "Resolved", "idempotency_key" => "resolve-1"}
          }
        },
        repo: repo,
        session: session
      )

    assert response_progress_payload(repo, resolved_response)["active"] == false

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-resolved", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "complete_review satisfies only the configured provider requirement at the current exact head", %{repo: repo} do
    review = %{
      "type" => "human",
      "args" => %{"team" => "maintainers", "context" => String.duplicate("x", 5_000)}
    }

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-GENERIC-REVIEW",
                 kind: "mcp",
                 status: "ci_waiting",
                 review_requirement: review
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    pr_url = "https://github.com/example/repo/pull/392"

    no_head =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "review-no-head", "method" => "tools/call", "params" => %{"name" => "complete_review"}},
        repo: repo,
        session: session
      )

    assert get_in(no_head, ["error", "data", "reason"]) == "review_current_head_missing"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/generic-review", "head_sha" => "review-head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => pr_url, "head_sha" => "review-head-a"})
    sync_pr_state(repo, session, pr_url, "review-head-a")

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Validation passed",
      "tests" => ["mix test worker_tools_ready_gate_test.exs"],
      "artifacts" => ["validation-log.txt"],
      "head_sha" => "review-head-a",
      "acceptance_criteria_met" => true
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Spoofed review completion",
      "idempotency_key" => "spoofed-review-completion",
      "payload" => %{"type" => "review_completion", "source_tool" => "complete_review", "review" => review, "head_sha" => "review-head-a"}
    })

    missing_review = mark_ready(repo, session, "ready-missing-review")
    assert "review_complete" in get_in(missing_review, ["error", "data", "missing"])

    completion =
      attach_tool(repo, session, "complete_review", %{
        "reference" => "human-review-42",
        "note" => "Maintainers approved the exact head."
      })

    completion_payload = response_progress_payload(repo, completion)
    assert completion_payload["type"] == "review_completion"
    assert completion_payload["source_tool"] == "complete_review"
    assert completion_payload["work_package_id"] == package.id
    assert completion_payload["head_sha"] == "review-head-a"
    assert completion_payload["reference"] == "human-review-42"
    assert completion_payload["note"] == "Maintainers approved the exact head."
    assert completion_payload["review_fingerprint"] == ReviewRequirement.fingerprint(review)
    assert String.ends_with?(get_in(completion_payload, ["review", "args", "context"]), "[truncated]")

    replay =
      attach_tool(repo, session, "complete_review", %{
        "reference" => "human-review-42",
        "note" => "Maintainers approved the exact head."
      })

    assert get_in(replay, ["result", "structuredContent", "progress_event", "id"]) ==
             get_in(completion, ["result", "structuredContent", "progress_event", "id"])

    changed_review = %{"type" => "automated", "args" => %{"policy" => "internal"}}
    package |> Ecto.Changeset.change(review_requirement: changed_review) |> repo.update!()
    requirement_changed = mark_ready(repo, session, "ready-changed-requirement")
    assert "review_complete" in get_in(requirement_changed, ["error", "data", "missing"])

    assert {:ok, package} = WorkPackageRepository.get(repo, package.id)
    package |> Ecto.Changeset.change(review_requirement: review) |> repo.update!()

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/generic-review", "head_sha" => "review-head-b"})
    attach_tool(repo, session, "attach_pr", %{"url" => pr_url, "head_sha" => "review-head-b"})
    sync_pr_state(repo, session, pr_url, "review-head-b")

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Validation passed at new head",
      "tests" => ["mix test worker_tools_ready_gate_test.exs"],
      "artifacts" => ["validation-log.txt"],
      "head_sha" => "review-head-b",
      "acceptance_criteria_met" => true
    })

    stale_review = mark_ready(repo, session, "ready-stale-review")
    assert "review_complete" in get_in(stale_review, ["error", "data", "missing"])

    attach_tool(repo, session, "complete_review", %{})
    ready = mark_ready(repo, session, "ready-current-review")
    assert get_in(ready, ["result", "structuredContent", "ready"]) == true
  end

  test "mark_ready does not require review-package metadata for non-merge-gated policies", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-QUICK-FIX", kind: "quick_fix", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(response, ["error", "data", "missing"])
    assert get_in(response, ["error", "data", "reason"]) == "readiness_failed"
    refute "plan_complete" in missing
    refute "branch_attached" in missing
    refute "pr_attached" in missing
    refute "review_package_submitted" in missing
    assert "tests_passed" in missing

    attach_tool(repo, session, "request_scope_expansion", %{
      "summary" => "Unrelated scope request",
      "status" => "tests_passed",
      "payload" => %{"lane" => "brief", "verdict" => "green"},
      "idempotency_key" => "quick-fix-unrelated-status"
    })

    unrelated_status_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix-unrelated-status", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    unrelated_missing = get_in(unrelated_status_response, ["error", "data", "missing"])
    assert "tests_passed" in unrelated_missing

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed",
      "status" => "tests_passed",
      "idempotency_key" => "quick-fix-tests"
    })

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-QUICK-FIX/worker", "head_sha" => "quick-fix-head-b"})

    stale_progress_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix-stale-progress", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    stale_progress_missing = get_in(stale_progress_response, ["error", "data", "missing"])
    assert "tests_passed" in stale_progress_missing

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed for latest head",
      "status" => "tests_passed",
      "idempotency_key" => "quick-fix-tests-head-b"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests failed after latest pass",
      "status" => "tests_failed",
      "idempotency_key" => "quick-fix-tests-head-b-failed"
    })

    stale_green_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix-stale-green", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    stale_green_missing = get_in(stale_green_response, ["error", "data", "missing"])
    assert "tests_passed" in stale_green_missing

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed after failure",
      "status" => "tests_passed",
      "idempotency_key" => "quick-fix-tests-head-b-repassed"
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix-after-progress", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"
  end

  test "legacy stored merge-ready status can still transition to merged", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-LEGACY-STATUS", kind: "mcp", status: "ready_for_merge")
             )

    repo.update_all(from(work_package in WorkPackage, where: work_package.id == ^package.id), set: [status: "ready_for_human_merge"])

    assert {:ok, updated} = WorkPackageRepository.update_status(repo, package.id, "ready_for_human_merge", "merged")
    assert updated.status == "merged"
  end

  test "ready evidence guard reads only the package with 1,000 history rows", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-GUARD-BOUNDED", kind: "mcp", status: "ready_for_worker")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    assert {1, nil} =
             repo.update_all(
               from(work_package in WorkPackage, where: work_package.id == ^package.id),
               set: [status: "ready_for_merge"]
             )

    now = DateTime.utc_now(:microsecond)

    rows =
      for sequence <- 1..1_000 do
        %{
          id: "progress-ready-guard-#{sequence}",
          work_package_id: package.id,
          summary: "Historical progress #{sequence}",
          status: "recorded",
          sequence: sequence,
          idempotency_scope: "direct",
          payload: %{},
          created_at: now,
          inserted_at: now,
          updated_at: now
        }
      end

    assert {1_000, nil} = repo.insert_all(ProgressEvent, rows)

    {response, queries} =
      capture_queries(repo, fn ->
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "ready-guard-bounded",
            "method" => "tools/call",
            "params" => %{
              "name" => "append_progress",
              "arguments" => %{"summary" => "Must remain rejected", "idempotency_key" => "ready-guard-bounded"}
            }
          },
          repo: repo,
          session: session
        )
      end)

    assert get_in(response, ["error", "data", "reason"]) == "already_ready"

    lock_index =
      Enum.find_index(queries, fn query ->
        String.starts_with?(query, "UPDATE \"sympp_work_packages\"") and String.contains?(query, "SET \"id\"")
      end)

    assert is_integer(lock_index)
    guard_queries = Enum.drop(queries, lock_index + 1)

    assert Enum.count(guard_queries, &String.contains?(&1, "FROM \"sympp_work_packages\"")) == 1
    refute Enum.any?(guard_queries, &String.contains?(&1, "FROM \"sympp_progress_events\""))
  end

  defp mark_ready(repo, session, id) do
    MCPHarness.request(
      %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
      repo: repo,
      session: session
    )
  end

  defp capture_queries(repo, fun) do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    event = repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, test_pid -> send(test_pid, {handler_id, metadata.query}) end,
        self()
      )

    try do
      result = fun.()
      {result, drain_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, queries) do
    receive do
      {^handler_id, query} -> drain_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
