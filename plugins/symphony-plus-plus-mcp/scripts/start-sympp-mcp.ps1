param(
  [switch]$Help,
  [switch]$ValidateOnly,
  [switch]$PrepareRuntimeOnly,
  [switch]$CleanupPreparedRuntime,
  [string]$CleanupRuntimeKey
)

$ErrorActionPreference = "Stop"

$DefaultBackendPort = 0
$DefaultDashboardPort = 19999
$BoardPath = "/sympp/board"

. (Join-Path $PSScriptRoot "sympp-launcher-runtime.ps1")
. (Join-Path $PSScriptRoot "sympp-mcp-launcher-helpers.ps1")
Write-SymppLauncherTrace "powershell_entry"
. (Join-Path $PSScriptRoot "sympp-mcp-artifact-manifest.ps1")
. (Join-Path $PSScriptRoot "sympp-mcp-artifact-channel.ps1")
. (Join-Path $PSScriptRoot "sympp-mcp-artifact-runtime.ps1")
. (Join-Path $PSScriptRoot "sympp-mcp-process-runtime.ps1")

function Write-Usage {
  Write-Host "Starts the Symphony++ Codex plugin MCP bridge and local operator servers."
  Write-Host ""
  Write-Host "Default behavior:"
  Write-Host "  - Reuse a healthy Symphony++ runtime when its MCP contract fingerprint matches this launcher."
  Write-Host "  - Keep source revision mismatches visible in diagnostics while allowing compatible runtimes to attach."
  Write-Host "  - Start a fresh managed backend and dashboard for a new MCP contract, leaving old leased runtimes to drain."
  Write-Host "  - Bridge Codex stdio MCP traffic into the HTTP backend /mcp endpoint."
  Write-Host ""
  Write-Host "Environment:"
  Write-Host "  SYMPP_REPO_ROOT              Explicit developer-only Symphony++ source checkout override. Marketplace installs are discovered automatically."
  Write-Host "  SYMPP_DATABASE               Optional SQLite ledger override passed to mix sympp.cockpit and mix sympp.mcp direct fallback."
  Write-Host "  SYMPP_LAUNCHER               Optional launcher: 'direct' or 'mise'. Defaults to 'mise' when elixir/mise.toml can run through mise; otherwise 'direct'."
  Write-Host "  SYMPP_MIX                    Optional mix executable path or name for direct launcher. Defaults to 'mix'."
  Write-Host "  SYMPP_MISE                   Optional mise executable path or name for mise launcher. Defaults to 'mise'."
  Write-Host "  MIX_BUILD_ROOT               Optional Mix build-root override. Defaults under %USERPROFILE%\.agents\splusplus\build\mcp for plugin launcher runs."
  Write-Host "  SYMPP_BACKEND_PORT           Preferred backend/API port. Defaults to any available port."
  Write-Host "  SYMPP_BACKEND_URL            Reuse an already-running backend URL instead of starting mix sympp.cockpit."
  Write-Host "  SYMPP_DASHBOARD_PORT         Preferred dashboard port. Defaults to $DefaultDashboardPort. Use 0 for any available port."
  Write-Host "  SYMPP_DASHBOARD_ORIGIN       Reuse an external dashboard origin instead of starting Vite."
  Write-Host "  SYMPP_AUTOSTART_SERVERS      Set to 0/false/off to skip backend and frontend autostart."
  Write-Host "  SYMPP_AUTOSTART_BACKEND      Set to 0/false/off to skip backend autostart."
  Write-Host "  SYMPP_AUTOSTART_FRONTEND     Set to 0/false/off to skip frontend autostart."
  Write-Host "  SYMPP_MCP_BRIDGE_MODE        'http' (default) bridges stdio to HTTP; 'direct_stdio' runs mix sympp.mcp directly."
  Write-Host "  SYMPP_ARTIFACT_RUNTIME       Set to 1/true/yes/on to prefer runtime artifacts from a source checkout."
  Write-Host "  SYMPP_RUNTIME_FILE           Optional runtime JSON output path. Defaults under %USERPROFILE%\.agents\splusplus\runtime."
  Write-Host "  SYMPP_LOG_DIR                Optional background server log directory. Defaults under %USERPROFILE%\.agents\splusplus\logs."
  Write-Host "  SYMPP_BACKEND_STARTUP_TIMEOUT_SEC    Backend startup wait. Defaults to 60."
  Write-Host "  SYMPP_BACKEND_PORT_RELEASE_TIMEOUT_SEC  Preferred backend port stale-listener wait. Defaults to 15."
  Write-Host "  SYMPP_ELIXIR_SETUP_TIMEOUT_SEC   Per-command Elixir setup wait. Defaults to 300."
  Write-Host "  SYMPP_FRONTEND_INSTALL_TIMEOUT_SEC   Dashboard npm install wait when dependencies are missing. Defaults to 180."
  Write-Host "  SYMPP_FRONTEND_STARTUP_TIMEOUT_SEC   Frontend startup wait. Defaults to 20."
  Write-Host "  SYMPP_MCP_HTTP_TIMEOUT_SEC           Per-request bridge timeout. Defaults to 300."
  Write-Host "  SYMPP_STARTUP_LOCK_TIMEOUT_SEC       Local startup lock wait. Defaults to the configured startup waits plus 30 seconds, with a 120-second floor."
  Write-Host "  SYMPP_MCP_CLIENT_HEARTBEAT_SEC       Bridge client lease heartbeat interval. Defaults to 300; max 540."
  Write-Host ""
  Write-Host "Installed plugins resolve through the Codex marketplace snapshot. .sympp-source-root hints are ignored."
}

function Write-Diagnostic([string]$Message) {
  [Console]::Error.WriteLine($Message)
}

function Test-SymppBackendCommandLine([string]$CommandLine) {
  if ([string]::IsNullOrWhiteSpace($CommandLine)) {
    return $false
  }

  if ($CommandLine -match "(?i)\bsympp\.cockpit\b") {
    return $true
  }

  return $CommandLine -match "(?i)(^|[\\/])artifacts[\\/]mcp[\\/]" -and
    $CommandLine -match "(?i)(start-runtime\.ps1|start-runtime\.(cmd|bat)|symphony_elixir(\.bat)?|[\\/]erts-[^\\/]+[\\/]bin[\\/]erl(\.exe)?)"
}

function Test-ManagedRuntimeCommandLine([string]$Role, [string]$CommandLine) {
  if ($Role -eq "backend") {
    return Test-SymppBackendCommandLine $CommandLine
  }

  return -not [string]::IsNullOrWhiteSpace($CommandLine) -and $CommandLine -match "(?i)\bvite\b"
}

function Test-ManagedRuntimePortCommandLine([string]$Role, [string]$CommandLine, [int]$Port) {
  if ($Port -le 0) {
    return $true
  }

  $portPattern = if ($Role -eq "backend") {
    "(?i)(--port|-Port)\s+`"?$Port`"?(?=\s|$)"
  } else {
    "(?i)--port\s+`"?$Port`"?(?=\s|$)"
  }
  return -not [string]::IsNullOrWhiteSpace($CommandLine) -and $CommandLine -match $portPattern
}

function Test-ProcessOwnsTcpPort([int]$ProcessId, [int]$Port) {
  if ($ProcessId -le 0 -or $Port -le 0) {
    return $false
  }

  foreach ($owner in @(Get-TcpPortOwners $Port)) {
    $ownerPid = 0
    if ([int]::TryParse([string]$owner.pid, [ref]$ownerPid) -and $ownerPid -eq $ProcessId) {
      return $true
    }
  }

  return $false
}

function Test-SymppBackendOwners([object[]]$Owners) {
  foreach ($owner in @($Owners)) {
    $processId = 0
    if ($null -ne $owner) {
      [void][int]::TryParse([string]$owner.pid, [ref]$processId)
    }
    if ($processId -gt 0 -and (Test-SymppBackendCommandLine (Get-ProcessCommandLine $processId))) {
      return $true
    }
  }

  return $false
}

function New-BackendBusySymppMessage([int]$Port, [object[]]$Owners, $Health) {
  $detail = if ($null -ne $Health -and -not [string]::IsNullOrWhiteSpace([string]$Health.detail)) { [string]$Health.detail } else { "unhealthy" }
  return "backend_port_busy_sympp_unhealthy: configured Symphony++ backend port http://127.0.0.1:$Port is occupied by $(Format-PortOwners $Owners), but MCP health did not complete (detail=$detail). Refusing to start a fallback runtime; retry after the singleton finishes startup or stop the stale owner."
}

function Wait-ForTcpPortRelease([int]$Port, [int]$TimeoutSec) {
  if ($Port -eq 0 -or (Test-PortAvailable $Port)) {
    return [pscustomobject]@{
      released = $true
      owners = @()
    }
  }

  $owners = @(Get-TcpPortOwners $Port)
  if ($TimeoutSec -gt 0) {
    Write-Diagnostic "Configured Symphony++ backend port 127.0.0.1:$Port is occupied by $(Format-PortOwners $owners); waiting up to $TimeoutSec seconds for stale listeners to clear."
  }

  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-PortAvailable $Port) {
      return [pscustomobject]@{
        released = $true
        owners = @()
      }
    }

    $owners = @(Get-TcpPortOwners $Port)
  }

  return [pscustomobject]@{
    released = $false
    owners = $owners
  }
}

function Get-FreeTcpPort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), 0)
  try {
    $listener.Start()
    return [int]$listener.LocalEndpoint.Port
  } finally {
    $listener.Stop()
  }
}

function Select-AvailablePort([int]$PreferredPort, [int[]]$Avoid = @()) {
  $avoidSet = [System.Collections.Generic.HashSet[int]]::new()
  foreach ($port in @($Avoid)) {
    if ($port -gt 0) {
      [void]$avoidSet.Add($port)
    }
  }

  if ($PreferredPort -eq 0) {
    do {
      $port = Get-FreeTcpPort
    } while ($avoidSet.Contains($port))
    return $port
  }

  if (-not $avoidSet.Contains($PreferredPort) -and (Test-PortAvailable $PreferredPort)) {
    return $PreferredPort
  }

  for ($offset = 1; $offset -le 200; $offset++) {
    $candidate = $PreferredPort + $offset
    if ($candidate -gt 65535) {
      break
    }
    if (-not $avoidSet.Contains($candidate) -and (Test-PortAvailable $candidate)) {
      return $candidate
    }
  }

  do {
    $fallback = Get-FreeTcpPort
  } while ($avoidSet.Contains($fallback))
  return $fallback
}

function ConvertTo-JsonBody($Payload) {
  return $Payload | ConvertTo-Json -Depth 16 -Compress
}

function Get-ResponseHeaderValue($Headers, [string]$Name) {
  if ($null -eq $Headers) {
    return $null
  }

  $rawValue = $null
  if ($Headers -is [System.Net.WebHeaderCollection]) {
    $rawValue = $Headers[$Name]
  } elseif ($Headers -is [System.Collections.IDictionary]) {
    foreach ($key in $Headers.Keys) {
      if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rawValue = $Headers[$key]
        break
      }
    }
  } else {
    $property = $Headers.PSObject.Properties |
      Where-Object { [string]::Equals($_.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase) } |
      Select-Object -First 1
    if ($property) {
      $rawValue = $property.Value
    }
  }

  foreach ($value in @($rawValue)) {
    if ($null -eq $value) {
      continue
    }

    foreach ($entry in @($value)) {
      foreach ($part in ([string]$entry).Split(",")) {
        $text = $part.Trim()
        if (-not [string]::IsNullOrWhiteSpace($text)) {
          return $text
        }
      }
    }
  }

  return $null
}

function Read-ErrorResponseBody($Response) {
  if ($null -eq $Response) {
    return $null
  }

  try {
    if ($Response.PSObject.Methods["GetResponseStream"]) {
      $stream = $Response.GetResponseStream()
      if ($null -eq $stream) {
        return $null
      }

      $reader = [System.IO.StreamReader]::new($stream)
      try {
        return $reader.ReadToEnd()
      } finally {
        $reader.Dispose()
      }
    }

    if ($Response.PSObject.Properties["Content"] -and $Response.Content) {
      return $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
  } catch {
    return $null
  }

  return $null
}

function New-InitializeRequest {
  return @{
    jsonrpc = "2.0"
    id = "sympp-plugin-launcher-init"
    method = "initialize"
    params = @{
      protocolVersion = "2025-03-26"
      clientInfo = @{
        name = "sympp-plugin-launcher"
        version = "0.1.0"
      }
      capabilities = @{}
    }
  }
}

function New-HealthRequest {
  return @{
    jsonrpc = "2.0"
    id = "sympp-plugin-launcher-health"
    method = "tools/call"
    params = @{
      name = "sympp.health"
      arguments = @{}
    }
  }
}

function New-SymppBackendHealth([bool]$Healthy, [string]$SourceRevision, [string]$Detail, [bool]$TcpOpen, [bool]$McpReady = $false, [bool]$LedgerReachable = $false, [string]$Status = $null, [string]$ContractFingerprint = $null) {
  return [pscustomobject]@{
    healthy = $Healthy
    source_revision = $SourceRevision
    contract_fingerprint = $ContractFingerprint
    detail = $Detail
    tcp_open = $TcpOpen
    mcp_ready = $McpReady
    ledger_reachable = $LedgerReachable
    status = $Status
  }
}

function Test-LoopbackHttpTcpOpen([string]$Origin) {
  if ([string]::IsNullOrWhiteSpace($Origin)) {
    return $false
  }

  $client = $null
  try {
    $uri = [System.Uri]::new($Origin.TrimEnd("/"))
    if ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https") {
      return $false
    }
    if (@("127.0.0.1", "localhost", "::1") -notcontains $uri.Host) {
      return $false
    }

    $port = [int]$uri.Port
    if ($port -le 0) {
      $port = if ($uri.Scheme -eq "https") { 443 } else { 80 }
    }

    $client = [System.Net.Sockets.TcpClient]::new()
    $connect = $client.BeginConnect($uri.Host, $port, $null, $null)
    if (-not $connect.AsyncWaitHandle.WaitOne(300)) {
      return $false
    }
    $client.EndConnect($connect)
    return $true
  } catch {
    return $false
  } finally {
    if ($client) {
      $client.Close()
    }
  }
}

function Get-HeaderValue($Headers, [string]$Name) {
  return Get-ResponseHeaderValue $Headers $Name
}

function Convert-SseContentToJsonLines([string]$Content) {
  $messages = [System.Collections.Generic.List[string]]::new()
  $dataLines = [System.Collections.Generic.List[string]]::new()

  foreach ($rawLine in ($Content -split "`r?`n")) {
    $line = $rawLine.TrimEnd("`r")
    if ([string]::IsNullOrWhiteSpace($line)) {
      if ($dataLines.Count -gt 0) {
        $message = ($dataLines -join "`n").Trim()
        if (-not [string]::IsNullOrWhiteSpace($message) -and $message -ne "[DONE]") {
          $messages.Add($message)
        }
        $dataLines.Clear()
      }
      continue
    }

    if ($line.StartsWith("data:", [System.StringComparison]::OrdinalIgnoreCase)) {
      $dataLines.Add($line.Substring(5).TrimStart())
    }
  }

  if ($dataLines.Count -gt 0) {
    $message = ($dataLines -join "`n").Trim()
    if (-not [string]::IsNullOrWhiteSpace($message) -and $message -ne "[DONE]") {
      $messages.Add($message)
    }
  }

  return @($messages)
}

function Convert-McpHttpContentToJsonLines([string]$Content, $Headers) {
  if ([string]::IsNullOrWhiteSpace($Content)) {
    return @()
  }

  $contentType = Get-HeaderValue $Headers "Content-Type"
  if ($contentType -and $contentType.ToLowerInvariant().Contains("text/event-stream")) {
    return @(Convert-SseContentToJsonLines $Content)
  }

  return @($Content.Trim())
}

function Get-InitializeProtocolVersion([string]$Body) {
  try {
    $payload = $Body | ConvertFrom-Json
    if ($payload.method -eq "initialize" -and $payload.params.protocolVersion) {
      return [string]$payload.params.protocolVersion
    }
  } catch {
  }

  return $null
}

function Get-ResponseProtocolVersion([string[]]$ContentLines) {
  foreach ($contentLine in @($ContentLines)) {
    if ([string]::IsNullOrWhiteSpace($contentLine)) {
      continue
    }

    try {
      $payload = $contentLine | ConvertFrom-Json
      if ($payload.result.protocolVersion) {
        return [string]$payload.result.protocolVersion
      }
    } catch {
    }
  }

  return $null
}

function Get-HealthSourceRevision($Payload) {
  if ($null -eq $Payload) {
    return $null
  }

  $content = if ($Payload.PSObject.Properties["source"]) { $Payload } elseif ($Payload.PSObject.Properties["result"]) { $Payload.result.structuredContent } else { $null }
  if ($null -eq $content -or -not $content.PSObject.Properties["source"]) {
    return $null
  }

  $source = $content.source
  if ($null -eq $source -or -not $source.PSObject.Properties["revision"]) {
    return $null
  }

  return Normalize-SymppSourceRevision ([string]$source.revision)
}

function Normalize-McpContractFingerprint([string]$Fingerprint) {
  if ([string]::IsNullOrWhiteSpace($Fingerprint)) {
    return $null
  }

  $fingerprint = $Fingerprint.Trim().ToLowerInvariant()
  if ($fingerprint -match "^[0-9a-f]{64}$") {
    return $fingerprint
  }

  return $null
}

