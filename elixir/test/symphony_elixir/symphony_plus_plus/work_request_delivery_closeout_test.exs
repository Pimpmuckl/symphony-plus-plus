defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestDeliveryCloseoutTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.TestSupport

  setup_all do
    database_path = database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(AgentRun)
    repo.delete_all(ClaimLease)
    repo.delete_all(AccessGrant)
    repo.delete_all(ProgressEvent)
    repo.delete_all(WorkPackageDelivery)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "PR merged closeout records delivery, merges the linked package, appends progress, and refreshes completion", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready_for_merge")

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-pr-merged",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/123",
        pr_number: 123,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 12:00:00.000000Z],
        merge_commit_sha: "abc123"
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "pr_merged"

    assert repo.get!(WorkPackage, linked_package.id).status == "merged"
    assert %WorkRequest{completed_at: %DateTime{}} = repo.get!(WorkRequest, work_request.id)

    assert [event] = repo.all(ProgressEvent)
    assert event.work_package_id == linked_package.id
    assert event.status == "merged"
    assert event.payload["source_tool"] == "record_work_package_delivery"
    assert event.payload["outcome"] == "pr_merged"
    assert event.payload["previous_status"] == "ready_for_merge"
    assert event.payload["next_status"] == "merged"

    assert {:ok, _drifted_after_closeout} = WorkPackageRepository.update(repo, linked_package.id, %{title: "Drifted after closeout"})
    assert {:ok, replay} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert replay.id == delivery.id
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1
    assert repo.aggregate(ProgressEvent, :count, :id) == 1
    assert repo.get!(WorkPackage, linked_package.id).status == "merged"
  end

  test "delivery evidence remains terminal truth after package status drift", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready_for_merge")

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-terminal-truth",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/130",
        pr_number: 130,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 13:00:00.000000Z],
        merge_commit_sha: "abc130"
      })

    assert {:ok, _delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert {:ok, _drifted} = WorkPackageRepository.update(repo, linked_package.id, %{status: "ready_for_worker"})

    assert {:error, :work_package_terminal} =
             AgentRunRepository.start_run(repo, %{work_package_id: linked_package.id, status: "starting"})

    assert {:error, :work_package_terminal} = AccessGrantService.mint_worker_grant(repo, linked_package.id)

    assert {:error, :work_package_terminal} =
             ClaimLeaseService.claim(
               repo,
               linked_package.id,
               %{
                 "actor_kind" => "agent",
                 "actor_id" => "local:delivery-residue",
                 "actor_display_name" => "delivery-residue"
               },
               stale_after_ms: 60_000
             )
  end

  test "PR merged recovery closeout merges stale linked package and retires worker grant", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready_for_worker")

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "stale-worker")

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-pr-merged-stale-worker",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/124",
        pr_number: 124,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 12:30:00.000000Z],
        merge_commit_sha: "abc124"
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "pr_merged"

    assert repo.get!(WorkPackage, linked_package.id).status == "merged"
    assert %AccessGrant{revoked_at: %DateTime{}} = repo.get!(AccessGrant, minted.grant.id)

    assert [event] = repo.all(ProgressEvent)
    assert event.status == "merged"
    assert event.payload["previous_status"] == "ready_for_worker"
    assert event.payload["retired_worker_grant_ids"] == [minted.grant.id]
    assert "worker_grant_active" in event.payload["runtime_reason_codes_before_closeout"]

    assert {:ok, %{counts: %{"delivered" => 1}, work_packages: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert slice.operational_state.key == "delivered"
    assert slice.work_package.raw_status == "merged"
  end

  test "PR merged recovery closeout merges stale linked package and retires active claim lease", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "implementing")

    assert {:ok, claim_lease} =
             ClaimLeaseService.claim(
               repo,
               linked_package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:pr-recovery-claim", "actor_display_name" => "worker-claim"},
               stale_after_ms: 60_000
             )

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-pr-merged-active-runtime",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/125",
        pr_number: 125,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 12:45:00.000000Z],
        merge_commit_sha: "abc125"
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "pr_merged"

    assert repo.get!(WorkPackage, linked_package.id).status == "merged"
    assert %ClaimLease{status: "released", release_reason: "pr_merged_delivery_closeout"} = repo.get!(ClaimLease, claim_lease.id)

    assert [event] = repo.all(ProgressEvent)
    assert event.payload["previous_status"] == "implementing"
    assert event.payload["retired_claim_lease_ids"] == [claim_lease.id]
    assert "claim_lease_active" in event.payload["runtime_reason_codes_before_closeout"]

    assert {:ok, %{counts: %{"delivered" => 1}, work_packages: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert slice.operational_state.key == "delivered"
    assert slice.work_package.raw_status == "merged"
  end

  test "delivery replay cleans the worktree after closeout retires worker authority", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready_for_worker")
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-closeout-retired-authority")
    codex_home = Path.join(fixture.root, "codex-home")
    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      assert {:ok, prepared} =
               WorktreeLifecycle.prepare(
                 repo,
                 linked_package.id,
                 %{
                   "repo_root" => fixture.repo_root,
                   "base_branch" => linked_package.base_branch,
                   "branch" => "feat/closeout-retired-authority"
                 },
                 codex_home: codex_home
               )

      assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
      assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "retired-worker")

      attrs =
        delivery_attrs(%{
          outcome: "pr_merged",
          idempotency_key: "delivery-pr-merged-retired-authority",
          pr_url: "https://github.com/nextide/symphony-plus-plus/pull/128",
          pr_number: 128,
          pr_repository: "nextide/symphony-plus-plus",
          pr_merged_at: ~U[2026-05-24 12:50:00.000000Z],
          merge_commit_sha: "abc128"
        })

      assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
      assert File.dir?(prepared.worktree_path)
      assert %AccessGrant{revoked_at: %DateTime{}} = repo.get!(AccessGrant, minted.grant.id)

      assert {:ok, ^delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
      refute File.exists?(prepared.worktree_path)
      assert repo.get!(WorkPackage, linked_package.id).worktree_path == nil
    after
      WorktreeLifecycle.cleanup(repo, linked_package.id, codex_home: codex_home)
      restore_env("CODEX_HOME", previous_codex_home)
    end
  end

  if match?({:win32, _}, :os.type()) do
    @tag skip: "System.cmd cannot execute the shell wrapper directly on Windows"
  end

  test "delivery closeout retries proof-gated cleanup after partial worktree removal", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready_for_merge")
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-closeout-cleanup-retry")
    codex_home = Path.join(fixture.root, "codex-home")
    fake_bin = Path.join(fixture.root, "fake-bin")
    marker = Path.join(fixture.root, "failed-once")
    real_git = System.find_executable("git") || flunk("git is required")
    previous_env = Map.new(["CODEX_HOME", "PATH", "SYMPP_REAL_GIT", "SYMPP_FAIL_ONCE_MARKER"], &{&1, System.get_env(&1)})

    try do
      install_fail_once_git!(fake_bin)

      System.put_env(%{
        "CODEX_HOME" => codex_home,
        "PATH" => TestSupport.path_with_prepended(fake_bin, System.get_env("PATH")),
        "SYMPP_REAL_GIT" => real_git,
        "SYMPP_FAIL_ONCE_MARKER" => marker
      })

      assert {:ok, prepared} =
               WorktreeLifecycle.prepare(repo, linked_package.id, %{
                 "repo_root" => fixture.repo_root,
                 "base_branch" => linked_package.base_branch,
                 "branch" => "fix/closeout-cleanup-retry"
               })

      attrs =
        delivery_attrs(%{
          outcome: "pr_merged",
          idempotency_key: "delivery-pr-merged-cleanup-retry",
          pr_url: "https://github.com/nextide/symphony-plus-plus/pull/457",
          pr_merged_at: ~U[2026-05-24 12:59:00.000000Z],
          merge_commit_sha: "abc457"
        })

      assert {:ok, _delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
      assert File.exists?(marker)
      refute File.exists?(prepared.worktree_path)
      assert repo.get!(WorkPackage, linked_package.id).worktree_path == nil
      refute Enum.any?(repo.all(ProgressEvent), &(&1.status == "worktree_cleanup_failed"))
    after
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
      WorktreeLifecycle.cleanup(repo, linked_package.id, codex_home: codex_home)
    end
  end

  test "terminal dispatch retirement completes deferred delivery worktree cleanup", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready_for_worker")
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-closeout-active-runner")
    codex_home = Path.join(fixture.root, "codex-home")
    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      assert {:ok, prepared} =
               WorktreeLifecycle.prepare(
                 repo,
                 linked_package.id,
                 %{
                   "repo_root" => fixture.repo_root,
                   "base_branch" => linked_package.base_branch,
                   "branch" => "feat/closeout-active-runner"
                 },
                 codex_home: codex_home
               )

      assert {:ok, agent_run} =
               AgentRunRepository.start_run(repo, %{
                 work_package_id: linked_package.id,
                 status: "retrying",
                 last_seen_at: DateTime.utc_now(:microsecond)
               })

      attrs =
        delivery_attrs(%{
          outcome: "pr_merged",
          idempotency_key: "delivery-pr-merged-active-agent-runtime",
          pr_url: "https://github.com/nextide/symphony-plus-plus/pull/129",
          pr_number: 129,
          pr_repository: "nextide/symphony-plus-plus",
          pr_merged_at: ~U[2026-05-24 12:55:00.000000Z],
          merge_commit_sha: "abc129"
        })

      assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
      assert delivery.outcome == "pr_merged"
      assert repo.get!(WorkPackage, linked_package.id).status == "merged"
      assert %AgentRun{status: "retrying"} = repo.get!(AgentRun, agent_run.id)
      assert %WorkRequest{completed_at: %DateTime{}} = repo.get!(WorkRequest, work_request.id)
      assert File.dir?(prepared.worktree_path)

      assert {:ok, archived} = Service.archive(repo, work_request.id)
      assert {:ok, %AgentRun{status: "retrying"}} = AgentRunRepository.heartbeat(repo, agent_run.id)

      assert %WorkRequest{completed_at: completed_at, archived_at: archived_at} = repo.get!(WorkRequest, work_request.id)
      assert completed_at == archived.completed_at
      assert archived_at == archived.archived_at
      Process.sleep(100)
      assert File.dir?(prepared.worktree_path)
      dirty_path = Path.join(prepared.worktree_path, "dirty.txt")
      File.write!(dirty_path, "preserve cleanup failure")

      assert {:error, :work_package_terminal} =
               AgentRunRepository.start_run(
                 repo,
                 %{work_package_id: linked_package.id, status: "starting", attempt: 2},
                 replace_agent_run_id: agent_run.id
               )

      assert %AgentRun{status: "failed", reason: "work package became terminal before retry dispatch"} =
               repo.get!(AgentRun, agent_run.id)

      assert_eventually(fn ->
        assert File.dir?(prepared.worktree_path)

        assert Enum.any?(repo.all(ProgressEvent), fn event ->
                 event.payload["type"] == "work_request_delivery_worktree_cleanup" and
                   event.payload["delivery_id"] == delivery.id
               end)
      end)

      File.rm!(dirty_path)
      assert {:ok, ^delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)

      assert_eventually(fn ->
        refute File.exists?(prepared.worktree_path)
        assert repo.get!(WorkPackage, linked_package.id).worktree_path == nil
      end)
    after
      restore_env("CODEX_HOME", previous_codex_home)
    end
  end

  test "worker-authored closeout-shaped progress cannot schedule worktree cleanup", %{repo: repo} do
    {_work_request, _work_package, linked_package} = linked_slice!(repo, status: "ready_for_worker")
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-closeout-spoofed-event")
    codex_home = Path.join(fixture.root, "codex-home")
    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      assert {:ok, prepared} =
               WorktreeLifecycle.prepare(
                 repo,
                 linked_package.id,
                 %{"repo_root" => fixture.repo_root, "base_branch" => linked_package.base_branch, "branch" => "feat/spoofed-closeout"},
                 codex_home: codex_home
               )

      assert {:ok, run} = AgentRunRepository.start_run(repo, %{work_package_id: linked_package.id, status: "running"})

      assert {:ok, _event} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: linked_package.id,
                 status: "merged",
                 summary: "Worker-authored closeout-shaped event",
                 idempotency_key: "worker-closeout-spoof",
                 payload: %{type: "work_request_delivery_closeout", source_tool: "record_work_package_delivery"}
               })

      assert {:ok, %AgentRun{status: "stopped"}} = AgentRunRepository.mark_stopped(repo, run.id, "worker exited")
      Process.sleep(100)
      assert File.dir?(prepared.worktree_path)
    after
      WorkPackageRepository.update(repo, linked_package.id, %{status: "closed"})
      WorktreeLifecycle.cleanup(repo, linked_package.id, codex_home: codex_home)
      restore_env("CODEX_HOME", previous_codex_home)
    end
  end

  test "PR merged recovery closeout ignores stale agent runtime rows that are not operationally active", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready_for_merge")

    assert {:ok, agent_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: linked_package.id,
               status: "running",
               last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -301, :second)
             })

    assert {:ok, %{work_packages: [before_closeout]}} = DeliveryBoard.project(repo, work_request.id)
    assert before_closeout.operational_state.key == "merge_ready"
    assert before_closeout.work_package.runtime_state.active? == false
    assert before_closeout.work_package.runtime_state.stale? == true
    assert before_closeout.work_package.runtime_state.stale_agent_run_ids == [agent_run.id]
    assert "agent_run_stale" in before_closeout.work_package.runtime_state.reason_codes

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-pr-merged-stale-agent-runtime",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/131",
        pr_number: 131,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 12:57:00.000000Z],
        merge_commit_sha: "abc131"
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "pr_merged"
    assert repo.get!(WorkPackage, linked_package.id).status == "merged"

    assert [event] = repo.all(ProgressEvent)
    assert "agent_run_stale" in event.payload["runtime_reason_codes_before_closeout"]
    assert event.payload["ignored_stale_agent_run_ids"] == [agent_run.id]

    assert {:ok, %{counts: %{"delivered" => 1}, work_packages: [after_closeout]}} = DeliveryBoard.project(repo, work_request.id)
    assert after_closeout.operational_state.key == "delivered"
    refute "work_package_active_after_delivery" in after_closeout.attention_reason_codes
  end

  test "PR merged closeout records delivery when linked worktree path is invalid", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-DELIVERY-INVALID-WORKTREE",
        work_package_id: "wp_ik4563eit3v5lguw",
        status: "ready_for_merge"
      )

    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-closeout-invalid-worktree")
    codex_home = Path.join(fixture.root, "codex-home")
    invalid_worktree_path = Path.join([codex_home, "worktrees", "spp_worktrees", "invalid-recorded-worktree"])
    File.mkdir_p!(Path.dirname(invalid_worktree_path))
    File.write!(invalid_worktree_path, "not a directory")

    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      assert {:ok, _updated_package} =
               WorkPackageRepository.update(repo, linked_package.id, %{
                 worktree_path: invalid_worktree_path,
                 worktree_target_repo_root: fixture.repo_root
               })

      attrs =
        delivery_attrs(%{
          outcome: "pr_merged",
          idempotency_key: "delivery-pr-merged-invalid-worktree",
          pr_url: "https://github.com/nextide/symphony-plus-plus/pull/456",
          pr_number: 456,
          pr_repository: "nextide/symphony-plus-plus",
          pr_merged_at: ~U[2026-05-24 12:58:00.000000Z],
          merge_commit_sha: "abc456"
        })

      assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
      assert delivery.outcome == "pr_merged"
      assert repo.get!(WorkPackage, linked_package.id).status == "merged"

      cleanup_event =
        repo.all(ProgressEvent)
        |> Enum.find(&(&1.payload["type"] == "work_request_delivery_worktree_cleanup"))

      assert cleanup_event.status == "worktree_cleanup_failed"
      assert cleanup_event.payload["reason"] == ":invalid_worktree_path"
      assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1
    after
      restore_env("CODEX_HOME", previous_codex_home)
    end
  end

  test "PR merged recovery closeout releases paused claim lease", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready_for_worker")

    assert {:ok, claim_lease} =
             ClaimLeaseService.claim(
               repo,
               linked_package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:paused-pr-recovery", "actor_display_name" => "paused-worker"},
               stale_after_ms: 60_000
             )

    assert {:ok, _paused_lease} =
             ClaimLeaseService.pause(
               repo,
               claim_lease.id,
               %{"actor_kind" => "operator", "actor_id" => "operator:pause"},
               reason: "operator paused the worker"
             )

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-pr-merged-paused-claim-lease",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/130",
        pr_number: 130,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 12:56:00.000000Z],
        merge_commit_sha: "abc130"
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "pr_merged"
    assert repo.get!(WorkPackage, linked_package.id).status == "merged"

    assert %ClaimLease{status: "released", release_reason: "pr_merged_delivery_closeout"} =
             repo.get!(ClaimLease, claim_lease.id)
  end

  test "PR merged recovery closeout clears active blockers", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready_for_worker")

    assert {:ok, _blocker} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Closeout blocked",
               status: "blocked",
               idempotency_key: "pr-merged-active-blocker",
               payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: "pr-merged-active-blocker", active: true}
             })

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-pr-merged-active-blocker",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/126",
        pr_number: 126,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 12:50:00.000000Z],
        merge_commit_sha: "abc126"
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "pr_merged"
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1
    assert repo.get!(WorkPackage, linked_package.id).status == "merged"
    refute WorkPackageActivity.context(repo, linked_package.id).blocker_state.active?
  end

  test "completed_no_pr superseded and abandoned close compatible linked packages to terminal states", %{repo: repo} do
    {no_pr_request, no_pr_slice, no_pr_package} = linked_slice!(repo, status: "reviewing", kind: "docs")

    assert {:ok, no_pr_delivery} =
             Service.record_work_package_delivery(
               repo,
               no_pr_request.id,
               no_pr_slice.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 idempotency_key: "delivery-no-pr",
                 no_pr_evidence: "Operator confirmed the docs-only package landed directly."
               })
             )

    assert no_pr_delivery.outcome == "completed_no_pr"
    assert no_pr_package.kind == "docs"
    assert repo.get!(WorkPackage, no_pr_package.id).status == "closed"
    assert %WorkRequest{completed_at: %DateTime{}} = repo.get!(WorkRequest, no_pr_request.id)

    {superseded_request, superseded_slice, superseded_package} = linked_slice!(repo, status: "implementing")
    successor_slice = create_work_package!(repo, superseded_request, id: "WRS-DELIVERY-SUCCESSOR")
    assert {:ok, _skipped_successor} = Repository.skip_work_package(repo, superseded_request.id, successor_slice.id, "planned")

    assert {:ok, superseded_delivery} =
             Service.record_work_package_delivery(
               repo,
               superseded_request.id,
               superseded_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 idempotency_key: "delivery-superseded",
                 successor_work_package_id: successor_slice.id,
                 superseded_reason: "Recut with narrower owned files."
               })
             )

    assert superseded_delivery.outcome == "superseded"
    assert repo.get!(WorkPackage, superseded_package.id).status == "closed"
    assert %WorkRequest{completed_at: %DateTime{}} = repo.get!(WorkRequest, superseded_request.id)

    {abandoned_request, abandoned_slice, abandoned_package} = linked_slice!(repo, status: "planning")

    assert {:ok, abandoned_delivery} =
             Service.record_work_package_delivery(
               repo,
               abandoned_request.id,
               abandoned_slice.id,
               delivery_attrs(%{
                 outcome: "abandoned",
                 idempotency_key: "delivery-abandoned",
                 abandoned_rationale: "Architecture decision made the package unnecessary."
               })
             )

    assert abandoned_delivery.outcome == "abandoned"
    assert repo.get!(WorkPackage, abandoned_package.id).status == "abandoned"
    assert %WorkRequest{completed_at: %DateTime{}} = repo.get!(WorkRequest, abandoned_request.id)
  end

  test "abandoned closeout accepts an already-abandoned no-code package after worker authority is cleared", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-DELIVERY-ABANDONED-ALREADY-TERMINAL",
        status: "ready_for_worker"
      )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "stopped-worker")

    assert {:ok, claim_lease} =
             ClaimLeaseService.claim(
               repo,
               linked_package.id,
               %{
                 "actor_kind" => "agent",
                 "actor_id" => "local:stopped-worker",
                 "actor_display_name" => "stopped-worker"
               },
               stale_after_ms: 60_000
             )

    assert {:ok, _released_lease} = ClaimLeaseService.release(repo, claim_lease.id, reason: "worker stopped before code")
    assert {:ok, _revoked_grant} = AccessGrantService.revoke(repo, minted.grant.id)

    assert {:ok, _abandoned_progress} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Worker stopped before implementation.",
               status: "abandoned",
               idempotency_key: "abandoned-before-closeout",
               payload: %{
                 "previous_status" => "ready_for_worker",
                 "next_status" => "abandoned"
               }
             })

    assert {:ok, _abandoned_package} = WorkPackageRepository.update(repo, linked_package.id, %{status: "abandoned", worktree_path: nil})

    attrs =
      delivery_attrs(%{
        outcome: "abandoned",
        idempotency_key: "delivery-abandoned-already-terminal",
        abandoned_rationale: "Worker stopped before implementation and the package was already marked abandoned."
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "abandoned"
    assert repo.get!(WorkPackage, linked_package.id).status == "abandoned"

    closeout_event = repo.all(ProgressEvent) |> Enum.find(&(&1.payload["source_tool"] == "record_work_package_delivery"))
    assert closeout_event.payload["previous_status"] == "abandoned"
    assert "package_terminal" in closeout_event.payload["runtime_reason_codes_before_closeout"]
  end

  test "abandoned closeout accepts an already-abandoned package with recycled inactive runtime", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-DELIVERY-ABANDONED-RECYCLED-RUNTIME",
        status: "ready_for_worker"
      )

    assert {:ok, _runtime_cleanup_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Worker runtime was recycled before delivery closeout.",
               status: "cleaned",
               idempotency_key: "abandoned-recycled-runtime-before-closeout",
               payload: %{
                 "source_tool" => "cleanup_work_request_work_package_runtime",
                 "delivery_evidence" => %{"outcome" => "abandoned"},
                 "runtime_cleanup" => %{"status" => "cleaned"}
               }
             })

    assert {:ok, _abandoned_package} = WorkPackageRepository.update(repo, linked_package.id, %{status: "abandoned", worktree_path: nil})

    attrs =
      delivery_attrs(%{
        outcome: "abandoned",
        idempotency_key: "delivery-abandoned-recycled-runtime",
        abandoned_rationale: "The package was already abandoned and its worker runtime had already been recycled."
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "abandoned"
    assert repo.get!(WorkPackage, linked_package.id).status == "abandoned"

    closeout_event = repo.all(ProgressEvent) |> Enum.find(&(&1.payload["source_tool"] == "record_work_package_delivery"))
    assert closeout_event.payload["previous_status"] == "abandoned"
    assert "worker_recycled" in closeout_event.payload["runtime_reason_codes_before_closeout"]
    assert "package_terminal" in closeout_event.payload["runtime_reason_codes_before_closeout"]
  end

  test "abandoned closeout rejects generic recycled runtime evidence without abandonment proof", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-DELIVERY-ABANDONED-GENERIC-RECYCLED",
        status: "ready_for_worker"
      )

    assert {:ok, _generic_recycle_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "A generic worker runtime recycle happened before closeout.",
               status: "claimed",
               idempotency_key: "abandoned-generic-recycled-runtime",
               payload: %{"source_tool" => "claim_local_assignment"}
             })

    assert {:ok, _abandoned_package} = WorkPackageRepository.update(repo, linked_package.id, %{status: "abandoned", worktree_path: nil})

    attrs =
      delivery_attrs(%{
        outcome: "abandoned",
        idempotency_key: "delivery-abandoned-generic-recycled-runtime",
        abandoned_rationale: "Generic runtime recycle evidence must not prove abandonment."
      })

    assert {:error, :active_runtime} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
  end

  test "abandoned closeout rejects already-abandoned packages with non-abandonable history", %{repo: repo} do
    for {history_status, request_id} <- [
          {"blocked", "WR-DELIVERY-ABANDONED-WITH-BLOCKED-HISTORY"},
          {"implementing", "WR-DELIVERY-ABANDONED-WITH-IMPLEMENTING-HISTORY"}
        ] do
      {work_request, work_package, linked_package} =
        linked_slice!(repo,
          work_request_id: request_id,
          status: "ready_for_worker"
        )

      assert {:ok, _history_progress} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: linked_package.id,
                 summary: "Package reached #{history_status} before it was abandoned.",
                 status: history_status,
                 idempotency_key: "abandoned-with-#{history_status}-history",
                 payload: %{
                   "previous_status" => "ready_for_worker",
                   "next_status" => history_status
                 }
               })

      assert {:ok, _abandoned_progress} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: linked_package.id,
                 summary: "Package was later abandoned.",
                 status: "abandoned",
                 idempotency_key: "abandoned-after-#{history_status}-history",
                 payload: %{
                   "previous_status" => history_status,
                   "next_status" => "abandoned"
                 }
               })

      assert {:ok, _abandoned_package} = WorkPackageRepository.update(repo, linked_package.id, %{status: "abandoned", worktree_path: nil})

      attrs =
        delivery_attrs(%{
          outcome: "abandoned",
          idempotency_key: "delivery-abandoned-with-#{history_status}-history",
          abandoned_rationale: "This should not hide non-abandonable history."
        })

      assert {:error, :work_package_not_abandonable} =
               Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    end

    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
  end

  test "abandoned closeout retires current worker authority on an already-abandoned package", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-DELIVERY-ABANDONED-CURRENT-RUNTIME",
        status: "ready_for_worker"
      )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "current-worker")

    assert {:ok, claim_lease} =
             ClaimLeaseService.claim(
               repo,
               linked_package.id,
               %{
                 "actor_kind" => "agent",
                 "actor_id" => "local:current-worker",
                 "actor_display_name" => "current-worker"
               },
               access_grant_id: minted.grant.id,
               stale_after_ms: 60_000
             )

    assert {:ok, _runtime_cleanup_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Prior cleanup evidence exists, but current authority remains.",
               status: "cleaned",
               idempotency_key: "abandoned-current-runtime-cleanup-evidence",
               payload: %{
                 "source_tool" => "cleanup_work_request_work_package_runtime",
                 "delivery_evidence" => %{"outcome" => "abandoned"}
               }
             })

    assert {:ok, _abandoned_package} = WorkPackageRepository.update(repo, linked_package.id, %{status: "abandoned", worktree_path: nil})

    attrs =
      delivery_attrs(%{
        outcome: "abandoned",
        idempotency_key: "delivery-abandoned-current-runtime",
        abandoned_rationale: "The architect is retiring the remaining worker authority."
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "abandoned"
    assert %AccessGrant{revoked_at: %DateTime{}} = repo.get!(AccessGrant, minted.grant.id)

    assert %ClaimLease{status: "released", release_reason: "abandoned_delivery_closeout"} =
             repo.get!(ClaimLease, claim_lease.id)
  end

  test "phase-child PR merged closeout must use merge_child_into_phase", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(repo,
        kind: "phase_child",
        status: "ready_for_architect_merge"
      )

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-phase-child",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/456",
        pr_number: 456,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 13:00:00.000000Z],
        merge_commit_sha: "def456"
      })

    assert {:error, :phase_child_pr_merged_requires_merge_child_into_phase} =
             Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)

    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_architect_merge"

    assert {:ok, _merged_into_phase} = WorkPackageRepository.update_status(repo, linked_package.id, "ready_for_architect_merge", "merged_into_phase")
    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)

    assert delivery.outcome == "pr_merged"
    assert repo.get!(WorkPackage, linked_package.id).status == "merged_into_phase"
    assert [event] = repo.all(ProgressEvent)
    assert event.status == "merged_into_phase"
  end

  test "linked PR merged closeout requires merge commit evidence and rolls back", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready_for_merge")

    assert {:error, %Ecto.Changeset{} = changeset} =
             Service.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: "delivery-weak-pr",
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/789",
                 pr_number: 789,
                 pr_repository: "nextide/symphony-plus-plus",
                 pr_merged_at: ~U[2026-05-24 14:00:00.000000Z]
               })
             )

    assert {"can't be blank", [validation: :required]} = changeset.errors[:merge_commit_sha]
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_merge"
  end

  test "linked PR merged closeout rejects malformed PR URL evidence and rolls back", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready_for_merge")

    assert {:error, :malformed_pr_evidence} =
             Service.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: "delivery-malformed-pr",
                 pr_url: "https://github.com/nextide/other/pull/789",
                 pr_number: 789,
                 pr_repository: "nextide/symphony-plus-plus",
                 pr_merged_at: ~U[2026-05-24 14:15:00.000000Z],
                 merge_commit_sha: "fed789"
               })
             )

    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_merge"
  end

  test "standalone PR merged closeout rejects malformed PR URL evidence", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DELIVERY-STANDALONE-MALFORMED-PR", status: "ready_for_slicing")
    work_package = create_work_package!(repo, work_request, id: "WRS-DELIVERY-STANDALONE-MALFORMED-PR")

    assert {:error, :malformed_pr_evidence} =
             Service.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: "delivery-standalone-malformed-pr",
                 pr_url: "https://github.com/nextide/other/pull/801",
                 pr_number: 801,
                 pr_repository: "nextide/symphony-plus-plus",
                 pr_merged_at: ~U[2026-05-24 14:20:00.000000Z],
                 merge_commit_sha: "standalone-801"
               })
             )

    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
  end

  test "replayed closeout requires matching audit and terminal state", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready_for_merge")

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-legacy-pr-merged",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/790",
        pr_number: 790,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 14:30:00.000000Z],
        merge_commit_sha: "legacy-790"
      })

    assert {:ok, delivery} = Repository.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert {:ok, _merged} = WorkPackageRepository.update_status(repo, linked_package.id, "ready_for_merge", "merged")

    assert {:ok, _event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Recorded WorkRequest delivery closeout: pr_merged",
               status: "merged",
               idempotency_key: "work_request_delivery_closeout:#{work_request.id}:#{work_package.id}:#{attrs.idempotency_key}",
               payload: %{
                 type: "work_request_delivery_closeout",
                 source_tool: "record_work_package_delivery",
                 work_request_id: work_request.id,
                 work_package_id: work_package.id,
                 delivery_id: delivery.id,
                 outcome: "pr_merged",
                 previous_status: "ready_for_merge",
                 next_status: "merged",
                 status_changed: true
               }
             })

    assert {:ok, replay} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert replay.id == delivery.id
    assert %WorkRequest{completed_at: %DateTime{}} = repo.get!(WorkRequest, work_request.id)
  end

  test "colliding closeout progress does not bypass validation or terminal mutation", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, status: "ready_for_merge")
    delivery_idempotency_key = "delivery-progress-collision"

    assert {:ok, _colliding_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Manual event with a colliding closeout key",
               status: "merged",
               idempotency_key: "work_request_delivery_closeout:#{work_request.id}:#{work_package.id}:#{delivery_idempotency_key}",
               payload: %{
                 type: "manual",
                 source_tool: "operator_note",
                 work_request_id: work_request.id,
                 work_package_id: work_package.id,
                 delivery_id: "not-this-delivery",
                 outcome: "pr_merged",
                 next_status: "merged"
               }
             })

    assert {:error, :idempotency_key_conflict} =
             Service.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: delivery_idempotency_key,
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/999",
                 pr_number: 999,
                 pr_repository: "nextide/symphony-plus-plus",
                 pr_merged_at: ~U[2026-05-24 15:00:00.000000Z],
                 merge_commit_sha: "fed999"
               })
             )

    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
    assert repo.aggregate(ProgressEvent, :count, :id) == 1
    assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_merge"
  end

  test "delivery on a planned WorkPackage completes and can archive the request", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DELIVERY-APPROVED-UNLINKED", status: "ready_for_slicing")
    work_package = create_work_package!(repo, work_request, id: "WRS-DELIVERY-APPROVED-UNLINKED")
    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

    assert {:ok, delivery} =
             Service.record_work_package_delivery(
               repo,
               work_request.id,
               approved_slice.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 idempotency_key: "delivery-approved-unlinked",
                 no_pr_evidence: "Operator noted the slice was approved but never dispatched."
               })
             )

    assert delivery.outcome == "completed_no_pr"
    assert %WorkRequest{completed_at: %DateTime{}, archived_at: nil} = repo.get!(WorkRequest, work_request.id)

    assert {:ok, archived} = Service.archive(repo, work_request.id)
    assert %DateTime{} = archived.archived_at
  end

  test "investigation no-PR closeout releases stale claim leases and closes the linked package", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-DELIVERY-INVESTIGATION-NO-PR",
        work_package_id: "wp_o3kgjdl7gausbmqi",
        kind: "investigation",
        status: "ready_for_merge"
      )

    assert {:ok, claim_lease} =
             ClaimLeaseService.claim(
               repo,
               linked_package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:stale-investigation", "actor_display_name" => "stale-worker"},
               stale_after_ms: 1
             )

    stale_at = DateTime.add(DateTime.utc_now(:microsecond), -5, :second)
    repo.update!(Ecto.Changeset.change(claim_lease, last_seen_at: stale_at, updated_at: stale_at))

    attrs =
      delivery_attrs(%{
        outcome: "completed_no_pr",
        idempotency_key: "delivery-investigation-no-pr-stale-lease",
        no_pr_evidence: "Investigation completed without a PR."
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "completed_no_pr"
    assert repo.get!(WorkPackage, linked_package.id).status == "closed"

    assert %ClaimLease{status: "released", release_reason: "completed_no_pr_delivery_closeout"} =
             repo.get!(ClaimLease, claim_lease.id)

    closeout_event = Enum.find(repo.all(ProgressEvent), &(&1.payload["type"] == "work_request_delivery_closeout"))
    assert closeout_event.payload["retired_claim_lease_ids"] == [claim_lease.id]
    assert "claim_lease_stale" in closeout_event.payload["runtime_reason_codes_before_closeout"]
  end

  test "active claim leases are released by architect closeout", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-DELIVERY-ACTIVE-CLAIM-LEASE",
        status: "ready_for_merge"
      )

    assert {:ok, claim_lease} =
             ClaimLeaseService.claim(
               repo,
               linked_package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:closeout-claim", "actor_display_name" => "worker-claim"},
               stale_after_ms: 60_000
             )

    attrs =
      delivery_attrs(%{
        outcome: "completed_no_pr",
        idempotency_key: "delivery-active-claim-lease",
        no_pr_evidence: "The package is complete and the architect is recording terminal delivery."
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "completed_no_pr"
    assert repo.get!(WorkPackage, linked_package.id).status == "closed"

    assert %ClaimLease{status: "released", release_reason: "completed_no_pr_delivery_closeout"} =
             repo.get!(ClaimLease, claim_lease.id)
  end

  test "stale agent runs do not block normal closeout and remain audited", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-DELIVERY-STALE-AGENT-RUN",
        status: "ready_for_merge"
      )

    assert {:ok, agent_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: linked_package.id,
               status: "running",
               last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -301, :second)
             })

    assert {:ok, _closed} = WorkPackageRepository.update_status(repo, linked_package.id, "ready_for_merge", "closed")

    attrs =
      delivery_attrs(%{
        outcome: "completed_no_pr",
        idempotency_key: "delivery-stale-agent-run",
        no_pr_evidence: "The package status is terminal, and the only runtime evidence is stale."
      })

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "completed_no_pr"

    assert [event] = repo.all(ProgressEvent)
    assert event.payload["previous_status"] == "closed"
    assert "agent_run_stale" in event.payload["runtime_reason_codes_before_closeout"]
    assert event.payload["ignored_stale_agent_run_ids"] == [agent_run.id]
  end

  defp linked_slice!(repo, overrides) do
    kind = Keyword.get(overrides, :kind, "mcp")
    status = Keyword.get(overrides, :status, "reviewing")
    request_id = Keyword.get_lazy(overrides, :work_request_id, fn -> "WR-DELIVERY-#{System.unique_integer([:positive])}" end)

    work_request = create_work_request!(repo, id: request_id, status: "ready_for_slicing")
    work_package_id = Keyword.get(overrides, :work_package_id, "WP-#{request_id}")
    work_package = create_work_package!(repo, work_request, id: work_package_id, kind: kind)

    work_package =
      repo.update!(
        Ecto.Changeset.change(work_package,
          status: status,
          dispatched_at: DateTime.utc_now(:microsecond)
        )
      )

    {work_request, work_package, work_package}
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = Repository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_work_package!(repo, work_request, overrides) do
    attrs = work_package_attrs(overrides)

    if attrs.kind == "phase_child" do
      insert_phase_child_fixture!(repo, work_request, attrs)
    else
      assert {:ok, work_package} = CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, attrs)
      work_package
    end
  end

  defp insert_phase_child_fixture!(repo, work_request, attrs) do
    attrs =
      Map.merge(attrs, %{
        work_request_id: work_request.id,
        repo: work_request.repo,
        sequence: 1,
        status: "planned"
      })

    repo.insert!(struct!(WorkPackage, attrs))
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-DELIVERY-#{System.unique_integer([:positive])}",
      title: "Close delivered WorkRequest slices",
      repo: "nextide/example",
      base_branch: "main",
      work_type: "feature",
      human_description: "Record closeout truth for delivered slices.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "architect_led_feature_branch"
    }

    Enum.into(overrides, defaults)
  end

  defp work_package_attrs(overrides) do
    defaults = %{
      title: "Close delivered slice",
      goal: "Record terminal delivery state.",
      kind: "mcp",
      base_branch: "main",
      branch_pattern: "feat/delivery-closeout",
      allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Delivery closeout is transactional."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/work_request_delivery_closeout_test.exs"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: ["Do not bypass phase-child merge semantics."]
    }

    Enum.into(overrides, defaults)
  end

  defp delivery_attrs(overrides) do
    defaults = %{
      idempotency_key: "delivery-#{System.unique_integer([:positive])}",
      recorded_by: "delivery-closeout-test"
    }

    Enum.into(overrides, defaults)
  end

  defp database_path do
    Path.join(System.tmp_dir!(), "sympp-work-request-delivery-closeout-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp install_fail_once_git!(bin_dir) do
    File.mkdir_p!(bin_dir)
    path = Path.join(bin_dir, "git")

    File.write!(
      path,
      """
      #!/bin/sh
      if [ "$3" = "worktree" ] && [ "$4" = "remove" ] && [ ! -e "$SYMPP_FAIL_ONCE_MARKER" ]; then
        : > "$SYMPP_FAIL_ONCE_MARKER"
        "$SYMPP_REAL_GIT" "$@" || exit $?
        exit 17
      fi
      exec "$SYMPP_REAL_GIT" "$@"
      """
    )

    File.chmod!(path, 0o755)
  end

  defp assert_eventually(fun, attempts \\ 40)
  defp assert_eventually(_fun, 0), do: flunk("condition was not met before timeout")

  defp assert_eventually(fun, attempts) when is_function(fun, 0) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
  end
end
