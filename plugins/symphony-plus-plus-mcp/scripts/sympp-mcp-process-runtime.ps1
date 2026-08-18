$ErrorActionPreference = "Stop"

function Invoke-LoggedSetupProcess([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory, [hashtable]$Environment, [string]$LogPrefix, [string]$LogDir, [int]$TimeoutSec) {
  $TimeoutSec = Get-SymppRemainingTimeoutSec $TimeoutSec $LogPrefix
  New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $stdoutPath = Join-Path $LogDir "$LogPrefix-$stamp.out.log"
  $stderrPath = Join-Path $LogDir "$LogPrefix-$stamp.err.log"
  $startCommand = Get-StartProcessCommand $FilePath $ArgumentList
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $startCommand.file
  $startInfo.WorkingDirectory = $WorkingDirectory
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true

  $argumentListProperty = $startInfo.GetType().GetProperty("ArgumentList")
  if ($null -ne $argumentListProperty) {
    foreach ($arg in @($startCommand.args)) {
      [void]$startInfo.ArgumentList.Add([string]$arg)
    }
  } else {
    $startInfo.Arguments = Join-ProcessArgumentList @($startCommand.args)
  }

  $environmentProperty = $startInfo.GetType().GetProperty("Environment")
  $environmentMap = if ($null -ne $environmentProperty) { $startInfo.Environment } else { $startInfo.EnvironmentVariables }
  foreach ($key in @($Environment.Keys)) {
    $environmentMap[[string]$key] = [string]$Environment[$key]
  }

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $timedOut = $false

  try {
    if (-not $process.Start()) {
      throw "failed to start logged setup process: $($startCommand.file)"
    }

    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutSec * 1000)) {
      $timedOut = $true
      try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
      try { [void]$process.WaitForExit(5000) } catch {}
    }

    try { [void]$stdoutTask.Wait(5000) } catch {}
    try { [void]$stderrTask.Wait(5000) } catch {}
    $stdout = if ($stdoutTask.IsCompleted -and -not $stdoutTask.IsFaulted -and -not $stdoutTask.IsCanceled) { [string]$stdoutTask.Result } else { "" }
    $stderr = if ($stderrTask.IsCompleted -and -not $stderrTask.IsFaulted -and -not $stderrTask.IsCanceled) { [string]$stderrTask.Result } else { "" }
    [System.IO.File]::WriteAllText($stdoutPath, $stdout, $utf8NoBom)
    [System.IO.File]::WriteAllText($stderrPath, $stderr, $utf8NoBom)

    return [pscustomobject]@{
      process = $process
      stdout = $stdoutPath
      stderr = $stderrPath
      timed_out = $timedOut
    }
  } catch {
    if ($process -and -not $process.HasExited) {
      try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
    }
    if (-not (Test-Path -LiteralPath $stdoutPath)) { [System.IO.File]::WriteAllText($stdoutPath, "", $utf8NoBom) }
    if (-not (Test-Path -LiteralPath $stderrPath)) { [System.IO.File]::WriteAllText($stderrPath, "", $utf8NoBom) }
    throw
  }
}

function Invoke-ElixirSetupCommand([string]$ElixirDir, [string]$Launcher, [string]$MixCommand, [string]$MiseCommand, [string[]]$MixArgs, [string]$LogPrefix, [string]$LogDir, [int]$TimeoutSec) {
  Assert-LauncherAvailable $Launcher $MixCommand $MiseCommand
  $command = Get-LauncherCommand $Launcher $MixCommand $MiseCommand $MixArgs

  $launch = Invoke-LoggedSetupProcess $command.file $command.args $ElixirDir @{} $LogPrefix $LogDir $TimeoutSec
  try {
    if ($launch.timed_out) {
      throw "Timed out after $TimeoutSec seconds."
    }

    if ($launch.process.ExitCode -ne 0) {
      throw "Exited with code $($launch.process.ExitCode)."
    }

    return $launch
  } catch {
    throw "$LogPrefix failed. detail=$($_.Exception.Message) stdout_log=$($launch.stdout) stderr_log=$($launch.stderr)"
  }
}

function Initialize-ElixirRuntime([string]$ElixirDir, [string]$Launcher, [string]$MixCommand, [string]$MiseCommand, [string]$LogDir, [int]$TimeoutSec) {
  Write-Diagnostic "source_fallback_compiling: ensuring Symphony++ Elixir dependencies are available in $ElixirDir."
  Invoke-ElixirSetupCommand $ElixirDir $Launcher $MixCommand $MiseCommand @("deps.get", "--check-locked") "elixir-deps" $LogDir $TimeoutSec

  Write-Diagnostic "source_fallback_compiling: compiling Symphony++ Elixir runtime in $ElixirDir."
  Invoke-ElixirSetupCommand $ElixirDir $Launcher $MixCommand $MiseCommand @("compile") "elixir-compile" $LogDir $TimeoutSec
}

