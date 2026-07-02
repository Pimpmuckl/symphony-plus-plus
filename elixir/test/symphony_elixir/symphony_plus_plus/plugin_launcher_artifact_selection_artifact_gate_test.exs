Code.require_file("plugin_launcher_artifact_selection_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.PluginLauncherArtifactSelectionArtifactGateTest do
  use SymphonyElixir.SymphonyPlusPlus.PluginLauncherArtifactSelectionCase

  test "installed MCP launcher direct stdio rejects verified artifacts without source fallback" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-runtime")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      artifact_log = Path.join(temp_codex_home, "artifact.log")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        revision = String.duplicate("b", 40)
        write_pinned_source_revision!(mcp_cache_root, revision)
        write_runtime_artifact!(mcp_cache_root, source_revision: revision)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_MCP_BRIDGE_MODE", "direct_stdio"},
              {"SYMPP_REPO_ROOT", ""},
              {"SYMPP_FAKE_ARTIFACT_LOG", artifact_log}
            ]
          )

        assert status != 0
        assert output =~ "artifact_direct_stdio_unsupported"
        refute File.exists?(artifact_log)
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher rejects invalid explicit repo root before artifact fallback" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-invalid-explicit-root")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      invalid_root = Path.join(temp_codex_home, "not-a-checkout")

      try do
        File.mkdir_p!(invalid_root)
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        revision = String.duplicate("b", 40)
        write_pinned_source_revision!(mcp_cache_root, revision)
        write_runtime_artifact!(mcp_cache_root, source_revision: revision)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_REPO_ROOT", invalid_root}
            ]
          )

        assert status != 0
        assert output =~ "SYMPP_REPO_ROOT does not look like a Symphony++ checkout"
        refute output =~ "Symphony++ MCP launcher validation passed."
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher validate-only treats downloadable artifacts as launchable" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-validate-selected")

    if powershell && windows?() do
      write_minimal_marketplace_source(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        revision = String.duplicate("b", 40)
        write_pinned_source_revision!(mcp_cache_root, revision)
        write_runtime_artifact!(mcp_cache_root, source_revision: revision)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MIX", Path.join(temp_codex_home, "missing-mix.cmd")},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status == 0, output
        assert output =~ "artifact_downloading:"
        assert output =~ "artifact_extracting:"
        assert output =~ "runtimeMode: artifact"
        assert output =~ "artifactStatus: artifact_selected"
        assert output =~ "artifactDetail: cache_prepared"
        assert output =~ "sourceFallback: disabled"
        refute output =~ "runtimeMode: blocked"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher ignores stale source marker for self-contained artifacts" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-stale-installed-marker")

    if powershell && windows?() do
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      File.write!(Path.join(marketplace_root, "elixir/WORKFLOW.md"), "workflow: test\n")
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      stale_revision = String.duplicate("a", 40)
      current_revision = String.duplicate("b", 40)

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_pinned_source_revision!(mcp_cache_root, stale_revision)
        write_runtime_artifact!(mcp_cache_root, source_revision: current_revision, entrypoint: "start-runtime.ps1")

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MIX", Path.join(temp_codex_home, "missing-mix.cmd")},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status == 0, output
        assert output =~ "runtimeMode: artifact"
        assert output =~ "artifactStatus: artifact_selected"
        assert normalize_path_fragment(output) =~ "reporoot: artifact-only"
        assert normalize_path_fragment(output) =~ "/#{String.slice(current_revision, 0, 12)}/"
        refute normalize_path_fragment(output) =~ "/#{String.slice(stale_revision, 0, 12)}/"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end
end
