Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageEnableHomeSafetyTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @moduletag :ci_slow

  test "enable command refuses default Codex home" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")

    if powershell do
      fake_home = unique_temp_path("sympp-plugin-enable-default-home")
      fake_default_codex_home = Path.join(fake_home, ".codex")
      fake_home_env = [{"HOME", fake_home}, {"USERPROFILE", fake_home}, {"HOMEDRIVE", ""}, {"HOMEPATH", ""}]

      try do
        File.mkdir_p!(fake_default_codex_home)

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              fake_default_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-EnableMcpCompanion"
            ],
            stderr_to_stdout: true,
            env: fake_home_env
          )

        assert status != 0
        assert normalize_prose(output) =~ "Refusing to enable symphony-plus-plus-mcp in the default Codex home"
      after
        File.rm_rf(fake_home)
      end
    end
  end
end
