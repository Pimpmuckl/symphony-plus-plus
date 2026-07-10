Code.require_file("../../support/mcp_harness.exs", __DIR__)
Code.require_file("../../support/symphony_plus_plus/mcp_session_helpers.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPDeliveryToolsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  import SymphonyElixir.SymphonyPlusPlus.MCPCase.SessionHelpers,
    only: [create_phase_architect_session: 4]

  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.GrantScope
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Session}
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{
    ArchitectHandoff,
    PlannedSlice,
    PlannedSliceDelivery,
    WorkRequest
  }

  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkPackageRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    schemas = [
      ProgressEvent,
      PlannedSliceDelivery,
      PlannedSlice,
      ClaimLease,
      GrantScope,
      AccessGrant,
      WorkRequest,
      WorkPackage,
      Phase
    ]

    for schema <- schemas do
      repo.delete_all(schema)
    end

    :ok
  end

  test "WR architect stale capabilities still read scoped package status and record closeout", %{
    repo: repo
  } do
    {work_request, planned_slice, linked_package} =
      linked_slice!(repo, work_request_id: "WR-MCP-DELIVERY-READ-CLOSE")

    session =
      repo
      |> create_work_request_architect_session(work_request, ArchitectHandoff.capabilities())
      |> stale_session_capabilities(legacy_work_request_architect_capabilities())

    read_child_response =
      mcp_tool(repo, session, "read_child_status", %{"work_package_id" => linked_package.id})

    assert get_in(read_child_response, ["result", "structuredContent", "work_package", "id"]) ==
             linked_package.id

    assert get_in(read_child_response, ["result", "structuredContent", "work_package", "status"]) ==
             linked_package.status

    {_sibling_request, _sibling_slice, sibling_package} =
      linked_slice!(repo, work_request_id: "WR-MCP-DELIVERY-READ-CLOSE-SIBLING")

    sibling_response =
      mcp_tool(repo, session, "read_child_status", %{"work_package_id" => sibling_package.id})

    assert get_in(sibling_response, ["error", "code"]) == -32_003
    assert get_in(sibling_response, ["error", "data", "reason"]) == "outside_session_scope"

    board_response =
      mcp_tool(repo, session, "read_delivery_board", %{
        "work_request_id" => work_request.id
      })

    board_payload = get_in(board_response, ["result", "structuredContent"])

    assert get_in(board_payload, ["delivery_board", "slices", Access.at(0), "work_package", "id"]) ==
             linked_package.id

    evidence_url = "https://example.invalid/delivery?token=placeholder"
    evidence_query_value = "placeholder"

    closeout_args =
      no_pr_args(
        work_request,
        planned_slice,
        "delivery-mcp-no-pr",
        "Operator confirmed #{evidence_url} completed without a PR."
      )

    closeout_response = record_delivery(repo, session, closeout_args)
    closeout_payload = get_in(closeout_response, ["result", "structuredContent"])

    assert closeout_payload["planned_slice_delivery"]["outcome"] == "completed_no_pr"
    refute Map.has_key?(closeout_payload["planned_slice_delivery"], "no_pr_evidence")
    refute inspect(closeout_response) =~ evidence_query_value

    read_closed_response =
      mcp_tool(repo, session, "read_delivery_board", %{
        "work_request_id" => work_request.id
      })

    assert get_in(read_closed_response, [
             "result",
             "structuredContent",
             "delivery_board",
             "counts",
             "completed_no_pr"
           ]) == 1

    assert get_in(read_closed_response, [
             "result",
             "structuredContent",
             "delivery_board",
             "slices",
             Access.at(0),
             "operational_state",
             "key"
           ]) == "completed_no_pr"

    delivery_evidence_path = [
      "delivery_board",
      "slices",
      Access.at(0),
      "delivery",
      "no_pr_evidence"
    ]

    assert get_in(read_closed_response, ["result", "structuredContent" | delivery_evidence_path]) =~ "[REDACTED]"
    refute get_in(read_closed_response, ["result", "structuredContent" | delivery_evidence_path]) =~ evidence_query_value
    assert repo.get!(WorkPackage, linked_package.id).status == "closed"

    replay_response = record_delivery(repo, session, closeout_args)

    assert get_in(replay_response, ["result", "structuredContent", "planned_slice_delivery", "id"]) ==
             closeout_payload["planned_slice_delivery"]["id"]

    refute get_in(read_closed_response, ["result", "structuredContent" | delivery_evidence_path]) =~
             evidence_query_value

    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 1
  end

  test "WR architect reads and closes linked package on planned-slice delivery base", %{
    repo: repo
  } do
    delivery_base = "feature/integration-base"

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-DELIVERY-CROSS-BASE",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    planned_slice =
      create_planned_slice!(repo, work_request,
        id: "WRS-MCP-DELIVERY-CROSS-BASE",
        target_base_branch: delivery_base,
        branch_pattern: "feat/integration-base"
      )

    assert {:ok, approved_slice} =
             WorkRequestRepository.approve_planned_slice(
               repo,
               work_request.id,
               planned_slice.id,
               "planned"
             )

    linked_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "WP-MCP-DELIVERY-CROSS-BASE",
        status: "reviewing"
      )

    assert {:ok, dispatched_slice} =
             WorkRequestRepository.dispatch_planned_slice(
               repo,
               work_request.id,
               approved_slice.id,
               "approved",
               linked_package.id
             )

    session =
      create_work_request_architect_session(repo, work_request, ArchitectHandoff.capabilities())

    board_response =
      mcp_tool(repo, session, "read_delivery_board", %{
        "work_request_id" => work_request.id
      })

    board_payload = get_in(board_response, ["result", "structuredContent"])

    assert board_payload["scope"] == %{
             "repo" => work_request.repo,
             "base_branch" => work_request.base_branch
           }

    assert get_in(board_payload, ["delivery_board", "slices", Access.at(0), "work_package", "id"]) ==
             linked_package.id

    assert get_in(board_payload, [
             "delivery_board",
             "slices",
             Access.at(0),
             "work_package",
             "base_branch"
           ]) == delivery_base

    closeout_response =
      record_delivery(
        repo,
        session,
        no_pr_args(
          work_request,
          dispatched_slice,
          "delivery-mcp-cross-base-no-pr",
          "Operator confirmed cross-base package completed without a PR."
        )
      )

    closeout_payload = get_in(closeout_response, ["result", "structuredContent"])
    assert closeout_payload["planned_slice_delivery"]["outcome"] == "completed_no_pr"

    read_closed_response =
      mcp_tool(repo, session, "read_delivery_board", %{
        "work_request_id" => work_request.id
      })

    assert get_in(read_closed_response, [
             "result",
             "structuredContent",
             "delivery_board",
             "counts",
             "completed_no_pr"
           ]) == 1

    assert get_in(read_closed_response, [
             "result",
             "structuredContent",
             "delivery_board",
             "slices",
             Access.at(0),
             "work_package",
             "base_branch"
           ]) == delivery_base

    closed_package = repo.get!(WorkPackage, linked_package.id)
    assert closed_package.status == "closed"
    assert closed_package.base_branch == delivery_base
  end

  test "repo-scoped delivery board only exposes packages on the matching delivery base", %{
    repo: repo
  } do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-DELIVERY-REPO-SCOPE-CROSS-BASE",
        base_branch: "main",
        status: "ready_for_slicing",
        repo_scopes: [
          %{repo: "nextide/example", base_branch: "feature/a"},
          %{repo: "nextide/example", base_branch: "feature/b"}
        ]
      )

    feature_a_slice =
      repo
      |> create_planned_slice!(
        work_request,
        id: "WRS-MCP-DELIVERY-REPO-SCOPE-A",
        target_base_branch: "feature/a",
        branch_pattern: "feat/a"
      )
      |> approve_slice!(repo, work_request)

    feature_b_slice =
      repo
      |> create_planned_slice!(
        work_request,
        id: "WRS-MCP-DELIVERY-REPO-SCOPE-B",
        target_base_branch: "feature/b",
        branch_pattern: "feat/b"
      )
      |> approve_slice!(repo, work_request)

    feature_a_package =
      create_matching_work_package!(repo, work_request, feature_a_slice,
        id: "WP-MCP-DELIVERY-REPO-SCOPE-A",
        status: "reviewing"
      )

    feature_b_package =
      create_matching_work_package!(repo, work_request, feature_b_slice,
        id: "WP-MCP-DELIVERY-REPO-SCOPE-B",
        status: "reviewing"
      )

    assert {:ok, _feature_a_dispatched} =
             WorkRequestRepository.dispatch_planned_slice(
               repo,
               work_request.id,
               feature_a_slice.id,
               "approved",
               feature_a_package.id
             )

    assert {:ok, _feature_b_dispatched} =
             WorkRequestRepository.dispatch_planned_slice(
               repo,
               work_request.id,
               feature_b_slice.id,
               "approved",
               feature_b_package.id
             )

    primary_session =
      create_work_request_architect_session(repo, work_request, ["read:work_request"])

    primary_payload = delivery_board_payload_for(repo, primary_session, work_request)

    assert slice_work_package(primary_payload, feature_a_slice.id)["id"] == feature_a_package.id
    assert slice_work_package(primary_payload, feature_b_slice.id)["id"] == feature_b_package.id

    {_anchor, feature_a_session, _grant} =
      create_phase_architect_session(
        repo,
        "SYMPP-ARCHITECT-WR-REPO-SCOPE-DELIVERY",
        ["read:work_request", "write:work_request"],
        repo: work_request.repo,
        base_branch: "feature/a"
      )

    scoped_payload = delivery_board_payload_for(repo, feature_a_session, work_request)

    assert get_in(scoped_payload, ["scope", "repo"]) == work_request.repo
    assert get_in(scoped_payload, ["scope", "base_branch"]) == "feature/a"
    assert slice_work_package(scoped_payload, feature_a_slice.id)["id"] == feature_a_package.id
    assert slice_by_id(scoped_payload, feature_b_slice.id)["work_package"] == nil
    assert slice_by_id(scoped_payload, feature_b_slice.id)["work_package_hidden?"] == true
    refute inspect(scoped_payload) =~ feature_b_package.id

    hidden_closeout_response =
      record_delivery(
        repo,
        feature_a_session,
        no_pr_args(
          work_request,
          feature_b_slice,
          "delivery-mcp-repo-scope-hidden-no-pr",
          "Hidden delivery-base closeout."
        )
      )

    assert get_in(hidden_closeout_response, ["error", "code"]) == -32_004
    assert get_in(hidden_closeout_response, ["error", "data", "reason"]) == "not_found"
  end

  test "WR architect reconciles merged PR evidence over stale package grant state", %{repo: repo} do
    {work_request, planned_slice, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-MCP-DELIVERY-RECONCILE-MERGED-STALE",
        work_package_status: "ready_for_merge"
      )

    session =
      create_work_request_architect_session(repo, work_request, [
        "read:work_request",
        "write:work_request"
      ])

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)

    assert {:ok, _assignment} =
             AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-stale-after-merge")

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Merged PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/#{linked_package.repo}/pull/91",
                 repository: linked_package.repo,
                 number: 91,
                 base_branch: linked_package.base_branch,
                 head_sha: "head-dogfood",
                 merged: true,
                 merged_at: "2026-05-28T12:00:00Z",
                 merge_commit_sha: "merge-91"
               }
             })

    dry_run_response = reconcile_request(repo, session, %{"work_request_id" => work_request.id})
    dry_run_payload = get_in(dry_run_response, ["result", "structuredContent", "reconciliation"])

    assert dry_run_payload["mode"] == "dry_run"
    assert dry_run_payload["proposed_count"] == 1

    assert [
             %{
               "planned_slice_id" => proposed_slice_id,
               "status" => "proposed",
               "reason" => "github_pr_merged"
             }
           ] = dry_run_payload["results"]

    assert proposed_slice_id == planned_slice.id
    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
    refute repo.get!(AccessGrant, minted.grant.id).revoked_at

    apply_response =
      reconcile_request(repo, session, %{"work_request_id" => work_request.id, "apply" => true})

    apply_payload = get_in(apply_response, ["result", "structuredContent"])

    assert get_in(apply_payload, ["reconciliation", "mode"]) == "apply"
    assert get_in(apply_payload, ["reconciliation", "applied_count"]) == 1
    assert get_in(apply_payload, ["delivery_board", "counts", "delivered"]) == 1
    refute Map.has_key?(apply_payload["delivery_board"], "slices")
    assert repo.get!(WorkPackage, linked_package.id).status == "merged"
    assert repo.get!(AccessGrant, minted.grant.id).revoked_at
  end

  test "WR architect read-only grants cannot mutate delivery closeout state", %{repo: repo} do
    {work_request, planned_slice, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-MCP-DELIVERY-READONLY",
        work_package_status: "ready_for_merge"
      )

    session = create_work_request_architect_session(repo, work_request, ["read:work_request"])
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)

    dry_run_response = reconcile_request(repo, session, %{"work_request_id" => work_request.id})

    assert get_in(dry_run_response, ["result", "structuredContent", "reconciliation", "mode"]) ==
             "dry_run"

    apply_response =
      reconcile_request(repo, session, %{"work_request_id" => work_request.id, "apply" => true})

    assert insufficient_capability?(apply_response)

    invalid_closeout_response = record_delivery(repo, session, %{})
    assert insufficient_capability?(invalid_closeout_response)

    closeout_response =
      record_delivery(
        repo,
        session,
        no_pr_args(
          work_request,
          planned_slice,
          "delivery-mcp-readonly-closeout",
          "Read-only architects cannot close delivery."
        )
      )

    assert insufficient_capability?(closeout_response)

    revoke_response =
      revoke_worker_key(
        repo,
        session,
        revoke_args(
          work_request,
          planned_slice,
          minted.grant.id,
          "Read-only architects cannot revoke worker grants."
        )
      )

    assert insufficient_capability?(revoke_response)
    refute repo.get!(AccessGrant, minted.grant.id).revoked_at
    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
  end

  test "WR architect live grant narrowing overrides stale session write capabilities", %{
    repo: repo
  } do
    {work_request, planned_slice, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-MCP-DELIVERY-LIVE-NARROWED",
        work_package_status: "ready_for_merge"
      )

    session =
      create_work_request_architect_session(repo, work_request, [
        "read:work_request",
        "write:work_request"
      ])

    assert :ok =
             update_grant_capabilities(repo, session.assignment.grant_id, ["read:work_request"])

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)

    dry_run_response = reconcile_request(repo, session, %{"work_request_id" => work_request.id})

    assert get_in(dry_run_response, ["result", "structuredContent", "reconciliation", "mode"]) ==
             "dry_run"

    apply_response =
      reconcile_request(repo, session, %{"work_request_id" => work_request.id, "apply" => true})

    assert insufficient_capability?(apply_response)

    closeout_response =
      record_delivery(
        repo,
        session,
        no_pr_args(
          work_request,
          planned_slice,
          "delivery-mcp-live-narrowed-closeout",
          "Live grant narrowing blocks stale write sessions."
        )
      )

    assert insufficient_capability?(closeout_response)

    revoke_response =
      revoke_worker_key(
        repo,
        session,
        revoke_args(
          work_request,
          planned_slice,
          minted.grant.id,
          "Live grant narrowing blocks stale write sessions."
        )
      )

    assert insufficient_capability?(revoke_response)

    invalid_revoke_response = revoke_worker_key(repo, session, %{})
    assert insufficient_capability?(invalid_revoke_response)

    refute repo.get!(AccessGrant, minted.grant.id).revoked_at
    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
  end

  test "WR architect write-only grants can apply reconciliation without dry-run read", %{
    repo: repo
  } do
    {work_request, _planned_slice, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-MCP-DELIVERY-RECONCILE-WRITEONLY",
        work_package_status: "ready_for_merge"
      )

    session = create_work_request_architect_session(repo, work_request, ["write:work_request"])

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Merged PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/#{linked_package.repo}/pull/92",
                 repository: linked_package.repo,
                 number: 92,
                 base_branch: linked_package.base_branch,
                 head_sha: "head-writeonly",
                 merged: true,
                 merged_at: "2026-05-28T12:00:00Z",
                 merge_commit_sha: "merge-92"
               }
             })

    dry_run_response = reconcile_request(repo, session, %{"work_request_id" => work_request.id})
    assert insufficient_capability?(dry_run_response)

    apply_response =
      reconcile_request(repo, session, %{"work_request_id" => work_request.id, "apply" => true})

    assert get_in(apply_response, [
             "result",
             "structuredContent",
             "reconciliation",
             "applied_count"
           ]) == 1

    assert repo.get!(WorkPackage, linked_package.id).status == "merged"
  end

  test "WR architect read_child_status falls back for dispatched package scope tool errors", %{
    repo: repo
  } do
    {work_request, _planned_slice, linked_package} =
      linked_slice!(repo, work_request_id: "WR-MCP-DELIVERY-STATUS-FALLBACK")

    session =
      create_work_request_architect_session(repo, work_request, ArchitectHandoff.capabilities())

    assert {:ok, _updated_package} =
             WorkPackageRepository.update(repo, linked_package.id, %{
               kind: "phase_child",
               phase_id: ArchitectHandoff.phase_id_for_work_request(work_request),
               parent_id: ArchitectHandoff.anchor_id_for_work_request(work_request),
               allowed_file_globs: ["outside/**"]
             })

    response =
      mcp_tool(repo, session, "read_child_status", %{"work_package_id" => linked_package.id})

    assert get_in(response, ["result", "structuredContent", "work_package", "id"]) ==
             linked_package.id

    assert get_in(response, ["result", "structuredContent", "work_package", "status"]) ==
             linked_package.status
  end

  test "WR architect read_child_status still works for duplicate planned-slice package links", %{
    repo: repo
  } do
    {work_request, _planned_slice, linked_package} =
      linked_slice!(repo, work_request_id: "WR-MCP-DELIVERY-STATUS-DUPLICATE")

    other_slice =
      create_planned_slice!(
        repo,
        work_request,
        id: "WRS-MCP-DELIVERY-STATUS-DUPLICATE-OTHER"
      )

    session =
      create_work_request_architect_session(repo, work_request, ArchitectHandoff.capabilities())

    drop_planned_slice_work_package_unique_index!(repo)

    try do
      repo.update!(
        Ecto.Changeset.change(other_slice,
          status: "dispatched",
          work_package_id: linked_package.id,
          dispatched_at: DateTime.utc_now(:microsecond)
        )
      )

      response =
        mcp_tool(repo, session, "read_child_status", %{"work_package_id" => linked_package.id})

      assert get_in(response, ["result", "structuredContent", "work_package", "id"]) ==
               linked_package.id
    after
      SQL.query!(
        repo,
        "UPDATE sympp_work_request_planned_slices SET work_package_id = NULL, dispatched_at = NULL WHERE id = ?",
        [other_slice.id]
      )

      create_planned_slice_work_package_unique_index!(repo)
    end
  end

  test "WR architect read_child_status fails closed for cross-WorkRequest duplicate links", %{
    repo: repo
  } do
    {work_request, _planned_slice, linked_package} =
      linked_slice!(repo, work_request_id: "WR-MCP-DELIVERY-STATUS-CROSS-DUPLICATE")

    other_work_request =
      sibling_work_request!(
        repo,
        work_request,
        "WR-MCP-DELIVERY-STATUS-CROSS-DUPLICATE-OTHER"
      )

    other_slice =
      create_planned_slice!(
        repo,
        other_work_request,
        id: "WRS-MCP-DELIVERY-STATUS-CROSS-DUPLICATE-OTHER"
      )

    session =
      create_work_request_architect_session(repo, work_request, ArchitectHandoff.capabilities())

    drop_planned_slice_work_package_unique_index!(repo)

    try do
      repo.update!(
        Ecto.Changeset.change(other_slice,
          status: "dispatched",
          work_package_id: linked_package.id,
          dispatched_at: DateTime.utc_now(:microsecond)
        )
      )

      response =
        mcp_tool(repo, session, "read_child_status", %{"work_package_id" => linked_package.id})

      assert get_in(response, ["error", "data", "reason"]) == "ambiguous_planned_slice_link"
    after
      SQL.query!(
        repo,
        "UPDATE sympp_work_request_planned_slices SET work_package_id = NULL, dispatched_at = NULL WHERE id = ?",
        [other_slice.id]
      )

      create_planned_slice_work_package_unique_index!(repo)
    end
  end

  test "WR architect narrowed capabilities do not regain child status calls", %{repo: repo} do
    {work_request, _planned_slice, linked_package} =
      linked_slice!(repo, work_request_id: "WR-MCP-DELIVERY-NARROWED")

    narrowed_capabilities = legacy_work_request_architect_capabilities()

    session =
      repo
      |> create_work_request_architect_session(work_request, ArchitectHandoff.capabilities())
      |> stale_session_capabilities(ArchitectHandoff.capabilities())

    assert :ok =
             update_grant_capabilities(repo, session.assignment.grant_id, narrowed_capabilities)

    tools_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}},
        repo: repo,
        session: session
      )

    tools_by_name = tools_response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(tools_by_name, "read_child_status")

    read_child_response =
      mcp_tool(repo, session, "read_child_status", %{"work_package_id" => linked_package.id})

    assert get_in(read_child_response, ["error", "code"]) == -32_001
    assert get_in(read_child_response, ["error", "data", "reason"]) == "insufficient_capability"
  end

  test "WR architect no-PR closeout retires stale worker grants", %{repo: repo} do
    delivery_base = "feature/revoke-delivery-base"

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-DELIVERY-GRANT-CLOSEOUT",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    planned_slice =
      create_planned_slice!(repo, work_request,
        id: "WRS-MCP-DELIVERY-GRANT-CLOSEOUT",
        target_base_branch: delivery_base,
        branch_pattern: "feat/revoke-delivery-base"
      )

    assert {:ok, approved_slice} =
             WorkRequestRepository.approve_planned_slice(
               repo,
               work_request.id,
               planned_slice.id,
               "planned"
             )

    linked_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "WP-MCP-DELIVERY-GRANT-CLOSEOUT",
        status: "ready_for_merge"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.dispatch_planned_slice(
               repo,
               work_request.id,
               approved_slice.id,
               "approved",
               linked_package.id
             )

    session = create_work_request_architect_session(repo, work_request, ["write:work_request"])

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)

    assert {:ok, _assignment} =
             AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    closeout_args =
      no_pr_args(
        work_request,
        planned_slice,
        "delivery-mcp-stale-grant",
        "Worker reported completion; architect is closing no-PR delivery."
      )

    closeout_response = record_delivery(repo, session, closeout_args)
    closeout_payload = get_in(closeout_response, ["result", "structuredContent"])

    assert closeout_payload["planned_slice_delivery"]["outcome"] == "completed_no_pr"

    assert repo.get!(AccessGrant, minted.grant.id).revoked_at

    closed_package = repo.get!(WorkPackage, linked_package.id)
    assert closed_package.status == "closed"
    assert closed_package.base_branch == delivery_base

    closeout_event =
      Enum.find(
        repo.all(ProgressEvent),
        &(&1.payload["type"] == "work_request_delivery_closeout")
      )

    assert closeout_event.payload["retired_worker_grant_ids"] == [minted.grant.id]
  end

  test "WR architect no-PR closeout still works after explicit worker revoke", %{repo: repo} do
    {work_request, planned_slice, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-MCP-DELIVERY-REVOKE-THEN-NO-PR",
        work_package_status: "ready_for_merge"
      )

    session = create_work_request_architect_session(repo, work_request, ["write:work_request"])

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)

    assert {:ok, _assignment} =
             AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    revoke_response =
      revoke_worker_key(
        repo,
        session,
        revoke_args(
          work_request,
          planned_slice,
          minted.grant.id,
          "Worker is complete; operator is closing without a PR."
        )
      )

    assert get_in(revoke_response, ["result", "structuredContent", "revoked_worker_grant", "id"]) ==
             minted.grant.id

    assert get_in(revoke_response, ["result", "structuredContent", "next_action"]) ==
             "retry_record_planned_slice_delivery"

    refute get_in(revoke_response, ["result", "structuredContent", "work_request"])
    refute get_in(revoke_response, ["result", "structuredContent", "revocation_event"])

    closeout_response =
      record_delivery(
        repo,
        session,
        no_pr_args(
          work_request,
          planned_slice,
          "delivery-mcp-after-explicit-revoke",
          "Worker was explicitly revoked before no-PR closeout."
        )
      )

    assert get_in(closeout_response, [
             "result",
             "structuredContent",
             "planned_slice_delivery",
             "outcome"
           ]) == "completed_no_pr"

    assert repo.get!(WorkPackage, linked_package.id).status == "closed"

    closeout_event =
      Enum.find(
        repo.all(ProgressEvent),
        &(&1.payload["type"] == "work_request_delivery_closeout")
      )

    assert "worker_recycled" in closeout_event.payload["runtime_reason_codes_before_closeout"]
  end

  test "WR architect abandons no-code failed dispatch after replacement delivery without explicit revoke or unrelated grants",
       %{repo: repo} do
    {work_request, failed_slice, failed_package} =
      linked_slice!(repo,
        work_request_id: "WR-MCP-DELIVERY-ABANDON-FAILED-DISPATCH",
        work_package_status: "ready_for_worker"
      )

    session = create_work_request_architect_session(repo, work_request, ["write:work_request"])

    assert {:ok, failed_minted} = AccessGrantService.mint_worker_grant(repo, failed_package.id)

    oracle_slice = create_planned_slice!(repo, work_request, id: "WRS-MCP-DELIVERY-ORACLE-ACTIVE")

    assert {:ok, approved_oracle} =
             WorkRequestRepository.approve_planned_slice(
               repo,
               work_request.id,
               oracle_slice.id,
               "planned"
             )

    oracle_package =
      create_matching_work_package!(repo, work_request, approved_oracle,
        id: "WP-MCP-DELIVERY-ORACLE-ACTIVE",
        status: "ready_for_worker"
      )

    assert {:ok, _oracle_dispatch} =
             WorkRequestRepository.dispatch_planned_slice(
               repo,
               work_request.id,
               approved_oracle.id,
               "approved",
               oracle_package.id
             )

    assert {:ok, oracle_minted} = AccessGrantService.mint_worker_grant(repo, oracle_package.id)

    assert {:ok, _oracle_assignment} =
             AccessGrantService.claim(repo, oracle_minted.work_key.secret, claimed_by: "oracle-worker")

    replacement_slice =
      create_planned_slice!(repo, work_request, id: "WRS-MCP-DELIVERY-REPLACEMENT")

    assert {:ok, approved_replacement} =
             WorkRequestRepository.approve_planned_slice(
               repo,
               work_request.id,
               replacement_slice.id,
               "planned"
             )

    replacement_package =
      create_matching_work_package!(repo, work_request, approved_replacement,
        id: "WP-MCP-DELIVERY-REPLACEMENT",
        status: "ready_for_merge"
      )

    assert {:ok, dispatched_replacement} =
             WorkRequestRepository.dispatch_planned_slice(
               repo,
               work_request.id,
               approved_replacement.id,
               "approved",
               replacement_package.id
             )

    replacement_response =
      record_delivery(
        repo,
        session,
        pr_merged_args(work_request, dispatched_replacement, "delivery-mcp-replacement-pr")
      )

    assert get_in(replacement_response, [
             "result",
             "structuredContent",
             "planned_slice_delivery",
             "outcome"
           ]) == "pr_merged"

    assert repo.get!(WorkPackage, replacement_package.id).status == "merged"

    revoke_response =
      revoke_worker_key(
        repo,
        session,
        revoke_args(
          work_request,
          failed_slice,
          failed_minted.grant.id,
          "Failed bootstrap before implementation."
        )
      )

    assert get_in(revoke_response, ["error", "data", "reason"]) ==
             "work_package_not_closeout_ready"

    refute repo.get!(AccessGrant, failed_minted.grant.id).revoked_at

    abandon_response =
      record_delivery(
        repo,
        session,
        abandoned_args(
          work_request,
          failed_slice,
          "delivery-mcp-abandoned-failed-dispatch",
          "Wildcard branch dispatch failed before implementation; replacement slice already delivered."
        )
      )

    assert get_in(abandon_response, [
             "result",
             "structuredContent",
             "planned_slice_delivery",
             "outcome"
           ]) == "abandoned"

    assert repo.get!(WorkPackage, failed_package.id).status == "abandoned"
    assert repo.get!(AccessGrant, failed_minted.grant.id).revoked_at

    refute repo.get!(AccessGrant, oracle_minted.grant.id).revoked_at
    assert repo.get!(WorkPackage, oracle_package.id).status == "ready_for_worker"
  end

  test "abandoned delivery closeout reports currently non-abandonable packages as preconditions",
       %{repo: repo} do
    {work_request, planned_slice, _linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-MCP-DELIVERY-ABANDONED-BLOCKED",
        work_package_status: "blocked"
      )

    session =
      create_work_request_architect_session(repo, work_request, ArchitectHandoff.capabilities())

    response =
      record_delivery(
        repo,
        session,
        abandoned_args(
          work_request,
          planned_slice,
          "delivery-mcp-abandoned-blocked",
          "Currently blocked packages should be superseded rather than hidden as no-code abandonments."
        )
      )

    assert get_in(response, ["error", "code"]) == -32_009
    assert get_in(response, ["error", "data", "decision_reason"]) == "precondition_denied"
    assert get_in(response, ["error", "data", "reason"]) == "work_package_not_abandonable"
    assert get_in(response, ["error", "data", "reason_code"]) == "work_package_not_abandonable"
  end

  test "workers and out-of-scope WR architects cannot record or revoke delivery", %{repo: repo} do
    {work_request, planned_slice, linked_package} =
      linked_slice!(repo, work_request_id: "WR-MCP-DELIVERY-SCOPED")

    worker_session = create_worker_session(repo, linked_package)

    args =
      no_pr_args(
        work_request,
        planned_slice,
        "delivery-mcp-denied",
        "Denied closeout should not be recorded."
      )

    worker_response = record_delivery(repo, worker_session, args)
    assert get_in(worker_response, ["error", "data", "reason"]) == "architect_grant_required"

    invalid_worker_response = record_delivery(repo, worker_session, %{})

    assert get_in(invalid_worker_response, ["error", "data", "reason"]) ==
             "architect_grant_required"

    worker_revoke_response =
      revoke_worker_key(
        repo,
        worker_session,
        revoke_args(work_request, planned_slice, "grant-denied", "Denied")
      )

    assert get_in(worker_revoke_response, ["error", "data", "reason"]) ==
             "architect_grant_required"

    sibling_request = sibling_work_request!(repo, work_request, "WR-MCP-DELIVERY-SIBLING")

    sibling_session =
      create_work_request_architect_session(repo, sibling_request, ["write:work_request"])

    sibling_response = record_delivery(repo, sibling_session, args)
    assert get_in(sibling_response, ["error", "code"]) == -32_004
    assert get_in(sibling_response, ["error", "data", "reason"]) == "not_found"

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)

    sibling_revoke_response =
      revoke_worker_key(
        repo,
        sibling_session,
        revoke_args(work_request, planned_slice, minted.grant.id, "Denied")
      )

    assert get_in(sibling_revoke_response, ["error", "code"]) == -32_004
    assert get_in(sibling_revoke_response, ["error", "data", "reason"]) == "not_found"
    refute repo.get!(AccessGrant, minted.grant.id).revoked_at

    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
  end

  test "delivery closeout refuses out-of-scope or mismatched successors", %{repo: repo} do
    {work_request, planned_slice, _linked_package} =
      linked_slice!(repo, work_request_id: "WR-MCP-DELIVERY-SUCCESSOR-SCOPE")

    successor_slice = create_planned_slice!(repo, work_request, id: "WRS-MCP-DELIVERY-SUCCESSOR")
    session = create_work_request_architect_session(repo, work_request, ["write:work_request"])

    assert {:ok, approved_successor} =
             WorkRequestRepository.approve_planned_slice(
               repo,
               work_request.id,
               successor_slice.id,
               "planned"
             )

    successor_package =
      create_matching_work_package!(repo, work_request, approved_successor,
        id: "WP-MCP-DELIVERY-SUCCESSOR",
        status: "reviewing"
      )

    assert {:ok, successor_slice} =
             WorkRequestRepository.dispatch_planned_slice(
               repo,
               work_request.id,
               approved_successor.id,
               "approved",
               successor_package.id
             )

    sibling_request =
      sibling_work_request!(repo, work_request, "WR-MCP-DELIVERY-SUCCESSOR-SIBLING")

    sibling_successor_slice =
      create_planned_slice!(repo, sibling_request, id: "WRS-MCP-DELIVERY-SUCCESSOR-SIBLING")

    sibling_response =
      record_delivery(
        repo,
        session,
        superseded_args(
          work_request,
          planned_slice,
          "delivery-mcp-successor-slice-out-of-scope",
          sibling_successor_slice.id,
          "Recut to a sibling request."
        )
      )

    assert get_in(sibling_response, ["error", "data", "reason"]) ==
             "successor_planned_slice_out_of_scope"

    other_successor_slice =
      create_planned_slice!(repo, work_request, id: "WRS-MCP-DELIVERY-SUCCESSOR-OTHER")

    assert {:ok, approved_other_successor} =
             WorkRequestRepository.approve_planned_slice(
               repo,
               work_request.id,
               other_successor_slice.id,
               "planned"
             )

    other_successor_package =
      create_matching_work_package!(repo, work_request, approved_other_successor,
        id: "WP-MCP-DELIVERY-SUCCESSOR-OTHER",
        status: "reviewing"
      )

    assert {:ok, _dispatched_other_successor} =
             WorkRequestRepository.dispatch_planned_slice(
               repo,
               work_request.id,
               approved_other_successor.id,
               "approved",
               other_successor_package.id
             )

    response =
      record_delivery(
        repo,
        session,
        superseded_args(
          work_request,
          planned_slice,
          "delivery-mcp-successor-out-of-scope",
          successor_slice.id,
          "Recut to a narrower package.",
          other_successor_package.id
        )
      )

    assert get_in(response, ["error", "data", "reason"]) ==
             "successor_work_package_slice_mismatch"

    _success_response =
      record_delivery(
        repo,
        session,
        superseded_args(
          work_request,
          planned_slice,
          "delivery-mcp-successor-visible",
          successor_slice.id,
          "Recut to a narrower package.",
          successor_package.id
        )
      )

    assert [delivery] =
             PlannedSliceDelivery
             |> repo.all()
             |> Enum.filter(&(&1.planned_slice_id == planned_slice.id))

    assert delivery.successor_work_package_id == successor_package.id
  end

  test "superseded closeout returns structured error for duplicate successor package links", %{
    repo: repo
  } do
    {work_request, planned_slice, _linked_package} =
      linked_slice!(repo, work_request_id: "WR-MCP-DELIVERY-SUCCESSOR-DUPLICATE")

    successor_slice =
      create_planned_slice!(repo, work_request, id: "WRS-MCP-DELIVERY-SUCCESSOR-DUPLICATE")

    session = create_work_request_architect_session(repo, work_request, ["write:work_request"])

    assert {:ok, approved_successor} =
             WorkRequestRepository.approve_planned_slice(
               repo,
               work_request.id,
               successor_slice.id,
               "planned"
             )

    successor_package =
      create_matching_work_package!(repo, work_request, approved_successor,
        id: "WP-MCP-DELIVERY-SUCCESSOR-DUPLICATE",
        status: "reviewing"
      )

    assert {:ok, dispatched_successor} =
             WorkRequestRepository.dispatch_planned_slice(
               repo,
               work_request.id,
               approved_successor.id,
               "approved",
               successor_package.id
             )

    duplicate_successor_slice =
      create_planned_slice!(repo, work_request, id: "WRS-MCP-DELIVERY-SUCCESSOR-DUPLICATE-OTHER")

    drop_planned_slice_work_package_unique_index!(repo)

    try do
      repo.update!(
        Ecto.Changeset.change(duplicate_successor_slice,
          status: "dispatched",
          work_package_id: successor_package.id,
          dispatched_at: DateTime.utc_now(:microsecond)
        )
      )

      response =
        record_delivery(
          repo,
          session,
          superseded_args(
            work_request,
            planned_slice,
            "delivery-mcp-successor-duplicate-package-link",
            dispatched_successor.id,
            "Recut to a successor package with ambiguous duplicate links.",
            successor_package.id
          )
        )

      assert get_in(response, ["error", "data", "reason"]) == "ambiguous_planned_slice_link"
      assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
    after
      SQL.query!(
        repo,
        """
        UPDATE sympp_work_request_planned_slices
        SET work_package_id = NULL, dispatched_at = NULL
        WHERE id = ?
        """,
        [duplicate_successor_slice.id]
      )

      create_planned_slice_work_package_unique_index!(repo)
    end
  end

  defp linked_slice!(repo, overrides) do
    request_id = Keyword.fetch!(overrides, :work_request_id)
    work_package_status = Keyword.get(overrides, :work_package_status, "reviewing")
    work_request = create_work_request!(repo, id: request_id, status: "ready_for_slicing")
    planned_slice = create_planned_slice!(repo, work_request, id: "WRS-#{request_id}")

    assert {:ok, approved_slice} =
             WorkRequestRepository.approve_planned_slice(
               repo,
               work_request.id,
               planned_slice.id,
               "planned"
             )

    linked_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "WP-#{request_id}",
        status: work_package_status
      )

    assert {:ok, dispatched_slice} =
             WorkRequestRepository.dispatch_planned_slice(
               repo,
               work_request.id,
               approved_slice.id,
               "approved",
               linked_package.id
             )

    {work_request, dispatched_slice, linked_package}
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp sibling_work_request!(repo, work_request, id) do
    create_work_request!(repo,
      id: id,
      repo: work_request.repo,
      base_branch: work_request.base_branch,
      status: "ready_for_slicing"
    )
  end

  defp create_planned_slice!(repo, work_request, overrides) do
    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(overrides)
             )

    planned_slice
  end

  defp approve_slice!(%PlannedSlice{} = planned_slice, repo, %WorkRequest{} = work_request) do
    assert {:ok, approved_slice} =
             WorkRequestRepository.approve_planned_slice(
               repo,
               work_request.id,
               planned_slice.id,
               "planned"
             )

    approved_slice
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
        acceptance_criteria: planned_slice.acceptance_criteria
      ]
      |> Keyword.merge(overrides)
      |> WorkPackageFactory.attrs()

    assert {:ok, work_package} = WorkPackageRepository.create(repo, attrs)
    work_package
  end

  defp create_work_request_architect_session(repo, %WorkRequest{} = work_request, capabilities) do
    phase_id = ArchitectHandoff.phase_id_for_work_request(work_request)

    assert {:ok, _phase} =
             PhaseRepository.create(repo, %{
               id: phase_id,
               title: "Architect handoff for #{work_request.id}"
             })

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

    assert {:ok, assignment} =
             AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "architect-1")

    MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
  end

  defp update_grant_capabilities(repo, grant_id, capabilities) do
    grant = repo.get!(AccessGrant, grant_id)

    case repo.update(AccessGrant.changeset(grant, %{capabilities: capabilities})) do
      {:ok, _grant} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stale_session_capabilities(%Session{} = session, capabilities) do
    %{session | assignment: %{session.assignment | capabilities: capabilities}}
  end

  defp create_worker_session(repo, %WorkPackage{} = work_package) do
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)

    assert {:ok, assignment} =
             AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
  end

  defp no_pr_args(work_request, planned_slice, idempotency_key, evidence) do
    %{
      "work_request_id" => work_request.id,
      "planned_slice_id" => planned_slice.id,
      "outcome" => "completed_no_pr",
      "idempotency_key" => idempotency_key,
      "evidence" => %{"completed_no_pr" => %{"no_pr_evidence" => evidence}}
    }
  end

  defp pr_merged_args(work_request, planned_slice, idempotency_key) do
    %{
      "work_request_id" => work_request.id,
      "planned_slice_id" => planned_slice.id,
      "outcome" => "pr_merged",
      "idempotency_key" => idempotency_key,
      "evidence" => %{
        "pr_merged" => %{
          "pr_url" => "https://github.com/nextide/symphony-plus-plus/pull/24",
          "pr_number" => 24,
          "pr_repository" => "nextide/symphony-plus-plus",
          "pr_merged_at" => "2026-05-28T12:00:00Z",
          "merge_commit_sha" => "abc24"
        }
      }
    }
  end

  defp abandoned_args(work_request, planned_slice, idempotency_key, rationale) do
    %{
      "work_request_id" => work_request.id,
      "planned_slice_id" => planned_slice.id,
      "outcome" => "abandoned",
      "idempotency_key" => idempotency_key,
      "evidence" => %{"abandoned" => %{"abandoned_rationale" => rationale}}
    }
  end

  defp revoke_args(work_request, planned_slice, grant_id, reason) do
    %{
      "work_request_id" => work_request.id,
      "planned_slice_id" => planned_slice.id,
      "grant_id" => grant_id,
      "reason" => reason
    }
  end

  defp legacy_work_request_architect_capabilities do
    ArchitectHandoff.capabilities() -- ["read:child_progress", "read:child_findings"]
  end

  defp superseded_args(
         work_request,
         planned_slice,
         idempotency_key,
         successor_planned_slice_id,
         reason,
         successor_work_package_id \\ nil
       ) do
    %{
      "work_request_id" => work_request.id,
      "planned_slice_id" => planned_slice.id,
      "outcome" => "superseded",
      "idempotency_key" => idempotency_key,
      "evidence" =>
        %{
          "superseded" => %{
            "superseded_reason" => reason,
            "successor_planned_slice_id" => successor_planned_slice_id
          }
        }
        |> put_in_if_present(["superseded", "successor_work_package_id"], successor_work_package_id)
    }
  end

  defp put_in_if_present(attrs, _path, nil), do: attrs
  defp put_in_if_present(attrs, path, value), do: put_in(attrs, path, value)

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

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-MCP-DELIVERY-#{System.unique_integer([:positive])}",
      title: "Expose delivery MCP tools",
      repo: "nextide/example",
      base_branch: "main",
      work_type: "feature",
      human_description: "Expose delivery-board and closeout through MCP.",
      constraints: %{
        "allowed_paths" => ["elixir/lib"],
        "forbidden_paths" => [],
        "requires_secret" => false
      },
      desired_dispatch_shape: "architect_led_feature_branch"
    }

    Enum.into(overrides, defaults)
  end

  defp planned_slice_attrs(overrides) do
    defaults = %{
      id: "WRS-MCP-DELIVERY-#{System.unique_integer([:positive])}",
      title: "Delivery MCP slice",
      goal: "Close delivered planned slices through MCP.",
      work_package_kind: "mcp",
      target_base_branch: "main",
      branch_pattern: "feat/mcp-delivery",
      owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Delivery MCP tools are scoped."],
      validation_steps: [
        "mix test test/symphony_elixir/symphony_plus_plus/mcp_delivery_tools_test.exs"
      ],
      review_lanes: ["normal"],
      stop_conditions: ["Do not expose broad package visibility."]
    }

    Enum.into(overrides, defaults)
  end

  defp record_delivery(repo, session, arguments),
    do: mcp_tool(repo, session, "record_planned_slice_delivery", arguments)

  defp reconcile_request(repo, session, arguments),
    do: mcp_tool(repo, session, "reconcile_work_request", arguments)

  defp revoke_worker_key(repo, session, arguments),
    do: mcp_tool(repo, session, "revoke_planned_slice_worker_key", arguments)

  defp delivery_board_payload_for(repo, session, %WorkRequest{} = work_request) do
    response =
      mcp_tool(repo, session, "read_delivery_board", %{
        "work_request_id" => work_request.id
      })

    assert response["error"] == nil
    get_in(response, ["result", "structuredContent"])
  end

  defp slice_work_package(payload, planned_slice_id) do
    payload
    |> slice_by_id(planned_slice_id)
    |> Map.get("work_package")
  end

  defp slice_by_id(payload, planned_slice_id) do
    payload
    |> get_in(["delivery_board", "slices"])
    |> Enum.find(&(&1["id"] == planned_slice_id))
  end

  defp insufficient_capability?(response) do
    get_in(response, ["error", "code"]) in [-32_001, -32_003] and
      get_in(response, ["error", "data", "reason"]) == "insufficient_capability" and
      get_in(response, ["error", "data", "reason_code"]) in [nil, "insufficient_capability"]
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
