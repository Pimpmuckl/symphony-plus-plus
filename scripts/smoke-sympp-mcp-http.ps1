param(
  [string]$Url = "http://127.0.0.1:19998/mcp",
  [switch]$Json,
  [switch]$Bound,
  [string]$WorkPackageId,
  [string]$ClaimedBy,
  [string]$RepoRoot,
  [string]$ExpectedSourceRevision,
  [switch]$SkipUnboundTools,
  [switch]$SkipLiveServer,
  [switch]$SkipBound,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

function Resolve-SmokeRepoRoot {
  if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
    return [System.IO.Path]::GetFullPath($RepoRoot)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
}

function Get-ContractStringList($Value) {
  @($Value | ForEach-Object {
      if ($null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_)) {
        [string]$_
      }
    })
}

function Read-McpToolsContract {
  $contractPath = Join-Path (Resolve-SmokeRepoRoot) "implementation_docs_symphplusplus/mcp/mcp_tools_contract.json"
  if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    throw "MCP tools contract JSON is missing: $contractPath"
  }

  Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
}

$McpToolsContract = Read-McpToolsContract
$DiscoveryPolicy = $McpToolsContract.discovery_policy
$UnboundContractTools = Get-ContractStringList $DiscoveryPolicy.unbound_tools
$SoloTools = @($UnboundContractTools | Where-Object { $_ -like "solo_*" })
$ExpectedGenericUnboundTools = @($UnboundContractTools | Where-Object { $_ -notlike "claim_local_*" })
$ExpectedHttpUnboundTools = Get-ContractStringList $DiscoveryPolicy.trusted_local_http_extra_tools
$ExpectedBoundWorkerTools = Get-ContractStringList $DiscoveryPolicy.bound_worker_tools
$ArchitectTools = Get-ContractStringList $DiscoveryPolicy.unbound_schema_sets.architect_tools

$ArchitectOnlyTools = @($ArchitectTools | Where-Object { $ExpectedBoundWorkerTools -notcontains $_ })
$ExpectedUnboundTools = @($UnboundContractTools + $ExpectedHttpUnboundTools + $ExpectedBoundWorkerTools + $ArchitectTools | Sort-Object -Unique)
$AllowedUnboundTools = $ExpectedUnboundTools
$UnboundOnlyTools = @($AllowedUnboundTools | Where-Object { $ExpectedBoundWorkerTools -notcontains $_ })
$ForbiddenUnboundTools = @()
$ForbiddenBoundWorkerTools =
  @($SoloTools + $ArchitectOnlyTools + $UnboundOnlyTools |
    Where-Object { $_ -ne "sympp.health" } |
    Sort-Object -Unique)

$ExpectedPreClaimGatedCalls = @(
  @{
    name = "dispatch_slice"
    arguments = @{
      work_request_id = "WR-SMOKE-PRECLAIM"
      planned_slice_id = "SLICE-SMOKE-PRECLAIM"
      claimed_by = "sympp-http-smoke"
    }
  },
  @{
    name = "read_context"
    arguments = @{}
  }
)

$ExpectedTrustedLocalPreClaimReadCalls = @(
  @{
    name = "read_work_request"
    arguments = @{
      work_request_id = "WR-SMOKE-PRECLAIM-READ"
    }
    allowedReasons = @("not_found")
  },
  @{
    name = "read_plan"
    arguments = @{
      work_request_id = "WR-SMOKE-PRECLAIM-READ"
      view = "nodes_with_slice_refs"
    }
    allowedReasons = @("not_found")
  },
  @{
    name = "read_delivery_board"
    arguments = @{
      work_request_id = "WR-SMOKE-PRECLAIM-READ"
    }
    allowedReasons = @("not_found")
  }
)

$ExpectedPreClaimGateReasons = @(
  "claim_required",
  "insufficient_capability",
  "insufficient_role"
)

$ExpectedWorkerResourceFiles = @(
  "context.md",
  "task_plan.md",
  "findings.md",
  "progress.md",
  "acceptance.md",
  "review_suite.md",
  "handoff.md"
)

$RedactedValue = "<redacted>"
$script:SensitiveValues = [System.Collections.Generic.List[string]]::new()

function New-SmokeResult([string]$Status, [string]$Message, [hashtable]$Data = @{}) {
  $result = [ordered]@{
    status = $Status
    message = $Message
    url = $Url
  }

  foreach ($key in $Data.Keys) {
    $result[$key] = $Data[$key]
  }

  return [pscustomobject]$result
}

function Add-SensitiveValue([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return
  }

  if (-not $script:SensitiveValues.Contains($Value)) {
    [void]$script:SensitiveValues.Add($Value)
  }
}

function Protect-SensitiveText([string]$Text) {
  if ($null -eq $Text) {
    return $null
  }

  $protected = [string]$Text
  foreach ($value in $script:SensitiveValues) {
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      $protected = $protected.Replace($value, $RedactedValue)
    }
  }

  return $protected
}

function ConvertTo-RedactedJson($Value) {
  return Protect-SensitiveText ($Value | ConvertTo-Json -Depth 12)
}

function Normalize-SourceRevision([string]$Revision) {
  if ([string]::IsNullOrWhiteSpace($Revision)) {
    return $null
  }

  $normalized = $Revision.Trim().ToLowerInvariant()
  if ($normalized -notmatch "^[0-9a-f]{40}$") {
    throw "Expected source revision must be a 40-character git SHA."
  }

  return $normalized
}

function Get-GitHeadRevision([string]$Root) {
  if ([string]::IsNullOrWhiteSpace($Root)) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "invalid_arguments" "RepoRoot must be non-empty when supplied."
    }
  }

  $fullRoot = [System.IO.Path]::GetFullPath($Root)
  if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "invalid_repo_root" "RepoRoot does not exist: $fullRoot"
    }
  }

  $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $git) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "source_revision_unavailable" "Could not find git to verify the daemon source revision for RepoRoot: $fullRoot"
    }
  }

  $output = @(& $git.Source @("-C", $fullRoot, "rev-parse", "--verify", "HEAD") 2>&1)
  if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "source_revision_unavailable" "Could not resolve git HEAD for RepoRoot: $fullRoot"
    }
  }

  try {
    return [pscustomobject]@{
      ok = $true
      revision = Normalize-SourceRevision ([string]$output[0])
    }
  } catch {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "source_revision_unavailable" "Git returned an invalid HEAD revision for RepoRoot: $fullRoot"
    }
  }
}

function Resolve-ExpectedSourceRevision {
  if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) {
    try {
      return [pscustomobject]@{
        ok = $true
        revision = Normalize-SourceRevision $ExpectedSourceRevision
      }
    } catch {
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "invalid_arguments" $_.Exception.Message
      }
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
    return Get-GitHeadRevision $RepoRoot
  }

  return [pscustomobject]@{
    ok = $true
    revision = $null
  }
}

