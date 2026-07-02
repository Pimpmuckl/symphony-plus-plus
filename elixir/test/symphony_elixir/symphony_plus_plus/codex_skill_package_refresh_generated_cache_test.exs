Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageRefreshGeneratedCacheTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @tag :ci_slow
  test "refresh script prunes generated local cache and overlays manifest-version cache" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")

    if powershell do
      for cache_name <- ["local", @plugin_version] do
        stale_manifest_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"])
        stale_mcp_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"])
        stale_root_solo_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-solo-session", "SKILL.md"])
        stale_root_architect_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-architect", "SKILL.md"])
        stale_mcp_solo_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-solo-session", "SKILL.md"], "symphony-plus-plus-mcp")
        stale_mcp_worker_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-worker", "SKILL.md"], "symphony-plus-plus-mcp")
        stale_mcp_coordinator_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-coordinator", "SKILL.md"], "symphony-plus-plus-mcp")
        marker_path = published_plugin_cache_path(temp_codex_home, [cache_name, "operator-marker", "keep.txt"])
        source_hint_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"])
        mcp_source_hint_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"], "symphony-plus-plus-mcp")

        File.mkdir_p!(Path.dirname(stale_manifest_path))
        File.write!(stale_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "stale"}))
        File.write!(stale_mcp_path, Jason.encode!(%{"mcpServers" => %{}}))
        File.write!(source_hint_path, "C:/sympp/generated\n")
        File.mkdir_p!(Path.dirname(stale_root_solo_skill_path))
        File.write!(stale_root_solo_skill_path, "stale duplicate skill")
        File.mkdir_p!(Path.dirname(stale_root_architect_skill_path))
        File.write!(stale_root_architect_skill_path, "stale default architect skill")
        File.mkdir_p!(Path.dirname(stale_mcp_solo_skill_path))
        File.write!(stale_mcp_solo_skill_path, "stale mcp solo duplicate")
        File.mkdir_p!(Path.dirname(stale_mcp_worker_skill_path))
        File.write!(stale_mcp_worker_skill_path, "stale mcp worker duplicate")
        File.mkdir_p!(Path.dirname(stale_mcp_coordinator_skill_path))
        File.write!(stale_mcp_coordinator_skill_path, "stale mcp coordinator duplicate")
        File.write!(mcp_source_hint_path, "C:/sympp/generated\n")
        File.mkdir_p!(Path.dirname(marker_path))
        File.write!(marker_path, "preserve #{cache_name}")
      end

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
        assert output =~ "Removed stale generated Symphony++ local plugin cache"
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"]))
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"], "symphony-plus-plus-mcp"))

        for cache_name <- [@plugin_version] do
          manifest =
            temp_codex_home
            |> published_plugin_cache_path([cache_name, ".codex-plugin", "plugin.json"])
            |> File.read!()
            |> Jason.decode!()

          assert manifest["version"] == @plugin_version
          refute Map.has_key?(manifest, "mcpServers")
          refute File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"]))
          refute File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, "skills"]))
          assert File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, "skills-default", "symphony-solo-session", "SKILL.md"]))
          assert File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, "skills-default", "symphony-worker", "SKILL.md"]))
          assert File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, "skills-default", "symphony-coordinator", "SKILL.md"]))
          refute File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"]))
          refute File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"], "symphony-plus-plus-mcp"))

          for skill <- ~w(symphony-solo-session symphony-worker symphony-coordinator symphony-work-package symphony-architect) do
            assert File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, "skills", skill, "SKILL.md"], "symphony-plus-plus-mcp"))
          end

          assert File.read!(published_plugin_cache_path(temp_codex_home, [cache_name, "operator-marker", "keep.txt"])) ==
                   "preserve #{cache_name}"
        end
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end
