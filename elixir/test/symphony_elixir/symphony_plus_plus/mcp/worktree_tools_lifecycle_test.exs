Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorktreeToolsLifecycleTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.MCP.SessionBinding

  @moduletag :ci_slow

  test "WorkPackage worktree MCP tools prepare, audit, and cleanup a linked package", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("symphony-plus-plus/beta", prefix: "sympp-mcp-worktree")
    other_fixture = TestSupport.git_repo_fixture!("symphony-plus-plus/beta", prefix: "sympp-mcp-other-worktree")
    same_origin_repo_root = TestSupport.git_repo_with_origin_fixture!(fixture.origin, prefix: "sympp-mcp-same-origin-worktree")
    codex_home = Path.join(fixture.root, "codex-home")
    config = Config.default(repo: repo, repo_root: test_repo_root())

    {anchor, session, _grant} =
      create_phase_architect_session(
        repo,
        "SYMPP-ARCHITECT-WORKTREE-LIFECYCLE",
        [
          "dispatch:work_request"
        ],
        repo: fixture.origin
      )

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WORKTREE-LIFECYCLE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced"
      )

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(
                 id: "WRS-MCP-WORKTREE-LIFECYCLE",
                 title: "Prepare package worktree",
                 base_branch: anchor.base_branch,
                 branch_pattern: "feat/worktree-lifecycle",
                 allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_packages/**"],
                 acceptance_criteria: ["Prepare and clean worktrees."]
               )
             )

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WORKTREE-LIFECYCLE",
                 kind: work_package.kind,
                 title: work_package.title,
                 repo: work_request.repo,
                 base_branch: work_package.base_branch,
                 branch_pattern: work_package.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: work_package.allowed_file_globs,
                 acceptance_criteria: work_package.acceptance_criteria,
                 status: "ready_for_worker"
               )
             )

    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")
    assert {:ok, _linked_slice} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", package.id)

    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      assert {:ok, guarded_grant} = AccessGrantService.mint_worker_grant(repo, package.id)

      assert {:ok, guarded_claim_lease} =
               ClaimLeaseService.claim(
                 repo,
                 package.id,
                 %{"actor_kind" => "agent", "actor_id" => "local:live-grant-cleanup", "actor_display_name" => "live-grant-cleanup"},
                 stale_after_ms: 60_000
               )

      guarded_clean_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: config
        )

      guarded_clean_payload = get_in(guarded_clean_response, ["result", "structuredContent"])
      assert guarded_clean_payload["worktree"]["status"] == "already_clean"
      assert %ClaimLease{status: "active"} = repo.get!(ClaimLease, guarded_claim_lease.id)
      assert {:ok, _released_guarded_claim} = ClaimLeaseService.release(repo, guarded_claim_lease.id, reason: "test cleanup")
      assert {:ok, _revoked_guarded_grant} = AccessGrantService.revoke(repo, guarded_grant.grant.id)

      assert {:ok, already_clean_claim_lease} =
               ClaimLeaseService.claim(
                 repo,
                 package.id,
                 %{"actor_kind" => "agent", "actor_id" => "local:already-clean", "actor_display_name" => "already-clean"},
                 stale_after_ms: 60_000
               )

      already_clean_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: config
        )

      already_clean_payload = get_in(already_clean_response, ["result", "structuredContent"])
      assert already_clean_payload["worktree"]["status"] == "already_clean"
      assert already_clean_payload["work_package"]["worktree_path"] == nil
      assert %ClaimLease{status: "released", release_reason: "work_request_runtime_cleanup"} = repo.get!(ClaimLease, already_clean_claim_lease.id)

      scope_mismatch_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => other_fixture.repo_root
          },
          config: config
        )

      assert get_in(scope_mismatch_response, ["error", "data", "reason"]) == "target_repo_root_scope_mismatch"

      wrong_branch_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root,
            "branch" => "feat/wrong-base"
          },
          config: config
        )

      assert get_in(wrong_branch_response, ["error", "data", "reason"]) == "branch_scope_mismatch"

      prepare_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root
          },
          config: config
        )

      prepare_payload = get_in(prepare_response, ["result", "structuredContent"])
      assert prepare_payload["worktree"]["status"] == "prepared"
      assert prepare_payload["work_package"]["worktree_path"] == prepare_payload["worktree"]["path"]
      assert comparable_path(prepare_payload["worktree"]["target_repo_root"]) == comparable_path(fixture.repo_root)
      assert prepare_payload["worker_launch"]["workspace_path"] == prepare_payload["worktree"]["path"]
      assert prepare_payload["worker_launch"]["instruction"] =~ "Use this worktree only"
      assert is_binary(prepare_payload["audit_event"]["id"])
      refute Map.has_key?(prepare_payload["audit_event"], "payload")
      assert File.dir?(prepare_payload["worktree"]["path"])

      same_origin_cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => same_origin_repo_root
          },
          config: config
        )

      assert get_in(same_origin_cleanup_response, ["error", "data", "reason"]) == "invalid_worktree_path"
      assert File.dir?(prepare_payload["worktree"]["path"])

      assert {:ok, _foreign_root_package} =
               WorkPackageRepository.update(repo, package.id, %{worktree_target_repo_root: other_fixture.repo_root})

      stored_scope_mismatch_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: config
        )

      assert get_in(stored_scope_mismatch_response, ["error", "data", "reason"]) == "target_repo_root_scope_mismatch"
      assert File.dir?(prepare_payload["worktree"]["path"])
      assert {:ok, _restored_root_package} = WorkPackageRepository.update(repo, package.id, %{worktree_target_repo_root: fixture.repo_root})

      assert {:ok, cleanup_claim_lease} =
               ClaimLeaseService.claim(
                 repo,
                 package.id,
                 %{"actor_kind" => "agent", "actor_id" => "local:worktree-cleanup", "actor_display_name" => "worktree-cleanup"},
                 stale_after_ms: 60_000
               )

      cleanup_binding_id = SessionBinding.binding_id("cleanup-client", "cleanup-state")

      assert {:ok, cleanup_binding} =
               %SessionBinding{}
               |> SessionBinding.changeset(%{
                 id: cleanup_binding_id,
                 client_key_hash: SessionBinding.client_key_hash("cleanup-client"),
                 initialized: true,
                 recoverable: true,
                 claim_lease_id: cleanup_claim_lease.id,
                 work_package_id: package.id,
                 grant_role: "worker",
                 claimed_by: "worktree-cleanup",
                 last_seen_at: DateTime.utc_now(:microsecond)
               })
               |> repo.insert()

      cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: config
        )

      cleanup_payload = get_in(cleanup_response, ["result", "structuredContent"])
      assert cleanup_payload["worktree"]["status"] == "cleaned"
      assert cleanup_payload["audit_event"]["summary"] == "Success removing worktree. Subagent can be closed now."
      assert cleanup_payload["work_package"]["worktree_path"] == nil
      assert is_binary(cleanup_payload["audit_event"]["id"])
      refute Map.has_key?(cleanup_payload["audit_event"], "payload")
      refute File.exists?(prepare_payload["worktree"]["path"])
      assert %ClaimLease{status: "released", release_reason: "work_request_runtime_cleanup"} = repo.get!(ClaimLease, cleanup_claim_lease.id)
      refute repo.get(SessionBinding, cleanup_binding.id)

      stale_prepare_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root
          },
          config: config
        )

      stale_prepare_payload = get_in(stale_prepare_response, ["result", "structuredContent"])
      assert stale_prepare_payload["worktree"]["status"] == "prepared"
      assert {:ok, _legacy_package} = WorkPackageRepository.update(repo, package.id, %{worktree_target_repo_root: nil})
      File.rm_rf!(stale_prepare_payload["worktree"]["path"])

      wrong_stale_cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: Config.default(repo: repo, repo_root: same_origin_repo_root)
        )

      assert get_in(wrong_stale_cleanup_response, ["error", "data", "reason"]) == "target_repo_root_required"

      assert {:ok, stale_cleanup_claim_lease} =
               ClaimLeaseService.claim(
                 repo,
                 package.id,
                 %{"actor_kind" => "agent", "actor_id" => "local:stale-worktree-cleanup", "actor_display_name" => "stale-worktree-cleanup"},
                 stale_after_ms: 60_000
               )

      assert {:ok, paused_stale_cleanup_claim_lease} =
               ClaimLeaseService.pause(
                 repo,
                 stale_cleanup_claim_lease.id,
                 %{"actor_kind" => "operator", "actor_id" => "operator:pause"},
                 reason: "operator pause"
               )

      stale_cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: Config.default(repo: repo, repo_root: fixture.repo_root)
        )

      stale_cleanup_payload = get_in(stale_cleanup_response, ["result", "structuredContent"])
      assert stale_cleanup_payload["worktree"]["status"] == "stale_record_cleared"
      assert stale_cleanup_payload["work_package"]["worktree_path"] == nil
      assert is_binary(stale_cleanup_payload["audit_event"]["id"])
      refute Map.has_key?(stale_cleanup_payload["audit_event"], "payload")
      assert %ClaimLease{status: "paused"} = repo.get!(ClaimLease, paused_stale_cleanup_claim_lease.id)
    after
      restore_env("CODEX_HOME", previous_codex_home)
    end

    assert {:ok, cleaned_package} = WorkPackageRepository.get(repo, package.id)
    assert cleaned_package.worktree_path == nil

    events =
      repo.all(
        from(progress_event in ProgressEvent,
          where: progress_event.work_package_id == ^package.id,
          order_by: [asc: progress_event.sequence]
        )
      )

    assert Enum.map(events, & &1.payload["source_tool"]) == [
             "cleanup_work_request_work_package_runtime",
             "prepare_work_package_worktree",
             "cleanup_work_request_work_package_runtime",
             "cleanup_work_package_worktree",
             "cleanup_work_package_worktree"
           ]

    assert %{
             "source_tool" => "prepare_work_package_worktree",
             "worktree_path" => "[REDACTED]",
             "target_repo_root" => "[REDACTED]"
           } = Enum.find(events, &(&1.payload["source_tool"] == "prepare_work_package_worktree")).payload

    assert %{
             "source_tool" => "cleanup_work_package_worktree",
             "worktree_path" => "[REDACTED]",
             "target_repo_root" => "[REDACTED]"
           } = Enum.find(events, &(&1.payload["source_tool"] == "cleanup_work_package_worktree" and &1.status == "cleaned")).payload

    assert %{
             "source_tool" => "cleanup_work_package_worktree",
             "status" => "stale_record_cleared"
           } =
             Enum.find(
               events,
               &(&1.payload["source_tool"] == "cleanup_work_package_worktree" and &1.status == "stale_record_cleared")
             ).payload
  end
end
