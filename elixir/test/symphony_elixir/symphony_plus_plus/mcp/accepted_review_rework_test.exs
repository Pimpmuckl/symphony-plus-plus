Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.AcceptedReviewReworkTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequestProgress

  @head_a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  test "an accepted current-head finding atomically reopens once and requires fresh head-B provider review", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-accepted-review-rework")
    branch = "agent/accepted-review-rework"
    worktree = Path.join(fixture.root, "worktree")
    TestSupport.git_output!(fixture.repo_root, ["worktree", "add", "-b", branch, worktree, "HEAD"])
    TestSupport.git_output!(fixture.repo_root, ["remote", "set-url", "origin", "https://github.com/nextide/symphony-plus-plus.git"])
    head_a = fixture.repo_root |> TestSupport.git_output!(["rev-parse", "HEAD"]) |> String.trim()

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-ACCEPTED-REWORK",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    review_requirement = %{"type" => "automated", "args" => %{"reviewer" => "review-suite", "mode" => "fast"}}

    assert {:ok, package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(
                 id: "WP-MCP-ACCEPTED-REWORK",
                 kind: "mcp",
                 status: "active",
                 base_branch: "main",
                 branch_pattern: branch,
                 worktree_path: worktree,
                 worktree_target_repo_root: fixture.repo_root,
                 review_requirement: review_requirement,
                 dispatched_at: DateTime.utc_now(:microsecond)
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: minted.grant.secret_hash)

    assert {:ok, lease} =
             ClaimLeaseService.claim(
               repo,
               package.id,
               %{"actor_kind" => "agent", "actor_id" => "worker-1", "actor_display_name" => "worker-1"},
               access_grant_id: minted.grant.id,
               stale_after_ms: :timer.hours(1)
             )

    pr_url = "https://github.com/nextide/symphony-plus-plus/pull/9369"
    attach_tool(repo, worker_session, "attach_branch", %{"branch" => package.branch_pattern, "head_sha" => head_a})
    attach_tool(repo, worker_session, "attach_pr", %{"url" => pr_url, "head_sha" => head_a})
    sync_pr_state(repo, worker_session, pr_url, head_a)
    completion_a = attach_tool(repo, worker_session, "complete_review", %{"reference" => "review-a-complete"})

    assert get_in(mcp_tool(repo, worker_session, "mark_ready", %{}), ["result", "structuredContent", "work_package", "status"]) ==
             "ready_for_merge"

    {_anchor, architect_session, architect_grant} =
      create_work_request_handoff_architect_session(repo, work_request, ["read:work_request", "write:work_request"])

    comment =
      mcp_tool(repo, architect_session, "add_comment", %{
        "target_kind" => "work_package",
        "target_id" => package.id,
        "body" => "changes requested"
      })

    assert get_in(comment, ["result", "structuredContent", "comment", "id"])
    assert repo.get!(WorkPackage, package.id).status == "ready_for_merge"

    rejected_prose =
      mcp_tool(repo, worker_session, "append_progress", %{
        "summary" => "changes requested",
        "idempotency_key" => "raw-comment-cannot-reopen"
      })

    assert get_in(rejected_prose, ["error", "data", "reason"]) == "already_ready"

    package_before = package_contract(repo.get!(WorkPackage, package.id))
    grant_before = immutable_record(repo.get!(AccessGrant, minted.grant.id))
    architect_grant_before = immutable_record(architect_grant)
    lease_before = immutable_record(lease)
    arguments = accepted_rework_arguments(work_request.id, package.id, head_a)

    assert {:ok, _merged_snapshot} =
             PlanningRepository.append_audit_progress_event_for_work_package(
               repo,
               worker_assignment,
               package.id,
               %{
                 "summary" => "Current provider snapshot reports merged",
                 "status" => "pr_synced",
                 "idempotency_key" => "merged-provider-snapshot",
                 "payload" =>
                   provider_snapshot(pr_url, head_a, %{
                     "status" => "merged",
                     "merged" => true
                   })
               }
             )

    assert {:ok, events_before_merged_rejection} = PlanningRepository.list_progress_events(repo, package.id)

    assert get_in(mcp_tool(repo, architect_session, "accept_review_rework", arguments), ["error", "data", "reason"]) ==
             "current_attached_pr_already_merged"

    assert repo.get!(WorkPackage, package.id).status == "ready_for_merge"
    assert {:ok, events_after_merged_rejection} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.map(events_after_merged_rejection, & &1.id) == Enum.map(events_before_merged_rejection, & &1.id)

    assert {:ok, _clean_snapshot} =
             PlanningRepository.append_audit_progress_event_for_work_package(
               repo,
               worker_assignment,
               package.id,
               %{
                 "summary" => "Current provider snapshot reports open",
                 "status" => "pr_synced",
                 "idempotency_key" => "open-provider-snapshot",
                 "payload" => provider_snapshot(pr_url, head_a, %{"status" => "clean", "merged" => false})
               }
             )

    abbreviated = put_in(arguments, ["evidence", "head_sha"], String.slice(head_a, 0, 12))

    assert get_in(mcp_tool(repo, architect_session, "accept_review_rework", abbreviated), ["error", "data", "reason"]) ==
             "stale_rework_head"

    responses =
      1..2
      |> Task.async_stream(fn _ -> mcp_tool(repo, architect_session, "accept_review_rework", arguments) end,
        max_concurrency: 2,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, response} -> response end)

    assert Enum.all?(responses, &(get_in(&1, ["result", "structuredContent", "work_package", "status"]) == "active"))
    assert [accepted_event_id] = responses |> Enum.map(&get_in(&1, ["result", "structuredContent", "accepted_review_rework", "id"])) |> Enum.uniq()

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.count(progress_events, &accepted_rework_event?/1) == 1
    accepted_event = Enum.find(progress_events, &(&1.id == accepted_event_id))
    assert accepted_event.payload["reference"] == "mcpdiag_9369db53009417dd"
    assert accepted_event.payload["provider"] == "review-suite"
    assert accepted_event.payload["finding"] == "The exact reviewed head has a reachable changes-required finding."
    assert accepted_event.payload["head_sha"] == head_a

    assert accepted_event.payload["pr"] == %{
             "url" => pr_url,
             "repository" => "nextide/symphony-plus-plus",
             "number" => 9369,
             "head_sha" => head_a
           }

    conflict = put_in(arguments, ["evidence", "finding"], "A conflicting finding.")

    assert get_in(mcp_tool(repo, architect_session, "accept_review_rework", conflict), ["error", "data", "reason"]) ==
             "idempotency_conflict"

    assert get_in(
             mcp_tool(repo, architect_session, "accept_review_rework", Map.put(arguments, "idempotency_key", "second-acceptance")),
             ["error", "data", "reason"]
           ) == "work_package_not_ready_for_rework"

    assert package_contract(repo.get!(WorkPackage, package.id)) == package_before
    assert immutable_record(repo.get!(AccessGrant, minted.grant.id)) == grant_before
    assert immutable_record(repo.get!(AccessGrant, architect_grant.id)) == architect_grant_before
    assert {:ok, current_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert immutable_record(current_lease) == lease_before

    assert get_in(submit_review(repo, worker_session, head_a, "review-a-retry"), ["error", "data", "reason"]) ==
             "rework_head_not_advanced"

    assert get_in(mcp_tool(repo, worker_session, "complete_review", %{}), ["error", "data", "reason"]) ==
             "rework_head_not_advanced"

    stale_ready = mcp_tool(repo, worker_session, "mark_ready", %{})
    assert "rework_head_advanced" in get_in(stale_ready, ["error", "data", "missing"])

    File.write!(Path.join(worktree, "head-b.txt"), "head B\n")
    TestSupport.git_output!(worktree, ["add", "head-b.txt"])
    TestSupport.git_output!(worktree, ["commit", "-m", "Head B"])
    head_b = worktree |> TestSupport.git_output!(["rev-parse", "HEAD"]) |> String.trim()
    attach_tool(repo, worker_session, "attach_branch", %{"branch" => package.branch_pattern, "head_sha" => head_b})
    assert {:ok, refreshed_events} = PlanningRepository.list_progress_events(repo, package.id)

    assert refreshed_events
           |> Enum.filter(&(&1.payload["type"] == "branch"))
           |> List.last()
           |> get_in([Access.key(:payload), "head_sha"]) == head_b

    attach_tool(repo, worker_session, "attach_pr", %{"url" => pr_url, "head_sha" => head_b})

    assert {:ok, provider_events} = PlanningRepository.list_progress_events(repo, package.id)

    assert PullRequestProgress.expected_head_sha(provider_events, %{repository: "nextide/symphony-plus-plus", number: 9369}) == head_b,
           inspect(Enum.map(provider_events, &{&1.sequence, &1.created_at, &1.payload["source_tool"], &1.payload["head_sha"]}))

    assert get_in(submit_review(repo, worker_session, String.slice(head_b, 0, 12), "review-b-short"), [
             "error",
             "data",
             "reason"
           ]) == "rework_review_head_not_current"

    before_sync = mcp_tool(repo, worker_session, "mark_ready", %{})
    assert "rework_current_pr_state" in get_in(before_sync, ["error", "data", "missing"])

    sync_pr_state(repo, worker_session, pr_url, head_b)

    before_completion = mcp_tool(repo, worker_session, "mark_ready", %{})
    assert "review_complete" in get_in(before_completion, ["error", "data", "missing"])
    completion_b = attach_tool(repo, worker_session, "complete_review", %{"reference" => "review-b-complete"})
    ready_b = mcp_tool(repo, worker_session, "mark_ready", %{})
    assert get_in(ready_b, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"

    assert get_in(completion_a, ["result", "structuredContent", "progress_event", "id"]) !=
             get_in(completion_b, ["result", "structuredContent", "progress_event", "id"])

    assert {:ok, final_events} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.any?(final_events, &(&1.id == accepted_event_id and &1.payload["head_sha"] == head_a))
  end

  test "phase children and terminal packages cannot use accepted review rework", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-REWORK-REJECTED", status: "ready_for_slicing")
    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: "phase-rework-rejected", title: "Rejected rework phase"})

    assert {:ok, parent} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(id: "WP-MCP-REWORK-PARENT", status: "active")
             )

    assert {:ok, child} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(
                 id: "WP-MCP-REWORK-CHILD",
                 kind: "phase_child",
                 status: "ready_for_architect_merge",
                 parent_id: parent.id,
                 phase_id: "phase-rework-rejected"
               )
             )

    assert {:ok, terminal} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(id: "WP-MCP-REWORK-TERMINAL", status: "merged")
             )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, work_request, ["read:work_request", "write:work_request"])

    assert get_in(mcp_tool(repo, session, "accept_review_rework", accepted_rework_arguments(work_request.id, child.id)), [
             "error",
             "data",
             "reason"
           ]) == "phase_child_rework_not_allowed"

    assert get_in(mcp_tool(repo, session, "accept_review_rework", accepted_rework_arguments(work_request.id, terminal.id)), [
             "error",
             "data",
             "reason"
           ]) == "work_package_not_ready_for_rework"
  end

  defp submit_review(repo, session, head_sha, idempotency_key) do
    mcp_tool(repo, session, "submit_review_package", review_arguments(head_sha, idempotency_key))
  end

  defp review_arguments(head_sha, idempotency_key) do
    %{
      "summary" => "Validated #{head_sha}",
      "tests" => ["mix test accepted_review_rework_test.exs"],
      "artifacts" => ["review-suite-#{head_sha}.json"],
      "head_sha" => head_sha,
      "idempotency_key" => idempotency_key
    }
  end

  defp accepted_rework_arguments(work_request_id, work_package_id, head_sha \\ @head_a) do
    %{
      "work_request_id" => work_request_id,
      "work_package_id" => work_package_id,
      "idempotency_key" => "accepted-finding-9369",
      "evidence" => %{
        "provider" => " review-suite ",
        "reference" => " mcpdiag_9369db53009417dd ",
        "head_sha" => head_sha,
        "finding" => " The exact reviewed head has a reachable changes-required finding. "
      }
    }
  end

  defp accepted_rework_event?(%ProgressEvent{payload: payload}) do
    payload["type"] == "accepted_review_rework" and payload["source_tool"] == "accept_review_rework"
  end

  defp provider_snapshot(url, head_sha, merge_state) do
    %{
      "type" => "pr",
      "source_tool" => "sync_pr",
      "url" => url,
      "repository" => "nextide/symphony-plus-plus",
      "number" => 9369,
      "head_sha" => head_sha,
      "check_summary" => %{"status" => "passing"},
      "review_state" => %{"status" => "approved"},
      "merge_state" => merge_state
    }
  end

  defp package_contract(package) do
    package |> immutable_record() |> Map.drop([:status, :dispatched_at])
  end

  defp immutable_record(struct) do
    struct |> Map.from_struct() |> Map.drop([:__meta__, :inserted_at, :updated_at])
  end
end
