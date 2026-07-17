Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPGuidanceRequestsTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Service, as: GuidanceRequestService
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Auth, Config}
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.TestSupport
  alias SymphonyElixir.WorkPackageFactory

  @phase_id "phase-guidance-requests-test"
  @repo_name "nextide/symphony-plus-plus"
  @base_branch "symphony-plus-plus/beta"
  @architect_capabilities ["read:guidance_request", "write:guidance_request"]
  @guidance_eligible_statuses ["ready_for_worker", "claimed", "planning", "implementing", "reviewing", "ci_waiting", "blocked"]
  @guidance_ineligible_statuses [
    "created",
    "ready_for_merge",
    "ready_for_architect_merge",
    "merging_into_phase",
    "merged_into_phase",
    "merged",
    "closed",
    "abandoned"
  ]

  defmodule GuidanceCreateLifecycleRaceRepo do
    @moduledoc false

    import Ecto.Query, only: [from: 2]

    alias SymphonyElixir.SymphonyPlusPlus.Repo
    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

    @race_key :sympp_guidance_create_lifecycle_race

    def arm(work_package_id, status), do: Process.put(@race_key, {work_package_id, status})
    def disarm, do: Process.delete(@race_key)

    def transaction(fun) do
      case Process.get(@race_key) do
        {work_package_id, status} when is_binary(work_package_id) and is_binary(status) ->
          Process.delete(@race_key)

          Repo.update_all(
            from(work_package in WorkPackage, where: work_package.id == ^work_package_id),
            set: [status: status, updated_at: DateTime.utc_now(:microsecond)]
          )

        _race ->
          :ok
      end

      Repo.transaction(fun)
    end

    def get(schema, id), do: Repo.get(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def all(query), do: Repo.all(query)
    def one(query), do: Repo.one(query)
    def update(changeset), do: Repo.update(changeset)
    def update_all(query, updates), do: Repo.update_all(query, updates)
    def rollback(value), do: Repo.rollback(value)
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkPackageRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(GuidanceRequest)
    repo.delete_all(ProgressEvent)
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkRequest)
    repo.delete_all(WorkPackage)
    repo.delete_all(Phase)

    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: @phase_id, title: "Guidance requests test phase"})

    :ok
  end

  test "workers create and read their own package guidance idempotently", %{repo: repo} do
    {package, worker_session} = create_worker_session(repo, "SYMPP-GUIDANCE-WORKER")

    create_args = %{
      "summary" => "Need boundary decision",
      "question" => "Should this worker add a compatibility shim?",
      "context" => "The assignment says no old-compat shims unless current code requires them.",
      "idempotency_key" => "guidance-create-1"
    }

    create_response = mcp_tool(repo, worker_session, "create_guidance_request", create_args)
    guidance_request = get_in(create_response, ["result", "structuredContent", "guidance_request"])

    assert guidance_request["status"] == "open"
    assert guidance_request["summary"] == "Need boundary decision"
    assert guidance_request["requested_by"] == "worker-1"
    assert guidance_request["answer"] == nil

    replay_response = mcp_tool(repo, worker_session, "create_guidance_request", create_args)
    assert get_in(replay_response, ["result", "structuredContent", "guidance_request", "id"]) == guidance_request["id"]
    assert get_in(replay_response, ["result", "structuredContent", "guidance_request", "requested_by"]) == "worker-1"

    conflict_response =
      mcp_tool(repo, worker_session, "create_guidance_request", %{create_args | "question" => "Different question"})

    assert get_in(conflict_response, ["error", "data", "reason"]) == "idempotency_conflict"

    read_response = mcp_tool(repo, worker_session, "read_guidance_request", %{"guidance_request_id" => guidance_request["id"]})
    assert get_in(read_response, ["result", "structuredContent", "guidance_request", "id"]) == guidance_request["id"]
    assert get_in(read_response, ["result", "structuredContent", "guidance_request", "requested_by"]) == "worker-1"

    second_worker_session = create_worker_session_for_package(repo, package, "worker-2")

    second_response =
      mcp_tool(repo, second_worker_session, "create_guidance_request", %{
        create_args
        | "question" => "A different worker can reuse the same key inside the same package."
      })

    second_guidance_request = get_in(second_response, ["result", "structuredContent", "guidance_request"])
    assert second_guidance_request["id"] != guidance_request["id"]
    assert second_guidance_request["status"] == "open"

    second_worker_read_response =
      mcp_tool(repo, second_worker_session, "read_guidance_request", %{"guidance_request_id" => guidance_request["id"]})

    assert get_in(second_worker_read_response, ["error", "data", "reason"]) == "not_found"
  end

  test "worker guidance replay normalizes atom-keyed structured prompt payloads", %{repo: repo} do
    {_package, worker_session} = create_worker_session(repo, "SYMPP-GUIDANCE-ATOM-PROMPT")

    create_attrs = %{
      "summary" => "Need prompt replay",
      "question" => "Can a structured prompt replay cleanly?",
      "context" => "The worker retries an Elixir-built payload with nested atom keys.",
      "idempotency_key" => "guidance-atom-prompt",
      decision_prompt: %{
        tl_dr: "Choose replay behavior.",
        details: "The same structured prompt should replay instead of conflicting.",
        options: [
          %{
            id: "continue",
            label: "Continue",
            description: "Proceed with the existing path.",
            pros: ["Keeps retry idempotent"],
            cons: ["No alternate behavior in this test"],
            answer: "Continue with the existing path."
          }
        ],
        custom_redirect_label: "No, and tell the agent what to do differently"
      }
    }

    assert {:ok, created} = GuidanceRequestService.create_for_worker(repo, worker_session.assignment, create_attrs)
    assert created.decision_prompt["tl_dr"] == "Choose replay behavior."
    assert get_in(created.decision_prompt, ["options", Access.at(0), "id"]) == "continue"

    assert {:ok, replayed} = GuidanceRequestService.create_for_worker(repo, worker_session.assignment, create_attrs)
    assert replayed.id == created.id
    assert repo.aggregate(GuidanceRequest, :count, :id) == 1
  end

  test "architect lists scoped guidance, reads it, and workers cannot answer", %{repo: repo} do
    {anchor, architect_session} = create_architect_session(repo, "SYMPP-GUIDANCE-ARCHITECT")
    {visible_package, worker_session} = create_worker_session(repo, "SYMPP-GUIDANCE-VISIBLE", phase_id: anchor.phase_id)
    {outside_package, outside_worker_session} = create_worker_session(repo, "SYMPP-GUIDANCE-OUTSIDE", phase_id: "phase-guidance-other")

    visible_request_id =
      create_guidance_request(repo, worker_session, %{
        "summary" => "Visible package question",
        "question" => "Should I stop for architect direction?",
        "context" => "The package has a boundary question.",
        "idempotency_key" => "visible-guidance"
      })

    outside_request_id =
      create_guidance_request(repo, outside_worker_session, %{
        "summary" => "Outside package question",
        "question" => "This should not leak.",
        "context" => "Different phase.",
        "idempotency_key" => "outside-guidance"
      })

    list_response = mcp_tool(repo, architect_session, "list_guidance_requests", %{})
    listed_ids = list_response |> get_in(["result", "structuredContent", "guidance_requests"]) |> Enum.map(& &1["id"])

    assert listed_ids == [visible_request_id]
    assert get_in(list_response, ["result", "structuredContent", "scope", "phase_id"]) == @phase_id

    outside_read_response = mcp_tool(repo, architect_session, "read_guidance_request", %{"guidance_request_id" => outside_request_id})
    assert get_in(outside_read_response, ["error", "data", "reason"]) == "not_found"

    scoped_read_response =
      mcp_tool(repo, architect_session, "read_guidance_request", %{"guidance_request_id" => visible_request_id, "work_package_id" => visible_package.id})

    assert get_in(scoped_read_response, ["result", "structuredContent", "guidance_request", "id"]) == visible_request_id

    mismatched_scope_read_response =
      mcp_tool(repo, architect_session, "read_guidance_request", %{"guidance_request_id" => visible_request_id, "work_package_id" => outside_package.id})

    assert get_in(mismatched_scope_read_response, ["error", "data", "reason"]) == "not_found"

    worker_outside_read_response =
      mcp_tool(repo, worker_session, "read_guidance_request", %{"guidance_request_id" => outside_request_id})

    assert get_in(worker_outside_read_response, ["error", "data", "reason"]) == "not_found"

    worker_answer_response =
      mcp_tool(repo, worker_session, "answer_guidance_request", %{
        "guidance_request_id" => visible_request_id,
        "answer" => "Workers cannot answer."
      })

    assert get_in(worker_answer_response, ["error", "data", "reason"]) == "architect_grant_required"

    answer_response =
      mcp_tool(repo, architect_session, "answer_guidance_request", %{
        "guidance_request_id" => visible_request_id,
        "answer" => "Ask the architect first and keep the implementation inside the assigned package."
      })

    assert get_in(answer_response, ["error", "data", "reason"]) == "outside_session_scope"

    worker_read_response = mcp_tool(repo, worker_session, "read_guidance_request", %{"guidance_request_id" => visible_request_id})
    assert get_in(worker_read_response, ["result", "structuredContent", "guidance_request", "answer"]) == nil
  end

  test "WorkRequest architect sees guidance for unphased dispatched slice packages", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-GUIDANCE-WR-DISPATCHED")
    work_package = create_work_package!(repo, work_request, id: "WRS-GUIDANCE-WR-DISPATCHED")
    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

    package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "WP-GUIDANCE-WR-DISPATCHED",
        phase_id: nil,
        status: "planning"
      )

    assert is_nil(package.phase_id)
    assert {:ok, _dispatched_slice} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", package.id)

    worker_session = create_worker_session_for_package(repo, package, "wr-worker")

    guidance_request_id =
      create_guidance_request(repo, worker_session, %{
        "summary" => "Need WorkRequest architect guidance",
        "question" => "Should this no-code dispatch be abandoned?",
        "context" => "The package is linked through a WorkRequest WorkPackage, not a phase child.",
        "idempotency_key" => "wr-linked-guidance"
      })

    {_anchor, architect_session} = create_work_request_architect_session(repo, work_request)
    list_response = mcp_tool(repo, architect_session, "list_guidance_requests", %{"status" => "open"})
    assert list_response["error"] == nil
    listed_ids = list_response |> get_in(["result", "structuredContent", "guidance_requests"]) |> Enum.map(& &1["id"])

    assert listed_ids == [guidance_request_id]

    answer_response =
      mcp_tool(repo, architect_session, "answer_guidance_request", %{
        "guidance_request_id" => guidance_request_id,
        "answer" => "Abandon the failed dispatch and continue with the recut slice."
      })

    assert get_in(answer_response, ["result", "structuredContent", "guidance_request", "status"]) == "answered"
    refute Map.has_key?(get_in(answer_response, ["result", "structuredContent", "guidance_request"]), "answer")

    worker_read_response = mcp_tool(repo, worker_session, "read_guidance_request", %{"guidance_request_id" => guidance_request_id})

    assert get_in(worker_read_response, ["result", "structuredContent", "guidance_request", "answer"]) ==
             "Abandon the failed dispatch and continue with the recut slice."
  end

  test "WorkRequest architect guidance accepts local checkout repo scope aliases", %{repo: repo} do
    checkout_path =
      TestSupport.git_repo_with_origin_fixture!("https://github.com/Pimpmuckl/nextide-saas-vod-intelligence.git",
        prefix: "sympp-guidance-repo-alias"
      )

    work_request =
      create_work_request!(repo,
        id: "WR-GUIDANCE-WR-REPO-ALIAS",
        repo: "Pimpmuckl/nextide-saas-vod-intelligence",
        base_branch: "main"
      )

    work_package = create_work_package!(repo, work_request, id: "WRS-GUIDANCE-WR-REPO-ALIAS")
    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

    package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "WP-GUIDANCE-WR-REPO-ALIAS",
        phase_id: nil,
        status: "planning"
      )

    assert {:ok, _dispatched_slice} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", package.id)

    worker_session = create_worker_session_for_package(repo, package, "repo-alias-worker")

    guidance_request_id =
      create_guidance_request(repo, worker_session, %{
        "summary" => "Need WorkRequest architect guidance through repo alias",
        "question" => "Can the architect answer this through a checkout-path grant?",
        "context" => "The WorkRequest is stored as owner/repo while the live grant carries a local checkout path.",
        "idempotency_key" => "wr-linked-guidance-repo-alias"
      })

    {_anchor, architect_session} = create_work_request_architect_session(repo, work_request)

    {1, _rows} =
      repo.update_all(
        from(grant in AccessGrant, where: grant.id == ^architect_session.assignment.grant_id),
        set: [scope_repo: checkout_path]
      )

    list_response = mcp_tool(repo, architect_session, "list_guidance_requests", %{"status" => "open"})
    assert list_response["error"] == nil
    listed_ids = list_response |> get_in(["result", "structuredContent", "guidance_requests"]) |> Enum.map(& &1["id"])

    assert listed_ids == [guidance_request_id]

    answer_response =
      mcp_tool(repo, architect_session, "answer_guidance_request", %{
        "guidance_request_id" => guidance_request_id,
        "answer" => "The checkout-path grant is scoped to the same repository."
      })

    assert get_in(answer_response, ["result", "structuredContent", "guidance_request", "status"]) == "answered"
  end

  test "WorkRequest linked guidance does not expose packages owned by another phase", %{repo: repo} do
    other_phase_id = "phase-guidance-wr-other"
    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: other_phase_id, title: "Other guidance phase"})

    work_request = create_work_request!(repo, id: "WR-GUIDANCE-WR-OTHER-PHASE")
    work_package = create_work_package!(repo, work_request, id: "WRS-GUIDANCE-WR-OTHER-PHASE")
    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

    package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "WP-GUIDANCE-WR-OTHER-PHASE",
        phase_id: other_phase_id,
        status: "planning"
      )

    assert {:ok, _dispatched_slice} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", package.id)

    worker_session = create_worker_session_for_package(repo, package, "other-phase-worker")

    _guidance_request_id =
      create_guidance_request(repo, worker_session, %{
        "summary" => "Other phase guidance",
        "question" => "This should stay inside the package phase.",
        "context" => "The package has its own phase owner.",
        "idempotency_key" => "wr-linked-other-phase-guidance"
      })

    {_anchor, architect_session} = create_work_request_architect_session(repo, work_request)
    list_response = mcp_tool(repo, architect_session, "list_guidance_requests", %{"status" => "open"})
    assert list_response["error"] == nil
    assert get_in(list_response, ["result", "structuredContent", "guidance_requests"]) == []
  end

  test "architect escalation records human_info_needed blocker that blocks readiness", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-GUIDANCE-BLOCKED")
    work_package = create_work_package!(repo, work_request, id: "WRS-GUIDANCE-BLOCKED")
    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

    package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "WP-GUIDANCE-BLOCKED",
        phase_id: nil,
        status: "ci_waiting"
      )

    assert {:ok, _dispatched_slice} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", package.id)

    worker_session = create_worker_session_for_package(repo, package, "blocked-worker")
    {_anchor, architect_session} = create_work_request_architect_session(repo, work_request)

    request_id =
      create_guidance_request(repo, worker_session, %{
        "summary" => "Need product call",
        "question" => "Which public behavior should this package implement?",
        "context" => "Two behaviors fit the current scope.",
        "idempotency_key" => "blocked-guidance"
      })

    escalation_response =
      mcp_tool(repo, architect_session, "escalate_guidance_request", %{
        "guidance_request_id" => request_id,
        "reason" => "The package cannot choose product behavior without human input.",
        "recommended_language" => "Human info needed: choose the package behavior before implementation continues.",
        "decision_prompt" => %{
          "tl_dr" => "Choose the package behavior.",
          "details" => "Two behaviors fit the package scope and the worker needs a product call.",
          "options" => [
            %{
              "id" => "explicit_behavior",
              "label" => "Explicit behavior",
              "description" => "Implement the public behavior named in the product brief.",
              "pros" => ["Matches the brief"],
              "cons" => ["Leaves alternate behavior for later"],
              "answer" => "Implement the explicit public behavior."
            }
          ],
          "custom_redirect_label" => "No, and tell the agent what to do differently"
        }
      })

    refute Map.has_key?(get_in(escalation_response, ["result", "structuredContent", "guidance_request"]), "decision_prompt")

    blocker = get_in(escalation_response, ["result", "structuredContent", "blocker"])
    assert blocker["active"] == true
    assert blocker["id"] == "guidance_request:#{request_id}"

    event = repo.get!(ProgressEvent, blocker["progress_event_id"])
    assert event.work_package_id == package.id
    assert event.body =~ "The package cannot choose product behavior without human input."
    assert event.body =~ "Human info needed: choose the package behavior before implementation continues."
    assert event.payload["type"] == "blocker"
    assert event.payload["source_tool"] == "report_blocker"
    assert event.payload["human_info_needed"] == true
    assert event.payload["recommended_language"] =~ "Human info needed"

    ready_response = mcp_tool(repo, worker_session, "mark_ready", %{})
    assert get_in(ready_response, ["error", "data", "reason_code"]) == "blocker_closeout_required"
    assert [%{"blocker_id" => blocker_id, "work_package_id" => package_id}] = get_in(ready_response, ["error", "data", "active_blockers"])
    assert blocker_id == "guidance_request:#{request_id}"
    assert package_id == package.id

    still_blocked_response =
      mcp_tool(repo, worker_session, "mark_ready", %{
        "blocker_closeout" => %{
          "decision" => "still_active",
          "blocker_ids" => [blocker_id]
        }
      })

    assert "no_active_blockers" in get_in(still_blocked_response, ["error", "data", "missing"])

    assert {:error, :unauthenticated} =
             GuidanceRequestService.answer_human_info_needed_for_local_operator(repo, nil, request_id, %{
               "work_package_id" => package.id,
               "answer" => "Do not accept unauthenticated service calls."
             })

    assert repo.get!(GuidanceRequest, request_id).status == "human_info_needed"

    assert {:error, :invalid_answer_choice} =
             GuidanceRequestService.answer_human_info_needed_for_local_operator(
               repo,
               :local_operator,
               request_id,
               %{
                 "work_package_id" => package.id,
                 "answer_choice" => "unknown_choice",
                 "answer_note" => "This should not be persisted."
               }
             )

    invalid_choice_request = repo.get!(GuidanceRequest, request_id)
    assert invalid_choice_request.status == "human_info_needed"
    refute invalid_choice_request.answer

    assert {:ok, %{guidance_request: answered, blocker_event: resolve_event}} =
             GuidanceRequestService.answer_human_info_needed_for_local_operator(
               repo,
               :local_operator,
               request_id,
               %{
                 "work_package_id" => package.id,
                 "answer_choice" => "explicit_behavior",
                 "answer_note" => "Keep the fallback out of this package."
               }
             )

    assert answered.status == "answered"
    assert answered.answered_by == "local-operator"
    assert answered.answer == "Implement the explicit public behavior. Keep the fallback out of this package."
    assert resolve_event.work_package_id == package.id
    assert resolve_event.status == "resolved"
    assert resolve_event.payload["source_tool"] == "resolve_blocker"
    assert resolve_event.payload["blocker_id"] == "guidance_request:#{request_id}"
    assert resolve_event.payload["active"] == false

    unblocked_ready_response = mcp_tool(repo, worker_session, "mark_ready", %{})
    unblocked_missing = get_in(unblocked_ready_response, ["error", "data", "missing"]) || []
    refute "no_active_blockers" in unblocked_missing
  end

  test "local operator answer path denies ordinary open guidance", %{repo: repo} do
    {package, worker_session} = create_worker_session(repo, "SYMPP-GUIDANCE-OPEN-DENIED", status: "ci_waiting")

    request_id =
      create_guidance_request(repo, worker_session, %{
        "summary" => "Open architect-owned guidance",
        "question" => "Can the local operator bypass architect guidance?",
        "context" => "Architects own ordinary open guidance answers.",
        "idempotency_key" => "open-guidance-denied"
      })

    assert {:error, :invalid_status} =
             GuidanceRequestService.answer_human_info_needed_for_local_operator(
               repo,
               :local_operator,
               request_id,
               %{
                 "work_package_id" => package.id,
                 "answer" => "Do not bypass the architect."
               }
             )

    assert repo.get!(GuidanceRequest, request_id).status == "open"
  end

  test "worker guidance creation is gated to worker-active lifecycle statuses", %{repo: repo} do
    for status <- @guidance_eligible_statuses do
      {_package, worker_session} = create_worker_session(repo, "SYMPP-GUIDANCE-ELIGIBLE-#{status}", status: status)

      response =
        mcp_tool(repo, worker_session, "create_guidance_request", %{
          "summary" => "Question from #{status}",
          "question" => "Can worker guidance be created from #{status}?",
          "context" => "Lifecycle gating should allow worker-active statuses.",
          "idempotency_key" => "guidance-eligible-#{status}"
        })

      assert get_in(response, ["result", "structuredContent", "guidance_request", "status"]) == "open"
    end

    for status <- @guidance_ineligible_statuses do
      {_package, worker_session} = create_worker_session(repo, "SYMPP-GUIDANCE-INELIGIBLE-#{status}", status: status)

      response =
        mcp_tool(repo, worker_session, "create_guidance_request", %{
          "summary" => "Question from #{status}",
          "question" => "Can worker guidance be created from #{status}?",
          "context" => "Lifecycle gating should deny pre-dispatch, ready, merge, and terminal states.",
          "idempotency_key" => "guidance-ineligible-#{status}"
        })

      assert get_in(response, ["error", "data", "reason"]) == expected_guidance_denial_reason(status)
    end
  end

  test "exact worker create replay bypasses lifecycle gate without new side effects", %{repo: repo} do
    {package, worker_session} = create_worker_session(repo, "SYMPP-GUIDANCE-REPLAY-AFTER-READY", status: "ci_waiting")

    create_args = %{
      "summary" => "Replay after lifecycle exit",
      "question" => "Can a lost create response be replayed after readiness?",
      "context" => "Idempotent replay should be read-only even when new creates are denied.",
      "idempotency_key" => "guidance-replay-after-ready"
    }

    create_response = mcp_tool(repo, worker_session, "create_guidance_request", create_args)
    request_id = get_in(create_response, ["result", "structuredContent", "guidance_request", "id"])
    assert get_in(create_response, ["result", "structuredContent", "guidance_request", "requested_by"]) == "worker-1"
    created = repo.get!(GuidanceRequest, request_id)

    assert {:ok, _package} = WorkPackageRepository.update(repo, package.id, %{"status" => "ready_for_merge"})

    replay_response = mcp_tool(repo, worker_session, "create_guidance_request", create_args)

    assert get_in(replay_response, ["result", "structuredContent", "guidance_request", "id"]) == request_id
    assert get_in(replay_response, ["result", "structuredContent", "guidance_request", "requested_by"]) == "worker-1"
    assert repo.get!(GuidanceRequest, request_id).updated_at == created.updated_at
    assert repo.aggregate(GuidanceRequest, :count, :id) == 1
    assert repo.aggregate(ProgressEvent, :count, :id) == 0

    grant = repo.get!(AccessGrant, worker_session.assignment.grant_id)
    assert {:ok, updated_grant} = grant |> Ecto.Changeset.change(claimed_by: "worker-renamed") |> repo.update()

    assert {:ok, renamed_worker_session} =
             Auth.session_from_grant(repo, updated_grant, proof_hash: worker_session.proof_hash)

    renamed_replay_response = mcp_tool(repo, renamed_worker_session, "create_guidance_request", create_args)

    assert get_in(renamed_replay_response, ["result", "structuredContent", "guidance_request", "id"]) == request_id
    assert get_in(renamed_replay_response, ["result", "structuredContent", "guidance_request", "requested_by"]) == "worker-1"

    renamed_read_response = mcp_tool(repo, renamed_worker_session, "read_guidance_request", %{"guidance_request_id" => request_id})

    assert get_in(renamed_read_response, ["result", "structuredContent", "guidance_request", "requested_by"]) == "worker-1"

    replayed = repo.get!(GuidanceRequest, request_id)
    assert replayed.requested_by == "worker-1"
    assert replayed.updated_at == created.updated_at
    assert repo.aggregate(GuidanceRequest, :count, :id) == 1
    assert repo.aggregate(ProgressEvent, :count, :id) == 0

    conflict_response =
      mcp_tool(repo, worker_session, "create_guidance_request", %{create_args | "question" => "Different question"})

    assert get_in(conflict_response, ["error", "data", "reason"]) == "idempotency_conflict"

    second_worker_session = create_worker_session_for_package(repo, package, "worker-2")
    second_worker_response = mcp_tool(repo, second_worker_session, "create_guidance_request", create_args)

    assert get_in(second_worker_response, ["error", "data", "reason"]) == "work_package_not_worker_active"
    assert repo.aggregate(GuidanceRequest, :count, :id) == 1
  end

  test "new worker guidance creation rechecks lifecycle inside the insert transaction", %{repo: repo} do
    {package, worker_session} = create_worker_session(repo, "SYMPP-GUIDANCE-CREATE-LIFECYCLE-RACE", status: "ci_waiting")

    GuidanceCreateLifecycleRaceRepo.arm(package.id, "ready_for_merge")

    response =
      try do
        mcp_tool(GuidanceCreateLifecycleRaceRepo, worker_session, "create_guidance_request", %{
          "summary" => "Race-sensitive guidance",
          "question" => "Can a stale active status create a guidance request?",
          "context" => "The package leaves the worker-active window before insert.",
          "idempotency_key" => "guidance-lifecycle-race"
        })
      after
        GuidanceCreateLifecycleRaceRepo.disarm()
      end

    assert get_in(response, ["error", "data", "reason"]) == "work_package_not_worker_active"
    assert repo.aggregate(GuidanceRequest, :count, :id) == 0
    assert {:ok, reloaded_package} = WorkPackageRepository.get(repo, package.id)
    assert reloaded_package.status == "ready_for_merge"
  end

  defp create_architect_session(repo, work_package_id) do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               work_package_attrs(
                 id: work_package_id,
                 phase_id: @phase_id,
                 status: "planning",
                 allowed_file_globs: ["elixir/lib/**"]
               )
             )

    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, @phase_id,
               work_package_id: anchor.id,
               capabilities: @architect_capabilities
             )

    assert {:ok, assignment} =
             AccessGrantRepository.claim(repo, minted.work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    {anchor, MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)}
  end

  defp create_work_request_architect_session(repo, %WorkRequest{} = work_request) do
    phase_id = ArchitectHandoff.phase_id_for_work_request(work_request)

    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Architect handoff for #{work_request.id}"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               work_package_attrs(
                 id: ArchitectHandoff.anchor_id_for_work_request(work_request),
                 kind: "delegation",
                 title: "Architect handoff: #{work_request.title}",
                 repo: work_request.repo,
                 base_branch: work_request.base_branch,
                 phase_id: phase_id,
                 status: "planning",
                 allowed_file_globs: ["elixir/lib", "elixir/lib/**"],
                 acceptance_criteria: ["Own the WorkRequest architecture."]
               )
             )

    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, phase_id,
               work_package_id: anchor.id,
               work_request_id: work_request.id,
               capabilities: @architect_capabilities
             )

    assert {:ok, assignment} =
             AccessGrantRepository.claim(repo, minted.work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    {anchor, MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)}
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_work_package!(repo, %WorkRequest{} = work_request, overrides) do
    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(work_request, overrides))

    work_package
  end

  defp create_matching_work_package!(repo, %WorkRequest{} = work_request, %WorkPackage{} = work_package, overrides) do
    attrs =
      [
        kind: work_package.kind,
        title: work_package.title,
        repo: work_request.repo,
        base_branch: work_package.base_branch,
        branch_pattern: work_package.branch_pattern,
        product_description: work_request.human_description,
        allowed_file_globs: work_package.allowed_file_globs,
        acceptance_criteria: work_package.acceptance_criteria
      ]
      |> Keyword.merge(overrides)
      |> work_package_attrs()

    assert {:ok, work_package} = WorkPackageRepository.create(repo, attrs)
    work_package
  end

  defp create_worker_session(repo, work_package_id, overrides \\ []) do
    phase_id = Keyword.get(overrides, :phase_id, @phase_id)
    target_status = Keyword.get(overrides, :status, "planning")

    if phase_id != @phase_id do
      assert {:ok, _phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Other guidance phase"})
    end

    package_attrs =
      overrides
      |> Keyword.put(:id, work_package_id)
      |> Keyword.put(:phase_id, phase_id)
      |> Keyword.put(:status, "planning")
      |> work_package_attrs()

    assert {:ok, package} = WorkPackageRepository.create(repo, package_attrs)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    assert {:ok, assignment} =
             AccessGrantRepository.claim(repo, minted.work_key.secret, %{claimed_by: "worker-1"}, DateTime.utc_now(:microsecond))

    package =
      if target_status == package.status do
        package
      else
        repo.update!(Ecto.Changeset.change(package, status: target_status))
      end

    {package, MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)}
  end

  defp expected_guidance_denial_reason(status) when status in ["merged_into_phase", "merged", "closed", "abandoned"],
    do: "work_package_terminal"

  defp expected_guidance_denial_reason(_status), do: "work_package_not_worker_active"

  defp create_worker_session_for_package(repo, %WorkPackage{} = package, claimed_by) do
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    assert {:ok, assignment} =
             AccessGrantRepository.claim(repo, minted.work_key.secret, %{claimed_by: claimed_by}, DateTime.utc_now(:microsecond))

    MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
  end

  defp create_guidance_request(repo, worker_session, attrs) do
    response = mcp_tool(repo, worker_session, "create_guidance_request", attrs)
    get_in(response, ["result", "structuredContent", "guidance_request", "id"])
  end

  defp work_package_attrs(overrides) do
    overrides
    |> Keyword.put_new(:kind, "mcp")
    |> Keyword.put_new(:repo, @repo_name)
    |> Keyword.put_new(:base_branch, @base_branch)
    |> Keyword.put_new(:allowed_file_globs, ["elixir/lib/**"])
    |> WorkPackageFactory.attrs()
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-GUIDANCE-#{System.unique_integer([:positive])}",
      title: "Guidance WorkRequest",
      repo: @repo_name,
      base_branch: @base_branch,
      work_type: "feature",
      human_description: "Route worker guidance through the owning WorkRequest architect.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "architect_led_feature_branch",
      status: "ready_for_slicing"
    }

    Enum.into(overrides, defaults)
  end

  defp work_package_attrs(%WorkRequest{} = work_request, overrides) do
    defaults = %{
      id: "WRS-GUIDANCE-#{System.unique_integer([:positive])}",
      title: "Guidance linked slice",
      goal: "Keep package guidance visible to the WorkRequest architect.",
      kind: "mcp",
      base_branch: work_request.base_branch,
      branch_pattern: "feat/guidance-linked-slice",
      allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/**"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Guidance remains answerable through the owning architect."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/mcp_guidance_requests_test.exs"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: ["Do not broaden guidance visibility across WorkRequests."]
    }

    Enum.into(overrides, defaults)
  end

  defp mcp_tool(repo, session, name, arguments) do
    MCPHarness.request(
      %{
        "jsonrpc" => "2.0",
        "id" => name,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      },
      config: Config.default(repo: repo),
      session: session
    )
  end
end
