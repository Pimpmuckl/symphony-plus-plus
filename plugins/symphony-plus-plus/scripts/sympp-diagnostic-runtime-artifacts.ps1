# Diagnostic runtime artifact helpers shared by the lifecycle doctor.

function Test-DiagnosticWindowsPlatform {
  return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
}

function Get-DiagnosticWindowsProcessorArchitecture {
  $arch = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITEW6432", "Process")
  if ([string]::IsNullOrWhiteSpace($arch)) {
    $arch = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE", "Process")
  }
  if (-not [string]::IsNullOrWhiteSpace($arch)) {
    return $arch
  }

  try {
    $runtimeArch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    if (-not [string]::IsNullOrWhiteSpace($runtimeArch)) {
      return $runtimeArch
    }
  } catch {
  }

  if ([IntPtr]::Size -eq 8) {
    return "AMD64"
  }

  return "x86"
}

function Convert-DiagnosticProcessorArchitectureToTargetArch([string]$Architecture) {
  if ([string]::IsNullOrWhiteSpace($Architecture)) {
    return $null
  }

  switch ($Architecture.Trim().ToLowerInvariant()) {
    "amd64" { return "x86_64" }
    "x64" { return "x86_64" }
    "arm64" { return "aarch64" }
    "aarch64" { return "aarch64" }
    "x86" { return "x86" }
    "ia64" { return "ia64" }
    default { return $null }
  }
}

function Get-DiagnosticRuntimePlatformKey {
  $os = if (Test-DiagnosticWindowsPlatform) {
    "windows"
  } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
    "linux"
  } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
    "macos"
  } else {
    $null
  }

  $architecture = if (Test-DiagnosticWindowsPlatform) {
    Get-DiagnosticWindowsProcessorArchitecture
  } else {
    try {
      [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    } catch {
      $null
    }
  }
  $arch = Convert-DiagnosticProcessorArchitectureToTargetArch $architecture

  if ([string]::IsNullOrWhiteSpace($os) -or [string]::IsNullOrWhiteSpace($arch)) {
    return $null
  }

  return "$os-$arch"
}

function Resolve-DiagnosticPluginHome {
  $configured = Resolve-OptionalFullPath $env:SYMPP_HOME
  if ($configured) {
    return $configured
  }

  return [System.IO.Path]::GetFullPath((Join-Path $HOME ".agents/splusplus"))
}

