param(
  [string]$MarketplacePath,
  [string]$MarketplaceName,
  [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "$HOME/.codex" }),
  [string]$PluginName = "all",
  [switch]$ValidateInstalledCache,
  [switch]$AllowDefaultCodexHomeRefresh
)

$ErrorActionPreference = "Stop"
$SymppPluginPackageNames = @("symphony-plus-plus", "symphony-plus-plus-mcp")

function Quote-PowerShellLiteral([string]$Value) {
  return "'" + ($Value -replace "'", "''") + "'"
}

function Get-AvailablePowerShellCommandName {
  foreach ($candidate in @("pwsh", "powershell.exe", "powershell")) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) {
      return $candidate
    }
  }

  return "powershell"
}

function Test-RefreshWindowsPlatform {
  return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
}

function Resolve-StrictPath([string]$Path) {
  return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
}

function Resolve-FullPathLenient([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path)
}

function Get-DefaultCodexHomePath {
  return Resolve-FullPathLenient (Join-Path $HOME ".codex")
}

function Test-SamePath([string]$Left, [string]$Right) {
  $leftFull = Resolve-FullPathLenient $Left
  $rightFull = Resolve-FullPathLenient $Right
  return $leftFull.TrimEnd("\", "/").Equals($rightFull.TrimEnd("\", "/"), [System.StringComparison]::OrdinalIgnoreCase)
}

function Normalize-SourceRevision([string]$Revision) {
  if ([string]::IsNullOrWhiteSpace($Revision)) {
    return $null
  }

  $normalized = $Revision.Trim().ToLowerInvariant()
  if ($normalized -match "^[0-9a-f]{40}$") {
    return $normalized
  }

  return $null
}

function Get-RepoHeadRevision([string]$RepoRoot) {
  $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $git) {
    return $null
  }

  try {
    $output = @(& $git.Source @("-C", $RepoRoot, "rev-parse", "--verify", "HEAD") 2>$null)
    if ($LASTEXITCODE -eq 0 -and $output.Count -gt 0) {
      return Normalize-SourceRevision ([string]$output[0])
    }
  } catch {
  }

  return $null
}

function Resolve-ConfiguredSourcePath([string]$SourcePath, [string]$MarketplaceFile, [string]$RepoRoot) {
  if ([System.IO.Path]::IsPathRooted($SourcePath)) {
    $rootedPath = [System.IO.Path]::GetFullPath($SourcePath)
    if (Test-Path -LiteralPath $rootedPath) {
      return $rootedPath
    }

    throw "Configured plugin source path does not exist: $rootedPath"
  }

  $repoRelative = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $SourcePath))
  if (Test-Path -LiteralPath $repoRelative) {
    return $repoRelative
  }

  $marketplaceRelative = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MarketplaceFile) $SourcePath))
  if (Test-Path -LiteralPath $marketplaceRelative) {
    return $marketplaceRelative
  }

  throw "Configured plugin source path '$SourcePath' was not found relative to repo root '$RepoRoot' or marketplace file '$MarketplaceFile'."
}

function Join-And-Normalize([string]$Base, [string[]]$Parts) {
  return [System.IO.Path]::GetFullPath((Join-Path -Path $Base -ChildPath ([System.IO.Path]::Combine($Parts))))
}

function Assert-PathInside([string]$Child, [string]$Parent, [string]$Message) {
  $parentWithSeparator = $Parent.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $Child.StartsWith($parentWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "$Message`: $Child"
  }
}

function Assert-SafeCacheTarget([string]$Target, [string]$PluginCacheRoot) {
  Assert-PathInside $Target $PluginCacheRoot "Resolved target cache path is outside this plugin cache"
}

function Assert-NotReparsePoint([string]$Target) {
  if (-not (Test-Path -LiteralPath $Target)) {
    return
  }

  $item = Get-Item -LiteralPath $Target -Force
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to refresh reparse-point plugin cache directory. Remove the link manually and rerun refresh: $Target"
  }
}

