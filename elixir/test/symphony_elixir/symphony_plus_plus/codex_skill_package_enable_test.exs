Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageEnableTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @moduletag :ci_slow

  test "enable command safely mutates only the MCP companion plugin config" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-enable-#{System.unique_integer([:positive])}")

    initial_config = """
    [plugins."symphony-plus-plus@jonat-local"]
    enabled = true
    note = "caf\u00e9"

    [plugins."unrelated@jonat-local"]
    enabled = false

    [mcp_servers.other]
    url = "http://127.0.0.1:9999/mcp"
    """

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
        assert result["status"] == "added_section"
        assert result["changed"] == true
        assert result["plugin_key"] == "symphony-plus-plus-mcp@jonat-local"
        assert result["restart_action"] =~ "Restart or reload"
        assert result["smoke_command"] =~ "smoke-sympp-mcp-http.ps1"
        assert result["smoke_command"] =~ "-RepoRoot"
        assert result["boundary"] =~ "generic worker"

        config = File.read!(Path.join(temp_codex_home, "config.toml"))
        assert companion_plugin_section_present?(config)
        assert normalize_newlines(config) =~ ~s([plugins."symphony-plus-plus-mcp@jonat-local"]\nenabled = true)
        assert config =~ ~s([plugins."symphony-plus-plus@jonat-local"])
        assert config =~ ~s([plugins."unrelated@jonat-local"])
        assert config =~ "[mcp_servers.other]"
        assert config =~ "caf\u00e9"
        refute config =~ "[mcp_servers.symphony_plus_plus]"

        backups = config_backups(temp_codex_home)
        assert length(backups) == 1
        assert same_path?(result["backup_path"], List.first(backups))
        assert normalize_newlines(File.read!(List.first(backups))) == normalize_newlines(initial_config)
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

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
