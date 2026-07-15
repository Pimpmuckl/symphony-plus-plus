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
    "Normalize-McpContractFingerprint", "Get-McpContractFingerprintFromContractFile",
    "Get-McpContractFingerprintFromMarketplaceSource", "Resolve-LocalMcpContractFingerprint",
    "New-RuntimeKey", "Get-RuntimeStateKey", "Get-PortFromOrigin", "Test-EndpointMatches",
    "Test-PortSelectionAllowsReuse", "Test-BackendContractMatches", "Test-BackendLaunchCompatible",
    "Test-RuntimeStateExternalLoopback", "New-ReusedBackendPlan", "New-ReusedDashboardPlan",
    "Resolve-LocalWarmAttachIdentity", "Resolve-FastAttachRuntimePlan"
  )) {
  Import-ScriptFunction $scriptPath $name
}
function Write-CompatibleSourceMismatchDiagnostic { }
$pluginRoot = Join-Path $repoRoot "plugins/symphony-plus-plus-mcp"
$fingerprint = Resolve-LocalMcpContractFingerprint $pluginRoot
Assert-True (-not [string]::IsNullOrWhiteSpace($fingerprint)) "Current local MCP contract must resolve without artifact metadata"
$backendUrl = "http://127.0.0.1:19998"
$runtimeKey = New-RuntimeKey $backendUrl $backendUrl $fingerprint
$state = [pscustomobject]@{
  plugin_root = $pluginRoot
  runtime_key = $runtimeKey
  runtime_mode = "artifact"
  backend = [pscustomobject]@{
    status = "started"; url = $backendUrl; managed = $true; pid = $PID
    expected_contract_fingerprint = $fingerprint; contract_fingerprint = $fingerprint; source_revision = "b" * 40
  }
  frontend = [pscustomobject]@{ status = "artifact_static"; origin = $backendUrl; managed = $false; pid = $null }
}
$identity = Resolve-LocalWarmAttachIdentity $state $pluginRoot 19998 19999 $false $false $null $null
Assert-True ($null -ne $identity) "Current-contract artifact-static runtime should be eligible for PowerShell fallback warm attach"
Assert-True ($null -eq (Resolve-LocalWarmAttachIdentity $state $pluginRoot 20000 19999 $true $false $null $null)) "Explicit backend port mismatch must reject fallback warm attach"
Assert-True ($null -eq (Resolve-LocalWarmAttachIdentity $state (Join-Path $pluginRoot "other") 19998 19999 $false $false $null $null)) "Different plugin payload must reject fallback warm attach"
$staleFingerprint = $(if ($fingerprint[0] -eq "0") { "1" } else { "0" }) + $fingerprint.Substring(1)
$staleState = $state | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$staleState.runtime_key = New-RuntimeKey $backendUrl $backendUrl $staleFingerprint
$staleState.backend.expected_contract_fingerprint = $staleFingerprint
$staleState.backend.contract_fingerprint = $staleFingerprint
Assert-True ($null -eq (Resolve-LocalWarmAttachIdentity $staleState $pluginRoot 19998 19999 $false $false $null $null)) "Stale fallback state must take the cold validation path"
$health = [pscustomobject]@{ healthy = $true; source_revision = $state.backend.source_revision; contract_fingerprint = $fingerprint }
$plan = Resolve-FastAttachRuntimePlan $state $state.backend.source_revision $fingerprint 0 0 $false $false $null $null $health $true $true
Assert-True ($null -ne $plan -and -not $plan.dashboard_plan.managed) "Artifact-static runtime should produce an unmanaged-dashboard fallback plan"
$source = Get-Content -LiteralPath $scriptPath -Raw
$warmCall = $source.LastIndexOf("if (Invoke-WarmAttachFromRuntimeState")
$artifactCall = $source.LastIndexOf('Resolve-SymppArtifactProbe $pluginRoot')
$coldLock = $source.LastIndexOf('$startupLock = Enter-FileLock')
$coldPlan = $source.LastIndexOf('$backendPlan = Resolve-BackendPlan')
Assert-True ($artifactCall -ge 0) "Cold launcher must retain artifact probing"
Assert-True ($warmCall -ge 0 -and $warmCall -lt $artifactCall) "PowerShell fallback warm attach must run before artifact probing"
Assert-True ($coldLock -ge 0 -and $coldLock -lt $coldPlan) "Cold singleton planning must remain under the startup lock"
Assert-True ((@([regex]::Matches($source, 'Resolve-SymppArtifactProbe \$pluginRoot[^\r\n]+')).Count -eq 2) -and -not $source.Contains('-ValidateOnly:$ValidateOnly')) "Fallback artifact probes must stay metadata-only until backend startup is required"

