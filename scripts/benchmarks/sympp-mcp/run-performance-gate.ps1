<#
.SYNOPSIS
Runs the isolated Symphony++ MCP high-concurrency performance gate.
.EXAMPLE
pwsh -NoProfile -File scripts/benchmarks/sympp-mcp/run-performance-gate.ps1
.EXAMPLE
pwsh -NoProfile -File scripts/benchmarks/sympp-mcp/run-performance-gate.ps1 -SelfTest
#>
[CmdletBinding()]
param(
  [ValidateRange(1, 1000)][int]$Clients = 100,
  [ValidateRange(1, 3600000)][int]$MaxColdMs = 600000,
  [ValidateRange(1, 60000)][int]$MaxWarmP95Ms = 2000,
  [ValidateRange(1, 2147483647)][int64]$MaxExactWarmBytes = 66864537,
  [ValidateRange(1, 600000)][int]$MaxDirectMs = 30000,
  [ValidateRange(1, 2147483647)][int64]$MaxBackendBytes = 536870912,
  [switch]$SelfTest,
  [switch]$Help
)

$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../.."))
$launcher = Join-Path $repoRoot "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1"
$warmProbe = Join-Path $repoRoot "plugins/symphony-plus-plus-mcp/tests/launcher/warm-attach-benchmark.ps1"
$directProbe = Join-Path $repoRoot "plugins/symphony-plus-plus-mcp/tests/transport/direct-http-transport.ps1"
$exactProbe = Join-Path $PSScriptRoot "exact-command-performance.ps1"
$payloadProbe = Join-Path $PSScriptRoot "measure-payloads.exs"
$profileCaps = [ordered]@{
  full = @{ tools = 80; bytes = 55000 }; worker = @{ tools = 35; bytes = 25000 }
  architect = @{ tools = 65; bytes = 45000 }; coordinator = @{ tools = 30; bytes = 20000 }
  solo = @{ tools = 30; bytes = 20000 }
}
$resultCaps = [ordered]@{ claim = 600; read = 1200; progress = 500 }
$exactP95Caps = @{ 1 = $MaxWarmP95Ms; 10 = $MaxWarmP95Ms; 100 = $MaxWarmP95Ms }
$thresholds = @{
  cold_ms = $MaxColdMs; warm_p95_ms = $MaxWarmP95Ms; exact_warm_p95_ms = $exactP95Caps
  exact_warm_bytes = $MaxExactWarmBytes; direct_ms = $MaxDirectMs
  clients = $Clients; backend_bytes = $MaxBackendBytes; profile_caps = $profileCaps; result_caps = $resultCaps
}

function Quote-Toon([string]$Value) {
  return '"' + $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n') + '"'
}

