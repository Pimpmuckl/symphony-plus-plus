Code.require_file("api_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.WorkRequestDeliveryProjectionTest do
  use SymphonyElixir.SymphonyPlusPlus.Dashboard.ApiCase, async: false

  test "WorkRequest detail preserves delivery-board closeout and delivery slice payloads", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-DELIVERY-BOARD")

    closeout_slice = add_approved_slice!(repo, work_request, id: "WRS-DASH-NEEDS-CLOSEOUT")
    closeout_package = create_matching_work_package!(repo, work_request, closeout_slice, id: "SYMPP-DASH-NEEDS-CLOSEOUT", status: "ready_for_merge")

    assert {:ok, _dispatched_closeout} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, closeout_slice.id, "approved", closeout_package.id)

    assert {:ok, _attached_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: closeout_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/nextide/symphony-plus-plus/pull/903",
                 head_sha: "head-903"
               }
             })

    assert {:ok, _merged_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: closeout_package.id,
               summary: "PR merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/nextide/symphony-plus-plus/pull/903",
                 head_sha: "head-903",
                 merge_state: %{merged: true}
               }
             })

    ready_merge_slice = add_approved_slice!(repo, work_request, id: "WRS-DASH-READY-MERGE", kind: "adapter")

    ready_merge_package =
      create_matching_work_package!(repo, work_request, ready_merge_slice,
        id: "SYMPP-DASH-READY-MERGE",
        kind: "adapter",
        policy_template: "adapter",
        status: "ready_for_merge"
      )

    assert {:ok, _dispatched_ready_merge} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, ready_merge_slice.id, "approved", ready_merge_package.id)

    ready_finish_slice = add_approved_slice!(repo, work_request, id: "WRS-DASH-READY-FINISH", kind: "investigation")

    ready_finish_package =
      create_matching_work_package!(repo, work_request, ready_finish_slice,
        id: "SYMPP-DASH-READY-FINISH",
        kind: "investigation",
        policy_template: "investigation",
        status: "ready_for_merge"
      )

    assert {:ok, _dispatched_ready_finish} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, ready_finish_slice.id, "approved", ready_finish_package.id)

    no_pr_slice = add_approved_slice!(repo, work_request, id: "WRS-DASH-NO-PR")
    no_pr_package = create_matching_work_package!(repo, work_request, no_pr_slice, id: "SYMPP-DASH-NO-PR", status: "closed")

    assert {:ok, _dispatched_no_pr} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, no_pr_slice.id, "approved", no_pr_package.id)

    assert {:ok, _no_pr_delivery} =
             WorkRequestRepository.record_work_package_delivery(
               repo,
               work_request.id,
               no_pr_slice.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 idempotency_key: "dashboard-delivery-board-no-pr",
                 no_pr_evidence: "Operator confirmed direct completion."
               })
             )

    superseded_slice = add_approved_slice!(repo, work_request, id: "WRS-DASH-SUPERSEDED")
    superseded_package = create_matching_work_package!(repo, work_request, superseded_slice, id: "SYMPP-DASH-SUPERSEDED", status: "closed")

    assert {:ok, _dispatched_superseded} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, superseded_slice.id, "approved", superseded_package.id)

    successor_slice = add_approved_slice!(repo, work_request, id: "WRS-DASH-SUCCESSOR")
    successor_package = create_matching_work_package!(repo, work_request, successor_slice, id: "SYMPP-DASH-SUCCESSOR", status: "ready_for_worker")

    assert {:ok, _successor_dispatch} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, successor_slice.id, "approved", successor_package.id)

    assert {:ok, _superseded_delivery} =
             WorkRequestRepository.record_work_package_delivery(
               repo,
               work_request.id,
               superseded_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 idempotency_key: "dashboard-delivery-board-superseded",
                 successor_work_package_id: successor_package.id,
                 superseded_reason: "Replaced by successor package."
               })
             )

    merged_delivery_work_package = add_approved_slice!(repo, work_request, id: "WRS-DASH-RECORDED-MERGED")

    merged_delivery_package =
      create_matching_work_package!(repo, work_request, merged_delivery_work_package,
        id: "SYMPP-DASH-RECORDED-MERGED",
        status: "ready_for_worker"
      )

    assert {:ok, _merged_delivery_progress} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: merged_delivery_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/nextide/symphony-plus-plus/pull/904",
                 number: 904,
                 repository: "nextide/symphony-plus-plus",
                 check_summary: %{status: "completed", conclusion: "success", completed: 2, total: 2}
               }
             })

    assert {:ok, _dispatched_merged_delivery} =
             CanonicalWorkPackageFixtures.dispatch_work_package(
               repo,
               work_request.id,
               merged_delivery_work_package.id,
               "approved",
               merged_delivery_package.id
             )

    assert {:ok, _merged_delivery} =
             WorkRequestRepository.record_work_package_delivery(
               repo,
               work_request.id,
               merged_delivery_work_package.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: "dashboard-delivery-board-pr-merged",
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/904",
                 pr_merged_at: ~U[2026-05-24 12:00:00.000000Z],
                 merge_commit_sha: "merge-904"
               })
             )

    filtered_successor_slice = add_approved_slice!(repo, work_request, id: "WRS-DASH-FILTERED-SUCCESSOR")

    filtered_successor_package =
      create_matching_work_package!(repo, work_request, filtered_successor_slice,
        id: "SYMPP-DASH-FILTERED-SUCCESSOR",
        status: "closed"
      )

    assert {:ok, _filtered_successor_dispatch} =
             CanonicalWorkPackageFixtures.dispatch_work_package(
               repo,
               work_request.id,
               filtered_successor_slice.id,
               "approved",
               filtered_successor_package.id
             )

    out_of_scope_successor_package =
      create_work_package!(repo,
        id: "SYMPP-DASH-OUT-OF-SCOPE-SUCCESSOR",
        status: "ready_for_worker",
        repo: work_request.repo,
        base_branch: "other-base"
      )

    assert {:error, :not_found} =
             WorkRequestRepository.record_work_package_delivery(
               repo,
               work_request.id,
               filtered_successor_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 idempotency_key: "dashboard-delivery-board-filtered-successor",
                 successor_work_package_id: out_of_scope_successor_package.id,
                 superseded_reason: "Out-of-scope successor should remain hidden."
               })
             )

    assert {:ok, payload} = Dashboard.work_request_detail(repo, work_request.id)

    assert payload.delivery_board["work_package_count"] == 8
    slices_by_id = Map.new(payload.delivery_board["work_packages"], &{&1["id"], &1})

    assert get_in(slices_by_id, ["WRS-DASH-NEEDS-CLOSEOUT", "operational_state", "key"]) == "needs_closeout"
    assert get_in(slices_by_id, ["WRS-DASH-NEEDS-CLOSEOUT", "attention_reason_codes"]) == ["pr_merged_without_delivery_outcome"]
    assert get_in(slices_by_id, ["WRS-DASH-READY-MERGE", "operational_state", "key"]) == "merge_ready"
    assert get_in(slices_by_id, ["WRS-DASH-READY-MERGE", "operational_state", "merge_required"]) == true
    assert get_in(slices_by_id, ["WRS-DASH-READY-FINISH", "operational_state", "key"]) == "ready_to_finish"
    assert get_in(slices_by_id, ["WRS-DASH-READY-FINISH", "operational_state", "merge_required"]) == false
    assert get_in(slices_by_id, ["WRS-DASH-NO-PR", "delivery", "outcome"]) == "completed_no_pr"
    assert get_in(slices_by_id, ["WRS-DASH-NO-PR", "operational_state", "key"]) == "completed_no_pr"
    assert get_in(slices_by_id, ["WRS-DASH-RECORDED-MERGED", "delivery", "outcome"]) == "pr_merged"

    assert get_in(slices_by_id, ["WRS-DASH-RECORDED-MERGED", "work_package", "pr_signal"]) == %{
             "status" => "merged",
             "url" => "https://github.com/nextide/symphony-plus-plus/pull/904",
             "number" => 904,
             "repository" => "nextide/symphony-plus-plus",
             "checks" => %{"status" => "passing", "current" => 2, "total" => 2}
           }

    assert get_in(slices_by_id, ["WRS-DASH-RECORDED-MERGED", "operational_state", "key"]) == "delivered"
    assert get_in(slices_by_id, ["WRS-DASH-SUPERSEDED", "successor", "work_package", "id"]) == successor_package.id
    assert get_in(slices_by_id, ["WRS-DASH-FILTERED-SUCCESSOR", "successor", "work_package"]) == nil
    assert get_in(slices_by_id, ["WRS-DASH-FILTERED-SUCCESSOR", "successor", "work_package_id"]) == nil

    work_packages_by_id = Map.new(payload.work_packages, &{&1.id, &1})

    assert Map.fetch!(work_packages_by_id, "WRS-DASH-NEEDS-CLOSEOUT").operational_state.key == "needs_closeout"
    assert Map.fetch!(work_packages_by_id, "WRS-DASH-READY-MERGE").operational_state.label == "Ready For Merge"
    assert Map.fetch!(work_packages_by_id, "WRS-DASH-READY-FINISH").operational_state.label == "Ready To Finish"
    assert get_in(Map.fetch!(work_packages_by_id, "WRS-DASH-NO-PR"), [:delivery, "outcome"]) == "completed_no_pr"
    assert Map.fetch!(work_packages_by_id, "WRS-DASH-NO-PR").operational_state.label == "Completed Without PR"
    assert get_in(Map.fetch!(work_packages_by_id, "WRS-DASH-RECORDED-MERGED"), [:delivery, "outcome"]) == "pr_merged"

    merged_slice = Map.fetch!(work_packages_by_id, "WRS-DASH-RECORDED-MERGED")
    assert merged_slice.operational_state.key == "delivered"
    assert merged_slice.operational_state.label == "Delivered"
    assert merged_slice.operational_state.raw_status == "ready_for_worker"
    assert merged_slice.operational_state.work_package_status == "ready_for_worker"
    assert merged_slice.operational_state.has_started == true
    assert merged_slice.operational_state.is_stale == true
    assert Enum.any?(merged_slice.operational_state.attention_items, &(&1.key == "ready_for_worker_with_activity"))
    assert "work_package_status_stale_after_delivery" in merged_slice.attention_reason_codes

    assert Map.fetch!(work_packages_by_id, "WRS-DASH-SUPERSEDED").operational_state.key == "superseded"
    assert get_in(Map.fetch!(work_packages_by_id, "WRS-DASH-SUPERSEDED"), [:successor, "work_package", "id"]) == successor_package.id
    assert payload.work_request.completed_at == nil
  end

  test "WorkRequest detail promotes docs packages without human merge to ready-to-finish", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-READY-FINISH")
    ready_finish_slice = add_approved_slice!(repo, work_request, id: "WRS-DASH-ONLY-READY-FINISH", kind: "docs")

    ready_finish_package =
      create_matching_work_package!(repo, work_request, ready_finish_slice,
        id: "SYMPP-DASH-ONLY-READY-FINISH",
        kind: "docs",
        policy_template: "docs",
        status: "ready_for_merge"
      )

    assert {:ok, _dispatched_ready_finish} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, ready_finish_slice.id, "approved", ready_finish_package.id)

    assert {:ok, payload} = Dashboard.work_request_detail(repo, work_request.id)

    assert payload.work_request.operational_state.key == "ready_to_finish"
    assert payload.work_request.operational_state.label == "Ready To Finish"

    delivery_work_packages_by_id = Map.new(payload.delivery_board["work_packages"], &{&1["id"], &1})
    assert get_in(delivery_work_packages_by_id, ["WRS-DASH-ONLY-READY-FINISH", "operational_state", "pr_required"]) == false
  end

  defp add_approved_slice!(repo, work_request, overrides) do
    assert {:ok, work_package} = CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(overrides))
    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")
    approved_slice
  end
end
