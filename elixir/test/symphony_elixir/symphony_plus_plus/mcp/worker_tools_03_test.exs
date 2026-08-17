Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools03Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "sync_pr repairs PR identity and records only a verified terminal merge after readiness", %{repo: repo} do
    original_client = Application.get_env(:symphony_elixir, :sympp_github_client)
    Application.put_env(:symphony_elixir, :sympp_github_client, SymphonyElixir.FakeGitHubClient)
    SymphonyElixir.FakeGitHubClient.clear()

    on_exit(fn ->
      SymphonyElixir.FakeGitHubClient.clear()

      case original_client do
        nil -> Application.delete_env(:symphony_elixir, :sympp_github_client)
        client -> Application.put_env(:symphony_elixir, :sympp_github_client, client)
      end
    end)

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-READY-SYNC-MERGED",
                 kind: "standard_pr",
                 repo: "nextide/repo",
                 base_branch: "main",
                 status: "ready_for_merge"
               )
             )

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "fix/ready-sync", head_sha: "head-a"}
             })

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    assert {:ok, initial_events} = PlanningRepository.list_progress_events(repo, package.id)

    SymphonyElixir.FakeGitHubClient.put_response(
      "nextide/repo",
      27,
      SymphonyElixir.GitHubPullRequestFixtures.metadata(27, "head-a", merged?: false)
    )

    open_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync-open",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{"url" => "https://github.com/nextide/repo/pull/27"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(open_response, ["error", "data", "reason"]) == "pr_not_merged"
    assert {:ok, unchanged_events} = PlanningRepository.list_progress_events(repo, package.id)
    assert length(unchanged_events) == length(initial_events)
    assert repo.get!(WorkPackage, package.id).status == "ready_for_merge"

    SymphonyElixir.FakeGitHubClient.put_response(
      "nextide/repo",
      27,
      SymphonyElixir.GitHubPullRequestFixtures.metadata(27, "head-a", merged?: true)
    )

    merged_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync-merged",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{"url" => "https://github.com/nextide/repo/pull/27"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(merged_response, ["result", "structuredContent", "work_package", "status"]) == "merged"
    assert get_in(merged_response, ["result", "structuredContent", "pr_sync", "status"]) == "merged"
    assert get_in(merged_response, ["result", "structuredContent", "next_owner"]) == "architect"
    assert get_in(merged_response, ["result", "structuredContent", "next_action"]) == "return_to_architect"

    replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync-replay",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{"url" => "https://github.com/nextide/repo/pull/27"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(replay_response, ["result", "structuredContent", "pr_sync", "status"]) == "already_merged"
    assert get_in(replay_response, ["result", "structuredContent", "next_owner"]) == "architect"
    assert get_in(replay_response, ["result", "structuredContent", "next_action"]) == "return_to_architect"
  end

  test "mark_ready does not require ci_waiting when package policy omits CI", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-NO-CI", kind: "mcp", status: "reviewing"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    append_done_plan(repo, package.id)

    missing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-no-ci-missing", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(missing_response, ["error", "data", "missing"])
    refute "status_ci_waiting" in missing
    refute "plan_complete" in missing
    assert "acceptance_criteria_met" in missing
    assert "tests_passed" in missing
    assert "pr_attached" in missing

    append_merge_ready_evidence(repo, session, package.id, "head-no-ci")

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-no-ci", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"
  end

  test "mark_ready derives CI readiness from evidence without a manual ci_waiting state", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-CI-REQUIRED", kind: "mcp", status: "active", policy_template: "mcp_ci_required")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    append_merge_ready_evidence(repo, session, package.id, "head-ci-required")

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-ci-required", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"
  end

  test "state machine accepts fact-owned readiness from active packages", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-CI-STATE-MACHINE", kind: "mcp", status: "active", policy_template: "mcp_ci_required")
             )

    actor = %{grant_role: "worker", capabilities: ["worker:lifecycle.transition"], work_package_id: package.id}

    assert :ok = StateMachine.validate_ready_transition(package, "ready_for_merge", actor)
  end
end
