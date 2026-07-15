$ErrorActionPreference = "Stop"

function Test-EnvEnabled([string]$Name) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $false
  }

  return $value.Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")
}

function Test-SourceCheckoutLaunch([string]$PluginRoot) {
  $sourceCandidate = [System.IO.Path]::GetFullPath((Join-Path $PluginRoot "../.."))
  return Test-SymphonySourceRoot $sourceCandidate
}

function Test-SourceFallbackAllowed([string]$PluginRoot) {
  if (Test-SourceCheckoutLaunch $PluginRoot) {
    return $true
  }

  return (Test-EnvEnabled "SYMPP_DEVELOPER_MODE") -or
    (Test-EnvEnabled "SYMPP_SOURCE_FALLBACK") -or
    (Test-EnvEnabled "SYMPP_ALLOW_SOURCE_COMPILE")
}

function Test-ArtifactRuntimeAllowed([string]$PluginRoot) {
  if (Test-EnvEnabled "SYMPP_ARTIFACT_RUNTIME") {
    return $true
  }

  return -not (Test-SourceCheckoutLaunch $PluginRoot)
}

function Resolve-SymppArtifactCacheRoot([string]$Platform, [string]$SourceRevision, [string]$PluginVersion, [string]$Sha256) {
  $revisionKey = if (-not [string]::IsNullOrWhiteSpace($SourceRevision)) {
    $SourceRevision.Substring(0, [Math]::Min(12, $SourceRevision.Length))
  } elseif (-not [string]::IsNullOrWhiteSpace($PluginVersion)) {
    $PluginVersion -replace "[^A-Za-z0-9_.-]", "_"
  } else {
    "unknown"
  }
  $shaKey = $Sha256.Substring(0, 16)
  return [System.IO.Path]::GetFullPath((Join-Path (Resolve-SymppPluginHome) "artifacts/mcp/$Platform/$revisionKey/$shaKey"))
}

function New-SymppArtifactRuntimeDescriptor([string]$ExtractRoot, [string]$Entrypoint, [string]$Workflow, [string[]]$RuntimeArgs, [string]$Sha256, [string]$Platform, [string]$SourceRevision, [string]$PluginVersion, [string]$ManifestPath, [string]$DashboardRoot, [string]$DashboardFingerprint) {
  $runtimeArgList = @()
  foreach ($arg in @($RuntimeArgs)) {
    if ($null -ne $arg) {
      $runtimeArgList += [string]$arg
    }
  }

  return [pscustomobject]@{
    root = [System.IO.Path]::GetFullPath($ExtractRoot)
    entrypoint = [System.IO.Path]::GetFullPath((Join-Path $ExtractRoot $Entrypoint))
    entrypoint_relative = $Entrypoint
    workflow = if ($Workflow) { [System.IO.Path]::GetFullPath((Join-Path $ExtractRoot $Workflow)) } else { $null }
    dashboard_root = if ($DashboardRoot) { [System.IO.Path]::GetFullPath((Join-Path $ExtractRoot $DashboardRoot)) } else { $null }
    dashboard_fingerprint = $DashboardFingerprint
    runtime_args = if ($runtimeArgList.Count -gt 0) { $runtimeArgList } else { $null }
    command_contract = "runtime_wrapper"
    sha256 = $Sha256
    platform = $Platform
    source_revision = $SourceRevision
    plugin_version = $PluginVersion
    manifest_path = $ManifestPath
  }
}