function Get-GateFailures($Metrics, $Limits) {
  $failures = [System.Collections.Generic.List[string]]::new()
  if ($Metrics.cold.isolated_bootstrap_ms -gt $Limits.cold_ms) { $failures.Add("cold.isolated_bootstrap_ms") }
  if ($Metrics.warm.p95_ms -gt $Limits.warm_p95_ms) { $failures.Add("warm.p95_ms") }
  if ($Metrics.direct.elapsed_ms -gt $Limits.direct_ms) { $failures.Add("direct.elapsed_ms") }
  if ($Metrics.warm.clients -ne $Limits.clients -or $Metrics.direct.clients -ne $Limits.clients) { $failures.Add("cohort.clients") }
  if ($Metrics.cold.backend_processes -ne 1 -or $Metrics.warm.backend_processes -ne 1 -or $Metrics.direct.backend_processes -ne 1) { $failures.Add("backend.singleton") }
  if ($Metrics.direct.backend_pid -ne $Metrics.cold.backend_pid -or $Metrics.direct.backend_start_ticks -ne $Metrics.cold.backend_start_ticks) { $failures.Add("backend.identity") }
  if ($Metrics.warm.leases_peak -ne $Metrics.warm.clients -or $Metrics.warm.leases_after -ne 0) { $failures.Add("warm.lease_lifecycle") }
  if ($Metrics.warm.remote_resolution_attempts -ne 0) { $failures.Add("warm.network_attempts") }
  if ($Metrics.direct.transport_processes -ne 0) { $failures.Add("direct.wrapper_processes") }
  if ($Metrics.direct.transport_private_bytes -ne 0) { $failures.Add("direct.wrapper_private_bytes") }
  if ($Metrics.direct.backend_private_bytes -gt $Limits.backend_bytes) { $failures.Add("direct.backend_private_bytes") }
  $nodeCohorts = @($Metrics.exact.node.warm | Where-Object { $_.clients -ge 10 })
  if ($nodeCohorts.Count -eq 0 -or @($Metrics.exact.node.warm | Where-Object { -not $Limits.exact_warm_p95_ms.ContainsKey([int]$_.clients) -or $_.p95_initialize_ms -gt $Limits.exact_warm_p95_ms[[int]$_.clients] }).Count -gt 0) { $failures.Add("exact.node.p95_ms") }
  if ($nodeCohorts.Count -eq 0 -or ($nodeCohorts.process_tree.median_private_bytes_per_client | Measure-Object -Maximum).Maximum -gt $Limits.exact_warm_bytes) { $failures.Add("exact.node.private_bytes") }
  if (@($Metrics.exact.node.warm | Where-Object { $_.git_invocations -ne 0 -or [int]$_.trace.payload_hash_validation -ne 0 -or [int]$_.trace.marketplace_git_validation -ne 0 -or [int]$_.trace.contract_fingerprint_resolution -ne 0 -or [int]$_.trace.artifact_manifest_resolution -ne 0 }).Count -gt 0) { $failures.Add("exact.node.warm_resolution") }
  if ([int]$Metrics.exact.node.cold.trace.installed_identity_full_validation -ne 1 -or [int]$Metrics.exact.node.cold.trace.payload_hash_validation -ne 1 -or [int]$Metrics.exact.node.cold.trace.marketplace_git_validation -ne 1 -or [int]$Metrics.exact.node.cold.trace.artifact_manifest_resolution -ne 1) { $failures.Add("exact.node.cold_resolution") }
  if (-not $Metrics.exact.node.lock_recovery.checked -or -not $Metrics.exact.node.lock_recovery.reclaimed) { $failures.Add("exact.node.lock_recovery") }
  if (-not $Metrics.exact.node.lifecycle_race.checked -or -not $Metrics.exact.node.lifecycle_race.healthy) { $failures.Add("exact.node.lifecycle_race") }
  if (-not $Metrics.exact.node.recovery.dashboard_healthy -or -not $Metrics.exact.node.mutation.checked -or -not $Metrics.exact.node.mutation.shortcut_rejected) { $failures.Add("exact.node.recovery_integrity") }
  $fallbackCohorts = @($Metrics.exact.fallback.warm)
  if (@($fallbackCohorts | Where-Object { $_.clients -eq 10 }).Count -eq 0 -or -not $Metrics.exact.fallback.recovery.dashboard_healthy) { $failures.Add("exact.fallback.functional") }
  foreach ($name in $Limits.profile_caps.Keys) {
    $row = $Metrics.profiles.$name; $cap = $Limits.profile_caps[$name]
    if ($row.tools -gt $cap.tools) { $failures.Add("profiles.$name.tools") }
    if ($row.bytes -gt $cap.bytes) { $failures.Add("profiles.$name.bytes") }
  }
  foreach ($name in $Limits.result_caps.Keys) {
    if ($Metrics.results.$name.bytes -gt $Limits.result_caps[$name]) { $failures.Add("results.$name.bytes") }
  }
  return @($failures)
}

function Add-CleanupFailure([string[]]$Failures, $Cleanup) {
  $result = @($Failures)
  if (-not $Cleanup.backend_port_free -or -not $Cleanup.dashboard_port_free -or
      -not $Cleanup.isolated_root_removed -or $Cleanup.cold_leases_after_close -ne 0) {
    $result += "cleanup"
  }
  return @($result)
}

