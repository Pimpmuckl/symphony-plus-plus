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
