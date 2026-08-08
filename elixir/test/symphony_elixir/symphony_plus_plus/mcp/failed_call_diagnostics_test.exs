Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.FailedCallDiagnosticsTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings

  setup %{repo: repo} do
    repo.delete_all(OperatorSettings)
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
    assert enabled_log =~ ~s("argument_keys":[])
    assert enabled_log =~ ~s("error_classification":"invalid_params")
    assert enabled_log =~ ~s("source":)
    refute enabled_log =~ secret
    refute enabled_log =~ "bearer"
    refute enabled_log =~ "nested"

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

  test "capture leaves protocol errors and tool notifications unchanged", %{repo: repo} do
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
    refute notification_log =~ "sympp_failed_mcp_call"

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
end
