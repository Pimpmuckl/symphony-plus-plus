[CmdletBinding()]
param(
  [string]$Url,
  [int[]]$ClientCounts = @(1, 10, 100),
  [switch]$StaticOnly
)

$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../../.."))

function Fail([string]$Message, [int]$Code = 1) {
  [Console]::Out.WriteLine("error: $Message")
  [Console]::Out.WriteLine("help: pass -StaticOnly or -Url http://127.0.0.1:<isolated-port>/mcp")
  exit $Code
}

function Assert-StaticContract {
  $configPath = Join-Path $repoRoot "plugins/symphony-plus-plus-mcp/.mcp.json"
  $cutoverPath = Join-Path $repoRoot "scripts/sympp-mcp-cutover.ps1"
  $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  $server = $config.symphony_plus_plus

  if ($server.PSObject.Properties["url"]) {
    throw "plugin MCP config bypasses the cold-start launcher"
  }
  if ([string]$server.type -ne "stdio" -or [string]$server.command -ne "cmd.exe" -or [string]$server.cwd -ne ".") {
    throw "plugin MCP config is not command-backed stdio"
  }
  if ([double]$server.startup_timeout_sec -ne 360.0) {
    throw "plugin MCP startup timeout does not cover singleton cold start"
  }
  $args = @($server.args)
  if ($args -notcontains "/c" -or -not @($args | Where-Object { [string]$_ -match "scripts[\\/]start-sympp-mcp\.cmd" })) {
    throw "plugin MCP config does not invoke the bundled launcher"
  }

  $cutover = Get-Content -LiteralPath $cutoverPath -Raw
  foreach ($required in @("Assert-InstalledCommandMcpConfig", "Existing S++ Processes (Preserved)", "external_loopback")) {
    if (-not $cutover.Contains($required)) {
      throw "cutover is missing '$required'"
    }
  }
  if ($cutover.Contains("Stop-Process")) {
    throw "cutover must let active stdio sessions drain"
  }
}

function New-McpRequest([string]$Body, [string]$SessionId = $null) {
  $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Url)
  $request.Headers.Accept.ParseAdd("application/json")
  $request.Headers.Accept.ParseAdd("text/event-stream")
  if ($SessionId) {
    $request.Headers.TryAddWithoutValidation("Mcp-Session-Id", $SessionId) | Out-Null
  }
  $request.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, "application/json")
  return $request
}

function Wait-Responses([object[]]$Pending, [string]$Stage) {
  [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($Pending.task))
  $responses = @()
  foreach ($entry in $Pending) {
    $response = $entry.task.GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
      throw "$Stage returned HTTP $([int]$response.StatusCode)"
    }
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $payload = $body | ConvertFrom-Json
    if ($payload.error) {
      $errorJson = $payload.error | ConvertTo-Json -Depth 8 -Compress
      throw "$Stage returned JSON-RPC error: $errorJson"
    }
    $responses += [pscustomobject]@{ response = $response; payload = $payload; client = $entry.client }
  }
  return $responses
}

function Get-TransportChildren {
  $all = @(Get-CimInstance Win32_Process)
  $ids = [System.Collections.Generic.HashSet[int]]::new()
  [void]$ids.Add([int]$PID)
  do {
    $before = $ids.Count
    foreach ($process in $all) {
      if ($ids.Contains([int]$process.ParentProcessId)) {
        [void]$ids.Add([int]$process.ProcessId)
      }
    }
  } while ($ids.Count -gt $before)

  return @(
    foreach ($process in $all) {
      if ($process.ProcessId -ne $PID -and $ids.Contains([int]$process.ProcessId) -and
          $process.Name -in @("cmd.exe", "powershell.exe", "pwsh.exe")) {
        Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
      }
    }
  )
}

function Get-BackendIdentity([int]$Port) {
  $listeners = @(
    Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
      Where-Object { $_.LocalAddress -in @("127.0.0.1", "::1") }
  )
  $owners = @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
  if ($listeners.Count -ne 1 -or $owners.Count -ne 1) {
    throw "expected exactly one loopback listener owner on isolated port $Port; listeners=$($listeners.Count) owners=$($owners.Count)"
  }
  $process = Get-Process -Id $owners[0] -ErrorAction Stop
  return [pscustomobject]@{
    pid = [int]$process.Id
    start_ticks = [long]$process.StartTime.ToUniversalTime().Ticks
    private_bytes = [long]$process.PrivateMemorySize64
  }
}

