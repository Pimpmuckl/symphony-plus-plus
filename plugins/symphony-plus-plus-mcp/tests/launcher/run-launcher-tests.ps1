[System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
$ErrorActionPreference = "Stop"
function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}
$inheritedPriority = & (Get-Command pwsh -ErrorAction Stop).Source -NoProfile -NonInteractive -Command '[System.Diagnostics.Process]::GetCurrentProcess().PriorityClass'
Assert-True ([System.Diagnostics.Process]::GetCurrentProcess().PriorityClass -eq [System.Diagnostics.ProcessPriorityClass]::BelowNormal) "Launcher test parent must run BelowNormal"
Assert-True ($inheritedPriority -eq "BelowNormal") "Launcher test descendants must inherit BelowNormal priority"
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
$runtimePath = Join-Path $repoRoot "plugins/symphony-plus-plus-mcp/scripts/sympp-launcher-runtime.ps1"
$artifactRuntimePath = Join-Path $repoRoot "plugins/symphony-plus-plus-mcp/scripts/sympp-mcp-artifact-runtime.ps1"
$processRuntimePath = Join-Path $repoRoot "plugins/symphony-plus-plus-mcp/scripts/sympp-mcp-process-runtime.ps1"
$betaPath = Join-Path $repoRoot "scripts/sympp-beta.ps1"
. $runtimePath
. $helperPath
. $processRuntimePath
$faultedRead = [System.Threading.Tasks.TaskCompletionSource[string]]::new()
$faultedRead.SetException([System.IO.IOException]::new("test read failure"))
$faultedState = [pscustomobject]@{ pending_task = $faultedRead.Task; buffered_lines = [System.Collections.Generic.Queue[string]]::new(); eof = $false }
$faultedResult = Receive-McpStdinLine $faultedState 1
Assert-True ($faultedResult.ready -and $null -eq $faultedResult.line -and $faultedState.eof) "Faulted stdin reads must become EOF"
Assert-True (-not (Test-McpBackendUnavailableResponse ([pscustomobject]@{ ok = $false; statusCode = 503 }))) "HTTP errors must remain backend responses"
Assert-True (Test-McpBackendUnavailableResponse ([pscustomobject]@{ ok = $false; statusCode = $null })) "Transport failures without a status must trigger recovery"
foreach ($name in @(
    "Normalize-McpContractFingerprint", "Get-McpContractFingerprintFromContractFile",
    "Get-McpContractFingerprintFromMarketplaceSource", "Resolve-LocalMcpContractFingerprint",
    "New-RuntimeKey", "Get-RuntimeStateKey", "Get-PortFromOrigin", "Test-EndpointMatches", "Test-BackendShouldShutdownOnIdle",
    "Test-PortSelectionAllowsReuse", "Test-BackendContractMatches", "Test-BackendLaunchCompatible",
    "Test-RuntimeStateExternalLoopback", "Test-RuntimeEntryEndpointMatches", "Test-SymppBackendCommandLine", "Get-ProcessCommandLine", "New-SymppPublicationControls", "Test-SymppPublicationControlsMatch",
    "Test-SymppPublishedRuntimeReadyLocally", "Resolve-SymppPendingBackendProcess", "Test-SymppStartingBackendOwned", "New-ReusedBackendPlan", "New-ReusedDashboardPlan",
    "Resolve-LocalWarmAttachIdentity", "Resolve-FastAttachRuntimePlan", "Resolve-DashboardPlan", "Set-SymppSourceRevisionEnvironment"
  )) {
  Import-ScriptFunction $scriptPath $name
}
foreach ($name in @("Get-SymppArtifactDirectoryFingerprint", "Test-SymppArtifactDashboardReady", "Remove-SymppArtifactExtractionStaging", "Expand-SymppArtifactArchive", "Test-ArtifactBackendProvidesDashboard", "Resolve-LaunchArtifactSelection")) {
  Import-ScriptFunction $artifactRuntimePath $name
}
foreach ($name in @("Get-PathIdentity", "Test-SamePath", "Test-SameDatabasePath", "Test-PathInside", "Resolve-BetaConfiguration", "Invoke-BetaGit", "Invoke-BetaGitNullPaths", "Get-BetaGitWorktrees", "Assert-BetaWorktreeIdentity", "Initialize-BetaWorktree", "Assert-BetaPackageSource", "Get-BetaEnvironment", "Invoke-WithBetaEnvironment", "Get-BetaCodexArguments", "Assert-BetaRuntimeIdentity", "Test-BetaRuntimeProcessRunning")) {
  Import-ScriptFunction $betaPath $name
}
function script:git { Write-Error "normal git progress"; $script:LASTEXITCODE = 0; "ok" }
try { $gitOutput = @(Invoke-BetaGit $repoRoot @("fetch")) } finally { Remove-Item Function:git }
Assert-True ($gitOutput -contains "ok") "Successful git stderr must not terminate the beta launcher"
function Write-Diagnostic([string]$Message) { }
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
$publishedControls = New-SymppPublicationControls 19998 19999 $false $false $null $null
$publishedState = $state | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$publishedState.backend.managed = $false
$publishedState.backend.status = "external_loopback"
$publishedState.frontend.status = "external_loopback"
$publishedState | Add-Member -NotePropertyName publication -NotePropertyValue ([pscustomobject]@{ status = "ready"; generation_key = "published-generation"; controls = $publishedControls })
$publishedIdentity = [pscustomobject]@{ generation_key = "published-generation"; contract_fingerprint = $fingerprint }
$staleFingerprint = $(if ($fingerprint[0] -eq "0") { "1" } else { "0" }) + $fingerprint.Substring(1)
function Get-SymppBackendHealthWithRetry { return $script:publishedExternalHealth }
try {
  $script:publishedExternalHealth = [pscustomobject]@{ healthy = $false; contract_fingerprint = $fingerprint }
  Assert-True (-not (Test-SymppPublishedRuntimeReadyLocally $publishedState $pluginRoot $null $publishedControls)) "A stopped external backend must not satisfy initial ready publication"
  $script:publishedExternalHealth = [pscustomobject]@{ healthy = $true; contract_fingerprint = $staleFingerprint }
  Assert-True (-not (Test-SymppPublishedRuntimeReadyLocally $publishedState $pluginRoot $null $publishedControls)) "A live incompatible external backend must not satisfy initial ready publication"
  $script:publishedExternalHealth = [pscustomobject]@{ healthy = $true; contract_fingerprint = $fingerprint }
  Assert-True (Test-SymppPublishedRuntimeReadyLocally $publishedState $pluginRoot $null $publishedControls) "A live compatible external backend should satisfy local readiness"
  Assert-True (Test-SymppPublishedRuntimeReadyLocally $publishedState $pluginRoot $publishedIdentity $publishedControls) "A live compatible external backend should satisfy ready publication"
  $mismatchedIdentity = [pscustomobject]@{ generation_key = "other-generation"; contract_fingerprint = $fingerprint }
  Assert-True (-not (Test-SymppPublishedRuntimeReadyLocally $publishedState $pluginRoot $mismatchedIdentity $publishedControls)) "A different installed generation must reject the publication"
  $publishedPlan = Resolve-FastAttachRuntimePlan $publishedState $publishedState.backend.source_revision $fingerprint 0 0 $false $false $null $null $script:publishedExternalHealth $true $true
  Assert-True ($null -ne $publishedPlan) "A live compatible external publication should produce a follower attach plan"
} finally {
  Remove-Item Function:Get-SymppBackendHealthWithRetry
}
Assert-True ($null -eq (Resolve-LocalWarmAttachIdentity $state $pluginRoot 20000 19999 $true $false $null $null)) "Explicit backend port mismatch must reject fallback warm attach"
Assert-True ($null -eq (Resolve-LocalWarmAttachIdentity $state (Join-Path $pluginRoot "other") 19998 19999 $false $false $null $null)) "Different plugin payload must reject fallback warm attach"
$staleState = $state | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$staleState.runtime_key = New-RuntimeKey $backendUrl $backendUrl $staleFingerprint
$staleState.backend.expected_contract_fingerprint = $staleFingerprint
$staleState.backend.contract_fingerprint = $staleFingerprint
Assert-True ($null -eq (Resolve-LocalWarmAttachIdentity $staleState $pluginRoot 19998 19999 $false $false $null $null)) "Stale fallback state must take the cold validation path"
$health = [pscustomobject]@{ healthy = $true; source_revision = $state.backend.source_revision; contract_fingerprint = $fingerprint }
$plan = Resolve-FastAttachRuntimePlan $state $state.backend.source_revision $fingerprint 0 0 $false $false $null $null $health $true $true
Assert-True ($null -ne $plan -and -not $plan.dashboard_plan.managed) "Artifact-static runtime should produce an unmanaged-dashboard fallback plan"
Assert-True (Test-BackendShouldShutdownOnIdle $state.backend $state.frontend) "Managed backends without a managed dashboard must shut down on idle in source and artifact modes"
Assert-True (Test-SymppBackendCommandLine 'cmd.exe /c C:\cache\artifacts\mcp\windows-x86_64\abc\runtime\start-runtime.cmd') "Supported artifact command wrappers must remain recoverable before binding"
$sourceState = [pscustomobject]@{ runtime_kind = "managed"; backend = [pscustomobject]@{ url = "http://127.0.0.1:20000" } }
$reusedSourcePlan = [pscustomobject]@{ reused = $true; should_start = $false; url = "http://127.0.0.1:20000" }
Assert-True (-not (Test-ArtifactBackendProvidesDashboard $sourceState $reusedSourcePlan "source")) "Reused source backends must not be promoted to artifact mode"
$sourceDashboardState = [pscustomobject]@{
  backend = [pscustomobject]@{ url = "http://127.0.0.1:20000" }
  frontend = [pscustomobject]@{ origin = "http://127.0.0.1:20001"; managed = $true; pid = 123 }
}
function Test-HealthySymppDashboard([string]$Origin) { return $true }
function Test-SymppDashboardMcpProxyMatches([string]$Origin, [string]$ExpectedContractFingerprint) { return $false }
$restartDashboardPlan = Resolve-DashboardPlan 20001 $null "http://127.0.0.1:20000" ("b" * 40) $sourceDashboardState $true ("b" * 40) $fingerprint $true $true
Assert-True ($restartDashboardPlan.reused -and $restartDashboardPlan.managed -and $restartDashboardPlan.pid -eq 123) "Backend restart must preserve a healthy recorded managed dashboard while its proxy is temporarily unavailable"
$nodePath = Join-Path $pluginRoot "scripts/start-sympp-mcp-bridge.js"

