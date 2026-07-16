param(
  [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { "$HOME/.codex" }),
  [string]$MarketplaceName = "*",
  [string]$RepoRoot,
  [switch]$EnableMcpCompanion,
  [switch]$SkipProcessScan,
  [switch]$SelfTest,
  [switch]$Doctor,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$SymppPluginPackageNames = @("symphony-plus-plus", "symphony-plus-plus-mcp")

$diagnosticRuntimeArtifactHelpers = Join-Path $PSScriptRoot "sympp-diagnostic-runtime-artifacts.ps1"
if (-not (Test-Path -LiteralPath $diagnosticRuntimeArtifactHelpers -PathType Leaf)) {
  throw "Symphony++ lifecycle diagnostic helper is missing: $diagnosticRuntimeArtifactHelpers. Refresh or repair the installed plugin cache."
}
. $diagnosticRuntimeArtifactHelpers

$diagnosticLauncherArtifactHelpers = Join-Path $PSScriptRoot "sympp-diagnostic-launcher-artifacts.ps1"
if (-not (Test-Path -LiteralPath $diagnosticLauncherArtifactHelpers -PathType Leaf)) {
  throw "Symphony++ lifecycle diagnostic launcher helper is missing: $diagnosticLauncherArtifactHelpers. Refresh or repair the installed plugin cache."
}
. $diagnosticLauncherArtifactHelpers

$diagnosticSelfTestHelpers = Join-Path $PSScriptRoot "sympp-diagnostic-self-test.ps1"
if (-not (Test-Path -LiteralPath $diagnosticSelfTestHelpers -PathType Leaf)) {
  throw "Symphony++ lifecycle diagnostic self-test helper is missing: $diagnosticSelfTestHelpers. Refresh or repair the installed plugin cache."
}
. $diagnosticSelfTestHelpers

function Resolve-OptionalFullPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $expandedPath = $Path
  if ($expandedPath -eq "~") {
    $expandedPath = $HOME
  } elseif ($expandedPath.StartsWith("~/") -or $expandedPath.StartsWith("~\")) {
    $expandedPath = Join-Path $HOME $expandedPath.Substring(2)
  }

  return [System.IO.Path]::GetFullPath($expandedPath)
}

function Normalize-ComparablePath([string]$Path) {
  $fullPath = Resolve-OptionalFullPath $Path
  if (-not $fullPath) {
    return $null
  }

  $trimmedPath = $fullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  if (Test-PathComparisonCaseInsensitive $trimmedPath) {
    return $trimmedPath.ToLowerInvariant()
  }

  return $trimmedPath
}

function Get-CaseVariantName([string]$Name) {
  $characters = @($Name.ToCharArray())
  for ($index = 0; $index -lt $characters.Count; $index++) {
    $character = [string]$characters[$index]
    if ($character -cmatch '[a-z]') {
      $characters[$index] = [char]$character.ToUpperInvariant()
      return -join $characters
    }
    if ($character -cmatch '[A-Z]') {
      $characters[$index] = [char]$character.ToLowerInvariant()
      return -join $characters
    }
  }

  return $null
}

function Get-ExistingCaseProbePath([string]$Path) {
  $probePath = Resolve-OptionalFullPath $Path
  if (-not $probePath) {
    $probePath = (Get-Location).ProviderPath
  }

  while (-not [string]::IsNullOrWhiteSpace($probePath)) {
    if (Test-Path -LiteralPath $probePath) {
      return [System.IO.Path]::GetFullPath($probePath)
    }

    $parentPath = Split-Path -Path $probePath -Parent
    if ([string]::IsNullOrWhiteSpace($parentPath) -or $parentPath -eq $probePath) {
      return $null
    }
    $probePath = $parentPath
  }

  return $null
}

function Get-FileIdentityKey([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $statCommand = Get-Command stat -ErrorAction SilentlyContinue
  if (-not $statCommand) {
    return $null
  }

  $statArguments = if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
    @("-f", "%d:%i", $Path)
  } else {
    @("-c", "%d:%i", "--", $Path)
  }

  try {
    $output = @(& $statCommand.Source @statArguments 2>$null)
    if ($LASTEXITCODE -eq 0 -and $output.Count -gt 0) {
      return ([string]$output[0]).Trim()
    }
  } catch {
  }

  return $null
}

function Test-PathComparisonCaseInsensitive([string]$Path = $null) {
  if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
    return $true
  }

  if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
    return $false
  }

  $probePath = Get-ExistingCaseProbePath $Path
  if (-not $probePath) {
    return $false
  }

  $probeName = Split-Path -Path $probePath -Leaf
  $variantName = Get-CaseVariantName $probeName
  if ([string]::IsNullOrWhiteSpace($variantName)) {
    return $false
  }

  $parentPath = Split-Path -Path $probePath -Parent
  if ([string]::IsNullOrWhiteSpace($parentPath)) {
    return $false
  }

  $variantPath = Join-Path $parentPath $variantName
  if (-not (Test-Path -LiteralPath $variantPath)) {
    return $false
  }

  $probeIdentity = Get-FileIdentityKey $probePath
  $variantIdentity = Get-FileIdentityKey $variantPath
  return -not [string]::IsNullOrWhiteSpace($probeIdentity) -and
    [System.StringComparer]::Ordinal.Equals($probeIdentity, $variantIdentity)
}

function Get-ComparablePathStringComparer([string]$Path = $null) {
  if (Test-PathComparisonCaseInsensitive $Path) {
    return [System.StringComparer]::OrdinalIgnoreCase
  }

  return [System.StringComparer]::Ordinal
}

function Test-ComparablePathEqual([string]$Left, [string]$Right) {
  if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
    return $false
  }

  return [System.StringComparer]::Ordinal.Equals((Normalize-ComparablePath $Left), (Normalize-ComparablePath $Right))
}

function Get-FileSystemLinkTargetPath($Item) {
  if ($null -eq $Item) {
    return $null
  }

  $targetProperty = $Item.PSObject.Properties["Target"]
  if (-not $targetProperty) {
    return $null
  }

  $target = @($targetProperty.Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1)
  if (-not $target) {
    return $null
  }

  if ([System.IO.Path]::IsPathRooted([string]$target)) {
    return [System.IO.Path]::GetFullPath([string]$target)
  }

  return [System.IO.Path]::GetFullPath((Join-Path (Split-Path $Item.FullName -Parent) ([string]$target)))
}

function Resolve-ComparableFileSystemPath([string]$Path) {
  $resolvedPath = Resolve-OptionalFullPath $Path
  if (-not $resolvedPath) {
    return $null
  }

  $visited = [System.Collections.Generic.HashSet[string]]::new((Get-ComparablePathStringComparer $resolvedPath))
  $root = [System.IO.Path]::GetPathRoot($resolvedPath)
  if ([string]::IsNullOrWhiteSpace($root)) {
    return Normalize-ComparablePath $resolvedPath
  }

  $segments = @(
    $resolvedPath.Substring($root.Length).Split(
      [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar),
      [System.StringSplitOptions]::RemoveEmptyEntries
    )
  )
  $currentPath = $root

  foreach ($segment in $segments) {
    $candidatePath = Join-Path $currentPath $segment
    $candidateKey = Normalize-ComparablePath $candidatePath
    if (-not $candidateKey -or -not $visited.Add($candidateKey)) {
      return Normalize-ComparablePath $candidatePath
    }
    try {
      $item = Get-Item -LiteralPath $candidatePath -Force -ErrorAction Stop
    } catch {
      $currentPath = $candidatePath
      continue
    }

    $targetPath = Get-FileSystemLinkTargetPath $item
    if (-not $targetPath) {
      $currentPath = $item.FullName
      continue
    }

    $currentPath = $targetPath
  }

  return Normalize-ComparablePath $currentPath
}

function Test-DefaultCodexHome([string]$Path) {
  $defaultPath = Join-Path $HOME ".codex"
  $defaultCodexHome = Normalize-ComparablePath $defaultPath
  $targetCodexHome = Normalize-ComparablePath $Path
  if ([string]::IsNullOrWhiteSpace($targetCodexHome)) {
    return $false
  }

  if (Test-ComparablePathEqual $targetCodexHome $defaultCodexHome) {
    return $true
  }

  $defaultFileSystemPath = Resolve-ComparableFileSystemPath $defaultPath
  $targetFileSystemPath = Resolve-ComparableFileSystemPath $Path
  return Test-ComparablePathEqual $targetFileSystemPath $defaultFileSystemPath
}

function Quote-PowerShellLiteral([string]$Value) {
  return "'" + ($Value -replace "'", "''") + "'"
}

function Test-SourceCheckoutRoot([string]$Path) {
  $fullPath = Resolve-OptionalFullPath $Path
  if (-not $fullPath) {
    return $false
  }

  return (Test-Path -LiteralPath (Join-Path $fullPath "elixir/mix.exs")) -and
    (Test-Path -LiteralPath (Join-Path $fullPath "scripts/refresh-local-plugin.ps1")) -and
    (Test-Path -LiteralPath (Join-Path $fullPath "scripts/smoke-sympp-mcp-http.ps1"))
}

function Get-RelativePackagePath([string]$Root, [string]$Path) {
  $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $rootWithSeparator = $rootPath + [System.IO.Path]::DirectorySeparatorChar
  $comparison = if (Test-PathComparisonCaseInsensitive $rootPath) {
    [System.StringComparison]::OrdinalIgnoreCase
  } else {
    [System.StringComparison]::Ordinal
  }

  if ($fullPath.StartsWith($rootWithSeparator, $comparison)) {
    return $fullPath.Substring($rootWithSeparator.Length).Replace("\", "/")
  }

  throw "Package fingerprint path is outside package root: $fullPath"
}

function Test-PackageFingerprintRelativePath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }

  $normalized = $Path.Replace("\", "/")
  return $normalized -eq ".mcp.json" -or
    $normalized.StartsWith(".codex-plugin/", [System.StringComparison]::Ordinal) -or
    $normalized.StartsWith("assets/", [System.StringComparison]::Ordinal) -or
    $normalized.StartsWith("scripts/", [System.StringComparison]::Ordinal) -or
    $normalized.StartsWith("skills/", [System.StringComparison]::Ordinal) -or
    $normalized.StartsWith("skills-default/", [System.StringComparison]::Ordinal)
}

function Get-PackageFingerprintFiles([string]$Root) {
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    return @()
  }

  $fingerprintInputs = @(".codex-plugin", ".mcp.json", "assets", "scripts", "skills", "skills-default")
  return @(
    foreach ($relativePath in $fingerprintInputs) {
      $candidate = Join-Path $Root $relativePath
      if (-not (Test-Path -LiteralPath $candidate)) {
        continue
      }

      $item = Get-Item -LiteralPath $candidate -Force
      if ($item.PSIsContainer) {
        Get-ChildItem -LiteralPath $candidate -File -Recurse -Force
      } else {
        $item
      }
    }
  )
}

function Get-GitTrackedPackageFingerprintPaths([string]$SourceRoot, [string]$PackageRoot) {
  if ([string]::IsNullOrWhiteSpace($SourceRoot) -or [string]::IsNullOrWhiteSpace($PackageRoot)) {
    return @()
  }

  $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $git) {
    return @()
  }

  try {
    $packagePrefix = Get-RelativePackagePath $SourceRoot $PackageRoot
    $trackedPaths = @(& $git.Source @("-C", $SourceRoot, "ls-files", "--", $packagePrefix) 2>$null)
    if ($LASTEXITCODE -ne 0) {
      return @()
    }

    $prefix = $packagePrefix.TrimEnd("/") + "/"
    return @(
      $trackedPaths |
        ForEach-Object { [string]$_ } |
        Where-Object { $_.StartsWith($prefix, [System.StringComparison]::Ordinal) } |
        ForEach-Object { $_.Substring($prefix.Length) } |
        Where-Object { Test-PackageFingerprintRelativePath $_ } |
        Sort-Object -Unique
    )
  } catch {
    return @()
  }
}

function Get-ExistingPackageFingerprintPaths([string]$Root) {
  return @(
    Get-PackageFingerprintFiles $Root |
      ForEach-Object { Get-RelativePackagePath $Root $_.FullName } |
      Sort-Object -Unique
  )
}

function Merge-PackageFingerprintPaths([string[]]$SourcePaths, [string[]]$CachePaths) {
  return @(
    @($SourcePaths) + @($CachePaths) |
      Where-Object { Test-PackageFingerprintRelativePath $_ } |
      Sort-Object -Unique
  )
}

function Get-FileSha256Hex([string]$Path) {
  $stream = [System.IO.File]::OpenRead($Path)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
    $stream.Dispose()
  }
}

function Get-PluginPackageFingerprint([string]$Root, [string[]]$RelativePaths = @()) {
  if ($RelativePaths.Count -gt 0) {
    $entries = @(
      $RelativePaths |
        ForEach-Object { [string]$_ } |
        Sort-Object -Unique |
        ForEach-Object {
          $relativePath = $_.Replace("\", "/")
          $fullPath = Join-Path $Root $relativePath
          if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            "$relativePath`0$(Get-FileSha256Hex $fullPath)"
          } else {
            "$relativePath`0<missing>"
          }
        }
    )
    if ($entries.Count -eq 0) {
      return $null
    }

    $payload = [System.String]::Join("`n", $entries)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
      return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
    } finally {
      $sha.Dispose()
    }
  }

  $files = @(Get-PackageFingerprintFiles $Root)
  if ($files.Count -eq 0) {
    return $null
  }

  $entries = @(
    $files |
      ForEach-Object {
        "$(Get-RelativePackagePath $Root $_.FullName)`0$(Get-FileSha256Hex $_.FullName)"
      } |
      Sort-Object
  )
  $payload = [System.String]::Join("`n", $entries)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-SourceCheckoutFromPluginRoot([string]$PluginRoot) {
  if ([string]::IsNullOrWhiteSpace($PluginRoot)) {
    return $null
  }

  $candidate = Split-Path (Split-Path $PluginRoot -Parent) -Parent
  if (Test-SourceCheckoutRoot $candidate) {
    return Resolve-OptionalFullPath $candidate
  }

  return $null
}

function Get-SourceCheckoutFromCurrentDirectory {
  try {
    $candidate = (Get-Location).ProviderPath
  } catch {
    return $null
  }

  while (-not [string]::IsNullOrWhiteSpace($candidate)) {
    if (Test-SourceCheckoutRoot $candidate) {
      return Resolve-OptionalFullPath $candidate
    }

    $parent = Split-Path $candidate -Parent
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidate) {
      break
    }
    $candidate = $parent
  }

  return $null
}

function Get-MarketplaceSourceRootFromCachePackage($Package) {
  if ($null -eq $Package -or [string]::IsNullOrWhiteSpace([string]$Package.root)) {
    return $null
  }

  $versionRoot = Resolve-OptionalFullPath ([string]$Package.root)
  if (-not $versionRoot) {
    return $null
  }

  $packageRoot = Split-Path -Parent $versionRoot
  $marketplaceRoot = Split-Path -Parent $packageRoot
  $cacheRoot = Split-Path -Parent $marketplaceRoot
  $pluginsRoot = Split-Path -Parent $cacheRoot

  if ((Split-Path -Leaf $cacheRoot) -ne "cache" -or (Split-Path -Leaf $pluginsRoot) -ne "plugins") {
    return $null
  }

  $codexHome = Split-Path -Parent $pluginsRoot
  $marketplaceName = Split-Path -Leaf $marketplaceRoot
  $candidate = Resolve-OptionalFullPath (Join-Path $codexHome ".tmp/marketplaces/$marketplaceName")
  $sourcePackageRoot = Join-Path $candidate "plugins/$($Package.package_name)"
  if ((Test-SourceCheckoutRoot $candidate) -and
      (Test-Path -LiteralPath (Join-Path $candidate ".codex-marketplace-install.json") -PathType Leaf) -and
      (Test-Path -LiteralPath (Join-Path $sourcePackageRoot ".codex-plugin/plugin.json") -PathType Leaf)) {
    return $candidate
  }

  return $null
}

function Test-PackageCanProvideSourceRootHint($Package) {
  if ($null -eq $Package) {
    return $false
  }

  if ($Package.package_name -eq "symphony-plus-plus") {
    return Test-DefaultPackageReady $Package
  }

  if ($Package.package_name -eq "symphony-plus-plus-mcp") {
    return Test-McpCompanionPackageReady $Package
  }

  return $false
}