function Write-SmokeResult($Result, [int]$ExitCode) {
  if ($Json) {
    ConvertTo-RedactedJson $Result
  }
  elseif ($ExitCode -eq 0) {
    Write-Host (Protect-SensitiveText "OK: $($Result.message)")
    if ($Result.PSObject.Properties["mode"]) {
      Write-Host (Protect-SensitiveText "Mode: $($Result.mode)")
    }
    if ($Result.PSObject.Properties["workPackageId"]) {
      Write-Host (Protect-SensitiveText "WorkPackage: $($Result.workPackageId)")
    }
    if ($Result.PSObject.Properties["daemonSourceRevision"] -and -not [string]::IsNullOrWhiteSpace([string]$Result.daemonSourceRevision)) {
      Write-Host (Protect-SensitiveText "DaemonSourceRevision: $($Result.daemonSourceRevision)")
    }
    if ($Result.PSObject.Properties["tools"]) {
      Write-Host (Protect-SensitiveText "Tools: $($Result.tools -join ', ')")
    }
    if ($Result.PSObject.Properties["resources"]) {
      Write-Host (Protect-SensitiveText "Resources: $($Result.resources -join ', ')")
    }
  }
  else {
    [Console]::Error.WriteLine((Protect-SensitiveText $Result.message))
  }

  exit $ExitCode
}

function ConvertTo-JsonBody([hashtable]$Payload) {
  return $Payload | ConvertTo-Json -Depth 12 -Compress
}

function New-InitializeRequest {
  return @{
    jsonrpc = "2.0"
    id = "sympp-http-smoke-init"
    method = "initialize"
    params = @{
      protocolVersion = "2025-03-26"
      clientInfo = @{
        name = "sympp-http-smoke"
        version = "0.1.0"
      }
      capabilities = @{}
    }
  }
}

function New-ToolsListRequest {
  return @{
    jsonrpc = "2.0"
    id = "sympp-http-smoke-tools"
    method = "tools/list"
    params = @{}
  }
}

function New-ToolCallRequest([string]$Id, [string]$Name, [hashtable]$Arguments) {
  return @{
    jsonrpc = "2.0"
    id = $Id
    method = "tools/call"
    params = @{
      name = $Name
      arguments = $Arguments
    }
  }
}

function New-ResourcesListRequest {
  return @{
    jsonrpc = "2.0"
    id = "sympp-http-smoke-resources"
    method = "resources/list"
    params = @{}
  }
}

function New-ResourcesReadRequest([string]$Uri) {
  return @{
    jsonrpc = "2.0"
    id = "sympp-http-smoke-resource"
    method = "resources/read"
    params = @{
      uri = $Uri
    }
  }
}

function Get-ResponseHeaderValue($Headers, [string]$Name) {
  if ($null -eq $Headers) {
    return $null
  }

  $rawValue = $null
  if ($Headers -is [System.Net.WebHeaderCollection]) {
    $rawValue = $Headers[$Name]
  }
  elseif ($Headers -is [System.Collections.IDictionary]) {
    foreach ($key in $Headers.Keys) {
      if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rawValue = $Headers[$key]
        break
      }
    }
  }
  else {
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
      }
      finally {
        $reader.Dispose()
      }
    }

    if ($Response.PSObject.Properties["Content"] -and $Response.Content) {
      return $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
  }
  catch {
    return $null
  }

  return $null
}

function Invoke-McpPost([string]$TargetUrl, [hashtable]$Payload, [string]$SessionId) {
  $headers = @{
    Accept = "application/json"
  }

  if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
    $headers["Mcp-Session-Id"] = [string]$SessionId
  }

  try {
    $response = Invoke-WebRequest `
      -Uri $TargetUrl `
      -Method Post `
      -Headers $headers `
      -ContentType "application/json" `
      -Body (ConvertTo-JsonBody $Payload) `
      -TimeoutSec 10 `
      -UseBasicParsing `
      -ErrorAction Stop

    return [pscustomobject]@{
      ok = $true
      statusCode = [int]$response.StatusCode
      headers = $response.Headers
      content = [string]$response.Content
      error = $null
    }
  }
  catch {
    $response = $_.Exception.Response
    $statusCode = $null
    if ($null -ne $response) {
      try {
        $statusCode = [int]$response.StatusCode
      }
      catch {
        $statusCode = $null
      }
    }

    return [pscustomobject]@{
      ok = $false
      statusCode = $statusCode
      headers = if ($null -ne $response) { $response.Headers } else { $null }
      content = Read-ErrorResponseBody $response
      error = $_.Exception.Message
    }
  }
}

function ConvertFrom-JsonResponse([string]$Content, [string]$Stage) {
  if ([string]::IsNullOrWhiteSpace($Content)) {
    throw "$Stage returned an empty response body."
  }

  try {
    return $Content | ConvertFrom-Json
  }
  catch {
    throw "$Stage returned non-JSON response: $($_.Exception.Message)"
  }
}

function Get-JsonRpcErrorMessage($Payload) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["error"]) {
    return $null
  }

  $errorObject = $Payload.error
  $reason = $null
  if ($errorObject.PSObject.Properties["data"] -and $errorObject.data.PSObject.Properties["reason"]) {
    $reason = [string]$errorObject.data.reason
  }

  if ($reason) {
    return "$($errorObject.message): $reason"
  }

  return [string]$errorObject.message
}

function Get-JsonRpcErrorReason($Payload) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["error"]) {
    return $null
  }

  $errorObject = $Payload.error
  if ($errorObject.PSObject.Properties["data"] -and $errorObject.data.PSObject.Properties["reason"]) {
    return [string]$errorObject.data.reason
  }

  return $null
}

function Get-ResponseErrorDetail($Response, [string]$Fallback) {
  if (-not [string]::IsNullOrWhiteSpace($Response.content)) {
    try {
      $payload = $Response.content | ConvertFrom-Json
      $jsonRpcError = Get-JsonRpcErrorMessage $payload
      if (-not [string]::IsNullOrWhiteSpace($jsonRpcError)) {
        return $jsonRpcError
      }
    }
    catch {
      return $Response.content
    }
  }

  return $Fallback
}

function New-PortOwner([int]$ProcessId, [string]$LocalAddress) {
  $processName = "<unknown>"
  try {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($process.ProcessName)) {
      $processName = [string]$process.ProcessName
    }
  }
  catch {
  }

  return [pscustomobject]@{
    pid = $ProcessId
    process = $processName
    localAddress = $LocalAddress
  }
}

function Add-PortOwner($Owners, $Seen, [int]$ProcessId, [string]$LocalAddress) {
  $key = "$ProcessId|$LocalAddress"
  if ($Seen.Contains($key)) {
    return
  }

  [void]$Seen.Add($key)
  [void]$Owners.Add((New-PortOwner $ProcessId $LocalAddress))
}

