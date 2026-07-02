Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageRefreshMcpOnlyTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @tag :ci_slow
  test "refresh script repairs stale default MCP artifacts during MCP-only refresh" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh-mcp-only")

    if powershell do
      stale_manifest_path = published_plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])
      stale_mcp_path = published_plugin_cache_path(temp_codex_home, ["local", ".mcp.json"])
      stale_hint_path = published_plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"])

      try do
        File.mkdir_p!(Path.dirname(stale_manifest_path))

        File.write!(
          stale_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "0.1.1", "mcpServers" => "./.mcp.json"})
        )

        File.write!(stale_mcp_path, Jason.encode!(%{"symphony_plus_plus" => %{"type" => "stdio", "command" => "pwsh", "args" => ["-NoProfile"], "cwd" => "."}}))
        File.write!(stale_hint_path, "C:/sympp/generated\n")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-CodexHome",
              temp_codex_home,
              "-PluginName",
              "symphony-plus-plus-mcp"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output
        assert output =~ "Repaired incompatible default Symphony++ plugin cache"

        repaired_manifest = stale_manifest_path |> File.read!() |> Jason.decode!()
        refute Map.has_key?(repaired_manifest, "mcpServers")
        refute File.exists?(stale_mcp_path)
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"], "symphony-plus-plus-mcp"))
        assert File.exists?(published_plugin_cache_path(temp_codex_home, [@plugin_version, ".mcp.json"], "symphony-plus-plus-mcp"))
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end
