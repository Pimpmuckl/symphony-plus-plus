$ErrorActionPreference = "Stop"

function Get-JsonPropertyValue($Object, [string[]]$Names) {
  if ($null -eq $Object) {
    return $null
  }

  foreach ($name in $Names) {
    if ($Object.PSObject.Properties[$name]) {
      return $Object.PSObject.Properties[$name].Value
    }
  }

  return $null
}

function Get-JsonPathValue($Object, [string[]]$Path) {
  $current = $Object
  foreach ($name in $Path) {
    if ($null -eq $current -or -not $current.PSObject.Properties[$name]) {
      return $null
    }

    $current = $current.PSObject.Properties[$name].Value
  }

  return $current
}

function Get-JsonFirstPathValue($Object, [string[][]]$Paths) {
  foreach ($path in $Paths) {
    $value = Get-JsonPathValue $Object $path
    if ($null -ne $value) {
      return $value
    }
  }

  return $null
}

function Get-SymppPluginVersion([string]$PluginRoot) {
  $manifestPath = Join-Path $PluginRoot ".codex-plugin/plugin.json"
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    return $null
  }

  try {
    $version = [string]((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).version)
    if (-not [string]::IsNullOrWhiteSpace($version)) {
      return $version.Trim()
    }
  } catch {
  }

  return $null
}

function Get-SymppPluginName([string]$PluginRoot) {
  $manifestPath = Join-Path $PluginRoot ".codex-plugin/plugin.json"
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    return $null
  }

  try {
    $name = [string]((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).name)
    if (-not [string]::IsNullOrWhiteSpace($name)) {
      return $name.Trim()
    }
  } catch {
  }

  return $null
}

function Resolve-ExpectedSourceRevision([string]$PluginRoot) {
  $sourceCandidate = [System.IO.Path]::GetFullPath((Join-Path $PluginRoot "../.."))
  if (Test-SymphonySourceRoot $sourceCandidate) {
    return Resolve-SymppSourceRevision $sourceCandidate $PluginRoot
  }

  $marketplaceRoot = Resolve-RepoRootFromMarketplaceCache $PluginRoot
  if ($marketplaceRoot) {
    return Resolve-SymppSourceRevision $marketplaceRoot $PluginRoot
  }

  $pinnedRevision = Get-SymppPinnedSourceRevision $PluginRoot
  if ($pinnedRevision) {
    return $pinnedRevision
  }

  return $null
}

function Get-SymppArtifactManifestPath([string]$PluginRoot) {
  foreach ($relativePath in @(".sympp-runtime-artifacts.json", "assets/sympp-runtime-artifacts.json")) {
    $candidate = Join-Path $PluginRoot $relativePath
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return [System.IO.Path]::GetFullPath($candidate)
    }
  }

  return $null
}

function Read-SymppArtifactManifest([string]$PluginRoot) {
  Write-SymppLauncherTrace "artifact_manifest_resolution"
  $path = Get-SymppArtifactManifestPath $PluginRoot
  if (-not $path) {
    return $null
  }

  try {
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $manifest | Add-Member -NotePropertyName manifest_path -NotePropertyValue $path -Force
    return Resolve-SymppPublishedArtifactManifest $manifest $path
  } catch {
    throw "artifact_manifest_invalid: $path could not be parsed as JSON. detail=$($_.Exception.Message)"
  }
}

function Normalize-SymppSha256([string]$Sha256) {
  if ([string]::IsNullOrWhiteSpace($Sha256)) {
    return $null
  }

  $normalized = $Sha256.Trim().ToLowerInvariant()
  if ($normalized -match "^[0-9a-f]{64}$") {
    return $normalized
  }

  return $null
}

function Normalize-SymppArtifactArch([string]$Arch) {
  if ([string]::IsNullOrWhiteSpace($Arch)) {
    return $null
  }

  switch ($Arch.Trim().ToLowerInvariant()) {
    { $_ -in @("x64", "x86_64", "amd64") } { return "x86_64" }
    { $_ -in @("arm64", "aarch64") } { return "aarch64" }
    default { return $Arch.Trim().ToLowerInvariant() }
  }
}

function Normalize-SymppArtifactAbi([string]$Abi) {
  if ([string]::IsNullOrWhiteSpace($Abi)) {
    return $null
  }

  return $Abi.Trim().ToLowerInvariant()
}

