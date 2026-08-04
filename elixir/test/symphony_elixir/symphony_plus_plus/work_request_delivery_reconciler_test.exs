Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestDeliveryReconcilerTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Config
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Revision
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryReconciler
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.TestSupport
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkRequestRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    for schema <- [
          ProgressEvent,
          WorkPackageDelivery,
          WorkPackage,
          DecisionLogEntry,
          AgentRun,
          ClaimLease,
          AccessGrant,
          WorkPackage,
          WorkRequest,
          Phase
        ] do
      repo.delete_all(schema)
    end

    :ok
  end

  test "dry-run proposes and apply records merged PR closeout through delivery service", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-PR-MERGED",
        work_package_id: "WP-RECONCILE-PR-MERGED",
        status: "ready_for_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 902, "head-902")

    assert {:ok, dry_run} = DeliveryReconciler.reconcile(repo, work_request.id, recorded_by: "reconciler-test")

    assert dry_run.mode == "dry_run"
    assert dry_run.proposed_count == 1
    assert dry_run.applied_count == 0

    assert [
             %{
               status: "proposed",
               reason: "github_pr_merged",
               work_package_id: work_package_id,
               action: action
             }
           ] = dry_run.results

    assert work_package_id == work_package.id
    assert work_package_id == linked_package.id
    assert action.work_request_id == work_request.id
    assert action.work_package_id == work_package.id
    assert action.outcome == "pr_merged"
    assert action.recorded_by == "reconciler-test"
    assert action.evidence.pr_merged.pr_number == 902
    assert action.evidence.pr_merged.merge_commit_sha == "merge-sha-902"
    refute Map.has_key?(action, :pr_url)
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_merge"

    assert {:ok, applied} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply, recorded_by: "reconciler-test")

    assert applied.applied_count == 1
    assert [%{status: "applied", reason: "github_pr_merged", delivery_id: delivery_id}] = applied.results
    assert is_binary(delivery_id)

    assert [delivery] = repo.all(WorkPackageDelivery)
    assert delivery.outcome == "pr_merged"
    assert delivery.work_package_id == work_package.id
    assert delivery.recorded_by == "reconciler-test"
    assert repo.get!(WorkPackage, linked_package.id).status == "merged"
  end

  test "apply records merged PR closeout when only stale agent runtime evidence remains", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-STALE-AGENT-RUN",
        work_package_id: "WP-RECONCILE-STALE-AGENT-RUN",
        status: "ready_for_merge"
      )

    assert {:ok, agent_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: linked_package.id,
               status: "running",
               last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -301, :second)
             })

    append_merged_pr_evidence!(repo, linked_package, 914, "head-914")

    assert {:ok, applied} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply, recorded_by: "reconciler-test")

    assert applied.applied_count == 1
    assert [%{status: "applied", work_package_id: work_package_id}] = applied.results
    assert work_package_id == work_package.id
    assert work_package_id == linked_package.id
    assert applied.delivery_board.counts["delivered"] == 1
    assert Map.get(applied.delivery_board.counts, "needs_closeout", 0) == 0

    assert [delivery] = repo.all(WorkPackageDelivery)
    assert delivery.outcome == "pr_merged"
    assert repo.get!(WorkPackage, linked_package.id).status == "merged"

    closeout_event = closeout_event!(repo)
    assert "agent_run_stale" in closeout_event.payload["runtime_reason_codes_before_closeout"]
    assert closeout_event.payload["ignored_stale_agent_run_ids"] == [agent_run.id]
  end

  test "apply records merged PR closeout for stale package and retires worker authority", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-STALE-PR-MERGED",
        work_package_id: "WP-RECONCILE-STALE-PR-MERGED",
        status: "ready_for_worker"
      )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "stale-worker")

    assert {:ok, claim_lease} =
             ClaimLeaseService.claim(
               repo,
               linked_package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:reconcile-claim", "actor_display_name" => "worker-claim"},
               stale_after_ms: 60_000
             )

    append_merged_pr_evidence!(repo, linked_package, 913, "head-913")

    assert {:ok, applied} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply, recorded_by: "reconciler-test")

    assert applied.applied_count == 1
    assert [%{status: "applied", work_package_id: work_package_id}] = applied.results
    assert work_package_id == work_package.id
    assert work_package_id == linked_package.id
    assert applied.delivery_board.counts["delivered"] == 1

    assert [delivery] = repo.all(WorkPackageDelivery)
    assert delivery.outcome == "pr_merged"
    assert repo.get!(WorkPackage, linked_package.id).status == "merged"
    assert %AccessGrant{revoked_at: %DateTime{}} = repo.get!(AccessGrant, minted.grant.id)
    assert %ClaimLease{status: "released", release_reason: "pr_merged_delivery_closeout"} = repo.get!(ClaimLease, claim_lease.id)
  end

  test "MCP reconcile_work_request dry-run reports proposed closeout without write capability", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-RECONCILE-MCP-DRY-RUN",
        work_package_id: "WP-RECONCILE-MCP-DRY-RUN",
        status: "ready_for_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 903, "head-903")
    session = create_work_request_architect_session(repo, work_request, ["read:work_request"])

    response = mcp_tool(repo, session, "reconcile_work_request", %{"work_request_id" => work_request.id})
    payload = get_in(response, ["result", "structuredContent", "reconciliation"])

    assert payload["mode"] == "dry_run"
    assert payload["proposed_count"] == 1
    assert [result] = payload["results"]
    assert result["status"] == "proposed"
    assert result["reason"] == "github_pr_merged"
    assert result["work_package_id"] == work_package.id
    assert get_in(result, ["action", "work_request_id"]) == work_request.id
    assert get_in(result, ["action", "work_package_id"]) == work_package.id
    assert get_in(result, ["action", "outcome"]) == "pr_merged"
    assert get_in(result, ["action", "evidence", "pr_merged", "pr_number"]) == 903
    assert get_in(result, ["action", "evidence", "pr_merged", "merge_commit_sha"]) == "merge-sha-903"
    refute Map.has_key?(result["action"], "pr_url")
    assert get_in(response, ["result", "structuredContent", "delivery_board", "counts", "needs_closeout"]) == 1
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_merge"
  end

  test "MCP reconcile_work_request dry-run action replays through record_work_package_delivery", %{repo: repo} do
    {work_request, _work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-RECONCILE-MCP-REPLAY",
        work_package_id: "WP-RECONCILE-MCP-REPLAY",
        status: "ready_for_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 915, "head-915")
    session = create_work_request_architect_session(repo, work_request, ["read:work_request", "write:work_request"])

    response =
      mcp_tool(repo, session, "reconcile_work_request", %{
        "work_request_id" => work_request.id,
        "recorded_by" => "manual-reconciler"
      })

    assert [result] = get_in(response, ["result", "structuredContent", "reconciliation", "results"])
    assert get_in(result, ["action", "recorded_by"]) == "manual-reconciler"

    record_response = mcp_tool(repo, session, "record_work_package_delivery", result["action"])
    assert get_in(record_response, ["result", "structuredContent", "work_package_delivery", "outcome"]) == "pr_merged"
    assert get_in(record_response, ["result", "structuredContent", "work_package_delivery", "recorded_by"]) == "manual-reconciler"
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1
  end

  test "MCP reconcile_work_request dry-run action preserves active blockers when replayed", %{repo: repo} do
    {work_request, _work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-RECONCILE-MCP-BLOCKER-REPLAY",
        work_package_id: "WP-RECONCILE-MCP-BLOCKER-REPLAY",
        status: "ready_for_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 916, "head-916")
    append_active_blocker!(repo, linked_package.id, "replay-blocker")
    session = create_work_request_architect_session(repo, work_request, ["read:work_request", "write:work_request"])

    response = mcp_tool(repo, session, "reconcile_work_request", %{"work_request_id" => work_request.id})
    assert [result] = get_in(response, ["result", "structuredContent", "reconciliation", "results"])
    assert get_in(result, ["action", "blocker_closeout", "decision"]) == "still_active"
    assert get_in(result, ["action", "blocker_closeout", "blocker_ids"]) == ["replay-blocker"]

    record_response = mcp_tool(repo, session, "record_work_package_delivery", result["action"])
    assert get_in(record_response, ["result", "structuredContent", "work_package_delivery", "outcome"]) == "pr_merged"
    assert get_in(record_response, ["result", "structuredContent", "blocker_closeout", "decision"]) == "still_active"
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1

    assert {:ok, replay} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)

    assert replay.applied_count == 0
    assert [%{status: "skipped", reason: "already_closeout", delivery_outcome: "pr_merged"}] = replay.results
    assert reconcile_blocker_closeout_events(repo, linked_package.id) == []
  end

  test "MCP reconcile_work_request apply preserves active blockers", %{repo: repo} do
    {work_request, _work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-RECONCILE-MCP-BLOCKER-APPLY",
        work_package_id: "WP-RECONCILE-MCP-BLOCKER-APPLY",
        status: "ready_for_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 917, "head-917")
    append_active_blocker!(repo, linked_package.id, "apply-blocker")
    session = create_work_request_architect_session(repo, work_request, ["read:work_request", "write:work_request"])

    response = mcp_tool(repo, session, "reconcile_work_request", %{"work_request_id" => work_request.id, "apply" => true})
    payload = get_in(response, ["result", "structuredContent", "reconciliation"])

    assert payload["applied_count"] == 1
    assert [result] = payload["results"]
    assert result["status"] == "applied"
    assert get_in(result, ["action", "blocker_closeout", "decision"]) == "still_active"
    assert get_in(result, ["action", "blocker_closeout", "blocker_ids"]) == ["apply-blocker"]
    assert [event_id] = result["blocker_closeout_event_ids"]
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1

    blocker_closeout_event = repo.get!(ProgressEvent, event_id)
    assert blocker_closeout_event.work_package_id == linked_package.id
    assert blocker_closeout_event.payload["type"] == "blocker_closeout_decision"
    assert blocker_closeout_event.payload["source_tool"] == "reconcile_work_request"
    assert blocker_closeout_event.payload["blocker_id"] == "apply-blocker"
    assert blocker_closeout_event.payload["decision"] == "still_active"
    assert blocker_closeout_event.actor_id == session.assignment.claimed_by
    assert blocker_closeout_event.access_grant_id == session.assignment.grant_id
    assert revision_count(repo, work_request.id) == 1

    replay_response = mcp_tool(repo, session, "reconcile_work_request", %{"work_request_id" => work_request.id, "apply" => true})

    assert get_in(replay_response, ["result", "structuredContent", "reconciliation", "applied_count"]) == 0
    assert revision_count(repo, work_request.id) == 1

    repo.delete_all(from(revision in Revision, where: revision.work_request_id == ^work_request.id))
    assert revision_count(repo, work_request.id) == 0

    backfill_response = mcp_tool(repo, session, "reconcile_work_request", %{"work_request_id" => work_request.id, "apply" => true})

    assert get_in(backfill_response, ["result", "structuredContent", "reconciliation", "applied_count"]) == 0
    assert revision_count(repo, work_request.id) == 1
  end

  test "apply does not append blocker preservation events when delivery recording fails", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-RECONCILE-BLOCKER-DELIVERY-FAILS",
        work_package_id: "WP-RECONCILE-BLOCKER-DELIVERY-FAILS",
        status: "ready_for_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 919, "head-919")
    append_active_blocker!(repo, linked_package.id, "delivery-failure-blocker")
    test_pid = self()

    record_delivery = fn callback_repo, callback_work_request_id, callback_work_package_id, attrs ->
      send(test_pid, {
        :record_delivery_called,
        callback_repo,
        callback_work_request_id,
        callback_work_package_id,
        attrs
      })

      {:error, :concurrent_closeout}
    end

    assert {:ok, result} =
             DeliveryReconciler.reconcile(repo, work_request.id,
               mode: :apply,
               record_work_package_delivery: record_delivery
             )

    assert_received {
      :record_delivery_called,
      ^repo,
      callback_work_request_id,
      callback_work_package_id,
      attrs
    }

    assert callback_work_request_id == work_request.id
    assert callback_work_package_id == work_package.id
    assert attrs.outcome == "pr_merged"
    assert attrs["allow_active_blocker_closeout"] == true

    assert result.applied_count == 0
    assert result.error_count == 1
    assert [%{status: "error", reason: "concurrent_closeout", action: action}] = result.results
    assert action.blocker_closeout.blocker_ids == ["delivery-failure-blocker"]
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0

    refute Enum.any?(repo.all(ProgressEvent), fn event ->
             event.work_package_id == linked_package.id and
               event.payload["type"] == "blocker_closeout_decision" and
               event.payload["source_tool"] == "reconcile_work_request"
           end)

    assert {:error, {:delivery_reconciliation_failed, "concurrent_closeout"}} =
             DeliveryReconciler.reconcile_work_package(repo, linked_package.id, record_work_package_delivery: record_delivery)
  end

  test "apply defers blocker preservation repair when append fails after delivery records", %{repo: repo} do
    {work_request, _work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-RECONCILE-BLOCKER-APPEND-FAILS",
        work_package_id: "WP-RECONCILE-BLOCKER-APPEND-FAILS",
        status: "ready_for_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 921, "head-921")
    append_active_blocker!(repo, linked_package.id, "append-failure-blocker")

    failing_appender = fn _repo, _work_package_id, _attrs -> {:error, :audit_revoked} end

    assert {:ok, result} =
             DeliveryReconciler.reconcile(repo, work_request.id,
               mode: :apply,
               append_blocker_closeout_event: failing_appender
             )

    assert result.applied_count == 1
    assert result.error_count == 0

    assert [
             %{
               status: "applied",
               reason: "github_pr_merged",
               blocker_closeout_repair: %{status: "deferred", reason: "audit_revoked"}
             }
           ] = result.results

    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1
    assert reconcile_blocker_closeout_events(repo, linked_package.id) == []

    assert {:ok, retry} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)

    assert retry.applied_count == 1

    assert [
             %{
               status: "applied",
               reason: "already_closeout_blocker_closeout_repaired",
               blocker_closeout_event_ids: [event_id]
             }
           ] = retry.results

    blocker_closeout_event = repo.get!(ProgressEvent, event_id)
    assert blocker_closeout_event.payload["blocker_id"] == "append-failure-blocker"
    assert blocker_closeout_event.payload["decision"] == "still_active"
  end

  test "apply repairs missing blocker preservation events for already closed deliveries", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-RECONCILE-BLOCKER-REPAIR",
        work_package_id: "WP-RECONCILE-BLOCKER-REPAIR",
        status: "ready_for_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 920, "head-920")
    append_active_blocker!(repo, linked_package.id, "repair-blocker")

    assert {:ok, _delivery} =
             WorkRequestService.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               merged_pr_delivery_attrs(920, %{"allow_active_blocker_closeout" => true})
             )

    assert reconcile_blocker_closeout_events(repo, linked_package.id) == []
    append_blocker_resolution!(repo, linked_package.id, "repair-blocker")

    assert {:ok, scoped_dry_run} =
             DeliveryReconciler.reconcile(repo, work_request.id, visible_work_package_ids: [])

    assert scoped_dry_run.proposed_count == 0
    assert [%{status: "skipped", reason: "already_closeout", delivery_outcome: "pr_merged"} = scoped_result] = scoped_dry_run.results
    assert scoped_result.work_package_status == "merged"

    assert {:ok, dry_run} = DeliveryReconciler.reconcile(repo, work_request.id)
    assert dry_run.proposed_count == 1

    assert [
             %{
               status: "proposed",
               reason: "already_closeout_blocker_closeout_repair",
               delivery_outcome: "pr_merged",
               action: dry_run_action
             }
           ] = dry_run.results

    assert dry_run_action.blocker_closeout.blocker_ids == ["repair-blocker"]
    assert dry_run_action.blocker_closeout.summary == "Preserve active blockers while repairing merged PR delivery closeout."
    assert reconcile_blocker_closeout_events(repo, linked_package.id) == []

    assert {:ok, result} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)

    assert result.applied_count == 1

    assert [
             %{
               status: "applied",
               reason: "already_closeout_blocker_closeout_repaired",
               delivery_outcome: "pr_merged",
               blocker_closeout_event_ids: [event_id]
             }
           ] = result.results

    blocker_closeout_event = repo.get!(ProgressEvent, event_id)
    assert blocker_closeout_event.payload["blocker_id"] == "repair-blocker"
    assert blocker_closeout_event.payload["decision"] == "still_active"

    assert {:ok, replay} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)
    assert replay.applied_count == 0
    assert [%{status: "skipped", reason: "already_closeout", delivery_outcome: "pr_merged"}] = replay.results
    assert length(reconcile_blocker_closeout_events(repo, linked_package.id)) == 1
  end

  test "already closed blocker repair summary names non-PR delivery outcomes", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-RECONCILE-NO-PR-BLOCKER-REPAIR",
        work_package_id: "WP-RECONCILE-NO-PR-BLOCKER-REPAIR",
        status: "reviewing"
      )

    append_active_blocker!(repo, linked_package.id, "no-pr-repair-blocker")

    assert {:ok, _delivery} =
             WorkRequestService.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               no_pr_delivery_attrs("no-pr-repair", %{"allow_active_blocker_closeout" => true})
             )

    append_blocker_resolution!(repo, linked_package.id, "no-pr-repair-blocker")

    assert {:ok, dry_run} = DeliveryReconciler.reconcile(repo, work_request.id)

    assert [
             %{
               status: "proposed",
               reason: "already_closeout_blocker_closeout_repair",
               delivery_outcome: "completed_no_pr",
               action: dry_run_action
             }
           ] = dry_run.results

    expected_summary = "Preserve active blockers while repairing completed no pr delivery closeout."
    assert dry_run_action.blocker_closeout.summary == expected_summary

    assert {:ok, result} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)
    assert [%{blocker_closeout_event_ids: [event_id]}] = result.results

    blocker_closeout_event = repo.get!(ProgressEvent, event_id)
    assert blocker_closeout_event.summary == expected_summary
  end

  test "already closed repair defers remaining blocker events after partial append", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-RECONCILE-BLOCKER-PARTIAL-REPAIR",
        work_package_id: "WP-RECONCILE-BLOCKER-PARTIAL-REPAIR",
        status: "ready_for_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 922, "head-922")
    append_active_blocker!(repo, linked_package.id, "partial-repair-a")
    append_active_blocker!(repo, linked_package.id, "partial-repair-b")

    assert {:ok, _delivery} =
             WorkRequestService.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               merged_pr_delivery_attrs(922, %{"allow_active_blocker_closeout" => true})
             )

    Process.put(:partial_repair_append_count, 0)

    failing_second_appender = fn callback_repo, _work_package_id, attrs ->
      count = Process.get(:partial_repair_append_count, 0) + 1
      Process.put(:partial_repair_append_count, count)

      case count do
        1 -> PlanningRepository.append_progress_event(callback_repo, attrs)
        _count -> {:error, :audit_revoked}
      end
    end

    assert {:ok, result} =
             DeliveryReconciler.reconcile(repo, work_request.id,
               mode: :apply,
               append_blocker_closeout_event: failing_second_appender
             )

    assert result.applied_count == 1
    assert result.error_count == 0

    assert [
             %{
               status: "applied",
               reason: "already_closeout_blocker_closeout_repaired",
               blocker_closeout_event_ids: [_event_id],
               blocker_closeout_repair: %{status: "deferred", reason: "audit_revoked"}
             }
           ] = result.results

    assert length(reconcile_blocker_closeout_events(repo, linked_package.id)) == 1
  end

  test "MCP reconcile_work_request apply keys blocker preservation by active blocker event", %{repo: repo} do
    {work_request, _work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-RECONCILE-MCP-RERAISED-BLOCKER",
        work_package_id: "WP-RECONCILE-MCP-RERAISED-BLOCKER",
        status: "ready_for_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 918, "head-918")
    append_active_blocker!(repo, linked_package.id, "reraised-blocker", idempotency_key: "reraised-blocker:first")

    assert {:ok, old_closeout_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Preserved prior active blocker",
               status: "blocked",
               idempotency_key:
                 [
                   "blocker_closeout",
                   "reconcile_work_request",
                   linked_package.id,
                   "reraised-blocker",
                   "still_active"
                 ]
                 |> Enum.join(":"),
               payload: %{
                 type: "blocker_closeout_decision",
                 source_tool: "reconcile_work_request",
                 blocker_id: "reraised-blocker",
                 decision: "still_active"
               }
             })

    append_blocker_resolution!(repo, linked_package.id, "reraised-blocker")

    reraised_blocker =
      append_active_blocker!(repo, linked_package.id, "reraised-blocker", idempotency_key: "reraised-blocker:second")

    session = create_work_request_architect_session(repo, work_request, ["read:work_request", "write:work_request"])

    response = mcp_tool(repo, session, "reconcile_work_request", %{"work_request_id" => work_request.id, "apply" => true})
    payload = get_in(response, ["result", "structuredContent", "reconciliation"])

    assert [result] = payload["results"]
    assert [event_id] = result["blocker_closeout_event_ids"]
    refute event_id == old_closeout_event.id

    blocker_closeout_event = repo.get!(ProgressEvent, event_id)

    assert blocker_closeout_event.idempotency_key ==
             [
               "blocker_closeout",
               "reconcile_work_request",
               linked_package.id,
               "reraised-blocker",
               reraised_blocker.id,
               "still_active"
             ]
             |> Enum.join(":")

    assert blocker_closeout_event.payload["blocker_id"] == "reraised-blocker"
    assert blocker_closeout_event.payload["decision"] == "still_active"
  end

  test "MCP reconcile_work_request apply returns fresh post-closeout delivery board", %{repo: repo} do
    {work_request, _work_package, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-RECONCILE-MCP-APPLY",
        work_package_id: "WP-RECONCILE-MCP-APPLY",
        status: "ready_for_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 904, "head-904")
    session = create_work_request_architect_session(repo, work_request, ["read:work_request", "write:work_request"])

    response = mcp_tool(repo, session, "reconcile_work_request", %{"work_request_id" => work_request.id, "apply" => true})
    payload = get_in(response, ["result", "structuredContent", "reconciliation"])

    assert payload["applied_count"] == 1
    counts = get_in(response, ["result", "structuredContent", "delivery_board", "counts"])
    assert Map.get(counts, "needs_closeout", 0) == 0
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1
    assert repo.get!(WorkPackage, linked_package.id).status == "merged"
  end

  test "repository base and head mismatches are skipped with reason codes", %{repo: repo} do
    cases = [
      {"repository_mismatch", [repository: "other/repo"]},
      {"base_branch_mismatch", [base_branch: "release"]},
      {"head_mismatch", [synced_head_sha: "other-head"]}
    ]

    for {reason, evidence_opts} <- cases do
      {work_request, _work_package, linked_package} =
        linked_slice!(repo,
          work_request_id: "WR-RECONCILE-#{String.upcase(reason)}",
          work_package_id: "WP-RECONCILE-#{String.upcase(reason)}",
          status: "ready_for_merge"
        )

      append_merged_pr_evidence!(repo, linked_package, System.unique_integer([:positive]), "expected-head", evidence_opts)

      assert {:ok, result} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)

      assert result.applied_count == 0
      assert [%{status: "skipped", reason: ^reason}] = result.results
      assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
      assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_merge"
    end
  end

  test "delivery matches merged PR evidence to a local checkout scope", %{repo: repo} do
    {work_request, _work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-LOCAL-REPO",
        work_package_id: "WP-RECONCILE-LOCAL-REPO",
        status: "ready_for_merge"
      )

    repo_path = TestSupport.git_repo_with_origin_fixture!("https://github.com/nextide/repo.git", prefix: "sympp-delivery-repo")
    repo.update_all(from(package in WorkPackage, where: package.id == ^linked_package.id), set: [repo: repo_path])
    append_merged_pr_evidence!(repo, linked_package, 906, "head-906")

    assert {:ok, result} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)
    assert result.applied_count == 1
    assert repo.get!(WorkPackage, linked_package.id).status == "merged"
  end

  test "blank work-package base branch is skipped with a clear reason", %{repo: repo} do
    {work_request, work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-BLANK-SLICE-BASE",
        work_package_id: "WP-RECONCILE-BLANK-SLICE-BASE",
        status: "ready_for_merge"
      )

    repo.update_all(from(slice in WorkPackage, where: slice.id == ^work_package.id), set: [base_branch: ""])
    append_merged_pr_evidence!(repo, linked_package, 905, "head-905", base_branch: "main")

    assert {:ok, result} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)

    assert result.applied_count == 0
    assert [%{status: "skipped", reason: "missing_base_branch", actual_base_branch: "main"}] = result.results
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_merge"
  end

  test "historical sync PR evidence can use merge reconciliation strong fields", %{repo: repo} do
    {work_request, _work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-HISTORICAL-MERGE",
        work_package_id: "WP-RECONCILE-HISTORICAL-MERGE",
        status: "ready_for_merge"
      )

    append_legacy_merged_pr_evidence!(repo, linked_package, 906, "head-906")

    assert {:ok, result} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)

    assert result.applied_count == 1
    assert [%{status: "applied", reason: "github_pr_merged", action: action}] = result.results
    assert action.evidence.pr_merged.merge_commit_sha == "merge-sha-906"

    assert [delivery] = repo.all(WorkPackageDelivery)
    assert DateTime.compare(delivery.pr_merged_at, ~U[2026-05-24 12:00:00Z]) == :eq
    assert delivery.merge_commit_sha == "merge-sha-906"
  end

  test "repaired sync PR evidence can drive merged delivery reconciliation", %{repo: repo} do
    {work_request, _work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-REPAIRED-SYNC-MERGE",
        work_package_id: "WP-RECONCILE-REPAIRED-SYNC-MERGE",
        status: "ready_for_merge"
      )

    append_repaired_merged_pr_evidence!(repo, linked_package, 907, "head-907")

    assert {:ok, result} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)

    assert result.applied_count == 1
    assert [%{status: "applied", reason: "github_pr_merged", action: action}] = result.results
    assert action.evidence.pr_merged.merge_commit_sha == "merge-sha-907"
  end

  test "later sync for a replaced PR does not become the active closeout PR", %{repo: repo} do
    {work_request, _work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-REPLACED-PR",
        work_package_id: "WP-RECONCILE-REPLACED-PR",
        status: "ready_for_merge"
      )

    append_replaced_pr_evidence!(repo, linked_package)

    assert {:ok, result} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)

    assert result.applied_count == 0
    assert [%{status: "skipped", reason: "no_structured_pr_merge_evidence"}] = result.results
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_merge"
  end

  test "decision-log prose and terminal package status do not infer no-PR completion", %{repo: repo} do
    {work_request, _work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-NO-PR-PROSE",
        work_package_id: "WP-RECONCILE-NO-PR-PROSE",
        status: "closed"
      )

    assert {:ok, _decision} =
             WorkRequestRepository.record_decision(repo, work_request.id, %{
               source_type: "architect",
               created_by: "architect-1",
               decision: "Slice completed without PR.",
               rationale: "Operator prose only.",
               scope_impact: "Advisory note."
             })

    assert {:ok, result} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)

    assert result.applied_count == 0
    assert [%{status: "skipped", reason: "no_structured_pr_merge_evidence"}] = result.results
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "closed"
  end

  test "already closed-out slices are skipped without duplicate deliveries", %{repo: repo} do
    {work_request, _work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-ALREADY-CLOSED",
        work_package_id: "WP-RECONCILE-ALREADY-CLOSED",
        status: "ready_for_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 911, "head-911")

    assert {:ok, first} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)
    assert [%{status: "applied"}] = first.results
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1

    assert {:ok, second} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)

    assert second.applied_count == 0
    assert [%{status: "skipped", reason: "already_closeout", delivery_outcome: "pr_merged"}] = second.results
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1
  end

  test "merged PR evidence without strong merge fields is skipped before apply", %{repo: repo} do
    {work_request, _work_package, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-WEAK-PR",
        work_package_id: "WP-RECONCILE-WEAK-PR",
        status: "ready_for_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 912, "head-912", merge_commit_sha: nil)

    assert {:ok, result} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)

    assert result.applied_count == 0
    assert [%{status: "skipped", reason: "missing_strong_pr_evidence", missing: "merge_commit_sha"}] = result.results
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_merge"
  end

  defp linked_slice!(repo, overrides) do
    request_id = Keyword.fetch!(overrides, :work_request_id)
    work_package_id = Keyword.fetch!(overrides, :work_package_id)
    status = Keyword.get(overrides, :status, "reviewing")
    work_request = create_work_request!(repo, id: request_id, status: "ready_for_slicing")
    work_package = create_work_package!(repo, work_request, id: "WRS-#{request_id}")

    assert {:ok, approved_slice} =
             CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

    work_package =
      create_matching_work_package!(
        repo,
        work_request,
        approved_slice,
        id: work_package_id,
        status: status
      )

    assert {:ok, dispatched_slice} =
             CanonicalWorkPackageFixtures.dispatch_work_package(
               repo,
               work_request.id,
               approved_slice.id,
               "approved",
               work_package.id
             )

    {work_request, dispatched_slice, work_package}
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_work_package!(repo, work_request, overrides) do
    assert {:ok, work_package} = CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(overrides))
    work_package
  end

  defp create_matching_work_package!(repo, work_request, work_package, overrides) do
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
      |> WorkPackageFactory.attrs()

    assert {:ok, work_package} = WorkPackageRepository.create(repo, attrs)
    work_package
  end

  defp create_work_request_architect_session(repo, %WorkRequest{} = work_request, capabilities) do
    phase_id = ArchitectHandoff.phase_id_for_work_request(work_request)

    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Architect handoff for #{work_request.id}"})

    anchor_attrs =
      [
        id: ArchitectHandoff.anchor_id_for_work_request(work_request),
        kind: "delegation",
        title: "Architect handoff: #{work_request.title}",
        repo: work_request.repo,
        base_branch: work_request.base_branch,
        phase_id: phase_id,
        status: "planning",
        allowed_file_globs: ["elixir/lib", "elixir/lib/**"],
        acceptance_criteria: ["Own the WorkRequest architecture."]
      ]
      |> WorkPackageFactory.attrs()

    assert {:ok, anchor} = WorkPackageRepository.create(repo, anchor_attrs)

    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, phase_id,
               work_package_id: anchor.id,
               capabilities: capabilities
             )

    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "architect-1")

    MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
  end

  defp append_merged_pr_evidence!(repo, work_package, number, attached_head_sha, opts \\ []) do
    synced_head_sha = Keyword.get(opts, :synced_head_sha, attached_head_sha)
    repository = Keyword.get(opts, :repository, "nextide/repo")
    url = Keyword.get(opts, :url, "https://github.com/#{repository}/pull/#{number}")
    base_branch = Keyword.get(opts, :base_branch, "main")
    merge_commit_sha = Keyword.get(opts, :merge_commit_sha, "merge-sha-#{number}")

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: attached_head_sha}
             })

    assert {:ok, _attached} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: url,
                 repository: repository,
                 number: number,
                 head_sha: attached_head_sha,
                 base_branch: base_branch
               }
             })

    assert {:ok, _synced} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: url,
                 repository: repository,
                 number: number,
                 head_sha: synced_head_sha,
                 base_branch: base_branch,
                 merged_at: "2026-05-24T12:00:00Z",
                 merge_commit_sha: merge_commit_sha,
                 merge_state: %{merged: true}
               }
             })
  end

  defp append_legacy_merged_pr_evidence!(repo, work_package, number, attached_head_sha) do
    url = "https://github.com/nextide/repo/pull/#{number}"

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: attached_head_sha}
             })

    assert {:ok, _attached} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: url,
                 repository: "nextide/repo",
                 number: number,
                 head_sha: attached_head_sha,
                 base_branch: "main"
               }
             })

    assert {:ok, _synced} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: url,
                 repository: "nextide/repo",
                 number: number,
                 head_sha: attached_head_sha,
                 base_branch: "main",
                 merge_state: %{merged: true}
               }
             })

    assert {:ok, _reconciled} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "GitHub PR merge reconciled",
               status: "github_pr_merged",
               payload: %{
                 type: "github_pr_merge_reconciliation",
                 source_tool: "operator_sync_prs",
                 url: url,
                 repository: "nextide/repo",
                 number: number,
                 head_sha: attached_head_sha,
                 merged: true,
                 merged_at: "2026-05-24T12:00:00Z",
                 merge_commit_sha: "merge-sha-#{number}"
               }
             })
  end

  defp append_repaired_merged_pr_evidence!(repo, work_package, number, head_sha) do
    url = "https://github.com/nextide/repo/pull/#{number}"

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: head_sha}
             })

    assert {:ok, _synced} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR repaired and merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 attachment_repair: true,
                 url: url,
                 repository: "nextide/repo",
                 number: number,
                 head_sha: head_sha,
                 base_branch: "main",
                 merged_at: "2026-05-24T12:00:00Z",
                 merge_commit_sha: "merge-sha-#{number}",
                 merge_state: %{merged: true}
               }
             })
  end

  defp append_replaced_pr_evidence!(repo, work_package) do
    old_url = "https://github.com/nextide/repo/pull/100"
    new_url = "https://github.com/nextide/repo/pull/101"

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "new-head"}
             })

    assert {:ok, _old_attached} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Old PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: old_url,
                 repository: "nextide/repo",
                 number: 100,
                 head_sha: "old-head",
                 base_branch: "main"
               }
             })

    assert {:ok, _new_attached} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Replacement PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: new_url,
                 repository: "nextide/repo",
                 number: 101,
                 head_sha: "new-head",
                 base_branch: "main"
               }
             })

    assert {:ok, _old_synced} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Old PR merged after replacement",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: old_url,
                 repository: "nextide/repo",
                 number: 100,
                 head_sha: "old-head",
                 base_branch: "main",
                 merged_at: "2026-05-24T12:00:00Z",
                 merge_commit_sha: "merge-sha-100",
                 merge_state: %{merged: true}
               }
             })
  end

  defp append_active_blocker!(repo, work_package_id, blocker_id, opts \\ []) do
    assert {:ok, event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package_id,
               summary: "Review scope blocker",
               status: "blocked",
               idempotency_key: Keyword.get(opts, :idempotency_key, blocker_id),
               payload: %{
                 type: "blocker",
                 source_tool: "report_blocker",
                 blocker_id: blocker_id,
                 active: true
               }
             })

    event
  end

  defp append_blocker_resolution!(repo, work_package_id, blocker_id) do
    assert {:ok, event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package_id,
               summary: "Review scope blocker resolved",
               status: "resolved",
               idempotency_key: "#{blocker_id}:resolved",
               payload: %{
                 type: "blocker",
                 source_tool: "resolve_blocker",
                 blocker_id: blocker_id,
                 active: false
               }
             })

    event
  end

  defp reconcile_blocker_closeout_events(repo, work_package_id) do
    repo.all(
      from(event in ProgressEvent,
        where: event.work_package_id == ^work_package_id,
        order_by: [asc: event.sequence]
      )
    )
    |> Enum.filter(fn event ->
      event.payload["type"] == "blocker_closeout_decision" and event.payload["source_tool"] == "reconcile_work_request"
    end)
  end

  defp closeout_event!(repo) do
    closeout_events =
      repo.all(ProgressEvent)
      |> Enum.filter(&(Map.get(&1.payload || %{}, "type") == "work_request_delivery_closeout"))

    assert [event] = closeout_events
    event
  end

  defp revision_count(repo, work_request_id) do
    Revision
    |> repo.all()
    |> Enum.count(&(&1.work_request_id == work_request_id))
  end

  defp merged_pr_delivery_attrs(number, overrides) do
    Map.merge(
      %{
        outcome: "pr_merged",
        idempotency_key: "delivery-reconciler-test:#{number}",
        recorded_by: "reconciler-test",
        pr_url: "https://github.com/nextide/repo/pull/#{number}",
        pr_number: number,
        pr_repository: "nextide/repo",
        pr_merged_at: ~U[2026-05-24 12:00:00Z],
        merge_commit_sha: "merge-sha-#{number}"
      },
      overrides
    )
  end

  defp no_pr_delivery_attrs(suffix, overrides) do
    Map.merge(
      %{
        outcome: "completed_no_pr",
        idempotency_key: "delivery-reconciler-test:no-pr:#{suffix}",
        recorded_by: "reconciler-test",
        no_pr_evidence: "Operator confirmed this slice completed without a PR."
      },
      overrides
    )
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-RECONCILE-#{System.unique_integer([:positive])}",
      title: "Reconcile delivered WorkRequest slices",
      repo: "nextide/repo",
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
      title: "Reconcile delivered slice",
      goal: "Record terminal delivery state.",
      kind: "mcp",
      base_branch: "main",
      branch_pattern: "feat/delivery-reconciler",
      allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Delivery reconciler is deterministic."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/work_request_delivery_reconciler_test.exs"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: ["Do not infer no-PR completion from prose."]
    }

    Enum.into(overrides, defaults)
  end

  defp mcp_tool(repo, %Session{} = session, name, arguments) do
    MCPHarness.request(
      %{
        "jsonrpc" => "2.0",
        "id" => name,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      },
      config: Config.default(repo: repo, repo_root: test_repo_root()),
      session: session
    )
  end

  defp test_repo_root do
    Path.expand("../../../..", __DIR__)
  end
end
