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
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

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
    repo.delete_all(WorkRequest)
    :ok
  end

  test "hotfix package runs through MCP with a generic review requirement", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               kind: "hotfix",
               repo: "nextide/symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Fix hotfix incident",
               product_description: "A pilot endpoint returns stale data.",
               engineering_scope: "Touch only the cache invalidation path.",
               acceptance_criteria: ["Endpoint returns fresh data.", "Required review is complete."],
               review_requirement: %{"type" => "human", "args" => %{"team" => "maintainers"}}
             })

    session = claim_worker_grant(repo, creation.worker_grant.id, "hotfix-worker")
    assert read_resource(repo, session, "sympp://work-packages/#{creation.work_package.id}/context.md") =~ "Fix hotfix incident"

    assert_worker_active(repo, session)

    head_sha = "p8-001-hotfix-head"
    attach_branch(repo, session, "agent/SYMPP-P8-001/hotfix", head_sha)
    attach_pr(repo, session, "https://github.com/nextide/symphony-plus-plus/pull/8001", head_sha)
    sync_fake_github(repo, session, 8001, head_sha, ["elixir/lib/symphony_elixir/cache.ex"])
    submit_validation_package(repo, session, head_sha)
    complete_review(repo, session, "maintainer-review-8001")

    response = mcp_tool(repo, session, "mark_ready", %{})

    assert get_in(response, ["result", "structuredContent", "ready"]) == true
    assert get_in(response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"

    assert {:ok, persisted} = WorkPackageRepository.get(repo, creation.work_package.id)
    assert persisted.parent_id == nil
    assert persisted.status == "ready_for_merge"
  end

  test "fake GitHub and generic review gates drive a CI-friendly MCP package to ready", %{repo: repo} do
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
                 allowed_file_globs: ["elixir/lib/**"],
                 review_requirement: %{"type" => "automated", "args" => %{"policy" => "repository"}}
               )
             )

    session = minted_worker_session(repo, package.id, "gate-worker")
    head_sha = "p8-001-gates-head"

    attach_branch(repo, session, "agent/SYMPP-P8-001/gates", head_sha)
    attach_pr(repo, session, "https://github.com/nextide/symphony-plus-plus/pull/8002", head_sha)
    sync_fake_github(repo, session, 8002, head_sha, ["elixir/lib/symphony_elixir/symphony_plus_plus/readiness.ex"])
    submit_validation_package(repo, session, head_sha)
    complete_review(repo, session, "automated-review-8002")

    response = mcp_tool(repo, session, "mark_ready", %{})

    assert get_in(response, ["result", "structuredContent", "ready"]) == true
    assert get_in(response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)
    assert Enum.any?(artifacts, &(&1.kind == "github_pr" and &1.path == "github-pr.json"))
    assert Enum.any?(artifacts, &(&1.kind == "review" and &1.path == "validation/p8-001-local.json"))
  end

  test "worker receives only parent goal and direct dependencies while broad reads stay denied", %{repo: repo} do
    assert {:ok, work_request} =
             WorkRequestRepository.create(repo, %{
               id: "WR-P8-WORKER-CONTEXT",
               title: "Ship scoped worker context",
               repo: "nextide/symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               work_type: "feature",
               human_description: "Let workers explain their assigned outcome.",
               constraints: %{},
               desired_dispatch_shape: "single_package",
               status: "sliced"
             })

    assert {:ok, unrelated_work_request} =
             WorkRequestRepository.create(repo, %{
               id: "WR-P8-WORKER-CONTEXT-UNRELATED",
               title: "Unrelated WorkRequest title",
               repo: "nextide/symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               work_type: "feature",
               human_description: "Unrelated WorkRequest goal",
               constraints: %{},
               desired_dispatch_shape: "single_package",
               status: "sliced"
             })

    assert {:ok, dependency} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P8-WORKER-CONTEXT-DEPENDENCY",
                 work_request_id: work_request.id,
                 title: "Finish dependency",
                 repo: work_request.repo,
                 base_branch: work_request.base_branch,
                 status: "ready_for_merge"
               )
             )

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P8-WORKER-CONTEXT",
                 work_request_id: work_request.id,
                 title: "Project worker context",
                 repo: work_request.repo,
                 base_branch: work_request.base_branch,
                 status: "active"
               )
             )

    assert {:ok, sibling} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P8-WORKER-CONTEXT-SIBLING",
                 work_request_id: work_request.id,
                 title: "Sibling contract title",
                 engineering_scope: "sibling-contract-secret",
                 repo: work_request.repo,
                 base_branch: work_request.base_branch,
                 status: "active"
               )
             )

    assert {:ok, _edge} =
             ProductTree.create_dependency_edge(repo, %{
               work_request_id: work_request.id,
               source_kind: "work_package",
               source_id: package.id,
               target_kind: "work_package",
               target_id: dependency.id,
               kind: "depends_on",
               reason: "Worker needs direct dependency status."
             })

    session = minted_worker_session(repo, package.id, "context-worker")
    response = mcp_tool(repo, session, "read_context", %{})
    context = get_in(response, ["result", "structuredContent"])

    assert context["parent_work_request"] == %{
             "id" => work_request.id,
             "title" => work_request.title,
             "goal" => work_request.human_description,
             "status" => work_request.status
           }

    assert context["direct_dependencies"] == [
             %{"id" => dependency.id, "title" => dependency.title, "status" => dependency.status}
           ]

    assert context["completion"] == %{
             "next_owner" => "architect",
             "next_action" => "return_ready_or_terminal_work_package"
           }

    context_text = get_in(response, ["result", "content", Access.at(0), "text"])
    refute context_text =~ sibling.title
    refute context_text =~ unrelated_work_request.title
    refute context_text =~ "sibling-contract-secret"

    for {tool, arguments} <- [
          {"list_work_requests", %{}},
          {"read_work_request", %{"work_request_id" => work_request.id}},
          {"read_plan", %{"work_request_id" => work_request.id}},
          {"read_delivery_board", %{"work_request_id" => work_request.id}}
        ] do
      denied = mcp_tool(repo, session, tool, arguments)
      assert get_in(denied, ["error", "code"]) == -32_003
      assert get_in(denied, ["error", "data", "reason"]) in ["outside_session_scope", "insufficient_role"]
    end

    sibling_resource =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "integration-worker-context-sibling-resource",
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/#{sibling.id}/context.md"}
        },
        repo: repo,
        session: session
      )

    assert get_in(sibling_resource, ["error", "code"]) == -32_003
    assert get_in(sibling_resource, ["error", "data", "reason"]) == "outside_session_scope"
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
  end

  defp test_repo_root do
    Path.expand("../../../..", __DIR__)
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
    assert {:ok, package} = WorkPackageRepository.get(repo, grant.work_package_id)

    if package.status == "ready_for_worker" do
      assert {:ok, _active} =
               WorkPackageRepository.update_status(repo, package.id, "ready_for_worker", "active")
    end

    session
  end

  defp minted_worker_session(repo, work_package_id, claimed_by) do
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package_id)
    claim_worker_grant(repo, minted.grant.id, claimed_by)
  end

  defp assert_worker_active(repo, session) do
    assert {:ok, package} = WorkPackageRepository.get(repo, session.assignment.work_package_id)
    assert package.status == "active"
  end

  defp attach_branch(repo, session, branch, head_sha) do
    attach_tool(repo, session, "attach_branch", %{"branch" => branch, "head_sha" => head_sha})
  end

  defp attach_pr(repo, session, url, head_sha) do
    attach_tool(repo, session, "attach_pr", %{"url" => url, "head_sha" => head_sha})
  end

  defp sync_fake_github(repo, session, number, head_sha, changed_files) do
    attach_tool(repo, session, "sync_pr", %{
      "recovery" => %{
        "url" => "https://github.com/nextide/symphony-plus-plus/pull/#{number}",
        "head_sha" => head_sha,
        "base_branch" => "symphony-plus-plus/beta",
        "changed_files" => Enum.map(changed_files, &%{"filename" => &1, "status" => "modified"}),
        "check_summary" => %{"status" => "passing"},
        "review_state" => %{"status" => "approved"},
        "merge_state" => %{"status" => "clean", "merged" => false}
      }
    })
  end

  defp submit_validation_package(repo, session, head_sha) do
    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Deterministic local validation evidence for P8 integration harness.",
      "tests" => ["mix sympp.integration"],
      "artifacts" => ["validation/p8-001-local.json"],
      "head_sha" => head_sha
    })
  end

  defp complete_review(repo, session, reference) do
    attach_tool(repo, session, "complete_review", %{"reference" => reference})
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