function Test-SymppArtifactAbiMatches($Artifact) {
  $artifactAbi = Normalize-SymppArtifactAbi ([string](Get-JsonFirstPathValue $Artifact @(
      @("abi"),
      @("target_abi"),
      @("platform", "abi"),
      @("platform", "target_abi")
    )))
  if (-not $artifactAbi) {
    return $true
  }

  $runtimeAbi = Normalize-SymppArtifactAbi (Get-SymppRuntimeAbiKey)
  return $runtimeAbi -and [System.StringComparer]::OrdinalIgnoreCase.Equals($artifactAbi, $runtimeAbi)
}

function Test-SymppArtifactPlatformStringMatches([string]$ArtifactPlatform, [string]$Platform) {
  if ([string]::IsNullOrWhiteSpace($ArtifactPlatform)) {
    return $false
  }

  $artifactParts = @($ArtifactPlatform.Trim().ToLowerInvariant() -split "-")
  $runtimeParts = @($Platform.Trim().ToLowerInvariant() -split "-")
  if ($artifactParts.Count -lt 2 -or $runtimeParts.Count -lt 2) {
    return [System.StringComparer]::OrdinalIgnoreCase.Equals($ArtifactPlatform.Trim(), $Platform)
  }

  if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($artifactParts[0], $runtimeParts[0])) {
    return $false
  }
  if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals((Normalize-SymppArtifactArch $artifactParts[1]), (Normalize-SymppArtifactArch $runtimeParts[1]))) {
    return $false
  }

  if ($artifactParts.Count -ge 3) {
    return [System.StringComparer]::OrdinalIgnoreCase.Equals((Normalize-SymppArtifactAbi $artifactParts[2]), (Normalize-SymppArtifactAbi (Get-SymppRuntimeAbiKey)))
  }

  return $true
}

function Test-SymppArtifactPlatformMatches($Artifact, [string]$Platform) {
  $artifactPlatform = Get-JsonFirstPathValue $Artifact @(
    @("platform"),
    @("target"),
    @("platform_key"),
    @("platform", "key")
  )
  if ($null -ne $artifactPlatform -and $artifactPlatform -isnot [System.Management.Automation.PSCustomObject] -and -not [string]::IsNullOrWhiteSpace([string]$artifactPlatform)) {
    return (Test-SymppArtifactPlatformStringMatches ([string]$artifactPlatform) $Platform) -and (Test-SymppArtifactAbiMatches $Artifact)
  }

  $os = [string](Get-JsonFirstPathValue $Artifact @(
      @("os"),
      @("target_os"),
      @("platform", "os"),
      @("platform", "target_os")
    ))
  $arch = [string](Get-JsonFirstPathValue $Artifact @(
      @("arch"),
      @("architecture"),
      @("target_arch"),
      @("platform", "arch"),
      @("platform", "architecture"),
      @("platform", "target_arch")
    ))
  if ([string]::IsNullOrWhiteSpace($os) -or [string]::IsNullOrWhiteSpace($arch)) {
    return $false
  }

  $artifactPlatform = "$($os.Trim().ToLowerInvariant())-$(Normalize-SymppArtifactArch $arch)"
  return (Test-SymppArtifactPlatformStringMatches $artifactPlatform $Platform) -and (Test-SymppArtifactAbiMatches $Artifact)
}

function Get-SymppArtifactSourceRevisions($Artifact, [string]$ManifestSourceRevision) {
  $revisionPaths = @(
    @("source_revision"),
    @("revision"),
    @("git_revision"),
    @("release", "source_revision"),
    @("plugin", "source_revision"),
    @("source", "revision")
  )
  $normalizedRevisions = @()
  foreach ($path in $revisionPaths) {
    $revisionValue = Get-JsonPathValue $Artifact $path
    $revision = Normalize-SymppSourceRevision ([string]$revisionValue)
    if ($revision) {
      $normalizedRevisions += $revision
    }
  }
  $manifestRevision = Normalize-SymppSourceRevision $ManifestSourceRevision
  if ($manifestRevision) {
    $normalizedRevisions += $manifestRevision
  }

  return @($normalizedRevisions)
}

