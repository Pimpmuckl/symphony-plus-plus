defmodule SymphonyElixir.SymphonyPlusPlus.RuntimeArtifactReleaseChannelTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../", __DIR__)
  @publisher Path.join(@repo_root, "scripts/publish-sympp-runtime-artifact.ps1")
  @contract_path Path.join(@repo_root, "elixir/priv/symphony_plus_plus/mcp_contract.json")
  @plugin_manifest_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/.codex-plugin/plugin.json")

  test "publisher validates all required platforms and writes launcher-readable aggregate manifest" do
    powershell = System.find_executable("pwsh")

    if powershell do
      temp_root = unique_temp_path("sympp-runtime-release-channel")
      output_path = Path.join(temp_root, "sympp-runtime-artifacts-stable.json")
      revision = String.duplicate("c", 40)
      dashboard_fingerprint = String.duplicate("d", 64)
      base_url = "https://github.com/Pimpmuckl/symphony-plus-plus/releases/download/test-runtime"

      try do
        File.mkdir_p!(temp_root)

        for platform <- ["linux-x64", "windows-x64", "macos-arm64"] do
          write_built_manifest!(temp_root, revision, platform, dashboard_fingerprint)
        end

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @publisher,
              "-ManifestDir",
              temp_root,
              "-PublishedBaseUrl",
              base_url,
              "-ReleaseTag",
              "test-runtime",
              "-Repository",
              "Pimpmuckl/symphony-plus-plus",
              "-Channel",
              "stable",
              "-ManifestVersion",
              "test-runtime",
              "-ChannelOutputPath",
              output_path
            ],
            cd: @repo_root,
            stderr_to_stdout: true
          )

        assert status == 0, output
        assert output =~ "Wrote aggregate release channel manifest"

        manifest = output_path |> File.read!() |> Jason.decode!()
        assert manifest["plugin"]["name"] == "symphony-plus-plus-mcp"
        assert manifest["plugin"]["version"] == plugin_version()
        assert manifest["plugin"]["source_revision"] == revision
        assert manifest["release"]["channel"] == "stable"
        assert manifest["release"]["source_revision"] == revision
        assert manifest["launcher_contract"]["mcp_contract_fingerprint"] == expected_mcp_contract_fingerprint()

        assert Enum.map(manifest["artifacts"], & &1["platform"]["os"]) == [
                 "linux",
                 "macos",
                 "windows"
               ]

        linux = Enum.find(manifest["artifacts"], &(&1["platform"]["os"] == "linux"))
        assert linux["archive"]["url"] == "#{base_url}/sympp-runtime-#{revision}-linux-x64.zip"
        assert linux["archive"]["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
        assert linux["dashboard"]["asset_root"] == "dashboard-static"
        assert linux["dashboard"]["fingerprint"] == dashboard_fingerprint
        assert linux["runtime"]["command"] == "start-runtime.sh"
        refute Map.has_key?(linux["runtime"], "workflow")

        assert_launcher_selects!(powershell, output_path, revision)
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "publisher refuses to advance channel when a required platform is missing" do
    powershell = System.find_executable("pwsh")

    if powershell do
      temp_root = unique_temp_path("sympp-runtime-release-channel-missing")
      revision = String.duplicate("e", 40)

      try do
        File.mkdir_p!(temp_root)
        write_built_manifest!(temp_root, revision, "linux-x64", String.duplicate("f", 64))

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @publisher,
              "-ManifestDir",
              temp_root,
              "-PublishedBaseUrl",
              "https://github.com/Pimpmuckl/symphony-plus-plus/releases/download/test-runtime",
              "-ReleaseTag",
              "test-runtime"
            ],
            cd: @repo_root,
            stderr_to_stdout: true
          )

        assert status != 0
        assert output =~ "missing required platform 'windows-x64'"
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "build scripts do not package the explicit-copy workflow template" do
    for script <- [
          Path.join(@repo_root, "scripts/build-sympp-runtime-artifact.ps1"),
          Path.join(@repo_root, "scripts/build-sympp-runtime-artifact.sh")
        ] do
      body = File.read!(script)

      refute body =~ "WORKFLOW.symfony_pp.md"
      refute body =~ "workflowTemplatePath"
      refute body =~ "workflow_template_path"
      refute body =~ ~r/(Copy-Item|cp).+WORKFLOW\.md/
      refute body =~ ~r/workflow\s*=\s*"WORKFLOW\.md"/
      refute body =~ ~s("workflow": "WORKFLOW.md")
      assert body =~ "unset SYMPP_WORKFLOW_FILE"
      assert body =~ "Remove-Item Env:SYMPP_WORKFLOW_FILE"
      assert body =~ "runtime/erts-*/bin/*"
      assert body =~ "runtime/bin/*"
      assert body =~ "pluginIdentity.name" or body =~ "plugin_name"
      assert body =~ "pluginIdentity.version" or body =~ "plugin_version"
    end
  end

  defp write_built_manifest!(root, revision, platform, dashboard_fingerprint) do
    extension = ".zip"
    archive_file = "sympp-runtime-#{revision}-#{platform}#{extension}"
    archive_path = Path.join(root, archive_file)
    File.write!(archive_path, "fake archive #{platform}\n")
    archive_sha = file_sha256(archive_path)

    manifest = %{
      "schema_version" => 1,
      "status" => "built",
      "plugin" => %{
        "marketplace" => "symphony-plus-plus",
        "name" => "symphony-plus-plus-mcp",
        "version" => plugin_version(),
        "packages" => ["symphony-plus-plus", "symphony-plus-plus-mcp"]
      },
      "source_revision" => revision,
      "mcp_contract_fingerprint" => expected_mcp_contract_fingerprint(),
      "contract_fingerprint" => expected_mcp_contract_fingerprint(),
      "platform" => platform,
      "created_at" => "2026-06-14T00:00:00Z",
      "artifact" => %{
        "file" => archive_file,
        "relative_path" => archive_file,
        "size_bytes" => File.stat!(archive_path).size,
        "sha256" => archive_sha
      },
      "payload_manifest" => %{
        "file" => "runtime-manifest.json",
        "sha256" => String.duplicate("a", 64)
      },
      "backend" => %{
        "kind" => "mix_release",
        "name" => "symphony_elixir",
        "relative_path" => "runtime",
        "entrypoints" => %{
          "unix" => "start-runtime.sh",
          "windows" => "start-runtime.ps1"
        }
      },
      "dashboard" => %{
        "kind" => "vite_static",
        "relative_path" => "dashboard-static",
        "index" => "dashboard-static/index.html",
        "vite_manifest" => "dashboard-static/.vite/manifest.json",
        "fingerprint" => dashboard_fingerprint
      },
      "launcher_contract" => %{
        "manifest" => "sympp-runtime-artifact",
        "version" => 1,
        "mcp_contract_fingerprint" => expected_mcp_contract_fingerprint()
      }
    }

    File.write!(
      Path.join(root, "sympp-runtime-#{revision}-#{platform}.manifest.json"),
      Jason.encode!(manifest)
    )
  end

  defp assert_launcher_selects!(powershell, manifest_path, revision) do
    script = """
    $ErrorActionPreference = "Stop"
    function Normalize-McpContractFingerprint([string]$Fingerprint) {
      if ([string]::IsNullOrWhiteSpace($Fingerprint)) { return $null }
      $normalized = $Fingerprint.Trim().ToLowerInvariant()
      if ($normalized -match "^[0-9a-f]{64}$") { return $normalized }
      return $null
    }
    . "#{Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/sympp-launcher-runtime.ps1")}"
    . "#{Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/sympp-mcp-artifact-channel.ps1")}"
    . "#{Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/sympp-mcp-artifact-manifest.ps1")}"
    $manifest = Get-Content -LiteralPath "#{manifest_path}" -Raw | ConvertFrom-Json
    $artifact = Select-SymppArtifact $manifest "linux-x64" "#{revision}" "#{expected_mcp_contract_fingerprint()}" "symphony-plus-plus-mcp" "#{plugin_version()}"
    if ($null -eq $artifact) { throw "no artifact selected" }
    if (-not ([string]$artifact.archive.url).EndsWith("linux-x64.zip")) { throw "wrong artifact selected" }
    """

    {output, status} =
      System.cmd(
        powershell,
        ["-NoProfile", "-Command", script],
        cd: @repo_root,
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp expected_mcp_contract_fingerprint do
    @contract_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("mcp_contract_fingerprint")
  end

  defp plugin_version do
    @plugin_manifest_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("version")
  end

  defp file_sha256(path) do
    :crypto.hash(:sha256, File.read!(path))
    |> Base.encode16(case: :lower)
  end

  defp unique_temp_path(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{unique_id()}")
  end

  defp unique_id do
    id = "#{System.pid()}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    String.replace(id, ~r/[^A-Za-z0-9_.-]/, "-")
  end
end