function Resolve-ArtifactWorkflowPath($ArtifactRuntime, [string]$ElixirDir) {
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_WORKFLOW_FILE)) {
    $candidate = [System.IO.Path]::GetFullPath($env:SYMPP_WORKFLOW_FILE)
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }

  if ($null -ne $ArtifactRuntime -and -not [string]::IsNullOrWhiteSpace([string]$ArtifactRuntime.workflow)) {
    $candidate = [System.IO.Path]::GetFullPath([string]$ArtifactRuntime.workflow)
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }

  if ($null -ne $ArtifactRuntime -and -not [string]::IsNullOrWhiteSpace([string]$ArtifactRuntime.root)) {
    $artifactWorkflow = Join-Path ([string]$ArtifactRuntime.root) "WORKFLOW.md"
    if (Test-Path -LiteralPath $artifactWorkflow -PathType Leaf) {
      return [System.IO.Path]::GetFullPath($artifactWorkflow)
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($ElixirDir)) {
    $sourceWorkflow = Join-Path $ElixirDir "WORKFLOW.md"
    if (Test-Path -LiteralPath $sourceWorkflow -PathType Leaf) {
      return [System.IO.Path]::GetFullPath($sourceWorkflow)
    }
  }

  return $null
}

function Get-ArtifactRuntimeArgList($ArtifactRuntime) {
  $args = @()
  foreach ($arg in @($ArtifactRuntime.runtime_args)) {
    if ($null -ne $arg -and -not [string]::IsNullOrWhiteSpace([string]$arg)) {
      $args += [string]$arg
    }
  }

  return $args
}

function Expand-ArtifactRuntimeArg([string]$Arg, [string]$Workflow, [string]$RuntimeLogRoot, $Plan, [string]$DashboardOrigin) {
  $expanded = $Arg
  $expanded = $expanded.Replace("{workflow}", $Workflow).Replace("{{workflow}}", $Workflow)
  $expanded = $expanded.Replace("{logs_root}", $RuntimeLogRoot).Replace("{{logs_root}}", $RuntimeLogRoot)
  $expanded = $expanded.Replace("{port}", [string]$Plan.port).Replace("{{port}}", [string]$Plan.port)
  if (-not [string]::IsNullOrWhiteSpace($DashboardOrigin)) {
    $expanded = $expanded.Replace("{dashboard_origin}", $DashboardOrigin).Replace("{{dashboard_origin}}", $DashboardOrigin)
  }

  return $expanded
}

function Resolve-ArtifactRuntimeArgs($ArtifactRuntime, [string]$Workflow, [string]$RuntimeLogRoot, $Plan, [string]$DashboardOrigin, [string]$EntrypointName) {
  $manifestArgs = Get-ArtifactRuntimeArgList $ArtifactRuntime
  if ($manifestArgs.Count -gt 0) {
    $expandedArgs = @()
    foreach ($arg in $manifestArgs) {
      $expandedArgs += Expand-ArtifactRuntimeArg ([string]$arg) $Workflow $RuntimeLogRoot $Plan $DashboardOrigin
    }

    return $expandedArgs
  }

  if ($entrypointName -like "*.ps1") {
    $args = @(
      "-IUnderstandThatThisWillBeRunningWithoutTheUsualGuardrails",
      "-LogsRoot", $runtimeLogRoot,
      "-Port", [string]$Plan.port
    )
    if (-not [string]::IsNullOrWhiteSpace($Workflow)) {
      $args += @("-Workflow", $Workflow)
    }

    return $args
  }
  if ($entrypointName -like "*.sh") {
    $args = @(
      "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
      "--logs-root", $runtimeLogRoot,
      "--port", [string]$Plan.port
    )
    if (-not [string]::IsNullOrWhiteSpace($Workflow)) {
      $args += @("--workflow", $Workflow)
    }

    return $args
  }
  if ($entrypointName -like "*.bat" -or $entrypointName -like "*.cmd") {
    return @()
  }

  throw "artifact_entrypoint_unsupported: verified artifact runtime entrypoint must be start-runtime.ps1, start-runtime.sh, or a Windows command wrapper."
}

