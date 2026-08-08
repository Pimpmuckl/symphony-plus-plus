Code.require_file("plugin_launcher_artifact_selection_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.PluginLauncherArtifactSelectionReleaseContractTest do
  use SymphonyElixir.SymphonyPlusPlus.PluginLauncherArtifactSelectionCase

  test "installed MCP launcher uses previous stable artifact while current release is still building" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-release-race-contract-match")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      installed_revision = String.duplicate("b", 40)
      published_revision = String.duplicate("a", 40)

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_pinned_source_revision!(mcp_cache_root, installed_revision)

        write_runtime_artifact!(mcp_cache_root,
          source_revision: published_revision,
          manifest_source_revision: published_revision,
          plugin_identity: %{
            "marketplace" => @plugin_marketplace_name,
            "name" => "symphony-plus-plus-mcp",
            "version" => @plugin_version,
            "packages" => ["symphony-plus-plus", "symphony-plus-plus-mcp"],
            "source_revision" => published_revision
          }
        )

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_DATABASE", ""},
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status == 0, output
        assert output =~ "runtimeMode: artifact"
        assert output =~ "artifactStatus: artifact_selected"
        assert output =~ "sourceFallback: disabled"
        assert normalize_path_fragment(output) =~ "/#{String.slice(published_revision, 0, 12)}/"
        refute normalize_path_fragment(output) =~ "/#{String.slice(installed_revision, 0, 12)}/"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher accepts matching-contract artifact across package version bumps" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-package-version-bump")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")
      installed_revision = String.duplicate("b", 40)
      published_revision = String.duplicate("a", 40)

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_pinned_source_revision!(mcp_cache_root, installed_revision)

        write_runtime_artifact!(mcp_cache_root,
          source_revision: published_revision,
          manifest_source_revision: published_revision,
          plugin_identity: %{
            "marketplace" => @plugin_marketplace_name,
            "name" => "symphony-plus-plus-mcp",
            "version" => "0.1.7",
            "packages" => ["symphony-plus-plus", "symphony-plus-plus-mcp"],
            "source_revision" => published_revision
          }
        )

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", script_path, "-ValidateOnly"],
            cd: Path.dirname(Path.dirname(script_path)),
            stderr_to_stdout: true,
            env: [
              {"SYMPP_DATABASE", ""},
              {"SYMPP_HOME", sympp_home},
              {"SYMPP_REPO_ROOT", ""}
            ]
          )

        assert status == 0, output
        assert output =~ "runtimeMode: artifact"
        assert output =~ "artifactStatus: artifact_selected"
        assert output =~ "sourceFallback: disabled"
        assert normalize_path_fragment(output) =~ "/#{String.slice(published_revision, 0, 12)}/"
        refute normalize_path_fragment(output) =~ "/#{String.slice(installed_revision, 0, 12)}/"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher reports contract mismatch before source mismatch" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-contract-mismatch")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)
        write_pinned_source_revision!(mcp_cache_root, String.duplicate("b", 40))

        write_runtime_artifact!(mcp_cache_root,
          source_revision: String.duplicate("a", 40),
          mcp_contract_fingerprint: String.duplicate("c", 64)
        )

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
        assert output =~ "artifactDetail=contract_mismatch"
        refute output =~ "source_revision_mismatch"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "installed MCP launcher rejects legacy contract marker without fingerprint" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-artifact-legacy-contract-marker")

    if powershell && windows?() do
      mcp_cache_root = plugin_cache_path(temp_codex_home, ["1.0.0"], "symphony-plus-plus-mcp")
      sympp_home = Path.join(temp_codex_home, "sympp-home")

      try do
        write_cache_manifest(mcp_cache_root, "symphony-plus-plus-mcp", mcp?: true)
        script_path = write_cached_script(mcp_cache_root, @mcp_plugin_start_script_path)

        write_runtime_artifact!(mcp_cache_root,
          source_revision: String.duplicate("a", 40),
          mcp_contract_fingerprint: :omit,
          manifest_contract_fingerprint: :omit,
          legacy_contract_manifest: true
        )

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
        assert output =~ "artifactDetail=contract_mismatch"
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end
end
