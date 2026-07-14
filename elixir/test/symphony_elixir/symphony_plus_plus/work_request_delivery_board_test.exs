defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestDeliveryBoardTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.DeliverySliceProjection
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(ProgressEvent)
    repo.delete_all(PlannedSliceDelivery)
    repo.delete_all(PlannedSlice)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "projects ordered slices with delivery outcome, linked WorkPackage summary, reason codes, and successor context", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-ORDERED")

    {superseded_slice, superseded_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-SUPERSEDED",
        work_package_id: "WP-BOARD-SUPERSEDED",
        status: "implementing"
      )

    {successor_slice, successor_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-SUCCESSOR",
        work_package_id: "WP-BOARD-SUCCESSOR",
        work_package_kind: "docs",
        status: "ready_for_worker"
      )

    assert {:ok, _delivery} =
             Repository.record_planned_slice_delivery(
               repo,
               work_request.id,
               superseded_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 idempotency_key: "delivery-board-superseded",
                 successor_planned_slice_id: successor_slice.id,
                 successor_work_package_id: successor_package.id,
                 superseded_reason: "Recut with narrower files."
               })
             )

    assert {:ok, board} = DeliveryBoard.project(repo, work_request.id)
    assert Enum.map(board.slices, & &1.id) == [superseded_slice.id, successor_slice.id]

    [superseded, successor] = board.slices
    assert superseded.raw_status == "dispatched"
    assert superseded.delivery_outcome == "superseded"
    assert superseded.work_package.id == superseded_package.id
    assert superseded.work_package.raw_status == "implementing"
    assert superseded.operational_state.key == "superseded"
    assert superseded.operational_state.raw_status == "dispatched"
    assert "linked_package_status_stale_after_delivery" in superseded.attention_reason_codes
    assert superseded.successor.planned_slice.id == successor_slice.id
    assert superseded.successor.work_package.id == successor_package.id
    assert successor.work_package.kind == "docs"
    assert successor.delivery_outcome == nil
  end

  test "terminal delivery outcome overrides stale blocked package truth while preserving raw detail", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-STALE")

    {planned_slice, linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-STALE",
        work_package_id: "WP-BOARD-STALE",
        status: "blocked"
      )

    assert {:ok, _blocker} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Still appears blocked",
               status: "blocked",
               idempotency_key: "delivery-board-stale-blocker",
               payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: "stale", active: true}
             })

    assert {:ok, _delivery} =
             Repository.record_planned_slice_delivery(
               repo,
               work_request.id,
               planned_slice.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: "delivery-board-pr-merged",
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/901",
                 pr_number: 901,
                 pr_repository: "nextide/symphony-plus-plus",
                 pr_merged_at: ~U[2026-05-24 12:00:00.000000Z],
                 merge_commit_sha: "abc901"
               })
             )

    assert {:ok, %{slices: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert slice.operational_state.key == "delivered"
    assert slice.operational_state.raw_status == "dispatched"
    assert slice.work_package.raw_status == "blocked"
    assert "linked_package_blocked_after_delivery" in slice.attention_reason_codes
    assert "linked_package_status_stale_after_delivery" in slice.attention_reason_codes
  end

  test "merged PR metadata without delivery outcome projects as needs closeout", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-NEEDS-CLOSEOUT")

    {_planned_slice, linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-NEEDS-CLOSEOUT",
        work_package_id: "WP-BOARD-NEEDS-CLOSEOUT",
        status: "ready_for_merge"
      )

    assert {:ok, _attached} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/symphony-plus-plus/pull/902", head_sha: "head-902"}
             })

    assert {:ok, _synced} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "PR merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/nextide/symphony-plus-plus/pull/902",
                 head_sha: "head-902",
                 merge_state: %{merged: true}
               }
             })

    assert {:ok, %{slices: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert slice.delivery_outcome == nil
    assert slice.operational_state.key == "needs_closeout"
    assert slice.operational_state.label == "Needs Closeout"
    assert slice.attention_reason_codes == ["pr_merged_without_delivery_outcome"]
  end

  test "stale merged PR metadata does not project needs closeout", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-STALE-PR")

    {_planned_slice, linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-STALE-PR",
        work_package_id: "WP-BOARD-STALE-PR",
        status: "ready_for_merge"
      )

    assert {:ok, _attached} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Stale PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/symphony-plus-plus/pull/903", head_sha: "old-head"}
             })

    assert {:ok, _stale_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Stale PR merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/nextide/symphony-plus-plus/pull/903",
                 head_sha: "old-head",
                 stale: true,
                 merge_state: %{merged: true}
               }
             })

    assert {:ok, %{slices: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert slice.delivery_outcome == nil
    assert slice.operational_state.key == "merge_ready"
    assert slice.attention_reason_codes == []
  end

  test "legacy stored merge-ready status projects with current visible label", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-LEGACY-READY")

    {_planned_slice, linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-LEGACY-READY",
        work_package_id: "WP-BOARD-LEGACY-READY",
        status: "ready_for_merge"
      )

    repo.query!("UPDATE sympp_work_packages SET status = ? WHERE id = ?", ["ready_for_human_merge", linked_package.id])

    assert {:ok, %{slices: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert slice.work_package.raw_status == "ready_for_human_merge"
    assert slice.operational_state.key == "merge_ready"
    assert slice.operational_state.label == "Ready"
  end

  test "newer PR attachments replace older merged sync metadata", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-REATTACHED-PR")

    {_planned_slice, linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-REATTACHED-PR",
        work_package_id: "WP-BOARD-REATTACHED-PR",
        status: "ready_for_merge"
      )

    assert {:ok, _old_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Old PR merged",
               status: "pr_synced",
               payload: %{type: "pr", source_tool: "sync_pr", url: "https://github.com/nextide/symphony-plus-plus/pull/904", merge_state: %{merged: true}}
             })

    assert {:ok, _new_attach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "New PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/symphony-plus-plus/pull/905", head_sha: "new-head"}
             })

    assert {:ok, %{slices: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert slice.work_package.pr.url == "https://github.com/nextide/symphony-plus-plus/pull/905"
    assert slice.operational_state.key == "merge_ready"
    assert slice.attention_reason_codes == []
  end

  test "review package payloads project as bounded summaries", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-REVIEW-PACKAGE")

    {_planned_slice, linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-REVIEW-PACKAGE",
        work_package_id: "WP-BOARD-REVIEW-PACKAGE",
        status: "reviewing"
      )

    assert {:ok, _review_package} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Review package submitted",
               status: "review_package_submitted",
               payload: %{
                 type: "review_package",
                 source_tool: "submit_review_package",
                 head_sha: "review-head",
                 artifacts: ["review.txt", "", "notes.md"],
                 acceptance_criteria_met: false,
                 tests_passed: false,
                 private_context: String.duplicate("secret-", 80),
                 reviews: [
                   %{lane: "normal", verdict: "green", private_notes: "do not expose"},
                   %{lane: "github", status: "passed", transcript: String.duplicate("log-", 80)}
                 ]
               }
             })

    assert {:ok, %{slices: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert package = slice.work_package.review.package
    assert package.artifacts == ["review.txt", "notes.md"]
    assert package.head_sha == "review-head"
    assert package.acceptance_criteria_met == false
    assert package.tests_passed == false
    refute Map.has_key?(package, :reviews)
    refute Map.has_key?(package, :private_context)
  end

  test "progress metadata projects as allowlisted summaries", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-PROGRESS-SUMMARIES")

    {_planned_slice, linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-PROGRESS-SUMMARIES",
        work_package_id: "WP-BOARD-PROGRESS-SUMMARIES",
        status: "reviewing",
        review_requirement: %{"type" => "human"}
      )

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{
                 type: "branch",
                 source_tool: "attach_branch",
                 branch: "feat/delivery-board",
                 head_sha: "branch-head",
                 raw_context: "do not expose"
               }
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/nextide/symphony-plus-plus/pull/906",
                 head_sha: "pr-head",
                 merge_state: %{merged: false, raw_payload: "do not expose"},
                 raw_context: "do not expose"
               }
             })

    assert {:ok, _review_package} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Validation package submitted",
               status: "review_package_submitted",
               payload: %{
                 type: "review_package",
                 source_tool: "submit_review_package",
                 head_sha: "branch-head",
                 artifacts: ["validation.txt"],
                 acceptance_criteria_met: true,
                 tests_passed: true,
                 transcript: "do not expose"
               }
             })

    assert {:ok, _review_completion} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Review finished",
               status: "review_completed",
               idempotency_key: "complete_review:#{linked_package.id}:branch-head:human",
               payload: %{
                 type: "review_completion",
                 source_tool: "complete_review",
                 work_package_id: linked_package.id,
                 head_sha: "branch-head",
                 review: %{"type" => "human"},
                 reference: "approval-906",
                 note: "Approved",
                 logs: "do not expose"
               }
             })

    assert {:ok, %{slices: [slice]}} = DeliveryBoard.project(repo, work_request.id)

    assert slice.work_package.branch == %{
             type: "branch",
             source_tool: "attach_branch",
             branch: "feat/delivery-board",
             head_sha: "branch-head"
           }

    assert slice.work_package.pr.url == "https://github.com/nextide/symphony-plus-plus/pull/906"
    assert slice.work_package.pr.merge_state == %{merged: false}
    assert slice.work_package.review.package.tests_passed == true
    assert slice.work_package.review.completion.review_type == "human"
    assert slice.work_package.review.completion.reference == "approval-906"

    refute Map.has_key?(slice.work_package.branch, :raw_context)
    refute Map.has_key?(slice.work_package.pr, :raw_context)
    refute Map.has_key?(slice.work_package.pr.merge_state, :raw_payload)
    refute Map.has_key?(slice.work_package.review.package, :transcript)
    refute Map.has_key?(slice.work_package.review.completion, :logs)

    changed_package =
      linked_package
      |> Ecto.Changeset.change(review_requirement: %{"type" => "automated"})
      |> repo.update!()

    assert {:ok, %{slices: [changed_slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert changed_slice.work_package.review.completion == nil

    changed_package
    |> Ecto.Changeset.change(review_requirement: %{"type" => "human"})
    |> repo.update!()

    assert {:ok, _new_head} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Branch advanced",
               status: "branch_attached",
               payload: %{
                 type: "branch",
                 source_tool: "attach_branch",
                 branch: "feat/delivery-board",
                 head_sha: "new-head"
               }
             })

    assert {:ok, %{slices: [advanced_slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert advanced_slice.work_package.review.completion == nil
  end

  test "preloaded dashboard metadata is used before progress fallback", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-PRELOADED-METADATA")

    {_planned_slice, linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-PRELOADED-METADATA",
        work_package_id: "WP-BOARD-PRELOADED-METADATA",
        status: "reviewing"
      )

    metadata = %{
      branch: %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "feat/from-dashboard", "raw_context" => "drop"},
      pr: %{
        "type" => "pr",
        "source_tool" => "sync_pr",
        "url" => "https://github.com/nextide/symphony-plus-plus/pull/907",
        "current_head_sha" => "dashboard-head",
        "check_summary" => %{"token" => "drop"}
      },
      review_completion: %{
        "type" => "review_completion",
        "source_tool" => "complete_review",
        "work_package_id" => linked_package.id,
        "head_sha" => "dashboard-head",
        "review" => %{"type" => "human"},
        "reference" => "approval-907",
        "transcript" => "drop"
      }
    }

    work_package_contexts = %{
      linked_package.id => %{
        work_package: linked_package,
        card: %{operational_state: %{attention_items: [], has_active_worker: false}, metadata: metadata}
      }
    }

    assert {:ok, %{slices: [slice]}} =
             DeliveryBoard.project(repo, work_request.id, work_package_contexts: work_package_contexts)

    assert slice.work_package.branch.branch == "feat/from-dashboard"
    assert slice.work_package.pr.url == "https://github.com/nextide/symphony-plus-plus/pull/907"
    assert slice.work_package.pr.current_head_sha == "dashboard-head"
    assert slice.work_package.review.completion.reference == "approval-907"
    refute Map.has_key?(slice.work_package.branch, :raw_context)
    refute Map.has_key?(slice.work_package.pr, :check_summary)
    refute Map.has_key?(slice.work_package.review.completion, :transcript)
  end

  test "empty preloaded metadata falls back to progress events", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-EMPTY-METADATA")

    {_planned_slice, linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-EMPTY-METADATA",
        work_package_id: "WP-BOARD-EMPTY-METADATA",
        status: "ready_for_merge"
      )

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "PR merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/nextide/symphony-plus-plus/pull/908",
                 merge_state: %{merged: true}
               }
             })

    work_package_contexts = %{
      linked_package.id => %{
        work_package: linked_package,
        card: %{operational_state: %{attention_items: [], has_active_worker: false}, metadata: %{}}
      }
    }

    assert {:ok, %{slices: [slice]}} =
             DeliveryBoard.project(repo, work_request.id, work_package_contexts: work_package_contexts)

    assert slice.work_package.pr.url == "https://github.com/nextide/symphony-plus-plus/pull/908"
    assert slice.operational_state.key == "needs_closeout"
  end

  test "scoped projection treats filtered linked packages as hidden instead of missing", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-HIDDEN-PACKAGE")

    {_planned_slice, _linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-HIDDEN-PACKAGE",
        work_package_id: "WP-BOARD-HIDDEN-PACKAGE",
        status: "ready_for_merge"
      )

    assert {:ok, %{slices: [slice]}} = DeliveryBoard.project(repo, work_request.id, visible_work_package_ids: [])
    assert slice.work_package == nil
    assert slice.work_package_hidden? == true
    assert slice.operational_state.key == "dispatched"
    assert slice.attention_reason_codes == []
  end

  test "projection marks duplicate planned-slice package links as repair-needed", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-AMBIGUOUS-PACKAGE")
    other_work_request = create_work_request!(repo, id: "WR-BOARD-AMBIGUOUS-PACKAGE-OTHER")
    first = create_planned_slice!(repo, work_request, id: "WRS-BOARD-AMBIGUOUS-A")
    second = create_planned_slice!(repo, other_work_request, id: "WRS-BOARD-AMBIGUOUS-B")

    work_package =
      create_matching_work_package!(repo, work_request, first,
        id: "WP-BOARD-AMBIGUOUS-PACKAGE",
        status: "ready_for_merge"
      )

    drop_planned_slice_work_package_unique_index!(repo)

    try do
      now = DateTime.utc_now(:microsecond)

      repo.update!(Ecto.Changeset.change(first, status: "dispatched", work_package_id: work_package.id, dispatched_at: now))
      repo.update!(Ecto.Changeset.change(second, status: "dispatched", work_package_id: work_package.id, dispatched_at: now))

      assert {:ok, board} = DeliveryBoard.project(repo, work_request.id)
      slices_by_id = Map.new(board.slices, &{&1.id, &1})

      projected = Map.fetch!(slices_by_id, first.id)
      assert projected.work_package == nil
      assert projected.work_package_ambiguous? == true
      assert projected.operational_state.key == "needs_repair"
      assert projected.attention_reason_codes == ["ambiguous_linked_work_package"]

      assert {:ok, scoped_board} = DeliveryBoard.project(repo, work_request.id, visible_work_package_ids: [])
      scoped_projected = scoped_board.slices |> Map.new(&{&1.id, &1}) |> Map.fetch!(first.id)

      assert scoped_projected.work_package == nil
      assert scoped_projected.work_package_hidden? == true
      assert scoped_projected.work_package_ambiguous? == false
      assert scoped_projected.operational_state.key == "dispatched"
      refute "ambiguous_linked_work_package" in scoped_projected.attention_reason_codes

      assert DeliverySliceProjection.primary_operational_state(projected, []) == %{
               attention_items: [
                 %{
                   key: "ambiguous_linked_work_package",
                   label: "Ambiguous Package",
                   reason: "Multiple planned slices point at the same WorkPackage.",
                   tone: "warning"
                 }
               ],
               attention_reason_codes: ["ambiguous_linked_work_package"],
               delivery_outcome: nil,
               key: "needs_repair",
               label: "Needs Repair",
               raw_status: "dispatched",
               reason: "Multiple planned slices point at the same WorkPackage.",
               tone: "warning",
               work_package_status: nil
             }

      assert {:ok, _delivery} =
               Repository.record_planned_slice_delivery(
                 repo,
                 work_request.id,
                 first.id,
                 delivery_attrs(%{
                   outcome: "pr_merged",
                   idempotency_key: "delivery-board-ambiguous-pr-merged",
                   pr_url: "https://github.com/nextide/symphony-plus-plus/pull/902",
                   pr_number: 902,
                   pr_repository: "nextide/symphony-plus-plus",
                   pr_merged_at: ~U[2026-05-24 12:00:00.000000Z],
                   merge_commit_sha: "abc902"
                 })
               )

      assert {:ok, delivered_board} = DeliveryBoard.project(repo, work_request.id)
      delivered = delivered_board.slices |> Map.new(&{&1.id, &1}) |> Map.fetch!(first.id)

      assert delivered.work_package == nil
      assert delivered.work_package_ambiguous? == true
      assert delivered.operational_state.key == "delivered"
      assert "ambiguous_linked_work_package" in delivered.attention_reason_codes
    after
      SQL.query!(
        repo,
        "UPDATE sympp_work_request_planned_slices SET work_package_id = NULL, dispatched_at = NULL WHERE id IN (?, ?)",
        [first.id, second.id]
      )

      create_planned_slice_work_package_unique_index!(repo)
    end
  end

  test "keeps skipped planned slices visible on the delivery board", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-SKIPPED-SCRATCH")
    visible_slice = create_planned_slice!(repo, work_request, id: "WRS-BOARD-VISIBLE-PLANNED")

    scratch_slice =
      repo
      |> create_planned_slice!(work_request, id: "WRS-BOARD-SKIPPED-SCRATCH")
      |> then(fn planned_slice ->
        assert {:ok, skipped} = Repository.skip_planned_slice(repo, work_request.id, planned_slice.id, "planned")
        skipped
      end)

    delivered_slice =
      repo
      |> create_planned_slice!(work_request, id: "WRS-BOARD-SKIPPED-DELIVERY")
      |> then(fn planned_slice ->
        assert {:ok, skipped} = Repository.skip_planned_slice(repo, work_request.id, planned_slice.id, "planned")
        skipped
      end)

    assert {:ok, _delivery} =
             Repository.record_planned_slice_delivery(
               repo,
               work_request.id,
               delivered_slice.id,
               delivery_attrs(%{
                 outcome: "abandoned",
                 idempotency_key: "delivery-board-skipped-delivery",
                 abandoned_rationale: "Operator recorded a terminal delivery outcome."
               })
             )

    linked_skipped_slice =
      repo
      |> create_planned_slice!(work_request, id: "WRS-BOARD-SKIPPED-LINKED")
      |> then(fn planned_slice ->
        assert {:ok, skipped} = Repository.skip_planned_slice(repo, work_request.id, planned_slice.id, "planned")
        skipped
      end)

    linked_package =
      create_matching_work_package!(repo, work_request, linked_skipped_slice,
        id: "WP-BOARD-SKIPPED-LINKED",
        status: "closed"
      )

    dispatched_at = DateTime.utc_now(:microsecond)

    linked_skipped_slice =
      repo.update!(
        Ecto.Changeset.change(linked_skipped_slice,
          work_package_id: linked_package.id,
          dispatched_at: dispatched_at
        )
      )

    assert {:ok, board} = DeliveryBoard.project(repo, work_request.id)
    assert Enum.map(board.slices, & &1.id) == [visible_slice.id, scratch_slice.id, delivered_slice.id, linked_skipped_slice.id]

    by_id = Map.new(board.slices, &{&1.id, &1})
    assert by_id[scratch_slice.id].raw_status == "skipped"
    assert by_id[delivered_slice.id].raw_status == "skipped"
    assert by_id[linked_skipped_slice.id].raw_status == "skipped"
  end

  test "preloaded blocked raw state does not imply active blocker evidence", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-RESOLVED-BLOCKER")

    {_planned_slice, linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-RESOLVED-BLOCKER",
        work_package_id: "WP-BOARD-RESOLVED-BLOCKER",
        status: "blocked"
      )

    work_package_contexts = %{
      linked_package.id => %{
        work_package: linked_package,
        card: %{operational_state: %{key: "blocked", attention_items: []}}
      }
    }

    assert {:ok, %{slices: [slice]}} =
             DeliveryBoard.project(repo, work_request.id, work_package_contexts: work_package_contexts)

    assert slice.operational_state.key == "blocked"
    assert slice.attention_reason_codes == []
  end

  test "completed without PR and superseded outcomes project distinctly", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-DISTINCT")

    {no_pr_slice, _no_pr_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-NO-PR",
        work_package_id: "WP-BOARD-NO-PR",
        status: "closed"
      )

    {superseded_slice, _superseded_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-DISTINCT-SUPERSEDED",
        work_package_id: "WP-BOARD-DISTINCT-SUPERSEDED",
        status: "closed"
      )

    successor_slice = create_planned_slice!(repo, work_request, id: "WRS-BOARD-DISTINCT-SUCCESSOR")

    assert {:ok, _no_pr_delivery} =
             Repository.record_planned_slice_delivery(
               repo,
               work_request.id,
               no_pr_slice.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 idempotency_key: "delivery-board-no-pr",
                 no_pr_evidence: "Operator confirmed direct completion."
               })
             )

    assert {:ok, _superseded_delivery} =
             Repository.record_planned_slice_delivery(
               repo,
               work_request.id,
               superseded_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 idempotency_key: "delivery-board-distinct-superseded",
                 successor_planned_slice_id: successor_slice.id,
                 superseded_reason: "Replaced by a smaller follow-up."
               })
             )

    assert {:ok, board} = DeliveryBoard.project(repo, work_request.id)
    slices_by_id = Map.new(board.slices, &{&1.id, &1})

    assert get_in(slices_by_id, [no_pr_slice.id, :operational_state, :key]) == "completed_no_pr"
    assert get_in(slices_by_id, [superseded_slice.id, :operational_state, :key]) == "superseded"
    assert get_in(slices_by_id, [superseded_slice.id, :successor, :planned_slice_id]) == successor_slice.id
  end

  test "delivery summary bounds freeform evidence", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-BOUNDED-DELIVERY")

    {planned_slice, _linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-BOUNDED-DELIVERY",
        work_package_id: "WP-BOARD-BOUNDED-DELIVERY",
        status: "closed"
      )

    assert {:ok, _delivery} =
             Repository.record_planned_slice_delivery(
               repo,
               work_request.id,
               planned_slice.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 idempotency_key: "delivery-board-bounded-evidence",
                 no_pr_evidence: String.duplicate("evidence-", 80)
               })
             )

    assert {:ok, %{slices: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert String.length(slice.delivery.no_pr_evidence) == 240
  end

  defp linked_slice!(repo, work_request, overrides) do
    work_package_id = Keyword.fetch!(overrides, :work_package_id)
    status = Keyword.get(overrides, :status, "ready_for_worker")

    planned_slice = create_planned_slice!(repo, work_request, Keyword.drop(overrides, [:work_package_id, :status]))
    assert {:ok, approved_slice} = Repository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    work_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: work_package_id,
        status: status
      )

    assert {:ok, dispatched_slice} = Repository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", work_package.id)

    {dispatched_slice, work_package}
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = Repository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_planned_slice!(repo, work_request, overrides) do
    assert {:ok, planned_slice} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(overrides))
    planned_slice
  end

  defp create_matching_work_package!(repo, work_request, planned_slice, overrides) do
    attrs =
      [
        kind: planned_slice.work_package_kind,
        title: planned_slice.title,
        repo: work_request.repo,
        base_branch: planned_slice.target_base_branch,
        branch_pattern: planned_slice.branch_pattern,
        product_description: work_request.human_description,
        allowed_file_globs: planned_slice.owned_file_globs,
        acceptance_criteria: planned_slice.acceptance_criteria,
        review_requirement: planned_slice.review_requirement
      ]
      |> Keyword.merge(overrides)
      |> WorkPackageFactory.attrs()

    assert {:ok, work_package} = WorkPackageRepository.create(repo, attrs)
    work_package
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-BOARD-#{System.unique_integer([:positive])}",
      title: "Project WorkRequest delivery board",
      repo: "nextide/example",
      base_branch: "main",
      work_type: "feature",
      human_description: "Expose delivery-board truth.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "architect_led_feature_branch",
      status: "ready_for_slicing"
    }

    Enum.into(overrides, defaults)
  end

  defp planned_slice_attrs(overrides) do
    defaults = %{
      id: "WRS-BOARD-#{System.unique_integer([:positive])}",
      title: "Add delivery-board projection",
      goal: "Project slice delivery state.",
      work_package_kind: "mcp",
      target_base_branch: "main",
      branch_pattern: "feat/delivery-board",
      owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Projection is shared."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/work_request_delivery_board_test.exs"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: ["Do not parse decision text."]
    }

    Enum.into(overrides, defaults)
  end

  defp delivery_attrs(overrides) do
    defaults = %{
      idempotency_key: "delivery-board-#{System.unique_integer([:positive])}",
      recorded_by: "delivery-board-test"
    }

    Enum.into(overrides, defaults)
  end

  defp drop_planned_slice_work_package_unique_index!(repo) do
    SQL.query!(repo, "DROP INDEX IF EXISTS sympp_work_request_planned_slices_work_package_id_unique_index")
  end

  defp create_planned_slice_work_package_unique_index!(repo) do
    SQL.query!(repo, """
    CREATE UNIQUE INDEX IF NOT EXISTS sympp_work_request_planned_slices_work_package_id_unique_index
    ON sympp_work_request_planned_slices (work_package_id)
    WHERE work_package_id IS NOT NULL
    """)
  end

  defp database_path do
    Path.join(System.tmp_dir!(), "sympp-work-request-delivery-board-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")
  end
end
