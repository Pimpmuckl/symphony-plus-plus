[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
  [string]$CodexHome = $(if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $HOME ".codex" } else { $env:CODEX_HOME }),
  [string]$SymppHome = $(if ([string]::IsNullOrWhiteSpace($env:SYMPP_HOME)) { Join-Path $HOME ".agents\splusplus" } else { $env:SYMPP_HOME }),
  [string]$MarketplaceName = "symphony-plus-plus",
  [string]$McpPluginName = "symphony-plus-plus-mcp",
  [string]$ExpectedSourceRevision,
  [int]$BackendPort = 19998,
  [int]$DashboardPort = 19999,
  [switch]$SkipMarketplaceUpgrade,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$script:SymppCutoverDryRun = [bool]$WhatIfPreference
if ($script:SymppCutoverDryRun) {
  $WhatIfPreference = $false
}
$script:SymppGeneratedPluginCacheFiles = @(".sympp-source-revision")

function Write-Section([string]$Title) {
  if (-not $Json) {
    Write-Host ""
    Write-Host "== $Title =="
  }
}

function ConvertTo-FullPath([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path)
}

function Require-Directory([string]$Path, [string]$Label) {
  $fullPath = ConvertTo-FullPath $Path
  if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
    throw "$Label does not exist: $fullPath"
  }

  return $fullPath
}

function Require-File([string]$Path, [string]$Label) {
  $fullPath = ConvertTo-FullPath $Path
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    throw "$Label does not exist: $fullPath"
  }

  return $fullPath
}

function Invoke-CapturedCommand([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory = $null) {
  $previousLocation = $null
  if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    $previousLocation = Get-Location
    Set-Location -LiteralPath $WorkingDirectory
  }

  try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = @(& $FilePath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
    if ($previousLocation) {
      Set-Location -LiteralPath $previousLocation
    }
  }

  return [pscustomobject]@{
    ExitCode = $exitCode
    Stdout = (($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) | Out-String)
    Stderr = (($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) | Out-String)
  }
}

function Invoke-CheckedCommand([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory = $null, [string]$Label = $FilePath) {
  $result = Invoke-CapturedCommand $FilePath $Arguments $WorkingDirectory
  if ($result.ExitCode -ne 0) {
    $message = "$Label failed with exit code $($result.ExitCode)."
    if (-not [string]::IsNullOrWhiteSpace($result.Stdout)) {
      $message += "`nSTDOUT:`n$($result.Stdout)"
    }
    if (-not [string]::IsNullOrWhiteSpace($result.Stderr)) {
      $message += "`nSTDERR:`n$($result.Stderr)"
    }
    throw $message
  }

  return $result
}

function Get-GitRevision([string]$RepoRoot) {
  $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $git) {
    throw "git was not found on PATH."
  }

  $result = Invoke-CheckedCommand $git.Source @("-C", $RepoRoot, "rev-parse", "--verify", "HEAD") $RepoRoot "git rev-parse"
  $revision = ($result.Stdout -split "(`r`n|`n|`r)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1).Trim().ToLowerInvariant()
  if ($revision -notmatch "^[0-9a-f]{40}$") {
    throw "git returned an invalid source revision for $RepoRoot`: $revision"
  }

  return $revision
}

function Get-RevisionFromTextFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  $content = (Get-Content -LiteralPath $Path -Raw).Trim().ToLowerInvariant()
  if ($content -match "^[0-9a-f]{40}$") {
    return $content
  }

  return $null
}

function Get-RevisionFromInstallMetadata([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  $metadata = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  foreach ($propertyName in @("source_revision", "sourceRevision", "revision", "commit", "head")) {
    $property = $metadata.PSObject.Properties[$propertyName]
    if ($property -and $property.Value) {
      $value = ([string]$property.Value).Trim().ToLowerInvariant()
      if ($value -match "^[0-9a-f]{40}$") {
        return $value
      }
    }
  }

  return $null
}

function Get-FileSha256([string]$Path) {
  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
      return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
    } finally {
      $sha256.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

function Resolve-MarketplaceSourceRevision([string]$MarketplaceSourceRoot) {
  try {
    return Get-GitRevision $MarketplaceSourceRoot
  } catch {
    # Installed marketplace caches may be packaged without .git. Match the
    # launcher contract and fall back to pinned non-secret revision markers.
  }

  foreach ($candidate in @(
      (Join-Path $MarketplaceSourceRoot ".codex-marketplace-install.json"),
      (Join-Path $MarketplaceSourceRoot ".sympp-source-revision")
    )) {
    $revision = if ($candidate.EndsWith(".json", [System.StringComparison]::OrdinalIgnoreCase)) {
      Get-RevisionFromInstallMetadata $candidate
    } else {
      Get-RevisionFromTextFile $candidate
    }
    if (-not [string]::IsNullOrWhiteSpace($revision)) {
      return $revision
    }
  }

  throw "Could not resolve the marketplace Symphony++ source revision from git, .codex-marketplace-install.json, or marketplace .sympp-source-revision."
}

function Normalize-ExpectedSourceRevision([string]$Revision) {
  if ([string]::IsNullOrWhiteSpace($Revision)) {
    return $null
  }

  $normalized = $Revision.Trim().ToLowerInvariant()
  if ($normalized -notmatch "^[0-9a-f]{40}$") {
    throw "ExpectedSourceRevision must be a 40-character git SHA."
  }

  return $normalized
}

function Resolve-InstalledPluginRoot([string]$CacheRoot, [string]$PluginName, [string]$RequiredRelativePath, [bool]$Required = $true) {
  $pluginRoot = Join-Path $CacheRoot $PluginName
  $pluginRoot = ConvertTo-FullPath $pluginRoot
  if (-not (Test-Path -LiteralPath $pluginRoot -PathType Container)) {
    if ($Required) {
      throw "Installed $PluginName plugin cache does not exist: $pluginRoot"
    }
    return $null
  }

  $candidates = @(
    Get-ChildItem -LiteralPath $pluginRoot -Directory |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $RequiredRelativePath) }
  )
  if ($candidates.Count -eq 0) {
    if ($Required) {
      throw "No installed $PluginName cache entry with $RequiredRelativePath was found under $pluginRoot."
    }
    return $null
  }

  $sortable = @(
    foreach ($candidate in $candidates) {
      $version = $null
      $parsed = [version]::new(0, 0)
      if ([version]::TryParse($candidate.Name, [ref]$version)) {
        $parsed = $version
      }
      [pscustomobject]@{
        Path = $candidate.FullName
        Version = $parsed
        LastWriteTimeUtc = $candidate.LastWriteTimeUtc
      }
    }
  )

  return ($sortable | Sort-Object Version, LastWriteTimeUtc | Select-Object -Last 1).Path
}

function Invoke-MarketplaceUpgrade([string]$CodexHomePath) {
  $codex = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $codex) {
    throw "codex was not found on PATH; pass -SkipMarketplaceUpgrade only when the installed marketplace/cache is already refreshed."
  }

  $previousCodexHome = $env:CODEX_HOME
  try {
    $env:CODEX_HOME = $CodexHomePath
    return Invoke-CheckedCommand $codex.Source @("plugin", "marketplace", "upgrade") $HOME "codex plugin marketplace upgrade"
  } finally {
    $env:CODEX_HOME = $previousCodexHome
  }
}