function Get-McpContractFingerprintFromContractFile([string]$ContractPath) {
  if ([string]::IsNullOrWhiteSpace($ContractPath) -or -not (Test-Path -LiteralPath $ContractPath -PathType Leaf)) {
    return $null
  }

  try {
    $contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
    return Normalize-McpContractFingerprint ([string]$contract.mcp_contract_fingerprint)
  } catch {
    return $null
  }
}

function Get-McpContractFingerprintFromArtifactManifest($Manifest) {
  if ($null -eq $Manifest) {
    return $null
  }

  return Normalize-McpContractFingerprint ([string](Get-JsonFirstPathValue $Manifest @(
        @("mcp_contract_fingerprint"),
        @("launcher_contract", "mcp_contract_fingerprint"),
        @("contract_fingerprint"),
        @("launcher_contract", "contract_fingerprint")
      )))
}

function Get-McpContractFingerprintFromMarketplaceSource([string]$PluginRoot) {
  $marketplaceRoot = Resolve-RepoRootFromMarketplaceCache $PluginRoot
  if (-not $marketplaceRoot) {
    return $null
  }

  return Get-McpContractFingerprintFromContractFile (Join-Path $marketplaceRoot "elixir/priv/symphony_plus_plus/mcp_contract.json")
}

function Resolve-LocalMcpContractFingerprint([string]$PluginRoot) {
  Write-SymppLauncherTrace "contract_fingerprint_resolution"
  $sourceRoot = [System.IO.Path]::GetFullPath((Join-Path $PluginRoot "../.."))
  if (Test-SymphonySourceRoot $sourceRoot) {
    $fingerprint = Get-McpContractFingerprintFromContractFile (Join-Path $sourceRoot "elixir/priv/symphony_plus_plus/mcp_contract.json")
    if ($fingerprint) { return $fingerprint }
  }

  return Get-McpContractFingerprintFromMarketplaceSource $PluginRoot
}

function Resolve-ExpectedMcpContractFingerprint([string]$PluginRoot) {
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_REPO_ROOT)) {
    $explicitRepoRoot = [System.IO.Path]::GetFullPath($env:SYMPP_REPO_ROOT)
    if (-not (Test-SymphonySourceRoot $explicitRepoRoot)) {
      throw "SYMPP_REPO_ROOT does not look like a Symphony++ checkout: $explicitRepoRoot"
    }

    $contractPath = Join-Path $explicitRepoRoot "elixir/priv/symphony_plus_plus/mcp_contract.json"
    $fingerprint = Get-McpContractFingerprintFromContractFile $contractPath
    if ($fingerprint) {
      return $fingerprint
    }

    throw "Symphony++ MCP launcher expected MCP contract fingerprint could not be resolved from explicit SYMPP_REPO_ROOT contract JSON: $contractPath"
  }

  $fingerprint = Resolve-LocalMcpContractFingerprint $PluginRoot
  if ($fingerprint) {
    return $fingerprint
  }

  $artifactManifest = $null
  try {
    $artifactManifest = Read-SymppArtifactManifest $PluginRoot
  } catch {
    $artifactManifest = $null
  }

  $fingerprint = Get-McpContractFingerprintFromArtifactManifest $artifactManifest
  if ($fingerprint) {
    return $fingerprint
  }

  if ($null -ne $artifactManifest) {
    return "0000000000000000000000000000000000000000000000000000000000000000"
  }

  return $null
}

function Get-HealthContractFingerprint($Payload) {
  if ($null -eq $Payload) {
    return $null
  }

  $content = if ($Payload.PSObject.Properties["source"]) { $Payload } elseif ($Payload.PSObject.Properties["result"]) { $Payload.result.structuredContent } else { $null }
  if ($null -eq $content -or -not $content.PSObject.Properties["source"]) {
    return $null
  }

  $source = $content.source
  if ($null -ne $source -and
      $source.PSObject.Properties["mcp_contract"] -and
      $null -ne $source.mcp_contract -and
      $source.mcp_contract.PSObject.Properties["fingerprint"]) {
    return Normalize-McpContractFingerprint ([string]$source.mcp_contract.fingerprint)
  }

  return $null
}

function Convert-HttpClientHeaders($Response) {
  $headers = @{}
  if ($null -eq $Response) {
    return $headers
  }

  foreach ($header in @($Response.Headers)) {
    $headers[[string]$header.Key] = @($header.Value)
  }
  if ($null -ne $Response.Content) {
    foreach ($header in @($Response.Content.Headers)) {
      $headers[[string]$header.Key] = @($header.Value)
    }
  }

  return $headers
}

function Test-McpRequestProvablyUnsent($Exception) {
  while ($null -ne $Exception) {
    if ($Exception -is [System.Net.Sockets.SocketException] -and
        $Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionRefused) { return $true }
    $Exception = $Exception.InnerException
  }
  return $false
}

function Wait-McpTaskWithLeaseHeartbeat($Task, [string]$McpUrl, [string]$LeaseClientId, [int]$HeartbeatIntervalMs) {
  $waitMs = [Math]::Max(1000, $HeartbeatIntervalMs)
  while (-not $Task.Wait($waitMs)) {
    Invoke-McpClientLease $McpUrl $LeaseClientId "heartbeat" | Out-Null
  }

  return $Task.GetAwaiter().GetResult()
}

function Invoke-McpPostWithLeaseHeartbeat([string]$Url, [string]$Body, [string]$SessionId, [string]$ProtocolVersion, [int]$TimeoutSec, [string]$LeaseClientId, [int]$LeaseHeartbeatIntervalMs) {
  Add-Type -AssemblyName System.Net.Http
  $client = [System.Net.Http.HttpClient]::new()
  $request = $null
  $response = $null
  try {
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Url)
    [void]$request.Headers.TryAddWithoutValidation("Accept", "application/json, text/event-stream")
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
      [void]$request.Headers.TryAddWithoutValidation("Mcp-Session-Id", $SessionId)
    }
    if (-not [string]::IsNullOrWhiteSpace($ProtocolVersion)) {
      [void]$request.Headers.TryAddWithoutValidation("MCP-Protocol-Version", $ProtocolVersion)
    }
    $request.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, "application/json")

    $response = Wait-McpTaskWithLeaseHeartbeat ($client.SendAsync($request)) $Url $LeaseClientId $LeaseHeartbeatIntervalMs
    $content = Wait-McpTaskWithLeaseHeartbeat ($response.Content.ReadAsStringAsync()) $Url $LeaseClientId $LeaseHeartbeatIntervalMs
    $headers = Convert-HttpClientHeaders $response
    $ok = $response.IsSuccessStatusCode

    return [pscustomobject]@{
      ok = $ok
      statusCode = [int]$response.StatusCode
      headers = $headers
      content = [string]$content
      content_lines = if ($ok) { @(Convert-McpHttpContentToJsonLines ([string]$content) $headers) } else { @() }
      error = if ($ok) { $null } else { $response.ReasonPhrase }
      may_have_reached_backend = $true
    }
  } catch {
    return [pscustomobject]@{
      ok = $false
      statusCode = $null
      headers = $null
      content = $null
      content_lines = @()
      error = $_.Exception.Message
      may_have_reached_backend = -not (Test-McpRequestProvablyUnsent $_.Exception)
    }
  } finally {
    if ($null -ne $response) {
      $response.Dispose()
    }
    if ($null -ne $request) {
      $request.Dispose()
    }
    $client.Dispose()
  }
}

function Invoke-McpPost([string]$Url, [string]$Body, [string]$SessionId, [string]$ProtocolVersion, [int]$TimeoutSec, [string]$LeaseClientId = $null, [int]$LeaseHeartbeatIntervalMs = 0) {
  if (-not [string]::IsNullOrWhiteSpace($LeaseClientId) -and $LeaseHeartbeatIntervalMs -gt 0) {
    return Invoke-McpPostWithLeaseHeartbeat $Url $Body $SessionId $ProtocolVersion $TimeoutSec $LeaseClientId $LeaseHeartbeatIntervalMs
  }

  $headers = @{ Accept = "application/json, text/event-stream" }
  if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
    $headers["Mcp-Session-Id"] = $SessionId
  }
  if (-not [string]::IsNullOrWhiteSpace($ProtocolVersion)) {
    $headers["MCP-Protocol-Version"] = $ProtocolVersion
  }

  try {
    $response = Invoke-WebRequest `
      -Uri $Url `
      -Method Post `
      -Headers $headers `
      -ContentType "application/json" `
      -Body $Body `
      -TimeoutSec $TimeoutSec `
      -UseBasicParsing `
      -ErrorAction Stop

    return [pscustomobject]@{
      ok = $true
      statusCode = [int]$response.StatusCode
      headers = $response.Headers
      content = [string]$response.Content
      content_lines = @(Convert-McpHttpContentToJsonLines ([string]$response.Content) $response.Headers)
      error = $null
      may_have_reached_backend = $true
    }
  } catch {
    $response = $_.Exception.Response
    $statusCode = $null
    if ($null -ne $response) {
      try {
        $statusCode = [int]$response.StatusCode
      } catch {
        $statusCode = $null
      }
    }

    return [pscustomobject]@{
      ok = $false
      statusCode = $statusCode
      headers = if ($null -ne $response) { $response.Headers } else { $null }
      content = Read-ErrorResponseBody $response
      content_lines = @()
      error = $_.Exception.Message
      may_have_reached_backend = -not (Test-McpRequestProvablyUnsent $_.Exception)
    }
  }
}

function Get-SymppBackendHealth([string]$BackendUrl, [bool]$RequireDashboardReady = $false) {
  if ([string]::IsNullOrWhiteSpace($BackendUrl)) {
    return New-SymppBackendHealth $false $null "missing_url" $false
  }

  $tcpOpen = $false
  try {
    $uri = [System.Uri]::new($BackendUrl)
    if ($uri.IsLoopback -and [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners().Port -notcontains $uri.Port) {
      return New-SymppBackendHealth $false $null "readiness_failed" $false
    }
    $tcpOpen = Test-LoopbackHttpTcpOpen $BackendUrl
    $readinessUrl = $BackendUrl.TrimEnd("/") + "/mcp/readiness"
    $response = Invoke-WebRequest -Uri $readinessUrl -Method Get -Headers @{ Accept = "application/json" } -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
    $payload = [string]$response.Content | ConvertFrom-Json
    $status = if ($payload.PSObject.Properties["status"]) { [string]$payload.status } else { $null }
    $ledgerReachable = $null -ne $payload.ledger -and $payload.ledger.PSObject.Properties["reachable"] -and $payload.ledger.reachable -eq $true
    $dashboardReady = $null -ne $payload.dashboard -and $payload.dashboard.PSObject.Properties["ready"] -and $payload.dashboard.ready -eq $true
    $healthy = [System.StringComparer]::OrdinalIgnoreCase.Equals($status, "ok") -and $ledgerReachable -and (-not $RequireDashboardReady -or $dashboardReady)
    $detail = if ($healthy) { $null } else { "health_degraded" }
    return New-SymppBackendHealth $healthy (Get-HealthSourceRevision $payload) $detail $true $true $ledgerReachable $status (Get-HealthContractFingerprint $payload)
  } catch {
    if ($null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
      return Get-LegacySymppBackendHealth $BackendUrl $tcpOpen
    }
    return New-SymppBackendHealth $false $null "readiness_failed" $tcpOpen
  }
}

function Get-LegacySymppBackendHealth([string]$BackendUrl, [bool]$TcpOpen) {
  $mcpUrl = $BackendUrl.TrimEnd("/") + "/mcp"
  $initializeBody = ConvertTo-JsonBody (New-InitializeRequest)
  $init = Invoke-McpPost $mcpUrl $initializeBody $null $null 2
  if (-not $init.ok -or [string]::IsNullOrWhiteSpace($init.content)) {
    return New-SymppBackendHealth $false $null "initialize_failed" $TcpOpen
  }

  $sessionId = Get-ResponseHeaderValue $init.headers "Mcp-Session-Id"
  if ([string]::IsNullOrWhiteSpace($sessionId)) {
    return New-SymppBackendHealth $false $null "missing_session_id" $TcpOpen
  }

  $protocolVersion = Get-ResponseProtocolVersion @($init.content_lines)
  if ([string]::IsNullOrWhiteSpace($protocolVersion)) {
    $protocolVersion = Get-InitializeProtocolVersion $initializeBody
  }

  $health = Invoke-McpPost $mcpUrl (ConvertTo-JsonBody (New-HealthRequest)) $sessionId $protocolVersion 2
  $healthLines = @($health.content_lines)
  if (-not $health.ok -or $healthLines.Count -eq 0) {
    return New-SymppBackendHealth $false $null "health_failed" $TcpOpen
  }

  try {
    $payload = $healthLines[0] | ConvertFrom-Json
    if ($null -eq $payload.result -or $null -ne $payload.error) {
      return New-SymppBackendHealth $false $null "health_error" $TcpOpen $true $false $null
    }

    $structuredContent = $payload.result.structuredContent
    $status = if ($null -ne $structuredContent -and $structuredContent.PSObject.Properties["status"]) { [string]$structuredContent.status } else { $null }
    $ledgerReachable = $null -ne $structuredContent -and $null -ne $structuredContent.ledger -and $structuredContent.ledger.PSObject.Properties["reachable"] -and $structuredContent.ledger.reachable -eq $true
    $healthy = [System.StringComparer]::OrdinalIgnoreCase.Equals($status, "ok") -and $ledgerReachable
    $detail = if ($healthy) { $null } else { "health_degraded" }
    return New-SymppBackendHealth $healthy (Get-HealthSourceRevision $payload) $detail $true $true $ledgerReachable $status (Get-HealthContractFingerprint $payload)
  } catch {
    return New-SymppBackendHealth $false $null "health_parse_failed" $TcpOpen
  }
}

function Get-SymppBackendHealthWithRetry([string]$BackendUrl, [int]$Attempts = 4, [int]$DelayMs = 500, [bool]$RequireDashboardReady = $false) {
  $last = $null
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    $last = Get-SymppBackendHealth $BackendUrl $RequireDashboardReady
    if ($last.healthy -or -not $last.tcp_open) {
      return $last
    }
    if ($attempt -lt $Attempts) {
      Start-Sleep -Milliseconds $DelayMs
    }
  }

  return $last
}

function Test-HealthySymppBackend([string]$BackendUrl) {
  return (Get-SymppBackendHealthWithRetry $BackendUrl).healthy
}

function Test-BackendContractMatches($Health, [string]$ExpectedContractFingerprint) {
  if ($null -eq $Health -or -not $Health.healthy) {
    return $false
  }

  $expected = Normalize-McpContractFingerprint $ExpectedContractFingerprint
  if ([string]::IsNullOrWhiteSpace($expected)) {
    return $false
  }

  $actual = $null
  if ($Health.PSObject.Properties["contract_fingerprint"]) {
    $actual = Normalize-McpContractFingerprint ([string]$Health.contract_fingerprint)
  }

  return -not [string]::IsNullOrWhiteSpace($actual) -and
    [System.StringComparer]::OrdinalIgnoreCase.Equals($actual, $expected)
}

function Test-BackendSourceRevisionEquals($Health, [string]$ExpectedSourceRevision) {
  if ($null -eq $Health -or [string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) {
    return $false
  }

  return Test-SourceRevisionEquals ([string]$Health.source_revision) $ExpectedSourceRevision
}

function Test-SourceRevisionEquals([string]$ActualSourceRevision, [string]$ExpectedSourceRevision) {
  return -not [string]::IsNullOrWhiteSpace($ActualSourceRevision) -and
    -not [string]::IsNullOrWhiteSpace($ExpectedSourceRevision) -and
    [System.StringComparer]::OrdinalIgnoreCase.Equals($ActualSourceRevision, $ExpectedSourceRevision)
}

function Test-BackendLaunchCompatible($Health, [string]$ExpectedContractFingerprint) {
  return Test-BackendContractMatches $Health $ExpectedContractFingerprint
}

function Format-BackendLaunchCompatibilityMismatch($Health, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint) {
  return "MCP contract fingerprint $(Format-McpContractFingerprintForDiagnostic $Health.contract_fingerprint) does not match expected $(Format-McpContractFingerprintForDiagnostic $ExpectedContractFingerprint). Source revision was $(Format-SourceRevisionForDiagnostic $Health.source_revision), expected $(Format-SourceRevisionForDiagnostic $ExpectedSourceRevision)."
}

function New-RuntimeKey([string]$BackendUrl, [string]$DashboardOrigin, [string]$ContractFingerprint) {
  $backend = if ([string]::IsNullOrWhiteSpace($BackendUrl)) { "none" } else { $BackendUrl.TrimEnd("/").ToLowerInvariant() }
  $dashboard = if ([string]::IsNullOrWhiteSpace($DashboardOrigin)) { "none" } else { $DashboardOrigin.TrimEnd("/").ToLowerInvariant() }
  $contract = if ([string]::IsNullOrWhiteSpace($ContractFingerprint)) { "unknown" } else { $ContractFingerprint.Trim().ToLowerInvariant() }
  return "contract=$contract;backend=$backend;dashboard=$dashboard"
}

function Get-RuntimeStateKey($State) {
  if ($null -eq $State) {
    return $null
  }

  if ($State.PSObject.Properties["runtime_key"] -and -not [string]::IsNullOrWhiteSpace([string]$State.runtime_key)) {
    return [string]$State.runtime_key
  }

  $contractFingerprint = $null
  if ($null -ne $State.backend -and $State.backend.PSObject.Properties["contract_fingerprint"]) {
    $contractFingerprint = [string]$State.backend.contract_fingerprint
  }

  if ($null -eq $State.backend) {
    return $null
  }

  return New-RuntimeKey ([string]$State.backend.url) ([string]$State.frontend.origin) $contractFingerprint
}

function Format-SourceRevisionForDiagnostic([string]$Revision) {
  if ([string]::IsNullOrWhiteSpace($Revision)) {
    return "unknown"
  }

  return $Revision
}

function Format-McpContractFingerprintForDiagnostic([string]$Fingerprint) {
  $fingerprint = Normalize-McpContractFingerprint $Fingerprint
  if ([string]::IsNullOrWhiteSpace($fingerprint)) {
    return "unknown"
  }

  return $fingerprint
}

function Write-CompatibleSourceMismatchDiagnostic([string]$Url, $Health, [string]$ExpectedSourceRevision) {
  if ($null -eq $Health -or [string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) {
    return
  }

  if ([string]::IsNullOrWhiteSpace([string]$Health.source_revision)) {
    Write-Diagnostic "Reusing compatible Symphony++ backend $Url with unknown source revision because MCP contract fingerprint $(Format-McpContractFingerprintForDiagnostic $Health.contract_fingerprint) matches this launcher."
    return
  }

  if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$Health.source_revision, $ExpectedSourceRevision)) {
    Write-Diagnostic "Reusing compatible Symphony++ backend $Url even though source revision $(Format-SourceRevisionForDiagnostic $Health.source_revision) differs from expected $(Format-SourceRevisionForDiagnostic $ExpectedSourceRevision); MCP contract fingerprint $(Format-McpContractFingerprintForDiagnostic $Health.contract_fingerprint) matches this launcher."
  }
}

