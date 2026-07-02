Code.require_file("codex_skill_package_case_test.exs", __DIR__)

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
end