function Resolve-InstalledMcpPluginRoot([string]$CacheRoot) {
  return Resolve-InstalledPluginRoot $CacheRoot $McpPluginName ".mcp.json" $true
}

function Assert-InstalledDirectMcpConfig([string]$InstalledPluginRoot, [int]$BackendPort) {
  $configPath = Require-File (Join-Path $InstalledPluginRoot ".mcp.json") "Installed MCP config"
  $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  $servers = if ($config.PSObject.Properties["mcp_servers"]) { $config.mcp_servers } else { $config }
  $server = $servers.PSObject.Properties["symphony_plus_plus"].Value
  $expectedUrl = "http://127.0.0.1:$BackendPort/mcp"

  if ($null -eq $server -or [string]$server.url -ne $expectedUrl) {
    throw "Installed Symphony++ MCP config must use direct streamable HTTP at $expectedUrl."
  }
  foreach ($stdioField in @("command", "args", "cwd")) {
    if ($server.PSObject.Properties[$stdioField]) {
      throw "Installed Symphony++ MCP config mixes direct HTTP with stdio field '$stdioField'."
    }
  }

  return $expectedUrl
}

function Resolve-InstalledDefaultPluginRoot([string]$CacheRoot) {
  return Resolve-InstalledPluginRoot $CacheRoot $MarketplaceName ".codex-plugin\plugin.json" $false
}

function Get-PluginSourceRoot([string]$MarketplaceSourceRoot, [string]$PluginName) {
  return Require-Directory (Join-Path $MarketplaceSourceRoot "plugins\$PluginName") "Marketplace $PluginName plugin payload"
}

function Get-PluginManifestVersion([string]$PluginRoot) {
  $manifestPath = Require-File (Join-Path $PluginRoot ".codex-plugin\plugin.json") "Plugin manifest"
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $version = ([string]$manifest.version).Trim()
  if ([string]::IsNullOrWhiteSpace($version)) {
    throw "Plugin manifest does not contain a version: $manifestPath"
  }

  return $version
}

function ConvertTo-PluginRelativePath([string]$PluginRoot, [string]$Path) {
  return $Path.Substring($PluginRoot.Length).TrimStart("\", "/").Replace("/", "\")
}

function Test-GeneratedPluginCacheFile([string]$RelativeFile) {
  foreach ($generatedFile in $script:SymppGeneratedPluginCacheFiles) {
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($RelativeFile, $generatedFile)) {
      return $true
    }
  }

  return $false
}

function Get-PluginPayloadRelativeFiles([string]$PluginRoot) {
  $files = [System.Collections.Generic.List[string]]::new()
  foreach ($file in @(Get-ChildItem -LiteralPath $PluginRoot -Recurse -File -Force)) {
    $relativeFile = ConvertTo-PluginRelativePath $PluginRoot $file.FullName
    if (-not (Test-GeneratedPluginCacheFile $relativeFile)) {
      [void]$files.Add($relativeFile)
    }
  }

  return @($files | Sort-Object -Unique)
}

function Get-PluginSourceRelativeFiles([string]$SourcePluginRoot) {
  return Get-PluginPayloadRelativeFiles $SourcePluginRoot
}

function Test-PathHasReparsePoint([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return $false
  }

  $item = Get-Item -LiteralPath $Path -Force
  return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Assert-NoReparsePoint([string]$Path, [string]$Label) {
  if (Test-PathHasReparsePoint $Path) {
    throw "$Label is a reparse point and will not be modified by the cutover fallback: $Path"
  }
}

function Assert-NoReparsePointTree([string]$Path, [string]$Label) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }

  Assert-NoReparsePoint $Path $Label
  if (Test-Path -LiteralPath $Path -PathType Container) {
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
      if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "$Label contains a reparse point and will not be modified by the cutover fallback: $($child.FullName)"
      }
    }
  }
}

function Get-PluginInstalledRelativeFiles([string]$InstalledPluginRoot) {
  return Get-PluginPayloadRelativeFiles $InstalledPluginRoot
}

function Compare-InstalledPluginCachePayload([string]$MarketplaceSourceRoot, [string]$InstalledPluginRoot, [string]$PluginName, [string]$SourceRevision) {
  $sourcePluginRoot = Get-PluginSourceRoot $MarketplaceSourceRoot $PluginName
  $sourceVersion = Get-PluginManifestVersion $sourcePluginRoot
  $installedVersion = Split-Path -Leaf (ConvertTo-FullPath $InstalledPluginRoot)
  $versionMatches = [System.StringComparer]::OrdinalIgnoreCase.Equals($sourceVersion, $installedVersion)
  $missingFiles = [System.Collections.Generic.List[string]]::new()
  $changedFiles = [System.Collections.Generic.List[string]]::new()
  $extraFiles = [System.Collections.Generic.List[string]]::new()
  $relativeFiles = @(Get-PluginSourceRelativeFiles $sourcePluginRoot)
  $sourceFileSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($relativeFile in $relativeFiles) {
    [void]$sourceFileSet.Add($relativeFile)
  }

  foreach ($relativeFile in $relativeFiles) {
    $sourcePath = Join-Path $sourcePluginRoot $relativeFile
    $installedPath = Join-Path $InstalledPluginRoot $relativeFile
    if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
      [void]$missingFiles.Add($relativeFile)
      continue
    }

    if ((Get-FileSha256 $sourcePath) -ne (Get-FileSha256 $installedPath)) {
      [void]$changedFiles.Add($relativeFile)
    }
  }

  foreach ($installedRelativeFile in @(Get-PluginInstalledRelativeFiles $InstalledPluginRoot)) {
    if (-not $sourceFileSet.Contains($installedRelativeFile)) {
      [void]$extraFiles.Add($installedRelativeFile)
    }
  }

  $revisionMarker = Join-Path $InstalledPluginRoot ".sympp-source-revision"
  $revisionMarkerValue = Get-RevisionFromTextFile $revisionMarker
  $revisionMarkerMatches = [string]::IsNullOrWhiteSpace($SourceRevision) -or
    [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$revisionMarkerValue, [string]$SourceRevision)
  $matches = $versionMatches -and $missingFiles.Count -eq 0 -and $changedFiles.Count -eq 0 -and $extraFiles.Count -eq 0 -and $revisionMarkerMatches

  return [pscustomobject]@{
    plugin = $PluginName
    sourceRoot = $sourcePluginRoot
    installedRoot = $InstalledPluginRoot
    sourceVersion = $sourceVersion
    installedVersion = $installedVersion
    versionMatches = $versionMatches
    sourceFileCount = $relativeFiles.Count
    matches = $matches
    missingFiles = @($missingFiles)
    changedFiles = @($changedFiles)
    extraFiles = @($extraFiles)
    revisionMarker = $revisionMarker
    revisionMarkerValue = $revisionMarkerValue
    revisionMarkerMatches = $revisionMarkerMatches
  }
}