function Get-TcpPortOwners([int]$Port) {
  $owners = [System.Collections.Generic.List[object]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new()

  if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    try {
      $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
      foreach ($connection in $connections) {
        $processId = [int]$connection.OwningProcess
        if ($processId -gt 0) {
          Add-PortOwner $owners $seen $processId ([string]$connection.LocalAddress)
        }
      }
    }
    catch {
    }
  }

  if ($owners.Count -eq 0 -and (Get-Command netstat -ErrorAction SilentlyContinue)) {
    try {
      $escapedPort = [regex]::Escape([string]$Port)
      foreach ($line in @(& netstat -ano -p tcp 2>$null)) {
        if ($line -match "^\s*TCP\s+(.+):$escapedPort\s+\S+\s+LISTENING\s+(\d+)\s*$") {
          Add-PortOwner $owners $seen ([int]$matches[2]) $matches[1].Trim()
        }
      }
    }
    catch {
    }
  }

  return @($owners)
}

function Format-PortOwners([object[]]$Owners) {
  return (@($Owners) | ForEach-Object {
      "pid=$($_.pid) process=$($_.process) localAddress=$($_.localAddress)"
    }) -join "; "
}

function Get-EndpointPortOwnership([string]$TargetUrl) {
  try {
    $uri = [System.Uri]::new($TargetUrl)
  }
  catch {
    return $null
  }

  if (-not $uri.IsLoopback) {
    return $null
  }

  $port = [int]$uri.Port
  $owners = @(Get-TcpPortOwners $port)
  if ($owners.Count -eq 0) {
    return $null
  }

  return [pscustomobject]@{
    port = $port
    owners = $owners
    summary = Format-PortOwners $owners
  }
}

function Test-ConnectionRefusedError([string]$Message) {
  if ([string]::IsNullOrWhiteSpace($Message)) {
    return $false
  }

  $normalized = $Message.ToLowerInvariant()
  return (
    $normalized.Contains("actively refused") -or
    $normalized.Contains("connection refused") -or
    $normalized.Contains("no connection could be made") -or
    $normalized.Contains("unable to connect") -or
    $normalized.Contains("failed to connect")
  )
}

function Get-ToolNames($ToolsPayload) {
  $tools = $ToolsPayload.result.tools
  if ($null -eq $tools) {
    return @()
  }

  return @($tools | ForEach-Object { [string]$_.name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
}

function Get-ResourceUris($ResourcesPayload) {
  $resources = $ResourcesPayload.result.resources
  if ($null -eq $resources) {
    return @()
  }

  return @($resources | ForEach-Object { [string]$_.uri } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
}

function Get-ResourceContentByMimeType($Payload, [string]$MimeType) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["result"]) {
    return $null
  }

  $normalizedMimeType = Normalize-MimeType $MimeType
  $contents = @($Payload.result.contents)
  foreach ($content in $contents) {
    if ($null -ne $content -and $content.PSObject.Properties["mimeType"] -and (Normalize-MimeType ([string]$content.mimeType)) -eq $normalizedMimeType) {
      return $content
    }
  }

  return $null
}

function Normalize-MimeType([string]$MimeType) {
  if ([string]::IsNullOrWhiteSpace($MimeType)) {
    return ""
  }

  return (($MimeType -split ";", 2)[0]).Trim().ToLowerInvariant()
}

function Get-AssignmentWorkPackageId($Payload) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["result"]) {
    return $null
  }

  $structuredContent = $Payload.result.structuredContent
  if ($null -eq $structuredContent -or -not $structuredContent.PSObject.Properties["assignment"]) {
    return $null
  }

  $assignment = $structuredContent.assignment
  if ($null -eq $assignment -or -not $assignment.PSObject.Properties["work_package_id"]) {
    return $null
  }

  $workPackageId = [string]$assignment.work_package_id
  if ([string]::IsNullOrWhiteSpace($workPackageId)) {
    return $null
  }

  return $workPackageId
}

function Get-HealthSourceRevision($Payload) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["result"]) {
    return $null
  }

  $structuredContent = $Payload.result.structuredContent
  if ($null -eq $structuredContent -or -not $structuredContent.PSObject.Properties["source"]) {
    return $null
  }

  $source = $structuredContent.source
  if ($null -eq $source -or -not $source.PSObject.Properties["revision"]) {
    return $null
  }

  try {
    return Normalize-SourceRevision ([string]$source.revision)
  } catch {
    return $null
  }
}

function Test-NonEmptyString($Value) {
  return $null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value)
}

function Test-HealthLedgerIdentity($Payload) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["result"]) {
    return [pscustomobject]@{ ok = $false; reason = "missing_result" }
  }

  $structuredContent = $Payload.result.structuredContent
  if ($null -eq $structuredContent -or -not $structuredContent.PSObject.Properties["ledger"]) {
    return [pscustomobject]@{ ok = $false; reason = "missing_ledger" }
  }

  $ledger = $structuredContent.ledger
  if ($null -eq $ledger -or -not $ledger.PSObject.Properties["identity"]) {
    return [pscustomobject]@{ ok = $false; reason = "missing_ledger_identity" }
  }

  $identity = $ledger.identity
  if ($null -eq $identity -or -not (Test-NonEmptyString $identity.kind) -or -not (Test-NonEmptyString $identity.source)) {
    return [pscustomobject]@{ ok = $false; reason = "incomplete_ledger_identity" }
  }

  $kind = [string]$identity.kind
  if ($kind -eq "sqlite" -and -not (Test-NonEmptyString $identity.display_path)) {
    return [pscustomobject]@{ ok = $false; reason = "missing_sqlite_display_path" }
  }

  if ($kind -eq "server" -and -not (Test-NonEmptyString $identity.endpoint)) {
    return [pscustomobject]@{ ok = $false; reason = "missing_server_endpoint" }
  }

  return [pscustomobject]@{ ok = $true; reason = $null }
}

