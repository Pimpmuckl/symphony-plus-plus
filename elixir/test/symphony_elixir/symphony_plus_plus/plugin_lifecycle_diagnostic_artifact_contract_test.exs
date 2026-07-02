Code.require_file("plugin_lifecycle_diagnostic_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.PluginLifecycleDiagnosticArtifactContractTest do
  use SymphonyElixir.SymphonyPlusPlus.PluginLifecycleDiagnosticCase

  @moduletag :ci_slow

  test "lifecycle doctor rejects runtime artifacts without contract metadata" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-doctor-artifact-missing-contract")

    if powershell do
      default_cache_root = published_plugin_cache_path(temp_codex_home, [@plugin_version])
      mcp_cache_root = published_plugin_cache_path(temp_codex_home, [@plugin_version], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(temp_codex_home)

        File.write!(Path.join(temp_codex_home, "config.toml"), """
        [plugins."symphony-plus-plus-mcp@#{@plugin_marketplace_name}"]
        enabled = true
        """)

        installed_script_path = write_cached_script(default_cache_root, @plugin_lifecycle_diagnostic_path)
        write_cache_manifest(default_cache_root, "symphony-plus-plus")
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        revision = String.duplicate("b", 40)
        write_pinned_source_revision!(mcp_cache_root, revision)

        write_runtime_artifact!(mcp_cache_root,
          source_revision: revision,
          mcp_contract_fingerprint: :omit
        )

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              installed_script_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              @plugin_marketplace_name,
              "-SkipProcessScan",
              "-Json"
            ],
            cd: temp_codex_home,
            stderr_to_stdout: true,
            env: [{"SYMPP_REPO_ROOT", ""}]
          )

        assert status == 0, output
        report = Jason.decode!(output)
        assert get_in(report, ["readiness", "workrequest_mcp", "status"]) == "runtime_artifact_unavailable"
        runtime_artifact = get_in(report, ["readiness", "workrequest_mcp", "runtime_artifact"])
        assert runtime_artifact["status"] == "artifact_missing"
        assert runtime_artifact["detail"] == "contract_mismatch"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end
end
