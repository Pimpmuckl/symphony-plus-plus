<#
.SYNOPSIS
Measures the shipped Symphony++ MCP command against a disposable marketplace install.
#>
[CmdletBinding()]
param(
  [string]$Cohorts = "1,10,100",
  [ValidateRange(1, 100)][int]$ColdClients = 1,
  [ValidateRange(1, 10)][int]$Repeats = 1,
  [ValidateRange(30, 900)][int]$StartupTimeoutSec = 300,
  [ValidateRange(60, 1800)][int]$ArtifactPreparationTimeoutSec = 600,
  [ValidateSet("NodePresent", "NodeMissing")][string]$LauncherMode = "NodePresent",
  [switch]$SkipMutationCheck,
  [switch]$SkipLifecycleBarrier,
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
$probeStartedAt = [DateTime]::UtcNow
$result = $null
$probeFailure = $null
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

function Write-BenchmarkProgress([string]$Message) {
  [Console]::Error.WriteLine($Message)
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_PERFORMANCE_PROGRESS_FILE)) {
    [System.IO.File]::AppendAllText(
      $env:SYMPP_PERFORMANCE_PROGRESS_FILE,
      "$([DateTime]::UtcNow.ToString('O')) $Message$([Environment]::NewLine)"
    )
  }
}

function Get-TraceCounts {
  $counts = @{}
  foreach ($line in @(Get-ChildItem -LiteralPath $traceDir -Filter "*.log" -File -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -LiteralPath $_.FullName })) {
    $name = (([string]$line).Trim() -split "`t", 2)[0]
    if ($name) { $counts[$name] = 1 + [int]$counts[$name] }
  }
  return $counts
}

function Get-TraceDetails([string]$Event, [long]$SinceMs = 0) {
  return @(Get-ChildItem -LiteralPath $traceDir -Filter "*.log" -File -ErrorAction SilentlyContinue | ForEach-Object {
      foreach ($line in @(Get-Content -LiteralPath $_.FullName)) {
        $parts = ([string]$line).Trim() -split "`t", 2
        if ($parts[0] -eq $Event -and $parts.Count -eq 2) {
          try {
            $record = $parts[1] | ConvertFrom-Json
            if ([long]$record.at_ms -ge $SinceMs) { $record }
          } catch { }
        }
      }
    })
}

function Get-TraceFileOffsets {
  $offsets = [System.Collections.Generic.Dictionary[string, long]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($file in @(Get-ChildItem -LiteralPath $traceDir -Filter "*.log" -File -ErrorAction SilentlyContinue)) {
    $offsets[$file.FullName] = $file.Length
  }
  return $offsets
}

function Test-NewTraceEvent($ExistingOffsets, [string]$Event, [string]$ClientId = "") {
  foreach ($file in @(Get-ChildItem -LiteralPath $traceDir -Filter "*.log" -File -ErrorAction SilentlyContinue)) {
    $offset = if ($ExistingOffsets.ContainsKey($file.FullName)) { [long]$ExistingOffsets[$file.FullName] } else { 0L }
    if ($file.Length -le $offset) { continue }
    $stream = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      [void]$stream.Seek($offset, [System.IO.SeekOrigin]::Begin)
      $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true, 1024, $true)
      try { $appended = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
      $stream.Dispose()
    }
    foreach ($line in @($appended -split "`r?`n")) {
      $parts = $line -split "`t", 2
      if ($parts[0] -ne $Event) { continue }
      if ([string]::IsNullOrWhiteSpace($ClientId)) { return $true }
      if ($parts.Count -eq 2) {
        try { if ([string](($parts[1] | ConvertFrom-Json).test_client) -eq $ClientId) { return $true } } catch { }
      }
    }
  }
  return $false
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

function ConvertFrom-ArtifactPhaseTiming([string]$Stderr, [double]$ElapsedMs) {
  $line = @($Stderr -split "`r?`n" | Where-Object { $_ -like "artifact_phases:*" } | Select-Object -Last 1)
  if ($line.Count -ne 1) { throw "Exact-command runtime artifact preparation omitted phase timings." }
  $values = @{}
  foreach ($match in [regex]::Matches($line[0], '([a-z_]+)=([^ ]+)')) { $values[$match.Groups[1].Value] = $match.Groups[2].Value }
  return [pscustomobject]@{
    cache = [string]$values.cache
    process_ms = [Math]::Round($ElapsedMs, 2)
    lock_wait_ms = [double]$(if ($values.lock_wait_ms) { $values.lock_wait_ms } else { 0 })
    download_ms = [double]$values.download_ms
    hash_ms = [double]$values.hash_ms
    extract_ms = [double]$values.extract_ms
    dashboard_proof_ms = [double]$values.dashboard_proof_ms
    promotion_ms = [double]$values.promotion_ms
    total_ms = [double]$values.total_ms
  }
}

function Prepare-ExactArtifact([hashtable]$Environment) {
  $preparationEnvironment = @{} + $Environment
  $preparationEnvironment.SYMPP_LAUNCHER_TRACE_DIR = Join-Path $tempRoot "preparation-trace"
  $preparationEnvironment.SYMPP_BENCH_GIT_LOG_DIR = Join-Path $tempRoot "preparation-git-invocations"
  foreach ($path in @($preparationEnvironment.SYMPP_LAUNCHER_TRACE_DIR, $preparationEnvironment.SYMPP_BENCH_GIT_LOG_DIR)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }

  $info = [System.Diagnostics.ProcessStartInfo]::new()
  $info.FileName = Join-Path $PSHOME "pwsh.exe"
  foreach ($arg in @("-NoProfile", "-File", (Join-Path $pluginRoot "scripts/start-sympp-mcp.ps1"), "-ValidateOnly")) { [void]$info.ArgumentList.Add($arg) }
  $info.WorkingDirectory = $pluginRoot
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  Set-SanitizedEnvironment $info $preparationEnvironment

  Write-BenchmarkProgress "Pre-acquiring verified exact-command runtime artifact..."
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $process = [System.Diagnostics.Process]::new(); $process.StartInfo = $info
  if (-not $process.Start()) { throw "Exact-command runtime artifact preparation failed to start." }
  $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit($ArtifactPreparationTimeoutSec * 1000)) {
    try { $process.Kill($true) } catch { }
    [void]$process.WaitForExit(15000)
    $process.Dispose()
    throw "Exact-command runtime artifact preparation timed out."
  }
  $watch.Stop()
  $stdout = $stdoutTask.GetAwaiter().GetResult(); $stderr = $stderrTask.GetAwaiter().GetResult(); $exitCode = $process.ExitCode
  $process.Dispose()
  if ($exitCode -ne 0) { throw "Exact-command runtime artifact preparation failed: $($stdout.Trim()) $($stderr.Trim())" }
  $validationCache = [System.IO.Path]::GetFullPath((Join-Path $Environment.SYMPP_HOME "runtime/launcher-validation"))
  if (-not $validationCache.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Exact-command preparation cache escaped its isolated root." }
  Remove-Item -LiteralPath $validationCache -Recurse -Force -ErrorAction SilentlyContinue
  Write-BenchmarkProgress "Verified exact-command runtime artifact acquired in $([Math]::Round($watch.Elapsed.TotalMilliseconds, 2)) ms."
  return ConvertFrom-ArtifactPhaseTiming $stderr $watch.Elapsed.TotalMilliseconds
}

function Start-ExactClient([hashtable]$Environment, $Barrier = $null) {
  $config = Get-Content -LiteralPath (Join-Path $pluginRoot ".mcp.json") -Raw | ConvertFrom-Json
  $server = $config.symphony_plus_plus
  $info = [System.Diagnostics.ProcessStartInfo]::new()
  if ($Barrier) {
    $readyFile = Join-Path $Barrier.ready_dir "$([guid]::NewGuid().ToString('N')).ready"
    $info.FileName = (Get-Command node.exe -ErrorAction Stop).Source
    foreach ($arg in @(
        (Join-Path $PSScriptRoot "exact-command-start-barrier.js"), $readyFile, $Barrier.release_file,
        $pluginRoot, [string]$server.command
      ) + @($server.args)) { [void]$info.ArgumentList.Add([string]$arg) }
  } else {
    $info.FileName = [string]$server.command
    foreach ($arg in @($server.args)) { [void]$info.ArgumentList.Add([string]$arg) }
  }
  $info.WorkingDirectory = $pluginRoot
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardInput = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  Set-SanitizedEnvironment $info $Environment
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $info
  $benchmarkClientId = [guid]::NewGuid().ToString("N")
  $info.Environment["SYMPP_BENCH_CLIENT_ID"] = $benchmarkClientId
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
    tools_watch = $null
    tools_ready_ms = 0.0
    barrier_ready_file = $(if ($Barrier) { $readyFile } else { $null })
    benchmark_client_id = $benchmarkClientId
  }
  $clients.Add($client)
  return $client
}

