Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestTools03Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "claim_local_architect_assignment reclaims with full handoff scope arguments", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-FULL-RECLAIM",
        status: "ready_for_clarification"
      )

    handoff = create_architect_handoff!(repo, work_request)
    old_args = %{"work_request_id" => work_request.id, "claimed_by" => "architect-old"}

    {old_response, _old_server} = claim_local_architect(repo, old_args, "local-architect-full-reclaim-old")
    assert get_in(old_response, ["result", "structuredContent", "assignment", "grant_id"]) == handoff.grant.id
    assert {:ok, old_lease} = ClaimLeaseService.current_for_work_package(repo, handoff.anchor_package.id)
    assert {:ok, _released} = ClaimLeaseService.release(repo, old_lease.id, reason: "test_reclaim")

    full_args = %{
      "work_request_id" => work_request.id,
      "claimed_by" => "architect-new",
      "architect_anchor_work_package_id" => handoff.anchor_package.id,
      "repo" => work_request.repo,
      "base_branch" => work_request.base_branch,
      "phase_id" => handoff.phase.id
    }

    {response, claimed_server} = claim_local_architect(repo, full_args, "local-architect-full-reclaim-new")

    assert get_in(response, ["result", "structuredContent", "assignment", "grant_id"]) == handoff.grant.id
    assert get_in(response, ["result", "structuredContent", "assignment", "claimed_by"]) == "architect-new"
    assert Scope.work_request(work_request.id) in claimed_server.session.assignment.scopes
  end

  test "claim_local_architect_assignment recovers bare WorkRequest id claim when grant scope rows are stale", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-BARE-STALE-SCOPE",
        status: "ready_for_clarification"
      )

    handoff = create_architect_handoff!(repo, work_request)
    assert {:ok, [grant]} = AccessGrantRepository.list_for_work_package(repo, handoff.anchor_package.id)

    repo.delete_all(
      from(scope in GrantScope,
        where: scope.access_grant_id == ^grant.id,
        where: scope.scope_type == "work_request"
      )
    )

    {response, claimed_server} =
      claim_local_architect(
        repo,
        %{"work_request_id" => work_request.id, "claimed_by" => "architect-bare"},
        "local-architect-bare-stale-scope"
      )

    assert get_in(response, ["result", "structuredContent", "assignment", "grant_id"]) == grant.id
    assert Scope.work_request(work_request.id) in claimed_server.session.assignment.scopes
  end

  test "claim_local_architect_assignment recovers when a singleton grant scope row is stale", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-STALE-SINGLETON-SCOPE",
        status: "ready_for_clarification"
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-STALE-SINGLETON-SIBLING",
        status: "ready_for_clarification"
      )

    handoff = create_architect_handoff!(repo, work_request)
    assert {:ok, [grant]} = AccessGrantRepository.list_for_work_package(repo, handoff.anchor_package.id)

    repo.update_all(
      from(scope in GrantScope,
        where: scope.access_grant_id == ^grant.id,
        where: scope.scope_type == "work_request"
      ),
      set: [scope_id: sibling.id]
    )

    {response, claimed_server} =
      claim_local_architect(
        repo,
        %{"work_request_id" => work_request.id, "claimed_by" => "architect-stale-singleton"},
        "local-architect-stale-singleton-scope"
      )

    assert get_in(response, ["result", "structuredContent", "assignment", "grant_id"]) == grant.id
    assert Scope.work_request(work_request.id) in claimed_server.session.assignment.scopes

    assert {:ok, scopes} = AccessGrantRepository.list_scopes(repo, grant.id)

    assert scopes
           |> Enum.filter(&(&1.scope_type == "work_request"))
           |> Enum.map(& &1.scope_id) == [work_request.id]
  end

  test "claim_local_architect_assignment prunes stale additive grant scope rows", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-STALE-ADDITIVE-SCOPE",
        status: "ready_for_clarification"
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-STALE-ADDITIVE-SIBLING",
        status: "ready_for_clarification"
      )

    handoff = create_architect_handoff!(repo, work_request)
    assert {:ok, [grant]} = AccessGrantRepository.list_for_work_package(repo, handoff.anchor_package.id)

    assert {:ok, _scope} =
             GrantScope.create_changeset(%{
               access_grant_id: grant.id,
               scope_type: "work_request",
               scope_id: sibling.id
             })
             |> repo.insert()

    {response, claimed_server} =
      claim_local_architect(
        repo,
        %{"work_request_id" => work_request.id, "claimed_by" => "architect-stale-additive"},
        "local-architect-stale-additive-scope"
      )

    assert get_in(response, ["result", "structuredContent", "assignment", "grant_id"]) == grant.id
    assert Scope.work_request(work_request.id) in claimed_server.session.assignment.scopes
    refute Scope.work_request(sibling.id) in claimed_server.session.assignment.scopes

    assert {:ok, scopes} = AccessGrantRepository.list_scopes(repo, grant.id)

    assert scopes
           |> Enum.filter(&(&1.scope_type == "work_request"))
           |> Enum.map(& &1.scope_id) == [work_request.id]
  end

  test "claim_local_architect_assignment does not repair stale rows when file scope drifts", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-STALE-FILE-SCOPE",
        status: "ready_for_clarification",
        constraints: %{"allowed_paths" => ["elixir/lib"]}
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-STALE-FILE-SCOPE-SIBLING",
        status: "ready_for_clarification"
      )

    handoff = create_architect_handoff!(repo, work_request)
    assert {:ok, [grant]} = AccessGrantRepository.list_for_work_package(repo, handoff.anchor_package.id)

    assert {:ok, _scope} =
             GrantScope.create_changeset(%{
               access_grant_id: grant.id,
               scope_type: "work_request",
               scope_id: sibling.id
             })
             |> repo.insert()

    work_request
    |> Ecto.Changeset.change(constraints: %{"allowed_paths" => ["docs"]})
    |> repo.update!()

    {response, _server} =
      claim_local_architect(
        repo,
        %{"work_request_id" => work_request.id, "claimed_by" => "architect-stale-file-scope"},
        "local-architect-stale-file-scope"
      )

    assert get_in(response, ["error", "data", "reason"]) == "ambiguous_phase_scope"

    assert {:ok, scopes} = AccessGrantRepository.list_scopes(repo, grant.id)

    assert scopes
           |> Enum.filter(&(&1.scope_type == "work_request"))
           |> Enum.map(& &1.scope_id)
           |> Enum.sort() == Enum.sort([work_request.id, sibling.id])
  end

  test "claim_local_architect_assignment fails closed for cross-branch scope", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-UNSAFE-SCOPE",
        status: "ready_for_clarification"
      )

    _handoff = create_architect_handoff!(repo, work_request)

    {branch_response, _branch_server} =
      claim_local_architect(
        repo,
        %{"work_request_id" => work_request.id, "base_branch" => "other-branch"},
        "local-architect-cross-branch"
      )

    assert get_in(branch_response, ["error", "data", "reason"]) == "base_branch_scope_mismatch"
  end

  test "claim_local_architect_assignment returns actionable phase-scope repair evidence", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-ACTIONABLE-SCOPE",
        status: "ready_for_clarification"
      )

    _handoff = create_architect_handoff!(repo, work_request)
    assert {:ok, _draft} = WorkRequestRepository.update_status(repo, work_request.id, "ready_for_clarification", "draft")

    {response, _server} =
      claim_local_architect(
        repo,
        %{"work_request_id" => work_request.id, "claimed_by" => "architect-actionable"},
        "local-architect-actionable-scope"
      )

    assert get_in(response, ["error", "data", "reason"]) == "phase_scope_not_available"
    assert get_in(response, ["error", "data", "action"]) == "repair_local_architect_handoff_scope"
    assert get_in(response, ["error", "data", "missing_evidence"]) == ["work_request_status"]
    assert get_in(response, ["error", "data", "hint"]) =~ "replay architect handoff"
  end

  test "claim_local_architect_assignment reports archived WorkRequests as terminal", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-ARCHIVED",
        status: "ready_for_clarification"
      )

    _handoff = create_architect_handoff!(repo, work_request)
    archived_at = DateTime.utc_now(:microsecond)

    work_request
    |> Ecto.Changeset.change(
      completed_at: archived_at,
      completion_source: "operator",
      archived_at: archived_at,
      archive_reason: "manual"
    )
    |> repo.update!()

    {response, _server} =
      claim_local_architect(
        repo,
        %{"work_request_id" => work_request.id, "claimed_by" => "architect-archived"},
        "local-architect-archived"
      )

    assert get_in(response, ["error", "data", "reason"]) == "work_request_terminal"
    assert get_in(response, ["error", "data", "terminal_state"]) == "archived"
    assert get_in(response, ["error", "data", "action"]) == "restore_work_request_or_start_new_work_request"
  end

  test "existing handoff architect sessions fail closed after WorkRequest archive", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-ARCHIVED-SESSION",
        status: "ready_for_clarification"
      )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, work_request, [
        "read:work_request",
        "write:work_request"
      ])

    archived_at = DateTime.utc_now(:microsecond)

    work_request
    |> Ecto.Changeset.change(
      completed_at: archived_at,
      completion_source: "operator",
      archived_at: archived_at,
      archive_reason: "manual"
    )
    |> repo.update!()

    response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_clarification"})

    assert get_in(response, ["error", "code"]) == -32_003
    assert get_in(response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "mark WorkRequest sliced MCP tool preserves approved-slice requirement", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-GUARD", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-GUARD",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    response =
      mcp_tool(repo, session, "finish_slicing", %{
        "work_request_id" => work_request.id,
        "current_status" => "ready_for_slicing"
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "no_approved_slices"

    assert {:ok, persisted_work_request} = WorkRequestRepository.get(repo, work_request.id)
    assert persisted_work_request.status == "ready_for_slicing"
  end

  test "WorkRequest MCP planned-slice mutations require slice authoring status", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-STATUS", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-STATUS",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "draft"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    add_args = %{
      "work_request_id" => work_request.id,
      "title" => "Draft-state slice",
      "goal" => "Should wait until slicing is open.",
      "work_package_kind" => "mcp",
      "target_base_branch" => anchor.base_branch,
      "owned_file_globs" => ["elixir/lib/**"],
      "forbidden_file_globs" => [],
      "acceptance_criteria" => ["WorkRequest is sliceable."],
      "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp"],
      "review_lanes" => ["normal"],
      "stop_conditions" => ["Stop before dispatch."]
    }

    add_response = mcp_tool(repo, session, "plan_slice", add_args)
    assert get_in(add_response, ["error", "code"]) == -32_602
    assert get_in(add_response, ["error", "data", "reason"]) == "invalid_status"
    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, Map.delete(add_args, "work_request_id"))

    for tool <- ["approve_slice", "skip_slice"] do
      response =
        mcp_tool(repo, session, tool, %{
          "work_request_id" => work_request.id,
          "planned_slice_id" => planned_slice.id,
          "current_status" => "planned"
        })

      assert get_in(response, ["error", "code"]) == -32_602
      assert get_in(response, ["error", "data", "reason"]) == "invalid_status"
    end

    assert {:ok, [persisted_slice]} = WorkRequestRepository.list_planned_slices(repo, work_request.id)
    assert persisted_slice.status == "planned"
  end

  test "WorkRequest MCP planned-slice writes honor planned-slice scope without parent WorkRequest scope", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-EXPLICIT", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-EXPLICIT",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-SLICE-EXPLICIT",
                 target_base_branch: anchor.base_branch
               )
             )

    grant_planned_slice_scope!(repo, session, planned_slice.id)
    remove_grant_scope_type!(repo, session, "repo")

    response =
      mcp_tool(repo, session, "approve_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "current_status" => "planned"
      })

    assert get_in(response, ["result", "structuredContent", "planned_slice", "status"]) == "approved"
    assert get_in(response, ["result", "structuredContent", "work_request", "id"]) == work_request.id
    text = assert_toon_tool_text!(response)
    assert text =~ "planned_slice:"
    assert text =~ "planned_slice_status: approved"

    assert {:ok, persisted_slice} = WorkRequestRepository.get_planned_slice(repo, work_request.id, planned_slice.id)
    assert persisted_slice.status == "approved"
  end

  test "WorkRequest MCP mutations require write capability and explicit live phase scope", %{repo: repo} do
    {read_anchor, read_session, _read_grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE-READONLY", [
        "read:work_request"
      ])

    read_only_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-READONLY",
        repo: read_anchor.repo,
        base_branch: read_anchor.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, read_only_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               read_only_work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-MUTATE-READONLY",
                 target_base_branch: read_anchor.base_branch
               )
             )

    read_only_response =
      mcp_tool(repo, read_session, "ask_question", %{
        "work_request_id" => read_only_work_request.id,
        "category" => "scope",
        "question" => "Question?",
        "why_needed" => "Capability check."
      })

    assert get_in(read_only_response, ["error", "code"]) == -32_003
    assert get_in(read_only_response, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(read_only_response, ["error", "data", "reason_code"]) == "insufficient_capability"

    read_only_slice_response =
      mcp_tool(repo, read_session, "plan_slice", %{
        "work_request_id" => read_only_work_request.id,
        "title" => "Denied slice",
        "goal" => "Capability check.",
        "work_package_kind" => "mcp",
        "target_base_branch" => read_anchor.base_branch,
        "owned_file_globs" => [],
        "forbidden_file_globs" => [],
        "acceptance_criteria" => [],
        "validation_steps" => [],
        "review_lanes" => [],
        "stop_conditions" => []
      })

    assert get_in(read_only_slice_response, ["error", "code"]) == -32_003
    assert get_in(read_only_slice_response, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(read_only_slice_response, ["error", "data", "reason_code"]) == "insufficient_capability"

    read_only_dispatch_response =
      mcp_tool(repo, read_session, "dispatch_slice", %{
        "work_request_id" => read_only_work_request.id,
        "planned_slice_id" => read_only_slice.id,
        "claimed_by" => "worker-1"
      })

    assert get_in(read_only_dispatch_response, ["error", "code"]) == -32_003
    assert get_in(read_only_dispatch_response, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(read_only_dispatch_response, ["error", "data", "reason_code"]) == "insufficient_capability"

    read_only_prepare_response =
      mcp_tool(repo, read_session, "prepare_work_package_worktree", %{
        "work_package_id" => "wp-missing"
      })

    assert get_in(read_only_prepare_response, ["error", "code"]) == -32_001
    assert get_in(read_only_prepare_response, ["error", "data", "reason"]) == "insufficient_capability"

    read_only_tools =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "read-only-tools", "method" => "tools/list", "params" => %{}},
        repo: repo,
        session: read_session
      )
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    for tool <- @architect_tool_names do
      assert Map.has_key?(read_only_tools, tool)
    end

    assert {:ok, legacy_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-WR-MUTATE-LEGACY", kind: "mcp"))

    assert {:error, %Ecto.Changeset{} = legacy_changeset} =
             create_architect_work_key(repo, legacy_package.id, ["write:work_request"])

    assert {"architect phase-scoped grants require phase scope", []} in Keyword.get_values(legacy_changeset.errors, :phase_id)

    {drift_anchor, drift_session, _drift_grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE-DRIFT", [
        "write:work_request",
        "dispatch:work_request"
      ])

    drift_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-DRIFT",
        repo: drift_anchor.repo,
        base_branch: drift_anchor.base_branch,
        status: "draft"
      )

    grant_work_request_scope!(repo, drift_session, drift_work_request.id)

    assert {:ok, drift_planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               drift_work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-MUTATE-DRIFT",
                 target_base_branch: drift_anchor.base_branch
               )
             )

    assert {:ok, _drifted_anchor} = WorkPackageRepository.update(repo, drift_anchor.id, %{repo: "nextide/other"})

    drift_response =
      mcp_tool(repo, drift_session, "set_work_request_status", %{
        "work_request_id" => drift_work_request.id,
        "current_status" => "draft",
        "next_status" => "ready_for_clarification"
      })

    assert get_in(drift_response, ["error", "code"]) == -32_003
    assert get_in(drift_response, ["error", "data", "reason"]) == "outside_session_scope"

    drift_slice_response =
      mcp_tool(repo, drift_session, "finish_slicing", %{
        "work_request_id" => drift_work_request.id,
        "current_status" => "ready_for_slicing"
      })

    assert get_in(drift_slice_response, ["error", "code"]) == -32_003
    assert get_in(drift_slice_response, ["error", "data", "reason"]) == "outside_session_scope"

    drift_dispatch_response =
      mcp_tool(repo, drift_session, "dispatch_slice", %{
        "work_request_id" => drift_work_request.id,
        "planned_slice_id" => drift_planned_slice.id,
        "claimed_by" => "worker-1"
      })

    assert get_in(drift_dispatch_response, ["error", "code"]) == -32_003
    assert get_in(drift_dispatch_response, ["error", "data", "reason"]) == "outside_session_scope"

    {revoked_anchor, revoked_session, revoked_grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE-REVOKED", [
        "write:work_request",
        "dispatch:work_request"
      ])

    revoked_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-REVOKED",
        repo: revoked_anchor.repo,
        base_branch: revoked_anchor.base_branch,
        status: "draft"
      )

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, revoked_grant.id)

    revoked_response =
      mcp_tool(repo, revoked_session, "set_work_request_status", %{
        "work_request_id" => revoked_work_request.id,
        "current_status" => "draft",
        "next_status" => "ready_for_clarification"
      })

    assert get_in(revoked_response, ["error", "code"]) == -32_001
    assert get_in(revoked_response, ["error", "data", "reason"]) == "revoked"

    revoked_slice_response =
      mcp_tool(repo, revoked_session, "finish_slicing", %{
        "work_request_id" => revoked_work_request.id,
        "current_status" => "ready_for_slicing"
      })

    assert get_in(revoked_slice_response, ["error", "code"]) == -32_001
    assert get_in(revoked_slice_response, ["error", "data", "reason"]) == "revoked"

    revoked_dispatch_response =
      mcp_tool(repo, revoked_session, "dispatch_slice", %{
        "work_request_id" => revoked_work_request.id,
        "planned_slice_id" => "WRS-MCP-WR-MUTATE-REVOKED",
        "claimed_by" => "worker-1"
      })

    assert get_in(revoked_dispatch_response, ["error", "code"]) == -32_001
    assert get_in(revoked_dispatch_response, ["error", "data", "reason"]) == "revoked"

    assert {:ok, worker_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WR-MUTATE-WORKER", kind: "mcp"))
    assert {:ok, worker_minted} = AccessGrantService.mint_worker_grant(repo, worker_package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, worker_minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: worker_minted.grant.secret_hash)

    worker_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-WORKER",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta",
        status: "ready_for_slicing"
      )

    assert {:ok, worker_planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               worker_work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-MUTATE-WORKER",
                 target_base_branch: "symphony-plus-plus/beta"
               )
             )

    worker_response =
      mcp_tool(repo, worker_session, "set_work_request_status", %{
        "work_request_id" => worker_work_request.id,
        "current_status" => "draft",
        "next_status" => "ready_for_clarification"
      })

    assert get_in(worker_response, ["error", "code"]) == -32_003
    assert get_in(worker_response, ["error", "data", "reason_code"]) == "insufficient_role"

    worker_slice_response =
      mcp_tool(repo, worker_session, "finish_slicing", %{
        "work_request_id" => worker_work_request.id,
        "current_status" => "ready_for_slicing"
      })

    assert get_in(worker_slice_response, ["error", "code"]) == -32_003
    assert get_in(worker_slice_response, ["error", "data", "reason_code"]) == "insufficient_role"

    worker_dispatch_response =
      mcp_tool(repo, worker_session, "dispatch_slice", %{
        "work_request_id" => worker_work_request.id,
        "planned_slice_id" => worker_planned_slice.id,
        "claimed_by" => "worker-1"
      })

    assert get_in(worker_dispatch_response, ["error", "code"]) == -32_003
    assert get_in(worker_dispatch_response, ["error", "data", "reason_code"]) == "insufficient_role"

    anonymous_response =
      mcp_tool(repo, nil, "set_work_request_status", %{
        "work_request_id" => "WR-MCP-WR-MISSING",
        "current_status" => "draft",
        "next_status" => "ready_for_clarification"
      })

    assert get_in(anonymous_response, ["error", "code"]) == -32_001
    assert get_in(anonymous_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(anonymous_response, ["error", "data", "action"]) == "claim_local_architect_assignment"

    anonymous_slice_response =
      mcp_tool(repo, nil, "finish_slicing", %{
        "work_request_id" => "WR-MCP-WR-MISSING",
        "current_status" => "ready_for_slicing"
      })

    assert get_in(anonymous_slice_response, ["error", "code"]) == -32_001
    assert get_in(anonymous_slice_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(anonymous_slice_response, ["error", "data", "action"]) == "claim_local_architect_assignment"

    anonymous_dispatch_response =
      mcp_tool(repo, nil, "dispatch_slice", %{
        "work_request_id" => "WR-MCP-WR-MISSING",
        "planned_slice_id" => "WRS-MCP-WR-MISSING",
        "claimed_by" => "worker-1"
      })

    assert get_in(anonymous_dispatch_response, ["error", "code"]) == -32_001
    assert get_in(anonymous_dispatch_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(anonymous_dispatch_response, ["error", "data", "action"]) == "claim_local_architect_assignment"
  end

  test "WorkRequest MCP question mutations fail closed for sibling question ids", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE-SIBLING-QUESTION", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-QUESTION-OWNER",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "clarifying"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-QUESTION-SIBLING",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "clarifying"
      )

    assert {:ok, sibling_question} =
             WorkRequestRepository.ask_question(
               repo,
               sibling.id,
               work_request_question_attrs(id: "WRQ-MCP-WR-SIBLING-QUESTION")
             )

    answer_response =
      mcp_tool(repo, session, "answer_question", %{
        "work_request_id" => work_request.id,
        "question_id" => sibling_question.id,
        "current_status" => "open",
        "answer" => "Do not answer a sibling question.",
        "answered_by" => "architect-1"
      })

    assert get_in(answer_response, ["error", "code"]) == -32_004
    assert get_in(answer_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(answer_response) =~ sibling.id

    close_response =
      mcp_tool(repo, session, "close_question", %{
        "work_request_id" => work_request.id,
        "question_id" => sibling_question.id,
        "current_status" => "open"
      })

    assert get_in(close_response, ["error", "code"]) == -32_004
    assert get_in(close_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(close_response) =~ sibling.id

    assert {:ok, [persisted_sibling_question]} = WorkRequestRepository.list_questions(repo, sibling.id)
    assert persisted_sibling_question.status == "open"
    assert persisted_sibling_question.answer == nil
  end

  test "WorkRequest MCP planned-slice status mutations fail closed for sibling slice ids", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE-SIBLING-SLICE", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-SLICE-OWNER",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-SLICE-SIBLING",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, sibling_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               sibling.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-WR-SIBLING-SLICE")
             )

    approve_response =
      mcp_tool(repo, session, "approve_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => sibling_slice.id,
        "current_status" => "planned"
      })

    assert get_in(approve_response, ["error", "code"]) == -32_004
    assert get_in(approve_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(approve_response) =~ sibling.id

    skip_response =
      mcp_tool(repo, session, "skip_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => sibling_slice.id,
        "current_status" => "planned"
      })

    assert get_in(skip_response, ["error", "code"]) == -32_004
    assert get_in(skip_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(skip_response) =~ sibling.id

    assert {:ok, [persisted_sibling_slice]} = WorkRequestRepository.list_planned_slices(repo, sibling.id)
    assert persisted_sibling_slice.status == "planned"
    assert persisted_sibling_slice.work_package_id == nil
  end

  defp create_architect_handoff!(repo, work_request) do
    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: local_architect_handoff_opts(repo)
             )

    handoff
  end

  defp local_architect_handoff_opts(repo) do
    [claimed_by: ArchitectHandoff.claimed_by(), database: repo.database_path(), local_architect_claim?: true]
  end

  defp claim_local_architect(repo, arguments, id) do
    Server.handle_state(
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => %{"name" => "claim_local_architect_assignment", "arguments" => arguments}
      },
      local_mcp_server(local_mcp_config(repo), "#{id}-state")
    )
  end
end