function Set-SymppSourceRevisionEnvironment([string]$Revision) {
  if ([string]::IsNullOrWhiteSpace($Revision)) {
    return
  }

  $env:SYMPP_SOURCE_REVISION = $Revision
  [Environment]::SetEnvironmentVariable("SYMPP_SOURCE_REVISION", $Revision, "Process")
}

function Test-HealthySymppDashboard([string]$DashboardOrigin) {
  if ([string]::IsNullOrWhiteSpace($DashboardOrigin)) {
    return $false
  }

  $url = $DashboardOrigin.TrimEnd("/") + $BoardPath
  try {
    $response = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
    return [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400 -and [string]$response.Content -match "Symphony\+\+ Dashboard"
  } catch {
    return $false
  }
}

function Test-SymppDashboardMcpProxyMatches([string]$DashboardOrigin, [string]$ExpectedContractFingerprint) {
  if ([string]::IsNullOrWhiteSpace($ExpectedContractFingerprint)) {
    return $false
  }

  $proxyHealth = Get-SymppBackendHealthWithRetry $DashboardOrigin 2 250 $true
  return Test-BackendContractMatches $proxyHealth $ExpectedContractFingerprint
}

function Get-PortFromOrigin([string]$Origin) {
  try {
    $uri = [System.Uri]::new($Origin)
    return [int]$uri.Port
  } catch {
    return $null
  }
}

function Read-RuntimeState([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $stream = $null
  $reader = $null
  try {
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
    return $reader.ReadToEnd() | ConvertFrom-Json
  } catch {
    return $null
  } finally {
    if ($null -ne $reader) { $reader.Dispose() }
    elseif ($null -ne $stream) { $stream.Dispose() }
  }
}

function Write-RuntimeState([string]$Path, $State) {
  $directory = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  $json = $State | ConvertTo-Json -Depth 12
  $temporary = "$Path.tmp-$PID-$([guid]::NewGuid().ToString('N'))"
  Get-ChildItem -LiteralPath $directory -File -Filter "$(Split-Path -Leaf $Path).tmp-*" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
  try {
    [System.IO.File]::WriteAllText($temporary, "$json`n", $utf8NoBom)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      $backup = "$Path.backup-$PID-$([guid]::NewGuid().ToString('N'))"
      try {
        [System.IO.File]::Replace($temporary, $Path, $backup)
      } finally {
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
      }
    } else {
      [System.IO.File]::Move($temporary, $Path)
    }
  } finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
  }
}

function New-SymppPublicationControls([int]$BackendPort, [int]$DashboardPort, [bool]$BackendPortExplicit, [bool]$DashboardPortExplicit, [string]$BackendUrl, [string]$DashboardOrigin) {
  return [pscustomobject]@{
    backend_port = $BackendPort
    dashboard_port = $DashboardPort
    backend_port_explicit = $BackendPortExplicit
    dashboard_port_explicit = $DashboardPortExplicit
    backend_url = if ([string]::IsNullOrWhiteSpace($BackendUrl)) { $null } else { $BackendUrl.TrimEnd("/") }
    dashboard_origin = if ([string]::IsNullOrWhiteSpace($DashboardOrigin)) { $null } else { $DashboardOrigin.TrimEnd("/") }
  }
}

function Test-SymppPublicationControlsMatch($Recorded, $Expected) {
  if ($null -eq $Recorded -or $null -eq $Expected) { return $false }
  foreach ($name in @("backend_port", "dashboard_port", "backend_port_explicit", "dashboard_port_explicit", "backend_url", "dashboard_origin")) {
    if ([string]$Recorded.$name -ne [string]$Expected.$name) { return $false }
  }
  return $true
}

function Set-SymppRuntimePublication($State, [string]$Status, $InstalledIdentity, $Controls, $BackendPlan, [string]$RuntimeRoot, [string]$BackendStartIdentity = $null) {
  $backendPid = if ($null -ne $BackendPlan) { $BackendPlan.pid } else { $null }
  $ownerAdapterPid = 0
  if (-not [int]::TryParse([string]$env:SYMPP_BACKEND_OWNER_PID, [ref]$ownerAdapterPid) -or $ownerAdapterPid -le 0) { $ownerAdapterPid = $PID }
  $publication = [pscustomobject]@{
    status = $Status
    generation_key = [string]$InstalledIdentity.generation_key
    installed_revision = [string]$InstalledIdentity.revision
    leader_pid = $PID
    owner_adapter_pid = $ownerAdapterPid
    leader_process_start_time_utc_ticks = Get-ProcessStartIdentity (Get-Process -Id $PID -ErrorAction SilentlyContinue)
    published_at = [DateTimeOffset]::UtcNow.ToString("o")
    controls = $Controls
    backend = [pscustomobject]@{
      pid = $backendPid
      process_start_time_utc_ticks = $BackendStartIdentity
      port = if ($null -ne $BackendPlan) { $BackendPlan.port } else { $null }
      runtime_root = $RuntimeRoot
    }
  }
  $State | Add-Member -NotePropertyName schema_version -NotePropertyValue 2 -Force
  $State | Add-Member -NotePropertyName publication -NotePropertyValue $publication -Force
  return $State
}

function Test-SymppPublishedRuntimeReadyLocally($State, [string]$PluginRoot, $InstalledIdentity, $Controls) {
  if ($null -eq $State -or $null -eq $State.publication -or
      [string]$State.publication.status -ne "ready" -or
      -not (Test-SymppPublicationControlsMatch $State.publication.controls $Controls) -or
      $null -eq $State.backend -or [string]::IsNullOrWhiteSpace([string]$State.backend.url)) {
    return $false
  }
  if ($null -ne $InstalledIdentity -and
      -not [System.StringComparer]::Ordinal.Equals([string]$State.publication.generation_key, [string]$InstalledIdentity.generation_key)) { return $false }
  try {
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([System.IO.Path]::GetFullPath([string]$State.plugin_root), [System.IO.Path]::GetFullPath($PluginRoot))) { return $false }
    Assert-LoopbackHttpOrigin ([string]$State.backend.url) "published Symphony++ backend"
  } catch { return $false }
  if ($null -ne $InstalledIdentity -and
      (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$State.backend.expected_contract_fingerprint, [string]$InstalledIdentity.contract_fingerprint) -or
      -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$State.backend.contract_fingerprint, [string]$InstalledIdentity.contract_fingerprint))) {
    return $false
  }
  if ($State.backend.managed -eq $true) {
    $backendPid = 0
    if (-not [int]::TryParse([string]$State.backend.pid, [ref]$backendPid) -or $backendPid -le 0 -or
        -not [System.StringComparer]::Ordinal.Equals([string]$State.publication.backend.process_start_time_utc_ticks, (Get-ProcessStartIdentity (Get-Process -Id $backendPid -ErrorAction SilentlyContinue))) -or
        -not (Test-ProcessOwnsTcpPort $backendPid ([int]$State.backend.port))) {
      return $false
    }
  } else {
    $publishedContract = if ($null -ne $InstalledIdentity) { [string]$InstalledIdentity.contract_fingerprint } else { [string]$State.backend.expected_contract_fingerprint }
    if (-not (Test-BackendLaunchCompatible (Get-SymppBackendHealthWithRetry ([string]$State.backend.url) 1 0) $publishedContract)) { return $false }
  }
  return $true
}

function Enter-SymppColdLeadership([string]$RuntimeFile, [string]$PluginRoot, $InstalledIdentity, $Controls, [DateTime]$Deadline, [bool]$RequireLeadership = $false) {
  $lockPath = Resolve-StartupLockFile $RuntimeFile
  $waitTraced = $false
  while ([DateTime]::UtcNow -lt $Deadline) {
    if (-not $RequireLeadership -and (Test-SymppPublishedRuntimeReadyLocally (Read-RuntimeState $RuntimeFile) $PluginRoot $InstalledIdentity $Controls)) {
      Write-SymppLauncherTrace "cold_follower_ready"
      return [pscustomobject]@{ leader = $false; lock = $null }
    }
    $lock = Try-Enter-FileLock $lockPath
    if ($null -ne $lock) {
      if (-not $RequireLeadership -and (Test-SymppPublishedRuntimeReadyLocally (Read-RuntimeState $RuntimeFile) $PluginRoot $InstalledIdentity $Controls)) {
        Exit-FileLock $lock
        Write-SymppLauncherTrace "cold_follower_ready"
        return [pscustomobject]@{ leader = $false; lock = $null }
      }
      Write-SymppLauncherTrace "cold_leader_acquired"
      return [pscustomobject]@{ leader = $true; lock = $lock }
    }
    if (-not $waitTraced) {
      Write-SymppLauncherTrace "cold_follower_wait"
      $waitTraced = $true
    }
    Start-Sleep -Milliseconds (Get-Random -Minimum 200 -Maximum 501)
  }
  throw "cold_start_timeout: timed out waiting for Symphony++ cold runtime publication."
}

function Resolve-SymppPendingBackendProcess($State) {
  $leaderPid = 0
  if ($null -eq $State.publication -or
      -not [int]::TryParse([string]$State.publication.leader_pid, [ref]$leaderPid) -or $leaderPid -le 0 -or
      [string]::IsNullOrWhiteSpace([string]$State.publication.backend.runtime_root)) { return $null }
  $leader = Get-Process -Id $leaderPid -ErrorAction SilentlyContinue
  if ($leader -and [System.StringComparer]::Ordinal.Equals(
      [string]$State.publication.leader_process_start_time_utc_ticks, (Get-ProcessStartIdentity $leader))) { return $null }
  $cim = Get-Command Get-CimInstance -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cim) { return $null }
  $publishedAt = [DateTimeOffset]::MinValue
  [void][DateTimeOffset]::TryParse([string]$State.publication.published_at, [ref]$publishedAt)
  $runtimeRoot = ([System.IO.Path]::GetFullPath([string]$State.publication.backend.runtime_root)).Replace("/", "\")
  $backendPort = [int]$State.publication.backend.port
  $publishedPid = 0
  [void][int]::TryParse([string]$State.publication.backend.pid, [ref]$publishedPid)
  $parentIds = @($leaderPid, $publishedPid) | Where-Object { $_ -gt 0 } | Select-Object -Unique
  $matches = @($parentIds | ForEach-Object { Get-CimInstance Win32_Process -Filter "ParentProcessId=$_" -ErrorAction SilentlyContinue } | Where-Object {
      $created = [DateTimeOffset]$_.CreationDate
      $commandLine = [string]$_.CommandLine
      $created -ge $publishedAt.AddSeconds(-1) -and (Test-SymppBackendCommandLine $commandLine) -and
        ($commandLine.Replace("/", "\").IndexOf($runtimeRoot, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
         (Test-ManagedRuntimePortCommandLine "backend" $commandLine $backendPort))
    })
  if ($matches.Count -ne 1) { return $null }
  $process = Get-Process -Id ([int]$matches[0].ProcessId) -ErrorAction SilentlyContinue
  if (-not $process) { return $null }
  return [pscustomobject]@{ pid = [int]$process.Id; process_start_time_utc_ticks = Get-ProcessStartIdentity $process }
}

function Test-SymppStartingBackendOwned($State, $InstalledIdentity, $Controls) {
  if ($null -eq $State -or $null -eq $State.publication -or [string]$State.publication.status -ne "starting" -or
      -not [System.StringComparer]::Ordinal.Equals([string]$State.publication.generation_key, [string]$InstalledIdentity.generation_key) -or
      -not (Test-SymppPublicationControlsMatch $State.publication.controls $Controls)) { return $false }
  $backendPid = 0
  $publishedProcess = $null
  $publishedIdentityMatches = [int]::TryParse([string]$State.publication.backend.pid, [ref]$backendPid) -and $backendPid -gt 0
  if ($publishedIdentityMatches) {
    $publishedProcess = Get-Process -Id $backendPid -ErrorAction SilentlyContinue
    $publishedIdentityMatches = $publishedProcess -and [System.StringComparer]::Ordinal.Equals(
      [string]$State.publication.backend.process_start_time_utc_ticks, (Get-ProcessStartIdentity $publishedProcess))
  }
  if (-not $publishedIdentityMatches) {
    $pending = Resolve-SymppPendingBackendProcess $State
    if ($null -eq $pending) { return $false }
    $backendPid = [int]$pending.pid
    $State.publication.backend.pid = $backendPid
    $State.publication.backend.process_start_time_utc_ticks = [string]$pending.process_start_time_utc_ticks
    $State.backend.pid = $backendPid
    Write-SymppLauncherTrace "backend_pending_launch_recovered"
  }
  if (-not [System.StringComparer]::Ordinal.Equals([string]$State.publication.backend.process_start_time_utc_ticks, (Get-ProcessStartIdentity (Get-Process -Id $backendPid -ErrorAction SilentlyContinue)))) { return $false }
  $commandLine = Get-ProcessCommandLine $backendPid
  if (-not (Test-SymppBackendCommandLine $commandLine)) { return $false }
  $runtimeRoot = [string]$State.publication.backend.runtime_root
  return -not [string]::IsNullOrWhiteSpace($runtimeRoot) -and
    ($commandLine.Replace("/", "\").IndexOf(([System.IO.Path]::GetFullPath($runtimeRoot)).Replace("/", "\"), [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
     (Test-ManagedRuntimePortCommandLine "backend" $commandLine ([int]$State.publication.backend.port)))
}

function Get-ProcessCommandLine([int]$ProcessId) {
  if ($ProcessId -le 0) {
    return $null
  }

  $cim = Get-Command Get-CimInstance -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cim) {
    try {
      $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
      if ($process) {
        return [string]$process.CommandLine
      }
    } catch {
    }
  }

  $procCmdline = "/proc/$ProcessId/cmdline"
  if (Test-Path -LiteralPath $procCmdline) {
    try {
      $raw = [System.IO.File]::ReadAllText($procCmdline)
      $text = ($raw -replace [char]0, " ").Trim()
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        return $text
      }
    } catch {
    }
  }

  return $null
}