function Get-ArtifactBackendCommand($ArtifactRuntime, $Plan, [string]$DashboardOrigin, [string]$ElixirDir, [string]$LogDir) {
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    throw "artifact_database_unsupported: verified artifact runtime wrapper does not support SYMPP_DATABASE. Use explicit source fallback for custom ledger paths."
  }

  $manifestArgs = Get-ArtifactRuntimeArgList $ArtifactRuntime
  $runtimeLogRoot = Join-Path $LogDir "artifact-runtime"
  $entrypoint = [string]$ArtifactRuntime.entrypoint
  $entrypointName = (Split-Path -Leaf $entrypoint).ToLowerInvariant()
  $workflow = Resolve-ArtifactWorkflowPath $ArtifactRuntime $ElixirDir
  $environment = @{
    SYMPP_RUNTIME_ARTIFACT = "1"
    SYMPP_RUNTIME_ARTIFACT_ACKNOWLEDGED = "1"
    SYMPP_LOGS_ROOT = $runtimeLogRoot
    SYMPP_BACKEND_PORT = [string]$Plan.port
    SYMPP_WORKFLOW_FILE = ""
  }
  if (-not [string]::IsNullOrWhiteSpace($workflow)) {
    $environment["SYMPP_WORKFLOW_FILE"] = $workflow
  }
  if (-not [string]::IsNullOrWhiteSpace($DashboardOrigin)) {
    $environment["SYMPP_DASHBOARD_ORIGIN"] = $DashboardOrigin
  }

  $args = Resolve-ArtifactRuntimeArgs $ArtifactRuntime $workflow $runtimeLogRoot $Plan $DashboardOrigin $entrypointName

  if ((Test-SymppWindowsPlatform) -and $entrypointName -eq "start-runtime.ps1" -and $manifestArgs.Count -eq 0) {
    $releaseEntrypoint = Join-Path $ArtifactRuntime.root "runtime/bin/symphony_elixir.bat"
    if (Test-Path -LiteralPath $releaseEntrypoint -PathType Leaf) {
      $releaseTmp = Join-Path $runtimeLogRoot "release-tmp"
      New-Item -ItemType Directory -Force -Path $releaseTmp | Out-Null
      $environment["RELEASE_TMP"] = $releaseTmp
      $environment["PHX_SERVER"] = "true"
      return [pscustomobject]@{
        file = "cmd.exe"
        args = @("/d", "/s", "/c", "call", "runtime\bin\symphony_elixir.bat", "start")
        working_directory = [string]$ArtifactRuntime.root
        environment = $environment
      }
    }
  }

  return [pscustomobject]@{
    file = $entrypoint
    args = $args
    working_directory = [string]$ArtifactRuntime.root
    environment = $environment
  }
}

function Start-Backend($Plan, [string]$DashboardOrigin, [string]$ElixirDir, [string]$Launcher, [string]$MixCommand, [string]$MiseCommand, [string]$LogDir, [int]$TimeoutSec, [string]$ExpectedContractFingerprint, $ArtifactRuntime = $null, [bool]$ShutdownOnIdle = $false, [scriptblock]$OnStarted = $null) {
  $TimeoutSec = Get-SymppRemainingTimeoutSec $TimeoutSec "backend startup"
  $args = @("sympp.cockpit", "--host", "127.0.0.1", "--port", [string]$Plan.port)
  if (-not [string]::IsNullOrWhiteSpace($DashboardOrigin)) {
    $args += @("--dashboard-origin", $DashboardOrigin)
  }
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    $args += @("--database", ([System.IO.Path]::GetFullPath($env:SYMPP_DATABASE)))
  }

  if ($null -ne $ArtifactRuntime) {
    $command = Get-ArtifactBackendCommand $ArtifactRuntime $Plan $DashboardOrigin $ElixirDir $LogDir
  } else {
    Assert-LauncherAvailable $Launcher $MixCommand $MiseCommand
    $sourceCommand = Get-LauncherCommand $Launcher $MixCommand $MiseCommand $args
    $command = [pscustomobject]@{
      file = $sourceCommand.file
      args = $sourceCommand.args
      working_directory = $ElixirDir
      environment = @{}
    }
  }

  $command.environment["SYMPP_DEFER_DASHBOARD_OPEN"] = "1"

  if ($ShutdownOnIdle) {
    $command.environment["SYMPP_MCP_SHUTDOWN_ON_IDLE"] = "1"
  }

  $launch = Start-LoggedProcess $command.file $command.args $command.working_directory $command.environment "backend-$($Plan.port)" $LogDir
  $reportedPid = [int]$launch.process.Id
  if ($OnStarted) {
    & $OnStarted $reportedPid (Get-ProcessStartIdentity $launch.process)
  }
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
  $ready = $false
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    $listenerPid = Get-ManagedListenerPid "backend" ([int]$Plan.port)
    if ($listenerPid -and [int]$listenerPid -ne $reportedPid) {
      $reportedPid = [int]$listenerPid
      if ($OnStarted) {
        $listenerProcess = Get-Process -Id $reportedPid -ErrorAction SilentlyContinue
        & $OnStarted $reportedPid (Get-ProcessStartIdentity $listenerProcess)
      }
    }
    if (Test-HealthySymppBackend $Plan.url) { $ready = $true; break }
    Start-Sleep -Milliseconds 250
  }
  if (-not $ready) {
    $portOwners = @(Get-TcpPortOwners ([int]$Plan.port))
    $portDetail = "portOwners=$(Format-PortOwners $portOwners)"
    if ($launch.process.HasExited) {
      throw "Symphony++ backend exited before becoming healthy at $($Plan.url). $portDetail stderr_log=$($launch.stderr)"
    }

    Stop-LoggedProcess $launch
    throw "Symphony++ backend did not become healthy at $($Plan.url) within $TimeoutSec seconds. $portDetail stderr_log=$($launch.stderr)"
  }

  $health = Get-SymppBackendHealthWithRetry $Plan.url
  if (-not (Test-BackendContractMatches $health $ExpectedContractFingerprint)) {
    Stop-LoggedProcess $launch
    throw "Symphony++ backend at $($Plan.url) reported MCP contract fingerprint $(Format-McpContractFingerprintForDiagnostic $health.contract_fingerprint), expected $(Format-McpContractFingerprintForDiagnostic $ExpectedContractFingerprint). stderr_log=$($launch.stderr)"
  }

  $listenerPid = Get-ManagedListenerPid "backend" ([int]$Plan.port)
  return [pscustomobject]@{
    pid = if ($listenerPid) { $listenerPid } else { $launch.process.Id }
    stdout = $launch.stdout
    stderr = $launch.stderr
    source_revision = if ($health.healthy) { $health.source_revision } else { $null }
    contract_fingerprint = if ($health.healthy) { $health.contract_fingerprint } else { $null }
  }
}

