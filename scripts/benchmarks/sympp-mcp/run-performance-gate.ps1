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
  [ValidateRange(1, 600000)][int]$MaxArtifactCacheMissMs = 120000,
  [ValidateRange(1, 60000)][int]$MaxArtifactPreparedMs = 5000,
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
$stateProbe = Join-Path $PSScriptRoot "measure-state-hot-path.exs"
$responseListProbe = Join-Path $PSScriptRoot "measure-response-list-hot-path.exs"
$profileCaps = [ordered]@{
  full = @{ tools = 80; bytes = 55000 }; worker = @{ tools = 35; bytes = 25000 }
  architect = @{ tools = 65; bytes = 45000 }; coordinator = @{ tools = 30; bytes = 20000 }
  solo = @{ tools = 30; bytes = 20000 }
}
$resultCaps = [ordered]@{ claim = 600; read = 1200; progress = 500 }
$responseListCaps = [ordered]@{
  list_queries = 25; list_bytes = 30000; list_p95_ms = 400
  read_plan_p50_ratio = 0.8; read_plan_reductions_ratio = 0.9
}
$exactP95Caps = @{ 1 = $MaxWarmP95Ms; 10 = $MaxWarmP95Ms }
$thresholds = @{
  cold_ms = $MaxColdMs; warm_p95_ms = $MaxWarmP95Ms; exact_warm_p95_ms = $exactP95Caps
  artifact_cache_miss_ms = $MaxArtifactCacheMissMs; artifact_prepared_ms = $MaxArtifactPreparedMs
  exact_warm_bytes = $MaxExactWarmBytes; direct_ms = $MaxDirectMs
  clients = $Clients; backend_bytes = $MaxBackendBytes; profile_caps = $profileCaps; result_caps = $resultCaps
  response_list_caps = $responseListCaps
}

function Quote-Toon([string]$Value) {
  return '"' + $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n') + '"'
}

