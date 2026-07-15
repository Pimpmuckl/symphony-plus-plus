function Test-DiagnosticRuntimeArtifactSourceFallbackAllowed([string]$Root, [string]$SourceRoot) {
  if (Import-DiagnosticMcpArtifactHelpers $Root) {
    $explicitRepoRoot = -not [string]::IsNullOrWhiteSpace($script:RepoRoot)
    return (Test-SourceFallbackAllowed $Root) -or ($explicitRepoRoot -and (Test-SourceCheckoutRoot $script:RepoRoot))
  }

  if (Get-SourceCheckoutFromPluginRoot $Root) {
    return $true
  }

  return (Test-DiagnosticEnvEnabled "SYMPP_DEVELOPER_MODE") -or
    (Test-DiagnosticEnvEnabled "SYMPP_SOURCE_FALLBACK") -or
    (Test-DiagnosticEnvEnabled "SYMPP_ALLOW_SOURCE_COMPILE")
}

function Resolve-DiagnosticRuntimeArtifactExpectedRevision([string]$Root, [string]$SourceRoot) {
  if (Import-DiagnosticMcpArtifactHelpers $Root) {
    return Resolve-ExpectedSourceRevision $Root
  }

  $pinnedRevision = Get-DiagnosticPinnedRevision $Root
  if ($pinnedRevision) {
    return $pinnedRevision
  }

  $sourceCandidate = Resolve-OptionalFullPath (Join-Path $Root "../..")
  if (Test-SourceCheckoutRoot $sourceCandidate) {
    return Get-DiagnosticGitHeadRevision $sourceCandidate
  }

  return $null
}

function Import-DiagnosticMcpArtifactHelpers([string]$Root) {
  $scriptsRoot = Join-Path $Root "scripts"
  $requiredScripts = @(
    "sympp-launcher-runtime.ps1",
    "sympp-mcp-launcher-helpers.ps1",
    "sympp-mcp-artifact-channel.ps1",
    "sympp-mcp-artifact-manifest.ps1",
    "sympp-mcp-artifact-runtime.ps1",
    "sympp-mcp-process-runtime.ps1"
  )

  foreach ($scriptName in $requiredScripts) {
    if (-not (Test-Path -LiteralPath (Join-Path $scriptsRoot $scriptName) -PathType Leaf)) {
      return $false
    }
  }

  foreach ($scriptName in $requiredScripts) {
    . (Join-Path $scriptsRoot $scriptName)
  }
  $promotedPrefixes = @(
    "Assert-Sympp",
    "Convert-Sympp",
    "Copy-Sympp",
    "Ensure-Sympp",
    "Enter-FileLock",
    "Exit-FileLock",
    "Expand-Sympp",
    "Get-EnvMode",
    "Get-FileSha256",
    "Get-Json",
    "Get-Sympp",
    "New-Sympp",
    "Normalize-Mcp",
    "Normalize-Sympp",
    "Read-Sympp",
    "Resolve-ExpectedSourceRevision",
    "Resolve-OptionalPath",
    "Resolve-RepoRootFromMarketplaceCache",
    "Resolve-Sympp",
    "Select-Sympp",
    "Set-Sympp",
    "Test-ArtifactRuntimeAllowed",
    "Test-EnvEnabled",
    "Test-InstalledPluginPayloadMatchesMarketplaceSource",
    "Test-SourceCheckout",
    "Test-SourceFallbackAllowed",
    "Test-SymphonySourceRoot",
    "Test-Sympp",
    "Write-SymppLauncherTrace"
  )
  foreach ($command in @(Get-Command -CommandType Function)) {
    foreach ($prefix in $promotedPrefixes) {
      if ($command.Name.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
        Set-Item -Path "function:script:$($command.Name)" -Value $command.ScriptBlock -Force
        break
      }
    }
  }
  return $true
}

function Get-DiagnosticRuntimeArtifactLaunchBlockReason($Runtime, [string]$Root, [bool]$CacheReady) {
  $bridgeMode = Get-EnvMode "SYMPP_MCP_BRIDGE_MODE" "http" @("http", "direct_stdio")
  if ($bridgeMode -eq "direct_stdio") {
    return "direct_stdio_unsupported"
  }

  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
    return "database_unsupported"
  }

  return $null
}