function Test-ProcessAlive([int]$ProcessId) {
  if ($ProcessId -le 0) {
    return $false
  }

  return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Test-BridgeLeaseMatchesRuntimeKey($Lease, [string]$RuntimeKey) {
  if ($null -eq $Lease -or [string]::IsNullOrWhiteSpace($RuntimeKey)) {
    return $false
  }

  if (-not $Lease.PSObject.Properties["runtime_key"] -or [string]::IsNullOrWhiteSpace([string]$Lease.runtime_key)) {
    return $false
  }

  return [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$Lease.runtime_key, $RuntimeKey)
}

function Test-ActiveLegacyBridgeLease($ActiveLeases) {
  foreach ($activeLease in @($ActiveLeases)) {
    $lease = $activeLease.lease
    if ($null -eq $lease -or -not $lease.PSObject.Properties["runtime_key"] -or [string]::IsNullOrWhiteSpace([string]$lease.runtime_key)) {
      return $true
    }
  }

  return $false
}

function Test-ActiveBridgeLeaseForRuntimeKey($ActiveLeases, [string]$RuntimeKey) {
  foreach ($activeLease in @($ActiveLeases)) {
    if (Test-BridgeLeaseMatchesRuntimeKey $activeLease.lease $RuntimeKey) {
      return $true
    }
  }

  return $false
}

function Stop-ManagedRuntimeProcess([string]$Role, $ProcessIdValue, [int]$Port) {
  $managedPid = 0
  if (-not [int]::TryParse([string]$ProcessIdValue, [ref]$managedPid) -or $managedPid -le 0) {
    return $false
  }

  $commandLine = Get-ProcessCommandLine $managedPid
  if ([string]::IsNullOrWhiteSpace($commandLine)) {
    Write-Diagnostic "Skipping $Role shutdown for pid=$managedPid because its command line could not be verified."
    return $false
  }

  if (-not (Test-ManagedRuntimeCommandLine $Role $commandLine) -or
      (-not (Test-ManagedRuntimePortCommandLine $Role $commandLine $Port) -and
       -not (Test-ProcessOwnsTcpPort $managedPid $Port))) {
    Write-Diagnostic "Skipping $Role shutdown for pid=$managedPid because it no longer matches the managed Symphony++ command."
    return $false
  }

  Write-Diagnostic "Stopping managed Symphony++ $Role pid=$managedPid after last Codex MCP bridge exited."
  $process = Get-Process -Id $managedPid -ErrorAction SilentlyContinue
  Stop-Process -Id $managedPid -Force -ErrorAction SilentlyContinue
  if ($process) {
    try {
      [void]$process.WaitForExit(5000)
    } catch {
    }
  }
  return $true
}

function Get-RuntimeEntryPort($Entry) {
  $port = 0
  if ($null -ne $Entry) {
    [void][int]::TryParse([string]$Entry.port, [ref]$port)
  }

  return $port
}

function Stop-ManagedRuntimeEntry([string]$Role, $Entry) {
  if ($null -eq $Entry -or $Entry.managed -ne $true) {
    return $false
  }

  $entryPort = Get-RuntimeEntryPort $Entry
  $managedPid = 0
  if (-not [int]::TryParse([string]$Entry.pid, [ref]$managedPid) -or $managedPid -le 0) {
    $listenerPid = if ($entryPort -gt 0) { Get-ManagedListenerPid $Role $entryPort } else { $null }
    if ($listenerPid) {
      Write-Diagnostic "Stopping managed Symphony++ $Role listener pid=$listenerPid for stale runtime entry with missing pid."
      return Stop-ManagedRuntimeProcess $Role $listenerPid $entryPort
    } else {
      Write-Diagnostic "Pruning stale managed Symphony++ $Role runtime entry with missing pid."
    }

    return $true
  }

  if (-not (Test-ProcessAlive $managedPid)) {
    $listenerPid = if ($entryPort -gt 0) { Get-ManagedListenerPid $Role $entryPort } else { $null }
    if ($listenerPid) {
      Write-Diagnostic "Stopping managed Symphony++ $Role listener pid=$listenerPid for stale runtime entry with exited pid=$managedPid."
      return Stop-ManagedRuntimeProcess $Role $listenerPid $entryPort
    } else {
      Write-Diagnostic "Pruning stale managed Symphony++ $Role runtime entry for exited pid=$managedPid."
    }

    return $true
  }

  $stopped = Stop-ManagedRuntimeProcess $Role $managedPid $entryPort
  $listenerPid = if ($entryPort -gt 0) { Get-ManagedListenerPid $Role $entryPort } else { $null }
  if ($listenerPid -and $listenerPid -ne $managedPid) {
    $stopped = (Stop-ManagedRuntimeProcess $Role $listenerPid $entryPort) -or $stopped
  }

  return $stopped
}

function Test-RuntimeStateExternalLoopback($RuntimeState) {
  if ($null -eq $RuntimeState) {
    return $false
  }

  if ($null -eq $RuntimeState.backend -or $null -eq $RuntimeState.frontend -or
      $RuntimeState.backend.managed -eq $true -or $RuntimeState.frontend.managed -eq $true) {
    return $false
  }

  return [string]$RuntimeState.backend.status -eq "external_loopback" -and
    [string]$RuntimeState.frontend.status -eq "external_loopback"
}

function Test-BackendShouldShutdownOnIdle($BackendPlan, $DashboardPlan) {
  return ($BackendPlan.managed -eq $true) -and
    ($DashboardPlan.managed -ne $true)
}

function Test-RuntimeEntryEndpointMatches([string]$Role, $Entry, [string]$Endpoint) {
  if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace($Endpoint)) {
    return $false
  }

  $entryEndpoint = if ($Role -eq "backend") { [string]$Entry.url } else { [string]$Entry.origin }
  return -not [string]::IsNullOrWhiteSpace($entryEndpoint) -and
    $entryEndpoint.TrimEnd("/") -eq $Endpoint.TrimEnd("/")
}

function Test-ManagedRuntimeEntrySuperseded([string]$Role, $Entry, [string]$SelectedEndpoint) {
  if ($null -eq $Entry -or $Entry.managed -ne $true) {
    return $false
  }

  $entryEndpoint = if ($Role -eq "backend") { [string]$Entry.url } else { [string]$Entry.origin }
  if ([string]::IsNullOrWhiteSpace($entryEndpoint)) {
    return $false
  }

  if ([string]::IsNullOrWhiteSpace($SelectedEndpoint)) {
    return $true
  }

  return $entryEndpoint.TrimEnd("/") -ne $SelectedEndpoint.TrimEnd("/")
}

function Test-PortSelectionAllowsReuse([int]$PreferredPort, [string]$Endpoint, [bool]$EnforcePreferredPort) {
  if (-not $EnforcePreferredPort -or $PreferredPort -eq 0) {
    return $true
  }

  return (Get-PortFromOrigin $Endpoint) -eq $PreferredPort
}

function Test-RuntimeEntryExternalOverride($Entry, [string]$Endpoint, [string]$Role) {
  if ($null -eq $Entry -or [string]$Entry.status -ne "external_override") {
    return $false
  }

  return Test-RuntimeEntryEndpointMatches $Role $Entry $Endpoint
}

function Test-EndpointMatches([string]$RecordedEndpoint, [string]$ExpectedEndpoint) {
  return -not [string]::IsNullOrWhiteSpace($RecordedEndpoint) -and
    -not [string]::IsNullOrWhiteSpace($ExpectedEndpoint) -and
    $RecordedEndpoint.TrimEnd("/") -eq $ExpectedEndpoint.TrimEnd("/")
}

function Test-BridgeLeaseMatchesBackend($Lease, [string]$BackendUrl) {
  if ($null -eq $Lease -or -not $Lease.PSObject.Properties["backend_url"]) {
    return $false
  }

  return Test-EndpointMatches ([string]$Lease.backend_url) $BackendUrl
}

function Test-BridgeLeaseMatchesDashboard($Lease, [string]$DashboardOrigin) {
  if ($null -eq $Lease -or -not $Lease.PSObject.Properties["dashboard_origin"]) {
    return $false
  }

  return Test-EndpointMatches ([string]$Lease.dashboard_origin) $DashboardOrigin
}

function Test-ActiveBridgeLeaseForBackend($ActiveLeases, [string]$BackendUrl) {
  foreach ($activeLease in @($ActiveLeases)) {
    if (Test-BridgeLeaseMatchesBackend $activeLease.lease $BackendUrl) {
      return $true
    }
  }

  return $false
}

function Test-ActiveBridgeLeaseForDashboard($ActiveLeases, [string]$DashboardOrigin) {
  foreach ($activeLease in @($ActiveLeases)) {
    if (Test-BridgeLeaseMatchesDashboard $activeLease.lease $DashboardOrigin) {
      return $true
    }
  }

  return $false
}

function New-SupersededRuntimeState($RuntimeState, $BackendPlan, $DashboardPlan) {
  $backend = $null
  $frontend = $null
  $runtimeKey = $null
  if ($null -ne $RuntimeState) {
    if (Test-ManagedRuntimeEntrySuperseded "backend" $RuntimeState.backend ([string]$BackendPlan.url)) {
      $backend = $RuntimeState.backend
    }
    if (Test-ManagedRuntimeEntrySuperseded "frontend" $RuntimeState.frontend ([string]$DashboardPlan.origin)) {
      $frontend = $RuntimeState.frontend
    }
    if ($null -ne $backend -or $null -ne $frontend) {
      $runtimeKey = Get-RuntimeStateKey $RuntimeState
    }
  }

  return [pscustomobject]@{
    runtime_key = $runtimeKey
    backend = $backend
    frontend = $frontend
  }
}

function Get-SupersededRuntimeKey($Superseded) {
  if ($null -eq $Superseded -or -not $Superseded.PSObject.Properties["runtime_key"]) {
    return $null
  }

  $runtimeKey = [string]$Superseded.runtime_key
  if ([string]::IsNullOrWhiteSpace($runtimeKey)) {
    return $null
  }

  return $runtimeKey
}

function Test-SupersededRuntimeStateHasEntries($Superseded) {
  return $null -ne $Superseded -and ($null -ne $Superseded.backend -or $null -ne $Superseded.frontend)
}

function Get-SupersededRuntimeStates($State) {
  $states = [System.Collections.ArrayList]::new()
  $seen = @{}
  if ($null -eq $State) {
    return @()
  }

  foreach ($entry in @($State.superseded_runtimes)) {
    if (-not (Test-SupersededRuntimeStateHasEntries $entry)) {
      continue
    }

    $runtimeKey = Get-SupersededRuntimeKey $entry
    if (-not [string]::IsNullOrWhiteSpace($runtimeKey)) {
      if ($seen.ContainsKey($runtimeKey)) {
        continue
      }
      $seen[$runtimeKey] = $true
    }

    [void]$states.Add($entry)
  }

  if ($State.PSObject.Properties["superseded"] -and (Test-SupersededRuntimeStateHasEntries $State.superseded)) {
    $runtimeKey = Get-SupersededRuntimeKey $State.superseded
    if ([string]::IsNullOrWhiteSpace($runtimeKey) -or -not $seen.ContainsKey($runtimeKey)) {
      [void]$states.Add($State.superseded)
    }
  }

  return @($states)
}

function Merge-SupersededRuntimeStates($Existing, $Candidate) {
  $states = [System.Collections.ArrayList]::new()
  $seen = @{}
  foreach ($entry in @($Candidate) + @($Existing)) {
    if (-not (Test-SupersededRuntimeStateHasEntries $entry)) {
      continue
    }

    $runtimeKey = Get-SupersededRuntimeKey $entry
    if (-not [string]::IsNullOrWhiteSpace($runtimeKey)) {
      if ($seen.ContainsKey($runtimeKey)) {
        continue
      }
      $seen[$runtimeKey] = $true
    }

    [void]$states.Add($entry)
  }

  return @($states)
}

function Set-SupersededRuntimeStates($State, $SupersededStates) {
  if ($null -eq $State) {
    return
  }

  $states = @($SupersededStates | Where-Object { Test-SupersededRuntimeStateHasEntries $_ })
  $legacyState = if ($states.Count -gt 0) { $states[0] } else { $null }
  $State | Add-Member -NotePropertyName superseded -NotePropertyValue $legacyState -Force
  $State | Add-Member -NotePropertyName superseded_runtimes -NotePropertyValue $states -Force
}

function Stop-SupersededManagedServersIfUnused([string]$RuntimeFile, $Superseded) {
  if ($null -eq $Superseded) {
    return $Superseded
  }

  $activeLeases = @(Get-ActiveBridgeLeases $RuntimeFile)
  if (Test-ActiveLegacyBridgeLease $activeLeases) {
    return $Superseded
  }

  if (-not (Test-ActiveBridgeLeaseForDashboard $activeLeases ([string]$Superseded.frontend.origin)) -and
      (Stop-ManagedRuntimeEntry "frontend" $Superseded.frontend)) {
    $Superseded.frontend = $null
  }
  if (-not (Test-ActiveBridgeLeaseForBackend $activeLeases ([string]$Superseded.backend.url)) -and
      (Stop-ManagedRuntimeEntry "backend" $Superseded.backend)) {
    $Superseded.backend = $null
  }

  return $Superseded
}

function Stop-SupersededRuntimeStatesIfUnused([string]$RuntimeFile, $SupersededStates) {
  $remaining = [System.Collections.ArrayList]::new()
  foreach ($superseded in @($SupersededStates)) {
    $updated = Stop-SupersededManagedServersIfUnused $RuntimeFile $superseded
    if (Test-SupersededRuntimeStateHasEntries $updated) {
      [void]$remaining.Add($updated)
    }
  }

  return @($remaining)
}

function Stop-ManagedRuntimeStateEntries($State, [string]$PreserveBackendUrl = $null, [string]$PreserveDashboardOrigin = $null) {
  $stoppedAny = $false
  if ($null -eq $State) {
    return $false
  }

  $supersededStates = [System.Collections.ArrayList]::new()
  foreach ($superseded in @(Get-SupersededRuntimeStates $State)) {
    if (-not (Test-RuntimeEntryEndpointMatches "frontend" $superseded.frontend $PreserveDashboardOrigin) -and
        (Stop-ManagedRuntimeEntry "frontend" $superseded.frontend)) {
      $superseded.frontend = $null
      $stoppedAny = $true
    }
    if (-not (Test-RuntimeEntryEndpointMatches "backend" $superseded.backend $PreserveBackendUrl) -and
        (Stop-ManagedRuntimeEntry "backend" $superseded.backend)) {
      $superseded.backend = $null
      $stoppedAny = $true
    }
    if (Test-SupersededRuntimeStateHasEntries $superseded) {
      [void]$supersededStates.Add($superseded)
    }
  }
  Set-SupersededRuntimeStates $State $supersededStates

  if (-not (Test-RuntimeEntryEndpointMatches "frontend" $State.frontend $PreserveDashboardOrigin) -and
      (Stop-ManagedRuntimeEntry "frontend" $State.frontend)) {
    $State.frontend.status = "stopped"
    $State.frontend.pid = $null
    $stoppedAny = $true
  }

  if (-not (Test-RuntimeEntryEndpointMatches "backend" $State.backend $PreserveBackendUrl) -and
      (Stop-ManagedRuntimeEntry "backend" $State.backend)) {
    $State.backend.status = "stopped"
    $State.backend.pid = $null
    $stoppedAny = $true
  }

  return $stoppedAny
}

function Stop-CurrentManagedRuntimeStateEntries($State, $ActiveLeases) {
  $stoppedAny = $false
  if ($null -eq $State) {
    return $false
  }

  if (-not (Test-ActiveBridgeLeaseForDashboard $ActiveLeases ([string]$State.frontend.origin)) -and
      (Stop-ManagedRuntimeEntry "frontend" $State.frontend)) {
    $State.frontend.status = "stopped"
    $State.frontend.pid = $null
    $stoppedAny = $true
  }

  if (-not (Test-ActiveBridgeLeaseForBackend $ActiveLeases ([string]$State.backend.url)) -and
      (Stop-ManagedRuntimeEntry "backend" $State.backend)) {
    $State.backend.status = "stopped"
    $State.backend.pid = $null
    $stoppedAny = $true
  }

  return $stoppedAny
}

function Get-ManagedListenerPid([string]$Role, [int]$Port) {
  foreach ($owner in @(Get-TcpPortOwners $Port)) {
    $commandLine = Get-ProcessCommandLine ([int]$owner.pid)
    if (Test-ManagedRuntimeCommandLine $Role $commandLine) {
      return [int]$owner.pid
    }
  }

  return $null
}

function Stop-ManagedServersIfUnused([string]$RuntimeFile, [string]$RuntimeKey) {
  Write-SymppLauncherTrace "last_detach_cleanup_requested"
  $lock = Enter-FileLock (Resolve-StartupLockFile $RuntimeFile) 30
  try {
    $activeLeases = @(Get-ActiveBridgeLeases $RuntimeFile)
    if ((Test-ActiveLegacyBridgeLease $activeLeases) -or (Test-ActiveBridgeLeaseForRuntimeKey $activeLeases $RuntimeKey)) {
      Write-SymppLauncherTrace "last_detach_cleanup_preserved_active_runtime"
      return
    }

    $state = Read-RuntimeState $RuntimeFile
    if ($null -eq $state) {
      return
    }

    $stateKey = Get-RuntimeStateKey $state
    $activeLeases = @(Get-ActiveBridgeLeases $RuntimeFile)
    if ((Test-ActiveLegacyBridgeLease $activeLeases) -or (Test-ActiveBridgeLeaseForRuntimeKey $activeLeases $RuntimeKey)) {
      Write-SymppLauncherTrace "last_detach_cleanup_preserved_active_runtime"
      return
    }
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($stateKey, $RuntimeKey)) {
      if (Stop-CurrentManagedRuntimeStateEntries $state $activeLeases) {
        Write-SymppLauncherTrace "last_detach_cleanup_stopped_runtime"
      }
    }
    $supersededStates = Stop-SupersededRuntimeStatesIfUnused $RuntimeFile (Get-SupersededRuntimeStates $state)
    Set-SupersededRuntimeStates $state $supersededStates

    Write-RuntimeState $RuntimeFile $state
  } finally {
    Exit-FileLock $lock
  }
}

function Start-LoggedProcess([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory, [hashtable]$Environment, [string]$LogPrefix, [string]$LogDir) {
  New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $stdoutPath = Join-Path $LogDir "$LogPrefix-$stamp.out.log"
  $stderrPath = Join-Path $LogDir "$LogPrefix-$stamp.err.log"
  $stdinPath = Join-Path $LogDir "$LogPrefix-$stamp.in.log"
  $startCommand = Get-StartProcessCommand $FilePath $ArgumentList

  $oldEnvironment = @{}
  foreach ($key in @($Environment.Keys)) {
    $oldEnvironment[$key] = [Environment]::GetEnvironmentVariable([string]$key, "Process")
    [Environment]::SetEnvironmentVariable([string]$key, [string]$Environment[$key], "Process")
  }

  try {
    [System.IO.File]::WriteAllBytes($stdinPath, [byte[]]@())
    $startArgs = @{
      FilePath = $startCommand.file
      ArgumentList = (Join-ProcessArgumentList @($startCommand.args))
      WorkingDirectory = $WorkingDirectory
      RedirectStandardInput = $stdinPath; RedirectStandardOutput = $stdoutPath; RedirectStandardError = $stderrPath; PassThru = $true
    }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { $startArgs["WindowStyle"] = "Hidden" }
    $process = Start-Process @startArgs
  } finally {
    foreach ($key in @($Environment.Keys)) {
      [Environment]::SetEnvironmentVariable([string]$key, $oldEnvironment[$key], "Process")
    }
  }

  return [pscustomobject]@{
    process = $process
    stdout = $stdoutPath
    stderr = $stderrPath
  }
}

function Stop-LoggedProcess($Launch) {
  if ($null -eq $Launch -or $null -eq $Launch.process -or $Launch.process.HasExited) {
    return
  }

  Stop-Process -Id $Launch.process.Id -Force -ErrorAction SilentlyContinue
  try {
    [void]$Launch.process.WaitForExit(5000)
  } catch {
  }
}

function Wait-Until([scriptblock]$Predicate, [int]$TimeoutSec) {
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    if (& $Predicate) {
      return $true
    }
    Start-Sleep -Milliseconds 500
  }

  return $false
}

