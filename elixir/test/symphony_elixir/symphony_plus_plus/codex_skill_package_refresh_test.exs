Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageRefreshTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @tag :ci_slow
  test "refresh script installs the repo-local plugin into the requested Codex home" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")

    if powershell do
      try do
        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-CodexHome",
              temp_codex_home
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        snapshot_root = Path.join([temp_codex_home, ".tmp", "marketplaces", @plugin_marketplace_name])
        assert File.exists?(Path.join(snapshot_root, "elixir/mix.exs"))
        assert File.exists?(Path.join(snapshot_root, "scripts/refresh-local-plugin.ps1"))
        assert File.exists?(Path.join(snapshot_root, "plugins/symphony-plus-plus/.codex-plugin/plugin.json"))
        assert File.exists?(Path.join(snapshot_root, "plugins/symphony-plus-plus-mcp/.codex-plugin/plugin.json"))

        assert Path.join(snapshot_root, ".codex-marketplace-install.json") |> File.read!() |> Jason.decode!() |> Map.fetch!("source") ==
                 "developer_checkout"

        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"]))
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"], "symphony-plus-plus-mcp"))

        for cache_name <- [@plugin_version] do
          refreshed_manifest_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"])
          refreshed_mcp_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"])
          refreshed_icon_path = published_plugin_cache_path(temp_codex_home, [cache_name, "assets", "splusplus-logo.png"])
          default_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-solo-session", "SKILL.md"])
          default_worker_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-worker", "SKILL.md"])
          default_coordinator_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-coordinator", "SKILL.md"])
          legacy_skills_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills-default"])
          source_hint_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"])
          generated_marker_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-generated-cache"])

          refreshed_manifest = refreshed_manifest_path |> File.read!() |> Jason.decode!()
          assert refreshed_manifest["name"] == "symphony-plus-plus"
          assert refreshed_manifest["version"] == @plugin_version
          assert refreshed_manifest["skills"] == "./skills/"
          refute Map.has_key?(refreshed_manifest, "mcpServers")
          assert refreshed_manifest["interface"]["composerIcon"] == "./assets/splusplus-logo.png"
          assert refreshed_manifest["interface"]["logo"] == "./assets/splusplus-logo.png"
          assert File.read!(refreshed_icon_path) == File.read!(@plugin_icon_path)
          assert File.read!(default_skill_path) == File.read!(@plugin_default_solo_skill_path)
          assert File.read!(default_worker_skill_path) == File.read!(@plugin_default_worker_skill_path)
          assert File.read!(default_coordinator_skill_path) == File.read!(@plugin_default_coordinator_skill_path)
          refute File.exists?(legacy_skills_path)
          refute File.exists?(refreshed_mcp_path)
          refute File.exists?(source_hint_path)
          assert File.read!(generated_marker_path) =~ "generated_by=refresh-local-plugin.ps1"
        end

        for cache_name <- [@plugin_version] do
          mcp_manifest_path =
            published_plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

          mcp_config_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"], "symphony-plus-plus-mcp")
          mcp_icon_path = published_plugin_cache_path(temp_codex_home, [cache_name, "assets", "splusplus-logo.png"], "symphony-plus-plus-mcp")
          mcp_solo_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-solo-session", "SKILL.md"], "symphony-plus-plus-mcp")
          mcp_base_worker_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-worker", "SKILL.md"], "symphony-plus-plus-mcp")
          mcp_base_coordinator_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-coordinator", "SKILL.md"], "symphony-plus-plus-mcp")
          mcp_work_package_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-work-package", "SKILL.md"], "symphony-plus-plus-mcp")
          mcp_architect_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-architect", "SKILL.md"], "symphony-plus-plus-mcp")
          mcp_manifest = mcp_manifest_path |> File.read!() |> Jason.decode!()
          mcp_config = mcp_config_path |> File.read!() |> Jason.decode!()
          assert mcp_manifest["name"] == "symphony-plus-plus-mcp"
          assert mcp_manifest["mcpServers"] == "./.mcp.json"
          assert mcp_manifest["interface"]["composerIcon"] == "./assets/splusplus-logo.png"
          assert mcp_manifest["interface"]["logo"] == "./assets/splusplus-logo.png"
          assert File.read!(mcp_icon_path) == File.read!(@plugin_icon_path)
          assert File.read!(mcp_solo_skill_path) == File.read!(@mcp_plugin_solo_skill_path)
          assert File.read!(mcp_base_worker_skill_path) == File.read!(@mcp_plugin_worker_skill_path)
          assert File.read!(mcp_base_coordinator_skill_path) == File.read!(@mcp_plugin_coordinator_skill_path)
          assert File.read!(mcp_work_package_skill_path) == File.read!(@mcp_plugin_skill_path)
          assert File.read!(mcp_architect_skill_path) == File.read!(@mcp_plugin_architect_skill_path)

          mcp_server = documented_mcp_server_map(mcp_config)["symphony_plus_plus"]
          assert mcp_server["type"] == "stdio"
          assert mcp_server["command"] == "cmd.exe"
          assert mcp_server["args"] == ["/d", "/s", "/c", "scripts\\start-sympp-mcp.cmd"]
          assert mcp_server["cwd"] == "."
          assert mcp_server["startup_timeout_sec"] == 360.0
          assert mcp_server["tool_timeout_sec"] == 300.0
          refute Map.has_key?(mcp_server, "url")
          refute Map.has_key?(mcp_server, "env")
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  @tag :ci_slow
  test "refresh script validates installed default cache wrapper from cache roots" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)

      try do
        expected_version =
          @plugin_manifest_path
          |> File.read!()
          |> Jason.decode!()
          |> Map.fetch!("version")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @refresh_script_path,
              "-CodexHome",
              temp_codex_home,
              "-PluginName",
              "symphony-plus-plus",
              "-ValidateInstalledCache"
            ],
            stderr_to_stdout: true,
            env: [{"SYMPP_LAUNCHER", "direct"}, {"SYMPP_MIX", fake_mix}]
          )

        assert status == 0, output
        assert output =~ "Mix 1.99.0 test"
        assert output =~ "Symphony++ Solo Session wrapper validation passed."
        assert output =~ "Validated installed Symphony++ plugin cache:"
        assert output =~ "cache: #{expected_version}"

        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"]))
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"], "symphony-plus-plus-mcp"))

        for cache_name <- [expected_version] do
          source_hint_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"])
          generated_marker_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-generated-cache"])
          refute File.exists?(source_hint_path)
          assert File.read!(generated_marker_path) =~ "generated_by=refresh-local-plugin.ps1"
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "Solo wrapper ignores sibling installed cache hints without marketplace or explicit override" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-solo-cache-hints")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      default_cache_root = published_plugin_cache_path(temp_codex_home, ["1.0.0"])
      companion_hint_path = published_plugin_cache_path(temp_codex_home, ["1.0.0", ".sympp-source-root"], "symphony-plus-plus-mcp")
      wrapper_path = Path.join(default_cache_root, "scripts/sympp-solo.ps1")

      try do
        File.mkdir_p!(Path.dirname(wrapper_path))
        File.cp!(@plugin_solo_script_path, wrapper_path)
        File.cp!(Path.join(Path.dirname(@plugin_solo_script_path), "sympp-launcher-runtime.ps1"), Path.join(Path.dirname(wrapper_path), "sympp-launcher-runtime.ps1"))
        File.mkdir_p!(Path.dirname(companion_hint_path))
        File.write!(companion_hint_path, "#{@repo_root}\n")

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", wrapper_path, "-ValidateOnly"],
            cd: temp_codex_home,
            stderr_to_stdout: true,
            env: [{"SYMPP_LAUNCHER", "direct"}, {"SYMPP_MIX", fake_mix}, {"SYMPP_REPO_ROOT", ""}]
          )

        assert status != 0
        assert output =~ "Cannot infer the Symphony++ runtime source"

        {override_output, override_status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", wrapper_path, "-ValidateOnly"],
            cd: temp_codex_home,
            stderr_to_stdout: true,
            env: [{"SYMPP_LAUNCHER", "direct"}, {"SYMPP_MIX", fake_mix}, {"SYMPP_REPO_ROOT", @repo_root}]
          )

        assert override_status == 0, override_output
        assert override_output =~ "Symphony++ Solo Session wrapper validation passed."
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end
end
