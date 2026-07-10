$ErrorActionPreference = "Stop"

function Resolve-OptionalPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  return [System.IO.Path]::GetFullPath($Path)
}

function Test-SymphonySourceRoot([string]$Path) {
  return (-not [string]::IsNullOrWhiteSpace($Path)) -and (Test-Path -LiteralPath (Join-Path $Path "elixir/mix.exs"))
}

function Get-FileSha256([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
      return (($sha256.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
      $stream.Dispose()
    }
  } finally {
    $sha256.Dispose()
  }
}

function Normalize-SymppMarketplaceSourceRevision([string]$Revision) {
  if ([string]::IsNullOrWhiteSpace($Revision)) {
    return $null
  }

  $normalized = $Revision.Trim().ToLowerInvariant()
  if ($normalized -match "^[0-9a-f]{40}$") {
    return $normalized
  }

  return $null
}

function Get-SymppMarketplaceSourceRevision([string]$SourceRoot) {
  $installPath = Join-Path $SourceRoot ".codex-marketplace-install.json"
  if (Test-Path -LiteralPath $installPath -PathType Leaf) {
    try {
      $install = Get-Content -LiteralPath $installPath -Raw | ConvertFrom-Json
      foreach ($propertyName in @("revision", "source_revision", "sourceRevision")) {
        if ($install.PSObject.Properties[$propertyName]) {
          $revision = Normalize-SymppMarketplaceSourceRevision ([string]$install.PSObject.Properties[$propertyName].Value)
          if ($revision) {
            return $revision
          }
        }
      }
    } catch {
    }
  }

  $revisionPath = Join-Path $SourceRoot ".sympp-source-revision"
  if (Test-Path -LiteralPath $revisionPath -PathType Leaf) {
    return Normalize-SymppMarketplaceSourceRevision (Get-Content -LiteralPath $revisionPath -Raw)
  }

  return $null
}

function Test-SymppMarketplaceContractMatchesRevision([string]$SourceRoot, [string]$ExpectedRevision) {
  $contractRelativePath = "implementation_docs_symphplusplus/mcp/mcp_tools_contract.json"
  $contractPath = Join-Path $SourceRoot $contractRelativePath
  if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    return $false
  }

  $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $git) {
    return $true
  }

  try {
    $insideWorkTree = @(& $git.Source @("-C", $SourceRoot, "rev-parse", "--is-inside-work-tree") 2>$null)
    if ($LASTEXITCODE -ne 0 -or $insideWorkTree.Count -eq 0 -or ([string]$insideWorkTree[0]).Trim().ToLowerInvariant() -ne "true") {
      return $true
    }

    $committedObject = @(& $git.Source @("-C", $SourceRoot, "rev-parse", "$($ExpectedRevision):$contractRelativePath") 2>$null)
    if ($LASTEXITCODE -ne 0 -or $committedObject.Count -eq 0) {
      return $false
    }

    $workingObject = @(& $git.Source @("-C", $SourceRoot, "hash-object", "--", $contractRelativePath) 2>$null)
    if ($LASTEXITCODE -ne 0 -or $workingObject.Count -eq 0) {
      return $false
    }

    return [System.StringComparer]::OrdinalIgnoreCase.Equals(([string]$committedObject[0]).Trim(), ([string]$workingObject[0]).Trim())
  } catch {
    return $false
  }
}

