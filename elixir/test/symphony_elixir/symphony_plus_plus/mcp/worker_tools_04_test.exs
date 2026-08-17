Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools04Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.{MetadataProjection, OperationalProjection}

  defmodule RecordingProvider do
    @behaviour SymphonyElixir.SymphonyPlusPlus.GitHub.Client

    @impl true
    def fetch_pull_request(ref, opts) do
      send(self(), {:provider_fetch, ref.repository, ref.number})
      SymphonyElixir.FakeGitHubClient.fetch_pull_request(ref, opts)
    end
  end

  setup do
    original_client = Application.get_env(:symphony_elixir, :sympp_github_client)
    Application.put_env(:symphony_elixir, :sympp_github_client, RecordingProvider)
    SymphonyElixir.FakeGitHubClient.clear()

    on_exit(fn ->
      SymphonyElixir.FakeGitHubClient.clear()

      case original_client do
        nil -> Application.delete_env(:symphony_elixir, :sympp_github_client)
        client -> Application.put_env(:symphony_elixir, :sympp_github_client, client)
      end
    end)

    :ok
  end

  test "review package submitted before PR attach does not satisfy later PR readiness", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PRE-PR-REVIEW", kind: "mcp", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PRE-PR-REVIEW/worker", "head_sha" => "pre-pr-head"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Pre-PR review",
      "tests" => ["mix test"],
      "artifacts" => ["pre-pr-review.txt"],
      "head_sha" => "pre-pr-head",
      "acceptance_criteria_met" => true
    })

    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/456", "head_sha" => "later-head"})

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-pr-attach", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(ready_response, ["error", "data", "missing"])
    assert "pr_attached" in missing
    refute "review_artifacts_attached" in missing
  end

  test "branch-only readiness rejects review evidence from an older branch head", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BRANCH-HEAD-REVIEW", kind: "quick_fix", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-BRANCH-HEAD-REVIEW/worker", "head_sha" => "old-head"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Old head review",
      "tests" => ["mix test"],
      "artifacts" => ["old-head-review.txt"],
      "head_sha" => "old-head"
    })

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-BRANCH-HEAD-REVIEW/worker", "head_sha" => "new-head"})

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(ready_response, ["error", "data", "missing"])
    assert "tests_passed" in missing
  end

  test "submit_review_package replay remains idempotent after branch head changes", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-REVIEW-REPLAY", kind: "mcp", status: "ci_waiting"))

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-REPLAY/worker", "head_sha" => "head-a"})

    review_arguments = %{
      "summary" => "Review head A",
      "tests" => ["mix test"],
      "artifacts" => ["review-head-a.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true
    }

    first_response = attach_tool(repo, session, "submit_review_package", review_arguments)
    first_event_id = get_in(first_response, ["result", "structuredContent", "progress_event", "id"])

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-REPLAY/worker", "head_sha" => "head-b"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/791", "head_sha" => "head-b"})

    retry_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "retry-review-head-a",
          "method" => "tools/call",
          "params" => %{"name" => "submit_review_package", "arguments" => review_arguments}
        },
        repo: repo,
        session: session
      )

    assert get_in(retry_response, ["result", "structuredContent", "progress_event", "id"]) == first_event_id

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-replay", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "acceptance_criteria_met" in get_in(ready_response, ["error", "data", "missing"])
    assert "tests_passed" in get_in(ready_response, ["error", "data", "missing"])
  end

  test "submit_review_package exact replay survives worker grant renewal", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-REVIEW-REGRANT", kind: "mcp", status: "ci_waiting"))

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-REGRANT/worker", "head_sha" => "head-a"})

    review_arguments = %{
      "summary" => "Review head A",
      "tests" => ["mix test"],
      "artifacts" => ["review-head-a.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true
    }

    first_response = attach_tool(repo, session, "submit_review_package", review_arguments)
    first_event_id = get_in(first_response, ["result", "structuredContent", "progress_event", "id"])

    assert {:ok, second_minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, second_assignment} = AccessGrantService.claim(repo, second_minted.work_key.secret, claimed_by: "worker-2")
    second_session = MCPHarness.session(second_assignment, proof_hash: second_minted.grant.secret_hash)

    retry_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "retry-review-regrant",
          "method" => "tools/call",
          "params" => %{"name" => "submit_review_package", "arguments" => review_arguments}
        },
        repo: repo,
        session: second_session
      )

    assert get_in(retry_response, ["result", "structuredContent", "progress_event", "id"]) == first_event_id

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, package.id)

    assert 1 ==
             Enum.count(progress_events, fn event ->
               event.status == "review_package_submitted" and event.payload["head_sha"] == "head-a"
             end)
  end

  test "metadata attachments require a scoped live session", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-METADATA-SCOPE", kind: "quick_fix", status: "ci_waiting"))
    assert {:ok, sibling_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-METADATA-SIBLING", kind: "quick_fix", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_session_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "branch-missing-session",
          "method" => "tools/call",
          "params" => %{"name" => "attach_branch", "arguments" => %{"branch" => "agent/SYMPP-METADATA-SCOPE/worker", "head_sha" => "head-a"}}
        },
        repo: repo
      )

    assert get_in(missing_session_response, ["error", "data", "reason"]) == "claim_required"

    stale_scope_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "pr-wrong-package",
          "method" => "tools/call",
          "params" => %{
            "name" => "attach_pr",
            "arguments" => %{"work_package_id" => sibling_package.id, "url" => "https://github.com/example/repo/pull/792", "head_sha" => "head-a"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_scope_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "metadata tools honor caller idempotency keys for repeated matching payloads", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-METADATA-IDEMPOTENCY", kind: "quick_fix", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-METADATA-IDEMPOTENCY/worker", "head_sha" => "same-head", "idempotency_key" => "branch-key-1"})
    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-METADATA-IDEMPOTENCY/worker", "head_sha" => "same-head", "idempotency_key" => "branch-key-2"})

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, package.id)

    assert events
           |> Enum.filter(&(get_in(&1.payload, ["type"]) == "branch" and get_in(&1.payload, ["head_sha"]) == "same-head"))
           |> length() == 2
  end

  test "sync_pr fetches only the attached PR and stores canonical provider states", %{repo: repo} do
    {package, session} = sync_package(repo, "SYMPP-PROVIDER-STATES", 42, "head-a")

    for status <- ~w(passing failing pending unknown) do
      metadata =
        provider_metadata(42, "head-a")
        |> Map.put("check_summary", %{"status" => status})

      SymphonyElixir.FakeGitHubClient.put_response("nextide/repo", 42, metadata)

      response = attach_tool(repo, session, "sync_pr", %{"idempotency_key" => "provider-state-#{status}"})
      payload = response_progress_payload(repo, response)

      assert payload["check_summary"] == %{"status" => status}
      assert payload["review_state"] == %{"status" => "approved"}
      assert payload["merge_state"] == %{"merged" => false, "status" => "clean"}
      assert payload["provider_reference"] == "https://github.com/nextide/repo/pull/42"
      assert {:ok, _observed_at, 0} = DateTime.from_iso8601(payload["observed_at"])
      assert_receive {:provider_fetch, "nextide/repo", 42}
      refute_receive {:provider_fetch, _, _}
    end

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.count(events, &(&1.status == "pr_synced")) == 4
  end

  test "default sync_pr retries replay before fetching the provider", %{repo: repo} do
    {package, session} = sync_package(repo, "SYMPP-PROVIDER-REPLAY", 48, "head-a")
    SymphonyElixir.FakeGitHubClient.put_response("nextide/repo", 48, provider_metadata(48, "head-a"))
    arguments = %{"idempotency_key" => "provider-retry", "url" => "https://github.com/nextide/repo/pull/48"}

    first = attach_tool(repo, session, "sync_pr", arguments)
    event_id = get_in(first, ["result", "structuredContent", "progress_event", "id"])
    assert_receive {:provider_fetch, "nextide/repo", 48}

    SymphonyElixir.FakeGitHubClient.put_response("nextide/repo", 48, {:error, :request_failed})
    replay = attach_tool(repo, session, "sync_pr", arguments)

    assert get_in(replay, ["result", "structuredContent", "progress_event", "id"]) == event_id
    refute_receive {:provider_fetch, _, _}

    package |> Ecto.Changeset.change(status: "ready_for_merge") |> repo.update!()
    terminal_replay = attach_tool(repo, session, "sync_pr", arguments)

    assert get_in(terminal_replay, ["result", "structuredContent", "progress_event", "id"]) == event_id
    refute_receive {:provider_fetch, _, _}
  end

  test "recovery retries replay with the persisted observation time and reject changed state", %{repo: repo} do
    {_package, session} = sync_package(repo, "SYMPP-RECOVERY-REPLAY", 49, "head-a")

    recovery = %{
      "url" => "https://github.com/nextide/repo/pull/49",
      "head_sha" => "head-a",
      "observed_at" => "",
      "check_summary" => %{"status" => "passing"},
      "review_state" => %{"status" => "approved"},
      "merge_state" => %{"status" => "clean", "merged" => false}
    }

    arguments = %{"idempotency_key" => "recovery-retry", "recovery" => recovery}
    first = attach_tool(repo, session, "sync_pr", arguments)
    event_id = get_in(first, ["result", "structuredContent", "progress_event", "id"])

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-RECOVERY-REPLAY", "head_sha" => "head-b"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/nextide/repo/pull/49", "head_sha" => "head-b"})

    replay = attach_tool(repo, session, "sync_pr", arguments)
    assert get_in(replay, ["result", "structuredContent", "progress_event", "id"]) == event_id

    changed = put_in(arguments, ["recovery", "check_summary", "status"], "failing")

    conflict =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "recovery-conflict",
          "method" => "tools/call",
          "params" => %{"name" => "sync_pr", "arguments" => changed}
        },
        repo: repo,
        session: session
      )

    assert get_in(conflict, ["error", "data", "reason"]) == "idempotency_conflict"
    refute_receive {:provider_fetch, _, _}
  end

  test "sync_pr provider failures preserve the previous snapshot", %{repo: repo} do
    {package, session} = sync_package(repo, "SYMPP-PROVIDER-FAILURE", 43, "head-a")
    SymphonyElixir.FakeGitHubClient.put_response("nextide/repo", 43, provider_metadata(43, "head-a"))

    successful = attach_tool(repo, session, "sync_pr", %{})
    snapshot = response_progress_payload(repo, successful)
    assert_receive {:provider_fetch, "nextide/repo", 43}
    assert {:ok, before_events} = PlanningRepository.list_progress_events(repo, package.id)

    for {response, reason} <- [{{:error, :request_failed}, "provider_unavailable"}, {:malformed, "provider_malformed"}] do
      SymphonyElixir.FakeGitHubClient.put_response("nextide/repo", 43, response)

      failed =
        MCPHarness.request(
          %{"jsonrpc" => "2.0", "id" => reason, "method" => "tools/call", "params" => %{"name" => "sync_pr", "arguments" => %{}}},
          repo: repo,
          session: session
        )

      assert get_in(failed, ["error", "code"]) == -32_000
      assert get_in(failed, ["error", "data", "layer"]) == "provider"
      assert get_in(failed, ["error", "data", "reason"]) == reason
      assert_receive {:provider_fetch, "nextide/repo", 43}
      assert {:ok, after_events} = PlanningRepository.list_progress_events(repo, package.id)
      assert after_events == before_events
      assert Enum.find(after_events, &(&1.status == "pr_synced")).payload == snapshot
    end
  end

  test "sync_pr rejects identity and provider head mismatches without replacing the snapshot", %{repo: repo} do
    {package, session} = sync_package(repo, "SYMPP-PROVIDER-HEAD", 44, "head-a")
    SymphonyElixir.FakeGitHubClient.put_response("nextide/repo", 44, provider_metadata(44, "head-a"))
    attach_tool(repo, session, "sync_pr", %{})
    assert_receive {:provider_fetch, "nextide/repo", 44}
    assert {:ok, before_events} = PlanningRepository.list_progress_events(repo, package.id)

    wrong_pr =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "wrong-pr",
          "method" => "tools/call",
          "params" => %{"name" => "sync_pr", "arguments" => %{"url" => "https://github.com/nextide/repo/pull/45"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(wrong_pr, ["error", "data", "reason"]) == "pr_reference_mismatch"
    refute_receive {:provider_fetch, _, _}

    SymphonyElixir.FakeGitHubClient.put_response("nextide/repo", 44, provider_metadata(44, "head-b"))

    stale =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "stale-head", "method" => "tools/call", "params" => %{"name" => "sync_pr", "arguments" => %{}}},
        repo: repo,
        session: session
      )

    assert get_in(stale, ["error", "data", "reason"]) == "provider_head_mismatch"
    assert get_in(stale, ["error", "data", "expected_head_sha"]) == "head-a"
    assert get_in(stale, ["error", "data", "actual_head_sha"]) == "head-b"
    assert get_in(stale, ["error", "data", "recovery", "next_action"]) == "prove_current_head_then_retry_sync_pr"
    assert_receive {:provider_fetch, "nextide/repo", 44}
    assert {:ok, after_events} = PlanningRepository.list_progress_events(repo, package.id)
    assert after_events == before_events
  end

  test "sync_pr accepts canonical state only through explicit recovery import", %{repo: repo} do
    {_package, session} = sync_package(repo, "SYMPP-PROVIDER-IMPORT", 46, "head-a")

    top_level =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "manual-top-level",
          "method" => "tools/call",
          "params" => %{"name" => "sync_pr", "arguments" => %{"check_summary" => %{"status" => "passing"}}}
        },
        repo: repo,
        session: session
      )

    assert get_in(top_level, ["error", "data", "reason"]) == "unexpected_argument"
    refute_receive {:provider_fetch, _, _}

    recovery = %{
      "url" => "https://github.com/nextide/repo/pull/46",
      "head_sha" => "head-a",
      "branch" => "agent/SYMPP-PROVIDER-IMPORT/worker",
      "base_branch" => "main",
      "base_sha" => "base-a",
      "changed_files" => [],
      "check_summary" => %{"status" => "passing"},
      "review_state" => %{"status" => "approved"},
      "merge_state" => %{"status" => "clean", "merged" => false},
      "provider_reference" => "import-46"
    }

    imported = attach_tool(repo, session, "sync_pr", %{"recovery" => recovery})
    payload = response_progress_payload(repo, imported)
    assert payload["check_summary"] == %{"status" => "passing"}
    assert payload["provider_reference"] == "import-46"
    refute_receive {:provider_fetch, _, _}

    invalid =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-import",
          "method" => "tools/call",
          "params" => %{"name" => "sync_pr", "arguments" => %{"recovery" => put_in(recovery, ["check_summary", "status"], "green")}}
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid, ["error", "data", "reason"]) == "invalid_recovery"
  end

  test "agent transcript attaches, zero-syncs, submits review, and exposes remaining gate", %{repo: repo} do
    {package, session} =
      sync_package(repo, "SYMPP-PROVIDER-TRANSCRIPT", 47, "head-a", review_requirement: %{"type" => "review_suite", "args" => %{"mode" => "fast"}})

    append_done_plan(repo, package.id)
    SymphonyElixir.FakeGitHubClient.put_response("nextide/repo", 47, provider_metadata(47, "head-a"))
    attach_tool(repo, session, "sync_pr", %{})
    assert_receive {:provider_fetch, "nextide/repo", 47}

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Provider snapshot implementation",
      "tests" => ["mix test"],
      "artifacts" => ["review-suite-fast.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true
    })

    ready =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(ready, ["error", "data", "missing"])
    assert "review_complete" in missing
    refute "pr_attached" in missing
    refute "tests_passed" in missing
  end

  test "attach_pr number requires unambiguous repository context for short package repos", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-NUMBER-SHORT-REPO",
                 kind: "mcp",
                 repo: "symphony-plus-plus",
                 status: "ci_waiting"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_context =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "attach_pr",
          "method" => "tools/call",
          "params" => %{"name" => "attach_pr", "arguments" => %{"number" => 42, "head_sha" => "head-a"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(missing_context, ["error", "data", "reason"]) == "missing_repository_use_url_or_owner_repo"

    explicit_repository =
      attach_tool(repo, session, "attach_pr", %{"number" => "42", "repository" => "nextide/symphony-plus-plus", "head_sha" => "head-a"})

    assert response_progress_payload(repo, explicit_repository)["url"] ==
             "https://github.com/nextide/symphony-plus-plus/pull/42"

    url_package =
      WorkPackageFactory.attrs(
        id: "SYMPP-PR-URL-SHORT-REPO",
        kind: "mcp",
        repo: "symphony-plus-plus",
        status: "ci_waiting"
      )

    assert {:ok, url_package} = WorkPackageRepository.create(repo, url_package)
    assert {:ok, url_minted} = AccessGrantService.mint_worker_grant(repo, url_package.id)
    assert {:ok, url_assignment} = AccessGrantService.claim(repo, url_minted.work_key.secret, claimed_by: "worker-1")
    url_session = MCPHarness.session(url_assignment, proof_hash: url_minted.grant.secret_hash)

    url_response =
      attach_tool(repo, url_session, "attach_pr", %{"url" => "https://github.com/nextide/symphony-plus-plus/pull/43", "head_sha" => "head-a"})

    assert response_progress_payload(repo, url_response)["number"] == 43
  end

  test "attach_pr idempotency replay accepts legacy URL-only payload shape", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PR-LEGACY-REPLAY", kind: "mcp", repo: "nextide/symphony-plus-plus", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    idempotency_key = "attach_pr:#{package.id}:legacy-pr-key"

    assert {:ok, legacy_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "pr_attached",
               status: "pr_attached",
               idempotency_key: idempotency_key,
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/nextide/symphony-plus-plus/pull/42",
                 head_sha: "legacy-head"
               }
             })

    response =
      attach_tool(repo, session, "attach_pr", %{
        "number" => 42,
        "head_sha" => "legacy-head",
        "idempotency_key" => "legacy-pr-key"
      })

    assert get_in(response, ["result", "structuredContent", "progress_event", "id"]) == legacy_event.id

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.count(events, &(&1.idempotency_key == idempotency_key)) == 1
  end

  test "sync_pr preserves service error shape for PR metadata lookup failures" do
    session =
      Session.new(
        %Assignment{
          grant_id: "grant-pr-sync-service",
          work_package_id: "SYMPP-PR-SERVICE-ERROR",
          display_key: "ABCD",
          grant_role: "worker",
          capabilities: ["read:own", "write:own"],
          claimed_at: ~U[2026-05-05 00:00:00Z],
          claimed_by: "worker-1"
        },
        proof_hash: "proof"
      )

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync-pr-service-error",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{}
          }
        },
        repo: BusyPrSyncRepo,
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_000
    assert get_in(response, ["error", "data", "resource"]) == "sync_pr"
    assert get_in(response, ["error", "data", "reason"]) == "ledger_unavailable"
  end

  test "latest branch head supersedes earlier PR head for review evidence", %{repo: repo} do
    full_head_sha = "abcdef1234567890abcdef1234567890abcdef12"
    short_head_sha = "abcdef12"
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-BRANCH-HEAD", kind: "quick_fix", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-BRANCH-HEAD/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/789", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-BRANCH-HEAD/worker", "head_sha" => short_head_sha})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/789", "head_sha" => "head-a"})

    stale_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "stale-review",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Old PR head review",
              "tests" => ["mix test"],
              "artifacts" => ["old-pr-head-review.txt"],
              "head_sha" => "bbcdef1234567890abcdef1234567890abcdef12"
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_response, ["error", "data", "reason"]) == "stale_head_sha"

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Latest branch head review",
      "tests" => ["mix test"],
      "artifacts" => ["latest-branch-head-review.txt"],
      "head_sha" => full_head_sha
    })

    assert MetadataProjection.review_head_matches?(%{"head_sha" => full_head_sha}, short_head_sha)
    refute MetadataProjection.review_head_matches?(%{"head_sha" => full_head_sha}, "bbcdef12")
    assert {:ok, state} = PlanningRepository.get_state(repo, package.id)
    context = OperationalProjection.readiness_context(state, repo, 0, 0)
    refute "review_artifacts_attached" in OperationalProjection.missing_readiness_evidence(context)

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "latest branch head requires matching PR metadata for merge-gated readiness", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CURRENT-HEAD-PR", kind: "mcp", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-CURRENT-HEAD-PR/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-CURRENT-HEAD-PR/worker", "head_sha" => "head-b"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Latest branch head review",
      "tests" => ["mix test"],
      "artifacts" => ["latest-branch-head-review.txt"],
      "head_sha" => "head-b",
      "acceptance_criteria_met" => true
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(ready_response, ["error", "data", "missing"])
    assert "pr_attached" in missing
  end

  defp sync_package(repo, id, number, head_sha, overrides \\ []) do
    attrs =
      [id: id, kind: "mcp", repo: "nextide/repo", status: "ci_waiting"]
      |> Keyword.merge(overrides)

    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(attrs))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "provider-owner")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/#{id}/worker", "head_sha" => head_sha})
    attach_tool(repo, session, "attach_pr", %{"number" => number, "head_sha" => head_sha})
    {package, session}
  end

  defp provider_metadata(number, head_sha) do
    SymphonyElixir.GitHubPullRequestFixtures.metadata(number, head_sha)
    |> Map.put("check_summary", %{"status" => "passing"})
    |> Map.put("review_state", %{"status" => "approved"})
  end
end
