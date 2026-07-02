Code.require_file("plugin_launcher_artifact_selection_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.PluginLauncherArtifactSelectionArtifactCacheTest do
  use SymphonyElixir.SymphonyPlusPlus.PluginLauncherArtifactSelectionCase
  @moduletag :ci_slow

  test "installed MCP launcher accepts wrapper artifact without workflow file" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-no-workflow")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      revision = String.duplicate("b", 40)

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_pinned_source_revision!(mcp_cache_root, revision)

        write_runtime_artifact!(mcp_cache_root,
          source_revision: revision,
          entrypoint: "start-runtime.ps1",
          bundled_workflow?: false
        )

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
        assert output =~ "sourceFallback: disabled"
        refute output =~ "workflow_missing"
        refute output =~ "artifact_workflow_missing"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher selects artifact when source revision is unavailable" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-no-source-revision")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_runtime_artifact!(mcp_cache_root, source_revision: nil)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status == 0, output
        assert output =~ "runtimeMode: artifact"
        assert output =~ "artifactStatus: artifact_selected"
        assert output =~ "artifactDetail: cache_prepared"
        assert output =~ "sourceFallback: disabled"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher rejects pluginless artifact when source revision is unavailable" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-no-plugin-identity")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_runtime_artifact!(mcp_cache_root, source_revision: nil, plugin_identity: :omit)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status != 0
        assert output =~ "artifactDetail=channel_not_ready"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher selects matching-contract artifact with different source revision" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-source-mismatch-contract-match")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      installed_revision = String.duplicate("b", 40)
      artifact_revision = String.duplicate("a", 40)

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_pinned_source_revision!(mcp_cache_root, installed_revision)
        write_runtime_artifact!(mcp_cache_root, source_revision: artifact_revision)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status == 0, output
        assert output =~ "runtimeMode: artifact"
        assert output =~ "artifactStatus: artifact_selected"
        assert normalize_path_fragment(output) =~ "/#{String.slice(artifact_revision, 0, 12)}/"
        refute normalize_path_fragment(output) =~ "/#{String.slice(installed_revision, 0, 12)}/"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end
end
