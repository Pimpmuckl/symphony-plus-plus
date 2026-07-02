Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageRefreshMarketplaceTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @tag :ci_slow
  test "refresh script rejects unresolved marketplace source paths" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")
    marketplace_path = unique_temp_path("sympp-marketplace") <> ".json"

    if powershell do
      marketplace = %{
        name: "jonat-local",
        plugins: [
          %{
            name: "symphony-plus-plus",
            source: %{source: "local", path: "missing/symphony-plus-plus"},
            policy: %{installation: "AVAILABLE", authentication: "ON_USE"},
            category: "Coding"
          }
        ]
      }

      try do
        File.write!(marketplace_path, Jason.encode!(marketplace))

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-MarketplacePath",
              marketplace_path,
              "-CodexHome",
              temp_codex_home
            ],
            stderr_to_stdout: true
          )

        assert status != 0
        assert output =~ "Configured plugin source path"
        refute File.exists?(plugin_cache_path(temp_codex_home, []))
      after
        File.rm(marketplace_path)
        File.rm_rf(temp_codex_home)
      end
    end
  end

  @tag :ci_slow
  test "refresh script resolves repo-root relative source paths from marketplace file" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")

    marketplace_path =
      Path.join(@repo_root, "plugins/symphony-plus-plus/sympp-marketplace-test-#{unique_id()}.json")

    if powershell do
      marketplace = %{
        name: "jonat-local",
        plugins: [
          %{
            name: "symphony-plus-plus",
            source: %{source: "local", path: "./plugins/symphony-plus-plus"},
            policy: %{installation: "AVAILABLE", authentication: "ON_USE"},
            category: "Coding"
          }
        ]
      }

      try do
        File.write!(marketplace_path, Jason.encode!(marketplace))

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-MarketplacePath",
              marketplace_path,
              "-CodexHome",
              temp_codex_home
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        refreshed_manifest_path = plugin_cache_path(temp_codex_home, [@plugin_version, ".codex-plugin", "plugin.json"])
        refreshed_mcp_path = plugin_cache_path(temp_codex_home, [@plugin_version, ".mcp.json"])

        assert refreshed_manifest_path |> File.read!() |> Jason.decode!() |> Map.fetch!("name") == "symphony-plus-plus"
        refute File.exists?(refreshed_mcp_path)
        refute File.exists?(plugin_cache_path(temp_codex_home, ["local"]))
      after
        File.rm(marketplace_path)
        File.rm_rf(temp_codex_home)
      end
    end
  end
end