function Test-FrontendDependenciesAvailable([string]$AssetsDir) {
  foreach ($candidate in @(
      "node_modules/.bin/vite.cmd",
      "node_modules/.bin/vite.ps1",
      "node_modules/.bin/vite"
    )) {
    if (Test-Path -LiteralPath (Join-Path $AssetsDir $candidate)) {
      return $true
    }
  }

  return $false
}

function Install-FrontendDependencies([string]$AssetsDir, [string]$LogDir, [int]$TimeoutSec) {
  $TimeoutSec = Get-SymppRemainingTimeoutSec $TimeoutSec "frontend dependency installation"
  if (Test-FrontendDependenciesAvailable $AssetsDir) {
    return $null
  }

  $npm = Resolve-NpmCommand
  $args = if (Test-Path -LiteralPath (Join-Path $AssetsDir "package-lock.json")) {
    @("ci", "--no-audit", "--no-fund")
  } else {
    @("install", "--no-audit", "--no-fund")
  }

  Write-Diagnostic "Installing Symphony++ dashboard dependencies in $AssetsDir because Vite is missing."
  $launch = Start-LoggedProcess $npm $args $AssetsDir @{} "frontend-install" $LogDir
  $completed = $false
  try {
    $completed = $launch.process.WaitForExit($TimeoutSec * 1000)
    if (-not $completed) {
      throw "Timed out after $TimeoutSec seconds."
    }

    if ($launch.process.ExitCode -ne 0) {
      throw "Exited with code $($launch.process.ExitCode)."
    }

    return $launch
  } catch {
    if (-not $completed) {
      Stop-LoggedProcess $launch
    }

    throw "frontend-install failed. detail=$($_.Exception.Message) stdout_log=$($launch.stdout) stderr_log=$($launch.stderr)"
  }
}

function Start-Frontend($Plan, [string]$BackendUrl, [string]$AssetsDir, [string]$LogDir, [int]$TimeoutSec) {
  $TimeoutSec = Get-SymppRemainingTimeoutSec $TimeoutSec "frontend startup"
  $npm = Resolve-NpmCommand
  $args = @("run", "dev", "--", "--host", "127.0.0.1", "--port", [string]$Plan.port)
  $launch = Start-LoggedProcess $npm $args $AssetsDir @{ SYMPP_API_ORIGIN = $BackendUrl } "frontend-$($Plan.port)" $LogDir
  $ready = Wait-Until { Test-HealthySymppDashboard $Plan.origin } $TimeoutSec
  if (-not $ready) {
    if ($launch.process.HasExited) {
      throw "Symphony++ dashboard exited before becoming healthy. stderr: $($launch.stderr)"
    }

    Stop-LoggedProcess $launch
    throw "Symphony++ dashboard did not become healthy at $($Plan.origin) within $TimeoutSec seconds. logs: $($launch.stderr)"
  }

  $listenerPid = Get-ManagedListenerPid "frontend" ([int]$Plan.port)
  return [pscustomobject]@{
    pid = if ($listenerPid) { $listenerPid } else { $launch.process.Id }
    stdout = $launch.stdout
    stderr = $launch.stderr
  }
}

