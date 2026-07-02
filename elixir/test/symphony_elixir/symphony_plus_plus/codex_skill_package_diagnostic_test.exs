Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageDiagnosticTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  test "diagnostic offers installed-script enable command without source checkout" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-installed-enable-#{System.unique_integer([:positive])}")

    if powershell do
      installed_script_path = plugin_cache_path(temp_codex_home, ["local", "scripts", "diagnose-mcp-lifecycle.ps1"])

      try do
        File.mkdir_p!(Path.dirname(installed_script_path))
        copy_lifecycle_diagnostic!(installed_script_path)
        write_activation_cache(temp_codex_home, "jonat-local")

        File.write!(
          Path.join(temp_codex_home, "config.toml"),
          """
          [plugins."symphony-plus-plus@jonat-local"]
          enabled = true
          """
        )

        {json_output, status} =
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
              "-Json"
            ],
            stderr_to_stdout: true,
            cd: temp_codex_home
          )

        assert status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["source_checkout"]["status"] == "not_found"

        enable_action =
          Enum.find(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))

        assert enable_action
        assert enable_action["command"] =~ "-EnableMcpCompanion"
        assert enable_action["command"] =~ "-CodexHome"
        assert normalize_path_fragment(enable_action["command"]) =~ normalize_path_fragment(installed_script_path)
        refute enable_action["message"] =~ "-RepoRoot"
        assert Enum.any?(readiness["next_actions"], &(&1["code"] == "restart_codex_session"))
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

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

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageDiagnosticCacheSelectionTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  test "lifecycle diagnostic ignores selected and non-selected cache hints" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-selected-source-hint-#{System.unique_integer([:positive])}")

    if powershell do
      installed_script_path = plugin_cache_path(temp_codex_home, ["local", "scripts", "diagnose-mcp-lifecycle.ps1"])
      companion_local_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      companion_local_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      companion_local_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")
      companion_old_manifest_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      companion_old_mcp_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".mcp.json"], "symphony-plus-plus-mcp")
      companion_old_hint_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".sympp-source-root"], "symphony-plus-plus-mcp")
      stale_source_root = Path.join(temp_codex_home, "stale-source")

      try do
        File.mkdir_p!(Path.join(stale_source_root, "elixir"))
        File.mkdir_p!(Path.join(stale_source_root, "scripts"))
        File.write!(Path.join(stale_source_root, "elixir/mix.exs"), "")
        File.write!(Path.join(stale_source_root, "scripts/refresh-local-plugin.ps1"), "")
        File.write!(Path.join(stale_source_root, "scripts/smoke-sympp-mcp-http.ps1"), "")
        File.mkdir_p!(Path.dirname(installed_script_path))
        copy_lifecycle_diagnostic!(installed_script_path)
        File.write!(Path.join(temp_codex_home, "config.toml"), "")

        mcp_config = command_mcp_config_json()

        for {manifest_path, mcp_path, hint_path, version, source_root} <- [
              {companion_local_manifest_path, companion_local_mcp_path, companion_local_hint_path, "2.0.0", @repo_root},
              {companion_old_manifest_path, companion_old_mcp_path, companion_old_hint_path, "1.0.0", stale_source_root}
            ] do
          File.mkdir_p!(Path.dirname(manifest_path))

          File.write!(
            manifest_path,
            Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => version, "mcpServers" => "./.mcp.json"})
          )

          File.write!(mcp_path, mcp_config)
          File.write!(hint_path, "#{source_root}\n")
        end

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

  test "lifecycle diagnostic does not treat stale enabled MCP companion as a Solo skill provider" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-readiness-mcp-only-#{System.unique_integer([:positive])}")

    if powershell do
      companion_manifest_path =
        plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

      companion_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(companion_manifest_path))

        File.write!(
          companion_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => @plugin_version, "mcpServers" => "./.mcp.json"})
        )

        File.write!(
          companion_mcp_path,
          command_mcp_config_json()
        )

        File.write!(
          Path.join(temp_codex_home, "config.toml"),
          """
          [plugins."symphony-plus-plus-mcp@jonat-local"]
          enabled = true
          """
        )

        {json_output, json_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert json_status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["overall_status"] == "plugin_cache_stale"
        assert readiness["solo_session"]["status"] == "default_plugin_not_enabled"
        assert readiness["workrequest_mcp"]["status"] == "companion_cache_stale"
        refute Enum.any?(readiness["next_actions"], &(&1["code"] == "enable_default_plugin"))
        assert readiness["session_visibility_note"] =~ "cannot inspect tools already registered"
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic marks stale or broken cache manifests incompatible" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-#{System.unique_integer([:positive])}")

    if powershell do
      repo_one = fixture_repo_root("repo-one")
      repo_two = fixture_repo_root("repo-two")
      repo_three = fixture_repo_root("repo-three")
      repo_four = fixture_repo_root("repo-four")
      stale_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])
      stale_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"])
      stale_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"])
      superseded_manifest_path = plugin_cache_path(temp_codex_home, ["0.1.1", ".codex-plugin", "plugin.json"])
      superseded_mcp_path = plugin_cache_path(temp_codex_home, ["0.1.1", ".mcp.json"])
      superseded_hint_path = plugin_cache_path(temp_codex_home, ["0.1.1", ".sympp-source-root"])
      broken_mcp_path = plugin_cache_path(temp_codex_home, ["broken", ".mcp.json"])
      broken_hint_path = plugin_cache_path(temp_codex_home, ["broken", ".sympp-source-root"])
      malformed_manifest_path = plugin_cache_path(temp_codex_home, ["malformed", ".codex-plugin", "plugin.json"])
      malformed_mcp_path = plugin_cache_path(temp_codex_home, ["malformed", ".mcp.json"])
      malformed_hint_path = plugin_cache_path(temp_codex_home, ["malformed", ".sympp-source-root"])
      bad_reference_manifest_path = plugin_cache_path(temp_codex_home, ["bad-reference", ".codex-plugin", "plugin.json"])
      bad_reference_mcp_path = plugin_cache_path(temp_codex_home, ["bad-reference", ".mcp.json"])
      bad_reference_hint_path = plugin_cache_path(temp_codex_home, ["bad-reference", ".sympp-source-root"])

      File.mkdir_p!(Path.dirname(stale_manifest_path))
      File.mkdir_p!(Path.dirname(superseded_manifest_path))
      File.mkdir_p!(Path.dirname(broken_mcp_path))
      File.mkdir_p!(Path.dirname(malformed_manifest_path))
      File.mkdir_p!(Path.dirname(bad_reference_manifest_path))

      File.write!(
        Path.join(temp_codex_home, "config.toml"),
        """
        [plugins."symphony-plus-plus@jonat-local"]
        enabled = false

        [plugins."symphony-plus-plus-mcp@jonat-local"]
        enabled = true
        """
      )

      File.write!(
        stale_manifest_path,
        Jason.encode!(%{
          "name" => "symphony-plus-plus",
          "version" => "0.1.1",
          "mcpServers" => "./.mcp.json"
        })
      )

      File.write!(stale_mcp_path, command_mcp_config_json())

      File.write!(superseded_manifest_path, File.read!(stale_manifest_path))
      File.write!(superseded_mcp_path, File.read!(stale_mcp_path))

      File.write!(
        broken_mcp_path,
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "cmd.exe"
          }
        })
      )

      write_source_hint!(stale_hint_path, repo_one)
      write_source_hint!(superseded_hint_path, repo_two)
      write_source_hint!(broken_hint_path, repo_two)
      File.write!(malformed_manifest_path, "{")
      write_source_hint!(malformed_hint_path, repo_three)

      File.write!(
        bad_reference_manifest_path,
        Jason.encode!(%{
          "name" => "symphony-plus-plus",
          "version" => "0.1.2"
        })
      )

      File.write!(
        bad_reference_mcp_path,
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "cmd.exe",
            "args" => ["-NoProfile"],
            "cwd" => "."
          }
        })
      )

      write_source_hint!(bad_reference_hint_path, repo_four)

      File.write!(
        malformed_mcp_path,
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "cmd.exe"
          }
        })
      )

      try do
        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-SkipProcessScan",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        caches = Map.fetch!(report, "installed_cache")
        config_entries = report["codex_config"]["symphony_plugin_entries"]

        stale_cache =
          caches
          |> Enum.find(&(&1["label"] == "local"))

        superseded_cache =
          caches
          |> Enum.find(&(&1["label"] == "0.1.1"))

        broken_cache =
          caches
          |> Enum.find(&(&1["label"] == "broken"))

        malformed_cache =
          caches
          |> Enum.find(&(&1["label"] == "malformed"))

        bad_reference_cache =
          caches
          |> Enum.find(&(&1["label"] == "bad-reference"))

        assert stale_cache["manifest_mcpServers_declared"] == true
        assert stale_cache["default_plugin_lifecycle_status"] == "incompatible_default_plugin_bundles_mcp"
        assert stale_cache["reference_mcp_server_status"] == "ok"
        assert stale_cache["symphony_plus_plus_server"] == "incompatible_default_plugin_bundles_mcp"

        assert superseded_cache["default_plugin_lifecycle_status"] == "incompatible_default_plugin_bundles_mcp"
        assert superseded_cache["reference_mcp_server_status"] == "ok"

        assert broken_cache["manifest_exists"] == false
        assert broken_cache["default_plugin_lifecycle_status"] == "missing_manifest"
        assert broken_cache["reference_mcp_server_status"] == "invalid_cwd"
        assert broken_cache["symphony_plus_plus_server"] == "missing_manifest"

        assert malformed_cache["default_plugin_lifecycle_status"] == "manifest_parse_error"
        assert malformed_cache["reference_mcp_server_status"] == "invalid_cwd"
        assert malformed_cache["symphony_plus_plus_server"] == "manifest_parse_error"

        assert bad_reference_cache["default_plugin_lifecycle_status"] == "incompatible_default_plugin_bundles_mcp"
        assert bad_reference_cache["reference_mcp_server_status"] == "invalid_args"
        assert bad_reference_cache["symphony_plus_plus_server"] == "incompatible_default_plugin_bundles_mcp"

        assert report["codex_config"]["symphony_plugin_enabled"] == true
        assert Enum.any?(config_entries, &(&1["plugin_name"] == "symphony-plus-plus" and &1["enabled"] == false))
        assert Enum.any?(config_entries, &(&1["plugin_name"] == "symphony-plus-plus-mcp" and &1["enabled"] == true))

        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_scan_performed"] == false
        assert report["process_scan_note"] =~ "-SkipProcessScan"
        assert report["process_repo_root_filters"] == []
        assert report["live_process_counts"]["erl_sympp_mcp"] == 0
        assert report["live_process_counts"]["start_sympp_mcp_pwsh_unattributed"] == 0
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageDiagnosticProcessScanTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  test "lifecycle diagnostic performs live process scan when package versions differ" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_root = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-drift-#{System.unique_integer([:positive])}")

    if powershell do
      default_version = "1.0.0"
      opt_in_version = "2.0.0"
      temp_codex_home = Path.join(temp_root, "codex-home")
      default_cache_manifest_path = plugin_cache_path(temp_codex_home, [default_version, ".codex-plugin", "plugin.json"])
      default_cache_hint_path = plugin_cache_path(temp_codex_home, [default_version, ".sympp-source-root"])
      diagnostic_path = plugin_cache_path(temp_codex_home, [default_version, "scripts", "diagnose-mcp-lifecycle.ps1"])

      opt_in_cache_manifest_path =
        plugin_cache_path(temp_codex_home, [opt_in_version, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

      opt_in_cache_mcp_path = plugin_cache_path(temp_codex_home, [opt_in_version, ".mcp.json"], "symphony-plus-plus-mcp")
      opt_in_cache_hint_path = plugin_cache_path(temp_codex_home, [opt_in_version, ".sympp-source-root"], "symphony-plus-plus-mcp")
      opt_in_local_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      opt_in_local_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      opt_in_local_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")

      mcp_config = command_mcp_config_json()

      try do
        File.mkdir_p!(Path.dirname(default_cache_manifest_path))
        File.mkdir_p!(Path.dirname(diagnostic_path))
        copy_lifecycle_diagnostic!(diagnostic_path)
        File.write!(default_cache_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => default_version}))
        File.write!(default_cache_hint_path, "C:/sympp/repo-one\n")

        File.mkdir_p!(Path.dirname(opt_in_cache_manifest_path))

        File.write!(
          opt_in_cache_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => opt_in_version, "mcpServers" => "./.mcp.json"})
        )

        File.write!(opt_in_cache_mcp_path, mcp_config)
        File.write!(opt_in_cache_hint_path, "C:/sympp/repo-one\n")
        File.mkdir_p!(Path.dirname(opt_in_local_manifest_path))
        File.write!(opt_in_local_manifest_path, "{")
        File.write!(opt_in_local_mcp_path, mcp_config)
        File.write!(opt_in_local_hint_path, "C:/sympp/broken-local\n")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-RepoRoot",
              @repo_root,
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        caches = Map.fetch!(report, "installed_cache")
        assert report["process_scan_scope"] == "repo_root_parameter"
        assert report["process_scan_performed"] == report["process_scan_supported"]
        assert [repo_filter] = report["process_repo_root_filters"]
        assert same_path?(repo_filter, @repo_root)
        assert report["live_process_counts"]["erl_sympp_mcp"] == 0

        assert Enum.any?(
                 caches,
                 &(&1["package_name"] == "symphony-plus-plus" and
                     &1["label"] == default_version and
                     &1["reference_mcp_server_status"] == "not_configured")
               )

        assert Enum.any?(
                 caches,
                 &(&1["package_name"] == "symphony-plus-plus-mcp" and
                     &1["label"] == opt_in_version and
                     &1["reference_mcp_server_status"] == "ok")
               )
      after
        File.rm_rf(temp_root)
      end
    end
  end

  test "lifecycle diagnostic does not scope source runs from stale installed opt-in cache versions" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-source-drift-#{System.unique_integer([:positive])}")

    if powershell do
      opt_in_version = "2.0.0"

      opt_in_cache_manifest_path =
        plugin_cache_path(temp_codex_home, [opt_in_version, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

      opt_in_cache_mcp_path = plugin_cache_path(temp_codex_home, [opt_in_version, ".mcp.json"], "symphony-plus-plus-mcp")
      opt_in_cache_hint_path = plugin_cache_path(temp_codex_home, [opt_in_version, ".sympp-source-root"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(opt_in_cache_manifest_path))

        File.write!(
          opt_in_cache_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => opt_in_version, "mcpServers" => "./.mcp.json"})
        )

        File.write!(opt_in_cache_mcp_path, command_mcp_config_json())

        File.write!(opt_in_cache_hint_path, "C:/sympp/repo-one\n")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic ignores stale opt-in local cache when source version differs" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-stale-local-#{System.unique_integer([:positive])}")

    if powershell do
      opt_in_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      opt_in_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      opt_in_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(opt_in_manifest_path))

        File.write!(
          opt_in_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => "0.0.1", "mcpServers" => "./.mcp.json"})
        )

        File.write!(opt_in_mcp_path, command_mcp_config_json())

        File.write!(opt_in_hint_path, "C:/sympp/stale-local\n")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic ignores opt-in local cache when no current opt-in version is known" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-local-unknown-current-#{System.unique_integer([:positive])}")

    if powershell do
      default_manifest_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"])
      diagnostic_path = plugin_cache_path(temp_codex_home, ["1.0.0", "scripts", "diagnose-mcp-lifecycle.ps1"])

      opt_in_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      opt_in_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      opt_in_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(diagnostic_path))
        copy_lifecycle_diagnostic!(diagnostic_path)
        File.mkdir_p!(Path.dirname(default_manifest_path))
        File.write!(default_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "1.0.0"}))
        File.mkdir_p!(Path.dirname(opt_in_manifest_path))

        File.write!(
          opt_in_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => "0.0.1", "mcpServers" => "./.mcp.json"})
        )

        File.write!(opt_in_mcp_path, command_mcp_config_json())

        File.write!(opt_in_hint_path, "C:/sympp/stale-local\n")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageDiagnosticHintScopeTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  test "lifecycle diagnostic scopes hinted installed default cache from opt-in local cache" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-local-only-#{System.unique_integer([:positive])}")

    if powershell do
      local_repo_root = fixture_repo_root("local")
      default_manifest_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"])
      default_hint_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".sympp-source-root"])
      diagnostic_path = plugin_cache_path(temp_codex_home, ["1.0.0", "scripts", "diagnose-mcp-lifecycle.ps1"])

      opt_in_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      opt_in_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      opt_in_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(diagnostic_path))
        copy_lifecycle_diagnostic!(diagnostic_path)
        File.mkdir_p!(Path.dirname(default_manifest_path))
        File.write!(default_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "1.0.0"}))
        write_source_hint!(default_hint_path, fixture_repo_root("default"))
        File.mkdir_p!(Path.dirname(opt_in_manifest_path))

        File.write!(
          opt_in_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => "2.0.0", "mcpServers" => "./.mcp.json"})
        )

        File.write!(opt_in_mcp_path, command_mcp_config_json())

        write_source_hint!(opt_in_hint_path, local_repo_root)
        refute File.exists?(plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp"))

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-SkipProcessScan",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic prefers current versioned opt-in cache over stale local cache" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-stale-local-versioned-#{System.unique_integer([:positive])}")

    if powershell do
      current_versioned_repo_root = fixture_repo_root("current-versioned")
      default_manifest_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"])
      default_hint_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".sympp-source-root"])
      diagnostic_path = plugin_cache_path(temp_codex_home, ["1.0.0", "scripts", "diagnose-mcp-lifecycle.ps1"])

      local_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      local_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      local_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")
      versioned_manifest_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      versioned_mcp_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".mcp.json"], "symphony-plus-plus-mcp")
      versioned_hint_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".sympp-source-root"], "symphony-plus-plus-mcp")

      mcp_config = command_mcp_config_json()

      try do
        File.mkdir_p!(Path.dirname(diagnostic_path))
        copy_lifecycle_diagnostic!(diagnostic_path)
        File.mkdir_p!(Path.dirname(default_manifest_path))
        File.write!(default_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "1.0.0"}))
        write_source_hint!(default_hint_path, fixture_repo_root("default"))

        for {manifest_path, mcp_path, hint_path, version, repo_root} <- [
              {local_manifest_path, local_mcp_path, local_hint_path, "0.0.1", fixture_repo_root("stale-local")},
              {versioned_manifest_path, versioned_mcp_path, versioned_hint_path, "1.0.0", current_versioned_repo_root}
            ] do
          File.mkdir_p!(Path.dirname(manifest_path))

          File.write!(
            manifest_path,
            Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => version, "mcpServers" => "./.mcp.json"})
          )

          File.write!(mcp_path, mcp_config)
          File.write!(hint_path, "#{repo_root}\n")
        end

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-SkipProcessScan",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic preserves ambiguity when current opt-in local and versioned hints differ" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-local-versioned-ambiguous-#{System.unique_integer([:positive])}")

    if powershell do
      mcp_config = command_mcp_config_json()

      try do
        for {label, repo_root} <- [{"local", fixture_repo_root("local")}, {@plugin_version, fixture_repo_root("versioned")}] do
          manifest_path = plugin_cache_path(temp_codex_home, [label, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
          mcp_path = plugin_cache_path(temp_codex_home, [label, ".mcp.json"], "symphony-plus-plus-mcp")
          hint_path = plugin_cache_path(temp_codex_home, [label, ".sympp-source-root"], "symphony-plus-plus-mcp")
          File.mkdir_p!(Path.dirname(manifest_path))

          File.write!(
            manifest_path,
            Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => @plugin_version, "mcpServers" => "./.mcp.json"})
          )

          File.write!(mcp_path, mcp_config)
          File.write!(hint_path, "#{repo_root}\n")
        end

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageDiagnosticOptInPrecedenceTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  test "lifecycle diagnostic keeps opt-in local precedence marketplace scoped" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-marketplace-scope-#{System.unique_integer([:positive])}")

    if powershell do
      mcp_config = command_mcp_config_json()

      try do
        for {marketplace, label, repo_root} <- [
              {"market-a", "local", "C:/sympp/market-a"},
              {"market-b", @plugin_version, "C:/sympp/market-b"}
            ] do
          manifest_path = plugin_cache_path(temp_codex_home, [label, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp", marketplace)
          mcp_path = plugin_cache_path(temp_codex_home, [label, ".mcp.json"], "symphony-plus-plus-mcp", marketplace)
          hint_path = plugin_cache_path(temp_codex_home, [label, ".sympp-source-root"], "symphony-plus-plus-mcp", marketplace)
          File.mkdir_p!(Path.dirname(manifest_path))

          File.write!(
            manifest_path,
            Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => @plugin_version, "mcpServers" => "./.mcp.json"})
          )

          File.write!(mcp_path, mcp_config)
          File.write!(hint_path, "#{repo_root}\n")
        end

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "*",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic prefers refreshed opt-in local cache over same-version companion" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-local-precedence-#{System.unique_integer([:positive])}")

    if powershell do
      local_repo_root = fixture_repo_root("local")
      default_manifest_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"])
      diagnostic_path = plugin_cache_path(temp_codex_home, ["1.0.0", "scripts", "diagnose-mcp-lifecycle.ps1"])

      versioned_manifest_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      versioned_mcp_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".mcp.json"], "symphony-plus-plus-mcp")
      versioned_hint_path = plugin_cache_path(temp_codex_home, ["1.0.0", ".sympp-source-root"], "symphony-plus-plus-mcp")
      local_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
      local_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      local_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")

      mcp_config = command_mcp_config_json()

      try do
        File.mkdir_p!(Path.dirname(diagnostic_path))
        copy_lifecycle_diagnostic!(diagnostic_path)
        File.mkdir_p!(Path.dirname(default_manifest_path))
        File.write!(default_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "1.0.0"}))

        for {manifest_path, mcp_path, hint_path, version, repo_root} <- [
              {versioned_manifest_path, versioned_mcp_path, versioned_hint_path, "1.0.0", fixture_repo_root("versioned")},
              {local_manifest_path, local_mcp_path, local_hint_path, "2.0.0", local_repo_root}
            ] do
          File.mkdir_p!(Path.dirname(manifest_path))

          File.write!(
            manifest_path,
            Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => version, "mcpServers" => "./.mcp.json"})
          )

          File.write!(mcp_path, mcp_config)
          File.write!(hint_path, "#{repo_root}\n")
        end

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-SkipProcessScan",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic ignores superseded opt-in cache versions when source version is installed" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-superseded-#{System.unique_integer([:positive])}")

    if powershell do
      current_version = @plugin_version
      stale_version = "0.0.1"
      current_repo_root = fixture_repo_root("repo-one")

      try do
        for {version, repo_root} <- [{current_version, current_repo_root}, {stale_version, fixture_repo_root("old-repo")}] do
          manifest_path = plugin_cache_path(temp_codex_home, [version, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")
          mcp_path = plugin_cache_path(temp_codex_home, [version, ".mcp.json"], "symphony-plus-plus-mcp")
          hint_path = plugin_cache_path(temp_codex_home, [version, ".sympp-source-root"], "symphony-plus-plus-mcp")
          File.mkdir_p!(Path.dirname(manifest_path))

          File.write!(
            manifest_path,
            Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => version, "mcpServers" => "./.mcp.json"})
          )

          File.write!(mcp_path, command_mcp_config_json())

          File.write!(hint_path, "#{repo_root}\n")
        end

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-SkipProcessScan",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageDiagnosticProcessScopeTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  test "lifecycle diagnostic does not scope live process scan from default-only cache hint" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-default-only-#{System.unique_integer([:positive])}")

    if powershell do
      default_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])
      default_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"])

      try do
        File.mkdir_p!(Path.dirname(default_manifest_path))
        File.write!(default_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => @plugin_version}))
        write_source_hint!(default_hint_path, fixture_repo_root("repo-one"))

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "lifecycle diagnostic prefers opt-in MCP cache hints over MCP-free default hints" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-diagnostic-opt-in-precedence-#{System.unique_integer([:positive])}")

    if powershell do
      repo_two = fixture_repo_root("repo-two")
      default_manifest_path = plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])
      default_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"])

      opt_in_manifest_path =
        plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

      opt_in_mcp_path = plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")
      opt_in_hint_path = plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(default_manifest_path))
        File.write!(default_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => @plugin_version}))
        write_source_hint!(default_hint_path, fixture_repo_root("repo-one"))

        File.mkdir_p!(Path.dirname(opt_in_manifest_path))

        File.write!(
          opt_in_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus-mcp", "version" => @plugin_version, "mcpServers" => "./.mcp.json"})
        )

        File.write!(opt_in_mcp_path, command_mcp_config_json())

        write_source_hint!(opt_in_hint_path, repo_two)

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-SkipProcessScan",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        report = Jason.decode!(output)
        assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
        assert report["process_repo_root_filters"] == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end
