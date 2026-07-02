Code.require_file("codex_skill_package_case_test.exs", __DIR__)

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