function Get-SymppArtifactSourceRevision($Artifact, [string]$ManifestSourceRevision) {
  $revisions = @(Get-SymppArtifactSourceRevisions $Artifact $ManifestSourceRevision)
  if ($revisions.Count -gt 0) {
    return $revisions[0]
  }

  return $null
}

function Test-SymppArtifactRevisionMatches($Artifact, [string]$ExpectedSourceRevision, [string]$ManifestSourceRevision, [bool]$RequireSourceRevision) {
  if (-not $RequireSourceRevision) {
    return $true
  }
  if ([string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) {
    return $false
  }

  $revisions = @(Get-SymppArtifactSourceRevisions $Artifact $ManifestSourceRevision)
  if ($revisions.Count -eq 0) {
    return $false
  }

  foreach ($revision in $revisions) {
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($revision, $ExpectedSourceRevision)) {
      return $false
    }
  }

  return $true
}

function Test-SymppArtifactHasSourceRevision($Artifact, [string]$ManifestSourceRevision) {
  $revisions = @(Get-SymppArtifactSourceRevisions $Artifact $ManifestSourceRevision)
  return $revisions.Count -gt 0
}

function Test-SymppArtifactContractMatches($Artifact, [string]$ExpectedContractFingerprint, [string]$ManifestContractFingerprint) {
  $artifactContract = Normalize-McpContractFingerprint ([string](Get-JsonFirstPathValue $Artifact @(
      @("mcp_contract_fingerprint"),
      @("contract_fingerprint"),
      @("launcher_contract", "mcp_contract_fingerprint"),
      @("launcher_contract", "contract_fingerprint"),
      @("runtime", "mcp_contract_fingerprint"),
      @("runtime", "contract_fingerprint")
    )))
  if (-not $artifactContract) {
    $artifactContract = Normalize-McpContractFingerprint $ManifestContractFingerprint
  }

  if (-not $artifactContract) {
    return [string]::IsNullOrWhiteSpace($ExpectedContractFingerprint)
  }

  return [System.StringComparer]::OrdinalIgnoreCase.Equals($artifactContract, $ExpectedContractFingerprint)
}

function Test-SymppArtifactManifestPluginMatches($Manifest, [string]$ExpectedPluginName, [string]$ExpectedPluginVersion, [string]$ExpectedSourceRevision, [bool]$RequireSourceRevision) {
  $requirePluginIdentity = (-not $RequireSourceRevision) -and
    -not [string]::IsNullOrWhiteSpace($ExpectedPluginName) -and
    -not [string]::IsNullOrWhiteSpace($ExpectedPluginVersion)
  $plugin = Get-JsonPathValue $Manifest @("plugin")
  if ($null -eq $plugin) {
    return -not $requirePluginIdentity
  }

  $name = [string](Get-JsonPathValue $plugin @("name"))
  $version = [string](Get-JsonPathValue $plugin @("version"))
  if (-not [string]::IsNullOrWhiteSpace($name)) {
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($name.Trim(), $ExpectedPluginName)) {
      return $false
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
      return -not $requirePluginIdentity
    }
    # Package versions can move for launcher-only fixes; runtime safety is gated by the MCP contract fingerprint.
    return $true
  }

  if ($requirePluginIdentity) {
    return $false
  }

  $packages = Get-JsonPathValue $plugin @("packages")
  foreach ($package in @($packages)) {
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals(([string]$package).Trim(), $ExpectedPluginName)) {
      return $true
    }
  }

  return $false
}

function Get-SymppArtifactCandidates($Manifest) {
  $artifactList = Get-JsonPropertyValue $Manifest @("artifacts", "runtime_artifacts")
  if ($null -ne $artifactList) {
    return @($artifactList)
  }

  if ($null -ne (Get-JsonPropertyValue $Manifest @("artifact", "archive"))) {
    return ,$Manifest
  }

  return @()
}