function Get-InstalledCacheStatus([string]$MarketplaceSourceRoot, [string]$InstalledDefaultPluginRoot, [string]$InstalledMcpPluginRoot, [string]$SourceRevision) {
  $plugins = [System.Collections.Generic.List[object]]::new()
  if (-not [string]::IsNullOrWhiteSpace($InstalledDefaultPluginRoot)) {
    [void]$plugins.Add((Compare-InstalledPluginCachePayload $MarketplaceSourceRoot $InstalledDefaultPluginRoot $MarketplaceName $SourceRevision))
  }
  [void]$plugins.Add((Compare-InstalledPluginCachePayload $MarketplaceSourceRoot $InstalledMcpPluginRoot $McpPluginName $SourceRevision))

  return [pscustomobject]@{
    sourceRevision = $SourceRevision
    refreshNeeded = @($plugins | Where-Object { -not $_.matches }).Count -gt 0
    plugins = $plugins
  }
}

function Write-InstalledCacheStatus([object]$Status) {
  foreach ($plugin in @($Status.plugins)) {
    $state = if ($plugin.matches) { "fresh" } else { "stale" }
    Write-Host "$($plugin.plugin): $state ($($plugin.sourceFileCount) source files checked)"
    if (-not $plugin.matches) {
      if (-not $plugin.versionMatches) {
        Write-Host "  version: installed '$($plugin.installedVersion)' expected '$($plugin.sourceVersion)'"
      }
      if ($plugin.missingFiles.Count -gt 0) {
        Write-Host "  missing: $(@($plugin.missingFiles) -join ', ')"
      }
      if ($plugin.changedFiles.Count -gt 0) {
        Write-Host "  changed: $(@($plugin.changedFiles) -join ', ')"
      }
      if ($plugin.extraFiles.Count -gt 0) {
        Write-Host "  extra: $(@($plugin.extraFiles) -join ', ')"
      }
      if (-not $plugin.revisionMarkerMatches) {
        Write-Host "  source revision marker: '$($plugin.revisionMarkerValue)' expected '$($Status.sourceRevision)'"
      }
    }
  }
}

function Copy-VerifiedPluginPayloadInPlace([object]$PluginStatus, [string]$SourceRevision) {
  if (-not $PluginStatus.versionMatches) {
    throw "Refusing in-place refresh for $($PluginStatus.plugin) because installed cache directory version '$($PluginStatus.installedVersion)' does not match marketplace manifest version '$($PluginStatus.sourceVersion)'. Run a marketplace install/upgrade that can create the correct versioned cache directory."
  }
  if ($PluginStatus.extraFiles.Count -gt 0) {
    throw "Refusing in-place refresh for $($PluginStatus.plugin) because the installed cache contains files that are absent from the marketplace snapshot: $(@($PluginStatus.extraFiles) -join ', ')"
  }

  Assert-NoReparsePointTree $PluginStatus.sourceRoot "Marketplace plugin payload"
  Assert-NoReparsePointTree $PluginStatus.installedRoot "Installed plugin cache payload"
  Assert-NoReparsePoint $PluginStatus.revisionMarker "Installed plugin source revision marker"
  New-Item -ItemType Directory -Path $PluginStatus.installedRoot -Force -ErrorAction Stop | Out-Null
  foreach ($item in @(Get-ChildItem -LiteralPath $PluginStatus.sourceRoot -Force)) {
    Copy-Item -LiteralPath $item.FullName -Destination $PluginStatus.installedRoot -Recurse -Force -ErrorAction Stop
  }

  if (-not [string]::IsNullOrWhiteSpace($SourceRevision)) {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($PluginStatus.revisionMarker, "$SourceRevision`n", $utf8NoBom)
  }
}

function Invoke-InstalledCacheRefreshFallback([object]$CacheStatus, [string]$SourceRevision) {
  foreach ($plugin in @($CacheStatus.plugins | Where-Object { -not $_.matches })) {
    if ($PSCmdlet.ShouldProcess($plugin.installedRoot, "Refresh verified Symphony++ installed plugin cache payload in place from marketplace snapshot")) {
      Copy-VerifiedPluginPayloadInPlace $plugin $SourceRevision
    }
  }
}

function Assert-InstalledCacheFresh([object]$CacheStatus) {
  if (-not $CacheStatus.refreshNeeded) {
    return
  }

  $details = @(
    foreach ($plugin in @($CacheStatus.plugins | Where-Object { -not $_.matches })) {
      $reasons = [System.Collections.Generic.List[string]]::new()
      if (-not $plugin.versionMatches) {
        [void]$reasons.Add("version_mismatch=$($plugin.installedVersion)->$($plugin.sourceVersion)")
      }
      if ($plugin.missingFiles.Count -gt 0) {
        [void]$reasons.Add("missing=$($plugin.missingFiles.Count)")
      }
      if ($plugin.changedFiles.Count -gt 0) {
        [void]$reasons.Add("changed=$($plugin.changedFiles.Count)")
      }
      if ($plugin.extraFiles.Count -gt 0) {
        [void]$reasons.Add("extra=$($plugin.extraFiles.Count)")
      }
      if (-not $plugin.revisionMarkerMatches) {
        [void]$reasons.Add("revision_marker_mismatch")
      }
      "$($plugin.plugin) ($($reasons -join ', '))"
    }
  ) -join "; "

  throw "Installed Symphony++ plugin cache still does not match the verified marketplace snapshot: $details"
}

function Get-CurrentProcessGuardSet {
  $guard = [System.Collections.Generic.HashSet[int]]::new()
  $currentProcessId = [int]$PID
  while ($currentProcessId -gt 0 -and -not $guard.Contains($currentProcessId)) {
    [void]$guard.Add($currentProcessId)
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $currentProcessId" -ErrorAction SilentlyContinue
    if (-not $process -or -not $process.ParentProcessId -or [int]$process.ParentProcessId -eq $currentProcessId) {
      break
    }
    $currentProcessId = [int]$process.ParentProcessId
  }

  return $guard
}

function Get-ProcessCommandLines {
  $guardProcessIds = Get-CurrentProcessGuardSet
  return @(
    Get-CimInstance Win32_Process |
      Where-Object { -not $guardProcessIds.Contains([int]$_.ProcessId) } |
      ForEach-Object {
        [pscustomobject]@{
          ProcessId = [int]$_.ProcessId
          ParentProcessId = [int]$_.ParentProcessId
          Name = [string]$_.Name
          CommandLine = [string]$_.CommandLine
        }
      }
  )
}

function Get-ListeningPorts([int[]]$Ports) {
  return @(
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
      Where-Object { $Ports -contains $_.LocalPort } |
      Sort-Object LocalPort |
      ForEach-Object {
        [pscustomobject]@{
          LocalAddress = [string]$_.LocalAddress
          LocalPort = [int]$_.LocalPort
          OwningProcess = [int]$_.OwningProcess
        }
      }
  )
}