function Write-Result($Metrics, [string[]]$Failures, $Cleanup) {
  $bin = [System.IO.Path]::GetFullPath($PSCommandPath)
  if ($HOME -and $bin.StartsWith($HOME, [System.StringComparison]::OrdinalIgnoreCase)) { $bin = "~" + $bin.Substring($HOME.Length) }
  [Console]::Out.WriteLine("bin: $(Quote-Toon $bin)")
  [Console]::Out.WriteLine("description: Run isolated Symphony++ MCP cold, warm, direct HTTP, and payload performance gates")
  [Console]::Out.WriteLine("status: $(if ($Failures.Count -eq 0) { 'pass' } else { 'fail' })")
  [Console]::Out.WriteLine("revision: $(Quote-Toon $Metrics.revision)")
  [Console]::Out.WriteLine("clients: $($Metrics.warm.clients)")
  [Console]::Out.WriteLine("thresholds:")
  [Console]::Out.WriteLine("  isolated_bootstrap_ms: $MaxColdMs")
  [Console]::Out.WriteLine("  warm_p95_ms: $MaxWarmP95Ms")
  [Console]::Out.WriteLine("  exact_warm_p95_ms: 1=$($exactP95Caps[1]),10=$($exactP95Caps[10]),100=$($exactP95Caps[100])")
  [Console]::Out.WriteLine("  exact_warm_private_bytes: $MaxExactWarmBytes")
  [Console]::Out.WriteLine("  direct_elapsed_ms: $MaxDirectMs")
  [Console]::Out.WriteLine("  backend_private_bytes: $MaxBackendBytes")
  [Console]::Out.WriteLine("  backend_processes: 1")
  [Console]::Out.WriteLine("  warm_leases_peak: $Clients")
  [Console]::Out.WriteLine("  zero_limits[5]: warm_leases_after,warm_network_attempts,wrapper_processes,wrapper_private_bytes,cold_leases_after_close")
  [Console]::Out.WriteLine("cold:")
  [Console]::Out.WriteLine("  isolated_bootstrap_ms: $($Metrics.cold.isolated_bootstrap_ms)")
  [Console]::Out.WriteLine("  budget_kind: isolated_compile_and_bootstrap")
  [Console]::Out.WriteLine("  backend_processes: $($Metrics.cold.backend_processes)")
  [Console]::Out.WriteLine("  backend_pid: $($Metrics.cold.backend_pid)")
  [Console]::Out.WriteLine("  backend_start_ticks: $($Metrics.cold.backend_start_ticks)")
  [Console]::Out.WriteLine("  leases_peak: $($Metrics.cold.leases_peak)")
  [Console]::Out.WriteLine("warm:")
  foreach ($name in @("p50_ms", "p95_ms", "max_ms", "backend_processes", "leases_peak", "leases_after", "remote_resolution_attempts")) {
    [Console]::Out.WriteLine("  ${name}: $($Metrics.warm.$name)")
  }
  [Console]::Out.WriteLine("exact_command:")
  foreach ($mode in @("node", "fallback")) {
    $exact = $Metrics.exact.$mode
    $cohorts = @($exact.warm | Where-Object { $_.clients -ge 10 })
    [Console]::Out.WriteLine("  ${mode}_p95_ms: $(($cohorts.p95_initialize_ms | Measure-Object -Maximum).Maximum)")
    [Console]::Out.WriteLine("  ${mode}_median_private_bytes: $(($cohorts.process_tree.median_private_bytes_per_client | Measure-Object -Maximum).Maximum)")
    [Console]::Out.WriteLine("  ${mode}_recovery_ms: $($exact.recovery.initialize_ms)")
  }
  [Console]::Out.WriteLine("  node_abandoned_locks_reclaimed: $($Metrics.exact.node.lock_recovery.reclaimed.ToString().ToLowerInvariant())")
  [Console]::Out.WriteLine("  node_lifecycle_race_healthy: $($Metrics.exact.node.lifecycle_race.healthy.ToString().ToLowerInvariant())")
  [Console]::Out.WriteLine("direct:")
  foreach ($name in @("clients", "elapsed_ms", "backend_processes", "backend_pid", "backend_start_ticks", "backend_private_bytes", "transport_processes", "transport_private_bytes", "host_private_bytes_delta")) {
    [Console]::Out.WriteLine("  ${name}: $($Metrics.direct.$name)")
  }
  [Console]::Out.WriteLine("profiles[5]{name,tools,bytes,tokens_estimate,max_tools,max_bytes}:")
  foreach ($name in $profileCaps.Keys) {
    $row = $Metrics.profiles.$name; $cap = $profileCaps[$name]
    [Console]::Out.WriteLine("  $name,$($row.tools),$($row.bytes),$($row.tokens_estimate),$($cap.tools),$($cap.bytes)")
  }
  [Console]::Out.WriteLine("results[3]{name,bytes,tokens_estimate,max_bytes}:")
  foreach ($name in $resultCaps.Keys) {
    $row = $Metrics.results.$name
    [Console]::Out.WriteLine("  $name,$($row.bytes),$($row.tokens_estimate),$($resultCaps[$name])")
  }
  [Console]::Out.WriteLine("failures[$($Failures.Count)]:$(if ($Failures.Count) { ' ' + ($Failures -join ',') } else { '' })")
  [Console]::Out.WriteLine("cleanup:")
  [Console]::Out.WriteLine("  backend_port_free: $(([bool]$Cleanup.backend_port_free).ToString().ToLowerInvariant())")
  [Console]::Out.WriteLine("  dashboard_port_free: $(([bool]$Cleanup.dashboard_port_free).ToString().ToLowerInvariant())")
  [Console]::Out.WriteLine("  cold_leases_after_close: $($Cleanup.cold_leases_after_close)")
  [Console]::Out.WriteLine("  isolated_root_removed: $(([bool]$Cleanup.isolated_root_removed).ToString().ToLowerInvariant())")
}

