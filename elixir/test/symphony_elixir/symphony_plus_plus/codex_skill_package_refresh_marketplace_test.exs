Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageRefreshMarketplaceTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @tag :ci_slow
  test "refresh script rejects unresolved marketplace source paths" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")
    marketplace_path = unique_temp_path("sympp-marketplace") <> ".json"

    if powershell do
      marketplace = %{
        name: "jonat-local",
        plugins: [
          %{
            name: "symphony-plus-plus",
            source: %{source: "local", path: "missing/symphony-plus-plus"},
            policy: %{installation: "AVAILABLE", authentication: "ON_USE"},
            category: "Coding"
          }
        ]
      }

      try do
        File.write!(marketplace_path, Jason.encode!(marketplace))

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-MarketplacePath",
              marketplace_path,
              "-CodexHome",
              temp_codex_home
            ],
            stderr_to_stdout: true
          )

        assert status != 0
        assert output =~ "Configured plugin source path"
        refute File.exists?(plugin_cache_path(temp_codex_home, []))
      after
        File.rm(marketplace_path)
        File.rm_rf(temp_codex_home)
      end
    end
  end

  @tag :ci_slow
  test "refresh script resolves repo-root relative source paths from marketplace file" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")

    marketplace_path =
      Path.join(@repo_root, "plugins/symphony-plus-plus/sympp-marketplace-test-#{unique_id()}.json")

    if powershell do
      marketplace = %{
        name: "jonat-local",
        plugins: [
          %{
            name: "symphony-plus-plus",
            source: %{source: "local", path: "./plugins/symphony-plus-plus"},
            policy: %{installation: "AVAILABLE", authentication: "ON_USE"},
            category: "Coding"
          }
        ]
      }

      try do
        File.write!(marketplace_path, Jason.encode!(marketplace))

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-MarketplacePath",
              marketplace_path,
              "-CodexHome",
              temp_codex_home
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output

        refreshed_manifest_path = plugin_cache_path(temp_codex_home, [@plugin_version, ".codex-plugin", "plugin.json"])
        refreshed_mcp_path = plugin_cache_path(temp_codex_home, [@plugin_version, ".mcp.json"])

        assert refreshed_manifest_path |> File.read!() |> Jason.decode!() |> Map.fetch!("name") == "symphony-plus-plus"
        refute File.exists?(refreshed_mcp_path)
        refute File.exists?(plugin_cache_path(temp_codex_home, ["local"]))
      after
        File.rm(marketplace_path)
        File.rm_rf(temp_codex_home)
      end
    end
  end

  @tag :ci_slow
  test "refresh script repairs incompatible generated default caches only" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")

    if powershell do
      stale_manifest_path = published_plugin_cache_path(temp_codex_home, ["0.0.9", ".codex-plugin", "plugin.json"])
      sentinel_path = published_plugin_cache_path(temp_codex_home, ["0.0.9", "already-open.txt"])
      incompatible_manifest_path = published_plugin_cache_path(temp_codex_home, ["0.1.1", ".codex-plugin", "plugin.json"])
      incompatible_mcp_path = published_plugin_cache_path(temp_codex_home, ["0.1.1", ".mcp.json"])
      incompatible_hint_path = published_plugin_cache_path(temp_codex_home, ["0.1.1", ".sympp-source-root"])
      malformed_manifest_path = published_plugin_cache_path(temp_codex_home, ["malformed-old", ".codex-plugin", "plugin.json"])
      malformed_mcp_path = published_plugin_cache_path(temp_codex_home, ["malformed-old", ".mcp.json"])
      malformed_hint_path = published_plugin_cache_path(temp_codex_home, ["malformed-old", ".sympp-source-root"])
      missing_manifest_mcp_path = published_plugin_cache_path(temp_codex_home, ["missing-manifest", ".mcp.json"])
      missing_manifest_hint_path = published_plugin_cache_path(temp_codex_home, ["missing-manifest", ".sympp-source-root"])
      manual_semver_mcp_path = published_plugin_cache_path(temp_codex_home, ["1.2.3", ".mcp.json"])
      manual_manifest_path = published_plugin_cache_path(temp_codex_home, ["manual-default", ".codex-plugin", "plugin.json"])
      manual_manifest_mcp_path = published_plugin_cache_path(temp_codex_home, ["manual-default", ".mcp.json"])
      scratch_path = published_plugin_cache_path(temp_codex_home, ["scratch", "note.txt"])
      scratch_mcp_path = published_plugin_cache_path(temp_codex_home, ["scratch", ".mcp.json"])
      File.mkdir_p!(Path.dirname(stale_manifest_path))
      File.write!(stale_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "0.0.9"}))
      File.write!(sentinel_path, "preserve")
      File.mkdir_p!(Path.dirname(incompatible_manifest_path))

      File.write!(
        incompatible_manifest_path,
        Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "0.1.1", "mcpServers" => "./.mcp.json"})
      )

      File.write!(incompatible_hint_path, "C:/sympp/generated\n")

      File.write!(
        incompatible_mcp_path,
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "pwsh",
            "args" => ["-NoProfile"],
            "cwd" => "."
          }
        })
      )

      File.mkdir_p!(Path.dirname(malformed_manifest_path))
      File.write!(malformed_manifest_path, "{")
      File.write!(malformed_hint_path, "C:/sympp/generated\n")

      File.write!(
        malformed_mcp_path,
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "pwsh",
            "args" => ["-NoProfile"],
            "cwd" => "."
          }
        })
      )

      File.mkdir_p!(Path.dirname(missing_manifest_mcp_path))
      File.write!(missing_manifest_hint_path, "C:/sympp/generated\n")

      File.write!(
        missing_manifest_mcp_path,
        Jason.encode!(%{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "pwsh",
            "args" => ["-NoProfile"],
            "cwd" => "."
          }
        })
      )

      File.mkdir_p!(Path.dirname(manual_semver_mcp_path))
      File.write!(manual_semver_mcp_path, Jason.encode!(%{"manual" => true}))
      File.mkdir_p!(Path.dirname(manual_manifest_path))

      File.write!(
        manual_manifest_path,
        Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "manual", "mcpServers" => "./.mcp.json"})
      )

      File.write!(manual_manifest_mcp_path, Jason.encode!(%{"manual" => true}))
      File.mkdir_p!(Path.dirname(scratch_path))
      File.write!(scratch_path, "do not touch")
      File.write!(scratch_mcp_path, Jason.encode!(%{"manual" => true}))

      try do
        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-CodexHome",
              temp_codex_home
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output
        assert output =~ "Repaired incompatible default Symphony++ plugin cache"

        versioned_manifest =
          published_plugin_cache_path(temp_codex_home, [@plugin_version, ".codex-plugin", "plugin.json"])
          |> File.read!()
          |> Jason.decode!()

        refute Map.has_key?(versioned_manifest, "mcpServers")
        refute File.exists?(published_plugin_cache_path(temp_codex_home, [@plugin_version, ".mcp.json"]))
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"]))

        repaired_manifest =
          published_plugin_cache_path(temp_codex_home, ["0.1.1", ".codex-plugin", "plugin.json"])
          |> File.read!()
          |> Jason.decode!()

        refute Map.has_key?(repaired_manifest, "mcpServers")
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["0.1.1", ".mcp.json"]))
        assert File.exists?(published_plugin_cache_path(temp_codex_home, ["malformed-old"]))
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["malformed-old", ".mcp.json"]))
        assert File.exists?(published_plugin_cache_path(temp_codex_home, ["missing-manifest"]))
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["missing-manifest", ".mcp.json"]))
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["0.0.9", ".mcp.json"]))
        assert File.exists?(manual_semver_mcp_path)
        manual_manifest = manual_manifest_path |> File.read!() |> Jason.decode!()
        assert Map.has_key?(manual_manifest, "mcpServers")
        assert File.exists?(manual_manifest_mcp_path)
        assert File.read!(sentinel_path) == "preserve"
        assert File.read!(scratch_path) == "do not touch"
        assert File.exists?(scratch_mcp_path)
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  @tag :ci_slow
  test "refresh script repairs stale default MCP artifacts during MCP-only refresh" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh-mcp-only")

    if powershell do
      stale_manifest_path = published_plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])
      stale_mcp_path = published_plugin_cache_path(temp_codex_home, ["local", ".mcp.json"])
      stale_hint_path = published_plugin_cache_path(temp_codex_home, ["local", ".sympp-source-root"])

      try do
        File.mkdir_p!(Path.dirname(stale_manifest_path))

        File.write!(
          stale_manifest_path,
          Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "0.1.1", "mcpServers" => "./.mcp.json"})
        )

        File.write!(stale_mcp_path, Jason.encode!(%{"symphony_plus_plus" => %{"type" => "stdio", "command" => "pwsh", "args" => ["-NoProfile"], "cwd" => "."}}))
        File.write!(stale_hint_path, "C:/sympp/generated\n")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-CodexHome",
              temp_codex_home,
              "-PluginName",
              "symphony-plus-plus-mcp"
            ],
            stderr_to_stdout: true
          )

        assert status == 0, output
        assert output =~ "Repaired incompatible default Symphony++ plugin cache"

        repaired_manifest = stale_manifest_path |> File.read!() |> Jason.decode!()
        refute Map.has_key?(repaired_manifest, "mcpServers")
        refute File.exists?(stale_mcp_path)
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"], "symphony-plus-plus-mcp"))
        assert File.exists?(published_plugin_cache_path(temp_codex_home, [@plugin_version, ".mcp.json"], "symphony-plus-plus-mcp"))
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end