function Test-CommandLineContainsPath([string]$CommandLine, [string]$Path) {
  if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }

  $normalizedCommand = $CommandLine.Replace("/", "\")
  $normalizedPath = (ConvertTo-FullPath $Path).TrimEnd("\").Replace("/", "\")
  return $normalizedCommand.IndexOf($normalizedPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Get-SymppProcessKind($Process, [string]$MarketplaceSourceRoot, [string]$InstalledPluginRoot) {
  $commandLine = [string]$Process.CommandLine
  $name = [string]$Process.Name

  if ([string]::IsNullOrWhiteSpace($commandLine)) {
    return $null
  }

  if ((Test-CommandLineContainsPath $commandLine $InstalledPluginRoot) -and $commandLine -match "start-sympp-mcp") {
    return "installed_launcher"
  }

  if ($commandLine -match "start-sympp-mcp\.(cmd|ps1)") {
    return "launcher_bridge"
  }

  $assetsRoot = Join-Path $MarketplaceSourceRoot "elixir\assets"
  if ((Test-CommandLineContainsPath $commandLine $assetsRoot) -and $commandLine -match "(vite|node_modules)") {
    return "dashboard_vite"
  }

  if ((Test-CommandLineContainsPath $commandLine $MarketplaceSourceRoot) -and $commandLine -match "\b(mix|mise|erl|elixir)\b.*\bsympp\.(cockpit|mcp)\b") {
    return "marketplace_elixir_runtime"
  }

  if ($commandLine -match "\bsympp\.(cockpit|mcp)\b") {
    return "elixir_runtime"
  }

  if (($name -in @("cmd.exe", "pwsh.exe", "powershell.exe", "mise.exe", "erl.exe", "node.exe")) -and
      (Test-CommandLineContainsPath $commandLine $MarketplaceSourceRoot) -and
      ($commandLine -match "(sympp|vite|start-sympp-mcp)")) {
    return "marketplace_runtime_wrapper"
  }

  return $null
}

function Get-CandidateProcesses([string]$MarketplaceSourceRoot, [string]$InstalledPluginRoot, [int[]]$Ports) {
  $processes = Get-ProcessCommandLines
  $listeners = Get-ListeningPorts $Ports
  $processByPid = @{}
  foreach ($process in $processes) {
    $processByPid[$process.ProcessId] = $process
  }

  $listenerByPid = @{}
  foreach ($listener in $listeners) {
    if (-not $listenerByPid.ContainsKey($listener.OwningProcess)) {
      $listenerByPid[$listener.OwningProcess] = [System.Collections.Generic.List[int]]::new()
    }
    [void]$listenerByPid[$listener.OwningProcess].Add($listener.LocalPort)
  }

  $safeProcessByPid = @{}
  $nonSymppListeners = @()
  foreach ($process in $processes) {
    $kind = Get-SymppProcessKind $process $MarketplaceSourceRoot $InstalledPluginRoot
    if ($kind) {
      $safeProcessByPid[$process.ProcessId] = [pscustomobject]@{
        Process = $process
        Kind = $kind
      }
    }
  }

  $candidatePidSet = [System.Collections.Generic.HashSet[int]]::new()
  foreach ($listener in $listeners) {
    if (-not $safeProcessByPid.ContainsKey($listener.OwningProcess)) {
      $process = $processByPid[$listener.OwningProcess]
      $nonSymppListeners += [pscustomobject]@{
        ProcessId = $listener.OwningProcess
        ParentProcessId = if ($process) { $process.ParentProcessId } else { $null }
        Name = if ($process) { $process.Name } else { $null }
        ListeningPorts = "$($listener.LocalPort)"
      }
      continue
    }

    $currentPid = $listener.OwningProcess
    while ($safeProcessByPid.ContainsKey($currentPid)) {
      [void]$candidatePidSet.Add($currentPid)
      $parentPid = $safeProcessByPid[$currentPid].Process.ParentProcessId
      if ($parentPid -eq $currentPid -or -not $safeProcessByPid.ContainsKey($parentPid)) {
        break
      }
      $currentPid = $parentPid
    }
  }

  $candidates = @(
    foreach ($candidateProcessId in $candidatePidSet) {
      $safe = $safeProcessByPid[$candidateProcessId]
      $listeningPorts = @()
      if ($listenerByPid.ContainsKey($candidateProcessId)) {
        $listeningPorts = @($listenerByPid[$candidateProcessId] | Sort-Object -Unique)
      }

      [pscustomobject]@{
        ProcessId = $safe.Process.ProcessId
        ParentProcessId = $safe.Process.ParentProcessId
        Name = $safe.Process.Name
        Kind = $safe.Kind
        ListeningPorts = ($listeningPorts -join ",")
        CommandLine = $safe.Process.CommandLine
      }
    }
  )

  return [pscustomobject]@{
    Candidates = @($candidates | Sort-Object ProcessId)
    NonSymppListeners = @($nonSymppListeners | Sort-Object ProcessId)
    Listeners = $listeners
  }
}

function Write-ProcessTable([object[]]$Rows, [string]$EmptyMessage) {
  if ($Rows.Count -eq 0) {
    Write-Host $EmptyMessage
    return
  }

  $Rows |
    Select-Object ProcessId, ParentProcessId, Name, Kind, ListeningPorts, CommandLine |
    Format-Table -AutoSize -Wrap
}

function Get-ProcessByPidFromInventory([int]$ProcessId) {
  return Get-ProcessCommandLines | Where-Object { $_.ProcessId -eq $ProcessId } | Select-Object -First 1
}

function Wait-ListeningPort([int]$Port, [int]$TimeoutSeconds) {
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($listener) {
      return [int]$listener.OwningProcess
    }
    Start-Sleep -Milliseconds 500
  } while ([DateTimeOffset]::UtcNow -lt $deadline)

  throw "Timed out waiting for port $Port to listen."
}

function Assert-ListenerKind([int]$ProcessId, [string[]]$ExpectedKinds, [string]$Label, [string]$MarketplaceSourceRoot, [string]$InstalledPluginRoot) {
  $process = Get-ProcessByPidFromInventory $ProcessId
  if (-not $process) {
    throw "$Label listener PID $ProcessId was not found in the process table."
  }

  $kind = Get-SymppProcessKind $process $MarketplaceSourceRoot $InstalledPluginRoot
  if ($ExpectedKinds -notcontains $kind) {
    throw "$Label listener PID $ProcessId ($($process.Name)) did not match the expected S++ runtime kind. Expected $($ExpectedKinds -join ', '), got '$kind'."
  }
}

function Invoke-ElixirSetup([string]$MarketplaceSourceRoot) {
  $elixirDir = Require-Directory (Join-Path $MarketplaceSourceRoot "elixir") "Marketplace Elixir directory"
  $mise = Get-Command mise -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $mise) {
    throw "mise was not found on PATH; cannot prepare the installed marketplace Elixir runtime."
  }

  Invoke-CheckedCommand $mise.Source @("exec", "--", "mix", "deps.get", "--check-locked") $elixirDir "mix deps.get --check-locked" | Out-Null
  Invoke-CheckedCommand $mise.Source @("exec", "--", "mix", "compile") $elixirDir "mix compile" | Out-Null
}

function Start-Backend([string]$MarketplaceSourceRoot, [string]$SourceRevision, [int]$BackendPort, [int]$DashboardPort, [string]$LogDir) {
  $elixirDir = Require-Directory (Join-Path $MarketplaceSourceRoot "elixir") "Marketplace Elixir directory"
  $mise = Get-Command mise -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $mise) {
    throw "mise was not found on PATH; cannot start mix sympp.cockpit from the installed marketplace cache."
  }

  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $stdout = Join-Path $LogDir "cutover-backend-$BackendPort-$stamp.out.log"
  $stderr = Join-Path $LogDir "cutover-backend-$BackendPort-$stamp.err.log"

  $previousSourceRevision = $env:SYMPP_SOURCE_REVISION
  try {
    $env:SYMPP_SOURCE_REVISION = $SourceRevision
    $process = Start-Process -FilePath $mise.Source `
      -ArgumentList @("exec", "--", "mix", "sympp.cockpit", "--host", "127.0.0.1", "--port", "$BackendPort", "--dashboard-origin", "http://127.0.0.1:$DashboardPort") `
      -WorkingDirectory $elixirDir `
      -RedirectStandardOutput $stdout `
      -RedirectStandardError $stderr `
      -WindowStyle Hidden `
      -PassThru
  } finally {
    $env:SYMPP_SOURCE_REVISION = $previousSourceRevision
  }

  return [pscustomobject]@{
    ProcessId = $process.Id
    StdoutLog = $stdout
    StderrLog = $stderr
  }
}

