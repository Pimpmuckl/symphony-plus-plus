Code.require_file("../../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryCloseoutPausedLeaseTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Session}
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
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
          ClaimLease,
          AccessGrant,
          WorkRequest,
          WorkPackage,
          Phase
        ] do
      repo.delete_all(schema)
    end

    :ok
  end

  test "service delivery closeout releases a paused current claim lease", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-closeout-paused-lease")
    codex_home = Path.join(fixture.root, "codex-home")
    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)
      {work_request, work_package, linked_package} = linked_slice!(repo, work_request_id: "WR-DELIVERY-PAUSED-LEASE")

      assert {:ok, prepared} =
               WorktreeLifecycle.prepare(
                 repo,
                 linked_package.id,
                 %{
                   "repo_root" => fixture.repo_root,
                   "base_branch" => linked_package.base_branch,
                   "branch" => "feat/closeout-paused-lease"
                 },
                 codex_home: codex_home
               )

      claim_lease = pause_claim_lease!(repo, linked_package)
      assert {:ok, _closed} = WorkPackageRepository.update_status(repo, linked_package.id, "ready_for_merge", "closed")

      attrs =
        no_pr_attrs(%{
          idempotency_key: "delivery-paused-claim-lease",
          no_pr_evidence: "The package is terminal and the architect is retiring the paused claim lease."
        })

      assert {:ok, delivery} = WorkRequestService.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
      assert delivery.outcome == "completed_no_pr"
      assert repo.get!(WorkPackage, linked_package.id).status == "closed"

      assert %ClaimLease{status: "released", release_reason: "completed_no_pr_delivery_closeout"} =
               repo.get!(ClaimLease, claim_lease.id)

      assert {:ok, replay} = WorkRequestService.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
      assert replay.id == delivery.id
      assert File.dir?(prepared.worktree_path)

      assert {:ok, _archived} = WorkRequestService.archive(repo, work_request.id)
      Process.sleep(100)
      assert File.dir?(prepared.worktree_path)

      assert {:ok, _cleaned} = WorktreeLifecycle.cleanup(repo, linked_package.id, codex_home: codex_home)
      refute File.exists?(prepared.worktree_path)
    after
      restore_env("CODEX_HOME", previous_codex_home)
    end
  end

  test "MCP record_work_package_delivery releases a paused current claim lease", %{repo: repo} do
    {work_request, work_package, linked_package} = linked_slice!(repo, work_request_id: "WR-MCP-DELIVERY-PAUSED-LEASE")
    session = create_work_request_architect_session(repo, work_request)
    claim_lease = pause_claim_lease!(repo, linked_package)
    assert {:ok, _closed} = WorkPackageRepository.update_status(repo, linked_package.id, "ready_for_merge", "closed")

    args =
      no_pr_args(
        work_request,
        work_package,
        "delivery-mcp-paused-claim-lease",
        "The architect is recording terminal delivery and retiring the paused claim lease."
      )

    response = record_delivery(repo, session, args)

    assert get_in(response, ["result", "structuredContent", "work_package_delivery", "outcome"]) == "completed_no_pr"
    assert repo.get!(WorkPackage, linked_package.id).status == "closed"

    assert %ClaimLease{status: "released", release_reason: "completed_no_pr_delivery_closeout"} =
             repo.get!(ClaimLease, claim_lease.id)
  end

  defp pause_claim_lease!(repo, %WorkPackage{} = work_package) do
    assert {:ok, claim_lease} =
             ClaimLeaseService.claim(
               repo,
               work_package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:paused-closeout", "actor_display_name" => "paused-worker"},
               stale_after_ms: 60_000
             )

    assert {:ok, paused_lease} =
             ClaimLeaseService.pause(
               repo,
               claim_lease.id,
               %{"actor_kind" => "operator", "actor_id" => "operator:pause"},
               reason: "operator paused the worker"
             )

    paused_lease
  end

  defp linked_slice!(repo, overrides) do
    request_id = Keyword.fetch!(overrides, :work_request_id)
    work_request = create_work_request!(repo, id: request_id, status: "ready_for_slicing")
    work_package = create_work_package!(repo, work_request, id: "WRS-#{request_id}")
    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")
    work_package = create_matching_work_package!(repo, work_request, approved_slice, id: "WP-#{request_id}", status: "ready_for_merge")
    assert {:ok, dispatched_slice} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", work_package.id)

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

  defp no_pr_attrs(overrides) do
    %{outcome: "completed_no_pr", recorded_by: "delivery-closeout-test"}
    |> Map.merge(overrides)
  end

  defp no_pr_args(work_request, work_package, idempotency_key, evidence) do
    %{
      "work_request_id" => work_request.id,
      "work_package_id" => work_package.id,
      "outcome" => "completed_no_pr",
      "idempotency_key" => idempotency_key,
      "evidence" => %{"completed_no_pr" => %{"no_pr_evidence" => evidence}}
    }
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-DELIVERY-#{System.unique_integer([:positive])}",
      title: "Close delivered WorkRequest slices",
      repo: "nextide/example",
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
      title: "Close delivered slice",
      goal: "Record terminal delivery state.",
      kind: "mcp",
      base_branch: "main",
      branch_pattern: "feat/delivery-closeout",
      allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Delivery closeout is transactional."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/work_requests/delivery_closeout_paused_lease_test.exs"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: ["Do not bypass phase-child merge semantics."]
    }

    Enum.into(overrides, defaults)
  end

  defp record_delivery(repo, session, arguments), do: mcp_tool(repo, session, "record_work_package_delivery", arguments)

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
    Path.expand("../../../../..", __DIR__)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