function Get-GateFailures($Metrics, $Limits) {
  $failures = [System.Collections.Generic.List[string]]::new()
  if ($Metrics.cold.isolated_bootstrap_ms -gt $Limits.cold_ms) { $failures.Add("cold.isolated_bootstrap_ms") }
  if ($Metrics.exact.node.artifact.cache_miss.process_ms -gt $Limits.artifact_cache_miss_ms) { $failures.Add("exact.node.artifact_cache_miss_ms") }
  if ($Metrics.exact.node.artifact.prepared_cache.process_ms -gt $Limits.artifact_prepared_ms) { $failures.Add("exact.node.artifact_prepared_ms") }
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
  if ($Metrics.state_hot_path.readiness_state.entry_growth -ne 0 -or $Metrics.state_hot_path.readiness_state.alias_growth -ne 0 -or $Metrics.state_hot_path.readiness_state.deadline_growth -ne 0) { $failures.Add("state_hot_path.readiness_state") }
  if ($Metrics.state_hot_path.operations.recovery_steady.write_statements -ne 0) { $failures.Add("state_hot_path.recovery_writes") }
  if ($Metrics.state_hot_path.ready_guard.package_reads_after_lock -ne 1 -or $Metrics.state_hot_path.ready_guard.history_reads_after_lock -ne 0) { $failures.Add("state_hot_path.ready_guard") }
  if (@($Metrics.state_hot_path.operations.PSObject.Properties.Value | Where-Object { $_.busy_retries -ne 0 }).Count -gt 0) { $failures.Add("state_hot_path.busy_retries") }
  if ($Metrics.response_list.read_plan.http.text_encodes.canonical -ne 1 -or $Metrics.response_list.read_plan.http.text_encodes.full -ne 0 -or $Metrics.response_list.read_plan.legacy_full_stdio.text_encodes.canonical -ne 0 -or $Metrics.response_list.read_plan.legacy_full_stdio.text_encodes.full -ne 1) { $failures.Add("response_list.read_plan_encoding") }
  if ($Metrics.response_list.read_plan.http.structured_nodes -ne 1000 -or $Metrics.response_list.read_plan.legacy_full_stdio.structured_nodes -ne 1000) { $failures.Add("response_list.read_plan_structured") }
  if ($Metrics.response_list.read_plan.http.p50_ms -gt ($Metrics.response_list.read_plan.legacy_full_stdio.p50_ms * $Limits.response_list_caps.read_plan_p50_ratio)) { $failures.Add("response_list.read_plan_p50") }
  if ($Metrics.response_list.read_plan.http.reductions_p50 -gt ($Metrics.response_list.read_plan.legacy_full_stdio.reductions_p50 * $Limits.response_list_caps.read_plan_reductions_ratio)) { $failures.Add("response_list.read_plan_reductions") }
  if ($Metrics.response_list.list_work_requests.query_count -gt $Limits.response_list_caps.list_queries -or $Metrics.response_list.list_work_requests.work_request_queries -ne 1 -or $Metrics.response_list.list_work_requests.repo_scope_queries -ne 1) { $failures.Add("response_list.list_queries") }
  if ($Metrics.response_list.list_work_requests.bytes -gt $Limits.response_list_caps.list_bytes -or $Metrics.response_list.list_work_requests.returned -ne 50 -or -not $Metrics.response_list.list_work_requests.has_next_cursor) { $failures.Add("response_list.list_bound") }
  if ($Metrics.response_list.list_work_requests.p95_ms -gt $Limits.response_list_caps.list_p95_ms) { $failures.Add("response_list.list_p95") }
  $nodeCohorts = @($Metrics.exact.node.warm | Where-Object { $_.clients -ge 10 })
  $missingSloCohorts = @($Limits.exact_warm_p95_ms.Keys | Where-Object { $clients = [int]$_; @($Metrics.exact.node.warm | Where-Object { [int]$_.clients -eq $clients }).Count -eq 0 })
  if ($missingSloCohorts.Count -gt 0 -or @($Metrics.exact.node.warm | Where-Object { $Limits.exact_warm_p95_ms.ContainsKey([int]$_.clients) -and $_.p95_initialize_ms -gt $Limits.exact_warm_p95_ms[[int]$_.clients] }).Count -gt 0) { $failures.Add("exact.node.p95_ms") }
  $node100 = @($Metrics.exact.node.warm | Where-Object { [int]$_.clients -eq 100 })
  if ($node100.Count -ne 1 -or [int]$node100[0].startup_burst -lt 1 -or [int]$node100[0].startup_burst -gt 10 -or [int]$node100[0].leases_peak -ne 101 -or [int]$node100[0].leases_after -ne 1 -or [int]$node100[0].process_tree.node_clients -ne 100 -or [int]$node100[0].process_tree.min_processes_per_client -lt 2) { $failures.Add("exact.node.live_100") }
  if ($nodeCohorts.Count -eq 0 -or ($nodeCohorts.process_tree.median_private_bytes_per_client | Measure-Object -Maximum).Maximum -gt $Limits.exact_warm_bytes) { $failures.Add("exact.node.private_bytes") }
  if (@($Metrics.exact.node.warm | Where-Object { $_.git_invocations -ne 0 -or [int]$_.trace.payload_hash_validation -ne 0 -or [int]$_.trace.marketplace_git_validation -ne 0 -or [int]$_.trace.contract_fingerprint_resolution -ne 0 -or [int]$_.trace.artifact_manifest_resolution -ne 0 }).Count -gt 0) { $failures.Add("exact.node.warm_resolution") }
  if ([int]$Metrics.exact.node.cold.trace.installed_identity_full_validation -ne 1 -or [int]$Metrics.exact.node.cold.trace.payload_hash_validation -ne 0 -or [int]$Metrics.exact.node.cold.trace.marketplace_git_validation -ne 0 -or [int]$Metrics.exact.node.cold.trace.artifact_manifest_resolution -ne 1) { $failures.Add("exact.node.cold_resolution") }
  if (-not $Metrics.exact.node.lock_recovery.checked -or -not $Metrics.exact.node.lock_recovery.reclaimed) { $failures.Add("exact.node.lock_recovery") }
  if (-not $Metrics.exact.node.lifecycle_race.checked -or -not $Metrics.exact.node.lifecycle_race.healthy) { $failures.Add("exact.node.lifecycle_race") }
  if (-not $Metrics.exact.node.recovery.dashboard_healthy -or -not $Metrics.exact.node.mutation.checked -or -not $Metrics.exact.node.mutation.shortcut_rejected -or -not $Metrics.exact.node.mutation.scan_race_detected -or -not $Metrics.exact.node.mutation.attach_race_rejected) { $failures.Add("exact.node.recovery_integrity") }
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
  [Console]::Out.WriteLine("description: Run isolated Symphony++ MCP cold, warm, direct HTTP, state, SQLite, and payload performance gates")
  [Console]::Out.WriteLine("status: $(if ($Failures.Count -eq 0) { 'pass' } else { 'fail' })")
  [Console]::Out.WriteLine("revision: $(Quote-Toon $Metrics.revision)")
  [Console]::Out.WriteLine("clients: $($Metrics.warm.clients)")
  [Console]::Out.WriteLine("thresholds:")
  [Console]::Out.WriteLine("  isolated_bootstrap_ms: $MaxColdMs")
  [Console]::Out.WriteLine("  artifact_cache_miss_ms: $MaxArtifactCacheMissMs")
  [Console]::Out.WriteLine("  artifact_prepared_ms: $MaxArtifactPreparedMs")
  [Console]::Out.WriteLine("  warm_p95_ms: $MaxWarmP95Ms")
  [Console]::Out.WriteLine("  exact_warm_p95_ms: 1=$($exactP95Caps[1]),10=$($exactP95Caps[10])")
  [Console]::Out.WriteLine("  exact_warm_private_bytes: $MaxExactWarmBytes")
  [Console]::Out.WriteLine("  direct_elapsed_ms: $MaxDirectMs")
  [Console]::Out.WriteLine("  backend_private_bytes: $MaxBackendBytes")
  [Console]::Out.WriteLine("  backend_processes: 1")
  [Console]::Out.WriteLine("  response_list: list_queries=$($responseListCaps.list_queries),list_bytes=$($responseListCaps.list_bytes),list_p95_ms=$($responseListCaps.list_p95_ms),read_plan_p50_ratio=$($responseListCaps.read_plan_p50_ratio),read_plan_reductions_ratio=$($responseListCaps.read_plan_reductions_ratio)")
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
  $artifact = $Metrics.exact.node.artifact
  [Console]::Out.WriteLine("  artifact_cache_miss: process_ms=$($artifact.cache_miss.process_ms),download_ms=$($artifact.cache_miss.download_ms),hash_ms=$($artifact.cache_miss.hash_ms),extract_ms=$($artifact.cache_miss.extract_ms),dashboard_proof_ms=$($artifact.cache_miss.dashboard_proof_ms),promotion_ms=$($artifact.cache_miss.promotion_ms)")
  [Console]::Out.WriteLine("  artifact_prepared_cache: process_ms=$($artifact.prepared_cache.process_ms),dashboard_proof_ms=$($artifact.prepared_cache.dashboard_proof_ms)")
  foreach ($mode in @("node", "fallback")) {
    $exact = $Metrics.exact.$mode
    $cohorts = @($exact.warm | Where-Object { $_.clients -ge 10 })
    $sloCohorts = @($exact.warm | Where-Object { $exactP95Caps.ContainsKey([int]$_.clients) })
    $latencyLabel = if ($mode -eq "node") { "node_slo_p95_ms" } else { "fallback_reported_p95_ms" }
    [Console]::Out.WriteLine("  ${latencyLabel}: $(($sloCohorts.p95_initialize_ms | Measure-Object -Maximum).Maximum)")
    [Console]::Out.WriteLine("  ${mode}_median_private_bytes: $(($cohorts.process_tree.median_private_bytes_per_client | Measure-Object -Maximum).Maximum)")
    [Console]::Out.WriteLine("  ${mode}_recovery_ms: $($exact.recovery.initialize_ms)")
  }
  $node100 = @($Metrics.exact.node.warm | Where-Object { [int]$_.clients -eq 100 })[0]
  [Console]::Out.WriteLine("  node_100_reported_p95_ms: $($node100.p95_initialize_ms)")
  [Console]::Out.WriteLine("  node_100_startup_burst: $($node100.startup_burst)")
  [Console]::Out.WriteLine("  node_abandoned_locks_reclaimed: $($Metrics.exact.node.lock_recovery.reclaimed.ToString().ToLowerInvariant())")
  [Console]::Out.WriteLine("  node_lifecycle_race_healthy: $($Metrics.exact.node.lifecycle_race.healthy.ToString().ToLowerInvariant())")
  [Console]::Out.WriteLine("direct:")
  foreach ($name in @("clients", "elapsed_ms", "backend_processes", "backend_pid", "backend_start_ticks", "backend_private_bytes", "transport_processes", "transport_private_bytes", "host_private_bytes_delta")) {
    [Console]::Out.WriteLine("  ${name}: $($Metrics.direct.$name)")
  }
  [Console]::Out.WriteLine("state_hot_path:")
  [Console]::Out.WriteLine("  readiness_state_growth: entries=$($Metrics.state_hot_path.readiness_state.entry_growth),aliases=$($Metrics.state_hot_path.readiness_state.alias_growth),deadlines=$($Metrics.state_hot_path.readiness_state.deadline_growth)")
  [Console]::Out.WriteLine("  ready_guard_1000: package_reads=$($Metrics.state_hot_path.ready_guard.package_reads_after_lock),history_reads=$($Metrics.state_hot_path.ready_guard.history_reads_after_lock)")
  [Console]::Out.WriteLine("  operations[7]{name,samples,p50_ms,p95_ms,max_ms,sql_statements,write_statements,busy_retries}:")
  foreach ($property in $Metrics.state_hot_path.operations.PSObject.Properties) {
    $row = $property.Value
    [Console]::Out.WriteLine("    $($property.Name),$($row.samples),$($row.p50_ms),$($row.p95_ms),$($row.max_ms),$($row.sql_statements),$($row.write_statements),$($row.busy_retries)")
  }
  [Console]::Out.WriteLine("response_list_hot_path:")
  [Console]::Out.WriteLine("  read_plan_http: p50_ms=$($Metrics.response_list.read_plan.http.p50_ms),p95_ms=$($Metrics.response_list.read_plan.http.p95_ms),allocation_bytes_p50=$($Metrics.response_list.read_plan.http.allocation_bytes_p50),bytes=$($Metrics.response_list.read_plan.http.bytes),reductions_p50=$($Metrics.response_list.read_plan.http.reductions_p50),full_encodes=$($Metrics.response_list.read_plan.http.text_encodes.full),canonical_encodes=$($Metrics.response_list.read_plan.http.text_encodes.canonical)")
  [Console]::Out.WriteLine("  read_plan_legacy_full_stdio: p50_ms=$($Metrics.response_list.read_plan.legacy_full_stdio.p50_ms),p95_ms=$($Metrics.response_list.read_plan.legacy_full_stdio.p95_ms),allocation_bytes_p50=$($Metrics.response_list.read_plan.legacy_full_stdio.allocation_bytes_p50),bytes=$($Metrics.response_list.read_plan.legacy_full_stdio.bytes),reductions_p50=$($Metrics.response_list.read_plan.legacy_full_stdio.reductions_p50),full_encodes=$($Metrics.response_list.read_plan.legacy_full_stdio.text_encodes.full),canonical_encodes=$($Metrics.response_list.read_plan.legacy_full_stdio.text_encodes.canonical)")
  [Console]::Out.WriteLine("  list_work_requests: p50_ms=$($Metrics.response_list.list_work_requests.p50_ms),p95_ms=$($Metrics.response_list.list_work_requests.p95_ms),allocation_bytes_p50=$($Metrics.response_list.list_work_requests.allocation_bytes_p50),bytes=$($Metrics.response_list.list_work_requests.bytes),queries=$($Metrics.response_list.list_work_requests.query_count),repo_scope_queries=$($Metrics.response_list.list_work_requests.repo_scope_queries),returned=$($Metrics.response_list.list_work_requests.returned),has_next_cursor=$($Metrics.response_list.list_work_requests.has_next_cursor.ToString().ToLowerInvariant())")
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

function Stop-CapturedProcessTree($Process, [string]$Label) {
  $killInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $killInfo.FileName = (Get-Command taskkill.exe -ErrorAction Stop).Source
  foreach ($arg in @("/PID", [string]$Process.Id, "/T", "/F")) { [void]$killInfo.ArgumentList.Add($arg) }
  $killInfo.UseShellExecute = $false; $killInfo.CreateNoWindow = $true
  $killInfo.RedirectStandardOutput = $true; $killInfo.RedirectStandardError = $true
  $killer = [System.Diagnostics.Process]::new(); $killer.StartInfo = $killInfo
  $stdoutTask = $null; $stderrTask = $null
  try {
    if (-not $killer.Start()) { throw "$Label timeout cleanup failed to start" }
    $stdoutTask = $killer.StandardOutput.ReadToEndAsync(); $stderrTask = $killer.StandardError.ReadToEndAsync()
    if (-not $killer.WaitForExit(15000)) {
      try { $killer.Kill() } catch [System.InvalidOperationException] { }
      [void]$killer.WaitForExit(5000)
    }
  } finally {
    if ($stdoutTask) { [void]$stdoutTask.GetAwaiter().GetResult() }
    if ($stderrTask) { [void]$stderrTask.GetAwaiter().GetResult() }
    $killer.Dispose()
  }
  if (-not $Process.WaitForExit(15000)) { throw "$Label timed out and its process tree did not exit" }
}

function Read-AvailableProcessOutput([object[]]$Streams) {
  foreach ($stream in $Streams) {
    $chunksRead = 0
    while ($chunksRead -lt 1024 -and $null -ne $stream.task -and $stream.task.IsCompleted) {
      $count = $stream.task.GetAwaiter().GetResult()
      if ($count -eq 0) { $stream.task = $null }
      else {
        [void]$stream.output.Append($stream.buffer, 0, $count)
        $stream.task = $stream.reader.ReadAsync($stream.buffer, 0, $stream.buffer.Length)
        $chunksRead++
      }
    }
  }
}

function Invoke-CapturedProcess($Info, [int]$TimeoutMs, [string]$Label) {
  $Info.UseShellExecute = $false; $Info.CreateNoWindow = $true
  $Info.RedirectStandardOutput = $true; $Info.RedirectStandardError = $true
  $process = [System.Diagnostics.Process]::new(); $process.StartInfo = $Info
  if (-not $process.Start()) { throw "$Label failed to start" }
  $stdoutBuffer = [char[]]::new(4096); $stderrBuffer = [char[]]::new(4096)
  $streams = @(
    [pscustomobject]@{ reader = $process.StandardOutput; buffer = $stdoutBuffer; task = $process.StandardOutput.ReadAsync($stdoutBuffer, 0, $stdoutBuffer.Length); output = [System.Text.StringBuilder]::new() }
    [pscustomobject]@{ reader = $process.StandardError; buffer = $stderrBuffer; task = $process.StandardError.ReadAsync($stderrBuffer, 0, $stderrBuffer.Length); output = [System.Text.StringBuilder]::new() }
  )
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
    Read-AvailableProcessOutput $streams
    Start-Sleep -Milliseconds 10
  }
  $timedOut = -not $process.HasExited
  if ($timedOut) {
    try { Stop-CapturedProcessTree $process $Label } catch { $process.Dispose(); throw }
  }
  $drainDeadline = [DateTime]::UtcNow.AddSeconds(2)
  $maximumDrainDeadline = [DateTime]::UtcNow.AddSeconds(30)
  do {
    $capturedLength = $streams[0].output.Length + $streams[1].output.Length
    Read-AvailableProcessOutput $streams
    if (($streams[0].output.Length + $streams[1].output.Length) -gt $capturedLength) {
      $extendedDeadline = [DateTime]::UtcNow.AddSeconds(2)
      $drainDeadline = if ($extendedDeadline -lt $maximumDrainDeadline) { $extendedDeadline } else { $maximumDrainDeadline }
    }
    if (@($streams | Where-Object { $null -ne $_.task }).Count -eq 0) { break }
    Start-Sleep -Milliseconds 10
  } while ([DateTime]::UtcNow -lt $drainDeadline -and [DateTime]::UtcNow -lt $maximumDrainDeadline)
  if ($timedOut) {
    $timeoutStdout = $streams[0].output.ToString()
    $timeoutStderr = $streams[1].output.ToString()
    if ($timeoutStdout.Length -gt 2000) { $timeoutStdout = $timeoutStdout.Substring($timeoutStdout.Length - 2000) }
    if ($timeoutStderr.Length -gt 2000) { $timeoutStderr = $timeoutStderr.Substring($timeoutStderr.Length - 2000) }
    $process.Dispose()
    throw "$Label timed out. stdout_tail=$timeoutStdout stderr_tail=$timeoutStderr"
  }
  $result = [pscustomobject]@{
    stdout = $streams[0].output.ToString()
    stderr = $streams[1].output.ToString()
    exit_code = $process.ExitCode
  }
  $process.Dispose()
  return $result
}