function Invoke-HealthSmoke([string]$SessionId, [string]$ExpectedRevision) {
  $healthResponse = Invoke-McpPost $Url (New-ToolCallRequest "sympp-http-smoke-health" "sympp.health" @{}) $SessionId
  if (-not $healthResponse.ok) {
    $reason = if ($healthResponse.statusCode) { "HTTP $($healthResponse.statusCode)" } else { "request failed" }
    $detail = Get-ResponseErrorDetail $healthResponse $healthResponse.error
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "health_failed" "MCP sympp.health failed with initialized session ($reason): $detail"
    }
  }

  $sessionCheck = Test-ResponseSessionHeader $healthResponse $SessionId "sympp.health"
  if (-not $sessionCheck.ok) {
    return $sessionCheck
  }

  $healthPayload = ConvertFrom-JsonResponse $healthResponse.content "sympp.health"
  $healthError = Get-JsonRpcErrorMessage $healthPayload
  if ($healthError) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "health_failed" "MCP sympp.health returned JSON-RPC error: $healthError"
    }
  }

  $actualRevision = Get-HealthSourceRevision $healthPayload
  if (-not [string]::IsNullOrWhiteSpace($ExpectedRevision)) {
    if ([string]::IsNullOrWhiteSpace($actualRevision)) {
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "stale_or_unverified_daemon" "MCP daemon did not report a source revision. Restart the local Symphony++ cockpit from the current checkout and rerun smoke." @{
          expectedSourceRevision = $ExpectedRevision
        }
      }
    }

    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($actualRevision, $ExpectedRevision)) {
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "stale_daemon_source_revision_mismatch" "MCP daemon source revision does not match the expected checkout. Restart the local Symphony++ cockpit and rerun smoke." @{
          expectedSourceRevision = $ExpectedRevision
          daemonSourceRevision = $actualRevision
        }
      }
    }
  }

  $identityCheck = Test-HealthLedgerIdentity $healthPayload
  if (-not $identityCheck.ok) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "health_ledger_identity_missing" "MCP sympp.health did not report a complete safe ledger identity ($($identityCheck.reason))."
    }
  }

  return [pscustomobject]@{
    ok = $true
    sourceRevision = $actualRevision
  }
}

function Initialize-HealthyMcpSession([bool]$RedactSessionId) {
  $expectedRevision = Resolve-ExpectedSourceRevision
  if (-not $expectedRevision.ok) {
    return [pscustomobject]@{
      ok = $false
      result = $expectedRevision.result
    }
  }

  $init = Invoke-InitializeSession $RedactSessionId
  if (-not $init.ok) {
    return [pscustomobject]@{
      ok = $false
      result = $init.result
    }
  }

  $health = Invoke-HealthSmoke $init.sessionId $expectedRevision.revision
  if (-not $health.ok) {
    return [pscustomobject]@{
      ok = $false
      result = $health.result
    }
  }

  return [pscustomobject]@{
    ok = $true
    sessionId = $init.sessionId
    expectedRevision = $expectedRevision.revision
    sourceRevision = $health.sourceRevision
  }
}

function Test-ResponseSessionHeader($Response, [string]$ExpectedSessionId, [string]$Stage) {
  $actualSessionId = Get-ResponseHeaderValue $Response.headers "Mcp-Session-Id"
  if ($actualSessionId -ne $ExpectedSessionId) {
    $actual = if ([string]::IsNullOrWhiteSpace($actualSessionId)) { "<missing>" } else { $actualSessionId }
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "session_id_mismatch" "MCP $Stage did not echo the expected Mcp-Session-Id. expected=$ExpectedSessionId actual=$actual"
    }
  }

  return [pscustomobject]@{ ok = $true }
}

function Get-ResourceJsonPayload($Payload, [string]$Stage) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["result"]) {
    throw "$Stage returned no result."
  }

  $contents = @($Payload.result.contents)
  $jsonContent = Get-ResourceContentByMimeType $Payload "application/json"
  $content = if ($null -ne $jsonContent) { $jsonContent } elseif ($contents.Count -gt 0) { $contents[0] } else { $null }
  if ($null -eq $content -or $null -eq $content.text) {
    throw "$Stage returned no text content."
  }

  try {
    $text = [string]$content.text
    return ($text | ConvertFrom-Json)
  }
  catch {
    throw "$Stage returned non-JSON resource text: $($_.Exception.Message)"
  }
}

function Resolve-BoundSmokeConfig([bool]$UseBound, [string]$PackageId, [string]$Owner) {
  if (-not $UseBound) {
    if (-not [string]::IsNullOrWhiteSpace($PackageId) -or -not [string]::IsNullOrWhiteSpace($Owner)) {
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "invalid_arguments" "Bound smoke package/owner arguments require -Bound. Run without -Bound for the unbound health smoke."
      }
    }

    return [pscustomobject]@{ ok = $true; bound = $false }
  }

  if ([string]::IsNullOrWhiteSpace($PackageId)) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "invalid_arguments" "Bound smoke requires -WorkPackageId <work-package-id>."
    }
  }

  $packageId = $PackageId.Trim()
  if ($packageId -eq "") {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "invalid_arguments" "Bound smoke requires a non-empty -WorkPackageId value."
    }
  }

  $owner = if ([string]::IsNullOrWhiteSpace($Owner)) { "sympp-http-smoke" } else { $Owner.Trim() }

  return [pscustomobject]@{
    ok = $true
    bound = $true
    workPackageId = $packageId
    claimedBy = $owner
  }
}

function Invoke-InitializeSession([bool]$RedactSessionId) {
  $initResponse = Invoke-McpPost $Url (New-InitializeRequest) $null
  if (-not $initResponse.ok) {
    if ($initResponse.statusCode) {
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "initialize_failed" "MCP initialize failed with HTTP $($initResponse.statusCode): $($initResponse.error)"
      }
    }

    $ownership = Get-EndpointPortOwnership $Url
    if ($ownership) {
      $status = if (Test-ConnectionRefusedError $initResponse.error) { "endpoint_unreachable_port_occupied" } else { "endpoint_unreachable_listener_unresponsive" }
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult $status "Could not initialize local MCP endpoint at $Url; a loopback listener is present on port $($ownership.port) ($($ownership.summary)), but initialize failed: $($initResponse.error)" @{
          port = $ownership.port
          portOwners = $ownership.owners
        }
      }
    }

    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "endpoint_unreachable" "Could not reach local MCP endpoint at $Url`: $($initResponse.error)"
    }
  }

  $initPayload = ConvertFrom-JsonResponse $initResponse.content "initialize"
  $initError = Get-JsonRpcErrorMessage $initPayload
  if ($initError) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "initialize_failed" "MCP initialize failed: $initError"
    }
  }

  $sessionId = Get-ResponseHeaderValue $initResponse.headers "Mcp-Session-Id"
  if ([string]::IsNullOrWhiteSpace($sessionId)) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "missing_session_id" "MCP initialize succeeded but did not return Mcp-Session-Id."
    }
  }

  if ($RedactSessionId) {
    Add-SensitiveValue $sessionId
  }

  return [pscustomobject]@{
    ok = $true
    sessionId = $sessionId
    payload = $initPayload
  }
}