function Test-InstalledPluginPayloadMatchesMarketplaceSource([string]$PluginRoot, [string]$SourceRoot) {
  $packageRoot = Split-Path -Parent ([System.IO.Path]::GetFullPath($PluginRoot))
  $packageName = Split-Path -Leaf $packageRoot
  $sourcePluginRoot = Join-Path $SourceRoot "plugins/$packageName"
  $relativePaths = @(
    ".codex-plugin/plugin.json",
    ".mcp.json",
    "scripts/start-sympp-mcp.ps1",
    "scripts/sympp-launcher-runtime.ps1",
    "scripts/sympp-mcp-artifact-manifest.ps1",
    "scripts/sympp-mcp-artifact-runtime.ps1",
    "scripts/sympp-mcp-process-runtime.ps1",
    "scripts/sympp-mcp-launcher-helpers.ps1"
  )
  $checked = 0

  foreach ($relativePath in $relativePaths) {
    $installedPath = Join-Path $PluginRoot $relativePath
    if (-not (Test-Path -LiteralPath $installedPath)) {
      continue
    }

    $sourcePath = Join-Path $sourcePluginRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
      return $false
    }

    if ((Get-FileSha256 $installedPath) -ne (Get-FileSha256 $sourcePath)) {
      return $false
    }
    $checked += 1
  }

  return $checked -gt 0
}

function Resolve-RepoRootFromMarketplaceCache([string]$PluginRoot) {
  $versionRoot = [System.IO.Path]::GetFullPath($PluginRoot)
  $packageRoot = Split-Path -Parent $versionRoot
  $marketplaceRoot = Split-Path -Parent $packageRoot
  $cacheRoot = Split-Path -Parent $marketplaceRoot
  $pluginsRoot = Split-Path -Parent $cacheRoot

  if ((Split-Path -Leaf $cacheRoot) -ne "cache" -or (Split-Path -Leaf $pluginsRoot) -ne "plugins") {
    return $null
  }

  $codexHome = Split-Path -Parent $pluginsRoot
  $marketplaceName = Split-Path -Leaf $marketplaceRoot
  $candidate = [System.IO.Path]::GetFullPath((Join-Path $codexHome ".tmp/marketplaces/$marketplaceName"))

  if ((Test-SymphonySourceRoot $candidate) -and
      (Test-Path -LiteralPath (Join-Path $candidate "plugins/symphony-plus-plus/.codex-plugin/plugin.json")) -and
      (Test-Path -LiteralPath (Join-Path $candidate "plugins/symphony-plus-plus-mcp/.codex-plugin/plugin.json"))) {
    $installedRevision = Get-SymppPinnedSourceRevision $versionRoot
    $marketplaceRevision = Get-SymppMarketplaceSourceRevision $candidate
    if (-not $installedRevision -or -not $marketplaceRevision -or
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals($installedRevision, $marketplaceRevision)) {
      return $null
    }

    if (-not (Test-SymppMarketplaceContractMatchesRevision $candidate $marketplaceRevision)) {
      return $null
    }

    if (-not (Test-InstalledPluginPayloadMatchesMarketplaceSource $versionRoot $candidate)) {
      return $null
    }

    return $candidate
  }

  return $null
}

function Test-SymphonySourceTreeMatchesRevision([string]$Path, [string]$ExpectedRevision) {
  $headRevision = Get-SymppGitHeadRevision $Path
  if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($ExpectedRevision, $headRevision)) {
    return $false
  }

  $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $git) {
    return $false
  }

  try {
    $status = @(& $git.Source @("-C", $Path, "status", "--porcelain=v1", "--untracked-files=all") 2>$null)
    return $LASTEXITCODE -eq 0 -and $status.Count -eq 0
  } catch {
    return $false
  }
}

function Resolve-RepoRootFromSourceCache([string]$PluginRoot) {
  $pluginRoot = [System.IO.Path]::GetFullPath($PluginRoot)
  $installedRevision = Get-SymppPinnedSourceRevision $pluginRoot
  if (-not $installedRevision) {
    return $null
  }

  $sourceCacheRoot = [System.IO.Path]::GetFullPath((Join-Path (Resolve-SymppPluginHome) "source-cache"))
  if (-not (Test-Path -LiteralPath $sourceCacheRoot)) {
    return $null
  }

  $candidates = @(
    Get-ChildItem -LiteralPath $sourceCacheRoot -Directory -Filter "symphony-plus-plus-*" -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending
  )

  foreach ($candidate in $candidates) {
    $candidatePath = [System.IO.Path]::GetFullPath($candidate.FullName)
    if (-not (Test-SymphonySourceRoot $candidatePath)) {
      continue
    }

    if ((Test-SymphonySourceTreeMatchesRevision $candidatePath $installedRevision) -and
        (Test-InstalledPluginPayloadMatchesMarketplaceSource $pluginRoot $candidatePath)) {
      return $candidatePath
    }
  }

  return $null
}