$pendingBase = Join-Path ([System.IO.Path]::GetTempPath()) "sympp-pending-launch-$([guid]::NewGuid().ToString('N'))"
$pendingRoot = Join-Path $pendingBase "artifacts/mcp/test/runtime"
$leader = $null; $wrapperPid = 0; $unrelated = $null; $ownedPid = 0
try {
  New-Item -ItemType Directory -Path $pendingRoot -Force | Out-Null
  $runtimeCmd = Join-Path $pendingRoot "start-runtime.cmd"
  $wrapperScript = Join-Path $pendingRoot "wrapper.ps1"
  $wrapperReady = Join-Path $pendingRoot "wrapper-ready"
  $wrapperRelease = Join-Path $pendingRoot "wrapper-release"
  $leaderCmd = Join-Path $pendingRoot "leader.cmd"
  Set-Content -LiteralPath $runtimeCmd -Value "@echo off`r`npowershell.exe -NoProfile -NonInteractive -Command `"Start-Sleep -Seconds 60`"" -NoNewline
  Set-Content -LiteralPath $wrapperScript -Value @(
    '[System.IO.File]::WriteAllText($env:SYMPP_TEST_WRAPPER_READY, "ready")'
    'while (-not (Test-Path -LiteralPath $env:SYMPP_TEST_WRAPPER_RELEASE)) { Start-Sleep -Milliseconds 25 }'
    'Start-Process cmd.exe -ArgumentList @("/d", "/s", "/c", "call `"$env:SYMPP_TEST_RUNTIME_CMD`"") -WorkingDirectory $env:SYMPP_TEST_RUNTIME_ROOT | Out-Null'
  )
  Set-Content -LiteralPath $leaderCmd -Value "@echo off`r`npowershell.exe -NoProfile -NonInteractive -File `"%~dp0wrapper.ps1`"`r`npowershell.exe -NoProfile -NonInteractive -Command `"Start-Sleep -Seconds 60`"" -NoNewline
  $env:SYMPP_TEST_WRAPPER_READY = $wrapperReady; $env:SYMPP_TEST_WRAPPER_RELEASE = $wrapperRelease
  $env:SYMPP_TEST_RUNTIME_CMD = $runtimeCmd; $env:SYMPP_TEST_RUNTIME_ROOT = $pendingRoot
  $publishedAt = [DateTimeOffset]::UtcNow
  $leader = Start-Process cmd.exe -ArgumentList @('/d', '/s', '/c', "call `"$leaderCmd`"") -WorkingDirectory $pendingRoot -WindowStyle Hidden -PassThru
  $leaderIdentity = Get-ProcessStartIdentity $leader
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
  while (-not (Test-Path -LiteralPath $wrapperReady) -and [DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
  $wrapper = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($leader.Id)" -ErrorAction SilentlyContinue | Where-Object { [string]$_.CommandLine -match 'wrapper\.ps1' } | Select-Object -First 1
  Assert-True ($null -ne $wrapper) "Pending-launch fixture did not create the published wrapper"
  $wrapperPid = [int]$wrapper.ProcessId
  $wrapperIdentity = Get-ProcessStartIdentity (Get-Process -Id $wrapperPid)
  Set-Content -LiteralPath $wrapperRelease -Value "ready" -NoNewline
  $owned = $null
  while ($null -eq $owned -and [DateTimeOffset]::UtcNow -lt $deadline) {
    $owned = Get-CimInstance Win32_Process -Filter "ParentProcessId=$wrapperPid" -ErrorAction SilentlyContinue | Where-Object { [string]$_.CommandLine -match 'start-runtime\.cmd' } | Select-Object -First 1
    if ($null -eq $owned) { Start-Sleep -Milliseconds 25 }
  }
  Assert-True ($null -ne $owned -and $null -eq (Get-Process -Id $wrapperPid -ErrorAction SilentlyContinue)) "Published wrapper did not exit after creating its backend child"
  $ownedPid = [int]$owned.ProcessId
  Stop-Process -Id $leader.Id -Force; [void]$leader.WaitForExit(5000)
  $unrelated = Start-Process cmd.exe -ArgumentList @('/d', '/s', '/c', "call `"$runtimeCmd`"") -WorkingDirectory $pendingRoot -WindowStyle Hidden -PassThru
  $controls = New-SymppPublicationControls 31991 31991 $true $true $null $null
  $identity = [pscustomobject]@{ generation_key = 'pending-generation' }
  $pendingState = [pscustomobject]@{
    backend = [pscustomobject]@{ pid = $wrapperPid }
    publication = [pscustomobject]@{
      status = 'starting'; generation_key = $identity.generation_key; controls = $controls; published_at = $publishedAt.ToString('o')
      leader_pid = $leader.Id; leader_process_start_time_utc_ticks = $leaderIdentity
      backend = [pscustomobject]@{ pid = $wrapperPid; process_start_time_utc_ticks = $wrapperIdentity; port = 31991; runtime_root = $pendingRoot }
    }
  }
  Assert-True (Test-SymppStartingBackendOwned $pendingState $identity $controls) "Leader-death recovery must adopt the exact backend child after its published wrapper exits"
  Assert-True ([int]$pendingState.publication.backend.pid -eq $ownedPid -and [int]$pendingState.publication.backend.pid -ne $unrelated.Id) "Pending recovery must not adopt an unrelated loopback process"
} finally {
  foreach ($processId in @($(if ($unrelated) { $unrelated.Id }), $ownedPid, $wrapperPid, $(if ($leader) { $leader.Id }))) {
    if ($processId -and (Get-Process -Id $processId -ErrorAction SilentlyContinue)) { & taskkill.exe /PID $processId /T /F 2>$null | Out-Null }
  }
  Remove-Item Env:SYMPP_TEST_WRAPPER_READY,Env:SYMPP_TEST_WRAPPER_RELEASE,Env:SYMPP_TEST_RUNTIME_CMD,Env:SYMPP_TEST_RUNTIME_ROOT -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $pendingBase -Recurse -Force -ErrorAction SilentlyContinue
}
$artifactTemp = Join-Path $PSScriptRoot (".artifact-runtime-" + [guid]::NewGuid().ToString("N"))
try {
  $payload = Join-Path $artifactTemp "payload"
  New-Item -ItemType Directory -Path (Join-Path $payload "dashboard-static") -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $payload "start-runtime.ps1") -Value "exit 0" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $payload "dashboard-static/index.html") -Value "ready" -Encoding UTF8
  $fingerprint = Get-SymppArtifactDirectoryFingerprint (Join-Path $payload "dashboard-static")
  $archive = Join-Path $artifactTemp "runtime.zip"
  [System.IO.Compression.ZipFile]::CreateFromDirectory($payload, $archive)
  $extractRoot = Join-Path $artifactTemp "runtime"
  New-Item -ItemType Directory -Path "$extractRoot.extracting-orphan" | Out-Null
  Remove-SymppArtifactExtractionStaging $extractRoot
  Assert-True (-not (Test-Path -LiteralPath "$extractRoot.extracting-orphan")) "Artifact staging cleanup must remove an orphaned extraction directory"
  $timings = Expand-SymppArtifactArchive $archive $extractRoot "start-runtime.ps1" ("a" * 64) "windows-x64" ("b" * 40) "0.1.9" "manifest.json" "dashboard-static" $fingerprint
  Assert-True (($timings.extract_ms -ge 0) -and (Test-SymppArtifactDashboardReady $extractRoot "dashboard-static" $fingerprint)) "Stdlib artifact extraction must preserve dashboard proof"
  function Ensure-SymppArtifactPrepared { $script:capturedDashboardRoot = $args[10]; return "cache_ready" }
  try {
    $script:capturedDashboardRoot = $null
    $rootDashboardRuntime = [pscustomobject]@{ root = $extractRoot; dashboard_root = $extractRoot; entrypoint_relative = "start-runtime.ps1"; sha256 = "a" * 64; platform = "windows-x64"; source_revision = "b" * 40; plugin_version = "0.1.9"; dashboard_fingerprint = $fingerprint }
    $rootDashboardProbe = [pscustomobject]@{ status = "artifact_selected"; selected_artifact = [pscustomobject]@{}; manifest_path = "manifest.json"; cache_root = $artifactTemp; runtime = $rootDashboardRuntime }
    $rootDashboardSelection = Resolve-LaunchArtifactSelection $pluginRoot $null $rootDashboardProbe ("b" * 40) $fingerprint $true $false
    Assert-True ($rootDashboardSelection.runtime_mode -eq "artifact" -and $script:capturedDashboardRoot -eq ".") "Root-level dashboard artifacts must retain a dot-relative asset root"
  } finally {
    Remove-Item Function:Ensure-SymppArtifactPrepared -ErrorAction SilentlyContinue
  }
} finally {
  Remove-Item -LiteralPath $artifactTemp -Recurse -Force -ErrorAction SilentlyContinue
}
& (Get-Command node.exe -ErrorAction Stop).Source --check $nodePath
$nodeExitCode = $LASTEXITCODE
Assert-True ($nodeExitCode -eq 0) "Node bridge must parse"
& (Get-Command node.exe -ErrorAction Stop).Source $nodePath --runtime-supported
$nodeExitCode = $LASTEXITCODE
Assert-True ($nodeExitCode -eq 0) "Current Node runtime must satisfy the conservative bridge check"
& (Get-Command node.exe -ErrorAction Stop).Source (Join-Path $PSScriptRoot "state-identity-tests.js")
$nodeExitCode = $LASTEXITCODE
Assert-True ($nodeExitCode -eq 0) "Node state identity tests must pass"
& (Get-Command node.exe -ErrorAction Stop).Source (Join-Path $PSScriptRoot "bridge-response-forwarding-tests.js")
$nodeExitCode = $LASTEXITCODE
Assert-True ($nodeExitCode -eq 0) "Node bridge response forwarding test must pass"
$artifactCommandTemp = Join-Path $PSScriptRoot (".artifact-command-" + [guid]::NewGuid().ToString("N"))
try {
  $artifactRoot = Join-Path $artifactCommandTemp "artifact & command"
  $releaseEntrypoint = Join-Path $artifactRoot "runtime/bin/symphony_elixir.bat"
  New-Item -ItemType Directory -Path (Split-Path -Parent $releaseEntrypoint) -Force | Out-Null
  Set-Content -LiteralPath $releaseEntrypoint -Value "@exit /b 0" -Encoding ascii
  $artifactRuntime = [pscustomobject]@{
    root = $artifactRoot
    entrypoint = Join-Path $artifactRoot "start-runtime.ps1"
    runtime_args = $null
    workflow = $null
  }
  $artifactPlan = [pscustomobject]@{ port = 20000 }
  $artifactCommand = Get-ArtifactBackendCommand $artifactRuntime $artifactPlan $null $null (Join-Path $artifactCommandTemp "logs")
  Assert-True ($artifactCommand.file -eq "cmd.exe" -and (@($artifactCommand.args) -join "|") -eq "/d|/s|/c|call|runtime\bin\symphony_elixir.bat|start") "Windows artifact startup must launch the release directly without reparsing the artifact root"
  Assert-True ($artifactCommand.working_directory -eq $artifactRoot) "Direct artifact startup must preserve the artifact working directory"
  Assert-True ($artifactCommand.environment.SYMPP_RUNTIME_ARTIFACT_ACKNOWLEDGED -eq "1" -and $artifactCommand.environment.PHX_SERVER -eq "true") "Direct artifact startup must preserve release safety and server environment"
  Assert-True ((Test-Path -LiteralPath $artifactCommand.environment.RELEASE_TMP -PathType Container)) "Direct artifact startup must provide an isolated release temp directory"
  $artifactRuntime.runtime_args = @("-Port", "{port}")
  $customCommand = Get-ArtifactBackendCommand $artifactRuntime $artifactPlan $null $null (Join-Path $artifactCommandTemp "custom-logs")
  Assert-True ($customCommand.file -eq $artifactRuntime.entrypoint -and (@($customCommand.args) -join "|") -eq "-Port|20000") "Artifacts with custom manifest arguments must retain the declared wrapper contract"
} finally {
  Remove-Item -LiteralPath $artifactCommandTemp -Recurse -Force -ErrorAction SilentlyContinue
}
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

