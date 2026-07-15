<#
.SYNOPSIS
Measures the shipped Symphony++ MCP command against a disposable marketplace install.
#>
[CmdletBinding()]
param(
  [string]$Cohorts = "1,10,100",
  [ValidateRange(1, 10)][int]$Repeats = 1,
  [ValidateRange(30, 900)][int]$StartupTimeoutSec = 300,
  [ValidateSet("NodePresent", "NodeMissing")][string]$LauncherMode = "NodePresent",
  [switch]$SkipMutationCheck,
  [switch]$Help
)

$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../.."))
$sourcePluginRoot = Join-Path $repoRoot "plugins/symphony-plus-plus-mcp"
$revision = ([string](& git -C $repoRoot rev-parse HEAD)).Trim()
$pluginVersion = [string]((Get-Content -LiteralPath (Join-Path $sourcePluginRoot ".codex-plugin/plugin.json") -Raw | ConvertFrom-Json).version)
$ownedPrefix = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".exact-"))
$tempRoot = $ownedPrefix + [guid]::NewGuid().ToString("N")
$codexHome = Join-Path $tempRoot "codex"
$marketplaceName = "benchmark"
$pluginRoot = Join-Path $codexHome "plugins/cache/$marketplaceName/symphony-plus-plus-mcp/$pluginVersion"
$marketplaceRoot = Join-Path $codexHome ".tmp/marketplaces/$marketplaceName"
$runtimeFile = Join-Path $tempRoot "runtime/codex-plugin.json"
$traceDir = Join-Path $tempRoot "trace"
$gitLogDir = Join-Path $tempRoot "git-invocations"
$clients = [System.Collections.Generic.List[object]]::new()
$runtimeState = $null
$backendStartTicks = 0L
$backendPort = 0
$result = $null
$startupBurst = 10
$cohortValues = @($Cohorts -split "," | ForEach-Object { [int]$_.Trim() })
if ($cohortValues.Count -eq 0 -or @($cohortValues | Where-Object { $_ -notin @(1, 10, 100) }).Count -gt 0) {
  throw "-Cohorts must be a comma-separated subset of 1,10,100."
}

function New-IsolatedPort {
  do {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try { $listener.Start(); $port = [int]$listener.LocalEndpoint.Port } finally { $listener.Stop() }
  } while ($port -in @(19998, 19999))
  return $port
}

function Get-ListenerPids([int]$Port) {
  return @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
}

function Get-LeaseCount {
  return @(Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $runtimeFile) "codex-plugin-leases") -Filter "bridge-*.json" -File -ErrorAction SilentlyContinue).Count
}

function Get-TraceCounts {
  $counts = @{}
  foreach ($line in @(Get-ChildItem -LiteralPath $traceDir -Filter "*.log" -File -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -LiteralPath $_.FullName })) {
    $name = ([string]$line).Trim()
    if ($name) { $counts[$name] = 1 + [int]$counts[$name] }
  }
  return $counts
}

function Get-GitInvocationCount {
  return @(Get-ChildItem -LiteralPath $gitLogDir -Filter "*.log" -File -ErrorAction SilentlyContinue).Count
}

function Get-Percentile([double[]]$Values, [double]$Percentile) {
  $sorted = @($Values | Sort-Object)
  if ($sorted.Count -eq 0) { return 0 }
  return [double]$sorted[[Math]::Max(0, [Math]::Ceiling($sorted.Count * $Percentile) - 1)]
}

function Set-SanitizedEnvironment($Info, [hashtable]$Environment) {
  foreach ($key in @($Info.Environment.Keys)) {
    if ([string]$key -match "(?i)(TOKEN|SECRET|API_KEY|AUTHORIZATION|GITHUB|LINEAR|OPENAI)" -or
        [string]$key -in @("SYMPP_REPO_ROOT", "SYMPP_BACKEND_URL", "SYMPP_DASHBOARD_ORIGIN", "SYMPP_DATABASE")) {
      [void]$Info.Environment.Remove([string]$key)
    }
  }
  foreach ($entry in $Environment.GetEnumerator()) { $Info.Environment[$entry.Key] = [string]$entry.Value }
}