function Get-UsableSourceHintRoots($Packages) {
  return @(
    $Packages |
      Where-Object { Test-PackageCanProvideSourceRootHint $_ } |
      ForEach-Object { Resolve-OptionalFullPath $_.source_root_hint } |
      Where-Object { Test-SourceCheckoutRoot $_ } |
      Sort-Object -Unique
  )
}

function Get-UsableMarketplaceSourceRoots($Packages) {
  return @(
    $Packages |
      ForEach-Object { Get-MarketplaceSourceRootFromCachePackage $_ } |
      Where-Object { Test-SourceCheckoutRoot $_ } |
      Sort-Object -Unique
  )
}

function New-SourceCheckoutStatus([string]$Status, [string]$Root, [string]$Note = $null) {
  return [pscustomobject]@{
    status = $Status
    root = $Root
    note = $Note
  }
}

function Resolve-ReadinessSourceCheckout([string]$PluginRoot, [string]$ProvidedRepoRoot, $PreferredPackages) {
  if (Test-SourceCheckoutRoot $ProvidedRepoRoot) {
    return New-SourceCheckoutStatus "repo_root_parameter" (Resolve-OptionalFullPath $ProvidedRepoRoot)
  }

  $sourceCheckoutRoot = Get-SourceCheckoutFromPluginRoot $PluginRoot
  if ($sourceCheckoutRoot) {
    return New-SourceCheckoutStatus "source_plugin_root" $sourceCheckoutRoot
  }

  $marketplaceSourceRoots = Get-UsableMarketplaceSourceRoots $PreferredPackages
  if ($marketplaceSourceRoots.Count -eq 1) {
    return New-SourceCheckoutStatus "codex_marketplace_source_clone" (@($marketplaceSourceRoots)[0])
  }

  if ($marketplaceSourceRoots.Count -gt 1) {
    return New-SourceCheckoutStatus "ambiguous_codex_marketplace_source_clones" $null "Selected installed caches resolve to multiple Codex marketplace source clones; rerun with -MarketplaceName <marketplace> or pass -RepoRoot only for explicit developer validation."
  }

  $sourceCheckoutRoot = Get-SourceCheckoutFromCurrentDirectory
  if ($sourceCheckoutRoot) {
    return New-SourceCheckoutStatus "current_working_directory" $sourceCheckoutRoot
  }

  return New-SourceCheckoutStatus "not_found" $null "No Codex marketplace source clone could be inferred. Run codex plugin marketplace upgrade, or pass -RepoRoot only for explicit developer validation."
}

function New-CodexMarketplaceUpgradeCommand([string]$CodexHomePath, [string]$MarketplaceName) {
  $marketplaceArg = if ([string]::IsNullOrWhiteSpace($MarketplaceName) -or $MarketplaceName -eq "*") {
    ""
  } else {
    " $(Quote-PowerShellLiteral $MarketplaceName)"
  }
  $upgradeCommand = "codex plugin marketplace upgrade$marketplaceArg"
  if ([string]::IsNullOrWhiteSpace($CodexHomePath)) {
    return $upgradeCommand
  }

  return "`$oldCodexHome = `$env:CODEX_HOME; try { `$env:CODEX_HOME = $(Quote-PowerShellLiteral $CodexHomePath); $upgradeCommand } finally { if (`$null -eq `$oldCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { `$env:CODEX_HOME = `$oldCodexHome } }"
}

function New-SourceScriptCommand([string]$SourceCheckoutRoot, [string]$RelativeScript, [string]$Arguments = $null) {
  if ([string]::IsNullOrWhiteSpace($SourceCheckoutRoot)) {
    return $null
  }

  $scriptPath = [System.IO.Path]::GetFullPath((Join-Path $SourceCheckoutRoot $RelativeScript))
  $command = "& $(Quote-PowerShellLiteral $scriptPath)"
  if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
    $command = "$command $Arguments"
  }

  return $command
}

function New-CurrentDiagnosticCommand([string]$Arguments = $null) {
  if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
    return $null
  }

  $scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
  $command = "& $(Quote-PowerShellLiteral $scriptPath)"
  if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
    $command = "$command $Arguments"
  }

  return $command
}

function New-CockpitCommand([string]$SourceCheckoutRoot) {
  if ([string]::IsNullOrWhiteSpace($SourceCheckoutRoot)) {
    return $null
  }

  $elixirRoot = [System.IO.Path]::GetFullPath((Join-Path $SourceCheckoutRoot "elixir"))
  return "Set-Location $(Quote-PowerShellLiteral $elixirRoot); mix sympp.cockpit --port 19998 --dashboard-origin http://127.0.0.1:19999"
}

function New-VerifyHttpMcpCommand([string]$SourceCheckoutRoot) {
  if ([string]::IsNullOrWhiteSpace($SourceCheckoutRoot)) {
    return $null
  }

  $sourceCheckoutRoot = [System.IO.Path]::GetFullPath($SourceCheckoutRoot)
  return New-SourceScriptCommand $sourceCheckoutRoot "scripts/smoke-sympp-mcp-http.ps1" "-RepoRoot $(Quote-PowerShellLiteral $sourceCheckoutRoot)"
}

function New-SourceCheckoutAction([string]$Code, [string]$Lane, [string]$Message, $SourceCheckout, [string]$Command) {
  if (-not [string]::IsNullOrWhiteSpace($Command)) {
    return New-ReadinessAction $Code $Lane $Message $Command
  }

  $note = if ($null -ne $SourceCheckout -and -not [string]::IsNullOrWhiteSpace([string]$SourceCheckout.note)) {
    [string]$SourceCheckout.note
  } else {
    "No Symphony++ source checkout could be inferred; rerun this doctor with -RepoRoot <path-to-symphony-plus-plus-checkout>."
  }

  return New-ReadinessAction $Code $Lane "$Message $note"
}

function Sanitize-CommandLine([string]$CommandLine) {
  if ([string]::IsNullOrWhiteSpace($CommandLine)) {
    return ""
  }

  $sanitized = $CommandLine
  $redactions = @(
    @{
      Pattern = '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s"'']+'
      Replacement = '${1}<redacted>'
    },
    @{
      Pattern = '(?i)(\bbearer\s+)[^\s"'']+'
      Replacement = '${1}<redacted>'
    },
    @{
      Pattern = '(?i)((?:--?|/)(?:api[-_]?key|token|secret|password|authorization|bearer)(?:\s+|=))(?:"[^"]*"|''[^'']*''|\S+)'
      Replacement = '${1}<redacted>'
    },
    @{
      Pattern = '(?i)(\b(?:api[-_]?key|token|secret|key|authorization|bearer|password)\b\s*[=:]\s*)(?:"[^"]*"|''[^'']*''|\S+)'
      Replacement = '${1}<redacted>'
    }
  )

  foreach ($redaction in $redactions) {
    $sanitized = $sanitized -replace $redaction.Pattern, $redaction.Replacement
  }

  $sanitized = $sanitized -replace "\s+", " "
  if ($sanitized.Length -gt 240) {
    return $sanitized.Substring(0, 240) + "...<truncated>"
  }

  return $sanitized
}

function Get-JsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  } catch {
    return [pscustomobject]@{
      __parse_error = $_.Exception.Message
    }
  }
}

function Get-JsonParseError($JsonObject) {
  if ($null -eq $JsonObject) {
    return $null
  }

  $property = $JsonObject.PSObject.Properties["__parse_error"]
  if ($property) {
    return [string]$property.Value
  }

  return $null
}

function Test-JsonProperty($JsonObject, [string]$Name) {
  if ($null -eq $JsonObject -or (Get-JsonParseError $JsonObject)) {
    return $false
  }

  return @($JsonObject.PSObject.Properties.Name) -contains $Name
}

function Get-McpShape($McpConfig) {
  if ($null -eq $McpConfig) {
    return "missing"
  }
  if (Get-JsonParseError $McpConfig) {
    return "parse_error"
  }

  $properties = @($McpConfig.PSObject.Properties.Name)
  if ($properties -contains "mcpServers") {
    return "wrapped_mcpServers"
  }
  if ($properties -contains "mcp_servers") {
    return "wrapped_mcp_servers"
  }

  return "direct_server_map"
}

function Get-McpServerMap($McpConfig) {
  if ($null -eq $McpConfig -or (Get-JsonParseError $McpConfig)) {
    return $null
  }

  $properties = @($McpConfig.PSObject.Properties.Name)
  if ($properties -contains "mcp_servers") {
    return $McpConfig.mcp_servers
  }
  if ($properties -contains "mcpServers") {
    return $McpConfig.mcpServers
  }

  return $McpConfig
}
function Test-LoopbackMcpUri([System.Uri]$Uri) {
  return $Uri.Scheme -eq "http" -and
    $Uri.AbsolutePath -eq "/mcp" -and
    ($Uri.Host -eq "127.0.0.1" -or $Uri.Host -eq "localhost" -or $Uri.Host -eq "::1" -or $Uri.Host -eq "[::1]")
}

function Get-HttpMcpReachabilityStatus($Server) {
  if ($null -eq $Server -or -not (@($Server.PSObject.Properties.Name) -contains "url")) {
    return "not_applicable"
  }

  try {
    $uri = [System.Uri]::new([string]$Server.url)
  } catch {
    return "invalid_url"
  }

  if (-not (Test-LoopbackMcpUri $uri)) {
    return "non_loopback_or_non_mcp_url"
  }

  try {
    $response = Invoke-WebRequest -Uri $uri.AbsoluteUri -Method Get -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop
    return "unexpected_http_status_$([int]$response.StatusCode)"
  } catch {
    $response = $_.Exception.Response
    if ($null -ne $response) {
      $statusCode = [int]$response.StatusCode
      if ($statusCode -eq 405) {
        return "mcp_endpoint_available"
      }

      return "unexpected_http_status_$statusCode"
    }

    return "unreachable"
  }
}

function Get-SymppMcpServerStatus($McpConfig) {
  $serverMap = Get-McpServerMap $McpConfig
  if ($null -eq $serverMap) {
    return "not_configured"
  }

  $server = $serverMap.symphony_plus_plus
  if ($null -eq $server) {
    return "missing"
  }
  if (@($server.PSObject.Properties.Name) -contains "url") {
    foreach ($stdioProperty in @("type", "command", "args", "cwd")) {
      if (@($server.PSObject.Properties.Name) -contains $stdioProperty) {
        return "invalid_mixed_http_stdio"
      }
    }

    try {
      $uri = [System.Uri]::new([string]$server.url)
    } catch {
      return "invalid_url"
    }

    if (-not (Test-LoopbackMcpUri $uri)) {
      return "invalid_url"
    }

    if ($server.url -eq "http://127.0.0.1:19998/mcp") {
      return "ok"
    }

    return "non_default_http_url"
  }
  if ($server.type -ne "stdio") {
    return "invalid_type"
  }
  if ($server.command -ne "cmd.exe") {
    return "unexpected_command"
  }
  if ($server.cwd -ne ".") {
    return "invalid_cwd"
  }

  $args = @($server.args)
  $hasCmdLaunch = @($args | Where-Object { [string]$_ -eq "/c" }).Count -gt 0
  $hasStartScript = @($args | Where-Object { [string]$_ -match "scripts[\\/]start-sympp-mcp\.cmd" }).Count -gt 0
  if (-not $hasCmdLaunch -or -not $hasStartScript) {
    return "invalid_args"
  }

  return "ok"
}

function Get-PluginPackageSummary([string]$Root, [string]$Label, [string]$PackageMarketplaceName) {
  $manifestPath = Join-Path $Root ".codex-plugin/plugin.json"
  $manifestExists = Test-Path -LiteralPath $manifestPath
  $manifest = Get-JsonFile $manifestPath
  $manifestParseError = Get-JsonParseError $manifest
  $manifestName = if ($manifest -and -not $manifestParseError) { [string]$manifest.name } else { $null }
  $manifestHasMcpServers = Test-JsonProperty $manifest "mcpServers"
  $manifestMcpServersValue = if ($manifestHasMcpServers) { [string]$manifest.mcpServers } else { $null }
  $mcpPath = if ($manifestHasMcpServers -and -not [string]::IsNullOrWhiteSpace($manifestMcpServersValue)) {
    [System.IO.Path]::GetFullPath((Join-Path $Root ([string]$manifest.mcpServers)))
  } else {
    Join-Path $Root ".mcp.json"
  }
  $rootMcpExists = Test-Path -LiteralPath (Join-Path $Root ".mcp.json")
  $mcp = Get-JsonFile $mcpPath
  $mcpParseError = Get-JsonParseError $mcp
  $serverMap = Get-McpServerMap $mcp
  $server = if ($null -ne $serverMap) { $serverMap.symphony_plus_plus } else { $null }
  $sourceHintPath = Join-Path $Root ".sympp-source-root"
  $sourceHint = if (Test-Path -LiteralPath $sourceHintPath) {
    (Get-Content -LiteralPath $sourceHintPath -Raw).Trim().TrimStart([char]0xFEFF)
  } else {
    $null
  }
  $artifactSourceRoot = Resolve-DiagnosticRuntimeArtifactSourceRoot $Root $sourceHint
  $artifactExpectedRevision = Resolve-DiagnosticRuntimeArtifactExpectedRevision $Root $artifactSourceRoot
  $artifactSourceFallbackAllowed = Test-DiagnosticRuntimeArtifactSourceFallbackAllowed $Root $artifactSourceRoot
  $mcpServerStatus = Get-SymppMcpServerStatus $mcp
  $isOptInMcpPackage = $manifestName -eq "symphony-plus-plus-mcp"
  $packageNameFromRoot = Split-Path (Split-Path $Root -Parent) -Leaf
  $isDefaultPackage = $manifestName -eq "symphony-plus-plus" -or $packageNameFromRoot -eq "symphony-plus-plus"
  $defaultPackageBundlesMcp = $isDefaultPackage -and (-not $isOptInMcpPackage) -and ($manifestHasMcpServers -or $rootMcpExists)
  $defaultPluginLifecycleStatus = if (-not $manifestExists) {
    "missing_manifest"
  } elseif ($manifestParseError) {
    "manifest_parse_error"
  } elseif ($manifestHasMcpServers -and $isOptInMcpPackage) {
    "opt_in_mcp_plugin_bundles_mcp"
  } elseif ($defaultPackageBundlesMcp) {
    "incompatible_default_plugin_bundles_mcp"
  } else {
    "skill_only"
  }

  [pscustomobject]@{
    label = $Label
    package_name = if ($manifestName) { $manifestName } else { Split-Path (Split-Path $Root -Parent) -Leaf }
    marketplace_name = $PackageMarketplaceName
    root = $Root
    exists = Test-Path -LiteralPath $Root
    manifest_exists = $manifestExists
    manifest_version = if ($manifest -and -not $manifestParseError) { [string]$manifest.version } else { $null }
    manifest_mcpServers_declared = $manifestHasMcpServers
    manifest_mcpServers = $manifestMcpServersValue
    manifest_parse_error = $manifestParseError
    default_plugin_lifecycle_status = $defaultPluginLifecycleStatus
    mcp_path_exists = Test-Path -LiteralPath $mcpPath
    mcp_shape = Get-McpShape $mcp
    mcp_parse_error = $mcpParseError
    reference_mcp_server_status = $mcpServerStatus
    http_mcp_reachability_status = Get-HttpMcpReachabilityStatus $server
    symphony_plus_plus_server = if (-not $manifestExists) { "missing_manifest" } elseif ($manifestParseError) { "manifest_parse_error" } elseif ($manifestHasMcpServers -and $isOptInMcpPackage) { $mcpServerStatus } elseif ($defaultPackageBundlesMcp) { "incompatible_default_plugin_bundles_mcp" } else { $mcpServerStatus }
    has_start_script = Test-Path -LiteralPath (Join-Path $Root "scripts/start-sympp-mcp.ps1")
    source_root_hint = $sourceHint
    runtime_artifact = Get-DiagnosticRuntimeArtifactStatus $Root $artifactExpectedRevision
    runtime_artifact_source_fallback_allowed = $artifactSourceFallbackAllowed
    package_fingerprint = Get-PluginPackageFingerprint $Root
  }
}