function Assert-NoReparsePointDescendants([string]$Target) {
  if (-not (Test-Path -LiteralPath $Target)) {
    return
  }

  $item = Get-Item -LiteralPath $Target -Force
  if (-not $item.PSIsContainer) {
    return
  }

  $reparsePoint = Get-ChildItem -LiteralPath $Target -Force -Recurse -ErrorAction Stop |
    Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
    Select-Object -First 1
  if ($null -ne $reparsePoint) {
    throw "Refusing to refresh plugin cache directory containing a reparse-point child. Remove the link manually and rerun refresh: $($reparsePoint.FullName)"
  }
}

function Assert-ExistingCachePathNotReparsePoint([string[]]$Paths) {
  foreach ($path in $Paths) {
    Assert-NotReparsePoint $path
  }
}

function Remove-ManagedCachePath([string]$Target, [string]$TargetRoot, [string]$Reason) {
  $resolvedTarget = [System.IO.Path]::GetFullPath($Target)
  $resolvedRoot = [System.IO.Path]::GetFullPath($TargetRoot)
  Assert-PathInside $resolvedTarget $resolvedRoot "Managed cache path resolves outside target root"
  if (-not (Test-Path -LiteralPath $resolvedTarget)) {
    return
  }

  Assert-NotReparsePoint $resolvedTarget
  Assert-NoReparsePointDescendants $resolvedTarget
  Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
  Write-Host "$Reason`: $resolvedTarget"
}

. (Join-Path $PSScriptRoot "refresh-local-plugin-snapshot.ps1")

function Sync-ManagedDirectoryChildren([string]$Source, [string]$Target, [string]$TargetRoot) {
  if (-not (Test-Path -LiteralPath $Source -PathType Container) -or -not (Test-Path -LiteralPath $Target -PathType Container)) {
    return
  }

  foreach ($targetChild in @(Get-ChildItem -LiteralPath $Target -Force)) {
    $sourceChild = Join-Path $Source $targetChild.Name
    if (Test-Path -LiteralPath $sourceChild) {
      continue
    }

    Remove-ManagedCachePath $targetChild.FullName $TargetRoot "Removed stale managed Symphony++ plugin cache item"
  }
}

function Copy-PluginCacheTarget([string]$TargetRoot, [string]$SourceRoot, [string]$RepoRoot) {
  Assert-SafeCacheTarget $TargetRoot $pluginCacheRoot
  Assert-NotReparsePoint $TargetRoot
  Assert-NoReparsePointDescendants $TargetRoot

  New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null

  foreach ($item in @(".codex-plugin", ".mcp.json", "assets", "skills", "skills-default", "scripts", "README.md")) {
    $source = Join-Path $SourceRoot $item
    $target = Join-Path $TargetRoot $item
    if (Test-Path -LiteralPath $source) {
      Assert-NotReparsePoint $target
      Assert-NoReparsePointDescendants $target
      Copy-Item -LiteralPath $source -Destination $TargetRoot -Recurse -Force
      Sync-ManagedDirectoryChildren $source $target $TargetRoot
    } elseif (Test-Path -LiteralPath $target) {
      Remove-ManagedCachePath $target $TargetRoot "Removed stale managed Symphony++ plugin cache item"
    }
  }

  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  $generatedMarkerPath = Join-Path $TargetRoot ".sympp-generated-cache"
  Assert-NotReparsePoint $generatedMarkerPath
  [System.IO.File]::WriteAllText($generatedMarkerPath, "generated_by=refresh-local-plugin.ps1`nsource=developer_checkout`n", $utf8NoBom)

  $legacySourceRootHintPath = Join-Path $TargetRoot ".sympp-source-root"
  if (Test-Path -LiteralPath $legacySourceRootHintPath) {
    Remove-ManagedCachePath $legacySourceRootHintPath $TargetRoot "Removed stale Symphony++ source-root cache hint"
  }

  $sourceRevisionPath = Join-Path $TargetRoot ".sympp-source-revision"
  Assert-NotReparsePoint $sourceRevisionPath
  $sourceRevision = Get-RepoHeadRevision $RepoRoot
  if ($sourceRevision) {
    [System.IO.File]::WriteAllText($sourceRevisionPath, "$sourceRevision`n", $utf8NoBom)
  } elseif (Test-Path -LiteralPath $sourceRevisionPath) {
    Remove-ManagedCachePath $sourceRevisionPath $TargetRoot "Removed stale Symphony++ source revision cache marker"
  }
}

