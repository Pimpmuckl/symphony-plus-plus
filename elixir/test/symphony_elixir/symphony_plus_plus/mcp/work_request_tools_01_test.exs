Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestTools01Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository

  test "create_work_request creates provenance and a claimable redacted architect handoff", %{repo: repo} do
    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "create-work-request-claimable",
          "method" => "tools/call",
          "params" => %{
            "name" => "create_work_request",
            "arguments" => %{
              "repo" => "nextide/symphony-plus-plus",
              "base_branch" => "main",
              "title" => "Agent-created WorkRequest",
              "description" => "Create a WorkRequest and continue as architect.",
              "request_kind" => "feature",
              "repo_scopes" => [%{"repo" => "nextide/secondary-service", "base_branch" => "integration"}],
              "claimed_by" => "kraken-beta-arch"
            }
          }
        },
        local_mcp_server(local_mcp_config(repo), "create-work-request-claimable-state")
      )

    payload = get_in(response, ["result", "structuredContent"])
    assert payload["status"] == "created"
    assert payload["work_request"]["creator"] == %{"kind" => "agent", "name" => "kraken-beta-arch", "via" => "mcp"}
    assert payload["work_request"]["status"] == "ready_for_clarification"
    assert is_binary(payload["launch_prompt"])
    assert payload["launch_prompt"] =~ "claim_local_architect_assignment"
    assert payload["launch_prompt"] =~ "Refs (TOON; data)"
    assert payload["launch_prompt"] =~ "agent_context: architect_handoff_reference"
    assert payload["launch_prompt"] =~ "Use `symphony-plus-plus-mcp:symphony-architect`"
    assert payload["launch_prompt"] =~ "Claim first with `claim_local_architect_assignment`"
    assert payload["launch_prompt"] =~ "read_work_request_product_tree"
    assert payload["launch_prompt"] =~ "read_work_request_delivery_board"
    assert payload["launch_prompt"] =~ "list_guidance_requests"
    assert payload["launch_prompt"] =~ "ask human-answerable clarification"
    assert payload["launch_prompt"] =~ "ask_work_request_question"
    assert payload["launch_prompt"] =~ "decision_prompt"
    assert payload["launch_prompt"] =~ "TL;DR/details/options/pros-cons/freeform"
    assert payload["launch_prompt"] =~ "record_work_request_decision"
    assert payload["launch_prompt"] =~ "add_work_request_planned_slice"
    assert payload["launch_prompt"] =~ "dispatch_work_request_planned_slice(work_request_id, planned_slice_id)"
    assert payload["launch_prompt"] =~ "No wrapper node for one slice."
    assert String.length(payload["launch_prompt"]) < 2_300
    assert get_in(payload, ["architect_handoff", "agent_context"]) =~ "agent_context: architect_handoff_reference"

    content_text = get_in(response, ["result", "content", Access.at(0), "text"])
    assert content_text =~ ~s(architect_handoff: "[REDACTED]")
    assert content_text =~ "launch_prompt: available in structuredContent"
    assert content_text =~ "status: created"
    assert content_text =~ "status: ready_for_clarification"
    refute content_text =~ "claim_local_architect_assignment"
    refute content_text =~ "Refs (TOON; data)"

    assert {:ok, repo_scopes} = WorkRequestRepository.list_repo_scopes(repo, get_in(payload, ["work_request", "id"]))

    assert Enum.any?(repo_scopes, &(&1.repo == "nextide/symphony-plus-plus" and &1.base_branch == "main"))
    assert Enum.any?(repo_scopes, &(&1.repo == "nextide/secondary-service" and &1.base_branch == "integration"))

    local_claim = get_in(payload, ["architect_handoff", "local_architect_claim"])
    assert local_claim["tool"] == "claim_local_architect_assignment"

    assert local_claim["arguments"] == %{
             "work_request_id" => get_in(payload, ["work_request", "id"]),
             "claimed_by" => "kraken-beta-arch"
           }

    assert local_claim["required_runtime_arguments"] == []
    assert local_claim["secret_in_response"] == false
    refute inspect(response) =~ "private_handoff"
    refute inspect(response) =~ "secret_handoff"
    refute inspect(response) =~ "claim_private_handoff"

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-created-work-request",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => local_claim["arguments"]
          }
        },
        local_mcp_server(local_mcp_config(repo), "claim-created-work-request")
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "claimed_by"]) == "kraken-beta-arch"

    claimed_tools_response = Server.handle(%{"jsonrpc" => "2.0", "id" => "claimed-architect-tools", "method" => "tools/list", "params" => %{}}, claimed_server)
    claimed_tools_by_name = Map.new(get_in(claimed_tools_response, ["result", "tools"]), &{&1["name"], &1})

    assert get_in(claimed_tools_by_name, ["add_work_request_planned_slice", "inputSchema", "required"]) == [
             "title",
             "goal",
             "work_package_kind",
             "target_base_branch",
             "owned_file_globs",
             "forbidden_file_globs",
             "acceptance_criteria",
             "validation_steps",
             "stop_conditions"
           ]

    assert get_in(claimed_tools_by_name, ["add_work_request_planned_slice", "inputSchema", "properties", "work_request_id", "description"]) =~
             "claimed architect WorkRequest"

    assert get_in(claimed_tools_by_name, ["approve_work_request_planned_slice", "inputSchema", "required"]) == [
             "planned_slice_id",
             "current_status"
           ]

    assert get_in(claimed_tools_by_name, ["skip_work_request_planned_slice", "inputSchema", "required"]) == [
             "planned_slice_id",
             "current_status"
           ]

    assert get_in(claimed_tools_by_name, ["mark_work_request_sliced", "inputSchema", "required"]) == ["current_status"]

    {default_owner_response, _default_owner_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "create-default-owner-work-request",
          "method" => "tools/call",
          "params" => %{
            "name" => "create_work_request",
            "arguments" => %{
              "repo" => "nextide/symphony-plus-plus",
              "base_branch" => "main",
              "title" => "Default-owner WorkRequest",
              "description" => "Create a WorkRequest without supplying a claim owner.",
              "request_kind" => "feature"
            }
          }
        },
        local_mcp_server(local_mcp_config(repo), "create-default-owner-work-request-state")
      )

    default_owner_payload = get_in(default_owner_response, ["result", "structuredContent"])
    default_owner_claim = get_in(default_owner_payload, ["architect_handoff", "local_architect_claim"])

    assert default_owner_payload["work_request"]["creator"] == %{"kind" => "agent", "name" => "mcp-agent", "via" => "mcp"}
    refute Map.has_key?(default_owner_payload, "claim")
    assert default_owner_claim["tool"] == "claim_local_architect_assignment"
    assert default_owner_claim["arguments"]["claimed_by"] == "symphony-architect"
    refute Map.has_key?(default_owner_claim["arguments"], "caller_id")
    assert default_owner_claim["required_runtime_arguments"] == []

    {default_claim_response, _default_claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-default-owner-work-request",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => default_owner_claim["arguments"]
          }
        },
        local_mcp_server(local_mcp_config(repo), "claim-default-owner-work-request")
      )

    assert get_in(default_claim_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"

    {local_create_response, _local_create_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-create-work-request",
          "method" => "tools/call",
          "params" => %{
            "name" => "create_work_request",
            "arguments" => %{
              "repo" => "nextide/symphony-plus-plus",
              "base_branch" => "main",
              "title" => "Local architect claim WorkRequest",
              "description" => "Create a WorkRequest from a trusted local MCP session.",
              "request_kind" => "feature",
              "claimed_by" => "local-create-arch"
            }
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-create-work-request-state")
      )

    local_create_payload = get_in(local_create_response, ["result", "structuredContent"])
    local_create_claim = get_in(local_create_payload, ["architect_handoff", "local_architect_claim"])

    refute Map.has_key?(local_create_payload, "claim")
    assert local_create_claim["tool"] == "claim_local_architect_assignment"
    assert local_create_claim["required_runtime_arguments"] == []
    assert local_create_claim["arguments"]["claimed_by"] == "local-create-arch"
    refute Map.has_key?(local_create_claim["arguments"], "caller_id")
    assert local_create_payload["launch_prompt"] =~ "claim_local_architect_assignment"

    {operator_response, _operator_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "operator-create-work-request",
          "method" => "tools/call",
          "params" => %{
            "name" => "create_work_request",
            "arguments" => %{
              "repo" => "nextide/symphony-plus-plus",
              "base_branch" => "main",
              "title" => "Operator-created WorkRequest",
              "human_description" => "Record supplied operator provenance.",
              "request_kind" => "investigation",
              "creator_kind" => "operator",
              "creator_name" => "JJ",
              "created_via" => "cli",
              "claimed_by" => "operator-arch"
            }
          }
        },
        local_mcp_server(local_mcp_config(repo), "operator-create-work-request-state")
      )

    assert get_in(operator_response, ["result", "structuredContent", "work_request", "creator"]) == %{
             "kind" => "operator",
             "name" => "JJ",
             "via" => "cli"
           }

    assert {:ok, %WorkRequest{}} = WorkRequestRepository.get(repo, get_in(operator_response, ["result", "structuredContent", "work_request", "id"]))
  end

  test "create_work_request requires trusted local HTTP with explicit state", %{repo: repo} do
    arguments = %{
      "repo" => "nextide/symphony-plus-plus",
      "base_branch" => "main",
      "title" => "Denied WorkRequest",
      "description" => "This should not be created outside trusted local HTTP.",
      "request_kind" => "investigation"
    }

    stdio_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "stdio-create-work-request-denied",
          "method" => "tools/call",
          "params" => %{"name" => "create_work_request", "arguments" => arguments}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(stdio_response, ["error", "code"]) == -32_001
    assert get_in(stdio_response, ["error", "data", "tool"]) == "create_work_request"
    assert get_in(stdio_response, ["error", "data", "reason"]) == "local_mcp_required"
    refute Enum.any?(tools_for_server(Server.new(Config.default(repo: repo), initialized: true)), &(&1["name"] == "create_work_request"))

    implicit_state_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "implicit-state-create-work-request-denied",
          "method" => "tools/call",
          "params" => %{"name" => "create_work_request", "arguments" => arguments}
        },
        Server.new(local_mcp_config(repo), initialized: true, local_daemon_trusted: true)
      )

    assert get_in(implicit_state_response, ["error", "code"]) == -32_001
    assert get_in(implicit_state_response, ["error", "data", "reason"]) == "local_mcp_session_required"

    refute Enum.any?(
             tools_for_server(Server.new(local_mcp_config(repo), initialized: true, local_daemon_trusted: true)),
             &(&1["name"] == "create_work_request")
           )

    remote_config = %{local_mcp_config(repo) | database: "https://ledger.example.test/mcp?token=ghp_createworksecret"}

    remote_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "remote-create-work-request-denied",
          "method" => "tools/call",
          "params" => %{"name" => "create_work_request", "arguments" => arguments}
        },
        local_mcp_server(remote_config, "remote-create-work-request-state")
      )

    assert get_in(remote_response, ["error", "code"]) == -32_001
    assert get_in(remote_response, ["error", "data", "reason"]) == "local_database_required"
    refute inspect(remote_response) =~ "ghp_createworksecret"
    refute Enum.any?(tools_for_server(local_mcp_server(remote_config, "remote-create-work-request-tools-state")), &(&1["name"] == "create_work_request"))

    memory_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "memory-create-work-request-denied",
          "method" => "tools/call",
          "params" => %{"name" => "create_work_request", "arguments" => arguments}
        },
        local_mcp_server(%{local_mcp_config(repo) | database: ":memory:"}, "memory-create-work-request-state")
      )

    assert get_in(memory_response, ["error", "code"]) == -32_001
    assert get_in(memory_response, ["error", "data", "reason"]) == "file_backed_database_required"

    pre_initialize_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "pre-init-create-work-request-denied",
          "method" => "tools/call",
          "params" => %{"name" => "create_work_request", "arguments" => arguments}
        },
        Server.new(local_mcp_config(repo), local_daemon_trusted: true, state_key: "pre-init-create-work-request-state")
      )

    assert get_in(pre_initialize_response, ["error", "code"]) == -32_000
    assert get_in(pre_initialize_response, ["error", "data", "reason"]) == "server_not_initialized"
  end

  test "architect WorkRequest read tools are scoped, filtered, redacted, and read-only", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-READ", [
        "read:work_request"
      ])

    in_scope =
      create_work_request!(repo,
        id: "WR-MCP-WR-IN",
        title: "Read WorkRequests",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing",
        human_description: "Use Bearer raw-secret-value for validation",
        constraints: %{"safe" => "visible", "token" => "raw-secret-value"}
      )

    _other_repo =
      create_work_request!(repo,
        id: "WR-MCP-WR-OTHER-REPO",
        repo: "nextide/other",
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    other_branch =
      create_work_request!(repo,
        id: "WR-MCP-WR-OTHER-BRANCH",
        repo: anchor.repo,
        base_branch: "main",
        status: "ready_for_slicing"
      )

    _other_status =
      create_work_request!(repo,
        id: "WR-MCP-WR-OTHER-STATUS",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "draft"
      )

    assert {:ok, _open_question} =
             WorkRequestRepository.ask_question(repo, in_scope.id, work_request_question_attrs(id: "WRQ-MCP-WR-OPEN"))

    assert {:ok, answered_question} =
             WorkRequestRepository.ask_question(repo, in_scope.id, work_request_question_attrs(id: "WRQ-MCP-WR-ANSWERED"))

    assert {:ok, _answered} =
             WorkRequestRepository.answer_question(repo, answered_question.id, "open", %{
               answer: "Bearer raw-secret-value",
               answered_by: "operator-1"
             })

    assert {:ok, closed_question} =
             WorkRequestRepository.ask_question(repo, in_scope.id, work_request_question_attrs(id: "WRQ-MCP-WR-CLOSED"))

    assert {:ok, _closed} = WorkRequestRepository.close_question(repo, closed_question.id, "open")

    assert {:ok, _decision} =
             WorkRequestRepository.record_decision(
               repo,
               in_scope.id,
               work_request_decision_attrs(id: "WRD-MCP-WR-1", decision: "Use https://example.test/path?sig=raw-secret-value")
             )

    assert {:ok, _planned} = WorkRequestRepository.add_planned_slice(repo, in_scope.id, work_request_planned_slice_attrs(id: "WRS-MCP-WR-PLANNED"))
    assert {:ok, approved} = WorkRequestRepository.add_planned_slice(repo, in_scope.id, work_request_planned_slice_attrs(id: "WRS-MCP-WR-APPROVED"))
    assert {:ok, skipped} = WorkRequestRepository.add_planned_slice(repo, in_scope.id, work_request_planned_slice_attrs(id: "WRS-MCP-WR-SKIPPED"))
    repo.update!(Ecto.Changeset.change(approved, status: "approved"))
    repo.update!(Ecto.Changeset.change(skipped, status: "skipped"))

    counts_before = {
      repo.aggregate(WorkRequest, :count),
      repo.aggregate(WorkPackage, :count),
      repo.aggregate(AccessGrant, :count),
      repo.aggregate(ProgressEvent, :count),
      repo.aggregate(Artifact, :count)
    }

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    list_payload = get_in(list_response, ["result", "structuredContent"])

    assert list_payload["scope"] == %{"repo" => anchor.repo, "base_branch" => anchor.base_branch}
    assert list_payload["filters"] == %{"status" => "ready_for_slicing"}
    assert list_payload["total_count"] == 1

    assert [
             %{
               "id" => "WR-MCP-WR-IN",
               "title" => "Read WorkRequests",
               "repo" => "nextide/symphony-plus-plus",
               "base_branch" => "symphony-plus-plus/beta",
               "status" => "ready_for_slicing"
             } = listed_work_request
           ] = list_payload["work_requests"]

    refute Map.has_key?(listed_work_request, "open_question_count")
    refute Map.has_key?(listed_work_request, "decision_count")
    refute Map.has_key?(listed_work_request, "planned_slice_count")

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => in_scope.id})
    read_payload = get_in(read_response, ["result", "structuredContent"])

    assert read_payload["work_request"]["id"] == in_scope.id
    assert read_payload["work_request"]["constraints"]["safe"] == "visible"
    assert read_payload["work_request"]["constraints"]["token"] == "[REDACTED]"
    assert Enum.map(read_payload["clarification_questions"], & &1["id"]) == ["WRQ-MCP-WR-OPEN", "WRQ-MCP-WR-ANSWERED", "WRQ-MCP-WR-CLOSED"]
    assert Enum.at(read_payload["clarification_questions"], 1)["answer"] == "[REDACTED]"
    assert Enum.map(read_payload["decision_log_entries"], & &1["id"]) == ["WRD-MCP-WR-1"]
    assert Enum.at(read_payload["decision_log_entries"], 0)["decision"] =~ "[REDACTED]"

    assert Enum.map(read_payload["planned_slices"], & &1["id"]) == [
             "WRS-MCP-WR-PLANNED",
             "WRS-MCP-WR-APPROVED",
             "WRS-MCP-WR-SKIPPED"
           ]

    assert Enum.at(read_payload["planned_slices"], 0)["review_lanes"] == ["brief", "normal"]

    assert read_payload["summary"] == %{
             "open_question_count" => 1,
             "answered_question_count" => 1,
             "closed_question_count" => 1,
             "decision_count" => 1,
             "planned_slice_count" => 1,
             "approved_slice_count" => 1,
             "dispatched_slice_count" => 0,
             "skipped_slice_count" => 1
           }

    refute inspect(list_response) =~ "WR-MCP-WR-OTHER-REPO"
    refute inspect(read_response) =~ "raw-secret-value"

    out_of_scope_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => other_branch.id})

    assert get_in(out_of_scope_response, ["error", "code"]) == -32_004
    assert get_in(out_of_scope_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(out_of_scope_response) =~ other_branch.id

    assert {
             repo.aggregate(WorkRequest, :count),
             repo.aggregate(WorkPackage, :count),
             repo.aggregate(AccessGrant, :count),
             repo.aggregate(ProgressEvent, :count),
             repo.aggregate(Artifact, :count)
           } == counts_before
  end

  test "planned slice add advances answered clarification WorkRequest after MCP read", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-CLARIFIED-SLICE", [
        "read:work_request",
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-CLARIFIED-SLICE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "clarifying"
      )

    assert {:ok, question} =
             WorkRequestRepository.ask_question(repo, work_request.id, work_request_question_attrs(id: "WRQ-MCP-WR-CLARIFIED-SLICE"))

    assert {:ok, _answered} =
             WorkRequestRepository.answer_question(repo, question.id, "open", %{
               answer: "Implement the shared WorkRequest service path.",
               answered_by: "operator-1"
             })

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => work_request.id})
    assert get_in(read_response, ["result", "structuredContent", "work_request", "status"]) == "clarifying"
    assert get_in(read_response, ["result", "structuredContent", "summary", "open_question_count"]) == 0

    add_args = %{
      "work_request_id" => work_request.id,
      "title" => "Unlock clarified slicing",
      "goal" => "Let architects add slices after questions are answered.",
      "work_package_kind" => "mcp",
      "target_base_branch" => anchor.base_branch,
      "owned_file_globs" => ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/service.ex"],
      "forbidden_file_globs" => [],
      "acceptance_criteria" => ["Answered clarification questions no longer require manual status ceremony."],
      "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp/work_request_tools_01_test.exs"],
      "review_lanes" => ["normal"],
      "stop_conditions" => ["Do not bypass open questions."]
    }

    add_response = mcp_tool(repo, session, "add_work_request_planned_slice", add_args)
    add_payload = get_in(add_response, ["result", "structuredContent"])

    assert add_payload["work_request"]["status"] == "ready_for_slicing"
    assert get_in(add_payload, ["planned_slice", "status"]) == "planned"
    assert add_payload["status"] == %{"work_request_status" => "ready_for_slicing", "planned_slice_status" => "planned"}

    blocked =
      create_work_request!(repo,
        id: "WR-MCP-WR-OPEN-QUESTION-SLICE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "clarifying"
      )

    assert {:ok, _open_question} =
             WorkRequestRepository.ask_question(repo, blocked.id, work_request_question_attrs(id: "WRQ-MCP-WR-OPEN-QUESTION-SLICE"))

    blocked_response = mcp_tool(repo, session, "add_work_request_planned_slice", Map.put(add_args, "work_request_id", blocked.id))

    assert get_in(blocked_response, ["error", "data", "reason"]) == "open_questions"
    assert get_in(blocked_response, ["error", "data", "message"]) =~ "Answer or close all open clarification questions"
  end

  test "architect-facing MCP reads emit TOON text without changing structured WorkRequest truth", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-TOON", [
        "read:work_request",
        "read:guidance_request",
        "write:guidance_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-TOON",
        title: "Emit TOON architect context",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced"
      )

    assert {:ok, answered_question} =
             WorkRequestRepository.ask_question(repo, work_request.id, work_request_question_attrs(id: "WRQ-MCP-WR-TOON"))

    assert {:ok, _answered} =
             WorkRequestRepository.answer_question(repo, answered_question.id, "open", %{
               answer: "Keep the WorkRequest backend-only.",
               answered_by: "operator-1"
             })

    assert {:ok, _decision} =
             WorkRequestRepository.record_decision(
               repo,
               work_request.id,
               work_request_decision_attrs(
                 id: "WRD-MCP-WR-TOON",
                 decision: "Use one worker package.",
                 rationale: "Delivery sequencing stays in the planned slices.",
                 scope_impact: "No lifecycle state is inferred from this decision."
               )
             )

    assert {:ok, dispatched_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-TOON-DISPATCHED",
                 title: "Implement TOON MCP text",
                 target_base_branch: anchor.base_branch,
                 branch_pattern: "feat/toon-architect-context"
               )
             )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-TOON-PLANNED",
                 title: "Follow-up dashboard markdown",
                 target_base_branch: anchor.base_branch,
                 branch_pattern: "feat/toon-dashboard-followup"
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, dispatched_slice.id, "planned")

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-TOON-DELIVERY",
                 kind: approved_slice.work_package_kind,
                 title: approved_slice.title,
                 repo: work_request.repo,
                 base_branch: approved_slice.target_base_branch,
                 branch_pattern: approved_slice.branch_pattern,
                 phase_id: anchor.phase_id,
                 product_description: work_request.human_description,
                 engineering_scope: approved_slice.goal,
                 allowed_file_globs: approved_slice.owned_file_globs,
                 acceptance_criteria: approved_slice.acceptance_criteria,
                 status: "ci_waiting"
               )
             )

    assert {:ok, _linked_slice} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", package.id)

    assert {:ok, _comment} =
             CommentService.create(repo, %{
               target_kind: "planned_slice",
               target_id: approved_slice.id,
               body: "Comment before merge",
               source_type: "architect",
               author_name: "architect-1"
             })

    assert {:ok, _blocker} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Waiting on guidance",
               status: "blocked",
               payload: %{"type" => "blocker", "source_tool" => "report_blocker", "blocker_id" => "toon-guidance", "active" => true}
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Draft PR attached",
               status: "pr_attached",
               payload: %{
                 "type" => "pr",
                 "source_tool" => "attach_pr",
                 "url" => "https://github.com/#{package.repo}/pull/44",
                 "repository" => package.repo,
                 "number" => 44,
                 "head_sha" => "toon-head",
                 "state" => "open"
               }
             })

    assert {:ok, minted_worker} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, minted_worker.work_key.secret, claimed_by: "toon-worker")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: minted_worker.grant.secret_hash)

    guidance_response =
      mcp_tool(repo, worker_session, "create_guidance_request", %{
        "summary" => "Need architect guidance",
        "question" => "Should the worker keep TOON text only in MCP content?",
        "context" => "Structured delivery data must remain the source of truth.",
        "idempotency_key" => "toon-architect-guidance"
      })

    guidance_id = get_in(guidance_response, ["result", "structuredContent", "guidance_request", "id"])

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => work_request.id})
    read_text = get_in(read_response, ["result", "content", Access.at(0), "text"])

    assert get_in(read_response, ["result", "structuredContent", "planned_slices", Access.at(0), "id"]) == approved_slice.id
    assert get_in(read_response, ["result", "structuredContent", "planned_slices", Access.at(1), "id"]) == planned_slice.id
    assert read_text =~ "agent_context: work_request_read"
    assert read_text =~ "decision_log_semantics: rationale_not_lifecycle_truth"
    assert read_text =~ "Record the human outcome before slicing."
    assert read_text =~ "allowed_paths"
    assert read_text =~ "elixir/lib"
    assert read_text =~ "decisions_as_rationale[1]"
    assert read_text =~ "planned_slices[2]"
    assert read_text =~ "WRS-MCP-WR-TOON-DISPATCHED"
    assert read_text =~ "Expose scoped read-only WorkRequest MCP payloads."
    assert read_text =~ "elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"
    assert read_text =~ "WorkRequest MCP reads are scoped and redacted."
    assert read_text =~ "mix test test/symphony_elixir/symphony_plus_plus/mcp"

    board_response = mcp_tool(repo, session, "read_work_request_delivery_board", %{"work_request_id" => work_request.id})
    board_text = get_in(board_response, ["result", "content", Access.at(0), "text"])

    assert get_in(board_response, ["result", "structuredContent", "delivery_board", "slices", Access.at(0), "work_package", "blocker_state", "active?"]) == true
    assert board_text =~ "agent_context: work_request_delivery_board"
    assert board_text =~ "slices[2]"
    assert board_text =~ "toon-guidance"
    assert board_text =~ "active_blocker"
    assert board_text =~ "https://github.com/#{package.repo}/pull/44"

    list_guidance_response = mcp_tool(repo, session, "list_guidance_requests", %{"status" => "open"})
    guidance_text = get_in(list_guidance_response, ["result", "content", Access.at(0), "text"])

    assert get_in(list_guidance_response, ["result", "structuredContent", "guidance_requests", Access.at(0), "id"]) == guidance_id
    assert guidance_text =~ "agent_context: guidance_request_list"
    assert guidance_text =~ "guidance_requests[1]"
    assert guidance_text =~ "Need architect guidance"

    list_comments_response =
      mcp_tool(repo, session, "list_comments", %{
        "target_kind" => "planned_slice",
        "target_id" => approved_slice.id
      })

    assert [%{"body" => "Comment before merge"}] = get_in(list_comments_response, ["result", "structuredContent", "comments"])
  end

  test "WorkRequest MCP reads require dedicated capability and fixed scope arguments", %{repo: repo} do
    {insufficient_anchor, insufficient_session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-AUTHZ", ["read:phase"])

    insufficient_target =
      create_work_request!(repo,
        id: "WR-MCP-WR-AUTHZ",
        repo: insufficient_anchor.repo,
        base_branch: insufficient_anchor.base_branch
      )

    list_denied = mcp_tool(repo, insufficient_session, "list_work_requests", %{})
    assert get_in(list_denied, ["error", "code"]) == -32_003
    assert get_in(list_denied, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(list_denied, ["error", "data", "reason_code"]) == "insufficient_capability"

    read_denied = mcp_tool(repo, insufficient_session, "read_work_request", %{"work_request_id" => insufficient_target.id})
    assert get_in(read_denied, ["error", "code"]) == -32_003
    assert get_in(read_denied, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(read_denied, ["error", "data", "reason_code"]) == "insufficient_capability"

    missing_read_denied = mcp_tool(repo, insufficient_session, "read_work_request", %{"work_request_id" => "WR-MCP-WR-AUTHZ-MISSING"})
    assert get_in(missing_read_denied, ["error", "code"]) == -32_003
    assert get_in(missing_read_denied, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(missing_read_denied, ["error", "data", "reason_code"]) == "insufficient_capability"

    board_denied =
      mcp_tool(repo, insufficient_session, "read_work_request_delivery_board", %{"work_request_id" => insufficient_target.id})

    assert get_in(board_denied, ["error", "code"]) == -32_003
    assert get_in(board_denied, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(board_denied, ["error", "data", "reason_code"]) == "insufficient_capability"

    missing_board_denied =
      mcp_tool(repo, insufficient_session, "read_work_request_delivery_board", %{"work_request_id" => "WR-MCP-WR-AUTHZ-MISSING"})

    assert get_in(missing_board_denied, ["error", "code"]) == -32_003
    assert get_in(missing_board_denied, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(missing_board_denied, ["error", "data", "reason_code"]) == "insufficient_capability"

    {_package, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-STRICT", ["read:work_request"])

    repo_argument_response = mcp_tool(repo, session, "list_work_requests", %{"repo" => "nextide/other"})
    assert get_in(repo_argument_response, ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(repo_argument_response, ["error", "data", "arguments"]) == ["repo"]

    branch_argument_response = mcp_tool(repo, session, "list_work_requests", %{"base_branch" => "other"})
    assert get_in(branch_argument_response, ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(branch_argument_response, ["error", "data", "arguments"]) == ["base_branch"]

    invalid_status_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "merged"})
    assert get_in(invalid_status_response, ["error", "data", "reason"]) == "invalid_status"
  end

  test "WorkRequest MCP reads hydrate persisted secondary repo scopes", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MULTI-REPO", [
        "read:work_request",
        "write:work_request"
      ])

    visible =
      create_work_request!(repo,
        id: "WR-MCP-WR-MULTI-REPO",
        repo: "nextide/secondary-service",
        base_branch: "main",
        status: "ready_for_slicing",
        repo_scopes: [
          %{repo: "nextide/secondary-service", base_branch: "main"},
          %{repo: anchor.repo, base_branch: anchor.base_branch}
        ]
      )

    hidden =
      create_work_request!(repo,
        id: "WR-MCP-WR-MULTI-HIDDEN",
        repo: "nextide/secondary-service",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    list_payload = get_in(list_response, ["result", "structuredContent"])

    assert Enum.map(list_payload["work_requests"], & &1["id"]) == [visible.id]
    refute inspect(list_response) =~ hidden.id

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => visible.id})
    assert get_in(read_response, ["result", "structuredContent", "work_request", "id"]) == visible.id

    hidden_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => hidden.id})
    assert get_in(hidden_read_response, ["error", "code"]) == -32_004
    assert get_in(hidden_read_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(hidden_read_response) =~ hidden.id

    status_response =
      mcp_tool(repo, session, "set_work_request_status", %{
        "work_request_id" => visible.id,
        "current_status" => "ready_for_slicing",
        "next_status" => "draft"
      })

    assert get_in(status_response, ["error", "code"]) == -32_004
    assert get_in(status_response, ["error", "data", "reason"]) == "not_found"

    assert {:ok, persisted} = WorkRequestRepository.get(repo, visible.id)
    assert persisted.status == "ready_for_slicing"
  end

  test "WorkRequest MCP list narrows to explicit WorkRequest read scopes", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-LIST-SCOPED", [
        "read:work_request"
      ])

    visible =
      create_work_request!(repo,
        id: "WR-MCP-WR-LIST-SCOPED",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    hidden =
      create_work_request!(repo,
        id: "WR-MCP-WR-LIST-HIDDEN",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, visible.id)
    remove_grant_scope_type!(repo, session, "repo")

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    list_payload = get_in(list_response, ["result", "structuredContent"])

    assert Enum.map(list_payload["work_requests"], & &1["id"]) == [visible.id]
    refute inspect(list_response) =~ hidden.id

    hidden_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => hidden.id})
    assert get_in(hidden_read_response, ["error", "code"]) == -32_004
    assert get_in(hidden_read_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(hidden_read_response) =~ hidden.id

    hidden_board_response = mcp_tool(repo, session, "read_work_request_delivery_board", %{"work_request_id" => hidden.id})
    assert get_in(hidden_board_response, ["error", "code"]) == -32_004
    assert get_in(hidden_board_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(hidden_board_response) =~ hidden.id
  end

  test "WorkRequest architect grants require phase scope before MCP use", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-WR-LEGACY", kind: "mcp"))

    assert {:error, %Ecto.Changeset{} = changeset} = create_architect_work_key(repo, package.id, ["read:work_request"])
    assert {"architect phase-scoped grants require phase scope", []} in Keyword.get_values(changeset.errors, :phase_id)
  end

  test "WorkRequest MCP reads fail closed when architect scope snapshot is missing", %{repo: repo} do
    {_anchor, session, grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MISSING-SCOPE", [
        "read:work_request"
      ])

    repo.update_all(
      from(access_grant in AccessGrant, where: access_grant.id == ^grant.id),
      set: [scope_base_branch: nil]
    )

    list_response = mcp_tool(repo, session, "list_work_requests", %{})
    assert get_in(list_response, ["error", "code"]) == -32_003
    assert get_in(list_response, ["error", "data", "reason"]) == "outside_session_scope"

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => "WR-MCP-WR-IN"})
    assert get_in(read_response, ["error", "code"]) == -32_003
    assert get_in(read_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "WorkRequest MCP reads reject drifted architect scope snapshots", %{repo: repo} do
    {anchor, session, grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-DRIFTED-SCOPE", [
        "read:work_request"
      ])

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-DRIFTED-SIBLING",
        repo: "nextide/other",
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    repo.update_all(
      from(access_grant in AccessGrant, where: access_grant.id == ^grant.id),
      set: [scope_repo: sibling.repo]
    )

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    assert get_in(list_response, ["error", "code"]) == -32_003
    assert get_in(list_response, ["error", "data", "reason"]) == "outside_session_scope"
    refute inspect(list_response) =~ sibling.id

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => sibling.id})
    assert get_in(read_response, ["error", "code"]) == -32_003
    assert get_in(read_response, ["error", "data", "reason"]) == "outside_session_scope"
    refute inspect(read_response) =~ sibling.id

    missing_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => "WR-MCP-WR-DRIFTED-MISSING"})
    assert get_in(missing_read_response, ["error", "code"]) == -32_003
    assert get_in(missing_read_response, ["error", "data", "reason"]) == "outside_session_scope"
  end
end