function Get-CompanionMcpSourcePackages([string]$DefaultPluginRoot) {
  $sourceSibling = Join-Path (Split-Path $DefaultPluginRoot -Parent) "symphony-plus-plus-mcp"
  if (Test-Path -LiteralPath (Join-Path $sourceSibling ".codex-plugin/plugin.json")) {
    $sourceSiblingPackage = Get-PluginPackageSummary $sourceSibling "source" "source"
    if ($sourceSiblingPackage.package_name -eq "symphony-plus-plus-mcp" -and -not [string]::IsNullOrWhiteSpace([string]$sourceSiblingPackage.manifest_version)) {
      return @($sourceSiblingPackage)
    }
  }

  $defaultCacheRoot = Split-Path $DefaultPluginRoot -Parent
  if ((Split-Path $defaultCacheRoot -Leaf) -ne "symphony-plus-plus") {
    return @()
  }

  $marketplaceRoot = Split-Path $defaultCacheRoot -Parent
  $companionCacheRoot = Join-Path $marketplaceRoot "symphony-plus-plus-mcp"
  $sameLabel = Split-Path $DefaultPluginRoot -Leaf
  $localManifestPath = Join-Path (Join-Path $companionCacheRoot "local") ".codex-plugin/plugin.json"
  $sameLabelManifestPath = Join-Path (Join-Path $companionCacheRoot $sameLabel) ".codex-plugin/plugin.json"
  $defaultGeneratedMarkerPath = Join-Path $DefaultPluginRoot ".sympp-generated-cache"
  $hasSameLabelCompanion = Test-Path -LiteralPath $sameLabelManifestPath
  $hasGeneratedDefaultMarker = Test-Path -LiteralPath $defaultGeneratedMarkerPath
  $hasLocalCompanion = Test-Path -LiteralPath $localManifestPath
  $localPackage = if ($hasLocalCompanion) {
    $candidatePackage = Get-PluginPackageSummary (Join-Path $companionCacheRoot "local") "source" "source"
    if ($candidatePackage.package_name -eq "symphony-plus-plus-mcp" -and -not [string]::IsNullOrWhiteSpace([string]$candidatePackage.manifest_version)) {
      $candidatePackage
    } else {
      $null
    }
  } else {
    $null
  }
  $sameLabelPackage = if ($hasSameLabelCompanion) {
    $candidatePackage = Get-PluginPackageSummary (Join-Path $companionCacheRoot $sameLabel) "source" "source"
    if ($candidatePackage.package_name -eq "symphony-plus-plus-mcp" -and -not [string]::IsNullOrWhiteSpace([string]$candidatePackage.manifest_version)) {
      $candidatePackage
    } else {
      $null
    }
  } else {
    $null
  }

  if ($null -eq $sameLabelPackage -and -not ($hasGeneratedDefaultMarker -and $null -ne $localPackage)) {
    return @()
  }

  $packages = @()
  if ($null -ne $localPackage -and (Test-LocalCompanionCanOverrideSameLabel $localPackage $sameLabelPackage)) {
    $packages += $localPackage
  }
  if ($null -ne $sameLabelPackage) {
    $packages += $sameLabelPackage
  }

  return $packages
}

function Get-InstalledDefaultPluginMarketplaceName([string]$DefaultPluginRoot) {
  $defaultCacheRoot = Split-Path $DefaultPluginRoot -Parent
  if ((Split-Path $defaultCacheRoot -Leaf) -ne "symphony-plus-plus") {
    return $null
  }

  return Split-Path (Split-Path $defaultCacheRoot -Parent) -Leaf
}

function Get-CurrentManifestVersionsByPackageName($SourcePackages) {
  $versions = @{}
  foreach ($package in @($SourcePackages)) {
    if (
      $null -ne $package -and
      -not [string]::IsNullOrWhiteSpace([string]$package.package_name) -and
      -not [string]::IsNullOrWhiteSpace([string]$package.manifest_version)
    ) {
      $packageName = [string]$package.package_name
      if (-not $versions.ContainsKey($packageName)) {
        $versions[$packageName] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
      }

      [void]$versions[$packageName].Add([string]$package.manifest_version)
    }
  }

  return $versions
}

function Compare-ManifestVersionStrings([string]$Left, [string]$Right) {
  if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
    return $null
  }

  $leftVersion = $null
  $rightVersion = $null
  if ([System.Version]::TryParse($Left, [ref]$leftVersion) -and [System.Version]::TryParse($Right, [ref]$rightVersion)) {
    return $leftVersion.CompareTo($rightVersion)
  }

  if ($Left.Equals($Right, [System.StringComparison]::OrdinalIgnoreCase)) {
    return 0
  }

  return $null
}

function Test-LocalCompanionCanOverrideSameLabel($LocalPackage, $SameLabelPackage) {
  if ($null -eq $SameLabelPackage) {
    return $true
  }

  $comparison = Compare-ManifestVersionStrings ([string]$LocalPackage.manifest_version) ([string]$SameLabelPackage.manifest_version)
  return $null -ne $comparison -and $comparison -ge 0
}

function Get-InstalledCompanionMcpVersionCandidatePackages($CachePackages, [string[]]$AllowedMarketplaces) {
  $packages = @(
    $CachePackages |
      Where-Object {
        $_.package_name -eq "symphony-plus-plus-mcp" -and
        $_.label -ne "local" -and
        -not [string]::IsNullOrWhiteSpace([string]$_.manifest_version) -and
        ($AllowedMarketplaces.Count -eq 0 -or $AllowedMarketplaces -contains $_.marketplace_name)
      }
  )
  if ($AllowedMarketplaces.Count -eq 0) {
    $distinctMarketplaces = @($packages | ForEach-Object { [string]$_.marketplace_name } | Sort-Object -Unique)
    if ($distinctMarketplaces.Count -gt 1) {
      return @()
    }
  }

  $distinctVersions = @($packages | ForEach-Object { [string]$_.manifest_version } | Sort-Object -Unique)
  if ($distinctVersions.Count -eq 1) {
    return $packages
  }

  return @()
}

function Test-CachePackageCanScopeProcesses($Package) {
  if ($Package.package_name -eq "symphony-plus-plus" -and $Package.default_plugin_lifecycle_status -eq "skill_only") {
    return $false
  }

  if ($Package.default_plugin_lifecycle_status -eq "incompatible_default_plugin_bundles_mcp") {
    return $Package.reference_mcp_server_status -eq "ok"
  }

  if ($Package.default_plugin_lifecycle_status -eq "opt_in_mcp_plugin_bundles_mcp") {
    return $Package.reference_mcp_server_status -eq "ok"
  }

  return $false
}

function Test-CachePackageIsCurrentForProcessScope($Package, $CurrentManifestVersionsByPackageName) {
  $currentManifestVersions = if ($null -ne $CurrentManifestVersionsByPackageName) {
    $CurrentManifestVersionsByPackageName[[string]$Package.package_name]
  } else {
    $null
  }

  if ($Package.label -eq "local") {
    if ($Package.package_name -ne "symphony-plus-plus-mcp") {
      return $true
    }

    return $null -ne $currentManifestVersions -and $currentManifestVersions.Contains([string]$Package.manifest_version)
  }

  if ($null -ne $currentManifestVersions -and $currentManifestVersions.Contains([string]$Package.label)) {
    return $true
  }

  return $false
}

function Test-VersionedOptInSuppressedByLocal($Package, $LocalPackagesByMarketplace) {
  if ($Package.package_name -ne "symphony-plus-plus-mcp" -or $Package.label -eq "local") {
    return $false
  }

  $marketplaceName = [string]$Package.marketplace_name
  if (-not $LocalPackagesByMarketplace.ContainsKey($marketplaceName)) {
    return $false
  }

  $localPackage = $LocalPackagesByMarketplace[$marketplaceName]
  $comparison = Compare-ManifestVersionStrings ([string]$localPackage.manifest_version) ([string]$Package.manifest_version)
  if ($null -ne $comparison -and $comparison -gt 0) {
    return $true
  }

  if ($null -ne $comparison -and $comparison -eq 0) {
    $localRoot = Normalize-ComparablePath $localPackage.source_root_hint
    $packageRoot = Normalize-ComparablePath $Package.source_root_hint
    return -not [string]::IsNullOrWhiteSpace($localRoot) -and $localRoot -eq $packageRoot
  }

  return $false
}

function Get-RepoRootFromCommand([string]$CommandLine) {
  if ([string]::IsNullOrWhiteSpace($CommandLine)) {
    return $null
  }

  $match = [regex]::Match($CommandLine, '--repo-root\s+(?:"([^"]+)"|(\S+))')
  if (-not $match.Success) {
    return $null
  }

  if ($match.Groups[1].Success) {
    return $match.Groups[1].Value.Trim().Trim('"').Trim("'")
  }

  return $match.Groups[2].Value.Trim().Trim('"').Trim("'")
}

function Test-ProcessMatchesAnyRepoRoot($Process, [string[]]$RepoRootFilters) {
  if ($RepoRootFilters.Count -eq 0) {
    return $false
  }

  $processRepoRoot = Normalize-ComparablePath (Get-RepoRootFromCommand $Process.CommandLine)
  return $processRepoRoot -and $RepoRootFilters -contains $processRepoRoot
}

function Find-AncestorLauncherProcessIds($Processes, $ProcessById, $LauncherProcessIds) {
  $found = [System.Collections.Generic.HashSet[int]]::new()

  foreach ($process in $Processes) {
    $parentProcessId = [int]$process.ParentProcessId
    $visited = [System.Collections.Generic.HashSet[int]]::new()
    while ($parentProcessId -and $visited.Add($parentProcessId)) {
      if ($LauncherProcessIds.Contains($parentProcessId)) {
        [void]$found.Add($parentProcessId)
        break
      }

      if (-not $ProcessById.ContainsKey($parentProcessId)) {
        break
      }

      $parent = $ProcessById[$parentProcessId]
      $parentProcessId = [int]$parent.ParentProcessId
    }
  }

  foreach ($processId in $found) {
    $processId
  }
}

function Get-PluginConfigSummary([string]$ConfigPath, [string]$MarketplaceName) {
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    return [pscustomobject]@{
      path = $ConfigPath
      exists = $false
      symphony_plugin_enabled = $null
      global_sympp_mcp_entry = $false
    }
  }

  $lines = @(Read-ConfigLines $ConfigPath)
  $entries = @()
  $sectionPattern = "^\s*\[\s*(?:plugins|`"plugins`"|'plugins')\s*\.\s*(?:`"(symphony-plus-plus(?:-mcp)?)@([^`"]+)`"|'(symphony-plus-plus(?:-mcp)?)@([^']+)')\s*\]\s*(?:#.*)?$"
  $dottedEnabledPattern = "^\s*(?:plugins|`"plugins`"|'plugins')\s*\.\s*(?:`"(symphony-plus-plus(?:-mcp)?)@([^`"]+)`"|'(symphony-plus-plus(?:-mcp)?)@([^']+)')\s*\.\s*(?:enabled|`"enabled`"|'enabled')\s*=\s*(true|false)\s*(?:#.*)?$"
  $rootInlinePattern = "^\s*(?:plugins|`"plugins`"|'plugins')\s*\.\s*(?:`"(symphony-plus-plus(?:-mcp)?)@([^`"]+)`"|'(symphony-plus-plus(?:-mcp)?)@([^']+)')\s*=\s*\{.*\}\s*(?:#.*)?$"
  $pluginsTableDottedEnabledPattern = "^\s*(?:`"(symphony-plus-plus(?:-mcp)?)@([^`"]+)`"|'(symphony-plus-plus(?:-mcp)?)@([^']+)')\s*\.\s*(?:enabled|`"enabled`"|'enabled')\s*=\s*(true|false)\s*(?:#.*)?$"
  $pluginsTableInlinePattern = "^\s*(?:`"(symphony-plus-plus(?:-mcp)?)@([^`"]+)`"|'(symphony-plus-plus(?:-mcp)?)@([^']+)')\s*=\s*\{.*\}\s*(?:#.*)?$"
  $dottedGlobalMcpPattern = '^\s*(?:mcp_servers|"mcp_servers"|''mcp_servers'')\s*\.\s*(?:symphony_plus_plus|"symphony_plus_plus"|''symphony_plus_plus'')\s*(?:\.|=)'
  $mcpServersTableEntryPattern = '^\s*(?:symphony_plus_plus|"symphony_plus_plus"|''symphony_plus_plus'')\s*(?:\.|=)'
  $pluginsRootSectionPattern = '^\s*\[\s*(?:plugins|"plugins"|''plugins'')\s*\]\s*(?:#.*)?$'
  $mcpServersRootSectionPattern = '^\s*\[\s*(?:mcp_servers|"mcp_servers"|''mcp_servers'')\s*\]\s*(?:#.*)?$'

  $globalSymppMcpEntry = $false
  $multilineState = $null
  $containerDepth = 0
  $insideTomlTable = $false
  $currentTomlTable = $null
  for ($index = 0; $index -lt $lines.Count; $index++) {
    $atTopLevel = [string]::IsNullOrWhiteSpace($multilineState) -and $containerDepth -eq 0
    $atRootTable = $atTopLevel -and -not $insideTomlTable

    if ($atTopLevel -and $lines[$index] -match '^\s*\[\s*(?:mcp_servers|"mcp_servers"|''mcp_servers'')\s*\.\s*(?:symphony_plus_plus|"symphony_plus_plus"|''symphony_plus_plus'')\s*\]\s*(?:#.*)?$') {
      $globalSymppMcpEntry = $true
    }
    if ($atRootTable -and $lines[$index] -match $dottedGlobalMcpPattern) {
      $globalSymppMcpEntry = $true
    }
    if ($atTopLevel -and $currentTomlTable -eq "mcp_servers" -and $lines[$index] -match $mcpServersTableEntryPattern) {
      $globalSymppMcpEntry = $true
    }

    if (($atRootTable -and $lines[$index] -match $dottedEnabledPattern) -or
        ($atTopLevel -and $currentTomlTable -eq "plugins" -and $lines[$index] -match $pluginsTableDottedEnabledPattern)) {
      $entryPluginName = if ($Matches[1]) { $Matches[1] } else { $Matches[3] }
      $entryMarketplaceName = if ($Matches[2]) { $Matches[2] } else { $Matches[4] }

      $entries += [pscustomobject]@{
        plugin_name = $entryPluginName
        marketplace_name = $entryMarketplaceName
        enabled = [System.Boolean]::Parse($Matches[5])
      }
    } elseif (($atRootTable -and $lines[$index] -match $rootInlinePattern) -or
              ($atTopLevel -and $currentTomlTable -eq "plugins" -and $lines[$index] -match $pluginsTableInlinePattern)) {
      $entryPluginName = if ($Matches[1]) { $Matches[1] } else { $Matches[3] }
      $entryMarketplaceName = if ($Matches[2]) { $Matches[2] } else { $Matches[4] }
      $enabledAssignment = Find-TomlBooleanKeyAssignment $lines[$index] "enabled" 1
      $entryEnabled = if ($null -ne $enabledAssignment) {
        [System.Boolean]::Parse($enabledAssignment.value)
      } else {
        $null
      }

      $entries += [pscustomobject]@{
        plugin_name = $entryPluginName
        marketplace_name = $entryMarketplaceName
        enabled = $entryEnabled
      }
    } elseif ($atTopLevel -and $lines[$index] -match $sectionPattern) {
      $entryPluginName = if ($Matches[1]) { $Matches[1] } else { $Matches[3] }
      $entryMarketplaceName = if ($Matches[2]) { $Matches[2] } else { $Matches[4] }
      $entryEnabled = $null
      $entryEnabledValues = New-Object 'System.Collections.Generic.List[bool]'
      $entryEnabledUnsupported = $false
      $sectionMultilineState = $null
      $sectionContainerDepth = 0
      for ($next = $index + 1; $next -lt $lines.Count; $next++) {
        $sectionAtTopLevel = [string]::IsNullOrWhiteSpace($sectionMultilineState) -and $sectionContainerDepth -eq 0

        if ($sectionAtTopLevel -and (Test-TomlTableHeaderLine $lines[$next])) {
          break
        }

        if ($sectionAtTopLevel -and $lines[$next] -match '^\s*(?:enabled|"enabled"|''enabled'')\s*=\s*(true|false)\s*(?:#.*)?$') {
          [void]$entryEnabledValues.Add([System.Boolean]::Parse($Matches[1]))
        } elseif ($sectionAtTopLevel -and $lines[$next] -match '^\s*(?:enabled|"enabled"|''enabled'')\s*=') {
          $entryEnabledUnsupported = $true
        }

        $nextSectionMultilineState = Update-TomlMultilineStringState $lines[$next] $sectionMultilineState
        $sectionContainerDepth = Update-TomlContainerDepthForLine $lines[$next] $sectionContainerDepth $sectionMultilineState $nextSectionMultilineState
        $sectionMultilineState = $nextSectionMultilineState
      }
      if ($entryEnabledValues.Count -eq 1 -and -not $entryEnabledUnsupported) {
        $entryEnabled = $entryEnabledValues[0]
      }

      $entries += [pscustomobject]@{
        plugin_name = $entryPluginName
        marketplace_name = $entryMarketplaceName
        enabled = $entryEnabled
      }
    }

    if ($atTopLevel -and (Test-TomlTableHeaderLine $lines[$index])) {
      $insideTomlTable = $true
      if ($lines[$index] -match $pluginsRootSectionPattern) {
        $currentTomlTable = "plugins"
      } elseif ($lines[$index] -match $mcpServersRootSectionPattern) {
        $currentTomlTable = "mcp_servers"
      } else {
        $currentTomlTable = $null
      }
    }
    $nextMultilineState = Update-TomlMultilineStringState $lines[$index] $multilineState
    $containerDepth = Update-TomlContainerDepthForLine $lines[$index] $containerDepth $multilineState $nextMultilineState
    $multilineState = $nextMultilineState
  }

  $selectedEntries = @(
    $entries |
      Where-Object {
        $MarketplaceName -eq "*" -or [string]$_.marketplace_name -eq [string]$MarketplaceName
      }
  )
  $enabledEntries = @($selectedEntries | Where-Object { $_.enabled -eq $true })
  $disabledEntries = @($selectedEntries | Where-Object { $_.enabled -eq $false })
  $selectedEnabled = if ($enabledEntries.Count -gt 0) {
    $true
  } elseif ($disabledEntries.Count -eq $selectedEntries.Count -and $selectedEntries.Count -gt 0) {
    $false
  } else {
    $null
  }

  [pscustomobject]@{
    path = $ConfigPath
    exists = $true
    symphony_plugin_enabled = $selectedEnabled
    symphony_plugin_entries = @($entries)
    symphony_default_plugin_enabled = Get-PluginEnabledFromEntries $entries "symphony-plus-plus" $MarketplaceName
    symphony_mcp_companion_plugin_enabled = Get-PluginEnabledFromEntries $entries "symphony-plus-plus-mcp" $MarketplaceName
    global_sympp_mcp_entry = $globalSymppMcpEntry
  }
}

function Get-PluginEnabledFromEntries($Entries, [string]$PluginName, [string]$MarketplaceName) {
  $matchingEntries = @(
    $Entries |
      Where-Object {
        $_.plugin_name -eq $PluginName -and
        ($MarketplaceName -eq "*" -or $_.marketplace_name -eq $MarketplaceName)
      }
  )

  if (@($matchingEntries | Where-Object { $_.enabled -eq $true }).Count -gt 0) {
    return $true
  }
  if (@($matchingEntries | Where-Object { $_.enabled -eq $false }).Count -gt 0) {
    return $false
  }

  return $null
}

function New-Utf8NoBomEncoding {
  return (New-Object System.Text.UTF8Encoding $false)
}

function New-StrictUtf8NoBomEncoding {
  return (New-Object System.Text.UTF8Encoding $false, $true)
}

function New-Utf8BomEncoding {
  return (New-Object System.Text.UTF8Encoding $true, $true)
}

function Get-SystemAnsiEncoding {
  try {
    [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
  } catch {
  }

  return [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
}

function Get-ConfigTextEncoding([string]$ConfigPath) {
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    return New-Utf8NoBomEncoding
  }

  $bytes = [System.IO.File]::ReadAllBytes($ConfigPath)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    return New-Utf8BomEncoding
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    return (New-Object System.Text.UnicodeEncoding $false, $true, $true)
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
    return (New-Object System.Text.UnicodeEncoding $true, $true, $true)
  }

  $utf8 = New-StrictUtf8NoBomEncoding
  try {
    [void]$utf8.GetString($bytes)
    return $utf8
  } catch {
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
      return Get-SystemAnsiEncoding
    }

    throw "Codex config is not valid UTF-8 and has no recognized Unicode BOM; refusing to rewrite it."
  }
}

function Read-ConfigLines([string]$ConfigPath) {
  $lines = [System.IO.File]::ReadAllLines($ConfigPath, (Get-ConfigTextEncoding $ConfigPath))
  if ($lines.Count -gt 0) {
    $lines[0] = $lines[0].TrimStart([char]0xFEFF)
  }

  return $lines
}

function New-TimestampedBackupPath([string]$Path) {
  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $backupPath = "$Path.sympp-backup-$timestamp"
  $suffix = 1
  while (Test-Path -LiteralPath $backupPath) {
    $backupPath = "$Path.sympp-backup-$timestamp.$suffix"
    $suffix += 1
  }

  return $backupPath
}

function Copy-CodexConfigBackup([string]$ConfigPath) {
  $backupPath = New-TimestampedBackupPath $ConfigPath
  Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force:$false
  return $backupPath
}

function Write-ConfigLines([string]$ConfigPath, [System.Collections.Generic.List[string]]$Lines) {
  $parent = Split-Path $ConfigPath -Parent
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
    [void](New-Item -ItemType Directory -Path $parent -Force)
  }

  [System.IO.File]::WriteAllLines($ConfigPath, [string[]]$Lines.ToArray(), (Get-ConfigTextEncoding $ConfigPath))
}

