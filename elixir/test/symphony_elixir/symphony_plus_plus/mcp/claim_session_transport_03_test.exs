Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionTransport03Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.RepoScope

  test "claim_local_architect_assignment claims and reconnects a legacy-main WorkRequest with only its id", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-CLAIM",
        status: "ready_for_clarification"
      )
      |> Ecto.Changeset.change(base_branch: "origin/main")
      |> repo.update!()

    assert {1, nil} =
             repo.update_all(
               from(scope in RepoScope, where: scope.work_request_id == ^work_request.id),
               set: [base_branch: "origin/main", scope_key: "repo:#{work_request.repo}:origin/main"]
             )

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, handoff.grant.id)
    assert is_nil(unclaimed_grant.claimed_at)
    assert handoff.work_request.base_branch == "origin/main"
    assert handoff.anchor_package.base_branch == "main"
    assert unclaimed_grant.scope_base_branch == "main"
    repo.delete_all(from(scope in GrantScope, where: scope.access_grant_id == ^handoff.grant.id))
    assert {:ok, []} = AccessGrantRepository.list_scopes(repo, handoff.grant.id)

    arguments = %{"work_request_id" => work_request.id}

    state_key = "local-architect-claim-state"
    config = %{local_mcp_config(repo) | claimed_by: "generic-config-owner"}

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => arguments}
        },
        local_mcp_server(config, state_key)
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == handoff.anchor_package.id
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "claimed_by"]) == ArchitectHandoff.claimed_by()
    assert get_in(claim_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "created"
    assert claimed_server.session.assignment.grant_role == "architect"
    assert Scope.work_request(work_request.id) in claimed_server.session.assignment.scopes
    assert claimed_server.session.proof_hash == unclaimed_grant.secret_hash
    refute inspect(claim_response) =~ unclaimed_grant.secret_hash
    refute inspect(claim_response) =~ "private_handoff"

    assert {:ok, claimed_grant} = AccessGrantRepository.get(repo, handoff.grant.id)
    assert claimed_grant.claimed_by == ArchitectHandoff.claimed_by()
    assert {:ok, scope_rows} = AccessGrantRepository.list_scopes(repo, handoff.grant.id)
    assert Enum.any?(scope_rows, &(&1.scope_type == "work_request" and &1.scope_id == work_request.id))

    read_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-read-work-request",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => %{"work_request_id" => work_request.id}}
        },
        claimed_server
      )

    assert get_in(read_response, ["result", "structuredContent", "work_request", "id"]) == work_request.id

    {reconnect_response, reconnected_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-reconnect",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => arguments}
        },
        local_mcp_server(config, state_key)
      )

    assert get_in(reconnect_response, ["result", "structuredContent", "assignment", "grant_id"]) == handoff.grant.id
    assert get_in(reconnect_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "heartbeat"
    assert reconnected_server.session.assignment.grant_role == "architect"
    assert Scope.work_request(work_request.id) in reconnected_server.session.assignment.scopes

    {reboot_response, rebooted_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-reboot-reclaim",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => Map.put(arguments, "caller_id", "codex-local-architect-reboot")
          }
        },
        local_mcp_server(config, "local-architect-reboot-state")
      )

    assert get_in(reboot_response, ["result", "structuredContent", "assignment", "grant_id"]) == handoff.grant.id
    assert get_in(reboot_response, ["result", "structuredContent", "local_claim", "caller_id"]) == "codex-local-architect-reboot"
    assert get_in(reboot_response, ["result", "structuredContent", "local_claim", "claimed_by"]) == ArchitectHandoff.claimed_by()
    assert get_in(reboot_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "heartbeat"
    assert rebooted_server.session.assignment.grant_role == "architect"
    assert Scope.work_request(work_request.id) in rebooted_server.session.assignment.scopes
  end

  test "claim_local_architect_assignment creates a missing local handoff for existing WorkRequests", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-MISSING-HANDOFF",
        status: "ready_for_clarification"
      )

    expected_anchor_id = ArchitectHandoff.anchor_id_for_work_request(work_request)
    assert {:error, :not_found} = WorkPackageRepository.get(repo, expected_anchor_id)

    {response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-missing-handoff",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{"work_request_id" => work_request.id, "claimed_by" => "local-architect-1"}
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-missing-handoff-state")
      )

    assert get_in(response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert get_in(response, ["result", "structuredContent", "assignment", "work_package_id"]) == expected_anchor_id
    assert get_in(response, ["result", "structuredContent", "assignment", "claimed_by"]) == "local-architect-1"
    assert get_in(response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "created"
    assert claimed_server.session.assignment.grant_role == "architect"
    assert Scope.work_request(work_request.id) in claimed_server.session.assignment.scopes
    assert {:ok, anchor} = WorkPackageRepository.get(repo, expected_anchor_id)
    assert anchor.phase_id == ArchitectHandoff.phase_id_for_work_request(work_request)

    {phase_mismatch_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-missing-handoff-phase-mismatch",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{"work_request_id" => work_request.id, "phase_id" => "phase-stale"}
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-missing-handoff-phase-mismatch-state")
      )

    assert get_in(phase_mismatch_response, ["error", "data", "reason"]) == "phase_scope_mismatch"

    {repo_mismatch_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-missing-handoff-repo-mismatch",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{"work_request_id" => work_request.id, "repo" => "nextide/other"}
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-missing-handoff-repo-mismatch-state")
      )

    assert get_in(repo_mismatch_response, ["error", "data", "reason"]) == "repo_scope_mismatch"
  end

  test "claim_local_architect_assignment reclaims old other-actor handoff lease after local recovery window", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-STALE-OTHER",
        status: "ready_for_clarification"
      )

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -6, :minute)

    assert {:ok, stale_lease} =
             ClaimLeaseService.claim(
               repo,
               handoff.anchor_package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:previous-architect", "actor_display_name" => "previous-architect"},
               now: stale_seen_at,
               stale_after_ms: :timer.hours(24)
             )

    refute ClaimLease.stale?(stale_lease, DateTime.utc_now(:microsecond))

    {response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-stale-other-reclaim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => %{"work_request_id" => work_request.id}}
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-stale-other-reclaim-state")
      )

    assert get_in(response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert get_in(response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "reclaimed"
    assert Scope.work_request(work_request.id) in claimed_server.session.assignment.scopes
    text = assert_toon_tool_text!(response)
    assert text =~ "lease: reclaimed"
    refute text =~ "grant_id"
    refute text =~ "claim_lease_id"
    refute text =~ "caller_id"

    assert {:ok, current_lease} = ClaimLeaseService.current_for_work_package(repo, handoff.anchor_package.id)
    assert current_lease.previous_claim_id == stale_lease.id
    assert current_lease.stale_after_ms == :timer.minutes(5)

    other_work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-OTHER-SCOPE",
        status: "ready_for_clarification"
      )

    write_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "stale-reclaim-other-write",
          "method" => "tools/call",
          "params" => %{
            "name" => "record_decision",
            "arguments" => %{
              "work_request_id" => other_work_request.id,
              "source_type" => "architect",
              "decision" => "Attempt write outside stale-reclaimed owner WorkRequest.",
              "rationale" => "This must remain scoped.",
              "scope_impact" => "No change.",
              "created_by" => "architect-1"
            }
          }
        },
        claimed_server
      )

    assert get_in(write_response, ["error", "data", "reason"]) == "not_found"
  end

  test "claim_local_architect_assignment recovers old grant owner after the handoff lease was released", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-RELEASED-GRANT-OWNER",
        status: "ready_for_clarification"
      )

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    old_arguments = %{"work_request_id" => work_request.id, "claimed_by" => "Codex coordinator"}

    {old_response, _old_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-old-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => old_arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-old-claim-state")
      )

    assert get_in(old_response, ["result", "structuredContent", "assignment", "claimed_by"]) == "Codex coordinator"
    assert {:ok, old_lease} = ClaimLeaseService.current_for_work_package(repo, handoff.anchor_package.id)
    assert {:ok, _released_lease} = ClaimLeaseService.release(repo, old_lease.id, reason: "operator_cleanup")

    new_arguments = %{"work_request_id" => work_request.id, "claimed_by" => "Codex janitor"}

    {response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-reclaim-released-grant-owner",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => new_arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-reclaim-released-grant-owner-state")
      )

    assert get_in(response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert get_in(response, ["result", "structuredContent", "assignment", "grant_id"]) == handoff.grant.id
    assert get_in(response, ["result", "structuredContent", "assignment", "claimed_by"]) == "Codex janitor"
    assert get_in(response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "created"
    assert Scope.work_request(work_request.id) in claimed_server.session.assignment.scopes

    text = assert_toon_tool_text!(response)
    assert text =~ "status: ok"
    assert text =~ "role: architect"
    refute text =~ "grant_id"
    refute text =~ "claim_lease_id"
    refute text =~ "caller_id"

    assert {:ok, recovered_grant} = AccessGrantRepository.get(repo, handoff.grant.id)
    assert recovered_grant.claimed_by == "Codex janitor"
  end

  test "claim_local_architect_assignment keeps recovered handoff grants live when reclaim audit fails", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-RECOVERED-AUDIT-FAILS",
        status: "ready_for_clarification"
      )

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    old_arguments = %{"work_request_id" => work_request.id, "claimed_by" => "Codex coordinator"}

    {old_response, _old_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-old-claim-audit-fails",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => old_arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-old-claim-audit-fails-state")
      )

    assert get_in(old_response, ["result", "structuredContent", "assignment", "claimed_by"]) == "Codex coordinator"
    assert {:ok, old_lease} = ClaimLeaseService.current_for_work_package(repo, handoff.anchor_package.id)

    old_lease
    |> ClaimLease.update_changeset(%{last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -6, :minute)})
    |> repo.update!()

    completed_at = ~U[2026-06-01 12:00:00.000000Z]

    repo.update!(
      Ecto.Changeset.change(work_request,
        completed_at: completed_at,
        completion_source: "derived"
      )
    )

    new_arguments = %{"work_request_id" => work_request.id, "claimed_by" => "Codex janitor"}

    {response, _failed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-recovered-audit-fails",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => new_arguments}
        },
        local_mcp_server(local_mcp_config(LocalClaimAuditFailureRepo), "local-architect-recovered-audit-fails-state")
      )

    assert get_in(response, ["error", "data", "reason"]) =~ "forced_reclaim_audit_failure"
    assert {:error, :not_found} = ClaimLeaseService.current_for_work_package(repo, handoff.anchor_package.id)

    assert {:ok, restored_grant} = AccessGrantRepository.get(repo, handoff.grant.id)
    assert restored_grant.claimed_by == "Codex coordinator"
    assert restored_grant.revoked_at == nil

    assert {:ok, restored_work_request} = WorkRequestRepository.get(repo, work_request.id)
    assert restored_work_request.completed_at == completed_at
    assert restored_work_request.completion_source == "derived"
    assert is_nil(restored_work_request.archived_at)
    assert is_nil(restored_work_request.archive_reason)
  end

  test "claim_local_architect_assignment cannot replace a bound worker role", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-ARCHITECT-CLAIM-BOUND-WORKER", base_branch: "main")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-BOUND-SESSION",
        status: "ready_for_clarification"
      )

    assert {:ok, _handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    {worker_response, worker_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-worker-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-bound-worker-state")
      )

    assert get_in(worker_response, ["result", "structuredContent", "assignment", "grant_role"]) == "worker"

    {response, server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-rebind",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => %{"work_request_id" => work_request.id}}
        },
        worker_server
      )

    assert get_in(response, ["error", "data", "reason"]) == "tool_not_callable"
    refute Map.has_key?(response["error"]["data"], "recovery")
    assert server.session.assignment.grant_role == "worker"
    assert {:ok, %ClaimLease{status: "active"}} = ClaimLeaseService.current_for_work_package(repo, package.id)
  end

  test "claim_local_architect_assignment reclaims a stale bound local session for the same WorkRequest with a new owner label", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-STALE-BOUND",
        status: "ready_for_clarification"
      )

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    old_arguments = %{"work_request_id" => work_request.id, "claimed_by" => "architect-before-reboot"}
    new_arguments = %{"work_request_id" => work_request.id, "claimed_by" => "architect-after-reboot"}

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-stale-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => old_arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-stale-state")
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert {:ok, stale_lease} = ClaimLeaseService.current_for_work_package(repo, handoff.anchor_package.id)

    stale_lease
    |> ClaimLease.update_changeset(%{last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -6, :minute)})
    |> repo.update!()

    {response, server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-rebind-after-stale-worker",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => new_arguments}
        },
        claimed_server
      )

    assert get_in(response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert get_in(response, ["result", "structuredContent", "assignment", "grant_id"]) == handoff.grant.id
    assert get_in(response, ["result", "structuredContent", "assignment", "claimed_by"]) == "architect-after-reboot"
    assert get_in(response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "reclaimed"
    assert server.session.assignment.grant_role == "architect"
    assert server.session.assignment.work_package_id == handoff.anchor_package.id
  end

  test "claim_local_architect_assignment keeps active same-anchor owners protected when owner labels differ", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-ACTIVE-BOUND",
        status: "ready_for_clarification"
      )

    assert {:ok, _handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-active-claim",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{"work_request_id" => work_request.id, "claimed_by" => "architect-before-reboot"}
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-active-state")
      )

    {response, server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-active-reclaim",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{"work_request_id" => work_request.id, "claimed_by" => "architect-after-reboot"}
          }
        },
        claimed_server
      )

    assert get_in(response, ["error", "data", "reason"]) == "claim_lease_active_for_other_actor"
    assert server.session.assignment.grant_role == "architect"
    assert server.session.assignment.claimed_by == "architect-before-reboot"
  end

  test "claim_local_architect_assignment can read trusted same-repo WorkRequests without widening writes", %{repo: repo} do
    previous_trusted_remotes = Application.get_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)
    Application.put_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes, ["https://github.com/Pimpmuckl/symphony-plus-plus.git"])

    on_exit(fn -> restore_app_env(:sympp_repo_identity_trusted_remotes, previous_trusted_remotes) end)

    owner =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-OWNER",
        status: "ready_for_slicing"
      )

    same_repo =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-SAME-REPO",
        repo: owner.repo,
        base_branch: owner.base_branch,
        status: "ready_for_slicing"
      )

    other_repo =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-OTHER-REPO",
        repo: "nextide/other",
        base_branch: owner.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, _handoff} =
             ArchitectHandoff.create_or_replay(repo, owner.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-claim",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{"work_request_id" => owner.id, "claimed_by" => "local-architect-1"}
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-same-repo-state")
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"

    same_repo_read =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "same-repo-read",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => %{"work_request_id" => same_repo.id}}
        },
        claimed_server
      )

    other_repo_read =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "other-repo-read",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => %{"work_request_id" => other_repo.id}}
        },
        claimed_server
      )

    same_repo_write =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "same-repo-write",
          "method" => "tools/call",
          "params" => %{
            "name" => "record_decision",
            "arguments" => %{
              "work_request_id" => same_repo.id,
              "source_type" => "architect",
              "decision" => "Attempt write outside owner WorkRequest.",
              "rationale" => "This should stay scoped.",
              "scope_impact" => "No change.",
              "created_by" => "local-architect-1"
            }
          }
        },
        claimed_server
      )

    assert get_in(same_repo_read, ["result", "structuredContent", "work_request", "id"]) == same_repo.id
    assert get_in(other_repo_read, ["error", "data", "reason"]) == "not_found"
    assert get_in(same_repo_write, ["error", "data", "reason"]) == "not_found"
  end

  test "claim_local_architect_assignment accepts stale local checkout repo scopes for owner repo WorkRequests", %{repo: repo} do
    checkout_path =
      TestSupport.git_repo_with_origin_fixture!("https://github.com/Pimpmuckl/nextide-saas-vod-intelligence.git",
        prefix: "sympp-local-architect-repo-alias"
      )

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-REPO-ALIAS",
        repo: "Pimpmuckl/nextide-saas-vod-intelligence",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    {1, _rows} =
      repo.update_all(
        from(package in WorkPackage, where: package.id == ^handoff.anchor_package.id),
        set: [repo: checkout_path]
      )

    {1, _rows} =
      repo.update_all(
        from(grant in AccessGrant, where: grant.id == ^handoff.grant.id),
        set: [scope_repo: checkout_path]
      )

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-repo-alias-claim",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{"work_request_id" => work_request.id, "claimed_by" => "local-architect-1"}
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-repo-alias-state")
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"

    read_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-repo-alias-read",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => %{"work_request_id" => work_request.id}}
        },
        claimed_server
      )

    assert get_in(read_response, ["result", "structuredContent", "work_request", "id"]) == work_request.id
  end

  test "claim_local_architect_assignment rejects mismatched optional scope hints", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-MISMATCH",
        status: "ready_for_clarification"
      )

    assert {:ok, _handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-mismatch",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "repo" => "nextide/other",
              "claimed_by" => "local-architect-1"
            }
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-mismatch-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "repo_scope_mismatch"
  end

  test "claim_local_architect_assignment rejects stale explicit anchor hints as scope mismatches", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-STALE-ANCHOR",
        status: "ready_for_clarification"
      )

    assert {:ok, _handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-stale-anchor",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "architect_anchor_work_package_id" => "SYMPP-WR-ARCH-stale"
            }
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-stale-anchor-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "architect_anchor_scope_mismatch"
  end

  defp handoff_opts(repo) do
    [claimed_by: ArchitectHandoff.claimed_by(), database: repo.database_path(), local_architect_claim?: true]
  end
end
