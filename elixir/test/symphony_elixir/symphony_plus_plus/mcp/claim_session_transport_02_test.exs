Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionTransport02Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "claim_local_assignment accepts prepared concrete branch for templated package branch", %{repo: repo} do
    package =
      create_local_claim_package!(repo, "SYMPP-LOCAL-PREPARED-BRANCH", branch_pattern: "agent/{{work_package_id}}/{{slug}}")

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    prepared_branch = "agent/SYMPP-LOCAL-PREPARED-BRANCH/final-review-corrections"
    File.mkdir_p!(Path.join(package.worktree_path, ".git"))
    File.write!(Path.join([package.worktree_path, ".git", "HEAD"]), "ref: refs/heads/#{prepared_branch}\n")

    try do
      {response, claimed_server} =
        Server.handle_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "local-prepared-branch",
            "method" => "tools/call",
            "params" => %{
              "name" => "claim_local_assignment",
              "arguments" => local_assignment_claim_args(package, %{"branch" => prepared_branch})
            }
          },
          local_mcp_server(local_mcp_config(repo), "local-prepared-branch-state")
        )

      assert get_in(response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
      assert claimed_server.session.assignment.work_package_id == package.id
      refute inspect(response) =~ minted.work_key.secret
    after
      File.rm_rf!(package.worktree_path)
    end
  end

  test "claim_local_assignment rejects unrelated prepared branch for templated package branch", %{repo: repo} do
    package =
      create_local_claim_package!(repo, "SYMPP-LOCAL-TEMPLATE-BRANCH-SCOPE", branch_pattern: "agent/{{work_package_id}}/{{slug}}")

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    unrelated_branch = "feature/main-retarget"
    File.mkdir_p!(Path.join(package.worktree_path, ".git"))
    File.write!(Path.join([package.worktree_path, ".git", "HEAD"]), "ref: refs/heads/#{unrelated_branch}\n")

    try do
      {response, _server} =
        Server.handle_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "local-template-branch-scope",
            "method" => "tools/call",
            "params" => %{
              "name" => "claim_local_assignment",
              "arguments" => local_assignment_claim_args(package, %{"branch" => unrelated_branch})
            }
          },
          local_mcp_server(local_mcp_config(repo), "local-template-branch-scope-state")
        )

      assert get_in(response, ["error", "data", "reason"]) == "branch_scope_mismatch"
      assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
      assert unclaimed_grant.claimed_at == nil
    after
      File.rm_rf!(package.worktree_path)
    end
  end

  test "claim_local_assignment diagnoses legacy wildcard branch patterns before claiming", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-WILDCARD-BRANCH")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    repo.update_all(
      from(work_package in WorkPackage, where: work_package.id == ^package.id),
      set: [branch_pattern: "feat/live-triggers-v1-native-audio-evidence-*"]
    )

    wildcard_package = repo.get!(WorkPackage, package.id)
    prepared_branch = "feat/live-triggers-v1-native-audio-evidence-worker"
    File.mkdir_p!(Path.join(wildcard_package.worktree_path, ".git"))
    File.write!(Path.join([wildcard_package.worktree_path, ".git", "HEAD"]), "ref: refs/heads/#{prepared_branch}\n")

    try do
      {response, _server} =
        Server.handle_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "local-wildcard-branch-pattern",
            "method" => "tools/call",
            "params" => %{
              "name" => "claim_local_assignment",
              "arguments" => local_assignment_claim_args(wildcard_package, %{"branch" => prepared_branch})
            }
          },
          local_mcp_server(local_mcp_config(repo), "local-wildcard-branch-pattern-state")
        )

      assert get_in(response, ["error", "code"]) == -32_602
      assert get_in(response, ["error", "data", "reason"]) == "unsupported_branch_pattern_wildcard"
      assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
      assert unclaimed_grant.claimed_at == nil
      refute repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id))
    after
      File.rm_rf!(wildcard_package.worktree_path)
    end
  end

  test "claim_local_assignment rejects literal templated branch without prepared git metadata", %{repo: repo} do
    package =
      create_local_claim_package!(repo, "SYMPP-LOCAL-TEMPLATE-UNPREPARED", branch_pattern: "agent/{{work_package_id}}/{{slug}}")

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-template-unprepared",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => local_assignment_claim_args(package, %{"branch" => package.branch_pattern})
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-template-unprepared-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "branch_scope_mismatch"
    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
    refute repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id))
  end

  test "claim_local_assignment rejects retargeted branch for concrete package branch", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-RETARGETED-BRANCH")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    retargeted_branch = "agent/SYMPP-LOCAL-RETARGETED-BRANCH/retargeted"
    File.mkdir_p!(Path.join(package.worktree_path, ".git"))
    File.write!(Path.join([package.worktree_path, ".git", "HEAD"]), "ref: refs/heads/#{retargeted_branch}\n")

    try do
      {response, _server} =
        Server.handle_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "local-retargeted-branch",
            "method" => "tools/call",
            "params" => %{
              "name" => "claim_local_assignment",
              "arguments" => local_assignment_claim_args(package, %{"branch" => retargeted_branch})
            }
          },
          local_mcp_server(local_mcp_config(repo), "local-retargeted-branch-state")
        )

      assert get_in(response, ["error", "data", "reason"]) == "branch_scope_mismatch"
      assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
      assert unclaimed_grant.claimed_at == nil
      refute repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id))
    after
      File.rm_rf!(package.worktree_path)
    end
  end

  test "claim_local_assignment rereads same-worker lease after concurrent local insert race", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-CLAIM-RACE")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    LocalClaimInsertRaceRepo.arm()

    try do
      {response, _server} =
        Server.handle_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "local-claim-race",
            "method" => "tools/call",
            "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
          },
          local_mcp_server(local_mcp_config(LocalClaimInsertRaceRepo), "local-claim-race-state")
        )

      assert get_in(response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
      assert get_in(response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "heartbeat"
      refute inspect(response) =~ minted.work_key.secret
    after
      LocalClaimInsertRaceRepo.disarm()
    end

    assert %ClaimLease{actor_display_name: "local-worker-1"} =
             repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id))

    assert {:ok, claimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert claimed_grant.claimed_by == "local-worker-1"
  end

  test "claim_local_assignment preserves other-worker lease after concurrent local insert race", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-CLAIM-RACE-OTHER")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    LocalClaimInsertRaceRepo.arm(%{
      actor_id: "local:other-worker",
      actor_display_name: "other-worker"
    })

    try do
      {response, _server} =
        Server.handle_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "local-claim-race-other",
            "method" => "tools/call",
            "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
          },
          local_mcp_server(local_mcp_config(LocalClaimInsertRaceRepo), "local-claim-race-other-state")
        )

      assert get_in(response, ["error", "data", "reason"]) == "active_claim_exists"
      refute inspect(response) =~ minted.work_key.secret
    after
      LocalClaimInsertRaceRepo.disarm()
    end

    assert %ClaimLease{actor_display_name: "other-worker"} =
             repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id))

    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
  end

  test "claim_local_assignment rejects wrong local scope without claiming the grant", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-WRONG-SCOPE")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-wrong-scope",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => local_assignment_claim_args(package, %{"base_branch" => "main"})
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-wrong-scope-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "base_branch_scope_mismatch"
    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
    assert unclaimed_grant.claimed_by == nil
  end

  test "claim_local_assignment rejects packages without recorded local worktree scope", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-MISSING-WORKTREE", worktree_path: nil)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-missing-worktree",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => local_assignment_claim_args(package, %{"worktree_path" => local_claim_worktree_path(package.id)})
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-missing-worktree-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "worktree_scope_required"
    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
  end

  test "claim_local_assignment rejects terminal work packages before claiming", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-TERMINAL")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    package = repo.update!(Ecto.Changeset.change(package, status: "closed"))

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-terminal",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "local-terminal-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "work_package_terminal"
    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
    assert unclaimed_grant.claimed_by == nil
    assert repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id)) == nil
  end

  test "claim_local_assignment requires local daemon generated state", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-TRUST-REQUIRED")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-trust-required",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        Server.new(local_mcp_config(repo), initialized: true, local_daemon_trusted: false, state_key: "caller-supplied-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "local_daemon_trust_required"
    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
  end

  test "claim_local_assignment requires explicit local HTTP MCP state", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-STATE-REQUIRED")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-state-required",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        Server.new(local_mcp_config(repo), initialized: true)
      )

    assert get_in(response, ["error", "data", "reason"]) == "local_mcp_session_required"
    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
    assert repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id)) == nil
  end

  test "claim_local_assignment returns invalid params for malformed arguments", %{repo: repo} do
    response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-malformed-arguments",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => []}
        },
        local_mcp_server(local_mcp_config(repo), "local-malformed-arguments-state")
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "invalid_tool_arguments"
  end

  test "claim_local_assignment treats paused leases as pause exempt instead of stale", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-PAUSED-LEASE")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)

    {_claim_response, _claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-paused-initial",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-paused-initial-state")
      )

    assert {:ok, %ClaimLease{id: lease_id} = lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert {:ok, paused_lease} = ClaimLeaseService.pause(repo, lease.id, %{"actor_id" => "operator"}, reason: "operator pause")

    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -10, :second)

    paused_lease
    |> ClaimLease.update_changeset(%{last_seen_at: stale_seen_at, stale_after_ms: 1})
    |> repo.update!()

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-paused-reclaim-denied",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-paused-reclaim-denied-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "claim_lease_paused"
    assert {:ok, %ClaimLease{id: ^lease_id, status: "paused"}} = ClaimLeaseService.current_for_work_package(repo, package.id)

    assert repo.aggregate(
             from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id and claim_lease.status == "reclaimed"),
             :count
           ) == 0
  end

  test "claim_local_assignment records audit evidence when reclaiming a stale lease", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-STALE-RECLAIM")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    assert {:ok, stale_lease} =
             ClaimLeaseService.claim(
               repo,
               package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:stale-worker", "actor_display_name" => "stale-worker"},
               now: DateTime.add(DateTime.utc_now(:microsecond), -10, :second),
               stale_after_ms: 1
             )

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-stale-reclaim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "local-stale-reclaim-state")
      )

    assert get_in(response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "reclaimed"
    assert get_in(response, ["result", "structuredContent", "local_claim", "reason_codes"]) == ["claim_lease_reclaimed", "worker_recycled"]
    assert get_in(response, ["result", "structuredContent", "local_claim", "claim_event", "status"]) == "claim_lease_reclaimed"
    text = assert_toon_tool_text!(response)
    assert text =~ "lease: reclaimed"
    assert text =~ "warning: stale_claim_reclaimed"
    refute text =~ "claim_lease_id"
    refute text =~ "caller_id"

    assert {:ok, reclaimed_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert reclaimed_lease.previous_claim_id == stale_lease.id

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.any?(progress_events, &(&1.status == "claim_lease_reclaimed" and &1.payload["previous_claim_id"] == stale_lease.id))
  end

  test "claim_local_assignment reclaims old no-heartbeat residue after the local recovery window", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-SHORT-STALE-RECLAIM")
    assert {:ok, old_minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -6, :minute)

    assert {:ok, stale_lease} =
             ClaimLeaseService.claim(
               repo,
               package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:stale-worker", "actor_display_name" => "stale-worker"},
               now: stale_seen_at,
               access_grant_id: old_minted.grant.id,
               stale_after_ms: :timer.hours(24)
             )

    refute ClaimLease.stale?(stale_lease, DateTime.utc_now(:microsecond))
    assert {:ok, _revoked} = AccessGrantService.revoke(repo, old_minted.grant.id)
    assert {:ok, _replacement_minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-short-stale-reclaim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "local-short-stale-reclaim-state")
      )

    assert get_in(response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "reclaimed"
    assert {:ok, reclaimed_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert reclaimed_lease.previous_claim_id == stale_lease.id
    assert reclaimed_lease.access_grant_id == nil
    assert reclaimed_lease.stale_after_ms == :timer.minutes(5)

    {assignment_response, _server} =
      Server.handle_state(
        %{"jsonrpc" => "2.0", "id" => "assignment-after-old-grant-reclaim", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        claimed_server
      )

    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
  end

  test "claim_local_assignment rolls back reclaimed leases when audit append fails", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-RECLAIM-AUDIT-FAILS")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    assert {:ok, stale_lease} =
             ClaimLeaseService.claim(
               repo,
               package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:stale-worker", "actor_display_name" => "stale-worker"},
               now: DateTime.add(DateTime.utc_now(:microsecond), -2, :second),
               stale_after_ms: 1
             )

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-reclaim-audit-fails",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(LocalClaimAuditFailureRepo), "local-reclaim-audit-fails-state")
      )

    assert get_in(response, ["error", "data", "reason"]) =~ "forced_reclaim_audit_failure"
    assert {:ok, restored_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert restored_lease.id == stale_lease.id
    assert restored_lease.status == "active"

    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
    assert unclaimed_grant.revoked_at == nil

    statuses =
      repo.all(
        from(claim_lease in ClaimLease,
          where: claim_lease.work_package_id == ^package.id,
          select: {claim_lease.id, claim_lease.status, claim_lease.release_reason}
        )
      )

    assert statuses == [{stale_lease.id, "active", nil}]
  end

  test "claim_local_assignment restores a reclaimed lease when grant binding fails", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-RECLAIM-FAILS")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    assert {:ok, _stale_lease} =
             ClaimLeaseService.claim(
               repo,
               package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:stale-worker", "actor_display_name" => "stale-worker"},
               now: DateTime.add(DateTime.utc_now(:microsecond), -2, :second),
               stale_after_ms: 1
             )

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-reclaim-fails",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "local-reclaim-fails-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "revoked"
    assert {:ok, restored_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert restored_lease.status == "active"
    assert restored_lease.actor_display_name == "stale-worker"

    statuses =
      repo.all(
        from(claim_lease in ClaimLease,
          where: claim_lease.work_package_id == ^package.id,
          select: {claim_lease.status, claim_lease.release_reason}
        )
      )

    assert statuses == [{"active", nil}]
  end

  test "claim_local_assignment preserves existing heartbeat leases when permanent grant binding fails", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-HEARTBEAT-FAILS")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)

    {_claim_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-heartbeat-initial",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-heartbeat-initial-state")
      )

    assert {:ok, %ClaimLease{id: lease_id, status: "active"}} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-heartbeat-fails",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-heartbeat-fails-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "revoked"
    assert {:ok, preserved_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert preserved_lease.id == lease_id
    assert preserved_lease.status == "active"

    statuses =
      repo.all(
        from(claim_lease in ClaimLease,
          where: claim_lease.work_package_id == ^package.id,
          select: {claim_lease.id, claim_lease.status, claim_lease.release_reason}
        )
      )

    assert statuses == [{lease_id, "active", nil}]

    assert {:ok, replacement} = AccessGrantService.mint_worker_grant(repo, package.id)

    {replacement_response, _replacement_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-heartbeat-replacement",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => arguments
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-heartbeat-replacement-state")
      )

    assert get_in(replacement_response, ["result", "structuredContent", "assignment", "grant_id"]) == replacement.grant.id
  end

  test "claim_local_assignment rejects active authority-lost lease before replacement worker claim", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-AUTHORITY-LOST")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)

    {_claim_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-authority-lost-initial",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-authority-lost-initial-state")
      )

    assert {:ok, %ClaimLease{id: original_lease_id, actor_display_name: "local-worker-1"}} =
             ClaimLeaseService.current_for_work_package(repo, package.id)

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)
    assert {:ok, _replacement} = AccessGrantService.mint_worker_grant(repo, package.id)

    {replacement_response, _replacement_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-authority-lost-replacement",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" =>
              local_assignment_claim_args(package, %{
                "caller_id" => "codex-local-authority-lost-replacement",
                "claimed_by" => "replacement-worker"
              })
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-authority-lost-replacement-state")
      )

    assert get_in(replacement_response, ["error", "data", "reason"]) == "claim_lease_active_for_other_actor"

    assert {:ok, %ClaimLease{id: ^original_lease_id, actor_display_name: "local-worker-1", status: "active"}} =
             ClaimLeaseService.current_for_work_package(repo, package.id)

    statuses =
      repo.all(
        from(claim_lease in ClaimLease,
          where: claim_lease.work_package_id == ^package.id,
          select: {claim_lease.id, claim_lease.status, claim_lease.release_reason}
        )
      )

    assert {original_lease_id, "active", nil} in statuses
    refute Enum.any?(statuses, fn {id, status, _reason} -> id != original_lease_id and status == "active" end)
  end

  test "claim_local_assignment accepts linked WorkRequest with slice delivery base", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-WR-DELIVERY-BASE")

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-DELIVERY-BASE",
        repo: package.repo,
        base_branch: "main",
        status: "ready_for_slicing"
      )

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(
                 id: "WRS-MCP-LOCAL-DELIVERY-BASE",
                 base_branch: package.base_branch,
                 branch_pattern: package.branch_pattern
               )
             )

    assert {:ok, _canonical_package} =
             CanonicalWorkPackageFixtures.dispatch_work_package(
               repo,
               work_request.id,
               work_package.id,
               "planned",
               package.id
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-wr-delivery-base",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => local_assignment_claim_args(package)
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-wr-delivery-base-state")
      )

    assert get_in(response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert claimed_server.session.assignment.work_package_id == package.id
    assert {:ok, claimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert claimed_grant.claimed_at != nil
    refute inspect(response) =~ minted.work_key.secret
  end

  test "final sync tools remain idempotent after claim_local_assignment reconnect", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-FINAL-SYNC", status: "ci_waiting")
    append_done_plan(repo, package.id)
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)
    config = local_mcp_config(repo)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-final-sync-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(config, "local-final-sync-claim-state")
      )

    head_sha = "abcdef1234567890abcdef1234567890abcdef12"
    attach_tool(repo, claimed_server.session, "attach_branch", %{"branch" => package.branch_pattern, "head_sha" => head_sha})
    attach_tool(repo, claimed_server.session, "attach_pr", %{"number" => 258, "head_sha" => head_sha})

    sync_args = %{
      "idempotency_key" => "sync-pr-after-reconnect",
      "recovery" => %{
        "number" => 258,
        "repository" => package.repo,
        "head_sha" => head_sha,
        "branch" => package.branch_pattern,
        "base_branch" => package.base_branch,
        "base_sha" => "base-head",
        "changed_files" => [],
        "check_summary" => %{"status" => "passing"},
        "review_state" => %{"status" => "unknown"},
        "merge_state" => %{"status" => "unknown", "merged" => false},
        "observed_at" => "2026-08-17T10:00:00Z"
      }
    }

    sync_response = attach_tool(repo, claimed_server.session, "sync_pr", sync_args)

    review_args = %{
      "summary" => "Ready after local reconnect",
      "tests" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true
    }

    review_response = attach_tool(repo, claimed_server.session, "submit_review_package", review_args)

    {_reconnect_response, reconnected_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-final-sync-reconnect",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(config, "local-final-sync-reconnect-state")
      )

    sync_replay_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "sync-replay", "method" => "tools/call", "params" => %{"name" => "sync_pr", "arguments" => sync_args}},
        repo: repo,
        session: reconnected_server.session
      )

    review_replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "review-replay",
          "method" => "tools/call",
          "params" => %{"name" => "submit_review_package", "arguments" => review_args}
        },
        repo: repo,
        session: reconnected_server.session
      )

    assert get_in(sync_replay_response, ["result", "structuredContent", "progress_event", "id"]) ==
             get_in(sync_response, ["result", "structuredContent", "progress_event", "id"])

    assert get_in(review_replay_response, ["result", "structuredContent", "progress_event", "id"]) ==
             get_in(review_response, ["result", "structuredContent", "progress_event", "id"])

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.count(progress_events, &(&1.status == "pr_synced")) == 1
    assert Enum.count(progress_events, &(&1.status == "review_package_submitted")) == 1
  end
end