function Invoke-ToolsListSmoke([string]$SessionId, [string[]]$Expected, [string]$SurfaceName, [string[]]$Forbidden = @()) {
  $toolsResponse = Invoke-McpPost $Url (New-ToolsListRequest) $SessionId
  if (-not $toolsResponse.ok) {
    $reason = if ($toolsResponse.statusCode) { "HTTP $($toolsResponse.statusCode)" } else { "request failed" }
    $detail = Get-ResponseErrorDetail $toolsResponse $toolsResponse.error
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "tools_list_failed" "MCP tools/list failed for $SurfaceName ($reason): $detail"
    }
  }

  $sessionCheck = Test-ResponseSessionHeader $toolsResponse $SessionId "tools/list for $SurfaceName"
  if (-not $sessionCheck.ok) {
    return $sessionCheck
  }

  $toolsPayload = ConvertFrom-JsonResponse $toolsResponse.content "tools/list"
  $toolsError = Get-JsonRpcErrorMessage $toolsPayload
  if ($toolsError) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "tools_list_failed" "MCP tools/list returned JSON-RPC error for $SurfaceName`: $toolsError"
    }
  }

  $toolNames = Get-ToolNames $toolsPayload
  $missingTools = @($Expected | Where-Object { $toolNames -notcontains $_ })
  if ($missingTools.Count -gt 0) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "missing_expected_tools" "MCP tools/list is missing expected $SurfaceName tools: $($missingTools -join ', ')." @{
        tools = $toolNames
        missingTools = $missingTools
      }
    }
  }

  $unexpectedTools = @($Forbidden | Where-Object { $toolNames -contains $_ })
  if ($unexpectedTools.Count -gt 0) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "unexpected_tools" "MCP tools/list exposed tools that must not appear for $SurfaceName`: $($unexpectedTools -join ', ')." @{
        tools = $toolNames
        unexpectedTools = $unexpectedTools
      }
    }
  }

  return [pscustomobject]@{
    ok = $true
    tools = $toolNames
    payload = $toolsPayload
  }
}

function Invoke-PreClaimGateSmoke([string]$SessionId) {
  $gatedTools = @()
  foreach ($call in $ExpectedPreClaimGatedCalls) {
    $toolName = [string]$call.name
    $gateResponse = Invoke-McpPost $Url (New-ToolCallRequest "sympp-http-smoke-preclaim-$toolName" $toolName $call.arguments) $SessionId
    if (-not $gateResponse.ok) {
      $reason = if ($gateResponse.statusCode) { "HTTP $($gateResponse.statusCode)" } else { "request failed" }
      $detail = Get-ResponseErrorDetail $gateResponse $gateResponse.error
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "preclaim_gate_failed" "MCP pre-claim $toolName failed transport validation ($reason): $detail"
      }
    }

    $sessionCheck = Test-ResponseSessionHeader $gateResponse $SessionId "pre-claim $toolName"
    if (-not $sessionCheck.ok) {
      return $sessionCheck
    }

    $gatePayload = ConvertFrom-JsonResponse $gateResponse.content "pre-claim $toolName"
    $gateReason = Get-JsonRpcErrorReason $gatePayload
    if ($ExpectedPreClaimGateReasons -notcontains $gateReason) {
      $detail = Get-JsonRpcErrorMessage $gatePayload
      if ([string]::IsNullOrWhiteSpace($detail)) {
        $detail = "call unexpectedly succeeded"
      }

      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "preclaim_gate_failed" "MCP pre-claim $toolName was not claim/permission gated: $detail" @{
          tool = $toolName
          reason = $gateReason
        }
      }
    }

    $gatedTools += $toolName
  }

  return [pscustomobject]@{
    ok = $true
    gatedTools = $gatedTools
  }
}

function Invoke-PreClaimReadSmoke([string]$SessionId) {
  $readTools = @()
  foreach ($call in $ExpectedTrustedLocalPreClaimReadCalls) {
    $toolName = [string]$call.name
    $readResponse = Invoke-McpPost $Url (New-ToolCallRequest "sympp-http-smoke-preclaim-read-$toolName" $toolName $call.arguments) $SessionId
    if (-not $readResponse.ok) {
      $reason = if ($readResponse.statusCode) { "HTTP $($readResponse.statusCode)" } else { "request failed" }
      $detail = Get-ResponseErrorDetail $readResponse $readResponse.error
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "preclaim_read_failed" "MCP trusted-local pre-claim read $toolName failed transport validation ($reason): $detail"
      }
    }

    $sessionCheck = Test-ResponseSessionHeader $readResponse $SessionId "trusted-local pre-claim read $toolName"
    if (-not $sessionCheck.ok) {
      return $sessionCheck
    }

    $readPayload = ConvertFrom-JsonResponse $readResponse.content "trusted-local pre-claim read $toolName"
    $readReason = Get-JsonRpcErrorReason $readPayload
    $readError = Get-JsonRpcErrorMessage $readPayload
    if ([string]::IsNullOrWhiteSpace($readReason)) {
      if (-not [string]::IsNullOrWhiteSpace($readError)) {
        return [pscustomobject]@{
          ok = $false
          result = New-SmokeResult "preclaim_read_failed" "MCP trusted-local pre-claim read $toolName returned a JSON-RPC error without a reason: $readError" @{
            tool = $toolName
            reason = $null
          }
        }
      }

      $readTools += "${toolName}:ok"
      continue
    }

    if ($ExpectedPreClaimGateReasons -contains $readReason) {
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "preclaim_read_claim_gated" "MCP trusted-local pre-claim read $toolName was still claim/permission gated: $readError" @{
          tool = $toolName
          reason = $readReason
        }
      }
    }

    $allowedReasons = @($call.allowedReasons)
    if ($allowedReasons -contains $readReason) {
      $readTools += "${toolName}:$readReason"
      continue
    }

    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "preclaim_read_failed" "MCP trusted-local pre-claim read $toolName returned an unexpected error: $readError" @{
        tool = $toolName
        reason = $readReason
      }
    }
  }

  return [pscustomobject]@{
    ok = $true
    readTools = $readTools
  }
}

function Invoke-McpSmoke {
  $session = Initialize-HealthyMcpSession $false
  if (-not $session.ok) {
    return $session.result
  }

  if ($SkipUnboundTools) {
    return New-SmokeResult "ok" "Local Symphony++ HTTP MCP daemon is initialized and passed health/source checks." @{
      mode = "unbound_health"
      sessionId = $session.sessionId
      daemonSourceRevision = $session.sourceRevision
      expectedSourceRevision = $session.expectedRevision
    }
  }

  $toolsCheck = Invoke-ToolsListSmoke $session.sessionId $ExpectedUnboundTools "unbound" $ForbiddenUnboundTools
  if (-not $toolsCheck.ok) {
    return $toolsCheck.result
  }

  $preClaimRead = Invoke-PreClaimReadSmoke $session.sessionId
  if (-not $preClaimRead.ok) {
    return $preClaimRead.result
  }

  $preClaimGate = Invoke-PreClaimGateSmoke $session.sessionId
  if (-not $preClaimGate.ok) {
    return $preClaimGate.result
  }

  return New-SmokeResult "ok" "Local Symphony++ HTTP MCP daemon is initialized and exposes the expected unbound tools." @{
    sessionId = $session.sessionId
    daemonSourceRevision = $session.sourceRevision
    expectedSourceRevision = $session.expectedRevision
    tools = $toolsCheck.tools
    preClaimReadTools = $preClaimRead.readTools
    preClaimGatedTools = $preClaimGate.gatedTools
  }
}