function Get-DiagnosticJsonPropertyValue($Object, [string[]]$Names) {
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

function Get-DiagnosticJsonPathValue($Object, [string[]]$Path) {
  $current = $Object
  foreach ($part in $Path) {
    if ($null -eq $current -or -not $current.PSObject.Properties[$part]) {
      return $null
    }
    $current = $current.PSObject.Properties[$part].Value
  }

  return $current
}

function Get-DiagnosticJsonFirstPathValue($Object, [object[]]$Paths) {
  foreach ($path in $Paths) {
    $value = Get-DiagnosticJsonPathValue $Object ([string[]]$path)
    if ($null -ne $value) {
      return $value
    }
  }

  return $null
}

function Test-DiagnosticRuntimeArtifactPlatformMatches($Artifact, [string]$Platform) {
  $artifactPlatform = [string](Get-DiagnosticJsonFirstPathValue $Artifact @(
      @("platform"),
      @("target"),
      @("platform_key"),
      @("platform", "key"),
      @("platform", "name"),
      @("platform", "target")
    ))
  if (-not [string]::IsNullOrWhiteSpace($artifactPlatform)) {
    $normalizedPlatform = $artifactPlatform.Trim().ToLowerInvariant()
    return [System.StringComparer]::OrdinalIgnoreCase.Equals($normalizedPlatform, $Platform) -or
      $normalizedPlatform.StartsWith("$Platform-", [System.StringComparison]::OrdinalIgnoreCase)
  }

  $os = [string](Get-DiagnosticJsonFirstPathValue $Artifact @(
      @("os"),
      @("target_os"),
      @("platform", "os"),
      @("platform", "target_os")
    ))
  $arch = [string](Get-DiagnosticJsonFirstPathValue $Artifact @(
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

  $normalizedArch = Convert-DiagnosticProcessorArchitectureToTargetArch $arch
  if ([string]::IsNullOrWhiteSpace($normalizedArch)) {
    $normalizedArch = $arch.Trim().ToLowerInvariant()
  }

  $artifactPlatform = "$($os.Trim().ToLowerInvariant())-$normalizedArch"
  return [System.StringComparer]::OrdinalIgnoreCase.Equals($artifactPlatform, $Platform)
}

function Normalize-DiagnosticSourceRevision([string]$Revision) {
  if ([string]::IsNullOrWhiteSpace($Revision)) {
    return $null
  }

  $normalized = $Revision.Trim().ToLowerInvariant()
  if ($normalized -match "^[0-9a-f]{40}$") {
    return $normalized
  }

  return $null
}

function Normalize-DiagnosticMcpContractFingerprint([string]$Fingerprint) {
  if ([string]::IsNullOrWhiteSpace($Fingerprint)) {
    return $null
  }

  $normalized = $Fingerprint.Trim().ToLowerInvariant()
  if ($normalized -match "^[0-9a-f]{64}$") {
    return $normalized
  }

  return $null
}

function Normalize-McpContractFingerprint([string]$Fingerprint) {
  return Normalize-DiagnosticMcpContractFingerprint $Fingerprint
}

function Test-DiagnosticRuntimeArtifactRevisionMatches($Artifact, [string]$ExpectedSourceRevision, [string]$ManifestSourceRevision) {
  if ([string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) {
    return $false
  }

  $artifactRevision = Normalize-DiagnosticSourceRevision ([string](Get-DiagnosticJsonFirstPathValue $Artifact @(
        @("source_revision"),
        @("revision"),
        @("git_revision"),
        @("release", "source_revision"),
        @("plugin", "source_revision")
      )))
  if (-not $artifactRevision) {
    $artifactRevision = Normalize-DiagnosticSourceRevision $ManifestSourceRevision
  }

  return $artifactRevision -and
    [System.StringComparer]::OrdinalIgnoreCase.Equals($artifactRevision, $ExpectedSourceRevision)
}

function Test-DiagnosticRuntimeArtifactContractMatches($Artifact, [string]$ExpectedContractFingerprint, [string]$ManifestContractFingerprint) {
  $artifactContract = Normalize-DiagnosticMcpContractFingerprint ([string](Get-DiagnosticJsonPropertyValue $Artifact @("mcp_contract_fingerprint", "contract_fingerprint")))
  if (-not $artifactContract) {
    $artifactContract = Normalize-DiagnosticMcpContractFingerprint $ManifestContractFingerprint
  }

  if (-not $artifactContract) {
    return [string]::IsNullOrWhiteSpace($ExpectedContractFingerprint)
  }

  return [System.StringComparer]::OrdinalIgnoreCase.Equals($artifactContract, $ExpectedContractFingerprint)
}

function Assert-DiagnosticRelativeArtifactPath([string]$Path, [string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Label must be present in the Symphony++ runtime artifact manifest."
  }

  if ([System.IO.Path]::IsPathRooted($Path) -or $Path.Contains("..")) {
    throw "$Label must be a relative path inside the extracted Symphony++ runtime artifact."
  }
}

function Resolve-DiagnosticRuntimeArtifactEntrypoint($Artifact) {
  $entrypoint = [string](Get-DiagnosticJsonFirstPathValue $Artifact @(
      @("entrypoint"),
      @("backend_entrypoint"),
      @("command"),
      @("runtime", "entrypoint"),
      @("runtime", "command"),
      @("backend", "entrypoint")
    ))
  if ([string]::IsNullOrWhiteSpace($entrypoint)) {
    if (Test-DiagnosticWindowsPlatform) {
      $entrypoint = "start-runtime.ps1"
    } else {
      $entrypoint = "start-runtime.sh"
    }
  }

  Assert-DiagnosticRelativeArtifactPath $entrypoint "artifact entrypoint"
  return $entrypoint.Replace("\", "/")
}

function Resolve-DiagnosticRuntimeArtifactSourceUri($Artifact, [string]$ManifestPath) {
  $value = [string](Get-DiagnosticJsonPropertyValue $Artifact @("url", "download_url", "uri", "path"))
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "artifact_missing: selected Symphony++ runtime artifact does not declare url, download_url, uri, or path."
  }

  if ([System.Uri]::IsWellFormedUriString($value, [System.UriKind]::Absolute)) {
    return $value
  }

  $manifestDir = Split-Path -Parent $ManifestPath
  return [System.IO.Path]::GetFullPath((Join-Path $manifestDir $value))
}

function Assert-DiagnosticRuntimeArtifactSourceUsable([string]$SourceUri) {
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

function Resolve-DiagnosticRuntimeArtifactDashboardRoot($Artifact) {
  $dashboardRoot = [string](Get-DiagnosticJsonFirstPathValue $Artifact @(
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

  Assert-DiagnosticRelativeArtifactPath $dashboardRoot "artifact dashboard asset root"
  return $dashboardRoot.Replace("\", "/")
}

function Resolve-DiagnosticRuntimeArtifactDashboardFingerprint($Artifact) {
  $fingerprint = [string](Get-DiagnosticJsonFirstPathValue $Artifact @(
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
  return Normalize-DiagnosticMcpContractFingerprint $fingerprint
}

function Get-DiagnosticArtifactDirectoryFingerprint([string]$Root) {
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    return $null
  }

  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName)) {
    $relativePath = [System.IO.Path]::GetRelativePath($Root, $file.FullName).Replace("\", "/")
    $lines.Add("$relativePath $(Get-FileSha256Hex $file.FullName)")
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

function Test-DiagnosticRuntimeArtifactDashboardReady([string]$ExtractRoot, [string]$DashboardRoot, [string]$DashboardFingerprint) {
  if ([string]::IsNullOrWhiteSpace($DashboardRoot) -or [string]::IsNullOrWhiteSpace($DashboardFingerprint)) {
    return $false
  }

  $dashboardPath = Join-Path $ExtractRoot $DashboardRoot
  $actual = Get-DiagnosticArtifactDirectoryFingerprint $dashboardPath
  return $actual -and [System.StringComparer]::OrdinalIgnoreCase.Equals($actual, $DashboardFingerprint)
}

function Test-DiagnosticRuntimeArtifactCacheReady([string]$CacheRoot, [string]$Entrypoint, [string]$Sha256, [string]$DashboardRoot, [string]$DashboardFingerprint) {
  $extractRoot = Join-Path $CacheRoot "runtime"
  $markerPath = Join-Path $extractRoot ".sympp-artifact.json"
  $entrypointPath = Join-Path $extractRoot $Entrypoint
  if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $entrypointPath -PathType Leaf)) {
    return $false
  }

  try {
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    return [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$marker.sha256, $Sha256) -and
      [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$marker.dashboard_root, $DashboardRoot) -and
      [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$marker.dashboard_fingerprint, $DashboardFingerprint) -and
      (Test-DiagnosticRuntimeArtifactDashboardReady $extractRoot $DashboardRoot $DashboardFingerprint)
  } catch {
    return $false
  }
}

function Get-DiagnosticMcpContractFingerprintFromContractFile([string]$ContractPath) {
  if ([string]::IsNullOrWhiteSpace($ContractPath) -or -not (Test-Path -LiteralPath $ContractPath -PathType Leaf)) {
    return $null
  }

  try {
    $contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
    return Normalize-DiagnosticMcpContractFingerprint ([string]$contract.mcp_contract_fingerprint)
  } catch {
    return $null
  }
}

function Get-DiagnosticMcpContractFingerprintFromManifestObject($Manifest) {
  $fingerprints = New-Object System.Collections.Generic.List[string]

  $manifestFingerprint = Normalize-DiagnosticMcpContractFingerprint ([string](Get-DiagnosticJsonFirstPathValue $Manifest @(
        @("mcp_contract_fingerprint"),
        @("launcher_contract", "mcp_contract_fingerprint"),
        @("contract_fingerprint"),
        @("launcher_contract", "contract_fingerprint")
      )))
  if ($manifestFingerprint) {
    $fingerprints.Add($manifestFingerprint)
  }

  foreach ($artifact in @(Get-DiagnosticJsonPropertyValue $Manifest @("artifacts", "runtime_artifacts"))) {
    $artifactFingerprint = Normalize-DiagnosticMcpContractFingerprint ([string](Get-DiagnosticJsonFirstPathValue $artifact @(
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

function Read-DiagnosticRuntimeArtifactManifest([string]$Root) {
  if ((Get-Command Read-SymppArtifactManifest -ErrorAction SilentlyContinue)) {
    return Read-SymppArtifactManifest $Root
  }

  $manifestPath = @(
    Join-Path $Root ".sympp-runtime-artifacts.json"
    Join-Path $Root "assets/sympp-runtime-artifacts.json"
  ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

  if (-not $manifestPath) {
    return $null
  }

  return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}

function Get-DiagnosticMcpContractFingerprintFromArtifactManifest([string]$Root) {
  try {
    $manifest = Read-DiagnosticRuntimeArtifactManifest $Root
  } catch {
    return $null
  }

  if ($null -eq $manifest) {
    return $null
  }

  $fingerprint = Get-DiagnosticMcpContractFingerprintFromManifestObject $manifest
  if ($fingerprint) {
    return $fingerprint
  }

  return "0000000000000000000000000000000000000000000000000000000000000000"
}

function Get-DiagnosticExpectedMcpContractFingerprint([string]$Root) {
  if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_REPO_ROOT)) {
    $explicitRepoRoot = [System.IO.Path]::GetFullPath($env:SYMPP_REPO_ROOT)
    if (-not (Test-SourceCheckoutRoot $explicitRepoRoot)) {
      throw "SYMPP_REPO_ROOT does not look like a Symphony++ checkout: $explicitRepoRoot"
    }

    $contractPath = Join-Path $explicitRepoRoot "elixir/priv/symphony_plus_plus/mcp_contract.json"
    $fingerprint = Get-DiagnosticMcpContractFingerprintFromContractFile $contractPath
    if ($fingerprint) {
      return $fingerprint
    }

    throw "Symphony++ diagnostic expected MCP contract fingerprint could not be resolved from explicit SYMPP_REPO_ROOT contract JSON: $contractPath"
  }

  $candidateRoots = New-Object System.Collections.Generic.List[string]
  $sourceCandidate = Resolve-OptionalFullPath (Join-Path $Root "../..")
  if (Test-SourceCheckoutRoot $sourceCandidate) {
    $candidateRoots.Add($sourceCandidate)
  }

  foreach ($candidateRoot in @($candidateRoots | Select-Object -Unique)) {
    $fingerprint = Get-DiagnosticMcpContractFingerprintFromContractFile (Join-Path $candidateRoot "elixir/priv/symphony_plus_plus/mcp_contract.json")
    if ($fingerprint) {
      return $fingerprint
    }
  }

  $sourceRoot = Resolve-DiagnosticRuntimeArtifactSourceRoot $Root $null
  if ($sourceRoot) {
    $fingerprint = Get-DiagnosticMcpContractFingerprintFromContractFile (Join-Path $sourceRoot "elixir/priv/symphony_plus_plus/mcp_contract.json")
    if ($fingerprint) {
      return $fingerprint
    }
  }

  $artifactManifest = $null
  try {
    $artifactManifest = Read-DiagnosticRuntimeArtifactManifest $Root
  } catch {
    $artifactManifest = $null
  }

  $fingerprint = Get-DiagnosticMcpContractFingerprintFromManifestObject $artifactManifest
  if ($fingerprint) {
    return $fingerprint
  }

  if ($null -ne $artifactManifest) {
    return "0000000000000000000000000000000000000000000000000000000000000000"
  }

  return $null
}

function Get-DiagnosticPinnedRevision([string]$Root) {
  $path = Join-Path $Root ".sympp-source-revision"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return $null
  }

  $revision = (Get-Content -LiteralPath $path -Raw).Trim().ToLowerInvariant()
  if ($revision -match "^[0-9a-f]{40}$") {
    return $revision
  }

  return $null
}

function Test-DiagnosticEnvEnabled([string]$Name) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $false
  }

  return $value.Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")
}

function Get-DiagnosticGitHeadRevision([string]$RepoRoot) {
  $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $git -or -not (Test-SourceCheckoutRoot $RepoRoot)) {
    return $null
  }

  try {
    $output = @(& $git.Source @("-C", $RepoRoot, "rev-parse", "--verify", "HEAD") 2>$null)
    if ($LASTEXITCODE -eq 0 -and $output.Count -gt 0) {
      return Normalize-DiagnosticSourceRevision ([string]$output[0])
    }
  } catch {
  }

  return $null
}

function Get-DiagnosticMarketplaceInstallRevision([string]$RepoRoot) {
  if (-not (Test-SourceCheckoutRoot $RepoRoot)) {
    return $null
  }

  $installPath = Join-Path $RepoRoot ".codex-marketplace-install.json"
  if (-not (Test-Path -LiteralPath $installPath -PathType Leaf)) {
    return $null
  }

  try {
    $install = Get-Content -LiteralPath $installPath -Raw | ConvertFrom-Json
    return Normalize-DiagnosticSourceRevision ([string]$install.revision)
  } catch {
    return $null
  }
}

function Resolve-DiagnosticRuntimeArtifactSourceRoot([string]$Root, [string]$SourceHint) {
  $sourceRoot = Get-SourceCheckoutFromPluginRoot $Root
  if ($sourceRoot) {
    return $sourceRoot
  }

  if ((Get-Command Import-DiagnosticMcpArtifactHelpers -ErrorAction SilentlyContinue) -and
      (Import-DiagnosticMcpArtifactHelpers $Root)) {
    $sourceRoot = Resolve-RepoRootFromMarketplaceCache $Root
    if ($sourceRoot) {
      return $sourceRoot
    }
  }

  $hintRoot = Resolve-OptionalFullPath $SourceHint
  if (Test-SourceCheckoutRoot $hintRoot) {
    return $hintRoot
  }

  return $null
}

function Get-DiagnosticRuntimeArtifactStatus([string]$Root, [string]$ExpectedRevision = $null) {
  if (Import-DiagnosticMcpArtifactHelpers $Root) {
    return Get-DiagnosticRuntimeArtifactStatusFromLauncherHelpers $Root $ExpectedRevision
  }

  $manifestPath = @(
    Join-Path $Root ".sympp-runtime-artifacts.json"
    Join-Path $Root "assets/sympp-runtime-artifacts.json"
  ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

  $platform = Get-DiagnosticRuntimePlatformKey
  $detail = if ($manifestPath) { "launcher_helpers_missing" } else { "manifest_missing" }
  return [pscustomobject]@{ status = "artifact_missing"; detail = $detail; platform = $platform; manifest_path = $manifestPath }
}