function Find-UnescapedSequence([string]$Line, [string]$Sequence, [int]$StartIndex) {
  $index = $Line.IndexOf($Sequence, $StartIndex, [System.StringComparison]::Ordinal)
  while ($index -ge 0) {
    $backslashCount = 0
    for ($cursor = $index - 1; $cursor -ge 0 -and $Line[$cursor] -eq '\'; $cursor--) {
      $backslashCount += 1
    }

    if (($backslashCount % 2) -eq 0) {
      return $index
    }

    $index = $Line.IndexOf($Sequence, $index + $Sequence.Length, [System.StringComparison]::Ordinal)
  }

  return -1
}

function Update-TomlMultilineStringState([string]$Line, [string]$State) {
  $index = 0
  $stateValue = $State

  while ($index -lt $Line.Length) {
    if ($stateValue -eq "basic") {
      $endIndex = Find-UnescapedSequence $Line '"""' $index
      if ($endIndex -lt 0) {
        return $stateValue
      }

      $index = $endIndex + 3
      $stateValue = $null
      continue
    }

    if ($stateValue -eq "literal") {
      $endIndex = $Line.IndexOf("'''", $index, [System.StringComparison]::Ordinal)
      if ($endIndex -lt 0) {
        return $stateValue
      }

      $index = $endIndex + 3
      $stateValue = $null
      continue
    }

    $char = $Line[$index]
    if ($char -eq "#") {
      break
    }

    if ($index + 2 -lt $Line.Length -and $Line.Substring($index, 3) -eq '"""') {
      $stateValue = "basic"
      $index += 3
      continue
    }

    if ($index + 2 -lt $Line.Length -and $Line.Substring($index, 3) -eq "'''") {
      $stateValue = "literal"
      $index += 3
      continue
    }

    if ($char -eq '"') {
      $index += 1
      while ($index -lt $Line.Length) {
        if ($Line[$index] -eq '\') {
          $index += 2
          continue
        }

        if ($Line[$index] -eq '"') {
          $index += 1
          break
        }

        $index += 1
      }
      continue
    }

    if ($char -eq "'") {
      $index += 1
      while ($index -lt $Line.Length) {
        if ($Line[$index] -eq "'") {
          $index += 1
          break
        }

        $index += 1
      }
      continue
    }

    $index += 1
  }

  return $stateValue
}

function Test-TomlTableHeaderLine([string]$Line) {
  $keySegment = '(?:"(?:[^"\\]|\\.)*"|''[^'']*''|[A-Za-z0-9_-]+)'
  return $Line -match "^\s*\[\[?\s*$keySegment(?:\s*\.\s*$keySegment)*\s*\]\]?\s*(?:#.*)?$"
}

function Test-TomlInlineKeyStart([string]$Line, [int]$Index) {
  $cursor = $Index - 1
  while ($cursor -ge 0 -and [char]::IsWhiteSpace($Line[$cursor])) {
    $cursor -= 1
  }

  if ($cursor -lt 0) {
    return $true
  }

  return $Line[$cursor] -eq "{" -or $Line[$cursor] -eq ","
}

