Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  alias SymphonyElixir.SymphonyPlusPlus.MCP.Server

  @tag :ci_slow
  test "lifecycle diagnostic explains default skill visible but MCP companion not enabled" do
    powershell =
      System.find_executable("powershell.exe") || System.find_executable("pwsh") ||
        System.find_executable("powershell")

    temp_codex_home =
      Path.join(
        System.tmp_dir!(),
        "sympp-plugin-readiness-default-only-#{System.unique_integer([:positive])}"
      )

    if powershell do
      default_manifest_path =
        plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])

      companion_manifest_path =
        plugin_cache_path(
          temp_codex_home,
          ["local", ".codex-plugin", "plugin.json"],
          "symphony-plus-plus-mcp"
        )

      companion_mcp_path =
        plugin_cache_path(temp_codex_home, ["local", ".mcp.json"], "symphony-plus-plus-mcp")

      try do
        File.mkdir_p!(Path.dirname(default_manifest_path))

        File.write!(
          default_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus", "version" => @plugin_version})
        )

        File.mkdir_p!(Path.dirname(companion_manifest_path))

        File.write!(
          companion_manifest_path,
          Jason.encode!(%{
            "name" => "symphony-plus-plus-mcp",
            "version" => @plugin_version,
            "mcpServers" => "./.mcp.json"
          })
        )

        File.write!(companion_mcp_path, command_mcp_config_json())

        File.write!(
          Path.join(temp_codex_home, "config.toml"),
          """
          [plugins."symphony-plus-plus@jonat-local"]
          enabled = true
          """
        )

        {json_output, json_status} =
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

        assert json_status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["overall_status"] == "plugin_cache_stale"
        assert readiness["solo_session"]["status"] == "default_plugin_cache_stale"
        assert readiness["workrequest_mcp"]["status"] == "companion_installed_not_enabled"

        assert readiness["workrequest_mcp"]["companion_config_key"] ==
                 "symphony-plus-plus-mcp@jonat-local"

        upgrade_action =
          Enum.find(readiness["next_actions"], &(&1["code"] == "upgrade_mcp_companion_cache"))

        assert upgrade_action
        assert_scoped_marketplace_upgrade!(upgrade_action["command"], temp_codex_home, "jonat-local")
        refute Enum.any?(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))
        assert readiness["generic_review_boundary"] =~ "generic worker"

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
              "-Doctor"
            ],
            stderr_to_stdout: true
          )

        assert doctor_status == 0, doctor_output
        assert doctor_output =~ "overall: plugin_cache_stale"
        assert doctor_output =~ "config key: symphony-plus-plus-mcp@jonat-local"
        assert doctor_output =~ "upgrade_mcp_companion_cache"
        assert doctor_output =~ "restart or reload the dedicated MCP-enabled session"
        assert doctor_output =~ "Keep symphony-plus-plus-mcp out of generic worker"
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  @tag :ci_slow
  test "lifecycle diagnostic self-test covers enable command TOML mutation shapes" do
    powershell =
      System.find_executable("powershell.exe") || System.find_executable("pwsh") ||
        System.find_executable("powershell")

    if powershell do
      {output, status} =
        System.cmd(
          powershell,
          ["-NoProfile", "-File", @plugin_lifecycle_diagnostic_path, "-SelfTest"],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "diagnose-mcp-lifecycle self-test passed."
    end
  end

  @tag :ci_slow
  test "HTTP MCP smoke self-test covers source revision validation" do
    powershell =
      System.find_executable("powershell.exe") || System.find_executable("pwsh") ||
        System.find_executable("powershell")

    if powershell do
      {output, status} =
        System.cmd(
          powershell,
          ["-NoProfile", "-File", @smoke_script_path, "-SelfTest"],
          stderr_to_stdout: true
        )

      assert status == 0, output

      assert output =~
               "PowerShell header normalization, source revision, redaction, and bound argument validation self-test passed."
    end
  end

  test "high-concurrency gate keeps its fast package contract" do
    powershell =
      System.find_executable("pwsh") || System.find_executable("powershell.exe") ||
        System.find_executable("powershell")

    if powershell do
      test_script =
        Path.join(
          @repo_root,
          "plugins/symphony-plus-plus-mcp/tests/end-to-end/run-performance-gate-tests.ps1"
        )

      {output, status} =
        System.cmd(powershell, ["-NoProfile", "-File", test_script], stderr_to_stdout: true)

      assert status == 0, output

      assert output =~
               "Performance gate parsing, structured output, threshold failures, and cutover contract passed."
    end
  end

  test "MCP contract manifest pins the server-reported fingerprint" do
    fingerprint = Server.mcp_contract_identity()["fingerprint"]
    contract = @contract_path |> File.read!() |> Jason.decode!()

    assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    assert contract["mcp_contract_fingerprint"] == fingerprint
  end
end
