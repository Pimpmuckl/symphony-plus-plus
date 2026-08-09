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
    assert_child_worker_active(repo, worker_session)
    attach_phase_child_ready_evidence(repo, worker_session, child_id, "p7-003-approval-replay-head")

    assert get_in(mcp_tool(repo, worker_session, "mark_ready", %{}), ["result", "structuredContent", "ready"]) == true

    approval_response =
      mcp_tool(repo, architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Ready before downstream merge blocker",
        "request_id" => "p7-003-approval-before-blocker"
      })

    assert get_in(approval_response, ["result", "structuredContent", "work_package", "status"]) == "merging_into_phase"

    assert {:ok, blocked_child} =
             WorkPackageRepository.update_status(repo, child_id, "merging_into_phase", "blocked")

    assert blocked_child.status == "blocked"

    blocker_id = "p7-003-post-approval-blocker"

    assert {:ok, _blocker} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: child_id,
               summary: "Phase merge conflict",
               body: "Architect approval happened, but the child needs follow-up before merge.",
               status: "blocked",
               payload: %{"type" => "blocker", "source_tool" => "report_blocker", "blocker_id" => blocker_id, "active" => true}
             })

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

    assert {:ok, _resolution} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: child_id,
               summary: "Phase merge conflict resolved",
               status: "resolved",
               payload: %{
                 "type" => "blocker",
                 "source_tool" => "resolve_blocker",
                 "blocker_id" => blocker_id,
                 "resolution" => "merge blocker resolved",
                 "active" => false
               }
             })

    assert {:ok, reactivated_child} =
             WorkPackageRepository.update_status(repo, child_id, "blocked", "active")

    assert reactivated_child.status == "active"

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

    assert {:ok, blocked_again} =
             WorkPackageRepository.update_status(repo, child_id, "merging_into_phase", "blocked")

    assert {:ok, active_again} =
             WorkPackageRepository.update_status(repo, child_id, blocked_again.status, "active")

    assert active_again.status == "active"

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

  test "phase architect tools revalidate phase anchors", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-STUB-DRIFT", kind: "mcp"))
    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-mcp-stub-drift", title: "Stub drift"})

    assert {:ok, architect_work_key} =
             create_architect_work_key(repo, package.id, ["mint:child_worker_key", "read:phase"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    assert {:ok, _package} = WorkPackageRepository.update(repo, package.id, %{phase_id: other_phase.id})

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