function Get-SymppArtifactDirectoryFingerprint([string]$Root) {
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    return $null
  }

  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName)) {
    $relativePath = [System.IO.Path]::GetRelativePath($Root, $file.FullName).Replace("\", "/")
    $lines.Add("$relativePath $(Get-FileSha256 $file.FullName)")
  }

  $payload = [string]::Join("`n", $lines)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Test-SymppArtifactDashboardReady([string]$ExtractRoot, [string]$DashboardRoot, [string]$DashboardFingerprint) {
  if ([string]::IsNullOrWhiteSpace($DashboardRoot)) {
    return $false
  }

  $dashboardPath = Join-Path $ExtractRoot $DashboardRoot
  if (-not (Test-Path -LiteralPath $dashboardPath -PathType Container)) {
    return $false
  }
  if ([string]::IsNullOrWhiteSpace($DashboardFingerprint)) {
    return $false
  }

  $actual = Get-SymppArtifactDirectoryFingerprint $dashboardPath
  return $actual -and [System.StringComparer]::OrdinalIgnoreCase.Equals($actual, $DashboardFingerprint)
}

function Test-SymppArtifactCacheReady([string]$ExtractRoot, [string]$Entrypoint, [string]$Sha256, [string]$DashboardRoot, [string]$DashboardFingerprint) {
  $markerPath = Join-Path $ExtractRoot ".sympp-artifact.json"
  $entrypointPath = Join-Path $ExtractRoot $Entrypoint
  if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $entrypointPath -PathType Leaf)) {
    return $false
  }

  try {
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$marker.sha256, $Sha256)) {
      return $false
    }
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$marker.dashboard_root, $DashboardRoot)) {
      return $false
    }
    if ([string]::IsNullOrWhiteSpace($DashboardFingerprint)) {
      return $false
    }
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$marker.dashboard_fingerprint, $DashboardFingerprint)) {
      return $false
    }
    return Test-SymppArtifactDashboardReady $ExtractRoot $DashboardRoot $DashboardFingerprint
  } catch {
    return $false
  }
}

function Assert-SymppArtifactArchiveVerified([string]$ArchivePath, [string]$ExpectedSha256) {
  $actual = Get-FileSha256 $ArchivePath
  if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($actual, $ExpectedSha256)) {
    throw "artifact_verification_failed: expected sha256 $ExpectedSha256 but got $actual for $ArchivePath."
  }
}

function Copy-SymppArtifactArchive([string]$SourceUri, [string]$TargetPath) {
  $targetDir = Split-Path -Parent $TargetPath
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
  $tempPath = "$TargetPath.tmp-$PID"

  try {
    if ([System.Uri]::IsWellFormedUriString($SourceUri, [System.UriKind]::Absolute)) {
      $uri = [System.Uri]$SourceUri
      if ($uri.Scheme -eq "file") {
        Copy-Item -LiteralPath $uri.LocalPath -Destination $tempPath -Force
      } elseif ($uri.Scheme -eq "https" -or ($uri.Scheme -eq "http" -and $uri.IsLoopback)) {
        Invoke-WebRequest -Uri $SourceUri -OutFile $tempPath -UseBasicParsing
      } else {
        throw "artifact_download_blocked: Symphony++ runtime artifacts must use https, file, or loopback http URLs."
      }
    } else {
      Copy-Item -LiteralPath $SourceUri -Destination $tempPath -Force
    }

    Move-Item -LiteralPath $tempPath -Destination $TargetPath -Force
  } finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
  }
}