function New-ReusedBackendPlan([string]$Status, [string]$Url, $Health, [bool]$Managed, $ProcessId) {
  $url = $Url.TrimEnd("/")
  return [pscustomobject]@{
    status = $Status
    url = $url
    mcp_url = "$url/mcp"
    port = Get-PortFromOrigin $url
    should_start = $false
    reused = $true
    managed = $Managed -eq $true
    pid = $ProcessId
    source_revision = $Health.source_revision
    contract_fingerprint = $Health.contract_fingerprint
  }
}

function Resolve-BackendPlan([int]$PreferredPort, [string]$ConfiguredUrl, $RuntimeState, [int]$PortReleaseTimeoutSec, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint, [bool]$EnforcePreferredPort, [int[]]$AvoidPorts = @()) {
  if (-not [string]::IsNullOrWhiteSpace($ConfiguredUrl)) {
    $url = $ConfiguredUrl.TrimEnd("/")
    Assert-LoopbackHttpOrigin $url "SYMPP_BACKEND_URL"
    $health = Get-SymppBackendHealthWithRetry $url
    if (-not $health.healthy) {
      throw "SYMPP_BACKEND_URL is not a healthy Symphony++ backend: $url"
    }
    if (-not (Test-BackendLaunchCompatible $health $ExpectedContractFingerprint)) {
      throw "SYMPP_BACKEND_URL is healthy but not compatible with this launcher: $(Format-BackendLaunchCompatibilityMismatch $health $ExpectedSourceRevision $ExpectedContractFingerprint): $url"
    }

    Write-CompatibleSourceMismatchDiagnostic $url $health $ExpectedSourceRevision
    return New-ReusedBackendPlan "external_override" $url $health $false $null
  }

  $selectedPort = $null
  if ($PreferredPort -gt 0) {
    $preferredUrl = "http://127.0.0.1:$PreferredPort"
    $preferredHealth = Get-SymppBackendHealthWithRetry $preferredUrl
    $preferredEntry = if ($null -ne $RuntimeState) { $RuntimeState.backend } else { $null }
    if ($preferredHealth.healthy) {
      if (Test-RuntimeEntryExternalOverride $preferredEntry $preferredUrl "backend") {
        Write-Diagnostic "Ignoring recorded external backend $preferredUrl for implicit reuse. Set SYMPP_BACKEND_URL=$preferredUrl to reuse it explicitly."
      } elseif (Test-BackendLaunchCompatible $preferredHealth $ExpectedContractFingerprint) {
        $managed = $false
        $entryPid = $null
        $status = "external_loopback"
        if (Test-RuntimeEntryEndpointMatches "backend" $preferredEntry $preferredUrl) {
          $managed = $preferredEntry.managed -eq $true
          $entryPid = $preferredEntry.pid
          if ($managed) {
            $status = "reused"
          }
        }
        Write-CompatibleSourceMismatchDiagnostic $preferredUrl $preferredHealth $ExpectedSourceRevision
        return New-ReusedBackendPlan $status $preferredUrl $preferredHealth $managed $entryPid
      } else {
        Write-Diagnostic "Ignoring healthy Symphony++ backend $preferredUrl because $(Format-BackendLaunchCompatibilityMismatch $preferredHealth $ExpectedSourceRevision $ExpectedContractFingerprint)"
      }
      $selectedPort = Select-AvailablePort $PreferredPort (@($PreferredPort) + @($AvoidPorts))
    }
  }

  if ($null -ne $RuntimeState -and $null -ne $RuntimeState.backend) {
    $runtimeUrl = [string]$RuntimeState.backend.url
    if (-not [string]::IsNullOrWhiteSpace($runtimeUrl)) {
      $runtimeUrl = $runtimeUrl.TrimEnd("/")
      $runtimeHealth = Get-SymppBackendHealthWithRetry $runtimeUrl
      $runtimeManaged = $RuntimeState.backend.managed -eq $true
      $portAllowed = Test-PortSelectionAllowsReuse $PreferredPort $runtimeUrl $EnforcePreferredPort
      if ($runtimeManaged -and $portAllowed -and $runtimeHealth.healthy -and (Test-BackendLaunchCompatible $runtimeHealth $ExpectedContractFingerprint)) {
        Write-CompatibleSourceMismatchDiagnostic $runtimeUrl $runtimeHealth $ExpectedSourceRevision
        return New-ReusedBackendPlan "reused" $runtimeUrl $runtimeHealth ($RuntimeState.backend.managed -eq $true) $RuntimeState.backend.pid
      }

      if ($runtimeHealth.healthy -and -not (Test-BackendLaunchCompatible $runtimeHealth $ExpectedContractFingerprint)) {
        Write-Diagnostic "Ignoring healthy runtime backend $runtimeUrl because $(Format-BackendLaunchCompatibilityMismatch $runtimeHealth $ExpectedSourceRevision $ExpectedContractFingerprint)"
      } elseif ($runtimeHealth.healthy -and -not $runtimeManaged) {
        Write-Diagnostic "Ignoring recorded external backend $runtimeUrl for implicit reuse. Set SYMPP_BACKEND_URL=$runtimeUrl to reuse it explicitly."
      } elseif ($runtimeHealth.healthy -and -not $portAllowed) {
        Write-Diagnostic "Ignoring healthy runtime backend $runtimeUrl because SYMPP_BACKEND_PORT requests $PreferredPort. Set SYMPP_BACKEND_URL=$runtimeUrl to reuse it explicitly."
      }
    }
  }

  if ($null -eq $selectedPort -and $PreferredPort -gt 0) {
    $portRelease = Wait-ForTcpPortRelease $PreferredPort $PortReleaseTimeoutSec
    if (-not $portRelease.released) {
      if (Test-SymppBackendOwners @($portRelease.owners)) {
        $busyHealth = Get-SymppBackendHealthWithRetry "http://127.0.0.1:$PreferredPort" 6 750
        if ($busyHealth.healthy -and (Test-BackendLaunchCompatible $busyHealth $ExpectedContractFingerprint)) {
          Write-CompatibleSourceMismatchDiagnostic "http://127.0.0.1:$PreferredPort" $busyHealth $ExpectedSourceRevision
          return New-ReusedBackendPlan "external_loopback" "http://127.0.0.1:$PreferredPort" $busyHealth $false $null
        }
        if ($busyHealth.mcp_ready) {
          Write-Diagnostic "$(New-BackendPortOccupiedMessage $PreferredPort @($portRelease.owners)) The occupied Symphony++ backend responded to MCP but is not a healthy compatible runtime (status=$($busyHealth.status), source=$(Format-SourceRevisionForDiagnostic $busyHealth.source_revision), contract=$(Format-McpContractFingerprintForDiagnostic $busyHealth.contract_fingerprint)). Selecting a fallback managed backend port for this Codex session."
          $selectedPort = Select-AvailablePort $PreferredPort (@($PreferredPort) + @($AvoidPorts))
        } elseif (-not $EnforcePreferredPort) {
          Write-Diagnostic "$(New-BackendPortOccupiedMessage $PreferredPort @($portRelease.owners)) The occupied Symphony++ backend did not become MCP-ready after the bounded retry window. Selecting a fallback managed backend port for this Codex session."
          $selectedPort = Select-AvailablePort $PreferredPort (@($PreferredPort) + @($AvoidPorts))
        } else {
          throw (New-BackendBusySymppMessage $PreferredPort @($portRelease.owners) $busyHealth)
        }
      } else {
        Write-Diagnostic "$(New-BackendPortOccupiedMessage $PreferredPort @($portRelease.owners)) Selecting a fallback managed backend port for this Codex session."
        $selectedPort = Select-AvailablePort $PreferredPort (@($PreferredPort) + @($AvoidPorts))
      }
    } else {
      $selectedPort = $PreferredPort
    }
  } elseif ($null -eq $selectedPort) {
    $selectedPort = Select-AvailablePort $PreferredPort @($AvoidPorts)
  }

  $url = "http://127.0.0.1:$selectedPort"
  return [pscustomobject]@{
    status = "starting"
    url = $url
    mcp_url = "$url/mcp"
    port = $selectedPort
    should_start = $true
    reused = $false
    managed = $true
    pid = $null
    source_revision = $null
    contract_fingerprint = $null
  }
}

function New-ReusedDashboardPlan([string]$Status, [string]$Origin, [bool]$Managed, $ProcessId) {
  $origin = $Origin.TrimEnd("/")
  return [pscustomobject]@{
    status = $Status
    origin = $origin
    url = "$origin$BoardPath"
    port = Get-PortFromOrigin $origin
    should_start = $false
    reused = $true
    managed = $Managed -eq $true
    pid = $ProcessId
  }
}

function New-DisabledDashboardPlan([string]$Status, [string]$Error = $null) {
  return [pscustomobject]@{
    status = $Status
    origin = $null
    url = $null
    port = $null
    should_start = $false
    reused = $false
    managed = $false
    pid = $null
    error = $Error
  }
}

function Resolve-LocalWarmAttachIdentity {
  param(
    $RuntimeState,
    [string]$PluginRoot,
    [int]$BackendPort,
    [int]$DashboardPort,
    [bool]$BackendPortExplicit,
    [bool]$DashboardPortExplicit,
    [string]$ConfiguredBackendUrl,
    [string]$ConfiguredDashboardOrigin
  )

  if ($null -eq $RuntimeState -or $null -eq $RuntimeState.backend -or $null -eq $RuntimeState.frontend -or
      -not $RuntimeState.PSObject.Properties["plugin_root"] -or
      [string]::IsNullOrWhiteSpace([string]$RuntimeState.plugin_root)) {
    return $null
  }
  try {
    $recordedPluginRoot = [System.IO.Path]::GetFullPath([string]$RuntimeState.plugin_root)
    $currentPluginRoot = [System.IO.Path]::GetFullPath($PluginRoot)
  } catch {
    return $null
  }
  if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($recordedPluginRoot, $currentPluginRoot)) { return $null }

  $currentContract = Resolve-LocalMcpContractFingerprint $PluginRoot
  $expectedContract = Normalize-McpContractFingerprint ([string]$RuntimeState.backend.expected_contract_fingerprint)
  $actualContract = Normalize-McpContractFingerprint ([string]$RuntimeState.backend.contract_fingerprint)
  if ([string]::IsNullOrWhiteSpace($currentContract) -or
      -not [System.StringComparer]::OrdinalIgnoreCase.Equals($currentContract, $expectedContract) -or
      -not [System.StringComparer]::OrdinalIgnoreCase.Equals($currentContract, $actualContract)) {
    return $null
  }

  $backendUrl = [string]$RuntimeState.backend.url
  $dashboardOrigin = [string]$RuntimeState.frontend.origin
  if ([string]::IsNullOrWhiteSpace($backendUrl)) {
    return $null
  }
  $backendUrl = $backendUrl.TrimEnd("/")
  $dashboardOrigin = if ([string]::IsNullOrWhiteSpace($dashboardOrigin)) { $null } else { $dashboardOrigin.TrimEnd("/") }
  try {
    Assert-LoopbackHttpOrigin $backendUrl "recorded Symphony++ backend"
    if ($dashboardOrigin) { Assert-LoopbackHttpOrigin $dashboardOrigin "recorded Symphony++ dashboard" }
  } catch {
    return $null
  }

  if (($BackendPortExplicit -and $BackendPort -gt 0 -and (Get-PortFromOrigin $backendUrl) -ne $BackendPort) -or
      ($DashboardPortExplicit -and $DashboardPort -gt 0 -and (-not $dashboardOrigin -or (Get-PortFromOrigin $dashboardOrigin) -ne $DashboardPort)) -or
      (-not [string]::IsNullOrWhiteSpace($ConfiguredBackendUrl) -and
       -not (Test-EndpointMatches $backendUrl $ConfiguredBackendUrl)) -or
      (-not [string]::IsNullOrWhiteSpace($ConfiguredDashboardOrigin) -and (-not $dashboardOrigin -or
       -not (Test-EndpointMatches $dashboardOrigin $ConfiguredDashboardOrigin)))) {
    return $null
  }

  $runtimeKey = New-RuntimeKey $backendUrl $dashboardOrigin $actualContract
  if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals((Get-RuntimeStateKey $RuntimeState), $runtimeKey)) {
    return $null
  }

  return [pscustomobject]@{
    runtime_key = $runtimeKey
    source_revision = [string]$RuntimeState.backend.source_revision
    contract_fingerprint = $actualContract
  }
}

function Resolve-FastAttachRuntimePlan {
  param(
    $RuntimeState,
    [string]$ExpectedSourceRevision,
    [string]$ExpectedContractFingerprint,
    [int]$PreferredBackendPort,
    [int]$PreferredDashboardPort,
    [bool]$BackendPortExplicit,
    [bool]$DashboardPortExplicit,
    [string]$ConfiguredBackendUrl,
    [string]$ConfiguredDashboardOrigin,
    [object]$BackendHealthOverride = $null,
    [object]$DashboardHealthyOverride = $null,
    [object]$DashboardProxyMatchesOverride = $null
  )

  if ($BackendPortExplicit -or $DashboardPortExplicit -or
      -not [string]::IsNullOrWhiteSpace($ConfiguredBackendUrl) -or
      -not [string]::IsNullOrWhiteSpace($ConfiguredDashboardOrigin)) {
    return $null
  }

  if ($null -eq $RuntimeState -or $null -eq $RuntimeState.backend -or $null -eq $RuntimeState.frontend) {
    return $null
  }

  $artifactStaticRuntime = [string]$RuntimeState.runtime_mode -eq "artifact" -and
    $RuntimeState.backend.managed -eq $true -and
    [string]$RuntimeState.frontend.status -eq "artifact_static" -and
    (Test-EndpointMatches ([string]$RuntimeState.backend.url) ([string]$RuntimeState.frontend.origin))
  $managedRuntime = $RuntimeState.backend.managed -eq $true -and $RuntimeState.frontend.managed -eq $true
  $headlessManagedRuntime = $RuntimeState.backend.managed -eq $true -and
    [string]::IsNullOrWhiteSpace([string]$RuntimeState.frontend.origin) -and
    [string]$RuntimeState.frontend.status -match "^(disabled|failed)"
  $externalLoopbackRuntime = Test-RuntimeStateExternalLoopback $RuntimeState
  if (-not $managedRuntime -and -not $headlessManagedRuntime -and -not $artifactStaticRuntime -and -not $externalLoopbackRuntime) {
    return $null
  }

  $backendUrl = [string]$RuntimeState.backend.url
  $dashboardOrigin = [string]$RuntimeState.frontend.origin
  if ([string]::IsNullOrWhiteSpace($backendUrl) -or (-not $headlessManagedRuntime -and [string]::IsNullOrWhiteSpace($dashboardOrigin))) {
    return $null
  }

  $backendUrl = $backendUrl.TrimEnd("/")
  $dashboardOrigin = if ([string]::IsNullOrWhiteSpace($dashboardOrigin)) { $null } else { $dashboardOrigin.TrimEnd("/") }
  try {
    Assert-LoopbackHttpOrigin $backendUrl "recorded Symphony++ backend"
    if (-not $headlessManagedRuntime) { Assert-LoopbackHttpOrigin $dashboardOrigin "recorded Symphony++ dashboard" }
  } catch {
    return $null
  }

  if (-not (Test-PortSelectionAllowsReuse $PreferredBackendPort $backendUrl $true) -or
      (-not $headlessManagedRuntime -and -not (Test-PortSelectionAllowsReuse $PreferredDashboardPort $dashboardOrigin $true))) {
    return $null
  }

  $backendHealth = if ($null -ne $BackendHealthOverride) { $BackendHealthOverride } else { Get-SymppBackendHealthWithRetry $backendUrl 4 500 (-not $headlessManagedRuntime) }
  if (-not (Test-BackendLaunchCompatible $backendHealth $ExpectedContractFingerprint)) {
    return $null
  }
  Write-CompatibleSourceMismatchDiagnostic $backendUrl $backendHealth $ExpectedSourceRevision

  $dashboardSharesBackend = Test-EndpointMatches $backendUrl $dashboardOrigin
  $dashboardHealthy = if ($headlessManagedRuntime -or $dashboardSharesBackend) { $true } elseif ($null -ne $DashboardHealthyOverride) { [bool]$DashboardHealthyOverride } else { Test-HealthySymppDashboard $dashboardOrigin }
  if (-not $dashboardHealthy) {
    return $null
  }

  $dashboardProxyMatches =
    if ($headlessManagedRuntime -or $dashboardSharesBackend) {
      $true
    } elseif ($null -ne $DashboardProxyMatchesOverride) {
      [bool]$DashboardProxyMatchesOverride
    } else {
      Test-SymppDashboardMcpProxyMatches $dashboardOrigin $ExpectedContractFingerprint
    }
  if (-not $dashboardProxyMatches) {
    return $null
  }

  $planStatus = if ($managedRuntime -or $headlessManagedRuntime -or $artifactStaticRuntime) { "fast_attach" } else { "external_loopback" }
  $backendPlan = New-ReusedBackendPlan $planStatus $backendUrl $backendHealth ($RuntimeState.backend.managed -eq $true) $RuntimeState.backend.pid
  $dashboardPlan = if ($headlessManagedRuntime) { New-DisabledDashboardPlan ([string]$RuntimeState.frontend.status) ([string]$RuntimeState.frontend.error) } else { New-ReusedDashboardPlan $planStatus $dashboardOrigin ($RuntimeState.frontend.managed -eq $true) $RuntimeState.frontend.pid }
  $runtimeKey = New-RuntimeKey $backendPlan.url $dashboardPlan.origin $backendHealth.contract_fingerprint
  if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals((Get-RuntimeStateKey $RuntimeState), $runtimeKey)) {
    return $null
  }

  return [pscustomobject]@{
    backend_plan = $backendPlan
    dashboard_plan = $dashboardPlan
    runtime_key = $runtimeKey
  }
}

