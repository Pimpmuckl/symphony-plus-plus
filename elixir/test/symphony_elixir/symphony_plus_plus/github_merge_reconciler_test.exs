defmodule SymphonyElixir.SymphonyPlusPlus.GitHubMergeReconcilerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.FakeAuthenticatedGitHubClient
  alias SymphonyElixir.FakeGhCli
  alias SymphonyElixir.FakeGitHubClient
  alias SymphonyElixir.GitHubPullRequestFixtures
  alias SymphonyElixir.GitHubTestSupport
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{
    DefaultClient,
    GhCliClient,
    HttpClient,
    MergeReconciler,
    PullRequestProgress
  }

  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkPackageRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(Artifact)
    repo.delete_all(ProgressEvent)
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackageDelivery)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkRequest)
    repo.delete_all(WorkPackage)
    repo.delete_all(Phase)
    FakeGitHubClient.clear()
    FakeGhCli.clear()
    :ok
  end

  test "PR progress helpers preserve created_at precedence over legacy sequences" do
    old_event = %ProgressEvent{
      id: "old-pr",
      sequence: 200,
      created_at: ~U[2026-05-20 12:00:00Z],
      payload: %{
        "type" => "pr",
        "source_tool" => "attach_pr",
        "url" => "https://github.com/nextide/repo/pull/1",
        "repository" => "nextide/repo",
        "number" => 1,
        "head_sha" => "old-head"
      }
    }

    new_event = %ProgressEvent{
      id: "new-pr",
      sequence: 1,
      created_at: ~U[2026-05-21 12:00:00Z],
      payload: %{
        "type" => "pr",
        "source_tool" => "attach_pr",
        "url" => "https://github.com/nextide/repo/pull/2",
        "repository" => "nextide/repo",
        "number" => 2,
        "head_sha" => "new-head"
      }
    }

    assert {:ok, %{ref: %{number: 2}, payload: %{"head_sha" => "new-head"}}} =
             PullRequestProgress.current_pr_state([new_event, old_event], ["attach_pr"])
  end

  test "merged PR fetch transitions ready standalone package to merged", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-MERGED", status: "ready_for_merge")
    append_pr_evidence(repo, package, 1, "head-a")
    FakeGitHubClient.put_response("nextide/repo", 1, GitHubPullRequestFixtures.metadata(1, "head-a", merged?: true))

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.merged_count == 1
    assert [%{status: "merged", reason: "github_pr_merged", work_package_id: "SYMPP-GH-MERGED"}] = result.results
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "merged"

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, package.id)

    assert Enum.any?(
             events,
             &match?(
               %ProgressEvent{status: "pr_synced", payload: %{"source_tool" => "sync_pr", "merged_at" => "2026-05-20T12:00:00Z", "merge_commit_sha" => "merge-sha-1"}},
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(%ProgressEvent{status: "github_pr_merged", payload: %{"source_tool" => "operator_sync_prs", "after_status" => "merged"}}, &1)
           )
  end

  test "verified terminal sync closes a linked WorkPackage and replays cleanly", %{repo: repo} do
    {work_request, work_package, package} = create_linked_package(repo, "SYMPP-GH-LINKED")
    append_pr_evidence(repo, package, 26, "head-a")
    FakeGitHubClient.put_response("nextide/repo", 26, GitHubPullRequestFixtures.metadata(26, "head-a", merged?: true))

    assert {:ok, first} = MergeReconciler.reconcile_work_package(repo, package.id, client: FakeGitHubClient)
    assert first.status == "merged"
    assert first.delivery_reconciliation.applied_count == 1
    assert repo.get!(WorkPackage, package.id).status == "merged"

    assert [delivery] = repo.all(WorkPackageDelivery)
    assert delivery.work_request_id == work_request.id
    assert delivery.work_package_id == work_package.id
    assert delivery.outcome == "pr_merged"

    assert {:ok, replay} = MergeReconciler.reconcile_work_package(repo, package.id, client: FakeGitHubClient)
    assert replay.status == "already_merged"
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1
  end

  test "non-merged PR syncs metadata without transitioning", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-OPEN", status: "ready_for_merge")
    append_pr_evidence(repo, package, 2, "head-a")
    FakeGitHubClient.put_response("nextide/repo", 2, GitHubPullRequestFixtures.metadata(2, "head-a", merged?: false))

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.merged_count == 0
    assert [%{status: "synced", reason: "pr_not_merged"}] = result.results
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "ready_for_merge"
  end

  test "merged PR with mismatched head syncs but does not transition", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-STALE", status: "ready_for_merge")
    append_pr_evidence(repo, package, 3, "expected-head")
    FakeGitHubClient.put_response("nextide/repo", 3, GitHubPullRequestFixtures.metadata(3, "other-head", merged?: true))

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.merged_count == 0
    assert [%{status: "skipped", reason: "head_mismatch", expected_head_sha: "expected-head"}] = result.results
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "ready_for_merge"
  end

  test "attached PR head wins over older branch head evidence", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-REATTACHED", status: "ready_for_merge")
    append_branch_evidence(repo, package, "old-head")
    append_attached_pr_evidence(repo, package, 5, "new-head")
    FakeGitHubClient.put_response("nextide/repo", 5, GitHubPullRequestFixtures.metadata(5, "new-head", merged?: true))

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.merged_count == 1
    assert [%{status: "merged", reason: "github_pr_merged"}] = result.results
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "merged"
  end

  test "newer branch head evidence wins over older attached PR head", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-BRANCH-NEWER", status: "ready_for_merge")
    append_attached_pr_evidence(repo, package, 6, "old-head")
    append_branch_evidence(repo, package, "new-head")
    FakeGitHubClient.put_response("nextide/repo", 6, GitHubPullRequestFixtures.metadata(6, "new-head", merged?: true))

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.merged_count == 1
    assert [%{status: "merged", reason: "github_pr_merged"}] = result.results
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "merged"
  end

  test "synced PR head evidence does not satisfy stale head guard", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-SYNC-NEWER", status: "ready_for_merge")
    append_attached_pr_evidence(repo, package, 7, "old-head")
    FakeGitHubClient.put_response("nextide/repo", 7, GitHubPullRequestFixtures.metadata(7, "new-head", merged?: true))

    assert {:ok, first_result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert first_result.merged_count == 0
    assert [%{status: "skipped", reason: "head_mismatch", expected_head_sha: "old-head"}] = first_result.results
    assert {:ok, ready_package} = WorkPackageRepository.get(repo, package.id)
    assert ready_package.status == "ready_for_merge"

    assert {:ok, second_result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert second_result.merged_count == 0
    assert [%{status: "skipped", reason: "head_mismatch", expected_head_sha: "old-head"}] = second_result.results
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "ready_for_merge"
  end

  test "merged PR targeting a different base branch syncs but does not transition", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-WRONG-BASE", status: "ready_for_merge")
    append_pr_evidence(repo, package, 8, "head-a")
    FakeGitHubClient.put_response("nextide/repo", 8, GitHubPullRequestFixtures.metadata(8, "head-a", merged?: true, base_branch: "release"))

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.merged_count == 0

    assert [
             %{
               status: "skipped",
               reason: "base_branch_mismatch",
               expected_base_branch: "main",
               actual_base_branch: "release"
             }
           ] = result.results

    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "ready_for_merge"
  end

  test "merged PR from a different repository is rejected before transition", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-WRONG-REPO", status: "ready_for_merge")
    append_pr_evidence(repo, package, 10, "head-a")

    metadata =
      10
      |> GitHubPullRequestFixtures.metadata("head-a", merged?: true)
      |> Map.put("html_url", "https://github.com/other/repo/pull/10")

    FakeGitHubClient.put_response("nextide/repo", 10, metadata)

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.merged_count == 0
    assert [%{status: "error", reason: "pr_reference_mismatch"}] = result.results
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "ready_for_merge"
  end

  test "merge transition rolls back when merge evidence cannot be recorded", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-EVIDENCE-FAIL", status: "ready_for_merge")
    append_pr_evidence(repo, package, 9, "head-a")

    assert {:ok, _existing_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Pre-existing merge reconciliation key",
               status: "test_merge_evidence_collision",
               idempotency_key: "operator_github_merge:#{package.id}:head-a",
               payload: %{type: "test_collision"}
             })

    FakeGitHubClient.put_response("nextide/repo", 9, GitHubPullRequestFixtures.metadata(9, "head-a", merged?: true))

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.error_count == 1
    assert [%{status: "error", reason: "merge_evidence_conflict"}] = result.results
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "ready_for_merge"

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, package.id)
    refute Enum.any?(events, &match?(%ProgressEvent{status: "github_pr_merged"}, &1))
  end

  test "phase child merge-ready package is not polled by v1 auto reconciliation", %{repo: repo} do
    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: "phase-1", title: "Phase 1"})

    assert {:ok, package} =
             create_package(repo,
               id: "SYMPP-GH-PHASE-CHILD",
               kind: "phase_child",
               status: "ready_for_architect_merge",
               parent_id: "phase-parent",
               phase_id: "phase-1"
             )

    append_pr_evidence(repo, package, 4, "head-a")

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.total_count == 0
    assert result.merged_count == 0
    assert result.results == []
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "ready_for_architect_merge"
  end

  test "periodic default sync prefers gh CLI and does not require token env", %{repo: repo} do
    with_github_client_env(nil, fn ->
      GitHubTestSupport.with_github_token_env(nil, fn ->
        assert {:ok, package} = create_package(repo, id: "SYMPP-GH-CLI-AUTO", status: "ready_for_merge")
        append_pr_evidence(repo, package, 22, "head-a")
        FakeGhCli.authenticate(:ok)
        FakeGhCli.put_response("nextide/repo", 22, GitHubPullRequestFixtures.gh_view(22, "head-a", merged?: true))

        assert {:ok, result} =
                 MergeReconciler.reconcile(repo,
                   client: DefaultClient,
                   require_authenticated_client?: true,
                   command_runner: &FakeGhCli.run/3
                 )

        assert result.merged_count == 1
        assert [%{status: "merged", reason: "github_pr_merged", work_package_id: "SYMPP-GH-CLI-AUTO"}] = result.results
        assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
        assert updated.status == "merged"

        assert [
                 %{args: ["auth", "status", "--hostname", "github.com"]},
                 %{args: ["pr", "view", "22", "--repo", "nextide/repo", "--json", _fields]}
               ] = FakeGhCli.commands()
      end)
    end)
  end

  test "periodic gh CLI sync skips instead of returning polling errors when gh cannot authenticate", %{repo: repo} do
    for {auth_status, reason} <- [
          {:unavailable, "gh_cli_unavailable_for_periodic_sync"},
          {:unauthorized, "gh_cli_auth_required_for_periodic_sync"}
        ] do
      FakeGhCli.clear()
      FakeGhCli.authenticate(auth_status)

      assert {:ok, result} =
               MergeReconciler.reconcile(repo,
                 client: GhCliClient,
                 require_authenticated_client?: true,
                 command_runner: &FakeGhCli.run/3
               )

      assert result.reason == reason
      assert result.results == []
      assert result.total_count == 0
    end
  end

  test "default local client falls back to token client when gh cannot see the PR", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-CLI-FALLBACK", status: "ready_for_merge")
    append_pr_evidence(repo, package, 24, "head-a")

    FakeGhCli.authenticate(:ok)
    FakeGhCli.put_error("nextide/repo", 24, :gh_not_found)
    FakeGitHubClient.put_response("nextide/repo", 24, GitHubPullRequestFixtures.metadata(24, "head-a", merged?: true))

    assert {:ok, result} =
             MergeReconciler.reconcile(repo,
               client: DefaultClient,
               fallback_client: FakeAuthenticatedGitHubClient,
               require_authenticated_client?: true,
               command_runner: &FakeGhCli.run/3
             )

    assert result.merged_count == 1
    assert [%{status: "merged", reason: "github_pr_merged", work_package_id: "SYMPP-GH-CLI-FALLBACK"}] = result.results
  end

  test "default local client auth guard honors configured fallback client", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-CLI-FALLBACK-AUTH", status: "ready_for_merge")
    append_pr_evidence(repo, package, 25, "head-a")

    FakeGhCli.authenticate(:unavailable)
    FakeGitHubClient.put_response("nextide/repo", 25, GitHubPullRequestFixtures.metadata(25, "head-a", merged?: true))

    assert {:ok, result} =
             MergeReconciler.reconcile(repo,
               client: DefaultClient,
               fallback_client: FakeAuthenticatedGitHubClient,
               require_authenticated_client?: true,
               command_runner: &FakeGhCli.run/3
             )

    assert result.merged_count == 1
    assert [%{status: "merged", reason: "github_pr_merged", work_package_id: "SYMPP-GH-CLI-FALLBACK-AUTH"}] = result.results
  end

  test "periodic sync skips custom clients without an auth probe", %{repo: repo} do
    assert {:ok, result} =
             MergeReconciler.reconcile(repo, client: FakeGitHubClient, require_authenticated_client?: true)

    assert result.reason == "authenticated_client_required_for_periodic_sync"
    assert result.results == []
    assert result.total_count == 0
  end

  test "periodic HTTP sync skips when no GitHub token is configured", %{repo: repo} do
    GitHubTestSupport.with_github_token_env(nil, fn ->
      assert {:ok, result} = MergeReconciler.reconcile(repo, client: HttpClient, require_authenticated_client?: true)

      assert result.reason == "github_token_required_for_periodic_sync"
      assert result.results == []
      assert result.total_count == 0
    end)
  end

  test "worker grant still cannot mark a package merged", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-WORKER-DENIED", status: "ready_for_merge")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    assert {:error, :worker_cannot_mark_merged} =
             LifecycleService.transition(repo, package.id, "merged", Map.from_struct(assignment))
  end

  defp create_package(repo, overrides) do
    attrs =
      overrides
      |> Keyword.put_new(:kind, "hotfix")
      |> Keyword.put_new(:repo, "nextide/repo")
      |> Keyword.put_new(:base_branch, "main")
      |> WorkPackageFactory.attrs()

    WorkPackageRepository.create(repo, attrs)
  end

  defp create_linked_package(repo, work_package_id) do
    request_id = "WR-#{work_package_id}"

    assert {:ok, work_request} =
             WorkRequestRepository.create(repo, %{
               id: request_id,
               title: "Deliver merged PR",
               repo: "nextide/repo",
               base_branch: "main",
               work_type: "bugfix",
               human_description: "Close delivery from verified merge evidence.",
               desired_dispatch_shape: "single_package",
               status: "ready_for_slicing"
             })

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(repo, request_id, %{
               id: "WRS-#{work_package_id}",
               title: "Sync merged PR",
               goal: "Record the verified terminal merge.",
               kind: "standard_pr",
               base_branch: "main",
               branch_pattern: "fix/ready-sync",
               allowed_file_globs: ["elixir/lib/**"],
               acceptance_criteria: ["Merged delivery is recorded."],
               validation_steps: ["mix test"],
               review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "fast"}}
             })

    assert {:ok, approved_slice} =
             CanonicalWorkPackageFixtures.approve_work_package(repo, request_id, work_package.id, "planned")

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: work_package_id,
                 kind: approved_slice.kind,
                 title: approved_slice.title,
                 repo: work_request.repo,
                 base_branch: approved_slice.base_branch,
                 branch_pattern: approved_slice.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: approved_slice.allowed_file_globs,
                 acceptance_criteria: approved_slice.acceptance_criteria,
                 status: "ready_for_merge"
               )
             )

    assert {:ok, dispatched_slice} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, request_id, approved_slice.id, "approved", package.id)

    {work_request, dispatched_slice, package}
  end

  defp append_pr_evidence(repo, package, number, head_sha) do
    append_branch_evidence(repo, package, head_sha)
    append_attached_pr_evidence(repo, package, number, head_sha)
  end

  defp append_branch_evidence(repo, package, head_sha) do
    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{package.id}", head_sha: head_sha}
             })
  end

  defp append_attached_pr_evidence(repo, package, number, head_sha) do
    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/repo/pull/#{number}", head_sha: head_sha}
             })
  end

  defp with_github_client_env(value, fun) do
    original = Application.get_env(:symphony_elixir, :sympp_github_client)

    try do
      case value do
        nil -> Application.delete_env(:symphony_elixir, :sympp_github_client)
        client -> Application.put_env(:symphony_elixir, :sympp_github_client, client)
      end

      fun.()
    after
      case original do
        nil -> Application.delete_env(:symphony_elixir, :sympp_github_client)
        client -> Application.put_env(:symphony_elixir, :sympp_github_client, client)
      end
    end
  end
end
