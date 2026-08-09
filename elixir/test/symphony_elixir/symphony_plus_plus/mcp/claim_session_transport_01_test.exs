Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionTransport01Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "server rejects re-initialize after handshake", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))
    initialize_request = %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()}

    {_init_response, initialized_server} = Server.handle_state(initialize_request, server)
    {second_response, second_server} = Server.handle_state(%{initialize_request | "id" => "init-again"}, initialized_server)

    assert get_in(second_response, ["error", "code"]) == -32_600
    assert get_in(second_response, ["error", "data", "reason"]) == "already_initialized"
    assert second_server.initialized == true
  end

  test "initialize rejects missing protocol versions and negotiates supported version", %{repo: repo} do
    missing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}},
        repo: repo
      )

    negotiated_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "initialize",
          "params" => %{initialize_params() | "protocolVersion" => "2024-11-05"}
        },
        repo: repo
      )

    assert get_in(missing_response, ["error", "code"]) == -32_602
    assert get_in(missing_response, ["error", "data", "reason"]) == "missing_protocol_version"
    assert get_in(negotiated_response, ["result", "protocolVersion"]) == "2025-03-26"
  end

  test "initialize rejects partial handshake params", %{repo: repo} do
    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{"protocolVersion" => "2025-03-26"}},
        repo: repo
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "invalid_initialize_params"
  end

  test "health tool reaches the test ledger without exposing package rows", %{repo: repo} do
    assert {:ok, _work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P3-001"))

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: repo, source_revision: "ABCDEF1234567890ABCDEF1234567890ABCDEF12")
      )

    result = get_in(response, ["result", "structuredContent"])
    text = get_in(response, ["result", "content", Access.at(0), "text"])

    assert result["status"] == "ok"
    assert result["ledger"]["reachable"] == true
    assert get_in(result, ["ledger", "identity", "kind"]) == "sqlite"
    assert get_in(result, ["ledger", "identity", "source"]) == "default"
    assert result["mode"] == "stdio"
    assert result["source"]["revision"] == "abcdef1234567890abcdef1234567890abcdef12"
    assert result["source"]["mcp_contract"] == Server.mcp_contract_identity()
    assert result["source"]["mcp_contract"]["fingerprint"] =~ ~r/\A[0-9a-f]{64}\z/
    refute text =~ "SYMPP-P3-001"
  end

  test "version resource includes source revision for stale daemon diagnostics", %{repo: repo} do
    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "version", "method" => "resources/read", "params" => %{"uri" => "sympp://health/version"}},
        config: Config.default(repo: repo, source_revision: "0123456789abcdef0123456789abcdef01234567")
      )

    assert %{"result" => %{"contents" => [%{"text" => text}]}} = response
    payload = Jason.decode!(text)

    assert payload["mode"] == "stdio"
    assert payload["source"]["revision"] == "0123456789abcdef0123456789abcdef01234567"
    assert payload["source"]["mcp_contract"] == Server.mcp_contract_identity()
  end

  test "health tool rejects arguments outside its empty schema", %{repo: repo} do
    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{"unexpected" => "value"}}
        },
        repo: repo
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "invalid_tool_arguments"
  end

  test "health tool accepts omitted arguments for its empty schema", %{repo: repo} do
    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health"}
        },
        repo: repo
      )

    assert get_in(response, ["result", "structuredContent", "ledger", "reachable"]) == true
  end

  test "health tool hides raw ledger failure details" do
    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: FailingHealthRepo)
      )

    result = get_in(response, ["result", "structuredContent"])
    text = get_in(response, ["result", "content", Access.at(0), "text"])

    assert result["status"] == "degraded"
    assert result["ledger"]["reachable"] == false
    assert result["ledger"]["error"] == "ledger_unavailable"
    assert get_in(result, ["ledger", "identity"]) == %{"kind" => "unknown", "source" => "default"}
    refute text =~ "C:/secret/path.sqlite"
    refute text =~ "RuntimeError"
  end

  test "resources do not expose package or assignment data without a session", %{repo: repo} do
    assert {:ok, _work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P3-001"))

    list_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "resources/list", "params" => %{}},
        repo: repo
      )

    assert get_in(list_response, ["result", "resources"]) == [
             %{
               "uri" => "sympp://health/version",
               "name" => "Symphony++ version",
               "mimeType" => "application/json"
             }
           ]

    assignment_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 3, "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        repo: repo
      )

    assert get_in(assignment_response, ["error", "code"]) == -32_001
    assert get_in(assignment_response, ["error", "data", "reason"]) == "missing_session"

    package_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/SYMPP-P3-001/task_plan.md"}
        },
        repo: repo
      )

    assert get_in(package_response, ["error", "code"]) == -32_001
    assert get_in(package_response, ["error", "data", "reason"]) == "missing_session"
  end

  test "notifications produce no JSON-RPC response", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    assert nil == Server.handle(%{"jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => %{}}, server)
    assert nil == Server.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, server)
  end

  test "initialize cannot be sent as a notification", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    response = Server.handle(%{"jsonrpc" => "2.0", "method" => "initialize", "params" => initialize_params()}, server)

    assert response["id"] == nil
    assert get_in(response, ["error", "code"]) == -32_600
    assert get_in(response, ["error", "data", "reason"]) == "initialize_requires_id"
  end

  test "malformed method-only payloads are not suppressed as notifications", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    missing_jsonrpc = Server.handle(%{"id" => nil, "method" => "initialize", "params" => %{}}, server)
    missing_method = Server.handle(%{"jsonrpc" => "2.0", "id" => 12}, server)
    method_only = Server.handle(%{"method" => "initialize", "params" => %{}}, server)

    assert get_in(missing_jsonrpc, ["error", "code"]) == -32_600
    assert get_in(missing_jsonrpc, ["error", "data", "reason"]) == "invalid_jsonrpc_version"
    assert get_in(missing_method, ["error", "data", "reason"]) == "missing_method"
    assert get_in(method_only, ["error", "code"]) == -32_600
    assert get_in(method_only, ["error", "data", "reason"]) == "request_must_be_object"
  end

  test "JSON-RPC requests reject invalid versions before shape fallthrough", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    missing_method = Server.handle(%{"jsonrpc" => "1.0", "id" => 1}, server)
    missing_id = Server.handle(%{"jsonrpc" => "1.0", "method" => "initialize"}, server)

    assert missing_method["id"] == 1
    assert get_in(missing_method, ["error", "code"]) == -32_600
    assert get_in(missing_method, ["error", "data", "reason"]) == "invalid_jsonrpc_version"

    assert missing_id["id"] == nil
    assert get_in(missing_id, ["error", "code"]) == -32_600
    assert get_in(missing_id, ["error", "data", "reason"]) == "invalid_jsonrpc_version"
  end

  test "JSON-RPC requests reject non-scalar ids", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    Enum.each(
      [
        %{"jsonrpc" => "2.0", "id" => %{}, "method" => "initialize", "params" => %{}},
        %{"jsonrpc" => "2.0", "id" => []},
        %{"id" => %{}, "method" => "initialize", "params" => %{}}
      ],
      fn request ->
        response = Server.handle(request, server)

        assert response["id"] == nil
        assert get_in(response, ["error", "code"]) == -32_600
        assert get_in(response, ["error", "data", "reason"]) == "invalid_request_id"
      end
    )
  end

  test "initialized tools call rejects invalid ids without notification side effects", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-BAD-ID-CLAIM")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)

    response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => %{"bad" => "id"},
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert response["id"] == nil
    assert get_in(response, ["error", "data", "reason"]) == "invalid_request_id"
    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
  end

  test "JSON-RPC batches are handled consistently through direct server calls", %{repo: repo} do
    response =
      MCPHarness.request(
        [
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          %{"jsonrpc" => "2.0", "id" => "version", "method" => "resources/read", "params" => %{"uri" => "sympp://health/version"}}
        ],
        repo: repo
      )

    assert [%{"id" => "version", "result" => %{"contents" => [%{"text" => text}]}}] = response
    assert Jason.decode!(text)["mode"] == "stdio"
  end

  test "JSON-RPC batch elements reject nested arrays", %{repo: repo} do
    response =
      MCPHarness.request(
        [
          [
            %{"jsonrpc" => "2.0", "id" => "version", "method" => "resources/read", "params" => %{"uri" => "sympp://health/version"}}
          ]
        ],
        repo: repo
      )

    assert [%{"id" => nil, "error" => %{"code" => -32_600, "data" => %{"reason" => "request_must_be_object"}}}] = response
  end

  test "JSON-RPC batches reject initialize requests", %{repo: repo} do
    response =
      MCPHarness.request(
        [
          %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
          %{"jsonrpc" => "2.0", "id" => "version", "method" => "resources/read", "params" => %{"uri" => "sympp://health/version"}}
        ],
        repo: repo
      )

    assert response["id"] == nil
    assert get_in(response, ["error", "code"]) == -32_600
    assert get_in(response, ["error", "data", "reason"]) == "initialize_must_be_standalone"
  end

  test "JSON-RPC notification-only batches return no response", %{repo: repo} do
    response =
      MCPHarness.request(
        [
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          %{"jsonrpc" => "2.0", "method" => "notifications/cancelled"}
        ],
        repo: repo
      )

    assert response == nil
  end

  test "JSON-RPC request params reject unsupported scalar values", %{repo: repo} do
    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => "bad"},
        repo: repo
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "params_must_be_object_or_array"
  end

  test "object-only MCP methods reject positional params", %{repo: repo} do
    Enum.each(
      [
        {"init", "initialize"},
        {"tools", "tools/list"},
        {"tool", "tools/call"},
        {"resources", "resources/list"},
        {"resource", "resources/read"}
      ],
      fn {id, method} ->
        response =
          MCPHarness.request(
            %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => []},
            repo: repo
          )

        assert get_in(response, ["error", "code"]) == -32_602
        assert get_in(response, ["error", "data", "reason"]) == "params_must_be_object"
      end
    )
  end

  test "JSON-RPC requests reject non-string methods", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => 12, "method" => 123, "params" => %{}}, server)

    assert response["id"] == 12
    assert get_in(response, ["error", "code"]) == -32_600
    assert get_in(response, ["error", "data", "reason"]) == "invalid_method"
  end

  test "JSON-RPC requests without versions reject non-string methods", %{repo: repo} do
    response = MCPHarness.request(%{"id" => "method", "method" => 123}, repo: repo)

    assert get_in(response, ["error", "code"]) == -32_600
    assert get_in(response, ["error", "data", "reason"]) == "invalid_method"
  end

  test "stdio handler rejects empty batches", %{repo: repo} do
    response = Stdio.handle_payload([], Server.new(Config.default(repo: repo)))

    assert response["id"] == nil
    assert get_in(response, ["error", "code"]) == -32_600
    assert get_in(response, ["error", "data", "reason"]) == "empty_batch"
  end

  test "stdio read errors keep expected disconnects graceful" do
    assert :ok = Stdio.handle_read_error(:terminated)
    assert :ok = Stdio.handle_read_error(:closed)

    assert_raise IO.StreamError, fn ->
      Stdio.handle_read_error(:eperm)
    end
  end

  test "stdio decoded payload helper retains response-only initialized state", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    init_response =
      Stdio.handle_payload(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
        server
      )

    tools_response =
      Stdio.handle_payload(
        %{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}},
        server
      )

    assert get_in(init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert is_list(get_in(tools_response, ["result", "tools"]))
  end

  test "stdio handler ignores blank lines and accepts CRLF lines", %{repo: repo} do
    server = Server.new(Config.default(repo: repo), initialized: true)

    assert nil == Stdio.line_response("\r\n", server)
    assert nil == Stdio.line_response("\n", server)

    response =
      Stdio.line_response(
        ~s({"jsonrpc":"2.0","id":10,"method":"resources/read","params":{"uri":"sympp://health/version"}}\r\n),
        server
      )

    assert response["id"] == 10
    assert get_in(response, ["result", "contents", Access.at(0), "uri"]) == "sympp://health/version"
  end

  test "injected session exposes only current assignment and denies sibling package scope", %{repo: repo} do
    assert {:ok, own_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P3-001"))
    assert {:ok, _sibling_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P3-002"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, own_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    assignment_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 5, "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        repo: repo,
        session: session
      )

    assignment_payload =
      assignment_response
      |> get_in(["result", "contents", Access.at(0), "text"])
      |> Jason.decode!()

    assert assignment_payload["work_package_id"] == "SYMPP-P3-001"
    assert assignment_payload["claimed_by"] == "worker-1"
    refute inspect(assignment_payload) =~ minted.work_key.secret

    own_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => 6,
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/SYMPP-P3-001/task_plan.md"}
        },
        repo: repo,
        session: session
      )

    own_text = get_in(own_response, ["result", "contents", Access.at(0), "text"])
    assert own_text =~ "Task Plan"
    assert own_text =~ "SYMPP-P3-001"

    sibling_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/SYMPP-P3-002/task_plan.md"}
        },
        repo: repo,
        session: session
      )

    assert get_in(sibling_response, ["error", "code"]) == -32_003
    assert get_in(sibling_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "claim_local_assignment binds the server session for worker lifecycle tools", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-P3-002")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)

    server = Server.new(Config.default(repo: repo), initialized: true)

    {extra_argument_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-extra-argument",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => Map.put(arguments, "unexpected", "value")
          }
        },
        server
      )

    assert get_in(extra_argument_response, ["error", "data", "reason"]) == "unexpected_argument"

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => arguments
          }
        },
        server
      )

    refute inspect(claim_response) =~ minted.work_key.secret
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-P3-002"
    assert get_in(claim_response, ["result", "structuredContent", "local_claim", "lifecycle_state"]) == "active"
    assert {:ok, active_package} = WorkPackageRepository.get(repo, package.id)
    assert active_package.status == "active"

    {retry_claim_response, retry_claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-retry",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => arguments
          }
        },
        server
      )

    assert get_in(retry_claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-P3-002"
    assert retry_claimed_server.session.assignment.work_package_id == "SYMPP-P3-002"
    assert {:ok, reconnected_package} = WorkPackageRepository.get(repo, package.id)
    assert reconnected_package.status == "active"

    assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        claimed_server
      )

    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "claimed_by"]) == "local-worker-1"

    report_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "report-blocker",
          "method" => "tools/call",
          "params" => %{
            "name" => "report_blocker",
            "arguments" => %{
              "summary" => "Waiting on scoped evidence",
              "idempotency_key" => "worker-blocker"
            }
          }
        },
        claimed_server
      )

    assert get_in(report_response, ["result", "structuredContent", "progress_event", "id"])
    blocker_id = get_in(report_response, ["result", "structuredContent", "blocker_id"])
    assert is_binary(blocker_id)

    assert {:ok, blocked_package} = WorkPackageRepository.get(repo, package.id)
    assert blocked_package.status == "blocked"

    resolve_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "resolve-blocker",
          "method" => "tools/call",
          "params" => %{
            "name" => "resolve_blocker",
            "arguments" => %{
              "blocker_id" => blocker_id,
              "resolution" => "Evidence arrived",
              "summary" => "Scoped evidence received",
              "idempotency_key" => "worker-blocker-resolved"
            }
          }
        },
        claimed_server
      )

    assert get_in(resolve_response, ["result", "structuredContent", "progress_event", "id"])
    assert {:ok, unblocked_package} = WorkPackageRepository.get(repo, package.id)
    assert unblocked_package.status == "active"

    assert {:ok, blocker_events} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.any?(blocker_events, &(&1.payload["blocker_id"] == blocker_id and &1.payload["active"] == true))
    assert Enum.any?(blocker_events, &(&1.payload["blocker_id"] == blocker_id and &1.payload["active"] == false))

    abandon_blocker_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "report-abandon-blocker",
          "method" => "tools/call",
          "params" => %{
            "name" => "report_blocker",
            "arguments" => %{
              "blocker_id" => "abandon-blocker",
              "summary" => "Work cannot continue",
              "idempotency_key" => "abandon-blocker"
            }
          }
        },
        claimed_server
      )

    assert get_in(abandon_blocker_response, ["result", "structuredContent", "progress_event", "id"])
    assert repo.get!(WorkPackage, package.id).status == "blocked"

    abandon_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "abandon",
          "method" => "tools/call",
          "params" => %{"name" => "abandon", "arguments" => %{"reason" => "Intentional worker closeout"}}
        },
        claimed_server
      )

    assert get_in(abandon_response, ["result", "structuredContent", "work_package", "status"]) == "abandoned"
    assert {:ok, abandoned_package} = WorkPackageRepository.get(repo, package.id)
    assert abandoned_package.status == "abandoned"

    assert {:ok, abandoned_events} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.any?(abandoned_events, &(&1.payload["blocker_id"] == "abandon-blocker" and &1.payload["active"] == true))

    assert Enum.any?(abandoned_events, fn event ->
             event.payload["type"] == "blocker_closeout_decision" and
               event.payload["blocker_id"] == "abandon-blocker" and
               event.payload["decision"] == "still_active"
           end)
  end

  test "one of 100 simultaneous owners atomically claims and activates the package", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-ATOMIC-CLAIM-100")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    responses =
      1..100
      |> Task.async_stream(
        fn attempt ->
          arguments = local_assignment_claim_args(package, %{"claimed_by" => "claimant-#{attempt}"})

          Server.handle_state(
            %{
              "jsonrpc" => "2.0",
              "id" => "claim-#{attempt}",
              "method" => "tools/call",
              "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
            },
            local_mcp_server(local_mcp_config(repo), "atomic-claim-#{attempt}")
          )
        end,
        max_concurrency: 100,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, response} -> response end)

    successful = Enum.filter(responses, fn {response, _server} -> get_in(response, ["result", "structuredContent", "assignment"]) end)
    assert length(successful) == 1

    assert Enum.all?(responses -- successful, fn {response, server} ->
             get_in(response, ["result", "structuredContent", "assignment"]) == nil and server.session == nil
           end)

    assert [{_response, winning_server}] = successful
    assert winning_server.session.assignment.work_package_id == package.id

    assert {:ok, active_package} = WorkPackageRepository.get(repo, package.id)
    assert active_package.status == "active"

    assert [active_lease] =
             repo.all(
               from(claim_lease in ClaimLease,
                 where: claim_lease.work_package_id == ^package.id and claim_lease.status == "active"
               )
             )

    assert active_lease.actor_display_name =~ "claimant-"

    assert [claimed_grant] =
             repo.all(
               from(grant in AccessGrant,
                 where: grant.work_package_id == ^package.id and not is_nil(grant.claimed_at) and is_nil(grant.revoked_at)
               )
             )

    assert claimed_grant.id == minted.grant.id
    assert repo.aggregate(from(grant in AccessGrant, where: grant.work_package_id == ^package.id), :count) == 1
    assert repo.aggregate(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id), :count) == 1
  end

  test "claim_local_assignment claims and reconnects a worker session from scoped local identity", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-RECONNECT")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)
    config = local_mcp_config(repo)

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-RECONNECT",
        repo: package.repo,
        base_branch: package.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(
                 id: "WRS-MCP-LOCAL-RECONNECT",
                 base_branch: package.base_branch,
                 branch_pattern: package.branch_pattern
               )
             )

    assert {:ok, _canonical_package} =
             CanonicalWorkPackageFixtures.dispatch_work_package(
               repo,
               work_request.id,
               work_package.id,
               "planned",
               package.id
             )

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(config, "local-claim-state")
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "claimed_by"]) == "local-worker-1"
    assert get_in(claim_response, ["result", "structuredContent", "local_claim", "mode"]) == "local-http"
    claim_text = assert_toon_tool_text!(claim_response)
    assert claim_text =~ "status: ok"
    assert claim_text =~ "work_package_id: #{package.id}"
    refute claim_text =~ "grant_id"
    refute claim_text =~ "claim_lease_id"
    refute claim_text =~ "caller_id"
    refute inspect(claim_response) =~ minted.work_key.secret
    assert claimed_server.session.assignment.work_package_id == package.id
    assert claimed_server.session.proof_hash == minted.grant.secret_hash

    assert {:ok, claimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert claimed_grant.claimed_by == "local-worker-1"

    assert %ClaimLease{actor_display_name: "local-worker-1"} =
             repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id))

    {reconnect_response, reconnected_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-reconnect",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" =>
              arguments
              |> Map.put("work_request_id", work_request.id)
          }
        },
        local_mcp_server(config, "local-reconnect-state")
      )

    assert get_in(reconnect_response, ["result", "structuredContent", "assignment", "grant_id"]) == minted.grant.id
    assert get_in(reconnect_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "heartbeat"

    assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        reconnected_server
      )

    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
  end

  test "claim_local_assignment reconnects same owner across a different caller_id", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-CALLER-ISOLATION")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)

    {claim_response, _claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-caller-isolation-initial",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-caller-isolation-initial-state")
      )

    assert get_in(claim_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "created"
    assert {:ok, %ClaimLease{id: lease_id, last_seen_at: last_seen_at}} = ClaimLeaseService.current_for_work_package(repo, package.id)

    {other_caller_response, other_caller_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-caller-isolation-other",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => Map.put(arguments, "caller_id", "codex-local-other")
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-caller-isolation-other-state")
      )

    assert get_in(other_caller_response, ["result", "structuredContent", "assignment", "grant_id"]) == minted.grant.id
    assert get_in(other_caller_response, ["result", "structuredContent", "local_claim", "caller_id"]) == "codex-local-other"
    assert get_in(other_caller_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "heartbeat"
    assert other_caller_server.session.assignment.work_package_id == package.id

    assert {:ok, %ClaimLease{id: ^lease_id, status: "active", last_seen_at: refreshed_at}} =
             ClaimLeaseService.current_for_work_package(repo, package.id)

    assert DateTime.compare(refreshed_at, last_seen_at) != :lt

    assert repo.aggregate(
             from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id and claim_lease.status != "active"),
             :count
           ) == 0
  end

  test "claim_local_assignment reconnects implicit same owner across local MCP states", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-IMPLICIT-CALLER")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = package |> local_assignment_claim_args() |> Map.delete("caller_id")
    config = local_mcp_config(repo)

    {claim_response, _claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-implicit-caller-initial",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(config, "local-implicit-caller-initial-state")
      )

    assert get_in(claim_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "created"
    initial_caller_id = get_in(claim_response, ["result", "structuredContent", "local_claim", "caller_id"])

    {other_state_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-implicit-caller-other",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(config, "local-implicit-caller-other-state")
      )

    assert get_in(other_state_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(other_state_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "heartbeat"
    other_caller_id = get_in(other_state_response, ["result", "structuredContent", "local_claim", "caller_id"])
    assert is_binary(initial_caller_id)
    assert is_binary(other_caller_id)
    refute initial_caller_id == other_caller_id
  end

  test "claim_local_assignment rejects active orphaned claim lease before grant binding", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-CALLER-IN-FLIGHT")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)

    assert {:ok, %ClaimLease{id: lease_id}} =
             ClaimLeaseService.claim(
               repo,
               package.id,
               local_assignment_claim_actor(arguments),
               stale_after_ms: :timer.minutes(5)
             )

    {other_caller_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-caller-in-flight-other",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => Map.put(arguments, "claimed_by", "local-worker-2")
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-caller-in-flight-other-state")
      )

    assert get_in(other_caller_response, ["error", "data", "reason"]) == "claim_lease_active_for_other_actor"

    assert {:ok, %ClaimLease{id: ^lease_id, status: "active", actor_display_name: "local-worker-1"}} =
             ClaimLeaseService.current_for_work_package(repo, package.id)

    assert repo.aggregate(
             from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id and claim_lease.status != "active"),
             :count
           ) == 0

    assert %ClaimLease{id: ^lease_id, status: "active", release_reason: nil} = repo.get(ClaimLease, lease_id)
  end

  test "claim_local_assignment claims the newest live worker grant", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-NEWEST-GRANT")
    assert {:ok, older} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, newer} = AccessGrantService.mint_worker_grant(repo, package.id)

    repo.update!(
      Ecto.Changeset.change(older.grant,
        inserted_at: ~U[2026-01-01 00:00:00.000000Z],
        updated_at: ~U[2026-01-01 00:00:00.000000Z]
      )
    )

    repo.update!(
      Ecto.Changeset.change(newer.grant,
        inserted_at: ~U[2026-01-02 00:00:00.000000Z],
        updated_at: ~U[2026-01-02 00:00:00.000000Z]
      )
    )

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-newest-grant",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "local-newest-grant-state")
      )

    assert get_in(response, ["result", "structuredContent", "assignment", "grant_id"]) == newer.grant.id
    assert {:ok, unclaimed_older} = AccessGrantRepository.get(repo, older.grant.id)
    assert unclaimed_older.claimed_at == nil
  end
end
