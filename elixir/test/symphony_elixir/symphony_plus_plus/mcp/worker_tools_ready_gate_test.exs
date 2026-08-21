Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerToolsReadyGateTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.ReviewRequirement

  defmodule ConcurrentReviewHeadRepo do
    @moduledoc false

    alias Ecto.Changeset
    alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
    alias SymphonyElixir.SymphonyPlusPlus.Repo
    alias SymphonyElixir.TestSupport

    @race_key :sympp_concurrent_review_head

    def arm(worktree_path), do: Process.put(@race_key, worktree_path)
    def disarm, do: Process.delete(@race_key)

    def transaction(fun), do: Repo.transaction(fun)
    def rollback(value), do: Repo.rollback(value)
    def get(schema, id), do: Repo.get(schema, id)
    def get!(schema, id), do: Repo.get!(schema, id)
    def one(query), do: Repo.one(query)
    def all(query), do: Repo.all(query)
    def update_all(query, updates), do: Repo.update_all(query, updates)

    def insert(%Changeset{} = changeset) do
      result = Repo.insert(changeset)
      maybe_advance_head(changeset)
      result
    end

    defp maybe_advance_head(%Changeset{
           data: %ProgressEvent{},
           changes: %{payload: %{"type" => "branch", "source_tool" => "attach_branch"}}
         }) do
      if worktree_path = Process.delete(@race_key) do
        File.write!(Path.join(worktree_path, "concurrent-head.txt"), "changed during review submission\n")
        TestSupport.git_output!(worktree_path, ["add", "concurrent-head.txt"])
        TestSupport.git_output!(worktree_path, ["commit", "-m", "Concurrent head change"])
      end
    end

    defp maybe_advance_head(%Changeset{}), do: :ok
  end

  test "mark_ready keeps provider state and external blocker resolution gates", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-BLOCKER", kind: "standard_pr", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_merge_evidence_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "missing-merge-evidence", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "pr_attached" in get_in(missing_merge_evidence_response, ["error", "data", "missing"])

    empty_review_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "empty-review", "method" => "tools/call", "params" => %{"name" => "submit_review_package", "arguments" => %{}}},
        repo: repo,
        session: session
      )

    assert get_in(empty_review_response, ["error", "data", "reason"]) == "missing_summary"

    assert {:ok, _blocker} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Temporarily blocked",
               status: "blocked",
               payload: %{"type" => "blocker", "source_tool" => "report_blocker", "blocker_id" => "blocker-1", "active" => true}
             })

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-BLOCKER/worker", "head_sha" => "abc125"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/125", "head_sha" => "abc125"})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/125", "abc125")

    blocked_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-blocked", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(blocked_response, ["error", "data", "reason_code"]) == "blocker_closeout_required"
    package_id = package.id
    assert [%{"blocker_id" => "blocker-1", "work_package_id" => ^package_id}] = get_in(blocked_response, ["error", "data", "active_blockers"])

    worker_closeout_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "ready-worker-closeout",
          "method" => "tools/call",
          "params" => %{
            "name" => "mark_ready",
            "arguments" => %{"blocker_closeout" => %{"decision" => "resolved", "blocker_ids" => ["blocker-1"], "resolution" => "worker supplied"}}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(worker_closeout_response, ["error", "code"]) == -32_602

    assert {:ok, _resolution} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Resolved by an authorized operator",
               status: "resolved",
               payload: %{
                 "type" => "blocker",
                 "source_tool" => "resolve_blocker",
                 "blocker_id" => "blocker-1",
                 "resolution" => "Unblocked",
                 "active" => false
               }
             })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-resolved", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "complete_review satisfies only the configured provider requirement at the current exact head", %{repo: repo} do
    review = %{
      "type" => "human",
      "args" => %{"team" => "maintainers", "context" => String.duplicate("x", 5_000)}
    }

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-GENERIC-REVIEW",
                 kind: "mcp",
                 status: "ci_waiting",
                 review_requirement: review
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    pr_url = "https://github.com/example/repo/pull/392"

    no_head =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "review-no-head", "method" => "tools/call", "params" => %{"name" => "complete_review"}},
        repo: repo,
        session: session
      )

    assert get_in(no_head, ["error", "data", "reason"]) == "review_current_head_missing"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/generic-review", "head_sha" => "review-head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => pr_url, "head_sha" => "review-head-a"})
    sync_pr_state(repo, session, pr_url, "review-head-a")

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Spoofed review completion",
      "idempotency_key" => "spoofed-review-completion",
      "payload" => %{"type" => "review_completion", "source_tool" => "complete_review", "review" => review, "head_sha" => "review-head-a"}
    })

    missing_review = mark_ready(repo, session, "ready-missing-review")
    assert "review_complete" in get_in(missing_review, ["error", "data", "missing"])

    completion =
      attach_tool(repo, session, "complete_review", %{
        "reference" => "human-review-42",
        "note" => "Maintainers approved the exact head."
      })

    completion_payload = response_progress_payload(repo, completion)
    assert completion_payload["type"] == "review_completion"
    assert completion_payload["source_tool"] == "complete_review"
    assert completion_payload["work_package_id"] == package.id
    assert completion_payload["head_sha"] == "review-head-a"
    assert completion_payload["reference"] == "human-review-42"
    assert completion_payload["note"] == "Maintainers approved the exact head."
    assert completion_payload["review_fingerprint"] == ReviewRequirement.fingerprint(review)
    assert String.ends_with?(get_in(completion_payload, ["review", "args", "context"]), "[truncated]")
    assert get_in(completion, ["result", "structuredContent", "remaining_readiness_gates"]) == []

    legacy_digest = :crypto.hash(:sha256, Jason.encode!(["review-head-a", review])) |> Base.url_encode64(padding: false)

    assert get_in(completion, ["result", "structuredContent", "progress_event", "idempotency_key"]) ==
             "complete_review:#{package.id}:current:#{legacy_digest}"

    replay =
      attach_tool(repo, session, "complete_review", %{
        "reference" => "human-review-42",
        "note" => "Maintainers approved the exact head."
      })

    assert get_in(replay, ["result", "structuredContent", "progress_event", "id"]) ==
             get_in(completion, ["result", "structuredContent", "progress_event", "id"])

    assert get_in(replay, ["result", "structuredContent", "remaining_readiness_gates"]) == []

    changed_review = %{"type" => "automated", "args" => %{"policy" => "internal"}}
    package |> Ecto.Changeset.change(review_requirement: changed_review) |> repo.update!()
    requirement_changed = mark_ready(repo, session, "ready-changed-requirement")
    assert "review_complete" in get_in(requirement_changed, ["error", "data", "missing"])

    assert {:ok, package} = WorkPackageRepository.get(repo, package.id)
    package |> Ecto.Changeset.change(review_requirement: review) |> repo.update!()

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/generic-review", "head_sha" => "REVIEW-HEAD-B"})
    attach_tool(repo, session, "attach_pr", %{"url" => pr_url, "head_sha" => "review-head-b"})
    sync_pr_state(repo, session, pr_url, "review-head-b")

    stale_review = mark_ready(repo, session, "ready-stale-review")
    assert "review_complete" in get_in(stale_review, ["error", "data", "missing"])

    attach_tool(repo, session, "complete_review", %{})
    ready = mark_ready(repo, session, "ready-current-review")
    assert get_in(ready, ["result", "structuredContent", "ready"]) == true
  end

  test "submit_review_package atomically refreshes a live scoped worktree head and invalidates old review evidence", %{repo: repo} do
    live = live_review_fixture!(repo, "SYMPP-LIVE-REVIEW-HEAD")
    config = Config.default(repo: repo, repo_root: live.fixture.repo_root)

    live_tool(repo, live.session, config, "attach_branch", %{"branch" => live.branch, "head_sha" => live.head_a})

    live_tool(repo, live.session, config, "submit_review_package", %{
      "summary" => "Review at head A",
      "tests" => ["mix test"],
      "artifacts" => ["head-a.txt"],
      "head_sha" => live.head_a
    })

    live_tool(repo, live.session, config, "complete_review", %{"reference" => "review-a"})
    head_b = commit_worktree!(live.worktree, "head-b.txt", "head B\n", "Head B")

    review_arguments = %{
      "summary" => "Review at head B",
      "tests" => ["mix test"],
      "artifacts" => ["head-b.txt"],
      "head_sha" => String.upcase(head_b)
    }

    response = live_tool(repo, live.session, config, "submit_review_package", review_arguments)
    replay = live_tool(repo, live.session, config, "submit_review_package", review_arguments)

    assert response_progress_payload(repo, response)["head_sha"] == head_b

    assert get_in(replay, ["result", "structuredContent", "progress_event", "id"]) ==
             get_in(response, ["result", "structuredContent", "progress_event", "id"])

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, live.package.id)

    refreshed_branch =
      events
      |> Enum.filter(&(get_in(&1.payload, ["type"]) == "branch"))
      |> List.last()

    current_review =
      events
      |> Enum.filter(&(get_in(&1.payload, ["type"]) == "review_package"))
      |> List.last()

    assert refreshed_branch.payload["branch"] == live.branch
    assert refreshed_branch.payload["head_sha"] == head_b
    assert current_review.payload["head_sha"] == head_b
    assert current_review.sequence == refreshed_branch.sequence + 1

    assert Enum.any?(events, fn event ->
             get_in(event.payload, ["type"]) == "review_completion" and event.payload["head_sha"] == live.head_a
           end)

    not_ready = live_request(repo, live.session, config, "mark_ready", %{})
    assert "review_complete" in get_in(not_ready, ["error", "data", "missing"])
  end

  test "submit_review_package rejects heads without matching live worktree proof", %{repo: repo} do
    live = live_review_fixture!(repo, "SYMPP-LIVE-REVIEW-NEGATIVE")
    config = Config.default(repo: repo, repo_root: live.fixture.repo_root)
    live_tool(repo, live.session, config, "attach_branch", %{"branch" => live.branch, "head_sha" => live.head_a})
    head_b = commit_worktree!(live.worktree, "head-b.txt", "head B\n", "Head B")

    mismatched = review_head_request(repo, live, config, String.duplicate("f", 40))
    assert_review_head_proof_error(mismatched, "worktree_head_mismatch")

    TestSupport.git_output!(live.worktree, ["checkout", "-b", "other-branch"])
    wrong_branch = review_head_request(repo, live, config, head_b)
    assert_review_head_proof_error(wrong_branch, "worktree_branch_mismatch")
    TestSupport.git_output!(live.worktree, ["checkout", live.branch])

    assert {:ok, _package} =
             WorkPackageRepository.update(repo, live.package.id, %{
               worktree_path: nil,
               worktree_target_repo_root: nil
             })

    unrecorded = review_head_request(repo, live, config, head_b)
    assert_review_head_proof_error(unrecorded, "worktree_scope_required")

    foreign = TestSupport.git_repo_fixture!("main", prefix: "sympp-live-review-foreign")

    assert {:ok, _package} =
             WorkPackageRepository.update(repo, live.package.id, %{
               worktree_path: foreign.repo_root,
               worktree_target_repo_root: foreign.repo_root
             })

    foreign_repo = review_head_request(repo, live, config, head_b)
    assert_review_head_proof_error(foreign_repo, "target_repo_root_required")

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, live.package.id)
    assert Enum.count(events, &(get_in(&1.payload, ["type"]) == "branch")) == 1
    refute Enum.any?(events, &(get_in(&1.payload, ["type"]) == "review_package"))
  end

  test "submit_review_package rolls back a concurrent live head change", %{repo: repo} do
    live = live_review_fixture!(repo, "SYMPP-LIVE-REVIEW-RACE")
    initial_config = Config.default(repo: repo, repo_root: live.fixture.repo_root)
    live_tool(repo, live.session, initial_config, "attach_branch", %{"branch" => live.branch, "head_sha" => live.head_a})
    head_b = commit_worktree!(live.worktree, "head-b.txt", "head B\n", "Head B")
    race_config = Config.default(repo: ConcurrentReviewHeadRepo, repo_root: live.fixture.repo_root)

    try do
      ConcurrentReviewHeadRepo.arm(live.worktree)
      response = review_head_request(ConcurrentReviewHeadRepo, live, race_config, head_b)

      assert get_in(response, ["error", "data", "reason"]) == "concurrent_head_change"
      assert get_in(response, ["error", "data", "proof_failure"]) == "worktree_head_mismatch"
      assert get_in(response, ["error", "data", "recovery", "next_action"]) == "retry_submit_review_package"
    after
      ConcurrentReviewHeadRepo.disarm()
    end

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, live.package.id)
    assert Enum.count(events, &(get_in(&1.payload, ["type"]) == "branch")) == 1
    refute Enum.any?(events, &(get_in(&1.payload, ["type"]) == "review_package"))
    assert {:ok, []} = PlanningRepository.list_artifacts(repo, live.package.id)
  end

  test "legacy stored merge-ready status can still transition to merged", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-LEGACY-STATUS", kind: "mcp", status: "ready_for_merge")
             )

    repo.update_all(from(work_package in WorkPackage, where: work_package.id == ^package.id), set: [status: "ready_for_human_merge"])

    assert {:ok, updated} = WorkPackageRepository.update_status(repo, package.id, "ready_for_human_merge", "merged")
    assert updated.status == "merged"
  end

  test "ready evidence guard reads only the package with 1,000 history rows", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-GUARD-BOUNDED", kind: "mcp", status: "ready_for_worker")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    assert {1, nil} =
             repo.update_all(
               from(work_package in WorkPackage, where: work_package.id == ^package.id),
               set: [status: "ready_for_merge"]
             )

    now = DateTime.utc_now(:microsecond)

    rows =
      for sequence <- 1..1_000 do
        %{
          id: "progress-ready-guard-#{sequence}",
          work_package_id: package.id,
          summary: "Historical progress #{sequence}",
          status: "recorded",
          sequence: sequence,
          idempotency_scope: "direct",
          payload: %{},
          created_at: now,
          inserted_at: now,
          updated_at: now
        }
      end

    assert {1_000, nil} = repo.insert_all(ProgressEvent, rows)

    {response, queries} =
      capture_queries(repo, fn ->
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "ready-guard-bounded",
            "method" => "tools/call",
            "params" => %{
              "name" => "append_progress",
              "arguments" => %{"summary" => "Must remain rejected", "idempotency_key" => "ready-guard-bounded"}
            }
          },
          repo: repo,
          session: session
        )
      end)

    assert get_in(response, ["error", "data", "reason"]) == "already_ready"

    lock_index =
      Enum.find_index(queries, fn query ->
        String.starts_with?(query, "UPDATE \"sympp_work_packages\"") and String.contains?(query, "SET \"id\"")
      end)

    assert is_integer(lock_index)
    guard_queries = Enum.drop(queries, lock_index + 1)

    assert Enum.count(guard_queries, &String.contains?(&1, "FROM \"sympp_work_packages\"")) == 1
    refute Enum.any?(guard_queries, &String.contains?(&1, "FROM \"sympp_progress_events\""))
  end

  defp mark_ready(repo, session, id) do
    MCPHarness.request(
      %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
      repo: repo,
      session: session
    )
  end

  defp live_review_fixture!(repo, id) do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-live-review-head")
    branch = "agent/#{id}/worker"
    worktree = Path.join(fixture.root, "worktree")
    TestSupport.git_output!(fixture.repo_root, ["worktree", "add", "-b", branch, worktree, "HEAD"])
    head_a = fixture.repo_root |> TestSupport.git_output!(["rev-parse", "HEAD"]) |> String.trim()

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: id,
                 repo: fixture.origin,
                 branch_pattern: branch,
                 worktree_path: worktree,
                 worktree_target_repo_root: fixture.repo_root,
                 review_requirement: %{"type" => "human"},
                 status: "ci_waiting"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: id)
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    %{fixture: fixture, worktree: worktree, branch: branch, head_a: head_a, package: package, session: session}
  end

  defp commit_worktree!(worktree, file, contents, message) do
    File.write!(Path.join(worktree, file), contents)
    TestSupport.git_output!(worktree, ["add", file])
    TestSupport.git_output!(worktree, ["commit", "-m", message])
    worktree |> TestSupport.git_output!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp review_head_request(repo, live, config, head_sha) do
    live_request(repo, live.session, config, "submit_review_package", %{
      "summary" => "Review new head",
      "tests" => ["mix test"],
      "artifacts" => ["new-head.txt"],
      "head_sha" => head_sha
    })
  end

  defp assert_review_head_proof_error(response, proof_failure) do
    assert get_in(response, ["error", "data", "reason"]) == "stale_head_sha"
    assert get_in(response, ["error", "data", "proof_failure"]) == proof_failure
    assert get_in(response, ["error", "data", "recovery", "next_action"]) == "attach_branch"
  end

  defp live_tool(repo, session, config, name, arguments) do
    response = live_request(repo, session, config, name, arguments)
    assert get_in(response, ["result", "structuredContent", "progress_event", "id"])
    response
  end

  defp live_request(repo, session, config, name, arguments) do
    MCPHarness.request(
      %{"jsonrpc" => "2.0", "id" => name, "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}},
      repo: repo,
      session: session,
      config: config
    )
  end

  defp capture_queries(repo, fun) do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    event = repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, test_pid -> send(test_pid, {handler_id, metadata.query}) end,
        self()
      )

    try do
      result = fun.()
      {result, drain_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, queries) do
    receive do
      {^handler_id, query} -> drain_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
