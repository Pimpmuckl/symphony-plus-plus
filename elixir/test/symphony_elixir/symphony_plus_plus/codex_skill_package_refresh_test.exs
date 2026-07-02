Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageRefreshTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @tag :ci_slow
  test "refresh script installs the repo-local plugin into the requested Codex home" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")

    if powershell do
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

        snapshot_root = Path.join([temp_codex_home, ".tmp", "marketplaces", @plugin_marketplace_name])
        assert File.exists?(Path.join(snapshot_root, "elixir/mix.exs"))
        assert File.exists?(Path.join(snapshot_root, "scripts/refresh-local-plugin.ps1"))
        assert File.exists?(Path.join(snapshot_root, "plugins/symphony-plus-plus/.codex-plugin/plugin.json"))
        assert File.exists?(Path.join(snapshot_root, "plugins/symphony-plus-plus-mcp/.codex-plugin/plugin.json"))

        assert Path.join(snapshot_root, ".codex-marketplace-install.json") |> File.read!() |> Jason.decode!() |> Map.fetch!("source") ==
                 "developer_checkout"

        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"]))
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"], "symphony-plus-plus-mcp"))

        for cache_name <- [@plugin_version] do
          refreshed_manifest_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"])
          refreshed_mcp_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"])
          refreshed_icon_path = published_plugin_cache_path(temp_codex_home, [cache_name, "assets", "splusplus-logo.png"])
          default_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills-default", "symphony-solo-session", "SKILL.md"])
          default_worker_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills-default", "symphony-worker", "SKILL.md"])
          default_coordinator_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills-default", "symphony-coordinator", "SKILL.md"])
          root_skills_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills"])
          source_hint_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"])
          generated_marker_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-generated-cache"])

          refreshed_manifest = refreshed_manifest_path |> File.read!() |> Jason.decode!()
          assert refreshed_manifest["name"] == "symphony-plus-plus"
          assert refreshed_manifest["version"] == @plugin_version
          assert refreshed_manifest["skills"] == "./skills-default/"
          refute Map.has_key?(refreshed_manifest, "mcpServers")
          assert refreshed_manifest["interface"]["composerIcon"] == "./assets/splusplus-logo.png"
          assert refreshed_manifest["interface"]["logo"] == "./assets/splusplus-logo.png"
          assert File.read!(refreshed_icon_path) == File.read!(@plugin_icon_path)
          assert File.read!(default_skill_path) == File.read!(@plugin_default_solo_skill_path)
          assert File.read!(default_worker_skill_path) == File.read!(@plugin_default_worker_skill_path)
          assert File.read!(default_coordinator_skill_path) == File.read!(@plugin_default_coordinator_skill_path)
          refute File.exists?(root_skills_path)
          refute File.exists?(refreshed_mcp_path)
          refute File.exists?(source_hint_path)
          assert File.read!(generated_marker_path) =~ "generated_by=refresh-local-plugin.ps1"
        end

        for cache_name <- [@plugin_version] do
          mcp_manifest_path =
            published_plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

          mcp_config_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"], "symphony-plus-plus-mcp")
          mcp_icon_path = published_plugin_cache_path(temp_codex_home, [cache_name, "assets", "splusplus-logo.png"], "symphony-plus-plus-mcp")
          mcp_solo_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-solo-session", "SKILL.md"], "symphony-plus-plus-mcp")
          mcp_base_worker_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-worker", "SKILL.md"], "symphony-plus-plus-mcp")
          mcp_base_coordinator_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-coordinator", "SKILL.md"], "symphony-plus-plus-mcp")
          mcp_work_package_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-work-package", "SKILL.md"], "symphony-plus-plus-mcp")
          mcp_architect_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-architect", "SKILL.md"], "symphony-plus-plus-mcp")
          mcp_manifest = mcp_manifest_path |> File.read!() |> Jason.decode!()
          mcp_config = mcp_config_path |> File.read!() |> Jason.decode!()
          assert mcp_manifest["name"] == "symphony-plus-plus-mcp"
          assert mcp_manifest["mcpServers"] == "./.mcp.json"
          assert mcp_manifest["interface"]["composerIcon"] == "./assets/splusplus-logo.png"
          assert mcp_manifest["interface"]["logo"] == "./assets/splusplus-logo.png"
          assert File.read!(mcp_icon_path) == File.read!(@plugin_icon_path)
          assert File.read!(mcp_solo_skill_path) == File.read!(@mcp_plugin_solo_skill_path)
          assert File.read!(mcp_base_worker_skill_path) == File.read!(@mcp_plugin_worker_skill_path)
          assert File.read!(mcp_base_coordinator_skill_path) == File.read!(@mcp_plugin_coordinator_skill_path)
          assert File.read!(mcp_work_package_skill_path) == File.read!(@mcp_plugin_skill_path)
          assert File.read!(mcp_architect_skill_path) == File.read!(@mcp_plugin_architect_skill_path)

          assert get_in(documented_mcp_server_map(mcp_config), ["symphony_plus_plus", "command"]) == "cmd.exe"
          assert get_in(documented_mcp_server_map(mcp_config), ["symphony_plus_plus", "cwd"]) == "."
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  @tag :ci_slow
  test "refresh script validates installed default cache wrapper from cache roots" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)

      try do
        expected_version =
          @plugin_manifest_path
          |> File.read!()
          |> Jason.decode!()
          |> Map.fetch!("version")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @refresh_script_path,
              "-CodexHome",
              temp_codex_home,
              "-PluginName",
              "symphony-plus-plus",
              "-ValidateInstalledCache"
            ],
            stderr_to_stdout: true,
            env: [{"SYMPP_LAUNCHER", "direct"}, {"SYMPP_MIX", fake_mix}]
          )

        assert status == 0, output
        assert output =~ "Mix 1.99.0 test"
        assert output =~ "Symphony++ Solo Session wrapper validation passed."
        assert output =~ "Validated installed Symphony++ plugin cache:"
        assert output =~ "cache: #{expected_version}"

        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"]))
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"], "symphony-plus-plus-mcp"))

        for cache_name <- [expected_version] do
          source_hint_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"])
          generated_marker_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-generated-cache"])
          refute File.exists?(source_hint_path)
          assert File.read!(generated_marker_path) =~ "generated_by=refresh-local-plugin.ps1"
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end

  test "Solo wrapper ignores sibling installed cache hints without marketplace or explicit override" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-solo-cache-hints")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)
      default_cache_root = published_plugin_cache_path(temp_codex_home, ["1.0.0"])
      companion_hint_path = published_plugin_cache_path(temp_codex_home, ["1.0.0", ".sympp-source-root"], "symphony-plus-plus-mcp")
      wrapper_path = Path.join(default_cache_root, "scripts/sympp-solo.ps1")

      try do
        File.mkdir_p!(Path.dirname(wrapper_path))
        File.cp!(@plugin_solo_script_path, wrapper_path)
        File.cp!(Path.join(Path.dirname(@plugin_solo_script_path), "sympp-launcher-runtime.ps1"), Path.join(Path.dirname(wrapper_path), "sympp-launcher-runtime.ps1"))
        File.mkdir_p!(Path.dirname(companion_hint_path))
        File.write!(companion_hint_path, "#{@repo_root}\n")

        {output, status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", wrapper_path, "-ValidateOnly"],
            cd: temp_codex_home,
            stderr_to_stdout: true,
            env: [{"SYMPP_LAUNCHER", "direct"}, {"SYMPP_MIX", fake_mix}, {"SYMPP_REPO_ROOT", ""}]
          )

        assert status != 0
        assert output =~ "Cannot infer the Symphony++ runtime source"

        {override_output, override_status} =
          System.cmd(
            powershell,
            ["-NoProfile", "-File", wrapper_path, "-ValidateOnly"],
            cd: temp_codex_home,
            stderr_to_stdout: true,
            env: [{"SYMPP_LAUNCHER", "direct"}, {"SYMPP_MIX", fake_mix}, {"SYMPP_REPO_ROOT", @repo_root}]
          )

        assert override_status == 0, override_output
        assert override_output =~ "Symphony++ Solo Session wrapper validation passed."
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end
end

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageRefreshInstallValidationTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @tag :ci_slow
  @tag timeout: 120_000
  test "refresh script installs and validates the opt-in MCP plugin" do
    powershell = System.find_executable("pwsh")
    temp_codex_home = unique_temp_path("sympp-plugin-mcp-refresh")

    if powershell do
      fake_mix = fake_mix_executable(temp_codex_home)

      try do
        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @refresh_script_path,
              "-PluginName",
              "symphony-plus-plus-mcp",
              "-CodexHome",
              temp_codex_home,
              "-ValidateInstalledCache"
            ],
            stderr_to_stdout: true,
            env: [{"SYMPP_LAUNCHER", "direct"}, {"SYMPP_MIX", fake_mix}]
          )

        assert status == 0, output
        assert output =~ "Mix 1.99.0 test"
        assert output =~ "Symphony++ MCP launcher validation passed."
        assert output =~ "Symphony++ Solo Session wrapper validation passed."
        assert output =~ "Validated installed Symphony++ plugin cache:"
        assert output =~ "cache: #{@plugin_version}"
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"], "symphony-plus-plus-mcp"))

        for cache_name <- [@plugin_version] do
          manifest_path =
            published_plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"], "symphony-plus-plus-mcp")

          source_hint_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"], "symphony-plus-plus-mcp")

          manifest = manifest_path |> File.read!() |> Jason.decode!()
          assert manifest["name"] == "symphony-plus-plus-mcp"
          assert manifest["mcpServers"] == "./.mcp.json"
          refute File.exists?(source_hint_path)
          assert File.exists?(Path.join([temp_codex_home, ".tmp", "marketplaces", @plugin_marketplace_name, "elixir", "mise.toml"]))

          for skill <- ~w(symphony-solo-session symphony-worker symphony-coordinator symphony-work-package symphony-architect) do
            assert File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, "skills", skill, "SKILL.md"], "symphony-plus-plus-mcp"))
          end
        end
      after
        File.rm_rf!(temp_codex_home)
      end
    end
  end