function Measure-Cohort([int]$Count, $ExpectedBackend) {
  [GC]::Collect()
  $beforeBytes = (Get-Process -Id $PID).PrivateMemorySize64
  $clients = @()
  $initialize = @()
  for ($index = 0; $index -lt $Count; $index++) {
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $clients += $client
    $body = @{
      jsonrpc = "2.0"; id = "init-$index"; method = "initialize"
      params = @{ protocolVersion = "2025-03-26"; capabilities = @{}; clientInfo = @{ name = "sympp-transport-measure"; version = "1" } }
    } | ConvertTo-Json -Depth 8 -Compress
    $initialize += [pscustomobject]@{ client = $client; task = $client.SendAsync((New-McpRequest $body)) }
  }

  try {
    $initialized = Wait-Responses $initialize "initialize"
    $sessionIds = @(
      $initialized | ForEach-Object {
        @($_.response.Headers.GetValues("Mcp-Session-Id")) | Select-Object -First 1
      }
    )
    if ($sessionIds.Count -ne $Count -or @($sessionIds | Sort-Object -Unique).Count -ne $Count) {
      throw "initialize did not return one unique MCP session per client"
    }
    $listed = @()
    for ($index = 0; $index -lt $initialized.Count; $index++) {
      $sessionId = $sessionIds[$index]
      if ([string]::IsNullOrWhiteSpace($sessionId)) {
        throw "initialize omitted Mcp-Session-Id"
      }
      $body = @{ jsonrpc = "2.0"; id = "tools-$index"; method = "tools/list"; params = @{} } | ConvertTo-Json -Depth 4 -Compress
      $listed += [pscustomobject]@{ client = $clients[$index]; task = $clients[$index].SendAsync((New-McpRequest $body $sessionId)) }
    }
    $tools = Wait-Responses $listed "tools/list"
    if (@($tools | Where-Object { @($_.payload.result.tools).Count -eq 0 }).Count -gt 0) {
      throw "tools/list returned an empty tool surface"
    }

    $children = @(Get-TransportChildren)
    $backend = Get-BackendIdentity $uri.Port
    if ($backend.pid -ne $ExpectedBackend.pid -or $backend.start_ticks -ne $ExpectedBackend.start_ticks) {
      throw "backend listener identity changed during measurement"
    }
    $afterBytes = (Get-Process -Id $PID).PrivateMemorySize64
    return [pscustomobject]@{
      clients = $Count
      backend_processes = 1
      backend_pid = $backend.pid
      backend_start_ticks = $backend.start_ticks
      backend_private_bytes = $backend.private_bytes
      transport_processes = $children.Count
      transport_private_bytes = [long](($children | Measure-Object PrivateMemorySize64 -Sum).Sum)
      host_private_bytes_delta = [long]($afterBytes - $beforeBytes)
    }
  } finally {
    foreach ($client in $clients) { $client.Dispose() }
  }
}

try {
  Assert-StaticContract
  if ($StaticOnly) {
    [Console]::Out.WriteLine("status: ok")
    [Console]::Out.WriteLine("transport: direct_http")
    exit 0
  }
  if ([string]::IsNullOrWhiteSpace($Url)) { Fail "-Url is required for live measurement" 2 }
  $uri = [Uri]$Url
  if (-not $uri.IsLoopback -or $uri.AbsolutePath -ne "/mcp" -or $uri.Port -eq 19998) {
    Fail "live measurement requires a non-default loopback /mcp URL" 2
  }

  [Console]::Error.WriteLine("Measuring direct HTTP cohorts on isolated port $($uri.Port)...")
  $backend = Get-BackendIdentity $uri.Port
  $rows = @(
    $ClientCounts | ForEach-Object {
      [Console]::Error.WriteLine("  cohort: $_ clients")
      Measure-Cohort $_ $backend
    }
  )
  [Console]::Out.WriteLine("transport: direct_http")
  [Console]::Out.WriteLine("measurements[$($rows.Count)]{clients,backend_processes,backend_pid,backend_start_ticks,backend_private_bytes,transport_processes,transport_private_bytes,host_private_bytes_delta}:")
  foreach ($row in $rows) {
    [Console]::Out.WriteLine("  $($row.clients),$($row.backend_processes),$($row.backend_pid),$($row.backend_start_ticks),$($row.backend_private_bytes),$($row.transport_processes),$($row.transport_private_bytes),$($row.host_private_bytes_delta)")
  }
} catch {
  Fail $_.Exception.Message
}
