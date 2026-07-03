Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.PhaseArchitectTools04Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "phase architect approval replay survives grant renewal after child blocks", %{repo: repo} do
    architect_capabilities = [
      "create:child_work_package",
      "mint:child_worker_key",
      "read:child_progress",
      "read:child_findings",
      "read:phase",
      "approve:child_ready_state"
    ]

    {anchor, architect_session} = create_architect_session(repo, "SYMPP-P7-003-APPROVAL-REPLAY-ANCHOR", architect_capabilities)

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-003-APPROVAL-REPLAY-CHILD")
    worker_session = claim_phase_child_worker(repo, architect_session, child_id)
    advance_child_worker_to_ci_waiting(repo, worker_session)
    attach_phase_child_ready_evidence(repo, worker_session, child_id, "p7-003-approval-replay-head")

    assert get_in(mcp_tool(repo, worker_session, "mark_ready", %{}), ["result", "structuredContent", "ready"]) == true

    approval_response =
      mcp_tool(repo, architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Ready before downstream merge blocker",
        "request_id" => "p7-003-approval-before-blocker"
      })

    assert get_in(approval_response, ["result", "structuredContent", "work_package", "status"]) == "merging_into_phase"

    block_response =
      mcp_tool(repo, worker_session, "set_status", %{
        "status" => "blocked",
        "expected_status" => "merging_into_phase",
        "reason" => "phase merge is blocked by a conflict"
      })

    assert get_in(block_response, ["result", "structuredContent", "work_package", "status"]) == "blocked"

    blocker_response =
      mcp_tool(repo, worker_session, "report_blocker", %{
        "summary" => "Phase merge conflict",
        "body" => "Architect approval happened, but the child needs worker follow-up before merge.",
        "idempotency_key" => "p7-003-post-approval-blocker"
      })

    blocker_payload = response_progress_payload(repo, blocker_response)
    assert blocker_payload["active"] == true

    renewed_architect_session = renew_phase_architect_session(repo, anchor, architect_capabilities)

    approval_replay_response =
      mcp_tool(repo, renewed_architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Ready before downstream merge blocker",
        "request_id" => "p7-003-approval-before-blocker"
      })

    assert get_in(approval_replay_response, ["result", "structuredContent", "work_package", "status"]) == "blocked"

    assert get_in(approval_replay_response, ["result", "structuredContent", "approval", "id"]) ==
             get_in(approval_response, ["result", "structuredContent", "approval", "id"])

    blocker_id = blocker_payload["blocker_id"]

    resolve_response =
      mcp_tool(repo, worker_session, "resolve_blocker", %{
        "blocker_id" => blocker_id,
        "resolution" => "merge blocker resolved",
        "summary" => "Phase merge conflict resolved",
        "idempotency_key" => "p7-003-post-approval-blocker-resolved"
      })

    assert response_progress_payload(repo, resolve_response)["active"] == false

    [
      {"blocked", "implementing"},
      {"implementing", "reviewing"},
      {"reviewing", "ci_waiting"}
    ]
    |> Enum.each(fn {expected_status, status} ->
      response =
        mcp_tool(repo, worker_session, "set_status", %{
          "expected_status" => expected_status,
          "status" => status,
          "reason" => "rework phase child after merge blocker"
        })

      assert get_in(response, ["result", "structuredContent", "work_package", "status"]) == status
    end)

    attach_phase_child_ready_evidence(repo, worker_session, child_id, "p7-003-approval-replay-head-reworked")

    assert get_in(mcp_tool(repo, worker_session, "mark_ready", %{}), ["result", "structuredContent", "work_package", "status"]) ==
             "ready_for_architect_merge"

    reapproval_response =
      mcp_tool(repo, renewed_architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Ready before downstream merge blocker",
        "request_id" => "p7-003-approval-before-blocker"
      })

    assert get_in(reapproval_response, ["result", "structuredContent", "work_package", "status"]) == "merging_into_phase"

    refute get_in(reapproval_response, ["result", "structuredContent", "approval", "id"]) ==
             get_in(approval_response, ["result", "structuredContent", "approval", "id"])

    reapproval_replay_response =
      mcp_tool(repo, renewed_architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Edited retry after rework",
        "request_id" => "p7-003-approval-before-blocker"
      })

    assert get_in(reapproval_replay_response, ["result", "structuredContent", "approval", "id"]) ==
             get_in(reapproval_response, ["result", "structuredContent", "approval", "id"])

    original_approval = repo.get!(ProgressEvent, get_in(approval_response, ["result", "structuredContent", "approval", "id"]))
    reapproval = repo.get!(ProgressEvent, get_in(reapproval_response, ["result", "structuredContent", "approval", "id"]))

    refute reapproval.inserted_at == original_approval.inserted_at

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, child_id)

    assert 2 ==
             Enum.count(progress_events, fn event ->
               event.status == "child_ready_approved" and get_in(event.payload, ["request_id"]) == "p7-003-approval-before-blocker"
             end)

    [
      {"merging_into_phase", "blocked"},
      {"blocked", "implementing"},
      {"implementing", "reviewing"},
      {"reviewing", "ci_waiting"}
    ]
    |> Enum.each(fn {expected_status, status} ->
      response =
        mcp_tool(repo, worker_session, "set_status", %{
          "expected_status" => expected_status,
          "status" => status,
          "reason" => "rework phase child before a distinct approval request"
        })

      assert get_in(response, ["result", "structuredContent", "work_package", "status"]) == status
    end)

    attach_phase_child_ready_evidence(repo, worker_session, child_id, "p7-003-approval-replay-head-second-reworked")

    assert get_in(mcp_tool(repo, worker_session, "mark_ready", %{}), ["result", "structuredContent", "work_package", "status"]) ==
             "ready_for_architect_merge"

    distinct_reapproval_response =
      mcp_tool(repo, renewed_architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Ready after a second rework cycle",
        "request_id" => "p7-003-approval-after-second-rework"
      })

    assert get_in(distinct_reapproval_response, ["result", "structuredContent", "work_package", "status"]) == "merging_into_phase"

    stale_approval_replay_response =
      mcp_tool(repo, renewed_architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Stale retry from the previous ready cycle",
        "request_id" => "p7-003-approval-before-blocker"
      })

    assert get_in(stale_approval_replay_response, ["error", "code"]) == -32_602
    assert get_in(stale_approval_replay_response, ["error", "data", "reason"]) == "child_not_ready_for_architect"
  end

  test "phase architect cannot approve child readiness when gates are failed", %{repo: repo} do
    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-003-FAILED-GATES-ANCHOR", [
        "read:child_progress",
        "read:child_findings",
        "read:phase",
        "approve:child_ready_state"
      ])

    assert {:ok, child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-003-FAILED-GATES-CHILD",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: anchor.id,
                 repo: anchor.repo,
                 base_branch: anchor.base_branch,
                 allowed_file_globs: anchor.allowed_file_globs,
                 status: "ready_for_architect_merge"
               )
             )

    response =
      mcp_tool(repo, architect_session, "approve_child_ready_state", %{
        "work_package_id" => child.id,
        "rationale" => "should fail without evidence"
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "readiness_failed"
    assert "plan_complete" in get_in(response, ["error", "data", "missing"])
    assert "acceptance_criteria_met" in get_in(response, ["error", "data", "missing"])

    assert {:ok, unchanged_child} = WorkPackageRepository.get(repo, child.id)
    assert unchanged_child.status == "ready_for_architect_merge"
  end

  test "phase architect merge record validates merge artifact", %{repo: repo} do
    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-003-MERGE-ARTIFACT-ANCHOR", [
        "read:phase",
        "merge:child_into_phase"
      ])

    assert {:ok, child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-003-MERGE-ARTIFACT-CHILD",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: anchor.id,
                 repo: anchor.repo,
                 base_branch: anchor.base_branch,
                 allowed_file_globs: anchor.allowed_file_globs,
                 status: "merging_into_phase"
               )
             )

    missing_uri_response =
      mcp_tool(repo, architect_session, "merge_child_into_phase", %{
        "work_package_id" => child.id,
        "merge_artifact" => %{"status" => "merged_into_phase"}
      })

    assert get_in(missing_uri_response, ["error", "code"]) == -32_602
    assert get_in(missing_uri_response, ["error", "data", "reason"]) == "missing_merge_artifact_uri"

    invalid_status_response =
      mcp_tool(repo, architect_session, "merge_child_into_phase", %{
        "work_package_id" => child.id,
        "merge_artifact" => %{"status" => "merged", "uri" => "https://github.com/nextide/symphony-plus-plus/pull/7004"}
      })

    assert get_in(invalid_status_response, ["error", "code"]) == -32_602
    assert get_in(invalid_status_response, ["error", "data", "reason"]) == "invalid_merge_artifact_status"

    assert {:ok, unchanged_child} = WorkPackageRepository.get(repo, child.id)
    assert unchanged_child.status == "merging_into_phase"
  end

  test "phase architect cannot finalize child merge after phase closes", %{repo: repo} do
    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-003-MERGE-CLOSED-PHASE-ANCHOR", [
        "read:phase",
        "merge:child_into_phase"
      ])

    assert {:ok, child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-003-MERGE-CLOSED-PHASE-CHILD",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: anchor.id,
                 repo: anchor.repo,
                 base_branch: anchor.base_branch,
                 allowed_file_globs: anchor.allowed_file_globs,
                 status: "merging_into_phase"
               )
             )

    phase = repo.get!(Phase, @architect_phase_id)
    assert {:ok, _phase} = repo.update(Ecto.Changeset.change(phase, status: "closed"))

    response =
      mcp_tool(repo, architect_session, "merge_child_into_phase", %{
        "work_package_id" => child.id,
        "merge_artifact" => %{
          "status" => "merged_into_phase",
          "uri" => "https://github.com/nextide/symphony-plus-plus/pull/7005"
        }
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "phase_not_active"

    assert {:ok, unchanged_child} = WorkPackageRepository.get(repo, child.id)
    assert unchanged_child.status == "merging_into_phase"
  end

  test "phase architect cannot replay pending child merge after phase closes", %{repo: repo} do
    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-003-MERGE-CLOSED-REPLAY-ANCHOR", [
        "read:phase",
        "merge:child_into_phase"
      ])

    assert {:ok, child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-003-MERGE-CLOSED-REPLAY-CHILD",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: anchor.id,
                 repo: anchor.repo,
                 base_branch: anchor.base_branch,
                 allowed_file_globs: anchor.allowed_file_globs,
                 status: "merging_into_phase"
               )
             )

    merge_artifact = %{
      "status" => "merged_into_phase",
      "uri" => "https://github.com/nextide/symphony-plus-plus/pull/7006",
      "summary" => "Pending phase merge event"
    }

    assert {:ok, _event} = append_child_merge_progress_event(repo, architect_session, child.id, merge_artifact)

    phase = repo.get!(Phase, @architect_phase_id)
    assert {:ok, _phase} = repo.update(Ecto.Changeset.change(phase, status: "closed"))

    response =
      mcp_tool(repo, architect_session, "merge_child_into_phase", %{
        "work_package_id" => child.id,
        "merge_artifact" => merge_artifact
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "phase_not_active"

    assert {:ok, unchanged_child} = WorkPackageRepository.get(repo, child.id)
    assert unchanged_child.status == "merging_into_phase"
    assert repo.get_by(Artifact, work_package_id: child.id, kind: "phase_merge") == nil
  end

  test "read_phase_board validates required phase_id before dashboard access", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-STUB-ARGS", kind: "mcp"))
    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["read:phase"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "phase-board-missing-args",
          "method" => "tools/call",
          "params" => %{"name" => "read_phase_board", "arguments" => %{}}
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "missing_phase_id"
  end

  test "remaining Phase 7 architect stubs return explicit not-yet-implemented errors", %{repo: repo} do
    {_package, session} =
      create_architect_session(repo, "SYMPP-ARCHITECT-PHASE7", [
        "read:phase",
        "request:child_replan"
      ])

    grants_before = repo.aggregate(AccessGrant, :count)

    replan_response =
      mcp_tool(repo, session, "request_child_replan", %{"work_package_id" => "SYMPP-ARCHITECT-PHASE7", "reason" => "not wired"})

    assert get_in(replan_response, ["error", "code"]) == -32_604
    assert get_in(replan_response, ["error", "data", "reason"]) == "phase7_not_implemented"
    assert repo.aggregate(AccessGrant, :count) == grants_before
  end

  test "Phase 7 architect stubs revalidate phase anchors before not-implemented", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-STUB-DRIFT", kind: "mcp"))
    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-mcp-stub-drift", title: "Stub drift"})

    assert {:ok, architect_work_key} =
             create_architect_work_key(repo, package.id, ["mint:child_worker_key", "read:phase", "request:child_replan"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    replan_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "replan-child-stub",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_child_replan",
            "arguments" => %{"work_package_id" => package.id, "reason" => "drift check"}
          }
        },
        config: test_mcp_config(repo),
        session: session
      )

    assert get_in(replan_response, ["error", "data", "reason"]) == "phase7_not_implemented"

    assert {:ok, _package} = WorkPackageRepository.update(repo, package.id, %{phase_id: other_phase.id})

    stale_replan_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "replan-child-stale",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_child_replan",
            "arguments" => %{"work_package_id" => package.id, "reason" => "drift check"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_replan_response, ["error", "code"]) == -32_003
    assert get_in(stale_replan_response, ["error", "data", "reason"]) == "outside_session_scope"

    stale_mint_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "mint-child-stale-anchor",
          "method" => "tools/call",
          "params" => %{"name" => "mint_child_worker_key", "arguments" => %{"work_package_id" => package.id}}
        },
        config: test_mcp_config(repo),
        session: session
      )

    assert get_in(stale_mint_response, ["error", "code"]) == -32_003
    assert get_in(stale_mint_response, ["error", "data", "reason"]) == "outside_session_scope"
  end
end
