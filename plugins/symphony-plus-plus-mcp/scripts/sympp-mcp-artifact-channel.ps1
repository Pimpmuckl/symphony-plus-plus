$ErrorActionPreference = "Stop"

function Invoke-SymppBoundedDownload([string]$SourceUri, [string]$OutFile, [int]$TimeoutSec, [string]$Phase) {
  $effectiveTimeout = Get-SymppRemainingTimeoutSec $TimeoutSec $Phase
  Invoke-WebRequest -Uri $SourceUri -OutFile $OutFile -TimeoutSec $effectiveTimeout -UseBasicParsing -ErrorAction Stop
}

function Resolve-SymppManifestReferenceUri($Reference, [string]$ManifestPath) {
  $value = [string](Get-JsonFirstPathValue $Reference @(
      @("url"),
      @("download_url"),
      @("uri"),
      @("path"),
      @("relative_path")
    ))
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $null
  }

  if ([System.Uri]::IsWellFormedUriString($value, [System.UriKind]::Absolute)) {
    return $value
  }
  if ([System.IO.Path]::IsPathRooted($value)) {
    return [System.IO.Path]::GetFullPath($value)
  }
  if ([System.Uri]::IsWellFormedUriString($ManifestPath, [System.UriKind]::Absolute)) {
    return [System.Uri]::new([System.Uri]$ManifestPath, $value).AbsoluteUri
  }

  return [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ManifestPath) $value))
}

function Read-SymppManifestReferenceContent([string]$SourceUri, [string]$ExpectedSha256) {
  $tempPath = $null
  try {
    $readPath = $SourceUri
    if ([System.Uri]::IsWellFormedUriString($SourceUri, [System.UriKind]::Absolute)) {
      $uri = [System.Uri]$SourceUri
      if ($uri.Scheme -eq "file") {
        $readPath = $uri.LocalPath
      } elseif ($uri.Scheme -eq "https" -or ($uri.Scheme -eq "http" -and $uri.IsLoopback)) {
        $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "sympp-artifact-manifest-$PID-$([guid]::NewGuid().ToString('N')).json"
        Write-SymppLauncherTrace "manifest_fetch_begin"
        Invoke-SymppBoundedDownload $SourceUri $tempPath 45 "artifact manifest download"
        Write-SymppLauncherTrace "manifest_fetch_end"
        $readPath = $tempPath
      } else {
        throw "artifact_download_blocked: Symphony++ runtime artifact manifests must use https, file, or loopback http URLs."
      }
    }

    if (-not (Test-Path -LiteralPath $readPath -PathType Leaf)) {
      throw "artifact_missing: referenced Symphony++ runtime artifact manifest does not exist: $readPath"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
      $actual = Get-FileSha256 $readPath
      if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($actual, $ExpectedSha256)) {
        throw "artifact_verification_failed: expected manifest sha256 $ExpectedSha256 but got $actual for $SourceUri."
      }
    }

    return Get-Content -LiteralPath $readPath -Raw
  } finally {
    if ($tempPath) {
      Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Set-SymppArtifactSourceOverride($Manifest, [string]$SourceUri, [string]$Sha256) {
  $artifact = Get-JsonPathValue $Manifest @("artifact")
  if ($null -eq $artifact) {
    $artifact = [pscustomobject]@{}
    $Manifest | Add-Member -NotePropertyName artifact -NotePropertyValue $artifact -Force
  }

  foreach ($name in @("file", "relative_path", "path", "download_url", "uri")) {
    if ($artifact.PSObject.Properties[$name]) {
      $artifact.PSObject.Properties.Remove($name)
    }
  }
  $artifact | Add-Member -NotePropertyName url -NotePropertyValue $SourceUri -Force
  if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
    $artifact | Add-Member -NotePropertyName sha256 -NotePropertyValue $Sha256 -Force
  }
}

function Resolve-SymppPublishedArtifactManifest($Manifest, [string]$ManifestPath) {
  $manifestReference = Get-JsonPathValue $Manifest @("manifest")
  $manifestUri = Resolve-SymppManifestReferenceUri $manifestReference $ManifestPath
  if (-not $manifestUri) {
    return $Manifest
  }

  $manifestSha = Normalize-SymppSha256 ([string](Get-JsonFirstPathValue $manifestReference @(@("sha256"), @("digest"))))
  $resolved = (Read-SymppManifestReferenceContent $manifestUri $manifestSha) | ConvertFrom-Json
  $artifactUri = Resolve-SymppManifestReferenceUri (Get-JsonPathValue $Manifest @("artifact")) $ManifestPath
  if ($artifactUri) {
    $artifactSha = Normalize-SymppSha256 ([string](Get-JsonFirstPathValue (Get-JsonPathValue $Manifest @("artifact")) @(@("sha256"), @("digest"))))
    Set-SymppArtifactSourceOverride $resolved $artifactUri $artifactSha
  }
  $resolved | Add-Member -NotePropertyName manifest_path -NotePropertyValue $manifestUri -Force
  return $resolved
}
