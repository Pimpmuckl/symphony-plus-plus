Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageEnableParserSensitiveTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @moduletag :ci_slow

  test "enable command keeps parser-sensitive embedded TOML text inert" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-enable-parser-sensitive-#{System.unique_integer([:positive])}")

    initial_config =
      ~s([plugins."symphony-plus-plus-mcp@jonat-local"]\n) <>
        ~s(note = \"\"\"\n) <>
        ~s(enabled = false\n) <>
        ~s([plugins."not-a-real-section@jonat-local"]\n) <>
        ~s([mcp_servers.symphony_plus_plus]\n) <>
        ~s(\"\"\"\n)

    if powershell do
      try do
        write_activation_cache(temp_codex_home, "jonat-local")
        File.mkdir_p!(temp_codex_home)
        File.write!(Path.join(temp_codex_home, "config.toml"), initial_config)

        {json_output, status} =
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
              "-EnableMcpCompanion",
              "-Json"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, json_output
        result = Jason.decode!(json_output)
        assert result["status"] == "added_enabled"
        assert result["changed"] == true

        config = File.read!(Path.join(temp_codex_home, "config.toml"))

        assert normalize_newlines(config) =~
                 ~s(note = \"\"\"\nenabled = false\n[plugins."not-a-real-section@jonat-local"]\n[mcp_servers.symphony_plus_plus]\n\"\"\")

        {doctor_json, doctor_status} =
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

        assert doctor_status == 0, doctor_json
        doctor_summary = Jason.decode!(doctor_json)
        assert doctor_summary["codex_config"]["symphony_mcp_companion_plugin_enabled"] == true
        assert doctor_summary["codex_config"]["global_sympp_mcp_entry"] == false
        assert doctor_summary["readiness"]["workrequest_mcp"]["companion_plugin_enabled"] == true

        refute Enum.any?(
                 doctor_summary["readiness"]["next_actions"],
                 &(&1["code"] == "enable_mcp_companion")
               )
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end
