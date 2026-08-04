defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestDeliveryBoardTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.DependencyEdge
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Node
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Repository, as: ProductTreeRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard.Signals
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  defmodule MissingProductTreeRepo do
    def all(_query), do: raise(%Exqlite.Error{message: "no such table: sympp_product_tree_nodes"})
  end

  setup_all do
    database_path = database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(AgentRun)
    repo.delete_all(ProgressEvent)
    repo.delete_all(WorkPackageDelivery)
    repo.delete_all(DependencyEdge)
    repo.delete_all(Node)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "keeps delivery signals available before product-tree migrations" do
    work_request = %WorkRequest{id: "WR-BOARD-LEGACY"}

    assert {:ok, %{}} =
             Signals.execution_graphs(
               MissingProductTreeRepo,
               [work_request],
               %{work_request.id => []},
               %{},
               []
             )
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
        kind: "docs",
        status: "ready_for_worker"
      )

    assert {:ok, _delivery} =
             Repository.record_work_package_delivery(
               repo,
               work_request.id,
               superseded_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 idempotency_key: "delivery-board-superseded",
                 successor_work_package_id: successor_package.id,
                 superseded_reason: "Recut with narrower files."
               })
             )

    assert {:ok, board} = DeliveryBoard.project(repo, work_request.id)
    assert Enum.map(board.work_packages, & &1.id) == [superseded_slice.id, successor_slice.id]

    [superseded, successor] = board.work_packages
    assert superseded.raw_status == "implementing"
    assert superseded.delivery_outcome == "superseded"
    assert superseded.work_package.id == superseded_package.id
    assert superseded.work_package.raw_status == "implementing"
    assert superseded.operational_state.key == "superseded"
    assert superseded.operational_state.raw_status == "implementing"
    assert superseded.attention_reason_codes == []
    assert superseded.successor.work_package.id == successor_slice.id
    assert superseded.successor.work_package.id == successor_package.id
    assert successor.work_package.kind == "docs"
    assert successor.delivery_outcome == nil
  end

  test "terminal delivery outcome suppresses stale blocked attention while preserving raw detail", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-STALE")

    {work_package, linked_package} =
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

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/nextide/symphony-plus-plus/pull/901",
                 number: 901,
                 repository: "nextide/symphony-plus-plus",
                 head_sha: "head-901",
                 check_summary: %{status: "completed", conclusion: "success", completed: 3, total: 3},
                 provider: "github"
               }
             })

    assert {:ok, _delivery} =
             Repository.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
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

    assert {:ok, %{work_packages: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert slice.operational_state.key == "delivered"
    assert slice.operational_state.raw_status == "blocked"
    assert slice.work_package.raw_status == "blocked"

    assert %{
             status: "merged",
             url: "https://github.com/nextide/symphony-plus-plus/pull/901",
             number: 901,
             repository: "nextide/symphony-plus-plus",
             head_sha: "head-901",
             checks: %{status: "passing", current: 3, total: 3}
           } = slice.work_package.pr_signal

    assert slice.attention_reason_codes == []
    assert slice.operational_state.attention_items == []
    refute WorkPackageActivity.context(repo, linked_package.id).blocker_state.active?
  end

  test "terminal delivery retains live runtime attention", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-LIVE-RUNTIME")

    {work_package, linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-LIVE-RUNTIME",
        work_package_id: "WP-BOARD-LIVE-RUNTIME",
        status: "ready_for_merge"
      )

    assert {:ok, _delivery} =
             Repository.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 idempotency_key: "delivery-board-live-runtime",
                 no_pr_evidence: "The package was completed without a pull request."
               })
             )

    assert {:ok, _run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: linked_package.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "post-delivery-runtime",
               started_at: DateTime.utc_now(:microsecond),
               last_seen_at: DateTime.utc_now(:microsecond)
             })

    assert {:ok, %{work_packages: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert slice.operational_state.key == "completed_no_pr"
    assert slice.attention_reason_codes == ["work_package_active_after_delivery"]
  end

  test "merged PR metadata without delivery outcome projects as needs closeout", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-NEEDS-CLOSEOUT")

    {_work_package, linked_package} =
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

    assert {:ok, %{work_packages: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert slice.delivery_outcome == nil
    assert slice.operational_state.key == "needs_closeout"
    assert slice.operational_state.label == "Needs Closeout"
    assert slice.attention_reason_codes == ["pr_merged_without_delivery_outcome"]
  end

  test "stale merged PR metadata does not project needs closeout", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-STALE-PR")

    {_work_package, linked_package} =
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

    assert {:ok, %{work_packages: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert slice.delivery_outcome == nil
    assert slice.operational_state.key == "merge_ready"
    assert slice.attention_reason_codes == []
  end

  test "legacy stored merge-ready status projects with current visible label", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-LEGACY-READY")

    {_work_package, linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-LEGACY-READY",
        work_package_id: "WP-BOARD-LEGACY-READY",
        status: "ready_for_merge"
      )

    repo.query!("UPDATE sympp_work_packages SET status = ? WHERE id = ?", ["ready_for_human_merge", linked_package.id])

    assert {:ok, %{work_packages: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert slice.work_package.raw_status == "ready_for_human_merge"
    assert slice.operational_state.key == "merge_ready"
    assert slice.operational_state.label == "Ready"
  end

  test "newer PR attachments replace older merged sync metadata", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-REATTACHED-PR")

    {_work_package, linked_package} =
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

    assert {:ok, %{work_packages: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert slice.work_package.pr.url == "https://github.com/nextide/symphony-plus-plus/pull/905"
    assert slice.operational_state.key == "merge_ready"
    assert slice.attention_reason_codes == []
  end

  test "review package payloads project as bounded summaries", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-REVIEW-PACKAGE")

    {_work_package, linked_package} =
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

    assert {:ok, %{work_packages: [slice]}} = DeliveryBoard.project(repo, work_request.id)
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

    {_work_package, linked_package} =
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

    assert {:ok, %{work_packages: [slice]}} = DeliveryBoard.project(repo, work_request.id)

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

    assert {:ok, %{work_packages: [changed_slice]}} = DeliveryBoard.project(repo, work_request.id)
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

    assert {:ok, %{work_packages: [advanced_slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert advanced_slice.work_package.review.completion == nil
  end

  test "preloaded dashboard metadata is used before progress fallback", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-PRELOADED-METADATA")

    {_work_package, linked_package} =
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

    assert {:ok, %{work_packages: [slice]}} =
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

    {_work_package, linked_package} =
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

    assert {:ok, %{work_packages: [slice]}} =
             DeliveryBoard.project(repo, work_request.id, work_package_contexts: work_package_contexts)

    assert slice.work_package.pr.url == "https://github.com/nextide/symphony-plus-plus/pull/908"
    assert slice.operational_state.key == "needs_closeout"
  end

  test "scoped projection treats filtered linked packages as hidden instead of missing", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-HIDDEN-PACKAGE")

    {_work_package, _linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-HIDDEN-PACKAGE",
        work_package_id: "WP-BOARD-HIDDEN-PACKAGE",
        status: "ready_for_merge"
      )

    assert {:ok, %{work_packages: [slice]}} = DeliveryBoard.project(repo, work_request.id, visible_work_package_ids: [])
    assert slice.work_package == nil
    assert slice.work_package_hidden? == true
    assert slice.operational_state.key == "dispatched"
    assert slice.attention_reason_codes == []
  end

  test "keeps skipped WorkPackages visible on the delivery board", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-SKIPPED-SCRATCH")
    visible_slice = create_work_package!(repo, work_request, id: "WRS-BOARD-VISIBLE-PLANNED")

    scratch_slice =
      repo
      |> create_work_package!(work_request, id: "WRS-BOARD-SKIPPED-SCRATCH")
      |> then(fn work_package ->
        assert {:ok, skipped} = Repository.skip_work_package(repo, work_request.id, work_package.id, "planned")
        skipped
      end)

    delivered_slice =
      repo
      |> create_work_package!(work_request, id: "WRS-BOARD-SKIPPED-DELIVERY")
      |> then(fn work_package ->
        assert {:ok, skipped} = Repository.skip_work_package(repo, work_request.id, work_package.id, "planned")
        skipped
      end)

    assert {:ok, _delivery} =
             Repository.record_work_package_delivery(
               repo,
               work_request.id,
               delivered_slice.id,
               delivery_attrs(%{
                 outcome: "abandoned",
                 idempotency_key: "delivery-board-skipped-delivery",
                 abandoned_rationale: "Operator recorded a terminal delivery outcome."
               })
             )

    assert {:ok, board} = DeliveryBoard.project(repo, work_request.id)
    assert Enum.map(board.work_packages, & &1.id) == [visible_slice.id, scratch_slice.id, delivered_slice.id]

    by_id = Map.new(board.work_packages, &{&1.id, &1})
    assert by_id[scratch_slice.id].raw_status == "skipped"
    assert by_id[delivered_slice.id].raw_status == "skipped"
  end

  test "preloaded blocked raw state does not imply active blocker evidence", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-RESOLVED-BLOCKER")

    {_work_package, linked_package} =
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

    assert {:ok, %{work_packages: [slice]}} =
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

    successor_slice = create_work_package!(repo, work_request, id: "WRS-BOARD-DISTINCT-SUCCESSOR")

    assert {:ok, _no_pr_delivery} =
             Repository.record_work_package_delivery(
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
             Repository.record_work_package_delivery(
               repo,
               work_request.id,
               superseded_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 idempotency_key: "delivery-board-distinct-superseded",
                 successor_work_package_id: successor_slice.id,
                 superseded_reason: "Replaced by a smaller follow-up."
               })
             )

    assert {:ok, board} = DeliveryBoard.project(repo, work_request.id)
    slices_by_id = Map.new(board.work_packages, &{&1.id, &1})

    assert get_in(slices_by_id, [no_pr_slice.id, :operational_state, :key]) == "completed_no_pr"
    assert get_in(slices_by_id, [superseded_slice.id, :operational_state, :key]) == "superseded"
    assert get_in(slices_by_id, [superseded_slice.id, :successor, :work_package_id]) == successor_slice.id
  end

  test "delivery summary bounds freeform evidence", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-BOUNDED-DELIVERY")

    {work_package, _linked_package} =
      linked_slice!(repo, work_request,
        id: "WRS-BOARD-BOUNDED-DELIVERY",
        work_package_id: "WP-BOARD-BOUNDED-DELIVERY",
        status: "closed"
      )

    assert {:ok, _delivery} =
             Repository.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 idempotency_key: "delivery-board-bounded-evidence",
                 no_pr_evidence: String.duplicate("evidence-", 80)
               })
             )

    assert {:ok, %{work_packages: [slice]}} = DeliveryBoard.project(repo, work_request.id)
    assert String.length(slice.delivery.no_pr_evidence) == 240
  end

  test "projects provider-neutral worker, PR, review, and authoritative dependency signals", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-BOARD-GRAPH-SIGNALS")
    last_activity = DateTime.utc_now(:microsecond)
    active_since = DateTime.add(last_activity, -60, :second)

    {_satisfied, satisfied} =
      linked_slice!(repo, work_request,
        id: "WP-GRAPH-SATISFIED",
        work_package_id: "WP-GRAPH-SATISFIED",
        status: "skipped"
      )

    {_active, active} =
      linked_slice!(repo, work_request,
        id: "WP-GRAPH-ACTIVE",
        work_package_id: "WP-GRAPH-ACTIVE",
        status: "implementing"
      )

    {_blocked, blocked} =
      linked_slice!(repo, work_request,
        id: "WP-GRAPH-BLOCKED",
        work_package_id: "WP-GRAPH-BLOCKED",
        status: "blocked"
      )

    {_waiting, waiting} =
      linked_slice!(repo, work_request,
        id: "WP-GRAPH-WAITING",
        work_package_id: "WP-GRAPH-WAITING",
        status: "ready_for_worker"
      )

    {_join, join} =
      linked_slice!(repo, work_request,
        id: "WP-GRAPH-JOIN",
        work_package_id: "WP-GRAPH-JOIN",
        status: "ready_for_worker",
        review_requirement: %{
          "type" => "review-suite",
          "args" => %{"mode" => "normal", "current" => 1, "total" => 2, "step" => "analysis"}
        }
      )

    assert {:ok, run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: active.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "fictional-worker-a",
               started_at: active_since,
               last_seen_at: last_activity
             })

    assert {:ok, _blocker} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: blocked.id,
               summary: "Waiting for fictional input",
               status: "blocked",
               idempotency_key: "graph-signal-blocker",
               payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: "fictional-input", active: true},
               created_at: ~U[2026-07-18 08:02:00.000000Z]
             })

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: join.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "feat/fictional-join", head_sha: "0123456"},
               created_at: ~U[2026-07-18 08:03:00.000000Z]
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: join.id,
               summary: "PR attached with checks running",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/example/fictional/pull/42",
                 number: 42,
                 repository: "example/fictional",
                 head_sha: "0123456789abcdef0123456789abcdef01234567",
                 check_summary: %{status: "completed", conclusion: "failure", completed: 1, total: 3},
                 merge_state: %{merged: false}
               },
               created_at: ~U[2026-07-18 08:04:00.000000Z]
             })

    assert {:ok, _review} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: join.id,
               summary: "Review running",
               status: "review_package_submitted",
               payload: %{
                 type: "review_package",
                 source_tool: "submit_review_package",
                 head_sha: "0123456789abcdef0123456789abcdef01234567",
                 status: "running",
                 evidence_id: "review-join-42",
                 artifacts: ["review.txt"]
               },
               created_at: ~U[2026-07-18 08:05:00.000000Z]
             })

    for {prerequisite, index} <- Enum.with_index([satisfied, active, blocked, waiting], 1) do
      assert {:ok, _edge} =
               ProductTreeRepository.create_dependency_edge(repo, %{
                 id: "edge-graph-join-#{index}",
                 work_request_id: work_request.id,
                 source_kind: "work_package",
                 source_id: join.id,
                 target_kind: "work_package",
                 target_id: prerequisite.id,
                 kind: "depends_on",
                 reason: "Fictional join input #{index}",
                 created_by: "fixture",
                 created_at: DateTime.add(~U[2026-07-18 08:00:00.000000Z], index, :second)
               })
    end

    assert {:ok, board} = DeliveryBoard.project(repo, work_request.id)
    packages = Map.new(board.work_packages, &{&1.id, &1.work_package})
    projected_join = Enum.find(board.work_packages, &(&1.id == join.id))

    assert projected_join.operational_state.key == "dependency_blocked"
    assert projected_join.operational_state.attention_reason_codes == ["unmet_dependencies"]
    assert projected_join.operational_state.reason =~ join.id
    refute projected_join.operational_state.reason =~ "Ready for worker pickup"

    assert %{status: "active", run_label: "fictional-worker-a"} = packages[active.id].worker_signal
    assert packages[active.id].worker_signal.active_since == active_since
    assert packages[active.id].worker_signal.last_activity == run.updated_at

    assert %{status: "open", number: 42, current_head_sha: "0123456", head_matches: true} =
             packages[join.id].pr_signal

    assert packages[join.id].pr_signal.checks == %{status: "failing", current: 1, total: 3}

    assert %{type: "review-suite", status: "in_progress", current: 1, total: 2, step: "analysis", evidence_id: "review-join-42"} =
             packages[join.id].review_signal

    secret_requirement = put_in(join.review_requirement, ["args", "api_key"], "fixture-secret")
    assert Signals.review(%{join | review_requirement: secret_requirement}, %{}).args["api_key"] == "[REDACTED]"

    assert packages[join.id].dependency_signal == %{
             satisfied: 1,
             required: 4,
             active: 1,
             blocked: 1,
             unmet_work_package_ids: [active.id, blocked.id, waiting.id],
             inputs: [
               %{work_package_id: active.id, status: "active"},
               %{work_package_id: blocked.id, status: "blocked"},
               %{work_package_id: satisfied.id, status: "satisfied"},
               %{work_package_id: waiting.id, status: "waiting"}
             ]
           }
  end

  defp linked_slice!(repo, work_request, overrides) do
    work_package_id = Keyword.fetch!(overrides, :work_package_id)
    status = Keyword.get(overrides, :status, "ready_for_worker")

    work_package =
      create_work_package!(
        repo,
        work_request,
        overrides
        |> Keyword.drop([:work_package_id])
        |> Keyword.put(:id, work_package_id)
        |> Keyword.put(:status, status)
        |> Keyword.put(:dispatched_at, DateTime.utc_now(:microsecond))
      )

    {work_package, work_package}
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = Repository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_work_package!(repo, work_request, overrides) do
    assert {:ok, work_package} = CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(overrides))
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

  defp work_package_attrs(overrides) do
    defaults = %{
      id: "WRS-BOARD-#{System.unique_integer([:positive])}",
      title: "Add delivery-board projection",
      goal: "Project slice delivery state.",
      kind: "mcp",
      base_branch: "main",
      branch_pattern: "feat/delivery-board",
      allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
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

  defp database_path do
    Path.join(System.tmp_dir!(), "sympp-work-request-delivery-board-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")
  end
end