function Get-RequestIdForError([string]$Line) {
  try {
    $payload = $Line | ConvertFrom-Json
    if ($payload.PSObject.Properties["id"]) {
      return $payload.id
    }
  } catch {
  }

  return $null
}

function Write-JsonRpcErrorLine([object]$Id, [int]$Code, [string]$Message, [object]$Data = $null) {
  $errorObject = @{
    jsonrpc = "2.0"
    id = $Id
    error = @{
      code = $Code
      message = $Message
    }
  }
  if ($null -ne $Data) {
    $errorObject.error["data"] = $Data
  }

  [Console]::Out.WriteLine(($errorObject | ConvertTo-Json -Depth 12 -Compress))
  [Console]::Out.Flush()
}

function Write-McpResponseLine([string]$Content) {
  if ([string]::IsNullOrWhiteSpace($Content)) {
    return
  }

  $line = $Content.Trim() -replace "(`r`n|`n|`r)", ""
  if (-not [string]::IsNullOrWhiteSpace($line)) {
    [Console]::Out.WriteLine($line)
    [Console]::Out.Flush()
  }
}

function New-McpClientLeaseId {
  return "bridge-$PID-$([guid]::NewGuid().ToString('N'))"
}

function Invoke-McpClientLease([string]$McpUrl, [string]$ClientId, [string]$Action, [bool]$Required = $false) {
  if ([string]::IsNullOrWhiteSpace($ClientId)) {
    return $null
  }

  $body = @{
    client_id = $ClientId
    action = $Action
  } | ConvertTo-Json -Depth 4 -Compress
  $leaseUrl = $McpUrl.TrimEnd("/") + "/client-lease"
  try {
    $response = Invoke-WebRequest -Uri $leaseUrl -Method Post -ContentType "application/json" -Body $body -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
      return $null
    }

    return $response.Content | ConvertFrom-Json
  } catch {
    if ($Required) {
      throw
    }

    return $null
  }
}

function Resolve-McpClientHeartbeatIntervalMs([int]$RequestedIntervalSec, $Lease) {
  $requestedMs = [Math]::Max(1000, $RequestedIntervalSec * 1000)
  if ($null -eq $Lease -or -not $Lease.PSObject.Properties["stale_after_ms"]) {
    return $requestedMs
  }

  $staleAfterMs = 0
  if (-not [int]::TryParse([string]$Lease.stale_after_ms, [ref]$staleAfterMs) -or $staleAfterMs -le 1000) {
    return $requestedMs
  }

  $marginMs = [Math]::Min(60000, [Math]::Max(1000, [int]($staleAfterMs / 10)))
  return [Math]::Min($requestedMs, [Math]::Max(1000, $staleAfterMs - $marginMs))
}

function Get-McpNowMs {
  return [int64]([DateTime]::UtcNow.Subtract([datetime]"1970-01-01T00:00:00Z").TotalMilliseconds)
}

function Invoke-McpClientHeartbeatIfDue([string]$McpUrl, [string]$ClientId, [int64]$LastHeartbeatMs, [int]$HeartbeatIntervalMs) {
  $now = Get-McpNowMs
  if (($now - $LastHeartbeatMs) -lt $HeartbeatIntervalMs) {
    return $LastHeartbeatMs
  }

  Invoke-McpClientLease $McpUrl $ClientId "heartbeat" | Out-Null
  return $now
}

function Test-McpRecoverableSessionNotFound($Response, [string]$SessionId, [string]$RequestProtocolVersion) {
  if ([string]::IsNullOrWhiteSpace($SessionId) -or -not [string]::IsNullOrWhiteSpace($RequestProtocolVersion)) {
    return $false
  }
  if ($null -eq $Response -or $Response.ok) {
    return $false
  }

  $statusCode = 0
  if (-not [int]::TryParse([string]$Response.statusCode, [ref]$statusCode)) {
    return $false
  }

  return $statusCode -eq 404
}

function Invoke-McpBridgeInitialize([string]$McpUrl, [int]$TimeoutSec, [string]$ClientId, [int]$HeartbeatIntervalMs) {
  $initializeBody = ConvertTo-JsonBody (New-InitializeRequest)
  $initializeProtocolVersion = Get-InitializeProtocolVersion $initializeBody
  $response = Invoke-McpPost $McpUrl $initializeBody $null $null $TimeoutSec $ClientId $HeartbeatIntervalMs
  if (-not $response.ok) {
    return [pscustomobject]@{
      ok = $false
      response = $response
      session_id = $null
      protocol_version = $null
    }
  }

  $sessionId = Get-ResponseHeaderValue $response.headers "Mcp-Session-Id"
  if ([string]::IsNullOrWhiteSpace($sessionId)) {
    return [pscustomobject]@{
      ok = $false
      response = $response
      session_id = $null
      protocol_version = $null
    }
  }

  $protocolVersion = Get-ResponseProtocolVersion @($response.content_lines)
  if ([string]::IsNullOrWhiteSpace($protocolVersion)) {
    $protocolVersion = $initializeProtocolVersion
  }

  return [pscustomobject]@{
    ok = $true
    response = $response
    session_id = $sessionId
    protocol_version = $protocolVersion
  }
}

