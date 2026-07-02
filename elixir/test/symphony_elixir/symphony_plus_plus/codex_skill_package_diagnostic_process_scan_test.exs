Code.require_file("codex_skill_package_case_test.exs", __DIR__)

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
end
