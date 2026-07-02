Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageDiagnosticTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  test "diagnostic offers installed-script enable command without source checkout" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = Path.join(System.tmp_dir!(), "sympp-plugin-installed-enable-#{System.unique_integer([:positive])}")

    if powershell do
      installed_script_path = plugin_cache_path(temp_codex_home, ["local", "scripts", "diagnose-mcp-lifecycle.ps1"])

      try do
        File.mkdir_p!(Path.dirname(installed_script_path))
        copy_lifecycle_diagnostic!(installed_script_path)
        write_activation_cache(temp_codex_home, "jonat-local")

        File.write!(
          Path.join(temp_codex_home, "config.toml"),
          """
          [plugins."symphony-plus-plus@jonat-local"]
          enabled = true
          """
        )

        {json_output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              installed_script_path,
              "-CodexHome",
              temp_codex_home,
              "-MarketplaceName",
              "jonat-local",
              "-SkipProcessScan",
              "-Json"
            ],
            stderr_to_stdout: true,
            cd: temp_codex_home
          )

        assert status == 0, json_output
        readiness = json_output |> Jason.decode!() |> Map.fetch!("readiness")
        assert readiness["source_checkout"]["status"] == "not_found"

        enable_action =
          Enum.find(readiness["next_actions"], &(&1["code"] == "enable_mcp_companion"))

        assert enable_action
        assert enable_action["command"] =~ "-EnableMcpCompanion"
        assert enable_action["command"] =~ "-CodexHome"
        assert normalize_path_fragment(enable_action["command"]) =~ normalize_path_fragment(installed_script_path)
        refute enable_action["message"] =~ "-RepoRoot"
        assert Enum.any?(readiness["next_actions"], &(&1["code"] == "restart_codex_session"))
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end