function Invoke-BoundMcpSmoke($Config) {
  $session = Initialize-HealthyMcpSession $true
  if (-not $session.ok) {
    return $session.result
  }

  $unboundTools = @()
  $preClaimReadTools = @()
  $preClaimGatedTools = @()
  if (-not $SkipUnboundTools) {
    $unbound = Invoke-ToolsListSmoke $session.sessionId $ExpectedUnboundTools "unbound pre-claim" $ForbiddenUnboundTools
    if (-not $unbound.ok) {
      return $unbound.result
    }

    $unboundTools = $unbound.tools

    $preClaimRead = Invoke-PreClaimReadSmoke $session.sessionId
    if (-not $preClaimRead.ok) {
      return $preClaimRead.result
    }

    $preClaimGate = Invoke-PreClaimGateSmoke $session.sessionId
    if (-not $preClaimGate.ok) {
      return $preClaimGate.result
    }

    $preClaimReadTools = $preClaimRead.readTools
    $preClaimGatedTools = $preClaimGate.gatedTools
  }

  $claimResponse = Invoke-McpPost $Url (New-ToolCallRequest "sympp-http-smoke-claim" "claim_local_assignment" @{
      work_package_id = $Config.workPackageId
      claimed_by = $Config.claimedBy
    }) $session.sessionId

  if (-not $claimResponse.ok) {
    $reason = if ($claimResponse.statusCode) { "HTTP $($claimResponse.statusCode)" } else { "request failed" }
    $detail = Get-ResponseErrorDetail $claimResponse $claimResponse.error
    return New-SmokeResult "claim_failed" "MCP claim_local_assignment failed ($reason): $detail"
  }

  $claimedSessionId = Get-ResponseHeaderValue $claimResponse.headers "Mcp-Session-Id"
  Add-SensitiveValue $claimedSessionId
  if ([string]::IsNullOrWhiteSpace($claimedSessionId)) {
    return New-SmokeResult "missing_claimed_session_id" "MCP claim_local_assignment succeeded but did not return Mcp-Session-Id."
  }

  if ($claimedSessionId -ne $session.sessionId) {
    return New-SmokeResult "session_id_mismatch" "MCP claim_local_assignment did not preserve the initialized Mcp-Session-Id."
  }

  $claimPayload = ConvertFrom-JsonResponse $claimResponse.content "claim_local_assignment"
  $claimError = Get-JsonRpcErrorMessage $claimPayload
  if ($claimError) {
    return New-SmokeResult "claim_failed" "MCP claim_local_assignment returned JSON-RPC error: $claimError"
  }

  $workPackageId = Get-AssignmentWorkPackageId $claimPayload
  if ([string]::IsNullOrWhiteSpace($workPackageId)) {
    return New-SmokeResult "claim_assignment_missing" "MCP claim_local_assignment response did not include assignment.work_package_id."
  }

  $boundTools = Invoke-ToolsListSmoke $claimedSessionId $ExpectedBoundWorkerTools "bound worker" $ForbiddenBoundWorkerTools
  if (-not $boundTools.ok) {
    return $boundTools.result
  }

  $assignmentToolResponse = Invoke-McpPost $Url (New-ToolCallRequest "sympp-http-smoke-assignment" "get_current_assignment" @{}) $claimedSessionId
  if (-not $assignmentToolResponse.ok) {
    $reason = if ($assignmentToolResponse.statusCode) { "HTTP $($assignmentToolResponse.statusCode)" } else { "request failed" }
    $detail = Get-ResponseErrorDetail $assignmentToolResponse $assignmentToolResponse.error
    return New-SmokeResult "assignment_tool_failed" "MCP get_current_assignment failed with claimed session ($reason): $detail"
  }

  $sessionCheck = Test-ResponseSessionHeader $assignmentToolResponse $claimedSessionId "get_current_assignment"
  if (-not $sessionCheck.ok) {
    return $sessionCheck.result
  }

  $assignmentToolPayload = ConvertFrom-JsonResponse $assignmentToolResponse.content "get_current_assignment"
  $assignmentToolError = Get-JsonRpcErrorMessage $assignmentToolPayload
  if ($assignmentToolError) {
    return New-SmokeResult "assignment_tool_failed" "MCP get_current_assignment returned JSON-RPC error: $assignmentToolError"
  }

  $assignmentToolWorkPackageId = Get-AssignmentWorkPackageId $assignmentToolPayload
  if ($assignmentToolWorkPackageId -ne $workPackageId) {
    return New-SmokeResult "assignment_mismatch" "MCP get_current_assignment returned a different WorkPackage id than claim_local_assignment."
  }

  $assignmentResourceResponse = Invoke-McpPost $Url (New-ResourcesReadRequest "sympp://assignment/current") $claimedSessionId
  if (-not $assignmentResourceResponse.ok) {
    $reason = if ($assignmentResourceResponse.statusCode) { "HTTP $($assignmentResourceResponse.statusCode)" } else { "request failed" }
    $detail = Get-ResponseErrorDetail $assignmentResourceResponse $assignmentResourceResponse.error
    return New-SmokeResult "assignment_resource_failed" "MCP resources/read sympp://assignment/current failed with claimed session ($reason): $detail"
  }

  $sessionCheck = Test-ResponseSessionHeader $assignmentResourceResponse $claimedSessionId "resources/read sympp://assignment/current"
  if (-not $sessionCheck.ok) {
    return $sessionCheck.result
  }

  $assignmentResourcePayload = ConvertFrom-JsonResponse $assignmentResourceResponse.content "resources/read"
  $assignmentResourceError = Get-JsonRpcErrorMessage $assignmentResourcePayload
  if ($assignmentResourceError) {
    return New-SmokeResult "assignment_resource_failed" "MCP resources/read sympp://assignment/current returned JSON-RPC error: $assignmentResourceError"
  }

  $assignmentResource = Get-ResourceJsonPayload $assignmentResourcePayload "resources/read sympp://assignment/current"
  if ([string]$assignmentResource.work_package_id -ne $workPackageId) {
    return New-SmokeResult "assignment_resource_mismatch" "MCP assignment resource returned a different WorkPackage id than claim_local_assignment."
  }

  $resourcesResponse = Invoke-McpPost $Url (New-ResourcesListRequest) $claimedSessionId
  if (-not $resourcesResponse.ok) {
    $reason = if ($resourcesResponse.statusCode) { "HTTP $($resourcesResponse.statusCode)" } else { "request failed" }
    $detail = Get-ResponseErrorDetail $resourcesResponse $resourcesResponse.error
    return New-SmokeResult "resources_list_failed" "MCP resources/list failed with claimed session ($reason): $detail"
  }

  $sessionCheck = Test-ResponseSessionHeader $resourcesResponse $claimedSessionId "resources/list"
  if (-not $sessionCheck.ok) {
    return $sessionCheck.result
  }

  $resourcesPayload = ConvertFrom-JsonResponse $resourcesResponse.content "resources/list"
  $resourcesError = Get-JsonRpcErrorMessage $resourcesPayload
  if ($resourcesError) {
    return New-SmokeResult "resources_list_failed" "MCP resources/list returned JSON-RPC error: $resourcesError"
  }

  $resourceUris = Get-ResourceUris $resourcesPayload
  $expectedResources = @("sympp://assignment/current")
  foreach ($fileName in $ExpectedWorkerResourceFiles) {
    $expectedResources += "sympp://work-packages/$workPackageId/$fileName"
  }

  $missingResources = @($expectedResources | Where-Object { $resourceUris -notcontains $_ })
  if ($missingResources.Count -gt 0) {
    return New-SmokeResult "missing_expected_resources" "MCP resources/list is missing expected bound worker resources: $($missingResources -join ', ')." @{
      resources = $resourceUris
      missingResources = $missingResources
    }
  }

  $data = @{
    mode = "bound_worker"
    claimedBy = $Config.claimedBy
    requestedWorkPackageId = $Config.workPackageId
    sessionId = $RedactedValue
    sessionIdRedacted = $true
    daemonSourceRevision = $session.sourceRevision
    expectedSourceRevision = $session.expectedRevision
    workPackageId = $workPackageId
    tools = $boundTools.tools
    resources = $resourceUris
  }

  if (-not $SkipUnboundTools) {
    $data["unboundTools"] = $unboundTools
    $data["preClaimReadTools"] = $preClaimReadTools
    $data["preClaimGatedTools"] = $preClaimGatedTools
  }

  return New-SmokeResult "ok" "Local Symphony++ HTTP MCP daemon claimed the WorkPackage and exposes the expected bound worker tools/resources." $data
}

