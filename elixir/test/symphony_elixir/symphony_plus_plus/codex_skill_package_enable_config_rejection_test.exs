Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageEnableConfigRejectionTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @moduletag :ci_slow

  test "enable command refuses unsupported inline-table enabled shapes without config mutation" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")

    config = """
    [plugins]
    "symphony-plus-plus-mcp@jonat-local" = { note = { enabled = false } }
    """

    if powershell do
      temp_codex_home = unique_temp_path("sympp-plugin-enable-unsupported-inline")

      try do
        write_activation_cache(temp_codex_home, "jonat-local")
        File.mkdir_p!(temp_codex_home)
        File.write!(Path.join(temp_codex_home, "config.toml"), config)

        {doctor_output, doctor_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-SkipProcessScan",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert doctor_status == 0, doctor_output
        readiness = doctor_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["overall_status"] == "mcp_companion_config_entry_unsupported"
        assert readiness["workrequest_mcp"]["status"] == "companion_config_entry_unsupported"

        assert Enum.any?(
                 readiness["next_actions"],
                 &(&1["code"] == "rewrite_mcp_companion_config_entry")
               )

        refute Enum.any?(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-EnableMcpCompanion"
            ],
            stderr_to_stdout: true
          )

        assert status != 0
        assert normalize_prose(output) =~ "Target plugin inline table contains no supported enabled = true/false entry"
        assert normalize_newlines(File.read!(Path.join(temp_codex_home, "config.toml"))) == normalize_newlines(config)
        assert config_backups(temp_codex_home) == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  test "diagnostic rejects duplicate companion enabled keys before enable command" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-enable-duplicate-enabled-#{System.unique_integer([:positive])}")

    config = """
    [plugins."symphony-plus-plus-mcp@jonat-local"]
    enabled = false
    enabled = true
    """

    if powershell do
      try do
        write_activation_cache(temp_codex_home, "jonat-local")
        File.mkdir_p!(temp_codex_home)
        File.write!(Path.join(temp_codex_home, "config.toml"), config)

        {doctor_output, doctor_status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert doctor_status == 0, doctor_output
        readiness = doctor_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["overall_status"] == "mcp_companion_config_entry_unsupported"
        assert readiness["workrequest_mcp"]["status"] == "companion_config_entry_unsupported"

        assert Enum.any?(
                 readiness["next_actions"],
                 &(&1["code"] == "rewrite_mcp_companion_config_entry")
               )

        refute Enum.any?(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @plugin_lifecycle_diagnostic_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-EnableMcpCompanion"
            ],
            stderr_to_stdout: true
          )

        assert status != 0
        assert normalize_prose(output) =~ "multiple enabled entries"
        assert normalize_newlines(File.read!(Path.join(temp_codex_home, "config.toml"))) == normalize_newlines(config)
        assert config_backups(temp_codex_home) == []
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end
