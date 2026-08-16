defmodule SymphonyElixir.SymphonyPlusPlus.MCPHTTPEndpointTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    ClientLeases,
    Config,
    FailedCall,
    HTTPStateStore,
    Session,
    SessionBinding,
    SessionRecovery,
    ToolCatalog
  }

  alias SymphonyElixir.SymphonyPlusPlus.MCP.Server
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository, as: SoloSessionRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.Endpoint

  @endpoint Endpoint
  @client_key "__sympp_mcp_local_http_client__"

  defmodule LazyHTTPRepo do
    @moduledoc false

    use Ecto.Repo, otp_app: :symphony_elixir, adapter: Ecto.Adapters.SQLite3
  end

  defmodule FailingLazyHTTPRepo do
    @moduledoc false

    def __adapter__, do: Ecto.Adapters.SQLite3
    def config, do: Application.get_env(:symphony_elixir, __MODULE__, [])
    def start_link(_opts), do: {:error, :start_failed}
  end

  defmodule RemoteHTTPRepo do
    @moduledoc false

    def config, do: [hostname: "ledger-http.example.test", port: 15_432, database: "sympp"]
    def query("PRAGMA database_list", _params, _opts), do: {:error, :unsupported}
    def query(_sql, _params, _opts), do: {:ok, %{rows: [[1]]}}
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])
    sympp_repo_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

    Application.put_env(
      :symphony_elixir,
      Endpoint,
      endpoint_config
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), sympp_repo: Repo)
    )

    start_supervised!({Repo, database: database_path, pool_size: 1})
    if Process.whereis(Endpoint) == nil, do: start_supervised!({Endpoint, []})

    assert :ok = WorkPackageRepository.migrate(Repo)
    assert :ok = SoloSessionRepository.migrate(Repo)
    assert :ok = PhaseRepository.migrate(Repo)
    assert :ok = WorkRequestRepository.migrate(Repo)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
      restore_sympp_repo_database(sympp_repo_database)
      File.rm(database_path)
    end)

    :ok
  end

  setup do
    reset_server_response_state()
    if Process.whereis(HTTPStateStore) == nil, do: start_supervised!(HTTPStateStore)
    HTTPStateStore.reset!()
    Repo.delete_all(OperatorSettings)
    FailedCall.reset()
    :ok
  end

  test "POST /mcp starts the HTTP state store when endpoint runtime omitted it" do
    restore_mode = remove_http_state_store_for_test()
    on_exit(fn -> restore_http_state_store_for_test(restore_mode) end)

    refute Process.whereis(HTTPStateStore)

    conn = post_json(initialize_request("init"))

    assert %{"jsonrpc" => "2.0", "id" => "init", "result" => %{"serverInfo" => %{"name" => "symphony-plus-plus"}}} =
             json_response(conn, 200)

    assert [_session_id] = get_resp_header(conn, "mcp-session-id")
  end

  test "POST /mcp restarts supervised HTTP state store through the application supervisor" do
    if application_supervises_http_state_store?() do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, HTTPStateStore)
      on_exit(fn -> restore_http_state_store_for_test(:application_supervisor) end)

      refute Process.whereis(HTTPStateStore)

      conn = post_json(initialize_request("restart"))

      assert %{"jsonrpc" => "2.0", "id" => "restart", "result" => %{"serverInfo" => %{"name" => "symphony-plus-plus"}}} =
               json_response(conn, 200)

      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
      assert Process.whereis(HTTPStateStore) == supervised_http_state_store_pid()
    end
  end

  test "POST /mcp initialize returns JSON and Mcp-Session-Id" do
    conn = post_json(initialize_request("init"))

    assert %{"jsonrpc" => "2.0", "id" => "init", "result" => %{"serverInfo" => %{"name" => "symphony-plus-plus"}}} =
             json_response(conn, 200)

    assert [session_id] = get_resp_header(conn, "mcp-session-id")
    assert session_id =~ ~r/^[!-~]+$/
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  test "GET /mcp/readiness is loopback-only and creates no MCP state" do
    before_state = :sys.get_state(HTTPStateStore)

    for _probe <- 1..100 do
      conn = get_local("/mcp/readiness")

      assert %{
               "status" => "ok",
               "source" => %{"revision" => revision, "mcp_contract" => %{"fingerprint" => fingerprint}},
               "mode" => "http",
               "ledger" => %{"reachable" => true, "mode" => ledger_mode},
               "dashboard" => %{"ready" => dashboard_ready?}
             } = json_response(conn, 200)

      assert is_binary(revision) or is_nil(revision)
      assert fingerprint =~ ~r/^[0-9a-f]{64}$/
      assert ledger_mode in ["live", "configured_identity"]
      assert is_boolean(dashboard_ready?)
      assert get_resp_header(conn, "mcp-session-id") == []
    end

    assert :sys.get_state(HTTPStateStore) == before_state

    assert get_in(get_local("/mcp/readiness", [], remote_ip: {10, 0, 0, 2}) |> json_response(403), ["error", "data", "reason"]) ==
             "local_only"

    assert get_in(get_local("/mcp/readiness", [{"x-forwarded-for", "10.0.0.2"}]) |> json_response(403), ["error", "data", "reason"]) ==
             "local_only"

    assert get_in(get_local("/mcp/readiness", [{"origin", "http://localhost:9999"}]) |> json_response(403), ["error", "data", "reason"]) ==
             "origin_not_allowed"
  end

  test "steady HTTP health requests perform no SQLite work inside the recovery heartbeat" do
    init = post_json(initialize_request("steady-health-init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    {responses, queries} =
      capture_queries(fn ->
        for index <- 1..25 do
          post_json(tool_call_request("steady-health-#{index}", "sympp.health", %{}), [{"mcp-session-id", session_id}])
        end
      end)

    assert Enum.all?(responses, fn response ->
             get_in(json_response(response, 200), ["result", "structuredContent", "status"]) == "ok"
           end)

    assert queries == []
  end

  test "POST /mcp/client-lease attaches and detaches launcher clients" do
    on_exit(fn -> ClientLeases.detach("endpoint-client") end)

    attach = post_json(%{"client_id" => "endpoint-client", "action" => "attach"}, [], path: "/mcp/client-lease")
    assert %{"status" => "ok", "active_client_count" => count} = json_response(attach, 200)
    assert count >= 1

    heartbeat = post_json(%{"client_id" => "endpoint-client", "action" => "heartbeat"}, [], path: "/mcp/client-lease")
    assert %{"status" => "ok"} = json_response(heartbeat, 200)

    detach = post_json(%{"client_id" => "endpoint-client", "action" => "detach"}, [], path: "/mcp/client-lease")
    assert %{"status" => "ok"} = json_response(detach, 200)
  end

  test "POST /mcp/client-lease restarts a missing lease worker" do
    on_exit(fn -> ClientLeases.detach("restarted-endpoint-client") end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, ClientLeases)
    refute Process.whereis(ClientLeases)

    attach = post_json(%{"client_id" => "restarted-endpoint-client", "action" => "attach"}, [], path: "/mcp/client-lease")
    assert %{"status" => "ok"} = json_response(attach, 200)
    assert Process.whereis(ClientLeases)
  end

  test "POST /mcp/client-lease keeps loopback and origin checks strict" do
    payload = %{"client_id" => "endpoint-client", "action" => "attach"}

    assert get_in(post_json(payload, [], path: "/mcp/client-lease", remote_ip: {10, 0, 0, 2}) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "local_only"

    assert get_in(post_json(payload, [{"x-forwarded-for", "10.0.0.2"}], path: "/mcp/client-lease") |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "local_only"

    assert get_in(post_json(payload, [{"origin", "http://localhost:9999"}], path: "/mcp/client-lease") |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "origin_not_allowed"
  end

  test "POST /mcp tools/list uses Mcp-Session-Id continuity" do
    init = post_json(initialize_request("init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    conn = post_json(tools_list_request("tools"), [{"mcp-session-id", session_id}])

    assert [^session_id] = get_resp_header(conn, "mcp-session-id")

    names = tool_names(json_response(conn, 200))
    assert length(names) == length(Enum.uniq(names))

    expected_names =
      Config.default(repo: Repo)
      |> ToolCatalog.unbound_tool_specs_for_config()
      |> Kernel.++(ToolCatalog.local_operator_tool_specs())
      |> Enum.map(& &1["name"])
      |> Enum.uniq()

    for tool <- expected_names do
      assert tool in names
    end
  end

  test "POST /mcp exposes and runs local operator WorkRequest note tools on loopback" do
    assert {:ok, work_request} =
             WorkRequestRepository.create(Repo, work_request_attrs(%{id: "WR-HTTP-ENDPOINT-LOCAL-OPERATOR"}))

    init = post_json(initialize_request("local-operator-init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    assert %Server{
             config: %Config{mode: :http, local_daemon_trusted: true},
             local_daemon_trusted: true
           } = stored_http_server()

    tools = post_json(tools_list_request("local-operator-tools"), [{"mcp-session-id", session_id}])
    names = tool_names(json_response(tools, 200))

    assert "add_work_request_comment" in names
    assert "record_work_request_operator_decision" in names

    comment =
      post_json(
        tool_call_request("local-operator-comment", "add_work_request_comment", %{
          "work_request_id" => work_request.id,
          "body" => "Endpoint operator noted ghp_endpointsecret",
          "created_by" => "endpoint operator"
        }),
        [{"mcp-session-id", session_id}]
      )

    assert [^session_id] = get_resp_header(comment, "mcp-session-id")
    payload = json_response(comment, 200)
    assert get_in(payload, ["result", "structuredContent", "comment", "source_type"]) == "operator"
    assert get_in(payload, ["result", "structuredContent", "comment", "body"]) == "Endpoint operator noted [REDACTED]"
  end

  test "POST /mcp tools/list follows a session initialized from the live dashboard repo" do
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    Application.delete_env(:symphony_elixir, :sympp_repo_database)

    on_exit(fn -> restore_sympp_repo_database(original_database) end)

    init = post_json(initialize_request("live-init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    conn = post_json(tools_list_request("live-tools"), [{"mcp-session-id", session_id}])

    assert [^session_id] = get_resp_header(conn, "mcp-session-id")
    assert "sympp.health" in tool_names(json_response(conn, 200))
  end

  test "POST /mcp persists claimed worker continuity over same Mcp-Session-Id" do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-HTTP-ENDPOINT-WORKER",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "main",
                 branch_pattern: "agent/SYMPP-HTTP-ENDPOINT-WORKER/worker",
                 worktree_path: local_claim_worktree_path("SYMPP-HTTP-ENDPOINT-WORKER"),
                 status: "ready_for_worker"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(Repo, work_package.id)

    init = post_json(initialize_request("init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    claim =
      post_json(
        tool_call_request("claim", "claim_local_assignment", local_assignment_claim_args(work_package, %{"claimed_by" => "worker-http"})),
        [{"mcp-session-id", session_id}]
      )

    assert [^session_id] = get_resp_header(claim, "mcp-session-id")
    assert get_in(json_response(claim, 200), ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id
    refute inspect(json_response(claim, 200)) =~ minted.work_key.secret

    tools = post_json(tools_list_request("worker-tools"), [{"mcp-session-id", session_id}])
    tool_names = tool_names(json_response(tools, 200))

    assert "get_current_assignment" in tool_names
    assert "append_progress" in tool_names
    refute "claim_local_assignment" in tool_names
    refute "claim_private_handoff" in tool_names
    refute "solo_attach" in tool_names

    assignment_tool =
      post_json(tool_call_request("assignment-tool", "get_current_assignment", %{}), [{"mcp-session-id", session_id}])

    assert get_in(json_response(assignment_tool, 200), ["result", "structuredContent", "assignment", "work_package_id"]) ==
             work_package.id

    assignment_resource =
      post_json(resources_read_request("assignment-resource", "sympp://assignment/current"), [{"mcp-session-id", session_id}])

    assignment_payload =
      assignment_resource
      |> json_response(200)
      |> resource_payload()

    assert assignment_payload["work_package_id"] == work_package.id

    resources = post_json(resources_list_request("resources"), [{"mcp-session-id", session_id}])

    assert "sympp://work-packages/#{work_package.id}/task_plan.md" in resource_uris(json_response(resources, 200))
  end

  test "POST /mcp persists claimed architect continuity for scoped WorkRequest reads" do
    assert {:ok, work_request} =
             WorkRequestRepository.create(
               Repo,
               work_request_attrs(%{
                 id: "WR-HTTP-ENDPOINT-ARCHITECT",
                 status: "ready_for_slicing"
               })
             )

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(Repo, work_request.id,
               local_operator?: true,
               handoff_opts: local_architect_handoff_opts()
             )

    init = post_json(initialize_request("init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    claim =
      post_json(
        tool_call_request("claim", "claim_local_architect_assignment", %{"work_request_id" => work_request.id, "claimed_by" => "architect-http"}),
        [{"mcp-session-id", session_id}]
      )

    assert get_in(json_response(claim, 200), ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert get_in(json_response(claim, 200), ["result", "structuredContent", "assignment", "work_package_id"]) == handoff.anchor_package.id

    tools = post_json(tools_list_request("architect-tools"), [{"mcp-session-id", session_id}])
    tool_names = tool_names(json_response(tools, 200))

    assert "get_current_assignment" in tool_names
    assert "read_work_request" in tool_names
    assert "dispatch_work_package" in tool_names
    refute "solo_attach" in tool_names

    read =
      post_json(
        tool_call_request("read-work-request", "read_work_request", %{"work_request_id" => work_request.id}),
        [{"mcp-session-id", session_id}]
      )

    assert get_in(json_response(read, 200), ["result", "structuredContent", "work_request", "id"]) == work_request.id
  end

  test "POST /mcp rehydrates claimed local worker session after backend state reset" do
    package_id = "SYMPP-HTTP-REHYDRATE-WORKER"

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(
                 id: package_id,
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "main",
                 branch_pattern: "agent/#{package_id}/worker",
                 worktree_path: local_claim_worktree_path(package_id),
                 status: "ready_for_worker"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(Repo, work_package.id)

    init = post_json(initialize_request("local-worker-init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    claim =
      post_json(
        tool_call_request(
          "local-worker-claim",
          "claim_local_assignment",
          local_assignment_claim_args(work_package, %{
            "caller_id" => "codex-http-rehydrate-worker",
            "claimed_by" => "local-worker-http-rehydrate"
          })
        ),
        [{"mcp-session-id", session_id}]
      )

    claim_payload = get_in(json_response(claim, 200), ["result", "structuredContent"])
    assert get_in(claim_payload, ["assignment", "work_package_id"]) == work_package.id
    assert get_in(claim_payload, ["local_claim", "claim_lease_action"]) == "created"
    claim_lease_id = get_in(claim_payload, ["local_claim", "claim_lease_id"])

    binding = Repo.get!(SessionBinding, SessionBinding.binding_id(@client_key, session_id))
    assert binding.recoverable
    refute inspect(binding) =~ minted.work_key.secret
    refute inspect(binding) =~ minted.grant.secret_hash

    near_expiry_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -82_800_000, :millisecond)

    assert {1, nil} =
             Repo.update_all(
               from(stored_binding in SessionBinding, where: stored_binding.id == ^binding.id),
               set: [last_seen_at: near_expiry_seen_at]
             )

    reset_mcp_runtime_state()

    assignment =
      post_json(tool_call_request("local-worker-assignment", "get_current_assignment", %{}), [{"mcp-session-id", session_id}])

    assert get_in(json_response(assignment, 200), ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id
    assert DateTime.compare(Repo.get!(SessionBinding, binding.id).last_seen_at, near_expiry_seen_at) == :gt

    context = post_json(tool_call_request("local-worker-context", "read_context", %{}), [{"mcp-session-id", session_id}])

    assert get_in(json_response(context, 200), ["result", "structuredContent", "uri"]) ==
             "sympp://work-packages/#{work_package.id}/context.md"

    progress =
      post_json(
        tool_call_request("local-worker-progress", "append_progress", %{
          "summary" => "Progress after MCP restart",
          "idempotency_key" => "local-worker-progress-after-restart"
        }),
        [{"mcp-session-id", session_id}]
      )

    assert get_in(json_response(progress, 200), ["result", "structuredContent", "progress_event", "summary"]) == "Progress after MCP restart"
    assert [%ClaimLease{id: ^claim_lease_id, actor_display_name: "local-worker-http-rehydrate"}] = active_claim_leases(work_package.id)
    assert %Server{session: %Session{assignment: %{work_package_id: ^package_id}}} = stored_http_server()
  end

  test "POST /mcp clears stale recovery binding when local claim metadata cannot be verified" do
    package_id = "SYMPP-HTTP-STALE-BIND"

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(
                 id: package_id,
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "main",
                 branch_pattern: "agent/#{package_id}/worker",
                 worktree_path: local_claim_worktree_path(package_id),
                 status: "ready_for_worker"
               )
             )

    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(Repo, work_package.id)

    init = post_json(initialize_request("stale-binding-init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    claim =
      post_json(
        tool_call_request(
          "stale-binding-claim",
          "claim_local_assignment",
          local_assignment_claim_args(work_package, %{
            "caller_id" => "codex-http-stale-binding-worker",
            "claimed_by" => "local-worker-http-stale-binding"
          })
        ),
        [{"mcp-session-id", session_id}]
      )

    claim_payload = get_in(json_response(claim, 200), ["result", "structuredContent"])
    assert get_in(claim_payload, ["assignment", "work_package_id"]) == work_package.id
    claim_lease_id = get_in(claim_payload, ["local_claim", "claim_lease_id"])

    assert Repo.get!(SessionBinding, SessionBinding.binding_id(@client_key, session_id)).recoverable

    stale_session =
      Session.new(%Assignment{
        grant_id: "grant-stale-binding",
        work_package_id: work_package.id,
        phase_id: nil,
        display_key: work_package.id,
        grant_role: "worker",
        capabilities: ["read:assignment"],
        claimed_at: DateTime.utc_now(:microsecond),
        claimed_by: "different-worker"
      })

    config = Config.default(mode: :http, repo: Repo, local_daemon_trusted: true)

    SessionRecovery.remember(
      config,
      @client_key,
      session_id,
      tool_call_request("stale-binding-unverified-claim", "claim_local_assignment", %{}),
      Server.new(config, initialized: true, local_daemon_trusted: true, session: stale_session, state_key: session_id),
      %{
        "result" => %{
          "structuredContent" => %{
            "assignment" => %{"work_package_id" => work_package.id},
            "local_claim" => %{"claim_lease_id" => claim_lease_id}
          }
        }
      }
    )

    binding = Repo.get!(SessionBinding, SessionBinding.binding_id(@client_key, session_id))
    refute binding.recoverable
    assert binding.access_grant_id == nil
    assert binding.claim_lease_id == nil

    reset_mcp_runtime_state()

    assignment =
      post_json(tool_call_request("stale-binding-assignment", "get_current_assignment", %{}), [{"mcp-session-id", session_id}])

    assert get_in(json_response(assignment, 200), ["error", "data", "reason"]) == "claim_required"
    assert [%ClaimLease{id: ^claim_lease_id, actor_display_name: "local-worker-http-stale-binding"}] = active_claim_leases(work_package.id)
  end

  test "POST /mcp refreshes stale durable binding before cleanup" do
    package_id = "SYMPP-HTTP-STALE-TOUCH"

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(
                 id: package_id,
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "main",
                 branch_pattern: "agent/#{package_id}/worker",
                 worktree_path: local_claim_worktree_path(package_id),
                 status: "ready_for_worker"
               )
             )

    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(Repo, work_package.id)

    init = post_json(initialize_request("stale-touch-init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    claim =
      post_json(
        tool_call_request(
          "stale-touch-claim",
          "claim_local_assignment",
          local_assignment_claim_args(work_package, %{
            "caller_id" => "codex-http-stale-touch-worker",
            "claimed_by" => "local-worker-http-stale-touch"
          })
        ),
        [{"mcp-session-id", session_id}]
      )

    assert get_in(json_response(claim, 200), ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id

    binding_id = SessionBinding.binding_id(@client_key, session_id)
    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -172_800_000, :millisecond)

    assert {1, nil} =
             Repo.update_all(
               from(binding in SessionBinding, where: binding.id == ^binding_id),
               set: [last_seen_at: stale_seen_at]
             )

    :sys.replace_state(HTTPStateStore, fn state ->
      due = System.monotonic_time(:millisecond) - 1
      %{state | deadlines: Map.new(state.deadlines, fn {key, _deadline} -> {key, due} end)}
    end)

    touch =
      post_json(tool_call_request("stale-touch-assignment", "get_current_assignment", %{}), [{"mcp-session-id", session_id}])

    assert get_in(json_response(touch, 200), ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id
    assert DateTime.compare(Repo.get!(SessionBinding, binding_id).last_seen_at, stale_seen_at) == :gt

    reset_mcp_runtime_state()

    assignment =
      post_json(tool_call_request("stale-touch-rehydrated-assignment", "get_current_assignment", %{}), [{"mcp-session-id", session_id}])

    assert get_in(json_response(assignment, 200), ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id
  end

  test "POST /mcp rehydrates claimed local architect session after backend state reset" do
    assert {:ok, work_request} =
             WorkRequestRepository.create(
               Repo,
               work_request_attrs(%{
                 id: "WR-HTTP-REHYDRATE-ARCHITECT",
                 status: "ready_for_clarification"
               })
             )

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(Repo, work_request.id,
               local_operator?: true,
               handoff_opts: local_architect_handoff_opts()
             )

    init = post_json(initialize_request("local-architect-init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    claim =
      post_json(
        tool_call_request("local-architect-claim", "claim_local_architect_assignment", %{
          "work_request_id" => work_request.id,
          "architect_anchor_work_package_id" => handoff.anchor_package.id,
          "repo" => work_request.repo,
          "base_branch" => work_request.base_branch,
          "phase_id" => handoff.phase.id,
          "caller_id" => "codex-http-rehydrate-architect",
          "claimed_by" => "local-architect-http-rehydrate"
        }),
        [{"mcp-session-id", session_id}]
      )

    claim_payload = get_in(json_response(claim, 200), ["result", "structuredContent"])
    assert get_in(claim_payload, ["assignment", "grant_role"]) == "architect"
    assert get_in(claim_payload, ["assignment", "work_package_id"]) == handoff.anchor_package.id
    assert get_in(claim_payload, ["local_claim", "claim_lease_action"]) == "created"
    claim_lease_id = get_in(claim_payload, ["local_claim", "claim_lease_id"])

    reset_mcp_runtime_state()

    read =
      post_json(
        tool_call_request("local-architect-read", "read_work_request", %{"work_request_id" => work_request.id}),
        [{"mcp-session-id", session_id}]
      )

    assert get_in(json_response(read, 200), ["result", "structuredContent", "work_request", "id"]) == work_request.id

    guidance =
      post_json(tool_call_request("local-architect-guidance", "list_guidance_requests", %{}), [{"mcp-session-id", session_id}])

    assert get_in(json_response(guidance, 200), ["result", "structuredContent", "guidance_requests"]) == []

    delivery_board =
      post_json(
        tool_call_request("local-architect-delivery-board", "read_delivery_board", %{"work_request_id" => work_request.id}),
        [{"mcp-session-id", session_id}]
      )

    assert get_in(json_response(delivery_board, 200), ["result", "structuredContent", "work_request", "id"]) == work_request.id
    assert [%ClaimLease{id: ^claim_lease_id, actor_display_name: "local-architect-http-rehydrate"}] = active_claim_leases(handoff.anchor_package.id)
  end

  test "POST /mcp unclaimed sessions fall back to clear claim_required errors after state reset" do
    unclaimed_init = post_json(initialize_request("unclaimed-init"))
    [unclaimed_session_id] = get_resp_header(unclaimed_init, "mcp-session-id")

    reset_mcp_runtime_state()

    preclaim_progress =
      post_json(
        tool_call_request("unclaimed-progress", "append_progress", %{
          "summary" => "Should not write",
          "idempotency_key" => "unclaimed-progress"
        }),
        [{"mcp-session-id", unclaimed_session_id}]
      )

    assert get_in(json_response(preclaim_progress, 200), ["error", "data", "reason"]) == "claim_required"

    preclaim_tools = post_json(tools_list_request("unclaimed-tools"), [{"mcp-session-id", unclaimed_session_id}])
    assert "claim_local_assignment" in tool_names(json_response(preclaim_tools, 200))
  end

  test "POST /mcp claimed worker follow-ups fail closed after grant revocation" do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-HTTP-ENDPOINT-REVOKED",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "main",
                 branch_pattern: "agent/SYMPP-HTTP-ENDPOINT-REVOKED/worker",
                 worktree_path: local_claim_worktree_path("SYMPP-HTTP-ENDPOINT-REVOKED"),
                 status: "ready_for_worker"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(Repo, work_package.id)

    init = post_json(initialize_request("init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    claim =
      post_json(
        tool_call_request("claim", "claim_local_assignment", local_assignment_claim_args(work_package, %{"claimed_by" => "worker-revoked"})),
        [{"mcp-session-id", session_id}]
      )

    assert get_in(json_response(claim, 200), ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id
    assert {:ok, _revoked} = AccessGrantService.revoke(Repo, minted.grant.id)

    tools = post_json(tools_list_request("revoked-tools"), [{"mcp-session-id", session_id}])
    tool_names = tool_names(json_response(tools, 200))

    assert "claim_local_assignment" in tool_names
    assert "claim_local_architect_assignment" in tool_names
    refute "get_current_assignment" in tool_names

    assignment_tool =
      post_json(tool_call_request("revoked-assignment", "get_current_assignment", %{}), [{"mcp-session-id", session_id}])

    assert get_in(json_response(assignment_tool, 200), ["error", "data", "reason"]) == "revoked"

    progress =
      post_json(
        tool_call_request("revoked-progress", "append_progress", %{"summary" => "Should not write", "idempotency_key" => "revoked-progress"}),
        [{"mcp-session-id", session_id}]
      )

    assert get_in(json_response(progress, 200), ["error", "data", "reason"]) == "claim_required"

    assignment_resource =
      post_json(resources_read_request("revoked-resource", "sympp://assignment/current"), [{"mcp-session-id", session_id}])

    assert get_in(json_response(assignment_resource, 200), ["error", "data", "reason"]) == "missing_session"
  end

  test "POST /mcp dispatches Solo tools through the dashboard lazy repo seam" do
    database_path = WorkPackageFactory.database_path()
    workspace_path = solo_workspace_path("lazy-repo")
    original_repo_config = Application.get_env(:symphony_elixir, LazyHTTPRepo)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.put_env(:symphony_elixir, LazyHTTPRepo, database: database_path)

    on_exit(fn ->
      restore_app_env(LazyHTTPRepo, original_repo_config)
      restore_sympp_repo_database(original_database)
      File.rm(database_path)
      File.rm_rf(workspace_path)
    end)

    with_endpoint_repo(LazyHTTPRepo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")

      pre_attach_health = post_json(tool_call_request("health", "sympp.health", %{}), [{"mcp-session-id", session_id}])
      tool_notification = post_json(tool_call_notification("solo_list", %{}), [{"mcp-session-id", session_id}])

      conn =
        post_json(
          tool_call_request("attach", "solo_attach", %{
            "repo" => "nextide/example",
            "base_branch" => "main",
            "workspace_path" => workspace_path,
            "caller_id" => "codex-local"
          }),
          [{"mcp-session-id", session_id}]
        )

      post_attach_health = post_json(tool_call_request("health-after-attach", "sympp.health", %{}), [{"mcp-session-id", session_id}])

      assert get_in(json_response(pre_attach_health, 200), ["result", "structuredContent", "status"]) == "degraded"
      assert get_in(json_response(pre_attach_health, 200), ["result", "structuredContent", "ledger", "reachable"]) == false
      assert response(tool_notification, 202) == ""
      assert get_in(json_response(conn, 200), ["result", "structuredContent", "action"]) == "solo_attach"
      assert get_in(json_response(post_attach_health, 200), ["result", "structuredContent", "status"]) == "ok"
      assert get_in(json_response(post_attach_health, 200), ["result", "structuredContent", "ledger", "reachable"]) == true
      assert File.exists?(database_path)
    end)
  end

  test "POST /mcp keeps custom repo startup discovery independent from fallback database" do
    fallback_database_path = WorkPackageFactory.database_path()
    original_repo_config = Application.get_env(:symphony_elixir, Repo)
    original_lazy_repo_config = Application.get_env(:symphony_elixir, LazyHTTPRepo)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.delete_env(:symphony_elixir, :sympp_repo_database)
    Application.put_env(:symphony_elixir, Repo, database: fallback_database_path)
    Application.delete_env(:symphony_elixir, LazyHTTPRepo)

    on_exit(fn ->
      restore_app_env(Repo, original_repo_config)
      restore_app_env(LazyHTTPRepo, original_lazy_repo_config)
      restore_sympp_repo_database(original_database)
      File.rm(fallback_database_path)
    end)

    with_endpoint_repo(LazyHTTPRepo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")

      tools = post_json(tools_list_request("tools"), [{"mcp-session-id", session_id}])

      assert "sympp.health" in tool_names(json_response(tools, 200))
      refute File.exists?(fallback_database_path)
    end)
  end

  test "POST /mcp keeps default repo startup discovery independent from fallback database" do
    fallback_database_path = WorkPackageFactory.database_path()
    original_repo_config = Application.get_env(:symphony_elixir, Repo)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.delete_env(:symphony_elixir, :sympp_repo_database)
    Application.put_env(:symphony_elixir, Repo, database: fallback_database_path)

    on_exit(fn ->
      restore_app_env(Repo, original_repo_config)
      restore_sympp_repo_database(original_database)
      File.rm(fallback_database_path)
    end)

    with_endpoint_repo(Repo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")

      tools = post_json(tools_list_request("tools"), [{"mcp-session-id", session_id}])
      health = post_json(tool_call_request("health", "sympp.health", %{}), [{"mcp-session-id", session_id}])

      assert "sympp.health" in tool_names(json_response(tools, 200))
      assert get_in(json_response(health, 200), ["result", "structuredContent", "status"]) == "degraded"
      refute File.exists?(fallback_database_path)
    end)
  end

  test "POST /mcp preserves live health for remote custom repo config" do
    with_endpoint_repo(RemoteHTTPRepo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")

      health = post_json(tool_call_request("health", "sympp.health", %{}), [{"mcp-session-id", session_id}])
      structured = get_in(json_response(health, 200), ["result", "structuredContent"])

      assert structured["status"] == "ok"
      assert structured["ledger"]["reachable"] == true

      assert structured["ledger"]["identity"] == %{
               "kind" => "server",
               "source" => "explicit",
               "endpoint" => "server://ledger-http.example.test:15432"
             }
    end)
  end

  test "POST /mcp keeps state-local follow-up traffic independent from lazy repo failures" do
    database_path = WorkPackageFactory.database_path()
    mismatch_database_path = WorkPackageFactory.database_path()
    original_repo_config = Application.get_env(:symphony_elixir, LazyHTTPRepo)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.delete_env(:symphony_elixir, :sympp_repo_database)
    Application.put_env(:symphony_elixir, LazyHTTPRepo, database: database_path)

    on_exit(fn ->
      if pid = Process.whereis(LazyHTTPRepo), do: GenServer.stop(pid, :normal, 5_000)
      restore_app_env(LazyHTTPRepo, original_repo_config)
      restore_sympp_repo_database(original_database)
      File.rm_rf(database_path)
      File.rm(mismatch_database_path)
    end)

    with_endpoint_repo(LazyHTTPRepo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")

      {:ok, mismatch_repo} = LazyHTTPRepo.start_link(database: mismatch_database_path, pool_size: 1)
      Process.unlink(mismatch_repo)

      tools = post_json(tools_list_request("tools"), [{"mcp-session-id", session_id}])
      notification = post_json(notification_request(), [{"mcp-session-id", session_id}])
      repo_backed = post_json(tool_call_request("repo-backed", "solo_list", %{}), [{"mcp-session-id", session_id}])
      repo_backed_notification = post_json(tool_call_notification("solo_list", %{}), [{"mcp-session-id", session_id}])
      repo_backed_resource = post_json(resources_list_request("resources"), [{"mcp-session-id", session_id}])
      health = post_json(tool_call_request("health", "sympp.health", %{}), [{"mcp-session-id", session_id}])

      version_resource =
        post_json(resources_read_request("version", "sympp://health/version"), [{"mcp-session-id", session_id}])

      protected_resource =
        post_json(
          resources_read_request("protected", "sympp://work-packages/SYMPP-MCP-HTTP/task_plan.md"),
          [{"mcp-session-id", session_id}]
        )

      unknown = post_json(tools_list_request("missing"), [{"mcp-session-id", "missing-session"}])

      assert "solo_attach" in tool_names(json_response(tools, 200))
      assert response(notification, 202) == ""
      assert json_response(repo_backed, 503) == json_rpc_error("repo-backed", -32_000, "Server error", "ledger_unavailable")
      assert json_response(repo_backed_notification, 503) == json_rpc_error(nil, -32_000, "Server error", "ledger_unavailable")
      assert json_response(repo_backed_resource, 503) == json_rpc_error("resources", -32_000, "Server error", "ledger_unavailable")
      assert get_in(json_response(health, 200), ["result", "structuredContent", "mode"]) == "http"
      assert get_in(json_response(version_resource, 200), ["result", "contents", Access.at(0), "uri"]) == "sympp://health/version"
      assert json_response(protected_resource, 503) == json_rpc_error("protected", -32_000, "Server error", "ledger_unavailable")
      assert get_in(json_response(unknown, 404), ["error", "data", "reason"]) == "unknown_state_key"
    end)
  end

  test "POST /mcp routes claimed tools/list through the dashboard lazy repo seam" do
    database_path = WorkPackageFactory.database_path()
    mismatch_database_path = WorkPackageFactory.database_path()
    original_repo_config = Application.get_env(:symphony_elixir, LazyHTTPRepo)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.delete_env(:symphony_elixir, :sympp_repo_database)
    Application.put_env(:symphony_elixir, LazyHTTPRepo, database: database_path)

    on_exit(fn ->
      if pid = Process.whereis(LazyHTTPRepo), do: GenServer.stop(pid, :normal, 5_000)
      restore_app_env(LazyHTTPRepo, original_repo_config)
      restore_sympp_repo_database(original_database)
      File.rm(database_path)
      File.rm(mismatch_database_path)
    end)

    with_endpoint_repo(LazyHTTPRepo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")
      config = Config.default(mode: :http, repo: LazyHTTPRepo, database: database_path)
      %Server{} = server = HTTPStateStore.get(config, @client_key, session_id)

      assert :ok = HTTPStateStore.put(config, @client_key, session_id, %{server | session: claimed_session()})

      {:ok, mismatch_repo} = LazyHTTPRepo.start_link(database: mismatch_database_path, pool_size: 1)
      Process.unlink(mismatch_repo)

      conn = post_json(tools_list_request("claimed-tools"), [{"mcp-session-id", session_id}])

      assert json_response(conn, 503) == json_rpc_error("claimed-tools", -32_000, "Server error", "ledger_unavailable")
    end)
  end

  test "POST /mcp keeps startup discovery DB-free when dashboard lazy repo startup fails" do
    database_path = WorkPackageFactory.database_path()
    original_repo_config = Application.get_env(:symphony_elixir, FailingLazyHTTPRepo)

    Application.put_env(:symphony_elixir, FailingLazyHTTPRepo, database: database_path)

    on_exit(fn ->
      restore_app_env(FailingLazyHTTPRepo, original_repo_config)
      File.rm(database_path)
    end)

    with_endpoint_repo(FailingLazyHTTPRepo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")

      tools = post_json(tools_list_request("tools"), [{"mcp-session-id", session_id}])
      health = post_json(tool_call_request("health", "sympp.health", %{}), [{"mcp-session-id", session_id}])
      repo_backed = post_json(tool_call_request("repo-backed", "solo_list", %{}), [{"mcp-session-id", session_id}])

      assert get_in(json_response(init, 200), ["result", "serverInfo", "name"]) == "symphony-plus-plus"
      assert "sympp.health" in tool_names(json_response(tools, 200))
      assert get_in(json_response(health, 200), ["result", "structuredContent", "mode"]) == "http"
      assert json_response(repo_backed, 503) == json_rpc_error("repo-backed", -32_000, "Server error", "ledger_unavailable")

      assert Enum.any?(Map.keys(:sys.get_state(HTTPStateStore).entries), fn
               {_namespace, _database_key, @client_key, ^session_id} -> true
               _entry -> false
             end)
    end)
  end

  test "POST /mcp notification returns 202 with no body and preserves state" do
    init = post_json(initialize_request("init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    notification = post_json(notification_request(), [{"mcp-session-id", session_id}])

    assert response(notification, 202) == ""
    assert [^session_id] = get_resp_header(notification, "mcp-session-id")

    conn = post_json(tools_list_request("after-notification"), [{"mcp-session-id", session_id}])

    assert "sympp.health" in tool_names(json_response(conn, 200))
  end

  test "POST /mcp requires Mcp-Session-Id for non-initialize requests" do
    conn = post_json(tools_list_request("tools"))

    assert json_response(conn, 400) == json_rpc_error("tools", -32_600, "Invalid Request", "missing_session_id")
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "POST /mcp observes failed tool requests and notifications once at the endpoint boundary" do
    assert {:ok, _settings} = OperatorSettingsRepository.update(Repo, %{"capture_failed_mcp_calls" => true})

    {request, request_log} =
      with_log(fn -> post_json(tool_call_request("private-endpoint-id", "sympp.health", %{"bearer" => "request-secret"})) end)

    request_error = json_response(request, 400)
    diagnostic_id = get_in(request_error, ["error", "data", "diagnostic_id"])
    assert diagnostic_id =~ ~r/^mcpdiag_[0-9a-f]{16}$/
    assert [request_event] = diagnostic_events(request_log)
    assert request_event["failure_layer"] == "endpoint"
    assert request_event["failure_reason"] == "missing_session_id"
    assert request_event["diagnostic_id"] == diagnostic_id

    {notification, notification_log} =
      with_log(fn -> post_json(tool_call_notification("sympp.health", %{"bearer" => "notification-secret"})) end)

    assert get_in(json_response(notification, 400), ["error", "data", "reason"]) == "missing_session_id"
    assert [notification_event] = diagnostic_events(notification_log)
    assert notification_event["failure_layer"] == "endpoint"
    refute request_log =~ "private-endpoint-id"
    refute request_log =~ "request-secret"
    refute notification_log =~ "notification-secret"
  end

  test "POST /mcp rejects JSON-RPC batches before session handling" do
    init_batch = post_json([initialize_request("init")])
    mixed_batch = post_json([initialize_request("init"), tools_list_request("tools")])

    assert json_response(init_batch, 400) == json_rpc_error(nil, -32_600, "Invalid Request", "batch_not_supported")

    assert json_response(mixed_batch, 400) ==
             json_rpc_error(nil, -32_600, "Invalid Request", "batch_not_supported")

    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "POST /mcp rejects JSON-RPC batches before Mcp-Session-Id continuity" do
    init = post_json(initialize_request("init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    conn = post_json([initialize_request("init"), tools_list_request("tools")])

    conn_with_session = post_json([tools_list_request("tools")], [{"mcp-session-id", session_id}])

    assert json_response(conn, 400) == json_rpc_error(nil, -32_600, "Invalid Request", "batch_not_supported")

    assert json_response(conn_with_session, 400) ==
             json_rpc_error(nil, -32_600, "Invalid Request", "batch_not_supported")
  end

  test "POST /mcp rejects unknown Mcp-Session-Id without creating state" do
    conn = post_json(tools_list_request("tools"), [{"mcp-session-id", "missing-session"}])

    assert get_in(json_response(conn, 404), ["error", "data", "reason"]) == "unknown_state_key"
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "POST /mcp rejects unknown Mcp-Session-Id for notifications" do
    conn = post_json(notification_request(), [{"mcp-session-id", "missing-session"}])

    assert json_response(conn, 404) == json_rpc_error(nil, -32_600, "Invalid Request", "unknown_state_key")
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "POST /mcp rejects malformed Mcp-Session-Id bytes without crashing" do
    conn = post_json(tools_list_request("tools"), [{"mcp-session-id", <<255>>}])

    assert json_response(conn, 400) == json_rpc_error("tools", -32_600, "Invalid Request", "invalid_session_id")
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "POST /mcp rejects reserved Mcp-Session-Id values without dispatching" do
    conn = post_json(tools_list_request("tools"), [{"mcp-session-id", "__sympp_mcp_current_state__"}])

    assert json_response(conn, 400) == json_rpc_error("tools", -32_600, "Invalid Request", "invalid_session_id")
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "POST /mcp invalid JSON returns controlled JSON-RPC error" do
    conn = post_raw("{")

    assert json_response(conn, 400) == json_rpc_error(nil, -32_700, "Parse error", "invalid_json")
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "GET /mcp returns 405 because this slice does not implement SSE" do
    conn =
      local_conn()
      |> get("/mcp")

    assert json_response(conn, 405) == json_rpc_error(nil, -32_601, "Method not found", "method_not_allowed")
    assert get_resp_header(conn, "allow") == ["POST"]
  end

  test "POST /mcp rejects non-loopback, forwarded, and cross-origin requests" do
    assert get_in(post_json(initialize_request("remote"), [], remote_ip: {10, 0, 0, 2}) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "local_only"

    assert get_in(post_json(initialize_request("forwarded"), [{"x-forwarded-for", "10.0.0.2"}]) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "local_only"

    assert get_in(post_json(initialize_request("origin"), [{"origin", "http://localhost:9999"}]) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "origin_not_allowed"

    assert get_in(post_json(initialize_request("malformed-host"), [], host: <<255>>) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "local_only"

    assert get_in(post_json(initialize_request("malformed-origin"), [{"origin", <<255>>}]) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "origin_not_allowed"

    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  defp post_json(payload, headers \\ [], opts \\ []) do
    payload
    |> Jason.encode!()
    |> post_raw(headers, opts)
  end

  defp get_local(path, headers \\ [], opts \\ []) do
    opts
    |> local_conn()
    |> put_headers(headers)
    |> get(path)
  end

  defp capture_queries(fun) do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    event = Repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, test_pid -> send(test_pid, {handler_id, metadata.query}) end,
        self()
      )

    try do
      result = fun.()
      {result, drain_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, queries) do
    receive do
      {^handler_id, query} -> drain_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp post_raw(body, headers \\ [], opts \\ []) do
    headers = [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"} | headers]
    path = Keyword.get(opts, :path, "/mcp")

    opts
    |> local_conn()
    |> put_headers(headers)
    |> post(path, body)
  end

  defp local_conn(opts \\ []) do
    build_conn()
    |> Map.put(:host, Keyword.get(opts, :host, "localhost"))
    |> Map.put(:port, Keyword.get(opts, :port, 4000))
    |> Map.put(:remote_ip, Keyword.get(opts, :remote_ip, {127, 0, 0, 1}))
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
  end

  defp initialize_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "clientInfo" => %{"name" => "sympp-http-endpoint-test-client", "version" => "0.1.0"},
        "capabilities" => %{}
      }
    }
  end

  defp tools_list_request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list", "params" => %{}}
  defp resources_list_request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "resources/list", "params" => %{}}
  defp resources_read_request(id, uri), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "resources/read", "params" => %{"uri" => uri}}
  defp notification_request, do: %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}}

  defp tool_call_request(id, name, arguments) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}}
  end

  defp tool_call_notification(name, arguments) do
    %{"jsonrpc" => "2.0", "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}}
  end

  defp tool_names(payload) do
    payload
    |> get_in(["result", "tools"])
    |> Enum.map(& &1["name"])
    |> Enum.sort()
  end

  defp diagnostic_events(log) do
    log
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, ~s("event":"sympp_failed_mcp_call")))
    |> Enum.map(fn line ->
      {json_start, 1} = :binary.match(line, "{")
      line |> binary_part(json_start, byte_size(line) - json_start) |> Jason.decode!()
    end)
  end

  defp stored_http_server do
    %{entries: entries} = :sys.get_state(HTTPStateStore)

    entries
    |> Map.values()
    |> Enum.map(fn {server, _touched_at} -> server end)
    |> List.first()
  end

  defp resource_uris(payload) do
    payload
    |> get_in(["result", "resources"])
    |> Enum.map(& &1["uri"])
    |> Enum.sort()
  end

  defp resource_payload(payload) do
    payload
    |> get_in(["result", "contents", Access.at(0), "text"])
    |> Jason.decode!()
  end

  defp local_assignment_claim_args(%WorkPackage{} = package, overrides) do
    %{
      "repo" => package.repo,
      "base_branch" => package.base_branch,
      "work_package_id" => package.id,
      "branch" => package.branch_pattern,
      "worktree_path" => package.worktree_path,
      "caller_id" => "codex-local-http-test",
      "claimed_by" => "local-worker-http"
    }
    |> Map.merge(overrides)
  end

  defp local_claim_worktree_path(work_package_id) do
    Path.expand(Path.join(System.tmp_dir!(), "sympp-http-local-claim-#{work_package_id}"))
  end

  defp local_architect_handoff_opts do
    [
      claimed_by: ArchitectHandoff.claimed_by(),
      database: Repo.database_path(),
      local_architect_claim?: true
    ]
  end

  defp active_claim_leases(work_package_id) do
    Repo.all(
      from(claim_lease in ClaimLease,
        where: claim_lease.work_package_id == ^work_package_id,
        where: claim_lease.status in ^ClaimLease.active_statuses(),
        order_by: [asc: claim_lease.inserted_at, asc: claim_lease.id]
      )
    )
  end

  defp reset_mcp_runtime_state do
    HTTPStateStore.reset!()
    reset_server_response_state()
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-HTTP-#{System.unique_integer([:positive])}",
      title: "HTTP MCP WorkRequest",
      repo: "nextide/symphony-plus-plus",
      base_branch: "main",
      work_type: "feature",
      human_description: "Prove HTTP MCP architect continuity.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false},
      desired_dispatch_shape: "single_package",
      status: "draft"
    }

    Enum.into(overrides, defaults)
  end

  defp json_rpc_error(id, code, message, reason) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message, "data" => %{"reason" => reason}}}
  end

  defp reset_server_response_state do
    handle_state_agent = Module.concat(Server, HandleState)

    case Process.whereis(handle_state_agent) do
      nil -> :ok
      _pid -> reset_handle_state_agent(handle_state_agent)
    end
  end

  defp reset_handle_state_agent(handle_state_agent) do
    Agent.update(handle_state_agent, fn _store -> %{} end)
  catch
    :exit, _reason -> :ok
  end

  defp claimed_session do
    Session.new(%Assignment{
      grant_id: "grant-http-claimed",
      work_package_id: "SYMPP-MCP-HTTP",
      phase_id: nil,
      display_key: "SYMPP-MCP-HTTP",
      grant_role: "worker",
      capabilities: ["read:assignment"],
      claimed_at: DateTime.utc_now(:microsecond),
      claimed_by: "codex-local"
    })
  end

  defp restore_sympp_repo_database(nil), do: Application.delete_env(:symphony_elixir, :sympp_repo_database)
  defp restore_sympp_repo_database(database), do: Application.put_env(:symphony_elixir, :sympp_repo_database, database)

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp remove_http_state_store_for_test do
    if application_supervises_http_state_store?() do
      _result = Supervisor.terminate_child(SymphonyElixir.Supervisor, HTTPStateStore)
      _result = Supervisor.delete_child(SymphonyElixir.Supervisor, HTTPStateStore)
      :application_supervisor
    else
      stop_http_state_store()
      :standalone
    end
  end

  defp restore_http_state_store_for_test(:application_supervisor) do
    stop_http_state_store()

    case Supervisor.start_child(SymphonyElixir.Supervisor, HTTPStateStore) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp restore_http_state_store_for_test(:standalone), do: stop_http_state_store()

  defp application_supervises_http_state_store? do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        Enum.any?(Supervisor.which_children(SymphonyElixir.Supervisor), fn
          {HTTPStateStore, _pid, _type, _modules} -> true
          _child -> false
        end)

      nil ->
        false
    end
  end

  defp supervised_http_state_store_pid do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        Enum.find_value(Supervisor.which_children(SymphonyElixir.Supervisor), fn
          {HTTPStateStore, child_pid, _type, _modules} when is_pid(child_pid) -> child_pid
          _child -> nil
        end)

      nil ->
        nil
    end
  end

  defp stop_http_state_store do
    case Process.whereis(HTTPStateStore) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _reason -> :ok
  end

  defp with_endpoint_repo(repo, fun) do
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])

    Application.put_env(:symphony_elixir, Endpoint, Keyword.put(endpoint_config, :sympp_repo, repo))

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
    end
  end

  defp solo_workspace_path(name) do
    path = Path.join(System.tmp_dir!(), "sympp-mcp-http-solo-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