function Get-DiagnosticRuntimeArtifactStatusFromLauncherHelpers([string]$Root, [string]$ExpectedRevision = $null) {
  $platform = Get-SymppRuntimePlatformKey
  if ([string]::IsNullOrWhiteSpace($platform)) {
    return [pscustomobject]@{ status = "artifact_missing"; detail = "platform_unknown"; platform = $platform; manifest_path = $null }
  }

  if (-not (Test-ArtifactRuntimeAllowed $Root)) {
    return [pscustomobject]@{ status = "artifact_skipped"; detail = "artifact_runtime_disabled"; platform = $platform; manifest_path = (Get-SymppArtifactManifestPath $Root) }
  }

  try {
    $manifest = Read-SymppArtifactManifest $Root
  } catch {
    return [pscustomobject]@{ status = "artifact_manifest_invalid"; detail = $_.Exception.Message; platform = $platform; manifest_path = (Get-SymppArtifactManifestPath $Root) }
  }
  if ($null -eq $manifest) {
    return [pscustomobject]@{ status = "artifact_missing"; detail = "manifest_missing"; platform = $platform; manifest_path = $null }
  }

  $expectedRevision = Normalize-SymppSourceRevision $ExpectedRevision
  $expectedContract = Get-DiagnosticExpectedMcpContractFingerprint $Root
  $pluginName = Get-SymppPluginName $Root
  $pluginVersion = Get-SymppPluginVersion $Root
  $requireSourceRevision = Test-SourceCheckoutLaunch $Root
  try {
    $artifact = Select-SymppArtifact $manifest $platform $expectedRevision $expectedContract $pluginName $pluginVersion $requireSourceRevision
  } catch {
    return [pscustomobject]@{ status = "artifact_manifest_invalid"; detail = $_.Exception.Message; platform = $platform; manifest_path = $manifest.manifest_path }
  }
  if ($null -eq $artifact) {
    $detail = Get-SymppArtifactSelectionMissDetail $manifest $platform $expectedRevision $expectedContract $pluginName $pluginVersion $requireSourceRevision
    return [pscustomobject]@{ status = "artifact_missing"; detail = $detail; platform = $platform; manifest_path = $manifest.manifest_path }
  }

  try {
    $sha256 = Get-SymppArtifactSha256 $artifact
    if (-not $sha256) {
      return [pscustomobject]@{ status = "artifact_verification_failed"; detail = "sha256_missing_or_invalid"; platform = $platform; manifest_path = $manifest.manifest_path }
    }

    $entrypoint = Resolve-SymppArtifactEntrypoint $artifact
    $dashboardRoot = Resolve-SymppArtifactDashboardRoot $artifact
    $dashboardFingerprint = Resolve-SymppArtifactDashboardFingerprint $artifact
    if ([string]::IsNullOrWhiteSpace($dashboardRoot) -or [string]::IsNullOrWhiteSpace($dashboardFingerprint)) {
      return [pscustomobject]@{ status = "artifact_verification_failed"; detail = "artifact_manifest_invalid: selected Symphony++ runtime artifact must declare dashboard asset_root and fingerprint."; platform = $platform; manifest_path = $manifest.manifest_path }
    }
    $workflow = Resolve-SymppArtifactWorkflow $artifact
    $runtimeArgs = Resolve-SymppArtifactRuntimeArgs $artifact
  } catch {
    return [pscustomobject]@{ status = "artifact_verification_failed"; detail = $_.Exception.Message; platform = $platform; manifest_path = $manifest.manifest_path }
  }

  $cacheSourceRevision = Resolve-SymppArtifactCacheSourceRevision $manifest $artifact $expectedRevision $requireSourceRevision
  $cacheRoot = Resolve-SymppArtifactCacheRoot $platform $cacheSourceRevision $pluginVersion $sha256
  $extractRoot = Join-Path $cacheRoot "runtime"
  $runtime = New-SymppArtifactRuntimeDescriptor $extractRoot $entrypoint $workflow $runtimeArgs $sha256 $platform $cacheSourceRevision $pluginVersion $manifest.manifest_path $dashboardRoot $dashboardFingerprint
  $cacheReady = Test-SymppArtifactCacheReady $extractRoot $entrypoint $sha256 $dashboardRoot $dashboardFingerprint
  $launchBlockReason = Get-DiagnosticRuntimeArtifactLaunchBlockReason $runtime $Root $cacheReady
  if ($launchBlockReason) {
    return [pscustomobject]@{ status = "artifact_unavailable"; detail = $launchBlockReason; platform = $platform; manifest_path = $manifest.manifest_path; cache_root = $cacheRoot }
  }

  if ($cacheReady) {
    return [pscustomobject]@{ status = "ready"; detail = "cache_ready"; platform = $platform; manifest_path = $manifest.manifest_path; cache_root = $cacheRoot }
  }

  $archivePath = Join-Path $cacheRoot "artifact.zip"
  if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
    $actual = Get-FileSha256 $archivePath
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($actual, $sha256)) {
      return [pscustomobject]@{ status = "artifact_verification_failed"; detail = "cached_archive_sha256_mismatch"; platform = $platform; manifest_path = $manifest.manifest_path; cache_root = $cacheRoot }
    }

    return [pscustomobject]@{ status = "artifact_selected"; detail = "archive_cached"; platform = $platform; manifest_path = $manifest.manifest_path; cache_root = $cacheRoot }
  }

  try {
    $sourceUri = Resolve-SymppArtifactSourceUri $artifact $manifest.manifest_path
    Assert-SymppArtifactSourceUsable $sourceUri
  } catch {
    return [pscustomobject]@{ status = "artifact_verification_failed"; detail = $_.Exception.Message; platform = $platform; manifest_path = $manifest.manifest_path; cache_root = $cacheRoot }
  }

  return [pscustomobject]@{ status = "artifact_selected"; detail = "download_required"; platform = $platform; manifest_path = $manifest.manifest_path; cache_root = $cacheRoot }
}