function Invoke-PowerShellFallbackRuntimeRecovery {
  param(
    [string]$RuntimeFile, [string]$PluginRoot, [int]$BackendPort, [int]$DashboardPort,
    [bool]$BackendPortExplicit, [bool]$DashboardPortExplicit,
    [string]$ConfiguredBackendUrl, [string]$ConfiguredDashboardOrigin, [string]$LauncherPath,
    $StdinReadState, [bool]$ActiveRequest = $false
  )

  $previousOwnerPid = $env:SYMPP_BACKEND_OWNER_PID
  try {
    $env:SYMPP_BACKEND_OWNER_PID = [string]$PID
    $powerShell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $preparationArgs = @{
      FilePath = $powerShell
      ArgumentList = (Join-ProcessArgumentList @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $LauncherPath, "-PrepareRuntimeOnly"))
      RedirectStandardOutput = (Join-Path (Resolve-LogDir) "fallback-recovery-$PID.out.log")
      PassThru = $true
    }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { $preparationArgs["WindowStyle"] = "Hidden" }
    $preparation = Start-Process @preparationArgs
    while (-not $preparation.WaitForExit(100)) {
      $stdinClosed = $null -ne $StdinReadState -and (Update-McpStdinReadState $StdinReadState)
      if ($stdinClosed -and -not $ActiveRequest -and $StdinReadState.buffered_lines.Count -eq 0) {
        if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
          & taskkill.exe /PID $preparation.Id /T /F 2>$null | Out-Null
        } else {
          Stop-Process -Id $preparation.Id -Force -ErrorAction SilentlyContinue
        }
        throw [System.OperationCanceledException]::new("STDIO closed during fallback backend recovery.")
      }
    }
  } finally {
    $env:SYMPP_BACKEND_OWNER_PID = $previousOwnerPid
  }
  Write-SymppLauncherTrace "fallback_recovery_prepared"

  try {
    $state = Read-RuntimeState $RuntimeFile
    $identity = Resolve-LocalWarmAttachIdentity $state $PluginRoot $BackendPort $DashboardPort $BackendPortExplicit $DashboardPortExplicit $ConfiguredBackendUrl $ConfiguredDashboardOrigin
    if ($null -eq $identity) { throw "Replacement runtime identity was unavailable." }
    Write-SymppLauncherTrace "fallback_recovery_identity"
    $plan = Resolve-FastAttachRuntimePlan $state $identity.source_revision $identity.contract_fingerprint 0 0 $false $false $null $null
    if ($null -eq $plan) { throw "Replacement runtime was not healthy." }
    Write-SymppLauncherTrace "fallback_recovery_plan"
    return $plan
  } catch {
    $failedKey = Get-RuntimeStateKey (Read-RuntimeState $RuntimeFile)
    if (-not [string]::IsNullOrWhiteSpace($failedKey)) { Stop-ManagedServersIfUnused $RuntimeFile $failedKey }
    throw
  }
}

function Invoke-WarmAttachFromRuntimeState {
  param(
    [string]$RuntimeFile,
    [string]$PluginRoot,
    [int]$BackendPort,
    [int]$DashboardPort,
    [bool]$BackendPortExplicit,
    [bool]$DashboardPortExplicit,
    [string]$ConfiguredBackendUrl,
    [string]$ConfiguredDashboardOrigin,
    [int]$BridgeTimeout,
    [int]$ClientHeartbeatInterval
  )

  $runtimeState = Read-RuntimeState $RuntimeFile
  $identity = Resolve-LocalWarmAttachIdentity $runtimeState $PluginRoot $BackendPort $DashboardPort $BackendPortExplicit $DashboardPortExplicit $ConfiguredBackendUrl $ConfiguredDashboardOrigin
  if ($null -eq $identity) {
    return $false
  }

  $recordedHealth = New-SymppBackendHealth $true $identity.source_revision "recorded" $true $true $true "ok" $identity.contract_fingerprint
  $provisionalPlan = Resolve-FastAttachRuntimePlan $runtimeState $identity.source_revision $identity.contract_fingerprint 0 0 $false $false $null $null $recordedHealth $true $true
  if ($null -eq $provisionalPlan) {
    return $false
  }

  # Publish before probing so a concurrent last-detach cleanup sees this client.
  $leasePath = New-BridgeLease $RuntimeFile $provisionalPlan.backend_plan $provisionalPlan.dashboard_plan $provisionalPlan.runtime_key
  $leaseState = [pscustomobject]@{ path = $leasePath; runtime_key = $identity.runtime_key }
  $attached = $false
  try {
    $confirmedState = Read-RuntimeState $RuntimeFile
    $confirmedIdentity = Resolve-LocalWarmAttachIdentity $confirmedState $PluginRoot $BackendPort $DashboardPort $BackendPortExplicit $DashboardPortExplicit $ConfiguredBackendUrl $ConfiguredDashboardOrigin
    if ($null -eq $confirmedIdentity -or
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals($identity.runtime_key, $confirmedIdentity.runtime_key)) {
      return $false
    }

    $confirmedPlan = Resolve-FastAttachRuntimePlan $confirmedState $confirmedIdentity.source_revision $confirmedIdentity.contract_fingerprint 0 0 $false $false $null $null
    if ($null -eq $confirmedPlan) {
      return $false
    }

    $attached = $true
    Write-Diagnostic "Symphony++ MCP bridge attached: backend=$($confirmedPlan.backend_plan.url) dashboard=$($confirmedPlan.dashboard_plan.url) runtime=$RuntimeFile"
    $fallbackRecovery = { param($stdinReadState, $activeRequest)
      $plan = Invoke-PowerShellFallbackRuntimeRecovery $RuntimeFile $PluginRoot $BackendPort $DashboardPort $BackendPortExplicit $DashboardPortExplicit $ConfiguredBackendUrl $ConfiguredDashboardOrigin $PSCommandPath $stdinReadState $activeRequest
      if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($leaseState.runtime_key, $plan.runtime_key)) {
        $replacementLeasePath = New-BridgeLease $RuntimeFile $plan.backend_plan $plan.dashboard_plan $plan.runtime_key
        Remove-BridgeLease $leaseState.path
        $leaseState.path = $replacementLeasePath; $leaseState.runtime_key = $plan.runtime_key
      }
      return [pscustomobject]@{ mcp_url = $plan.backend_plan.mcp_url }
    }
    Invoke-HttpMcpBridge $confirmedPlan.backend_plan.mcp_url $BridgeTimeout (New-McpClientLeaseId) $ClientHeartbeatInterval $fallbackRecovery
    return $true
  } finally {
    Remove-BridgeLease $leaseState.path
    if ($attached) {
      Stop-ManagedServersIfUnused $RuntimeFile $leaseState.runtime_key
    }
  }
}

function Resolve-DashboardPlan([int]$PreferredPort, [string]$ConfiguredOrigin, [string]$BackendUrl, [string]$BackendSourceRevision, $RuntimeState, [bool]$EnforcePreferredPort, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint, [bool]$AllowRecordedRuntimeReuse, [bool]$BackendWillStart) {
  if (-not [string]::IsNullOrWhiteSpace($ConfiguredOrigin)) {
    $origin = $ConfiguredOrigin.TrimEnd("/")
    return New-ReusedDashboardPlan "external_override" $origin $false $null
  }

  if ($AllowRecordedRuntimeReuse -and $null -ne $RuntimeState -and $null -ne $RuntimeState.frontend) {
    $runtimeBackendUrl = [string]$RuntimeState.backend.url
    $runtimeOrigin = [string]$RuntimeState.frontend.origin
    if (-not [string]::IsNullOrWhiteSpace($runtimeBackendUrl) -and
        $runtimeBackendUrl.TrimEnd("/") -eq $BackendUrl.TrimEnd("/")) {
      $runtimeManaged = $RuntimeState.frontend.managed -eq $true
      $portAllowed = Test-PortSelectionAllowsReuse $PreferredPort $runtimeOrigin $EnforcePreferredPort
      $runtimeHealthy = -not [string]::IsNullOrWhiteSpace($runtimeOrigin) -and (Test-HealthySymppDashboard $runtimeOrigin)
      $proxyMatches = $BackendWillStart -or ($runtimeHealthy -and (Test-SymppDashboardMcpProxyMatches $runtimeOrigin $ExpectedContractFingerprint))
      if ($runtimeManaged -and $portAllowed -and $runtimeHealthy -and $proxyMatches) {
        return New-ReusedDashboardPlan "reused" $runtimeOrigin ($RuntimeState.frontend.managed -eq $true) $RuntimeState.frontend.pid
      }
      if ($runtimeHealthy) {
        if (-not $runtimeManaged) {
          Write-Diagnostic "Ignoring recorded external dashboard $($runtimeOrigin.TrimEnd('/')) for implicit reuse. Set SYMPP_DASHBOARD_ORIGIN=$($runtimeOrigin.TrimEnd('/')) to reuse it explicitly."
        } elseif (-not $portAllowed) {
          Write-Diagnostic "Ignoring healthy runtime dashboard $($runtimeOrigin.TrimEnd('/')) because SYMPP_DASHBOARD_PORT requests $PreferredPort. Set SYMPP_DASHBOARD_ORIGIN=$($runtimeOrigin.TrimEnd('/')) to reuse it explicitly."
        } elseif (-not $proxyMatches) {
          Write-Diagnostic "Ignoring healthy runtime dashboard $($runtimeOrigin.TrimEnd('/')) because its MCP proxy does not match expected MCP contract $(Format-McpContractFingerprintForDiagnostic $ExpectedContractFingerprint). Expected source revision remains $(Format-SourceRevisionForDiagnostic $ExpectedSourceRevision)."
        }
      }
    } elseif (-not [string]::IsNullOrWhiteSpace($runtimeOrigin) -and (Test-HealthySymppDashboard $runtimeOrigin)) {
      Write-Diagnostic "Ignoring healthy runtime dashboard $($runtimeOrigin.TrimEnd('/')) because it was recorded for backend $($runtimeBackendUrl.TrimEnd('/')), not $($BackendUrl.TrimEnd('/'))."
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceRevision) -and
      -not (Test-SourceRevisionEquals $BackendSourceRevision $ExpectedSourceRevision)) {
    Write-Diagnostic "Not starting Symphony++ dashboard assets from source $(Format-SourceRevisionForDiagnostic $ExpectedSourceRevision) against compatible backend source $(Format-SourceRevisionForDiagnostic $BackendSourceRevision). MCP bridge will attach backend-only; restart the singleton or set SYMPP_DASHBOARD_ORIGIN to use an operator-owned dashboard."
    return New-DisabledDashboardPlan "disabled_source_drift" "backend_source_revision_mismatch"
  }

  $selectedBackendPort = Get-PortFromOrigin $BackendUrl
  $avoid = if ($selectedBackendPort -gt 0) { @([int]$selectedBackendPort) } else { @() }
  $selectedPort = Select-AvailablePort $PreferredPort $avoid
  $origin = "http://127.0.0.1:$selectedPort"
  return [pscustomobject]@{
    status = "starting"
    origin = $origin
    url = "$origin$BoardPath"
    port = $selectedPort
    should_start = $true
    reused = $false
    managed = $true
    pid = $null
  }
}

