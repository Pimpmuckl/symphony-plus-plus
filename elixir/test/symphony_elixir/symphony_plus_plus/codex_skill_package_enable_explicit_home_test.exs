Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageEnableExplicitHomeTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @moduletag :ci_slow

  test "enable command requires explicit CodexHome even when CODEX_HOME is set" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-enable-implicit-home-#{System.unique_integer([:positive])}")

    config = """
    [plugins."symphony-plus-plus-mcp@jonat-local"]
    enabled = false
    """

    if powershell do
      try do
        write_activation_cache(temp_codex_home, "jonat-local")
        File.mkdir_p!(temp_codex_home)
        File.write!(Path.join(temp_codex_home, "config.toml"), config)

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-MarketplaceName",
              "jonat-local",
              "-EnableMcpCompanion"
            ],
            stderr_to_stdout: true,
            env: [{"CODEX_HOME", temp_codex_home}]
          )

        assert status != 0
        assert normalize_prose(output) =~ "without an explicit -CodexHome"
        assert normalize_newlines(File.read!(Path.join(temp_codex_home, "config.toml"))) == normalize_newlines(config)
        assert config_backups(temp_codex_home) == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end