function Get-SymppManifestSourceRevision($Manifest, [string]$ExpectedSourceRevision, [bool]$RequireSourceRevision) {
  $manifestRevisionPaths = @(
    @("source_revision"),
    @("revision"),
    @("git_revision"),
    @("release", "source_revision"),
    @("plugin", "source_revision"),
    @("source", "revision")
  )
  $manifestRevision = $null
  foreach ($path in $manifestRevisionPaths) {
    $revision = Normalize-SymppSourceRevision ([string](Get-JsonPathValue $Manifest $path))
    if ($revision) {
      if ($RequireSourceRevision -and -not [System.StringComparer]::OrdinalIgnoreCase.Equals($revision, $ExpectedSourceRevision)) {
        return [pscustomobject]@{ revision = $revision; matches = $false }
      }
      if (-not $manifestRevision) {
        $manifestRevision = $revision
      }
    }
  }

  return [pscustomobject]@{ revision = $manifestRevision; matches = $true }
}

function Resolve-SymppArtifactCacheSourceRevision($Manifest, $Artifact, [string]$ExpectedSourceRevision, [bool]$RequireSourceRevision) {
  $manifestRevision = (Get-SymppManifestSourceRevision $Manifest $ExpectedSourceRevision $RequireSourceRevision).revision
  $artifactSourceRevision = Get-SymppArtifactSourceRevision $Artifact $manifestRevision
  if (-not [string]::IsNullOrWhiteSpace($artifactSourceRevision)) {
    return $artifactSourceRevision
  }

  return $ExpectedSourceRevision
}

function Resolve-SymppArtifactSelection($Manifest, [string]$Platform, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint, [string]$ExpectedPluginName, [string]$ExpectedPluginVersion, [bool]$RequireSourceRevision) {
  if ($null -eq $Manifest) {
    return [pscustomobject]@{ artifact = $null; detail = "manifest_missing" }
  }
  if (-not (Test-SymppArtifactManifestPluginMatches $Manifest $ExpectedPluginName $ExpectedPluginVersion $ExpectedSourceRevision $RequireSourceRevision)) {
    return [pscustomobject]@{ artifact = $null; detail = "channel_not_ready" }
  }

  $artifacts = @(Get-SymppArtifactCandidates $Manifest)
  if ($artifacts.Count -eq 0) {
    return [pscustomobject]@{ artifact = $null; detail = "channel_not_ready" }
  }

  $platformMatches = @($artifacts | Where-Object { Test-SymppArtifactPlatformMatches $_ $Platform })
  if ($platformMatches.Count -eq 0) {
    return [pscustomobject]@{ artifact = $null; detail = "platform_missing" }
  }

  $manifestRevisionResult = Get-SymppManifestSourceRevision $Manifest $ExpectedSourceRevision $RequireSourceRevision
  $manifestContract = Normalize-McpContractFingerprint ([string](Get-JsonFirstPathValue $Manifest @(
      @("mcp_contract_fingerprint"),
      @("contract_fingerprint"),
      @("launcher_contract", "mcp_contract_fingerprint"),
      @("launcher_contract", "contract_fingerprint")
    )))

  $contractMatches = @($platformMatches | Where-Object { Test-SymppArtifactContractMatches $_ $ExpectedContractFingerprint $manifestContract })
  if ($contractMatches.Count -eq 0) {
    return [pscustomobject]@{ artifact = $null; detail = "contract_mismatch" }
  }

  $matches = $contractMatches
  $detail = "selected"
  if ($RequireSourceRevision) {
    $sourceMatches = @($contractMatches | Where-Object { Test-SymppArtifactRevisionMatches $_ $ExpectedSourceRevision $manifestRevisionResult.revision $RequireSourceRevision })
    if ($sourceMatches.Count -gt 0) {
      $matches = $sourceMatches
    } elseif (-not [string]::IsNullOrWhiteSpace($ExpectedContractFingerprint)) {
      $matches = @($contractMatches | Where-Object { Test-SymppArtifactHasSourceRevision $_ $manifestRevisionResult.revision })
      if ($matches.Count -eq 0) {
        return [pscustomobject]@{ artifact = $null; detail = "source_revision_mismatch" }
      }
      $detail = "compatible_source_revision_fallback"
    } else {
      return [pscustomobject]@{ artifact = $null; detail = "source_revision_mismatch" }
    }
  }

  if ($matches.Count -eq 1) {
    return [pscustomobject]@{ artifact = $matches[0]; detail = $detail }
  }
  if ($matches.Count -gt 1) {
    throw "artifact_manifest_invalid: Symphony++ runtime artifact manifest contains multiple matching artifacts for platform $Platform."
  }

  return [pscustomobject]@{ artifact = $null; detail = "matching_artifact_missing" }
}