function Release-ExactStartBarrier([object[]]$Cohort, $Barrier, [int]$TimeoutSec, $Watch = $null) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
  while (@($Cohort | Where-Object { -not (Test-Path -LiteralPath $_.barrier_ready_file -PathType Leaf) }).Count -gt 0) {
    $failed = @($Cohort | Where-Object { $_.process.HasExited })
    if ($failed.Count) { throw "Exact-command start-barrier client exited before release: $($failed[0].stderr_task.GetAwaiter().GetResult().Trim())" }
    if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for exact-command start barrier." }
    Start-Sleep -Milliseconds 5
  }
  foreach ($client in $Cohort) { $client.watch.Restart() }
  if ($Watch) { $Watch.Restart() }
  $releasedAt = [DateTime]::UtcNow
  New-Item -ItemType File -Path $Barrier.release_file -Force | Out-Null
  return $releasedAt
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

function Measure-ExactToolsList($Client, [int]$TimeoutSec) {
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $Client.process.StandardInput.WriteLine('{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
  $responseTask = $Client.process.StandardOutput.ReadLineAsync()
  if (-not $responseTask.Wait($TimeoutSec * 1000)) { throw "Timed out waiting for exact-command tools/list." }
  $watch.Stop()
  $line = $responseTask.GetAwaiter().GetResult()
  $response = $line | ConvertFrom-Json
  if ($null -eq $response.result.tools -or $response.error) { throw "Exact client returned an invalid tools/list response: $line" }
  return $watch.Elapsed.TotalMilliseconds
}

function Stop-ExactClients([object[]]$Clients) {
  $active = @($Clients | Where-Object { $null -ne $_ -and $null -ne $_.process })
  if ($script:probeFailure) {
    foreach ($client in @($active | Where-Object { -not $_.process.HasExited })) {
      try { $client.process.Kill($true) } catch { }
    }
  }
  $exitDeadline = [DateTime]::UtcNow.AddSeconds(60)
  foreach ($client in $active) {
    try { $client.process.StandardInput.Close() } catch { }
    $remainingMs = [Math]::Max(0, [int][Math]::Ceiling(($exitDeadline - [DateTime]::UtcNow).TotalMilliseconds))
    if ($remainingMs -eq 0 -or -not $client.process.WaitForExit($remainingMs)) { break }
  }
  foreach ($client in @($active | Where-Object { -not $_.process.HasExited })) {
    try { $client.process.Kill($true) } catch [System.InvalidOperationException] { }
  }

  $killDeadline = [DateTime]::UtcNow.AddSeconds(15)
  foreach ($client in $active) {
    if (-not $client.process.HasExited) {
      $remainingMs = [Math]::Max(0, [int][Math]::Ceiling(($killDeadline - [DateTime]::UtcNow).TotalMilliseconds))
      [void]$client.process.WaitForExit($remainingMs)
    }
    $client.process.Dispose()
    $client.process = $null
  }
}

function Stop-ExactClient($Client) {
  Stop-ExactClients @($Client)
}

function Get-ProcessTreeMetrics([object[]]$Cohort, [int]$ExcludedPid, [bool]$IncludeClientDetails = $true) {
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
    clients = $(if ($IncludeClientDetails) { @($detail) } else { @() })
  }
}

