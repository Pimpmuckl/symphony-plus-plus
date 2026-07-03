Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools06Test do
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

  test "review-suite result rejects missing head, wrong package, stale head, non-passing verdicts, and failed-result override", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-REVIEW-SUITE-INVALID",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_review_suite_artifact"
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    base_args = %{
      "work_package_id" => package.id,
      "head_sha" => "head-a",
      "suite" => "review-suite",
      "anchor" => "phase_gate-head-a",
      "summary" => "Review suite result",
      "status" => "passed",
      "verdict" => "green"
    }

    missing_head_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "missing-head",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => Map.delete(base_args, "head_sha")}
        },
        repo: repo,
        session: session
      )

    assert get_in(missing_head_response, ["error", "data", "reason"]) == "missing_head_sha"

    wrong_package_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "wrong-package",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => Map.put(base_args, "work_package_id", "SYMPP-OTHER")}
        },
        repo: repo,
        session: session
      )

    assert get_in(wrong_package_response, ["error", "data", "reason"]) == "outside_session_scope"

    non_passing_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "non-passing",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => %{base_args | "status" => "failed", "verdict" => "red"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(non_passing_response, ["error", "data", "reason"]) == "non_passing_review_suite_result"
    assert get_in(non_passing_response, ["error", "data", "expected_statuses"]) == ["passed", "pass", "green", "success"]
    assert get_in(non_passing_response, ["error", "data", "expected_verdicts"]) == ["green", "clean", "passed", "pass", "success", "approved"]

    completed_lifecycle_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "completed-lifecycle-status",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => %{base_args | "status" => "completed", "verdict" => "clean"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(completed_lifecycle_response, ["error", "data", "reason"]) == "non_passing_review_suite_result"
    assert get_in(completed_lifecycle_response, ["error", "data", "got", "status"]) == "completed"

    arbitrary_payload_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "arbitrary-review-suite-payload",
          "method" => "tools/call",
          "params" => %{
            "name" => "attach_review_suite_result",
            "arguments" => Map.put(base_args, "payload", %{"raw_prompt" => "do not expose", "reviewer_internal" => %{"trace" => "hidden"}})
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(arbitrary_payload_response, ["error", "data", "reason"]) == "unexpected_argument"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-INVALID/worker", "head_sha" => "head-a"})

    assert {:ok, _failed_event} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               idempotency_key: "attach_review_suite_result:#{package.id}:failed-review-suite-head-a",
               summary: "Failed review-suite result",
               status: "review_suite_failed",
               payload: %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => "head-a",
                 "suite" => "review-suite",
                 "anchor" => "phase_gate-head-a-failed",
                 "summary" => "Review suite failed",
                 "status" => "failed",
                 "verdict" => "red"
               }
             })

    failed_override_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "failed-override",
          "method" => "tools/call",
          "params" => %{
            "name" => "attach_review_suite_result",
            "arguments" => Map.put(base_args, "idempotency_key", "failed-override-green")
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(failed_override_response, ["error", "data", "reason"]) == "failed_review_suite_result_exists"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-INVALID/worker", "head_sha" => "head-b"})

    stale_head_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "stale-head",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => base_args}
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_head_response, ["error", "data", "reason"]) == "stale_head_sha"
  end

  test "review evidence accepts clean vocabulary and promotes stale package status to reviewing", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-PROMOTE", kind: "mcp", status: "ready_for_worker")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-PROMOTE/worker", "head_sha" => "review-head-a"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Review package is ready",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "review-head-a",
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    assert {:ok, promoted_after_review_package} = WorkPackageRepository.get(repo, package.id)
    assert promoted_after_review_package.status == "reviewing"

    assert {:ok, suite_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-CLEAN", kind: "mcp", status: "ready_for_worker")
             )

    assert {:ok, suite_minted} = AccessGrantService.mint_worker_grant(repo, suite_package.id)
    assert {:ok, suite_assignment} = AccessGrantService.claim(repo, suite_minted.work_key.secret, claimed_by: "worker-2")
    suite_session = MCPHarness.session(suite_assignment, proof_hash: suite_minted.grant.secret_hash)

    attach_tool(repo, suite_session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-CLEAN/worker", "head_sha" => "suite-head-clean"})

    suite_response =
      attach_tool(repo, suite_session, "attach_review_suite_result", %{
        "work_package_id" => suite_package.id,
        "head_sha" => "suite-head-clean",
        "suite" => "review-suite",
        "anchor" => "review-suite-clean",
        "summary" => "Review passed cleanly",
        "status" => "passed",
        "verdict" => "clean"
      })

    suite_payload = response_progress_payload(repo, suite_response)
    assert suite_payload["status"] == "passed"
    assert suite_payload["verdict"] == "clean"

    assert {:ok, promoted_after_suite} = WorkPackageRepository.get(repo, suite_package.id)
    assert promoted_after_suite.status == "reviewing"
  end

  test "passing review verdict aliases and stricter profiles satisfy required readiness lanes", %{repo: repo} do
    ["clean", "passed", "pass", "success", "approved"]
    |> Enum.with_index()
    |> Enum.each(fn {verdict, index} ->
      package_id = "SYMPP-REVIEW-ALIAS-#{index}"
      head_sha = "alias-head-#{index}"

      assert {:ok, package} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(id: package_id, kind: "mcp", status: "ci_waiting")
               )

      append_done_plan(repo, package.id)
      assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
      assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-#{index}")
      session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

      attach_tool(repo, session, "attach_branch", %{"branch" => "agent/#{package.id}/worker", "head_sha" => head_sha})
      attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/#{910 + index}", "head_sha" => head_sha})

      attach_tool(repo, session, "submit_review_package", %{
        "summary" => "Ready review package",
        "tests" => ["mix test"],
        "artifacts" => ["review.txt"],
        "head_sha" => head_sha,
        "acceptance_criteria_met" => true,
        "reviews" => [%{"lane" => "deep", "verdict" => verdict}]
      })

      ready_response =
        MCPHarness.request(
          %{"jsonrpc" => "2.0", "id" => "ready-review-alias-#{index}", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
          repo: repo,
          session: session
        )

      assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    end)
  end

  test "normal review evidence satisfies brief readiness lanes", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-NORMAL-FOR-BRIEF", kind: "quick_fix", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-NORMAL-FOR-BRIEF/worker", "head_sha" => "brief-head"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready quick fix review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "brief-head",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "clean"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-normal-for-brief", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "exact failed review package lane blocks stronger passing aliases", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-EXACT-FAIL-BLOCKS", kind: "quick_fix", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-EXACT-FAIL-BLOCKS/worker", "head_sha" => "exact-fail-head"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready quick fix review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "exact-fail-head",
      "acceptance_criteria_met" => true,
      "reviews" => [
        %{"lane" => "deep", "verdict" => "clean"},
        %{"lane" => "brief", "verdict" => "failed"}
      ]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-exact-fail-blocks", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_lanes_complete" in get_in(ready_response, ["error", "data", "missing"])
  end

  test "failed stronger review package lane blocks weaker readiness aliases", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-STRONGER-FAIL-BLOCKS", kind: "quick_fix", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-STRONGER-FAIL-BLOCKS/worker", "head_sha" => "stronger-fail-head"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready quick fix review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "stronger-fail-head",
      "acceptance_criteria_met" => true,
      "reviews" => [
        %{"lane" => "normal", "verdict" => "clean"},
        %{"lane" => "deep", "verdict" => "failed"}
      ]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-stronger-fail-blocks", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_lanes_complete" in get_in(ready_response, ["error", "data", "missing"])
  end

  test "later generic review failures block older satisfying-profile passes", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-DEEP-BEATS-BRIEF-FAIL", kind: "quick_fix", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-DEEP-BEATS-BRIEF-FAIL/worker", "head_sha" => "generic-review-head"})

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed",
      "status" => "tests_passed",
      "idempotency_key" => "generic-review-tests"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Deep review failed",
      "status" => "review_deep_failed",
      "idempotency_key" => "generic-review-deep-failed"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Later brief review passed",
      "status" => "review_brief_green",
      "idempotency_key" => "generic-review-brief-green"
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-deep-beats-brief-fail", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_lanes_complete" in get_in(ready_response, ["error", "data", "missing"])

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Brief review passed after failure",
      "status" => "review_brief_green",
      "idempotency_key" => "generic-review-brief-regreen"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Later normal review failed",
      "status" => "review_normal_failed",
      "idempotency_key" => "generic-review-normal-failed"
    })

    stronger_fail_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-brief-green-normal-fail", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_lanes_complete" in get_in(stronger_fail_response, ["error", "data", "missing"])
  end

  test "minimal Review Suite round id attaches derived current-head evidence and satisfies readiness lanes", %{repo: repo} do
    head_sha = "minimal-round-head"
    branch = "agent/SYMPP-REVIEW-SUITE-MINIMAL/worker"
    put_review_suite_state!("rvw_minimal_clean", "orc-minimal-clean", head_sha, "deep", branch: branch)

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-MINIMAL", kind: "mcp", status: "ci_waiting", policy_template: "mcp_review_suite_artifact")
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => branch, "head_sha" => head_sha})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/930", "head_sha" => head_sha})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package without embedded Review Suite metadata",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true,
      "reviews" => []
    })

    missing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-before-minimal-round", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_suite_result" in get_in(missing_response, ["error", "data", "missing"])
    assert "review_lanes_complete" in get_in(missing_response, ["error", "data", "missing"])

    result_response = attach_tool(repo, session, "attach_review_suite_result", %{"round_id" => "rvw_minimal_clean"})
    payload = response_progress_payload(repo, result_response)

    assert payload["work_package_id"] == package.id
    assert payload["head_sha"] == head_sha
    assert payload["suite"] == "review-suite"
    assert payload["anchor"] == "review_t1"
    assert payload["round_id"] == "review_t1"
    assert payload["review_suite_id"] == "rvw_minimal_clean"
    assert payload["status"] == "passed"
    assert payload["verdict"] == "clean"
    assert payload["lane"] == "deep"
    assert payload["profile"] == "deep"
    assert payload["base_branch"] == package.base_branch
    assert payload["branch"] == branch

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-minimal-round", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "minimal Review Suite round id accepts review green status aliases", %{repo: repo} do
    head_sha = "minimal-round-green-alias-head"
    branch = "agent/SYMPP-REVIEW-SUITE-GREEN-ALIAS/worker"
    put_review_suite_state!("rvw_minimal_success", "orc-minimal-success", head_sha, "normal", stage: "review-complete", review_green: "success", branch: branch)

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-GREEN-ALIAS", kind: "quick_fix", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => branch, "head_sha" => head_sha})

    response = attach_tool(repo, session, "attach_review_suite_result", %{"round_id" => "rvw_minimal_success"})
    payload = response_progress_payload(repo, response)

    assert payload["status"] == "passed"
    assert payload["profile"] == "normal"
  end

  test "minimal Review Suite round id accepts unique stored round ids despite unrelated corrupt cycles", %{repo: repo} do
    head_sha = "actual-round-id-head"
    branch = "agent/SYMPP-REVIEW-SUITE-ACTUAL-ROUND/worker"
    state_dir = put_review_suite_state!("rvw_actual_round", "orc-actual-round", head_sha, "normal", branch: branch)
    File.write!(Path.join([state_dir, "orchestrator", "cycles", "orc-corrupt.json"]), "{")

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-ACTUAL-ROUND", kind: "quick_fix", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => branch, "head_sha" => head_sha})

    response = attach_tool(repo, session, "attach_review_suite_result", %{"round_id" => "review_t1"})
    payload = response_progress_payload(repo, response)

    assert payload["round_id"] == "review_t1"
    assert payload["review_suite_id"] == "rvw_actual_round"
    assert payload["head_sha"] == head_sha
    assert payload["profile"] == "normal"
  end

  test "round id takes precedence over complete explicit fallback fields", %{repo: repo} do
    head_sha = "mixed-round-bypass-head"
    branch = "agent/SYMPP-REVIEW-SUITE-MIXED/worker"

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-MIXED", kind: "quick_fix", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => branch, "head_sha" => head_sha})
    put_review_suite_state!("rvw_other_missing_mixed", "orc-other-missing-mixed", head_sha, "normal")

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "mixed-round-explicit-fields",
          "method" => "tools/call",
          "params" => %{
            "name" => "attach_review_suite_result",
            "arguments" => %{
              "round_id" => "rvw_missing_mixed",
              "head_sha" => head_sha,
              "suite" => "review-suite",
              "anchor" => "spoofed-anchor",
              "summary" => "Spoofed explicit review suite pass",
              "status" => "passed",
              "verdict" => "clean",
              "profile" => "normal",
              "lane" => "normal"
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "data", "reason"]) == "review_suite_round_unavailable"
    assert get_in(response, ["error", "data", "round_id"]) == "rvw_missing_mixed"
    assert ["head_sha", "profile"] -- get_in(response, ["error", "data", "fallback_explicit_fields"]) == []
  end

  test "minimal Review Suite round id rejects same-head identity mismatches", %{repo: repo} do
    head_sha = "identity-mismatch-head"
    branch = "agent/SYMPP-REVIEW-SUITE-IDENTITY/worker"

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-IDENTITY", kind: "mcp", status: "ci_waiting", policy_template: "mcp_review_suite_artifact")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => branch, "head_sha" => head_sha})

    put_review_suite_state!("rvw_wrong_base", "orc-wrong-base", head_sha, "normal", base_branch: "release", branch: branch)
    wrong_base_response = review_suite_round_response(repo, session, "wrong-base-round", "rvw_wrong_base")

    assert get_in(wrong_base_response, ["error", "data", "reason"]) == "review_suite_round_identity_mismatch"
    assert get_in(wrong_base_response, ["error", "data", "field"]) == "base_branch"
    assert get_in(wrong_base_response, ["error", "data", "expected"]) == package.base_branch
    assert get_in(wrong_base_response, ["error", "data", "got"]) == "release"

    put_review_suite_state!("rvw_wrong_repo", "orc-wrong-repo", head_sha, "normal", repo: "other/repo", branch: branch)
    wrong_repo_response = review_suite_round_response(repo, session, "wrong-repo-round", "rvw_wrong_repo")

    assert get_in(wrong_repo_response, ["error", "data", "reason"]) == "review_suite_round_identity_mismatch"
    assert get_in(wrong_repo_response, ["error", "data", "field"]) == "repo"
    assert get_in(wrong_repo_response, ["error", "data", "expected"]) == package.repo
    assert get_in(wrong_repo_response, ["error", "data", "got"]) == "other/repo"

    put_review_suite_state!("rvw_wrong_branch", "orc-wrong-branch", head_sha, "normal", branch: "agent/other-package/worker")
    wrong_branch_response = review_suite_round_response(repo, session, "wrong-branch-round", "rvw_wrong_branch")

    assert get_in(wrong_branch_response, ["error", "data", "reason"]) == "review_suite_round_identity_mismatch"
    assert get_in(wrong_branch_response, ["error", "data", "field"]) == "branch"
    assert get_in(wrong_branch_response, ["error", "data", "expected"]) == branch
    assert get_in(wrong_branch_response, ["error", "data", "got"]) == "agent/other-package/worker"

    put_review_suite_state!("rvw_wrong_package", "orc-wrong-package", head_sha, "normal", branch: branch, work_package_id: "SYMPP-OTHER-PACKAGE")
    wrong_package_response = review_suite_round_response(repo, session, "wrong-package-round", "rvw_wrong_package")

    assert get_in(wrong_package_response, ["error", "data", "reason"]) == "review_suite_round_identity_mismatch"
    assert get_in(wrong_package_response, ["error", "data", "field"]) == "work_package_id"
    assert get_in(wrong_package_response, ["error", "data", "expected"]) == package.id
    assert get_in(wrong_package_response, ["error", "data", "got"]) == "SYMPP-OTHER-PACKAGE"
  end

  test "review-suite readiness blocks when latest current-head rerun failed", %{repo: repo} do
    head_sha = "multi-round-head"

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-MULTI-ROUND", kind: "mcp", status: "ci_waiting", policy_template: "mcp_review_suite_artifact")
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-MULTI-ROUND/worker", "head_sha" => head_sha})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/931", "head_sha" => head_sha})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package without embedded Review Suite metadata",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true,
      "reviews" => []
    })

    attach_tool(repo, session, "attach_review_suite_result", %{
      "head_sha" => head_sha,
      "suite" => "review-suite",
      "anchor" => "deep-round",
      "summary" => "Deep review clean",
      "status" => "passed",
      "verdict" => "clean",
      "profile" => "deep"
    })

    attach_tool(repo, session, "attach_review_suite_result", %{
      "head_sha" => head_sha,
      "suite" => "review-suite",
      "anchor" => "brief-round",
      "summary" => "Later brief review clean",
      "status" => "passed",
      "verdict" => "clean",
      "profile" => "brief"
    })

    assert {:ok, _later_failed_event} =
             PlanningRepository.append_progress_event(repo, %{
               "work_package_id" => package.id,
               "idempotency_key" => "attach_review_suite_result:#{package.id}:later-brief-fail",
               "summary" => "Later brief review-suite result failed",
               "status" => "review_suite_failed",
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => head_sha,
                 "suite" => "review-suite",
                 "anchor" => "brief-round-failed",
                 "summary" => "Later brief review failed",
                 "status" => "failed",
                 "verdict" => "red",
                 "profile" => "brief"
               }
             })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-multi-round", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["error", "data", "reason"]) == "readiness_failed"
    assert "review_suite_result" in get_in(ready_response, ["error", "data", "missing"])
  end

  test "exact failed Review Suite lane blocks stronger passing aliases", %{repo: repo} do
    head_sha = "review-suite-exact-fail-head"

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-EXACT-FAIL", kind: "quick_fix", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-EXACT-FAIL/worker", "head_sha" => head_sha})

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed",
      "status" => "tests_passed",
      "idempotency_key" => "review-suite-exact-fail-tests"
    })

    assert {:ok, _artifact} =
             PlanningRepository.append_artifact(repo, %{
               "id" => review_suite_artifact_id(package.id, head_sha),
               "work_package_id" => package.id,
               "path" => "review-suite-result.json",
               "title" => "Review-suite result",
               "kind" => "review_suite"
             })

    assert {:ok, _brief_failed_event} =
             PlanningRepository.append_progress_event(repo, %{
               "created_at" => ~U[2026-05-05 00:00:00Z],
               "idempotency_key" => "attach_review_suite_result:#{package.id}:brief-fail",
               "status" => "review_suite_failed",
               "summary" => "Brief review-suite result failed",
               "work_package_id" => package.id,
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => head_sha,
                 "suite" => "review-suite",
                 "anchor" => "brief-fail",
                 "summary" => "Brief review suite failed",
                 "status" => "failed",
                 "verdict" => "red",
                 "profile" => "brief"
               }
             })

    assert {:ok, _deep_passed_event} =
             PlanningRepository.append_progress_event(repo, %{
               "created_at" => ~U[2026-05-05 00:00:10Z],
               "idempotency_key" => "attach_review_suite_result:#{package.id}:deep-pass",
               "status" => "review_suite_passed",
               "summary" => "Deep review-suite result passed",
               "work_package_id" => package.id,
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => head_sha,
                 "suite" => "review-suite",
                 "anchor" => "deep-pass",
                 "summary" => "Deep review suite passed",
                 "status" => "passed",
                 "verdict" => "clean",
                 "profile" => "deep"
               }
             })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-review-suite-exact-fail", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_lanes_complete" in get_in(ready_response, ["error", "data", "missing"])
  end

  test "latest stronger Review Suite failure blocks stale stronger pass", %{repo: repo} do
    head_sha = "review-suite-stronger-fail-head"

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-STRONGER-FAIL", kind: "quick_fix", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-STRONGER-FAIL/worker", "head_sha" => head_sha})

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed",
      "status" => "tests_passed",
      "idempotency_key" => "review-suite-stronger-fail-tests"
    })

    assert {:ok, _artifact} =
             PlanningRepository.append_artifact(repo, %{
               "id" => review_suite_artifact_id(package.id, head_sha),
               "work_package_id" => package.id,
               "path" => "review-suite-result.json",
               "title" => "Review-suite result",
               "kind" => "review_suite"
             })

    assert {:ok, _deep_passed_event} =
             PlanningRepository.append_progress_event(repo, %{
               "work_package_id" => package.id,
               "idempotency_key" => "attach_review_suite_result:#{package.id}:deep-pass",
               "summary" => "Deep review-suite result passed",
               "status" => "review_suite_passed",
               "created_at" => ~U[2026-05-05 00:00:00Z],
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => head_sha,
                 "suite" => "review-suite",
                 "anchor" => "deep-pass",
                 "summary" => "Deep review suite passed",
                 "status" => "passed",
                 "verdict" => "clean",
                 "profile" => "deep"
               }
             })

    assert {:ok, _deep_failed_event} =
             PlanningRepository.append_progress_event(repo, %{
               "work_package_id" => package.id,
               "idempotency_key" => "attach_review_suite_result:#{package.id}:deep-fail",
               "summary" => "Deep review-suite result failed",
               "status" => "review_suite_failed",
               "created_at" => ~U[2026-05-05 00:00:10Z],
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => head_sha,
                 "suite" => "review-suite",
                 "anchor" => "deep-fail",
                 "summary" => "Deep review suite failed",
                 "status" => "failed",
                 "verdict" => "red",
                 "profile" => "deep"
               }
             })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-review-suite-stronger-fail", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_lanes_complete" in get_in(ready_response, ["error", "data", "missing"])
  end

  test "latest stronger Review Suite failure blocks older weaker pass", %{repo: repo} do
    head_sha = "review-suite-weaker-pass-stronger-fail-head"

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-WEAKER-PASS-STRONGER-FAIL", kind: "quick_fix", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-WEAKER-PASS-STRONGER-FAIL/worker", "head_sha" => head_sha})

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed",
      "status" => "tests_passed",
      "idempotency_key" => "review-suite-weaker-pass-stronger-fail-tests"
    })

    assert {:ok, _artifact} =
             PlanningRepository.append_artifact(repo, %{
               "id" => review_suite_artifact_id(package.id, head_sha),
               "work_package_id" => package.id,
               "path" => "review-suite-result.json",
               "title" => "Review-suite result",
               "kind" => "review_suite"
             })

    assert {:ok, _brief_passed_event} =
             PlanningRepository.append_progress_event(repo, %{
               "work_package_id" => package.id,
               "idempotency_key" => "attach_review_suite_result:#{package.id}:brief-pass",
               "summary" => "Brief review-suite result passed",
               "status" => "review_suite_passed",
               "created_at" => ~U[2026-05-05 00:00:00Z],
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => head_sha,
                 "suite" => "review-suite",
                 "anchor" => "brief-pass",
                 "summary" => "Brief review suite passed",
                 "status" => "passed",
                 "verdict" => "clean",
                 "profile" => "brief"
               }
             })

    assert {:ok, _normal_failed_event} =
             PlanningRepository.append_progress_event(repo, %{
               "work_package_id" => package.id,
               "idempotency_key" => "attach_review_suite_result:#{package.id}:normal-fail",
               "summary" => "Normal review-suite result failed",
               "status" => "review_suite_failed",
               "created_at" => ~U[2026-05-05 00:00:10Z],
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => head_sha,
                 "suite" => "review-suite",
                 "anchor" => "normal-fail",
                 "summary" => "Normal review suite failed",
                 "status" => "failed",
                 "verdict" => "red",
                 "profile" => "normal"
               }
             })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-review-suite-weaker-pass-stronger-fail", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_lanes_complete" in get_in(ready_response, ["error", "data", "missing"])
  end

  test "minimal Review Suite round id rejects stale heads and unavailable local state", %{repo: repo} do
    state_dir = put_review_suite_state!("rvw_stale_clean", "orc-stale-clean", "round-head-a", "normal")

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-STALE-ROUND", kind: "mcp", status: "ci_waiting", policy_template: "mcp_review_suite_artifact")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-STALE-ROUND/worker", "head_sha" => "round-head-b"})

    stale_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "stale-review-suite-round",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => %{"round_id" => "rvw_stale_clean"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_response, ["error", "data", "reason"]) == "stale_head_sha"

    missing_state_dir = Path.join(System.tmp_dir!(), "missing-review-suite-state-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :sympp_review_suite_state_dir, missing_state_dir)

    unavailable_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "missing-review-suite-round",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => %{"round_id" => "rvw_missing_clean"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(unavailable_response, ["error", "data", "reason"]) == "review_suite_round_unavailable"

    assert get_in(unavailable_response, ["error", "data", "fallback_explicit_fields"]) == [
             "work_package_id",
             "head_sha",
             "status",
             "verdict",
             "suite",
             "anchor",
             "summary",
             "profile",
             "lane"
           ]

    Application.put_env(:symphony_elixir, :sympp_review_suite_state_dir, state_dir)
  end

  test "minimal Review Suite round id rejects ambiguous stored ids and missing stored profiles", %{repo: repo} do
    state_dir = put_review_suite_state!("rvw_missing_profile", "orc-missing-profile", "profile-head-a", nil)
    append_review_suite_cycle!(state_dir, "rvw_duplicate_round", "orc-duplicate-round", "profile-head-a", "normal")

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-PROFILE-GUARD", kind: "mcp", status: "ci_waiting", policy_template: "mcp_review_suite_artifact")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-PROFILE-GUARD/worker", "head_sha" => "profile-head-a"})

    missing_profile_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "missing-review-suite-profile",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => %{"round_id" => "rvw_missing_profile", "profile" => "deep"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(missing_profile_response, ["error", "data", "reason"]) == "review_suite_round_missing_profile"

    ambiguous_round_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "ambiguous-review-suite-round",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => %{"round_id" => "review_t1"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(ambiguous_round_response, ["error", "data", "reason"]) == "review_suite_round_ambiguous"
    assert get_in(ambiguous_round_response, ["error", "data", "matching_cycle_ids"]) == ["orc-duplicate-round", "orc-missing-profile"]
  end

  test "minimal Review Suite round id rejects unsafe cycle ids", %{repo: repo} do
    state_dir = Path.join(System.tmp_dir!(), "review-suite-state-unsafe-cycle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([state_dir, "orchestrator", "cycles"]))
    File.write!(Path.join([state_dir, "orchestrator", "index.json"]), Jason.encode!(%{"public_ids" => %{"rvw_unsafe_cycle" => "orc-../escape"}}))

    previous = Application.get_env(:symphony_elixir, :sympp_review_suite_state_dir)
    Application.put_env(:symphony_elixir, :sympp_review_suite_state_dir, state_dir)

    ExUnit.Callbacks.on_exit(fn ->
      restore_review_suite_state_dir(previous)
      File.rm_rf(state_dir)
    end)

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-UNSAFE-CYCLE", kind: "mcp", status: "ci_waiting", policy_template: "mcp_review_suite_artifact")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "unsafe-review-suite-cycle",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => %{"round_id" => "rvw_unsafe_cycle"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "data", "reason"]) == "review_suite_round_unavailable"
    assert get_in(response, ["error", "data", "missing"]) == ["safe Review Suite cycle id orc-*"]
  end

  test "review-suite result idempotent retry replays after current head advances", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-REPLAY", kind: "mcp", status: "ci_waiting", policy_template: "mcp_review_suite_artifact")
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    args = %{
      "work_package_id" => package.id,
      "head_sha" => "head-a",
      "suite" => "review-suite",
      "anchor" => "phase_gate-head-a",
      "summary" => "Review suite result",
      "status" => "passed",
      "verdict" => "green",
      "lane" => "normal",
      "reviewer" => "review-suite",
      "idempotency_key" => "review-suite-head-a"
    }

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-REPLAY/worker", "head_sha" => "head-a"})
    first_response = attach_tool(repo, session, "attach_review_suite_result", args)
    first_event_id = get_in(first_response, ["result", "structuredContent", "progress_event", "id"])

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-REPLAY/worker", "head_sha" => "head-b"})

    replay_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "review-suite-replay", "method" => "tools/call", "params" => %{"name" => "attach_review_suite_result", "arguments" => args}},
        repo: repo,
        session: session
      )

    assert get_in(replay_response, ["result", "structuredContent", "progress_event", "id"]) == first_event_id

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)

    revoked_replay_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "review-suite-revoked-replay", "method" => "tools/call", "params" => %{"name" => "attach_review_suite_result", "arguments" => args}},
        repo: repo,
        session: session
      )

    assert get_in(revoked_replay_response, ["error", "data", "reason"]) == "revoked"
  end

  test "review-suite readiness uses chronological latest result for the current head", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-ORDER", kind: "mcp", status: "ci_waiting", policy_template: "mcp_review_suite_artifact")
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-ORDER/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/901", "head_sha" => "head-a"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    assert {:ok, _artifact} =
             PlanningRepository.append_artifact(repo, %{
               "id" => review_suite_artifact_id(package.id, "head-a"),
               "work_package_id" => package.id,
               "path" => "review-suite-result.json",
               "title" => "Review-suite result",
               "kind" => "review_suite"
             })

    assert {:ok, _newer_passed_event} =
             PlanningRepository.append_progress_event(repo, %{
               "work_package_id" => package.id,
               "idempotency_key" => "attach_review_suite_result:#{package.id}:chronological-pass",
               "summary" => "Newer review-suite result passed",
               "status" => "review_suite_passed",
               "created_at" => ~U[2026-05-05 00:00:10Z],
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => "head-a",
                 "suite" => "review-suite",
                 "anchor" => "phase_gate-head-a-pass",
                 "summary" => "Newer review suite passed",
                 "status" => "passed",
                 "verdict" => "green"
               }
             })

    assert {:ok, _older_failed_event} =
             PlanningRepository.append_progress_event(repo, %{
               "work_package_id" => package.id,
               "idempotency_key" => "attach_review_suite_result:#{package.id}:chronological-fail",
               "summary" => "Older review-suite result failed",
               "status" => "review_suite_failed",
               "created_at" => ~U[2026-05-05 00:00:00Z],
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => "head-a",
                 "suite" => "review-suite",
                 "anchor" => "phase_gate-head-a-fail",
                 "summary" => "Older review suite failed",
                 "status" => "failed",
                 "verdict" => "red"
               }
             })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-review-suite-order", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "review-suite readiness blocks when the current-head latest result failed", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-LATEST-FAIL", kind: "mcp", status: "ci_waiting", policy_template: "mcp_review_suite_artifact")
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-LATEST-FAIL/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/902", "head_sha" => "head-a"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    assert {:ok, _artifact} =
             PlanningRepository.append_artifact(repo, %{
               "id" => review_suite_artifact_id(package.id, "head-a"),
               "work_package_id" => package.id,
               "path" => "review-suite-result.json",
               "title" => "Review-suite result",
               "kind" => "review_suite"
             })

    assert {:ok, _older_passed_event} =
             PlanningRepository.append_progress_event(repo, %{
               "work_package_id" => package.id,
               "idempotency_key" => "attach_review_suite_result:#{package.id}:latest-fail-pass",
               "summary" => "Older review-suite result passed",
               "status" => "review_suite_passed",
               "created_at" => ~U[2026-05-05 00:00:00Z],
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => "head-a",
                 "suite" => "review-suite",
                 "anchor" => "phase_gate-head-a-pass",
                 "summary" => "Older review suite passed",
                 "status" => "passed",
                 "verdict" => "green"
               }
             })

    assert {:ok, _newer_failed_event} =
             PlanningRepository.append_progress_event(repo, %{
               "work_package_id" => package.id,
               "idempotency_key" => "attach_review_suite_result:#{package.id}:latest-fail-fail",
               "summary" => "Newer review-suite result failed",
               "status" => "review_suite_failed",
               "created_at" => ~U[2026-05-05 00:00:10Z],
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => "head-a",
                 "suite" => "review-suite",
                 "anchor" => "phase_gate-head-a-fail",
                 "summary" => "Newer review suite failed",
                 "status" => "failed",
                 "verdict" => "red"
               }
             })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-review-suite-latest-fail", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["error", "data", "reason"]) == "readiness_failed"
    assert "review_suite_result" in get_in(ready_response, ["error", "data", "missing"])
  end

  test "stale and spoofed review-suite evidence cannot satisfy required readiness", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-REVIEW-SUITE-SPOOF",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_review_suite_artifact"
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-SPOOF/worker", "head_sha" => "head-a"})

    attach_tool(repo, session, "attach_review_suite_result", %{
      "work_package_id" => package.id,
      "head_sha" => "head-a",
      "suite" => "review-suite",
      "anchor" => "phase_gate-head-a",
      "summary" => "Old head review suite",
      "status" => "passed",
      "verdict" => "green"
    })

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-SPOOF/worker", "head_sha" => "head-b"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/901", "head_sha" => "head-b"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "head-b",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Spoofed review-suite JSON",
      "idempotency_key" => "spoof-review-suite-json",
      "payload" => %{
        "type" => "review_suite_result",
        "source_tool" => "attach_review_suite_result",
        "work_package_id" => package.id,
        "head_sha" => "head-b",
        "suite" => "review-suite",
        "anchor" => "phase_gate-head-b",
        "status" => "passed",
        "verdict" => "green"
      }
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-spoofed-review-suite", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(ready_response, ["error", "data", "missing"])
    assert "review_suite_result" in missing
    refute "review_package_submitted" in missing
  end

  defp put_review_suite_state!(public_id, cycle_key, head_sha, profile, opts \\ []) do
    state_dir = Path.join(System.tmp_dir!(), "review-suite-state-#{System.unique_integer([:positive])}")
    cycles_dir = Path.join([state_dir, "orchestrator", "cycles"])
    File.mkdir_p!(cycles_dir)

    File.write!(
      Path.join([state_dir, "orchestrator", "index.json"]),
      Jason.encode!(%{"public_ids" => %{public_id => cycle_key}})
    )

    File.write!(
      Path.join(cycles_dir, "#{cycle_key}.json"),
      Jason.encode!(review_suite_cycle(public_id, head_sha, profile, opts))
    )

    previous = Application.get_env(:symphony_elixir, :sympp_review_suite_state_dir)
    Application.put_env(:symphony_elixir, :sympp_review_suite_state_dir, state_dir)

    ExUnit.Callbacks.on_exit(fn ->
      restore_review_suite_state_dir(previous)
      File.rm_rf(state_dir)
    end)

    state_dir
  end

  defp append_review_suite_cycle!(state_dir, public_id, cycle_key, head_sha, profile, opts \\ []) do
    index_path = Path.join([state_dir, "orchestrator", "index.json"])
    index = index_path |> File.read!() |> Jason.decode!()

    index =
      Map.update(index, "public_ids", %{public_id => cycle_key}, fn public_ids ->
        Map.put(public_ids, public_id, cycle_key)
      end)

    File.write!(index_path, Jason.encode!(index))
    File.write!(Path.join([state_dir, "orchestrator", "cycles", "#{cycle_key}.json"]), Jason.encode!(review_suite_cycle(public_id, head_sha, profile, opts)))
  end

  defp review_suite_cycle(public_id, head_sha, profile, opts) do
    %{
      "public_id" => public_id,
      "stage" => Keyword.get(opts, :stage, "review-green"),
      "validation" => %{"review_green" => Keyword.get(opts, :review_green, "passed")},
      "identity" => review_suite_cycle_identity(head_sha, opts),
      "mode" => review_suite_cycle_mode(profile),
      "review_heads" => %{"last_reviewed_head" => head_sha},
      "rounds" => [
        %{"round_id" => "review_t1", "review_status" => "completed", "reviewed_head" => head_sha}
      ],
      "decisions" => [
        %{"round_id" => "review_t1", "command" => "clean", "reviewed_head" => head_sha}
      ]
    }
  end

  defp review_suite_cycle_mode(nil), do: %{}
  defp review_suite_cycle_mode(profile), do: %{"effective" => profile, "requested" => profile}

  defp review_suite_cycle_identity(head_sha, opts) do
    %{"base" => Keyword.get(opts, :base_branch, "main"), "branch" => Keyword.get(opts, :branch, "hotfix/review-suite-round-ux"), "head" => head_sha}
    |> put_identity("repo", Keyword.get(opts, :repo))
    |> put_identity("work_package_id", Keyword.get(opts, :work_package_id))
  end

  defp put_identity(identity, _key, nil), do: identity
  defp put_identity(identity, key, value), do: Map.put(identity, key, value)

  defp review_suite_round_response(repo, session, request_id, round_id) do
    MCPHarness.request(
      %{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "method" => "tools/call",
        "params" => %{"name" => "attach_review_suite_result", "arguments" => %{"round_id" => round_id}}
      },
      repo: repo,
      session: session
    )
  end

  defp restore_review_suite_state_dir(nil), do: Application.delete_env(:symphony_elixir, :sympp_review_suite_state_dir)
  defp restore_review_suite_state_dir(value), do: Application.put_env(:symphony_elixir, :sympp_review_suite_state_dir, value)

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
