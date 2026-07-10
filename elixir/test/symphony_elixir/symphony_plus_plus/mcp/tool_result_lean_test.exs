defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolResultLeanTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Server, ToolResult}

  test "canonical agent result keeps structuredContent once and emits only a compact summary" do
    payload = %{
      "text" => String.duplicate("Package context line. ", 40),
      "uri" => "sympp://work-packages/wp_example/context.md"
    }

    original = ToolResult.read_tool_result(payload)
    lean = ToolResult.canonical_agent_result(original)
    text = get_in(lean, ["content", Access.at(0), "text"])

    assert lean["structuredContent"] == original["structuredContent"]
    assert text =~ "uri:"
    assert text =~ "sympp://work-packages/wp_example/context.md"
    refute text =~ "Package context line"
    assert byte_size(Jason.encode!(lean)) < byte_size(Jason.encode!(original)) * 2 / 3
  end

  test "canonical summaries retain useful progress diagnostics" do
    result =
      ToolResult.tool_result(%{
        "progress_event" => %{
          "id" => "progress_1",
          "status" => "in_progress",
          "summary" => "Implemented lean tool surfaces",
          "idempotency_key" => "progress:lean"
        }
      })
      |> ToolResult.canonical_agent_result()

    text = get_in(result, ["content", Access.at(0), "text"])
    assert text =~ "result: progress_event"
    assert text =~ "status: in_progress"
    assert text =~ "summary: Implemented lean tool surfaces"
    assert result["structuredContent"]["progress_event"]["idempotency_key"] == "progress:lean"
  end

  test "HTTP full and explicit profiles both emit canonical results" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => "health",
      "method" => "tools/call",
      "params" => %{"name" => "sympp.health", "arguments" => %{}}
    }

    shared_config = [source_revision: nil, health_ledger_mode: :configured_identity]
    lean_config = Config.default([surface_profile: :worker] ++ shared_config)
    full_config = Config.default([mode: :http, surface_profile: :full] ++ shared_config)
    lean_server = Server.new(lean_config, initialized: true)

    full_server = Server.new(full_config, initialized: true)

    lean_text = lean_server |> then(&Server.handle(request, &1)) |> get_in(["result", "content", Access.at(0), "text"])
    full_text = full_server |> then(&Server.handle(request, &1)) |> get_in(["result", "content", Access.at(0), "text"])

    assert lean_text =~ "ledger:"
    assert lean_text =~ "status:"
    assert full_text =~ "ledger:"
    assert full_text =~ "status:"
    refute lean_text =~ "mcp_contract:"
    refute full_text =~ "mcp_contract:"
  end
end
