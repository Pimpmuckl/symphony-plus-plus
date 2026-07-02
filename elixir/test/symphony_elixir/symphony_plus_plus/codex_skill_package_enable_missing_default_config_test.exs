Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageEnableMissingDefaultConfigTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @moduletag :ci_slow

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