end

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageRefreshGeneratedCacheTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  @tag :ci_slow
  test "refresh script prunes generated local cache and overlays manifest-version cache" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh")

    if powershell do
      for cache_name <- ["local", @plugin_version] do
        stale_manifest_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".codex-plugin", "plugin.json"])
        stale_mcp_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"])
        stale_root_solo_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-solo-session", "SKILL.md"])
        stale_root_architect_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-architect", "SKILL.md"])
        stale_mcp_solo_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-solo-session", "SKILL.md"], "symphony-plus-plus-mcp")
        stale_mcp_worker_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-worker", "SKILL.md"], "symphony-plus-plus-mcp")
        stale_mcp_coordinator_skill_path = published_plugin_cache_path(temp_codex_home, [cache_name, "skills", "symphony-coordinator", "SKILL.md"], "symphony-plus-plus-mcp")
        marker_path = published_plugin_cache_path(temp_codex_home, [cache_name, "operator-marker", "keep.txt"])
        source_hint_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"])
        mcp_source_hint_path = published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"], "symphony-plus-plus-mcp")

        File.mkdir_p!(Path.dirname(stale_manifest_path))
        File.write!(stale_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "stale"}))
        File.write!(stale_mcp_path, Jason.encode!(%{"mcpServers" => %{}}))
        File.write!(source_hint_path, "C:/sympp/generated\n")
        File.mkdir_p!(Path.dirname(stale_root_solo_skill_path))
        File.write!(stale_root_solo_skill_path, "stale duplicate skill")
        File.mkdir_p!(Path.dirname(stale_root_architect_skill_path))
        File.write!(stale_root_architect_skill_path, "stale default architect skill")
        File.mkdir_p!(Path.dirname(stale_mcp_solo_skill_path))
        File.write!(stale_mcp_solo_skill_path, "stale mcp solo duplicate")
        File.mkdir_p!(Path.dirname(stale_mcp_worker_skill_path))
        File.write!(stale_mcp_worker_skill_path, "stale mcp worker duplicate")
        File.mkdir_p!(Path.dirname(stale_mcp_coordinator_skill_path))
        File.write!(stale_mcp_coordinator_skill_path, "stale mcp coordinator duplicate")
        File.write!(mcp_source_hint_path, "C:/sympp/generated\n")
        File.mkdir_p!(Path.dirname(marker_path))
        File.write!(marker_path, "preserve #{cache_name}")
      end

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
        assert output =~ "Removed stale generated Symphony++ local plugin cache"
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"]))
        refute File.exists?(published_plugin_cache_path(temp_codex_home, ["local"], "symphony-plus-plus-mcp"))

        for cache_name <- [@plugin_version] do
          manifest =
            temp_codex_home
            |> published_plugin_cache_path([cache_name, ".codex-plugin", "plugin.json"])
            |> File.read!()
            |> Jason.decode!()

          assert manifest["version"] == @plugin_version
          refute Map.has_key?(manifest, "mcpServers")
          refute File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, ".mcp.json"]))
          refute File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, "skills"]))
          assert File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, "skills-default", "symphony-solo-session", "SKILL.md"]))
          assert File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, "skills-default", "symphony-worker", "SKILL.md"]))
          assert File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, "skills-default", "symphony-coordinator", "SKILL.md"]))
          refute File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"]))
          refute File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, ".sympp-source-root"], "symphony-plus-plus-mcp"))

          for skill <- ~w(symphony-solo-session symphony-worker symphony-coordinator symphony-work-package symphony-architect) do
            assert File.exists?(published_plugin_cache_path(temp_codex_home, [cache_name, "skills", skill, "SKILL.md"], "symphony-plus-plus-mcp"))
          end

          assert File.read!(published_plugin_cache_path(temp_codex_home, [cache_name, "operator-marker", "keep.txt"])) ==
                   "preserve #{cache_name}"
        end
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end

  @tag :ci_slow
  test "refresh script fails when an unmarked local cache could shadow the versioned install" do
    powershell = System.find_executable("powershell.exe") || System.find_executable("pwsh") || System.find_executable("powershell")
    temp_codex_home = unique_temp_path("sympp-plugin-refresh-unmarked-local")

    if powershell do
      unmarked_manifest_path = published_plugin_cache_path(temp_codex_home, ["local", ".codex-plugin", "plugin.json"])

      try do
        File.mkdir_p!(Path.dirname(unmarked_manifest_path))
        File.write!(unmarked_manifest_path, Jason.encode!(%{"name" => "symphony-plus-plus", "version" => "stale"}))

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              @refresh_script_path,
              "-PluginName",
              "symphony-plus-plus",
              "-CodexHome",
              temp_codex_home
            ],
            stderr_to_stdout: true
          )

        assert status != 0
        assert output =~ "Unmarked local plugin cache entry still exists"
        assert File.exists?(unmarked_manifest_path)
        assert File.exists?(published_plugin_cache_path(temp_codex_home, [@plugin_version, ".codex-plugin", "plugin.json"]))
      after
        File.rm_rf(temp_codex_home)
      end
    end
  end