function Expand-SymppArtifactArchive([string]$ArchivePath, [string]$ExtractRoot, [string]$Entrypoint, [string]$Sha256, [string]$Platform, [string]$SourceRevision, [string]$PluginVersion, [string]$ManifestPath, [string]$DashboardRoot, [string]$DashboardFingerprint) {
  $parent = Split-Path -Parent $ExtractRoot
  $staging = "$ExtractRoot.extracting-$PID"
  Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  try {
    Write-Diagnostic "artifact_extracting: extracting verified Symphony++ runtime artifact to $ExtractRoot."
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $staging -Force
    $entrypointPath = Join-Path $staging $Entrypoint
    if (-not (Test-Path -LiteralPath $entrypointPath -PathType Leaf)) {
      throw "artifact_missing: extracted Symphony++ runtime artifact did not contain entrypoint $Entrypoint."
    }
    if (-not (Test-SymppWindowsPlatform)) {
      try {
        & chmod +x $entrypointPath
        if ($LASTEXITCODE -ne 0) {
          throw "chmod exited with $LASTEXITCODE"
        }
      } catch {
        throw "artifact_verification_failed: could not mark extracted Symphony++ runtime artifact entrypoint executable. detail=$($_.Exception.Message)"
      }
    }

    $effectiveDashboardFingerprint = $DashboardFingerprint
    if ([string]::IsNullOrWhiteSpace($effectiveDashboardFingerprint)) {
      $effectiveDashboardFingerprint = Get-SymppArtifactDirectoryFingerprint (Join-Path $staging $DashboardRoot)
    }
    if (-not (Test-SymppArtifactDashboardReady $staging $DashboardRoot $effectiveDashboardFingerprint)) {
      throw "artifact_verification_failed: extracted Symphony++ runtime artifact dashboard assets did not match declared fingerprint."
    }

    $marker = [pscustomobject]@{
      sha256 = $Sha256
      platform = $Platform
      source_revision = $SourceRevision
      plugin_version = $PluginVersion
      manifest_path = $ManifestPath
      dashboard_root = $DashboardRoot
      dashboard_fingerprint = $effectiveDashboardFingerprint
      extracted_at = (Get-Date).ToString("o")
    }
    $marker | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $staging ".sympp-artifact.json") -Encoding UTF8
    Remove-Item -LiteralPath $ExtractRoot -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $staging -Destination $ExtractRoot -Force
  } finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Ensure-SymppArtifactPrepared(
  [object]$Artifact,
  [string]$ManifestPath,
  [string]$CacheRoot,
  [string]$ArchivePath,
  [string]$ExtractRoot,
  [string]$Entrypoint,
  [string]$Sha256,
  [string]$Platform,
  [string]$SourceRevision,
  [string]$PluginVersion,
  [string]$DashboardRoot,
  [string]$DashboardFingerprint
) {
  if (Test-SymppArtifactCacheReady $ExtractRoot $Entrypoint $Sha256 $DashboardRoot $DashboardFingerprint) {
    return "cache_ready"
  }

  $lock = Enter-FileLock (Join-Path $CacheRoot "artifact.lock") 600
  try {
    if (Test-SymppArtifactCacheReady $ExtractRoot $Entrypoint $Sha256 $DashboardRoot $DashboardFingerprint) {
      return "cache_ready"
    }

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
      $sourceUri = Resolve-SymppArtifactSourceUri $Artifact $ManifestPath
      Assert-SymppArtifactSourceUsable $sourceUri
      Write-Diagnostic "artifact_downloading: downloading Symphony++ runtime artifact for $Platform."
      Copy-SymppArtifactArchive $sourceUri $ArchivePath
    }

    try {
      Assert-SymppArtifactArchiveVerified $ArchivePath $Sha256
    } catch {
      $sourceUri = Resolve-SymppArtifactSourceUri $Artifact $ManifestPath
      Assert-SymppArtifactSourceUsable $sourceUri
      Write-Diagnostic "artifact_redownloading: cached Symphony++ runtime artifact failed verification; downloading again. detail=$($_.Exception.Message)"
      Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
      Copy-SymppArtifactArchive $sourceUri $ArchivePath
    }

    Assert-SymppArtifactArchiveVerified $ArchivePath $Sha256
    Expand-SymppArtifactArchive $ArchivePath $ExtractRoot $Entrypoint $Sha256 $Platform $SourceRevision $PluginVersion $ManifestPath $DashboardRoot $DashboardFingerprint
    return "cache_prepared"
  } finally {
    Exit-FileLock $lock
  }
}

