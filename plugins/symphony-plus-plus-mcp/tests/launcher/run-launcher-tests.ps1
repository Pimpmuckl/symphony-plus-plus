$ErrorActionPreference = "Stop"

function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Import-ScriptFunction([string]$Path, [string]$Name) {
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  Assert-True ($errors.Count -eq 0) "PowerShell parse failed for $Path"
  $functionAst = $ast.Find({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)
  Assert-True ($null -ne $functionAst) "Missing function $Name in $Path"
  $definition = [regex]::Replace($functionAst.Extent.Text, '^function\s+[A-Za-z0-9_-]+', "function script:$Name")
  Invoke-Expression $definition
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../../.."))
$scriptPath = Join-Path $repoRoot "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1"
$helperPath = Join-Path $repoRoot "plugins/symphony-plus-plus-mcp/scripts/sympp-mcp-launcher-helpers.ps1"
. $helperPath

foreach ($name in @(
    "Normalize-McpContractFingerprint",
    "New-RuntimeKey",
    "Get-RuntimeStateKey",
    "Get-PortFromOrigin",
    "Test-EndpointMatches",
    "Test-PortSelectionAllowsReuse",
    "Test-BackendContractMatches",
    "Test-BackendLaunchCompatible",
    "Test-RuntimeStateExternalLoopback",
    "New-ReusedBackendPlan",
    "New-ReusedDashboardPlan",
    "Resolve-LocalWarmAttachIdentity",
    "Resolve-FastAttachRuntimePlan"
  )) {
  Import-ScriptFunction $scriptPath $name
}

function Write-CompatibleSourceMismatchDiagnostic { }

$fingerprint = "a" * 64
$pluginRoot = Join-Path $repoRoot "plugins/symphony-plus-plus-mcp"
$backendUrl = "http://127.0.0.1:19998"
$runtimeKey = New-RuntimeKey $backendUrl $backendUrl $fingerprint
$state = [pscustomobject]@{
  plugin_root = $pluginRoot
  runtime_key = $runtimeKey
  runtime_mode = "artifact"
  backend = [pscustomobject]@{
    status = "started"
    url = $backendUrl
    managed = $true
    pid = $PID
    expected_contract_fingerprint = $fingerprint
    contract_fingerprint = $fingerprint
    source_revision = "b" * 40
  }
  frontend = [pscustomobject]@{
    status = "artifact_static"
    origin = $backendUrl
    managed = $false
    pid = $null
  }
}

$identity = Resolve-LocalWarmAttachIdentity $state $pluginRoot 19998 19999 $false $false $null $null
Assert-True ($null -ne $identity) "Artifact-static runtime should be eligible for local warm attach"
Assert-True ($null -eq (Resolve-LocalWarmAttachIdentity $state $pluginRoot 20000 19999 $true $false $null $null)) "Explicit backend port mismatch must reject warm attach"
Assert-True ($null -eq (Resolve-LocalWarmAttachIdentity $state (Join-Path $pluginRoot "other") 19998 19999 $false $false $null $null)) "Different plugin payload must reject warm attach"

$health = [pscustomobject]@{
  healthy = $true
  source_revision = $state.backend.source_revision
  contract_fingerprint = $fingerprint
}
$plan = Resolve-FastAttachRuntimePlan $state $state.backend.source_revision $fingerprint 0 0 $false $false $null $null $health $true $true
Assert-True ($null -ne $plan) "Artifact-static runtime should produce a fast attach plan"
Assert-True (-not $plan.dashboard_plan.managed) "Artifact-static dashboard must remain unmanaged"
Assert-True ($null -eq (Resolve-FastAttachRuntimePlan $null $null $fingerprint 0 0 $false $false $null $null $health $true $true)) "Missing state must take the cold path"

$source = Get-Content -LiteralPath $scriptPath -Raw
$warmCall = $source.LastIndexOf("if (Invoke-WarmAttachFromRuntimeState")
$artifactCall = $source.LastIndexOf('Resolve-SymppArtifactProbe $pluginRoot')
$coldLock = $source.LastIndexOf('$startupLock = Enter-FileLock')
$coldPlan = $source.LastIndexOf('$backendPlan = Resolve-BackendPlan')
Assert-True ($warmCall -ge 0 -and $warmCall -lt $artifactCall) "Warm attach must run before artifact probing"
Assert-True ($coldLock -ge 0 -and $coldLock -lt $coldPlan) "Cold singleton planning must remain under the startup lock"
$tokens = $null
$errors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
$warmFunction = $scriptAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-WarmAttachFromRuntimeState" }, $true).Extent.Text
Assert-True ($warmFunction -notmatch 'Enter-FileLock|Resolve-SymppArtifactProbe|Invoke-WebRequest') "Warm attach must not take the startup lock or resolve remote artifacts"

$process = Get-Process -Id $PID
$startIdentity = Get-ProcessStartIdentity $process
$processMap = @{ [string]$PID = [pscustomobject]@{ exists = $true; start_time_utc_ticks = $startIdentity } }
$liveLease = [pscustomobject]@{ pid = $PID; process_start_time_utc_ticks = $startIdentity; created_at = [DateTimeOffset]::UtcNow.ToString("o") }
$reusedPidLease = [pscustomobject]@{ pid = $PID; process_start_time_utc_ticks = "1"; created_at = [DateTimeOffset]::UtcNow.ToString("o") }
Assert-True (Test-BridgeLeaseActive $liveLease $processMap) "Matching PID/start identity must stay live"
Assert-True (-not (Test-BridgeLeaseActive $reusedPidLease $processMap)) "Reused PID identity must be stale"
Assert-True (-not (Test-BridgeLeaseActive $liveLease @{})) "Missing process must be stale"
$legacyLive = [pscustomobject]@{ pid = $PID; created_at = [DateTimeOffset]::UtcNow.ToString("o") }
$legacyReused = [pscustomobject]@{ pid = $PID; created_at = $process.StartTime.ToUniversalTime().AddSeconds(-1).ToString("o") }
Assert-True (Test-BridgeLeaseActive $legacyLive $processMap) "Live legacy lease must be preserved"
Assert-True (-not (Test-BridgeLeaseActive $legacyReused $processMap)) "Legacy reused PID must be stale"
Assert-True ((Get-Content -LiteralPath $helperPath -Raw) -notmatch 'Get-CimInstance|Get-WmiObject') "Lease validation must not use CIM/WMI"

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sympp-launcher-tests-" + [guid]::NewGuid().ToString("N"))
try {
  $runtimeFile = Join-Path $tempRoot "runtime.json"
  $backendPlan = [pscustomobject]@{ managed = $false; status = "external_loopback"; source_revision = $state.backend.source_revision; url = $backendUrl }
  $dashboardPlan = [pscustomobject]@{ origin = $backendUrl }
  $leasePath = New-BridgeLease $runtimeFile $backendPlan $dashboardPlan $runtimeKey
  $lease = Get-Content -LiteralPath $leasePath -Raw | ConvertFrom-Json
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$lease.process_start_time_utc_ticks)) "New lease must record process start identity"
  $stalePath = Join-Path (Resolve-BridgeLeaseDir $runtimeFile) "bridge-stale.json"
  [System.IO.File]::WriteAllText($stalePath, (($reusedPidLease | ConvertTo-Json) + "`n"))
  $active = @(Get-ActiveBridgeLeases $runtimeFile)
  Assert-True ($active.Count -eq 1 -and $active[0].path -eq $leasePath) "Lease scan must preserve live identity and remove stale reused PID"
  Assert-True (-not (Test-Path -LiteralPath $stalePath)) "Stale lease file must be removed"
  Assert-True (@(Get-ChildItem (Resolve-BridgeLeaseDir $runtimeFile) -Filter "*.tmp").Count -eq 0) "Lease publication must be atomic"
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$benchmark = & (Join-Path $PSScriptRoot "warm-attach-benchmark.ps1") | ConvertFrom-Json
Assert-True ($benchmark.clients -eq 100 -and $benchmark.p95_ms -lt 2000) "100-client warm attach p95 must stay below 2 seconds"
Assert-True ($benchmark.backend_processes_before -eq 1 -and $benchmark.backend_processes_after -eq 1) "Benchmark must preserve exactly one backend process"
Assert-True ($benchmark.leases_peak -eq 100 -and $benchmark.leases_after -eq 0) "Concurrent clients must publish and remove exactly 100 leases"
Assert-True ($benchmark.remote_network_attempts -eq 0) "Warm benchmark must make zero remote network attempts"
$coldSmoke = & (Join-Path $PSScriptRoot "cold-start-singleton-smoke.ps1") | ConvertFrom-Json
Assert-True ($coldSmoke.singleton_creations -eq 1 -and $coldSmoke.backend_processes -eq 1) "Concurrent cold clients must create exactly one singleton"

Write-Host "Launcher warm/cold, lease identity, and 100-client regression tests passed."
