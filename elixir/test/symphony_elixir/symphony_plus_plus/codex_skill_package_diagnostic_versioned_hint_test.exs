Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageDiagnosticVersionedHintTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @moduletag :ci_slow

  test "lifecycle diagnostic ignores valid versioned cache hints when local cache has no source hint" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-versioned-source-hint-#{System.unique_integer([:positive])}")

    if powershell do
      installed_script_path = plugin_cache_path(temp_codex_home, ["local", "scripts", "diagnose-mcp-lifecycle.ps1"])
      companion_local_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      companion_local_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      companion_version_manifest_path = plugin_cache_path(temp_codex_home, ["10.0.0", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      companion_version_mcp_path = plugin_cache_path(temp_codex_home, ["10.0.0", ".mcp.json"], "symphony-plus-plus-mcp")
      companion_version_hint_path = plugin_cache_path(temp_codex_home, ["10.0.0", ".sympp-source-root"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(installed_script_path))
        copy_lifecycle_diagnostic!(installed_script_path)
        File.write!(Path.join(temp_codex_home, "config.toml"), "")
        File.mkdir_p!(Path.dirname(companion_local_manifest_path))

        File.write!(
          companion_local_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => "10.0.0", "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          companion_local_mcp_path,
          command_mcp_config_json()
        )

        File.mkdir_p!(Path.dirname(companion_version_manifest_path))

        File.write!(
          companion_version_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => "10.0.0", "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          companion_version_mcp_path,
          command_mcp_config_json()
        )

        File.write!(companion_version_hint_path, "#{@repo_root}\n")

        {json_output, json_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              installed_script_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-SkipProcessScan",
              "-Json"
            ],
            stderr_to_stdout: true,
            cd: temp_codex_home
          )

        assert json_status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["source_checkout"]["status"] == "not_found"
        assert readiness["source_checkout"]["root"] in [nil, ""]

        default_refresh =
          Enum.find(readiness["next_actions"], &(&1["code"] == "upgrade_default_plugin_cache"))

        assert_scoped_marketplace_upgrade!(default_refresh["command"], temp_codex_home, "jonat-local")
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end
