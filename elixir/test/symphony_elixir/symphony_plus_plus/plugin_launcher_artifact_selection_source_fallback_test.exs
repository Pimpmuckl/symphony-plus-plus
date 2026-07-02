Code.require_file("plugin_launcher_artifact_selection_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.PluginLauncherArtifactSelectionSourceFallbackTest do
  use SymphonyElixir.SymphonyPlusPlus.PluginLauncherArtifactSelectionCase

  test "source checkout MCP launcher ignores artifacts unless explicitly opted in" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-source-artifact-skip")

    if powershell && windows?() do
      fake_mix = fake_mix_executable(temp_codex_home)
      marketplace_root = write_minimal_marketplace_source(temp_codex_home)
      source_plugin_root = Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      fake_mix_log = Path.join(temp_codex_home, "fake-mix.log")
      artifact_log = Path.join(temp_codex_home, "artifact.log")

      try do
        write_runtime_artifact!(source_plugin_root, source_revision: String.duplicate("b", 40))
        script_path = Path.join(source_plugin_root, "scripts/start-sympp-mcp.ps1")

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path],
            cd: marketplace_root,
            stderr_to_stdout: true,
            env: [
              {"SYMPP_ELIXIR_SETUP_TIMEOUT_SEC", "5"},
              {"SYMPP_FAKE_ARTIFACT_LOG", artifact_log},
              {"SYMPP_FAKE_MIX_LOG", fake_mix_log},
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MCP_BRIDGE_MODE", "direct_stdio"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status == 0, output
        assert File.read!(fake_mix_log) =~ "sympp.mcp --mode stdio --repo-root"
        refute File.exists?(artifact_log)
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "artifact manifest errors degrade to explicit source fallback" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-invalid-fallback")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      write_minimal_marketplace_source(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      fake_mix_log = Path.join(temp_codex_home, "fake-mix.log")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        write_pinned_source_revision!(mcp_cache_root, @marketplace_revision)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        File.write!(Path.join(mcp_cache_root, ".sympp-runtime-artifacts.json"), "{not-json")

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_ELIXIR_SETUP_TIMEOUT_SEC", "5"},
              {"SYMPP_FAKE_MIX_LOG", fake_mix_log},
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MCP_BRIDGE_MODE", "direct_stdio"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", ""},
              {"SYMPP_SOURCE_FALLBACK", "1"}
            ]
          )

        assert status == 0, output
        assert output =~ "source_fallback_compiling"
        assert File.read!(fake_mix_log) =~ "sympp.mcp --mode stdio --repo-root"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "explicit repo root contract wins over stale artifact manifest contract" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-explicit-repo-contract")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      fake_mix_log = Path.join(temp_codex_home, "fake-mix.log")
      revision = @marketplace_revision

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        write_pinned_source_revision!(mcp_cache_root, revision)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)

        write_runtime_artifact!(mcp_cache_root,
          source_revision: revision,
          mcp_contract_fingerprint: String.duplicate("a", 64),
          manifest_contract_fingerprint: String.duplicate("a", 64)
        )

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_ELIXIR_SETUP_TIMEOUT_SEC", "5"},
              {"SYMPP_FAKE_MIX_LOG", fake_mix_log},
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_MCP_BRIDGE_MODE", "direct_stdio"},
              {"SYMPP_MIX", fake_mix},
              {"SYMPP_REPO_ROOT", @repo_root}
            ]
          )

        assert status == 0, output
        assert output =~ "source_fallback_compiling"

        assert normalize_path_fragment(File.read!(fake_mix_log)) =~
                 "--repo-root #{normalize_path_fragment(@repo_root)}"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "explicit repo root without contract fails before artifact fallback" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-explicit-repo-missing-contract")

    if powershell do
      explicit_repo_root = Path.join(temp_codex_home, "explicit-repo")
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      revision = @marketplace_revision

      try do
        File.mkdir_p!(Path.join(explicit_repo_root, "elixir"))
        File.write!(Path.join(explicit_repo_root, "elixir/mix.exs"), "defmodule ExplicitRepo.MixProject do\nend\n")

        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        write_pinned_source_revision!(mcp_cache_root, revision)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_runtime_artifact!(mcp_cache_root, source_revision: revision)

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_HOME", Path.join(temp_codex_home, "sympp-home")},
              {"SYMPP_LAUNCHER", "direct"},
              {"SYMPP_REPO_ROOT", explicit_repo_root}
            ]
          )

        assert status != 0
        assert normalize_prose(output) =~ "explicit SYMPP_REPO_ROOT contract JSON"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end
end
