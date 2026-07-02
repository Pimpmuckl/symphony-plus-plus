Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageDiagnosticSupersededOptInTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @moduletag :ci_slow

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
