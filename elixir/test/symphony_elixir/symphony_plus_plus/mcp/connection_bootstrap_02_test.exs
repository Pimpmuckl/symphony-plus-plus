Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ConnectionBootstrap02Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog

  @repo_root Path.expand("../../../../../", __DIR__)
  @contract_path Path.join(@repo_root, "elixir/priv/symphony_plus_plus/mcp_contract.json")

  test "published MCP contract identity matches the runtime" do
    contract = @contract_path |> File.read!() |> Jason.decode!()
    tool_sets = Map.fetch!(contract, "tool_sets")

    assert Map.keys(contract) |> Enum.sort() == ["mcp_contract_fingerprint", "tool_sets", "version"]
    assert Map.fetch!(contract, "version") == 7
    assert Map.fetch!(contract, "mcp_contract_fingerprint") == Server.mcp_contract_identity()["fingerprint"]
    assert Map.fetch!(tool_sets, "unbound_tools") == ToolCatalog.contract_unbound_tools()
    assert Map.fetch!(tool_sets, "trusted_local_http_extra_tools") == ToolCatalog.contract_trusted_local_http_extra_tools()
    assert Map.fetch!(tool_sets, "worker_tools") == ToolCatalog.worker_tools()
    assert Map.fetch!(tool_sets, "architect_tools") == ToolCatalog.architect_tools()
    assert Map.fetch!(tool_sets, "shared_worker_architect_tools") == ToolCatalog.shared_worker_architect_tools()
  end

  test "mix task reuses an already-started repo for the exact SQLite URI" do
    database = "file:sympp_mcp_#{System.unique_integer([:positive])}?mode=memory&cache=shared"
    original_repo = Repo.get_dynamic_repo()
    original_logger_config = Application.fetch_env(:logger, :console)
    {:ok, pid} = Repo.start_link(database: database, name: Repo.process_name(database), pool_size: 1, log: false)

    input =
      [
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()}),
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        })
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    try do
      output =
        capture_io(input, fn ->
          McpTask.run(["--database", database])
        end)

      responses = decode_json_lines(output)

      assert Enum.any?(responses, fn response ->
               get_in(response, ["result", "structuredContent", "ledger", "reachable"]) == true
             end)

      assert Process.alive?(pid)
      assert Repo.get_dynamic_repo() == original_repo
      assert Application.fetch_env(:logger, :console) == original_logger_config
    after
      GenServer.stop(pid)
    end
  end

  test "harness config override does not require a repo option" do
    config = Config.default(repo: Repo, version: "test-version")

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/read", "params" => %{"uri" => "sympp://health/version"}},
        config: config
      )

    text = get_in(response, ["result", "contents", Access.at(0), "text"])
    assert Jason.decode!(text)["version"] == "test-version"
  end

  test "initialize returns server version and MCP capabilities", %{repo: repo} do
    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => initialize_params()},
        repo: repo
      )

    assert response["jsonrpc"] == "2.0"
    assert response["id"] == 1
    assert get_in(response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert get_in(response, ["result", "serverInfo", "version"])
    assert get_in(response, ["result", "capabilities", "tools"]) == %{}
    assert get_in(response, ["result", "capabilities", "resources"]) == %{}
  end

  test "server requires initialize before MCP operations", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    pre_init_response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}}, server)

    assert get_in(pre_init_response, ["error", "code"]) == -32_000
    assert get_in(pre_init_response, ["error", "data", "reason"]) == "server_not_initialized"

    {init_response, initialized_server} =
      Server.handle_state(%{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()}, server)

    assert init_response["result"]["protocolVersion"] == "2025-03-26"
    assert initialized_server.initialized == true

    post_init_response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}}, initialized_server)

    assert is_list(get_in(post_init_response, ["result", "tools"]))
  end

  test "tools list exposes the stable full catalog while unbound writes stay claim-gated", %{repo: repo} do
    unbound_server = Server.new(Config.default(repo: repo), initialized: true)

    unbound_response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "unbound-tools", "method" => "tools/list", "params" => %{}}, unbound_server)

    unbound_tools = get_in(unbound_response, ["result", "tools"])
    unbound_tool_names = Enum.map(unbound_tools, & &1["name"])
    unbound_tools_by_name = Map.new(unbound_tools, &{&1["name"], &1})

    assert length(unbound_tool_names) == length(Enum.uniq(unbound_tool_names))

    for tool <- [
          "claim_local_assignment",
          "claim_local_architect_assignment",
          "get_current_assignment",
          "release_current_assignment",
          "solo_attach",
          "solo_list",
          "solo_record_task_plan",
          "solo_append_progress",
          "solo_append_finding",
          "solo_record_decision",
          "solo_report_blocker",
          "solo_resolve_blocker",
          "solo_record_validation",
          "solo_pause",
          "solo_resume",
          "solo_complete",
          "solo_archive",
          "solo_show",
          "sympp.health"
        ] do
      assert Map.has_key?(unbound_tools_by_name, tool)
    end

    assert Map.has_key?(unbound_tools_by_name, "create_work_request")

    trusted_local_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "trusted-local-tools", "method" => "tools/list", "params" => %{}},
        local_mcp_server(local_mcp_config(repo), "trusted-local-tools-state")
      )

    trusted_local_tools_by_name =
      trusted_local_response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(trusted_local_tools_by_name, "create_work_request")

    for tool <- ToolCatalog.architect_tools(), do: assert(Map.has_key?(unbound_tools_by_name, tool))

    for tool <- ToolCatalog.worker_tools(), do: assert(Map.has_key?(unbound_tools_by_name, tool))

    assert get_in(unbound_tools_by_name, ["claim_local_assignment", "inputSchema", "required"]) == ["work_package_id"]
    assert get_in(unbound_tools_by_name, ["claim_local_assignment", "inputSchema", "properties", "work_package_id", "type"]) == "string"
    assert get_in(unbound_tools_by_name, ["claim_local_architect_assignment", "inputSchema", "required"]) == ["work_request_id"]
    assert get_in(unbound_tools_by_name, ["claim_local_architect_assignment", "inputSchema", "properties", "work_request_id", "type"]) == "string"
    assert get_in(unbound_tools_by_name, ["release_current_assignment", "inputSchema", "required"]) == []
    assert get_in(unbound_tools_by_name, ["release_current_assignment", "inputSchema", "properties", "reason", "type"]) == "string"
    assert get_in(unbound_tools_by_name, ["solo_append_progress", "inputSchema", "properties", "body", "description"]) =~ "Markdown"

    assert get_in(trusted_local_tools_by_name, ["create_work_request", "inputSchema", "required"]) == [
             "repo",
             "base_branch",
             "title",
             "request_kind"
           ]

    assert get_in(trusted_local_tools_by_name, ["create_work_request", "inputSchema", "then", "anyOf"]) == [
             %{"required" => ["description"]},
             %{"required" => ["human_description"]}
           ]

    assert get_in(trusted_local_tools_by_name, ["create_work_request", "inputSchema", "properties", "description", "description"]) =~ "Markdown"
    assert get_in(trusted_local_tools_by_name, ["create_work_request", "inputSchema", "properties", "human_description", "description"]) =~ "Markdown"
    refute Map.has_key?(unbound_tools_by_name, "upsert_plan_node")
    refute Map.has_key?(unbound_tools_by_name, "move_plan_node")
    refute Map.has_key?(unbound_tools_by_name, "set_plan_node_completion")

    unclaimed_read_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "unclaimed-read-work-request",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => %{"unexpected" => "value"}}
        },
        unbound_server
      )

    assert get_in(unclaimed_read_response, ["error", "code"]) == -32_001
    assert get_in(unclaimed_read_response, ["error", "data", "tool"]) == "read_work_request"
    assert get_in(unclaimed_read_response, ["error", "data", "reason"]) == "local_mcp_required"

    unclaimed_progress_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "unclaimed-append-progress",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"unexpected" => "value"}}
        },
        unbound_server
      )

    assert get_in(unclaimed_progress_response, ["error", "code"]) == -32_001
    assert get_in(unclaimed_progress_response, ["error", "data", "resource"]) == "append_progress"
    assert get_in(unclaimed_progress_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(unclaimed_progress_response, ["error", "data", "action"]) == "claim_local_assignment"

    health_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "health-toon", "method" => "tools/call", "params" => %{"name" => "sympp.health", "arguments" => %{}}},
        unbound_server
      )

    health_text = assert_toon_tool_text!(health_response)
    assert health_text =~ "status:"
    assert health_text =~ "ledger:"
    assert get_in(health_response, ["result", "structuredContent", "ledger", "reachable"]) in [true, false]

    claim_package = create_local_claim_package!(repo, "SYMPP-UNBOUND-CLAIM-CALL")
    assert {:ok, _claim_minted} = AccessGrantService.mint_worker_grant(repo, claim_package.id)

    claim_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-local-assignment",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(claim_package)}
        },
        local_mcp_server(local_mcp_config(repo), "unbound-claim-call-state")
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-UNBOUND-CLAIM-CALL"
    claim_text = assert_toon_tool_text!(claim_response)
    assert claim_text =~ "status: ok"
    assert claim_text =~ "tool: claim_local_assignment"
    assert claim_text =~ "work_package_id: SYMPP-UNBOUND-CLAIM-CALL"
    refute claim_text =~ "claim_lease_id"
    refute claim_text =~ "grant_id"
    refute claim_text =~ "caller_id"
    refute claim_text =~ ~s("assignment")

    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WORKER-TOOLS-LIST", kind: "mcp", branch_pattern: nil))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: minted.grant.secret_hash)
    worker_server = Server.new(Config.default(repo: repo), initialized: true, session: worker_session)

    worker_response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "worker-tools", "method" => "tools/list", "params" => %{}}, worker_server)

    tools_by_name =
      worker_response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    for tool <- ["report_blocker", "resolve_blocker"] do
      assert Map.has_key?(tools_by_name, tool)

      denied_response =
        Server.handle(
          %{"jsonrpc" => "2.0", "id" => tool, "method" => "tools/call", "params" => %{"name" => tool, "arguments" => %{}}},
          unbound_server
        )

      assert get_in(denied_response, ["error", "code"]) == -32_001
    end

    refute Map.has_key?(tools_by_name, "create_guidance_request")

    assert get_in(tools_by_name, ["get_current_assignment", "inputSchema", "required"]) == []
    assert get_in(tools_by_name, ["release_current_assignment", "inputSchema", "required"]) == []
    assert get_in(tools_by_name, ["release_current_assignment", "inputSchema", "properties", "reason", "type"]) == "string"
    assert get_in(tools_by_name, ["append_progress", "inputSchema", "required"]) == ["summary", "idempotency_key"]
    assert get_in(tools_by_name, ["append_progress", "inputSchema", "properties", "body", "description"]) =~ "Markdown"
    assert get_in(tools_by_name, ["append_finding", "inputSchema", "required"]) == ["title", "body", "idempotency_key"]
    assert get_in(tools_by_name, ["append_finding", "inputSchema", "properties", "body", "description"]) =~ "Markdown"
    assert get_in(tools_by_name, ["read_guidance_request", "inputSchema", "required"]) == ["guidance_request_id"]
    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "required"]) == ["expected_version", "nodes"]
    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "properties", "expected_version", "type"]) == "integer"
    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "properties", "nodes", "minItems"]) == 1

    assert get_in(tools_by_name, [
             "update_task_plan",
             "inputSchema",
             "properties",
             "nodes",
             "items",
             "properties",
             "status",
             "enum"
           ]) == ["pending", "in_progress", "done", "skipped"]

    refute Map.has_key?(get_in(tools_by_name, ["update_task_plan", "inputSchema", "properties"]), "work_package_id")

    refute Map.has_key?(get_in(tools_by_name, ["update_task_plan", "inputSchema", "properties", "nodes", "items"]), "anyOf")

    refute Map.has_key?(tools_by_name, "set_status")
    assert get_in(tools_by_name, ["report_blocker", "inputSchema", "required"]) == ["summary", "idempotency_key"]

    assert get_in(tools_by_name, ["resolve_blocker", "inputSchema", "required"]) == [
             "blocker_id",
             "resolution",
             "summary",
             "idempotency_key"
           ]

    assert get_in(tools_by_name, ["abandon", "inputSchema", "required"]) == ["reason"]
    assert get_in(tools_by_name, ["mark_ready", "inputSchema", "properties"]) == %{}
    assert get_in(tools_by_name, ["add_comment", "inputSchema", "required"]) == ["target_kind", "target_id", "body"]
    assert get_in(tools_by_name, ["add_comment", "inputSchema", "properties", "target_kind", "enum"]) == ["work_request", "work_package"]
    assert get_in(tools_by_name, ["add_comment", "inputSchema", "properties", "body", "maxLength"]) == Comment.max_body_length()
    assert get_in(tools_by_name, ["add_comment", "inputSchema", "properties", "body", "description"]) =~ "Markdown"
    assert get_in(tools_by_name, ["list_comments", "inputSchema", "required"]) == ["target_kind", "target_id"]

    assert get_in(tools_by_name, ["resolve_comment", "inputSchema", "required"]) == ["comment_id"]
    assert get_in(tools_by_name, ["resolve_comment", "inputSchema", "properties", "resolution_note", "maxLength"]) == Comment.max_resolution_note_length()
    assert get_in(tools_by_name, ["resolve_comment", "inputSchema", "properties", "resolution_note", "description"]) =~ "Markdown"
    assert get_in(tools_by_name, ["attach_branch", "inputSchema", "required"]) == ["head_sha"]
    assert get_in(tools_by_name, ["attach_branch", "inputSchema", "properties", "head_sha", "type"]) == "string"

    assert get_in(tools_by_name, ["attach_pr", "inputSchema", "properties", "head_sha", "type"]) == "string"
    assert get_in(tools_by_name, ["attach_pr", "inputSchema", "then", "allOf"]) != nil

    assert get_in(tools_by_name, ["attach_pr", "inputSchema", "properties", "number", "anyOf"]) == [
             %{"type" => "integer", "minimum" => 1},
             %{"type" => "string", "pattern" => "^[1-9][0-9]*$"}
           ]

    assert get_in(tools_by_name, ["attach_pr", "inputSchema", "properties", "metadata", "type"]) == "object"
    attach_pr_properties = get_in(tools_by_name, ["attach_pr", "inputSchema", "properties"])

    for sync_only <- ["branch", "base_branch", "base_sha", "changed_files", "changed_files_count", "check_summary", "review_state", "merge_state", "recovery"] do
      refute Map.has_key?(attach_pr_properties, sync_only)
    end

    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "required"]) == []

    sync_pr_properties = get_in(tools_by_name, ["sync_pr", "inputSchema", "properties"])

    for manual <- ["head_sha", "metadata", "branch", "base_branch", "base_sha", "changed_files", "changed_files_count", "check_summary", "review_state", "merge_state"] do
      refute Map.has_key?(sync_pr_properties, manual)
    end

    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "then"]) == nil
    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "properties", "recovery", "type"]) == "object"
    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "properties", "recovery", "additionalProperties"]) == false

    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "properties", "recovery", "properties", "check_summary", "properties", "status", "enum"]) ==
             ~w(passing failing pending unknown)

    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "properties", "recovery", "properties", "changed_files", "anyOf"]) == [
             %{
               "type" => "array",
               "items" => %{
                 "anyOf" => [
                   %{"type" => "string", "minLength" => 1, "pattern" => "\\S"},
                   %{"type" => "object", "additionalProperties" => true}
                 ]
               }
             },
             %{"type" => "integer", "minimum" => 0}
           ]

    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "properties", "number", "anyOf"]) == [
             %{"type" => "integer", "minimum" => 1},
             %{"type" => "string", "pattern" => "^[1-9][0-9]*$"}
           ]

    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "required"]) == ["summary"]
    assert get_in(tools_by_name, ["complete_review", "inputSchema", "required"]) == []
    assert get_in(tools_by_name, ["complete_review", "inputSchema", "properties", "reference", "type"]) == ["string", "null"]
    refute Map.has_key?(get_in(tools_by_name, ["submit_review_package", "inputSchema", "properties"]), "reviews")
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "properties", "head_sha", "type"]) == "string"

    refute Map.has_key?(tools_by_name, "claim_work_key")
    refute Map.has_key?(tools_by_name, "claim_private_handoff")
  end

  test "tools list returns Codex-compatible top-level input schemas for every surface", %{repo: repo} do
    assert {:ok, worker_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CODEX-SCHEMA-WORKER", kind: "mcp"))
    assert {:ok, worker_minted} = AccessGrantService.mint_worker_grant(repo, worker_package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, worker_minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: worker_minted.grant.secret_hash)

    {_anchor, architect_session, _grant} = create_phase_architect_session(repo, "SYMPP-CODEX-SCHEMA-ARCHITECT", ["read:phase"])

    surfaces = [
      {"unbound", Server.new(Config.default(repo: repo), initialized: true)},
      {"worker", Server.new(Config.default(repo: repo), initialized: true, session: worker_session)},
      {"architect", Server.new(test_mcp_config(repo), initialized: true, session: architect_session)}
    ]

    for {surface, server} <- surfaces,
        tool <- tools_for_server(server) do
      schema = Map.fetch!(tool, "inputSchema")

      assert schema["type"] == "object", "#{surface} #{tool["name"]} inputSchema must be a top-level object"

      forbidden = Map.take(schema, @codex_forbidden_top_level_schema_keys)
      assert forbidden == %{}, "#{surface} #{tool["name"]} has Codex-rejected top-level schema keys: #{inspect(Map.keys(forbidden))}"
    end
  end
end
