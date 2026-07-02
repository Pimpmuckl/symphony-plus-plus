Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageRefreshInstallValidationTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @tag :ci_slow
  @tag timeout: 120_000
  test "refresh script installs and validates the opt-in MCP plugin" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-mcp-refresh")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)

      try do
        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @refresh_script_path,
              "-PluginName",
              "symphony-plus-plus-mcp",
              "-CodexHome",
              temp_codex_home,
              "-ValidateInstalledCache"
            ],
            stderr_to_stdout: true,
            env: [{"SYMPP_LAUNCHER", "direct"}, {"SYMPP_MIX", fake_mix}]
          )

        assert status == 0, output
        assert output =~ "Mix 1.99.0 test"
        assert output =~ "Symphony++ MCP launcher validation passed."
        assert output =~ "Symphony++ Solo Session wrapper validation passed."
        assert output =~ "Validated installed Symphony++ plugin cache:"
        assert output =~ "cache: #{@plugin_version}"
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"], "symphony-plus-plus-mcp"))

        for cache_name <- [@plugin_version] do
          manifest_path =
            published_plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

          source_hint_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"], "symphony-plus-plus-mcp")

          manifest = manifest_path |> File.read!() |> Jason.decode!()
          assert manifest["name"] == "symphony-plus-plus-mcp"
          assert manifest["mcpServers"] == "./.mcp.json"
          refute File.exists?(source_hint_path)
          assert File.exists?(Path.join([temp_codex_home, ".tmp", "marketplaces", @plugin_marketplace_name, "elixir", "mise.toml"]))

          for skill <- ~w(symphony-solo-session symphony-worker symphony-coordinator symphony-work-package symphony-architect) do
            assert File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, "skills", skill, "SKILL.md"], "symphony-plus-plus-mcp"))
          end
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end
end