function Get-SymppArtifactSelectionMissDetail($Manifest, [string]$Platform, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint, [string]$ExpectedPluginName, [string]$ExpectedPluginVersion, [bool]$RequireSourceRevision) {
  return (Resolve-SymppArtifactSelection $Manifest $Platform $ExpectedSourceRevision $ExpectedContractFingerprint $ExpectedPluginName $ExpectedPluginVersion $RequireSourceRevision).detail
}

function Select-SymppArtifact($Manifest, [string]$Platform, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint, [string]$ExpectedPluginName, [string]$ExpectedPluginVersion, [bool]$RequireSourceRevision = $true) {
  return (Resolve-SymppArtifactSelection $Manifest $Platform $ExpectedSourceRevision $ExpectedContractFingerprint $ExpectedPluginName $ExpectedPluginVersion $RequireSourceRevision).artifact
}

function Assert-SymppRelativeArtifactPath([string]$Path, [string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Label must be present in the Symphony++ runtime artifact manifest."
  }

  if ([System.IO.Path]::IsPathRooted($Path) -or $Path.Contains("..")) {
    throw "$Label must be a relative path inside the extracted Symphony++ runtime artifact."
  }
}

function Assert-SymppSingleArtifactSourceLocation($Artifact) {
  $primaryLocations = @(
    @("url"),
    @("download_url"),
    @("uri"),
    @("path"),
    @("relative_path"),
    @("archive", "url"),
    @("archive", "download_url"),
    @("archive", "uri"),
    @("archive", "path"),
    @("archive", "relative_path"),
    @("artifact", "url"),
    @("artifact", "download_url"),
    @("artifact", "uri"),
    @("artifact", "path"),
    @("artifact", "relative_path")
  )
  $declared = @()
  foreach ($path in $primaryLocations) {
    $value = [string](Get-JsonPathValue $Artifact $path)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      $declared += ($path -join ".")
    }
  }

  if ($declared.Count -gt 1) {
    throw "artifact_manifest_invalid: selected Symphony++ runtime artifact declares multiple archive locations: $($declared -join ', ')."
  }
}

function Resolve-SymppArtifactSourceUri($Artifact, [string]$ManifestPath) {
  Assert-SymppSingleArtifactSourceLocation $Artifact
  $value = [string](Get-JsonFirstPathValue $Artifact @(
      @("url"),
      @("download_url"),
      @("uri"),
      @("path"),
      @("relative_path"),
      @("archive", "url"),
      @("archive", "download_url"),
      @("archive", "uri"),
      @("archive", "path"),
      @("archive", "relative_path"),
      @("artifact", "url"),
      @("artifact", "download_url"),
      @("artifact", "uri"),
      @("artifact", "path"),
      @("artifact", "relative_path")
    ))
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "artifact_missing: selected Symphony++ runtime artifact does not declare url, download_url, uri, or path."
  }

  if ([System.Uri]::IsWellFormedUriString($value, [System.UriKind]::Absolute)) {
    return $value
  }
  if ([System.IO.Path]::IsPathRooted($value)) {
    return [System.IO.Path]::GetFullPath($value)
  }

  $manifestDir = Split-Path -Parent $ManifestPath
  return [System.IO.Path]::GetFullPath((Join-Path $manifestDir $value))
}

function Assert-SymppArtifactSourceUsable([string]$SourceUri) {
  if ([System.Uri]::IsWellFormedUriString($SourceUri, [System.UriKind]::Absolute)) {
    $uri = [System.Uri]$SourceUri
    if ($uri.Scheme -eq "file") {
      if (-not (Test-Path -LiteralPath $uri.LocalPath -PathType Leaf)) {
        throw "artifact_missing: selected Symphony++ runtime artifact file does not exist: $($uri.LocalPath)"
      }
      return
    }
    if ($uri.Scheme -eq "https" -or ($uri.Scheme -eq "http" -and $uri.IsLoopback)) {
      return
    }
    throw "artifact_download_blocked: Symphony++ runtime artifacts must use https, file, or loopback http URLs."
  }

  if (-not (Test-Path -LiteralPath $SourceUri -PathType Leaf)) {
    throw "artifact_missing: selected Symphony++ runtime artifact file does not exist: $SourceUri"
  }
}

