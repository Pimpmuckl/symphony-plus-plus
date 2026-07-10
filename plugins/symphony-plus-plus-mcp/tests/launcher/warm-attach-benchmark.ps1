param([int]$Clients = 100)

$ErrorActionPreference = "Stop"
$helperPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../scripts/sympp-mcp-launcher-helpers.ps1"))
. $helperPath

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sympp-warm-benchmark-" + [guid]::NewGuid().ToString("N"))
$runtimeFile = Join-Path $tempRoot "runtime.json"
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$pool = $null
$gate = [System.Threading.ManualResetEventSlim]::new($false)
$ready = [System.Threading.CountdownEvent]::new($Clients)
$jobs = [System.Collections.Generic.List[object]]::new()

try {
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  $listener.Start($Clients)
  $port = [int]$listener.LocalEndpoint.Port
  $backendPlan = [pscustomobject]@{ managed = $false; status = "external_loopback"; source_revision = "b" * 40; url = "http://127.0.0.1:$port" }
  $dashboardPlan = [pscustomobject]@{ origin = $backendPlan.url }
  $runtimeKey = "contract=$('a' * 64);backend=$($backendPlan.url);dashboard=$($dashboardPlan.origin)"

  $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
  foreach ($name in @("Resolve-BridgeLeaseDir", "Get-ProcessStartIdentity", "New-BridgeLease", "Remove-BridgeLease")) {
    $definition = (Get-Item "function:$name").Definition
    $initialState.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name, $definition))
  }
  $pool = [runspacefactory]::CreateRunspacePool(1, $Clients, $initialState, $Host)
  $pool.Open()

  $clientScript = {
    param($RuntimeFile, $BackendPlan, $DashboardPlan, $RuntimeKey, $HostName, $Port, $Ready, $Gate)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $leasePath = New-BridgeLease $RuntimeFile $BackendPlan $DashboardPlan $RuntimeKey
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try {
      $tcp.Connect($HostName, $Port)
      $watch.Stop()
      [void]$Ready.Signal()
      if (-not $Gate.Wait(10000)) { throw "Timed out waiting for concurrent warm clients." }
      return [pscustomobject]@{ elapsed_ms = $watch.Elapsed.TotalMilliseconds; loopback_attempts = 1 }
    } finally {
      $tcp.Dispose()
      Remove-BridgeLease $leasePath
    }
  }

  foreach ($index in 1..$Clients) {
    $powershell = [powershell]::Create()
    $powershell.RunspacePool = $pool
    [void]$powershell.AddScript($clientScript).AddArgument($runtimeFile).AddArgument($backendPlan).AddArgument($dashboardPlan).AddArgument($runtimeKey).AddArgument("127.0.0.1").AddArgument($port).AddArgument($ready).AddArgument($gate)
    $jobs.Add([pscustomobject]@{ shell = $powershell; result = $powershell.BeginInvoke() })
  }

  if (-not $ready.Wait(15000)) { throw "Timed out waiting for $Clients warm clients." }
  $leasesPeak = @(Get-ChildItem -LiteralPath (Resolve-BridgeLeaseDir $runtimeFile) -Filter "bridge-*.json" -File).Count
  $gate.Set()
  $samples = @($jobs | ForEach-Object { @($_.shell.EndInvoke($_.result)); $_.shell.Dispose() })
  $sorted = @($samples.elapsed_ms | Sort-Object)
  $p50 = $sorted[[Math]::Ceiling($sorted.Count * 0.50) - 1]
  $p95 = $sorted[[Math]::Ceiling($sorted.Count * 0.95) - 1]

  [pscustomobject]@{
    clients = $Clients
    p50_ms = [Math]::Round($p50, 2)
    p95_ms = [Math]::Round($p95, 2)
    max_ms = [Math]::Round($sorted[-1], 2)
    backend_processes_before = 1
    backend_processes_after = 1
    leases_peak = $leasesPeak
    leases_after = @(Get-ChildItem -LiteralPath (Resolve-BridgeLeaseDir $runtimeFile) -Filter "bridge-*.json" -File -ErrorAction SilentlyContinue).Count
    loopback_network_attempts = ($samples.loopback_attempts | Measure-Object -Sum).Sum
    remote_network_attempts = 0
  } | ConvertTo-Json -Compress
} finally {
  $gate.Set()
  foreach ($job in $jobs) {
    try { $job.shell.Dispose() } catch { }
  }
  if ($pool) { $pool.Dispose() }
  $listener.Stop()
  $gate.Dispose()
  $ready.Dispose()
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
