param([int]$IdleMilliseconds = 1500)
$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../../.."))
$pluginRoot = Join-Path $repoRoot "plugins/symphony-plus-plus-mcp"
$launcher = Join-Path $pluginRoot "scripts/start-sympp-mcp.ps1"
$tempRoot = Join-Path $PSScriptRoot (".persistent-artifact-" + [guid]::NewGuid().ToString("N"))
$runtimeFile = Join-Path $tempRoot "state/runtime.json"
$backendProcessId = $null
$backendStartTicks = $null
$frontendProcessId = $null

function New-IsolatedPort([int[]]$Avoid) {
  do {
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try { $probe.Start(); $port = [int]$probe.LocalEndpoint.Port } finally { $probe.Stop() }
  } while ($port -in $Avoid -or $port -in @(19998, 19999))
  return $port
}

function Start-IsolatedProcess([string]$FilePath, [string[]]$Arguments, [hashtable]$Environment, [bool]$RedirectStreams = $true) {
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $FilePath
  foreach ($argument in $Arguments) { [void]$psi.ArgumentList.Add($argument) }
  $psi.WorkingDirectory = $repoRoot
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $RedirectStreams
  $psi.RedirectStandardOutput = $RedirectStreams
  $psi.RedirectStandardError = $RedirectStreams
  foreach ($key in @($psi.Environment.Keys)) {
    if ([string]$key -match "(?i)(TOKEN|SECRET|API_KEY|AUTHORIZATION|GITHUB|LINEAR|OPENAI)" -or
        [string]$key -in @("SYMPP_REPO_ROOT", "SYMPP_BACKEND_PORT", "SYMPP_DASHBOARD_PORT", "SYMPP_BACKEND_URL", "SYMPP_DASHBOARD_ORIGIN")) {
      [void]$psi.Environment.Remove([string]$key)
    }
  }
  foreach ($entry in $Environment.GetEnumerator()) { $psi.Environment[$entry.Key] = [string]$entry.Value }
  $process = [System.Diagnostics.Process]::Start($psi)
  if (-not $process) { throw "Failed to start isolated process: $FilePath" }
  return $process
}

function Invoke-IsolatedCommand([string]$FilePath, [string[]]$Arguments, [hashtable]$Environment) {
  $process = Start-IsolatedProcess $FilePath $Arguments $Environment $false
  try {
    if (-not $process.WaitForExit(900000)) { $process.Kill($true); throw "Timed out: $FilePath" }
    if ($process.ExitCode -ne 0) { throw "$FilePath exited $($process.ExitCode)." }
  } finally {
    if (-not $process.HasExited) { $process.Kill($true) }
    $process.Dispose()
  }
}

function Invoke-McpBridge([string]$FilePath, [string[]]$Arguments, [hashtable]$Environment) {
  $process = Start-IsolatedProcess $FilePath $Arguments $Environment
  try {
    $stderr = $process.StandardError.ReadToEndAsync()
    $requests = @(
      @{ jsonrpc = "2.0"; id = 1; method = "initialize"; params = @{ protocolVersion = "2025-03-26"; capabilities = @{}; clientInfo = @{ name = "persistent-runtime-smoke"; version = "1" } } },
      @{ jsonrpc = "2.0"; id = 2; method = "tools/list"; params = @{} }
    )
    $responses = foreach ($request in $requests) {
      $process.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 8 -Compress))
      $process.StandardInput.Flush()
      $line = $process.StandardOutput.ReadLineAsync()
      if (-not $line.Wait(60000)) { throw "Timed out waiting for MCP response from $FilePath" }
      $line.Result | ConvertFrom-Json
    }
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(60000)) { $process.Kill($true); throw "Bridge did not exit after stdin closed: $FilePath" }
    $errorText = $stderr.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw "$FilePath exited $($process.ExitCode): $errorText" }
    if ($responses[0].result.protocolVersion -ne "2025-03-26" -or @($responses[1].result.tools).Count -eq 0) {
      throw "Bridge did not complete real initialize plus tools/list."
    }
    return $errorText
  } finally {
    if (-not $process.HasExited) { $process.Kill($true) }
    $process.Dispose()
  }
}

function Get-Sha256([string]$Value) {
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Value))).ToLowerInvariant()
}