function Resolve-SymppArtifactEntrypoint($Artifact) {
  $entrypoint = [string](Get-JsonFirstPathValue $Artifact @(
      @("entrypoint"),
      @("backend_entrypoint"),
      @("command"),
      @("runtime", "command"),
      @("runtime", "entrypoint"),
      @("backend", "entrypoint"),
      @("backend", "entrypoints", $(if (Test-SymppWindowsPlatform) { "windows" } else { "unix" }))
    ))
  if ([string]::IsNullOrWhiteSpace($entrypoint)) {
    $entrypoint = if (Test-SymppWindowsPlatform) { "start-runtime.ps1" } else { "start-runtime.sh" }
  }

  Assert-SymppRelativeArtifactPath $entrypoint "artifact entrypoint"
  return $entrypoint.Replace("\", "/")
}

function Resolve-SymppArtifactWorkflow($Artifact) {
  $workflow = [string](Get-JsonFirstPathValue $Artifact @(
      @("workflow"),
      @("workflow_path"),
      @("runtime", "workflow"),
      @("runtime", "workflow_path"),
      @("launcher_contract", "workflow"),
      @("launcher_contract", "workflow_path")
    ))
  if ([string]::IsNullOrWhiteSpace($workflow)) {
    return $null
  }

  Assert-SymppRelativeArtifactPath $workflow "artifact workflow"
  return $workflow.Replace("\", "/")
}

function Resolve-SymppArtifactRuntimeArgs($Artifact) {
  $argsValue = Get-JsonFirstPathValue $Artifact @(
    @("runtime_args"),
    @("runtime", "args"),
    @("command_args"),
    @("args")
  )
  if ($null -eq $argsValue) {
    return $null
  }

  $args = @()
  if ($argsValue -is [array]) {
    foreach ($arg in $argsValue) {
      $args += [string]$arg
    }
  } else {
    $args += [string]$argsValue
  }

  return $args
}

function Resolve-SymppArtifactDashboardRoot($Artifact) {
  $dashboardRoot = [string](Get-JsonFirstPathValue $Artifact @(
      @("dashboard", "asset_root"),
      @("dashboard", "assets_root"),
      @("dashboard", "path"),
      @("dashboard", "relative_path"),
      @("dashboard_assets", "root"),
      @("dashboard_assets", "path"),
      @("dashboard_assets", "relative_path"),
      @("frontend", "asset_root"),
      @("frontend", "assets_root")
    ))
  if ([string]::IsNullOrWhiteSpace($dashboardRoot)) {
    return $null
  }

  Assert-SymppRelativeArtifactPath $dashboardRoot "artifact dashboard asset root"
  return $dashboardRoot.Replace("\", "/")
}

function Resolve-SymppArtifactDashboardFingerprint($Artifact) {
  $fingerprint = [string](Get-JsonFirstPathValue $Artifact @(
      @("dashboard", "fingerprint"),
      @("dashboard", "asset_fingerprint"),
      @("dashboard", "assets_fingerprint"),
      @("dashboard", "sha256"),
      @("dashboard", "digest"),
      @("dashboard_assets", "fingerprint"),
      @("dashboard_assets", "sha256"),
      @("dashboard_assets", "digest"),
      @("frontend", "asset_fingerprint"),
      @("frontend", "assets_fingerprint")
    ))
  if ([string]::IsNullOrWhiteSpace($fingerprint)) {
    return $null
  }

  $normalized = Normalize-SymppSha256 $fingerprint
  if (-not $normalized) {
    throw "artifact_manifest_invalid: artifact dashboard asset fingerprint must be a sha256 hex digest."
  }

  return $normalized
}

function Get-SymppArtifactSha256($Artifact) {
  return Normalize-SymppSha256 ([string](Get-JsonFirstPathValue $Artifact @(
        @("sha256"),
        @("sha256sum"),
        @("digest"),
        @("archive", "sha256"),
        @("archive", "sha256sum"),
        @("archive", "digest"),
        @("artifact", "sha256"),
        @("artifact", "sha256sum"),
        @("artifact", "digest")
      )))
}