function Invoke-Cohort([int]$Count, [hashtable]$Environment, [int]$BackendPid, [switch]$StartBarrier) {
  $cohortWatch = [System.Diagnostics.Stopwatch]::StartNew()
  $gitBefore = Get-GitInvocationCount
  $traceBefore = Get-TraceCounts
  $startedAtMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $cohort = [System.Collections.Generic.List[object]]::new()
  if ($StartBarrier) {
    $barrier = [pscustomobject]@{
      ready_dir = Join-Path $tempRoot "barrier-$([guid]::NewGuid().ToString('N'))"
      release_file = Join-Path $tempRoot "barrier-$([guid]::NewGuid().ToString('N')).release"
    }
    New-Item -ItemType Directory -Path $barrier.ready_dir -Force | Out-Null
    foreach ($index in 1..$Count) { $cohort.Add((Start-ExactClient $Environment $barrier)) }
    [void](Release-ExactStartBarrier @($cohort) $barrier $StartupTimeoutSec)
    Wait-ClientsReady @($cohort) $StartupTimeoutSec
  } else {
    for ($offset = 0; $offset -lt $Count; $offset += $startupBurst) {
      $batchCount = [Math]::Min($startupBurst, $Count - $offset)
      $batch = @(foreach ($index in 1..$batchCount) { Start-ExactClient $Environment })
      Wait-ClientsReady $batch $StartupTimeoutSec
      foreach ($client in $batch) { $cohort.Add($client) }
    }
  }
  $tree = Get-ProcessTreeMetrics $cohort $BackendPid (-not $StartBarrier)
  $samples = @($cohort.elapsed_ms | Sort-Object)
  $leasePeak = Get-LeaseCount
  $gitAfter = Get-GitInvocationCount
  $traceAfter = Get-TraceCounts
  $traceDelta = @{}
  foreach ($name in @($traceAfter.Keys + $traceBefore.Keys | Select-Object -Unique)) { $traceDelta[$name] = [int]$traceAfter[$name] - [int]$traceBefore[$name] }
  if ($LauncherMode -eq "NodePresent" -and
      ([int]$traceDelta["node_bridge_selected"] -ne $Count -or
       [int]$traceDelta["generation_attach_handles_released"] -ne $Count -or
       [int]$traceDelta["generation_attach_initial_validation"] -ne $Count)) {
    throw "Node warm cohort did not validate identity and release generation watchers before attachment."
  }
  $initialValidations = @(Get-TraceDetails "generation_attach_initial_validation" $startedAtMs)
  if ($LauncherMode -eq "NodePresent" -and @($initialValidations | Where-Object { -not $_.valid -or [double]$_.elapsed_ms -lt 100 -or [double]$_.overlap_ms -le 0 }).Count -gt 0) {
    throw "Node warm cohort weakened the two-observation generation settle."
  }
  if ([int]$traceDelta["backend_recovery_ready"] -ne 0 -or
      @((Get-TraceDetails "backend_recovery_decision" $startedAtMs) | Where-Object { $_.action -ne "lease_repair" }).Count -gt 0) {
    throw "Warm cohort performed an unclassified or avoidable full runtime adoption."
  }
  $serverLeasePeak = [int](($((Get-TraceDetails "client_lease_attach_ok" $startedAtMs).active_clients) | Measure-Object -Maximum).Maximum)
  Stop-ExactClients @($cohort)
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while ((Get-LeaseCount) -gt 1 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
  $cohortWatch.Stop()
  $traceAfterDetach = Get-TraceCounts
  $traceDeltaAfterDetach = @{}
  foreach ($name in @($traceAfterDetach.Keys + $traceBefore.Keys | Select-Object -Unique)) { $traceDeltaAfterDetach[$name] = [int]$traceAfterDetach[$name] - [int]$traceBefore[$name] }
  if ($LauncherMode -eq "NodePresent" -and
      ([int]$traceDeltaAfterDetach["client_lease_attach_ok"] -ne $Count -or [int]$traceDeltaAfterDetach["client_lease_detach_ok"] -ne $Count)) {
    throw "Node warm cohort server lease lifecycle mismatch."
  }
  return [pscustomobject]@{
    clients = $Count
    startup_burst = $(if ($StartBarrier) { $Count } else { [Math]::Min($startupBurst, $Count) })
    start_barrier = [bool]$StartBarrier
    completion_ms = [Math]::Round($cohortWatch.Elapsed.TotalMilliseconds, 2)
    p50_initialize_ms = [Math]::Round((Get-Percentile $samples 0.50), 2)
    p95_initialize_ms = [Math]::Round((Get-Percentile $samples 0.95), 2)
    max_initialize_ms = [Math]::Round((Get-Percentile $samples 1.0), 2)
    process_tree = $tree
    leases_peak = $leasePeak
    leases_after = Get-LeaseCount
    server_leases_peak = $serverLeasePeak
    git_invocations = $gitAfter - $gitBefore
    trace = $traceDeltaAfterDetach
  }
}

function Test-Dashboard([string]$Url) {
  try { return (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } catch { return $false }
}

function Get-RuntimeIdentitySnapshot {
  $state = Get-Content -LiteralPath $runtimeFile -Raw | ConvertFrom-Json
  return [pscustomobject]@{
    backend_pid = [int]$state.backend.pid
    backend_epoch = [string]$state.publication.backend.process_start_time_utc_ticks
    runtime_key = [string]$state.runtime_key
    generation_key = [string]$state.publication.generation_key
  }
}

function Test-SameRuntimeIdentity($Expected, $Actual) {
  return $Expected.backend_pid -eq $Actual.backend_pid -and
    $Expected.backend_epoch -eq $Actual.backend_epoch -and
    $Expected.runtime_key -ceq $Actual.runtime_key -and
    $Expected.generation_key -ceq $Actual.generation_key
}

function Limit-DiagnosticText([string]$Text, [int]$MaximumLength) {
  if ($null -eq $Text) { return "" }
  $normalized = ($Text -replace '\r?\n', ' ').Trim()
  if ($normalized.Length -le $MaximumLength) { return $normalized }
  return $normalized.Substring($normalized.Length - $MaximumLength)
}

function Write-PreCleanupBackendDiagnostics {
  $url = "http://127.0.0.1:$backendPort/mcp/readiness"
  try {
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -SkipHttpErrorCheck
    Write-BenchmarkProgress "Exact backend HTTP before cleanup: status=$([int]$response.StatusCode) body=$(Limit-DiagnosticText ([string]$response.Content) 2000)"
  } catch {
    Write-BenchmarkProgress "Exact backend HTTP before cleanup: error=$(Limit-DiagnosticText ([string]$_.Exception.Message) 1000)"
  }

  try {
    $listenerPids = @(Get-ListenerPids $backendPort | Select-Object -First 4)
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $processRows = [System.Collections.Generic.List[string]]::new()
    foreach ($listenerPid in $listenerPids) {
      $currentPid = [int]$listenerPid
      foreach ($depth in 0..7) {
        if (-not $currentPid -or -not $seen.Add($currentPid)) { break }
        $row = @(Get-CimInstance Win32_Process -Filter "ProcessId = $currentPid" -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($row.Count -ne 1) { $processRows.Add("pid=$currentPid unavailable"); break }
        $processRows.Add("pid=$($row[0].ProcessId) parent=$($row[0].ParentProcessId) name=$($row[0].Name)")
        $currentPid = [int]$row[0].ParentProcessId
      }
    }
    $tree = if ($processRows.Count) { Limit-DiagnosticText ($processRows -join ' | ') 6000 } else { "none" }
    Write-BenchmarkProgress "Exact backend process tree before cleanup: listeners=$($listenerPids -join ',') tree=$tree"
  } catch {
    Write-BenchmarkProgress "Exact backend process tree before cleanup: error=$(Limit-DiagnosticText ([string]$_.Exception.Message) 1000)"
  }

  try {
    $logRows = [System.Collections.Generic.List[string]]::new()
    foreach ($log in @(Get-ChildItem -LiteralPath (Join-Path $tempRoot "logs") -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc | Select-Object -Last 20)) {
      $tail = Limit-DiagnosticText ((Get-Content -LiteralPath $log.FullName -Tail 40 -ErrorAction SilentlyContinue) -join [Environment]::NewLine) 1500
      $logRows.Add("path=$([System.IO.Path]::GetRelativePath($tempRoot, $log.FullName)) bytes=$($log.Length) tail=$tail")
    }
    $inventory = if ($logRows.Count) { Limit-DiagnosticText ($logRows -join ' | ') 8000 } else { "none" }
    Write-BenchmarkProgress "Exact backend logs before cleanup: $inventory"
  } catch {
    Write-BenchmarkProgress "Exact backend logs before cleanup: error=$(Limit-DiagnosticText ([string]$_.Exception.Message) 1000)"
  }
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

$minWorkers = 0; $minIo = 0
[System.Threading.ThreadPool]::GetMinThreads([ref]$minWorkers, [ref]$minIo)
# Windows redirected pipes occupy workers even during ReadLineAsync/ReadToEndAsync.
# Reserve both readers per live client so pool growth does not become startup latency.
$peakClients = [Math]::Max($ColdClients, ($cohortValues | Measure-Object -Maximum).Maximum + 1)
[void][System.Threading.ThreadPool]::SetMinThreads(2 * $peakClients + $minWorkers, $minIo)
try {
  foreach ($path in @(
      $pluginRoot, (Join-Path $marketplaceRoot "elixir"),
      (Join-Path $marketplaceRoot "plugins/symphony-plus-plus/.codex-plugin"),
      (Join-Path $marketplaceRoot "plugins/symphony-plus-plus-mcp"),
      (Join-Path $marketplaceRoot "elixir/priv/symphony_plus_plus"),
      (Split-Path -Parent $runtimeFile), $traceDir, $gitLogDir, (Join-Path $tempRoot "shim"),
      (Join-Path $tempRoot "profile"), (Join-Path $tempRoot "logs")
    )) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
  Copy-SourcePlugin $pluginRoot
  Copy-SourcePlugin (Join-Path $marketplaceRoot "plugins/symphony-plus-plus-mcp")
  Copy-Item -LiteralPath (Join-Path $repoRoot "plugins/symphony-plus-plus/.codex-plugin/plugin.json") -Destination (Join-Path $marketplaceRoot "plugins/symphony-plus-plus/.codex-plugin/plugin.json") -Force
  Copy-Item -LiteralPath (Join-Path $repoRoot "elixir/mix.exs") -Destination (Join-Path $marketplaceRoot "elixir/mix.exs") -Force
  Copy-Item -LiteralPath (Join-Path $repoRoot "elixir/priv/symphony_plus_plus/mcp_contract.json") -Destination (Join-Path $marketplaceRoot "elixir/priv/symphony_plus_plus/mcp_contract.json") -Force
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
    $nodeDirectories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($node in @(Get-Command node.exe -All -ErrorAction Stop)) {
      [void]$nodeDirectories.Add([System.IO.Path]::GetFullPath((Split-Path -Parent $node.Source)).TrimEnd("\"))
    }
    $effectivePath = (@($env:PATH -split ";" | Where-Object {
          $_ -and -not $nodeDirectories.Contains([System.IO.Path]::GetFullPath($_).TrimEnd("\"))
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
    SYMPP_INTEGRITY_MARKER = Join-Path $tempRoot "unsafe-cleanup-ran"
    HOME = Join-Path $tempRoot "profile"
    USERPROFILE = Join-Path $tempRoot "profile"
    HOMEDRIVE = [System.IO.Path]::GetPathRoot($tempRoot).TrimEnd("\")
    HOMEPATH = (Join-Path $tempRoot "profile").Substring([System.IO.Path]::GetPathRoot($tempRoot).Length - 1)
    PATH = (Join-Path $tempRoot "shim") + ";" + $effectivePath
  }

  $artifactCacheMiss = Prepare-ExactArtifact $environment
  $artifactPreparedCache = Prepare-ExactArtifact $environment
  Write-BenchmarkProgress "Starting exact-command artifact cold client on port $backendPort..."
  $coldCohort = @()
  $coldWatch = [System.Diagnostics.Stopwatch]::StartNew()
  $coldStartedAt = [DateTime]::UtcNow
  if ($ColdClients -gt 1) {
    $coldBarrier = [pscustomobject]@{ ready_dir = Join-Path $tempRoot "cold-barrier"; release_file = Join-Path $tempRoot "cold.release" }
    New-Item -ItemType Directory -Path $coldBarrier.ready_dir -Force | Out-Null
    $coldCohort = @(foreach ($index in 1..$ColdClients) { Start-ExactClient $environment $coldBarrier })
    $coldStartedAt = Release-ExactStartBarrier $coldCohort $coldBarrier $StartupTimeoutSec $coldWatch
  } else { $coldCohort = @(Start-ExactClient $environment) }
  $cold = $coldCohort[0]
  Wait-ClientsReady $coldCohort $StartupTimeoutSec
  Write-BenchmarkProgress "Cold initialize: p95=$([Math]::Round((Get-Percentile @($coldCohort.elapsed_ms) 0.95), 2)) ms max=$([Math]::Round(($coldCohort.elapsed_ms | Measure-Object -Maximum).Maximum, 2)) ms."
  foreach ($client in $coldCohort) {
    $client.tools_watch = [System.Diagnostics.Stopwatch]::StartNew()
    $client.process.StandardInput.WriteLine('{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    $client.line_task = $client.process.StandardOutput.ReadLineAsync()
  }
  foreach ($client in $coldCohort) {
    if (-not $client.line_task.Wait($StartupTimeoutSec * 1000)) { throw "Cold cohort tools/list timed out." }
    $client.tools_watch.Stop()
    $client.tools_ready_ms = $coldWatch.Elapsed.TotalMilliseconds
    $tools = $client.line_task.GetAwaiter().GetResult() | ConvertFrom-Json
    if ($tools.error -or @($tools.result.tools).Count -eq 0) { throw "Cold cohort tools/list failed." }
  }
  $coldAllReadyMs = $coldWatch.Elapsed.TotalMilliseconds
  Write-BenchmarkProgress "Cold cohort: $ColdClients clients initialized and listed tools in $([Math]::Round($coldAllReadyMs, 2)) ms."
  $runtimeState = Get-Content -LiteralPath $runtimeFile -Raw | ConvertFrom-Json
  $databasePath = Join-Path $environment.USERPROFILE ".agents/splusplus/symphony_plus_plus.sqlite3"
  if (-not (Test-Path -LiteralPath $databasePath -PathType Leaf) -or
      -not ([System.IO.Path]::GetFullPath($databasePath)).StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Exact artifact runtime did not use its isolated Windows home ledger."
  }
  if ([string]$runtimeState.runtime_mode -ne "artifact" -or [string]$runtimeState.frontend.status -ne "artifact_static") { throw "Cold exact command did not start the artifact dashboard runtime." }
  if (-not (Test-Dashboard ([string]$runtimeState.frontend.url))) { throw "Artifact dashboard was not healthy." }
  $owners = @(Get-ListenerPids $backendPort)
  if ($owners.Count -ne 1 -or [int]$owners[0] -ne [int]$runtimeState.backend.pid) { throw "Cold exact command did not own one backend singleton." }
  $backend = Get-Process -Id ([int]$runtimeState.backend.pid) -ErrorAction Stop
  $backendStartTicks = $backend.StartTime.ToUniversalTime().Ticks
  $toolsListMs = $cold.tools_watch.Elapsed.TotalMilliseconds
  $clientStartedAt = if ($ColdClients -gt 1) { $coldStartedAt } else { $cold.process.StartTime.ToUniversalTime() }
  $runtimeReadyAt = ([DateTimeOffset]$runtimeState.generated_at).UtcDateTime
  $coldMetrics = [pscustomobject]@{
    clients = $ColdClients
    all_ready_ms = [Math]::Round($coldAllReadyMs, 2)
    initialize_ms = [Math]::Round($cold.elapsed_ms, 2)
    initialize_p95_ms = [Math]::Round((Get-Percentile @($coldCohort.elapsed_ms) 0.95), 2)
    initialize_max_ms = [Math]::Round(($coldCohort.elapsed_ms | Measure-Object -Maximum).Maximum, 2)
    backend_process_started_ms = [Math]::Round(($backend.StartTime.ToUniversalTime() - $clientStartedAt).TotalMilliseconds, 2)
    runtime_state_ready_ms = [Math]::Round(($runtimeReadyAt - $clientStartedAt).TotalMilliseconds, 2)
    tools_list_ms = [Math]::Round($toolsListMs, 2)
    tools_list_total_ms = [Math]::Round($cold.tools_ready_ms, 2)
    phases = @(foreach ($event in @("powershell_entry", "powershell_config_begin", "powershell_config_end", "cold_leader_acquired", "backend_plan_begin", "backend_plan_end", "runtime_starting_published", "manifest_fetch_begin", "manifest_fetch_end", "backend_start_begin", "backend_start_end", "runtime_ready_published", "node_bridge_selected")) {
      foreach ($record in @(Get-TraceDetails $event ([DateTimeOffset]$clientStartedAt).ToUnixTimeMilliseconds())) {
        [pscustomobject]@{ event = $event; elapsed_ms = $record.at_ms - ([DateTimeOffset]$clientStartedAt).ToUnixTimeMilliseconds() }
      }
    })
    backend_pid = $backend.Id
    backend_start_ticks = $backendStartTicks
    dashboard_healthy = $true
    runtime_mode = [string]$runtimeState.runtime_mode
    trace = Get-TraceCounts
    git_invocations = Get-GitInvocationCount
  }

  if ($ColdClients -gt 1) { Stop-ExactClients @($coldCohort | Select-Object -Skip 1) }

  $warmResults = [System.Collections.Generic.List[object]]::new()
  foreach ($repeat in 1..$Repeats) {
    foreach ($count in $cohortValues) {
      Write-BenchmarkProgress "Measuring exact-command warm cohort repeat=$repeat clients=$count..."
      $identityBefore = Get-RuntimeIdentitySnapshot
      $cohort = Invoke-Cohort $count $environment $backend.Id
      if ($cohort.leases_peak -ne ($count + 1) -or $cohort.leases_after -ne 1) { throw "Warm cohort lease lifecycle mismatch." }
      $currentOwners = @(Get-ListenerPids $backendPort)
      if ($currentOwners.Count -ne 1 -or [int]$currentOwners[0] -ne $backend.Id) { throw "Warm cohort changed singleton identity." }
      $identityAfter = Get-RuntimeIdentitySnapshot
      if (-not (Test-SameRuntimeIdentity $identityBefore $identityAfter)) { throw "Warm cohort changed the backend epoch, runtime key, or installed generation." }
      if ($LauncherMode -eq "NodePresent" -and [int]$cohort.trace["last_detach_cleanup_requested"] -ne 0) {
        throw "Node warm cohort entered last-detach cleanup while the anchor remained live."
      }
      if ($LauncherMode -eq "NodeMissing" -and
          ([int]$cohort.trace["last_detach_cleanup_stopped_runtime"] -ne 0 -or
           [int]$cohort.trace["last_detach_cleanup_preserved_active_runtime"] -ne $count)) {
        throw "PowerShell fallback cleanup did not preserve the anchored runtime."
      }
      $cohort | Add-Member -NotePropertyName repeat -NotePropertyValue $repeat
      $warmResults.Add($cohort)
    }
  }

  $lifecycleBarrier = [pscustomobject]@{ checked = $false }
  if ($LauncherMode -eq "NodePresent" -and -not $SkipLifecycleBarrier) {
    Write-BenchmarkProgress "Running exact-command 200-client simultaneous lifecycle barrier..."
    $identityBefore = Get-RuntimeIdentitySnapshot
    $lifecycleBarrier = Invoke-Cohort 200 $environment $backend.Id -StartBarrier
    if ($lifecycleBarrier.leases_peak -ne 201 -or $lifecycleBarrier.leases_after -ne 1 -or $lifecycleBarrier.server_leases_peak -ne 201) {
      throw "Lifecycle barrier lease boundary mismatch."
    }
    Start-Sleep -Milliseconds 1500
    $identityAfter = Get-RuntimeIdentitySnapshot
    $currentOwners = @(Get-ListenerPids $backendPort)
    $identityUnchanged = Test-SameRuntimeIdentity $identityBefore $identityAfter
    $anchorProtected = $currentOwners.Count -eq 1 -and [int]$currentOwners[0] -eq $backend.Id -and
      [int]$lifecycleBarrier.trace["last_detach_cleanup_requested"] -eq 0
    if (-not $identityUnchanged -or -not $anchorProtected) { throw "Lifecycle barrier changed or shut down the anchored artifact runtime." }
    $lifecycleBarrier | Add-Member -NotePropertyName checked -NotePropertyValue $true
    $lifecycleBarrier | Add-Member -NotePropertyName identity_unchanged -NotePropertyValue $identityUnchanged
    $lifecycleBarrier | Add-Member -NotePropertyName anchor_protected -NotePropertyValue $anchorProtected
  }

  $cacheRelease = [pscustomobject]@{ checked = $false; moved = $null; cleanup_completed = $null }
  $lockRecovery = [pscustomobject]@{ checked = $false; reclaimed = $null }
  $lifecycleRace = [pscustomobject]@{ checked = $false; healthy = $null; backend_reused = $null }
  if ($LauncherMode -eq "NodePresent") {
    Write-BenchmarkProgress "Checking exact-command cache release..."
    $cacheRelease.checked = $true
    $cacheProbe = Start-ExactClient $environment
    Wait-ClientsReady @($cacheProbe) $StartupTimeoutSec
    $movedPluginRoot = "$pluginRoot.released"
    $cleanupBefore = [int](Get-TraceCounts)["last_detach_cleanup_completed"]
    try {
      Move-Item -LiteralPath $pluginRoot -Destination $movedPluginRoot
      $cacheRelease.moved = -not (Test-Path -LiteralPath $pluginRoot) -and (Test-Path -LiteralPath $movedPluginRoot)
      Stop-ExactClient $cold
      $cold = $null
      Stop-ExactClient $cacheProbe
      $cacheProbe = $null
      $deadline = [DateTime]::UtcNow.AddSeconds(60)
      do {
        $cacheRelease.cleanup_completed = [int](Get-TraceCounts)["last_detach_cleanup_completed"] -gt $cleanupBefore
        if ($cacheRelease.cleanup_completed -and @(Get-ListenerPids $backendPort).Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
      } while ([DateTime]::UtcNow -lt $deadline)
    } finally {
      if ($cacheProbe) { Stop-ExactClient $cacheProbe }
      if ((Test-Path -LiteralPath $movedPluginRoot) -and -not (Test-Path -LiteralPath $pluginRoot)) { Move-Item -LiteralPath $movedPluginRoot -Destination $pluginRoot }
    }
    if (-not $cacheRelease.moved -or -not $cacheRelease.cleanup_completed) { throw "Retained Node bridge did not release the plugin cache while preserving last-detach cleanup." }
    $cold = Start-ExactClient $environment
    Wait-ClientsReady @($cold) $StartupTimeoutSec
    $runtimeState = Get-Content -LiteralPath $runtimeFile -Raw | ConvertFrom-Json
    $backend = Get-Process -Id ([int]$runtimeState.backend.pid) -ErrorAction Stop
    $backendStartTicks = $backend.StartTime.ToUniversalTime().Ticks

    $lockRecovery.checked = $true
    Write-BenchmarkProgress "Checking exact-command abandoned-lock recovery..."
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
    Write-BenchmarkProgress "Racing a fresh attach against last-detach cleanup..."
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

  Write-BenchmarkProgress "Killing the artifact backend and measuring automatic recovery..."
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

  $mutation = [pscustomobject]@{ checked = $false; shortcut_rejected = $null; scan_race_detected = $null; attach_race_rejected = $null; unsafe_cleanup_skipped = $null }
  if (-not $SkipMutationCheck) {
    Write-BenchmarkProgress "Checking exact-command mutation rejection..."
    $mutation.checked = $true
    $mutationFile = Join-Path $pluginRoot "scripts/start-sympp-mcp.ps1"
    if ($LauncherMode -eq "NodePresent") {
      Remove-Item -LiteralPath $generationMarker[0].FullName -Force -ErrorAction SilentlyContinue
      $originalBytes = [System.IO.File]::ReadAllBytes($mutationFile)
      $originalWriteTime = [System.IO.File]::GetLastWriteTimeUtc($mutationFile)
      $retryBefore = [int](Get-TraceCounts)["generation_scan_retry"]
      $scanRejectionBefore = [int](Get-TraceCounts)["warm_miss_generation"]
      $scanTraceOffsets = Get-TraceFileOffsets
      $scanClient = Start-ExactClient $environment
      $deadline = [DateTime]::UtcNow.AddSeconds(60)
      while (-not (Test-NewTraceEvent $scanTraceOffsets "generation_scan_complete" $scanClient.benchmark_client_id) -and -not $scanClient.process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 5 }
      if (-not (Test-NewTraceEvent $scanTraceOffsets "generation_scan_complete" $scanClient.benchmark_client_id)) { throw "Mutation race did not observe an in-progress generation scan." }
      [System.IO.File]::AppendAllText($mutationFile, "`n# transient benchmark mutation")
      while (-not (Test-NewTraceEvent $scanTraceOffsets "generation_watch_invalidated" $scanClient.benchmark_client_id) -and -not $scanClient.process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 5 }
      if (-not (Test-NewTraceEvent $scanTraceOffsets "generation_watch_invalidated" $scanClient.benchmark_client_id)) { throw "Installed payload mutation was not observed by the generation watcher." }
      [System.IO.File]::WriteAllBytes($mutationFile, $originalBytes)
      [System.IO.File]::SetLastWriteTimeUtc($mutationFile, $originalWriteTime)
      Wait-ClientsReady @($scanClient) $StartupTimeoutSec
      $mutation.scan_race_detected = [int](Get-TraceCounts)["generation_scan_retry"] -gt $retryBefore -or
        [int](Get-TraceCounts)["warm_miss_generation"] -gt $scanRejectionBefore
      Stop-ExactClient $scanClient
      if (-not $mutation.scan_race_detected) { throw "Installed payload mutation during generation scan was not retried or rejected safely." }
    }
    $attachRejectionBefore = [int](Get-TraceCounts)["warm_miss_generation"]
    Remove-Item -LiteralPath $environment.SYMPP_INTEGRITY_MARKER -Force -ErrorAction SilentlyContinue
    $attachTraceOffsets = Get-TraceFileOffsets
    $mutationStream = $null
    if ($LauncherMode -eq "NodePresent") {
      $mutationStream = [System.IO.File]::Open($mutationFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
    }
    try {
      $mutated = Start-ExactClient $environment
      $deadline = [DateTime]::UtcNow.AddSeconds(60)
      if ($LauncherMode -eq "NodePresent") {
        while (-not (Test-NewTraceEvent $attachTraceOffsets "generation_identity_resolved" $mutated.benchmark_client_id) -and -not $mutated.process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 5 }
        if (-not (Test-NewTraceEvent $attachTraceOffsets "generation_identity_resolved" $mutated.benchmark_client_id)) { throw "Mutation race did not reach the generation-pinned attachment boundary." }
        $mutationBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('Set-Content -LiteralPath $env:SYMPP_INTEGRITY_MARKER -Value invoked')
        $mutationStream.Position = 0
        $mutationStream.SetLength(0)
        $mutationStream.Write($mutationBytes, 0, $mutationBytes.Length)
        $mutationStream.Flush($true)
      } else {
        Set-Content -LiteralPath $mutationFile -Value 'Set-Content -LiteralPath $env:SYMPP_INTEGRITY_MARKER -Value invoked' -Encoding utf8NoBOM
      }
    } finally {
      if ($null -ne $mutationStream) { $mutationStream.Dispose() }
    }
    while ((-not $mutated.process.HasExited -or -not $mutated.line_task.IsCompleted) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    $mutation.shortcut_rejected = $mutated.process.HasExited -and
      $mutated.line_task.IsCompleted -and
      [string]::IsNullOrWhiteSpace([string]$mutated.line_task.GetAwaiter().GetResult())
    $mutation.attach_race_rejected = $LauncherMode -ne "NodePresent" -or
      ([int](Get-TraceCounts)["warm_miss_generation"] -gt $attachRejectionBefore -and $mutation.shortcut_rejected)
    $mutation.unsafe_cleanup_skipped = -not (Test-Path -LiteralPath $environment.SYMPP_INTEGRITY_MARKER)
    if ($LauncherMode -ne "NodePresent") { $mutation.scan_race_detected = $true }
    Stop-ExactClient $mutated
    if (-not $mutation.shortcut_rejected -or -not $mutation.attach_race_rejected -or -not $mutation.unsafe_cleanup_skipped) {
      throw "Installed payload mutation at the attachment boundary was not rejected safely before warm attach: shortcut=$($mutation.shortcut_rejected) attach=$($mutation.attach_race_rejected) cleanup=$($mutation.unsafe_cleanup_skipped)."
    }
  }

  $result = [pscustomobject]@{
    revision = $revision
    launcher_mode = $LauncherMode
    command = "cmd.exe /d /s /c scripts\start-sympp-mcp.cmd"
    backend_port = $backendPort
    artifact = [pscustomobject]@{ cache_miss = $artifactCacheMiss; prepared_cache = $artifactPreparedCache }
    isolation = [pscustomobject]@{ database = $databasePath; verified = $true }
    cold = $coldMetrics
    warm = @($warmResults)
    lifecycle_barrier = $lifecycleBarrier
    cache_release = $cacheRelease
    lock_recovery = $lockRecovery
    lifecycle_race = $lifecycleRace
    recovery = $recoveryMetrics
    mutation = $mutation
  }
  Write-BenchmarkProgress "Exact-command probe completed."
} catch {
  $caught = $_
  $probeFailure = $caught
  $errorDetail = @(
    [string]$caught.Exception.Message
    [string]$caught.ScriptStackTrace
    [string]$caught.InvocationInfo.PositionMessage
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  Write-BenchmarkProgress "Exact-command probe failed: $(($errorDetail -join ' | ') -replace '\r?\n', ' ')"
  Write-PreCleanupBackendDiagnostics
  [Console]::Error.WriteLine("trace: $((Get-TraceCounts | ConvertTo-Json -Compress)) git_invocations=$(Get-GitInvocationCount)")
  throw
} finally {
  [void][System.Threading.ThreadPool]::SetMinThreads($minWorkers, $minIo)
  Stop-ExactClients @($clients | Where-Object { $_.process })
  if ($probeFailure) {
    $clientDiagnostics = @($clients | ForEach-Object {
      if ($_.stderr_task -and $_.stderr_task.IsCompleted) {
        try { [string]$_.stderr_task.GetAwaiter().GetResult() } catch { [string]$_.Exception.Message }
      }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($clientDiagnostics.Count) {
      Write-BenchmarkProgress "Exact client stderr after cleanup: $((($clientDiagnostics -join ' | ') -replace '\r?\n', ' ').Trim())"
    }
    $logDiagnostics = @(Get-ChildItem -LiteralPath $tempRoot -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '\.(err|out)\.log$' } |
      ForEach-Object {
        $content = [string](Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue)
        if ($content.Length -gt 2000) { $content = $content.Substring($content.Length - 2000) }
        if (-not [string]::IsNullOrWhiteSpace($content)) {
          $role = if ($_.Name -match '^(.+?)-\d{8}-') { $Matches[1] } else { $_.BaseName }
          "path=$([System.IO.Path]::GetRelativePath($tempRoot, $_.FullName)) role=$role tail=$content"
        }
      })
    if ($logDiagnostics.Count) {
      Write-BenchmarkProgress "Exact launcher logs after cleanup: $((($logDiagnostics -join ' | ') -replace '\r?\n', ' ').Trim())"
    }
    $failureRuntime = $null
    if (Test-Path -LiteralPath $runtimeFile -PathType Leaf) {
      $runtimeContent = [string](Get-Content -LiteralPath $runtimeFile -Raw -ErrorAction SilentlyContinue)
      if (-not [string]::IsNullOrWhiteSpace($runtimeContent)) {
        $runtimeTail = if ($runtimeContent.Length -gt 4000) { $runtimeContent.Substring($runtimeContent.Length - 4000) } else { $runtimeContent }
        Write-BenchmarkProgress "Exact runtime before backend cleanup: $((($runtimeTail -replace '\r?\n', ' ').Trim()))"
        try { $failureRuntime = $runtimeContent | ConvertFrom-Json } catch { }
        if ($failureRuntime -and $failureRuntime.backend) {
          $failureBackendPid = [int]$failureRuntime.backend.pid
          $failureBackend = Get-Process -Id $failureBackendPid -ErrorAction SilentlyContinue
          try { $failureBackendStartTime = if ($failureBackend) { $failureBackend.StartTime.ToUniversalTime() } else { $null } } catch { $failureBackendStartTime = $null }
          try { $runtimeGeneratedAt = ([DateTimeOffset]::Parse([string]$failureRuntime.generated_at)).UtcDateTime } catch { $runtimeGeneratedAt = $null }
          if ([int]$failureRuntime.backend.port -eq $backendPort -and
              $failureBackendPid -in @(Get-ListenerPids $backendPort) -and
              $failureBackendStartTime -and $runtimeGeneratedAt -and
              $failureBackendStartTime -ge $probeStartedAt -and $failureBackendStartTime -le $runtimeGeneratedAt) {
            $runtimeState = $failureRuntime
            $backendStartTicks = $failureBackendStartTime.Ticks
            Write-BenchmarkProgress "Exact recovered backend cleanup identity: pid=$failureBackendPid"
          }
        }
      }
    }
    $failureListenerPids = if ($backendPort) { @(Get-ListenerPids $backendPort) } else { @() }
    $failureListeners = @($failureListenerPids | ForEach-Object {
      $listenerProcess = Get-Process -Id ([int]$_) -ErrorAction SilentlyContinue
      if ($listenerProcess) { "pid=$($listenerProcess.Id) name=$($listenerProcess.ProcessName)" } else { "pid=$_" }
    })
    $failureHealth = if ($failureRuntime -and $failureRuntime.frontend -and $failureRuntime.frontend.url) {
      Test-Dashboard ([string]$failureRuntime.frontend.url)
    } else { $false }
    Write-BenchmarkProgress "Exact listener before backend cleanup: port=$backendPort owners=$($failureListeners -join ',') dashboard_healthy=$failureHealth"
    Write-BenchmarkProgress "Exact-command post-cleanup trace: $((Get-TraceCounts | ConvertTo-Json -Compress)) git_invocations=$(Get-GitInvocationCount)"
  }
  if ($runtimeState -and $runtimeState.backend -and $backendStartTicks) {
    $process = Get-Process -Id ([int]$runtimeState.backend.pid) -ErrorAction SilentlyContinue
    if ($process) {
      $processStartTime = $process.StartTime
      if ($processStartTime -and $processStartTime.ToUniversalTime().Ticks -eq $backendStartTicks) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
  }
  $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
  if (-not $resolvedTemp.StartsWith($ownedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Benchmark cleanup root escaped its owned prefix." }
  $remainingListeners = @()
  if ($backendPort) {
    if ($probeFailure) {
      foreach ($listenerPid in @(Get-ListenerPids $backendPort)) {
        $listenerProcess = Get-Process -Id ([int]$listenerPid) -ErrorAction SilentlyContinue
        $listenerDetails = Get-CimInstance Win32_Process -Filter "ProcessId = $listenerPid" -ErrorAction SilentlyContinue
        try { $listenerStartedAt = if ($listenerProcess) { $listenerProcess.StartTime.ToUniversalTime() } else { $null } } catch { $listenerStartedAt = $null }
        if ($listenerStartedAt -and
            $listenerStartedAt -ge $probeStartedAt -and
            -not [string]::IsNullOrWhiteSpace([string]$listenerDetails.CommandLine) -and
            ([string]$listenerDetails.CommandLine).IndexOf($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
          Write-BenchmarkProgress "Stopping verified exact backend listener after probe failure: pid=$listenerPid"
          Stop-Process -Id ([int]$listenerPid) -Force -ErrorAction SilentlyContinue
        }
      }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ((Get-ListenerPids $backendPort).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    $remainingListeners = @(Get-ListenerPids $backendPort)
    if ($remainingListeners.Count -gt 0) {
      $cleanupFailure = "Benchmark cleanup left port $backendPort occupied; owners=$($remainingListeners -join ',')."
      if ($probeFailure) { Write-BenchmarkProgress "Exact cleanup failed after probe failure: $cleanupFailure" } else { throw $cleanupFailure }
    }
  }
  if ($remainingListeners.Count -eq 0) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $resolvedTemp) {
      $cleanupFailure = "Benchmark cleanup did not remove its isolated root."
      if ($probeFailure) { Write-BenchmarkProgress "Exact cleanup failed after probe failure: $cleanupFailure" } else { throw $cleanupFailure }
    }
  } else {
    Write-BenchmarkProgress "Preserving exact benchmark root because backend ownership could not be verified: $resolvedTemp"
  }
}

$result | ConvertTo-Json -Depth 12