function Find-TomlBooleanKeyAssignment([string]$Line, [string]$KeyName, [int]$TargetDepth = 0) {
  $index = 0
  $depthValue = 0
  $escapedKeyName = [regex]::Escape($KeyName)
  $keyToken = "(?:$escapedKeyName|`"$escapedKeyName`"|'$escapedKeyName')"

  while ($index -lt $Line.Length) {
    $char = $Line[$index]
    if ($char -eq "#") {
      break
    }

    if ($index + 2 -lt $Line.Length -and $Line.Substring($index, 3) -eq '"""') {
      $endIndex = Find-UnescapedSequence $Line '"""' ($index + 3)
      if ($endIndex -lt 0) {
        break
      }

      $index = $endIndex + 3
      continue
    }

    if ($index + 2 -lt $Line.Length -and $Line.Substring($index, 3) -eq "'''") {
      $endIndex = $Line.IndexOf("'''", $index + 3, [System.StringComparison]::Ordinal)
      if ($endIndex -lt 0) {
        break
      }

      $index = $endIndex + 3
      continue
    }

    if ($char -eq '"') {
      $index += 1
      while ($index -lt $Line.Length) {
        if ($Line[$index] -eq '\') {
          $index += 2
          continue
        }

        if ($Line[$index] -eq '"') {
          $index += 1
          break
        }

        $index += 1
      }
      continue
    }

    if ($char -eq "'") {
      $index += 1
      while ($index -lt $Line.Length) {
        if ($Line[$index] -eq "'") {
          $index += 1
          break
        }

        $index += 1
      }
      continue
    }

    $match = if ($depthValue -eq $TargetDepth -and (Test-TomlInlineKeyStart $Line $index)) {
      [regex]::Match($Line.Substring($index), "^(\s*$keyToken\s*=\s*)(true|false)(?=\b)")
    } else {
      [System.Text.RegularExpressions.Match]::Empty
    }
    if ($match.Success) {
      return [pscustomobject]@{
        value = $match.Groups[2].Value
        value_start = $index + $match.Groups[2].Index
        value_length = $match.Groups[2].Length
      }
    }

    if ($char -eq "[" -or $char -eq "{") {
      $depthValue += 1
    } elseif ($char -eq "]" -or $char -eq "}") {
      if ($depthValue -gt 0) {
        $depthValue -= 1
      }
    }

    $index += 1
  }

  return $null
}

function Update-TomlContainerDepth([string]$Line, [int]$Depth) {
  $index = 0
  $depthValue = $Depth

  while ($index -lt $Line.Length) {
    $char = $Line[$index]
    if ($char -eq "#") {
      break
    }

    if ($index + 2 -lt $Line.Length -and $Line.Substring($index, 3) -eq '"""') {
      $endIndex = Find-UnescapedSequence $Line '"""' ($index + 3)
      if ($endIndex -lt 0) {
        break
      }

      $index = $endIndex + 3
      continue
    }

    if ($index + 2 -lt $Line.Length -and $Line.Substring($index, 3) -eq "'''") {
      $endIndex = $Line.IndexOf("'''", $index + 3, [System.StringComparison]::Ordinal)
      if ($endIndex -lt 0) {
        break
      }

      $index = $endIndex + 3
      continue
    }

    if ($char -eq '"') {
      $index += 1
      while ($index -lt $Line.Length) {
        if ($Line[$index] -eq '\') {
          $index += 2
          continue
        }

        if ($Line[$index] -eq '"') {
          $index += 1
          break
        }

        $index += 1
      }
      continue
    }

    if ($char -eq "'") {
      $index += 1
      while ($index -lt $Line.Length) {
        if ($Line[$index] -eq "'") {
          $index += 1
          break
        }

        $index += 1
      }
      continue
    }

    if ($char -eq "[" -or $char -eq "{") {
      $depthValue += 1
    } elseif ($char -eq "]" -or $char -eq "}") {
      if ($depthValue -gt 0) {
        $depthValue -= 1
      }
    }

    $index += 1
  }

  return $depthValue
}

function Update-TomlContainerDepthForLine([string]$Line, [int]$Depth, [string]$PreviousMultilineState, [string]$NextMultilineState) {
  if ([string]::IsNullOrWhiteSpace($PreviousMultilineState)) {
    return Update-TomlContainerDepth $Line $Depth
  }

  if (-not [string]::IsNullOrWhiteSpace($NextMultilineState)) {
    return $Depth
  }

  $endIndex = if ($PreviousMultilineState -eq "basic") {
    Find-UnescapedSequence $Line '"""' 0
  } else {
    $Line.IndexOf("'''", 0, [System.StringComparison]::Ordinal)
  }

  if ($endIndex -lt 0) {
    return $Depth
  }

  return Update-TomlContainerDepth $Line.Substring($endIndex + 3) $Depth
}

function Set-PluginEnabledInConfig([string]$ConfigPath, [string]$PluginKey) {
  $configExisted = Test-Path -LiteralPath $ConfigPath
  $sectionHeader = "[plugins.`"$PluginKey`"]"
  $lineList = New-Object 'System.Collections.Generic.List[string]'

  if ($configExisted) {
    foreach ($line in @(Read-ConfigLines $ConfigPath)) {
      [void]$lineList.Add([string]$line)
    }
  }

  if (-not $configExisted) {
    [void]$lineList.Add($sectionHeader)
    [void]$lineList.Add("enabled = true")
    Write-ConfigLines $ConfigPath $lineList

    return [pscustomobject]@{
      status = "created_config"
      changed = $true
      backup_path = $null
      config_existed = $false
      plugin_key = $PluginKey
    }
  }

  $escapedPluginKey = [regex]::Escape($PluginKey)
  $sectionPattern = "^\s*\[\s*(?:plugins|`"plugins`"|'plugins')\s*\.\s*(?:`"$escapedPluginKey`"|'$escapedPluginKey')\s*\]\s*(?:#.*)?$"
  $dottedEnabledPattern = "^\s*(?:plugins|`"plugins`"|'plugins')\s*\.\s*(?:`"$escapedPluginKey`"|'$escapedPluginKey')\s*\.\s*(?:enabled|`"enabled`"|'enabled')\s*=\s*(true|false)\s*(?:#.*)?$"
  $rootInlinePattern = "^\s*(?:plugins|`"plugins`"|'plugins')\s*\.\s*(?:`"$escapedPluginKey`"|'$escapedPluginKey')\s*=\s*\{.*\}\s*(?:#.*)?$"
  $pluginsTableDottedEnabledPattern = "^\s*(?:`"$escapedPluginKey`"|'$escapedPluginKey')\s*\.\s*(?:enabled|`"enabled`"|'enabled')\s*=\s*(true|false)\s*(?:#.*)?$"
  $pluginsTableInlinePattern = "^\s*(?:`"$escapedPluginKey`"|'$escapedPluginKey')\s*=\s*\{.*\}\s*(?:#.*)?$"
  $pluginsRootSectionPattern = '^\s*\[\s*(?:plugins|"plugins"|''plugins'')\s*\]\s*(?:#.*)?$'
  $sectionIndices = New-Object 'System.Collections.Generic.List[int]'
  $dottedEnabledIndices = New-Object 'System.Collections.Generic.List[int]'
  $inlineEntryIndices = New-Object 'System.Collections.Generic.List[int]'
  $multilineState = $null
  $containerDepth = 0
  $insideTomlTable = $false
  $currentTomlTable = $null
  for ($index = 0; $index -lt $lineList.Count; $index++) {
    $atTopLevel = [string]::IsNullOrWhiteSpace($multilineState) -and $containerDepth -eq 0
    $atRootTable = $atTopLevel -and -not $insideTomlTable

    if ($atTopLevel -and $lineList[$index] -match $sectionPattern) {
      [void]$sectionIndices.Add($index)
    } elseif (($atRootTable -and $lineList[$index] -match $dottedEnabledPattern) -or
              ($atTopLevel -and $currentTomlTable -eq "plugins" -and $lineList[$index] -match $pluginsTableDottedEnabledPattern)) {
      [void]$dottedEnabledIndices.Add($index)
    } elseif (($atRootTable -and $lineList[$index] -match $rootInlinePattern) -or
              ($atTopLevel -and $currentTomlTable -eq "plugins" -and $lineList[$index] -match $pluginsTableInlinePattern)) {
      [void]$inlineEntryIndices.Add($index)
    }
    if ($atTopLevel -and (Test-TomlTableHeaderLine $lineList[$index])) {
      $insideTomlTable = $true
      if ($lineList[$index] -match $pluginsRootSectionPattern) {
        $currentTomlTable = "plugins"
      } else {
        $currentTomlTable = $null
      }
    }
    $nextMultilineState = Update-TomlMultilineStringState $lineList[$index] $multilineState
    $containerDepth = Update-TomlContainerDepthForLine $lineList[$index] $containerDepth $multilineState $nextMultilineState
    $multilineState = $nextMultilineState
  }

  if ($sectionIndices.Count -gt 1) {
    throw "Codex config contains multiple [$sectionHeader] sections; refusing ambiguous mutation."
  }
  if ($dottedEnabledIndices.Count -gt 1) {
    throw "Codex config contains multiple dotted enabled entries for [$sectionHeader]; refusing ambiguous mutation."
  }
  if ($inlineEntryIndices.Count -gt 1) {
    throw "Codex config contains multiple inline table entries for [$sectionHeader]; refusing ambiguous mutation."
  }
  if ($sectionIndices.Count + $dottedEnabledIndices.Count + $inlineEntryIndices.Count -gt 1) {
    throw "Codex config contains multiple entries for [$sectionHeader]; refusing ambiguous mutation."
  }

  $status = $null
  if ($inlineEntryIndices.Count -eq 1) {
    $inlineIndex = $inlineEntryIndices[0]
    $enabledAssignment = Find-TomlBooleanKeyAssignment $lineList[$inlineIndex] "enabled" 1
    if ($null -eq $enabledAssignment) {
      throw "Target plugin inline table contains no supported enabled = true/false entry; rewrite it as a plugin section or dotted enabled key before enabling."
    }

    if ($enabledAssignment.value -eq "true") {
      return [pscustomobject]@{
        status = "already_enabled"
        changed = $false
        backup_path = $null
        config_existed = $true
        plugin_key = $PluginKey
      }
    }

    $lineList[$inlineIndex] = $lineList[$inlineIndex].Remove($enabledAssignment.value_start, $enabledAssignment.value_length).Insert($enabledAssignment.value_start, "true")
    $status = "enabled_existing_inline_table"
  } elseif ($dottedEnabledIndices.Count -eq 1) {
    $enabledIndex = $dottedEnabledIndices[0]
    if ($lineList[$enabledIndex] -match "^\s*(?:plugins|`"plugins`"|'plugins')\s*\.\s*(?:`"$escapedPluginKey`"|'$escapedPluginKey')\s*\.\s*(?:enabled|`"enabled`"|'enabled')\s*=\s*true\s*(?:#.*)?$" -or
        $lineList[$enabledIndex] -match "^\s*(?:`"$escapedPluginKey`"|'$escapedPluginKey')\s*\.\s*(?:enabled|`"enabled`"|'enabled')\s*=\s*true\s*(?:#.*)?$") {
      return [pscustomobject]@{
        status = "already_enabled"
        changed = $false
        backup_path = $null
        config_existed = $true
        plugin_key = $PluginKey
      }
    }

    if ($lineList[$enabledIndex] -match "^(\s*(?:plugins|`"plugins`"|'plugins')\s*\.\s*(?:`"$escapedPluginKey`"|'$escapedPluginKey')\s*\.\s*(?:enabled|`"enabled`"|'enabled')\s*=\s*)false(\s*(?:#.*)?)$") {
      $lineList[$enabledIndex] = "$($Matches[1])true$($Matches[2])"
    } elseif ($lineList[$enabledIndex] -match "^(\s*(?:`"$escapedPluginKey`"|'$escapedPluginKey')\s*\.\s*(?:enabled|`"enabled`"|'enabled')\s*=\s*)false(\s*(?:#.*)?)$") {
      $lineList[$enabledIndex] = "$($Matches[1])true$($Matches[2])"
    } else {
      $lineList[$enabledIndex] = "plugins.`"$PluginKey`".enabled = true"
    }
    $status = "enabled_existing_dotted_key"
  } elseif ($sectionIndices.Count -eq 0) {
    if ($lineList.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lineList[$lineList.Count - 1])) {
      [void]$lineList.Add("")
    }
    [void]$lineList.Add($sectionHeader)
    [void]$lineList.Add("enabled = true")
    $status = "added_section"
  } else {
    $sectionIndex = $sectionIndices[0]
    $sectionEnd = $lineList.Count
    $multilineState = $null
    $containerDepth = 0
    for ($index = $sectionIndex + 1; $index -lt $lineList.Count; $index++) {
      if ([string]::IsNullOrWhiteSpace($multilineState) -and $containerDepth -eq 0 -and (Test-TomlTableHeaderLine $lineList[$index])) {
        $sectionEnd = $index
        break
      }
      $nextMultilineState = Update-TomlMultilineStringState $lineList[$index] $multilineState
      $containerDepth = Update-TomlContainerDepthForLine $lineList[$index] $containerDepth $multilineState $nextMultilineState
      $multilineState = $nextMultilineState
    }

    $enabledIndices = New-Object 'System.Collections.Generic.List[int]'
    $multilineState = $null
    $containerDepth = 0
    for ($index = $sectionIndex + 1; $index -lt $sectionEnd; $index++) {
      if (-not [string]::IsNullOrWhiteSpace($multilineState)) {
        $nextMultilineState = Update-TomlMultilineStringState $lineList[$index] $multilineState
        $containerDepth = Update-TomlContainerDepthForLine $lineList[$index] $containerDepth $multilineState $nextMultilineState
        $multilineState = $nextMultilineState
        continue
      }

      if ($containerDepth -eq 0 -and $lineList[$index] -match '^\s*(?:enabled|"enabled"|''enabled'')\s*=\s*(true|false)\s*(?:#.*)?$') {
        [void]$enabledIndices.Add($index)
      } elseif ($containerDepth -eq 0 -and $lineList[$index] -match '^\s*(?:enabled|"enabled"|''enabled'')\s*=') {
        throw "Target plugin section contains an unsupported enabled value; expected true or false."
      }
      $nextMultilineState = Update-TomlMultilineStringState $lineList[$index] $multilineState
      $containerDepth = Update-TomlContainerDepthForLine $lineList[$index] $containerDepth $multilineState $nextMultilineState
      $multilineState = $nextMultilineState
    }

    if ($enabledIndices.Count -gt 1) {
      throw "Target plugin section contains multiple enabled entries; refusing ambiguous mutation."
    }

    if ($enabledIndices.Count -eq 0) {
      $lineList.Insert($sectionIndex + 1, "enabled = true")
      $status = "added_enabled"
    } else {
      $enabledIndex = $enabledIndices[0]
      if ($lineList[$enabledIndex] -match '^\s*(?:enabled|"enabled"|''enabled'')\s*=\s*true\s*(?:#.*)?$') {
        return [pscustomobject]@{
          status = "already_enabled"
          changed = $false
          backup_path = $null
          config_existed = $true
          plugin_key = $PluginKey
        }
      }

      if ($lineList[$enabledIndex] -match '^(\s*(?:enabled|"enabled"|''enabled'')\s*=\s*)false(\s*(?:#.*)?)$') {
        $lineList[$enabledIndex] = "$($Matches[1])true$($Matches[2])"
      } else {
        $lineList[$enabledIndex] = "enabled = true"
      }
      $status = "enabled_existing_section"
    }
  }

  $backupPath = Copy-CodexConfigBackup $ConfigPath
  Write-ConfigLines $ConfigPath $lineList

  return [pscustomobject]@{
    status = $status
    changed = $true
    backup_path = $backupPath
    config_existed = $true
    plugin_key = $PluginKey
  }
}

function Format-ReadinessActions($Actions) {
  $lines = @(
    @($Actions) |
      ForEach-Object {
        $line = "[$($_.code)] $($_.message)"
        if ($_.PSObject.Properties["command"]) {
          $line = "$line Command: $($_.command)"
        }
        $line
      }
  )

  if ($lines.Count -eq 0) {
    return "Run the doctor again with -Doctor for the next action."
  }

  return ($lines -join " ")
}

function Invoke-McpCompanionEnable($Summary, [string]$RequestedMarketplaceName, [string]$CodexHomePath) {
  if (Test-DefaultCodexHome $CodexHomePath) {
    throw "Refusing to enable symphony-plus-plus-mcp in the default Codex home. Rerun with -CodexHome <dedicated-symphony-plus-plus-codex-home>."
  }

  if (Test-ActivationMarketplaceAmbiguous $Summary.installed_cache $RequestedMarketplaceName "symphony-plus-plus-mcp") {
    throw "Multiple symphony-plus-plus-mcp plugin marketplaces are installed; rerun with -MarketplaceName <marketplace> before enabling the MCP companion."
  }

  if (Test-CrossActivationMarketplacePairingAmbiguous $Summary.installed_cache $RequestedMarketplaceName) {
    throw "The skill-only and MCP companion packages resolve to different marketplaces in wildcard mode; rerun with -MarketplaceName <marketplace> before enabling the MCP companion."
  }

  if ($Summary.codex_config.global_sympp_mcp_entry -eq $true) {
    throw "Codex config already contains [mcp_servers.symphony_plus_plus]. Remove or relocate that global MCP entry before enabling the plugin companion in this config."
  }

  $companionPackage = Get-PreferredActivationPackage $Summary.installed_cache "symphony-plus-plus-mcp" $RequestedMarketplaceName
  if (-not (Test-McpCompanionPackageReady $companionPackage)) {
    $nextActions = Format-ReadinessActions $Summary.readiness.next_actions
    throw "Cannot enable symphony-plus-plus-mcp because the companion cache or manifest is missing or invalid. Doctor next action: $nextActions"
  }

  if (Test-PackageFreshnessStale $Summary.readiness.workrequest_mcp.cache_freshness) {
    $nextActions = Format-ReadinessActions $Summary.readiness.next_actions
    throw "Cannot enable symphony-plus-plus-mcp because the companion cache is stale. Doctor next action: $nextActions"
  }

  $marketplaceName = [string]$companionPackage.marketplace_name
  if ([string]::IsNullOrWhiteSpace($marketplaceName) -or $marketplaceName -eq "*") {
    throw "Cannot determine the target marketplace for symphony-plus-plus-mcp; rerun with -MarketplaceName <marketplace>."
  }

  $enabledOtherCompanionEntries = @(
    $Summary.codex_config.symphony_plugin_entries |
      Where-Object {
        $_.plugin_name -eq "symphony-plus-plus-mcp" -and
        $_.enabled -eq $true -and
        [string]$_.marketplace_name -ne $marketplaceName
      }
  )
  if ($enabledOtherCompanionEntries.Count -gt 0) {
    throw "Another symphony-plus-plus-mcp marketplace is already enabled in this Codex config. Disable or relocate that entry before enabling $marketplaceName."
  }

  $pluginKey = Get-ActivationConfigKey "symphony-plus-plus-mcp" $marketplaceName
  $configPath = Join-Path $CodexHomePath "config.toml"
  $mutation = Set-PluginEnabledInConfig $configPath $pluginKey
  $sourceRoot = if ($null -ne $Summary.source_checkout) { [string]$Summary.source_checkout.root } else { $null }
  $smokeCommand = New-VerifyHttpMcpCommand $sourceRoot
  if ([string]::IsNullOrWhiteSpace($smokeCommand)) {
    $smokeCommand = "Set-Location <path-to-symphony-plus-plus-checkout>; .\scripts\smoke-sympp-mcp-http.ps1 -RepoRoot <path-to-symphony-plus-plus-checkout>"
  }

  return [pscustomobject]@{
    status = $mutation.status
    changed = $mutation.changed
    codex_home = $CodexHomePath
    config_path = $configPath
    backup_path = $mutation.backup_path
    plugin_key = $pluginKey
    marketplace_name = $marketplaceName
    companion_cache_label = $companionPackage.label
    companion_cache_lifecycle = $companionPackage.default_plugin_lifecycle_status
    companion_reference_mcp_server_status = $companionPackage.reference_mcp_server_status
    companion_http_mcp_reachability_status = $companionPackage.http_mcp_reachability_status
    restart_action = "Restart or reload the dedicated Symphony++ MCP Codex session so the plugin launcher starts the managed backend/dashboard before the model starts."
    smoke_command = $smokeCommand
    boundary = "Keep symphony-plus-plus-mcp out of generic worker, worker_smart, review-suite, and codex review configs; use a dedicated S++ MCP-enabled config/session instead."
  }
}

function Write-McpCompanionEnableSummary($Result) {
  Write-Host "Symphony++ MCP companion enable"
  Write-Host "  status: $($Result.status)"
  Write-Host "  changed: $($Result.changed)"
  Write-Host "  codex_home: $($Result.codex_home)"
  Write-Host "  config: $($Result.config_path)"
  Write-Host "  backup: $(if ($Result.backup_path) { $Result.backup_path } else { 'none' })"
  Write-Host "  plugin key: $($Result.plugin_key)"
  Write-Host "  companion cache: $($Result.companion_cache_label) / $($Result.companion_cache_lifecycle)"
  Write-Host "  server: $($Result.companion_reference_mcp_server_status)"
  Write-Host "  endpoint: $($Result.companion_http_mcp_reachability_status)"
  Write-Host ""
  Write-Host "Next steps:"
  Write-Host "  - $($Result.restart_action)"
  Write-Host "  - Optional: verify the local HTTP MCP daemon after the Codex session starts:"
  Write-Host "    $($Result.smoke_command)"
  Write-Host ""
  Write-Host "Boundary: $($Result.boundary)"
}

function New-ReadinessAction([string]$Code, [string]$Lane, [string]$Message, [string]$Command = $null) {
  $action = [ordered]@{
    code = $Code
    lane = $Lane
    message = $Message
  }
  if (-not [string]::IsNullOrWhiteSpace($Command)) {
    $action["command"] = $Command
  }

  return [pscustomobject]$action
}

function New-ReadinessWarning([string]$Code, [string]$Message) {
  return [pscustomobject]@{
    code = $Code
    message = $Message
  }
}

function Get-ActivationConfigKey([string]$PluginName, [string]$MarketplaceName) {
  if ([string]::IsNullOrWhiteSpace($MarketplaceName) -or $MarketplaceName -eq "*") {
    return "$PluginName@<marketplace>"
  }

  return "$PluginName@$MarketplaceName"
}

function Test-ActivationMarketplaceAmbiguous($CachePackages, [string]$MarketplaceName, [string]$PackageName = $null) {
  if ($MarketplaceName -ne "*") {
    return $false
  }

  $marketplaces = @(
    $CachePackages |
      Where-Object {
        if ([string]::IsNullOrWhiteSpace($PackageName)) {
          $SymppPluginPackageNames -contains $_.package_name
        } else {
          $_.package_name -eq $PackageName
        }
      } |
      ForEach-Object { [string]$_.marketplace_name } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Sort-Object -Unique
  )

  return $marketplaces.Count -gt 1
}

function Get-PreferredActivationPackage($CachePackages, [string]$PackageName, [string]$MarketplaceName) {
  $packages = @(
    $CachePackages |
      Where-Object {
        $_.package_name -eq $PackageName -and
        ($MarketplaceName -eq "*" -or $_.marketplace_name -eq $MarketplaceName)
      } |
      ForEach-Object {
        $isReady = if ($PackageName -eq "symphony-plus-plus") {
          Test-DefaultPackageReady $_
        } elseif ($PackageName -eq "symphony-plus-plus-mcp") {
          Test-McpCompanionPackageReady $_
        } else {
          $false
        }
        $readyPriority = if ($isReady) { 0 } else { 1 }
        $priority = if ($_.label -eq "local") {
          0
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$_.manifest_version) -and $_.label -eq $_.manifest_version) {
          1
        } else {
          2
        }
        $parsedVersion = $null
        $versionSortKey = if ([System.Version]::TryParse([string]$_.manifest_version, [ref]$parsedVersion)) {
          $parsedVersion
        } else {
          [System.Version]::new(0, 0)
        }

        [pscustomobject]@{
          ready_priority = $readyPriority
          priority = $priority
          version_sort_key = $versionSortKey
          package = $_
        }
      } |
      Sort-Object ready_priority, priority, @{ Expression = { [string]$_.package.marketplace_name } }, @{ Expression = { $_.version_sort_key }; Descending = $true }, @{ Expression = { [string]$_.package.label }; Descending = $true }
  )

  if ($packages.Count -eq 0) {
    return $null
  }

  return $packages[0].package
}

function Test-CrossActivationMarketplacePairingAmbiguous($CachePackages, [string]$MarketplaceName) {
  if ($MarketplaceName -ne "*") {
    return $false
  }

  if ((Test-ActivationMarketplaceAmbiguous $CachePackages $MarketplaceName "symphony-plus-plus") -or
      (Test-ActivationMarketplaceAmbiguous $CachePackages $MarketplaceName "symphony-plus-plus-mcp")) {
    return $false
  }

  $defaultPackage = Get-PreferredActivationPackage $CachePackages "symphony-plus-plus" $MarketplaceName
  $companionPackage = Get-PreferredActivationPackage $CachePackages "symphony-plus-plus-mcp" $MarketplaceName
  return $null -ne $defaultPackage -and
    $null -ne $companionPackage -and
    [string]$defaultPackage.marketplace_name -ne [string]$companionPackage.marketplace_name
}

function Get-PreferredActivationSourceHintPackage($CachePackages, [string]$PackageName, [string]$MarketplaceName) {
  $packages = @(
    $CachePackages |
      Where-Object {
        $_.package_name -eq $PackageName -and
        ($MarketplaceName -eq "*" -or $_.marketplace_name -eq $MarketplaceName) -and
        (Test-PackageCanProvideSourceRootHint $_) -and
        (Test-SourceCheckoutRoot (Resolve-OptionalFullPath $_.source_root_hint))
      } |
      ForEach-Object {
        $priority = if ($_.label -eq "local") {
          0
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$_.manifest_version) -and $_.label -eq $_.manifest_version) {
          1
        } else {
          2
        }
        $parsedVersion = $null
        $versionSortKey = if ([System.Version]::TryParse([string]$_.manifest_version, [ref]$parsedVersion)) {
          $parsedVersion
        } else {
          [System.Version]::new(0, 0)
        }

        [pscustomobject]@{
          priority = $priority
          version_sort_key = $versionSortKey
          package = $_
        }
      } |
      Sort-Object priority, @{ Expression = { [string]$_.package.marketplace_name } }, @{ Expression = { $_.version_sort_key }; Descending = $true }, @{ Expression = { [string]$_.package.label }; Descending = $true }
  )

  if ($packages.Count -eq 0) {
    return $null
  }

  return $packages[0].package
}

function Get-ActivationSourceHintPackages($CachePackages, [string]$MarketplaceName) {
  return @(
    foreach ($packageName in $SymppPluginPackageNames) {
      Get-PreferredActivationSourceHintPackage $CachePackages $packageName $MarketplaceName
    }
  )
}

function Test-DefaultPackageReady($Package) {
  return $null -ne $Package -and
    $Package.package_name -eq "symphony-plus-plus" -and
    $Package.manifest_exists -eq $true -and
    [string]::IsNullOrWhiteSpace([string]$Package.manifest_parse_error) -and
    $Package.default_plugin_lifecycle_status -eq "skill_only"
}

function Test-McpCompanionPackageReady($Package) {
  return $null -ne $Package -and
    $Package.package_name -eq "symphony-plus-plus-mcp" -and
    $Package.manifest_exists -eq $true -and
    [string]::IsNullOrWhiteSpace([string]$Package.manifest_parse_error) -and
    $Package.default_plugin_lifecycle_status -eq "opt_in_mcp_plugin_bundles_mcp" -and
    $Package.reference_mcp_server_status -eq "ok"
}

function Get-SourcePackageSummaryFromCheckout([string]$SourceRoot, [string]$PackageName) {
  if ([string]::IsNullOrWhiteSpace($SourceRoot) -or [string]::IsNullOrWhiteSpace($PackageName)) {
    return $null
  }

  $packageRoot = Resolve-OptionalFullPath (Join-Path $SourceRoot "plugins/$PackageName")
  if (-not $packageRoot -or -not (Test-Path -LiteralPath (Join-Path $packageRoot ".codex-plugin/plugin.json"))) {
    return $null
  }

  return Get-PluginPackageSummary $packageRoot "source" "source"
}

function New-PackageFreshnessResult([string]$Status, $Package, $SourcePackage) {
  $result = [ordered]@{ status = $Status }
  if ($null -ne $Package) {
    $result.package_name = [string]$Package.package_name
    $result.cache_label = [string]$Package.label
    $result.cache_version = [string]$Package.manifest_version
    $result.cache_root = [string]$Package.root
  }
  if ($null -ne $SourcePackage) {
    $result.source_version = [string]$SourcePackage.manifest_version
    $result.source_root = [string]$SourcePackage.root
  }

  return [pscustomobject]$result
}

function Test-SourcePackageSummaryComparable($SourcePackage, [string]$PackageName) {
  return $null -ne $SourcePackage -and
    $SourcePackage.manifest_exists -eq $true -and
    [string]::IsNullOrWhiteSpace([string]$SourcePackage.manifest_parse_error) -and
    [string]$SourcePackage.package_name -eq $PackageName -and
    -not [string]::IsNullOrWhiteSpace([string]$SourcePackage.manifest_version)
}

function Get-InstalledPackageFreshness($Package, [string]$SourceRoot) {
  if ($null -eq $Package) {
    return New-PackageFreshnessResult "not_installed" $null $null
  }

  $sourcePackage = Get-SourcePackageSummaryFromCheckout $SourceRoot ([string]$Package.package_name)
  if (-not (Test-SourcePackageSummaryComparable $sourcePackage ([string]$Package.package_name))) {
    return New-PackageFreshnessResult "unknown_source" $Package $null
  }

  if ([string]$Package.manifest_version -ne [string]$sourcePackage.manifest_version) {
    return New-PackageFreshnessResult "version_mismatch" $Package $sourcePackage
  }

  $trackedRelativePaths = @(Get-GitTrackedPackageFingerprintPaths $SourceRoot ([string]$sourcePackage.root))
  if ($trackedRelativePaths.Count -eq 0) {
    return New-PackageFreshnessResult "unknown_fingerprint" $Package $sourcePackage
  }

  $relativePaths = @(Merge-PackageFingerprintPaths $trackedRelativePaths @(Get-ExistingPackageFingerprintPaths ([string]$Package.root)))
  $cacheFingerprint = Get-PluginPackageFingerprint ([string]$Package.root) $relativePaths
  $sourceFingerprint = Get-PluginPackageFingerprint ([string]$sourcePackage.root) $relativePaths

  if ([string]::IsNullOrWhiteSpace([string]$cacheFingerprint) -or [string]::IsNullOrWhiteSpace([string]$sourceFingerprint)) {
    return New-PackageFreshnessResult "unknown_fingerprint" $Package $sourcePackage
  }

  if ([string]$cacheFingerprint -eq [string]$sourceFingerprint) {
    return New-PackageFreshnessResult "current" $Package $sourcePackage
  }

  return New-PackageFreshnessResult "content_mismatch" $Package $sourcePackage
}

function Test-PackageFreshnessStale($Freshness) {
  return $null -ne $Freshness -and @("version_mismatch", "content_mismatch") -contains [string]$Freshness.status
}

function Format-PackageFreshnessMessage($Freshness) {
  if ($null -eq $Freshness) {
    return "Package cache freshness could not be evaluated."
  }

  if ($Freshness.status -eq "version_mismatch") {
    return "$($Freshness.package_name) cache $($Freshness.cache_label) has manifest version $($Freshness.cache_version), but the inferred source checkout has version $($Freshness.source_version)."
  }

  if ($Freshness.status -eq "content_mismatch") {
    return "$($Freshness.package_name) cache $($Freshness.cache_label) has the same manifest version as the inferred source checkout, but packaged file contents differ."
  }

  return "$($Freshness.package_name) cache freshness status: $($Freshness.status)."
}

function Get-ReadinessSummary($CachePackages, $Config, [string]$MarketplaceName, $SourceCheckout, [string]$CodexHomePath) {
  $defaultMarketplaceAmbiguous = Test-ActivationMarketplaceAmbiguous $CachePackages $MarketplaceName "symphony-plus-plus"
  $companionMarketplaceAmbiguous = Test-ActivationMarketplaceAmbiguous $CachePackages $MarketplaceName "symphony-plus-plus-mcp"
  $defaultPackage = if ($defaultMarketplaceAmbiguous) { $null } else { Get-PreferredActivationPackage $CachePackages "symphony-plus-plus" $MarketplaceName }
  $companionPackage = if ($companionMarketplaceAmbiguous) { $null } else { Get-PreferredActivationPackage $CachePackages "symphony-plus-plus-mcp" $MarketplaceName }
  $defaultMarketplace = if ($null -ne $defaultPackage -and -not [string]::IsNullOrWhiteSpace([string]$defaultPackage.marketplace_name)) {
    [string]$defaultPackage.marketplace_name
  } elseif ($MarketplaceName -ne "*") {
    $MarketplaceName
  } else {
    $null
  }
  $companionMarketplace = if ($null -ne $companionPackage -and -not [string]::IsNullOrWhiteSpace([string]$companionPackage.marketplace_name)) {
    [string]$companionPackage.marketplace_name
  } elseif ($MarketplaceName -ne "*") {
    $MarketplaceName
  } else {
    $defaultMarketplace
  }
  $crossMarketplacePairingAmbiguous = Test-CrossActivationMarketplacePairingAmbiguous $CachePackages $MarketplaceName
  $companionSelectionBlocked = $companionMarketplaceAmbiguous -or $crossMarketplacePairingAmbiguous

  $configExists = $Config.exists -eq $true
  $defaultEnabled = if ($configExists) { Get-PluginEnabledFromEntries $Config.symphony_plugin_entries "symphony-plus-plus" $defaultMarketplace } else { $null }
  $companionEnabled = if ($configExists) { Get-PluginEnabledFromEntries $Config.symphony_plugin_entries "symphony-plus-plus-mcp" $companionMarketplace } else { $null }
  $targetCompanionEntries = @(
    if ($configExists) {
      $Config.symphony_plugin_entries |
        Where-Object {
          $_.plugin_name -eq "symphony-plus-plus-mcp" -and
          ($companionMarketplace -eq "*" -or [string]$_.marketplace_name -eq [string]$companionMarketplace)
        }
    }
  )
  $unsupportedTargetCompanionConfigEntry = @(
    $targetCompanionEntries |
      Where-Object { $null -eq $_.enabled }
  ).Count -gt 0 -or $targetCompanionEntries.Count -gt 1
  $enabledCompanionEntries = @(
    if ($configExists) {
      $Config.symphony_plugin_entries |
        Where-Object { $_.plugin_name -eq "symphony-plus-plus-mcp" -and $_.enabled -eq $true }
    }
  )
  $enabledOtherCompanionEntries = @(
    $enabledCompanionEntries |
      Where-Object { [string]$_.marketplace_name -ne [string]$companionMarketplace }
  )
  $defaultCodexHomeSelected = Test-DefaultCodexHome $CodexHomePath
  $otherMarketplaceMcpCompanionEnabled = $enabledOtherCompanionEntries.Count -gt 0
  $defaultHomeMcpCompanionEnabled = $configExists -and $enabledCompanionEntries.Count -gt 0 -and $defaultCodexHomeSelected
  $sourceRoot = if ($null -ne $SourceCheckout) { [string]$SourceCheckout.root } else { $null }
  $defaultFreshness = Get-InstalledPackageFreshness $defaultPackage $sourceRoot
  $companionFreshness = Get-InstalledPackageFreshness $companionPackage $sourceRoot
  $defaultCacheStale = Test-PackageFreshnessStale $defaultFreshness
  $companionCacheStale = Test-PackageFreshnessStale $companionFreshness
  $defaultStructurallyReady = Test-DefaultPackageReady $defaultPackage
  $companionStructurallyReady = Test-McpCompanionPackageReady $companionPackage
  $defaultReady = $defaultStructurallyReady -and -not $defaultCacheStale
  $companionReady = $companionStructurallyReady -and -not $companionCacheStale
  $companionProvidesSoloSkills = $companionReady -and $companionEnabled -eq $true
  $refreshCodexHomeArg = if ([string]::IsNullOrWhiteSpace($CodexHomePath)) { "" } else { "-CodexHome $(Quote-PowerShellLiteral $CodexHomePath) " }
  $companionRefreshMarketplaceArg = if ([string]::IsNullOrWhiteSpace($companionMarketplace)) { "" } else { "-MarketplaceName $(Quote-PowerShellLiteral $companionMarketplace) " }
  $actions = @()
  $warnings = @()

  if ($defaultCacheStale) {
    $warnings += New-ReadinessWarning "default_plugin_cache_stale" "$(Format-PackageFreshnessMessage $defaultFreshness) Upgrade the Codex marketplace before relying on newly merged skill or wrapper changes."
    $actions += New-ReadinessAction "upgrade_default_plugin_cache" "solo_session" "Upgrade the stale skill-only Symphony++ plugin from the configured marketplace." (New-CodexMarketplaceUpgradeCommand $CodexHomePath $defaultMarketplace)
  }

  if ($companionCacheStale) {
    $warnings += New-ReadinessWarning "mcp_companion_cache_stale" "$(Format-PackageFreshnessMessage $companionFreshness) Upgrade the Codex marketplace before relying on MCP launcher, dashboard, or skill changes."
    $actions += New-ReadinessAction "upgrade_mcp_companion_cache" "workrequest_mcp" "Upgrade the stale opt-in MCP companion from the configured marketplace." (New-CodexMarketplaceUpgradeCommand $CodexHomePath $companionMarketplace)
  }

  if (-not $configExists) {
    $createConfigMessage = if (-not $companionSelectionBlocked -and $companionStructurallyReady -and $defaultCodexHomeSelected) {
      "No Codex config exists at $($Config.path). Choose a dedicated Symphony++ MCP Codex home before enabling the companion; the default Codex home is intentionally refused."
    } elseif (-not $companionSelectionBlocked -and $companionStructurallyReady) {
      "No Codex config exists at $($Config.path). Run the explicit MCP companion enable command below to create it, or restore the config before diagnosing unrelated plugin enablement."
    } else {
      "Create or restore the Codex config at $($Config.path) before plugin enablement can be diagnosed."
    }
    $actions += New-ReadinessAction "create_codex_config" "config" $createConfigMessage
  }
  if ($companionMarketplaceAmbiguous) {
    $actions += New-ReadinessAction "rerun_with_marketplace" "config" "Multiple symphony-plus-plus-mcp marketplaces are installed; rerun this doctor with -MarketplaceName <marketplace> before using MCP companion repair actions."
  } elseif ($crossMarketplacePairingAmbiguous) {
    $actions += New-ReadinessAction "rerun_with_marketplace" "config" "The skill-only and MCP companion packages resolve to different marketplaces in wildcard mode; rerun with -MarketplaceName <marketplace> before using package-specific repair actions."
  } elseif ($defaultMarketplaceAmbiguous) {
    $actions += New-ReadinessAction "select_default_plugin_marketplace" "solo_session" "Multiple skill-only symphony-plus-plus marketplaces are installed; rerun with -MarketplaceName <marketplace> before using default plugin repair actions."
  }

  $defaultStatus = if (-not $configExists) {
    "config_missing"
  } elseif ($companionProvidesSoloSkills) {
    "ready_via_mcp_companion"
  } elseif ($defaultMarketplaceAmbiguous) {
    "default_plugin_marketplace_ambiguous"
  } elseif ($defaultEnabled -ne $true) {
    "default_plugin_not_enabled"
  } elseif ($defaultCacheStale) {
    "default_plugin_cache_stale"
  } elseif (-not $defaultStructurallyReady) {
    "default_plugin_cache_missing_or_invalid"
  } else {
    "ready"
  }

  if (-not $defaultMarketplaceAmbiguous -and -not $crossMarketplacePairingAmbiguous -and -not $defaultStructurallyReady -and -not $companionProvidesSoloSkills) {
    $actions += New-ReadinessAction "upgrade_default_plugin_cache" "solo_session" "Install or repair the skill-only Symphony++ plugin from the configured marketplace." (New-CodexMarketplaceUpgradeCommand $CodexHomePath $defaultMarketplace)
  } elseif (-not $defaultMarketplaceAmbiguous -and -not $crossMarketplacePairingAmbiguous -and $configExists -and $defaultEnabled -ne $true -and -not $companionProvidesSoloSkills) {
    $defaultConfigKey = Get-ActivationConfigKey "symphony-plus-plus" $defaultMarketplace
    $actions += New-ReadinessAction "enable_default_plugin" "solo_session" "Enable the default skill-only plugin for MCP-free Symphony++ planning: [plugins.`"$defaultConfigKey`"] enabled = true."
  }

  $companionArtifactStatus = if ($null -ne $companionPackage -and $null -ne $companionPackage.runtime_artifact) {
    [string]$companionPackage.runtime_artifact.status
  } else {
    $null
  }
  $companionArtifactDetail = if ($null -ne $companionPackage -and $null -ne $companionPackage.runtime_artifact) {
    [string]$companionPackage.runtime_artifact.detail
  } else {
    $null
  }
  $companionArtifactFallbackAllowed = $null -ne $companionPackage -and
    $companionPackage.PSObject.Properties["runtime_artifact_source_fallback_allowed"] -and
    $companionPackage.runtime_artifact_source_fallback_allowed -eq $true
  $companionArtifactMissingBlocksLaunch = $companionArtifactStatus -eq "artifact_missing" -and
    ($companionArtifactDetail -ne "manifest_missing" -or -not $companionArtifactFallbackAllowed)
  $companionArtifactSelectedBlocksLaunch = $false
  $companionArtifactUnavailable =
    $companionArtifactStatus -in @("artifact_manifest_invalid", "artifact_verification_failed", "artifact_unavailable") -or
    $companionArtifactMissingBlocksLaunch -or
    $companionArtifactSelectedBlocksLaunch
  $companionArtifactBlocksLaunch = $companionArtifactUnavailable -and -not $companionArtifactFallbackAllowed

  $companionStatus = if (-not $configExists) {
    "config_missing"
  } elseif ($companionMarketplaceAmbiguous) {
    "companion_marketplace_ambiguous"
  } elseif (-not $companionStructurallyReady) {
    if ($null -eq $companionPackage) {
      "companion_cache_missing"
    } else {
      "companion_config_invalid"
    }
  } elseif ($unsupportedTargetCompanionConfigEntry) {
    "companion_config_entry_unsupported"
  } elseif ($companionEnabled -ne $true) {
    "companion_installed_not_enabled"
  } elseif ($companionCacheStale) {
    "companion_cache_stale"
  } elseif ($companionArtifactBlocksLaunch) {
    "runtime_artifact_unavailable"
  } elseif ($companionPackage.http_mcp_reachability_status -eq "not_applicable") {
    "ready"
  } elseif ($companionPackage.http_mcp_reachability_status -eq "mcp_endpoint_available") {
    "ready"
  } elseif ($companionPackage.http_mcp_reachability_status -eq "unreachable") {
    "endpoint_unreachable"
  } else {
    [string]$companionPackage.http_mcp_reachability_status
  }

  if (-not $companionSelectionBlocked -and -not $companionStructurallyReady) {
    $actions += New-ReadinessAction "upgrade_mcp_companion_cache" "workrequest_mcp" "Install or repair the opt-in MCP companion from the configured marketplace." (New-CodexMarketplaceUpgradeCommand $CodexHomePath $companionMarketplace)
  } elseif (-not $companionSelectionBlocked -and $companionStructurallyReady -and $companionEnabled -ne $true -and $otherMarketplaceMcpCompanionEnabled) {
    $actions += New-ReadinessAction "resolve_mcp_companion_marketplace_conflict" "config" "Another symphony-plus-plus-mcp marketplace is already enabled in this Codex config; disable or relocate that entry before enabling $companionMarketplace."
  } elseif (-not $companionSelectionBlocked -and $companionStructurallyReady -and $companionEnabled -ne $true -and $defaultCodexHomeSelected) {
    $actions += New-ReadinessAction "choose_dedicated_codex_home" "workrequest_mcp" "Rerun the doctor and enable command with -CodexHome <dedicated-symphony-plus-plus-codex-home>; refusing to enable symphony-plus-plus-mcp in the default Codex home keeps generic worker/review configs MCP-clean."
  } elseif (-not $companionSelectionBlocked -and $companionStructurallyReady -and $unsupportedTargetCompanionConfigEntry) {
    $companionConfigKey = Get-ActivationConfigKey "symphony-plus-plus-mcp" $companionMarketplace
    $rewriteMessage = @(
      "A $companionConfigKey config entry exists, but its enabled value is missing, duplicate, or unsupported."
      "Rewrite it as a supported boolean plugin entry before using -EnableMcpCompanion, for example [plugins.`"$companionConfigKey`"] enabled = false."
    ) -join " "
    $actions += New-ReadinessAction "rewrite_mcp_companion_config_entry" "config" $rewriteMessage
  } elseif (-not $companionSelectionBlocked -and $companionStructurallyReady -and -not $companionCacheStale -and $companionEnabled -ne $true -and $Config.global_sympp_mcp_entry -ne $true) {
    $companionConfigKey = Get-ActivationConfigKey "symphony-plus-plus-mcp" $companionMarketplace
    $enableArgs = "$($refreshCodexHomeArg)$($companionRefreshMarketplaceArg)-EnableMcpCompanion"
    $enableCommand = New-CurrentDiagnosticCommand $enableArgs
    if ([string]::IsNullOrWhiteSpace($enableCommand)) {
      $enableCommand = New-SourceScriptCommand $sourceRoot "plugins/symphony-plus-plus/scripts/diagnose-mcp-lifecycle.ps1" $enableArgs
      $actions += New-SourceCheckoutAction "enable_mcp_companion" "workrequest_mcp" "Enable the opt-in MCP companion only in a dedicated S++ config/session: [plugins.`"$companionConfigKey`"] enabled = true." $SourceCheckout $enableCommand
    } else {
      $actions += New-ReadinessAction "enable_mcp_companion" "workrequest_mcp" "Enable the opt-in MCP companion only in a dedicated S++ config/session: [plugins.`"$companionConfigKey`"] enabled = true." $enableCommand
    }
    $actions += New-ReadinessAction "restart_codex_session" "workrequest_mcp" "Restart or reload that dedicated Codex session so the plugin launcher can start the managed S++ backend/dashboard before the model starts."
  } elseif (-not $companionSelectionBlocked -and $companionStatus -eq "endpoint_unreachable") {
    $actions += New-SourceCheckoutAction "start_cockpit" "workrequest_mcp" "Start the local Symphony++ cockpit/HTTP MCP daemon." $SourceCheckout (New-CockpitCommand $sourceRoot)
    $actions += New-SourceCheckoutAction "verify_http_mcp" "workrequest_mcp" "Verify the local HTTP MCP daemon source revision independently of Codex plugin loading." $SourceCheckout (New-VerifyHttpMcpCommand $sourceRoot)
  } elseif (-not $companionSelectionBlocked -and $companionStatus -eq "runtime_artifact_unavailable") {
    $actions += New-SourceCheckoutAction "refresh_mcp_companion_cache" "workrequest_mcp" "Refresh the opt-in MCP companion cache so its runtime artifact manifest matches the plugin version and MCP contract." $SourceCheckout (New-SourceScriptCommand $sourceRoot "scripts/refresh-local-plugin.ps1" "$($refreshCodexHomeArg)$($companionRefreshMarketplaceArg)-PluginName symphony-plus-plus-mcp -ValidateInstalledCache")
  } elseif (-not $companionSelectionBlocked -and $companionStatus -eq "ready") {
    $actions += New-SourceCheckoutAction "verify_http_mcp" "workrequest_mcp" "Verify the local HTTP MCP daemon source revision independently of Codex plugin loading." $SourceCheckout (New-VerifyHttpMcpCommand $sourceRoot)
    $actions += New-ReadinessAction "verify_codex_session" "workrequest_mcp" "If the current Codex session still lacks symphony_plus_plus tools, restart or reload the dedicated MCP-enabled session; this doctor verifies config, cache, and daemon reachability, not the already-open model tool list."
  }

  if ($Config.global_sympp_mcp_entry -eq $true) {
    $warnings += New-ReadinessWarning "global_sympp_mcp_entry_present" "A top-level [mcp_servers.symphony_plus_plus] entry is present. Keep this out of generic worker/review configs unless every session using that config should see S++ MCP."
    $actions += New-ReadinessAction "relocate_global_sympp_mcp_entry" "config" "Remove the top-level [mcp_servers.symphony_plus_plus] entry from generic configs, or move S++ MCP activation into a dedicated plugin-enabled S++ config/session."
  }

  if ($defaultHomeMcpCompanionEnabled) {
    $warnings += New-ReadinessWarning "default_codex_home_mcp_companion_enabled" "symphony-plus-plus-mcp is enabled in the default Codex home. Move MCP companion activation to a dedicated S++ Codex home/session to keep generic worker and review configs MCP-clean."
    $actions += New-ReadinessAction "move_mcp_companion_to_dedicated_codex_home" "config" "Disable symphony-plus-plus-mcp in the default Codex home and enable it only in a dedicated Symphony++ MCP Codex home/session."
  }

  if ($otherMarketplaceMcpCompanionEnabled) {
    $warnings += New-ReadinessWarning "other_marketplace_mcp_companion_enabled" "Another symphony-plus-plus-mcp marketplace is already enabled in this Codex config. Keep only one MCP companion marketplace enabled per dedicated S++ session."
  }

  $soloReady = $defaultStatus -eq "ready" -or $defaultStatus -eq "ready_via_mcp_companion"
  $overallStatus = if (-not $configExists) {
    "config_missing"
  } elseif ($companionMarketplaceAmbiguous) {
    "multiple_marketplaces_need_selection"
  } elseif ($crossMarketplacePairingAmbiguous) {
    "multiple_marketplaces_need_selection"
  } elseif ($Config.global_sympp_mcp_entry -eq $true) {
    "global_footgun_present"
  } elseif ($defaultHomeMcpCompanionEnabled) {
    "default_codex_home_mcp_companion_enabled"
  } elseif ($otherMarketplaceMcpCompanionEnabled) {
    "mcp_companion_enabled_in_other_marketplace"
  } elseif ($defaultStatus -eq "default_plugin_cache_stale" -or $companionStatus -eq "companion_cache_stale") {
    "plugin_cache_stale"
  } elseif ($soloReady -and $companionStatus -eq "ready") {
    "healthy_local_workrequest_mcp"
  } elseif ($defaultStatus -eq "ready" -and $companionStatus -eq "companion_installed_not_enabled") {
    "solo_ready_mcp_companion_not_enabled"
  } elseif ($companionStatus -eq "companion_config_entry_unsupported") {
    "mcp_companion_config_entry_unsupported"
  } elseif ($companionStatus -eq "endpoint_unreachable") {
    "mcp_companion_endpoint_unreachable"
  } elseif ($companionStatus -eq "companion_installed_not_enabled") {
    "mcp_companion_not_enabled"
  } elseif ($defaultStatus -eq "ready") {
    "solo_ready_mcp_not_ready"
  } else {
    "needs_repair"
  }

  return [pscustomobject]@{
    overall_status = $overallStatus
    marketplace_name = if ($MarketplaceName -eq "*" -and $defaultMarketplace -eq $companionMarketplace -and -not [string]::IsNullOrWhiteSpace($defaultMarketplace)) { $defaultMarketplace } else { $MarketplaceName }
    source_checkout = $SourceCheckout
    solo_session = [pscustomobject]@{
      status = $defaultStatus
      plugin_config_key = Get-ActivationConfigKey "symphony-plus-plus" $defaultMarketplace
      plugin_enabled = $defaultEnabled
      cache_label = if ($null -ne $defaultPackage) { $defaultPackage.label } else { $null }
      cache_lifecycle = if ($null -ne $defaultPackage) { $defaultPackage.default_plugin_lifecycle_status } else { $null }
      cache_freshness = $defaultFreshness
    }
    workrequest_mcp = [pscustomobject]@{
      status = $companionStatus
      companion_config_key = Get-ActivationConfigKey "symphony-plus-plus-mcp" $companionMarketplace
      companion_plugin_enabled = $companionEnabled
      cache_label = if ($null -ne $companionPackage) { $companionPackage.label } else { $null }
      cache_lifecycle = if ($null -ne $companionPackage) { $companionPackage.default_plugin_lifecycle_status } else { $null }
      cache_freshness = $companionFreshness
      runtime_artifact = if ($null -ne $companionPackage) { $companionPackage.runtime_artifact } else { $null }
      reference_mcp_server_status = if ($null -ne $companionPackage) { $companionPackage.reference_mcp_server_status } else { $null }
      http_mcp_reachability_status = if ($null -ne $companionPackage) { $companionPackage.http_mcp_reachability_status } else { $null }
      transport = if ($null -ne $companionPackage -and $companionPackage.http_mcp_reachability_status -eq "not_applicable") { "command_stdio_to_http_bridge" } else { "http_url" }
      default_backend_url = "http://127.0.0.1:19998"
      default_mcp_url = "http://127.0.0.1:19998/mcp"
      default_dashboard_url = "http://127.0.0.1:19999/sympp/board"
      runtime_file = [System.IO.Path]::GetFullPath((Join-Path $HOME ".agents/splusplus/runtime/codex-plugin.json"))
    }
    next_actions = @($actions)
    warnings = @($warnings)
    session_visibility_note = "This doctor verifies source/cache/config and the command-backed launcher shape. It cannot inspect tools already registered inside an open Codex model session; restart or reload the dedicated MCP-enabled session after config/cache changes."
    generic_review_boundary = "Keep symphony-plus-plus-mcp out of generic worker, worker_smart, review-suite, and codex review configs; use a dedicated S++ MCP-enabled config/session instead."
  }
}

function Write-DoctorSummary($Summary) {
  $readiness = $Summary.readiness
  Write-Host "Symphony++ activation doctor"
  Write-Host "  overall: $($readiness.overall_status)"
  Write-Host "  codex_home: $($Summary.codex_home)"
  Write-Host "  marketplace: $($readiness.marketplace_name)"
  Write-Host "  source checkout: $($readiness.source_checkout.status) $($readiness.source_checkout.root)"
  if (-not [string]::IsNullOrWhiteSpace([string]$readiness.source_checkout.note)) {
    Write-Host "  source note: $($readiness.source_checkout.note)"
  }
  Write-Host "  config: $($Summary.codex_config.path)"
  Write-Host ""
  Write-Host "MCP-free skill package"
  Write-Host "  status: $($readiness.solo_session.status)"
  Write-Host "  config key: $($readiness.solo_session.plugin_config_key)"
  Write-Host "  enabled: $($readiness.solo_session.plugin_enabled)"
  Write-Host "  cache: $($readiness.solo_session.cache_label) / $($readiness.solo_session.cache_lifecycle)"
  Write-Host "  cache freshness: $($readiness.solo_session.cache_freshness.status)"
  Write-Host ""
  Write-Host "WorkRequest MCP companion"
  Write-Host "  status: $($readiness.workrequest_mcp.status)"
  Write-Host "  config key: $($readiness.workrequest_mcp.companion_config_key)"
  Write-Host "  enabled: $($readiness.workrequest_mcp.companion_plugin_enabled)"
  Write-Host "  cache: $($readiness.workrequest_mcp.cache_label) / $($readiness.workrequest_mcp.cache_lifecycle)"
  Write-Host "  cache freshness: $($readiness.workrequest_mcp.cache_freshness.status)"
  if ($null -ne $readiness.workrequest_mcp.runtime_artifact) {
    Write-Host "  runtime artifact: $($readiness.workrequest_mcp.runtime_artifact.status) / $($readiness.workrequest_mcp.runtime_artifact.detail)"
  }
  Write-Host "  server: $($readiness.workrequest_mcp.reference_mcp_server_status)"
  Write-Host "  endpoint: $($readiness.workrequest_mcp.http_mcp_reachability_status)"
  Write-Host "  transport: $($readiness.workrequest_mcp.transport)"
  Write-Host "  backend: $($readiness.workrequest_mcp.default_backend_url)"
  Write-Host "  dashboard: $($readiness.workrequest_mcp.default_dashboard_url)"
  Write-Host "  runtime file: $($readiness.workrequest_mcp.runtime_file)"
  Write-Host ""

  if (@($readiness.warnings).Count -gt 0) {
    Write-Host "Warnings:"
    foreach ($warning in @($readiness.warnings)) {
      Write-Host "  - [$($warning.code)] $($warning.message)"
    }
    Write-Host ""
  }

  if (@($readiness.next_actions).Count -gt 0) {
    Write-Host "Next actions:"
    foreach ($action in @($readiness.next_actions)) {
      Write-Host "  - [$($action.code)] $($action.message)"
      if ($action.PSObject.Properties["command"]) {
        Write-Host "    $($action.command)"
      }
    }
  } else {
    Write-Host "Next actions: none"
  }

  Write-Host ""
  Write-Host "Session visibility: $($readiness.session_visibility_note)"
  Write-Host ""
  Write-Host "Boundary: $($readiness.generic_review_boundary)"
}

$pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$repoRootWasProvided = -not [string]::IsNullOrWhiteSpace($RepoRoot)
$RepoRoot = Resolve-OptionalFullPath $RepoRoot
if ($repoRootWasProvided -and -not (Test-Path -LiteralPath (Join-Path $RepoRoot "elixir/mix.exs"))) {
  throw "RepoRoot does not look like a Symphony++ checkout with elixir/mix.exs: $RepoRoot"
}
$repoRootFilter = Normalize-ComparablePath $RepoRoot

if ($SelfTest) {
  Invoke-SelfTest
  exit 0
}

$codexHomePath = Resolve-OptionalFullPath $CodexHome
$sourcePackage = Get-PluginPackageSummary $pluginRoot "source" "source"
$cacheBaseRoot = Join-Path $codexHomePath "plugins/cache"
$cacheRoots = @()
if ($MarketplaceName -eq "*") {
  if (Test-Path -LiteralPath $cacheBaseRoot) {
    $cacheRoots = @(
      Get-ChildItem -LiteralPath $cacheBaseRoot -Directory |
      ForEach-Object {
        $marketplaceDir = $_
        foreach ($pluginPackageName in $SymppPluginPackageNames) {
          $candidate = Join-Path $marketplaceDir.FullName $pluginPackageName
          if (Test-Path -LiteralPath $candidate) {
            [pscustomobject]@{ marketplace_name = $marketplaceDir.Name; plugin_name = $pluginPackageName; root = $candidate }
          }
        }
      }
    )
  }
} else {
  $cacheRoots = @(
    foreach ($pluginPackageName in $SymppPluginPackageNames) {
      [pscustomobject]@{
        marketplace_name = $MarketplaceName
        plugin_name = $pluginPackageName
        root = Join-Path $cacheBaseRoot (Join-Path $MarketplaceName $pluginPackageName)
      }
    }
  )
}

$cachePackages = @()
foreach ($cacheRoot in $cacheRoots) {
  if (Test-Path -LiteralPath $cacheRoot.root) {
    $cachePackages += @(
      Get-ChildItem -LiteralPath $cacheRoot.root -Directory |
      Sort-Object Name |
      ForEach-Object { Get-PluginPackageSummary $_.FullName $_.Name $cacheRoot.marketplace_name }
    )
  }
}

$sourcePackages = @($sourcePackage)
$companionMcpSourcePackages = @(Get-CompanionMcpSourcePackages $pluginRoot)
$sourcePackages += $companionMcpSourcePackages
if ($companionMcpSourcePackages.Count -eq 0) {
  $installedSourceMarketplaceName = Get-InstalledDefaultPluginMarketplaceName $pluginRoot
  $allowedFallbackMarketplaces = if ($MarketplaceName -ne "*") {
    @($MarketplaceName)
  } elseif (-not [string]::IsNullOrWhiteSpace($installedSourceMarketplaceName)) {
    @($installedSourceMarketplaceName)
  } else {
    @()
  }
  $sourcePackages += @(Get-InstalledCompanionMcpVersionCandidatePackages $cachePackages $allowedFallbackMarketplaces)
}
$currentManifestVersionsByPackageName = Get-CurrentManifestVersionsByPackageName $sourcePackages

$processScopeCachePackages = @(
  $cachePackages |
    Where-Object {
    (Test-CachePackageIsCurrentForProcessScope $_ $currentManifestVersionsByPackageName) -and
    (Test-CachePackageCanScopeProcesses $_)
    }
)
$hasOptInMcpProcessScopePackage = @(
  $processScopeCachePackages |
    Where-Object { $_.package_name -eq "symphony-plus-plus-mcp" }
).Count -gt 0
$localOptInMcpProcessScopePackages = @{}
foreach ($package in @($processScopeCachePackages | Where-Object { $_.package_name -eq "symphony-plus-plus-mcp" -and $_.label -eq "local" })) {
  $localOptInMcpProcessScopePackages[[string]$package.marketplace_name] = $package
}

$cacheRepoRootFilters = @(
  $processScopeCachePackages |
  Where-Object {
    -not (
      $hasOptInMcpProcessScopePackage -and
      $_.package_name -eq "symphony-plus-plus" -and
      $_.default_plugin_lifecycle_status -eq "skill_only" -and
      $_.reference_mcp_server_status -eq "not_configured"
    ) -and -not (
      Test-VersionedOptInSuppressedByLocal $_ $localOptInMcpProcessScopePackages
    )
  } |
  ForEach-Object {
    Normalize-ComparablePath (Get-MarketplaceSourceRootFromCachePackage $_)
  } |
  Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
  Sort-Object -Unique
)
$processRepoRootFilters = if ($repoRootFilter) {
  @($repoRootFilter)
} elseif ($cacheRepoRootFilters.Count -eq 1) {
  @($cacheRepoRootFilters[0])
} else {
  @()
}
$processScanScope = if ($repoRootFilter) {
  "repo_root_parameter"
} elseif ($processRepoRootFilters.Count -gt 0) {
  "installed_cache_marketplace_source_clone"
} elseif ($cacheRepoRootFilters.Count -gt 1) {
  "skipped_ambiguous_marketplace_source_clones"
} else {
  "skipped_no_repo_root_scope"
}
$processScanSupported = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
$processScanNote = if ($SkipProcessScan) {
  "Skipped live process scan because -SkipProcessScan was supplied."
} elseif (-not $processScanSupported) {
  "Win32_Process process inventory is only available on Windows."
} elseif ($cacheRepoRootFilters.Count -gt 1 -and $processRepoRootFilters.Count -eq 0) {
  "Skipped scoped live process scan because selected installed caches resolve to multiple Codex marketplace source clones; pass -RepoRoot only for explicit developer validation."
} elseif ($processRepoRootFilters.Count -eq 0) {
  "Skipped live process scan because no -RepoRoot value or Codex marketplace source clone was available for the selected Codex home and marketplace."
} else {
  $null
}
$shouldScanProcesses = $null -eq $processScanNote -and $processScanSupported -and $processRepoRootFilters.Count -gt 0
$allProcesses = if ($shouldScanProcesses) {
  @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, CommandLine, CreationDate)
} else {
  @()
}
$processById = @{}
foreach ($process in $allProcesses) {
  $processById[[int]$process.ProcessId] = $process
}
$allLauncherProcesses = @($allProcesses | Where-Object { $_.Name -match "^(pwsh|powershell)(\.exe)?$" -and $_.CommandLine -match "start-sympp-mcp\.ps1" })
$allCmdProcesses = @($allProcesses | Where-Object { $_.Name -eq "cmd.exe" -and $_.CommandLine -match "mix\.bat.*sympp\.mcp --mode stdio" })
$allMiseProcesses = @($allProcesses | Where-Object { $_.Name -match "^mise(\.exe)?$" -and $_.CommandLine -match "exec.*mix.*sympp\.mcp --mode stdio" })
$allErlProcesses = @($allProcesses | Where-Object { $_.Name -eq "erl.exe" -and $_.CommandLine -match "sympp\.mcp --mode stdio" })

$cmdProcesses = @($allCmdProcesses | Where-Object { Test-ProcessMatchesAnyRepoRoot $_ $processRepoRootFilters })
$miseProcesses = @($allMiseProcesses | Where-Object { Test-ProcessMatchesAnyRepoRoot $_ $processRepoRootFilters })
$erlProcesses = @($allErlProcesses | Where-Object { Test-ProcessMatchesAnyRepoRoot $_ $processRepoRootFilters })
$allLauncherProcessIds = [System.Collections.Generic.HashSet[int]]::new()
foreach ($process in $allLauncherProcesses) {
  [void]$allLauncherProcessIds.Add([int]$process.ProcessId)
}
$launcherProcessIds = [System.Collections.Generic.HashSet[int]]::new()
if ($processRepoRootFilters.Count -gt 0) {
  $directLauncherProcesses = @($allLauncherProcesses | Where-Object { Test-ProcessMatchesAnyRepoRoot $_ $processRepoRootFilters })
  foreach ($process in $directLauncherProcesses) {
    [void]$launcherProcessIds.Add([int]$process.ProcessId)
  }
  $filterAnchorProcesses = @($cmdProcesses) + @($miseProcesses) + @($erlProcesses)
  foreach ($processId in @(Find-AncestorLauncherProcessIds $filterAnchorProcesses $processById $allLauncherProcessIds)) {
    [void]$launcherProcessIds.Add([int]$processId)
  }
}
$launcherProcesses = @($allLauncherProcesses | Where-Object { $launcherProcessIds.Contains([int]$_.ProcessId) })
$unattributedLauncherProcesses = if ($repoRootFilter -and $processRepoRootFilters.Count -gt 0) {
  @($allLauncherProcesses | Where-Object { -not $launcherProcessIds.Contains([int]$_.ProcessId) })
} else {
  @()
}

$repoRoots = @(
  $erlProcesses |
  ForEach-Object { Get-RepoRootFromCommand $_.CommandLine } |
  Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
  Group-Object |
  Sort-Object Name |
  ForEach-Object { [pscustomobject]@{ repo_root = $_.Name; erl_processes = $_.Count } }
)

$launcherParents = @(
  $launcherProcesses |
  Group-Object ParentProcessId |
  Sort-Object Name |
  ForEach-Object {
    $parentProcessId = [int]$_.Name
    $parent = $allProcesses | Where-Object { $_.ProcessId -eq $parentProcessId } | Select-Object -First 1
    [pscustomobject]@{
      parent_pid = $parentProcessId
      launcher_count = $_.Count
      parent_name = if ($parent) { $parent.Name } else { $null }
      parent_command = if ($parent) { Sanitize-CommandLine $parent.CommandLine } else { $null }
    }
  }
)

$unattributedLauncherParents = @(
  $unattributedLauncherProcesses |
  Group-Object ParentProcessId |
  Sort-Object Name |
  ForEach-Object {
    $parentProcessId = [int]$_.Name
    $parent = $allProcesses | Where-Object { $_.ProcessId -eq $parentProcessId } | Select-Object -First 1
    [pscustomobject]@{
      parent_pid = $parentProcessId
      launcher_count = $_.Count
      parent_name = if ($parent) { $parent.Name } else { $null }
      parent_command = if ($parent) { Sanitize-CommandLine $parent.CommandLine } else { $null }
    }
  }
)

$summary = [pscustomobject]@{
  generated_at = (Get-Date).ToString("o")
  codex_home = $codexHomePath
  marketplace_name = $MarketplaceName
  repo_root_filter = $RepoRoot
  process_scan_supported = $processScanSupported
  process_scan_performed = $shouldScanProcesses
  process_scan_scope = $processScanScope
  process_repo_root_filters = @($processRepoRootFilters)
  process_scan_note = $processScanNote
  source_package = $sourcePackage
  installed_cache = @($cachePackages)
  codex_config = Get-PluginConfigSummary (Join-Path $codexHomePath "config.toml") $MarketplaceName
  live_process_counts = [pscustomobject]@{
    start_sympp_mcp_pwsh = $launcherProcesses.Count
    start_sympp_mcp_pwsh_unattributed = $unattributedLauncherProcesses.Count
    mix_cmd_sympp_mcp = $cmdProcesses.Count
    mise_sympp_mcp = $miseProcesses.Count
    erl_sympp_mcp = $erlProcesses.Count
  }
  live_repo_roots = @($repoRoots)
  launcher_parents = @($launcherParents)
  unattributed_launcher_parents = @($unattributedLauncherParents)
}

$readinessSourcePackages = @(
  if (-not (Test-ActivationMarketplaceAmbiguous $cachePackages $MarketplaceName)) {
    Get-ActivationSourceHintPackages $cachePackages $MarketplaceName
    foreach ($packageName in $SymppPluginPackageNames) {
      Get-PreferredActivationPackage $cachePackages $packageName $MarketplaceName
    }
  }
) | Where-Object { $null -ne $_ }
$sourceCheckout = Resolve-ReadinessSourceCheckout $pluginRoot $RepoRoot $readinessSourcePackages
$summary | Add-Member -NotePropertyName source_checkout -NotePropertyValue $sourceCheckout
$summary | Add-Member -NotePropertyName readiness -NotePropertyValue (Get-ReadinessSummary $summary.installed_cache $summary.codex_config $MarketplaceName $sourceCheckout $codexHomePath)

if ($EnableMcpCompanion) {
  if (-not $PSBoundParameters.ContainsKey("CodexHome")) {
    throw "Refusing to enable symphony-plus-plus-mcp without an explicit -CodexHome. Rerun with -CodexHome <dedicated-symphony-plus-plus-codex-home>."
  }

  $enableResult = Invoke-McpCompanionEnable $summary $MarketplaceName $codexHomePath
  if ($Json) {
    $enableResult | ConvertTo-Json -Depth 6
    exit 0
  }

  Write-McpCompanionEnableSummary $enableResult
  exit 0
}

if ($Json) {
  $summary | ConvertTo-Json -Depth 8
  exit 0
}

if ($Doctor) {
  Write-DoctorSummary $summary
  exit 0
}

Write-Host "Symphony++ plugin MCP lifecycle diagnostic"
Write-Host "  generated_at: $($summary.generated_at)"
Write-Host "  codex_home: $($summary.codex_home)"
Write-Host "  marketplace_name: $($summary.marketplace_name)"
Write-Host "  process_scan_supported: $($summary.process_scan_supported)"
Write-Host "  process_scan_scope: $($summary.process_scan_scope)"
if ($summary.process_scan_note) {
  Write-Host "  process_scan_note: $($summary.process_scan_note)"
}
Write-Host "  plugin_enabled: $($summary.codex_config.symphony_plugin_enabled)"
Write-Host "  readiness: $($summary.readiness.overall_status)"
Write-Host "  global_sympp_mcp_entry: $($summary.codex_config.global_sympp_mcp_entry)"
Write-Host "  source_mcp_shape: $($summary.source_package.mcp_shape)"
Write-Host "  live start-sympp-mcp pwsh: $($summary.live_process_counts.start_sympp_mcp_pwsh)"
Write-Host "  live unattributed start-sympp-mcp pwsh: $($summary.live_process_counts.start_sympp_mcp_pwsh_unattributed)"
Write-Host "  live mix.bat sympp.mcp cmd: $($summary.live_process_counts.mix_cmd_sympp_mcp)"
Write-Host "  live mise exec mix sympp.mcp: $($summary.live_process_counts.mise_sympp_mcp)"
Write-Host "  live erl sympp.mcp: $($summary.live_process_counts.erl_sympp_mcp)"
Write-Host ""
Write-Host "Installed cache:"
foreach ($package in $summary.installed_cache) {
  Write-Host "  $($package.marketplace_name)/$($package.package_name)/$($package.label): version=$($package.manifest_version) lifecycle=$($package.default_plugin_lifecycle_status) shape=$($package.mcp_shape) server=$($package.symphony_plus_plus_server) http=$($package.http_mcp_reachability_status) source=$($package.source_root_hint)"
}
Write-Host ""
Write-Host "Live repo roots:"
foreach ($root in $summary.live_repo_roots) {
  Write-Host "  $($root.repo_root): erl=$($root.erl_processes)"
}
Write-Host ""
Write-Host "Launcher parents:"
foreach ($parent in $summary.launcher_parents) {
  Write-Host "  pid=$($parent.parent_pid) count=$($parent.launcher_count) name=$($parent.parent_name) cmd=$($parent.parent_command)"
}
Write-Host ""
Write-Host "Unattributed launcher parents:"
foreach ($parent in $summary.unattributed_launcher_parents) {
  Write-Host "  pid=$($parent.parent_pid) count=$($parent.launcher_count) name=$($parent.parent_name) cmd=$($parent.parent_command)"
}
