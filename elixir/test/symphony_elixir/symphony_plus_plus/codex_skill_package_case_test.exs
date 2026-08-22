# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase do
  use ExUnit.CaseTemplate

  using opts do
    async? = Keyword.get(opts, :async, true)

    quote do
      use ExUnit.Case, async: unquote(async?)

      alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine
      alias SymphonyElixir.SymphonyPlusPlus.MCP.Server
      alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry

      @repo_root Path.expand("../../../../", __DIR__)
      @plugin_manifest_path Path.join(@repo_root, "plugins/symphony-plus-plus/.codex-plugin/plugin.json")
      @plugin_version @plugin_manifest_path |> File.read!() |> Jason.decode!() |> Map.fetch!("version")
      @plugin_mcp_path Path.join(@repo_root, "plugins/symphony-plus-plus/.mcp.json")
      @plugin_skills_dir Path.join(@repo_root, "plugins/symphony-plus-plus/skills")
      @plugin_legacy_skills_dir Path.join(@repo_root, "plugins/symphony-plus-plus/skills-default")
      @plugin_icon_path Path.join(@repo_root, "plugins/symphony-plus-plus/assets/splusplus-logo.png")
      @plugin_default_solo_skill_path Path.join(@repo_root, "plugins/symphony-plus-plus/skills/symphony-solo-session/SKILL.md")
      @plugin_default_worker_skill_path Path.join(@repo_root, "plugins/symphony-plus-plus/skills/symphony-worker/SKILL.md")
      @plugin_default_coordinator_skill_path Path.join(@repo_root, "plugins/symphony-plus-plus/skills/symphony-coordinator/SKILL.md")
      @plugin_solo_script_path Path.join(@repo_root, "plugins/symphony-plus-plus/scripts/sympp-solo.ps1")
      @plugin_lifecycle_diagnostic_path Path.join(@repo_root, "plugins/symphony-plus-plus/scripts/diagnose-mcp-lifecycle.ps1")
      @plugin_lifecycle_diagnostic_helper_names ~w(
          sympp-diagnostic-runtime-artifacts.ps1
          sympp-diagnostic-launcher-artifacts.ps1
          sympp-diagnostic-self-test.ps1
        )
      @mcp_plugin_manifest_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/.codex-plugin/plugin.json")
      @mcp_plugin_mcp_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/.mcp.json")
      @mcp_plugin_readme_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/README.md")
      @mcp_plugin_icon_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/assets/splusplus-logo.png")
      @mcp_plugin_skill_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/skills/symphony-work-package/SKILL.md")
      @mcp_plugin_solo_skill_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/skills/symphony-solo-session/SKILL.md")
      @mcp_plugin_worker_skill_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/skills/symphony-worker/SKILL.md")
      @mcp_plugin_coordinator_skill_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/skills/symphony-coordinator/SKILL.md")
      @mcp_plugin_architect_skill_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/skills/symphony-architect/SKILL.md")
      @mcp_plugin_start_script_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1")
      @mcp_plugin_start_cmd_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.cmd")
      @mcp_plugin_helper_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/sympp-mcp-launcher-helpers.ps1")
      @mcp_plugin_solo_script_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/sympp-solo.ps1")
      @marketplace_path Path.join(@repo_root, ".agents/plugins/marketplace.json")
      @plugin_marketplace_name "symphony-plus-plus"
      @plugin_readme_path Path.join(@repo_root, "plugins/symphony-plus-plus/README.md")
      @refresh_script_path Path.join(@repo_root, "scripts/refresh-local-plugin.ps1")
      @smoke_script_path Path.join(@repo_root, "scripts/smoke-sympp-mcp-http.ps1")
      @worker_secret_script_path Path.join(@repo_root, "scripts/sympp-worker-secret.ps1")
      @worker_secret_shell_path Path.join(@repo_root, "scripts/sympp-worker-secret.sh")
      @mcp_plugin_prompt_path Path.join(
                                @repo_root,
                                "plugins/symphony-plus-plus-mcp/skills/symphony-work-package/references/worker_prompt.md"
                              )
      @mcp_plugin_wiring_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/skills/symphony-work-package/references/mcp_wiring.md")
      @contract_path Path.join(@repo_root, "elixir/priv/symphony_plus_plus/mcp_contract.json")

      @worker_tools [
        "get_current_assignment",
        "read_context",
        "read_task_plan",
        "update_task_plan",
        "append_finding",
        "append_progress",
        "report_blocker",
        "resolve_blocker",
        "abandon",
        "add_comment",
        "list_comments",
        "resolve_comment",
        "read_guidance_request",
        "attach_branch",
        "attach_pr",
        "sync_pr",
        "submit_review_package",
        "complete_review",
        "mark_ready"
      ]

      defp same_path?(left, right) do
        Path.expand(left) |> String.downcase() == Path.expand(right) |> String.downcase()
      end

      defp normalize_path_fragment(value) do
        value
        |> String.replace("\\", "/")
        |> String.downcase()
      end

      defp normalize_newlines(value) do
        String.replace(value, "\r\n", "\n")
      end

      defp normalize_prose(value) do
        value
        |> normalize_newlines()
        |> String.replace(~r/\e\[[0-9;]*m/, "")
        |> String.replace(~r/\s+\|\s+|\s+/, " ")
      end

      defp fixture_repo_root(name), do: if(windows?(), do: "C:/sympp/#{name}", else: Path.join(System.tmp_dir!(), "sympp-fixtures/#{name}"))

      defp write_source_hint!(path, repo_root), do: File.write!(path, "#{repo_root}\n")

      defp assert_scoped_marketplace_upgrade!(command, codex_home, _marketplace) do
        assert command =~ "codex plugin marketplace upgrade"
        assert command =~ "CODEX_HOME"
        assert normalize_path_fragment(command) =~ normalize_path_fragment(codex_home)
      end

      defp fake_mix_executable(temp_root) do
        path = Path.join(temp_root, if(windows?(), do: "mix.cmd", else: "mix"))
        File.mkdir_p!(Path.dirname(path))

        File.write!(path, fake_mix_script())

        unless windows?() do
          File.chmod!(path, 0o755)
        end

        path
      end

      defp fake_mix_script do
        if windows?() do
          """
          @echo off
          if "%~1"=="--version" (
            echo Mix 1.99.0 test
            exit /b 0
          )
          if "%~1"=="deps.get" if "%~2"=="--check-locked" (
            exit /b 0
          )
          if "%~1"=="sympp.solo" if "%~2"=="--help" (
            exit /b 0
          )
          echo unexpected mix args: %*
          exit /b 2
          """
        else
          """
          #!/usr/bin/env sh
          if [ "$1" = "--version" ]; then
            echo "Mix 1.99.0 test"
            exit 0
          fi
          if [ "$1" = "deps.get" ] && [ "$2" = "--check-locked" ]; then
            exit 0
          fi
          if [ "$1" = "sympp.solo" ] && [ "$2" = "--help" ]; then
            exit 0
          fi
          echo "unexpected mix args: $*" >&2
          exit 2
          """
        end
      end

      defp windows?, do: match?({:win32, _name}, :os.type())

      defp unique_temp_path(prefix) do
        Path.join(System.tmp_dir!(), "#{prefix}-#{unique_id()}")
      end

      defp unique_id do
        id = "#{System.pid()}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
        String.replace(id, ~r/[^A-Za-z0-9_.-]/, "-")
      end

      defp companion_plugin_section_present?(config) do
        Regex.match?(
          ~r/\[\s*(?:plugins|"plugins"|'plugins')\s*\.\s*(?:"symphony-plus-plus-mcp@jonat-local"|'symphony-plus-plus-mcp@jonat-local')\s*\]/,
          config
        )
      end

      defp command_mcp_config do
        %{
          "symphony_plus_plus" => %{
            "type" => "stdio",
            "command" => "cmd.exe",
            "args" => [
              "/d",
              "/s",
              "/c",
              "scripts\\start-sympp-mcp.cmd"
            ],
            "cwd" => ".",
            "startup_timeout_sec" => 360.0,
            "tool_timeout_sec" => 300.0
          }
        }
      end

      defp command_mcp_config_json, do: Jason.encode!(command_mcp_config())

      defp write_activation_cache(codex_home, marketplace_name) do
        write_activation_cache_plugin(codex_home, marketplace_name, "symphony-plus-plus")
        write_activation_cache_plugin(codex_home, marketplace_name, "symphony-plus-plus-mcp")
      end

      defp write_activation_cache_plugin(codex_home, marketplace_name, plugin_name) do
        source_root = Path.join(@repo_root, "plugins/#{plugin_name}")
        cache_root = plugin_cache_path(codex_home, ["local"], plugin_name, marketplace_name)

        File.rm_rf!(cache_root)
        File.mkdir_p!(Path.dirname(cache_root))
        File.cp_r!(source_root, cache_root)
      end

      defp copy_lifecycle_diagnostic!(target_path) do
        File.mkdir_p!(Path.dirname(target_path))
        File.cp!(@plugin_lifecycle_diagnostic_path, target_path)

        for helper_name <- @plugin_lifecycle_diagnostic_helper_names do
          File.cp!(
            Path.join(Path.dirname(@plugin_lifecycle_diagnostic_path), helper_name),
            Path.join(Path.dirname(target_path), helper_name)
          )
        end
      end

      defp config_backups(codex_home) do
        codex_home
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "config.toml.sympp-backup-"))
        |> Enum.map(&Path.join(codex_home, &1))
        |> Enum.sort()
      end

      defp documented_mcp_server_map(%{"mcpServers" => _}) do
        flunk("plugin .mcp.json must use a documented direct server map or wrapped mcp_servers shape")
      end

      defp documented_mcp_server_map(%{"mcp_servers" => server_map}), do: server_map
      defp documented_mcp_server_map(server_map), do: server_map

      defp published_plugin_cache_path(codex_home, suffix, plugin_name \\ "symphony-plus-plus") do
        plugin_cache_path(codex_home, suffix, plugin_name, @plugin_marketplace_name)
      end

      defp plugin_cache_path(codex_home, suffix, plugin_name \\ "symphony-plus-plus", marketplace_name \\ "jonat-local") do
        Path.join([codex_home, "plugins", "cache", marketplace_name, plugin_name] ++ suffix)
      end
    end
  end
end
