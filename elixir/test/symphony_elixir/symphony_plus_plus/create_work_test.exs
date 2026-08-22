Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CreateWorkTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.CreateWork
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Server}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkPackageRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "parses valid create-work requests" do
    assert {:ok, request} =
             CreateWork.parse_request(%{
               kind: "hotfix",
               repo: "kraken",
               base_branch: "beta",
               title: "Fix allocator outage",
               product_description: "Allocator workers are stuck.",
               engineering_scope: "Restore allocator claims.",
               acceptance_criteria: ["Allocator claims recover."],
               policy_template: "hotfix"
             })

    assert request["kind"] == "hotfix"
    assert request["repo"] == "kraken"
    assert request["base_branch"] == "beta"
    assert request["title"] == "Fix allocator outage"
    assert request["acceptance_criteria"] == ["Allocator claims recover."]
    assert request["allowed_file_globs"] == []
    assert request["parent_id"] == nil
    assert request["policy"].template == "hotfix"
  end

  test "rejects missing repo base branch and title" do
    assert {:error, {:missing_required_field, "repo"}} =
             CreateWork.parse_request(%{base_branch: "main", title: "Missing repo"})

    assert {:error, {:missing_required_field, "base_branch"}} =
             CreateWork.parse_request(%{repo: "kraken", title: "Missing base"})

    assert {:error, {:missing_required_field, "title"}} =
             CreateWork.parse_request(%{repo: "kraken", base_branch: "main"})
  end

  test "normalizes explicit IDs and rejects blank IDs" do
    assert {:ok, request} =
             CreateWork.parse_request(%{
               id: " custom-work-id ",
               repo: "kraken",
               base_branch: "main",
               title: "Custom id",
               acceptance_criteria: ["Custom ID works."]
             })

    assert request["id"] == "custom-work-id"

    assert {:error, :invalid_work_package_id} =
             CreateWork.parse_request(%{
               id: "   ",
               repo: "kraken",
               base_branch: "main",
               title: "Blank id"
             })
  end

  test "accepts resolved policy template names and rejects blank acceptance criteria" do
    assert {:ok, request} =
             CreateWork.parse_request(%{
               repo: "kraken",
               base_branch: "main",
               title: "Explicit hotfix policy",
               acceptance_criteria: ["Hotfix works."],
               policy_template: "hotfix"
             })

    assert request["kind"] == "hotfix"
    assert request["policy_template"] == "hotfix"
    assert request["policy"].template == "hotfix"

    assert {:ok, request} =
             CreateWork.parse_request(%{
               repo: "symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Explicit worker package policy",
               acceptance_criteria: ["Worker package policy works."],
               kind: "mcp",
               policy_template: "worker_package"
             })

    assert request["kind"] == "mcp"
    assert request["policy_template"] == "mcp"
    assert request["policy"].template == "worker_package"

    assert {:ok, request} =
             CreateWork.parse_request(%{
               kind: "mcp",
               repo: "symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Wire MCP package",
               acceptance_criteria: ["MCP work is created."],
               policy_template: "worker_package"
             })

    assert request["policy"].template == "worker_package"
    assert request["kind"] == "mcp"

    assert {:ok, request} =
             CreateWork.parse_request(%{
               kind: "mcp",
               repo: "symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Wire current PR policy",
               acceptance_criteria: ["Current PR state is required."],
               policy_template: "mcp_current_pr_state"
             })

    assert request["policy_template"] == "mcp_current_pr_state"
    assert "current_pr_state" in request["policy"].required_gates

    assert {:ok, request} =
             CreateWork.parse_request(%{
               repo: "symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Default current PR policy kind",
               acceptance_criteria: ["Current PR state is required."],
               policy_template: "mcp_current_pr_state"
             })

    assert request["kind"] == "mcp"
    assert request["policy_template"] == "mcp_current_pr_state"

    assert {:ok, request} =
             CreateWork.parse_request(%{
               repo: "symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Default changed-file scope policy kind",
               acceptance_criteria: ["Changed files stay in scope."],
               policy_template: "mcp_changed_file_scope_guard",
               allowed_file_globs: ["elixir/lib/**"]
             })

    assert request["kind"] == "mcp"
    assert request["policy_template"] == "mcp_changed_file_scope_guard"
    assert request["allowed_file_globs"] == ["elixir/lib/**"]
    assert "scope_guard" in request["policy"].required_gates
    refute "review_complete" in request["policy"].required_gates

    assert {:error, :missing_allowed_file_globs} =
             CreateWork.parse_request(%{
               repo: "symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Missing changed-file scope",
               acceptance_criteria: ["Changed files stay in scope."],
               policy_template: "mcp_changed_file_scope_guard"
             })

    assert {:error, :overbroad_allowed_file_globs} =
             CreateWork.parse_request(%{
               repo: "symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Overbroad changed-file scope",
               acceptance_criteria: ["Changed files stay in scope."],
               policy_template: "mcp_changed_file_scope_guard",
               allowed_file_globs: ["**/**"]
             })

    assert {:ok, request} =
             CreateWork.parse_request(%{
               repo: "symphony-plus-plus",
               base_branch: "main",
               title: "Docs-only package",
               kind: "docs",
               allowed_file_globs: ["README.md", "docs/**"]
             })

    assert request["kind"] == "docs"
    assert request["policy_template"] == "docs"
    assert request["allowed_file_globs"] == ["README.md", "docs/**"]

    assert {:error, :non_documentation_allowed_file_globs} =
             CreateWork.parse_request(%{
               repo: "symphony-plus-plus",
               base_branch: "main",
               title: "Docs kind cannot own code",
               kind: "docs",
               allowed_file_globs: ["elixir/lib/**"]
             })

    assert {:error, :invalid_acceptance_criteria} =
             CreateWork.parse_request(%{
               repo: "kraken",
               base_branch: "main",
               title: "Bad acceptance",
               acceptance_criteria: ["  "]
             })

    assert {:ok, request} =
             CreateWork.parse_request(%{
               repo: "kraken",
               base_branch: "main",
               title: "Nil acceptance",
               acceptance_criteria: nil
             })

    assert request["acceptance_criteria"] == []

    assert {:error, :missing_acceptance_criteria} =
             CreateWork.parse_request(%{
               kind: "mcp",
               repo: "symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Missing gated acceptance"
             })

    assert {:error, :invalid_policy_template} =
             CreateWork.parse_request(%{
               repo: "kraken",
               base_branch: "main",
               title: "Bad template",
               policy_template: ["hotfix"]
             })
  end

  test "rejects policy templates that conflict with the work kind" do
    assert {:error, :policy_template_mismatch} =
             CreateWork.parse_request(%{
               kind: "quick_fix",
               repo: "symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Quick fix cannot request worker package",
               acceptance_criteria: ["Conflict is rejected."],
               policy_template: "worker_package"
             })

    assert {:error, :policy_template_mismatch} =
             CreateWork.parse_request(%{
               kind: "quick_fix",
               repo: "symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "Quick fix cannot request hotfix policy",
               acceptance_criteria: ["Conflict is rejected."],
               policy_template: "hotfix"
             })

    assert {:ok, exact_alias_request} =
             CreateWork.parse_request(%{
               kind: "mcp",
               repo: "symphony-plus-plus",
               base_branch: "symphony-plus-plus/beta",
               title: "MCP current PR state accepts exact policy and template alias",
               acceptance_criteria: ["Current PR state is required."],
               policy_template: "mcp_current_pr_state"
             })

    assert exact_alias_request["policy_template"] == "mcp_current_pr_state"
    assert "current_pr_state" in exact_alias_request["policy"].required_gates
  end

  test "preserves allowed file globs and rejects invalid scope constraints", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               kind: "hotfix",
               repo: "kraken",
               base_branch: "main",
               title: "Fix scoped hotfix",
               engineering_scope: "Touch only the balance path.",
               acceptance_criteria: ["Balance regression is fixed."],
               allowed_file_globs: [" src/[0-9]/** ", "# not a heading"]
             })

    assert creation.work_package.allowed_file_globs == ["src/[0-9]/**", "# not a heading"]
    assert creation.virtual_files["context.md"] =~ "```text\nsrc/[0-9]/**\n# not a heading\n```"

    assert {:error, :invalid_allowed_file_globs} =
             CreateWork.parse_request(%{
               repo: "kraken",
               base_branch: "main",
               title: "Bad globs",
               acceptance_criteria: ["Rejected."],
               allowed_file_globs: ["   "]
             })
  end

  test "rejects parented work and malformed kinds" do
    assert {:error, :parent_not_supported} =
             CreateWork.parse_request(%{
               repo: "kraken",
               base_branch: "main",
               title: "Bad parent",
               parent_id: "phase_123"
             })

    assert {:error, :invalid_kind} =
             CreateWork.parse_request(%{
               kind: "   ",
               repo: "kraken",
               base_branch: "main",
               title: "Blank kind"
             })

    assert {:error, :invalid_kind} =
             CreateWork.parse_request(%{
               kind: 123,
               repo: "kraken",
               base_branch: "main",
               title: "Numeric kind"
             })
  end

  test "creates quick fix work with default policy, one grant, and initial virtual files", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               repo: "kraken",
               base_branch: "beta",
               title: "Fix flaky uploader",
               product_description: "Uploader sometimes leaves jobs in pending.",
               engineering_scope: "Make uploader completion idempotent.",
               acceptance_criteria: ["Uploader pending jobs drain.", "Focused regression coverage exists."]
             })

    assert creation.work_package.kind == "quick_fix"
    assert creation.work_package.parent_id == nil
    assert creation.work_package.status == "ready_for_worker"
    assert creation.policy.template == "quick_fix"
    refute Map.has_key?(creation.policy, :review_suite)
    assert creation.work_package.review_requirement == nil
    assert creation.virtual_files["context.md"] =~ "- Status: `ready_for_worker`"
    assert creation.virtual_files["handoff.md"] =~ "- Status: `ready_for_worker`"
    refute creation.virtual_files["context.md"] =~ "- Status: `created`"
    refute creation.virtual_files["handoff.md"] =~ "- Status: `created`"

    assert %{id: grant_id, role: "worker"} = creation.worker_grant
    refute Map.has_key?(creation.worker_grant, :secret)
    refute Map.has_key?(creation.worker_grant, :display_key)
    assert repo.aggregate(AccessGrant, :count) == 1

    assert creation.virtual_files["context.md"] =~ "Fix flaky uploader"
    assert creation.virtual_files["task_plan.md"] =~ "Implement requested scope"
    assert creation.virtual_files["acceptance.md"] =~ "Focused regression coverage exists."
    assert creation.virtual_files["review.md"] =~ "No review required."

    assert {:ok, rendered} = PlanningRepository.get_render_state(repo, creation.work_package.id)
    refute inspect(rendered) =~ grant_id

    refute Enum.any?(creation.virtual_files, fn {_name, markdown} -> String.contains?(markdown, grant_id) end)
  end

  test "create-work bootstrap response redacts prompt and grant verifier material", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               repo: "kraken",
               base_branch: "main",
               title: "Create bootstrap response",
               acceptance_criteria: ["Return bootstrap metadata without raw worker secrets."]
             })

    bootstrap = %{
      type: "ledger_claim",
      launch_prompt: "Use raw_secret_bootstrap_response only inside the ledger.",
      claim: %{tool: "claim_local_assignment", arguments: %{}}
    }

    response_creation = %{creation | worker_grant: Map.put(creation.worker_grant, :secret_hash, "hash-should-not-leak")}
    payload = CreateWork.response_payload(response_creation, worker_bootstrap: bootstrap)
    json = Jason.encode!(payload)

    assert payload.worker_bootstrap.launch_prompt =~ "[REDACTED]"
    refute payload.worker_bootstrap.launch_prompt =~ "raw_secret_bootstrap_response"
    refute Map.has_key?(payload.worker_grant, :display_key)
    refute Map.has_key?(payload.worker_grant, :secret)
    refute Map.has_key?(payload.worker_grant, :secret_hash)
    refute json =~ "raw_secret_bootstrap_response"
    refute json =~ "hash-should-not-leak"
  end

  test "direct create-work generic review requirement remains durable", %{repo: repo} do
    review = %{"type" => "human", "args" => %{"team" => "maintainers"}}

    assert {:ok, creation} =
             CreateWork.create(repo, %{
               kind: "standard_pr",
               repo: "kraken",
               base_branch: "main",
               title: "Use a direct human review",
               acceptance_criteria: ["Direct review guidance remains coherent."],
               review_requirement: review
             })

    assert creation.work_package.review_requirement == review
    assert CreateWork.response_payload(creation).work_package.review == review
    assert creation.virtual_files["review.md"] =~ "\"type\": \"human\""
    assert creation.virtual_files["review.md"] =~ "\"team\": \"maintainers\""

    assert {:ok, later_review} = Renderer.render(repo, creation.work_package.id, "review.md")
    assert later_review == creation.virtual_files["review.md"]
  end

  test "response payload preserves nil worker grant", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               repo: "kraken",
               base_branch: "main",
               title: "Create no-grant response",
               acceptance_criteria: ["Serialize response without worker grant."]
             })

    payload = CreateWork.response_payload(%{creation | worker_grant: nil})

    assert payload.worker_grant == nil
    assert Jason.encode!(payload) =~ ~s("worker_grant":null)
  end

  test "creates acceptance-less quick fix work when the policy does not require criteria", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               repo: "kraken",
               base_branch: "main",
               title: "Fix operator typo"
             })

    assert creation.work_package.kind == "quick_fix"
    assert creation.work_package.acceptance_criteria == []
    assert creation.virtual_files["acceptance.md"] =~ "No acceptance criteria recorded."

    assert {:ok, persisted} = WorkPackageRepository.get(repo, creation.work_package.id)
    assert persisted.acceptance_criteria == []

    assert {:ok, acceptance_md} = Renderer.render(repo, creation.work_package.id, "acceptance.md")
    assert acceptance_md =~ "No acceptance criteria recorded."
  end

  test "rejects non-dispatchable kinds" do
    assert {:error, :kind_not_dispatchable} =
             CreateWork.parse_request(%{
               kind: "product",
               repo: "kraken",
               base_branch: "main",
               title: "Polish account summary"
             })

    assert CreateWork.error_message(:kind_not_dispatchable) =~ "standard_pr (ordinary PR work)"
  end

  test "renders investigation and blank scope plan guidance correctly", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               kind: "investigation",
               repo: "kraken",
               base_branch: "main",
               title: "Investigate queue stalls",
               engineering_scope: "   "
             })

    assert creation.policy.template == "investigation"
    assert creation.virtual_files["task_plan.md"] =~ "Investigate requested scope"
    refute creation.virtual_files["task_plan.md"] =~ "Implement requested scope"
    assert creation.virtual_files["task_plan.md"] =~ "Use the engineering scope from context.md."
    assert creation.virtual_files["acceptance.md"] =~ "No acceptance criteria recorded."
  end

  test "creates a hotfix package that a worker can claim and read through MCP", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               kind: "hotfix",
               repo: "kraken",
               base_branch: "main",
               title: "Fix production balance regression",
               product_description: "Available balance is overstated.",
               engineering_scope: "Exclude pending withdrawals from available balance.",
               acceptance_criteria: ["Pending withdrawals are excluded."]
             })

    config = local_mcp_config(repo)
    server = local_mcp_server(config, "hotfix-worker-state")

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => %{"work_package_id" => creation.work_package.id, "claimed_by" => "worker-1"}
          }
        },
        server
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == creation.work_package.id

    plan_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "read-plan", "method" => "tools/call", "params" => %{"name" => "read_task_plan"}},
        claimed_server
      )

    assert get_in(plan_response, ["result", "structuredContent", "uri"]) ==
             "sympp://work-packages/#{creation.work_package.id}/task_plan.md"

    resource_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "acceptance",
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/#{creation.work_package.id}/acceptance.md"}
        },
        repo: repo,
        session: claimed_server.session
      )

    text = get_in(resource_response, ["result", "contents", Access.at(0), "text"])
    assert text =~ "Pending withdrawals are excluded."
    refute text =~ creation.worker_grant.id
  end

  test "drives hotfix package from create-work through worker MCP readiness", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               kind: "hotfix",
               repo: "kraken",
               base_branch: "main",
               title: "Fix hotfix incident",
               product_description: "A production endpoint is returning stale results.",
               engineering_scope: "Refresh the endpoint cache invalidation path only.",
               acceptance_criteria: ["Endpoint returns fresh results.", "Hotfix evidence is attached."],
               review_requirement: %{"type" => "human", "args" => %{"team" => "maintainers"}}
             })

    assert {:ok, sibling_creation} =
             CreateWork.create(repo, %{
               kind: "hotfix",
               repo: "kraken",
               base_branch: "main",
               title: "Sibling hotfix",
               acceptance_criteria: ["Sibling remains isolated."]
             })

    assert creation.work_package.parent_id == nil
    assert creation.work_package.status == "ready_for_worker"
    assert creation.policy.template == "hotfix"
    config = local_mcp_config(repo)
    server = local_mcp_server(config, "hotfix-worker-state")

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => %{"work_package_id" => creation.work_package.id, "claimed_by" => "worker-hotfix-1"}
          }
        },
        server
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == creation.work_package.id
    session = claimed_server.session
    assert {:ok, active_package} = WorkPackageRepository.get(repo, creation.work_package.id)
    assert active_package.status == "active"

    {reconnect_response, _reconnected_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-reconnect",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => %{"work_package_id" => creation.work_package.id, "claimed_by" => "worker-hotfix-1"}
          }
        },
        local_mcp_server(config, "hotfix-worker-state")
      )

    assert get_in(reconnect_response, ["result", "structuredContent", "assignment", "work_package_id"]) == creation.work_package.id

    wrong_owner_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-wrong-owner",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => %{"work_package_id" => creation.work_package.id, "claimed_by" => "worker-hotfix-2"}
          }
        },
        repo: repo
      )

    assert get_in(wrong_owner_response, ["error", "data", "reason"]) == "claim_lease_active_for_other_actor"

    context_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "context",
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/#{creation.work_package.id}/context.md"}
        },
        repo: repo,
        session: session
      )

    context_text = get_in(context_response, ["result", "contents", Access.at(0), "text"])
    assert context_text =~ "Fix hotfix incident"
    assert context_text =~ "- Parent: source: `Not recorded.`"

    read_plan_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "read-plan", "method" => "tools/call", "params" => %{"name" => "read_task_plan"}},
        repo: repo,
        session: session
      )

    assert get_in(read_plan_response, ["result", "structuredContent", "text"]) =~ "Implement requested scope"

    plan_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{
              "expected_version" => get_in(read_plan_response, ["result", "structuredContent", "version"]),
              "nodes" => [
                %{
                  "title" => "Record hotfix proof",
                  "body" => "Worker updated the virtual plan through MCP.",
                  "status" => "done"
                }
              ]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert Enum.any?(
             get_in(plan_response, ["result", "structuredContent", "plan_nodes"]),
             &(&1["id"] =~ ~r/^plan_/ and &1["title"] == "Record hotfix proof" and &1["status"] == "done")
           )

    finding_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "finding",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{
              "title" => "Root cause isolated",
              "body" => "Cache invalidation missed the hot path.",
              "idempotency_key" => "hotfix-finding"
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(finding_response, ["result", "structuredContent", "finding", "title"]) == "Root cause isolated"

    progress_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "progress",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_progress",
            "arguments" => %{
              "summary" => "Focused hotfix test passed",
              "status" => "tests_passed",
              "body" => "Regression script exercised the stale-result path.",
              "idempotency_key" => "hotfix-tests"
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(progress_response, ["result", "structuredContent", "progress_event", "status"]) == "tests_passed"

    progress_file_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "progress-file",
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/#{creation.work_package.id}/progress.md"}
        },
        repo: repo,
        session: session
      )

    assert get_in(progress_file_response, ["result", "contents", Access.at(0), "text"]) =~ "Focused hotfix test passed"

    denied_sibling_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sibling-context",
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/#{sibling_creation.work_package.id}/context.md"}
        },
        repo: repo,
        session: session
      )

    assert get_in(denied_sibling_response, ["error", "code"]) == -32_003
    assert get_in(denied_sibling_response, ["error", "data", "reason"]) == "outside_session_scope"

    missing_evidence_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing-evidence", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(missing_evidence_response, ["error", "data", "missing"])
    assert "branch_attached" in missing
    assert "pr_attached" in missing
    assert "review_complete" in missing

    head_sha = "hotfix-head"

    attach_tool(repo, session, "attach_branch", %{
      "branch" => "agent/SYMPP-P4-003/hotfix-e2e",
      "head_sha" => head_sha
    })

    attach_tool(repo, session, "attach_pr", %{
      "url" => "https://github.com/example/symphony-plus-plus/pull/4003",
      "head_sha" => head_sha
    })

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Fake hotfix validation package for the E2E path.",
      "tests" => ["mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs"],
      "artifacts" => ["validation/SYMPP-P4-003-hotfix.json"],
      "head_sha" => head_sha
    })

    attach_tool(repo, session, "complete_review", %{"reference" => "maintainer-review-4003"})

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_merge"

    assert {:ok, persisted} = WorkPackageRepository.get(repo, creation.work_package.id)
    assert persisted.status == "ready_for_merge"
    assert persisted.parent_id == nil
  end

  test "normal work package and grant reads do not expose the raw worker secret", %{repo: repo} do
    assert {:ok, creation} =
             CreateWork.create(repo, %{
               repo: "kraken",
               base_branch: "main",
               title: "Fix claim typo",
               acceptance_criteria: ["Typo fixed."]
             })

    refute Map.has_key?(creation.worker_grant, :secret)
    refute Map.has_key?(creation.worker_grant, :display_key)

    assert {:ok, work_package} = WorkPackageRepository.get(repo, creation.work_package.id)
    refute inspect(work_package) =~ creation.worker_grant.id

    grant = repo.one(from(grant in AccessGrant, where: grant.work_package_id == ^creation.work_package.id))
    assert grant.secret_hash
    refute grant.secret_hash == creation.worker_grant.id
  end

  defp local_mcp_config(repo), do: Config.default(repo: repo, mode: :http, local_daemon_trusted: true)

  defp local_mcp_server(%Config{} = config, state_key) do
    Server.new(config, initialized: true, local_daemon_trusted: true, state_key: state_key)
  end

  defp attach_tool(repo, session, name, arguments) do
    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => name, "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}},
        repo: repo,
        session: session
      )

    assert get_in(response, ["result", "structuredContent", "progress_event", "id"])
    response
  end
end