function New-McpStdinReader {
  return [System.IO.StreamReader]::new([Console]::OpenStandardInput())
}

function New-McpStdinReadState($Reader) {
  return [pscustomobject]@{
    reader = $Reader
    pending_task = $Reader.ReadLineAsync()
    buffered_lines = [System.Collections.Generic.Queue[string]]::new()
    eof = $false
  }
}

function Update-McpStdinReadState($State) {
  while (-not $State.eof -and $State.pending_task.IsCompleted) {
    try { $line = $State.pending_task.Result } catch { $State.eof = $true; break }
    if ($null -eq $line) { $State.eof = $true; break }
    $State.buffered_lines.Enqueue($line)
    $State.pending_task = $State.reader.ReadLineAsync()
  }
  return [bool]$State.eof
}

function Receive-McpStdinLine($State, [int]$WaitMs) {
  if ($State.buffered_lines.Count -eq 0 -and -not $State.eof -and -not $State.pending_task.Wait($WaitMs)) {
    return [pscustomobject]@{ ready = $false; line = $null }
  }
  [void](Update-McpStdinReadState $State)
  if ($State.buffered_lines.Count -gt 0) {
    return [pscustomobject]@{ ready = $true; line = $State.buffered_lines.Dequeue() }
  }
  return [pscustomobject]@{ ready = $State.eof; line = $null }
}

function Test-McpBackendUnavailableResponse($Response) {
  if ($null -eq $Response -or $Response.ok) { return $false }
  $statusCode = 0
  return -not [int]::TryParse([string]$Response.statusCode, [ref]$statusCode) -or $statusCode -in @(502, 503, 504)
}

function Test-McpToolCall([string]$Line) {
  try { $payload = $Line | ConvertFrom-Json; return @($payload | Where-Object { [string]$_.method -eq "tools/call" }).Count -gt 0 } catch { return $false }
}

function Invoke-McpBackendRecovery([scriptblock]$Recover, [string]$McpUrl, [string]$ClientId, [int]$HeartbeatIntervalSec, $StdinReadState) {
  if ($null -eq $Recover) { return $null }
  try {
    Write-SymppLauncherTrace "fallback_recovery_begin"
    $replacement = & $Recover $StdinReadState
    Write-SymppLauncherTrace "fallback_recovery_callback"
    $nextMcpUrl = [string]$replacement.mcp_url
    if ([string]::IsNullOrWhiteSpace($nextMcpUrl)) { return $null }
    $lease = Invoke-McpClientLease $nextMcpUrl $ClientId "attach" $true
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($McpUrl, $nextMcpUrl)) {
      Invoke-McpClientLease $McpUrl $ClientId "detach" | Out-Null
    }
    Write-SymppLauncherTrace "fallback_backend_recovery_ready"
    return [pscustomobject]@{
      mcp_url = $nextMcpUrl
      heartbeat_interval_ms = Resolve-McpClientHeartbeatIntervalMs $HeartbeatIntervalSec $lease
    }
  } catch {
    if ($_.Exception -isnot [System.OperationCanceledException]) { Write-Diagnostic "Symphony++ fallback backend recovery failed: $($_.Exception.Message)" }
    return $null
  }
}

