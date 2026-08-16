defmodule SymphonyElixir.SymphonyPlusPlus.MCPHTTPTransportMinimalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Config,
    FailedCall,
    HTTPStateStore,
    HTTPTransport,
    LedgerNamespace,
    Server,
    Session,
    SessionBinding
  }

  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository, as: SoloSessionRepository
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    if Process.whereis(HTTPStateStore) == nil, do: start_supervised!(HTTPStateStore)
    assert :ok = WorkPackageRepository.migrate(Repo)
    assert :ok = SoloSessionRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, config: Config.default(mode: :http, repo: Repo)}
  end

  setup %{config: config} do
    reset_server_response_state()
    HTTPStateStore.reset!()

    config.repo.delete_all(SoloSessionEntry)
    config.repo.delete_all(SoloSession)
    config.repo.delete_all(OperatorSettings)
    config.repo.delete_all(AccessGrant)
    config.repo.delete_all(WorkPackage)
    FailedCall.reset()

    :ok
  end

  test "initialize returns a valid MCP response and generated state key", %{config: config} do
    assert {:ok, result} = HTTPTransport.handle(config, initialize_request("init"), client_key: "client-a")

    assert result.status == :ok
    assert is_binary(result.state_key)
    assert result.response["jsonrpc"] == "2.0"
    assert result.response["id"] == "init"
    assert get_in(result.response, ["result", "protocolVersion"]) == "2025-03-26"
    assert get_in(result.response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert %Server{initialized: true, session: nil} = HTTPStateStore.get(config, "client-a", result.state_key)
  end

  test "initialize only marks state trusted when the internal daemon config opts in", %{config: config} do
    assert {:ok, ordinary} = HTTPTransport.handle(config, initialize_request("ordinary-init"), client_key: "ordinary-client")
    assert %Server{local_daemon_trusted: false} = HTTPStateStore.get(config, "ordinary-client", ordinary.state_key)

    trusted_config = Config.default(mode: :http, repo: Repo, local_daemon_trusted: true)

    assert {:ok, trusted} = HTTPTransport.handle(trusted_config, initialize_request("trusted-init"), client_key: "trusted-client")
    assert %Server{local_daemon_trusted: true} = HTTPStateStore.get(trusted_config, "trusted-client", trusted.state_key)
  end

  test "tools/list after initialize exposes only callable unbound tools", %{config: config} do
    {:ok, init} = HTTPTransport.handle(config, initialize_request("init"), client_key: "client-a")

    assert {:ok, tools} =
             HTTPTransport.handle(config, tools_list_request("tools"), client_key: "client-a", state_key: init.state_key)

    assert tools.state_key == init.state_key

    names = tool_names(tools.response)
    assert length(names) == length(Enum.uniq(names))

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
      assert tool in names
    end
  end

  test "trusted local HTTP advertises callable bootstrap and recovery tools before claim", %{config: config} do
    trusted_config = %{config | local_daemon_trusted: true}
    package_id = "SYMPP-HTTP-TRUSTED-LOCAL-CLAIM"

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               trusted_config.repo,
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

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(trusted_config.repo, work_package.id)

    {:ok, init} = HTTPTransport.handle(trusted_config, initialize_request("trusted-init"), client_key: "trusted-client")

    assert {:ok, tools} =
             HTTPTransport.handle(trusted_config, tools_list_request("trusted-tools"), client_key: "trusted-client", state_key: init.state_key)

    names = tool_names(tools.response)
    assert length(names) == length(Enum.uniq(names))

    for tool <- [
          "claim_local_assignment",
          "claim_local_architect_assignment",
          "create_work_request",
          "get_current_assignment",
          "release_current_assignment",
          "sympp.health"
        ] do
      assert tool in names
    end

    assert {:ok, preclaim_progress} =
             HTTPTransport.handle(
               trusted_config,
               tool_call_request("preclaim-progress", "append_progress", %{
                 "summary" => "Should not write",
                 "idempotency_key" => "preclaim-progress"
               }),
               client_key: "trusted-client",
               state_key: init.state_key
             )

    assert preclaim_progress.status == :error
    assert get_in(preclaim_progress.response, ["error", "data", "resource"]) == "append_progress"
    assert get_in(preclaim_progress.response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(preclaim_progress.response, ["error", "data", "action"]) == "claim_local_assignment"
    assert {:ok, []} = PlanningRepository.list_progress_events(trusted_config.repo, work_package.id)

    assert {:ok, preclaim_work_request_read} =
             HTTPTransport.handle(
               trusted_config,
               tool_call_request("preclaim-work-request-read", "read_work_request", %{"work_request_id" => "WR-PRECLAIM"}),
               client_key: "trusted-client",
               state_key: init.state_key
             )

    assert preclaim_work_request_read.status == :error
    assert get_in(preclaim_work_request_read.response, ["error", "data", "tool"]) == "read_work_request"
    assert get_in(preclaim_work_request_read.response, ["error", "data", "reason"]) == "not_found"

    assert {:ok, claim} =
             HTTPTransport.handle(
               trusted_config,
               tool_call_request("local-claim", "claim_local_assignment", local_assignment_claim_args(work_package)),
               client_key: "trusted-client",
               state_key: init.state_key
             )

    assert get_in(claim.response, ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id
    refute inspect(claim.response) =~ minted.work_key.secret

    assert {:ok, claimed_tools} =
             HTTPTransport.handle(trusted_config, tools_list_request("trusted-worker-tools"), client_key: "trusted-client", state_key: init.state_key)

    claimed_names = tool_names(claimed_tools.response)
    assert "get_current_assignment" in claimed_names
    assert "append_progress" in claimed_names
    assert "claim_local_assignment" in claimed_names
    refute "claim_local_architect_assignment" in claimed_names
    refute "claim_private_handoff" in claimed_names

    assert {:ok, assignment} =
             HTTPTransport.handle(trusted_config, get_current_assignment_request(), client_key: "trusted-client", state_key: init.state_key)

    assert get_in(assignment.response, ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id

    assert {:ok, progress} =
             HTTPTransport.handle(
               trusted_config,
               tool_call_request("postclaim-progress", "append_progress", %{
                 "summary" => "Post-claim progress",
                 "idempotency_key" => "postclaim-progress"
               }),
               client_key: "trusted-client",
               state_key: init.state_key
             )

    assert get_in(progress.response, ["result", "structuredContent", "progress_event", "summary"]) == "Post-claim progress"
  end

  test "batched local claim persists rehydration metadata", %{config: config} do
    trusted_config = %{config | local_daemon_trusted: true}
    package_id = "SYMPP-HTTP-BATCH-LOCAL"

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               trusted_config.repo,
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

    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(trusted_config.repo, work_package.id)
    {:ok, init} = HTTPTransport.handle(trusted_config, initialize_request("batch-local-init"), client_key: "batch-local-client")

    assert {:ok, batch} =
             HTTPTransport.handle(
               trusted_config,
               [
                 tool_call_request("batch-local-claim", "claim_local_assignment", local_assignment_claim_args(work_package)),
                 tools_list_request("batch-local-tools")
               ],
               client_key: "batch-local-client",
               state_key: init.state_key
             )

    assert batch.state_key == init.state_key
    assert is_list(batch.response)

    assert Enum.any?(batch.response, fn response ->
             get_in(response, ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id
           end)

    HTTPStateStore.reset!()
    reset_server_response_state()

    assert {:ok, assignment} =
             HTTPTransport.handle(
               trusted_config,
               get_current_assignment_request(),
               client_key: "batch-local-client",
               state_key: init.state_key
             )

    assert get_in(assignment.response, ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id
  end

  test "batched failed local-claim notification does not shadow later local claim recovery", %{config: config} do
    trusted_config = %{config | local_daemon_trusted: true}
    package_id = "SYMPP-HTTP-BATCH-SHADOW"
    client_key = "batch-shadow-client"

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               trusted_config.repo,
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

    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(trusted_config.repo, work_package.id)
    {:ok, init} = HTTPTransport.handle(trusted_config, initialize_request("batch-shadow-init"), client_key: client_key)

    failed_local_notification =
      tool_call_request("failed-local-shadow", "claim_local_assignment", %{"work_package_id" => "missing-package"})
      |> Map.delete("id")

    assert {:ok, batch} =
             HTTPTransport.handle(
               trusted_config,
               [
                 failed_local_notification,
                 tool_call_request("batch-shadow-local-claim", "claim_local_assignment", local_assignment_claim_args(work_package))
               ],
               client_key: client_key,
               state_key: init.state_key
             )

    assert Enum.any?(batch.response, fn response ->
             get_in(response, ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id
           end)

    binding_id = SessionBinding.binding_id(client_key, init.state_key)
    assert Repo.get!(SessionBinding, binding_id).recoverable

    HTTPStateStore.reset!()
    reset_server_response_state()

    assert {:ok, assignment} =
             HTTPTransport.handle(
               trusted_config,
               get_current_assignment_request(),
               client_key: client_key,
               state_key: init.state_key
             )

    assert get_in(assignment.response, ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id
  end

  test "sympp.health works after initialize", %{config: config} do
    {:ok, init} = HTTPTransport.handle(config, initialize_request("init"), client_key: "client-a")

    assert {:ok, health} =
             HTTPTransport.handle(config, health_request("health"), client_key: "client-a", state_key: init.state_key)

    assert get_in(health.response, ["result", "structuredContent", "status"]) == "ok"
    assert get_in(health.response, ["result", "structuredContent", "mode"]) == "http"
    assert get_in(health.response, ["result", "structuredContent", "ledger", "reachable"]) == true
    assert get_in(health.response, ["result", "structuredContent", "source", "mcp_contract"]) == Server.mcp_contract_identity()
  end

  test "live repo policy stays in transport for state-local and repo-backed followups", %{config: config} do
    {:ok, init} = HTTPTransport.handle(config, initialize_request("init"), client_key: "client-a")
    parent = self()
    ref = make_ref()

    live_handle = fn _payload, _client_key, _state_key ->
      send(parent, {:live_handle_called, ref})
      {:error, :repo_unavailable}
    end

    assert {:ok, health} =
             HTTPTransport.handle(config, health_request("health"),
               client_key: "client-a",
               state_key: init.state_key,
               live_handle: live_handle
             )

    assert get_in(health.response, ["result", "structuredContent", "status"]) == "ok"
    refute_receive {:live_handle_called, ^ref}

    resources = resources_list_request("resources")

    assert {:error, :ledger_unavailable, ^resources} =
             HTTPTransport.handle(config, resources,
               client_key: "client-a",
               state_key: init.state_key,
               live_handle: live_handle
             )

    assert_receive {:live_handle_called, ^ref}
  end

  test "a second client cannot reuse initialized state from a state key", %{config: config} do
    {:ok, init} = HTTPTransport.handle(config, initialize_request("init"), client_key: "client-a")

    assert {:ok, foreign_tools} =
             HTTPTransport.handle(config, tools_list_request("foreign-tools"), client_key: "client-b", state_key: init.state_key)

    assert foreign_tools.status == :error
    assert foreign_tools.state_key == nil
    assert get_in(foreign_tools.response, ["error", "data", "reason"]) == "unknown_state_key"
    assert HTTPStateStore.get(config, "client-b", init.state_key) == nil
    assert %Server{initialized: true} = HTTPStateStore.get(config, "client-a", init.state_key)
  end

  test "same client follow-up without state key does not use a current alias", %{config: config} do
    {:ok, init} = HTTPTransport.handle(config, initialize_request("init"), client_key: "client-a")

    assert {:ok, headerless_tools} = HTTPTransport.handle(config, tools_list_request("headerless-tools"), client_key: "client-a")

    assert headerless_tools.status == :error
    assert headerless_tools.state_key == nil
    assert get_in(headerless_tools.response, ["error", "data", "reason"]) == "server_not_initialized"
    assert %Server{initialized: true} = HTTPStateStore.get(config, "client-a", init.state_key)
  end

  test "unknown supplied state keys are controlled errors and are not persisted", %{config: config} do
    assert {:ok, unknown_initialize} =
             HTTPTransport.handle(config, initialize_request("caller-state-init"), client_key: "client-a", state_key: "caller-chosen")

    assert unknown_initialize.status == :error
    assert unknown_initialize.state_key == nil
    assert get_in(unknown_initialize.response, ["error", "data", "reason"]) == "unknown_state_key"
    assert HTTPStateStore.get(config, "client-a", "caller-chosen") == nil

    assert {:ok, unknown_followup} =
             HTTPTransport.handle(config, tools_list_request("unknown-tools"), client_key: "client-a", state_key: "missing-state")

    assert unknown_followup.status == :error
    assert get_in(unknown_followup.response, ["error", "data", "reason"]) == "unknown_state_key"
    assert HTTPStateStore.get(config, "client-a", "missing-state") == nil
  end

  test "notifications return no response without corrupting initialized state", %{config: config} do
    {:ok, init} = HTTPTransport.handle(config, initialize_request("init"), client_key: "client-a")

    assert {:ok, notification} =
             HTTPTransport.handle(config, notification_request(), client_key: "client-a", state_key: init.state_key)

    assert notification.response == nil
    assert notification.status == :no_response
    assert notification.state_key == init.state_key

    assert {:ok, tools} =
             HTTPTransport.handle(config, tools_list_request("tools-after-notification"), client_key: "client-a", state_key: init.state_key)

    assert "sympp.health" in tool_names(tools.response)
  end

  test "batch transport observes each failed tool item once without retaining values", %{config: config} do
    assert {:ok, _settings} = OperatorSettingsRepository.update(config.repo, %{"capture_failed_mcp_calls" => true})
    {:ok, init} = HTTPTransport.handle(config, initialize_request("batch-failure-init"), client_key: "batch-failure-client")

    request = tool_call_request("private-request-id", "sympp.health", %{"bearer" => "request-secret"})
    notification = tool_call_request(nil, "sympp.health", %{"bearer" => "notification-secret"}) |> Map.delete("id")

    {result, log} =
      with_log(fn ->
        HTTPTransport.handle(config, [request, notification],
          client_key: "batch-failure-client",
          state_key: init.state_key
        )
      end)

    assert {:ok, %{response: [%{"error" => %{"data" => %{"diagnostic_id" => diagnostic_id}}}]}} = result
    assert diagnostic_id =~ ~r/^mcpdiag_[0-9a-f]{16}$/
    assert events = diagnostic_events(log)
    assert length(events) == 2
    assert Enum.all?(events, &(&1["failure_layer"] == "tool"))
    assert events |> Enum.map(& &1["diagnostic_id"]) |> Enum.uniq() |> length() == 2
    refute log =~ "private-request-id"
    refute log =~ "request-secret"
    refute log =~ "notification-secret"
  end

  test "invalid JSON-RPC shapes return controlled errors without creating HTTP state", %{config: config} do
    assert {:ok, invalid_body} = HTTPTransport.handle(config, "not-a-json-rpc-object", client_key: "client-a")

    assert invalid_body.status == :error
    assert invalid_body.state_key == nil
    assert get_in(invalid_body.response, ["error", "code"]) == -32_600
    assert get_in(invalid_body.response, ["error", "data", "reason"]) == "request_must_be_object"
    assert :sys.get_state(HTTPStateStore).entries == %{}

    assert {:ok, invalid_initialize} =
             HTTPTransport.handle(
               config,
               %{"jsonrpc" => "2.0", "id" => "bad-init", "method" => "initialize", "params" => %{"protocolVersion" => "2025-03-26"}},
               client_key: "client-a"
             )

    assert invalid_initialize.status == :error
    assert invalid_initialize.state_key == nil
    assert get_in(invalid_initialize.response, ["error", "data", "reason"]) == "invalid_initialize_params"
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "batched initialize requests are rejected without creating HTTP state", %{config: config} do
    assert {:ok, batch_initialize} =
             HTTPTransport.handle(config, [initialize_request("batch-init")], client_key: "client-a")

    assert batch_initialize.status == :error
    assert batch_initialize.state_key == nil
    assert get_in(batch_initialize.response, ["error", "data", "reason"]) == "initialize_must_be_standalone"
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "raced missing existing state is not recreated as a placeholder", %{config: config} do
    {:ok, init} = HTTPTransport.handle(config, initialize_request("init"), client_key: "client-a")
    parent = self()

    holder =
      Task.async(fn ->
        HTTPStateStore.update_with_status(
          config,
          "client-a",
          init.state_key,
          default_server_fun(config, init.state_key),
          fn server ->
            send(parent, {:holding_update, self()})

            receive do
              :release_update -> :ok
            after
              1_000 -> raise "timed out waiting to release update"
            end

            {:held, server}
          end
        )
      end)

    assert_receive {:holding_update, holder_pid}

    raced_transport =
      Task.async(fn ->
        HTTPTransport.handle(config, tools_list_request("raced-tools"), client_key: "client-a", state_key: init.state_key)
      end)

    wait_for_queued_lock(config, "client-a", init.state_key, 1)

    delete = Task.async(fn -> HTTPStateStore.delete(config, "client-a", init.state_key) end)

    wait_for_queued_lock(config, "client-a", init.state_key, 2)
    reverse_queued_lock(config, "client-a", init.state_key)
    send(holder_pid, :release_update)

    assert Task.await(holder) == {:held, :stored}
    assert Task.await(delete) == :ok
    assert {:ok, lost} = Task.await(raced_transport)
    assert lost.status == :error
    assert lost.state_key == nil
    assert get_in(lost.response, ["error", "data", "reason"]) == "state_update_lost"
    assert HTTPStateStore.get(config, "client-a", init.state_key) == nil
  end

  test "claim_local_assignment persists bound HTTP continuity for later requests", %{config: config} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               config.repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-HTTP-MINIMAL-CLAIM",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "main",
                 branch_pattern: "agent/SYMPP-HTTP-MINIMAL-CLAIM/worker",
                 worktree_path: local_claim_worktree_path("SYMPP-HTTP-MINIMAL-CLAIM"),
                 status: "ready_for_worker"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(config.repo, work_package.id)
    local_config = %{config | mode: :http, local_daemon_trusted: true}
    {:ok, init} = HTTPTransport.handle(local_config, initialize_request("init"), client_key: "client-a")

    assert {:ok, claim} =
             HTTPTransport.handle(
               local_config,
               tool_call_request("claim", "claim_local_assignment", local_assignment_claim_args(work_package, %{"claimed_by" => "worker-a"})),
               client_key: "client-a",
               state_key: init.state_key
             )

    assert get_in(claim.response, ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id

    assert %Server{initialized: true, session: %Session{} = session} = stored_server = HTTPStateStore.get(local_config, "client-a", init.state_key)
    assert session.assignment.work_package_id == work_package.id
    assert session.assignment.grant_id == minted.grant.id
    assert session.proof_hash == minted.grant.secret_hash
    refute inspect(stored_server) =~ minted.work_key.secret

    assert {:ok, tools} =
             HTTPTransport.handle(local_config, tools_list_request("tools-after-claim"), client_key: "client-a", state_key: init.state_key)

    assert "claim_local_assignment" in tool_names(tools.response)
    refute "claim_local_architect_assignment" in tool_names(tools.response)
    assert "get_current_assignment" in tool_names(tools.response)

    assert {:ok, assignment} =
             HTTPTransport.handle(local_config, get_current_assignment_request(), client_key: "client-a", state_key: init.state_key)

    assert get_in(assignment.response, ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id
  end

  defp initialize_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "clientInfo" => %{"name" => "sympp-http-transport-minimal-test-client", "version" => "0.1.0"},
        "capabilities" => %{}
      }
    }
  end

  defp tools_list_request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list", "params" => %{}}
  defp resources_list_request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "resources/list", "params" => %{}}

  defp health_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "sympp.health", "arguments" => %{}}
    }
  end

  defp notification_request, do: %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}}

  defp get_current_assignment_request do
    %{
      "jsonrpc" => "2.0",
      "id" => "assignment",
      "method" => "tools/call",
      "params" => %{"name" => "get_current_assignment", "arguments" => %{}}
    }
  end

  defp tool_call_request(id, name, arguments) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}}
  end

  defp local_assignment_claim_args(%WorkPackage{} = package, overrides \\ %{}) do
    %{
      "repo" => package.repo,
      "base_branch" => package.base_branch,
      "work_package_id" => package.id,
      "branch" => package.branch_pattern,
      "worktree_path" => package.worktree_path,
      "caller_id" => "codex-local-test",
      "claimed_by" => "local-worker-1"
    }
    |> Map.merge(overrides)
  end

  defp local_claim_worktree_path(work_package_id) do
    Path.expand(Path.join(System.tmp_dir!(), "sympp-http-local-claim-#{work_package_id}"))
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

  defp default_server_fun(config, state_key) do
    fn -> Server.new(config, state_key: state_key) end
  end

  defp wait_for_queued_lock(config, client_key, state_key, expected_len, attempts \\ 50)

  defp wait_for_queued_lock(_config, _client_key, _state_key, expected_len, 0) do
    flunk("timed out waiting for #{expected_len} queued HTTP state lock waiters")
  end

  defp wait_for_queued_lock(%Config{} = config, client_key, state_key, expected_len, attempts) do
    store = :sys.get_state(HTTPStateStore)
    key = store_key(config, client_key, state_key)

    queued? =
      case Map.get(store.locks, key) do
        %{queue: queue} -> :queue.len(queue) >= expected_len
        _missing -> false
      end

    if queued? do
      :ok
    else
      Process.sleep(10)
      wait_for_queued_lock(config, client_key, state_key, expected_len, attempts - 1)
    end
  end

  defp reverse_queued_lock(%Config{} = config, client_key, state_key) do
    key = store_key(config, client_key, state_key)

    :sys.replace_state(HTTPStateStore, fn state ->
      locks =
        Map.update!(state.locks, key, fn lock ->
          queue =
            lock.queue
            |> :queue.to_list()
            |> Enum.reverse()
            |> :queue.from_list()

          %{lock | queue: queue}
        end)

      %{state | locks: locks}
    end)

    :ok
  end

  defp store_key(%Config{} = config, client_key, state_key) do
    {config.mode, LedgerNamespace.key(config), client_key, state_key}
  end
end
