defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolSurfaceLeanTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Server, ToolCatalog}

  @profiles ~w(worker architect coordinator solo)a
  @removed_tools ~w(request_child_replan split_work_package publish_phase_update)

  test "surface profile is selected before the first tools/list" do
    for profile <- @profiles do
      tools = listed_tools(profile)
      names = MapSet.new(tools, & &1["name"])

      assert length(tools) == MapSet.size(names)
      assert Enum.all?(tools, &(not Map.has_key?(&1, "title")))
      refute Enum.any?(@removed_tools, fn name -> MapSet.member?(names, name) end)

      case profile do
        :worker ->
          assert MapSet.equal?(names, MapSet.new(["sympp.health", "release_current_assignment", "claim_local_assignment" | ToolCatalog.worker_tools()]))

        :architect ->
          expected = ["sympp.health", "release_current_assignment", "claim_local_architect_assignment", "get_current_assignment" | ToolCatalog.architect_tools()]
          assert MapSet.equal?(names, MapSet.new(expected))

        profile when profile in [:coordinator, :solo] ->
          assert MapSet.equal?(names, MapSet.new(["sympp.health", "release_current_assignment" | ToolCatalog.solo_tools()]))
      end
    end
  end

  test "role profiles are complete without a tools/list refresh" do
    worker = tools_by_name(:worker)
    architect = tools_by_name(:architect)

    assert Map.has_key?(worker, "claim_local_assignment")
    assert Map.has_key?(worker, "read_context")
    assert Map.has_key?(worker, "mark_ready")
    refute Map.has_key?(worker["append_progress"]["inputSchema"]["properties"], "work_package_id")

    assert Map.has_key?(architect, "claim_local_architect_assignment")
    assert Map.has_key?(architect, "read_work_request")
    assert Map.has_key?(architect, "dispatch_slice")
    assert architect["dispatch_slice"]["inputSchema"]["required"] == ["planned_slice_id"]
    refute Enum.any?(@removed_tools, &Map.has_key?(architect, &1))
  end

  test "full and default expose every implemented tool" do
    config = Config.default(surface_profile: :full, source_revision: nil)
    full = ToolCatalog.startup_tool_specs(:full, config)
    expected_full = config |> ToolCatalog.unbound_tool_specs_for_config() |> ToolCatalog.lean_tool_specs()

    assert full == expected_full

    assert Enum.any?(full, &(&1["name"] == "claim_local_assignment"))
    assert Enum.any?(full, &(&1["name"] == "claim_local_architect_assignment"))
    assert Enum.any?(full, &(&1["name"] == "solo_attach"))
    assert Enum.all?(full, &(not Map.has_key?(&1, "title")))
    refute Enum.any?(full, &(&1["description"] == "Symphony++ worker tool #{&1["name"]}."))
    refute Enum.any?(@removed_tools, fn name -> Enum.any?(full, &(&1["name"] == name)) end)
    assert Config.default(surface_profile: "default", source_revision: nil).surface_profile == :full
  end

  test "profile parsing rejects unknown startup surfaces" do
    assert {:ok, %Config{surface_profile: :worker}} = Config.parse(["--surface-profile", "worker"])
    assert {:ok, %Config{surface_profile: :full}} = Config.parse(["--surface-profile", "default"])
    assert {:error, usage} = Config.parse(["--surface-profile", "bootstrap"])
    assert usage == Config.usage()
    assert_raise ArgumentError, fn -> Config.default(surface_profile: "bootstrap", source_revision: nil) end
  end

  test "role schemas are materially smaller than full discovery" do
    full_bytes =
      encoded_bytes(ToolCatalog.startup_tool_specs(:full, Config.default(surface_profile: :full, source_revision: nil)))

    for profile <- @profiles do
      assert encoded_bytes(listed_tools(profile)) < full_bytes
    end
  end

  defp listed_tools(profile) do
    server = Server.new(Config.default(surface_profile: profile, source_revision: nil), initialized: true)
    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}}, server)
    get_in(response, ["result", "tools"])
  end

  defp tools_by_name(profile), do: Map.new(listed_tools(profile), &{&1["name"], &1})
  defp encoded_bytes(tools), do: tools |> then(&%{"tools" => &1}) |> Jason.encode!() |> byte_size()
end