function Wait-ProcessStopped([int]$ProcessIdValue) {
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while ((Get-Process -Id $ProcessIdValue -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
  if (Get-Process -Id $ProcessIdValue -ErrorAction SilentlyContinue) { throw "Managed backend pid=$ProcessIdValue did not stop." }
}

try {
  foreach ($path in @(
      $tempRoot, (Split-Path -Parent $runtimeFile), (Join-Path $tempRoot "logs"), (Join-Path $tempRoot "database"),
      (Join-Path $tempRoot "tmp"), (Join-Path $tempRoot "xdg/config"),
      (Join-Path $tempRoot "xdg/cache"), (Join-Path $tempRoot "xdg/data")
    )) { New-Item -ItemType Directory -Path $path -Force | Out-Null }

  $backendPort = New-IsolatedPort @()
  $dashboardPort = New-IsolatedPort @($backendPort)
  $sourceEnvironment = @{
    SYMPP_REPO_ROOT = $repoRoot; SYMPP_HOME = Join-Path $tempRoot "runtime-home"
    SYMPP_RUNTIME_FILE = $runtimeFile; SYMPP_LOG_DIR = Join-Path $tempRoot "logs"
    SYMPP_DATABASE = Join-Path $tempRoot "database/ledger.sqlite3"
    SYMPP_BACKEND_PORT = [string]$backendPort; SYMPP_DASHBOARD_PORT = [string]$dashboardPort
    SYMPP_OPEN_DASHBOARD = "0"; SYMPP_AUTOSTART_FRONTEND = "1"; SYMPP_MCP_BRIDGE_MODE = "http"
    SYMPP_SOURCE_FALLBACK = "1"; SYMPP_ARTIFACT_RUNTIME = "0"; SYMPP_LAUNCHER = "direct"
    SYMPP_ELIXIR_SETUP_TIMEOUT_SEC = "600"; MIX_BUILD_ROOT = Join-Path $repoRoot "elixir/_build"; HEX_OFFLINE = "1"
    TEMP = Join-Path $tempRoot "tmp"; TMP = Join-Path $tempRoot "tmp"
    XDG_CONFIG_HOME = Join-Path $tempRoot "xdg/config"; XDG_CACHE_HOME = Join-Path $tempRoot "xdg/cache"; XDG_DATA_HOME = Join-Path $tempRoot "xdg/data"
  }
  $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
  [void](Invoke-IsolatedCommand $pwsh @("-NoProfile", "-File", $launcher, "-PrepareRuntimeOnly") $sourceEnvironment)
  $state = Get-Content -LiteralPath $runtimeFile -Raw | ConvertFrom-Json
  $backendProcessId = [int]$state.backend.pid
  $backendStartTicks = (Get-Process -Id $backendProcessId -ErrorAction Stop).StartTime.ToUniversalTime().Ticks
  $frontendProcessId = [int]$state.frontend.pid
  Stop-Process -Id $frontendProcessId -Force -ErrorAction Stop
  Wait-ProcessStopped $frontendProcessId
  $frontendProcessId = $null
  $contract = [string]$state.backend.contract_fingerprint
  $backend = ([string]$state.backend.url).TrimEnd("/")

  $codexHome = Join-Path $tempRoot "codex"
  $installedRoot = Join-Path $codexHome "plugins/cache/symphony-plus-plus/symphony-plus-plus-mcp/0.1.9"
  $sourceRoot = Join-Path $codexHome ".tmp/marketplaces/symphony-plus-plus"
  $sourcePluginRoot = Join-Path $sourceRoot "plugins/symphony-plus-plus-mcp"
  foreach ($destination in @($installedRoot, $sourcePluginRoot)) {
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $pluginRoot "scripts") -Destination $destination -Recurse
  }
  $revision = "b" * 40
  New-Item -ItemType Directory -Path (Join-Path $sourceRoot "elixir/priv/symphony_plus_plus") -Force | Out-Null
  @{ revision = $revision } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $sourceRoot ".codex-marketplace-install.json")
  @{ mcp_contract_fingerprint = $contract } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $sourceRoot "elixir/priv/symphony_plus_plus/mcp_contract.json")
  $installedPath = [System.IO.Path]::GetFullPath($installedRoot).ToLowerInvariant()
  $generationKey = Get-Sha256 "$installedPath`n$revision`n$contract"
  $validationFile = Join-Path $sourceEnvironment.SYMPP_HOME ("runtime/launcher-validation/" + (Get-Sha256 $installedPath).Substring(0, 12) + ".json")
  New-Item -ItemType Directory -Path (Split-Path -Parent $validationFile) -Force | Out-Null
  @{ schema_version = 1; plugin_root = $installedRoot; source_root = $sourceRoot; generation_key = $generationKey; revision = $revision; contract_fingerprint = $contract } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath $validationFile

  $runtimeKey = "contract=$($contract.ToLowerInvariant());backend=$($backend.ToLowerInvariant());dashboard=$($backend.ToLowerInvariant())"
  $state.plugin_root = $installedRoot
  $state.runtime_kind = "artifact"
  $state.runtime_mode = "artifact"
  $state.runtime_key = $runtimeKey
  $state.frontend.status = "artifact_static"
  $state.frontend.origin = $backend
  $state.frontend.url = "$backend/sympp/board"
  $state.frontend.port = $backendPort
  $state.frontend.managed = $false
  $state.frontend.pid = $null
  $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $runtimeFile

  $installedEnvironment = @{
    SYMPP_HOME = $sourceEnvironment.SYMPP_HOME; SYMPP_RUNTIME_FILE = $runtimeFile
    SYMPP_LOG_DIR = $sourceEnvironment.SYMPP_LOG_DIR; SYMPP_LAUNCHER_TRACE_DIR = Join-Path $tempRoot "trace"
    SYMPP_STARTUP_LOCK_TIMEOUT_SEC = "30"; SYMPP_MCP_HTTP_TIMEOUT_SEC = "60"
  }
  $node = (Get-Command node.exe -ErrorAction Stop).Source
  $bridge = Join-Path $installedRoot "scripts/start-sympp-mcp-bridge.js"
  $firstBridgeLog = Invoke-McpBridge $node @($bridge) $installedEnvironment
  Start-Sleep -Milliseconds $IdleMilliseconds
  $afterIdle = Get-Process -Id $backendProcessId -ErrorAction SilentlyContinue
  if (-not $afterIdle) { throw "Artifact backend stopped after idle detach. Bridge diagnostics: $firstBridgeLog" }
  if ($afterIdle.StartTime.ToUniversalTime().Ticks -ne $backendStartTicks) { throw "Artifact backend PID identity changed after last detach." }
  Invoke-McpBridge $node @($bridge) $installedEnvironment
  $afterSecondWave = Get-Process -Id $backendProcessId -ErrorAction Stop
  if ($afterSecondWave.StartTime.ToUniversalTime().Ticks -ne $backendStartTicks) { throw "Second bridge wave did not reuse the artifact backend PID." }

  $installedLauncher = Join-Path $installedRoot "scripts/start-sympp-mcp.ps1"
  [void](Invoke-IsolatedCommand $pwsh @("-NoProfile", "-File", $installedLauncher, "-CleanupRuntimeKey", "superseded-$runtimeKey") $installedEnvironment)
  [void](Get-Process -Id $backendProcessId -ErrorAction Stop)
  [void](Invoke-IsolatedCommand $pwsh @("-NoProfile", "-File", $installedLauncher, "-CleanupRuntimeKey", $runtimeKey) $installedEnvironment)
  Wait-ProcessStopped $backendProcessId
  $backendProcessId = $null

  [void](Invoke-IsolatedCommand $pwsh @("-NoProfile", "-File", $launcher, "-PrepareRuntimeOnly") $sourceEnvironment)
  $sourceState = Get-Content -LiteralPath $runtimeFile -Raw | ConvertFrom-Json
  $sourceProcessId = [int]$sourceState.backend.pid
  $frontendProcessId = [int]$sourceState.frontend.pid
  $backendProcessId = $sourceProcessId
  $backendStartTicks = (Get-Process -Id $sourceProcessId -ErrorAction Stop).StartTime.ToUniversalTime().Ticks
  Invoke-McpBridge $pwsh @("-NoProfile", "-File", $launcher) $sourceEnvironment
  Wait-ProcessStopped $sourceProcessId
  $backendProcessId = $null
  $frontendProcessId = $null

  [pscustomobject]@{
    artifact_waves = 2; initialize_and_tools_list = 2; artifact_pid_reused = $true
    stale_cleanup_preserved_current = $true; explicit_cleanup_stopped_exact = $true
    source_last_detach_stopped = $true; isolated_runtime_ledger_ports = $true
  } | ConvertTo-Json -Compress
} finally {
  if ($frontendProcessId) { Stop-Process -Id $frontendProcessId -Force -ErrorAction SilentlyContinue }
  if ($backendProcessId -and $backendStartTicks) {
    $backendProcess = Get-Process -Id $backendProcessId -ErrorAction SilentlyContinue
    if ($backendProcess -and $backendProcess.StartTime.ToUniversalTime().Ticks -eq $backendStartTicks) { Stop-Process -Id $backendProcessId -Force }
  }
  $ownedRoot = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd("\") + "\"
  if (-not ([System.IO.Path]::GetFullPath($tempRoot).StartsWith($ownedRoot, [StringComparison]::OrdinalIgnoreCase))) { throw "Cleanup abort: temp root escaped the launcher test directory." }
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
