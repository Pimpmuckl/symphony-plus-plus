[CmdletBinding()]
param(
  [string]$MarketplaceSource,
  [string]$MarketplaceRef,
  [ValidateRange(60, 900)][int]$StartupTimeoutSec = 300
)

$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../.."))
$ownedPrefix = [System.IO.Path]::GetFullPath((Join-Path $env:SystemDrive "sp-"))
$tempRoot = $ownedPrefix + [guid]::NewGuid().ToString("N")
$codexHome = Join-Path $tempRoot "c"
$runtimeFile = Join-Path $tempRoot "runtime/codex-plugin.json"
$clients = [System.Collections.Generic.List[object]]::new()
$runtimeIdentity = $null
$result = $null

function Invoke-CodexJson([string[]]$Arguments) {
  $output = & (Get-Command codex -ErrorAction Stop).Source @Arguments
  if ($LASTEXITCODE -ne 0) { throw "codex $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
  return ($output | Out-String | ConvertFrom-Json)
}

function New-IsolatedPort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  try {
    $listener.Start()
    return [int]$listener.LocalEndpoint.Port
  } finally {
    $listener.Stop()
  }
}

function Set-IsolatedEnvironment($Info, [hashtable]$Environment) {
  foreach ($key in @($Info.Environment.Keys)) {
    if ([string]$key -match "(?i)(TOKEN|SECRET|API_KEY|AUTHORIZATION|GITHUB|LINEAR|OPENAI)" -or
        [string]$key -in @("SYMPP_REPO_ROOT", "SYMPP_BACKEND_URL", "SYMPP_DASHBOARD_ORIGIN")) {
      [void]$Info.Environment.Remove([string]$key)
    }
  }
  foreach ($entry in $Environment.GetEnumerator()) { $Info.Environment[$entry.Key] = [string]$entry.Value }
}

function Start-McpClient([string]$PluginRoot, [hashtable]$Environment) {
  $server = (Get-Content -LiteralPath (Join-Path $PluginRoot ".mcp.json") -Raw | ConvertFrom-Json).symphony_plus_plus
  $info = [System.Diagnostics.ProcessStartInfo]::new()
  $info.FileName = [string]$server.command
  foreach ($argument in @($server.args)) { [void]$info.ArgumentList.Add([string]$argument) }
  $info.WorkingDirectory = $PluginRoot
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardInput = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  Set-IsolatedEnvironment $info $Environment
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $info
  if (-not $process.Start()) { throw "Installed MCP launcher failed to start." }
  $process.StandardInput.AutoFlush = $true
  $process.StandardInput.WriteLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"stock-marketplace-lifecycle","version":"1"},"capabilities":{}}}')
  $client = [pscustomobject]@{
    process = $process
    line_task = $process.StandardOutput.ReadLineAsync()
    stderr_task = $process.StandardError.ReadToEndAsync()
  }
  $clients.Add($client)
  return $client
}

function Wait-McpInitialize($Client) {
  $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSec)
  while (-not $Client.line_task.IsCompleted) {
    if ($Client.process.HasExited) { throw "Installed launcher exited before initialize: $($Client.stderr_task.GetAwaiter().GetResult().Trim())" }
    if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for installed launcher initialize." }
    Start-Sleep -Milliseconds 20
  }
  $line = $Client.line_task.GetAwaiter().GetResult()
  if ([string]::IsNullOrWhiteSpace($line)) {
    if (-not $Client.process.HasExited) { [void]$Client.process.WaitForExit(5000) }
    $detail = if ($Client.stderr_task.IsCompleted) { $Client.stderr_task.GetAwaiter().GetResult().Trim() } else { "stderr still open" }
    throw "Installed launcher closed stdout before initialize: $detail"
  }
  $response = $line | ConvertFrom-Json
  if ($response.error -or $null -eq $response.result) { throw "Installed launcher returned an invalid initialize response: $line" }
  $Client.process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
}

function Get-RuntimeIdentity {
  $state = Get-Content -LiteralPath $runtimeFile -Raw | ConvertFrom-Json
  $process = Get-Process -Id ([int]$state.backend.pid) -ErrorAction Stop
  $dashboard = Invoke-WebRequest -Uri ([string]$state.frontend.url) -UseBasicParsing -TimeoutSec 15
  if ($dashboard.StatusCode -ne 200) { throw "Installed runtime dashboard returned HTTP $($dashboard.StatusCode)." }
  return [pscustomobject]@{
    pid = [int]$process.Id
    start_ticks = $process.StartTime.ToUniversalTime().Ticks
    dashboard_url = [string]$state.frontend.url
    runtime_mode = [string]$state.runtime_mode
  }
}

function Stop-McpClient($Client) {
  if ($null -eq $Client -or $null -eq $Client.process) { return }
  try { $Client.process.StandardInput.Close() } catch { }
  if (-not $Client.process.WaitForExit(60000)) {
    $Client.process.Kill($true)
    [void]$Client.process.WaitForExit(15000)
  }
  $Client.process.Dispose()
  $Client.process = $null
}