function Resolve-RepoRootFromPluginRoot([string]$PluginRoot) {
  $pluginRoot = [System.IO.Path]::GetFullPath($PluginRoot)
  $sourceCandidate = [System.IO.Path]::GetFullPath((Join-Path $pluginRoot "../.."))
  if (Test-SymphonySourceRoot $sourceCandidate) {
    return $sourceCandidate
  }

  $sourceCacheRoot = Resolve-RepoRootFromSourceCache $pluginRoot
  if ($sourceCacheRoot) {
    return $sourceCacheRoot
  }

  $marketplaceRoot = Resolve-RepoRootFromMarketplaceCache $pluginRoot
  if ($marketplaceRoot) {
    return $marketplaceRoot
  }

  throw "Cannot infer the Symphony++ runtime source. Run codex plugin marketplace upgrade, or set SYMPP_REPO_ROOT only for explicit developer validation."
}

function Resolve-RepoRoot {
  $configuredRoot = Resolve-OptionalPath $env:SYMPP_REPO_ROOT
  if ($configuredRoot) {
    if (Test-SymphonySourceRoot $configuredRoot) {
      return $configuredRoot
    }

    throw "SYMPP_REPO_ROOT does not look like a Symphony++ checkout with elixir/mix.exs: $configuredRoot"
  }

  $pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
  return Resolve-RepoRootFromPluginRoot $pluginRoot
}

function Resolve-SymppHome {
  $configured = Resolve-OptionalPath $env:SYMPP_HOME
  if ($configured) {
    return $configured
  }

  return Resolve-SymppPluginHome
}

function Resolve-RuntimeFile {
  $configured = Resolve-OptionalPath $env:SYMPP_RUNTIME_FILE
  if ($configured) {
    return $configured
  }

  return [System.IO.Path]::GetFullPath((Join-Path (Resolve-SymppHome) "runtime/codex-plugin.json"))
}

function Resolve-LogDir {
  $configured = Resolve-OptionalPath $env:SYMPP_LOG_DIR
  if ($configured) {
    return $configured
  }

  return [System.IO.Path]::GetFullPath((Join-Path (Resolve-SymppHome) "logs"))
}

function Resolve-StartupLockFile([string]$RuntimeFile) {
  $runtimeDir = Split-Path -Parent $RuntimeFile
  return [System.IO.Path]::GetFullPath((Join-Path $runtimeDir "codex-plugin.lock"))
}

function Resolve-BridgeLeaseDir([string]$RuntimeFile) {
  return [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $RuntimeFile) "codex-plugin-leases"))
}

function Get-ProcessStartIdentity($Process) {
  try {
    return [string]$Process.StartTime.ToUniversalTime().Ticks
  } catch {
    return $null
  }
}

function Get-ProcessIdentityMap([int[]]$ProcessIds) {
  $identities = @{}
  $ids = @($ProcessIds | Where-Object { $_ -gt 0 } | Select-Object -Unique)
  if ($ids.Count -eq 0) {
    return $identities
  }

  foreach ($process in @(Get-Process -Id $ids -ErrorAction SilentlyContinue)) {
    $identities[[string]$process.Id] = [pscustomobject]@{
      exists = $true
      start_time_utc_ticks = Get-ProcessStartIdentity $process
    }
  }
  return $identities
}