$betaRoot = Join-Path $PSScriptRoot (".beta-bootstrap-" + [guid]::NewGuid().ToString("N"))
try {
  $codexConfig = [pscustomobject]@{
    worktree = "C:\beta"; sympp_home = "C:\beta-home"; runtime_file = "C:\beta-home\runtime.json"; log_dir = "C:\beta-home\logs"
    mix_build_root = "C:\beta-home\build"; database = "C:\beta-home\ledger.sqlite3"; backend_port = 20000; dashboard_port = 20001
  }
  $freshCodexArguments = @(Get-BetaCodexArguments $codexConfig $null)
  $resumeCodexArguments = @(Get-BetaCodexArguments $codexConfig "thread-id")
  $mcpEnvironmentNames = [regex]::Matches($freshCodexArguments[1], '(?:env=\{|,)(SYMPP_[A-Z_]+|MIX_BUILD_ROOT)=') | ForEach-Object { $_.Groups[1].Value }
  Assert-True (($freshCodexArguments[0] -eq "-c") -and $freshCodexArguments[1].Contains('cwd="C:/beta/plugins/symphony-plus-plus-mcp"') -and $freshCodexArguments[1].Contains('env={SYMPP_HOME="C:\\beta-home"') -and $freshCodexArguments[1].Contains('SYMPP_DATABASE="C:\\beta-home\\ledger.sqlite3"') -and $freshCodexArguments[1] -notmatch 'env_vars') "Beta Codex must pass its eight-value environment directly to the source MCP bridge"
  Assert-True ((@($mcpEnvironmentNames) -join ",") -eq "SYMPP_HOME,SYMPP_RUNTIME_FILE,SYMPP_LOG_DIR,MIX_BUILD_ROOT,SYMPP_REPO_ROOT,SYMPP_DATABASE,SYMPP_BACKEND_PORT,SYMPP_DASHBOARD_PORT") "Beta MCP override must contain exactly the eight beta runtime values"
  Assert-True ((@($freshCodexArguments[2..3]) -join "|") -eq "-C|C:\beta") "Beta Codex must open a fresh thread directly in the beta worktree"
  Assert-True ((@($resumeCodexArguments[2..5]) -join "|") -eq "-C|C:\beta|resume|thread-id") "Beta Codex must resume directly inside the beta environment"
  $origin = Join-Path $betaRoot "origin.git"
  $sourceRepo = Join-Path $betaRoot "source"
  $betaWorktree = Join-Path $betaRoot "beta"
  $betaHome = Join-Path $betaRoot "home"
  New-Item -ItemType Directory -Path $betaRoot -Force | Out-Null
  & git init --bare $origin | Out-Null
  & git init -b main $sourceRepo | Out-Null
  & git -C $sourceRepo config user.email "launcher-tests@example.invalid"
  & git -C $sourceRepo config user.name "Launcher Tests"
  Set-Content -LiteralPath (Join-Path $sourceRepo "README.md") -Value "fixture" -NoNewline
  & git -C $sourceRepo add README.md
  & git -C $sourceRepo commit -m fixture | Out-Null
  & git -C $sourceRepo remote add origin $origin
  & git -C $sourceRepo push -u origin main | Out-Null
  & git -C $sourceRepo branch beta
  & git -C $sourceRepo push origin beta | Out-Null

  $betaConfig = Resolve-BetaConfiguration $sourceRepo $betaWorktree $betaHome $null $false 20000 20001
  $casePathsMatch = Test-SamePath (Join-Path $betaRoot "case") (Join-Path $betaRoot "CASE")
  $runningOnWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
  Assert-True ($casePathsMatch -eq $runningOnWindows) "Beta path comparisons must follow platform case semantics"
  Initialize-BetaWorktree $betaConfig
  Assert-True ((& git -C $betaWorktree branch --show-current) -eq "beta") "Beta bootstrap must create the fixed beta worktree"
  Assert-True ((& git -C $betaWorktree rev-parse --abbrev-ref --symbolic-full-name '@{u}') -eq "origin/beta") "Beta worktree must track origin/beta"
  Initialize-BetaWorktree $betaConfig
  Set-Content -LiteralPath (Join-Path $sourceRepo "README.md") -Value "remote update" -NoNewline
  & git -C $sourceRepo commit -am "remote update" | Out-Null
  & git -C $sourceRepo push origin HEAD:beta | Out-Null
  Initialize-BetaWorktree $betaConfig
  Assert-True ((& git -C $betaWorktree rev-parse HEAD) -eq (& git -C $betaWorktree rev-parse origin/beta)) "Clean beta setup must fast-forward to origin/beta"
  Set-Content -LiteralPath (Join-Path $betaWorktree "untracked.txt") -Value "preserve me" -NoNewline
  Initialize-BetaWorktree $betaConfig
  Assert-True ((Get-Content -LiteralPath (Join-Path $betaWorktree "untracked.txt") -Raw) -eq "preserve me") "Beta setup must preserve harmless untracked files"
  $fixturePluginScripts = Join-Path $betaWorktree "plugins/symphony-plus-plus-mcp/scripts"
  New-Item -ItemType Directory -Path $fixturePluginScripts -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $fixturePluginScripts "scratch.ps1") -Value "scratch" -NoNewline
  $packageRejected = $false
  try { Assert-BetaPackageSource $betaConfig } catch { $packageRejected = $true }
  Assert-True $packageRejected "Beta packaging must reject untracked source inputs"
  Remove-Item -LiteralPath (Join-Path $fixturePluginScripts "scratch.ps1") -Force
  Set-Content -LiteralPath (& git -C $betaWorktree rev-parse --git-path info/exclude) -Value "*.local"
  Set-Content -LiteralPath (Join-Path $fixturePluginScripts "scratch.local") -Value "ignored" -NoNewline
  $ignoredPackageRejected = $false
  try { Assert-BetaPackageSource $betaConfig } catch { $ignoredPackageRejected = $true }
  Assert-True $ignoredPackageRejected "Beta packaging must reject ignored plugin inputs"
  Remove-Item -LiteralPath (Join-Path $betaWorktree "plugins") -Recurse -Force
  Set-Content -LiteralPath (Join-Path $betaWorktree "incoming.local") -Value "preserve me" -NoNewline
  Set-Content -LiteralPath (Join-Path $sourceRepo "incoming.local") -Value "remote" -NoNewline
  & git -C $sourceRepo add -f incoming.local
  & git -C $sourceRepo commit -m "remote ignored collision" | Out-Null
  & git -C $sourceRepo push origin HEAD:beta | Out-Null
  $collisionRejected = $false
  try { Initialize-BetaWorktree $betaConfig } catch { $collisionRejected = $true }
  Assert-True ($collisionRejected -and (Get-Content -LiteralPath (Join-Path $betaWorktree "incoming.local") -Raw) -eq "preserve me") "Beta setup must not overwrite ignored local files"
  Remove-Item -LiteralPath (Join-Path $betaWorktree "incoming.local") -Force
  Initialize-BetaWorktree $betaConfig
  $ignoredDirectory = Join-Path $betaWorktree "dír.local"
  New-Item -ItemType Directory -Path $ignoredDirectory | Out-Null
  Set-Content -LiteralPath (Join-Path $ignoredDirectory "item") -Value "preserve me" -NoNewline
  Set-Content -LiteralPath (Join-Path $sourceRepo "dír.local") -Value "remote" -NoNewline
  & git -C $sourceRepo add -f "dír.local"
  & git -C $sourceRepo commit -m "remote ignored directory collision" | Out-Null
  & git -C $sourceRepo push origin HEAD:beta | Out-Null
  $directoryCollisionRejected = $false
  try { Initialize-BetaWorktree $betaConfig } catch { $directoryCollisionRejected = $true }
  Assert-True ($directoryCollisionRejected -and (Get-Content -LiteralPath (Join-Path $ignoredDirectory "item") -Raw) -eq "preserve me") "Beta setup must not replace ignored local directories"
  Remove-Item -LiteralPath $ignoredDirectory -Recurse -Force
  Initialize-BetaWorktree $betaConfig
  Set-Content -LiteralPath (Join-Path $betaWorktree "README.md") -Value "dirty state" -NoNewline
  $dirtyRejected = $false
  try { Initialize-BetaWorktree $betaConfig } catch { $dirtyRejected = $true }
  Assert-True ($dirtyRejected -and (Get-Content -LiteralPath (Join-Path $betaWorktree "README.md") -Raw) -eq "dirty state") "Dirty beta setup must refuse without overwriting local changes"
  & git -C $betaWorktree restore README.md
  Set-Content -LiteralPath (Join-Path $betaWorktree "local.txt") -Value "local" -NoNewline
  & git -C $betaWorktree add local.txt
  & git -C $betaWorktree commit -m "local beta" | Out-Null
  Set-Content -LiteralPath (Join-Path $sourceRepo "remote.txt") -Value "remote" -NoNewline
  & git -C $sourceRepo add remote.txt
  & git -C $sourceRepo commit -m "remote beta" | Out-Null
  & git -C $sourceRepo push origin HEAD:beta | Out-Null
  $divergedHead = & git -C $betaWorktree rev-parse HEAD
  $divergedRejected = $false
  try { Initialize-BetaWorktree $betaConfig } catch { $divergedRejected = $true }
  Assert-True ($divergedRejected -and (& git -C $betaWorktree rev-parse HEAD) -eq $divergedHead) "Diverged beta setup must refuse without resetting local commits"

  $environment = Get-BetaEnvironment $betaConfig
  Assert-True ($environment.SYMPP_HOME -eq $betaConfig.sympp_home -and $environment.SYMPP_RUNTIME_FILE -eq $betaConfig.runtime_file -and $environment.SYMPP_LOG_DIR -eq $betaConfig.log_dir) "Beta runtime state and logs must use the isolated home"
  Assert-True ($environment.MIX_BUILD_ROOT -eq $betaConfig.mix_build_root -and $environment.SYMPP_DATABASE -eq $betaConfig.database -and $environment.SYMPP_REPO_ROOT -eq $betaWorktree) "Beta source build and ledger must use isolated paths"
  Assert-True (-not $environment.Contains("CODEX_HOME")) "Source beta Codex must inherit the normal authenticated Codex home"
  Assert-True ($environment.SYMPP_BACKEND_PORT -eq "20000" -and $environment.SYMPP_DASHBOARD_PORT -eq "20001") "Beta ports must remain separate from stable"
  Assert-True ($null -eq $environment.SYMPP_BACKEND_URL -and $null -eq $environment.SYMPP_DASHBOARD_ORIGIN -and $null -eq $environment.SYMPP_AUTOSTART_SERVERS) "Beta commands must clear inherited runtime overrides"
  $previousCodexHome = $env:CODEX_HOME
  $previousBackendUrl = $env:SYMPP_BACKEND_URL
  try {
    $env:CODEX_HOME = Join-Path $betaRoot "normal-codex"
    $env:SYMPP_BACKEND_URL = "http://127.0.0.1:19998"
    $sourceCodexHome = Invoke-WithBetaEnvironment $betaConfig { $env:CODEX_HOME }
    $packageCodexHome = Invoke-WithBetaEnvironment $betaConfig { $env:CODEX_HOME } -Package
    Assert-True ($sourceCodexHome -eq $env:CODEX_HOME) "Source Codex must retain normal authentication"
    Assert-True ($packageCodexHome -eq $betaConfig.codex_home -and (Test-PathInside $packageCodexHome $betaHome)) "Package validation must use only the isolated Codex home"
    Assert-True ($env:SYMPP_BACKEND_URL -eq "http://127.0.0.1:19998") "Beta environment must restore inherited process settings"
  } finally {
    $env:CODEX_HOME = $previousCodexHome
    $env:SYMPP_BACKEND_URL = $previousBackendUrl
  }

  $liveDatabase = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) ".agents/splusplus/symphony_plus_plus.sqlite3"
  $liveRejected = $false
  try { Resolve-BetaConfiguration $sourceRepo $betaWorktree $betaHome $liveDatabase $false 20000 20001 } catch { $liveRejected = $true }
  Assert-True $liveRejected "The live ledger must require explicit -LiveLedger"
  $alternateLiveRejected = $false
  try { Resolve-BetaConfiguration $sourceRepo $betaWorktree $betaHome (Join-Path $betaHome "other.sqlite3") $true 20000 20001 } catch { $alternateLiveRejected = $true }
  Assert-True $alternateLiveRejected "-LiveLedger must not accept an alternate database"
  $ledgerTarget = Join-Path $betaRoot "ledger-target.sqlite3"
  $ledgerAlias = Join-Path $betaRoot "ledger-alias.sqlite3"
  Set-Content -LiteralPath $ledgerTarget -Value "fixture" -NoNewline
  New-Item -ItemType HardLink -Path $ledgerAlias -Target $ledgerTarget | Out-Null
  Assert-True (Test-SamePath $ledgerAlias $ledgerTarget) "Existing database aliases must compare by file identity"
  $ledgerDirectory = Join-Path $betaRoot "ledger-directory"
  $ledgerDirectoryAlias = Join-Path $betaRoot "ledger-directory-alias"
  New-Item -ItemType Directory -Path $ledgerDirectory | Out-Null
  $directoryLinkType = if ($runningOnWindows) { "Junction" } else { "SymbolicLink" }
  New-Item -ItemType $directoryLinkType -Path $ledgerDirectoryAlias -Target $ledgerDirectory | Out-Null
  try {
    Assert-True (Test-SameDatabasePath (Join-Path $ledgerDirectory "future.sqlite3") (Join-Path $ledgerDirectoryAlias "future.sqlite3")) "Future database paths must compare resolved parent identity"
    if (-not $runningOnWindows) { Assert-True (-not (Test-SameDatabasePath (Join-Path $ledgerDirectory "future.sqlite3") (Join-Path $ledgerDirectory "FUTURE.sqlite3"))) "Future database identity must preserve case on Unix" }
  } finally {
    Remove-Item -LiteralPath $ledgerDirectoryAlias -Force
  }

  $state = [pscustomobject]@{
    repo_root = $betaWorktree; plugin_root = Join-Path $betaWorktree "plugins/symphony-plus-plus-mcp"; runtime_mode = "source"
    backend = [pscustomobject]@{ port = 20000; url = "http://127.0.0.1:20000" }
    frontend = [pscustomobject]@{ port = 20001; origin = "http://127.0.0.1:20001" }
  }
  Assert-BetaRuntimeIdentity $betaConfig $state
  Assert-True (Test-BetaRuntimeProcessRunning ([pscustomobject]@{ managed = $true; pid = $PID })) "Status must recognize a live recorded managed process"
  foreach ($pidValue in @($null, 0, 2147483647)) {
    Assert-True (-not (Test-BetaRuntimeProcessRunning ([pscustomobject]@{ managed = $true; pid = $pidValue }))) "Status must reject null, zero, and dead PIDs"
  }
  Assert-True (-not (Test-BetaRuntimeProcessRunning ([pscustomobject]@{ managed = $false; pid = $PID }))) "Status must not report unmanaged processes as beta-owned"
  $state.plugin_root = Join-Path $betaConfig.normal_codex_home "plugins/cache/symphony-plus-plus/symphony-plus-plus-mcp/0.1.9"
  Assert-BetaRuntimeIdentity $betaConfig $state
  $state.plugin_root = Join-Path $betaWorktree "plugins/symphony-plus-plus-mcp"
  $state.backend.port = 19998
  $identityRejected = $false
  try { Assert-BetaRuntimeIdentity $betaConfig $state } catch { $identityRejected = $true }
  Assert-True $identityRejected "Beta controls must reject stable runtime identity"

  $unrelated = Join-Path $betaRoot "unrelated"
  New-Item -ItemType Directory -Path $unrelated | Out-Null
  $unrelatedConfig = Resolve-BetaConfiguration $sourceRepo $unrelated $betaHome $null $false 20000 20001
  $unrelatedRejected = $false
  try { Initialize-BetaWorktree $unrelatedConfig } catch { $unrelatedRejected = $true }
  Assert-True $unrelatedRejected "Beta bootstrap must refuse to overwrite an unrelated path"
} finally {
  Remove-Item -LiteralPath $betaRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$generationRoot = Join-Path $PSScriptRoot (".generation-" + [guid]::NewGuid().ToString("N"))
try {
  $installedRoot = Join-Path $generationRoot "installed"
  $sourceRoot = Join-Path $generationRoot "source"
  foreach ($directory in @($installedRoot, (Join-Path $sourceRoot "elixir/priv/symphony_plus_plus"))) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  Set-Content -LiteralPath (Join-Path $installedRoot "payload.txt") -Value "first" -NoNewline
  Set-Content -LiteralPath (Join-Path $sourceRoot ".codex-marketplace-install.json") -Value (@{ revision = "a" * 40 } | ConvertTo-Json -Compress) -NoNewline
  Set-Content -LiteralPath (Join-Path $sourceRoot "elixir/priv/symphony_plus_plus/mcp_contract.json") -Value (@{ mcp_contract_fingerprint = "c" * 64 } | ConvertTo-Json -Compress) -NoNewline
  $beforeGeneration = Get-SymppPluginGenerationKey $installedRoot $sourceRoot
  Set-Content -LiteralPath (Join-Path $sourceRoot ".codex-marketplace-install.json") -Value (@{ revision = "b" * 40 } | ConvertTo-Json -Compress) -NoNewline
  $afterGeneration = Get-SymppPluginGenerationKey $installedRoot $sourceRoot
  Assert-True ($beforeGeneration -ne $afterGeneration) "Generation identity must follow Codex marketplace revision metadata"
} finally {
  Remove-Item -LiteralPath $generationRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$marketplaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sympp-marketplace-" + [guid]::NewGuid().ToString("N"))
$previousSymppHome = $env:SYMPP_HOME
try {
  $codexHome = Join-Path $marketplaceRoot "codex"
  $sourceRoot = Join-Path $codexHome ".tmp/marketplaces/test-market"
  $installedRoot = Join-Path $codexHome "plugins/cache/test-market/symphony-plus-plus-mcp/0.1.9"
  $contractRoot = Join-Path $sourceRoot "elixir/priv/symphony_plus_plus"
  foreach ($directory in @($installedRoot, $contractRoot, (Join-Path $sourceRoot "elixir"))) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  $revision = "b" * 40
  $fingerprint = "c" * 64
  Set-Content -LiteralPath (Join-Path $sourceRoot "elixir/mix.exs") -Value "[]" -NoNewline
  Set-Content -LiteralPath (Join-Path $sourceRoot ".codex-marketplace-install.json") -Value (@{ revision = $revision } | ConvertTo-Json -Compress) -NoNewline
  Set-Content -LiteralPath (Join-Path $contractRoot "mcp_contract.json") -Value (@{ mcp_contract_fingerprint = $fingerprint } | ConvertTo-Json -Compress) -NoNewline
  Set-Content -LiteralPath (Join-Path $installedRoot "payload.txt") -Value "matching" -NoNewline
  $env:SYMPP_HOME = Join-Path $marketplaceRoot "sympp"

  $installedIdentity = Resolve-SymppInstalledMarketplaceIdentity $installedRoot
  Assert-True ($installedIdentity.revision -eq $revision) "Stock marketplace install must resolve without an S++ source revision marker"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $installedRoot ".sympp-source-revision"))) "Marketplace identity test must not synthesize a source revision marker"

  Set-Content -LiteralPath (Join-Path $installedRoot "payload.txt") -Value "modified" -NoNewline
  $modifiedIdentity = Resolve-SymppInstalledMarketplaceIdentity $installedRoot
  Assert-True ($modifiedIdentity.revision -eq $revision) "S++ must trust Codex-owned plugin cache installation instead of re-hashing the payload"

  Set-Content -LiteralPath (Join-Path $sourceRoot ".codex-marketplace-install.json") -Value "{}" -NoNewline
  Set-Content -LiteralPath (Join-Path $sourceRoot ".sympp-source-revision") -Value $revision -NoNewline
  Assert-True (-not (Get-SymppMarketplaceSourceRevision $sourceRoot)) "Private S++ markers must not substitute for missing Codex marketplace metadata"
} finally {
  $env:SYMPP_HOME = $previousSymppHome
  Remove-Item -LiteralPath $marketplaceRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$benchmark = & (Join-Path $PSScriptRoot "warm-attach-benchmark.ps1") | ConvertFrom-Json
Assert-True ($benchmark.clients -eq 100 -and $benchmark.p95_ms -lt 2000) "100-client PowerShell fallback warm attach p95 must stay below 2 seconds"
Assert-True ($benchmark.backend_processes -eq 1 -and $benchmark.leases_peak -eq 100 -and $benchmark.leases_after -eq 0) "Fallback warm burst must preserve one listener and exact lease lifecycle"
Assert-True ($benchmark.remote_resolution_attempts -eq 0) "Fallback warm burst must make zero artifact or remote resolution attempts"
$nodeBurstJson = & (Get-Command node.exe -ErrorAction Stop).Source (Join-Path $PSScriptRoot "node-bridge-burst.js")
$nodeExitCode = $LASTEXITCODE
Assert-True ($nodeExitCode -eq 0) "Node bridge burst test must pass"
$nodeBurst = $nodeBurstJson | ConvertFrom-Json
Assert-True ($nodeBurst.clients -eq 200 -and $nodeBurst.board -eq 0 -and $nodeBurst.earlyLease -eq 1 -and $nodeBurst.initialize -eq 200) "200 concurrent production Node bridges must initialize with one health-leader lease and no dashboard traffic"
$coldSmokeJson = & (Get-Command node.exe -ErrorAction Stop).Source (Join-Path $PSScriptRoot "cold-start-singleton-smoke.js")
$coldExitCode = $LASTEXITCODE
Assert-True ($coldExitCode -eq 0) "Installed cold-herd, leader-death, and rotating-owner suite must pass"
$coldSmoke = $coldSmokeJson | ConvertFrom-Json
Assert-True ((@($coldSmoke.matrix.clients) -join ",") -eq "30,100,200" -and @($coldSmoke.matrix | Where-Object { $_.manifest -ne 1 -or $_.artifact -ne 1 -or $_.backends -ne 1 -or $_.listeners -ne 0 }).Count -eq 0) "30/100/200 shipped-command matrices must preserve singleton cold work and release the backend listener after the final client"
Assert-True ($coldSmoke.powershell_5_1 -and $coldSmoke.pwsh -and $coldSmoke.cleanup -and @($coldSmoke.leader_death).Count -eq 4) "Cold-herd coverage must prove both PowerShell shells, cleanup, and all leader-death phases"
Assert-True (@($coldSmoke.recovery).Count -eq 11 -and @($coldSmoke.recovery | Where-Object { $_.mode -notin "shutdown_during_recovery", "powershell_fallback_initialize_retry" -and ($_.backends -ne 2 -or $_.pids -ne 2 -or $_.listeners -ne 0 -or $_.recovery_leaders -ne 1) }).Count -eq 0) "Node and PowerShell fallback recovery must each elect exactly one replacement backend and still reach zero listeners"
Assert-True (@($coldSmoke.recovery | Where-Object { $_.mode -like "*ambiguous_tool" -and $_.mutations -eq 1 }).Count -eq 2 -and @($coldSmoke.recovery | Where-Object { $_.mode -notin "shutdown_during_recovery", "generation_changed_recovery", "cleanup_source_changed_recovery", "powershell_fallback_initialize_retry" -and $_.tools_list -le $_.clients }).Count -eq 0) "Recovered adapters that issue tools/list must rebind it and never replay the ambiguous mutating tool call"
Assert-True (@($coldSmoke.recovery | Where-Object { $_.mode -like "*backend_only_read_recovery" -and $_.tools_list -eq 3 -and $_.mutations -eq 0 }).Count -eq 2) "Node and PowerShell fallback bridges must replay an ambiguous read-only request after backend-only recovery"
Assert-True (($coldSmoke.recovery | Where-Object mode -eq "shutdown_during_recovery").shutdown_race) "Adapters must exit when STDIO closes during heartbeat recovery"
Assert-True (($coldSmoke.recovery | Where-Object mode -eq "generation_changed_recovery").fatal_generation) "A replacement rejected by generation validation must detach its lease and fail the adapter closed"
Assert-True (($coldSmoke.recovery | Where-Object mode -eq "cleanup_source_changed_recovery").fatal_cleanup) "A replacement rejected by cleanup-source validation must detach its lease, fail closed, and stop cleanly"
Assert-True (($coldSmoke.recovery | Where-Object mode -eq "powershell_fallback_recovery").fallback_recovery -and ($coldSmoke.recovery | Where-Object mode -eq "powershell_fallback_recovery").cancelled_recovery) "Surviving PowerShell fallback adapters must retain STDIO, rebind the replacement, cancel recovery on final close, and drain it after final detach"
Assert-True (($coldSmoke.recovery | Where-Object mode -eq "powershell_fallback_initialize_retry").initialize_retry) "A provably unsent initialize must be retransmitted after PowerShell fallback recovery"
Assert-True ($coldSmoke.powershell_fallback.clients -eq 30 -and $coldSmoke.powershell_fallback.preparations -eq 1 -and $coldSmoke.powershell_fallback.backends -eq 1) "Direct PowerShell fallback must elect one cold leader before installed identity and runtime work"
$jobCertificationJson = & (Join-Path $PSScriptRoot "run-job-object-certification.ps1")
$jobCertificationExitCode = $LASTEXITCODE
Assert-True ($jobCertificationExitCode -eq 0) "Windows Job Object certification must pass"
$jobCertification = $jobCertificationJson | ConvertFrom-Json
Assert-True ($jobCertification.clients -eq 32 -and $jobCertification.initial_epochs -eq 1 -and $jobCertification.owner_rotations -eq 3) "Independent Job clients must preserve singleton startup and three owner rotations"
Assert-True ($jobCertification.backend_recoveries -eq 2 -and $jobCertification.mutations -eq 1 -and $jobCertification.original_stdio) "Job clients must preserve backend recovery, ambiguous-call safety, and original follower STDIO"
Assert-True ($jobCertification.processes_after -eq 0 -and $jobCertification.listeners_after -eq 0 -and $jobCertification.active_leases_after -eq 0) "Final Job close must leave no owned process, listener, or active lease"
$persistentRuntime = @(& (Join-Path $PSScriptRoot "persistent-artifact-runtime-smoke.ps1"))[-1] | ConvertFrom-Json
Assert-True ($persistentRuntime.installed_waves -eq 2 -and $persistentRuntime.initialize_and_tools_list -eq 3 -and $persistentRuntime.installed_pids_distinct) "Installed command must stop the artifact-static runtime and start a new backend PID for the next wave"
Assert-True ($persistentRuntime.artifact_last_detach_stopped -and $persistentRuntime.listeners_closed -and $persistentRuntime.source_last_detach_stopped -and $persistentRuntime.isolated_runtime_ledger_ports) "Source and installed artifact cleanup must stop their managed listeners and remain isolated from the main runtime"

Write-Host "Launcher bootstrap, contract freshness, cold singleton, and lease identity regressions passed."