function Resolve-SymppPreparedArtifactRuntime([string]$PluginRoot, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint, [switch]$ValidateOnly, [switch]$PrepareArtifact) {
  $platform = Get-SymppRuntimePlatformKey
  if ([string]::IsNullOrWhiteSpace($platform)) {
    return [pscustomobject]@{ status = "artifact_missing"; detail = "platform_unknown"; runtime = $null }
  }

  $manifest = Read-SymppArtifactManifest $PluginRoot
  if ($null -eq $manifest) {
    return [pscustomobject]@{ status = "artifact_missing"; detail = "manifest_missing"; platform = $platform; runtime = $null }
  }

  $pluginName = Get-SymppPluginName $PluginRoot
  $pluginVersion = Get-SymppPluginVersion $PluginRoot
  $requireSourceRevision = Test-SourceCheckoutLaunch $PluginRoot
  $artifact = Select-SymppArtifact $manifest $platform $ExpectedSourceRevision $ExpectedContractFingerprint $pluginName $pluginVersion $requireSourceRevision
  if ($null -eq $artifact) {
    $detail = Get-SymppArtifactSelectionMissDetail $manifest $platform $ExpectedSourceRevision $ExpectedContractFingerprint $pluginName $pluginVersion $requireSourceRevision
    return [pscustomobject]@{ status = "artifact_missing"; detail = $detail; platform = $platform; manifest_path = $manifest.manifest_path; runtime = $null }
  }

  $sha256 = Get-SymppArtifactSha256 $artifact
  if (-not $sha256) {
    throw "artifact_verification_failed: selected Symphony++ runtime artifact does not declare a valid sha256."
  }

  $entrypoint = Resolve-SymppArtifactEntrypoint $artifact
  $workflow = Resolve-SymppArtifactWorkflow $artifact
  $dashboardRoot = Resolve-SymppArtifactDashboardRoot $artifact
  $dashboardFingerprint = Resolve-SymppArtifactDashboardFingerprint $artifact
  if ([string]::IsNullOrWhiteSpace($dashboardRoot)) {
    throw "artifact_manifest_invalid: selected Symphony++ runtime artifact must declare dashboard asset_root."
  }
  $runtimeArgs = Resolve-SymppArtifactRuntimeArgs $artifact
  $cacheSourceRevision = Resolve-SymppArtifactCacheSourceRevision $manifest $artifact $ExpectedSourceRevision $requireSourceRevision
  $cacheRoot = Resolve-SymppArtifactCacheRoot $platform $cacheSourceRevision $pluginVersion $sha256
  $extractRoot = Join-Path $cacheRoot "runtime"
  $archivePath = Join-Path $cacheRoot "artifact.zip"
  $runtimeDescriptor = New-SymppArtifactRuntimeDescriptor $extractRoot $entrypoint $workflow $runtimeArgs $sha256 $platform $cacheSourceRevision $pluginVersion $manifest.manifest_path $dashboardRoot $dashboardFingerprint

  if ($ValidateOnly) {
    if (-not $PrepareArtifact) {
      return [pscustomobject]@{
        status = "artifact_selected"
        detail = "metadata_selected"
        platform = $platform
        manifest_path = $manifest.manifest_path
        cache_root = $cacheRoot
        runtime = $runtimeDescriptor
        selected_artifact = $artifact
      }
    }

    $prepareDetail = Ensure-SymppArtifactPrepared $artifact $manifest.manifest_path $cacheRoot $archivePath $extractRoot $entrypoint $sha256 $platform $cacheSourceRevision $pluginVersion $dashboardRoot $dashboardFingerprint
    return [pscustomobject]@{
      status = "artifact_selected"
      detail = $prepareDetail
      platform = $platform
      manifest_path = $manifest.manifest_path
      cache_root = $cacheRoot
      runtime = $runtimeDescriptor
    }
  }

  $prepareDetail = Ensure-SymppArtifactPrepared $artifact $manifest.manifest_path $cacheRoot $archivePath $extractRoot $entrypoint $sha256 $platform $cacheSourceRevision $pluginVersion $dashboardRoot $dashboardFingerprint
  if ($prepareDetail -eq "cache_ready") {
    Write-Diagnostic "ready: reusing verified Symphony++ runtime artifact at $extractRoot."
  }

  return [pscustomobject]@{
    status = "ready"
    detail = "artifact_ready"
    platform = $platform
    manifest_path = $manifest.manifest_path
    cache_root = $cacheRoot
    runtime = $runtimeDescriptor
  }
}

function Resolve-SymppArtifactProbe([string]$PluginRoot, [string]$ExpectedSourceRevision, [string]$ExpectedContractFingerprint, [bool]$ArtifactRuntimeAllowed, [bool]$SourceFallbackAllowed, [switch]$ValidateOnly, [switch]$PrepareArtifact) {
  if (-not $ArtifactRuntimeAllowed) {
    return [pscustomobject]@{
      status = "artifact_skipped"
      detail = "source_checkout"
      platform = Get-SymppRuntimePlatformKey
      runtime = $null
    }
  }

  try {
    return Resolve-SymppPreparedArtifactRuntime $PluginRoot $ExpectedSourceRevision $ExpectedContractFingerprint -ValidateOnly:$ValidateOnly -PrepareArtifact:$PrepareArtifact
  } catch {
    if ($SourceFallbackAllowed) {
      return [pscustomobject]@{
        status = "artifact_unavailable"
        detail = $_.Exception.Message
        platform = Get-SymppRuntimePlatformKey
        runtime = $null
      }
    }

    throw
  }
}

