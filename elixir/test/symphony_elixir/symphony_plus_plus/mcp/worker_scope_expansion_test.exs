Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerScopeExpansionTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "scope guard uses current-head changed-file paths from sync_pr when a later sync omits file paths", %{repo: repo} do
    changed_paths = [
      "implementation_docs_symphplusplus/README.md",
      "implementation_docs_symphplusplus/docs/01_IMPLEMENTATION_GUIDE.md",
      "implementation_docs_symphplusplus/docs/02_SYSTEM_SPEC.md",
      "implementation_docs_symphplusplus/docs/07_DASHBOARD_SPEC.md",
      "implementation_docs_symphplusplus/docs/09_OPERATIONAL_RUNBOOK.md",
      "implementation_docs_symphplusplus/docs/12_OPERATOR_TRAINING.md",
      "implementation_docs_symphplusplus/docs/13_WORKREQUEST_CONTRACT.md"
    ]

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-GUARD-SYNC-PR",
                 kind: "mcp",
                 repo: "Pimpmuckl/symphony-plus-plus",
                 base_branch: "main",
                 status: "ci_waiting",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: changed_paths
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    head_sha = "scope-docs-head-a"
    pr_url = "https://github.com/Pimpmuckl/symphony-plus-plus/pull/61"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-V2-PRODUCT-001/workrequest-contract", "head_sha" => head_sha})
    attach_tool(repo, session, "attach_pr", %{"url" => pr_url, "head_sha" => head_sha})

    path_sync_response =
      attach_tool(repo, session, "sync_pr", %{
        "url" => pr_url,
        "metadata" => %{
          "head_sha" => head_sha,
          "base" => %{"ref" => "main", "sha" => "base-pr61"},
          "changed_files" => Enum.map(changed_paths, &%{"filename" => &1, "status" => "modified"}),
          "changed_files_count" => length(changed_paths),
          "check_summary" => %{"conclusion" => "success"},
          "review_state" => %{"state" => "approved"},
          "merge_state" => %{"state" => "clean"}
        }
      })

    path_sync_payload = response_progress_payload(repo, path_sync_response)
    assert path_sync_payload["changed_files_available"] == true
    assert path_sync_payload["changed_files_count"] == 7
    assert length(path_sync_payload["changed_files"]) == 7

    count_only_sync_response =
      attach_tool(repo, session, "sync_pr", %{
        "url" => pr_url,
        "metadata" => %{
          "head_sha" => head_sha,
          "base" => %{"ref" => "main", "sha" => "base-pr61"},
          "changed_files" => 7,
          "check_summary" => %{"conclusion" => "success"},
          "review_state" => %{"state" => "approved"},
          "merge_state" => %{"state" => "clean"}
        }
      })

    count_only_payload = response_progress_payload(repo, count_only_sync_response)
    assert count_only_payload["changed_files_available"] == false
    assert count_only_payload["changed_files_count"] == 7

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    attach_tool(repo, session, "attach_review_suite_result", %{
      "work_package_id" => package.id,
      "head_sha" => head_sha,
      "suite" => "review-suite",
      "anchor" => "phase_gate-scope-docs-head-a",
      "summary" => "normal is green",
      "status" => "passed",
      "verdict" => "green"
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-doc-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "architect approval repairs overbroad existing scope constraints", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-GUARD-REPAIR",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: ["**"]
               )
             )

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["approve:scope_expansion"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    architect_session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    approval_response =
      attach_tool(repo, architect_session, "approve_scope_expansion", %{
        "work_package_id" => package.id,
        "allowed_file_globs" => ["docs/**"],
        "rationale" => "Replace invalid catch-all with scoped package docs."
      })

    assert get_in(approval_response, ["result", "structuredContent", "allowed_file_globs"]) == ["docs/**"]
    event_id = get_in(approval_response, ["result", "structuredContent", "progress_event", "id"])
    refute Map.has_key?(get_in(approval_response, ["result", "structuredContent", "progress_event"]), "payload")
    payload = repo.get!(ProgressEvent, event_id).payload
    assert payload["previous_allowed_file_globs"] == ["**"]
    assert payload["allowed_file_globs"] == ["docs/**"]

    assert {:ok, repaired_package} = WorkPackageRepository.get(repo, package.id)
    assert repaired_package.allowed_file_globs == ["docs/**"]
  end

  test "direct package architect still needs scope approval capability", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-GUARD-DIRECT-WRITE-DENIED",
                 kind: "mcp",
                 status: "blocked",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: ["elixir/lib/**"]
               )
             )

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["read:phase", "write:work_request"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    architect_session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    approval_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "direct-write-scope-approval-denied",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => package.id,
              "allowed_file_globs" => ["docs/**"],
              "rationale" => "Direct package write is not approval authority."
            }
          }
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(approval_response, ["error", "data", "reason"]) == "insufficient_capability"

    assert {:ok, unchanged_package} = WorkPackageRepository.get(repo, package.id)
    assert unchanged_package.allowed_file_globs == ["elixir/lib/**"]
  end

  test "explicit phase scope approval cannot approve sibling package expansion", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-SCOPE-EXPANSION-SIBLING-DENIED",
        status: "ready_for_slicing",
        constraints: %{"allowed_paths" => ["elixir/lib", "docs"], "requires_secret" => false}
      )

    assert {:ok, anchor_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-EXPANSION-PHASE-ANCHOR",
                 kind: "mcp",
                 repo: work_request.repo,
                 base_branch: work_request.base_branch,
                 status: "blocked",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: ["elixir/lib/**"]
               )
             )

    assert {:ok, architect_work_key} = create_architect_work_key(repo, anchor_package.id, ["read:phase", "approve:scope_expansion"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    architect_session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-SCOPE-EXPANSION-SIBLING-DENIED",
                 target_base_branch: work_request.base_branch,
                 owned_file_globs: ["elixir/lib/**"]
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    assert {:ok, target_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-EXPANSION-SIBLING-DENIED",
                 title: approved_slice.title,
                 kind: approved_slice.work_package_kind,
                 repo: work_request.repo,
                 base_branch: approved_slice.target_base_branch,
                 branch_pattern: approved_slice.branch_pattern,
                 product_description: work_request.human_description,
                 status: "blocked",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: approved_slice.owned_file_globs,
                 acceptance_criteria: approved_slice.acceptance_criteria
               )
             )

    assert {:ok, _dispatched_slice} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", target_package.id)

    approval_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "phase-scope-sibling-approval-denied",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => target_package.id,
              "allowed_file_globs" => ["docs/**"],
              "rationale" => "Package-scoped approval keys must not mutate sibling packages."
            }
          }
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(approval_response, ["error", "data", "reason"]) == "outside_session_scope"

    assert {:ok, unchanged_package} = WorkPackageRepository.get(repo, target_package.id)
    assert unchanged_package.allowed_file_globs == ["elixir/lib/**"]
  end

  test "direct package architect approval repairs linked WorkRequest scope", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-SCOPE-EXPANSION-DIRECT-LINKED",
        status: "ready_for_slicing",
        constraints: %{"allowed_paths" => ["elixir/lib", "docs"], "requires_secret" => false}
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-SCOPE-EXPANSION-DIRECT-LINKED",
                 target_base_branch: work_request.base_branch,
                 owned_file_globs: ["elixir/lib/**"]
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-EXPANSION-DIRECT-LINKED",
                 title: approved_slice.title,
                 kind: approved_slice.work_package_kind,
                 repo: work_request.repo,
                 base_branch: approved_slice.target_base_branch,
                 branch_pattern: approved_slice.branch_pattern,
                 product_description: work_request.human_description,
                 status: "blocked",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: approved_slice.owned_file_globs,
                 acceptance_criteria: approved_slice.acceptance_criteria
               )
             )

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["approve:scope_expansion"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    architect_session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    assert {:ok, _dispatched_slice} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", package.id)

    assert {:ok, duplicate_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-SCOPE-EXPANSION-DIRECT-LINKED-DUPLICATE",
                 target_base_branch: work_request.base_branch,
                 owned_file_globs: ["elixir/lib/**"]
               )
             )

    assert {:ok, approved_duplicate_slice} =
             WorkRequestRepository.approve_planned_slice(repo, work_request.id, duplicate_slice.id, "planned")

    drop_planned_slice_work_package_unique_index!(repo)

    ExUnit.Callbacks.on_exit(fn ->
      repo.query!(
        "UPDATE sympp_work_request_planned_slices SET work_package_id = NULL, dispatched_at = NULL WHERE id = ?",
        [approved_duplicate_slice.id]
      )

      create_planned_slice_work_package_unique_index!(repo)
    end)

    repo.update!(
      Ecto.Changeset.change(approved_duplicate_slice,
        status: "dispatched",
        work_package_id: package.id,
        dispatched_at: DateTime.utc_now(:microsecond)
      )
    )

    assert {:ok, _stale_package} = WorkPackageRepository.update(repo, package.id, %{"allowed_file_globs" => ["src/**", "elixir/lib/**"]})

    approval_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "direct-linked-scope-expansion-outside-request",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => package.id,
              "allowed_file_globs" => ["src/**"],
              "rationale" => "Direct approvals for WorkRequest packages stay inside the WorkRequest."
            }
          }
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(approval_response, ["error", "data", "reason"]) == "scope_expansion_outside_work_request"

    assert {:ok, rejected_package} = WorkPackageRepository.get(repo, package.id)
    assert rejected_package.allowed_file_globs == ["src/**", "elixir/lib/**"]

    repair_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "direct-linked-scope-expansion-repair",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => package.id,
              "allowed_file_globs" => ["docs/**"],
              "rationale" => "Valid approval should drop stale scope outside the WorkRequest."
            }
          }
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(repair_response, ["result", "structuredContent", "allowed_file_globs"]) == ["elixir/lib/**", "docs/**"]

    assert {:ok, repaired_package} = WorkPackageRepository.get(repo, package.id)
    assert repaired_package.allowed_file_globs == ["elixir/lib/**", "docs/**"]
  end

  test "direct package architect approval fails closed for cross-WorkRequest duplicate links", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-SCOPE-EXPANSION-CROSS-LINK",
        status: "ready_for_slicing",
        constraints: %{"allowed_paths" => ["elixir/lib", "docs"], "requires_secret" => false}
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-SCOPE-EXPANSION-CROSS-LINK",
                 target_base_branch: work_request.base_branch,
                 owned_file_globs: ["elixir/lib/**"]
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-EXPANSION-CROSS-LINK",
                 title: approved_slice.title,
                 kind: approved_slice.work_package_kind,
                 repo: work_request.repo,
                 base_branch: approved_slice.target_base_branch,
                 branch_pattern: approved_slice.branch_pattern,
                 product_description: work_request.human_description,
                 status: "blocked",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: approved_slice.owned_file_globs,
                 acceptance_criteria: approved_slice.acceptance_criteria
               )
             )

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["approve:scope_expansion"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    architect_session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    assert {:ok, _dispatched_slice} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", package.id)

    other_work_request = create_work_request!(repo, id: "WR-MCP-SCOPE-EXPANSION-CROSS-LINK-OTHER", status: "ready_for_slicing")

    assert {:ok, other_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               other_work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-SCOPE-EXPANSION-CROSS-LINK-OTHER",
                 target_base_branch: other_work_request.base_branch,
                 owned_file_globs: ["docs/**"]
               )
             )

    assert {:ok, approved_other_slice} =
             WorkRequestRepository.approve_planned_slice(repo, other_work_request.id, other_slice.id, "planned")

    drop_planned_slice_work_package_unique_index!(repo)

    ExUnit.Callbacks.on_exit(fn ->
      repo.query!(
        "UPDATE sympp_work_request_planned_slices SET work_package_id = NULL, dispatched_at = NULL WHERE id = ?",
        [approved_other_slice.id]
      )

      create_planned_slice_work_package_unique_index!(repo)
    end)

    repo.update!(
      Ecto.Changeset.change(approved_other_slice,
        status: "dispatched",
        work_package_id: package.id,
        dispatched_at: DateTime.utc_now(:microsecond)
      )
    )

    approval_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "direct-cross-linked-scope-expansion",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => package.id,
              "allowed_file_globs" => ["docs/**"],
              "rationale" => "Cross-WorkRequest duplicates must be repaired before approval."
            }
          }
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(approval_response, ["error", "data", "reason"]) == "ambiguous_planned_slice_link"

    assert {:ok, unchanged_package} = WorkPackageRepository.get(repo, package.id)
    assert unchanged_package.allowed_file_globs == ["elixir/lib/**"]
  end

  test "WorkRequest architect claim cannot approve unlinked current package scope expansion", %{
    repo: repo
  } do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-SCOPE-EXPANSION-UNLINKED-ANCHOR",
        status: "ready_for_slicing",
        constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false}
      )

    assert {:ok, _handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: [
                 claimed_by: ArchitectHandoff.claimed_by(),
                 database: repo.database_path(),
                 local_architect_claim?: true
               ]
             )

    {claim_response, architect_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-wr-architect-unlinked-anchor-scope-expansion",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{"work_request_id" => work_request.id}
          }
        },
        local_mcp_server(local_mcp_config(repo), "wr-architect-unlinked-anchor-scope-expansion-state")
      )

    capabilities = get_in(claim_response, ["result", "structuredContent", "assignment", "capabilities"])
    assert "write:work_request" in capabilities
    refute "approve:scope_expansion" in capabilities

    anchor_id = ArchitectHandoff.anchor_id_for_work_request(work_request)

    repo.query!(
      "UPDATE sympp_work_packages SET policy_template = ? WHERE id = ?",
      ["mcp_changed_file_scope_guard", anchor_id]
    )

    response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "wr-architect-unlinked-anchor-scope-expansion",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => anchor_id,
              "allowed_file_globs" => ["docs/**"],
              "rationale" => "Unlinked handoff anchors cannot bypass WorkRequest scope."
            }
          }
        },
        architect_server
      )

    assert get_in(response, ["error", "data", "reason"]) == "outside_session_scope"

    assert {:ok, unchanged_anchor} = WorkPackageRepository.get(repo, anchor_id)
    refute "docs/**" in unchanged_anchor.allowed_file_globs
  end

  test "WorkRequest architect claim approves dispatched package scope expansion", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-SCOPE-EXPANSION-WR-ARCHITECT",
        status: "ready_for_slicing",
        constraints: %{"allowed_paths" => ["elixir/lib", "docs"], "requires_secret" => false}
      )

    assert {:ok, _handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: [
                 claimed_by: ArchitectHandoff.claimed_by(),
                 database: repo.database_path(),
                 local_architect_claim?: true
               ]
             )

    {claim_response, architect_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-wr-architect-scope-expansion",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{"work_request_id" => work_request.id}
          }
        },
        local_mcp_server(local_mcp_config(repo), "wr-architect-scope-expansion-state")
      )

    capabilities = get_in(claim_response, ["result", "structuredContent", "assignment", "capabilities"])
    assert "write:work_request" in capabilities
    refute "approve:scope_expansion" in capabilities

    list_response = Server.handle(%{"jsonrpc" => "2.0", "id" => "wr-architect-tools", "method" => "tools/list", "params" => %{}}, architect_server)
    tools_by_name = list_response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})
    assert Map.has_key?(tools_by_name, "approve_scope_expansion")

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-SCOPE-EXPANSION-WR-ARCHITECT",
                 target_base_branch: work_request.base_branch,
                 owned_file_globs: ["elixir/lib/**"]
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-EXPANSION-WR-ARCHITECT",
                 title: approved_slice.title,
                 kind: approved_slice.work_package_kind,
                 repo: work_request.repo,
                 base_branch: approved_slice.target_base_branch,
                 branch_pattern: approved_slice.branch_pattern,
                 product_description: work_request.human_description,
                 status: "blocked",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: approved_slice.owned_file_globs,
                 acceptance_criteria: approved_slice.acceptance_criteria
               )
             )

    assert {:ok, _dispatched_slice} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", package.id)

    approval_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "wr-architect-scope-expansion-approval",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => package.id,
              "allowed_file_globs" => ["docs/**"],
              "rationale" => "Docs are needed for this dispatched package."
            }
          }
        },
        architect_server
      )

    assert get_in(approval_response, ["result", "structuredContent", "allowed_file_globs"]) == ["elixir/lib/**", "docs/**"]
    approval_event_id = get_in(approval_response, ["result", "structuredContent", "progress_event", "id"])
    assert repo.get!(ProgressEvent, approval_event_id).work_package_id == package.id

    outside_scope_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "wr-architect-scope-expansion-outside-request",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => package.id,
              "allowed_file_globs" => ["src/**"],
              "rationale" => "This must stay inside the WorkRequest."
            }
          }
        },
        architect_server
      )

    assert get_in(outside_scope_response, ["error", "data", "reason"]) == "scope_expansion_outside_work_request"

    assert {:ok, updated_package} = WorkPackageRepository.get(repo, package.id)
    assert updated_package.allowed_file_globs == ["elixir/lib/**", "docs/**"]

    assert {:ok, ready_package} = WorkPackageRepository.update(repo, package.id, %{status: "ready_for_merge"})

    assert {:ok, renewed} =
             AccessGrantService.mint_architect_grant(repo, ArchitectHandoff.phase_id_for_work_request(work_request),
               work_package_id: ArchitectHandoff.anchor_id_for_work_request(work_request),
               work_request_id: work_request.id,
               capabilities: ArchitectHandoff.capabilities()
             )

    assert {:ok, renewed_assignment} =
             AccessGrantRepository.claim(
               repo,
               renewed.work_key.secret,
               %{claimed_by: ArchitectHandoff.claimed_by()},
               DateTime.utc_now(:microsecond)
             )

    renewed_session = MCPHarness.session(renewed_assignment, proof_hash: renewed.grant.secret_hash)

    retry_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "wr-architect-scope-expansion-retry-after-ready",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => ready_package.id,
              "allowed_file_globs" => ["docs/**"],
              "rationale" => "Docs are needed for this dispatched package."
            }
          }
        },
        repo: repo,
        session: renewed_session
      )

    assert get_in(retry_response, ["result", "structuredContent", "progress_event", "id"]) == approval_event_id
  end

  test "scope expansion approval rejects packages without scope guard", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-GUARD-NOT-REQUIRED",
                 kind: "quick_fix",
                 status: "ci_waiting",
                 policy_template: "quick_fix",
                 allowed_file_globs: []
               )
             )

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["approve:scope_expansion"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    architect_session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    approval_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "unguarded-scope-approval",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => package.id,
              "allowed_file_globs" => ["docs/**"],
              "rationale" => "Unguarded packages must not record scope approvals."
            }
          }
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(approval_response, ["error", "data", "reason"]) == "scope_guard_not_required"

    assert {:ok, unchanged_package} = WorkPackageRepository.get(repo, package.id)
    assert unchanged_package.allowed_file_globs == []
  end

  defp drop_planned_slice_work_package_unique_index!(repo) do
    repo.query!("DROP INDEX IF EXISTS sympp_work_request_planned_slices_work_package_id_unique_index")
  end

  defp create_planned_slice_work_package_unique_index!(repo) do
    repo.query!("""
    CREATE UNIQUE INDEX IF NOT EXISTS sympp_work_request_planned_slices_work_package_id_unique_index
    ON sympp_work_request_planned_slices (work_package_id)
    WHERE work_package_id IS NOT NULL
    """)
  end
end