end

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

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageRefreshContractTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  test "template skill mirrors installable skill metadata" do
    skill = File.read!(@skill_path)
    template_skill = File.read!(@template_skill_path)

    assert frontmatter(skill) == frontmatter(template_skill)

    for file <- ["worker_prompt.md", "mcp_wiring.md", "handoff.md"] do
      assert File.exists?(Path.join(@template_references_dir, file))
    end
  end

  test "handoff docs include skill installation and MCP setup" do
    handoff = File.read!(@handoff_path)
    runbook = File.read!(@runbook_path)

    for content <- [handoff, runbook] do
      assert content =~ ".codex/skills/symphony-work-package/"
      assert content =~ "plugins/symphony-plus-plus-mcp/"
      assert content =~ "mcp_wiring.md"
      assert content =~ "templates/worker_agent_prompt.md"
    end
  end

  test "MCP contract lists the current worker tools" do
    contract =
      @contract_path
      |> File.read!()
      |> Jason.decode!()

    actual_tools = get_in(contract, ["discovery_policy", "unbound_schema_sets", "worker_tools"])
    bound_worker_tools = get_in(contract, ["discovery_policy", "bound_worker_tools"]) -- ["sympp.health", "release_current_assignment"]

    assert actual_tools == @worker_tools
    assert bound_worker_tools == @worker_tools
    refute "request_context" in actual_tools
  end

  test "MCP contract and worker prompts align on ledger local claim inputs" do
    contract =
      @contract_path
      |> File.read!()
      |> Jason.decode!()

    worker_claim = get_in(contract, ["claim_policy", "worker_claim"])
    tool_schemas = Map.new(contract["tool_schemas"], &{&1["name"], &1})
    claim_tool = Map.fetch!(tool_schemas, "claim_local_assignment")

    assert worker_claim["tool"] == "claim_local_assignment"
    assert worker_claim["required_arguments"] == ["work_package_id"]

    assert worker_claim["optional_arguments"] == ["claimed_by"]

    assert claim_tool["required_arguments"] == [
             "work_package_id"
           ]

    assert claim_tool["optional_arguments"] == ["claimed_by"]

    assert get_in(contract, ["claim_policy", "reclaim_policy"]) =~ "Stale leases may be reclaimed"
    assert get_in(contract, ["claim_policy", "secret_policy"]) =~ "do not require raw grant secrets"

    prompt = File.read!(@template_prompt_path)

    for marker <- [
          "WorkPackage: <WORK_PACKAGE_ID>",
          ~s({"work_package_id":"<WORK_PACKAGE_ID>"}),
          "Include `claimed_by` only when"
        ] do
      assert prompt =~ marker
    end

    refute prompt =~ "claimed_by: <stable-worker-identity>"
  end

  test "MCP contract enum constraints mirror runtime values" do
    contract =
      @contract_path
      |> File.read!()
      |> Jason.decode!()

    tool_schemas = Map.new(contract["tool_schemas"], &{&1["name"], &1})

    assert get_in(tool_schemas, ["record_work_request_decision", "argument_constraints", "source_type"]) ==
             DecisionLogEntry.source_types()

    assert get_in(tool_schemas, ["add_work_request_planned_slice", "argument_constraints", "work_package_kind"]) ==
             WorkPackage.planned_slice_kinds()
  end
end