function Invoke-HttpMcpBridge([string]$McpUrl, [int]$TimeoutSec, [string]$ClientId = $null, [int]$HeartbeatIntervalSec = 300, [scriptblock]$Recover = $null) {
  if ($null -ne $Recover) { Write-SymppLauncherTrace "fallback_recovery_enabled" }
  $sessionId = $null
  $protocolVersion = $null
  $needsInitialize = $false
  $stdinReader = New-McpStdinReader
  $lease = Invoke-McpClientLease $McpUrl $ClientId "attach" $true
  $heartbeatIntervalMs = Resolve-McpClientHeartbeatIntervalMs $HeartbeatIntervalSec $lease
  $lastHeartbeatMs = Get-McpNowMs
  try {
    $stdinReadState = New-McpStdinReadState $stdinReader
    while ($true) {
      $stdinLine = Receive-McpStdinLine $stdinReadState $heartbeatIntervalMs
      if (-not $stdinLine.ready) {
        $heartbeat = Invoke-McpClientLease $McpUrl $ClientId "heartbeat"
        if ($null -eq $heartbeat -and -not (Test-LoopbackHttpTcpOpen $McpUrl)) {
          $recovered = Invoke-McpBackendRecovery $Recover $McpUrl $ClientId $HeartbeatIntervalSec $stdinReadState
          if ($null -ne $recovered) {
            $McpUrl = $recovered.mcp_url; $heartbeatIntervalMs = $recovered.heartbeat_interval_ms
            $sessionId = $null; $protocolVersion = $null; $needsInitialize = $true
          }
        }
        $lastHeartbeatMs = Get-McpNowMs
        continue
      }

      $line = $stdinLine.line
      if ($null -eq $line) {
        break
      }
      if ([string]::IsNullOrWhiteSpace($line)) {
        continue
      }

      if ($null -ne $Recover) {
        $requestLease = Invoke-McpClientLease $McpUrl $ClientId "heartbeat"
        if ($null -ne $requestLease) {
          $heartbeatIntervalMs = Resolve-McpClientHeartbeatIntervalMs $HeartbeatIntervalSec $requestLease
          $lastHeartbeatMs = Get-McpNowMs
        }
      }
      $lastHeartbeatMs = Invoke-McpClientHeartbeatIfDue $McpUrl $ClientId $lastHeartbeatMs $heartbeatIntervalMs
      $requestProtocolVersion = Get-InitializeProtocolVersion $line
      if ($null -ne $Recover -and -not (Test-LoopbackHttpTcpOpen $McpUrl)) {
        $recovered = Invoke-McpBackendRecovery $Recover $McpUrl $ClientId $HeartbeatIntervalSec $stdinReadState
        if ($null -eq $recovered) {
          Write-JsonRpcErrorLine (Get-RequestIdForError $line) -32000 "Symphony++ HTTP MCP bridge request failed." @{ detail = "Backend recovery failed before request transmission." }
          continue
        }
        $McpUrl = $recovered.mcp_url; $heartbeatIntervalMs = $recovered.heartbeat_interval_ms
        $sessionId = $null; $protocolVersion = $null; $needsInitialize = $true
      }
      if ($needsInitialize -and [string]::IsNullOrWhiteSpace($requestProtocolVersion)) {
        $bridgeInitialize = Invoke-McpBridgeInitialize $McpUrl $TimeoutSec $ClientId $heartbeatIntervalMs
        if (-not $bridgeInitialize.ok) {
          Write-JsonRpcErrorLine (Get-RequestIdForError $line) -32000 "Symphony++ HTTP MCP bridge request failed." @{ detail = "Replacement MCP session initialization failed." }
          continue
        }
        $sessionId = $bridgeInitialize.session_id; $protocolVersion = $bridgeInitialize.protocol_version; $needsInitialize = $false
      }
      $response = Invoke-McpPost $McpUrl $line $sessionId $protocolVersion $TimeoutSec $ClientId $heartbeatIntervalMs
      $lastHeartbeatMs = Invoke-McpClientHeartbeatIfDue $McpUrl $ClientId $lastHeartbeatMs $heartbeatIntervalMs
      $nextSessionId = Get-ResponseHeaderValue $response.headers "Mcp-Session-Id"
      if (-not [string]::IsNullOrWhiteSpace($nextSessionId)) {
        $sessionId = $nextSessionId
      }

      if (Test-McpRecoverableSessionNotFound $response $sessionId $requestProtocolVersion) {
        if ($null -ne $Recover) {
          $recovered = Invoke-McpBackendRecovery $Recover $McpUrl $ClientId $HeartbeatIntervalSec $stdinReadState
          if ($null -ne $recovered) {
            $McpUrl = $recovered.mcp_url
            $heartbeatIntervalMs = $recovered.heartbeat_interval_ms
          }
        }
        $bridgeInitialize = Invoke-McpBridgeInitialize $McpUrl $TimeoutSec $ClientId $heartbeatIntervalMs
        $lastHeartbeatMs = Invoke-McpClientHeartbeatIfDue $McpUrl $ClientId $lastHeartbeatMs $heartbeatIntervalMs
        if ($bridgeInitialize.ok) {
          $sessionId = $bridgeInitialize.session_id
          $protocolVersion = $bridgeInitialize.protocol_version
          $response = Invoke-McpPost $McpUrl $line $sessionId $protocolVersion $TimeoutSec $ClientId $heartbeatIntervalMs
          $lastHeartbeatMs = Invoke-McpClientHeartbeatIfDue $McpUrl $ClientId $lastHeartbeatMs $heartbeatIntervalMs
          $nextSessionId = Get-ResponseHeaderValue $response.headers "Mcp-Session-Id"
          if (-not [string]::IsNullOrWhiteSpace($nextSessionId)) {
            $sessionId = $nextSessionId
          }
        }
      }

      $requestMayHaveReachedBackend = -not ($response.PSObject.Properties["may_have_reached_backend"] -and $response.may_have_reached_backend -eq $false)
      if ((Test-McpBackendUnavailableResponse $response) -and -not (Test-LoopbackHttpTcpOpen $McpUrl)) {
        $recovered = Invoke-McpBackendRecovery $Recover $McpUrl $ClientId $HeartbeatIntervalSec $stdinReadState
        if ($null -ne $recovered) {
          $McpUrl = $recovered.mcp_url; $heartbeatIntervalMs = $recovered.heartbeat_interval_ms
          $sessionId = $null; $protocolVersion = $null; $needsInitialize = $true
          if (-not $requestMayHaveReachedBackend -or -not (Test-McpToolCall $line)) {
            if (-not [string]::IsNullOrWhiteSpace($requestProtocolVersion)) {
              $needsInitialize = $false
            } else {
              $bridgeInitialize = Invoke-McpBridgeInitialize $McpUrl $TimeoutSec $ClientId $heartbeatIntervalMs
              if ($bridgeInitialize.ok) {
                $sessionId = $bridgeInitialize.session_id; $protocolVersion = $bridgeInitialize.protocol_version; $needsInitialize = $false
              }
            }
            if (-not $needsInitialize) {
              $response = Invoke-McpPost $McpUrl $line $sessionId $protocolVersion $TimeoutSec $ClientId $heartbeatIntervalMs
              $nextSessionId = Get-ResponseHeaderValue $response.headers "Mcp-Session-Id"
              if (-not [string]::IsNullOrWhiteSpace($nextSessionId)) { $sessionId = $nextSessionId }
              $requestMayHaveReachedBackend = -not ($response.PSObject.Properties["may_have_reached_backend"] -and $response.may_have_reached_backend -eq $false)
            }
          }
        }
      }
      if ((Test-McpBackendUnavailableResponse $response) -and (Test-McpToolCall $line) -and $requestMayHaveReachedBackend) {
        Write-JsonRpcErrorLine (Get-RequestIdForError $line) -32001 "Symphony++ tool call outcome is indeterminate." @{ reason = "backend_lost_after_request_started"; replayed = $false }
        continue
      }
      if (-not $response.ok) {
        Write-JsonRpcErrorLine (Get-RequestIdForError $line) -32000 "Symphony++ HTTP MCP bridge request failed." @{
          statusCode = $response.statusCode
          detail = $response.error
        }
        continue
      }

      if (-not [string]::IsNullOrWhiteSpace($requestProtocolVersion)) {
        $needsInitialize = $false
        $responseProtocolVersion = Get-ResponseProtocolVersion @($response.content_lines)
        if (-not [string]::IsNullOrWhiteSpace($responseProtocolVersion)) {
          $protocolVersion = $responseProtocolVersion
        } else {
          $protocolVersion = $requestProtocolVersion
        }
      }

      foreach ($contentLine in @($response.content_lines)) {
        Write-McpResponseLine $contentLine
      }
    }
  } finally {
    if ($null -ne $stdinReader) {
      $stdinReader.Dispose()
    }
    Invoke-McpClientLease $McpUrl $ClientId "detach" | Out-Null
  }
}