function New-BridgeLease([string]$RuntimeFile, $BackendPlan, $DashboardPlan, [string]$RuntimeKey) {
  $leaseDir = Resolve-BridgeLeaseDir $RuntimeFile
  New-Item -ItemType Directory -Path $leaseDir -Force | Out-Null
  $leasePath = Join-Path $leaseDir ("bridge-$PID-$([guid]::NewGuid().ToString('N')).json")
  $temporaryPath = "$leasePath.tmp"
  $process = Get-Process -Id $PID -ErrorAction Stop
  $lease = [pscustomobject]@{
    pid = $PID
    process_start_time_utc_ticks = Get-ProcessStartIdentity $process
    created_at = [DateTimeOffset]::UtcNow.ToString("o")
    runtime_key = $RuntimeKey
    runtime_kind = if ($BackendPlan.managed -eq $true) { "managed" } else { [string]$BackendPlan.status }
    source_revision = $BackendPlan.source_revision
    backend_url = $BackendPlan.url
    dashboard_origin = $DashboardPlan.origin
  }
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  try {
    [System.IO.File]::WriteAllText($temporaryPath, (($lease | ConvertTo-Json -Depth 8) + "`n"), $utf8NoBom)
    [System.IO.File]::Move($temporaryPath, $leasePath)
  } finally {
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
  }
  return $leasePath
}

function Remove-BridgeLease([string]$LeasePath) {
  if (-not [string]::IsNullOrWhiteSpace($LeasePath)) {
    Remove-Item -LiteralPath $LeasePath -Force -ErrorAction SilentlyContinue
  }
}

function Test-BridgeLeaseActive($Lease, $ProcessIdentities) {
  if ($null -eq $Lease -or -not $Lease.PSObject.Properties["pid"]) {
    return $false
  }

  $leasePid = 0
  if (-not [int]::TryParse([string]$Lease.pid, [ref]$leasePid) -or $leasePid -le 0 -or
      -not $ProcessIdentities.ContainsKey([string]$leasePid)) {
    return $false
  }

  $processIdentity = $ProcessIdentities[[string]$leasePid]
  $actualStart = [string]$processIdentity.start_time_utc_ticks
  if ($Lease.PSObject.Properties["process_start_time_utc_ticks"] -and
      -not [string]::IsNullOrWhiteSpace([string]$Lease.process_start_time_utc_ticks)) {
    return [string]::IsNullOrWhiteSpace($actualStart) -or
      [System.StringComparer]::Ordinal.Equals([string]$Lease.process_start_time_utc_ticks, $actualStart)
  }

  # Legacy leases have no exact start identity. Keep a live pre-lease process,
  # but reject a reused PID whose process started after the lease was created.
  if (-not [string]::IsNullOrWhiteSpace($actualStart) -and $Lease.PSObject.Properties["created_at"]) {
    $createdAt = [DateTimeOffset]::MinValue
    $startTicks = 0L
    if ([DateTimeOffset]::TryParse([string]$Lease.created_at, [ref]$createdAt) -and
        [long]::TryParse($actualStart, [ref]$startTicks)) {
      return $startTicks -le $createdAt.UtcDateTime.Ticks
    }
  }

  return $true
}

function Get-ActiveBridgeLeases([string]$RuntimeFile) {
  $leaseDir = Resolve-BridgeLeaseDir $RuntimeFile
  if (-not (Test-Path -LiteralPath $leaseDir -PathType Container)) {
    return @()
  }

  $candidates = [System.Collections.Generic.List[object]]::new()
  foreach ($leasePath in @(Get-ChildItem -LiteralPath $leaseDir -Filter "bridge-*.json" -File -ErrorAction SilentlyContinue)) {
    $lease = $null
    try {
      $lease = Get-Content -LiteralPath $leasePath.FullName -Raw | ConvertFrom-Json
    } catch {
    }
    $candidates.Add([pscustomobject]@{ path = $leasePath.FullName; lease = $lease })
  }

  $processIds = @($candidates | ForEach-Object {
      $leasePid = 0
      if ($null -ne $_.lease -and [int]::TryParse([string]$_.lease.pid, [ref]$leasePid)) { $leasePid }
    })
  $processIdentities = Get-ProcessIdentityMap $processIds
  $active = [System.Collections.Generic.List[object]]::new()
  foreach ($candidate in $candidates) {
    if (Test-BridgeLeaseActive $candidate.lease $processIdentities) {
      $active.Add($candidate)
    } else {
      Remove-Item -LiteralPath $candidate.path -Force -ErrorAction SilentlyContinue
    }
  }

  return @($active)
}

