Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageDiagnosticLocalPrecedenceTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

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
end