function Resolve-LaunchArtifactSelection(
  [string]$PluginRoot,
  [string]$RepoRoot,
  $ArtifactProbe,
  [string]$ExpectedSourceRevision,
  [string]$ExpectedContractFingerprint,
  [bool]$ArtifactRuntimeAllowed,
  [bool]$SourceFallbackAllowed
) {
  $artifactRuntime = $null
  $runtimeMode = "source"
  $sourceRevision = $ExpectedSourceRevision

  if ($ArtifactProbe.status -eq "ready" -or $ArtifactProbe.status -eq "artifact_selected") {
    try {
      $preparedArtifact = if ($ArtifactProbe.status -eq "ready" -and $ArtifactProbe.runtime) {
        $ArtifactProbe
      } elseif ($ArtifactProbe.PSObject.Properties["selected_artifact"] -and $ArtifactProbe.selected_artifact -and $ArtifactProbe.runtime) {
        $runtime = $ArtifactProbe.runtime
        $dashboardRoot = [System.IO.Path]::GetRelativePath([string]$runtime.root, [string]$runtime.dashboard_root)
        $prepareDetail = Ensure-SymppArtifactPrepared $ArtifactProbe.selected_artifact $ArtifactProbe.manifest_path $ArtifactProbe.cache_root (Join-Path $ArtifactProbe.cache_root "artifact.zip") $runtime.root $runtime.entrypoint_relative $runtime.sha256 $runtime.platform $runtime.source_revision $runtime.plugin_version $dashboardRoot $runtime.dashboard_fingerprint
        if ($prepareDetail -eq "cache_ready") {
          Write-Diagnostic "ready: reusing verified Symphony++ runtime artifact at $($runtime.root)."
        }
        [pscustomobject]@{ status = "ready"; detail = "artifact_ready"; runtime = $runtime }
      } else {
        Resolve-SymppArtifactProbe $PluginRoot $sourceRevision $ExpectedContractFingerprint $ArtifactRuntimeAllowed $SourceFallbackAllowed
      }
      if ($preparedArtifact.status -eq "ready" -and $preparedArtifact.runtime) {
        $artifactRuntime = $preparedArtifact.runtime
        $runtimeMode = "artifact"
        $sourceRevision = [string]$artifactRuntime.source_revision
        Set-SymppSourceRevisionEnvironment $sourceRevision
        Write-Diagnostic "ready: verified Symphony++ runtime artifact selected for $($artifactRuntime.platform)."
      } elseif (-not $SourceFallbackAllowed) {
        Write-Diagnostic "$($preparedArtifact.status): $($preparedArtifact.detail)"
        Write-Diagnostic "source_fallback_disabled: set SYMPP_SOURCE_FALLBACK=1 or SYMPP_DEVELOPER_MODE=1 to compile from a source checkout."
        throw "source_fallback_disabled: no verified Symphony++ runtime artifact is ready for this installed launcher."
      }
    } catch {
      if (-not $SourceFallbackAllowed) {
        Write-Diagnostic "source_fallback_disabled: set SYMPP_SOURCE_FALLBACK=1 or SYMPP_DEVELOPER_MODE=1 to compile from a source checkout."
        throw
      }
      Write-Diagnostic "source_fallback_compiling: artifact startup failed under explicit source fallback control. detail=$($_.Exception.Message)"
      if ([string]::IsNullOrWhiteSpace($sourceRevision) -and -not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $sourceRevision = Resolve-SymppSourceRevision $RepoRoot $PluginRoot
        Set-SymppSourceRevisionEnvironment $sourceRevision
      }
    }
  } elseif ($ArtifactProbe.status -eq "artifact_unavailable" -and $SourceFallbackAllowed) {
    Write-Diagnostic "source_fallback_compiling: artifact probe failed under source fallback control. detail=$($ArtifactProbe.detail)"
  } elseif (-not $SourceFallbackAllowed) {
    Write-Diagnostic "$($ArtifactProbe.status): $($ArtifactProbe.detail)"
    Write-Diagnostic "source_fallback_disabled: set SYMPP_SOURCE_FALLBACK=1 or SYMPP_DEVELOPER_MODE=1 to compile from a source checkout."
    throw "source_fallback_disabled: no verified Symphony++ runtime artifact is ready for this installed launcher."
  }

  return [pscustomobject]@{
    artifact_runtime = $artifactRuntime
    runtime_mode = $runtimeMode
    expected_source_revision = $sourceRevision
  }
}

function Test-ArtifactBackendProvidesDashboard($RuntimeState, $BackendPlan, [string]$RuntimeMode) {
  if ($RuntimeMode -eq "artifact") {
    return $true
  }

  if ($BackendPlan.reused -eq $true -and $BackendPlan.should_start -ne $true) {
    return $true
  }

  return $null -ne $RuntimeState -and
    $RuntimeState.PSObject.Properties["runtime_kind"] -and
    [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$RuntimeState.runtime_kind, "artifact") -and
    (Test-RuntimeEntryEndpointMatches "backend" $RuntimeState.backend $BackendPlan.url)
}