function Enter-FileLock([string]$LockPath, [int]$TimeoutSec) {
  $lockDir = Split-Path -Parent $LockPath
  New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)

  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      return [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
      Start-Sleep -Milliseconds 200
    }
  }

  throw "Timed out waiting for Symphony++ launcher startup lock: $LockPath"
}

function Exit-FileLock($Lock) {
  if ($null -ne $Lock) {
    $Lock.Dispose()
  }
}

function Test-EnvDisabled([string]$Name) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $false
  }

  return $value.Trim().ToLowerInvariant() -in @("0", "false", "no", "off")
}

function Get-EnvInteger([string]$Name, [int]$Default, [int]$Min, [int]$Max) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $Default
  }

  $parsed = 0
  if (-not [int]::TryParse($value.Trim(), [ref]$parsed) -or $parsed -lt $Min -or $parsed -gt $Max) {
    throw "$Name must be an integer from $Min to $Max."
  }

  return $parsed
}

function Get-EnvMode([string]$Name, [string]$Default, [string[]]$Allowed) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  $mode = if ([string]::IsNullOrWhiteSpace($value)) { $Default } else { $value.Trim().ToLowerInvariant() }
  if ($Allowed -notcontains $mode) {
    throw "$Name must be one of: $($Allowed -join ', ')."
  }

  return $mode
}

function Test-IsMiseShim([string]$Path) {
  $normalized = $Path.Replace("\", "/").ToLowerInvariant()
  return ($normalized -match "/mise/" -or $normalized -match "/\.mise/") -and $normalized -match "/shims?/"
}

function Resolve-CommandSource([string]$CommandName, [string]$MissingMessage) {
  $command = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $command) {
    throw $MissingMessage
  }

  if ($command.Source) {
    return [string]$command.Source
  }

  return [string]$command.Path
}

function Assert-LoopbackHttpOrigin([string]$Url, [string]$Name) {
  try {
    $uri = [System.Uri]$Url
  } catch {
    throw "$Name must be a valid local http URL."
  }

  if ($uri.Scheme -ne "http" -or -not $uri.IsLoopback) {
    throw "$Name must use a loopback http origin."
  }
}

function Resolve-NpmCommand {
  foreach ($candidate in @("npm.cmd", "npm.exe", "npm")) {
    $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.CommandType -eq "Application") {
      if ($command.Source) {
        return [string]$command.Source
      }
      return [string]$command.Path
    }
  }

  throw "Could not find npm executable. Install Node/npm or set SYMPP_DASHBOARD_ORIGIN to an existing dashboard."
}

function Test-NpmAvailable {
  try {
    [void](Resolve-NpmCommand)
    return $true
  } catch {
    return $false
  }
}

function Get-PowerShellHostCommandName {
  foreach ($candidate in @("pwsh", "powershell.exe", "powershell")) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) {
      return $candidate
    }
  }

  return "powershell"
}

function Get-StartProcessCommand([string]$FilePath, [string[]]$ArgumentList) {
  if ($FilePath.EndsWith(".ps1", [System.StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject]@{
      file = Get-PowerShellHostCommandName
      args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $FilePath) + @($ArgumentList)
    }
  }

  return [pscustomobject]@{
    file = $FilePath
    args = @($ArgumentList)
  }
}

