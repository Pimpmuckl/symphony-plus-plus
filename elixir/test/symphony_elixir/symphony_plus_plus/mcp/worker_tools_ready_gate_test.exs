Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerToolsReadyGateTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ReviewLanes

  test "mark_ready requires plan nodes when package-depth planning is meaningful", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-PACKAGE-PLAN", kind: "mcp", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-PACKAGE-PLAN/worker", "head_sha" => "abc126"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/126", "head_sha" => "abc126"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready except package plan",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc126",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
    assert "review_package_submitted" in get_in(missing_merge_evidence_response, ["error", "data", "missing"])

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
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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

  test "mark_ready follows linked planned-slice review lanes over package policy defaults", %{repo: repo} do
    work_request =
      create_work_request!(
        repo,
        id: "WR-BRIEF-READY-SLICE",
        status: "ready_for_slicing",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main"
      )

    assert {:ok, planned} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-BRIEF-READY-SLICE",
                 title: "Brief review readiness",
                 goal: "Keep readiness aligned with the planned slice review profile.",
                 work_package_kind: "mcp",
                 target_base_branch: "main",
                 branch_pattern: "agent/brief-ready-slice",
                 owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
                 acceptance_criteria: ["Brief review evidence is enough for this slice."],
                 validation_steps: ["mix test worker_tools_ready_gate_test.exs"],
                 review_lanes: ["brief"],
                 stop_conditions: ["Stop before broad lifecycle rewrites."]
               )
             )

    assert {:ok, approved} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned.id, "planned")

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-BRIEF-READY-SLICE",
                 kind: "mcp",
                 title: approved.title,
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "main",
                 branch_pattern: approved.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: approved.owned_file_globs,
                 acceptance_criteria: approved.acceptance_criteria,
                 status: "ci_waiting"
               )
             )

    assert {:ok, _linked} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved.id, "approved", package.id)

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/brief-ready-slice", "head_sha" => "brief-head"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/392", "head_sha" => "brief-head"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Brief review passed",
      "tests" => ["mix test worker_tools_ready_gate_test.exs"],
      "artifacts" => ["review-brief-log.txt"],
      "head_sha" => "brief-head",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "brief", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-brief-slice", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    refute Map.has_key?(get_in(ready_response, ["result", "structuredContent"]), "warnings")
  end

  test "planned-slice review lanes reject non Review Suite profiles", %{repo: repo} do
    work_request =
      create_work_request!(
        repo,
        id: "WR-GITHUB-READY-SLICE",
        status: "ready_for_slicing",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main"
      )

    assert {:error, changeset} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-GITHUB-READY-SLICE",
                 review_lanes: ["review_github"]
               )
             )

    assert {"must be one of: brief, normal, deep, emergency", _metadata} = Keyword.fetch!(changeset.errors, :review_lanes)
  end

  test "planned-slice review lanes ignore invalid legacy values", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-REDACTED-LANES", kind: "mcp", status: "ci_waiting")
             )

    {required_lanes, warnings} = ReviewLanes.required_from_planned_slice_lanes(package, ["brief", "raw_secret_review_lane"])

    assert required_lanes == ["brief"]
    assert warnings == []
  end

  test "empty planned-slice review lanes disable policy review defaults", %{repo: repo} do
    work_request =
      create_work_request!(
        repo,
        id: "WR-NO-REVIEW-LANES",
        status: "ready_for_slicing",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-NO-REVIEW-LANES",
                 review_lanes: []
               )
             )

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-NO-REVIEW-LANES", kind: "mcp", status: "ci_waiting")
             )

    repo.query!(
      "UPDATE sympp_work_request_planned_slices SET work_package_id = ? WHERE id = ?",
      [package.id, planned_slice.id]
    )

    assert {:ok, {[], []}} = ReviewLanes.required(repo, package)
  end

  test "review lane resolver falls back to policy without repo context", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-NIL-REPO-LANES", kind: "mcp", status: "ci_waiting")
             )

    assert {:ok, {["normal"], []}} = ReviewLanes.required(nil, package)
  end

  test "review lane resolver falls back to policy for duplicate linked planned slices", %{repo: repo} do
    work_request =
      create_work_request!(
        repo,
        id: "WR-DUPLICATE-REVIEW-LANES",
        status: "ready_for_slicing",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main"
      )

    assert {:ok, brief_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(id: "WRS-DUPLICATE-REVIEW-LANES-A", review_lanes: ["brief"])
             )

    assert {:ok, normal_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(id: "WRS-DUPLICATE-REVIEW-LANES-B", review_lanes: ["normal"])
             )

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DUPLICATE-REVIEW-LANES", kind: "mcp", status: "ci_waiting")
             )

    drop_planned_slice_work_package_unique_index!(repo)

    try do
      repo.query!(
        "UPDATE sympp_work_request_planned_slices SET work_package_id = ? WHERE id IN (?, ?)",
        [package.id, brief_slice.id, normal_slice.id]
      )

      assert {:ok, {["normal"], []}} = ReviewLanes.required(repo, package)
    after
      repo.query!(
        "UPDATE sympp_work_request_planned_slices SET work_package_id = NULL WHERE id IN (?, ?)",
        [brief_slice.id, normal_slice.id]
      )

      create_planned_slice_work_package_unique_index!(repo)
    end
  end

  test "mark_ready ignores invalid legacy planned-slice review lanes", %{repo: repo} do
    work_request =
      create_work_request!(
        repo,
        id: "WR-SECRET-LANE-FAILURE",
        status: "ready_for_slicing",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main"
      )

    assert {:ok, planned} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-SECRET-LANE-FAILURE",
                 title: "Secret lane failure detail",
                 goal: "Keep failure details redacted.",
                 work_package_kind: "mcp",
                 target_base_branch: "main",
                 branch_pattern: "agent/secret-lane-failure",
                 owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
                 acceptance_criteria: ["Failure details do not leak lane values."],
                 validation_steps: ["mix test worker_tools_ready_gate_test.exs"],
                 review_lanes: ["brief"],
                 stop_conditions: ["Stop before broad lifecycle rewrites."]
               )
             )

    assert {:ok, approved} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned.id, "planned")

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SECRET-LANE-FAILURE",
                 kind: "mcp",
                 title: approved.title,
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "main",
                 branch_pattern: approved.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: approved.owned_file_globs,
                 acceptance_criteria: approved.acceptance_criteria,
                 status: "ci_waiting"
               )
             )

    assert {:ok, _linked} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved.id, "approved", package.id)

    repo.query!(
      "UPDATE sympp_work_request_planned_slices SET review_lanes = ? WHERE id = ?",
      [Jason.encode!(["brief", "raw_secret_review_lane"]), planned.id]
    )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/secret-lane-failure", "head_sha" => "secret-lane-head"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/393", "head_sha" => "secret-lane-head"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Brief review passed",
      "tests" => ["mix test worker_tools_ready_gate_test.exs"],
      "artifacts" => ["review-brief-log.txt"],
      "head_sha" => "secret-lane-head",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "brief", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "secret-lane-ready-fail", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    refute inspect(ready_response) =~ "raw_secret_review_lane"
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
    assert "review_lanes_complete" in missing

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
    assert "review_lanes_complete" in unrelated_missing

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed",
      "status" => "tests_passed",
      "idempotency_key" => "quick-fix-tests"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "brief review green",
      "status" => "review_brief_green",
      "idempotency_key" => "quick-fix-review-brief"
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
    assert "review_lanes_complete" in stale_progress_missing

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed for latest head",
      "status" => "tests_passed",
      "idempotency_key" => "quick-fix-tests-head-b"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "brief review green for latest head",
      "status" => "review_brief_green",
      "idempotency_key" => "quick-fix-review-brief-head-b"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests failed after latest pass",
      "status" => "tests_failed",
      "idempotency_key" => "quick-fix-tests-head-b-failed"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "brief review red after latest green",
      "status" => "review_brief_red",
      "idempotency_key" => "quick-fix-review-brief-head-b-red"
    })

    stale_green_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix-stale-green", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    stale_green_missing = get_in(stale_green_response, ["error", "data", "missing"])
    assert "tests_passed" in stale_green_missing
    assert "review_lanes_complete" in stale_green_missing

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed after failure",
      "status" => "tests_passed",
      "idempotency_key" => "quick-fix-tests-head-b-repassed"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "brief review green after red",
      "status" => "review_brief_green",
      "idempotency_key" => "quick-fix-review-brief-head-b-regreen"
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

  defp drop_planned_slice_work_package_unique_index!(repo) do
    repo.query!("DROP INDEX IF EXISTS sympp_work_request_planned_slices_work_package_id_unique_index")
  end

  defp create_planned_slice_work_package_unique_index!(repo) do
    repo.query!("""
    CREATE UNIQUE INDEX IF NOT EXISTS sympp_work_request_planned_slices_work_package_id_unique_index
    ON sympp_work_request_planned_slices (work_package_id)
    WHERE work_package_id IS NOT NULL
    """)
  end
end
