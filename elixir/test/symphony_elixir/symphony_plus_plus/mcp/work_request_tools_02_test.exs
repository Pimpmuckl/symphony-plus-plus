Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestTools02Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Revision

  test "WorkRequest MCP read tools for handoff phases include same repo/base siblings", %{repo: repo} do
    handoff_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-SIBLING",
        repo: handoff_work_request.repo,
        base_branch: handoff_work_request.base_branch,
        status: "ready_for_slicing"
      )

    _other_repo =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-OTHER-REPO",
        repo: "nextide/other",
        base_branch: handoff_work_request.base_branch,
        status: "ready_for_slicing"
      )

    other_base =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-OTHER-BASE",
        repo: handoff_work_request.repo,
        base_branch: "release/handoff-sibling",
        status: "ready_for_slicing"
      )

    assert {:ok, sibling_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               sibling.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-WR-HANDOFF-SIBLING", target_base_branch: sibling.base_branch)
             )

    {anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, handoff_work_request, [
        "read:work_request",
        "write:work_request",
        "dispatch:work_request"
      ])

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    list_payload = get_in(list_response, ["result", "structuredContent"])

    assert list_payload["scope"] == %{
             "repo" => anchor.repo,
             "base_branch" => anchor.base_branch
           }

    assert Enum.map(list_payload["work_requests"], & &1["id"]) == [handoff_work_request.id, sibling.id]
    refute inspect(list_response) =~ "WR-MCP-WR-HANDOFF-OTHER-REPO"
    refute inspect(list_response) =~ other_base.id

    sibling_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => sibling.id})
    assert get_in(sibling_read_response, ["result", "structuredContent", "work_request", "id"]) == sibling.id

    sibling_board_response = mcp_tool(repo, session, "read_delivery_board", %{"work_request_id" => sibling.id})
    assert get_in(sibling_board_response, ["result", "structuredContent", "work_request", "id"]) == sibling.id

    other_base_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => other_base.id})
    assert get_in(other_base_read_response, ["error", "code"]) == -32_004
    assert get_in(other_base_read_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(other_base_read_response) =~ other_base.id

    sibling_status_response =
      mcp_tool(repo, session, "set_work_request_status", %{
        "work_request_id" => sibling.id,
        "current_status" => "ready_for_slicing",
        "next_status" => "sliced"
      })

    assert get_in(sibling_status_response, ["error", "code"]) == -32_004
    assert get_in(sibling_status_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(sibling_status_response) =~ sibling.id

    sibling_question_response =
      mcp_tool(repo, session, "ask_question", %{
        "work_request_id" => sibling.id,
        "category" => "scope",
        "question" => "Can the sibling be mutated?",
        "why_needed" => "Mutation must stay pinned to the claimed WorkRequest."
      })

    assert get_in(sibling_question_response, ["error", "code"]) == -32_004
    assert get_in(sibling_question_response, ["error", "data", "reason"]) == "not_found"

    sibling_decision_response =
      mcp_tool(repo, session, "record_decision", %{
        "work_request_id" => sibling.id,
        "source_type" => "architect",
        "decision" => "Mutate sibling",
        "rationale" => "This should be denied.",
        "scope_impact" => "No sibling state should change.",
        "created_by" => "architect-1"
      })

    assert get_in(sibling_decision_response, ["error", "code"]) == -32_004
    assert get_in(sibling_decision_response, ["error", "data", "reason"]) == "not_found"

    sibling_add_slice_response =
      mcp_tool(repo, session, "plan_slice", %{
        "work_request_id" => sibling.id,
        "title" => "Sibling mutation",
        "goal" => "This should be denied.",
        "work_package_kind" => "mcp",
        "target_base_branch" => sibling.base_branch,
        "owned_file_globs" => ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
        "forbidden_file_globs" => [],
        "acceptance_criteria" => ["Sibling mutation remains denied."],
        "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp"],
        "review_lanes" => ["normal"],
        "stop_conditions" => ["Stop before mutating siblings."]
      })

    assert get_in(sibling_add_slice_response, ["error", "code"]) == -32_004
    assert get_in(sibling_add_slice_response, ["error", "data", "reason"]) == "not_found"

    sibling_approve_response =
      mcp_tool(repo, session, "approve_slice", %{
        "work_request_id" => sibling.id,
        "planned_slice_id" => sibling_slice.id,
        "current_status" => "planned"
      })

    assert get_in(sibling_approve_response, ["error", "code"]) == -32_004
    assert get_in(sibling_approve_response, ["error", "data", "reason"]) == "not_found"

    sibling_skip_response =
      mcp_tool(repo, session, "skip_slice", %{
        "work_request_id" => sibling.id,
        "planned_slice_id" => sibling_slice.id,
        "current_status" => "planned"
      })

    assert get_in(sibling_skip_response, ["error", "code"]) == -32_004
    assert get_in(sibling_skip_response, ["error", "data", "reason"]) == "not_found"

    assert {:ok, sibling_node} =
             ProductTree.create_node(repo, %{
               work_request_id: sibling.id,
               title: "Sibling plan"
             })

    sibling_upsert_response =
      mcp_tool(repo, session, "upsert_plan_node", %{
        "work_request_id" => sibling.id,
        "title" => "Sibling node mutation"
      })

    assert get_in(sibling_upsert_response, ["error", "code"]) == -32_004
    assert get_in(sibling_upsert_response, ["error", "data", "reason"]) == "not_found"

    sibling_move_response =
      mcp_tool(repo, session, "move_slice_to_plan_node", %{
        "work_request_id" => sibling.id,
        "planned_slice_id" => sibling_slice.id,
        "product_tree_node_id" => sibling_node.id
      })

    assert get_in(sibling_move_response, ["error", "code"]) == -32_004
    assert get_in(sibling_move_response, ["error", "data", "reason"]) == "not_found"

    sibling_mark_response =
      mcp_tool(repo, session, "finish_slicing", %{
        "work_request_id" => sibling.id,
        "current_status" => "ready_for_slicing"
      })

    assert get_in(sibling_mark_response, ["error", "code"]) == -32_004
    assert get_in(sibling_mark_response, ["error", "data", "reason"]) == "not_found"

    sibling_dispatch_response =
      mcp_tool(repo, session, "dispatch_slice", %{
        "work_request_id" => sibling.id,
        "planned_slice_id" => sibling_slice.id,
        "claimed_by" => "sibling-worker"
      })

    assert get_in(sibling_dispatch_response, ["error", "code"]) == -32_004
    assert get_in(sibling_dispatch_response, ["error", "data", "reason"]) == "not_found"

    sibling_delivery_response =
      mcp_tool(repo, session, "record_planned_slice_delivery", %{
        "work_request_id" => sibling.id,
        "planned_slice_id" => sibling_slice.id,
        "outcome" => "completed_no_pr",
        "evidence" => %{
          "completed_no_pr" => %{"no_pr_evidence" => "Sibling delivery mutation should be denied."}
        },
        "idempotency_key" => "sibling-delivery-denied"
      })

    assert get_in(sibling_delivery_response, ["error", "code"]) == -32_004
    assert get_in(sibling_delivery_response, ["error", "data", "reason"]) == "not_found"

    assert {:ok, persisted_sibling} = WorkRequestRepository.get(repo, sibling.id)
    assert persisted_sibling.status == "ready_for_slicing"
    assert {:ok, []} = WorkRequestRepository.list_questions(repo, sibling.id)
    assert {:ok, []} = WorkRequestRepository.list_decisions(repo, sibling.id)
    assert {:ok, [persisted_sibling_slice]} = WorkRequestRepository.list_planned_slices(repo, sibling.id)
    assert persisted_sibling_slice.id == sibling_slice.id
    assert persisted_sibling_slice.status == "planned"
    assert is_nil(persisted_sibling_slice.work_package_id)

    target_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => handoff_work_request.id})
    assert get_in(target_read_response, ["result", "structuredContent", "work_request", "id"]) == handoff_work_request.id
  end

  test "architect current WorkRequest planning writes can omit work_request_id", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-CURRENT-WR-WRITES", [
        "read:work_request",
        "write:work_request",
        "dispatch:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-CURRENT-WR-WRITES",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-CURRENT-WR-WRITES-SIBLING",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    add_args = %{
      "title" => "Current WorkRequest slice",
      "goal" => "Use the claimed WorkRequest when omitted.",
      "owned_file_globs" => ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
      "acceptance_criteria" => ["Omitted WorkRequest id targets the current claim."],
      "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp/work_request_tools_02_test.exs"],
      "stop_conditions" => ["Stop before dispatch."]
    }

    missing_context_response = mcp_tool(repo, session, "plan_slice", add_args)
    assert get_in(missing_context_response, ["error", "data", "reason"]) == "missing_work_request_id"

    grant_work_request_scope!(repo, session, work_request.id)

    add_response = mcp_tool(repo, session, "plan_slice", add_args)
    add_payload = get_in(add_response, ["result", "structuredContent"])
    planned_slice_id = get_in(add_payload, ["planned_slice", "id"])

    assert add_payload["work_request"]["id"] == work_request.id
    assert get_in(add_payload, ["planned_slice", "work_request_id"]) == work_request.id
    assert get_in(add_payload, ["planned_slice", "delivery_repo"]) == work_request.repo
    assert get_in(add_payload, ["planned_slice", "target_base_branch"]) == work_request.base_branch

    assert {:ok, planned_slice} = WorkRequestRepository.get_planned_slice(repo, work_request.id, planned_slice_id)
    assert planned_slice.work_package_kind == "standard_pr"
    assert planned_slice.branch_pattern == nil
    assert planned_slice.forbidden_file_globs == []
    assert planned_slice.review_lanes == ["normal"]

    unsafe_omission_response =
      mcp_tool(repo, session, "plan_slice", Map.delete(add_args, "owned_file_globs"))

    assert get_in(unsafe_omission_response, ["error", "data", "reason"]) == "missing_owned_file_globs"

    skip_add_response =
      mcp_tool(
        repo,
        session,
        "plan_slice",
        Map.merge(add_args, %{
          "title" => "Current WorkRequest skipped slice",
          "goal" => "Create a second current WorkRequest slice."
        })
      )

    skip_slice_id = get_in(skip_add_response, ["result", "structuredContent", "planned_slice", "id"])

    node_response =
      mcp_tool(repo, session, "upsert_plan_node", %{
        "title" => "Current WorkRequest product node"
      })

    node_payload = get_in(node_response, ["result", "structuredContent"])
    node_id = get_in(node_payload, ["product_plan_node", "id"])

    assert node_payload["work_request"]["id"] == work_request.id

    move_response =
      mcp_tool(repo, session, "move_slice_to_plan_node", %{
        "planned_slice_id" => planned_slice_id,
        "product_tree_node_id" => node_id
      })

    assert get_in(move_response, ["result", "structuredContent", "product_tree_slice_link", "work_request_id"]) == work_request.id

    approve_response =
      mcp_tool(repo, session, "approve_slice", %{
        "planned_slice_id" => planned_slice_id,
        "current_status" => "planned"
      })

    assert get_in(approve_response, ["result", "structuredContent", "planned_slice", "status"]) == "approved"

    skip_response =
      mcp_tool(repo, session, "skip_slice", %{
        "planned_slice_id" => skip_slice_id,
        "current_status" => "planned"
      })

    assert get_in(skip_response, ["result", "structuredContent", "planned_slice", "status"]) == "skipped"

    board_response = mcp_tool(repo, session, "read_delivery_board", %{})
    assert get_in(board_response, ["result", "structuredContent", "work_request", "id"]) == work_request.id

    mark_response =
      mcp_tool(repo, session, "finish_slicing", %{
        "current_status" => "ready_for_slicing"
      })

    assert get_in(mark_response, ["result", "structuredContent", "work_request", "status"]) == "sliced"

    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, sibling.id)
    assert {:ok, persisted_sibling} = WorkRequestRepository.get(repo, sibling.id)
    assert persisted_sibling.status == "ready_for_slicing"

    read_missing_response = mcp_tool(repo, session, "read_work_request", %{})
    assert get_in(read_missing_response, ["error", "data", "reason"]) == "missing_work_request_id"

    dispatch_response =
      mcp_tool(repo, session, "dispatch_slice", %{
        "planned_slice_id" => planned_slice_id,
        "claimed_by" => "current-wr-worker"
      })

    work_package_id = get_in(dispatch_response, ["result", "structuredContent", "work_package", "id"])
    assert is_binary(work_package_id)

    work_package = repo.get!(WorkPackage, work_package_id)
    assert work_package.kind == "standard_pr"
    assert work_package.policy_template == "standard_pr"
    assert {:ok, review_suite} = Renderer.render(repo, work_package_id, "review_suite.md")
    assert review_suite =~ "Policy template: `worker_package`"
    assert review_suite =~ "- Required: normal"
    assert review_suite =~ "human_merge"

    assert get_in(dispatch_response, ["result", "structuredContent", "coordinates", "primary_execution"]) == %{
             "kind" => "work_package",
             "work_package_id" => work_package_id
           }

    assert get_in(dispatch_response, ["result", "structuredContent", "coordinates", "product_audit"]) == %{
             "kind" => "planned_slice",
             "work_request_id" => work_request.id,
             "planned_slice_id" => planned_slice_id
           }

    assert {:ok, _attached} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package_id,
               summary: "PR attached and merged",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/#{anchor.repo}/pull/920",
                 repository: anchor.repo,
                 number: 920,
                 base_branch: anchor.base_branch,
                 head_sha: "head-current-wr",
                 merged: true,
                 merged_at: "2026-06-07T10:00:00Z",
                 merge_commit_sha: "merge-current-wr"
               }
             })

    reconcile_response = mcp_tool(repo, session, "reconcile_work_request", %{"apply" => true})
    assert get_in(reconcile_response, ["result", "structuredContent", "next_action"]) == "sliced"
    assert is_map(get_in(reconcile_response, ["result", "structuredContent", "delivery_board", "counts"]))
    refute Map.has_key?(get_in(reconcile_response, ["result", "structuredContent", "delivery_board"]), "slices")
    assert repo.get!(WorkPackage, work_package_id).status == "merged"
  end

  test "record_planned_slice_delivery accepts typed evidence for each outcome and rejects conflicts", %{repo: repo} do
    cases = [
      {"TYPED-PR", "ready_for_merge", "pr_merged", "merged"},
      {"TYPED-NO-PR", "reviewing", "completed_no_pr", "closed"},
      {"TYPED-SUPERSEDED", "ready_for_worker", "superseded", "closed"},
      {"TYPED-ABANDONED", "ready_for_worker", "abandoned", "abandoned"}
    ]

    for {suffix, package_status, outcome, expected_package_status} <- cases do
      {work_request, planned_slice, work_package} =
        linked_delivery_slice!(repo,
          id_suffix: suffix,
          package_status: package_status
        )

      {_anchor, session, _grant} =
        create_work_request_handoff_architect_session(repo, work_request, [
          "read:work_request",
          "write:work_request",
          "dispatch:work_request"
        ])

      evidence = typed_delivery_evidence(repo, work_request, outcome, suffix)

      response =
        mcp_tool(repo, session, "record_planned_slice_delivery", %{
          "work_request_id" => work_request.id,
          "planned_slice_id" => planned_slice.id,
          "outcome" => outcome,
          "idempotency_key" => "typed-delivery-#{String.downcase(suffix)}",
          "evidence" => evidence
        })

      assert get_in(response, ["result", "structuredContent", "planned_slice_delivery", "outcome"]) == outcome

      if outcome == "superseded" do
        assert get_in(response, ["result", "structuredContent", "planned_slice_delivery", "successor_work_package_id"]) ==
                 get_in(evidence, ["superseded", "successor_work_package_id"])
      end

      assert repo.get!(WorkPackage, work_package.id).status == expected_package_status
    end

    {work_request, planned_slice, _work_package} =
      linked_delivery_slice!(repo,
        id_suffix: "TYPED-CONFLICT",
        package_status: "ready_for_merge"
      )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, work_request, [
        "read:work_request",
        "write:work_request",
        "dispatch:work_request"
      ])

    mismatch_response =
      mcp_tool(repo, session, "record_planned_slice_delivery", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "outcome" => "pr_merged",
        "idempotency_key" => "typed-delivery-mismatch",
        "evidence" => %{
          "completed_no_pr" => %{"no_pr_evidence" => "Wrong typed evidence for this outcome."}
        }
      })

    assert get_in(mismatch_response, ["error", "data", "reason"]) == "conflicting_delivery_evidence"

    invalid_outcome_response =
      mcp_tool(repo, session, "record_planned_slice_delivery", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "outcome" => "merged",
        "idempotency_key" => "typed-delivery-invalid-outcome",
        "evidence" => %{"merged" => %{"summary" => "invalid outcome"}}
      })

    assert get_in(invalid_outcome_response, ["error", "data", "reason"]) == "invalid_outcome"

    assert get_in(invalid_outcome_response, ["error", "data", "validation_errors"]) == [
             %{
               "field" => "outcome",
               "reason" => "invalid_value",
               "allowed_values" => ["pr_merged", "completed_no_pr", "superseded", "abandoned"]
             }
           ]

    invalid_cleanup_evidence_response =
      mcp_tool(repo, session, "cleanup_work_request_planned_slice_runtime", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "outcome" => "superseded",
        "reason" => "cleanup stale runtime"
      })

    assert get_in(invalid_cleanup_evidence_response, ["error", "data", "reason"]) == "invalid_delivery_evidence"

    cleanup_errors = get_in(invalid_cleanup_evidence_response, ["error", "data", "validation_errors"])

    assert %{
             "field" => "successor_planned_slice_id",
             "message" => "can't be blank",
             "reason" => "required"
           } = Enum.find(cleanup_errors, &(&1["field"] == "successor_planned_slice_id"))

    assert %{
             "field" => "superseded_reason",
             "message" => "can't be blank",
             "reason" => "required"
           } = Enum.find(cleanup_errors, &(&1["field"] == "superseded_reason"))

    flat_response =
      mcp_tool(repo, session, "record_planned_slice_delivery", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "outcome" => "pr_merged",
        "idempotency_key" => "typed-delivery-flat-conflict",
        "pr_url" => "https://github.com/nextide/symphony-plus-plus/pull/301",
        "evidence" => pr_merged_delivery_evidence(301)
      })

    assert get_in(flat_response, ["error", "data", "reason"]) == "unexpected_argument"

    extra_field_response =
      mcp_tool(repo, session, "record_planned_slice_delivery", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "outcome" => "pr_merged",
        "idempotency_key" => "typed-delivery-extra-field",
        "evidence" => %{
          "pr_merged" => Map.put(pr_merged_delivery_evidence(302)["pr_merged"], "no_pr_evidence", "Not PR evidence.")
        }
      })

    assert get_in(extra_field_response, ["error", "data", "reason"]) == "invalid_evidence"
  end

  test "product plan node tools reject mixed intent arguments", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-NODE-MIXED-INTENT", [
        "read:work_request",
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-NODE-MIXED-INTENT",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    content_with_topology =
      mcp_tool(repo, session, "upsert_plan_node", %{
        "work_request_id" => work_request.id,
        "title" => "Content only",
        "parent_id" => "ptn-parent"
      })

    assert get_in(content_with_topology, ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(content_with_topology, ["error", "data", "arguments"]) == ["parent_id"]

    move_with_content =
      mcp_tool(repo, session, "move_plan_node", %{
        "work_request_id" => work_request.id,
        "product_tree_node_id" => "ptn-child",
        "parent_id" => nil,
        "title" => "Content belongs in the content tool"
      })

    assert get_in(move_with_content, ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(move_with_content, ["error", "data", "arguments"]) == ["title"]

    completion_with_topology =
      mcp_tool(repo, session, "set_plan_node_completion", %{
        "work_request_id" => work_request.id,
        "product_tree_node_id" => "ptn-child",
        "completion_mark" => "done",
        "parent_id" => nil
      })

    assert get_in(completion_with_topology, ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(completion_with_topology, ["error", "data", "arguments"]) == ["parent_id"]
  end

  test "record_planned_slice_delivery requires active blocker closeout and can preserve blockers", %{repo: repo} do
    {work_request, planned_slice, work_package} =
      linked_delivery_slice!(repo,
        id_suffix: "PRESERVE",
        package_status: "ready_for_merge"
      )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, work_request, [
        "read:work_request",
        "write:work_request",
        "dispatch:work_request"
      ])

    append_active_blocker!(repo, work_package.id, "preserve-blocker")

    missing_closeout_response =
      mcp_tool(repo, session, "record_planned_slice_delivery", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "outcome" => "pr_merged",
        "idempotency_key" => "delivery-preserve-missing-closeout",
        "evidence" => %{
          "pr_merged" => %{
            "pr_url" => "https://github.com/nextide/symphony-plus-plus/pull/201",
            "pr_number" => 201,
            "pr_repository" => "nextide/symphony-plus-plus",
            "pr_merged_at" => "2026-06-07T10:00:00Z",
            "merge_commit_sha" => "abc201"
          }
        }
      })

    assert get_in(missing_closeout_response, ["error", "data", "reason_code"]) == "blocker_closeout_required"
    assert [%{"blocker_id" => "preserve-blocker", "work_package_id" => blocker_work_package_id}] = get_in(missing_closeout_response, ["error", "data", "active_blockers"])
    assert blocker_work_package_id == work_package.id

    preserve_response =
      mcp_tool(repo, session, "record_planned_slice_delivery", %{
        "planned_slice_id" => planned_slice.id,
        "outcome" => "pr_merged",
        "idempotency_key" => "delivery-preserve-with-closeout",
        "evidence" => %{
          "pr_merged" => %{
            "pr_url" => "https://github.com/nextide/symphony-plus-plus/pull/201",
            "pr_number" => 201,
            "pr_repository" => "nextide/symphony-plus-plus",
            "pr_merged_at" => "2026-06-07T10:00:00Z",
            "merge_commit_sha" => "abc201"
          }
        },
        "blocker_closeout" => %{
          "decision" => "still_active",
          "blocker_ids" => ["preserve-blocker"],
          "summary" => "Blocker is intentionally preserved after merge"
        }
      })

    assert get_in(preserve_response, ["result", "structuredContent", "planned_slice_delivery", "outcome"]) == "pr_merged"
    assert get_in(preserve_response, ["result", "structuredContent", "blocker_closeout", "decision"]) == "still_active"
    assert repo.get!(WorkPackage, work_package.id).status == "merged"

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, work_package.id)
    assert [%{active: true, id: "preserve-blocker"}] = progress_events |> BlockerProjection.blockers() |> Enum.filter(& &1.active)
  end

  test "record_planned_slice_delivery can resolve active blockers before closeout", %{repo: repo} do
    {work_request, planned_slice, work_package} =
      linked_delivery_slice!(repo,
        id_suffix: "RESOLVE",
        package_status: "reviewing"
      )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, work_request, [
        "read:work_request",
        "write:work_request",
        "dispatch:work_request"
      ])

    append_active_blocker!(repo, work_package.id, "resolve-blocker")

    response =
      mcp_tool(repo, session, "record_planned_slice_delivery", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "outcome" => "completed_no_pr",
        "idempotency_key" => "delivery-resolve-with-closeout",
        "evidence" => %{
          "completed_no_pr" => %{"no_pr_evidence" => "Operator confirmed this landed directly."}
        },
        "blocker_closeout" => %{
          "decision" => "resolved",
          "blocker_ids" => ["resolve-blocker"],
          "resolution" => "The review-scope blocker was handled before closeout."
        }
      })

    assert get_in(response, ["result", "structuredContent", "planned_slice_delivery", "outcome"]) == "completed_no_pr"
    assert get_in(response, ["result", "structuredContent", "blocker_closeout", "decision"]) == "resolved"
    assert repo.get!(WorkPackage, work_package.id).status == "closed"

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, work_package.id)
    refute Enum.any?(BlockerProjection.blockers(progress_events), & &1.active)
    assert Enum.any?(progress_events, &(get_in(&1.payload, ["source_tool"]) == "resolve_blocker" and get_in(&1.payload, ["blocker_id"]) == "resolve-blocker"))
  end

  test "terminal product plan node completion asks for descendant blocker closeout", %{repo: repo} do
    {work_request, planned_slice, work_package} =
      linked_delivery_slice!(repo,
        id_suffix: "PLAN-NODE",
        package_status: "reviewing"
      )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, work_request, [
        "read:work_request",
        "write:work_request",
        "dispatch:work_request"
      ])

    node_response =
      mcp_tool(repo, session, "upsert_plan_node", %{
        "work_request_id" => work_request.id,
        "title" => "Blocked plan node"
      })

    product_tree_node_id = get_in(node_response, ["result", "structuredContent", "product_plan_node", "id"])

    move_response =
      mcp_tool(repo, session, "move_slice_to_plan_node", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "product_tree_node_id" => product_tree_node_id
      })

    assert get_in(move_response, ["result", "structuredContent", "product_tree_slice_link", "product_tree_node_id"]) == product_tree_node_id

    append_active_blocker!(repo, work_package.id, "node-blocker")

    missing_closeout_response =
      mcp_tool(repo, session, "set_plan_node_completion", %{
        "work_request_id" => work_request.id,
        "product_tree_node_id" => product_tree_node_id,
        "completion_mark" => "done"
      })

    assert get_in(missing_closeout_response, ["error", "data", "reason_code"]) == "blocker_closeout_required"

    resolved_response =
      mcp_tool(repo, session, "set_plan_node_completion", %{
        "work_request_id" => work_request.id,
        "product_tree_node_id" => product_tree_node_id,
        "completion_mark" => "done",
        "blocker_closeout" => %{
          "decision" => "resolved",
          "blocker_ids" => ["node-blocker"],
          "resolution" => "The node blocker was handled before marking the node done."
        }
      })

    assert get_in(resolved_response, ["result", "structuredContent", "product_plan_node", "completion_mark"]) == "done"
    assert get_in(resolved_response, ["result", "structuredContent", "blocker_closeout", "decision"]) == "resolved"

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, work_package.id)
    refute Enum.any?(BlockerProjection.blockers(progress_events), & &1.active)
    assert length(resolve_blocker_events(progress_events, "node-blocker")) == 1

    append_active_blocker!(repo, work_package.id, "node-blocker", idempotency_key: "node-blocker-reraised")

    reraised_resolved_response =
      mcp_tool(repo, session, "set_plan_node_completion", %{
        "work_request_id" => work_request.id,
        "product_tree_node_id" => product_tree_node_id,
        "completion_mark" => "done",
        "blocker_closeout" => %{
          "decision" => "resolved",
          "blocker_ids" => ["node-blocker"],
          "resolution" => "The re-raised node blocker was handled too."
        }
      })

    assert get_in(reraised_resolved_response, ["result", "structuredContent", "blocker_closeout", "decision"]) == "resolved"
    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, work_package.id)
    refute Enum.any?(BlockerProjection.blockers(progress_events), & &1.active)
    assert length(resolve_blocker_events(progress_events, "node-blocker")) == 2
  end

  test "legacy recovered handoff architects read same repo/base without persisted repo scope", %{repo: repo} do
    handoff_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-LEGACY-HANDOFF",
        repo: "symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    equivalent_sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-LEGACY-HANDOFF-SIBLING",
        repo: "Pimpmuckl/symphony-plus-plus",
        base_branch: handoff_work_request.base_branch,
        status: "ready_for_slicing"
      )

    other_repo =
      create_work_request!(repo,
        id: "WR-MCP-WR-LEGACY-HANDOFF-OTHER-REPO",
        repo: "Elsewhere/symphony-plus-plus",
        base_branch: handoff_work_request.base_branch,
        status: "ready_for_slicing"
      )

    other_base =
      create_work_request!(repo,
        id: "WR-MCP-WR-LEGACY-HANDOFF-OTHER-BASE",
        repo: equivalent_sibling.repo,
        base_branch: "release/legacy-handoff",
        status: "ready_for_slicing"
      )

    assert {:ok, sibling_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               equivalent_sibling.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-WR-LEGACY-HANDOFF-SIBLING", target_base_branch: equivalent_sibling.base_branch)
             )

    {anchor, session, grant} =
      create_work_request_handoff_architect_session(repo, handoff_work_request, [
        "read:work_request",
        "write:work_request",
        "dispatch:work_request"
      ])

    session = legacy_handoff_session_without_repo_scope!(repo, session, grant)

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    list_payload = get_in(list_response, ["result", "structuredContent"])

    assert list_payload["scope"] == %{
             "repo" => anchor.repo,
             "base_branch" => anchor.base_branch
           }

    assert Enum.map(list_payload["work_requests"], & &1["id"]) == [handoff_work_request.id, equivalent_sibling.id]
    refute inspect(list_response) =~ other_repo.id
    refute inspect(list_response) =~ other_base.id

    sibling_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => equivalent_sibling.id})
    assert get_in(sibling_read_response, ["result", "structuredContent", "work_request", "id"]) == equivalent_sibling.id

    sibling_board_response = mcp_tool(repo, session, "read_delivery_board", %{"work_request_id" => equivalent_sibling.id})
    assert get_in(sibling_board_response, ["result", "structuredContent", "work_request", "id"]) == equivalent_sibling.id

    other_repo_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => other_repo.id})
    assert get_in(other_repo_read_response, ["error", "code"]) == -32_004
    assert get_in(other_repo_read_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(other_repo_read_response) =~ other_repo.id

    other_base_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => other_base.id})
    assert get_in(other_base_read_response, ["error", "code"]) == -32_004
    assert get_in(other_base_read_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(other_base_read_response) =~ other_base.id

    sibling_status_response =
      mcp_tool(repo, session, "set_work_request_status", %{
        "work_request_id" => equivalent_sibling.id,
        "current_status" => "ready_for_slicing",
        "next_status" => "sliced"
      })

    assert get_in(sibling_status_response, ["error", "code"]) == -32_004
    assert get_in(sibling_status_response, ["error", "data", "reason"]) == "not_found"

    sibling_approve_response =
      mcp_tool(repo, session, "approve_slice", %{
        "work_request_id" => equivalent_sibling.id,
        "planned_slice_id" => sibling_slice.id,
        "current_status" => "planned"
      })

    assert get_in(sibling_approve_response, ["error", "code"]) == -32_004
    assert get_in(sibling_approve_response, ["error", "data", "reason"]) == "not_found"

    assert {:ok, persisted_sibling} = WorkRequestRepository.get(repo, equivalent_sibling.id)
    assert persisted_sibling.status == "ready_for_slicing"
    assert {:ok, [persisted_sibling_slice]} = WorkRequestRepository.list_planned_slices(repo, equivalent_sibling.id)
    assert persisted_sibling_slice.id == sibling_slice.id
    assert persisted_sibling_slice.status == "planned"
  end

  test "legacy recovered handoff architects fail closed with partial frozen repo scope", %{repo: repo} do
    handoff_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-LEGACY-HANDOFF-PARTIAL",
        repo: "symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-LEGACY-HANDOFF-PARTIAL-SIBLING",
        repo: handoff_work_request.repo,
        base_branch: handoff_work_request.base_branch,
        status: "ready_for_slicing"
      )

    {_anchor, session, grant} =
      create_work_request_handoff_architect_session(repo, handoff_work_request, [
        "read:work_request"
      ])

    repo_only_session =
      legacy_handoff_session_with_scope_fields!(repo, session, grant, handoff_work_request.repo, nil)

    repo_only_response = mcp_tool(repo, repo_only_session, "list_work_requests", %{"status" => "ready_for_slicing"})
    assert get_in(repo_only_response, ["error", "code"]) == -32_003
    assert get_in(repo_only_response, ["error", "data", "reason"]) == "outside_session_scope"
    refute inspect(repo_only_response) =~ sibling.id

    base_only_session =
      legacy_handoff_session_with_scope_fields!(repo, repo_only_session, grant, nil, handoff_work_request.base_branch)

    base_only_response = mcp_tool(repo, base_only_session, "list_work_requests", %{"status" => "ready_for_slicing"})
    assert get_in(base_only_response, ["error", "code"]) == -32_003
    assert get_in(base_only_response, ["error", "data", "reason"]) == "outside_session_scope"
    refute inspect(base_only_response) =~ sibling.id
  end

  test "WorkRequest MCP scope is not pinned for normal non-handoff phases", %{repo: repo} do
    first =
      create_work_request!(repo,
        id: "WR-MCP-WR-PREFIX-FIRST",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    second =
      create_work_request!(repo,
        id: "WR-MCP-WR-PREFIX-SECOND",
        repo: first.repo,
        base_branch: first.base_branch,
        status: "ready_for_slicing"
      )

    phase_id = "phase-manual-work-request-scope"
    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Manual WorkRequest phase"})

    {_anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-PREFIX-NON-HANDOFF", ["read:work_request"],
        phase_id: phase_id,
        repo: first.repo,
        base_branch: first.base_branch
      )

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    list_payload = get_in(list_response, ["result", "structuredContent"])

    assert list_payload["scope"] == %{"repo" => first.repo, "base_branch" => first.base_branch}
    assert Enum.map(list_payload["work_requests"], & &1["id"]) == [first.id, second.id]
  end

  test "WorkRequest MCP tools fail closed for partial handoff provenance", %{repo: repo} do
    first =
      create_work_request!(repo,
        id: "WR-MCP-WR-PARTIAL-HANDOFF-FIRST",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-PARTIAL-HANDOFF-SIBLING",
        repo: first.repo,
        base_branch: first.base_branch,
        status: "ready_for_slicing"
      )

    phase_id = "phase-wr-architect-partial-provenance"
    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Partial handoff phase"})

    {_anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-PARTIAL-HANDOFF", ["read:work_request"],
        phase_id: phase_id,
        repo: first.repo,
        base_branch: first.base_branch
      )

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    assert get_in(list_response, ["error", "code"]) == -32_003
    assert get_in(list_response, ["error", "data", "reason"]) == "outside_session_scope"
    refute inspect(list_response) =~ sibling.id
  end

  test "WorkRequest MCP tools fail closed when handoff provenance no longer matches a WorkRequest", %{repo: repo} do
    handoff_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-DRIFTED",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-DRIFTED-SIBLING",
        repo: handoff_work_request.repo,
        base_branch: handoff_work_request.base_branch,
        status: "ready_for_slicing"
      )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, handoff_work_request, [
        "read:work_request"
      ])

    assert {:ok, _drifted} =
             WorkRequestRepository.update(repo, handoff_work_request.id, %{"repo" => "nextide/drifted"})

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    assert get_in(list_response, ["error", "code"]) == -32_003
    assert get_in(list_response, ["error", "data", "reason"]) == "outside_session_scope"
    refute inspect(list_response) =~ sibling.id
  end

  test "WorkRequest MCP tools fail closed when handoff WorkRequest leaves eligible status", %{repo: repo} do
    handoff_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-INELIGIBLE",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, handoff_work_request, [
        "read:work_request"
      ])

    assert {:ok, _draft} = WorkRequestRepository.update_status(repo, handoff_work_request.id, "ready_for_slicing", "draft")

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => handoff_work_request.id})
    assert get_in(read_response, ["error", "code"]) == -32_003
    assert get_in(read_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "WorkRequest MCP tools fail closed when handoff WorkRequest file scope changes", %{repo: repo} do
    handoff_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-FILE-SCOPE",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, handoff_work_request, [
        "read:work_request"
      ])

    assert {:ok, _narrowed} =
             WorkRequestRepository.update(repo, handoff_work_request.id, %{
               "constraints" => %{"allowed_paths" => ["docs"], "requires_secret" => false}
             })

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => handoff_work_request.id})
    assert get_in(read_response, ["error", "code"]) == -32_003
    assert get_in(read_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "architect WorkRequest mutation tools update scoped clarification state and redact responses", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_clarification"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    status_response =
      mcp_tool(repo, session, "set_work_request_status", %{
        "work_request_id" => work_request.id,
        "current_status" => "ready_for_clarification",
        "next_status" => "clarifying"
      })

    status_payload = get_in(status_response, ["result", "structuredContent"])
    assert status_payload["work_request"]["status"] == "clarifying"
    assert MapSet.new(Map.keys(status_payload["work_request"])) == MapSet.new(["id", "status", "updated_at"])
    assert status_payload["status"] == %{"previous_status" => "ready_for_clarification", "current_status" => "clarifying"}
    assert status_payload["scope"] == %{"repo" => anchor.repo, "base_branch" => anchor.base_branch}

    assert {:ok, persisted_work_request} = WorkRequestRepository.get(repo, work_request.id)
    assert persisted_work_request.status == "clarifying"

    ask_response =
      mcp_tool(repo, session, "ask_question", %{
        "work_request_id" => work_request.id,
        "category" => "scope",
        "question" => "Can the implementation use Bearer raw_secret_value?",
        "why_needed" => "The architect needs to avoid raw_secret_value leakage.",
        "decision_prompt" => %{
          "tl_dr" => "Choose whether to continue.",
          "details" => "The architect needs a human-readable option picker.",
          "options" => [
            %{
              "id" => "continue",
              "label" => "Continue",
              "description" => "Proceed with the safe path.",
              "pros" => ["Fastest path"],
              "cons" => ["Leaves polish for later"],
              "answer" => "Continue without raw_secret_value."
            }
          ],
          "custom_redirect_label" => "No, and tell the agent what to do differently"
        },
        "asked_by_agent_run_id" => "raw_secret_value"
      })

    ask_payload = get_in(ask_response, ["result", "structuredContent"])
    question_id = get_in(ask_payload, ["clarification_question", "id"])
    assert is_binary(question_id)
    assert get_in(ask_payload, ["clarification_question", "status"]) == "open"
    refute Map.has_key?(ask_payload["clarification_question"], "asked_by_agent_run_id")
    refute Map.has_key?(ask_payload["clarification_question"], "decision_prompt")
    assert MapSet.new(Map.keys(ask_payload["work_request"])) == MapSet.new(["id", "status", "updated_at"])
    refute inspect(ask_response) =~ "raw_secret_value"

    wrong_status_response =
      mcp_tool(repo, session, "answer_question", %{
        "work_request_id" => work_request.id,
        "question_id" => question_id,
        "expected_question_status" => "ready_for_slicing",
        "answer" => "Wrong status domain."
      })

    assert get_in(wrong_status_response, ["error", "data", "reason"]) == "invalid_question_status"
    assert get_in(wrong_status_response, ["error", "data", "status_domain"]) == "clarification_question"
    assert get_in(wrong_status_response, ["error", "data", "expected_statuses"]) == ["open"]
    assert get_in(wrong_status_response, ["error", "data", "got"]) == "ready_for_slicing"

    malformed_status_response =
      mcp_tool(repo, session, "answer_question", %{
        "work_request_id" => work_request.id,
        "question_id" => question_id,
        "expected_question_status" => 123,
        "answer" => "Malformed status guard."
      })

    assert get_in(malformed_status_response, ["error", "data", "reason"]) == "invalid_question_status"
    assert get_in(malformed_status_response, ["error", "data", "got"]) == "non_string"

    answer_response =
      mcp_tool(repo, session, "answer_question", %{
        "work_request_id" => work_request.id,
        "question_id" => question_id,
        "answer" => "Use signed URL https://example.test/path?sig=raw_secret_value instead."
      })

    answer_payload = get_in(answer_response, ["result", "structuredContent"])
    assert get_in(answer_payload, ["clarification_question", "status"]) == "answered"
    refute Map.has_key?(answer_payload["clarification_question"], "answered_by")
    refute inspect(answer_response) =~ "raw_secret_value"

    close_ask_response =
      mcp_tool(repo, session, "ask_question", %{
        "work_request_id" => work_request.id,
        "category" => "acceptance",
        "question" => "Can the stale branch be ignored?",
        "why_needed" => "The architect needs an explicit closure reason."
      })

    close_question_id = get_in(close_ask_response, ["result", "structuredContent", "clarification_question", "id"])

    close_response =
      mcp_tool(repo, session, "close_question", %{
        "work_request_id" => work_request.id,
        "question_id" => close_question_id,
        "current_status" => "open"
      })

    assert get_in(close_response, ["result", "structuredContent", "clarification_question", "status"]) == "closed"

    combined_ask_response =
      mcp_tool(repo, session, "ask_question", %{
        "work_request_id" => work_request.id,
        "category" => "product",
        "question" => "Should we keep this backend-only?",
        "why_needed" => "The answer should become decision-log truth."
      })

    combined_question_id = get_in(combined_ask_response, ["result", "structuredContent", "clarification_question", "id"])

    combined_response =
      mcp_tool(repo, session, "answer_question_and_record_decision", %{
        "work_request_id" => work_request.id,
        "question_id" => combined_question_id,
        "answer" => "Keep it backend-only.",
        "source_type" => "architect",
        "decision" => "Keep the WorkRequest backend-only.",
        "rationale" => "The UI is out of scope.",
        "scope_impact" => "No dashboard changes."
      })

    combined_payload = get_in(combined_response, ["result", "structuredContent"])
    assert get_in(combined_payload, ["clarification_question", "status"]) == "answered"
    assert is_binary(get_in(combined_payload, ["decision_log_entry", "id"]))
    assert get_in(combined_payload, ["decision_log_entry", "source_id"]) == combined_question_id

    decision_response =
      mcp_tool(repo, session, "record_decision", %{
        "work_request_id" => work_request.id,
        "source_type" => "architect",
        "source_id" => "comment-1",
        "decision" => "Keep this WorkRequest backend-only with token raw_secret_value excluded.",
        "rationale" => "Dashboard work is out of scope.",
        "scope_impact" => "No dashboard changes.",
        "created_by" => "architect-1"
      })

    decision_payload = get_in(decision_response, ["result", "structuredContent"])
    assert is_binary(get_in(decision_payload, ["decision_log_entry", "id"]))
    assert get_in(decision_payload, ["decision_log_entry", "source_id"]) == "comment-1"
    assert decision_payload["status"] == %{"work_request_status" => "clarifying"}
    refute inspect(decision_response) =~ "raw_secret_value"

    assert {:ok, questions} = WorkRequestRepository.list_questions(repo, work_request.id)
    assert Enum.map(questions, & &1.status) == ["answered", "closed", "answered"]
    assert {:ok, decisions} = WorkRequestRepository.list_decisions(repo, work_request.id)
    assert Enum.map(decisions, & &1.source_id) == [combined_question_id, "comment-1"]
  end

  test "ask_question rejects malformed decision prompts without echoing nested input", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-BAD-PROMPT", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-BAD-DECISION-PROMPT",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "clarifying"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    response =
      mcp_tool(repo, session, "ask_question", %{
        "work_request_id" => work_request.id,
        "category" => "scope",
        "question" => "Can the implementation continue?",
        "why_needed" => "The architect needs a human answer.",
        "decision_prompt" => %{
          "tl_dr" => "Do not leak raw_secret_value.",
          "details" => "This malformed prompt is missing options."
        }
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "decision_prompt must contain 1 to 4 options"
    refute inspect(response) =~ "raw_secret_value"
  end

  test "WorkRequest MCP question mutations leave parent status explicit", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-STATUS-EXPLICIT", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-STATUS-EXPLICIT",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_clarification"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    response =
      mcp_tool(repo, session, "ask_question", %{
        "work_request_id" => work_request.id,
        "category" => "scope",
        "question" => "Should this move status automatically?",
        "why_needed" => "MCP uses explicit status mutation."
      })

    payload = get_in(response, ["result", "structuredContent"])
    assert payload["work_request"]["status"] == "ready_for_clarification"

    assert payload["status"] == %{
             "work_request_status" => "ready_for_clarification",
             "question_status" => "open"
           }

    assert {:ok, persisted_work_request} = WorkRequestRepository.get(repo, work_request.id)
    assert persisted_work_request.status == "ready_for_clarification"
  end

  test "architect WorkRequest planned-slice mutation tools update scoped slices and mark sliced", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-MUTATE", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-MUTATE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing",
        human_description: "Do not return raw_secret_value."
      )

    grant_work_request_scope!(repo, session, work_request.id)

    counts_before = {
      repo.aggregate(WorkPackage, :count),
      repo.aggregate(AccessGrant, :count),
      repo.aggregate(ProgressEvent, :count),
      repo.aggregate(Artifact, :count)
    }

    add_args = %{
      "work_request_id" => work_request.id,
      "title" => "Planned raw_secret_value slice",
      "goal" => "Persist a planned slice without leaking raw_secret_value.",
      "work_package_kind" => "mcp",
      "target_base_branch" => anchor.base_branch,
      "owned_file_globs" => [" elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex "],
      "forbidden_file_globs" => [],
      "acceptance_criteria" => ["MCP planned-slice mutation succeeds."],
      "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp"],
      "review_lanes" => ["fast", "normal"],
      "stop_conditions" => ["Stop before dispatch."]
    }

    changeset_error_response =
      mcp_tool(
        repo,
        session,
        "plan_slice",
        Map.merge(add_args, %{
          "title" => "Invalid raw_secret_value slice",
          "goal" => "Do not echo raw_secret_value in changeset errors.",
          "work_package_kind" => "side_quest",
          "review_lanes" => ["raw_secret_value"]
        })
      )

    assert get_in(changeset_error_response, ["error", "code"]) == -32_602
    assert get_in(changeset_error_response, ["error", "data", "reason"]) == "invalid_planned_slice"
    validation_errors = get_in(changeset_error_response, ["error", "data", "validation_errors"])

    assert %{
             "field" => "review_lanes",
             "message" => "must be Review Suite profiles only; GitHub review lanes do not belong here",
             "reason" => "invalid_review_lanes",
             "allowed_values" => ["fast", "normal", "deep"]
           } = Enum.find(validation_errors, &(&1["field"] == "review_lanes"))

    assert %{
             "field" => "work_package_kind",
             "message" => "is invalid",
             "reason" => "invalid_value",
             "allowed_values" => allowed_kinds
           } = Enum.find(validation_errors, &(&1["field"] == "work_package_kind"))

    assert allowed_kinds == WorkPackage.planned_slice_kinds()

    refute inspect(changeset_error_response) =~ "raw_secret_value"
    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    invalid_docs_scope_response =
      mcp_tool(
        repo,
        session,
        "plan_slice",
        Map.merge(add_args, %{
          "title" => "Invalid docs scope",
          "goal" => "Docs kind cannot own code paths.",
          "work_package_kind" => "docs",
          "owned_file_globs" => ["elixir/lib/**"]
        })
      )

    assert get_in(invalid_docs_scope_response, ["error", "code"]) == -32_602
    assert get_in(invalid_docs_scope_response, ["error", "data", "reason"]) == "planned_slice_scope_violation"

    assert [
             %{
               "field" => "owned_file_globs",
               "value" => "elixir/lib/**",
               "reason" => "non_documentation_owned_glob"
             }
           ] = get_in(invalid_docs_scope_response, ["error", "data", "validation_errors"])

    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    invalid_branch_response =
      mcp_tool(
        repo,
        session,
        "plan_slice",
        Map.put(add_args, "branch_pattern", "feat/live-triggers-v1-native-audio-evidence-*")
      )

    assert get_in(invalid_branch_response, ["error", "data", "reason"]) == "unsupported_branch_pattern_wildcard"

    assert [
             %{
               "field" => "branch_pattern",
               "value" => "feat/live-triggers-v1-native-audio-evidence-*",
               "reason" => "unsupported_branch_pattern_wildcard"
             }
             | _
           ] = get_in(invalid_branch_response, ["error", "data", "validation_errors"])

    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    add_response = mcp_tool(repo, session, "plan_slice", add_args)
    add_payload = get_in(add_response, ["result", "structuredContent"])
    planned_slice_id = get_in(add_payload, ["planned_slice", "id"])

    assert is_binary(planned_slice_id)
    assert add_payload["scope"] == %{"repo" => anchor.repo, "base_branch" => anchor.base_branch}
    assert add_payload["work_request"]["status"] == "ready_for_slicing"
    assert get_in(add_payload, ["planned_slice", "status"]) == "planned"
    refute Map.has_key?(add_payload["planned_slice"], "owned_file_globs")
    refute Map.has_key?(add_payload["planned_slice"], "acceptance_criteria")
    refute Map.has_key?(add_payload["planned_slice"], "review_lanes")
    assert add_payload["status"] == %{"work_request_status" => "ready_for_slicing", "planned_slice_status" => "planned"}
    refute inspect(add_response) =~ "raw_secret_value"

    skip_add_response =
      mcp_tool(
        repo,
        session,
        "plan_slice",
        Map.merge(add_args, %{
          "title" => "Skipped follow-up",
          "goal" => "Record a slice that can be skipped.",
          "branch_pattern" => "agent/SYMPP-V2-WR-015/skipped"
        })
      )

    skip_slice_id = get_in(skip_add_response, ["result", "structuredContent", "planned_slice", "id"])

    approve_response =
      mcp_tool(repo, session, "approve_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice_id,
        "current_status" => "planned"
      })

    approve_payload = get_in(approve_response, ["result", "structuredContent"])
    assert get_in(approve_payload, ["planned_slice", "status"]) == "approved"

    assert approve_payload["status"] == %{
             "work_request_status" => "ready_for_slicing",
             "previous_planned_slice_status" => "planned",
             "planned_slice_status" => "approved"
           }

    skip_response =
      mcp_tool(repo, session, "skip_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => skip_slice_id,
        "current_status" => "planned"
      })

    skip_payload = get_in(skip_response, ["result", "structuredContent"])
    assert get_in(skip_payload, ["planned_slice", "status"]) == "skipped"
    refute Map.has_key?(skip_payload["planned_slice"], "branch_pattern")

    mark_response =
      mcp_tool(repo, session, "finish_slicing", %{
        "work_request_id" => work_request.id,
        "current_status" => "ready_for_slicing"
      })

    mark_payload = get_in(mark_response, ["result", "structuredContent"])
    assert mark_payload["work_request"]["status"] == "sliced"
    assert mark_payload["status"] == %{"previous_status" => "ready_for_slicing", "current_status" => "sliced"}

    assert {:ok, planned_slices} = WorkRequestRepository.list_planned_slices(repo, work_request.id)
    assert Enum.map(planned_slices, & &1.status) == ["approved", "skipped"]
    assert {:ok, persisted_work_request} = WorkRequestRepository.get(repo, work_request.id)
    assert persisted_work_request.status == "sliced"

    assert {
             repo.aggregate(WorkPackage, :count),
             repo.aggregate(AccessGrant, :count),
             repo.aggregate(ProgressEvent, :count),
             repo.aggregate(Artifact, :count)
           } == counts_before
  end

  test "architect WorkRequest product tree tools create nodes and move slices", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-PRODUCT-TREE-MOVE", [
        "read:work_request",
        "write:work_request",
        "dispatch:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-PRODUCT-TREE-MOVE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-WR-PRODUCT-TREE-MOVE", target_base_branch: work_request.base_branch)
             )

    node_response =
      mcp_tool(repo, session, "upsert_plan_node", %{
        "work_request_id" => work_request.id,
        "title" => "Backend product layer",
        "node_kind" => "layer"
      })

    node_payload = get_in(node_response, ["result", "structuredContent"])
    product_tree_node_id = get_in(node_payload, ["product_plan_node", "id"])

    assert is_binary(product_tree_node_id)
    refute Map.has_key?(node_payload["product_plan_node"], "title")
    refute Map.has_key?(node_payload, "product_tree")
    assert node_payload["scope"] == %{"repo" => anchor.repo, "base_branch" => anchor.base_branch}

    positioned_node_response =
      mcp_tool(repo, session, "move_plan_node", %{
        "work_request_id" => work_request.id,
        "product_tree_node_id" => product_tree_node_id,
        "position" => 2
      })

    assert get_in(positioned_node_response, ["result", "structuredContent", "product_plan_node", "position"]) == 2
    refute Map.has_key?(get_in(positioned_node_response, ["result", "structuredContent"]), "product_tree")

    child_response =
      mcp_tool(repo, session, "upsert_plan_node", %{
        "work_request_id" => work_request.id,
        "title" => "Nested cleanup"
      })

    child_node_id = get_in(child_response, ["result", "structuredContent", "product_plan_node", "id"])

    nested_child_response =
      mcp_tool(repo, session, "move_plan_node", %{
        "work_request_id" => work_request.id,
        "product_tree_node_id" => child_node_id,
        "parent_id" => product_tree_node_id
      })

    assert get_in(nested_child_response, ["result", "structuredContent", "product_plan_node", "parent_id"]) == product_tree_node_id
    refute Map.has_key?(get_in(nested_child_response, ["result", "structuredContent"]), "product_tree")

    root_child_response =
      mcp_tool(repo, session, "move_plan_node", %{
        "work_request_id" => work_request.id,
        "product_tree_node_id" => child_node_id,
        "parent_id" => ""
      })

    assert get_in(root_child_response, ["result", "structuredContent", "product_plan_node", "parent_id"]) == nil
    refute Map.has_key?(get_in(root_child_response, ["result", "structuredContent"]), "product_tree")

    nested_again_response =
      mcp_tool(repo, session, "move_plan_node", %{
        "work_request_id" => work_request.id,
        "product_tree_node_id" => child_node_id,
        "parent_id" => product_tree_node_id
      })

    assert get_in(nested_again_response, ["result", "structuredContent", "product_plan_node", "parent_id"]) == product_tree_node_id

    content_edit_response =
      mcp_tool(repo, session, "upsert_plan_node", %{
        "work_request_id" => work_request.id,
        "product_tree_node_id" => child_node_id,
        "description" => "A content-only edit keeps topology unchanged."
      })

    assert get_in(content_edit_response, ["result", "structuredContent", "product_plan_node", "parent_id"]) == product_tree_node_id

    explicit_root_response =
      mcp_tool(repo, session, "move_plan_node", %{
        "work_request_id" => work_request.id,
        "product_tree_node_id" => child_node_id,
        "parent_id" => ""
      })

    assert get_in(explicit_root_response, ["result", "structuredContent", "product_plan_node", "parent_id"]) == nil
    refute Map.has_key?(get_in(explicit_root_response, ["result", "structuredContent"]), "product_tree")

    move_response =
      mcp_tool(repo, session, "move_slice_to_plan_node", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "product_tree_node_id" => product_tree_node_id,
        "position" => 3
      })

    move_payload = get_in(move_response, ["result", "structuredContent"])
    link_payload = move_payload["product_tree_slice_link"]

    assert link_payload["planned_slice_id"] == planned_slice.id
    assert link_payload["product_tree_node_id"] == product_tree_node_id
    assert link_payload["position"] == 3
    assert get_in(move_payload, ["status", "slice_product_tree_location"]) == "product_plan_node"
    refute Map.has_key?(move_payload, "product_tree")

    approve_response =
      mcp_tool(repo, session, "approve_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "current_status" => "planned"
      })

    assert get_in(approve_response, ["result", "structuredContent", "planned_slice", "status"]) == "approved"

    dispatch_response =
      mcp_tool(repo, session, "dispatch_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "claimed_by" => "product-tree-worker"
      })

    work_package_id = get_in(dispatch_response, ["result", "structuredContent", "work_package", "id"])
    assert is_binary(work_package_id)
    assert {:ok, _blocked_work_package} = WorkPackageRepository.update(repo, work_package_id, %{status: "blocked"})

    assert {:ok, scratch_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-PRODUCT-TREE-SCRATCH",
                 title: "Superseded scratch",
                 target_base_branch: work_request.base_branch
               )
             )

    scratch_slice = repo.update!(Ecto.Changeset.change(scratch_slice, status: "skipped"))

    assert {:ok, _scratch_link} =
             ProductTree.create_slice_link(repo, %{
               work_request_id: work_request.id,
               product_tree_node_id: product_tree_node_id,
               planned_slice_id: scratch_slice.id,
               position: 4
             })

    read_refs_response =
      mcp_tool(repo, session, "read_plan", %{
        "work_request_id" => work_request.id
      })

    read_refs_payload = get_in(read_refs_response, ["result", "structuredContent"])
    read_refs_tree = read_refs_payload["product_tree"]
    read_refs_nodes_by_id = Map.new(read_refs_tree["nodes"], &{&1["id"], &1})
    read_refs_node = read_refs_nodes_by_id[product_tree_node_id]

    assert read_refs_payload["view"] == "nodes_with_slice_refs"
    assert Enum.sort(read_refs_node["slice_ids"]) == Enum.sort([planned_slice.id, scratch_slice.id])
    assert read_refs_node["computed_completion_mark"] == "partial"
    assert {read_refs_node["attention_count"], read_refs_node["guidance_count"], read_refs_node["blocker_count"]} == {1, 0, 1}
    assert Map.has_key?(read_refs_nodes_by_id, child_node_id)
    read_refs_by_id = Map.new(read_refs_tree["slice_refs"], &{&1["id"], &1})
    assert get_in(read_refs_by_id, [planned_slice.id, "work_package_id"]) == work_package_id
    assert get_in(read_refs_by_id, [planned_slice.id, "operational_state", "key"]) == "blocked"
    assert get_in(read_refs_by_id, [planned_slice.id, "has_full_payload"]) == false
    assert get_in(read_refs_by_id, [scratch_slice.id, "has_full_payload"]) == false
    summary = read_refs_tree["summary"]
    assert {summary["attention_count"], summary["guidance_count"], summary["blocker_count"]} == {1, 0, 1}
    refute Map.has_key?(read_refs_tree, "slices")

    read_nodes_response =
      mcp_tool(repo, session, "read_plan", %{
        "work_request_id" => work_request.id,
        "view" => "nodes_only"
      })

    read_nodes_payload = get_in(read_nodes_response, ["result", "structuredContent"])
    read_nodes_tree = read_nodes_payload["product_tree"]
    read_nodes_by_id = Map.new(read_nodes_tree["nodes"], &{&1["id"], &1})

    assert read_nodes_payload["view"] == "nodes_only"
    refute Enum.any?(["slice_ids", "attention_count", "guidance_count"], &Map.has_key?(read_nodes_by_id[product_tree_node_id], &1))
    assert read_nodes_by_id[product_tree_node_id]["computed_completion_mark"] == "partial"
    assert read_nodes_tree["root_slice_ids"] == []
    assert read_nodes_tree["omitted_slice_count"] == 2

    read_full_response =
      mcp_tool(repo, session, "read_plan", %{
        "work_request_id" => work_request.id,
        "view" => "nodes_with_slices"
      })

    read_full_tree = get_in(read_full_response, ["result", "structuredContent", "product_tree"])
    read_full_text = get_in(read_full_response, ["result", "content", Access.at(0), "text"])

    read_full_by_id = Map.new(read_full_tree["slices"], &{&1["id"], &1})
    assert get_in(read_full_by_id, [planned_slice.id, "goal"]) == "Expose scoped read-only WorkRequest MCP payloads."
    assert get_in(read_full_by_id, [planned_slice.id, "operational_state", "key"]) == "blocked"
    assert Map.has_key?(read_full_by_id, scratch_slice.id)
    assert read_full_text =~ "agent_context: work_request_product_tree"
    assert read_full_text =~ "nodes_with_slices"

    direct_response =
      mcp_tool(repo, session, "move_slice_to_plan_node", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "product_tree_node_id" => ""
      })

    direct_payload = get_in(direct_response, ["result", "structuredContent"])

    assert direct_payload["product_tree_slice_link"] == nil
    assert get_in(direct_payload, ["status", "slice_product_tree_location"]) == "direct"
    refute Map.has_key?(direct_payload, "product_tree")

    direct_read_response =
      mcp_tool(repo, session, "read_plan", %{
        "work_request_id" => work_request.id,
        "view" => "nodes_with_slice_refs"
      })

    assert get_in(direct_read_response, ["result", "structuredContent", "product_tree", "root_slice_ids"]) == [planned_slice.id]
  end

  test "architect WorkRequest product tree tools require authoring status", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-PRODUCT-TREE-STATUS", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-PRODUCT-TREE-STATUS",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-WR-PRODUCT-TREE-STATUS", target_base_branch: work_request.base_branch)
             )

    assert {:ok, product_node} =
             ProductTree.create_node(repo, %{
               work_request_id: work_request.id,
               title: "Locked product plan"
             })

    assert {:ok, _clarifying} = WorkRequestRepository.update_status(repo, work_request.id, "ready_for_slicing", "clarifying")

    upsert_response =
      mcp_tool(repo, session, "upsert_plan_node", %{
        "work_request_id" => work_request.id,
        "title" => "Should not be accepted"
      })

    move_response =
      mcp_tool(repo, session, "move_slice_to_plan_node", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "product_tree_node_id" => product_node.id
      })

    assert get_in(upsert_response, ["error", "data", "reason"]) == "invalid_status"
    assert get_in(move_response, ["error", "data", "reason"]) == "invalid_status"
  end

  test "architect WorkRequest planned-slice tools allow delivery base different from WorkRequest base", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-DELIVERY-BASE", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-DELIVERY-BASE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    delivery_base = "feature/integration-base"

    add_response =
      mcp_tool(repo, session, "plan_slice", %{
        "work_request_id" => work_request.id,
        "title" => "Integration branch delivery",
        "goal" => "Prepare a worker from a delivery base different from the parent WorkRequest base.",
        "work_package_kind" => "mcp",
        "target_base_branch" => delivery_base,
        "owned_file_globs" => ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
        "forbidden_file_globs" => [],
        "acceptance_criteria" => ["Delivery base is preserved on the planned slice."],
        "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp"],
        "review_lanes" => ["normal"],
        "stop_conditions" => ["Stop before unrelated scope."]
      })

    add_payload = get_in(add_response, ["result", "structuredContent"])

    assert add_payload["scope"] == %{"repo" => anchor.repo, "base_branch" => anchor.base_branch}
    assert get_in(add_payload, ["planned_slice", "target_base_branch"]) == delivery_base
    assert {:ok, detail} = Dashboard.work_request_detail(repo, work_request.id)
    assert detail.product_tree.latest_revision.revision_number == 1

    assert [revision] =
             Revision
             |> repo.all()
             |> Enum.filter(&(&1.work_request_id == work_request.id))

    refute Map.has_key?(revision.tree_snapshot, "latest_revision")
    assert {:ok, [planned_slice]} = WorkRequestRepository.list_planned_slices(repo, work_request.id)
    assert planned_slice.target_base_branch == delivery_base
  end

  test "core WorkRequest slice mutations tolerate ledgers before product-tree schema migration", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-PRE-V3", [
        "write:work_request",
        "read:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-PRE-V3",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)
    drop_product_tree_tables!(repo)
    on_exit(fn -> assert :ok = WorkPackageRepository.migrate(repo) end)
    refute table_exists?(repo, "sympp_product_tree_nodes")

    add_response =
      mcp_tool(repo, session, "plan_slice", %{
        "work_request_id" => work_request.id,
        "title" => "Pre-V3 planned slice",
        "goal" => "Keep core WorkRequest planning usable before product-tree migration.",
        "work_package_kind" => "mcp",
        "target_base_branch" => anchor.base_branch,
        "owned_file_globs" => ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
        "forbidden_file_globs" => [],
        "acceptance_criteria" => ["Slice creation still succeeds."],
        "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp"],
        "review_lanes" => ["normal"],
        "stop_conditions" => ["Stop before dispatch."]
      })

    add_payload = get_in(add_response, ["result", "structuredContent"])
    planned_slice_id = get_in(add_payload, ["planned_slice", "id"])

    assert is_binary(planned_slice_id)
    assert get_in(add_payload, ["planned_slice", "status"]) == "planned"

    approve_response =
      mcp_tool(repo, session, "approve_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice_id,
        "current_status" => "planned"
      })

    assert get_in(approve_response, ["result", "structuredContent", "planned_slice", "status"]) == "approved"

    assert {:ok, persisted_slice} = WorkRequestRepository.get_planned_slice(repo, work_request.id, planned_slice_id)
    assert persisted_slice.status == "approved"
  end

  test "WorkRequest MCP planned-slice validation rejects unsupported globstar at add and approve", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-GLOBSTAR", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-GLOBSTAR",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing",
        constraints: %{"allowed_paths" => ["scripts", "elixir/lib"], "requires_secret" => false}
      )

    grant_work_request_scope!(repo, session, work_request.id)

    add_args = %{
      "work_request_id" => work_request.id,
      "title" => "Invalid globstar slice",
      "goal" => "Reject invalid globstar placement before dispatch.",
      "work_package_kind" => "mcp",
      "target_base_branch" => anchor.base_branch,
      "owned_file_globs" => ["scripts/**deploy**"],
      "forbidden_file_globs" => [],
      "acceptance_criteria" => ["Invalid globstar placement is rejected early."],
      "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp"],
      "review_lanes" => ["normal"],
      "stop_conditions" => ["Stop before dispatch."]
    }

    add_response = mcp_tool(repo, session, "plan_slice", add_args)

    assert get_in(add_response, ["error", "code"]) == -32_602
    assert get_in(add_response, ["error", "data", "reason"]) == "planned_slice_scope_violation"

    assert get_in(add_response, ["error", "data", "validation_errors"]) == [
             %{"field" => "owned_file_globs", "value" => "scripts/**deploy**", "reason" => "unsupported_globstar"}
           ]

    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, Map.delete(add_args, "work_request_id"))

    approve_response =
      mcp_tool(repo, session, "approve_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "current_status" => "planned"
      })

    assert get_in(approve_response, ["error", "code"]) == -32_602
    assert get_in(approve_response, ["error", "data", "reason"]) == "planned_slice_scope_violation"

    assert get_in(approve_response, ["error", "data", "validation_errors"]) == [
             %{"field" => "owned_file_globs", "value" => "scripts/**deploy**", "reason" => "unsupported_globstar"}
           ]

    assert {:ok, persisted_slice} = WorkRequestRepository.get_planned_slice(repo, work_request.id, planned_slice.id)
    assert persisted_slice.status == "planned"
  end

  defp drop_product_tree_tables!(repo) do
    repo.query!("DELETE FROM schema_migrations WHERE version = ?", [20_260_604_123_000])

    Enum.each(
      [
        "sympp_product_tree_dependency_edges",
        "sympp_product_tree_slice_links",
        "sympp_product_tree_revisions",
        "sympp_product_tree_nodes"
      ],
      &repo.query!("DROP TABLE IF EXISTS #{&1}")
    )
  end

  defp typed_delivery_evidence(_repo, _work_request, "pr_merged", _suffix), do: pr_merged_delivery_evidence(291)

  defp typed_delivery_evidence(_repo, _work_request, "completed_no_pr", _suffix) do
    %{"completed_no_pr" => %{"no_pr_evidence" => "Operator confirmed this completed without a PR."}}
  end

  defp typed_delivery_evidence(repo, work_request, "superseded", suffix) do
    assert {:ok, successor} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-DELIVERY-SUCCESSOR-#{suffix}",
                 target_base_branch: work_request.base_branch
               )
             )

    assert {:ok, approved_successor} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, successor.id, "planned")

    successor_work_package =
      [
        id: "WP-MCP-DELIVERY-SUCCESSOR-#{suffix}",
        title: approved_successor.title,
        kind: approved_successor.work_package_kind,
        repo: work_request.repo,
        base_branch: approved_successor.target_base_branch,
        branch_pattern: approved_successor.branch_pattern,
        product_description: work_request.human_description,
        allowed_file_globs: approved_successor.owned_file_globs,
        acceptance_criteria: approved_successor.acceptance_criteria,
        status: "ready_for_worker"
      ]
      |> WorkPackageFactory.attrs()
      |> then(&WorkPackageRepository.create(repo, &1))
      |> case do
        {:ok, work_package} -> work_package
        {:error, reason} -> flunk("failed to create successor WorkPackage: #{inspect(reason)}")
      end

    assert {:ok, dispatched_successor} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_successor.id, "approved", successor_work_package.id)

    %{
      "superseded" => %{
        "successor_planned_slice_id" => dispatched_successor.id,
        "successor_work_package_id" => successor_work_package.id,
        "superseded_reason" => "Recut into a narrower planned slice."
      }
    }
  end

  defp typed_delivery_evidence(_repo, _work_request, "abandoned", _suffix) do
    %{"abandoned" => %{"abandoned_rationale" => "No code was produced and the slice is abandoned."}}
  end

  defp pr_merged_delivery_evidence(number) do
    %{
      "pr_merged" => %{
        "pr_url" => "https://github.com/nextide/symphony-plus-plus/pull/#{number}",
        "pr_number" => number,
        "pr_repository" => "nextide/symphony-plus-plus",
        "pr_merged_at" => "2026-06-07T10:00:00Z",
        "merge_commit_sha" => "abc#{number}"
      }
    }
  end

  defp linked_delivery_slice!(repo, opts) do
    suffix = Keyword.fetch!(opts, :id_suffix)
    package_status = Keyword.fetch!(opts, :package_status)

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-BLOCKER-CLOSEOUT-#{suffix}",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-BLOCKER-CLOSEOUT-#{suffix}",
                 target_base_branch: work_request.base_branch,
                 branch_pattern: "agent/blocker-closeout-#{String.downcase(suffix)}"
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    work_package =
      [
        id: "WP-MCP-BLOCKER-CLOSEOUT-#{suffix}",
        title: approved_slice.title,
        kind: approved_slice.work_package_kind,
        repo: work_request.repo,
        base_branch: approved_slice.target_base_branch,
        branch_pattern: approved_slice.branch_pattern,
        product_description: work_request.human_description,
        allowed_file_globs: approved_slice.owned_file_globs,
        acceptance_criteria: approved_slice.acceptance_criteria,
        status: package_status
      ]
      |> WorkPackageFactory.attrs()
      |> then(&WorkPackageRepository.create(repo, &1))
      |> case do
        {:ok, work_package} -> work_package
        {:error, reason} -> flunk("failed to create WorkPackage: #{inspect(reason)}")
      end

    assert {:ok, dispatched_slice} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", work_package.id)

    {work_request, dispatched_slice, work_package}
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

  defp resolve_blocker_events(progress_events, blocker_id) do
    Enum.filter(progress_events, &(get_in(&1.payload, ["source_tool"]) == "resolve_blocker" and get_in(&1.payload, ["blocker_id"]) == blocker_id))
  end

  defp table_exists?(repo, table) do
    %{rows: rows} = repo.query!("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [table])
    rows != []
  end

  defp legacy_handoff_session_without_repo_scope!(repo, session, grant) do
    legacy_handoff_session_with_scope_fields!(repo, session, grant, nil, nil)
  end

  defp legacy_handoff_session_with_scope_fields!(repo, session, grant, scope_repo, scope_base_branch) do
    repo.update_all(
      from(access_grant in AccessGrant, where: access_grant.id == ^grant.id),
      set: [scope_repo: scope_repo, scope_base_branch: scope_base_branch]
    )

    remove_grant_scope_type!(repo, session, "repo")

    %{
      session
      | assignment: %{
          session.assignment
          | scopes: Enum.reject(session.assignment.scopes, &match?(%Scope{type: :repo}, &1))
        }
    }
  end
end