function ConvertTo-ProcessArgument([string]$Argument) {
  if ($null -eq $Argument -or $Argument.Length -eq 0) {
    return '""'
  }

  if ($Argument -notmatch '[\s"]') {
    return $Argument
  }

  $result = [System.Text.StringBuilder]::new()
  [void]$result.Append('"')
  $backslashes = 0
  foreach ($char in $Argument.ToCharArray()) {
    if ($char -eq '\') {
      $backslashes += 1
    } elseif ($char -eq '"') {
      [void]$result.Append('\' * (($backslashes * 2) + 1))
      [void]$result.Append('"')
      $backslashes = 0
    } else {
      if ($backslashes -gt 0) {
        [void]$result.Append('\' * $backslashes)
        $backslashes = 0
      }
      [void]$result.Append($char)
    }
  }

  if ($backslashes -gt 0) {
    [void]$result.Append('\' * ($backslashes * 2))
  }
  [void]$result.Append('"')
  return $result.ToString()
}

function Join-ProcessArgumentList([string[]]$ArgumentList) {
  return (@($ArgumentList) | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " "
}

function Resolve-MixCommand([string]$MixCommand) {
  $source = Resolve-CommandSource $MixCommand "Could not find mix executable '$MixCommand'. Install Elixir or set SYMPP_MIX."
  if (Test-IsMiseShim $source) {
    throw "Direct launcher resolved mix to a mise shim: $source. Set SYMPP_MIX to a non-mise Mix executable, or set SYMPP_LAUNCHER=mise after trusting the checkout's mise config."
  }

  return $source
}

function Assert-LauncherAvailable([string]$Launcher, [string]$MixCommand, [string]$MiseCommand) {
  switch ($Launcher) {
    "direct" {
      [void](Resolve-MixCommand $MixCommand)
      return
    }
    "mise" {
      [void](Resolve-CommandSource $MiseCommand "Could not find mise executable '$MiseCommand'. Install mise or set SYMPP_MISE.")
      return
    }
    default {
      throw "Unsupported SYMPP_LAUNCHER '$Launcher'. Use 'direct' or 'mise'."
    }
  }
}

function Get-LauncherCommand([string]$Launcher, [string]$MixCommand, [string]$MiseCommand, [string[]]$MixArgs) {
  switch ($Launcher) {
    "direct" {
      return [pscustomobject]@{
        file = Resolve-MixCommand $MixCommand
        args = @($MixArgs)
      }
    }
    "mise" {
      return [pscustomobject]@{
        file = Resolve-CommandSource $MiseCommand "Could not find mise executable '$MiseCommand'. Install mise or set SYMPP_MISE."
        args = @("exec", "--", "mix") + @($MixArgs)
      }
    }
    default {
      throw "Unsupported SYMPP_LAUNCHER '$Launcher'. Use 'direct' or 'mise'."
    }
  }
}

function Test-LauncherVersion([string]$Launcher, [string]$MixCommand, [string]$MiseCommand) {
  $command = Get-LauncherCommand $Launcher $MixCommand $MiseCommand @("--version")
  & $command.file @($command.args) | Out-Host
  return $LASTEXITCODE
}

function Test-PortAvailable([int]$Port) {
  if ($Port -eq 0) {
    return $true
  }

  $listener = $null
  try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), $Port)
    $listener.Start()
    return $true
  } catch {
    return $false
  } finally {
    if ($listener) {
      $listener.Stop()
    }
  }
}

function New-PortOwner([int]$ProcessId, [string]$LocalAddress) {
  $processName = "<unknown>"
  try {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($process.ProcessName)) {
      $processName = [string]$process.ProcessName
    }
  } catch {
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
    } catch {
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
    } catch {
    }
  }

  return @($owners)
}

function Format-PortOwners([object[]]$Owners) {
  if ($Owners.Count -eq 0) {
    return "an unknown process"
  }

  return (@($Owners) | ForEach-Object {
      "pid=$($_.pid) process=$($_.process) localAddress=$($_.localAddress)"
    }) -join "; "
}

function New-BackendPortOccupiedMessage([int]$Port, [object[]]$Owners) {
  $ownerSummary = Format-PortOwners $Owners
  return "backend_port_occupied: configured Symphony++ backend port http://127.0.0.1:$Port is occupied by $ownerSummary. Wait for stale listeners to exit, stop the owning process, set SYMPP_BACKEND_PORT=0 or another explicit port, or set SYMPP_BACKEND_URL to a healthy backend."
}
