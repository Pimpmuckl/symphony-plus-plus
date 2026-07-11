Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.IntegrationHarnessTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.CreateWork
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Auth, Config, Server}
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  @phase_id "phase-p8-001-integration"
  @architect_capabilities [
    "create:child_work_package",
    "mint:child_worker_key",
    "read:child_progress",
    "read:child_findings",
    "read:phase",
    "approve:child_ready_state",
    "merge:child_into_phase"
  ]

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkPackageRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(Artifact)
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    repo.delete_all(Phase)

    :ok
  end

  test "hotfix package runs through MCP with fake GitHub and review evidence", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               kind: "hotfix",
               repo: "nextide/symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Fix hotfix incident",
               product_description: "A pilot endpoint returns stale data.",
               engineering_scope: "Touch only the cache invalidation path.",
               acceptance_criteria: ["Endpoint returns fresh data.", "Hotfix review evidence exists."],
               review_suite_template: "hotfix"
             })

    session = claim_worker_grant(repo, creation.worker_grant.id, "hotfix-worker")
    assert read_resource(repo, session, "sympp://work-packages/#{creation.work_package.id}/context.md") =~ "Fix hotfix incident"

    update_plan(repo, session)
    append_progress(repo, session, "Hotfix regression passed", "tests_passed", "hotfix-tests")
    advance_worker_to_ci_waiting(repo, session)

    head_sha = "p8-001-hotfix-head"
    attach_branch(repo, session, "agent/SYMPP-P8-001/hotfix", head_sha)
    attach_pr(repo, session, "https://github.com/nextide/symphony-plus-plus/pull/8001", head_sha)
    sync_fake_github(repo, session, 8001, head_sha, ["elixir/lib/symphony_elixir/cache.ex"])
    submit_fake_review_package(repo, session, head_sha, ["fast"])

    response = mcp_tool(repo, session, "mark_ready", %{})

    assert get_in(response, ["result", "structuredContent", "ready"]) == true
    assert get_in(response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"

    assert {:ok, persisted} = WorkPackageRepository.get(repo, creation.work_package.id)
    assert persisted.parent_id == nil
    assert persisted.status == "ready_for_merge"
  end

  test "fake GitHub and review-suite gates drive a CI-friendly MCP package to ready", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P8-001-GATES",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta",
                 status: "ci_waiting",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: ["elixir/lib/**"]
               )
             )

    append_done_plan(repo, package.id)
    session = minted_worker_session(repo, package.id, "gate-worker")
    head_sha = "p8-001-gates-head"

    attach_branch(repo, session, "agent/SYMPP-P8-001/gates", head_sha)
    attach_pr(repo, session, "https://github.com/nextide/symphony-plus-plus/pull/8002", head_sha)
    sync_fake_github(repo, session, 8002, head_sha, ["elixir/lib/symphony_elixir/symphony_plus_plus/readiness.ex"])
    submit_fake_review_package(repo, session, head_sha)
    attach_fake_review_suite_result(repo, session, package.id, head_sha)

    response = mcp_tool(repo, session, "mark_ready", %{})

    assert get_in(response, ["result", "structuredContent", "ready"]) == true
    assert get_in(response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)
    assert Enum.any?(artifacts, &(&1.kind == "github_pr" and &1.path == "github-pr.json"))
    assert Enum.any?(artifacts, &(&1.kind == "review_suite" and &1.path == "review-suite-result.json"))
  end

  test "phase architect delegates two packages through ready approval and merge", %{repo: repo} do
    {anchor, architect_session} = create_architect_session(repo, "SYMPP-P8-001-PHASE-ANCHOR")

    child_a = create_child_work_package(repo, architect_session, "SYMPP-P8-001-PHASE-A")
    child_b = create_child_work_package(repo, architect_session, "SYMPP-P8-001-PHASE-B")

    for {child_id, suffix} <- [{child_a, "a"}, {child_b, "b"}] do
      worker_session = claim_phase_child_worker(repo, architect_session, child_id, "phase-worker-#{suffix}")
      head_sha = "p8-001-phase-head-#{suffix}"

      advance_worker_to_ci_waiting(repo, worker_session)
      attach_phase_child_ready_evidence(repo, worker_session, child_id, head_sha)

      ready_response = mcp_tool(repo, worker_session, "mark_ready", %{})
      assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_architect_merge"

      approval_response =
        mcp_tool(repo, architect_session, "approve_child_ready_state", %{
          "work_package_id" => child_id,
          "rationale" => "Deterministic P8 harness evidence is green.",
          "request_id" => "p8-001-approve-#{suffix}"
        })

      assert get_in(approval_response, ["result", "structuredContent", "work_package", "status"]) == "merging_into_phase"

      merge_response =
        mcp_tool(repo, architect_session, "merge_child_into_phase", %{
          "work_package_id" => child_id,
          "merge_artifact" => %{
            "status" => "merged_into_phase",
            "uri" => "https://github.com/nextide/symphony-plus-plus/pull/80#{suffix}",
            "summary" => "Merged #{child_id} in local harness",
            "commit_sha" => head_sha
          }
        })

      assert get_in(merge_response, ["result", "structuredContent", "work_package", "status"]) == "merged_into_phase"
    end

    board_response = mcp_tool(repo, architect_session, "read_phase_board", %{"phase_id" => anchor.phase_id})

    assert get_in(board_response, ["result", "structuredContent", "summary", "child_count"]) == 2
    assert get_in(board_response, ["result", "structuredContent", "summary", "merged_child_count"]) == 2
    assert get_in(board_response, ["result", "structuredContent", "summary", "open_child_count"]) == 0
  end

  test "security denials reject invalid grants and scope drift", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P8-001-SECURITY"))
    assert {:ok, sibling} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P8-001-SIBLING"))

    local_claim_config = Config.default(repo: repo, mode: :http, local_daemon_trusted: true)
    local_claim_state_key = "integration-security-denials-local-claim"

    assert %{"result" => %{"serverInfo" => %{"name" => "symphony-plus-plus"}}} =
             Server.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => "init-local-claim-security-denial",
                 "method" => "initialize",
                 "params" => %{"protocolVersion" => "2025-03-26", "capabilities" => %{}, "clientInfo" => %{"name" => "test"}}
               },
               Server.new(local_claim_config, state_key: local_claim_state_key)
             )

    missing_package_claim_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "bad-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => %{"work_package_id" => "SYMPP-P8-001-MISSING", "claimed_by" => "worker"}}
        },
        Server.new(local_claim_config, state_key: local_claim_state_key)
      )

    assert get_in(missing_package_claim_response, ["error", "data", "reason"]) == "not_found"

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    session = claim_worker_grant(repo, minted.grant.id, "security-worker")

    sibling_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sibling-read",
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/#{sibling.id}/context.md"}
        },
        repo: repo,
        session: session
      )

    assert get_in(sibling_response, ["error", "data", "reason"]) == "outside_session_scope"

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)

    revoked_response = mcp_tool(repo, session, "append_progress", %{"summary" => "should fail", "idempotency_key" => "revoked"})
    assert get_in(revoked_response, ["error", "data", "reason"]) == "revoked"

    {anchor, architect_session} = create_architect_session(repo, "SYMPP-P8-001-DRIFT-ANCHOR")
    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-p8-001-other", title: "Other phase"})
    assert {:ok, _updated_anchor} = WorkPackageRepository.update(repo, anchor.id, %{phase_id: other_phase.id})

    drift_response = mcp_tool(repo, architect_session, "read_phase_board", %{"phase_id" => @phase_id})
    assert get_in(drift_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  defp create_architect_session(repo, anchor_id) do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: @phase_id, title: "P8 integration phase"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: anchor_id,
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta",
                 allowed_file_globs: ["elixir/lib/**"],
                 phase_id: phase.id,
                 status: "planning"
               )
             )

    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, phase.id,
               work_package_id: anchor.id,
               capabilities: @architect_capabilities
             )

    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "architect-1")
    {anchor, MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)}
  end

  defp create_child_work_package(repo, session, child_id) do
    response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => child_id,
          "title" => "Implement #{child_id}",
          "acceptance_criteria" => ["Complete #{child_id}"],
          "allowed_file_globs" => ["elixir/lib/symphony_elixir/**"]
        }
      })

    assert get_in(response, ["result", "structuredContent", "work_package", "id"]) == child_id
    child_id
  end

  defp claim_phase_child_worker(repo, architect_session, child_id, claimed_by) do
    response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => %{"claimed_by" => claimed_by}
      })

    claim_child_worker_from_mint_response(repo, response, claimed_by)
  end

  defp test_repo_root do
    Path.expand("../../../..", __DIR__)
  end

  defp claim_child_worker_from_mint_response(repo, mint_response, claimed_by) do
    worker_grant = get_in(mint_response, ["result", "structuredContent", "worker_grant"])
    bootstrap_claim = get_in(worker_grant, ["worker_bootstrap", "claim"])
    arguments = Map.fetch!(bootstrap_claim, "arguments")

    assert bootstrap_claim["tool"] == "claim_local_assignment"
    assert arguments["work_package_id"] == worker_grant["work_package_id"]
    assert arguments["claimed_by"] == claimed_by
    refute Map.has_key?(arguments, "caller_id")

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "integration-claim-child-worker-from-bootstrap",
          "method" => "tools/call",
          "params" => %{"name" => bootstrap_claim["tool"], "arguments" => arguments}
        },
        Server.new(
          Config.default(repo: repo, mode: :http, repo_root: test_repo_root(), local_daemon_trusted: true),
          initialized: true,
          state_key: "integration-child-worker-bootstrap-#{worker_grant["id"]}-#{System.unique_integer([:positive])}"
        )
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "grant_id"]) == worker_grant["id"]
    claimed_server.session
  end

  defp claim_worker_grant(repo, grant_id, claimed_by) do
    now = DateTime.utc_now(:microsecond)

    assert {1, _rows} =
             repo.update_all(
               from(grant in AccessGrant, where: grant.id == ^grant_id),
               set: [claimed_at: now, claimed_by: claimed_by, updated_at: now]
             )

    assert {:ok, grant} = AccessGrantRepository.get(repo, grant_id)
    assert {:ok, session} = Auth.session_from_grant(repo, grant, proof_hash: grant.secret_hash)
    session
  end

  defp minted_worker_session(repo, work_package_id, claimed_by) do
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package_id)
    claim_worker_grant(repo, minted.grant.id, claimed_by)
  end

  defp update_plan(repo, session) do
    read_response = mcp_tool(repo, session, "read_task_plan", %{})

    response =
      mcp_tool(repo, session, "update_task_plan", %{
        "expected_version" => get_in(read_response, ["result", "structuredContent", "version"]),
        "id" => "p8-001-harness-proof",
        "title" => "Record deterministic harness proof",
        "status" => "done"
      })

    assert get_in(response, ["result", "structuredContent", "version"])
  end

  defp append_done_plan(repo, work_package_id) do
    assert {:ok, _plan_node} =
             PlanningRepository.append_plan_node(repo, %{
               "work_package_id" => work_package_id,
               "title" => "Complete implementation",
               "status" => "done"
             })
  end

  defp advance_worker_to_ci_waiting(repo, session) do
    [
      {"ready_for_worker", "claimed"},
      {"claimed", "planning"},
      {"planning", "implementing"},
      {"implementing", "reviewing"},
      {"reviewing", "ci_waiting"}
    ]
    |> Enum.each(fn {expected_status, status} ->
      response =
        mcp_tool(repo, session, "set_status", %{
          "expected_status" => expected_status,
          "status" => status,
          "reason" => "advance P8 integration harness flow"
        })

      assert get_in(response, ["result", "structuredContent", "work_package", "status"]) == status
    end)
  end

  defp attach_phase_child_ready_evidence(repo, session, child_id, head_sha) do
    append_done_plan(repo, child_id)
    attach_branch(repo, session, "agent/#{child_id}/worker", head_sha)
    attach_pr(repo, session, phase_child_pr_url(child_id), head_sha)
    submit_fake_review_package(repo, session, head_sha)
  end

  defp phase_child_pr_url("SYMPP-P8-001-PHASE-A"), do: "https://github.com/nextide/symphony-plus-plus/pull/8003"
  defp phase_child_pr_url("SYMPP-P8-001-PHASE-B"), do: "https://github.com/nextide/symphony-plus-plus/pull/8004"

  defp attach_branch(repo, session, branch, head_sha) do
    attach_tool(repo, session, "attach_branch", %{"branch" => branch, "head_sha" => head_sha})
  end

  defp attach_pr(repo, session, url, head_sha) do
    attach_tool(repo, session, "attach_pr", %{"url" => url, "head_sha" => head_sha})
  end

  defp sync_fake_github(repo, session, number, head_sha, changed_files) do
    attach_tool(repo, session, "sync_pr", %{
      "number" => number,
      "metadata" => %{
        "head_sha" => head_sha,
        "base_branch" => "symphony-plus-plus/beta",
        "changed_files" => Enum.map(changed_files, &%{"filename" => &1, "status" => "modified"}),
        "check_summary" => %{"conclusion" => "success"},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      }
    })
  end

  defp submit_fake_review_package(repo, session, head_sha, lanes \\ ["normal"]) do
    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Deterministic local review evidence for P8 integration harness.",
      "tests" => ["mix sympp.integration"],
      "artifacts" => ["review-suite/p8-001-local.json"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true,
      "reviews" => Enum.map(lanes, &%{"lane" => &1, "verdict" => "green"})
    })
  end

  defp attach_fake_review_suite_result(repo, session, work_package_id, head_sha) do
    attach_tool(repo, session, "attach_review_suite_result", %{
      "work_package_id" => work_package_id,
      "head_sha" => head_sha,
      "suite" => "review-suite",
      "anchor" => "phase_gate-p8-001-local",
      "summary" => "normal profile is green in the deterministic harness.",
      "status" => "passed",
      "verdict" => "green",
      "lane" => "normal"
    })
  end

  defp append_progress(repo, session, summary, status, idempotency_key) do
    response =
      mcp_tool(repo, session, "append_progress", %{
        "summary" => summary,
        "status" => status,
        "idempotency_key" => idempotency_key
      })

    assert get_in(response, ["result", "structuredContent", "progress_event", "id"])
  end

  defp read_resource(repo, session, uri) do
    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => uri, "method" => "resources/read", "params" => %{"uri" => uri}},
        repo: repo,
        session: session
      )

    get_in(response, ["result", "contents", Access.at(0), "text"])
  end

  defp attach_tool(repo, session, name, arguments) do
    response = mcp_tool(repo, session, name, arguments)
    assert get_in(response, ["result", "structuredContent", "progress_event", "id"])
    response
  end

  defp mcp_tool(repo, session, name, arguments) do
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
end