function Start-ExactClient([hashtable]$Environment) {
  $config = Get-Content -LiteralPath (Join-Path $pluginRoot ".mcp.json") -Raw | ConvertFrom-Json
  $server = $config.symphony_plus_plus
  $info = [System.Diagnostics.ProcessStartInfo]::new()
  $info.FileName = [string]$server.command
  foreach ($arg in @($server.args)) { [void]$info.ArgumentList.Add([string]$arg) }
  $info.WorkingDirectory = $pluginRoot
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardInput = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  Set-SanitizedEnvironment $info $Environment
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $info
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  if (-not $process.Start()) { throw "Exact shipped MCP command failed to start." }
  $process.StandardInput.AutoFlush = $true
  $process.StandardInput.WriteLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"sympp-exact-benchmark","version":"1"},"capabilities":{}}}')
  $client = [pscustomobject]@{
    process = $process
    watch = $watch
    line_task = $process.StandardOutput.ReadLineAsync()
    stderr_task = $process.StandardError.ReadToEndAsync()
    ready = $false
    elapsed_ms = 0.0
  }
  $clients.Add($client)
  return $client
}

function Wait-ClientsReady([object[]]$Cohort, [int]$TimeoutSec) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
  while (@($Cohort | Where-Object { -not $_.ready }).Count -gt 0) {
    foreach ($client in @($Cohort | Where-Object { -not $_.ready })) {
      if ($client.line_task.IsCompleted) {
        $client.watch.Stop()
        $line = $client.line_task.GetAwaiter().GetResult()
        if ([string]::IsNullOrWhiteSpace($line)) {
          $detail = if ($client.process.HasExited) { $client.stderr_task.GetAwaiter().GetResult().Trim() } else { "stdout closed before initialize" }
          throw "Exact client failed initialize: $detail"
        }
        $response = $line | ConvertFrom-Json
        if ($null -eq $response.result -or $response.error) { throw "Exact client returned an invalid initialize response: $line" }
        $client.elapsed_ms = $client.watch.Elapsed.TotalMilliseconds
        $client.ready = $true
        $client.process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
      } elseif ($client.process.HasExited) {
        throw "Exact client exited before initialize: $($client.stderr_task.GetAwaiter().GetResult().Trim())"
      }
    }
    if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for exact-command initialize." }
    Start-Sleep -Milliseconds 5
  }
}

function Stop-ExactClient($Client) {
  if ($null -eq $Client -or $null -eq $Client.process) { return }
  try { $Client.process.StandardInput.Close() } catch { }
  if (-not $Client.process.WaitForExit(60000)) {
    $Client.process.Kill($true)
    [void]$Client.process.WaitForExit(15000)
  }
  $Client.process.Dispose()
  $Client.process = $null
}

function Get-ProcessTreeMetrics([object[]]$Cohort, [int]$ExcludedPid) {
  $rows = @(Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name)
  $children = @{}
  foreach ($row in $rows) {
    $key = [int]$row.ParentProcessId
    if (-not $children.ContainsKey($key)) { $children[$key] = [System.Collections.Generic.List[int]]::new() }
    $children[$key].Add([int]$row.ProcessId)
  }
  $detail = foreach ($client in $Cohort) {
    $pending = [System.Collections.Generic.Queue[int]]::new()
    $pending.Enqueue([int]$client.process.Id)
    $ids = [System.Collections.Generic.List[int]]::new()
    while ($pending.Count -gt 0) {
      $id = $pending.Dequeue()
      if ($id -ne $ExcludedPid -and -not $ids.Contains($id)) { $ids.Add($id) }
      if ($children.ContainsKey($id)) { foreach ($child in $children[$id]) { $pending.Enqueue($child) } }
    }
    $privateBytes = 0L
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $ids) {
      $process = Get-Process -Id $id -ErrorAction SilentlyContinue
      if ($process) { $privateBytes += [long]$process.PrivateMemorySize64; $names.Add("$($process.ProcessName):$($process.PrivateMemorySize64)") }
    }
    [pscustomobject]@{ root_pid = [int]$client.process.Id; processes = $ids.Count; private_bytes = $privateBytes; names = @($names) }
  }
  $bytes = @($detail.private_bytes)
  $counts = @($detail.processes)
  return [pscustomobject]@{
    total_private_bytes = [long](($bytes | Measure-Object -Sum).Sum)
    median_private_bytes_per_client = Get-Percentile $bytes 0.50
    p95_private_bytes_per_client = Get-Percentile $bytes 0.95
    max_private_bytes_per_client = Get-Percentile $bytes 1.0
    total_processes = [int](($counts | Measure-Object -Sum).Sum)
    min_processes_per_client = Get-Percentile $counts 0.0
    median_processes_per_client = Get-Percentile $counts 0.50
    node_clients = @($detail | Where-Object { [string]($_.names -join ",") -match "(^|,)node:" }).Count
    clients = @($detail)
  }
}

