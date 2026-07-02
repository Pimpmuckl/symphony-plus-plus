Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageRefreshUnmarkedLocalCacheTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @tag :ci_slow
  test "refresh script fails when an unmarked local cache could shadow the versioned install" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh-unmarked-local")

    if powershell do
      unmarked_manifest_path = published_plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])

      try do
        File.mkdir_p!(Path.dirname(unmarked_manifest_path))
        File.write!(unmarked_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "stale"}))

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-PluginName",
              "symphony-plus-plus",
              "-CodexHome",
              temp_codex_home
            ],
            stderr_to_stdout: true
          )

        assert status != 0
        assert output =~ "Unmarked local plugin cache entry still exists"
        assert File.exists?(unmarked_manifest_path)
        assert File.exists?(published_plugin_cache_path(temp_codex_home, [@plugin_version, ".codex-plugin", "plugin.json"]))
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end
