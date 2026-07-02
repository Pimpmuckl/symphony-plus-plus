Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageDiagnosticCacheRepairTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @moduletag :ci_slow

  test "lifecycle diagnostic keeps installed cache repair marketplace-owned" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-readiness-source-root-#{System.unique_integer([:positive])}")

    if powershell do
      installed_script_path = plugin_cache_path(temp_codex_home, ["local", "scripts", "diagnose-mcp-lifecycle.ps1"])
      installed_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"])
      installed_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])
      companion_local_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      companion_local_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      companion_old_version_manifest_path = plugin_cache_path(temp_codex_home, ["2.0.0", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      companion_old_version_mcp_path = plugin_cache_path(temp_codex_home, ["2.0.0", ".mcp.json"], "symphony-plus-plus-mcp")
      companion_old_version_hint_path = plugin_cache_path(temp_codex_home, ["2.0.0", ".sympp-source-root"], "symphony-plus-plus-mcp")
      companion_new_version_manifest_path = plugin_cache_path(temp_codex_home, ["10.0.0", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      companion_new_version_mcp_path = plugin_cache_path(temp_codex_home, ["10.0.0", ".mcp.json"], "symphony-plus-plus-mcp")
      companion_new_version_hint_path = plugin_cache_path(temp_codex_home, ["10.0.0", ".sympp-source-root"], "symphony-plus-plus-mcp")

      run_diagnostic = fn cwd ->
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
          cd: cwd
        )
      end

      try do
        File.mkdir_p!(Path.dirname(installed_script_path))
        copy_lifecycle_diagnostic!(installed_script_path)

        {no_config_output, no_config_status} = run_diagnostic.(temp_codex_home)
        assert no_config_status == 0, no_config_output
        no_config_readiness = no_config_output |> Jason.decode!() |> Map.fetch!("readiness")

        create_config =
          Enum.find(no_config_readiness["next_actions"], &(&1["code"] == "create_codex_config"))

        assert create_config
        refute Map.has_key?(create_config, "command")
        assert create_config["message"] =~ "config.toml"

        File.write!(Path.join(temp_codex_home, "config.toml"), "")

        {current_output, current_status} = run_diagnostic.(@repo_root)
        assert current_status == 0, current_output
        current_readiness = current_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert current_readiness["source_checkout"]["status"] == "current_working_directory"
        assert same_path?(current_readiness["source_checkout"]["root"], @repo_root)

        current_refresh =
          Enum.find(current_readiness["next_actions"], &(&1["code"] == "upgrade_default_plugin_cache"))

        assert_scoped_marketplace_upgrade!(current_refresh["command"], temp_codex_home, "jonat-local")

        {missing_output, missing_status} = run_diagnostic.(temp_codex_home)
        assert missing_status == 0, missing_output
        missing_readiness = missing_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert missing_readiness["source_checkout"]["status"] == "not_found"

        missing_refresh =
          Enum.find(missing_readiness["next_actions"], &(&1["code"] == "upgrade_default_plugin_cache"))

        assert missing_refresh
        assert_scoped_marketplace_upgrade!(missing_refresh["command"], temp_codex_home, "jonat-local")

        File.write!(installed_hint_path, "#{@repo_root}\n")

        {invalid_hint_output, invalid_hint_status} = run_diagnostic.(temp_codex_home)
        assert invalid_hint_status == 0, invalid_hint_output
        invalid_hint_readiness = invalid_hint_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert invalid_hint_readiness["source_checkout"]["status"] == "not_found"

        File.mkdir_p!(Path.dirname(installed_manifest_path))
        File.write!(installed_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => @plugin_version}))

        {hint_output, hint_status} = run_diagnostic.(temp_codex_home)
        assert hint_status == 0, hint_output
        hint_readiness = hint_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert hint_readiness["source_checkout"]["status"] == "not_found"
        assert hint_readiness["source_checkout"]["root"] in [nil, ""]

        companion_refresh =
          Enum.find(hint_readiness["next_actions"], &(&1["code"] == "upgrade_mcp_companion_cache"))

        assert_scoped_marketplace_upgrade!(companion_refresh["command"], temp_codex_home, "jonat-local")

        File.mkdir_p!(Path.dirname(companion_local_manifest_path))

        File.write!(
          companion_local_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => @plugin_version, "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          companion_local_mcp_path,
          Jason.encode!(%{"symphony_plus_plus" => %{"url" => "http://example.invalid/mcp"}})
        )

        File.mkdir_p!(Path.dirname(companion_old_version_manifest_path))

        File.write!(
          companion_old_version_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => "2.0.0", "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          companion_old_version_mcp_path,
          command_mcp_config_json()
        )

        File.write!(companion_old_version_hint_path, "#{@repo_root}\n")
        File.mkdir_p!(Path.dirname(companion_new_version_manifest_path))

        File.write!(
          companion_new_version_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => "10.0.0", "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          companion_new_version_mcp_path,
          command_mcp_config_json()
        )

        File.write!(companion_new_version_hint_path, "#{@repo_root}\n")

        {valid_version_output, valid_version_status} = run_diagnostic.(temp_codex_home)
        assert valid_version_status == 0, valid_version_output
        valid_version_readiness = valid_version_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert valid_version_readiness["workrequest_mcp"]["status"] == "companion_installed_not_enabled"
        assert valid_version_readiness["workrequest_mcp"]["cache_label"] == "10.0.0"
        assert valid_version_readiness["workrequest_mcp"]["cache_freshness"]["status"] == "unknown_source"

        refute Enum.any?(valid_version_readiness["next_actions"], &(&1["code"] == "upgrade_mcp_companion_cache"))

        assert Enum.any?(valid_version_readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end