function Invoke-Cohort([int]$Count, [hashtable]$Environment, [int]$BackendPid) {
  $gitBefore = Get-GitInvocationCount
  $traceBefore = Get-TraceCounts
  $cohort = [System.Collections.Generic.List[object]]::new()
  for ($offset = 0; $offset -lt $Count; $offset += $startupBurst) {
    $batchCount = [Math]::Min($startupBurst, $Count - $offset)
    $batch = @(foreach ($index in 1..$batchCount) { Start-ExactClient $Environment })
    Wait-ClientsReady $batch $StartupTimeoutSec
    foreach ($client in $batch) { $cohort.Add($client) }
  }
  $tree = Get-ProcessTreeMetrics $cohort $BackendPid
  $samples = @($cohort.elapsed_ms | Sort-Object)
  $leasePeak = Get-LeaseCount
  $gitAfter = Get-GitInvocationCount
  $traceAfter = Get-TraceCounts
  $traceDelta = @{}
  foreach ($name in @($traceAfter.Keys + $traceBefore.Keys | Select-Object -Unique)) { $traceDelta[$name] = [int]$traceAfter[$name] - [int]$traceBefore[$name] }
  foreach ($client in $cohort) { Stop-ExactClient $client }
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while ((Get-LeaseCount) -gt 1 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
  return [pscustomobject]@{
    clients = $Count
    startup_burst = [Math]::Min($startupBurst, $Count)
    p50_initialize_ms = [Math]::Round((Get-Percentile $samples 0.50), 2)
    p95_initialize_ms = [Math]::Round((Get-Percentile $samples 0.95), 2)
    max_initialize_ms = [Math]::Round((Get-Percentile $samples 1.0), 2)
    process_tree = $tree
    leases_peak = $leasePeak
    leases_after = Get-LeaseCount
    git_invocations = $gitAfter - $gitBefore
    trace = $traceDelta
  }
}

function Test-Dashboard([string]$Url) {
  try { return (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } catch { return $false }
}

function Copy-SourcePlugin([string]$Destination) {
  $prefix = "plugins/symphony-plus-plus-mcp/"
  $files = @(& git -C $repoRoot ls-files --cached -- $prefix)
  $newBridge = $prefix + "scripts/start-sympp-mcp-bridge.js"
  if (Test-Path -LiteralPath (Join-Path $repoRoot $newBridge)) { $files += $newBridge }
  if ($LASTEXITCODE -ne 0 -or $files.Count -eq 0) { throw "Could not enumerate the source plugin payload." }
  foreach ($repoRelative in $files) {
    $pluginRelative = ([string]$repoRelative).Substring($prefix.Length)
    $target = Join-Path $Destination $pluginRelative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot $repoRelative) -Destination $target -Force
  }
}

if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }
if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { throw "Get-NetTCPConnection is required." }
if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { throw "Get-CimInstance is required." }