function Invoke-DirectStdioMcp([string]$RepoRoot, [string]$ElixirDir, [string]$Launcher, [string]$MixCommand, [string]$MiseCommand, $ArtifactRuntime = $null) {
  $mcpArgs = @("sympp.mcp", "--mode", "stdio")
  if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
    $mcpArgs += @("--repo-root", $RepoRoot)
  }
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    $mcpArgs += @("--database", ([System.IO.Path]::GetFullPath($env:SYMPP_DATABASE)))
  }

  if ($null -ne $ArtifactRuntime) {
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals([string]$ArtifactRuntime.command_contract, "runtime_wrapper")) {
      throw "artifact_direct_stdio_unsupported: verified artifact runtimes start the HTTP backend wrapper; use SYMPP_MCP_BRIDGE_MODE=http."
    }

    Set-Location -LiteralPath ([string]$ArtifactRuntime.root)
    & ([string]$ArtifactRuntime.entrypoint) @($mcpArgs)
    exit $LASTEXITCODE
  }

  Set-Location -LiteralPath $ElixirDir
  Assert-LauncherAvailable $Launcher $MixCommand $MiseCommand
  $command = Get-LauncherCommand $Launcher $MixCommand $MiseCommand $mcpArgs
  & $command.file @($command.args)
  exit $LASTEXITCODE
}
