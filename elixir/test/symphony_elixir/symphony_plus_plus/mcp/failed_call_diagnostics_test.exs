Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.FailedCallDiagnosticsTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{FailedCall, HTTPTransport}
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings

  defmodule DiagnosticFailureRepo do
    alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def get(Settings, id), do: Repo.get(Settings, id)

    def get(_schema, _id) do
      case Process.get({__MODULE__, :failure}) do
        :exit -> exit(:repository_secret_exit)
        _raise -> raise "repository secret exception C:/private/provider-body"
      end
    end
  end

  defmodule TelemetryFailureRepo do
    alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings

    def get(Settings, _id) do
      case Process.get({__MODULE__, :failure}) do
        :exit -> exit(:telemetry_secret_exit)
        _raise -> raise "telemetry secret C:/private/provider-body"
      end
    end
  end

  setup %{repo: repo} do
    repo.delete_all(OperatorSettings)
    FailedCall.reset()
    :ok
  end

  test "failed tool diagnostics default off, redact values, and follow the setting immediately", %{repo: repo} do
    secret = "Bearer argument-value-that-must-not-be-logged"
    request = failed_health_request(secret)

    {disabled_response, disabled_log} = capture_response(fn -> MCPHarness.request(request, repo: repo) end)
    refute Map.has_key?(disabled_response["error"]["data"], "diagnostic_id")
    refute disabled_log =~ "sympp_failed_mcp_call"

    assert {:ok, enabled_settings} = OperatorSettingsRepository.update(repo, %{"capture_failed_mcp_calls" => true})
    changes_before = total_changes(repo)

    {enabled_response, enabled_log} = capture_response(fn -> MCPHarness.request(request, repo: repo) end)
    diagnostic_id = enabled_response["error"]["data"]["diagnostic_id"]

    assert diagnostic_id =~ ~r/^mcpdiag_[0-9a-f]{16}$/
    assert enabled_log =~ ~s("event":"sympp_failed_mcp_call")
    assert enabled_log =~ ~s("diagnostic_id":"#{diagnostic_id}")
    assert enabled_log =~ ~s("tool_name":"sympp.health")
    assert enabled_log =~ ~s("argument_keys":["nested"])
    assert enabled_log =~ ~s("unsafe_argument_name_count":1)
    assert enabled_log =~ ~s("argument_keys_truncated":0)
    assert enabled_log =~ ~s("error_classification":"invalid_params")
    assert enabled_log =~ ~s("failure_layer":"tool")
    assert enabled_log =~ ~s("failure_reason":"invalid_tool_arguments")
    assert enabled_log =~ ~s("mcp_contract_fingerprint":)
    assert enabled_log =~ ~s("source_revision":)
    assert enabled_log =~ ~s("next_action":"fix_tool_arguments")
    assert enabled_response["error"]["data"]["recovery"] == %{"next_action" => "fix_tool_arguments"}
    refute enabled_log =~ secret
    refute enabled_log =~ "bearer"

    secret_tool_name = "tool-#{secret}"
    unknown_tool_request = put_in(request, ["params", "name"], secret_tool_name)

    {unknown_tool_response, unknown_tool_log} =
      capture_response(fn -> MCPHarness.request(unknown_tool_request, repo: repo) end)

    assert is_binary(unknown_tool_response["error"]["data"]["diagnostic_id"])
    assert unknown_tool_log =~ ~s("tool_name":"unknown")
    refute unknown_tool_log =~ secret_tool_name
    assert total_changes(repo) == changes_before

    assert {:ok, disabled_settings} = OperatorSettingsRepository.update(repo, %{"capture_failed_mcp_calls" => false})
    assert DateTime.compare(disabled_settings.updated_at, enabled_settings.updated_at) in [:eq, :gt]

    {toggled_response, toggled_log} = capture_response(fn -> MCPHarness.request(request, repo: repo) end)
    refute Map.has_key?(toggled_response["error"]["data"], "diagnostic_id")
    refute toggled_log =~ "sympp_failed_mcp_call"
  end

  test "capture leaves protocol errors unchanged and observes failed tool notifications", %{repo: repo} do
    assert {:ok, _settings} = OperatorSettingsRepository.update(repo, %{"capture_failed_mcp_calls" => true})

    protocol_request = %{
      "jsonrpc" => "2.0",
      "id" => "protocol-error",
      "method" => "unknown/method",
      "params" => %{"name" => "not-a-dispatched-tool"}
    }

    {protocol_response, protocol_log} = capture_response(fn -> MCPHarness.request(protocol_request, repo: repo) end)
    assert protocol_response["error"] == %{"code" => -32_601, "message" => "Method not found", "data" => %{}}
    refute protocol_log =~ "sympp_failed_mcp_call"

    notification = failed_health_request("notification-secret") |> Map.delete("id")
    {notification_response, notification_log} = capture_response(fn -> MCPHarness.request(notification, repo: repo) end)
    assert notification_response == nil
    assert [notification_event] = diagnostic_events(notification_log)
    assert notification_event["failure_reason"] == "invalid_tool_arguments"
    assert notification_event["tool_name"] == "sympp.health"
    refute diagnostic_event_line(notification_log) =~ "notification-secret"

    unauthorized_request = %{
      "jsonrpc" => "2.0",
      "id" => "unauthorized",
      "method" => "tools/call",
      "params" => %{"name" => "read_context", "arguments" => %{}}
    }

    {unauthorized_response, unauthorized_log} =
      capture_response(fn -> MCPHarness.request(unauthorized_request, repo: repo) end)

    assert unauthorized_response["error"]["code"] == -32_001
    assert unauthorized_log =~ ~s("error_classification":"unauthorized")
    assert unauthorized_log =~ ~s("tool_name":"read_context")

    missing_session_id = "secret-session-value"

    not_found_request = %{
      "jsonrpc" => "2.0",
      "id" => "not-found",
      "method" => "tools/call",
      "params" => %{"name" => "solo_show", "arguments" => %{"session_id" => missing_session_id}}
    }

    {not_found_response, not_found_log} = capture_response(fn -> MCPHarness.request(not_found_request, repo: repo) end)
    assert not_found_response["error"]["code"] == -32_004
    assert not_found_log =~ ~s("error_classification":"not_found")
    assert not_found_log =~ ~s("tool_name":"solo_show")
    assert not_found_log =~ ~s("argument_keys":["session_id"])
    refute diagnostic_event_line(not_found_log) =~ missing_session_id
  end

  test "HTTP worker diagnostics recognize restricted catalog tools without request details", %{repo: repo} do
    assert {:ok, _settings} = OperatorSettingsRepository.update(repo, %{"capture_failed_mcp_calls" => true})
    package = create_local_claim_package!(repo, "SYMPP-DIAGNOSTIC-WORKER")
    assert {:ok, _grant} = AccessGrantService.mint_worker_grant(repo, package.id)

    config = local_mcp_config(repo)
    client_key = "failed-call-diagnostics"

    assert {:ok, initialized} =
             HTTPTransport.handle(
               config,
               %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
               client_key: client_key
             )

    assert {:ok, claimed} =
             HTTPTransport.handle(
               config,
               %{
                 "jsonrpc" => "2.0",
                 "id" => "claim",
                 "method" => "tools/call",
                 "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
               },
               client_key: client_key,
               state_key: initialized.state_key
             )

    assert get_in(claimed.response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id

    {solo_response, solo_log} =
      capture_response(fn ->
        assert {:ok, result} =
                 HTTPTransport.handle(config, tool_call("solo_show", %{"session_id" => "private-solo-session"}),
                   client_key: client_key,
                   state_key: initialized.state_key
                 )

        result.response
      end)

    recovery = solo_response["error"]["data"]["recovery"]
    assert recovery["tool"] == "release_current_assignment"
    assert recovery["next_action"] == "call_release_current_assignment_then_retry_solo_tool"
    assert is_binary(recovery["fallback"])
    assert [solo_event] = diagnostic_events(solo_log)
    assert solo_event["recovery"] == Map.take(recovery, ["fresh_mcp_session_required", "next_action", "tool"])
    refute diagnostic_event_line(solo_log) =~ "private-solo-session"
    refute Map.has_key?(solo_event["recovery"], "fallback")

    secret = "Bearer C:/private/branch/wp_identifier_secret"

    request = %{
      "jsonrpc" => "2.0",
      "id" => secret,
      "method" => "tools/call",
      "params" => %{
        "name" => "create_child_work_package",
        "arguments" => %{"package" => %{"goal" => secret, "path" => secret}}
      }
    }

    {response, log} =
      capture_response(fn ->
        assert {:ok, result} =
                 HTTPTransport.handle(config, request,
                   client_key: client_key,
                   state_key: initialized.state_key
                 )

        result.response
      end)

    assert response["error"]["code"] == -32_001
    assert response["error"]["data"]["reason"] == "architect_grant_required"
    assert log =~ ~s("tool_name":"create_child_work_package")
    assert log =~ ~s("failure_reason":"architect_grant_required")
    assert log =~ ~s("argument_keys":[])
    refute diagnostic_event_line(log) =~ secret
  end

  test "batch failures emit once per tool item including notifications", %{repo: repo} do
    assert {:ok, _settings} = OperatorSettingsRepository.update(repo, %{"capture_failed_mcp_calls" => true})

    failed_request = failed_health_request("batch-request-secret")
    failed_notification = failed_health_request("batch-notification-secret") |> Map.delete("id")

    {response, log} =
      capture_response(fn ->
        MCPHarness.request([failed_request, failed_notification, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}],
          repo: repo
        )
      end)

    assert [%{"error" => %{"data" => %{"diagnostic_id" => diagnostic_id}}}] = response
    assert diagnostic_id =~ ~r/^mcpdiag_[0-9a-f]{16}$/

    assert events = diagnostic_events(log)
    assert length(events) == 2
    assert events |> Enum.map(& &1["diagnostic_id"]) |> Enum.uniq() |> length() == 2
    assert Enum.all?(events, &(&1["tool_name"] == "sympp.health"))
    refute diagnostic_event_line(log) =~ "batch-request-secret"
    refute diagnostic_event_line(log) =~ "batch-notification-secret"
  end

  test "tool boundary observes exceptions and exits once without changing containment", %{repo: repo} do
    assert {:ok, _settings} = OperatorSettingsRepository.update(repo, %{"capture_failed_mcp_calls" => true})
    on_exit(fn -> Process.delete({DiagnosticFailureRepo, :failure}) end)

    config = %{
      local_mcp_config(DiagnosticFailureRepo)
      | database: "C:/trusted/ledger.db",
        source_revision: String.duplicate("a", 40)
    }

    server = Server.new(config, initialized: true, state_key: "failure-test")

    request =
      tool_call("list_comments", %{
        "target_kind" => "work_request",
        "target_id" => "private-session-value"
      })

    Process.put({DiagnosticFailureRepo, :failure}, :raise)

    exception_log =
      capture_log(fn ->
        assert_raise RuntimeError, "repository secret exception C:/private/provider-body", fn -> Server.handle(request, server) end
      end)

    assert [exception_event] = diagnostic_events(exception_log)
    assert exception_event["cause_kind"] == "exception"
    assert exception_event["failure_layer"] == "tool"
    assert exception_event["failure_reason"] == "unhandled_tool_failure"
    refute diagnostic_event_line(exception_log) =~ "private-session-value"
    refute diagnostic_event_line(exception_log) =~ "provider-body"

    Process.put({DiagnosticFailureRepo, :failure}, :exit)
    exit_log = capture_log(fn -> assert catch_exit(Server.handle(request, server)) == :repository_secret_exit end)

    assert [exit_event] = diagnostic_events(exit_log)
    assert exit_event["cause_kind"] == "exit"
    refute diagnostic_event_line(exit_log) =~ "repository_secret_exit"
  end

  test "telemetry and summary failures do not change protocol behavior" do
    on_exit(fn -> Process.delete({TelemetryFailureRepo, :failure}) end)
    config = Config.default(repo: TelemetryFailureRepo)
    server = Server.new(config, initialized: true)
    request = failed_health_request("telemetry-value")

    Process.put({TelemetryFailureRepo, :failure}, :raise)
    response = Server.handle(request, server)
    assert response["error"]["code"] == -32_602
    refute Map.has_key?(response["error"]["data"], "diagnostic_id")
    refute Map.has_key?(response["error"]["data"], "recovery")

    Process.put({TelemetryFailureRepo, :failure}, :exit)
    assert Server.handle(Map.delete(request, "id"), server) == nil

    store = Module.concat(FailedCall, Store)
    Agent.stop(Process.whereis(store))
    blocker = spawn(fn -> receive do: ({:"$gen_call", _from, _request} -> :ok) end)
    Process.register(blocker, store)
    on_exit(fn -> Process.exit(blocker, :kill) end)

    assert FailedCall.summary() == %{
             "durability" => "process_local",
             "groups" => [],
             "last_reset_at" => nil,
             "observation_started_at" => nil,
             "source_identities" => [],
             "status" => "unavailable",
             "total_failures" => 0
           }
  end

  test "trusted local summary exposes only process-local aggregate boundaries", %{repo: repo} do
    assert {:ok, _settings} = OperatorSettingsRepository.update(repo, %{"capture_failed_mcp_calls" => true})
    config = local_mcp_config(repo)
    client_key = "failed-call-summary"

    assert {:ok, initialized} = HTTPTransport.handle(config, initialize_request(), client_key: client_key)

    assert {:ok, failed} =
             Task.async(fn ->
               HTTPTransport.handle(config, failed_health_request("summary-secret"),
                 client_key: client_key,
                 state_key: initialized.state_key
               )
             end)
             |> Task.await()

    assert is_binary(failed.response["error"]["data"]["diagnostic_id"])

    assert {:ok, summary_response} =
             HTTPTransport.handle(config, tool_call("summarize_failed_mcp_calls", %{}),
               client_key: client_key,
               state_key: initialized.state_key
             )

    summary = get_in(summary_response.response, ["result", "structuredContent"])
    assert summary["status"] == "ok"
    assert summary["durability"] == "process_local"
    assert summary["total_failures"] == 1
    assert is_binary(summary["observation_started_at"])
    assert {:ok, observation_started_at, 0} = DateTime.from_iso8601(summary["observation_started_at"])
    assert {:ok, last_reset_at, 0} = DateTime.from_iso8601(summary["last_reset_at"])
    assert DateTime.compare(last_reset_at, observation_started_at) in [:eq, :gt]
    assert [%{"source_revision" => revision, "mcp_contract_fingerprint" => fingerprint}] = summary["source_identities"]
    assert revision =~ ~r/^[0-9a-f]{40}$/
    assert fingerprint =~ ~r/^[0-9a-f]{64}$/
    assert [group] = summary["groups"]
    assert group["count"] == 1
    assert group["first_observed_at"] == group["last_observed_at"]
    refute inspect(summary) =~ "summary-secret"

    :ok = FailedCall.reset()
    reset_summary = FailedCall.summary()
    assert reset_summary["total_failures"] == 0
    assert reset_summary["groups"] == []
    assert reset_summary["observation_started_at"] == summary["observation_started_at"]
    assert is_binary(reset_summary["last_reset_at"])
  end

  defp failed_health_request(secret) do
    %{
      "jsonrpc" => "2.0",
      "id" => "failed-health",
      "method" => "tools/call",
      "params" => %{
        "name" => "sympp.health",
        "arguments" => %{"bearer" => secret, "nested" => %{"token" => secret}}
      }
    }
  end

  defp tool_call(name, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => "failed-call-test",
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    }
  end

  defp initialize_request do
    %{
      "jsonrpc" => "2.0",
      "id" => "failed-call-init",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "clientInfo" => %{"name" => "failed-call-test", "version" => "1"},
        "capabilities" => %{}
      }
    }
  end

  defp capture_response(fun) do
    parent = self()
    ref = make_ref()
    log = capture_log(fn -> send(parent, {ref, fun.()}) end)
    assert_receive {^ref, response}
    {response, log}
  end

  defp total_changes(repo), do: repo.query!("SELECT total_changes()").rows |> hd() |> hd()

  defp diagnostic_event_line(log) do
    Enum.find(String.split(log, "\n"), &String.contains?(&1, ~s("event":"sympp_failed_mcp_call")))
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
end