try {
  foreach ($path in @(
      $pluginRoot, (Join-Path $marketplaceRoot "elixir"),
      (Join-Path $marketplaceRoot "plugins/symphony-plus-plus/.codex-plugin"),
      (Join-Path $marketplaceRoot "plugins/symphony-plus-plus-mcp"),
      (Join-Path $marketplaceRoot "implementation_docs_symphplusplus/mcp"),
      (Split-Path -Parent $runtimeFile), $traceDir, $gitLogDir, (Join-Path $tempRoot "shim"),
      (Join-Path $tempRoot "profile"), (Join-Path $tempRoot "logs")
    )) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
  Copy-SourcePlugin $pluginRoot
  Copy-SourcePlugin (Join-Path $marketplaceRoot "plugins/symphony-plus-plus-mcp")
  Copy-Item -LiteralPath (Join-Path $repoRoot "plugins/symphony-plus-plus/.codex-plugin/plugin.json") -Destination (Join-Path $marketplaceRoot "plugins/symphony-plus-plus/.codex-plugin/plugin.json") -Force
  Copy-Item -LiteralPath (Join-Path $repoRoot "elixir/mix.exs") -Destination (Join-Path $marketplaceRoot "elixir/mix.exs") -Force
  Copy-Item -LiteralPath (Join-Path $repoRoot "implementation_docs_symphplusplus/mcp/mcp_tools_contract.json") -Destination (Join-Path $marketplaceRoot "implementation_docs_symphplusplus/mcp/mcp_tools_contract.json") -Force
  Set-Content -LiteralPath (Join-Path $pluginRoot ".sympp-source-revision") -Value $revision -Encoding utf8NoBOM
  @{ source_type = "git"; source = "benchmark"; ref_name = "main"; sparse_paths = @(); revision = $revision } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $marketplaceRoot ".codex-marketplace-install.json") -Encoding utf8NoBOM

  $realGit = (Get-Command git.exe -ErrorAction Stop).Source
  $shim = @"
