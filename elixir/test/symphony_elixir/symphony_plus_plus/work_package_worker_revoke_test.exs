Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackageWorkerRevokeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.GrantScope
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Session}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.SessionBinding
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{ArchitectHandoff, WorkRequest}
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
    schemas =
      [
        ProgressEvent,
        WorkPackageDelivery,
        WorkPackage,
        SessionBinding,
        AgentRun,
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

  test "architect recycles in-progress work-package worker authority before superseded closeout", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, "implementing")
    successor_slice = create_work_package!(repo, work_request, "WRS-MCP-DELIVERY-IN-PROGRESS-SUCCESSOR")
    session = create_work_request_architect_session(repo, work_request)

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "active-worker")

    closeout_args = superseded_args(work_request, work_package, successor_slice.id)

    active_response = mcp_tool(repo, session, "record_work_package_delivery", closeout_args)
    assert get_in(active_response, ["error", "data", "reason"]) == "active_runtime"
    assert get_in(active_response, ["error", "data", "next_action"]) == "release_worker_or_retry_after_stale"

    revoke_response =
      mcp_tool(repo, session, "revoke_work_package_worker_key", %{
        "work_request_id" => work_request.id,
        "work_package_id" => work_package.id,
        "grant_id" => minted.grant.id,
        "reason" => "Worker is being recut and the old runtime authority must be recycled."
      })

    revoke_payload = get_in(revoke_response, ["result", "structuredContent"])
    assert revoke_payload["work_package"]["id"] == linked_package.id
    assert revoke_payload["work_package"]["status"] == "blocked"
    assert revoke_payload["revoked_worker_grant"]["id"] == minted.grant.id
    assert revoke_payload["next_action"] == "retry_record_work_package_delivery"

    assert revoke_payload["closeout_affordance"]["reason_codes"] == [
             "worker_recycled",
             "work_package_worker_key_revoked",
             "work_package_blocked_for_recycle"
           ]

    assert revoke_payload["closeout_affordance"]["previous_work_package_status"] == "implementing"
    assert revoke_payload["closeout_affordance"]["work_package_status"] == "blocked"
    assert is_binary(get_in(revoke_payload, ["audit_event", "id"]))
    refute Map.has_key?(revoke_payload, "revocation_event")
    assert repo.get!(AccessGrant, minted.grant.id).revoked_at
    assert repo.get!(WorkPackage, linked_package.id).status == "blocked"

    closeout_response = mcp_tool(repo, session, "record_work_package_delivery", closeout_args)

    assert get_in(closeout_response, ["result", "structuredContent", "work_package_delivery", "outcome"]) == "superseded"
    assert repo.get!(WorkPackage, linked_package.id).status == "closed"
  end

  test "architect cleanup recycles linked worker grant claim lease and recoverable MCP binding before superseded closeout", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, "implementing")
    successor_slice = create_work_package!(repo, work_request, "WRS-MCP-DELIVERY-RUNTIME-CLEANUP-SUCCESSOR")
    session = create_work_request_architect_session(repo, work_request)

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "active-worker")
    assert {:ok, child_minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id, provenance: "child_worker_delegation")
    assert {:ok, _assignment} = AccessGrantService.claim(repo, child_minted.work_key.secret, claimed_by: "delegated-worker")

    assert {:ok, claim_lease} =
             ClaimLeaseService.claim(repo, linked_package.id, local_worker_actor("active-worker"),
               access_grant_id: minted.grant.id,
               stale_after_ms: 60_000
             )

    session_binding = insert_recoverable_session_binding!(repo, linked_package.id, minted.grant.id, claim_lease)

    non_worker_binding =
      insert_recoverable_session_binding!(repo, linked_package.id, minted.grant.id, claim_lease,
        id_suffix: "#{linked_package.id}-architect",
        grant_role: "architect"
      )

    other_binding = insert_recoverable_session_binding!(repo, "WP-OUTSIDE-RUNTIME-CLEANUP", minted.grant.id, claim_lease)

    closeout_args = superseded_args(work_request, work_package, successor_slice.id)

    active_response = mcp_tool(repo, session, "record_work_package_delivery", closeout_args)
    assert get_in(active_response, ["error", "data", "reason"]) == "active_runtime"
    assert get_in(active_response, ["error", "data", "next_action"]) == "release_worker_or_retry_after_stale"

    cleanup_response =
      mcp_tool(repo, session, "cleanup_work_request_work_package_runtime", cleanup_args(work_request, work_package, successor_slice.id))

    cleanup_payload = get_in(cleanup_response, ["result", "structuredContent"])
    assert cleanup_payload["work_package"]["id"] == linked_package.id
    assert cleanup_payload["work_package"]["status"] == "implementing"
    assert cleanup_payload["runtime_cleanup"]["status"] == "cleaned"
    assert Enum.sort(cleanup_payload["runtime_cleanup"]["revoked_worker_grant_ids"]) == Enum.sort([minted.grant.id, child_minted.grant.id])
    assert cleanup_payload["runtime_cleanup"]["released_claim_lease_ids"] == [claim_lease.id]
    assert cleanup_payload["runtime_cleanup"]["cleared_mcp_session_binding_ids"] == [session_binding.id]
    assert "claim_leases_released" in cleanup_payload["runtime_cleanup"]["reason_codes"]
    assert "mcp_session_bindings_cleared" in cleanup_payload["runtime_cleanup"]["reason_codes"]

    assert repo.get!(AccessGrant, minted.grant.id).revoked_at
    assert repo.get!(AccessGrant, child_minted.grant.id).revoked_at
    assert %ClaimLease{status: "released", release_reason: "work_request_runtime_cleanup"} = repo.get!(ClaimLease, claim_lease.id)
    refute repo.get(SessionBinding, session_binding.id)
    assert repo.get(SessionBinding, non_worker_binding.id)
    assert repo.get(SessionBinding, other_binding.id)

    assert is_binary(get_in(cleanup_payload, ["audit_event", "id"]))

    event_payload =
      repo.all(ProgressEvent)
      |> Enum.map(& &1.payload)
      |> Enum.find(&(&1["source_tool"] == "cleanup_work_request_work_package_runtime"))

    assert event_payload["source_tool"] == "cleanup_work_request_work_package_runtime"
    assert event_payload["work_request_id"] == work_request.id
    assert event_payload["work_package_id"] == work_package.id
    assert get_in(event_payload, ["delivery_evidence", "outcome"]) == "superseded"
    assert get_in(event_payload, ["delivery_evidence", "successor_work_package_id"]) == successor_slice.id

    closeout_response = mcp_tool(repo, session, "record_work_package_delivery", closeout_args)

    assert get_in(closeout_response, ["result", "structuredContent", "work_package_delivery", "outcome"]) == "superseded"
    assert repo.get!(WorkPackage, linked_package.id).status == "closed"
  end

  test "architect cleanup allows abandoned no-code closeout after claimed runtime is recycled", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, "ready_for_worker")
    session = create_work_request_architect_session(repo, work_request)

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "no-code-worker")

    assert {:ok, _claim_lease} =
             ClaimLeaseService.claim(repo, linked_package.id, local_worker_actor("no-code-worker"),
               access_grant_id: minted.grant.id,
               stale_after_ms: 60_000
             )

    cleanup_response =
      mcp_tool(repo, session, "cleanup_work_request_work_package_runtime", abandoned_cleanup_args(work_request, work_package))

    assert get_in(cleanup_response, ["result", "structuredContent", "runtime_cleanup", "status"]) == "cleaned"

    abandoned_response =
      mcp_tool(repo, session, "record_work_package_delivery", %{
        "work_request_id" => work_request.id,
        "work_package_id" => work_package.id,
        "outcome" => "abandoned",
        "idempotency_key" => "delivery-abandoned-after-runtime-cleanup",
        "evidence" => %{
          "abandoned" => %{"abandoned_rationale" => "The original no-code dispatch was replaced before implementation started."}
        }
      })

    assert get_in(abandoned_response, ["result", "structuredContent", "work_package_delivery", "outcome"]) == "abandoned"
    assert repo.get!(WorkPackage, linked_package.id).status == "abandoned"
  end

  test "architect cleanup rejects missing delivery evidence without mutating runtime", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, "implementing")
    session = create_work_request_architect_session(repo, work_request)

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "active-worker")

    response =
      mcp_tool(repo, session, "cleanup_work_request_work_package_runtime", %{
        "work_request_id" => work_request.id,
        "work_package_id" => work_package.id,
        "reason" => "No terminal delivery evidence is attached."
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "missing_outcome"
    refute repo.get!(AccessGrant, minted.grant.id).revoked_at
    refute Enum.any?(repo.all(ProgressEvent), &(&1.payload["source_tool"] == "cleanup_work_request_work_package_runtime"))
  end

  test "architect cleanup rejects abandoned evidence for an implementing package without mutating runtime", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, "implementing")
    session = create_work_request_architect_session(repo, work_request)

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "active-worker")

    response =
      mcp_tool(repo, session, "cleanup_work_request_work_package_runtime", abandoned_cleanup_args(work_request, work_package))

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "work_package_not_abandonable"
    refute repo.get!(AccessGrant, minted.grant.id).revoked_at
    refute Enum.any?(repo.all(ProgressEvent), &(&1.payload["source_tool"] == "cleanup_work_request_work_package_runtime"))
  end

  test "architect cleanup rejects paused claim leases without mutating runtime", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, "implementing")
    successor_slice = create_work_package!(repo, work_request, "WRS-MCP-DELIVERY-PAUSED-SUCCESSOR")
    session = create_work_request_architect_session(repo, work_request)

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "paused-worker")

    assert {:ok, claim_lease} =
             ClaimLeaseService.claim(repo, linked_package.id, local_worker_actor("paused-worker"),
               access_grant_id: minted.grant.id,
               stale_after_ms: 60_000
             )

    assert {:ok, paused_lease} = ClaimLeaseService.pause(repo, claim_lease.id, local_worker_actor("architect"), reason: "operator pause")

    response = mcp_tool(repo, session, "cleanup_work_request_work_package_runtime", cleanup_args(work_request, work_package, successor_slice.id))

    assert get_in(response, ["error", "code"]) == -32_009
    assert get_in(response, ["error", "data", "reason"]) == "active_runtime"
    refute repo.get!(AccessGrant, minted.grant.id).revoked_at
    assert %ClaimLease{status: "paused"} = repo.get!(ClaimLease, paused_lease.id)
    refute Enum.any?(repo.all(ProgressEvent), &(&1.payload["source_tool"] == "cleanup_work_request_work_package_runtime"))
  end

  test "architect cleanup rejects fresh active AgentRun evidence without mutating runtime", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, "implementing")
    successor_slice = create_work_package!(repo, work_request, "WRS-MCP-DELIVERY-AGENT-RUN-SUCCESSOR")
    session = create_work_request_architect_session(repo, work_request)

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)

    assert {:ok, _agent_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: linked_package.id,
               access_grant_id: minted.grant.id,
               actor_id: "active-agent"
             })

    response = mcp_tool(repo, session, "cleanup_work_request_work_package_runtime", cleanup_args(work_request, work_package, successor_slice.id))

    assert get_in(response, ["error", "code"]) == -32_009
    assert get_in(response, ["error", "data", "reason"]) == "active_runtime"
    refute repo.get!(AccessGrant, minted.grant.id).revoked_at
    refute Enum.any?(repo.all(ProgressEvent), &(&1.payload["source_tool"] == "cleanup_work_request_work_package_runtime"))
  end

  test "architect cleanup rejects WorkPackages outside the WorkRequest scope", %{repo: repo} do
    {work_request, _work_package, _linked_package} = linked_slice!(repo, "implementing")
    {other_work_request, other_work_package, _other_package} = linked_slice!(repo, "implementing", "OTHER")
    session = create_work_request_architect_session(repo, work_request)

    response =
      mcp_tool(repo, session, "cleanup_work_request_work_package_runtime", %{
        "work_request_id" => work_request.id,
        "work_package_id" => other_work_package.id,
        "outcome" => "abandoned",
        "abandoned_rationale" => "Attempted abandoned cleanup outside the scoped WorkRequest.",
        "reason" => "Attempted cleanup for a slice from #{other_work_request.id}."
      })

    assert get_in(response, ["error", "code"]) == -32_004
    assert get_in(response, ["error", "data", "reason"]) == "not_found"
  end

  defp linked_slice!(repo, status) do
    linked_slice!(repo, status, "RECYCLE")
  end

  defp linked_slice!(repo, status, suffix) do
    work_request = create_work_request!(repo, suffix)
    work_package = create_work_package!(repo, work_request, "WRS-MCP-DELIVERY-IN-PROGRESS-#{suffix}")
    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

    linked_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "WP-MCP-DELIVERY-IN-PROGRESS-#{suffix}",
        status: status
      )

    assert {:ok, dispatched_slice} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", linked_package.id)

    {work_request, dispatched_slice, linked_package}
  end

  defp create_work_request!(repo, suffix) do
    attrs = %{
      id: "WR-MCP-DELIVERY-IN-PROGRESS-#{suffix}",
      title: "Recycle work-package workers",
      repo: "nextide/example",
      base_branch: "main",
      work_type: "feature",
      human_description: "Recycle runtime authority before superseded closeout.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "architect_led_feature_branch",
      status: "ready_for_slicing"
    }

    assert {:ok, work_request} = WorkRequestRepository.create(repo, attrs)
    work_request
  end

  defp create_work_package!(repo, work_request, id) do
    attrs = %{
      id: id,
      title: "Delivery MCP slice",
      goal: "Close delivered WorkPackages through MCP.",
      kind: "mcp",
      base_branch: "main",
      branch_pattern: "feat/mcp-delivery",
      allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Delivery MCP tools are scoped."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/work_package_worker_revoke_test.exs"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: ["Do not expose broad package visibility."]
    }

    assert {:ok, work_package} = CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, attrs)
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

  defp create_work_request_architect_session(repo, %WorkRequest{} = work_request) do
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
               capabilities: ["write:work_request"]
             )

    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "architect-1")

    MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
  end

  defp superseded_args(work_request, work_package, successor_work_package_id) do
    %{
      "work_request_id" => work_request.id,
      "work_package_id" => work_package.id,
      "outcome" => "superseded",
      "idempotency_key" => "delivery-mcp-in-progress-recut-after-recycle",
      "evidence" => %{
        "superseded" => %{
          "superseded_reason" => "Recut after the old worker authority was explicitly recycled.",
          "successor_work_package_id" => successor_work_package_id
        }
      }
    }
  end

  defp cleanup_args(work_request, work_package, successor_work_package_id) do
    %{
      "work_request_id" => work_request.id,
      "work_package_id" => work_package.id,
      "outcome" => "superseded",
      "successor_work_package_id" => successor_work_package_id,
      "superseded_reason" => "Recut after the old worker authority was explicitly recycled.",
      "reason" => "The linked worker runtime was superseded by established WorkRequest delivery truth."
    }
  end

  defp abandoned_cleanup_args(work_request, work_package) do
    %{
      "work_request_id" => work_request.id,
      "work_package_id" => work_package.id,
      "outcome" => "abandoned",
      "abandoned_rationale" => "The original no-code dispatch was replaced before implementation started.",
      "reason" => "The linked no-code worker runtime is abandoned by established WorkRequest delivery truth."
    }
  end

  defp local_worker_actor(claimed_by) do
    %{
      "actor_kind" => "agent",
      "actor_id" => "local:#{claimed_by}",
      "actor_display_name" => claimed_by
    }
  end

  defp insert_recoverable_session_binding!(repo, work_package_id, access_grant_id, %ClaimLease{} = claim_lease, opts \\ []) do
    now = DateTime.utc_now(:microsecond)
    id_suffix = Keyword.get(opts, :id_suffix, work_package_id)
    grant_role = Keyword.get(opts, :grant_role, "worker")

    attrs = %{
      id: "mcp-http-runtime-cleanup-#{id_suffix}",
      client_key_hash: "client-hash-#{id_suffix}",
      initialized: true,
      recoverable: true,
      recovery_kind: "claim_local_assignment",
      access_grant_id: access_grant_id,
      claim_lease_id: claim_lease.id,
      work_package_id: work_package_id,
      grant_role: grant_role,
      claimed_by: claim_lease.actor_display_name,
      actor_kind: claim_lease.actor_kind,
      actor_id: claim_lease.actor_id,
      actor_display_name: claim_lease.actor_display_name,
      last_seen_at: now
    }

    %SessionBinding{}
    |> SessionBinding.changeset(attrs)
    |> repo.insert!()
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