function Resolve-SymppLauncherRuntimeInputs([string]$PluginRoot, [string]$BridgeMode, [bool]$Validate, [string]$ExpectedContractFingerprint = $null, [string]$ExpectedSourceRevision = $null) {
  if ([string]::IsNullOrWhiteSpace($ExpectedContractFingerprint)) {
    $ExpectedContractFingerprint = Resolve-ExpectedMcpContractFingerprint $PluginRoot
  }
  if ([string]::IsNullOrWhiteSpace($ExpectedContractFingerprint)) {
    throw "Symphony++ MCP launcher expected MCP contract fingerprint could not be resolved from contract JSON or runtime artifact manifest."
  }
  if ([string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) {
    $ExpectedSourceRevision = Resolve-ExpectedSourceRevision $PluginRoot
  }
  $artifactRuntimeAllowed = if ($BridgeMode -eq "direct_stdio") { $false } else { Test-ArtifactRuntimeAllowed $PluginRoot }
  $repoRoot = $null
  $explicitRepoRoot = -not [string]::IsNullOrWhiteSpace($env:SYMPP_REPO_ROOT)
  $sourceFallbackAllowed = Test-SourceFallbackAllowed $PluginRoot
  try {
    $repoRoot = Resolve-RepoRoot
    $sourceFallbackAllowed = $sourceFallbackAllowed -or ($explicitRepoRoot -and (Test-SymphonySourceRoot $repoRoot))
  } catch {
    if ($explicitRepoRoot) { throw }
  }

  $artifactProbe = $null
  $artifactProbeError = $null
  try {
    $artifactProbe = Resolve-SymppArtifactProbe $PluginRoot $ExpectedSourceRevision $ExpectedContractFingerprint $artifactRuntimeAllowed $sourceFallbackAllowed -ValidateOnly -PrepareArtifact:$Validate
  } catch { $artifactProbeError = $_ }
  if ($null -ne $artifactProbeError -or $null -eq $artifactProbe -or @("ready", "artifact_selected") -notcontains $artifactProbe.status) {
    try {
      $repoRoot = Resolve-RepoRoot
      $sourceFallbackAllowed = $sourceFallbackAllowed -or ($explicitRepoRoot -and (Test-SymphonySourceRoot $repoRoot))
      if ($null -ne $artifactProbeError -and $sourceFallbackAllowed) {
        $artifactProbe = Resolve-SymppArtifactProbe $PluginRoot $ExpectedSourceRevision $ExpectedContractFingerprint $artifactRuntimeAllowed $sourceFallbackAllowed -ValidateOnly -PrepareArtifact:$Validate
        $artifactProbeError = $null
      }
    } catch {
      if ($null -ne $artifactProbeError) { throw $artifactProbeError }
      if ($sourceFallbackAllowed) { throw }
    }
  }
  if ($null -ne $artifactProbeError) { throw $artifactProbeError }

  $artifactValidationLaunchable = @("ready", "artifact_selected") -contains $artifactProbe.status
  if (-not $artifactValidationLaunchable -and $sourceFallbackAllowed -and [string]::IsNullOrWhiteSpace($repoRoot)) {
    $repoRoot = Resolve-RepoRoot
  }
  $elixirDir = if ([string]::IsNullOrWhiteSpace($repoRoot)) { $null } else { Join-Path $repoRoot "elixir" }
  $assetsDir = if ([string]::IsNullOrWhiteSpace($elixirDir)) { $null } else { Join-Path $elixirDir "assets" }
  $mix = if ([string]::IsNullOrWhiteSpace($env:SYMPP_MIX)) { "mix" } else { $env:SYMPP_MIX }
  $mise = if ([string]::IsNullOrWhiteSpace($env:SYMPP_MISE)) { "mise" } else { $env:SYMPP_MISE }
  $defaultLauncher = if ($sourceFallbackAllowed -and $elixirDir -and (Test-Path -LiteralPath $elixirDir)) { Resolve-SymppDefaultLauncher $elixirDir $mise } else { "direct" }
  $launcher = Get-EnvMode "SYMPP_LAUNCHER" $defaultLauncher @("direct", "mise")
  Set-SymppSourceRevisionEnvironment $ExpectedSourceRevision
  Set-SymppWindowsNativeTargetEnvironment
  $defaultMixBuildRoot = if ($sourceFallbackAllowed -and $elixirDir -and (Test-Path -LiteralPath $elixirDir)) { Resolve-SymppDefaultMixBuildRoot $repoRoot $launcher "mcp" $PluginRoot } else { $null }
  if (-not $Validate -and $sourceFallbackAllowed -and $elixirDir -and (Test-Path -LiteralPath $elixirDir)) {
    Set-SymppDefaultMixBuildRoot $repoRoot $launcher "mcp" $PluginRoot
  }

  if ($artifactValidationLaunchable) {
    $artifactLaunchBlockReason = if ($BridgeMode -eq "direct_stdio") { "direct_stdio_unsupported" } elseif (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) { "database_unsupported" } else { $null }
    if ($artifactLaunchBlockReason) {
      Write-Diagnostic "artifact_skipped: verified artifact runtime is not launchable in this configuration. detail=$artifactLaunchBlockReason"
      $artifactValidationLaunchable = $false
      $artifactProbe = [pscustomobject]@{ status = "artifact_unavailable"; detail = $artifactLaunchBlockReason; platform = $artifactProbe.platform; manifest_path = $artifactProbe.manifest_path; runtime = $null }
    }
  }
  if (-not $artifactValidationLaunchable -and $sourceFallbackAllowed -and [string]::IsNullOrWhiteSpace($ExpectedSourceRevision) -and $repoRoot) {
    $ExpectedSourceRevision = Resolve-SymppSourceRevision $repoRoot $PluginRoot
  }
  return [pscustomobject]@{
    expected_contract_fingerprint = $ExpectedContractFingerprint; expected_source_revision = $ExpectedSourceRevision
    artifact_runtime_allowed = $artifactRuntimeAllowed; source_fallback_allowed = $sourceFallbackAllowed
    artifact_probe = $artifactProbe; artifact_validation_launchable = $artifactValidationLaunchable
    repo_root = $repoRoot; elixir_dir = $elixirDir; assets_dir = $assetsDir
    mix = $mix; mise = $mise; launcher = $launcher; default_mix_build_root = $defaultMixBuildRoot
    log_dir = Resolve-LogDir
  }
}

if ($Help) {
  Write-Usage
  exit 0
}

if (-not [string]::IsNullOrWhiteSpace($CleanupRuntimeKey)) {
  Stop-ManagedServersIfUnused (Resolve-RuntimeFile) $CleanupRuntimeKey
  exit 0
}
if ($CleanupPreparedRuntime) {
  $cleanupRuntimeFile = Resolve-RuntimeFile
  $cleanupState = Read-RuntimeState $cleanupRuntimeFile
  if ($null -ne $cleanupState) {
    $cleanupKey = Get-RuntimeStateKey $cleanupState
    if (-not [string]::IsNullOrWhiteSpace($cleanupKey)) {
      Stop-ManagedServersIfUnused $cleanupRuntimeFile $cleanupKey
    }
  }
  exit 0
}

$pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
Write-SymppLauncherTrace "powershell_config_begin"
$runtimeFile = Resolve-RuntimeFile
$bridgeMode = Get-EnvMode "SYMPP_MCP_BRIDGE_MODE" "http" @("http", "direct_stdio")
if (-not $ValidateOnly -and -not $PrepareRuntimeOnly -and $bridgeMode -eq "http" -and [string]::IsNullOrWhiteSpace($env:SYMPP_REPO_ROOT)) {
  $warmBackendPortExplicit = -not [string]::IsNullOrWhiteSpace($env:SYMPP_BACKEND_PORT)
  $warmDashboardPortExplicit = -not [string]::IsNullOrWhiteSpace($env:SYMPP_DASHBOARD_PORT)
  $warmBackendPort = Get-EnvInteger "SYMPP_BACKEND_PORT" $DefaultBackendPort 0 65535
  $warmDashboardPort = Get-EnvInteger "SYMPP_DASHBOARD_PORT" $DefaultDashboardPort 0 65535
  $warmBridgeTimeout = Get-EnvInteger "SYMPP_MCP_HTTP_TIMEOUT_SEC" 300 1 3600
  $warmHeartbeatInterval = Get-EnvInteger "SYMPP_MCP_CLIENT_HEARTBEAT_SEC" 300 5 540
  if (Invoke-WarmAttachFromRuntimeState $runtimeFile $pluginRoot $warmBackendPort $warmDashboardPort $warmBackendPortExplicit $warmDashboardPortExplicit $env:SYMPP_BACKEND_URL $env:SYMPP_DASHBOARD_ORIGIN $warmBridgeTimeout $warmHeartbeatInterval) {
    exit 0
  }
}

$installedHttpCold = -not $ValidateOnly -and $bridgeMode -eq "http" -and
  [string]::IsNullOrWhiteSpace($env:SYMPP_REPO_ROOT) -and (Test-SymppInstalledMarketplacePluginRoot $pluginRoot)
$installedIdentity = $null
$runtimeInputs = if ($installedHttpCold) { $null } else { Resolve-SymppLauncherRuntimeInputs $pluginRoot $bridgeMode ([bool]$ValidateOnly) }
$expectedContractFingerprint = if ($installedHttpCold) { $null } else { [string]$runtimeInputs.expected_contract_fingerprint }
$expectedSourceRevision = if ($installedHttpCold) { $null } else { [string]$runtimeInputs.expected_source_revision }
$artifactRuntimeAllowed = if ($installedHttpCold) { $true } else { [bool]$runtimeInputs.artifact_runtime_allowed }
$artifactRuntime = $null
$runtimeMode = "source"
$repoRoot = if ($runtimeInputs) { $runtimeInputs.repo_root } else { $null }
$sourceFallbackAllowed = if ($runtimeInputs) { [bool]$runtimeInputs.source_fallback_allowed } else { $false }
$artifactProbe = if ($runtimeInputs) { $runtimeInputs.artifact_probe } else { [pscustomobject]@{ status = "not_probed"; detail = "cold_leader_pending"; runtime = $null } }
$artifactValidationLaunchable = if ($runtimeInputs) { [bool]$runtimeInputs.artifact_validation_launchable } else { $false }
$elixirDir = if ($runtimeInputs) { $runtimeInputs.elixir_dir } else { $null }
$assetsDir = if ($runtimeInputs) { $runtimeInputs.assets_dir } else { $null }
$mix = if ($runtimeInputs) { $runtimeInputs.mix } else { if ([string]::IsNullOrWhiteSpace($env:SYMPP_MIX)) { "mix" } else { $env:SYMPP_MIX } }
$mise = if ($runtimeInputs) { $runtimeInputs.mise } else { if ([string]::IsNullOrWhiteSpace($env:SYMPP_MISE)) { "mise" } else { $env:SYMPP_MISE } }
$launcher = if ($runtimeInputs) { $runtimeInputs.launcher } else { "direct" }
$defaultMixBuildRoot = if ($runtimeInputs) { $runtimeInputs.default_mix_build_root } else { $null }
$logDir = if ($runtimeInputs) { $runtimeInputs.log_dir } else { Resolve-LogDir }

if ($ValidateOnly) {
  $validationRuntimeMode = if ($artifactValidationLaunchable) { "artifact" } elseif ($sourceFallbackAllowed) { "source" } else { "blocked" }
  if ($validationRuntimeMode -eq "blocked") {
    throw "Symphony++ MCP launcher validation failed: no verified runtime artifact is launchable and source fallback is unavailable. artifactStatus=$($artifactProbe.status) artifactDetail=$($artifactProbe.detail)."
  }

  if ($sourceFallbackAllowed -and -not $artifactValidationLaunchable) {
    Assert-LauncherAvailable $launcher $mix $mise
    Push-Location -LiteralPath $elixirDir
    try {
      $validationExitCode = Test-LauncherVersion $launcher $mix $mise
    } finally {
      Pop-Location
    }
    if ($validationExitCode -ne 0) {
      throw "Selected Symphony++ MCP launcher failed validation with exit code $validationExitCode."
    }
  }

  Write-Host "Symphony++ MCP launcher validation passed."
  Write-Host "  repoRoot: $(if ([string]::IsNullOrWhiteSpace($repoRoot)) { "artifact-only" } else { $repoRoot })"
  Write-Host "  elixirDir: $(if ([string]::IsNullOrWhiteSpace($elixirDir)) { "not_required" } else { $elixirDir })"
  Write-Host "  assetsDir: $(if ([string]::IsNullOrWhiteSpace($assetsDir)) { "not_required" } else { $assetsDir })"
  Write-Host "  runtimeMode: $validationRuntimeMode"
  Write-Host "  artifactStatus: $($artifactProbe.status)"
  Write-Host "  artifactDetail: $($artifactProbe.detail)"
  if ($artifactProbe.manifest_path) {
    Write-Host "  artifactManifest: $($artifactProbe.manifest_path)"
  }
  if ($artifactProbe.cache_root) {
    Write-Host "  artifactCache: $($artifactProbe.cache_root)"
  }
  Write-Host "  sourceFallback: $(if ($sourceFallbackAllowed) { "enabled" } else { "disabled" })"
  Write-Host "  launcher: $launcher"
  if ($defaultMixBuildRoot) {
    Write-Host "  mixBuildRoot: $defaultMixBuildRoot"
  }
  Write-Host "  runtimeFile: $runtimeFile"
  Write-Host "  logDir: $logDir"
  if (Test-NpmAvailable) {
    Write-Host "  dashboardLauncher: available"
  } else {
    Write-Host "  dashboardLauncher: unavailable (MCP bridge can still start; dashboard autostart will be recorded as failed)"
  }
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    Write-Host "  database: $([System.IO.Path]::GetFullPath($env:SYMPP_DATABASE))"
  }
  exit 0
}

$elixirSetupTimeout = Get-EnvInteger "SYMPP_ELIXIR_SETUP_TIMEOUT_SEC" 300 1 1800
if ($bridgeMode -eq "direct_stdio") {
  if (-not $sourceFallbackAllowed) {
    throw "artifact_direct_stdio_unsupported: verified artifact runtimes start the HTTP backend wrapper; direct stdio requires explicit source fallback."
  }
  if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    $repoRoot = Resolve-RepoRoot
    $elixirDir = Join-Path $repoRoot "elixir"
    $assetsDir = Join-Path $elixirDir "assets"
  }
  if ([string]::IsNullOrWhiteSpace($expectedSourceRevision)) {
    $expectedSourceRevision = Resolve-SymppSourceRevision $repoRoot $pluginRoot
    Set-SymppSourceRevisionEnvironment $expectedSourceRevision
  }
  $runtimeMode = "source"
  if ($runtimeMode -eq "source") {
    [void](Initialize-ElixirRuntime $elixirDir $launcher $mix $mise $logDir $elixirSetupTimeout)
  }
  Invoke-DirectStdioMcp $repoRoot $elixirDir $launcher $mix $mise $artifactRuntime
  exit 0
}

$autostartServers = -not (Test-EnvDisabled "SYMPP_AUTOSTART_SERVERS")
$autostartBackend = $autostartServers -and -not (Test-EnvDisabled "SYMPP_AUTOSTART_BACKEND")
$autostartFrontend = $autostartServers -and -not (Test-EnvDisabled "SYMPP_AUTOSTART_FRONTEND")
$backendPortExplicit = -not [string]::IsNullOrWhiteSpace($env:SYMPP_BACKEND_PORT)
$dashboardPortExplicit = -not [string]::IsNullOrWhiteSpace($env:SYMPP_DASHBOARD_PORT)
$backendPort = Get-EnvInteger "SYMPP_BACKEND_PORT" $DefaultBackendPort 0 65535
$dashboardPort = Get-EnvInteger "SYMPP_DASHBOARD_PORT" $DefaultDashboardPort 0 65535
$backendTimeout = Get-EnvInteger "SYMPP_BACKEND_STARTUP_TIMEOUT_SEC" 60 1 600
$backendPortReleaseTimeout = Get-EnvInteger "SYMPP_BACKEND_PORT_RELEASE_TIMEOUT_SEC" 15 0 600
$frontendInstallTimeout = Get-EnvInteger "SYMPP_FRONTEND_INSTALL_TIMEOUT_SEC" 180 1 1800
$frontendTimeout = Get-EnvInteger "SYMPP_FRONTEND_STARTUP_TIMEOUT_SEC" 20 1 600
$bridgeTimeout = Get-EnvInteger "SYMPP_MCP_HTTP_TIMEOUT_SEC" 300 1 3600
$clientHeartbeatInterval = Get-EnvInteger "SYMPP_MCP_CLIENT_HEARTBEAT_SEC" 300 5 540
$startupLockMinimum = 30
if ($autostartBackend) {
  $startupLockMinimum += ($elixirSetupTimeout * 2)
  $startupLockMinimum += $backendTimeout
  $startupLockMinimum += $backendPortReleaseTimeout
}
if ($autostartFrontend) {
  $startupLockMinimum += $frontendInstallTimeout
  $startupLockMinimum += $frontendTimeout
}
$startupLockDefault = [Math]::Min(1800, [Math]::Max(120, $startupLockMinimum))
$startupLockTimeout = Get-EnvInteger "SYMPP_STARTUP_LOCK_TIMEOUT_SEC" $startupLockDefault 1 1800
if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_STARTUP_LOCK_TIMEOUT_SEC) -and $startupLockTimeout -lt $startupLockMinimum) {
  throw "SYMPP_STARTUP_LOCK_TIMEOUT_SEC must be at least $startupLockMinimum for the configured backend/frontend startup waits."
}
$coldStartTimeout = Get-EnvInteger "SYMPP_COLD_START_TIMEOUT_SEC" 300 30 330
$coldStartDeadline = [DateTime]::UtcNow.AddSeconds($coldStartTimeout)
$publicationControls = New-SymppPublicationControls $backendPort $dashboardPort $backendPortExplicit $dashboardPortExplicit $env:SYMPP_BACKEND_URL $env:SYMPP_DASHBOARD_ORIGIN

$backendLaunch = $null
$frontendLaunch = $null
$frontendInstall = $null
$frontendError = $null
$backendPlan = $null
$dashboardPlan = $null
$bridgeLeasePath = $null
$runtimeKey = $null
$supersededStates = @()