function Ensure-NodeModules([string]$AssetsDir) {
  $vite = Join-Path $AssetsDir "node_modules\.bin\vite.cmd"
  if (Test-Path -LiteralPath $vite -PathType Leaf) {
    return $vite
  }

  $npm = Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $npm) {
    throw "Vite launcher was missing and npm was not found on PATH: $vite"
  }

  $result = Invoke-CheckedCommand $npm.Source @("install") $AssetsDir "npm install"
  return Require-File $vite "Vite launcher after npm install"
}

function Start-Dashboard([string]$MarketplaceSourceRoot, [int]$BackendPort, [int]$DashboardPort, [string]$LogDir) {
  $assetsDir = Require-Directory (Join-Path $MarketplaceSourceRoot "elixir\assets") "Marketplace dashboard assets directory"
  $vite = Ensure-NodeModules $assetsDir

  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $stdout = Join-Path $LogDir "cutover-dashboard-$DashboardPort-$stamp.out.log"
  $stderr = Join-Path $LogDir "cutover-dashboard-$DashboardPort-$stamp.err.log"
  $command = "`"$vite`" --host 127.0.0.1 --port $DashboardPort --strictPort"

  $previousApiOrigin = $env:SYMPP_API_ORIGIN
  try {
    $env:SYMPP_API_ORIGIN = "http://127.0.0.1:$BackendPort"
    $process = Start-Process -FilePath "cmd.exe" `
      -ArgumentList @("/c", $command) `
      -WorkingDirectory $assetsDir `
      -RedirectStandardOutput $stdout `
      -RedirectStandardError $stderr `
      -WindowStyle Hidden `
      -PassThru
  } finally {
    $env:SYMPP_API_ORIGIN = $previousApiOrigin
  }

  return [pscustomobject]@{
    ProcessId = $process.Id
    StdoutLog = $stdout
    StderrLog = $stderr
  }
}

function Normalize-McpContractFingerprint([string]$Fingerprint) {
  if ([string]::IsNullOrWhiteSpace($Fingerprint)) {
    return $null
  }

  $normalized = $Fingerprint.Trim().ToLowerInvariant()
  if ($normalized -match "^[0-9a-f]{64}$") {
    return $normalized
  }

  return $null
}

function Get-CutoverJsonPathValue($Object, [string[]]$Path) {
  $current = $Object
  foreach ($part in $Path) {
    if ($null -eq $current -or -not $current.PSObject.Properties[$part]) {
      return $null
    }
    $current = $current.PSObject.Properties[$part].Value
  }

  return $current
}

function Get-CutoverJsonFirstPathValue($Object, [object[]]$Paths) {
  foreach ($path in $Paths) {
    $value = Get-CutoverJsonPathValue $Object ([string[]]$path)
    if ($null -ne $value) {
      return $value
    }
  }

  return $null
}

function Get-McpContractFingerprintFromContractFile([string]$ContractPath) {
  if ([string]::IsNullOrWhiteSpace($ContractPath) -or -not (Test-Path -LiteralPath $ContractPath -PathType Leaf)) {
    return $null
  }

  $contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
  return Normalize-McpContractFingerprint ([string]$contract.mcp_contract_fingerprint)
}

function Get-McpContractFingerprintFromManifestObject($Manifest) {
  $fingerprints = New-Object System.Collections.Generic.List[string]
  $manifestFingerprint = Normalize-McpContractFingerprint ([string](Get-CutoverJsonFirstPathValue $Manifest @(
        @("mcp_contract_fingerprint"),
        @("launcher_contract", "mcp_contract_fingerprint"),
        @("contract_fingerprint"),
        @("launcher_contract", "contract_fingerprint")
      )))
  if ($manifestFingerprint) {
    $fingerprints.Add($manifestFingerprint)
  }

  foreach ($artifact in @((Get-CutoverJsonFirstPathValue $Manifest @(@("artifacts"), @("runtime_artifacts"))))) {
    $artifactFingerprint = Normalize-McpContractFingerprint ([string](Get-CutoverJsonFirstPathValue $artifact @(
          @("mcp_contract_fingerprint"),
          @("launcher_contract", "mcp_contract_fingerprint"),
          @("runtime", "mcp_contract_fingerprint"),
          @("contract_fingerprint"),
          @("launcher_contract", "contract_fingerprint"),
          @("runtime", "contract_fingerprint")
        )))
    if ($artifactFingerprint) {
      $fingerprints.Add($artifactFingerprint)
    }
  }

  $unique = @($fingerprints | Sort-Object -Unique)
  if ($unique.Count -eq 1) {
    return $unique[0]
  }

  return $null
}

function Get-McpContractFingerprintFromArtifactManifest([string]$InstalledPluginRoot) {
  $manifestPath = @(
    Join-Path $InstalledPluginRoot ".sympp-runtime-artifacts.json"
    Join-Path $InstalledPluginRoot "assets\sympp-runtime-artifacts.json"
  ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

  if (-not $manifestPath) {
    return $null
  }

  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $fingerprint = Get-McpContractFingerprintFromManifestObject $manifest
  if ($fingerprint) {
    return $fingerprint
  }

  return "0000000000000000000000000000000000000000000000000000000000000000"
}

function Resolve-CutoverMcpContractFingerprint([string]$InstalledPluginRoot, [string]$MarketplaceSourceRoot) {
  if (-not [string]::IsNullOrWhiteSpace($MarketplaceSourceRoot)) {
    $fingerprint = Get-McpContractFingerprintFromContractFile (Join-Path $MarketplaceSourceRoot "implementation_docs_symphplusplus/mcp/mcp_tools_contract.json")
    if ($fingerprint) {
      return $fingerprint
    }
  }

  return Get-McpContractFingerprintFromArtifactManifest $InstalledPluginRoot
}

function Get-RuntimeStateContractFingerprint($State, [string]$FallbackFingerprint) {
  $installedFingerprint = Normalize-McpContractFingerprint $FallbackFingerprint
  if ($installedFingerprint) {
    return $installedFingerprint
  }

  if ($null -ne $State.backend) {
    if ($State.backend.PSObject.Properties["contract_fingerprint"]) {
      $fingerprint = Normalize-McpContractFingerprint ([string]$State.backend.contract_fingerprint)
      if ($fingerprint) {
        return $fingerprint
      }
    }
    if ($State.backend.PSObject.Properties["expected_contract_fingerprint"]) {
      $fingerprint = Normalize-McpContractFingerprint ([string]$State.backend.expected_contract_fingerprint)
      if ($fingerprint) {
        return $fingerprint
      }
    }
  }

  return Normalize-McpContractFingerprint $FallbackFingerprint
}

function New-RuntimeKey([string]$BackendUrl, [string]$DashboardOrigin, [string]$ContractFingerprint) {
  $backend = if ([string]::IsNullOrWhiteSpace($BackendUrl)) { "none" } else { $BackendUrl.TrimEnd("/").ToLowerInvariant() }
  $dashboard = if ([string]::IsNullOrWhiteSpace($DashboardOrigin)) { "none" } else { $DashboardOrigin.TrimEnd("/").ToLowerInvariant() }
  $contract = if ([string]::IsNullOrWhiteSpace($ContractFingerprint)) { "unknown" } else { $ContractFingerprint.Trim().ToLowerInvariant() }
  return "contract=$contract;backend=$backend;dashboard=$dashboard"
}

function Update-RuntimeStatePids([string]$RuntimeFile, [string]$InstalledPluginRoot, [int]$BackendPid, [int]$DashboardPid, [string]$SourceRevision, [int]$BackendPort, [int]$DashboardPort, [string]$ExpectedContractFingerprint) {
  $runtimeFilePath = ConvertTo-FullPath $RuntimeFile
  $state = if (Test-Path -LiteralPath $runtimeFilePath -PathType Leaf) {
    Get-Content -LiteralPath $runtimeFilePath -Raw | ConvertFrom-Json
  } else {
    [pscustomobject]@{
      generated_at = $null
      runtime_kind = $null
      runtime_key = $null
      runtime_mode = "source"
      plugin_root = $InstalledPluginRoot
      backend = [pscustomobject]@{
        pid = $null; port = $null; url = $null; mcp_url = $null; status = $null
        reused = $null; managed = $null; expected_source_revision = $null; source_revision = $null
        expected_contract_fingerprint = $null; contract_fingerprint = $null
      }
      frontend = [pscustomobject]@{
        pid = $null; port = $null; origin = $null; url = $null; status = $null; reused = $null; managed = $null
      }
      superseded_runtimes = @()
    }
  }
  $backendUrl = "http://127.0.0.1:$BackendPort"
  $dashboardOrigin = "http://127.0.0.1:$DashboardPort"
  $contractFingerprint = Get-RuntimeStateContractFingerprint $state $ExpectedContractFingerprint
  $state.generated_at = (Get-Date).ToString("o")
  $state.plugin_root = $InstalledPluginRoot
  $state.runtime_kind = "external_loopback"
  $state.runtime_key = New-RuntimeKey $backendUrl $dashboardOrigin $contractFingerprint
  $state.backend.pid = $BackendPid
  $state.backend.port = $BackendPort
  $state.backend.url = $backendUrl
  $state.backend.mcp_url = "$backendUrl/mcp"
  $state.backend.status = "external_loopback"
  $state.backend.reused = $true
  $state.backend.managed = $false
  $state.backend.expected_source_revision = $SourceRevision
  $state.backend.source_revision = $SourceRevision
  if ($contractFingerprint) {
    $state.backend.expected_contract_fingerprint = $contractFingerprint
    $state.backend.contract_fingerprint = $contractFingerprint
  }
  $state.frontend.pid = $DashboardPid
  $state.frontend.port = $DashboardPort
  $state.frontend.origin = $dashboardOrigin
  $state.frontend.url = "$dashboardOrigin/sympp/board"
  $state.frontend.status = "external_loopback"
  $state.frontend.reused = $true
  $state.frontend.managed = $false
  if ($null -eq $state.superseded_runtimes) {
    $state.superseded_runtimes = @()
  }

  New-Item -ItemType Directory -Path (Split-Path -Parent $runtimeFilePath) -Force | Out-Null
  $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $runtimeFilePath -Encoding UTF8
  return $state
}

function Invoke-McpSmoke([string]$RepoRoot, [string]$SourceRevision, [int]$BackendPort) {
  $smokeScript = Require-File (Join-Path $PSScriptRoot "smoke-sympp-mcp-http.ps1") "MCP HTTP smoke script"
  $result = Invoke-CheckedCommand "powershell" @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $smokeScript,
    "-Url",
    "http://127.0.0.1:$BackendPort/mcp",
    "-RepoRoot",
    $RepoRoot,
    "-ExpectedSourceRevision",
    $SourceRevision,
    "-Json"
  ) $RepoRoot "smoke-sympp-mcp-http.ps1"

  return $result.Stdout
}

function Invoke-DashboardSmoke([int]$DashboardPort) {
  $url = "http://127.0.0.1:$DashboardPort/sympp/board"
  $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 15
  return [pscustomobject]@{
    Url = $url
    StatusCode = [int]$response.StatusCode
    Length = [int]$response.Content.Length
    HasRoot = ($response.Content -match '<div id="root"')
  }
}

$codexHomePath = Require-Directory $CodexHome "Codex home"
$symppHomePath = ConvertTo-FullPath $SymppHome
$logDir = Join-Path $symppHomePath "logs"
$runtimeFile = Join-Path $symppHomePath "runtime\codex-plugin.json"
$marketplaceSourceRoot = Require-Directory (Join-Path $codexHomePath ".tmp\marketplaces\$MarketplaceName") "Installed marketplace source root"
$cacheRoot = Require-Directory (Join-Path $codexHomePath "plugins\cache\$MarketplaceName") "Installed plugin cache root"
$installedDefaultPluginRoot = Resolve-InstalledDefaultPluginRoot $cacheRoot
$installedPluginRoot = Resolve-InstalledMcpPluginRoot $cacheRoot
$allPorts = @($BackendPort, $DashboardPort) + @(20000..20120)
$sourceRevision = Normalize-ExpectedSourceRevision $ExpectedSourceRevision
$marketplaceUpgradeAlreadyRun = $false
$marketplaceUpgradeFailure = $null

if (-not $script:SymppCutoverDryRun) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

Write-Section "Installed Symphony++ MCP Cutover"
if (-not $Json) {
  Write-Host "Codex home: $codexHomePath"
  Write-Host "Marketplace source: $marketplaceSourceRoot"
  Write-Host "Installed default plugin: $installedDefaultPluginRoot"
  Write-Host "Installed MCP plugin: $installedPluginRoot"
  Write-Host "Runtime file: $runtimeFile"
}

if (-not $script:SymppCutoverDryRun -and -not $SkipMarketplaceUpgrade -and -not [string]::IsNullOrWhiteSpace($sourceRevision)) {
  $currentMarketplaceRevision = Resolve-MarketplaceSourceRevision $marketplaceSourceRoot
  if ($currentMarketplaceRevision -ne $sourceRevision) {
    Write-Section "Marketplace Upgrade Preflight"
    $preflightUpgradeFailed = $false
    try {
      if ($PSCmdlet.ShouldProcess("Codex marketplace $MarketplaceName", "Run codex plugin marketplace upgrade")) {
        $preflightUpgrade = Invoke-MarketplaceUpgrade $codexHomePath
        $marketplaceUpgradeAlreadyRun = $true
        if (-not $Json -and -not [string]::IsNullOrWhiteSpace($preflightUpgrade.Stdout)) {
          Write-Host $preflightUpgrade.Stdout.Trim()
        }
      }
    } catch {
      $preflightUpgradeFailed = $true
      if (-not $Json) {
        Write-Host "Marketplace upgrade failed; the installed-cache fallback will be evaluated."
        Write-Host $_.Exception.Message
      }
    }

    $marketplaceSourceRoot = Require-Directory (Join-Path $codexHomePath ".tmp\marketplaces\$MarketplaceName") "Installed marketplace source root"
    $cacheRoot = Require-Directory (Join-Path $codexHomePath "plugins\cache\$MarketplaceName") "Installed plugin cache root"
    $installedDefaultPluginRoot = Resolve-InstalledDefaultPluginRoot $cacheRoot
    $installedPluginRoot = Resolve-InstalledMcpPluginRoot $cacheRoot
    $currentMarketplaceRevision = Resolve-MarketplaceSourceRevision $marketplaceSourceRoot
    if ($currentMarketplaceRevision -ne $sourceRevision -and -not $preflightUpgradeFailed) {
      throw "Marketplace source revision mismatch. Expected $sourceRevision but $marketplaceSourceRoot is at $currentMarketplaceRevision."
    }
  }
}

$cacheStatusRevision = if ([string]::IsNullOrWhiteSpace($sourceRevision)) {
  if ($script:SymppCutoverDryRun) { $null } else { Resolve-MarketplaceSourceRevision $marketplaceSourceRoot }
} else {
  $sourceRevision
}
$initialCacheStatus = Get-InstalledCacheStatus $marketplaceSourceRoot $installedDefaultPluginRoot $installedPluginRoot $cacheStatusRevision

Write-Section "Installed Cache Status"
if (-not $Json) {
  Write-InstalledCacheStatus $initialCacheStatus
}

$initialInventory = Get-CandidateProcesses $marketplaceSourceRoot $installedPluginRoot $allPorts
Write-Section "Existing S++ Processes (Preserved)"
if (-not $Json) {
  Write-ProcessTable $initialInventory.Candidates "No verified S++ launcher/runtime processes are currently running."
  if ($initialInventory.NonSymppListeners.Count -gt 0) {
    Write-Host ""
    Write-Host "Non-S++ listeners on checked ports are preserved:"
    $initialInventory.NonSymppListeners |
      Select-Object ProcessId, ParentProcessId, Name, ListeningPorts |
      Format-Table -AutoSize -Wrap
  }
}

if ($script:SymppCutoverDryRun) {
  $summary = [pscustomobject]@{
    status = "what_if"
    message = "Dry run completed. No processes were stopped, no cache was upgraded, and no singleton was started."
    candidates = $initialInventory.Candidates
    nonSymppListeners = $initialInventory.NonSymppListeners
    installedCache = $initialCacheStatus
    marketplaceSourceRoot = $marketplaceSourceRoot
    installedDefaultPluginRoot = $installedDefaultPluginRoot
    installedPluginRoot = $installedPluginRoot
    runtimeFile = $runtimeFile
  }
  if ($Json) {
    $summary | ConvertTo-Json -Depth 20
  } else {
    Write-Host ""
    Write-Host $summary.message
  }
  exit 0
}

if (-not $SkipMarketplaceUpgrade -and -not $marketplaceUpgradeAlreadyRun) {
  Write-Section "Marketplace Upgrade"
  if ($PSCmdlet.ShouldProcess("Codex marketplace $MarketplaceName", "Run codex plugin marketplace upgrade")) {
    try {
      $upgrade = Invoke-MarketplaceUpgrade $codexHomePath
      if (-not $Json -and -not [string]::IsNullOrWhiteSpace($upgrade.Stdout)) {
        Write-Host $upgrade.Stdout.Trim()
      }
    } catch {
      $marketplaceUpgradeFailure = $_.Exception.Message
      if ([string]::IsNullOrWhiteSpace($sourceRevision)) {
        throw "Marketplace upgrade failed and -ExpectedSourceRevision was not supplied. The installed-cache fallback only runs when the helper can prove the marketplace snapshot is at the intended revision. Rerun with -ExpectedSourceRevision <git-sha>, use -SkipMarketplaceUpgrade when the cache is intentionally pre-refreshed, or fix the marketplace upgrade failure.`n$marketplaceUpgradeFailure"
      }
      if (-not $Json) {
        Write-Host "Marketplace upgrade failed; evaluating installed-cache fallback."
        Write-Host $marketplaceUpgradeFailure
      }
    }
  }

  $marketplaceSourceRoot = Require-Directory (Join-Path $codexHomePath ".tmp\marketplaces\$MarketplaceName") "Installed marketplace source root"
  $cacheRoot = Require-Directory (Join-Path $codexHomePath "plugins\cache\$MarketplaceName") "Installed plugin cache root"
  $installedDefaultPluginRoot = Resolve-InstalledDefaultPluginRoot $cacheRoot
  $installedPluginRoot = Resolve-InstalledMcpPluginRoot $cacheRoot
}