function New-IsolatedPort([int[]]$Avoid) {
  do {
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try { $probe.Start(); $port = [int]$probe.LocalEndpoint.Port } finally { $probe.Stop() }
  } while ($port -in $Avoid -or $port -in @(19998, 19999))
  return $port
}

function Get-ListenerPids([int]$Port) {
  return @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
}

function Set-IsolatedEnvironment($ProcessInfo, [hashtable]$Environment) {
  foreach ($key in @($ProcessInfo.Environment.Keys)) {
    if ([string]$key -match "(?i)(TOKEN|SECRET|API_KEY|AUTHORIZATION|GITHUB|LINEAR|OPENAI)" -or [string]$key -in @("SYMPP_BACKEND_URL", "SYMPP_DASHBOARD_ORIGIN")) {
      [void]$ProcessInfo.Environment.Remove([string]$key)
    }
  }
  foreach ($entry in $Environment.GetEnumerator()) { $ProcessInfo.Environment[$entry.Key] = [string]$entry.Value }
}

function Start-IsolatedLauncher([hashtable]$Environment) {
  $info = [System.Diagnostics.ProcessStartInfo]::new()
  $info.FileName = (Get-Command pwsh -ErrorAction Stop).Source
  foreach ($arg in @("-NoProfile", "-File", $launcher)) { [void]$info.ArgumentList.Add($arg) }
  $info.WorkingDirectory = $repoRoot; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
  $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
  Set-IsolatedEnvironment $info $Environment
  $process = [System.Diagnostics.Process]::new(); $process.StartInfo = $info
  if (-not $process.Start()) { throw "failed to start isolated launcher" }
  $process | Add-Member NoteProperty GateStdoutTask ($process.StandardOutput.ReadToEndAsync())
  $process | Add-Member NoteProperty GateStderrTask ($process.StandardError.ReadToEndAsync())
  return $process
}

function Invoke-CapturedProcess($Info, [int]$TimeoutMs, [string]$Label) {
  $Info.UseShellExecute = $false; $Info.CreateNoWindow = $true
  $Info.RedirectStandardOutput = $true; $Info.RedirectStandardError = $true
  $process = [System.Diagnostics.Process]::Start($Info)
  $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit($TimeoutMs)) { $process.Kill($true); throw "$Label timed out" }
  $stdout = $stdoutTask.GetAwaiter().GetResult(); $stderr = $stderrTask.GetAwaiter().GetResult()
  $result = [pscustomobject]@{ stdout = $stdout; stderr = $stderr; exit_code = $process.ExitCode }
  $process.Dispose()
  return $result
}

function Invoke-ExactCommandProbe([string]$Mode, [string]$Cohorts, [switch]$CheckMutation) {
  $info = [System.Diagnostics.ProcessStartInfo]::new()
  $info.FileName = (Get-Command pwsh -ErrorAction Stop).Source
  foreach ($arg in @("-NoProfile", "-File", $exactProbe, "-LauncherMode", $Mode, "-Cohorts", $Cohorts, "-Repeats", "1")) { [void]$info.ArgumentList.Add($arg) }
  if (-not $CheckMutation) { [void]$info.ArgumentList.Add("-SkipMutationCheck") }
  $info.WorkingDirectory = $repoRoot
  $run = Invoke-CapturedProcess $info 900000 "exact shipped command ($Mode)"
  if ($run.exit_code -ne 0) { throw "exact shipped command ($Mode) failed: $(([string]$run.stderr).Trim()) $(([string]$run.stdout).Trim())" }
  return $run.stdout | ConvertFrom-Json
}

function Invoke-IsolatedMix([string[]]$Arguments, [hashtable]$Environment) {
  $mix = (Get-Command mix -ErrorAction Stop).Source; $info = [System.Diagnostics.ProcessStartInfo]::new()
  if ([System.IO.Path]::GetExtension($mix) -eq ".ps1") { $info.FileName = (Get-Command pwsh -ErrorAction Stop).Source; $arguments = @("-NoProfile", "-File", $mix) + $Arguments }
  else { $info.FileName = $mix; $arguments = $Arguments }
  foreach ($arg in $arguments) { [void]$info.ArgumentList.Add($arg) }
  $info.WorkingDirectory = Join-Path $repoRoot "elixir"; Set-IsolatedEnvironment $info $Environment
  $result = Invoke-CapturedProcess $info 600000 "isolated mix command"
  if ($result.exit_code -ne 0) { throw "isolated mix command failed: $(([string]$result.stderr).Trim())" }
  return $result.stdout
}