$startupLock = $null
Write-SymppLauncherTrace "powershell_config_end"
if ($installedHttpCold) {
  Start-SymppColdStartDeadline $coldStartTimeout
  $requireColdRepair = $false
  while ($null -eq $startupLock) {
    $leadership = Enter-SymppColdLeadership $runtimeFile $pluginRoot $installedIdentity $publicationControls $coldStartDeadline $requireColdRepair
    if ($leadership.leader) {
      $startupLock = $leadership.lock
      $installedIdentity = Resolve-SymppInstalledMarketplaceIdentity $pluginRoot
      $expectedContractFingerprint = [string]$installedIdentity.contract_fingerprint
      $expectedSourceRevision = [string]$installedIdentity.revision
      break
    }
    if ($PrepareRuntimeOnly) {
      $installedIdentity = Resolve-SymppInstalledMarketplaceIdentity $pluginRoot -ReadOnly
      if (Test-SymppPublishedRuntimeReadyLocally (Read-RuntimeState $runtimeFile) $pluginRoot $installedIdentity $publicationControls) { exit 0 }
      $requireColdRepair = $true
      continue
    }
    if (Invoke-WarmAttachFromRuntimeState $runtimeFile $pluginRoot $backendPort $dashboardPort $backendPortExplicit $dashboardPortExplicit $env:SYMPP_BACKEND_URL $env:SYMPP_DASHBOARD_ORIGIN $bridgeTimeout $clientHeartbeatInterval) { exit 0 }
    $requireColdRepair = $true
  }
} else {
  $startupLock = Enter-FileLock (Resolve-StartupLockFile $runtimeFile) $startupLockTimeout
}
try {
  $runtimeState = Read-RuntimeState $runtimeFile
  $recoveredBackendPlan = $null
  if ($installedHttpCold -and $null -ne $runtimeState -and $null -ne $runtimeState.publication -and [string]$runtimeState.publication.status -eq "starting") {
    if (Test-SymppStartingBackendOwned $runtimeState $installedIdentity $publicationControls) {
      Write-RuntimeState $runtimeFile $runtimeState
      $recoveryTimeout = Get-SymppRemainingTimeoutSec $backendTimeout "owned backend recovery"
      $recoveryHealth = $null
      $recoveryListenerPid = $null
      if (Wait-Until {
          $script:recoveryHealth = Get-SymppBackendHealthWithRetry ([string]$runtimeState.backend.url) 1 0 $true
          $script:recoveryListenerPid = Get-ManagedListenerPid "backend" ([int]$runtimeState.backend.port)
          (Test-BackendLaunchCompatible $script:recoveryHealth $expectedContractFingerprint) -and $script:recoveryListenerPid
        } $recoveryTimeout) {
        $recoveredBackendPlan = New-ReusedBackendPlan "recovered" ([string]$runtimeState.backend.url) $script:recoveryHealth $true $script:recoveryListenerPid
        Write-SymppLauncherTrace "backend_adopted"
      } else {
        [void](Stop-ManagedRuntimeProcess "backend" $runtimeState.backend.pid ([int]$runtimeState.backend.port))
        $runtimeState = $null
      }
    } else {
      $runtimeState = $null
    }
  }
  $activeLeasesAtStart = @(Get-ActiveBridgeLeases $runtimeFile)
  if ($activeLeasesAtStart.Count -eq 0 -and $null -ne $runtimeState -and $null -ne $runtimeState.backend) {
    $runtimeHealth = Get-SymppBackendHealthWithRetry ([string]$runtimeState.backend.url)
    $preserveBackendUrl = if ([string]::IsNullOrWhiteSpace($env:SYMPP_BACKEND_URL)) { $null } else { $env:SYMPP_BACKEND_URL.TrimEnd("/") }
    $preserveDashboardOrigin = if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DASHBOARD_ORIGIN)) {
      $env:SYMPP_DASHBOARD_ORIGIN.TrimEnd("/")
    } elseif ($runtimeState.frontend.managed -eq $true -and (Test-HealthySymppDashboard ([string]$runtimeState.frontend.origin))) {
      ([string]$runtimeState.frontend.origin).TrimEnd("/")
    } else {
      $null
    }
    if (-not (Test-BackendContractMatches $runtimeHealth $expectedContractFingerprint) -and
        (Stop-ManagedRuntimeStateEntries $runtimeState $preserveBackendUrl $preserveDashboardOrigin)) {
      Write-RuntimeState $runtimeFile $runtimeState
    }
  }

  Write-SymppLauncherTrace "backend_plan_begin"
  $backendPlan = if ($recoveredBackendPlan) { $recoveredBackendPlan } else {
    $backendPortReleaseBudget = if ($installedHttpCold) { Get-SymppRemainingTimeoutSec $backendPortReleaseTimeout "backend port release" } else { $backendPortReleaseTimeout }
    Resolve-BackendPlan $backendPort $env:SYMPP_BACKEND_URL $runtimeState $backendPortReleaseBudget $expectedSourceRevision $expectedContractFingerprint $backendPortExplicit @($dashboardPort)
  }
  Write-SymppLauncherTrace "backend_plan_end"
  if ($installedHttpCold -and -not $backendPlan.should_start -and $autostartFrontend -and [string]::IsNullOrWhiteSpace($env:SYMPP_DASHBOARD_ORIGIN)) {
    $runtimeInputs = Resolve-SymppLauncherRuntimeInputs $pluginRoot $bridgeMode $false $expectedContractFingerprint $expectedSourceRevision
    $artifactRuntimeAllowed = [bool]$runtimeInputs.artifact_runtime_allowed
    $sourceFallbackAllowed = [bool]$runtimeInputs.source_fallback_allowed
    $artifactProbe = $runtimeInputs.artifact_probe
    $repoRoot = $runtimeInputs.repo_root; $elixirDir = $runtimeInputs.elixir_dir; $assetsDir = $runtimeInputs.assets_dir
    $mix = $runtimeInputs.mix; $mise = $runtimeInputs.mise; $launcher = $runtimeInputs.launcher; $defaultMixBuildRoot = $runtimeInputs.default_mix_build_root; $logDir = $runtimeInputs.log_dir
  }
  if ($backendPlan.should_start -and -not $autostartBackend) {
    throw "Backend autostart is disabled and no reusable Symphony++ backend was found at $($backendPlan.url)."
  }
  if ($backendPlan.should_start) {
    if ($installedHttpCold) {
      $startingState = [pscustomobject]@{
        generated_at = [DateTimeOffset]::UtcNow.ToString("o"); plugin_root = $pluginRoot; runtime_mode = "pending"; runtime_kind = "pending"
        artifact = [pscustomobject]@{ status = "not_probed"; detail = "cold_leader" }
        backend = [pscustomobject]@{ status = "starting"; url = $backendPlan.url; mcp_url = $backendPlan.mcp_url; port = $backendPlan.port; managed = $true; pid = $null; expected_source_revision = $expectedSourceRevision; expected_contract_fingerprint = $expectedContractFingerprint; contract_fingerprint = $null }
        frontend = [pscustomobject]@{ status = "starting"; origin = $null; url = $null; port = $null; managed = $false; pid = $null }
      }
      [void](Set-SymppRuntimePublication $startingState "starting" $installedIdentity $publicationControls $backendPlan $null)
      Write-RuntimeState $runtimeFile $startingState
      Write-SymppLauncherTrace "runtime_starting_published"
      $runtimeInputs = Resolve-SymppLauncherRuntimeInputs $pluginRoot $bridgeMode $false $expectedContractFingerprint $expectedSourceRevision
      $expectedContractFingerprint = [string]$runtimeInputs.expected_contract_fingerprint
      $expectedSourceRevision = [string]$runtimeInputs.expected_source_revision
      $artifactRuntimeAllowed = [bool]$runtimeInputs.artifact_runtime_allowed
      $sourceFallbackAllowed = [bool]$runtimeInputs.source_fallback_allowed
      $artifactProbe = $runtimeInputs.artifact_probe
      $artifactValidationLaunchable = [bool]$runtimeInputs.artifact_validation_launchable
      $repoRoot = $runtimeInputs.repo_root; $elixirDir = $runtimeInputs.elixir_dir; $assetsDir = $runtimeInputs.assets_dir
      $mix = $runtimeInputs.mix; $mise = $runtimeInputs.mise; $launcher = $runtimeInputs.launcher; $defaultMixBuildRoot = $runtimeInputs.default_mix_build_root; $logDir = $runtimeInputs.log_dir
    }
    $artifactSelection = Resolve-LaunchArtifactSelection $pluginRoot $repoRoot $artifactProbe $expectedSourceRevision $expectedContractFingerprint $artifactRuntimeAllowed $sourceFallbackAllowed
    $artifactRuntime = $artifactSelection.artifact_runtime
    $runtimeMode = [string]$artifactSelection.runtime_mode
    $expectedSourceRevision = [string]$artifactSelection.expected_source_revision
  }

  $restartingRecordedBackend = $backendPlan.should_start -and $runtimeState.backend.managed -eq $true -and
    (Test-RuntimeEntryEndpointMatches "backend" $runtimeState.backend $backendPlan.url)
  $allowRecordedDashboardReuse = $backendPlan.managed -eq $true -and
    ([string]$backendPlan.status -eq "reused" -or $restartingRecordedBackend)
  $artifactDashboardPortMatchesBackend = $dashboardPortExplicit -and $dashboardPort -eq $backendPlan.port
  $artifactBackendProvidesDashboard = (Test-ArtifactBackendProvidesDashboard $runtimeState $backendPlan $runtimeMode) -and
    ($backendPlan.should_start -or ((Test-HealthySymppDashboard $backendPlan.url) -and (Test-SymppDashboardMcpProxyMatches $backendPlan.url $expectedContractFingerprint)))
  if ($artifactBackendProvidesDashboard -and -not $backendPlan.should_start) {
    $runtimeMode = "artifact"
  }
  if ($artifactBackendProvidesDashboard -and
      [string]::IsNullOrWhiteSpace($env:SYMPP_DASHBOARD_ORIGIN) -and
      ((-not $dashboardPortExplicit) -or $artifactDashboardPortMatchesBackend) -and
      ($backendPlan.should_start -or $backendPlan.reused)) {
    $dashboardPlan = New-ReusedDashboardPlan "artifact_static" $backendPlan.url $false $null
  } else {
    $dashboardBackendSourceRevision = if ($backendPlan.should_start) { $expectedSourceRevision } else { [string]$backendPlan.source_revision }
    $dashboardPlan = Resolve-DashboardPlan $dashboardPort $env:SYMPP_DASHBOARD_ORIGIN $backendPlan.url $dashboardBackendSourceRevision $runtimeState $dashboardPortExplicit $expectedSourceRevision $expectedContractFingerprint $allowRecordedDashboardReuse $backendPlan.should_start
  }
  if ($runtimeMode -eq "artifact" -and $dashboardPortExplicit -and $dashboardPlan.should_start -and -not (Test-Path -LiteralPath $assetsDir -PathType Container)) {
    throw "SYMPP_DASHBOARD_PORT requires source dashboard assets when artifact mode must start a separate dashboard. Set SYMPP_DASHBOARD_ORIGIN to reuse an operator-owned dashboard, or clear SYMPP_DASHBOARD_PORT to use the artifact backend dashboard."
  }
  if ($dashboardPlan.should_start -and -not $autostartFrontend) {
    $dashboardPlan = New-DisabledDashboardPlan "disabled" "frontend_autostart_disabled"
  }

  $supersededStates = Merge-SupersededRuntimeStates (Get-SupersededRuntimeStates $runtimeState) (New-SupersededRuntimeState $runtimeState $backendPlan $dashboardPlan)
  $supersededStates = Stop-SupersededRuntimeStatesIfUnused $runtimeFile $supersededStates

  if ($backendPlan.should_start) {
    if ($runtimeMode -eq "source") {
      [void](Initialize-ElixirRuntime $elixirDir $launcher $mix $mise $logDir $elixirSetupTimeout)
    }
    $backendDashboardOrigin = if ($runtimeMode -eq "artifact" -and [string]$dashboardPlan.status -eq "artifact_static") { $null } else { $dashboardPlan.origin }
    $backendShutdownOnIdle = Test-BackendShouldShutdownOnIdle $backendPlan $dashboardPlan
    $startingRuntimeRoot = if ($runtimeMode -eq "artifact") { [string]$artifactRuntime.root } else { [string]$repoRoot }
    if ($installedHttpCold) {
      $startingState.runtime_mode = $runtimeMode; $startingState.runtime_kind = $runtimeMode
      $startingState.artifact = if ($artifactRuntime) { [pscustomobject]@{ status = "ready"; root = $artifactRuntime.root; entrypoint = $artifactRuntime.entrypoint; sha256 = $artifactRuntime.sha256; platform = $artifactRuntime.platform; manifest_path = $artifactRuntime.manifest_path } } else { $artifactProbe }
      $startingState.frontend.status = if ($runtimeMode -eq "artifact") { "artifact_static" } else { "starting" }
      $startingState.frontend.origin = if ($runtimeMode -eq "artifact") { $backendPlan.url } else { $dashboardPlan.origin }
      [void](Set-SymppRuntimePublication $startingState "starting" $installedIdentity $publicationControls $backendPlan $startingRuntimeRoot)
      Write-RuntimeState $runtimeFile $startingState
    }
    $onBackendStarted = if ($installedHttpCold) { {
        param($StartedPid, $StartIdentity)
        $backendPlan.pid = $StartedPid; $startingState.backend.pid = $StartedPid
        [void](Set-SymppRuntimePublication $startingState "starting" $installedIdentity $publicationControls $backendPlan $startingRuntimeRoot $StartIdentity)
        Write-RuntimeState $runtimeFile $startingState
      } } else { $null }
    Write-SymppLauncherTrace "backend_start_begin"
    $backendLaunch = Start-Backend $backendPlan $backendDashboardOrigin $elixirDir $launcher $mix $mise $logDir $backendTimeout $expectedContractFingerprint $artifactRuntime $backendShutdownOnIdle $onBackendStarted
    Write-SymppLauncherTrace "backend_start_end"
    $backendPlan.status = "started"
    $backendPlan.pid = $backendLaunch.pid
    $backendPlan.source_revision = $backendLaunch.source_revision
    $backendPlan.contract_fingerprint = $backendLaunch.contract_fingerprint
    if ($restartingRecordedBackend -and $dashboardPlan.reused -and
        -not (Test-SymppDashboardMcpProxyMatches $dashboardPlan.origin $expectedContractFingerprint)) {
      [void](Stop-ManagedRuntimeEntry "backend" $backendPlan)
      throw "dashboard_proxy_mismatch: the preserved dashboard proxy did not recover after the backend restarted."
    }
    if ($runtimeMode -eq "artifact" -and [string]$dashboardPlan.status -eq "artifact_static") {
      if (-not (Test-HealthySymppDashboard $backendPlan.url) -or -not (Test-SymppDashboardMcpProxyMatches $backendPlan.url $expectedContractFingerprint)) {
        [void](Stop-ManagedRuntimeEntry "backend" $backendPlan)
        throw "artifact_dashboard_unavailable: verified artifact backend started, but its dashboard route is not healthy for the expected MCP contract."
      }
    }
  }

  if ($dashboardPlan.should_start) {
    try {
      $frontendInstall = Install-FrontendDependencies $assetsDir $logDir $frontendInstallTimeout
      $frontendLaunch = Start-Frontend $dashboardPlan $backendPlan.url $assetsDir $logDir $frontendTimeout
      $dashboardPlan.status = "started"
      $dashboardPlan.pid = $frontendLaunch.pid
    } catch {
      $frontendError = $_.Exception.Message
      $dashboardPlan.status = "failed"
      Write-Diagnostic "Symphony++ dashboard autostart failed; MCP bridge will continue. detail=$frontendError"
    }
  }
  if ($null -eq $frontendError -and $null -ne $dashboardPlan.PSObject.Properties["error"]) {
    $frontendError = $dashboardPlan.error
  }

  $runtimeSourceRevision = if ([string]::IsNullOrWhiteSpace([string]$backendPlan.source_revision)) { $expectedSourceRevision } else { [string]$backendPlan.source_revision }
  $runtimeContractFingerprint = if ([string]::IsNullOrWhiteSpace([string]$backendPlan.contract_fingerprint)) { $expectedContractFingerprint } else { [string]$backendPlan.contract_fingerprint }
  $runtimeKey = New-RuntimeKey $backendPlan.url $dashboardPlan.origin $runtimeContractFingerprint
  $state = [pscustomobject]@{
    generated_at = (Get-Date).ToString("o")
    repo_root = $repoRoot
    plugin_root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
    mcp_transport = "stdio_to_http_bridge"
    runtime_key = $runtimeKey
    runtime_kind = if ($runtimeMode -eq "artifact") { "artifact" } elseif ($backendPlan.managed -eq $true) { "managed" } else { [string]$backendPlan.status }
    runtime_mode = $runtimeMode
    artifact = if ($artifactRuntime) {
      [pscustomobject]@{
        status = "ready"
        root = $artifactRuntime.root
        entrypoint = $artifactRuntime.entrypoint
        sha256 = $artifactRuntime.sha256
        platform = $artifactRuntime.platform
        manifest_path = $artifactRuntime.manifest_path
      }
    } elseif ($null -ne $runtimeState -and $null -ne $runtimeState.artifact) {
      $runtimeState.artifact
    } else {
      [pscustomobject]@{
        status = $artifactProbe.status
        detail = $artifactProbe.detail
        platform = $artifactProbe.platform
        manifest_path = $artifactProbe.manifest_path
      }
    }
    backend = [pscustomobject]@{
      status = $backendPlan.status
      url = $backendPlan.url
      mcp_url = $backendPlan.mcp_url
      port = $backendPlan.port
      reused = $backendPlan.reused
      managed = $backendPlan.managed -eq $true
      pid = $backendPlan.pid
      expected_source_revision = $expectedSourceRevision
      source_revision = $backendPlan.source_revision
      expected_contract_fingerprint = $expectedContractFingerprint
      contract_fingerprint = $backendPlan.contract_fingerprint
      stdout_log = if ($backendLaunch) { $backendLaunch.stdout } else { $null }
      stderr_log = if ($backendLaunch) { $backendLaunch.stderr } else { $null }
    }
    frontend = [pscustomobject]@{
      status = $dashboardPlan.status
      origin = $dashboardPlan.origin
      url = $dashboardPlan.url
      port = $dashboardPlan.port
      reused = $dashboardPlan.reused
      managed = $dashboardPlan.managed -eq $true
      pid = $dashboardPlan.pid
      install_stdout_log = if ($frontendInstall) { $frontendInstall.stdout } else { $null }
      install_stderr_log = if ($frontendInstall) { $frontendInstall.stderr } else { $null }
      stdout_log = if ($frontendLaunch) { $frontendLaunch.stdout } else { $null }
      stderr_log = if ($frontendLaunch) { $frontendLaunch.stderr } else { $null }
      error = $frontendError
    }
    controls = [pscustomobject]@{
      backend_port_env = "SYMPP_BACKEND_PORT"
      dashboard_port_env = "SYMPP_DASHBOARD_PORT"
      backend_url_env = "SYMPP_BACKEND_URL"
      dashboard_origin_env = "SYMPP_DASHBOARD_ORIGIN"
      autostart_env = "SYMPP_AUTOSTART_SERVERS"
      bridge_mode_env = "SYMPP_MCP_BRIDGE_MODE"
    }
    superseded = if ($supersededStates.Count -gt 0) { $supersededStates[0] } else { $null }
    superseded_runtimes = $supersededStates
  }
  if ($installedHttpCold) {
    $readyRoot = if ($runtimeMode -eq "artifact" -and $artifactRuntime) { [string]$artifactRuntime.root } elseif ($repoRoot) { [string]$repoRoot } else { [string]$state.artifact.root }
    $readyStartIdentity = Get-ProcessStartIdentity (Get-Process -Id ([int]$state.backend.pid) -ErrorAction SilentlyContinue)
    [void](Set-SymppRuntimePublication $state "ready" $installedIdentity $publicationControls $backendPlan $readyRoot $readyStartIdentity)
  }
  Write-RuntimeState $runtimeFile $state
  if ($installedHttpCold) { Write-SymppLauncherTrace "runtime_ready_published" }
  if (-not $PrepareRuntimeOnly) {
    $bridgeLeasePath = New-BridgeLease $runtimeFile $backendPlan $dashboardPlan $runtimeKey
  }

  $dashboardSummary = if ($dashboardPlan.url) { "$($dashboardPlan.url) [$($dashboardPlan.status)]" } else { $dashboardPlan.status }
  $readyKind = if ($PrepareRuntimeOnly) { "runtime" } else { "MCP bridge" }
  Write-Diagnostic "Symphony++ $readyKind ready: backend=$($backendPlan.url) dashboard=$dashboardSummary runtime=$runtimeFile"
} finally {
  Exit-FileLock $startupLock
}
if ($PrepareRuntimeOnly) {
  exit 0
}
try {
  $leaseState = [pscustomobject]@{ path = $bridgeLeasePath; runtime_key = $runtimeKey }
  $fallbackRecovery = { param($stdinReadState, $activeRequest)
    $recoveryPlan = Invoke-PowerShellFallbackRuntimeRecovery $runtimeFile $pluginRoot $backendPort $dashboardPort $backendPortExplicit $dashboardPortExplicit $env:SYMPP_BACKEND_URL $env:SYMPP_DASHBOARD_ORIGIN $PSCommandPath $stdinReadState $activeRequest
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($leaseState.runtime_key, $recoveryPlan.runtime_key)) {
      $replacementLeasePath = New-BridgeLease $runtimeFile $recoveryPlan.backend_plan $recoveryPlan.dashboard_plan $recoveryPlan.runtime_key
      Remove-BridgeLease $leaseState.path
      $leaseState.path = $replacementLeasePath; $leaseState.runtime_key = $recoveryPlan.runtime_key
    }
    $script:backendPlan = $recoveryPlan.backend_plan
    $script:dashboardPlan = $recoveryPlan.dashboard_plan
    return [pscustomobject]@{ mcp_url = $recoveryPlan.backend_plan.mcp_url }
  }
  Invoke-HttpMcpBridge $backendPlan.mcp_url $bridgeTimeout (New-McpClientLeaseId) $clientHeartbeatInterval $fallbackRecovery
} finally {
  Remove-BridgeLease $leaseState.path
  Stop-ManagedServersIfUnused $runtimeFile $leaseState.runtime_key
}