function Invoke-ExactCommandProbe([string]$Mode, [string]$Cohorts, [switch]$CheckMutation) {
  $artifactPreparationTimeoutSec = 600
  $info = [System.Diagnostics.ProcessStartInfo]::new()
  $info.FileName = (Get-Command pwsh -ErrorAction Stop).Source
  foreach ($arg in @("-NoProfile", "-File", $exactProbe, "-LauncherMode", $Mode, "-Cohorts", $Cohorts, "-Repeats", "1", "-ArtifactPreparationTimeoutSec", [string]$artifactPreparationTimeoutSec)) { [void]$info.ArgumentList.Add($arg) }
  if (-not $CheckMutation) { [void]$info.ArgumentList.Add("-SkipMutationCheck") }
  $info.WorkingDirectory = $repoRoot
  $run = Invoke-CapturedProcess $info ((900 + $artifactPreparationTimeoutSec) * 1000) "exact shipped command ($Mode)"
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

function New-SelfTestExactCohort([int]$Clients) {
  return [pscustomobject]@{
    clients = $Clients
    startup_burst = [Math]::Min(10, $Clients)
    p95_initialize_ms = 1
    leases_peak = $Clients + 1
    leases_after = 1
    git_invocations = 0
    trace = [pscustomobject]@{ payload_hash_validation = 0; marketplace_git_validation = 0; contract_fingerprint_resolution = 0; artifact_manifest_resolution = 0 }
    process_tree = [pscustomobject]@{ median_private_bytes_per_client = 1; min_processes_per_client = 2; node_clients = $Clients }
  }
}

function Invoke-SelfTest {
  $base = [pscustomobject]@{
    cold = [pscustomobject]@{ isolated_bootstrap_ms = 1; backend_processes = 1; backend_pid = 1; backend_start_ticks = 1; leases_peak = 1 }
    warm = [pscustomobject]@{ clients = 100; p95_ms = 1; backend_processes = 1; leases_peak = 100; leases_after = 0; remote_resolution_attempts = 0 }
    direct = [pscustomobject]@{ clients = 100; elapsed_ms = 1; backend_processes = 1; backend_pid = 1; backend_start_ticks = 1; transport_processes = 0; transport_private_bytes = 0; backend_private_bytes = 1 }
    exact = [pscustomobject]@{
      node = [pscustomobject]@{ artifact = [pscustomobject]@{ cache_miss = [pscustomobject]@{ process_ms = 1 }; prepared_cache = [pscustomobject]@{ process_ms = 1 } }; cold = [pscustomobject]@{ trace = [pscustomobject]@{ installed_identity_full_validation = 1; payload_hash_validation = 0; marketplace_git_validation = 0; artifact_manifest_resolution = 1 } }; warm = @(New-SelfTestExactCohort 1; New-SelfTestExactCohort 10; New-SelfTestExactCohort 100); lock_recovery = [pscustomobject]@{ checked = $true; reclaimed = $true }; lifecycle_race = [pscustomobject]@{ checked = $true; healthy = $true }; recovery = [pscustomobject]@{ dashboard_healthy = $true }; mutation = [pscustomobject]@{ checked = $true; shortcut_rejected = $true; scan_race_detected = $true; attach_race_rejected = $true } }
      fallback = [pscustomobject]@{ warm = @([pscustomobject]@{ clients = 10; p95_initialize_ms = 1; process_tree = [pscustomobject]@{ median_private_bytes_per_client = 1 } }); recovery = [pscustomobject]@{ dashboard_healthy = $true } }
    }
    profiles = [pscustomobject]@{ full = @{ tools = 1; bytes = 1 }; worker = @{ tools = 1; bytes = 1 }; architect = @{ tools = 1; bytes = 1 }; coordinator = @{ tools = 1; bytes = 1 }; solo = @{ tools = 1; bytes = 1 } }
    results = [pscustomobject]@{ claim = @{ bytes = 1 }; read = @{ bytes = 1 }; progress = @{ bytes = 1 } }
    state_hot_path = [pscustomobject]@{
      readiness_state = [pscustomobject]@{ entry_growth = 0; alias_growth = 0; deadline_growth = 0 }
      ready_guard = [pscustomobject]@{ package_reads_after_lock = 1; history_reads_after_lock = 0 }
      operations = [pscustomobject]@{
        readiness = @{ busy_retries = 0 }; recovery_steady = @{ busy_retries = 0; write_statements = 0 }
        worker_read = @{ busy_retries = 0 }; worker_write = @{ busy_retries = 0 }
        architect_read = @{ busy_retries = 0 }; architect_write = @{ busy_retries = 0 }; ready_guard_1000 = @{ busy_retries = 0 }
      }
    }
    response_list = [pscustomobject]@{
      read_plan = [pscustomobject]@{
        http = [pscustomobject]@{ p50_ms = 1; reductions_p50 = 1; structured_nodes = 1000; text_encodes = [pscustomobject]@{ canonical = 1; full = 0 } }
        legacy_full_stdio = [pscustomobject]@{ p50_ms = 2; reductions_p50 = 2; structured_nodes = 1000; text_encodes = [pscustomobject]@{ canonical = 0; full = 1 } }
      }
      list_work_requests = [pscustomobject]@{ query_count = 2; work_request_queries = 1; repo_scope_queries = 1; bytes = 1; returned = 50; has_next_cursor = $true; p95_ms = 1 }
    }
  }
  $cases = [ordered]@{
    "cold.isolated_bootstrap_ms" = { param($m) $m.cold.isolated_bootstrap_ms = $MaxColdMs + 1 }
    "exact.node.artifact_cache_miss_ms" = { param($m) $m.exact.node.artifact.cache_miss.process_ms = $MaxArtifactCacheMissMs + 1 }
    "exact.node.artifact_prepared_ms" = { param($m) $m.exact.node.artifact.prepared_cache.process_ms = $MaxArtifactPreparedMs + 1 }
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
    "exact.node.live_100" = { param($m) $m.exact.node.warm[2].startup_burst = 11 }
    "exact.node.private_bytes" = { param($m) $m.exact.node.warm[1].process_tree.median_private_bytes_per_client = $MaxExactWarmBytes + 1 }
    "exact.node.warm_resolution" = { param($m) $m.exact.node.warm[0].git_invocations = 1 }
    "exact.node.cold_resolution" = { param($m) $m.exact.node.cold.trace.artifact_manifest_resolution = 2 }
    "exact.node.lock_recovery" = { param($m) $m.exact.node.lock_recovery.reclaimed = $false }
    "exact.node.lifecycle_race" = { param($m) $m.exact.node.lifecycle_race.healthy = $false }
    "exact.node.recovery_integrity" = { param($m) $m.exact.node.mutation.shortcut_rejected = $false }
    "exact.fallback.functional" = { param($m) $m.exact.fallback.recovery.dashboard_healthy = $false }
    "state_hot_path.readiness_state" = { param($m) $m.state_hot_path.readiness_state.entry_growth = 1 }
    "state_hot_path.recovery_writes" = { param($m) $m.state_hot_path.operations.recovery_steady.write_statements = 1 }
    "state_hot_path.ready_guard" = { param($m) $m.state_hot_path.ready_guard.history_reads_after_lock = 1 }
    "state_hot_path.busy_retries" = { param($m) $m.state_hot_path.operations.worker_read.busy_retries = 1 }
    "response_list.read_plan_encoding" = { param($m) $m.response_list.read_plan.http.text_encodes.full = 1 }
    "response_list.read_plan_structured" = { param($m) $m.response_list.read_plan.http.structured_nodes = 999 }
    "response_list.read_plan_p50" = { param($m) $m.response_list.read_plan.http.p50_ms = 2 }
    "response_list.read_plan_reductions" = { param($m) $m.response_list.read_plan.http.reductions_p50 = 2 }
    "response_list.list_queries" = { param($m) $m.response_list.list_work_requests.repo_scope_queries = 2 }
    "response_list.list_bound" = { param($m) $m.response_list.list_work_requests.returned = 51 }
    "response_list.list_p95" = { param($m) $m.response_list.list_work_requests.p95_ms = $responseListCaps.list_p95_ms + 1 }
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
  [Console]::Error.WriteLine("Measuring shipped command with Node missing...")
  $exactFallback = Invoke-ExactCommandProbe "NodeMissing" "1,10"
  [Console]::Error.WriteLine("Measuring shipped command with Node present...")
  $exactNode = Invoke-ExactCommandProbe "NodePresent" "1,10,100" -CheckMutation
  [Console]::Error.WriteLine("Measuring MCP profiles and representative payloads...")
  $payloadOutput = Invoke-IsolatedMix @("run", "--no-start", $payloadProbe) $environment
  $payloadJson = @($payloadOutput -split "`r?`n" | Where-Object { $_.Trim().StartsWith("{") } | Select-Object -Last 1)
  if ($payloadJson.Count -ne 1) { throw "payload probe omitted JSON output" }
  $payloads = $payloadJson[0] | ConvertFrom-Json
  [Console]::Error.WriteLine("Measuring MCP state and SQLite hot paths...")
  $stateOutput = Invoke-IsolatedMix @("run", "--no-start", $stateProbe) $environment
  $stateJson = @($stateOutput -split "`r?`n" | Where-Object { $_.Trim().StartsWith("{") } | Select-Object -Last 1)
  if ($stateJson.Count -ne 1) { throw "state hot-path probe omitted JSON output" }
  $stateHotPath = $stateJson[0] | ConvertFrom-Json
  [Console]::Error.WriteLine("Measuring MCP response construction and WorkRequest list hot paths...")
  $responseListOutput = Invoke-IsolatedMix @("run", "--no-start", $responseListProbe) $environment
  $responseListJson = @($responseListOutput -split "`r?`n" | Where-Object { $_.Trim().StartsWith("{") } | Select-Object -Last 1)
  if ($responseListJson.Count -ne 1) { throw "response/list hot-path probe omitted JSON output" }
  $responseList = $responseListJson[0] | ConvertFrom-Json
  $revision = [string](& git -C $repoRoot rev-parse HEAD); $metrics = [pscustomobject]@{ revision = $revision.Trim(); cold = $cold; warm = $warm; direct = $direct; exact = [pscustomobject]@{ node = $exactNode; fallback = $exactFallback }; profiles = $payloads.profiles; results = $payloads.results; state_hot_path = $stateHotPath; response_list = $responseList }
} catch {
  $caught = $_
  $failure = @(
    [string]$caught.Exception.Message
    [string]$caught.ScriptStackTrace
    [string]$caught.InvocationInfo.PositionMessage
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  $failure = $failure -join [Environment]::NewLine
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_PERFORMANCE_PROGRESS_FILE)) {
    [System.IO.File]::AppendAllText(
      $env:SYMPP_PERFORMANCE_PROGRESS_FILE,
      "$([DateTime]::UtcNow.ToString('O')) Performance gate captured failure: $(($failure -replace '\r?\n', ' ').Trim())$([Environment]::NewLine)"
    )
  }
  $backendLog = @(Get-ChildItem (Join-Path $tempRoot "logs") -Filter "backend-*.err.log" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc | Select-Object -Last 1); if ($backendLog) { $rawDetail = Get-Content $backendLog.FullName -Raw; $detail = if ($null -eq $rawDetail) { "" } else { ([string]$rawDetail).Trim() }; if ($detail.Length -gt 2000) { $detail = $detail.Substring($detail.Length - 2000) }; $failure += "`nbackend stderr: $detail" }
} finally {
  try {
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
        $currentStartTime = $backend.StartTime
        if (-not $currentStartTime) { $backend = $null }
        elseif ($currentStartTime.ToUniversalTime().Ticks -ne $backendStartTicks -or [int]$runtime.backend.port -ne $backendPort) { $failure = "cleanup refused changed backend identity" }
        else { Stop-Process -Id $backend.Id -Force -ErrorAction SilentlyContinue }
      }
    }
    $ownedRoot = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if ([System.IO.Path]::GetFullPath($tempRoot).StartsWith($ownedRoot, [System.StringComparison]::OrdinalIgnoreCase)) { Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if ($backendPort) { $cleanup.backend_port_free = @(Get-ListenerPids $backendPort).Count -eq 0 }
    if ($dashboardPort) { $cleanup.dashboard_port_free = @(Get-ListenerPids $dashboardPort).Count -eq 0 }
    $cleanup.isolated_root_removed = -not (Test-Path $tempRoot)
  } catch {
    $cleanupCaught = $_
    $cleanupDetail = @(
      [string]$cleanupCaught.Exception.Message
      [string]$cleanupCaught.ScriptStackTrace
      [string]$cleanupCaught.InvocationInfo.PositionMessage
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $failure = (@($failure, "cleanup failure: $($cleanupDetail -join [Environment]::NewLine)") |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
  }
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_PERFORMANCE_PROGRESS_FILE)) {
    try {
      [System.IO.File]::AppendAllText(
        $env:SYMPP_PERFORMANCE_PROGRESS_FILE,
        "$([DateTime]::UtcNow.ToString('O')) Performance gate cleanup completed: backend_port_free=$($cleanup.backend_port_free) dashboard_port_free=$($cleanup.dashboard_port_free) cold_leases_after_close=$($cleanup.cold_leases_after_close) isolated_root_removed=$($cleanup.isolated_root_removed)$([Environment]::NewLine)"
      )
    } catch { }
  }
}