@echo off
>"%SYMPP_BENCH_GIT_LOG_DIR%\git-%RANDOM%-%RANDOM%.log" echo git
"$realGit" %*
exit /b %ERRORLEVEL%
"@
  Set-Content -LiteralPath (Join-Path $tempRoot "shim/git.cmd") -Value $shim -Encoding ascii -NoNewline

  $backendPort = New-IsolatedPort
  if ((Get-ListenerPids $backendPort).Count -ne 0) { throw "Selected benchmark port was not empty." }
  $effectivePath = $env:PATH
  if ($LauncherMode -eq "NodeMissing") {
    $node = Get-Command node.exe -ErrorAction Stop | Select-Object -First 1
    $nodeDirectory = [System.IO.Path]::GetFullPath((Split-Path -Parent $node.Source)).TrimEnd("\")
    $effectivePath = (@($env:PATH -split ";" | Where-Object {
          $_ -and -not [System.IO.Path]::GetFullPath($_).TrimEnd("\").Equals($nodeDirectory, [System.StringComparison]::OrdinalIgnoreCase)
        }) -join ";")
  }
  $environment = @{
    SYMPP_HOME = Join-Path $tempRoot "home"
    SYMPP_RUNTIME_FILE = $runtimeFile
    SYMPP_LOG_DIR = Join-Path $tempRoot "logs"
    SYMPP_BACKEND_PORT = [string]$backendPort
    SYMPP_DASHBOARD_PORT = [string]$backendPort
    SYMPP_OPEN_DASHBOARD = "0"
    SYMPP_MCP_BRIDGE_MODE = "http"
    SYMPP_ARTIFACT_RUNTIME = "1"
    SYMPP_MCP_CLIENT_HEARTBEAT_SEC = "5"
    SYMPP_BACKEND_STARTUP_TIMEOUT_SEC = [string]$StartupTimeoutSec
    SYMPP_STARTUP_LOCK_TIMEOUT_SEC = "1800"
    SYMPP_LAUNCHER_TRACE_DIR = $traceDir
    SYMPP_BENCH_GIT_LOG_DIR = $gitLogDir
    HOME = Join-Path $tempRoot "profile"
    PATH = (Join-Path $tempRoot "shim") + ";" + $effectivePath
  }

  [Console]::Error.WriteLine("Starting exact-command artifact cold client on port $backendPort...")
  $cold = Start-ExactClient $environment
  Wait-ClientsReady @($cold) $StartupTimeoutSec
  $runtimeState = Get-Content -LiteralPath $runtimeFile -Raw | ConvertFrom-Json
  if ([string]$runtimeState.runtime_mode -ne "artifact" -or [string]$runtimeState.frontend.status -ne "artifact_static") { throw "Cold exact command did not start the artifact dashboard runtime." }
  if (-not (Test-Dashboard ([string]$runtimeState.frontend.url))) { throw "Artifact dashboard was not healthy." }
  $owners = @(Get-ListenerPids $backendPort)
  if ($owners.Count -ne 1 -or [int]$owners[0] -ne [int]$runtimeState.backend.pid) { throw "Cold exact command did not own one backend singleton." }
  $backend = Get-Process -Id ([int]$runtimeState.backend.pid) -ErrorAction Stop
  $backendStartTicks = $backend.StartTime.ToUniversalTime().Ticks
  $coldMetrics = [pscustomobject]@{
    initialize_ms = [Math]::Round($cold.elapsed_ms, 2)
    backend_pid = $backend.Id
    backend_start_ticks = $backendStartTicks
    dashboard_healthy = $true
    runtime_mode = [string]$runtimeState.runtime_mode
    trace = Get-TraceCounts
    git_invocations = Get-GitInvocationCount
  }

  $warmResults = [System.Collections.Generic.List[object]]::new()
  foreach ($repeat in 1..$Repeats) {
    foreach ($count in $cohortValues) {
      [Console]::Error.WriteLine("Measuring exact-command warm cohort repeat=$repeat clients=$count...")
      $cohort = Invoke-Cohort $count $environment $backend.Id
      if ($cohort.leases_peak -ne ($count + 1) -or $cohort.leases_after -ne 1) { throw "Warm cohort lease lifecycle mismatch." }
      $currentOwners = @(Get-ListenerPids $backendPort)
      if ($currentOwners.Count -ne 1 -or [int]$currentOwners[0] -ne $backend.Id) { throw "Warm cohort changed singleton identity." }
      $cohort | Add-Member -NotePropertyName repeat -NotePropertyValue $repeat
      $warmResults.Add($cohort)
    }
  }

  $lockRecovery = [pscustomobject]@{ checked = $false; reclaimed = $null }
  $lifecycleRace = [pscustomobject]@{ checked = $false; healthy = $null; backend_reused = $null }
  if ($LauncherMode -eq "NodePresent") {
    $lockRecovery.checked = $true
    $identityDir = Join-Path $environment.SYMPP_HOME "runtime/launcher-validation"
    $generationMarker = @(Get-ChildItem -LiteralPath $identityDir -Filter "*.generation" -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($generationMarker.Count -ne 1) { throw "Exact Node launcher did not publish a generation marker." }
    $generationLock = "$($generationMarker[0].FullName).lock"
    $healthCache = Join-Path (Split-Path -Parent $runtimeFile) "codex-plugin-health.json"
    $healthLock = "$healthCache.lock"
    $staleOwner = @{ lock_id = "abandoned"; owner_pid = 2147483647; owner_pipe = "\\.\pipe\sympp-missing"; owner_token = "abandoned" } | ConvertTo-Json -Compress
    Remove-Item -LiteralPath $generationMarker[0].FullName -Force
    Remove-Item -LiteralPath $healthCache -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $generationLock -Value $staleOwner -Encoding utf8NoBOM
    Set-Content -LiteralPath $healthLock -Value $staleOwner -Encoding utf8NoBOM
    $reclaimedBefore = [int](Get-TraceCounts)["abandoned_lock_reclaimed"]
    $lockClient = Start-ExactClient $environment
    Wait-ClientsReady @($lockClient) $StartupTimeoutSec
    Stop-ExactClient $lockClient
    $reclaimedAfter = [int](Get-TraceCounts)["abandoned_lock_reclaimed"]
    $lockRecovery.reclaimed = $reclaimedAfter - $reclaimedBefore -ge 2 -and
      -not (Test-Path -LiteralPath $generationLock) -and -not (Test-Path -LiteralPath $healthLock)
    if (-not $lockRecovery.reclaimed) { throw "Exact Node launcher did not reclaim abandoned validation locks." }

    $lifecycleRace.checked = $true
    [Console]::Error.WriteLine("Racing a fresh attach against last-detach cleanup...")
    $previousBackendPid = $backend.Id
    $cold.process.StandardInput.Close()
    $raceClient = Start-ExactClient $environment
    Wait-ClientsReady @($raceClient) $StartupTimeoutSec
    if (-not $cold.process.WaitForExit(60000)) { throw "Previous anchor did not exit during lifecycle race." }
    $cold.process.Dispose()
    $cold.process = $null
    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSec)
    do {
      try { $raceState = Get-Content -LiteralPath $runtimeFile -Raw | ConvertFrom-Json } catch { $raceState = $null }
      $raceOwners = @(Get-ListenerPids $backendPort)
      $lifecycleRace.healthy = $raceState -and $raceOwners.Count -eq 1 -and
        [int]$raceOwners[0] -eq [int]$raceState.backend.pid -and (Test-Dashboard ([string]$raceState.frontend.url))
      if ($lifecycleRace.healthy) { break }
      Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $lifecycleRace.healthy) { throw "Attach versus last-detach cleanup did not leave one healthy runtime." }
    $lifecycleRace.backend_reused = [int]$raceState.backend.pid -eq $previousBackendPid
    $cold = $raceClient
    $runtimeState = $raceState
    $backend = Get-Process -Id ([int]$raceState.backend.pid) -ErrorAction Stop
    $backendStartTicks = $backend.StartTime.ToUniversalTime().Ticks
  }

  [Console]::Error.WriteLine("Killing the artifact backend and measuring automatic recovery...")
  Stop-Process -Id $backend.Id -Force -ErrorAction Stop
  [void]$backend.WaitForExit(30000)
  $recovery = Start-ExactClient $environment
  Wait-ClientsReady @($recovery) $StartupTimeoutSec
  $recoveredState = Get-Content -LiteralPath $runtimeFile -Raw | ConvertFrom-Json
  if ([int]$recoveredState.backend.pid -eq $backend.Id -or -not (Test-Dashboard ([string]$recoveredState.frontend.url))) { throw "Backend kill did not recover a fresh artifact dashboard runtime." }
  $recovered = Get-Process -Id ([int]$recoveredState.backend.pid) -ErrorAction Stop
  $runtimeState = $recoveredState
  $backendStartTicks = $recovered.StartTime.ToUniversalTime().Ticks
  $recoveryMetrics = [pscustomobject]@{
    initialize_ms = [Math]::Round($recovery.elapsed_ms, 2)
    previous_backend_pid = $backend.Id
    backend_pid = $recovered.Id
    dashboard_healthy = $true
  }
  Stop-ExactClient $recovery

  $mutation = [pscustomobject]@{ checked = $false; shortcut_rejected = $null; scan_race_retried = $null; attach_race_rejected = $null }
  if (-not $SkipMutationCheck) {
    $mutation.checked = $true
    $mutationFile = Join-Path $pluginRoot "scripts/start-sympp-mcp.ps1"
    if ($LauncherMode -eq "NodePresent") {
      Remove-Item -LiteralPath $generationMarker[0].FullName -Force -ErrorAction SilentlyContinue
      $originalBytes = [System.IO.File]::ReadAllBytes($mutationFile)
      $originalWriteTime = [System.IO.File]::GetLastWriteTimeUtc($mutationFile)
      $scanBefore = [int](Get-TraceCounts)["generation_scan_complete"]
      $retryBefore = [int](Get-TraceCounts)["generation_scan_retry"]
      $scanClient = Start-ExactClient $environment
      $deadline = [DateTime]::UtcNow.AddSeconds(60)
      while ([int](Get-TraceCounts)["generation_scan_complete"] -le $scanBefore -and -not $scanClient.process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 5 }
      if ([int](Get-TraceCounts)["generation_scan_complete"] -le $scanBefore) { throw "Mutation race did not observe an in-progress generation scan." }
      [System.IO.File]::AppendAllText($mutationFile, "`n# transient benchmark mutation")
      [System.IO.File]::WriteAllBytes($mutationFile, $originalBytes)
      [System.IO.File]::SetLastWriteTimeUtc($mutationFile, $originalWriteTime)
      Wait-ClientsReady @($scanClient) $StartupTimeoutSec
      $mutation.scan_race_retried = [int](Get-TraceCounts)["generation_scan_retry"] -gt $retryBefore
      Stop-ExactClient $scanClient
      if (-not $mutation.scan_race_retried) { throw "Installed payload mutation during generation scan did not force a retry." }
    }
    $attachBefore = [int](Get-TraceCounts)["generation_attach_preflight"]
    $mutated = Start-ExactClient $environment
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    if ($LauncherMode -eq "NodePresent") {
      while ([int](Get-TraceCounts)["generation_attach_preflight"] -le $attachBefore -and -not $mutated.process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 5 }
      if ([int](Get-TraceCounts)["generation_attach_preflight"] -le $attachBefore) { throw "Mutation race did not reach the generation-pinned attachment boundary." }
    }
    Add-Content -LiteralPath $mutationFile -Value "`n# benchmark mutation"
    while (-not $mutated.process.HasExited -and -not $mutated.line_task.IsCompleted -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    $mutation.shortcut_rejected = $mutated.process.HasExited -and
      $mutated.line_task.IsCompleted -and
      [string]::IsNullOrWhiteSpace([string]$mutated.line_task.GetAwaiter().GetResult())
    $mutation.attach_race_rejected = $LauncherMode -ne "NodePresent" -or ([int](Get-TraceCounts)["warm_miss_generation"] -gt 0 -and $mutation.shortcut_rejected)
    if ($LauncherMode -ne "NodePresent") { $mutation.scan_race_retried = $true }
    Stop-ExactClient $mutated
    if (-not $mutation.shortcut_rejected -or -not $mutation.attach_race_rejected) { throw "Installed payload mutation at the attachment boundary was not rejected before warm attach." }
  }

  $result = [pscustomobject]@{
    revision = $revision
    launcher_mode = $LauncherMode
    command = "cmd.exe /d /s /c scripts\start-sympp-mcp.cmd"
    backend_port = $backendPort
    cold = $coldMetrics
    warm = @($warmResults)
    lock_recovery = $lockRecovery
    lifecycle_race = $lifecycleRace
    recovery = $recoveryMetrics
    mutation = $mutation
  }
} catch {
  $diagnostics = [System.Collections.Generic.List[string]]::new()
  foreach ($log in @(Get-ChildItem -LiteralPath $tempRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.(err|out)\.log$' })) {
    $rawContent = Get-Content -LiteralPath $log.FullName -Raw -ErrorAction SilentlyContinue
    $content = if ($null -eq $rawContent) { "" } else { $rawContent.Trim() }
    if ($content) { $diagnostics.Add("$($log.Name): $content") }
  }
  if ($diagnostics.Count) { [Console]::Error.WriteLine(($diagnostics -join "`n")) }
  [Console]::Error.WriteLine("trace: $((Get-TraceCounts | ConvertTo-Json -Compress)) git_invocations=$(Get-GitInvocationCount)")
  throw
} finally {
  foreach ($client in @($clients)) { if ($client.process) { Stop-ExactClient $client } }
  if ((-not $runtimeState -or -not $runtimeState.backend) -and (Test-Path -LiteralPath $runtimeFile -PathType Leaf)) {
    try { $runtimeState = Get-Content -LiteralPath $runtimeFile -Raw | ConvertFrom-Json } catch { $runtimeState = $null }
    if ($runtimeState -and $runtimeState.backend) {
      $process = Get-Process -Id ([int]$runtimeState.backend.pid) -ErrorAction SilentlyContinue
      if ($process) { $backendStartTicks = $process.StartTime.ToUniversalTime().Ticks }
    }
  }
  if ($runtimeState -and $runtimeState.backend -and $backendStartTicks) {
    $process = Get-Process -Id ([int]$runtimeState.backend.pid) -ErrorAction SilentlyContinue
    if ($process -and $process.StartTime.ToUniversalTime().Ticks -eq $backendStartTicks) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
  }
  if ($backendPort) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ((Get-ListenerPids $backendPort).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if ((Get-ListenerPids $backendPort).Count -gt 0) { throw "Benchmark cleanup left port $backendPort occupied." }
  }
  $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
  if (-not $resolvedTemp.StartsWith($ownedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Benchmark cleanup root escaped its owned prefix." }
  Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $resolvedTemp) { throw "Benchmark cleanup did not remove its isolated root." }
}

$result | ConvertTo-Json -Depth 12