function Invoke-SelfTest {
  $dictionary = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $dictionary["Mcp-Session-Id"] = @("state-key-one", "ignored")
  $normalized = Get-ResponseHeaderValue $dictionary "mcp-session-id"
  if ($normalized -ne "state-key-one") {
    throw "Expected first header-array value to be used, got '$normalized'."
  }

  $customHeaders = [pscustomobject]@{
    "mcp-session-id" = @("state-key-two")
  }
  $normalized = Get-ResponseHeaderValue $customHeaders "Mcp-Session-Id"
  if ($normalized -ne "state-key-two") {
    throw "Expected PSCustomObject header value to be used, got '$normalized'."
  }

  if ((Get-ResponseHeaderValue @{} "Mcp-Session-Id") -ne $null) {
    throw "Expected missing header to normalize to null."
  }

  $webHeaders = [System.Net.WebHeaderCollection]::new()
  $webHeaders.Add("Mcp-Session-Id", "state-key-three")
  $normalized = Get-ResponseHeaderValue $webHeaders "mcp-session-id"
  if ($normalized -ne "state-key-three") {
    throw "Expected WebHeaderCollection header value to be used, got '$normalized'."
  }

  $duplicateWebHeaders = [System.Net.WebHeaderCollection]::new()
  $duplicateWebHeaders.Add("Mcp-Session-Id", "state-key-four")
  $duplicateWebHeaders.Add("Mcp-Session-Id", "ignored")
  $normalized = Get-ResponseHeaderValue $duplicateWebHeaders "Mcp-Session-Id"
  if ($normalized -ne "state-key-four") {
    throw "Expected first duplicated WebHeaderCollection value to be used, got '$normalized'."
  }

  $sessionCheck = Test-ResponseSessionHeader ([pscustomobject]@{ headers = @{ "Mcp-Session-Id" = "expected-session" } }) "expected-session" "self-test"
  if (-not $sessionCheck.ok) {
    throw "Expected matching session header to pass continuity validation."
  }

  $sessionCheck = Test-ResponseSessionHeader ([pscustomobject]@{ headers = @{ "Mcp-Session-Id" = "rotated-session" } }) "expected-session" "self-test"
  if ($sessionCheck.ok -or $sessionCheck.result.status -ne "session_id_mismatch") {
    throw "Expected mismatched session header to fail continuity validation."
  }

  if ($ExpectedUnboundTools -notcontains "claim_local_assignment" -or $ExpectedUnboundTools -notcontains "claim_local_architect_assignment") {
    throw "Expected unbound discovery to include local HTTP claim tools."
  }

  if ($ExpectedHttpUnboundTools -notcontains "create_work_request") {
    throw "Expected trusted local HTTP unbound discovery to include safe bootstrap tools."
  }

  if ($ExpectedHttpUnboundTools -notcontains "add_work_request_comment" -or $ExpectedHttpUnboundTools -notcontains "record_work_request_operator_decision") {
    throw "Expected trusted local HTTP unbound discovery to require safe operator note tools."
  }

  if ($ForbiddenUnboundTools -contains "add_work_request_comment" -or $ForbiddenUnboundTools -contains "record_work_request_operator_decision") {
    throw "Expected unbound forbidden tools to allow trusted local operator note tools."
  }

  if ($ExpectedUnboundTools -notcontains "append_progress" -or $ExpectedUnboundTools -notcontains "get_current_assignment") {
    throw "Expected unbound discovery to include worker scoped schemas."
  }

  if ($ExpectedUnboundTools -notcontains "read_work_request" -or $ExpectedUnboundTools -notcontains "read_plan" -or $ExpectedUnboundTools -notcontains "dispatch_slice" -or $ExpectedUnboundTools -notcontains "read_delivery_board") {
    throw "Expected unbound discovery to include architect scoped schemas."
  }

  if ($ForbiddenUnboundTools.Count -ne 0) {
    throw "Expected unbound discovery to treat schema visibility as authorization-neutral."
  }

  if ($ForbiddenUnboundTools -contains "claim_local_assignment" -or $ForbiddenUnboundTools -contains "sympp.health") {
    throw "Expected unbound forbidden tools to keep health and local claim tools allowed."
  }

  $preClaimReadNames = @($ExpectedTrustedLocalPreClaimReadCalls | ForEach-Object { [string]$_.name })
  if ($preClaimReadNames -notcontains "read_work_request" -or $preClaimReadNames -notcontains "read_plan" -or $preClaimReadNames -notcontains "read_delivery_board") {
    throw "Expected trusted-local pre-claim smoke to verify read-only WorkRequest calls."
  }

  $preClaimGateNames = @($ExpectedPreClaimGatedCalls | ForEach-Object { [string]$_.name })
  if ($preClaimGateNames -contains "read_work_request") {
    throw "Expected pre-claim smoke to treat read_work_request as trusted-local read validation, not a claim-gated call."
  }

  if ($preClaimGateNames -notcontains "dispatch_slice" -or $preClaimGateNames -notcontains "read_context") {
    throw "Expected pre-claim smoke to verify mutation and worker context calls remain gated."
  }

  if ($ForbiddenBoundWorkerTools -notcontains "list_work_requests" -or $ForbiddenBoundWorkerTools -notcontains "dispatch_slice") {
    throw "Expected bound worker forbidden tools to include architect-only tools."
  }

  if ($ForbiddenBoundWorkerTools -notcontains "claim_local_assignment") {
    throw "Expected bound worker forbidden tools to include unbound claim tools."
  }

  if ($ArchitectTools -notcontains "read_guidance_request") {
    throw "Expected full architect surface to include shared read_guidance_request."
  }

  if ($ForbiddenBoundWorkerTools -contains "read_guidance_request") {
    throw "Expected shared worker guidance read tool to remain allowed for bound workers."
  }

  $healthPayload = @{
    result = @{
      structuredContent = @{
        source = @{
          revision = "ABCDEF1234567890ABCDEF1234567890ABCDEF12"
        }
      }
    }
  } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  if ((Get-HealthSourceRevision $healthPayload) -ne "abcdef1234567890abcdef1234567890abcdef12") {
    throw "Expected health source revision extraction to normalize daemon revisions."
  }

  $missingSourcePayload = @{ result = @{ structuredContent = @{} } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  if ($null -ne (Get-HealthSourceRevision $missingSourcePayload)) {
    throw "Expected missing health source revision to normalize to null."
  }

  $jsonRpcErrorWithoutReason = @{
    error = @{
      message = "synthetic bridge error"
    }
  } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  if ($null -ne (Get-JsonRpcErrorReason $jsonRpcErrorWithoutReason)) {
    throw "Expected JSON-RPC errors without data.reason to normalize to a null reason."
  }
  if ((Get-JsonRpcErrorMessage $jsonRpcErrorWithoutReason) -ne "synthetic bridge error") {
    throw "Expected JSON-RPC errors without data.reason to preserve their message."
  }

  $resourcePayload = @{
    result = @{
      contents = @(
        @{
          uri = "sympp://assignment/current"
          mimeType = "text/vnd.toon"
          text = "work_package_id: wp_toon"
        },
        @{
          uri = "sympp://assignment/current"
          mimeType = "Application/JSON; charset=utf-8"
          text = '{"work_package_id":"wp_json"}'
        }
      )
    }
  } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $resourceJson = Get-ResourceJsonPayload $resourcePayload "resources/read self-test"
  if ([string]$resourceJson.work_package_id -ne "wp_json") {
    throw "Expected resource JSON parsing to prefer application/json over TOON presentation text."
  }

  if ((Normalize-SourceRevision "0123456789ABCDEF0123456789ABCDEF01234567") -ne "0123456789abcdef0123456789abcdef01234567") {
    throw "Expected source revision normalization to lower-case valid git SHAs."
  }

  $invalidRevisionThrew = $false
  try {
    [void](Normalize-SourceRevision "not-a-sha")
  } catch {
    $invalidRevisionThrew = $true
  }
  if (-not $invalidRevisionThrew) {
    throw "Expected invalid source revisions to fail validation."
  }

  $script:SensitiveValues.Clear()
  Add-SensitiveValue "secret-value-for-self-test"
  Add-SensitiveValue "claimed-session-for-self-test"
  $redactedJson = ConvertTo-RedactedJson (New-SmokeResult "ok" "secret-value-for-self-test claimed-session-for-self-test" @{
      secret = "secret-value-for-self-test"
      sessionId = "claimed-session-for-self-test"
    })
  if ($redactedJson -match "secret-value-for-self-test" -or $redactedJson -match "claimed-session-for-self-test") {
    throw "Expected JSON smoke output redaction to remove raw secret and claimed session values."
  }

  if ($redactedJson -notmatch [regex]::Escape($RedactedValue)) {
    throw "Expected JSON smoke output redaction marker to be present."
  }

  $resolved = Resolve-BoundSmokeConfig $true "WP-SMOKE-SELFTEST" "worker-self-test"
  if (-not $resolved.ok -or $resolved.workPackageId -ne "WP-SMOKE-SELFTEST" -or $resolved.claimedBy -ne "worker-self-test") {
    throw "Expected bound smoke argument resolution to accept a WorkPackage id and owner."
  }

  $defaultOwner = Resolve-BoundSmokeConfig $true "WP-SMOKE-SELFTEST" ""
  if (-not $defaultOwner.ok -or $defaultOwner.claimedBy -ne "sympp-http-smoke") {
    throw "Expected bound smoke argument resolution to default the claimed_by owner."
  }

  $script:SkipUnboundTools = $true
  try {
    $unboundSkip = Resolve-BoundSmokeConfig $false "" ""
    if (-not $unboundSkip.ok -or $unboundSkip.bound) {
      throw "Expected -SkipUnboundTools without -Bound to remain a valid unbound health/source smoke."
    }
  }
  finally {
    $script:SkipUnboundTools = $false
  }

  $missingPackage = Resolve-BoundSmokeConfig $true "" "worker-self-test"
  if ($missingPackage.ok -or $missingPackage.result.status -ne "invalid_arguments") {
    throw "Expected missing WorkPackage id to fail bound smoke validation."
  }

  $unexpectedBoundArgument = Resolve-BoundSmokeConfig $false "WP-SMOKE-SELFTEST" ""
  if ($unexpectedBoundArgument.ok -or $unexpectedBoundArgument.result.status -ne "invalid_arguments") {
    throw "Expected bound arguments without -Bound to fail validation."
  }

  return New-SmokeResult "ok" "PowerShell header normalization, source revision, redaction, and bound argument validation self-test passed."
}

function Invoke-StaticSmokeValidation {
  [void](Invoke-SelfTest)
  return New-SmokeResult "ok" "Static Symphony++ MCP contract, source revision, redaction, and bound argument validation passed; live server probe skipped."
}

try {
  if ($SelfTest) {
    Write-SmokeResult (Invoke-SelfTest) 0
  }

  $config = Resolve-BoundSmokeConfig ([bool]($Bound -and -not $SkipBound)) $WorkPackageId $ClaimedBy
  if (-not $config.ok) {
    Write-SmokeResult $config.result 1
  }

  if ($SkipLiveServer) {
    Write-SmokeResult (Invoke-StaticSmokeValidation) 0
  }

  $result = if ($config.bound) { Invoke-BoundMcpSmoke $config } else { Invoke-McpSmoke }
  $exitCode = if ($result.status -eq "ok") { 0 } else { 1 }
  Write-SmokeResult $result $exitCode
}
catch {
  $result = New-SmokeResult "script_error" $_.Exception.Message
  Write-SmokeResult $result 1
}
