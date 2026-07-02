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

  test "diagnostic does not advertise enable command for missing default Codex config" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    fake_home = Path.join(System.tmp_dir!(), "sympp-plugin-default-missing-#{System.unique_integer([:positive])}")
    default_codex_home = Path.join(fake_home, ".codex")

    if powershell do
      try do
        write_activation_cache(default_codex_home, "jonat-local")

        {json_output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              "~/.codex",
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true,
            env: [{"HOME", fake_home}, {"USERPROFILE", fake_home}, {"HOMEDRIVE", ""}, {"HOMEPATH", ""}]
          )

        assert status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        create_config = Enum.find(readiness["next_actions"], &(&1["code"] == "create_codex_config"))
        assert create_config["message"] =~ "Choose a dedicated Symphony++ MCP Codex home"
        refute create_config["message"] =~ "enable command below"
        assert Enum.any?(readiness["next_actions"], &(&1["code"] == "choose_dedicated_codex_home"))
        refute Enum.any?(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))
      after
        File.rm_rf(fake_home)
      end
    end
  end
end
