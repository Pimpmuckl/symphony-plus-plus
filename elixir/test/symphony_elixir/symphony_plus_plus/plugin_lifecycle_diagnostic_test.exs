Code.require_file("plugin_lifecycle_diagnostic_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.PluginLifecycleDiagnosticTest do
  use SymphonyElixir.SymphonyPlusPlus.PluginLifecycleDiagnosticCase

  test "lifecycle doctor ignores stale cache hints when marketplace source is not verified" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-marketplace-source-doctor")

    if powershell do
      write_minimal_marketplace_source(temp_codex_home)
      stale_source_root = write_minimal_stale_source(temp_codex_home)
      default_cache_root = published_plugin_cache_path(temp_codex_home, [@plugin_version])
      mcp_cache_root = published_plugin_cache_path(temp_codex_home, [@plugin_version], "symphony-plus-plus-mcp")

      try do
        File.write!(Path.join(temp_codex_home, "config.toml"), """
        [plugins."symphony-plus-plus-mcp@#{@plugin_marketplace_name}"]
        enabled = true
        """)

        installed_script_path = write_cached_script(default_cache_root, @plugin_lifecycle_diagnostic_path)
        write_cache_manifest(default_cache_root, "symphony-plus-plus")
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_pinned_source_revision!(default_cache_root, String.duplicate("b", 40))
        write_pinned_source_revision!(mcp_cache_root, String.duplicate("b", 40))
        File.write!(Path.join(default_cache_root, ".sympp-source-root"), "#{stale_source_root}\n")
        File.write!(Path.join(mcp_cache_root, ".sympp-source-root"), "#{stale_source_root}\n")

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
        source_checkout = get_in(report, ["readiness", "source_checkout"])

        refute source_checkout["root"] &&
                 normalize_path_fragment(source_checkout["root"]) == normalize_path_fragment(stale_source_root)

        case source_checkout["status"] do
          "not_found" ->
            assert source_checkout["root"] in [nil, ""]
            assert report["process_scan_scope"] == "skipped_no_repo_root_scope"
            assert report["process_repo_root_filters"] == []

          "codex_marketplace_source_clone" ->
            marketplace_root = Path.join([temp_codex_home, ".tmp", "marketplaces", @plugin_marketplace_name])
            assert normalize_path_fragment(source_checkout["root"]) == normalize_path_fragment(marketplace_root)
            assert report["process_scan_scope"] == "installed_cache_marketplace_source_clone"

            assert Enum.map(report["process_repo_root_filters"], &normalize_path_fragment/1) == [
                     normalize_path_fragment(marketplace_root)
                   ]

          other ->
            flunk("expected no source checkout or a verified marketplace source clone, got #{inspect(other)}")
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "diagnostic contract resolver fails bad explicit repo override" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-doctor-explicit-contract")

    if powershell do
      try do
        explicit_repo_root = Path.join(temp_codex_home, "explicit-repo")
        artifact_root = Path.join(temp_codex_home, "artifact-root")
        File.mkdir_p!(explicit_repo_root)
        File.mkdir_p!(artifact_root)

        command = """
        function Test-SourceCheckoutRoot([string]$Path) { return $true }
        . #{quote_powershell_literal(@diagnostic_runtime_artifacts_path)}
        Get-DiagnosticExpectedMcpContractFingerprint #{quote_powershell_literal(artifact_root)}
        """

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-Command", command],
            stderr_to_stdout: true,
            env: [{"SYMPP_REPO_ROOT", explicit_repo_root}]
          )

        assert status != 0
        assert normalize_prose(output) =~ "explicit SYMPP_REPO_ROOT contract JSON"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end
end