function ConvertFrom-DirectProbe([string[]]$Lines, [double]$ElapsedMs) {
  $row = @($Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+,' } | Select-Object -Last 1)
  if ($row.Count -ne 1) { throw "direct HTTP probe omitted its machine-readable measurement row" }
  $parts = $row[0].Split(',')
  if ($parts.Count -ne 8) { throw "direct HTTP probe returned an invalid measurement row" }
  return [pscustomobject]@{
    clients = [int]$parts[0]; backend_processes = [int]$parts[1]; backend_pid = [int]$parts[2]
    backend_start_ticks = [long]$parts[3]; backend_private_bytes = [long]$parts[4]
    transport_processes = [int]$parts[5]; transport_private_bytes = [long]$parts[6]
    host_private_bytes_delta = [long]$parts[7]; elapsed_ms = [Math]::Round($ElapsedMs, 2)
  }
}

function Invoke-SelfTest {
  $base = [pscustomobject]@{
    cold = [pscustomobject]@{ isolated_bootstrap_ms = 1; backend_processes = 1; backend_pid = 1; backend_start_ticks = 1; leases_peak = 1 }
    warm = [pscustomobject]@{ clients = 100; p95_ms = 1; backend_processes = 1; leases_peak = 100; leases_after = 0; remote_resolution_attempts = 0 }
    direct = [pscustomobject]@{ clients = 100; elapsed_ms = 1; backend_processes = 1; backend_pid = 1; backend_start_ticks = 1; transport_processes = 0; transport_private_bytes = 0; backend_private_bytes = 1 }
    exact = [pscustomobject]@{
      node = [pscustomobject]@{ cold = [pscustomobject]@{ trace = [pscustomobject]@{ installed_identity_full_validation = 1; payload_hash_validation = 1; marketplace_git_validation = 1; artifact_manifest_resolution = 1 } }; warm = @([pscustomobject]@{ clients = 10; p95_initialize_ms = 1; git_invocations = 0; trace = [pscustomobject]@{ payload_hash_validation = 0; marketplace_git_validation = 0; contract_fingerprint_resolution = 0; artifact_manifest_resolution = 0 }; process_tree = [pscustomobject]@{ median_private_bytes_per_client = 1 } }); lock_recovery = [pscustomobject]@{ checked = $true; reclaimed = $true }; lifecycle_race = [pscustomobject]@{ checked = $true; healthy = $true }; recovery = [pscustomobject]@{ dashboard_healthy = $true }; mutation = [pscustomobject]@{ checked = $true; shortcut_rejected = $true } }
      fallback = [pscustomobject]@{ warm = @([pscustomobject]@{ clients = 10; p95_initialize_ms = 1; process_tree = [pscustomobject]@{ median_private_bytes_per_client = 1 } }); recovery = [pscustomobject]@{ dashboard_healthy = $true } }
    }
    profiles = [pscustomobject]@{ full = @{ tools = 1; bytes = 1 }; worker = @{ tools = 1; bytes = 1 }; architect = @{ tools = 1; bytes = 1 }; coordinator = @{ tools = 1; bytes = 1 }; solo = @{ tools = 1; bytes = 1 } }
    results = [pscustomobject]@{ claim = @{ bytes = 1 }; read = @{ bytes = 1 }; progress = @{ bytes = 1 } }
  }
  $cases = [ordered]@{
    "cold.isolated_bootstrap_ms" = { param($m) $m.cold.isolated_bootstrap_ms = $MaxColdMs + 1 }
    "warm.p95_ms" = { param($m) $m.warm.p95_ms = $MaxWarmP95Ms + 1 }
    "direct.elapsed_ms" = { param($m) $m.direct.elapsed_ms = $MaxDirectMs + 1 }
    "cohort.clients" = { param($m) $m.direct.clients = 99 }
    "backend.singleton" = { param($m) $m.direct.backend_processes = 2 }
    "backend.identity" = { param($m) $m.direct.backend_pid = 2 }
    "warm.lease_lifecycle" = { param($m) $m.warm.leases_after = 1 }
    "warm.network_attempts" = { param($m) $m.warm.remote_resolution_attempts = 1 }
    "direct.wrapper_processes" = { param($m) $m.direct.transport_processes = 1 }
    "direct.wrapper_private_bytes" = { param($m) $m.direct.transport_private_bytes = 1 }
    "direct.backend_private_bytes" = { param($m) $m.direct.backend_private_bytes = $MaxBackendBytes + 1 }
    "exact.node.p95_ms" = { param($m) $m.exact.node.warm[0].p95_initialize_ms = $exactP95Caps[10] + 1 }
    "exact.node.private_bytes" = { param($m) $m.exact.node.warm[0].process_tree.median_private_bytes_per_client = $MaxExactWarmBytes + 1 }
    "exact.node.warm_resolution" = { param($m) $m.exact.node.warm[0].git_invocations = 1 }
    "exact.node.cold_resolution" = { param($m) $m.exact.node.cold.trace.artifact_manifest_resolution = 2 }
    "exact.node.lock_recovery" = { param($m) $m.exact.node.lock_recovery.reclaimed = $false }
    "exact.node.lifecycle_race" = { param($m) $m.exact.node.lifecycle_race.healthy = $false }
    "exact.node.recovery_integrity" = { param($m) $m.exact.node.mutation.shortcut_rejected = $false }
    "exact.fallback.functional" = { param($m) $m.exact.fallback.recovery.dashboard_healthy = $false }
  }
  $baseFailures = @(Get-GateFailures $base $thresholds)
  if ($baseFailures.Count -ne 0) { throw "valid baseline unexpectedly failed: $($baseFailures -join ',')" }
  $detected = [System.Collections.Generic.List[string]]::new()
  foreach ($expected in $cases.Keys) {
    $metrics = $base | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    & $cases[$expected] $metrics
    if ((Get-GateFailures $metrics $thresholds) -notcontains $expected) { throw "intentional threshold failure was not detected: $expected" }
    $detected.Add($expected)
  }
  foreach ($name in $profileCaps.Keys) {
    foreach ($field in @("tools", "bytes")) {
      $expected = "profiles.$name.$field"; $metrics = $base | ConvertTo-Json -Depth 8 | ConvertFrom-Json
      $metrics.profiles.$name.$field = $profileCaps[$name][$field] + 1
      if ((Get-GateFailures $metrics $thresholds) -notcontains $expected) { throw "intentional threshold failure was not detected: $expected" }
      $detected.Add($expected)
    }
  }
  foreach ($name in $resultCaps.Keys) {
    $expected = "results.$name.bytes"; $metrics = $base | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $metrics.results.$name.bytes = $resultCaps[$name] + 1
    if ((Get-GateFailures $metrics $thresholds) -notcontains $expected) { throw "intentional threshold failure was not detected: $expected" }
    $detected.Add($expected)
  }
  $cleanup = @{ backend_port_free = $true; dashboard_port_free = $true; isolated_root_removed = $true; cold_leases_after_close = 1 }
  if ((Add-CleanupFailure @() $cleanup) -notcontains "cleanup") { throw "intentional threshold failure was not detected: cleanup" }
  $detected.Add("cleanup")
  [Console]::Out.WriteLine("status: pass")
  [Console]::Out.WriteLine("intentional_failures[$($detected.Count)]: $($detected -join ',')")
}

if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }
if ($SelfTest) { Invoke-SelfTest; exit 0 }
if ($Clients -ne 100) { [Console]::Out.WriteLine("error: -Clients must be 100 for the release gate"); exit 2 }
if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { [Console]::Out.WriteLine("error: Get-NetTCPConnection is required for listener ownership checks"); exit 2 }