if ($failure) {
  try {
    [Console]::Out.WriteLine("status: error")
    [Console]::Out.WriteLine("error: $(Quote-Toon $failure)")
    [Console]::Out.WriteLine("cleanup:")
    foreach ($name in $cleanup.Keys) { $value = if ($name -eq "cold_leases_after_close") { $cleanup[$name] } else { ([bool]$cleanup[$name]).ToString().ToLowerInvariant() }; [Console]::Out.WriteLine("  ${name}: $value") }
    if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_PERFORMANCE_PROGRESS_FILE)) {
      [System.IO.File]::AppendAllText(
        $env:SYMPP_PERFORMANCE_PROGRESS_FILE,
        "$([DateTime]::UtcNow.ToString('O')) Performance gate rendered captured failure.$([Environment]::NewLine)"
      )
    }
  } catch {
    $renderCaught = $_
    $renderDetail = @(
      [string]$renderCaught.Exception.Message
      [string]$renderCaught.ScriptStackTrace
      [string]$renderCaught.InvocationInfo.PositionMessage
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_PERFORMANCE_PROGRESS_FILE)) {
      [System.IO.File]::AppendAllText(
        $env:SYMPP_PERFORMANCE_PROGRESS_FILE,
        "$([DateTime]::UtcNow.ToString('O')) Performance gate final render failed: $((($renderDetail -join ' | ') -replace '\r?\n', ' ').Trim())$([Environment]::NewLine)"
      )
    }
    throw
  }
  exit 1
}
$failures = Add-CleanupFailure @(Get-GateFailures $metrics $thresholds) $cleanup
Write-Result $metrics $failures $cleanup
exit $(if ($failures.Count -eq 0) { 0 } else { 1 })
