Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestTools02Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Node
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository

  test "record_work_package_delivery accepts typed evidence for each outcome and rejects conflicts", %{repo: repo} do
    cases = [
      {"TYPED-PR", "ready_for_merge", "pr_merged", "merged"},
      {"TYPED-NO-PR", "reviewing", "completed_no_pr", "closed"},
      {"TYPED-SUPERSEDED", "ready_for_worker", "superseded", "closed"},
      {"TYPED-ABANDONED", "ready_for_worker", "abandoned", "abandoned"}
    ]

    for {suffix, package_status, outcome, expected_package_status} <- cases do
      {work_request, work_package, work_package} =
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
        mcp_tool(repo, session, "record_work_package_delivery", %{
          "work_request_id" => work_request.id,
          "work_package_id" => work_package.id,
          "outcome" => outcome,
          "idempotency_key" => "typed-delivery-#{String.downcase(suffix)}",
          "evidence" => evidence
        })

      assert get_in(response, ["result", "structuredContent", "work_package_delivery", "outcome"]) == outcome

      if outcome == "superseded" do
        assert get_in(response, ["result", "structuredContent", "work_package_delivery", "successor_work_package_id"]) ==
                 get_in(evidence, ["superseded", "successor_work_package_id"])
      end

      assert repo.get!(WorkPackage, work_package.id).status == expected_package_status
    end

    {work_request, work_package, _work_package} =
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
      mcp_tool(repo, session, "record_work_package_delivery", %{
        "work_request_id" => work_request.id,
        "work_package_id" => work_package.id,
        "outcome" => "pr_merged",
        "idempotency_key" => "typed-delivery-mismatch",
        "evidence" => %{
          "completed_no_pr" => %{"no_pr_evidence" => "Wrong typed evidence for this outcome."}
        }
      })

    assert get_in(mismatch_response, ["error", "data", "reason"]) == "conflicting_delivery_evidence"

    invalid_outcome_response =
      mcp_tool(repo, session, "record_work_package_delivery", %{
        "work_request_id" => work_request.id,
        "work_package_id" => work_package.id,
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
      mcp_tool(repo, session, "cleanup_work_request_work_package_runtime", %{
        "work_request_id" => work_request.id,
        "work_package_id" => work_package.id,
        "outcome" => "superseded",
        "reason" => "cleanup stale runtime"
      })

    assert get_in(invalid_cleanup_evidence_response, ["error", "data", "reason"]) == "invalid_delivery_evidence"

    cleanup_errors = get_in(invalid_cleanup_evidence_response, ["error", "data", "validation_errors"])

    assert %{
             "field" => "successor_work_package_id",
             "message" => "can't be blank",
             "reason" => "required"
           } = Enum.find(cleanup_errors, &(&1["field"] == "successor_work_package_id"))

    assert %{
             "field" => "superseded_reason",
             "message" => "can't be blank",
             "reason" => "required"
           } = Enum.find(cleanup_errors, &(&1["field"] == "superseded_reason"))

    flat_response =
      mcp_tool(repo, session, "record_work_package_delivery", %{
        "work_request_id" => work_request.id,
        "work_package_id" => work_package.id,
        "outcome" => "pr_merged",
        "idempotency_key" => "typed-delivery-flat-conflict",
        "pr_url" => "https://github.com/nextide/symphony-plus-plus/pull/301",
        "evidence" => pr_merged_delivery_evidence(301)
      })

    assert get_in(flat_response, ["error", "data", "reason"]) == "unexpected_argument"

    extra_field_response =
      mcp_tool(repo, session, "record_work_package_delivery", %{
        "work_request_id" => work_request.id,
        "work_package_id" => work_package.id,
        "outcome" => "pr_merged",
        "idempotency_key" => "typed-delivery-extra-field",
        "evidence" => %{
          "pr_merged" => Map.put(pr_merged_delivery_evidence(302)["pr_merged"], "no_pr_evidence", "Not PR evidence.")
        }
      })

    assert get_in(extra_field_response, ["error", "data", "reason"]) == "invalid_evidence"
  end

  test "Group and dependency tools expose the atomic public graph contract", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-GROUP-CONTRACT", [
        "read:work_request",
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-GROUP-CONTRACT",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    parent_response =
      mcp_tool(repo, session, "upsert_group", %{
        "work_request_id" => work_request.id,
        "title" => "Parent Group",
        "kind" => "capability"
      })

    parent_group_id = get_in(parent_response, ["result", "structuredContent", "group", "id"])
    assert is_binary(parent_group_id)

    child_response =
      mcp_tool(repo, session, "upsert_group", %{
        "work_request_id" => work_request.id,
        "title" => "Child Group",
        "description" => "Temporary description",
        "parent_group_id" => parent_group_id,
        "position" => 2
      })

    child_group_id = get_in(child_response, ["result", "structuredContent", "group", "id"])

    moved_response =
      mcp_tool(repo, session, "upsert_group", %{
        "work_request_id" => work_request.id,
        "group_id" => child_group_id,
        "title" => "Renamed Group",
        "description" => nil,
        "parent_group_id" => nil,
        "position" => 1
      })

    assert get_in(moved_response, ["result", "structuredContent", "group", "id"]) == child_group_id
    assert get_in(moved_response, ["result", "structuredContent", "group", "position"]) == 1
    assert get_in(moved_response, ["result", "structuredContent", "group", "description"]) == nil

    dependency_response =
      mcp_tool(repo, session, "upsert_dependency", %{
        "work_request_id" => work_request.id,
        "dependent" => %{"kind" => "group", "id" => child_group_id},
        "prerequisite" => %{"kind" => "group", "id" => parent_group_id},
        "reason" => "The parent capability lands first."
      })

    dependency = get_in(dependency_response, ["result", "structuredContent", "dependency"])
    upsert_revision = get_in(dependency_response, ["result", "structuredContent", "product_tree_revision"])
    assert dependency["dependent"] == %{"kind" => "group", "id" => child_group_id}
    assert dependency["prerequisite"] == %{"kind" => "group", "id" => parent_group_id}
    assert is_integer(upsert_revision["revision_number"])

    self_dependency_response =
      mcp_tool(repo, session, "upsert_dependency", %{
        "work_request_id" => work_request.id,
        "dependency_id" => dependency["id"],
        "dependent" => %{"kind" => "group", "id" => parent_group_id},
        "prerequisite" => %{"kind" => "group", "id" => parent_group_id},
        "reason" => "Invalid self-dependency."
      })

    assert get_in(self_dependency_response, ["error", "data", "reason"]) == "invalid_dependency"

    stale_dependency_response =
      mcp_tool(repo, session, "upsert_dependency", %{
        "work_request_id" => work_request.id,
        "dependency_id" => "missing-dependency",
        "dependent" => %{"kind" => "group", "id" => child_group_id},
        "prerequisite" => %{"kind" => "group", "id" => parent_group_id},
        "reason" => "This stale update must not create a new dependency."
      })

    assert get_in(stale_dependency_response, ["error", "data", "reason"]) == "not_found"

    delete_dependency_response =
      mcp_tool(repo, session, "delete_dependency", %{
        "work_request_id" => work_request.id,
        "dependency_id" => dependency["id"]
      })

    assert get_in(delete_dependency_response, ["result", "structuredContent", "deleted", "id"]) == dependency["id"]

    assert get_in(delete_dependency_response, ["result", "structuredContent", "product_tree_revision", "revision_number"]) ==
             upsert_revision["revision_number"] + 1

    read_response =
      mcp_tool(repo, session, "read_plan", %{
        "work_request_id" => work_request.id,
        "view" => "groups_with_work_package_refs"
      })

    product_tree = get_in(read_response, ["result", "structuredContent", "product_tree"])
    assert product_tree["schema_version"] == "product_tree.v4"
    assert Enum.map(product_tree["groups"], & &1["id"]) |> Enum.sort() == Enum.sort([parent_group_id, child_group_id])
    assert Enum.find(product_tree["groups"], &(&1["id"] == child_group_id))["title"] == "Renamed Group"
    assert Enum.find(product_tree["groups"], &(&1["id"] == child_group_id))["parent_group_id"] == nil
    assert Enum.find(product_tree["groups"], &(&1["id"] == child_group_id))["description"] == nil
    refute Enum.find(product_tree["groups"], &(&1["id"] == child_group_id)) |> Map.has_key?("completion_mark")
    assert product_tree["dependency_intents"] == []
    assert product_tree["execution_graph"]["effective_edges"] == []
    refute Map.has_key?(product_tree, "nodes")
  end

  test "record_work_package_delivery clears active blocker residue", %{repo: repo} do
    {work_request, work_package, work_package} =
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

    response =
      mcp_tool(repo, session, "record_work_package_delivery", %{
        "work_request_id" => work_request.id,
        "work_package_id" => work_package.id,
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

    assert get_in(response, ["result", "structuredContent", "work_package_delivery", "outcome"]) == "pr_merged"
    refute get_in(response, ["result", "structuredContent"]) |> Map.has_key?("blocker_closeout")
    assert repo.get!(WorkPackage, work_package.id).status == "merged"

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, work_package.id)
    refute Enum.any?(BlockerProjection.blockers(progress_events), & &1.active)
    assert Enum.any?(progress_events, &(get_in(&1.payload, ["source_tool"]) == "resolve_blocker" and get_in(&1.payload, ["blocker_id"]) == "preserve-blocker"))
  end

  test "deleting a Group ungroups its direct contents and removes its dependencies", %{repo: repo} do
    {work_request, work_package, work_package} =
      linked_delivery_slice!(repo,
        id_suffix: "DELETE-GROUP",
        package_status: "planned"
      )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, work_request, [
        "read:work_request",
        "write:work_request",
        "dispatch:work_request"
      ])

    parent_response =
      mcp_tool(repo, session, "upsert_group", %{
        "work_request_id" => work_request.id,
        "title" => "Parent Group"
      })

    parent_group_id = get_in(parent_response, ["result", "structuredContent", "group", "id"])

    deleted_group_response =
      mcp_tool(repo, session, "upsert_group", %{
        "work_request_id" => work_request.id,
        "title" => "Temporary Group",
        "parent_group_id" => parent_group_id
      })

    deleted_group_id = get_in(deleted_group_response, ["result", "structuredContent", "group", "id"])

    child_response =
      mcp_tool(repo, session, "upsert_group", %{
        "work_request_id" => work_request.id,
        "title" => "Preserved Child Group",
        "parent_group_id" => deleted_group_id
      })

    child_group_id = get_in(child_response, ["result", "structuredContent", "group", "id"])
    child_before_delete = repo.get!(Node, child_group_id)

    prerequisite_response =
      mcp_tool(repo, session, "upsert_group", %{
        "work_request_id" => work_request.id,
        "title" => "Prerequisite Group"
      })

    prerequisite_group_id = get_in(prerequisite_response, ["result", "structuredContent", "group", "id"])

    move_response =
      mcp_tool(repo, session, "update_work_package", %{
        "work_request_id" => work_request.id,
        "work_package_id" => work_package.id,
        "expected_contract_revision" => work_package.contract_revision,
        "patch" => %{"group_id" => deleted_group_id}
      })

    assert get_in(move_response, ["result", "structuredContent", "work_package_id"]) == work_package.id

    dependency_response =
      mcp_tool(repo, session, "upsert_dependency", %{
        "work_request_id" => work_request.id,
        "dependent" => %{"kind" => "group", "id" => deleted_group_id},
        "prerequisite" => %{"kind" => "group", "id" => prerequisite_group_id},
        "reason" => "Temporary Group depends on the prerequisite."
      })

    assert is_binary(get_in(dependency_response, ["result", "structuredContent", "dependency", "id"]))
    contract_revision_before_delete = repo.get!(WorkPackage, work_package.id).contract_revision

    delete_response =
      mcp_tool(repo, session, "delete_group", %{
        "work_request_id" => work_request.id,
        "group_id" => deleted_group_id
      })

    assert get_in(delete_response, ["result", "structuredContent", "deleted"]) == %{
             "group_id" => deleted_group_id,
             "moved_group_count" => 1,
             "moved_work_package_count" => 1,
             "parent_group_id" => parent_group_id,
             "removed_dependency_count" => 1
           }

    read_response =
      mcp_tool(repo, session, "read_plan", %{
        "work_request_id" => work_request.id,
        "view" => "groups_with_work_package_refs"
      })

    product_tree = get_in(read_response, ["result", "structuredContent", "product_tree"])
    refute Enum.any?(product_tree["groups"], &(&1["id"] == deleted_group_id))
    assert Enum.find(product_tree["groups"], &(&1["id"] == child_group_id))["parent_group_id"] == parent_group_id
    assert DateTime.after?(repo.get!(Node, child_group_id).updated_at, child_before_delete.updated_at)
    assert product_tree["dependency_intents"] == []
    ungrouped_work_package = repo.get!(WorkPackage, work_package.id)
    assert ungrouped_work_package.product_tree_node_id == parent_group_id
    assert ungrouped_work_package.contract_revision == contract_revision_before_delete + 1
    assert Enum.find(product_tree["groups"], &(&1["id"] == parent_group_id))["work_package_ids"] == [work_package.id]
    assert product_tree["root_work_package_ids"] == []
    assert [%{"group_id" => ^parent_group_id, "id" => work_package_id}] = product_tree["work_package_refs"]
    assert work_package_id == work_package.id
  end

  test "dispatch reports exact unmet prerequisites from the public execution graph", %{repo: repo} do
    {work_request, dependent, dependent} =
      linked_delivery_slice!(repo,
        id_suffix: "GRAPH-DISPATCH",
        package_status: "planned"
      )

    assert {:ok, prerequisite} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(
                 id: "WP-MCP-GRAPH-DISPATCH-PREREQUISITE",
                 base_branch: work_request.base_branch,
                 branch_pattern: "agent/graph-dispatch-prerequisite",
                 status: "planned"
               )
             )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, work_request, [
        "read:work_request",
        "write:work_request",
        "dispatch:work_request"
      ])

    dependency_response =
      mcp_tool(repo, session, "upsert_dependency", %{
        "work_request_id" => work_request.id,
        "dependent" => %{"kind" => "work_package", "id" => dependent.id},
        "prerequisite" => %{"kind" => "work_package", "id" => prerequisite.id},
        "reason" => "The shared contract must land first."
      })

    assert is_binary(get_in(dependency_response, ["result", "structuredContent", "dependency", "id"]))
    assert {:ok, _work_request} = WorkRequestRepository.update_status(repo, work_request.id, "ready_for_slicing", "sliced")

    dispatch_response =
      mcp_tool(repo, session, "dispatch_work_package", %{
        "work_request_id" => work_request.id,
        "work_package_id" => dependent.id
      })

    assert get_in(dispatch_response, ["error", "message"]) ==
             "WorkPackage #{dependent.id} has unmet dependencies: #{prerequisite.id}"

    assert get_in(dispatch_response, ["error", "data"]) == %{
             "prerequisite_work_package_ids" => [prerequisite.id],
             "reason" => "unmet_work_package_dependencies",
             "remediation" => "Complete or skip the prerequisite WorkPackages, then retry dispatch_work_package for WorkPackage #{dependent.id}.",
             "tool" => "dispatch_work_package",
             "work_package_id" => dependent.id
           }

    assert repo.get!(WorkPackage, dependent.id).status == "planned"
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
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               equivalent_sibling.id,
               work_request_work_package_attrs(id: "WRS-MCP-WR-LEGACY-HANDOFF-SIBLING", base_branch: equivalent_sibling.base_branch)
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

    sibling_update_response =
      mcp_tool(repo, session, "update_work_package", %{
        "work_request_id" => equivalent_sibling.id,
        "work_package_id" => sibling_slice.id,
        "expected_contract_revision" => sibling_slice.contract_revision,
        "patch" => %{"title" => "Out of scope"}
      })

    assert get_in(sibling_update_response, ["error", "code"]) == -32_004
    assert get_in(sibling_update_response, ["error", "data", "reason"]) == "not_found"

    assert {:ok, persisted_sibling} = WorkRequestRepository.get(repo, equivalent_sibling.id)
    assert persisted_sibling.status == "ready_for_slicing"
    assert {:ok, [persisted_sibling_slice]} = WorkRequestRepository.list_work_packages(repo, equivalent_sibling.id)
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

  defp typed_delivery_evidence(_repo, _work_request, "pr_merged", _suffix), do: pr_merged_delivery_evidence(291)

  defp typed_delivery_evidence(_repo, _work_request, "completed_no_pr", _suffix) do
    %{"completed_no_pr" => %{"no_pr_evidence" => "Operator confirmed this completed without a PR."}}
  end

  defp typed_delivery_evidence(repo, work_request, "superseded", suffix) do
    assert {:ok, successor_work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(
                 id: "WP-MCP-DELIVERY-SUCCESSOR-#{suffix}",
                 base_branch: work_request.base_branch,
                 status: "ready_for_worker",
                 dispatched_at: DateTime.utc_now(:microsecond)
               )
             )

    %{
      "superseded" => %{
        "successor_work_package_id" => successor_work_package.id,
        "superseded_reason" => "Recut into a narrower WorkPackage."
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

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(
                 id: "WP-MCP-BLOCKER-CLOSEOUT-#{suffix}",
                 base_branch: work_request.base_branch,
                 branch_pattern: "agent/blocker-closeout-#{String.downcase(suffix)}",
                 status: package_status,
                 dispatched_at: DateTime.utc_now(:microsecond)
               )
             )

    {work_request, work_package, work_package}
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
