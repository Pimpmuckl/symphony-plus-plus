defmodule SymphonyElixir.SymphonyPlusPlus.RuntimeArtifactManifestScriptsTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../", __DIR__)
  @build_ps1 Path.join(@repo_root, "scripts/build-sympp-runtime-artifact.ps1")
  @build_sh Path.join(@repo_root, "scripts/build-sympp-runtime-artifact.sh")
  @publish_ps1 Path.join(@repo_root, "scripts/publish-sympp-runtime-artifact.ps1")
  @publish_sh Path.join(@repo_root, "scripts/publish-sympp-runtime-artifact.sh")
  @contract_path Path.join(@repo_root, "elixir/priv/symphony_plus_plus/mcp_contract.json")

  test "PowerShell build dry-run resolves MCP contract fingerprint" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-artifact-build-dry-run")

    if powershell do
      try do
        File.mkdir_p!(temp_root)

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @build_ps1,
              "-Revision",
              String.duplicate("a", 40),
              "-OutputDir",
              temp_root,
              "-Platform",
              "test-x64",
              "-DryRun"
            ],
            cd: @repo_root,
            stderr_to_stdout: true
          )

        assert status == 0, output
        assert output =~ "Dry run:"
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "shell build dry-run resolves MCP contract fingerprint" do
    bash = System.find_executable("bash")
    temp_root = unique_temp_path("sympp-artifact-build-sh-dry-run")

    if bash do
      try do
        File.mkdir_p!(temp_root)

        {output, status} =
          System.cmd(
            bash,
            [
              bash_path(@build_sh),
              "--revision",
              String.duplicate("a", 40),
              "--output-dir",
              bash_path(temp_root),
              "--platform",
              "test-x64",
              "--dry-run"
            ],
            cd: @repo_root,
            stderr_to_stdout: true
          )

        assert status == 0, output
        assert output =~ "Dry run:"
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "PowerShell publish propagates MCP contract fingerprint to channel manifest" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-artifact-publish-ps")

    if powershell do
      try do
        manifest_path = write_built_manifest!(temp_root, include_contract?: true)
        channel_path = Path.join(temp_root, "channel.json")

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @publish_ps1,
              "-ManifestPath",
              manifest_path,
              "-PublishedArtifactUrl",
              "https://example.invalid/sympp-runtime.zip",
              "-PublishedManifestUrl",
              "https://example.invalid/sympp-runtime.manifest.json",
              "-ChannelOutputPath",
              channel_path
            ],
            cd: @repo_root,
            stderr_to_stdout: true
          )

        assert status == 0, output
        channel = channel_path |> File.read!() |> Jason.decode!()
        fingerprint = expected_mcp_contract_fingerprint()
        assert channel["mcp_contract_fingerprint"] == fingerprint
        assert channel["contract_fingerprint"] == fingerprint
        assert channel["plugin"]["name"] == "symphony-plus-plus-mcp"
        assert channel["plugin"]["version"] == expected_mcp_plugin_version()
        assert channel["artifact"]["mcp_contract_fingerprint"] == fingerprint
        assert channel["launcher_contract"]["mcp_contract_fingerprint"] == fingerprint
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "PowerShell publish rejects built manifest without MCP contract fingerprint" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-artifact-publish-ps-missing-contract")

    if powershell do
      try do
        manifest_path = write_built_manifest!(temp_root, include_contract?: false)

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @publish_ps1,
              "-ManifestPath",
              manifest_path,
              "-PublishedArtifactUrl",
              "https://example.invalid/sympp-runtime.zip",
              "-PublishedManifestUrl",
              "https://example.invalid/sympp-runtime.manifest.json",
              "-ChannelOutputPath",
              Path.join(temp_root, "channel.json")
            ],
            cd: @repo_root,
            stderr_to_stdout: true
          )

        assert status != 0

        normalized = normalized_output(output)
        assert normalized =~ "Artifact manifest must declare mcp_contract_fingerprint"
        assert normalized =~ "contract_fingerprint:"
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "PowerShell publish rejects built manifest without plugin identity" do
    powershell = System.find_executable("pwsh")
    temp_root = unique_temp_path("sympp-artifact-publish-ps-missing-plugin")

    if powershell do
      try do
        manifest_path = write_built_manifest!(temp_root, include_contract?: true, include_plugin?: false)

        {output, status} =
          System.cmd(
            powershell,
            [
              "-NoProfile",
              "-File",
              @publish_ps1,
              "-ManifestPath",
              manifest_path,
              "-PublishedArtifactUrl",
              "https://example.invalid/sympp-runtime.zip",
              "-PublishedManifestUrl",
              "https://example.invalid/sympp-runtime.manifest.json",
              "-ChannelOutputPath",
              Path.join(temp_root, "channel.json")
            ],
            cd: @repo_root,
            stderr_to_stdout: true
          )

        assert status != 0
        assert normalized_output(output) =~ "missing required property 'plugin'."
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "shell publish propagates MCP contract fingerprint to channel manifest" do
    bash = System.find_executable("bash")
    temp_root = unique_temp_path("sympp-artifact-publish-sh")

    if bash do
      try do
        manifest_path = write_built_manifest!(temp_root, include_contract?: true)
        channel_path = Path.join(temp_root, "channel.json")

        {output, status} =
          System.cmd(
            bash,
            [
              bash_path(@publish_sh),
              "--manifest",
              bash_path(manifest_path),
              "--published-artifact-url",
              "https://example.invalid/sympp-runtime.tar.gz",
              "--published-manifest-url",
              "https://example.invalid/sympp-runtime.manifest.json",
              "--channel-output",
              bash_path(channel_path)
            ],
            cd: @repo_root,
            stderr_to_stdout: true
          )

        assert status == 0, output
        channel = channel_path |> File.read!() |> Jason.decode!()
        fingerprint = expected_mcp_contract_fingerprint()
        assert channel["mcp_contract_fingerprint"] == fingerprint
        assert channel["plugin"]["name"] == "symphony-plus-plus-mcp"
        assert channel["plugin"]["version"] == expected_mcp_plugin_version()
        assert channel["artifact"]["mcp_contract_fingerprint"] == fingerprint
        assert channel["launcher_contract"]["mcp_contract_fingerprint"] == fingerprint
        assert channel["launcher_contract"]["contract_fingerprint"] == fingerprint
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "shell publish rejects built manifest without plugin identity" do
    bash = System.find_executable("bash")
    temp_root = unique_temp_path("sympp-artifact-publish-sh-missing-plugin")

    if bash do
      try do
        manifest_path = write_built_manifest!(temp_root, include_contract?: true, include_plugin?: false)

        {output, status} =
          System.cmd(
            bash,
            [
              bash_path(@publish_sh),
              "--manifest",
              bash_path(manifest_path),
              "--published-artifact-url",
              "https://example.invalid/sympp-runtime.tar.gz",
              "--published-manifest-url",
              "https://example.invalid/sympp-runtime.manifest.json",
              "--channel-output",
              bash_path(Path.join(temp_root, "channel.json"))
            ],
            cd: @repo_root,
            stderr_to_stdout: true
          )

        assert status != 0
        assert output =~ "Artifact manifest is missing required property 'plugin'."
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  test "shell publish rejects built manifest without MCP contract fingerprint" do
    bash = System.find_executable("bash")
    temp_root = unique_temp_path("sympp-artifact-publish-sh-missing-contract")

    if bash do
      try do
        manifest_path = write_built_manifest!(temp_root, include_contract?: false)

        {output, status} =
          System.cmd(
            bash,
            [
              bash_path(@publish_sh),
              "--manifest",
              bash_path(manifest_path),
              "--published-artifact-url",
              "https://example.invalid/sympp-runtime.tar.gz",
              "--published-manifest-url",
              "https://example.invalid/sympp-runtime.manifest.json",
              "--channel-output",
              bash_path(Path.join(temp_root, "channel.json"))
            ],
            cd: @repo_root,
            stderr_to_stdout: true
          )

        assert status != 0
        assert output =~ "Artifact manifest must declare mcp_contract_fingerprint or contract_fingerprint:"
      after
        File.rm_rf!(temp_root)
      end
    end
  end

  defp write_built_manifest!(temp_root, opts) do
    File.mkdir_p!(temp_root)
    artifact_path = Path.join(temp_root, "sympp-runtime.zip")
    File.write!(artifact_path, "runtime")

    fingerprint = expected_mcp_contract_fingerprint()

    manifest =
      %{
        "schema_version" => 1,
        "status" => "built",
        "plugin" => %{
          "marketplace" => "symphony-plus-plus",
          "name" => "symphony-plus-plus-mcp",
          "version" => expected_mcp_plugin_version(),
          "packages" => ["symphony-plus-plus", "symphony-plus-plus-mcp"]
        },
        "source_revision" => String.duplicate("a", 40),
        "platform" => "test-x64",
        "artifact" => %{
          "file" => Path.basename(artifact_path),
          "sha256" => file_sha256(artifact_path),
          "size_bytes" => byte_size("runtime")
        },
        "dashboard" => %{
          "kind" => "vite_static",
          "relative_path" => "dashboard-static",
          "index" => "dashboard-static/index.html",
          "vite_manifest" => "dashboard-static/.vite/manifest.json",
          "fingerprint" => String.duplicate("d", 64)
        },
        "launcher_contract" => %{
          "manifest" => "sympp-runtime-artifact",
          "version" => 1
        }
      }

    manifest =
      if Keyword.fetch!(opts, :include_contract?) do
        manifest
        |> Map.put("mcp_contract_fingerprint", fingerprint)
        |> put_in(["launcher_contract", "mcp_contract_fingerprint"], fingerprint)
      else
        manifest
      end

    manifest =
      if Keyword.get(opts, :include_plugin?, true) do
        manifest
      else
        Map.delete(manifest, "plugin")
      end

    manifest_path = Path.join(temp_root, "sympp-runtime.manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    manifest_path
  end

  defp expected_mcp_contract_fingerprint do
    @contract_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("mcp_contract_fingerprint")
  end

  defp expected_mcp_plugin_version do
    @repo_root
    |> Path.join("plugins/symphony-plus-plus-mcp/.codex-plugin/plugin.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("version")
  end

  defp file_sha256(path) do
    :crypto.hash(:sha256, File.read!(path))
    |> Base.encode16(case: :lower)
  end

  defp bash_path(path) do
    normalized = String.replace(path, "\\", "/")

    case Regex.run(~r/\A([A-Za-z]):\/(.*)\z/, normalized) do
      [_, drive, rest] -> "/mnt/#{String.downcase(drive)}/#{rest}"
      nil -> normalized
    end
  end

  defp normalized_output(output) do
    output
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.replace(~r/\s+/, " ")
  end

  defp unique_temp_path(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{unique_id()}")
  end

  defp unique_id do
    id = "#{System.pid()}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    String.replace(id, ~r/[^A-Za-z0-9_.-]/, "-")
  end
end
