param([int]$Clients = 20)
$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../../.."))
$launcher = Join-Path $repoRoot "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1"
$tempRoot = Join-Path $PSScriptRoot (".cold-production-" + [guid]::NewGuid().ToString("N"))
$runtimeFile = Join-Path $tempRoot "state/runtime.json"
$logDir = Join-Path $tempRoot "logs"
$database = Join-Path $tempRoot "database/ledger.sqlite3"
$mixBuildRoot = Join-Path $tempRoot "mix-build"
$mixHome = Join-Path $tempRoot "mix-home"
$hexHome = Join-Path $tempRoot "hex-home"
$jobs = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$runtimeState = $null
$backendStartTicks = $null
function New-IsolatedPort([int[]]$Avoid) {
  do {
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try { $probe.Start(); $port = [int]$probe.LocalEndpoint.Port } finally { $probe.Stop() }
  } while ($port -in $Avoid -or $port -in @(19998, 19999))
  return $port
}
function Get-ListenerPids([int]$Port) {
  if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { throw "Get-NetTCPConnection is required for isolated port ownership checks." }
  return @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
}
function Assert-NoListener([int]$Port) {
  if (@(Get-ListenerPids $Port).Count -ne 0) { throw "Isolation abort: port $Port already has a listener." }
  $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
  try { $probe.Start() } catch { throw "Isolation abort: port $Port cannot be exclusively bound." } finally { $probe.Stop() }
  if (@(Get-ListenerPids $Port).Count -ne 0) { throw "Isolation abort: port $Port gained a listener before launch." }
}

function Start-IsolatedLauncher([hashtable]$Environment) {
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = (Get-Command pwsh -ErrorAction Stop).Source
  [void]$psi.ArgumentList.Add("-NoProfile")
  [void]$psi.ArgumentList.Add("-File")
  [void]$psi.ArgumentList.Add($launcher)
  $psi.WorkingDirectory = $repoRoot
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  foreach ($key in @($psi.Environment.Keys)) {
    if ([string]$key -match "(?i)(TOKEN|SECRET|API_KEY|AUTHORIZATION|GITHUB|LINEAR|OPENAI)" -or
        [string]$key -in @("SYMPP_BACKEND_URL", "SYMPP_DASHBOARD_ORIGIN")) {
      [void]$psi.Environment.Remove([string]$key)
    }
  }
  foreach ($entry in $Environment.GetEnumerator()) { $psi.Environment[$entry.Key] = [string]$entry.Value }
  $process = [System.Diagnostics.Process]::Start($psi)
  if (-not $process) { throw "Failed to start isolated launcher client." }
  return $process
}

