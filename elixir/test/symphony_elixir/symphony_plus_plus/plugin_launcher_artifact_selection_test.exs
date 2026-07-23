Code.require_file("plugin_launcher_artifact_selection_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.PluginLauncherArtifactSelectionTest do
  use SymphonyElixir.SymphonyPlusPlus.PluginLauncherArtifactSelectionCase

  test "installed MCP launcher treats artifact release listeners as managed backends" do
    script = File.read!(@mcp_plugin_start_script_path)

    assert script =~ "artifacts[\\\\/]mcp"
    assert script =~ "start-runtime\\.ps1"
    assert script =~ "symphony_elixir"
    assert script =~ "Test-ProcessOwnsTcpPort"
    assert script =~ "Stop-ManagedRuntimeProcess $Role $listenerPid $entryPort"
    assert script =~ "RedirectStandardInput"

    process_runtime =
      File.read!(Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/sympp-mcp-process-runtime.ps1"))

    assert process_runtime =~ "New-McpStdinReader"
    assert process_runtime =~ "OpenStandardInput"
  end

  test "installed MCP launcher falls back to marketplace source when artifact manifest is missing" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-missing")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        write_pinned_source_revision!(mcp_cache_root, @marketplace_revision)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", ""},
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_SOURCE_FALLBACK", "1"}
            ]
          )

        assert status == 0, output
        assert output =~ "Symphony++ MCP launcher validation passed."
        assert normalize_path_fragment(output) =~ "reporoot: #{normalize_path_fragment(marketplace_root)}"
        assert output =~ "runtimeMode: source"
        assert output =~ "artifactStatus: artifact_missing"
        assert output =~ "artifactDetail: manifest_missing"
        assert output =~ "sourceFallback: enabled"
        assert output =~ "Mix 1.99.0 test"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher trusts Codex marketplace metadata without rechecking the git worktree" do
    powershell = System.find_executable("pwsh")
    git = System.find_executable("git")
    temp_codex_home = unique_temp_path("sympp-plugin-dirty-marketplace-contract")

    if powershell && git do
      fake_mix = fake_mix_executable(temp_codex_home)
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      revision = commit_marketplace_source!(marketplace_root, git)
      contract_path = Path.join(marketplace_root, "elixir/priv/symphony_plus_plus/mcp_contract.json")
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        write_pinned_source_revision!(mcp_cache_root, revision)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        File.write!(contract_path, File.read!(contract_path) <> "\n")

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", ""},
              {"SYMPP_HOME", Path.join(temp_codex_home, "sympp-home")},
              {"SYMPP_SOURCE_FALLBACK", "1"}
            ]
          )

        assert status == 0, output
        assert output =~ "Symphony++ MCP launcher validation passed."
        assert normalize_path_fragment(output) =~ "reporoot: #{normalize_path_fragment(marketplace_root)}"
        assert output =~ "runtimeMode: source"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher validate-only fails when artifact and source fallback are unavailable" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-blocked")

    if powershell do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [{"SYMPP_REPO_ROOT", ""}, {"SYMPP_HOME", Path.join(temp_codex_home, "sympp-home")}]
          )

        assert status != 0
        assert normalize_prose(output) =~ "expected MCP contract fingerprint could not be resolved"
        refute output =~ "Symphony++ MCP launcher validation passed."
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end
end