$tempRoot = Join-Path $PSScriptRoot (".gate-" + [guid]::NewGuid().ToString("N"))
$runtimeFile = Join-Path $tempRoot "state/runtime.json"; $database = Join-Path $tempRoot "database/ledger.sqlite3"
$launcherProcess = $null; $runtime = $null; $backendStartTicks = $null; $failure = $null
$cleanup = [ordered]@{ backend_port_free = $false; dashboard_port_free = $false; cold_leases_after_close = -1; isolated_root_removed = $false }
try {
  $paths = @{
    SYMPP_HOME = Join-Path $tempRoot "home"; SYMPP_LOG_DIR = Join-Path $tempRoot "logs"
    MIX_BUILD_ROOT = Join-Path $tempRoot "mix-build"; MIX_DEPS_PATH = Join-Path $tempRoot "mix-deps"
    MIX_HOME = Join-Path $tempRoot "mix-home"; HEX_HOME = Join-Path $tempRoot "hex-home"
    REBAR_CACHE_DIR = Join-Path $tempRoot "rebar"; TEMP = Join-Path $tempRoot "tmp"; TMP = Join-Path $tempRoot "tmp"
    XDG_CONFIG_HOME = Join-Path $tempRoot "xdg/config"; XDG_CACHE_HOME = Join-Path $tempRoot "xdg/cache"; XDG_DATA_HOME = Join-Path $tempRoot "xdg/data"
  }
  foreach ($path in @($tempRoot, (Split-Path -Parent $runtimeFile), (Split-Path -Parent $database)) + @($paths.Values)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
  $sourceMixHome = if ($env:MIX_HOME) { $env:MIX_HOME } else { Join-Path ([Environment]::GetFolderPath("UserProfile")) ".mix" }
  foreach ($name in @("archives", "elixir")) { $source = Join-Path $sourceMixHome $name; if (Test-Path $source) { Copy-Item $source $paths.MIX_HOME -Recurse -Force } }
  $sourceHexHome = if ($env:HEX_HOME) { $env:HEX_HOME } else { Join-Path ([Environment]::GetFolderPath("UserProfile")) ".hex" }
  foreach ($name in @("packages", "cache.ets")) { $source = Join-Path $sourceHexHome $name; if (Test-Path $source) { Copy-Item $source $paths.HEX_HOME -Recurse -Force } }
  $backendPort = New-IsolatedPort @(); $dashboardPort = New-IsolatedPort @($backendPort)
  if (@(Get-ListenerPids $backendPort).Count -or @(Get-ListenerPids $dashboardPort).Count) { throw "unique gate ports were not empty before launch" }
  $environment = @{} + $paths + @{
    SYMPP_REPO_ROOT = $repoRoot; SYMPP_RUNTIME_FILE = $runtimeFile; SYMPP_DATABASE = $database
    SYMPP_BACKEND_PORT = $backendPort; SYMPP_DASHBOARD_PORT = $dashboardPort; SYMPP_DASHBOARD_ORIGIN = "http://127.0.0.1:$dashboardPort"; SYMPP_AUTOSTART_FRONTEND = "0"
    SYMPP_OPEN_DASHBOARD = "0"
    SYMPP_MCP_BRIDGE_MODE = "http"; SYMPP_SOURCE_FALLBACK = "1"; SYMPP_ARTIFACT_RUNTIME = "0"
    SYMPP_LAUNCHER = "direct"; SYMPP_ELIXIR_SETUP_TIMEOUT_SEC = "900"; HEX_OFFLINE = "1"
  }
  [Console]::Error.WriteLine("Starting isolated cold attach on a unique non-default port...")
  $coldWatch = [System.Diagnostics.Stopwatch]::StartNew(); $launcherProcess = Start-IsolatedLauncher $environment
  $deadline = [DateTime]::UtcNow.AddMinutes(15)
  do {
    if ($launcherProcess.HasExited) { throw "isolated launcher exited early: $(([string]$launcherProcess.GateStderrTask.GetAwaiter().GetResult()).Trim())" }
    if (Test-Path $runtimeFile) { try { $runtime = Get-Content $runtimeFile -Raw | ConvertFrom-Json } catch { $runtime = $null } }
    $leases = @(Get-ChildItem (Join-Path $tempRoot "state/codex-plugin-leases") -Filter "bridge-*.json" -File -ErrorAction SilentlyContinue)
    if ($runtime -and [int]$runtime.backend.port -eq $backendPort -and $leases.Count -eq 1) { break }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  $coldWatch.Stop()
  if (-not $runtime -or $leases.Count -ne 1) { throw "timed out waiting for isolated cold attach" }
  $owners = @(Get-ListenerPids $backendPort)
  if ($owners.Count -ne 1 -or [int]$owners[0] -ne [int]$runtime.backend.pid) { throw "isolated backend listener ownership mismatch" }
  $backend = Get-Process -Id ([int]$runtime.backend.pid) -ErrorAction Stop; $backendStartTicks = $backend.StartTime.ToUniversalTime().Ticks
  $cold = [pscustomobject]@{ isolated_bootstrap_ms = [Math]::Round($coldWatch.Elapsed.TotalMilliseconds, 2); backend_processes = 1; backend_pid = $backend.Id; backend_start_ticks = $backendStartTicks; leases_peak = 1 }
  [Console]::Error.WriteLine("Measuring 100 production warm attaches against a stubbed healthy endpoint...")
  $warm = & $warmProbe -Clients $Clients | ConvertFrom-Json
  [Console]::Error.WriteLine("Measuring 100 direct HTTP clients...")
  $directInfo = [System.Diagnostics.ProcessStartInfo]::new(); $directInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
  foreach ($arg in @("-NoProfile", "-File", $directProbe, "-Url", "http://127.0.0.1:$backendPort/mcp", "-ClientCounts", [string]$Clients)) { [void]$directInfo.ArgumentList.Add($arg) }
  $directInfo.WorkingDirectory = $repoRoot; Set-IsolatedEnvironment $directInfo $environment
  $directWatch = [System.Diagnostics.Stopwatch]::StartNew(); $directRun = Invoke-CapturedProcess $directInfo 120000 "direct HTTP probe"; $directWatch.Stop()
  if ($directRun.exit_code -ne 0) { throw "direct HTTP probe failed: $(([string]$directRun.stdout).Trim()) $(([string]$directRun.stderr).Trim())" }
  $direct = ConvertFrom-DirectProbe @($directRun.stdout -split "`r?`n") $directWatch.Elapsed.TotalMilliseconds
  [Console]::Error.WriteLine("Measuring the shipped command with Node present and missing...")
  $exactFallback = Invoke-ExactCommandProbe "NodeMissing" "1,10"
  $exactNode = Invoke-ExactCommandProbe "NodePresent" "1,10,100" -CheckMutation
  [Console]::Error.WriteLine("Measuring MCP profiles and representative payloads...")
  $payloadOutput = Invoke-IsolatedMix @("run", "--no-start", $payloadProbe) $environment
  $payloadJson = @($payloadOutput -split "`r?`n" | Where-Object { $_.Trim().StartsWith("{") } | Select-Object -Last 1)
  if ($payloadJson.Count -ne 1) { throw "payload probe omitted JSON output" }
  $payloads = $payloadJson[0] | ConvertFrom-Json
  $revision = [string](& git -C $repoRoot rev-parse HEAD); $metrics = [pscustomobject]@{ revision = $revision.Trim(); cold = $cold; warm = $warm; direct = $direct; exact = [pscustomobject]@{ node = $exactNode; fallback = $exactFallback }; profiles = $payloads.profiles; results = $payloads.results }
} catch {
  $failure = $_.Exception.Message
  $backendLog = @(Get-ChildItem (Join-Path $tempRoot "logs") -Filter "backend-*.err.log" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc | Select-Object -Last 1); if ($backendLog) { $detail = ([string](Get-Content $backendLog.FullName -Raw)).Trim(); if ($detail.Length -gt 2000) { $detail = $detail.Substring($detail.Length - 2000) }; $failure += "`nbackend stderr: $detail" }
} finally {
  if ($launcherProcess) {
    try { $launcherProcess.StandardInput.Close() } catch { }
    if (-not $launcherProcess.WaitForExit(60000)) { $launcherProcess.Kill($true); [void]$launcherProcess.WaitForExit(15000) }
    $launcherProcess.Dispose()
  }
  if ($tempRoot) {
    $leaseDir = Join-Path $tempRoot "state/codex-plugin-leases"
    $leaseDeadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
      $cleanup.cold_leases_after_close = @(Get-ChildItem $leaseDir -Filter "bridge-*.json" -File -ErrorAction SilentlyContinue).Count
      if ($cleanup.cold_leases_after_close -eq 0) { break }
      Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $leaseDeadline)
  }
  if ($runtime -and $backendStartTicks) {
    $backend = Get-Process -Id ([int]$runtime.backend.pid) -ErrorAction SilentlyContinue
    if ($backend) {
      if ($backend.StartTime.ToUniversalTime().Ticks -ne $backendStartTicks -or [int]$runtime.backend.port -ne $backendPort) { $failure = "cleanup refused changed backend identity" }
      else { Stop-Process -Id $backend.Id -Force -ErrorAction SilentlyContinue }
    }
  }
  $ownedRoot = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
  if ([System.IO.Path]::GetFullPath($tempRoot).StartsWith($ownedRoot, [System.StringComparison]::OrdinalIgnoreCase)) { Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
  if ($backendPort) { $cleanup.backend_port_free = @(Get-ListenerPids $backendPort).Count -eq 0 }
  if ($dashboardPort) { $cleanup.dashboard_port_free = @(Get-ListenerPids $dashboardPort).Count -eq 0 }
  $cleanup.isolated_root_removed = -not (Test-Path $tempRoot)
}

if ($failure) {
  [Console]::Out.WriteLine("status: error")
  [Console]::Out.WriteLine("error: $(Quote-Toon $failure)")
  [Console]::Out.WriteLine("cleanup:")
  foreach ($name in $cleanup.Keys) { $value = if ($name -eq "cold_leases_after_close") { $cleanup[$name] } else { ([bool]$cleanup[$name]).ToString().ToLowerInvariant() }; [Console]::Out.WriteLine("  ${name}: $value") }
  exit 1
}
$failures = Add-CleanupFailure @(Get-GateFailures $metrics $thresholds) $cleanup
Write-Result $metrics $failures $cleanup
exit $(if ($failures.Count -eq 0) { 0 } else { 1 })
