Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageDiagnosticStaleInstalledScopeTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

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
end
