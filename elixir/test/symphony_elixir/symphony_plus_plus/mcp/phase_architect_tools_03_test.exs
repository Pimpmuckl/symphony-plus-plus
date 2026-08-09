Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.PhaseArchitectTools03Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "child worker key minting uses transaction-current parent architect expiry", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-PARENT-SHORTENED-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-PARENT-SHORTENED-CHILD")
    shortened_expires_at = DateTime.utc_now(:microsecond) |> DateTime.add(60, :second) |> DateTime.truncate(:microsecond)
    MintParentGrantRaceRepo.arm(architect_session.assignment.grant_id, %{expires_at: shortened_expires_at})

    response =
      try do
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "mint_child_worker_key",
            "method" => "tools/call",
            "params" => %{
              "name" => "mint_child_worker_key",
              "arguments" => %{"work_package_id" => child_id}
            }
          },
          config: test_mcp_config(MintParentGrantRaceRepo),
          session: architect_session
        )
      after
        MintParentGrantRaceRepo.disarm()
      end

    assert get_in(response, ["result", "structuredContent", "worker_grant", "work_package_id"]) == child_id
    minted_expires_at = get_in(response, ["result", "structuredContent", "worker_grant", "expires_at"])
    assert {:ok, minted_expires_at, _offset} = DateTime.from_iso8601(minted_expires_at)
    assert DateTime.compare(DateTime.truncate(minted_expires_at, :microsecond), shortened_expires_at) != :gt

    {_anchor, broader_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-PARENT-SHORT-BROAD-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    broader_child_id = create_child_work_package(repo, broader_session, "SYMPP-P7-002-MINT-PARENT-SHORT-BROAD-CHILD")
    broader_shortened_expires_at = DateTime.utc_now(:microsecond) |> DateTime.add(60, :second) |> DateTime.truncate(:microsecond)
    requested_expires_at = DateTime.utc_now(:microsecond) |> DateTime.add(3600, :second) |> DateTime.truncate(:microsecond)
    MintParentGrantRaceRepo.arm(broader_session.assignment.grant_id, %{expires_at: broader_shortened_expires_at})

    broader_response =
      try do
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "mint_child_worker_key",
            "method" => "tools/call",
            "params" => %{
              "name" => "mint_child_worker_key",
              "arguments" => %{
                "work_package_id" => broader_child_id,
                "template" => %{"expires_at" => DateTime.to_iso8601(requested_expires_at)}
              }
            }
          },
          config: test_mcp_config(MintParentGrantRaceRepo),
          session: broader_session
        )
      after
        MintParentGrantRaceRepo.disarm()
      end

    assert get_in(broader_response, ["error", "code"]) == -32_602
    assert get_in(broader_response, ["error", "data", "reason"]) == "broader_child_grant"
  end

  test "child worker key minting defaults to no expiry for non-expiring architect grants", %{repo: repo} do
    {_anchor, architect_session} =
      create_non_expiring_architect_session(repo, "SYMPP-P7-002-MINT-NO-EXPIRY-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-NO-EXPIRY-CHILD")

    response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id
      })

    assert get_in(response, ["result", "structuredContent", "worker_grant", "work_package_id"]) == child_id
    assert get_in(response, ["result", "structuredContent", "worker_grant", "expires_at"]) == nil

    grant_id = get_in(response, ["result", "structuredContent", "worker_grant", "id"])
    assert {:ok, grant} = AccessGrantRepository.get(repo, grant_id)
    assert grant.expires_at == nil

    explicit_child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-NO-EXPIRY-EXPLICIT")
    explicit_expires_at = DateTime.utc_now(:microsecond) |> DateTime.add(3_600, :second) |> DateTime.truncate(:microsecond)

    explicit_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => explicit_child_id,
        "template" => %{"expires_at" => DateTime.to_iso8601(explicit_expires_at)}
      })

    assert get_in(explicit_response, ["result", "structuredContent", "worker_grant", "work_package_id"]) == explicit_child_id
    minted_expires_at = get_in(explicit_response, ["result", "structuredContent", "worker_grant", "expires_at"])
    assert {:ok, minted_expires_at, _offset} = DateTime.from_iso8601(minted_expires_at)
    assert DateTime.compare(DateTime.truncate(minted_expires_at, :microsecond), explicit_expires_at) == :eq

    expired_child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-NO-EXPIRY-PAST")
    expired_expires_at = DateTime.utc_now(:microsecond) |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    expired_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => expired_child_id,
        "template" => %{"expires_at" => DateTime.to_iso8601(expired_expires_at)}
      })

    assert get_in(expired_response, ["error", "code"]) == -32_602
    assert get_in(expired_response, ["error", "data", "reason"]) == "invalid_expires_at"
  end

  test "phase child scope resolves local checkout repository identity", %{repo: repo} do
    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-LOCAL-REPO-ANCHOR", ["mint:child_worker_key", "read:phase"])

    matching_path =
      TestSupport.git_repo_with_origin_fixture!("https://github.com/nextide/symphony-plus-plus.git", prefix: "sympp-phase-child-repo")

    assert {:ok, child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-MINT-LOCAL-REPO-CHILD",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: anchor.id,
                 base_branch: anchor.base_branch,
                 repo: matching_path,
                 status: "ready_for_worker",
                 allowed_file_globs: anchor.allowed_file_globs
               )
             )

    response = mcp_tool(repo, architect_session, "mint_child_worker_key", %{"work_package_id" => child.id})
    assert get_in(response, ["result", "structuredContent", "worker_grant", "work_package_id"]) == child.id

    different_path = TestSupport.git_repo_with_origin_fixture!("https://github.com/elsewhere/symphony-plus-plus.git", prefix: "sympp-phase-child-other")

    assert {:ok, different_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-MINT-OTHER-REPO-CHILD",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: anchor.id,
                 base_branch: anchor.base_branch,
                 repo: different_path,
                 status: "ready_for_worker",
                 allowed_file_globs: anchor.allowed_file_globs
               )
             )

    rejected = mcp_tool(repo, architect_session, "mint_child_worker_key", %{"work_package_id" => different_child.id})
    assert get_in(rejected, ["error", "data", "reason"]) == "repo_scope_mismatch"
  end

  test "phase architect cannot mint or read child worker key for sibling anchor, sibling phase, or mismatched base branch", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-SCOPE-ANCHOR", [
        "mint:child_worker_key",
        "read:child_progress",
        "read:child_findings",
        "read:phase"
      ])

    assert {:ok, sibling_anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-MINT-SIBLING-ANCHOR",
                 kind: "mcp",
                 phase_id: @architect_phase_id,
                 base_branch: "symphony-plus-plus/beta",
                 repo: "nextide/symphony-plus-plus",
                 status: "planning"
               )
             )

    assert {:ok, sibling_anchor_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-MINT-SIBLING-ANCHOR-CHILD",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: sibling_anchor.id,
                 base_branch: "symphony-plus-plus/beta",
                 repo: "nextide/symphony-plus-plus",
                 status: "ready_for_worker"
               )
             )

    sibling_anchor_child_updated_at = sibling_anchor_child.updated_at

    sibling_anchor_mint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => sibling_anchor_child.id
      })

    assert get_in(sibling_anchor_mint_response, ["error", "code"]) == -32_003
    assert get_in(sibling_anchor_mint_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert {:ok, unchanged_sibling_anchor_child} = WorkPackageRepository.get(repo, sibling_anchor_child.id)
    assert unchanged_sibling_anchor_child.updated_at == sibling_anchor_child_updated_at

    sibling_anchor_status_response =
      mcp_tool(repo, architect_session, "read_child_status", %{"work_package_id" => sibling_anchor_child.id})

    assert get_in(sibling_anchor_status_response, ["error", "code"]) == -32_003
    assert get_in(sibling_anchor_status_response, ["error", "data", "reason"]) == "outside_session_scope"

    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-p7-002-mint-outside", title: "Mint outside phase"})

    assert {:ok, out_of_phase_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-MINT-OUT-OF-PHASE",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: other_phase.id,
                 parent_id: "SYMPP-P7-002-MINT-SCOPE-ANCHOR",
                 base_branch: "symphony-plus-plus/beta",
                 repo: "nextide/symphony-plus-plus",
                 status: "ready_for_worker"
               )
             )

    out_of_phase_child_updated_at = out_of_phase_child.updated_at

    out_of_phase_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => out_of_phase_child.id
      })

    assert get_in(out_of_phase_response, ["error", "code"]) == -32_003
    assert get_in(out_of_phase_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert {:ok, unchanged_out_of_phase_child} = WorkPackageRepository.get(repo, out_of_phase_child.id)
    assert unchanged_out_of_phase_child.updated_at == out_of_phase_child_updated_at

    assert {:ok, wrong_base_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-MINT-WRONG-BASE",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: "SYMPP-P7-002-MINT-SCOPE-ANCHOR",
                 base_branch: "main",
                 repo: "nextide/symphony-plus-plus",
                 status: "ready_for_worker"
               )
             )

    wrong_base_child_updated_at = wrong_base_child.updated_at

    wrong_base_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => wrong_base_child.id
      })

    assert get_in(wrong_base_response, ["error", "code"]) == -32_602
    assert get_in(wrong_base_response, ["error", "data", "reason"]) == "base_branch_scope_mismatch"
    assert {:ok, unchanged_wrong_base_child} = WorkPackageRepository.get(repo, wrong_base_child.id)
    assert unchanged_wrong_base_child.updated_at == wrong_base_child_updated_at
  end

  test "phase architect mint revalidates child file scope before worker grant creation", %{repo: repo} do
    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-FILE-SCOPE-ANCHOR", [
        "mint:child_worker_key",
        "read:phase"
      ])

    assert {:ok, broader_file_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-MINT-BROADER-FILE-SCOPE",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: anchor.id,
                 base_branch: anchor.base_branch,
                 repo: anchor.repo,
                 status: "ready_for_worker",
                 allowed_file_globs: ["**"]
               )
             )

    broader_file_child_updated_at = broader_file_child.updated_at
    grants_before_mint = repo.aggregate(AccessGrant, :count)

    response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => broader_file_child.id
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "overbroad_allowed_file_globs"
    assert repo.aggregate(AccessGrant, :count) == grants_before_mint

    assert {:ok, unchanged_child} = WorkPackageRepository.get(repo, broader_file_child.id)
    assert unchanged_child.updated_at == broader_file_child_updated_at
  end

  test "phase architect read_child_status revalidates phase anchor drift", %{repo: repo} do
    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-READ-DRIFT-ANCHOR", [
        "create:child_work_package",
        "read:child_progress",
        "read:child_findings",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-READ-DRIFT-CHILD")

    response = mcp_tool(repo, architect_session, "read_child_status", %{"work_package_id" => anchor.id})
    assert get_in(response, ["result", "structuredContent", "work_package", "id"]) == anchor.id

    child_response = mcp_tool(repo, architect_session, "read_child_status", %{"work_package_id" => child_id})
    assert get_in(child_response, ["result", "structuredContent", "work_package", "id"]) == child_id

    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-p7-002-read-drift", title: "Read drift"})
    assert {:ok, _anchor} = WorkPackageRepository.update(repo, anchor.id, %{phase_id: other_phase.id})

    drifted_response = mcp_tool(repo, architect_session, "read_child_status", %{"work_package_id" => anchor.id})

    assert get_in(drifted_response, ["error", "code"]) == -32_003
    assert get_in(drifted_response, ["error", "data", "reason"]) == "outside_session_scope"

    drifted_child_response = mcp_tool(repo, architect_session, "read_child_status", %{"work_package_id" => child_id})

    assert get_in(drifted_child_response, ["error", "code"]) == -32_003
    assert get_in(drifted_child_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "phase architect read_child_status rejects detached and repo-drifted anchors", %{repo: repo} do
    {detached_anchor, detached_session} =
      create_architect_session(repo, "SYMPP-P7-002-READ-DETACHED-ANCHOR", [
        "create:child_work_package",
        "read:child_progress",
        "read:child_findings",
        "read:phase"
      ])

    detached_child_id = create_child_work_package(repo, detached_session, "SYMPP-P7-002-READ-DETACHED-CHILD")

    assert {:ok, _anchor} = WorkPackageRepository.update(repo, detached_anchor.id, %{phase_id: nil})

    detached_anchor_response = mcp_tool(repo, detached_session, "read_child_status", %{"work_package_id" => detached_anchor.id})
    detached_child_response = mcp_tool(repo, detached_session, "read_child_status", %{"work_package_id" => detached_child_id})

    assert get_in(detached_anchor_response, ["error", "code"]) == -32_003
    assert get_in(detached_anchor_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert get_in(detached_child_response, ["error", "code"]) == -32_003
    assert get_in(detached_child_response, ["error", "data", "reason"]) == "outside_session_scope"

    {repo_drift_anchor, repo_drift_session} =
      create_architect_session(repo, "SYMPP-P7-002-READ-REPO-DRIFT-ANCHOR", [
        "read:child_progress",
        "read:child_findings",
        "read:phase"
      ])

    assert {:ok, _anchor} = WorkPackageRepository.update(repo, repo_drift_anchor.id, %{repo: "nextide/other-repo"})

    repo_drift_response = mcp_tool(repo, repo_drift_session, "read_child_status", %{"work_package_id" => repo_drift_anchor.id})

    assert get_in(repo_drift_response, ["error", "code"]) == -32_003
    assert get_in(repo_drift_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "phase child readiness approval and merge record update phase progress", %{repo: repo} do
    architect_capabilities = [
      "create:child_work_package",
      "mint:child_worker_key",
      "read:child_progress",
      "read:child_findings",
      "read:phase",
      "approve:child_ready_state",
      "merge:child_into_phase"
    ]

    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-003-FLOW-ANCHOR", architect_capabilities)

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-003-FLOW-CHILD")
    worker_session = claim_phase_child_worker(repo, architect_session, child_id)
    assert_child_worker_active(repo, worker_session)
    attach_phase_child_ready_evidence(repo, worker_session, child_id, "p7-003-flow-head")

    ready_response = mcp_tool(repo, worker_session, "mark_ready", %{})

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_architect_merge"

    worker_approval_response =
      mcp_tool(repo, worker_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "worker cannot approve"
      })

    assert get_in(worker_approval_response, ["error", "code"]) == -32_001
    assert get_in(worker_approval_response, ["error", "data", "reason"]) == "architect_grant_required"

    blank_request_id_response =
      mcp_tool(repo, architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Required evidence is green",
        "request_id" => "   "
      })

    assert get_in(blank_request_id_response, ["error", "code"]) == -32_602
    assert get_in(blank_request_id_response, ["error", "data", "reason"]) == "blank_request_id"

    assert {:ok, ready_child} = WorkPackageRepository.get(repo, child_id)
    assert ready_child.status == "ready_for_architect_merge"

    approval_response =
      mcp_tool(repo, architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Required evidence is green",
        "request_id" => "p7-003-approval-flow"
      })

    assert get_in(approval_response, ["result", "structuredContent", "work_package", "status"]) == "merging_into_phase"
    assert get_in(approval_response, ["result", "structuredContent", "approval", "payload", "type"]) == "child_ready_approval"
    approval_event = repo.get!(ProgressEvent, get_in(approval_response, ["result", "structuredContent", "approval", "id"]))
    assert approval_event.actor_id == architect_session.assignment.claimed_by
    assert approval_event.actor_type == "architect"
    assert approval_event.access_grant_id == architect_session.assignment.grant_id
    assert approval_event.payload["source_tool"] == "approve_child_ready_state"

    approval_replay_response =
      mcp_tool(repo, architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Required evidence is green",
        "request_id" => "p7-003-approval-flow"
      })

    assert get_in(approval_replay_response, ["result", "structuredContent", "work_package", "status"]) == "merging_into_phase"

    assert get_in(approval_replay_response, ["result", "structuredContent", "approval", "id"]) ==
             get_in(approval_response, ["result", "structuredContent", "approval", "id"])

    approval_changed_rationale_replay_response =
      mcp_tool(repo, architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Edited retry explanation",
        "request_id" => "p7-003-approval-flow"
      })

    assert get_in(approval_changed_rationale_replay_response, ["result", "structuredContent", "approval", "id"]) ==
             get_in(approval_response, ["result", "structuredContent", "approval", "id"])

    assert get_in(approval_changed_rationale_replay_response, ["result", "structuredContent", "approval", "payload", "rationale"]) ==
             "Required evidence is green"

    renewed_architect_session = renew_phase_architect_session(repo, anchor, architect_capabilities)

    approval_renewal_response =
      mcp_tool(repo, renewed_architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Required evidence is green",
        "request_id" => "p7-003-approval-flow"
      })

    assert get_in(approval_renewal_response, ["result", "structuredContent", "approval", "id"]) ==
             get_in(approval_response, ["result", "structuredContent", "approval", "id"])

    worker_close_response =
      mcp_tool(repo, worker_session, "abandon", %{
        "reason" => "worker cannot abandon child after architect approval"
      })

    assert get_in(worker_close_response, ["error", "data", "reason"]) == "child_under_architect_control"

    worker_progress_response =
      mcp_tool(repo, worker_session, "append_progress", %{
        "summary" => "late worker update",
        "status" => "late_worker_update",
        "idempotency_key" => "late-worker-update-after-architect-approval"
      })

    assert get_in(worker_progress_response, ["error", "data", "reason"]) == "child_under_architect_control"

    worker_attach_pr_replay_response =
      mcp_tool(repo, worker_session, "attach_pr", %{
        "url" => "https://github.com/nextide/symphony-plus-plus/pull/7003",
        "head_sha" => "p7-003-flow-head"
      })

    assert get_in(worker_attach_pr_replay_response, ["result", "structuredContent", "progress_event", "id"])

    worker_attach_pr_mutation_response =
      mcp_tool(repo, worker_session, "attach_pr", %{
        "url" => "https://github.com/nextide/symphony-plus-plus/pull/7003",
        "head_sha" => "late-worker-head"
      })

    assert get_in(worker_attach_pr_mutation_response, ["error", "data", "reason"]) == "child_under_architect_control"

    worker_review_package_replay_response =
      mcp_tool(repo, worker_session, "submit_review_package", ready_review_package_args("p7-003-flow-head"))

    assert get_in(worker_review_package_replay_response, ["result", "structuredContent", "progress_event", "id"])

    worker_review_package_mutation_response =
      mcp_tool(
        repo,
        worker_session,
        "submit_review_package",
        "p7-003-flow-head"
        |> ready_review_package_args()
        |> Map.put("summary", "Late worker review package")
      )

    assert get_in(worker_review_package_mutation_response, ["error", "data", "reason"]) == "child_under_architect_control"

    worker_merge_response =
      mcp_tool(repo, worker_session, "report_blocker", %{
        "summary" => "worker cannot block child after architect approval",
        "idempotency_key" => "late-worker-blocker-after-approval"
      })

    assert get_in(worker_merge_response, ["error", "data", "reason"]) == "child_under_architect_control"

    merge_artifact = %{
      "status" => "merged_into_phase",
      "uri" => "https://github.com/nextide/symphony-plus-plus/pull/7003",
      "summary" => "Recorded local phase merge",
      "commit_sha" => "p7-003-flow-head"
    }

    merge_response =
      mcp_tool(repo, architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => merge_artifact
      })

    assert get_in(merge_response, ["result", "structuredContent", "work_package", "status"]) == "merged_into_phase"
    assert get_in(merge_response, ["result", "structuredContent", "artifact", "kind"]) == "phase_merge"
    assert get_in(merge_response, ["result", "structuredContent", "merge_artifact", "status"]) == "merged_into_phase"
    assert get_in(merge_response, ["result", "structuredContent", "artifact", "metadata", "commit_sha"]) == "p7-003-flow-head"
    merge_event = repo.get!(ProgressEvent, get_in(merge_response, ["result", "structuredContent", "merge", "id"]))
    assert merge_event.actor_id == architect_session.assignment.claimed_by
    assert merge_event.actor_type == "architect"
    assert merge_event.access_grant_id == architect_session.assignment.grant_id
    assert merge_event.payload["source_tool"] == "merge_child_into_phase"

    merge_replay_response =
      mcp_tool(repo, architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => merge_artifact
      })

    assert get_in(merge_replay_response, ["result", "structuredContent", "work_package", "status"]) == "merged_into_phase"

    assert get_in(merge_replay_response, ["result", "structuredContent", "merge", "id"]) ==
             get_in(merge_response, ["result", "structuredContent", "merge", "id"])

    merge_renewal_response =
      mcp_tool(repo, renewed_architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => merge_artifact
      })

    assert get_in(merge_renewal_response, ["result", "structuredContent", "merge", "id"]) ==
             get_in(merge_response, ["result", "structuredContent", "merge", "id"])

    different_actor_architect_session = renew_phase_architect_session(repo, anchor, architect_capabilities, "architect-2")

    different_actor_merge_replay_response =
      mcp_tool(repo, different_actor_architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => merge_artifact
      })

    assert get_in(different_actor_merge_replay_response, ["result", "structuredContent", "merge", "id"]) ==
             get_in(merge_response, ["result", "structuredContent", "merge", "id"])

    merge_update_artifact = %{
      "status" => "merged_into_phase",
      "uri" => "https://github.com/nextide/symphony-plus-plus/pull/7003#merge-commit",
      "summary" => "Updated local phase merge",
      "commit_sha" => "p7-003-flow-head-updated"
    }

    merge_update_response =
      mcp_tool(repo, renewed_architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => merge_update_artifact
      })

    assert get_in(merge_update_response, ["result", "structuredContent", "work_package", "status"]) == "merged_into_phase"

    refute get_in(merge_update_response, ["result", "structuredContent", "merge", "id"]) ==
             get_in(merge_response, ["result", "structuredContent", "merge", "id"])

    assert get_in(merge_update_response, ["result", "structuredContent", "artifact", "uri"]) ==
             "https://github.com/nextide/symphony-plus-plus/pull/7003#merge-commit"

    assert get_in(merge_update_response, ["result", "structuredContent", "artifact", "metadata", "commit_sha"]) ==
             "p7-003-flow-head-updated"

    stale_merge_replay_response =
      mcp_tool(repo, renewed_architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => merge_artifact
      })

    assert get_in(stale_merge_replay_response, ["result", "structuredContent", "merge", "id"]) ==
             get_in(merge_response, ["result", "structuredContent", "merge", "id"])

    assert get_in(stale_merge_replay_response, ["result", "structuredContent", "artifact", "uri"]) ==
             "https://github.com/nextide/symphony-plus-plus/pull/7003#merge-commit"

    assert get_in(stale_merge_replay_response, ["result", "structuredContent", "merge_artifact", "uri"]) ==
             "https://github.com/nextide/symphony-plus-plus/pull/7003#merge-commit"

    board_response = mcp_tool(repo, architect_session, "read_phase_board", %{"phase_id" => @architect_phase_id})

    assert get_in(board_response, ["result", "structuredContent", "summary", "child_count"]) == 1
    assert get_in(board_response, ["result", "structuredContent", "summary", "merged_child_count"]) == 1
    assert get_in(board_response, ["result", "structuredContent", "summary", "open_child_count"]) == 0

    phase = repo.get!(Phase, @architect_phase_id)
    assert {:ok, _phase} = repo.update(Ecto.Changeset.change(phase, status: "closed"))

    closed_phase_exact_replay_response =
      mcp_tool(repo, renewed_architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => merge_update_artifact
      })

    assert get_in(closed_phase_exact_replay_response, ["error", "code"]) == -32_602
    assert get_in(closed_phase_exact_replay_response, ["error", "data", "reason"]) == "phase_not_active"

    closed_phase_merge_update_response =
      mcp_tool(repo, renewed_architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => %{
          "status" => "merged_into_phase",
          "uri" => "https://github.com/nextide/symphony-plus-plus/pull/7003#post-close-update",
          "summary" => "Late local phase merge update"
        }
      })

    assert get_in(closed_phase_merge_update_response, ["error", "code"]) == -32_602
    assert get_in(closed_phase_merge_update_response, ["error", "data", "reason"]) == "phase_not_active"

    assert repo.get_by(Artifact, work_package_id: child_id, kind: "phase_merge").uri ==
             "https://github.com/nextide/symphony-plus-plus/pull/7003#merge-commit"

    assert repo.get_by(Artifact, work_package_id: child_id, kind: "phase_merge").metadata["commit_sha"] ==
             "p7-003-flow-head-updated"
  end
end