function Read-IsolatedState {
  if (-not (Test-Path -LiteralPath $runtimeFile -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $runtimeFile -Raw | ConvertFrom-Json } catch { return $null }
}

try {
  foreach ($path in @(
      $tempRoot, (Split-Path -Parent $runtimeFile), $logDir, (Split-Path -Parent $database),
      $mixBuildRoot, $mixHome, $hexHome, (Join-Path $tempRoot "rebar"), (Join-Path $tempRoot "tmp"),
      (Join-Path $tempRoot "xdg/config"), (Join-Path $tempRoot "xdg/cache"), (Join-Path $tempRoot "xdg/data")
    )) { New-Item -ItemType Directory -Path $path -Force | Out-Null }

  $sourceMixHome = if ($env:MIX_HOME) { $env:MIX_HOME } else { Join-Path ([Environment]::GetFolderPath("UserProfile")) ".mix" }
  foreach ($name in @("archives", "elixir")) {
    $source = Join-Path $sourceMixHome $name
    if (Test-Path -LiteralPath $source -PathType Container) { Copy-Item -LiteralPath $source -Destination $mixHome -Recurse -Force }
  }
  $sourceHexHome = if ($env:HEX_HOME) { $env:HEX_HOME } else { Join-Path ([Environment]::GetFolderPath("UserProfile")) ".hex" }
  foreach ($name in @("packages", "cache.ets")) {
    $source = Join-Path $sourceHexHome $name
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $hexHome -Recurse -Force }
  }

  $backendPort = New-IsolatedPort @()
  $dashboardPort = New-IsolatedPort @($backendPort)
  Assert-NoListener $backendPort
  Assert-NoListener $dashboardPort
  $environment = @{
    SYMPP_REPO_ROOT = $repoRoot; SYMPP_HOME = Join-Path $tempRoot "runtime-home"
    SYMPP_RUNTIME_FILE = $runtimeFile; SYMPP_LOG_DIR = $logDir; SYMPP_DATABASE = $database
    SYMPP_BACKEND_PORT = [string]$backendPort; SYMPP_DASHBOARD_PORT = [string]$dashboardPort
    SYMPP_OPEN_DASHBOARD = "0"
    SYMPP_AUTOSTART_FRONTEND = "0"; SYMPP_MCP_BRIDGE_MODE = "http"; SYMPP_SOURCE_FALLBACK = "1"
    SYMPP_ARTIFACT_RUNTIME = "0"; SYMPP_LAUNCHER = "direct"; SYMPP_ELIXIR_SETUP_TIMEOUT_SEC = "600"
    MIX_BUILD_ROOT = $mixBuildRoot; MIX_HOME = $mixHome; HEX_HOME = $hexHome; HEX_OFFLINE = "1"
    REBAR_CACHE_DIR = Join-Path $tempRoot "rebar"; TEMP = Join-Path $tempRoot "tmp"; TMP = Join-Path $tempRoot "tmp"
    XDG_CONFIG_HOME = Join-Path $tempRoot "xdg/config"; XDG_CACHE_HOME = Join-Path $tempRoot "xdg/cache"; XDG_DATA_HOME = Join-Path $tempRoot "xdg/data"
  }
  foreach ($index in 1..$Clients) { $jobs.Add((Start-IsolatedLauncher $environment)) }

  $deadline = [DateTime]::UtcNow.AddMinutes(15)
  do {
    $exited = @($jobs | Where-Object { $_.HasExited })
    if ($exited.Count -gt 0) { throw "Isolated cold launcher exited before singleton readiness: $(@($exited.ExitCode) -join ',')." }
    $runtimeState = Read-IsolatedState
    $leases = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot "state/codex-plugin-leases") -Filter "bridge-*.json" -File -ErrorAction SilentlyContinue)
    if ($runtimeState -and [int]$runtimeState.backend.port -eq $backendPort -and
        [string]$runtimeState.backend.status -in @("started", "reused")) {
      if (-not $backendStartTicks) { $backendStartTicks = (Get-Process -Id ([int]$runtimeState.backend.pid) -ErrorAction Stop).StartTime.ToUniversalTime().Ticks }
      if ($leases.Count -eq $Clients) { break }
    }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  if (-not $runtimeState -or $leases.Count -ne $Clients) { throw "Timed out waiting for isolated cold singleton and $Clients bridge leases." }

  $owners = @(Get-ListenerPids $backendPort)
  if ($owners.Count -ne 1 -or [int]$owners[0] -ne [int]$runtimeState.backend.pid) { throw "Cold backend listener is not uniquely owned by the recorded runtime." }
  if (@(Get-ListenerPids $dashboardPort).Count -ne 0) { throw "Disabled isolated dashboard unexpectedly has a listener." }
  if (-not (Test-Path -LiteralPath $database -PathType Leaf)) { throw "Isolated backend did not create its database." }
  [pscustomobject]@{
    clients = $Clients; singleton_creations = 1; backend_processes = $owners.Count
    leases_peak = $leases.Count; preflight_listeners = 0; isolated_roots = $true
    backend_port = $backendPort; dashboard_port = $dashboardPort
  } | ConvertTo-Json -Compress
} finally {
  foreach ($job in $jobs) {
    try { $job.StandardInput.Close() } catch { }
    if (-not $job.WaitForExit(60000)) { $job.Kill($true); [void]$job.WaitForExit(15000) }
    $job.Dispose()
  }
  if ($runtimeState -and $backendStartTicks) {
    $backend = Get-Process -Id ([int]$runtimeState.backend.pid) -ErrorAction SilentlyContinue
    if ($backend) {
      if ($backend.StartTime.ToUniversalTime().Ticks -ne $backendStartTicks -or [int]$runtimeState.backend.port -ne $backendPort) { throw "Cleanup abort: isolated backend PID identity changed." }
      Stop-Process -Id $backend.Id -Force -ErrorAction Stop
    }
  }
  $ownedRoot = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd("\") + "\"
  if (-not ([System.IO.Path]::GetFullPath($tempRoot).StartsWith($ownedRoot, [System.StringComparison]::OrdinalIgnoreCase))) { throw "Cleanup abort: temp root escaped the owned launcher-test directory." }
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
