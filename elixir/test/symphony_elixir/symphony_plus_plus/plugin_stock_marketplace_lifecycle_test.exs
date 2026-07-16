defmodule SymphonyElixir.SymphonyPlusPlus.PluginStockMarketplaceLifecycleTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../", __DIR__)
  @script_path Path.join(@repo_root, "scripts/benchmarks/sympp-mcp/stock-marketplace-lifecycle.ps1")
  @workflow_path Path.join(@repo_root, ".github/workflows/plugin-stock-marketplace-lifecycle.yml")
  @bridge_path Path.join(@repo_root, "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp-bridge.js")

  test "release regression keeps Codex in charge of marketplace installation" do
    script = File.read!(@script_path)
    workflow = File.read!(@workflow_path)
    bridge = File.read!(@bridge_path)

    assert script =~ ~s("plugin", "marketplace", "add")
    assert script =~ ~s("plugin", "add", "symphony-plus-plus-mcp@symphony-plus-plus")
    assert script =~ ~s("plugin", "marketplace", "upgrade")
    assert script =~ ".sympp-source-revision"
    assert script =~ "Start-McpClient $pluginRoot"
    assert script =~ "backend_start_ticks_before"
    assert script =~ "Remove-OwnedTree $tempRoot"

    assert workflow =~ "runs-on: windows-latest"
    assert workflow =~ "npm install --global @openai/codex@0.143.0"
    assert workflow =~ "stock-marketplace-lifecycle.ps1"

    assert script =~ ~s($after.runtime_mode -ne "artifact")

    assert bridge =~ "installedMarketplaceMissingAdvisoryRevision"
    assert bridge =~ "runPowerShellForInstalledMarketplace"
    refute bridge =~ "SYMPP_REPO_ROOT: sourceRoot"
    assert bridge =~ ~s(stdio: "inherit")
  end
end