$sourceRevision = if ([string]::IsNullOrWhiteSpace($sourceRevision)) {
  Resolve-MarketplaceSourceRevision $marketplaceSourceRoot
} else {
  $sourceRevision
}

$actualMarketplaceRevision = Resolve-MarketplaceSourceRevision $marketplaceSourceRoot
if ($actualMarketplaceRevision -ne $sourceRevision) {
  $upgradeDetail = if ($marketplaceUpgradeFailure) { " Marketplace upgrade failure: $marketplaceUpgradeFailure" } else { "" }
  throw "Marketplace source revision mismatch. Expected $sourceRevision but $marketplaceSourceRoot is at $actualMarketplaceRevision.$upgradeDetail"
}

$cacheStatus = Get-InstalledCacheStatus $marketplaceSourceRoot $installedDefaultPluginRoot $installedPluginRoot $sourceRevision
if ($cacheStatus.refreshNeeded) {
  Write-Section "Installed Cache Refresh Fallback"
  if (-not $Json) {
    if ($marketplaceUpgradeFailure) {
      Write-Host "Using fallback because marketplace upgrade failed but the marketplace source snapshot is at the expected revision."
    } else {
      Write-Host "Using fallback because the installed Symphony++ plugin cache does not match the verified marketplace snapshot."
    }
    Write-InstalledCacheStatus $cacheStatus
  }

  Invoke-InstalledCacheRefreshFallback $cacheStatus $sourceRevision
  $installedDefaultPluginRoot = Resolve-InstalledDefaultPluginRoot $cacheRoot
  $installedPluginRoot = Resolve-InstalledMcpPluginRoot $cacheRoot
  $cacheStatus = Get-InstalledCacheStatus $marketplaceSourceRoot $installedDefaultPluginRoot $installedPluginRoot $sourceRevision
  Assert-InstalledCacheFresh $cacheStatus
  if (-not $Json) {
    Write-Host "Installed Symphony++ plugin cache refreshed in place and verified."
  }
} elseif ($marketplaceUpgradeFailure) {
  if (-not $Json) {
    Write-Host "Marketplace upgrade failed, but the installed Symphony++ plugin cache already matches the verified marketplace snapshot."
  }
}