$mcp = Get-Content -LiteralPath (Join-Path $pluginRoot ".mcp.json") -Raw | ConvertFrom-Json
$server = $mcp.symphony_plus_plus
Assert-True ($server.command -eq "cmd.exe" -and (@($server.args) -join " ") -eq "/d /s /c scripts\start-sympp-mcp.cmd") "Shipped MCP config must exercise the bootstrap command exactly"
$cmdPath = Join-Path $pluginRoot "scripts/start-sympp-mcp.cmd"
$nodePath = Join-Path $pluginRoot "scripts/start-sympp-mcp-bridge.js"
$cmd = Get-Content -LiteralPath $cmdPath -Raw
$node = Get-Content -LiteralPath $nodePath -Raw
$preflightCall = $node.IndexOf('if (!await preflightRuntimeHealth')
$stdinRead = $node.IndexOf('readline.createInterface')
Assert-True ($cmd.Contains('%%~$PATH:I') -and -not $cmd.Contains('where node.exe') -and $cmd.Contains('-PrepareRuntimeOnly') -and $cmd.Contains('if "%bridge_exit%"=="42" goto :run_pwsh')) "Bootstrap must select Node without a per-client discovery process and preserve PowerShell fallback after preparation"
Assert-True ($cmd.Contains('-CleanupPreparedRuntime') -and $source.Contains('if ($CleanupPreparedRuntime)')) "Unexpected post-prepare Node failures must clean an unleased managed runtime"
Assert-True ($source.Contains('if ($PrepareRuntimeOnly)') -and $source.IndexOf('if ($PrepareRuntimeOnly)') -lt $source.LastIndexOf('Invoke-HttpMcpBridge')) "Prepared cold runtime must exit before any PowerShell stdio bridge"
Assert-True ($preflightCall -ge 0 -and $preflightCall -lt $stdinRead -and $node.Contains('trace("warm_miss_health");')) "Node health mismatches must route through cold recovery before consuming stdin"
Assert-True ($node.Contains('/mcp/readiness') -and $node.Contains('response.status === 404') -and $node.Contains('legacyBackendHealth')) "Node launcher health probes must prefer stateless readiness and retain a 404-only legacy runtime fallback"
Assert-True ($source.Contains('/mcp/readiness') -and $source.Contains('StatusCode -eq 404') -and $source.Contains('Get-LegacySymppBackendHealth')) "PowerShell launcher health probes must prefer stateless readiness and retain a 404-only legacy runtime fallback"
Assert-True ($node.Contains('backendHealth(identity.backend, !identity.headless)') -and $node.Contains('!requireDashboard || dashboardReady')) "Node backend readiness must preserve supported headless runtime reuse"
Assert-True ($source.Contains('[bool]$RequireDashboardReady = $false') -and $source.Contains('Get-SymppBackendHealthWithRetry $DashboardOrigin 2 250 $true')) "PowerShell backend readiness must preserve headless reuse while dashboard proxy checks remain strict"
Assert-True ($node.Contains('confirmed.runtimeKey.toLowerCase()') -and $node.Contains('trace("warm_miss_state");')) "Concurrent runtime rotation must route through cold recovery"
Assert-True ($node.Contains('/^(disabled|failed)/.test(String(state.frontend.status))')) "Node warm attach must accept every launcher-produced disabled or failed headless status"
Assert-True ($node.Contains('SYMPP_STARTUP_LOCK_TIMEOUT_SEC || 1800') -and $node.Contains('trace("warm_miss_lock");')) "Node startup locking must honor the configured timeout and remain recoverable"
Assert-True ((@([regex]::Matches($node, 'require\("([^./][^"]*)"\)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ",") -eq "child_process,crypto,fs,http,net,os,path,readline") "Node bridge must use standard-library modules only"
& (Get-Command node.exe -ErrorAction Stop).Source --check $nodePath
Assert-True ($LASTEXITCODE -eq 0) "Node bridge must parse"
& (Get-Command node.exe -ErrorAction Stop).Source $nodePath --runtime-supported
Assert-True ($LASTEXITCODE -eq 0) "Current Node runtime must satisfy the conservative bridge check"
$process = Get-Process -Id $PID
$startIdentity = Get-ProcessStartIdentity $process
$processMap = @{ [string]$PID = [pscustomobject]@{ exists = $true; start_time_utc_ticks = $startIdentity } }
$liveLease = [pscustomobject]@{ pid = $PID; process_start_time_utc_ticks = $startIdentity; created_at = [DateTimeOffset]::UtcNow.ToString("o") }
$reusedPidLease = [pscustomobject]@{ pid = $PID; process_start_time_utc_ticks = "1"; created_at = [DateTimeOffset]::UtcNow.ToString("o") }
Assert-True (Test-BridgeLeaseActive $liveLease $processMap) "Matching PID/start identity must stay live"
Assert-True (-not (Test-BridgeLeaseActive $reusedPidLease $processMap)) "Reused PID identity must be stale"
$livenessPath = [System.IO.Path]::GetTempFileName()
try {
  [System.IO.File]::WriteAllText($livenessPath, "node-lease-token")
  $nodeLease = [pscustomobject]@{ pid = $PID; process_liveness_pipe = $livenessPath; process_liveness_token = "node-lease-token" }
  Assert-True (Test-BridgeLeaseActive $nodeLease $processMap) "Matching Node liveness token must stay live"
  $nodeLease.process_liveness_token = "reused-process-token"
  Assert-True (-not (Test-BridgeLeaseActive $nodeLease $processMap)) "Mismatched Node liveness token must be stale"
} finally {
  Remove-Item -LiteralPath $livenessPath -Force -ErrorAction SilentlyContinue
}
Assert-True (-not (Test-BridgeLeaseActive $liveLease @{})) "Missing process must be stale"
Assert-True ((Get-Content -LiteralPath $helperPath -Raw) -notmatch 'Get-CimInstance|Get-WmiObject') "Lease validation must not use CIM/WMI"

$generationRoot = Join-Path $PSScriptRoot (".generation-" + [guid]::NewGuid().ToString("N"))
try {
  $installedRoot = Join-Path $generationRoot "installed"
  $sourceRoot = Join-Path $generationRoot "source"
  $sourcePluginRoot = Join-Path $sourceRoot "plugin"
  foreach ($directory in @($installedRoot, $sourcePluginRoot, (Join-Path $sourceRoot "implementation_docs_symphplusplus/mcp"))) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  Set-Content -LiteralPath (Join-Path $installedRoot "payload.txt") -Value "first" -NoNewline
  Set-Content -LiteralPath (Join-Path $sourcePluginRoot "payload.txt") -Value "first" -NoNewline
  Set-Content -LiteralPath (Join-Path $installedRoot ".sympp-source-revision") -Value ("a" * 40) -NoNewline
  Set-Content -LiteralPath (Join-Path $sourceRoot ".codex-marketplace-install.json") -Value "{}" -NoNewline
  Set-Content -LiteralPath (Join-Path $sourceRoot "implementation_docs_symphplusplus/mcp/mcp_tools_contract.json") -Value "{}" -NoNewline
  $payloadPath = Join-Path $installedRoot "payload.txt"
  $originalWriteTime = [System.IO.File]::GetLastWriteTimeUtc($payloadPath)
  $beforeGeneration = Get-SymppPluginGenerationKey $installedRoot $sourcePluginRoot $sourceRoot
  Set-Content -LiteralPath $payloadPath -Value "other" -NoNewline
  [System.IO.File]::SetLastWriteTimeUtc($payloadPath, $originalWriteTime)
  $afterGeneration = Get-SymppPluginGenerationKey $installedRoot $sourcePluginRoot $sourceRoot
  Assert-True ($beforeGeneration -ne $afterGeneration) "Generation identity must detect same-length payload replacement with restored mtime"
} finally {
  Remove-Item -LiteralPath $generationRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$benchmark = & (Join-Path $PSScriptRoot "warm-attach-benchmark.ps1") | ConvertFrom-Json
Assert-True ($benchmark.clients -eq 100 -and $benchmark.p95_ms -lt 2000) "100-client PowerShell fallback warm attach p95 must stay below 2 seconds"
Assert-True ($benchmark.backend_processes -eq 1 -and $benchmark.leases_peak -eq 100 -and $benchmark.leases_after -eq 0) "Fallback warm burst must preserve one listener and exact lease lifecycle"
Assert-True ($benchmark.remote_resolution_attempts -eq 0) "Fallback warm burst must make zero artifact or remote resolution attempts"
$coldSmoke = & (Join-Path $PSScriptRoot "cold-start-singleton-smoke.ps1") | ConvertFrom-Json
Assert-True ($coldSmoke.clients -eq 20 -and $coldSmoke.singleton_creations -eq 1 -and $coldSmoke.backend_processes -eq 1) "Concurrent production cold clients must create exactly one backend"
Assert-True ($coldSmoke.isolated_roots -and $coldSmoke.preflight_listeners -eq 0) "Cold smoke must prove isolated roots and empty unique ports before launch"

Write-Host "Launcher bootstrap, contract freshness, cold singleton, and lease identity regressions passed."
