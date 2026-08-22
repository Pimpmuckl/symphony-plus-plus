defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolSurfaceLeanTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Server}

  test "handle state outlives the caller that first creates it" do
    agent = Module.concat(Server, HandleState)
    if pid = Process.whereis(agent), do: Agent.stop(pid)
    parent = self()

    {caller, caller_ref} =
      spawn_monitor(fn ->
        _tools = listed_tools(:worker)
        send(parent, {:handle_state_started, self()})

        receive do
          :stop -> exit(:shutdown)
        end
      end)

    assert_receive {:handle_state_started, ^caller}
    agent_pid = Process.whereis(agent)
    agent_ref = Process.monitor(agent_pid)
    send(caller, :stop)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :shutdown}
    refute_receive {:DOWN, ^agent_ref, :process, ^agent_pid, _reason}, 50
    assert Process.alive?(agent_pid)
  end

  test "profile parsing rejects unknown startup surfaces" do
    assert {:ok, %Config{surface_profile: :worker}} = Config.parse(["--surface-profile", "worker"])
    assert {:ok, %Config{surface_profile: :full}} = Config.parse(["--surface-profile", "default"])
    assert {:error, usage} = Config.parse(["--surface-profile", "bootstrap"])
    assert usage == Config.usage()
    assert_raise ArgumentError, fn -> Config.default(surface_profile: "bootstrap", source_revision: nil) end
  end

  defp listed_tools(profile) do
    server = Server.new(Config.default(surface_profile: profile, source_revision: nil), initialized: true)
    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}}, server)
    get_in(response, ["result", "tools"])
  end
end