Write-Section "Installed Direct HTTP Validation"
$installedMcpUrl = Assert-InstalledDirectMcpConfig $installedPluginRoot $BackendPort
if (-not $Json) {
  Write-Host "MCP URL: $installedMcpUrl"
}

Write-Section "Installed Runtime Setup"
Invoke-ElixirSetup $marketplaceSourceRoot
if (-not $Json) {
  Write-Host "Elixir dependencies and compiled runtime are ready."
}

Write-Section "Start Singleton"
$backendStart = $null
$dashboardStart = $null
$backendListeners = @(Get-ListeningPorts @($BackendPort))
if ($backendListeners.Count -gt 1) {
  throw "Multiple listeners were found on the configured backend port $BackendPort."
}
if ($backendListeners.Count -eq 0 -and $PSCmdlet.ShouldProcess("127.0.0.1:$BackendPort", "Start Symphony++ backend singleton from installed marketplace cache")) {
  $backendStart = Start-Backend $marketplaceSourceRoot $sourceRevision $BackendPort $DashboardPort $logDir
}
$dashboardListeners = @(Get-ListeningPorts @($DashboardPort))
if ($dashboardListeners.Count -gt 1) {
  throw "Multiple listeners were found on the configured dashboard port $DashboardPort."
}
if ($dashboardListeners.Count -eq 0 -and $PSCmdlet.ShouldProcess("127.0.0.1:$DashboardPort", "Start Symphony++ dashboard from installed marketplace cache")) {
  $dashboardStart = Start-Dashboard $marketplaceSourceRoot $BackendPort $DashboardPort $logDir
}