function Remove-GeneratedLocalCacheEntry([string]$PluginCacheRoot) {
  $localCacheRoot = Join-And-Normalize $PluginCacheRoot @("local")
  Assert-SafeCacheTarget $localCacheRoot $PluginCacheRoot
  if (-not (Test-Path -LiteralPath $localCacheRoot)) {
    return
  }

  if (Test-GeneratedDefaultPluginCache $localCacheRoot) {
    Remove-ManagedCachePath $localCacheRoot $PluginCacheRoot "Removed stale generated Symphony++ local plugin cache"
    return
  }

  throw "Unmarked local plugin cache entry still exists. Inspect and remove it manually if obsolete, then rerun refresh: $localCacheRoot"
}

function Assert-SafeVersionSegment([string]$Version) {
  if ([string]::IsNullOrWhiteSpace($Version)) {
    throw "Plugin manifest must include a non-empty version."
  }

  if ($Version.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $Version.Contains("/") -or $Version.Contains("\")) {
    throw "Plugin manifest version is not safe for a cache directory name: $Version"
  }
}

function Assert-SafeCacheSegment([string]$Value, [string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$Label must be non-empty."
  }

  if ($Value.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $Value.Contains("/") -or $Value.Contains("\")) {
    throw "$Label is not safe for a cache directory name: $Value"
  }
}

function Assert-RequiredJsonValue($Value, [string]$Message) {
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    throw $Message
  }
}

function Resolve-DocumentedMcpServerMap($McpConfig, [string]$McpConfigPath) {
  $propertyNames = @($McpConfig.PSObject.Properties.Name)
  if ($propertyNames -contains "mcpServers") {
    throw "Plugin .mcp.json must use a documented shape: direct server map or wrapped mcp_servers, not mcpServers: $McpConfigPath"
  }

  if ($propertyNames -contains "mcp_servers") {
    return $McpConfig.mcp_servers
  }

  return $McpConfig
}

function Get-ParsedJsonOrNull([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Write-JsonFileNoBom([string]$Path, $Value) {
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  $json = $Value | ConvertTo-Json -Depth 16
  [System.IO.File]::WriteAllText($Path, "$json`n", $utf8NoBom)
}

function Test-GeneratedDefaultPluginCache([string]$CacheEntryRoot) {
  return (Test-Path -LiteralPath (Join-Path $CacheEntryRoot ".sympp-generated-cache")) -or
    (Test-Path -LiteralPath (Join-Path $CacheEntryRoot ".sympp-source-root"))
}

function Test-IncompatibleDefaultPluginCache([string]$CacheEntryRoot) {
  if (-not (Test-GeneratedDefaultPluginCache $CacheEntryRoot)) {
    return $false
  }

  $rootMcpPath = Join-Path $CacheEntryRoot ".mcp.json"
  if (Test-Path -LiteralPath $rootMcpPath) {
    return $true
  }

  $manifestPath = Join-Path $CacheEntryRoot ".codex-plugin/plugin.json"
  $manifest = Get-ParsedJsonOrNull $manifestPath
  if ($null -eq $manifest -or [string]$manifest.name -ne "symphony-plus-plus") {
    return $false
  }

  $manifestHasMcpServers = @($manifest.PSObject.Properties.Name) -contains "mcpServers"
  return $manifestHasMcpServers
}

function Repair-IncompatibleDefaultPluginCache([string]$CacheEntryRoot) {
  $changed = $false
  $rootMcpPath = Join-Path $CacheEntryRoot ".mcp.json"
  if (Test-Path -LiteralPath $rootMcpPath) {
    Remove-ManagedCachePath $rootMcpPath $CacheEntryRoot "Removed stale default Symphony++ plugin MCP startup file"
    $changed = $true
  }

  $manifestPath = Join-Path $CacheEntryRoot ".codex-plugin/plugin.json"
  $manifest = Get-ParsedJsonOrNull $manifestPath
  if ($null -ne $manifest -and @($manifest.PSObject.Properties.Name) -contains "mcpServers") {
    $manifest.PSObject.Properties.Remove("mcpServers")
    Write-JsonFileNoBom $manifestPath $manifest
    $changed = $true
  }

  if ($changed) {
    Write-Host "Repaired incompatible default Symphony++ plugin cache: $CacheEntryRoot"
  }
}

function Repair-IncompatibleDefaultPluginCacheEntries([string]$PluginCacheRoot) {
  if (-not (Test-Path -LiteralPath $PluginCacheRoot)) {
    return
  }
  if ((Get-Item -LiteralPath $PluginCacheRoot -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    Write-Host "Skipped stale default Symphony++ plugin cache repair for reparse-point root: $PluginCacheRoot"
    return
  }

  foreach ($cacheEntry in @(Get-ChildItem -LiteralPath $PluginCacheRoot -Directory -Force)) {
    if (-not (Test-IncompatibleDefaultPluginCache $cacheEntry.FullName)) {
      continue
    }

    Assert-SafeCacheTarget $cacheEntry.FullName $PluginCacheRoot
    Assert-NotReparsePoint $cacheEntry.FullName
    Assert-NoReparsePointDescendants $cacheEntry.FullName
    Repair-IncompatibleDefaultPluginCache $cacheEntry.FullName
  }
}

function Assert-CachePluginConfig([string]$TargetRoot, [string]$ExpectedVersion) {
  $targetManifestPath = Join-Path $TargetRoot ".codex-plugin/plugin.json"
  $targetManifest = Get-Content -LiteralPath $targetManifestPath -Raw | ConvertFrom-Json
  if ($targetManifest.name -ne $PluginName) {
    throw "Installed plugin manifest name mismatch in $targetManifestPath."
  }
  if ($targetManifest.version -ne $ExpectedVersion) {
    throw "Installed plugin manifest version mismatch in $targetManifestPath."
  }
  foreach ($iconProperty in @("composerIcon", "logo")) {
    if ($targetManifest.interface.$iconProperty -ne "./assets/splusplus-logo.png") {
      throw "Installed plugin manifest must declare interface.$iconProperty './assets/splusplus-logo.png': $targetManifestPath"
    }
  }
  $iconPath = Join-Path $TargetRoot "assets/splusplus-logo.png"
  if (-not (Test-Path -LiteralPath $iconPath)) {
    throw "Installed plugin icon is missing from cache: $iconPath"
  }
  $manifestHasMcpServers = @($targetManifest.PSObject.Properties.Name) -contains "mcpServers"
  if ($PluginName -eq "symphony-plus-plus" -and $manifestHasMcpServers) {
    throw "Default installed plugin manifest must not declare mcpServers; keep generic S++ MCP opt-in instead: $targetManifestPath"
  }
  if ($PluginName -eq "symphony-plus-plus-mcp" -and (-not $manifestHasMcpServers -or $targetManifest.mcpServers -ne "./.mcp.json")) {
    throw "Opt-in MCP plugin manifest must declare mcpServers './.mcp.json': $targetManifestPath"
  }

  $mcpConfigPath = [System.IO.Path]::GetFullPath((Join-Path $TargetRoot ".mcp.json"))
  Assert-PathInside $mcpConfigPath $TargetRoot "Installed plugin reference .mcp.json path resolves outside this cache"
  if ($PluginName -eq "symphony-plus-plus") {
    $rootSkillsPath = Join-Path $TargetRoot "skills"
    if (-not (Test-Path -LiteralPath $rootSkillsPath)) {
      throw "Default installed plugin cache is missing the standard root skills directory: $rootSkillsPath"
    }

    $legacyDefaultSkillsPath = Join-Path $TargetRoot "skills-default"
    if (Test-Path -LiteralPath $legacyDefaultSkillsPath) {
      throw "Default installed plugin cache still contains the legacy skills-default directory: $legacyDefaultSkillsPath"
    }

    if (Test-Path -LiteralPath $mcpConfigPath) {
      throw "Default installed plugin cache must not contain root .mcp.json; use symphony-plus-plus-mcp for bundled MCP startup: $mcpConfigPath"
    }

    foreach ($requiredDefaultSkill in @("symphony-solo-session", "symphony-worker", "symphony-coordinator")) {
      $requiredDefaultSkillPath = Join-Path $TargetRoot "skills/$requiredDefaultSkill/SKILL.md"
      if (-not (Test-Path -LiteralPath $requiredDefaultSkillPath)) {
        throw "Default installed plugin cache is missing MCP-free base skill '$requiredDefaultSkill': $requiredDefaultSkillPath"
      }
    }

    return
  }

  foreach ($mcpRequiredSkill in @("symphony-solo-session", "symphony-worker", "symphony-coordinator", "symphony-work-package", "symphony-architect")) {
    $mcpRequiredSkillPath = Join-Path $TargetRoot "skills/$mcpRequiredSkill/SKILL.md"
    if (-not (Test-Path -LiteralPath $mcpRequiredSkillPath)) {
      throw "Opt-in MCP plugin cache is missing full MCP-mode skill '$mcpRequiredSkill': $mcpRequiredSkillPath"
    }
  }

  if (-not (Test-Path -LiteralPath $mcpConfigPath)) {
    throw "Installed plugin reference .mcp.json path does not exist: $mcpConfigPath"
  }

  $mcpConfig = Get-Content -LiteralPath $mcpConfigPath -Raw | ConvertFrom-Json
  $serverMap = Resolve-DocumentedMcpServerMap $mcpConfig $mcpConfigPath
  $server = $serverMap.symphony_plus_plus
  if ($null -eq $server) {
    throw "Installed MCP config does not define symphony_plus_plus in a documented MCP config shape: $mcpConfigPath"
  }
  if (@($server.PSObject.Properties.Name) -contains "url") {
    throw "Installed opt-in MCP server must use the command-backed launcher, not a URL-only endpoint: $mcpConfigPath"
  }
  if ($server.type -ne "stdio") {
    throw "Installed opt-in MCP server must declare type 'stdio': $mcpConfigPath"
  }
  if ($server.command -ne "cmd.exe") {
    throw "Installed opt-in MCP server command must be cmd.exe so the launcher can resolve pwsh or powershell.exe: $mcpConfigPath"
  }
  if ($server.cwd -ne ".") {
    throw "Installed opt-in MCP server cwd must be '.': $mcpConfigPath"
  }
  if ($server.startup_timeout_sec -ne 360) {
    throw "Installed opt-in MCP server startup_timeout_sec must be 360: $mcpConfigPath"
  }
  if ($server.tool_timeout_sec -ne 300) {
    throw "Installed opt-in MCP server tool_timeout_sec must be 300: $mcpConfigPath"
  }

  $args = @($server.args)
  if ($args -notcontains "/c") {
    throw "Installed opt-in MCP server args must launch the command wrapper through cmd.exe /c: $mcpConfigPath"
  }
  $hasStartWrapper = @($args | Where-Object { [string]$_ -match "scripts[\\/]start-sympp-mcp\.cmd" }).Count -gt 0
  if (-not $hasStartWrapper) {
    throw "Installed opt-in MCP server args must reference scripts/start-sympp-mcp.cmd: $mcpConfigPath"
  }
}

function Invoke-InstalledCacheValidation([string]$TargetRoot, [string]$Label, [string]$ExpectedVersion, [string]$ValidationSourceRoot) {
  Assert-CachePluginConfig $TargetRoot $ExpectedVersion

  Push-Location -LiteralPath $TargetRoot
  $oldRepoRoot = $env:SYMPP_REPO_ROOT
  try {
    $powershell = Get-AvailablePowerShellCommandName
    Remove-Item Env:SYMPP_REPO_ROOT -ErrorAction SilentlyContinue
    if ($PluginName -eq "symphony-plus-plus-mcp") {
      if (-not [string]::IsNullOrWhiteSpace($ValidationSourceRoot)) {
        $env:SYMPP_REPO_ROOT = $ValidationSourceRoot
      }

      if (Test-RefreshWindowsPlatform) {
        & cmd.exe @("/d", "/s", "/c", "scripts\start-sympp-mcp.cmd -ValidateOnly")
      } else {
        & $powershell @("-NoProfile", "-File", "scripts/start-sympp-mcp.ps1", "-ValidateOnly")
      }
      if ($LASTEXITCODE -ne 0) {
        throw "Installed plugin MCP launcher validation failed for $Label cache with exit code $LASTEXITCODE."
      }
    }

    & $powershell @(
      "-NoProfile",
      "-Command",
      "`$env:PSExecutionPolicyPreference='Bypass'; & 'scripts/sympp-solo.ps1' -ValidateOnly"
    )
    if ($LASTEXITCODE -ne 0) {
      throw "Installed plugin Solo Session wrapper validation failed for $Label cache with exit code $LASTEXITCODE."
    }
  } finally {
    if ($null -eq $oldRepoRoot) {
      Remove-Item Env:SYMPP_REPO_ROOT -ErrorAction SilentlyContinue
    } else {
      $env:SYMPP_REPO_ROOT = $oldRepoRoot
    }
    Pop-Location
  }

  Write-Host "Validated installed Symphony++ plugin cache:"
  Write-Host "  cache: $Label"
  Write-Host "  root: $TargetRoot"
}

$repoRoot = Resolve-StrictPath (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($MarketplacePath)) {
  $MarketplacePath = Join-Path $repoRoot ".agents\plugins\marketplace.json"
}

$marketplaceFile = Resolve-StrictPath $MarketplacePath
$marketplace = Get-Content -LiteralPath $marketplaceFile -Raw | ConvertFrom-Json
$marketplaceName = if ([string]::IsNullOrWhiteSpace($MarketplaceName)) { [string]$marketplace.name } else { $MarketplaceName }
if ([string]::IsNullOrWhiteSpace($marketplaceName)) {
  throw "Marketplace file must include a top-level name."
}
Assert-SafeCacheSegment $marketplaceName "Marketplace name"

if ($PluginName -in @("all", "*")) {
  $selectedPluginNames = @(
    @($marketplace.plugins) |
      Where-Object { $SymppPluginPackageNames -contains $_.name } |
      ForEach-Object { [string]$_.name } |
      Sort-Object -Unique
  )
  if ($selectedPluginNames.Count -eq 0) {
    throw "No Symphony++ plugins were found in $marketplaceFile."
  }

  foreach ($selectedPluginName in $selectedPluginNames) {
    & $PSCommandPath `
      -MarketplacePath $marketplaceFile `
      -MarketplaceName $marketplaceName `
      -CodexHome $CodexHome `
      -PluginName $selectedPluginName `
      -ValidateInstalledCache:$ValidateInstalledCache `
      -AllowDefaultCodexHomeRefresh:$AllowDefaultCodexHomeRefresh
  }

  exit 0
}

$sourceRoot = Resolve-StrictPath (Join-Path $repoRoot "plugins\$PluginName")
$plugin = @($marketplace.plugins) | Where-Object { $_.name -eq $PluginName } | Select-Object -First 1
if (-not $plugin) {
  throw "Plugin '$PluginName' was not found in $marketplaceFile."
}
if ($plugin.source.source -ne "local") {
  throw "Plugin '$PluginName' is not a local marketplace plugin."
}

$configuredSourceRoot = Resolve-ConfiguredSourcePath ([string]$plugin.source.path) $marketplaceFile $repoRoot
if (-not ([System.IO.Path]::GetFullPath($configuredSourceRoot).TrimEnd("\", "/").Equals($sourceRoot.TrimEnd("\", "/"), [System.StringComparison]::OrdinalIgnoreCase))) {
  throw "Plugin '$PluginName' marketplace path resolves to $configuredSourceRoot, not this checkout source $sourceRoot."
}

$manifestPath = Join-Path $sourceRoot ".codex-plugin/plugin.json"
if (-not (Test-Path -LiteralPath $manifestPath)) {
  throw "Missing plugin manifest at $manifestPath."
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.name -ne $PluginName) {
  throw "Plugin manifest name '$($manifest.name)' does not match requested plugin '$PluginName'."
}
$manifestVersion = [string]$manifest.version
Assert-SafeVersionSegment $manifestVersion

$codexHomePath = [System.IO.Path]::GetFullPath($CodexHome)
if (-not $AllowDefaultCodexHomeRefresh -and (Test-SamePath $codexHomePath (Get-DefaultCodexHomePath))) {
  throw "Refusing to refresh the default Codex plugin cache from a developer checkout. Run 'codex plugin marketplace upgrade' for installed plugins, or pass -CodexHome <isolated-dev-home>. Use -AllowDefaultCodexHomeRefresh only for an intentional local development cache."
}
$pluginsRoot = Join-And-Normalize $codexHomePath @("plugins")
$cacheRoot = Join-And-Normalize $codexHomePath @("plugins", "cache")
$marketplaceCacheRoot = Join-And-Normalize $cacheRoot @($marketplaceName)
$pluginCacheRoot = Join-And-Normalize $cacheRoot @($marketplaceName, $PluginName)
$defaultPluginCacheRoot = Join-And-Normalize $cacheRoot @($marketplaceName, "symphony-plus-plus")
Assert-PathInside $pluginCacheRoot $cacheRoot "Resolved plugin cache path is outside Codex plugin cache"
Assert-PathInside $defaultPluginCacheRoot $cacheRoot "Resolved default plugin cache path is outside Codex plugin cache"
Assert-ExistingCachePathNotReparsePoint @($codexHomePath, $pluginsRoot, $cacheRoot, $marketplaceCacheRoot, $pluginCacheRoot)
Sync-MarketplaceSourceSnapshot $codexHomePath $marketplaceName $repoRoot

$versionTargetRoot = Join-And-Normalize $pluginCacheRoot @($manifestVersion)

New-Item -ItemType Directory -Path $pluginCacheRoot -Force | Out-Null
Repair-IncompatibleDefaultPluginCacheEntries $defaultPluginCacheRoot

Copy-PluginCacheTarget $versionTargetRoot $sourceRoot $repoRoot

if ($ValidateInstalledCache) {
  Invoke-InstalledCacheValidation $versionTargetRoot $manifestVersion $manifestVersion $repoRoot
}

Remove-GeneratedLocalCacheEntry $pluginCacheRoot

Write-Host "Refreshed local Codex plugin cache:"
Write-Host "  source: $sourceRoot"
Write-Host "  version target: $versionTargetRoot"
Write-Host ""
Write-Host "Restart or reload Codex to pick up refreshed plugin skills and MCP servers."
Write-Host "Run the activation doctor to inspect enablement and next actions without mutating config:"
$doctorScript = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "plugins/symphony-plus-plus/scripts/diagnose-mcp-lifecycle.ps1"))
$doctorPowerShell = Get-AvailablePowerShellCommandName
Write-Host "  $doctorPowerShell -NoProfile -File $(Quote-PowerShellLiteral $doctorScript) -CodexHome $(Quote-PowerShellLiteral $codexHomePath) -MarketplaceName $(Quote-PowerShellLiteral $marketplaceName) -Doctor"
