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

function Get-ScriptFunctionDefinitions([string]$Path, [string[]]$Names) {
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) { throw "PowerShell parse failed for $Path" }
  $definitions = @{}
  foreach ($functionAst in $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Names -contains $node.Name
      }, $true)) {
    $body = $functionAst.Body.Extent.Text
    $parameters = if ($functionAst.Parameters.Count -gt 0) { "param(" + (($functionAst.Parameters.Extent.Text) -join ", ") + ")`n" } else { "" }
    $definitions[$functionAst.Name] = $parameters + $body.Substring(1, $body.Length - 2)
  }
  return $definitions
}

function Assert-CutoverProcessClassifier([string]$CutoverPath) {
  $names = @(
    "ConvertTo-FullPath", "Normalize-McpContractFingerprint", "Test-CommandLineContainsPath",
    "Test-CutoverPathWithinRoot", "Test-InstalledPluginRootOrigin", "Resolve-ManagedArtifactRuntimeContext",
    "Test-ManagedArtifactRuntimeProcess", "Get-SymppProcessKind", "Update-RuntimeStatePids"
  )
  $definitions = Get-ScriptFunctionDefinitions $CutoverPath $names
  foreach ($name in $names) {
    if (-not $definitions.ContainsKey($name)) { throw "cutover classifier is missing '$name'" }
    Set-Item -Path "Function:\$name" -Value $definitions[$name]
  }

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sympp-cutover-classifier-" + [guid]::NewGuid().ToString("N"))
  $expectedRevision = "a" * 40
  $artifactRevision = "e" * 40
  $contract = "b" * 64
  $sha256 = "c" * 64
  $platform = "windows-x86_64"
  $symppHome = Join-Path $tempRoot ".agents\splusplus"
  $marketplaceSourceRoot = Join-Path $tempRoot "marketplace"
  $installedPluginRoot = Join-Path $tempRoot "installed\symphony-plus-plus-mcp\0.1.9"
  $previousInstalledPluginRoot = Join-Path (Split-Path -Parent $installedPluginRoot) "0.1.8"
  $runtimeFile = Join-Path $symppHome "runtime\codex-plugin.json"
  $artifactRoot = Join-Path $symppHome "artifacts\mcp\$platform\$($artifactRevision.Substring(0, 12))\$($sha256.Substring(0, 16))\runtime"
  $executable = Join-Path $artifactRoot "runtime\erts-17.0.2\bin\erl.exe"

  try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $executable), $marketplaceSourceRoot, $installedPluginRoot, $previousInstalledPluginRoot, (Split-Path -Parent $runtimeFile) -Force | Out-Null
    Set-Content -LiteralPath $executable -Value "fixture" -Encoding UTF8
    $marker = [pscustomobject]@{ sha256 = $sha256; platform = $platform; source_revision = $artifactRevision }
    $manifest = [pscustomobject]@{
      source_revision = $artifactRevision
      plugin = [pscustomobject]@{ name = "symphony-plus-plus-mcp" }
      backend = [pscustomobject]@{ kind = "mix_release"; relative_path = "runtime" }
      launcher_contract = [pscustomobject]@{ mcp_contract_fingerprint = $contract }
    }
    $state = [pscustomobject]@{
      runtime_kind = "artifact"; runtime_mode = "artifact"; plugin_root = $installedPluginRoot
      backend = [pscustomobject]@{
        pid = 4242; managed = $true; source_revision = $artifactRevision; expected_source_revision = $artifactRevision
        contract_fingerprint = $contract; expected_contract_fingerprint = $contract
      }
    }
    $marker | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $artifactRoot ".sympp-artifact.json") -Encoding UTF8
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $artifactRoot "runtime-manifest.json") -Encoding UTF8
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $runtimeFile -Encoding UTF8

    $context = Resolve-ManagedArtifactRuntimeContext $runtimeFile $symppHome $installedPluginRoot $contract
    $process = [pscustomobject]@{ ProcessId = 4242; Name = "erl.exe"; ExecutablePath = $executable; CommandLine = "`"$executable`" -mode embedded" }
    if ((Get-SymppProcessKind $process $marketplaceSourceRoot $installedPluginRoot $context) -ne "managed_artifact_runtime") {
      throw "verified managed artifact listener was not classified"
    }
    if ([string]$context.SourceRevision -ne $artifactRevision -or [string]$context.ExpectedSourceRevision -ne $artifactRevision) {
      throw "contract-compatible artifact source revision was not preserved"
    }
    $state.plugin_root = $previousInstalledPluginRoot
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $runtimeFile -Encoding UTF8
    $upgradeContext = Resolve-ManagedArtifactRuntimeContext $runtimeFile $symppHome $installedPluginRoot $contract
    if (-not $upgradeContext -or
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$upgradeContext.RecordedPluginRoot, (ConvertTo-FullPath $previousInstalledPluginRoot))) {
      throw "contract-compatible artifact from a previous installed plugin version was not classified"
    }
    $preservedState = Update-RuntimeStatePids $runtimeFile $installedPluginRoot 4242 4343 $expectedRevision 19998 19999 $contract $upgradeContext
    if ([string]$preservedState.runtime_kind -ne "artifact" -or $preservedState.backend.managed -ne $true -or
        [string]$preservedState.backend.source_revision -ne $artifactRevision -or
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals((ConvertTo-FullPath ([string]$preservedState.plugin_root)), (ConvertTo-FullPath $installedPluginRoot))) {
      throw "accepted artifact runtime identity was not preserved across refresh"
    }
    $state = $preservedState
    if (-not (Resolve-ManagedArtifactRuntimeContext $runtimeFile $symppHome $installedPluginRoot $contract)) {
      throw "preserved artifact runtime could not be classified again"
    }

    foreach ($unsafeProcess in @(
        [pscustomobject]@{ ProcessId = 4243; Name = "erl.exe"; ExecutablePath = $executable; CommandLine = $process.CommandLine },
        [pscustomobject]@{ ProcessId = 4242; Name = "cmd.exe"; ExecutablePath = $executable; CommandLine = $process.CommandLine },
        [pscustomobject]@{ ProcessId = 4242; Name = "erl.exe"; ExecutablePath = (Join-Path $tempRoot "erl.exe"); CommandLine = $process.CommandLine }
      )) {
      if (Get-SymppProcessKind $unsafeProcess $marketplaceSourceRoot $installedPluginRoot $context) {
        throw "unsafe artifact listener process was classified"
      }
    }

    $state.plugin_root = Join-Path $tempRoot "unmanaged-plugin-root\0.1.8"
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $runtimeFile -Encoding UTF8
    if (Resolve-ManagedArtifactRuntimeContext $runtimeFile $symppHome $installedPluginRoot $contract) {
      throw "runtime state from outside the installed plugin cache was accepted"
    }
    $state.plugin_root = $installedPluginRoot

    $state.backend.managed = $false
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $runtimeFile -Encoding UTF8
    if (Resolve-ManagedArtifactRuntimeContext $runtimeFile $symppHome $installedPluginRoot $contract) {
      throw "unmanaged runtime state was accepted"
    }
    $state.backend.managed = $true
    $state.backend.expected_source_revision = "d" * 40
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $runtimeFile -Encoding UTF8
    if (Resolve-ManagedArtifactRuntimeContext $runtimeFile $symppHome $installedPluginRoot $contract) {
      throw "mismatched runtime revision was accepted"
    }
    $state.backend.expected_source_revision = $artifactRevision
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $runtimeFile -Encoding UTF8
    if (Resolve-ManagedArtifactRuntimeContext $runtimeFile $symppHome $installedPluginRoot ("d" * 64)) {
      throw "mismatched runtime contract was accepted"
    }

    $marker.source_revision = "d" * 40
    $marker | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $artifactRoot ".sympp-artifact.json") -Encoding UTF8
    if (Get-SymppProcessKind $process $marketplaceSourceRoot $installedPluginRoot $context) {
      throw "artifact marker revision mismatch was accepted"
    }
    $marker.source_revision = $artifactRevision
    $marker | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $artifactRoot ".sympp-artifact.json") -Encoding UTF8
    $manifest.launcher_contract.mcp_contract_fingerprint = "d" * 64
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $artifactRoot "runtime-manifest.json") -Encoding UTF8
    if (Get-SymppProcessKind $process $marketplaceSourceRoot $installedPluginRoot $context) {
      throw "artifact manifest contract mismatch was accepted"
    }
  } finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
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
  $artifactContextIndex = $cutover.IndexOf('$managedArtifactContext = Resolve-ManagedArtifactRuntimeContext')
  $existingListenerIndex = $cutover.IndexOf('if ($backendListeners.Count -eq 1)')
  $artifactSetupGateIndex = $cutover.IndexOf('if ($acceptedManagedArtifactContext)')
  $sourceSetupIndex = $cutover.IndexOf('Invoke-ElixirSetup $marketplaceSourceRoot')
  if ($artifactContextIndex -lt 0 -or $existingListenerIndex -lt 0 -or $artifactSetupGateIndex -lt 0 -or $sourceSetupIndex -lt 0 -or
      $artifactContextIndex -ge $existingListenerIndex -or $existingListenerIndex -ge $artifactSetupGateIndex -or
      $artifactSetupGateIndex -ge $sourceSetupIndex) {
    throw "cutover does not classify an existing managed artifact listener before source setup"
  }
  Assert-CutoverProcessClassifier $cutoverPath
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