$backendPid = Wait-ListeningPort $BackendPort 60
$dashboardPid = Wait-ListeningPort $DashboardPort 60
$backendKinds = if ($backendStart) {
  @("elixir_runtime", "marketplace_elixir_runtime", "marketplace_runtime_wrapper")
} else {
  @("marketplace_elixir_runtime", "marketplace_runtime_wrapper")
}
Assert-ListenerKind $backendPid $backendKinds "Backend" $marketplaceSourceRoot $installedPluginRoot
Assert-ListenerKind $dashboardPid @("dashboard_vite", "marketplace_runtime_wrapper") "Dashboard" $marketplaceSourceRoot $installedPluginRoot

if (-not $Json) {
  Write-Host "Backend listener: PID $backendPid on 127.0.0.1:$BackendPort"
  Write-Host "Dashboard listener: PID $dashboardPid on 127.0.0.1:$DashboardPort"
}

Write-Section "Refresh Runtime State"
$expectedContractFingerprint = Resolve-CutoverMcpContractFingerprint $installedPluginRoot $marketplaceSourceRoot
$smokeJson = Invoke-McpSmoke $marketplaceSourceRoot $sourceRevision $BackendPort
$runtimeState = Update-RuntimeStatePids $runtimeFile $installedPluginRoot $backendPid $dashboardPid $sourceRevision $BackendPort $DashboardPort $expectedContractFingerprint
if (-not $Json) {
  Write-Host "Runtime key: $($runtimeState.runtime_key)"
  Write-Host "Runtime kind: $($runtimeState.runtime_kind)"
  if ($runtimeState.backend.PSObject.Properties["contract_fingerprint"]) {
    Write-Host "MCP contract: $($runtimeState.backend.contract_fingerprint)"
  }
}

Write-Section "Verification"
$finalInventory = Get-CandidateProcesses $marketplaceSourceRoot $installedPluginRoot $allPorts
$dynamicListeners = @(
  $finalInventory.Candidates |
    Where-Object {
      @([string]$_.ListeningPorts -split "," |
        Where-Object {
          $_ -match "^\d+$" -and [int]$_ -ge 20000 -and [int]$_ -le 20120
        }).Count -gt 0
    }
)
if ($dynamicListeners.Count -gt 0) {
  $dynamicSummary = @($dynamicListeners | ForEach-Object { "pid:$($_.ProcessId)/ports:$($_.ListeningPorts)" }) -join ", "
  throw "Unexpected dynamic S++ leak/listener ports remain in 20000-20120: $dynamicSummary"
}

$dashboardSmoke = Invoke-DashboardSmoke $DashboardPort
if (-not $dashboardSmoke.HasRoot) {
  throw "Dashboard route returned HTTP $($dashboardSmoke.StatusCode) but did not include the Vite root element."
}

if (-not $Json) {
  Write-Host "Dynamic ports 20000-20120: none"
  Write-Host "MCP smoke: passed"
  Write-Host "Dashboard smoke: HTTP $($dashboardSmoke.StatusCode), length $($dashboardSmoke.Length)"
  Write-Host ""
  Write-Host "Left-running S++ listener PIDs:"
  $finalInventory.Listeners |
    Where-Object { $_.LocalPort -in @($BackendPort, $DashboardPort) } |
    ForEach-Object {
      $process = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
      [pscustomobject]@{
        Port = $_.LocalPort
        ProcessId = $_.OwningProcess
        ProcessName = if ($process) { $process.ProcessName } else { $null }
        Path = if ($process) { $process.Path } else { $null }
      }
    } |
    Format-Table -AutoSize
}

$summary = [pscustomobject]@{
  status = "ok"
  message = "Installed Symphony++ direct HTTP cutover completed."
  sourceRevision = $sourceRevision
  mcpContractFingerprint = if ($runtimeState.backend.PSObject.Properties["contract_fingerprint"]) { $runtimeState.backend.contract_fingerprint } else { $null }
  marketplaceSourceRoot = $marketplaceSourceRoot
  installedDefaultPluginRoot = $installedDefaultPluginRoot
  installedPluginRoot = $installedPluginRoot
  installedCache = $cacheStatus
  marketplaceUpgradeFailure = $marketplaceUpgradeFailure
  runtimeFile = $runtimeFile
  backend = @{
    port = $BackendPort
    pid = $backendPid
    startedProcessId = if ($backendStart) { $backendStart.ProcessId } else { $null }
    stdoutLog = if ($backendStart) { $backendStart.StdoutLog } else { $null }
    stderrLog = if ($backendStart) { $backendStart.StderrLog } else { $null }
  }
  dashboard = @{
    port = $DashboardPort
    pid = $dashboardPid
    startedProcessId = if ($dashboardStart) { $dashboardStart.ProcessId } else { $null }
    stdoutLog = if ($dashboardStart) { $dashboardStart.StdoutLog } else { $null }
    stderrLog = if ($dashboardStart) { $dashboardStart.StderrLog } else { $null }
    route = $dashboardSmoke
  }
  stoppedPids = @()
  stillRunningStoppedCandidates = @()
  dynamicLeakPorts = @($dynamicListeners)
  mcpSmoke = $smokeJson | ConvertFrom-Json
}

if ($Json) {
  $summary | ConvertTo-Json -Depth 20
} else {
  Write-Host "Cutover complete."
  Write-Host "Stopped PIDs: none (active sessions are preserved)"
  Write-Host "Left running: backend PID $backendPid, dashboard PID $dashboardPid"
}