function Remove-OwnedTree([string]$Path) {
  $resolved = [System.IO.Path]::GetFullPath($Path)
  if (-not $resolved.StartsWith($ownedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Cleanup root escaped its owned prefix: $resolved" }
  for ($attempt = 1; $attempt -le 60 -and [System.IO.Directory]::Exists($resolved); $attempt++) {
    try {
      Get-ChildItem -LiteralPath $resolved -File -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.IsReadOnly = $false }
      [System.IO.Directory]::Delete($resolved, $true)
    } catch {
      if ($attempt -eq 60) { throw }
      Start-Sleep -Milliseconds 250
    }
  }
  if ([System.IO.Directory]::Exists($resolved)) { throw "Lifecycle cleanup did not remove $resolved" }
}

if ([string]::IsNullOrWhiteSpace($MarketplaceSource)) {
  $MarketplaceSource = ([string](& git -C $repoRoot remote get-url origin)).Trim()
}
if ([string]::IsNullOrWhiteSpace($MarketplaceRef)) {
  $MarketplaceRef = ([string](& git -C $repoRoot branch --show-current)).Trim()
}
if ([string]::IsNullOrWhiteSpace($MarketplaceSource) -or [string]::IsNullOrWhiteSpace($MarketplaceRef)) {
  throw "MarketplaceSource and MarketplaceRef are required."
}

try {
  New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
  $backendPort = New-IsolatedPort
  $environment = @{
    CODEX_HOME = $codexHome
    HOME = Join-Path $tempRoot "profile"
    MIX_BUILD_ROOT = Join-Path $tempRoot "build"
    SYMPP_HOME = Join-Path $tempRoot "home"
    SYMPP_RUNTIME_FILE = $runtimeFile
    SYMPP_LOG_DIR = Join-Path $tempRoot "logs"
    SYMPP_BACKEND_PORT = [string]$backendPort
    SYMPP_DASHBOARD_PORT = [string]$backendPort
    SYMPP_OPEN_DASHBOARD = "0"
    SYMPP_MCP_BRIDGE_MODE = "http"
    SYMPP_ARTIFACT_RUNTIME = "1"
    SYMPP_BACKEND_STARTUP_TIMEOUT_SEC = [string]$StartupTimeoutSec
    SYMPP_STARTUP_LOCK_TIMEOUT_SEC = "1800"
  }

  $previousCodexHome = $env:CODEX_HOME
  try {
    $env:CODEX_HOME = $codexHome
    [void](Invoke-CodexJson @("plugin", "marketplace", "add", $MarketplaceSource, "--ref", $MarketplaceRef, "--json"))
    $installed = Invoke-CodexJson @("plugin", "add", "symphony-plus-plus-mcp@symphony-plus-plus", "--json")
  } finally {
    $env:CODEX_HOME = $previousCodexHome
  }
  $pluginRoot = [System.IO.Path]::GetFullPath([string]$installed.installedPath)
  if (-not $pluginRoot.StartsWith([System.IO.Path]::GetFullPath($codexHome), [System.StringComparison]::OrdinalIgnoreCase)) { throw "Codex installed the plugin outside the disposable home." }
  if (Test-Path -LiteralPath (Join-Path $pluginRoot ".sympp-source-revision")) { throw "Stock installed package unexpectedly contains .sympp-source-revision." }

  $first = Start-McpClient $pluginRoot $environment
  Wait-McpInitialize $first
  $before = Get-RuntimeIdentity
  $runtimeIdentity = $before

  try {
    $env:CODEX_HOME = $codexHome
    [void](Invoke-CodexJson @("plugin", "marketplace", "upgrade", "symphony-plus-plus", "--json"))
  } finally {
    $env:CODEX_HOME = $previousCodexHome
  }
  if (Test-Path -LiteralPath (Join-Path $pluginRoot ".sympp-source-revision")) { throw "Marketplace upgrade unexpectedly created .sympp-source-revision." }

  $second = Start-McpClient $pluginRoot $environment
  Wait-McpInitialize $second
  $after = Get-RuntimeIdentity
  if ($after.pid -ne $before.pid -or $after.start_ticks -ne $before.start_ticks) { throw "Marketplace upgrade replaced the healthy backend singleton." }
  if ($after.runtime_mode -ne "artifact") { throw "Installed lifecycle used unexpected runtime mode: $($after.runtime_mode)" }

  $result = [pscustomobject]@{
    marketplace_source = $MarketplaceSource
    marketplace_ref = $MarketplaceRef
    marker_free = $true
    initializes = 2
    backend_pid_before = $before.pid
    backend_pid_after = $after.pid
    backend_start_ticks_before = $before.start_ticks
    backend_start_ticks_after = $after.start_ticks
    dashboard_url = $after.dashboard_url
    dashboard_status = 200
    runtime_mode = $after.runtime_mode
  }
} finally {
  foreach ($client in @($clients)) { Stop-McpClient $client }
  if ($runtimeIdentity) {
    $backend = Get-Process -Id $runtimeIdentity.pid -ErrorAction SilentlyContinue
    if ($backend -and $backend.StartTime.ToUniversalTime().Ticks -eq $runtimeIdentity.start_ticks) {
      Stop-Process -Id $backend.Id -Force -ErrorAction Stop
      if (-not $backend.WaitForExit(60000)) { throw "Timed out waiting for isolated backend cleanup." }
    }
  }
  Remove-OwnedTree $tempRoot
}

$result | Add-Member -NotePropertyName cleanup_complete -NotePropertyValue $true
$result | ConvertTo-Json -Compress
