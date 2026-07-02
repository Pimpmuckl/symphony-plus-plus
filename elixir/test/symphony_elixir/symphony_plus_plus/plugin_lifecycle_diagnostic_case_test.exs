# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.PluginLifecycleDiagnosticCase do
  use ExUnit.CaseTemplate

  using _opts do
    quote do
      use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

      @marketplace_revision String.duplicate("b", 40)
      @diagnostic_runtime_artifacts_path Path.join(
                                           @repo_root,
                                           "plugins/symphony-plus-plus/scripts/sympp-diagnostic-runtime-artifacts.ps1"
                                         )

      defp write_cached_script(cache_root, source_script_path) do
        target = Path.join([cache_root, "scripts", Path.basename(source_script_path)])
        File.mkdir_p!(Path.dirname(target))
        File.cp!(source_script_path, target)

        for helper_name <-
              ~w(sympp-launcher-runtime.ps1 sympp-mcp-launcher-helpers.ps1 sympp-mcp-artifact-manifest.ps1 sympp-mcp-artifact-channel.ps1 sympp-mcp-artifact-runtime.ps1 sympp-mcp-process-runtime.ps1 sympp-diagnostic-runtime-artifacts.ps1 sympp-diagnostic-launcher-artifacts.ps1 sympp-diagnostic-self-test.ps1) do
          source_helper = Path.join(Path.dirname(source_script_path), helper_name)

          if File.exists?(source_helper) do
            File.cp!(source_helper, Path.join(Path.dirname(target), helper_name))
          end
        end

        target
      end

      defp write_cache_manifest(cache_root, plugin_name, opts \\ []) do
        manifest_path = Path.join(cache_root, ".codex-plugin/plugin.json")
        File.mkdir_p!(Path.dirname(manifest_path))

        manifest =
          if Keyword.get(opts, :mcp?, false) do
            %{"name" => plugin_name, "version" => @plugin_version, "mcpServers" => "./.mcp.json"}
          else
            %{"name" => plugin_name, "version" => @plugin_version}
          end

        File.write!(manifest_path, Jason.encode!(manifest))

        if Keyword.get(opts, :mcp?, false) do
          File.write!(
            Path.join(cache_root, ".mcp.json"),
            Jason.encode!(%{
              "symphony_plus_plus" => %{
                "type" => "stdio",
                "command" => "cmd.exe",
                "args" => ["/d", "/s", "/c", "scripts/start-sympp-mcp.cmd"],
                "cwd" => "."
              }
            })
          )
        end
      end

      defp write_minimal_marketplace_source(codex_home) do
        marketplace_root = Path.join([codex_home, ".tmp", "marketplaces", @plugin_marketplace_name])
        File.mkdir_p!(marketplace_root)
        File.write!(Path.join(marketplace_root, ".codex-marketplace-install.json"), Jason.encode!(%{"revision" => @marketplace_revision}))
        File.mkdir_p!(Path.join(marketplace_root, "elixir"))
        File.write!(Path.join(marketplace_root, "elixir/mix.exs"), "defmodule SymphonyElixir.MixProject do\nend\n")
        File.mkdir_p!(Path.join(marketplace_root, "elixir/lib/mix/tasks"))
        File.write!(Path.join(marketplace_root, "elixir/lib/mix/tasks/sympp.solo.ex"), "")
        File.mkdir_p!(Path.join(marketplace_root, "scripts"))
        File.write!(Path.join(marketplace_root, "scripts/refresh-local-plugin.ps1"), "")
        File.write!(Path.join(marketplace_root, "scripts/smoke-sympp-mcp-http.ps1"), "")
        File.mkdir_p!(Path.join(marketplace_root, "implementation_docs_symphplusplus/mcp"))
        File.cp!(@contract_path, Path.join(marketplace_root, "implementation_docs_symphplusplus/mcp/mcp_tools_contract.json"))
        File.mkdir_p!(Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp/scripts"))

        File.cp!(
          @mcp_plugin_start_script_path,
          Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1")
        )

        for helper_name <-
              ~w(sympp-launcher-runtime.ps1 sympp-mcp-launcher-helpers.ps1 sympp-mcp-artifact-manifest.ps1 sympp-mcp-artifact-channel.ps1 sympp-mcp-artifact-runtime.ps1 sympp-mcp-process-runtime.ps1) do
          File.cp!(
            Path.join(Path.dirname(@mcp_plugin_start_script_path), helper_name),
            Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp/scripts/#{helper_name}")
          )
        end

        write_cache_manifest(Path.join(marketplace_root, "plugins/symphony-plus-plus"), "symphony-plus-plus")
        write_cache_manifest(Path.join(marketplace_root, "plugins/symphony-plus-plus-mcp"), "symphony-plus-plus-mcp", mcp?: true)

        marketplace_root
      end

      defp write_minimal_stale_source(codex_home) do
        source_root = Path.join(codex_home, "stale-source")
        File.mkdir_p!(Path.join(source_root, "elixir/lib/mix/tasks"))
        File.write!(Path.join(source_root, "elixir/mix.exs"), "defmodule Stale.MixProject do\nend\n")
        File.write!(Path.join(source_root, "elixir/lib/mix/tasks/sympp.solo.ex"), "")
        File.mkdir_p!(Path.join(source_root, "scripts"))
        File.write!(Path.join(source_root, "scripts/refresh-local-plugin.ps1"), "")
        File.write!(Path.join(source_root, "scripts/smoke-sympp-mcp-http.ps1"), "")
        source_root
      end

      defp write_runtime_artifact!(cache_root, opts) do
        archive_path = Path.join(cache_root, "sympp-runtime.zip")
        entrypoint = "runtime.cmd"
        dashboard_entries = [{"dashboard-static/index.html", "<main>ok</main>"}]
        artifact_entries = [{entrypoint, "@echo off\nexit /b 0\n"}, {"WORKFLOW.md", "workflow: artifact\n"}] ++ dashboard_entries
        artifact_contract_fingerprint = Keyword.get(opts, :mcp_contract_fingerprint, expected_mcp_contract_fingerprint())

        {:ok, _} =
          :zip.create(
            String.to_charlist(archive_path),
            Enum.map(artifact_entries, fn {name, content} -> {String.to_charlist(name), content} end)
          )

        artifact =
          %{
            "platform" => runtime_platform_key(),
            "path" => Path.basename(archive_path),
            "sha256" => file_sha256(archive_path),
            "entrypoint" => entrypoint,
            "workflow" => "WORKFLOW.md",
            "dashboard" => %{
              "asset_root" => "dashboard-static",
              "fingerprint" => dashboard_fingerprint(dashboard_entries)
            }
          }
          |> maybe_put("source_revision", Keyword.get(opts, :source_revision))
          |> maybe_put_unless_omitted("mcp_contract_fingerprint", artifact_contract_fingerprint)

        manifest =
          %{
            "plugin" => %{
              "marketplace" => @plugin_marketplace_name,
              "name" => "symphony-plus-plus-mcp",
              "version" => @plugin_version,
              "packages" => ["symphony-plus-plus", "symphony-plus-plus-mcp"]
            },
            "artifacts" => [artifact]
          }

        File.write!(Path.join(cache_root, ".sympp-runtime-artifacts.json"), Jason.encode!(manifest))
      end

      defp write_pinned_source_revision!(cache_root, revision) do
        File.write!(Path.join(cache_root, ".sympp-source-revision"), "#{revision}\n")
      end

      defp dashboard_fingerprint(entries) do
        entries
        |> Enum.filter(fn {name, _content} -> String.starts_with?(name, "dashboard-static/") end)
        |> Enum.map(fn {name, content} ->
          relative_name = String.replace_prefix(name, "dashboard-static/", "")
          "#{relative_name} #{content_sha256(content)}"
        end)
        |> Enum.sort()
        |> Enum.join("\n")
        |> content_sha256()
      end

      defp content_sha256(content) do
        content
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
      end

      defp maybe_put(map, _key, nil), do: map
      defp maybe_put(map, key, value), do: Map.put(map, key, value)
      defp maybe_put_unless_omitted(map, _key, :omit), do: map
      defp maybe_put_unless_omitted(map, key, value), do: maybe_put(map, key, value)

      defp file_sha256(path) do
        path
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
      end

      defp runtime_platform_key do
        "#{runtime_os_key()}-#{runtime_arch_key()}"
      end

      defp runtime_os_key do
        case :os.type() do
          {:win32, _} -> "windows"
          {:unix, :darwin} -> "macos"
          {:unix, _} -> "linux"
        end
      end

      defp runtime_arch_key do
        architecture =
          :erlang.system_info(:system_architecture)
          |> List.to_string()
          |> String.downcase()

        cond do
          String.contains?(architecture, "aarch64") -> "aarch64"
          String.contains?(architecture, "arm64") -> "aarch64"
          String.contains?(architecture, "x86_64") -> "x86_64"
          String.contains?(architecture, "amd64") -> "x86_64"
          String.contains?(architecture, "i386") -> "x86"
          true -> "unknown"
        end
      end

      defp expected_mcp_contract_fingerprint do
        @contract_path
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("mcp_contract_fingerprint")
      end

      defp quote_powershell_literal(value) do
        "'" <> String.replace(value, "'", "''") <> "'"
      end
    end
  end
end
