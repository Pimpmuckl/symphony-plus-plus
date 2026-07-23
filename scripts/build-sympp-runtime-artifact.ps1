[CmdletBinding()]
param(
  [string]$Revision = $env:SYMPP_SOURCE_REVISION,
  [string]$OutputDir = "artifacts/sympp-runtime",
  [string]$Platform = "",
  [switch]$DryRun,
  [switch]$Help
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Show-Usage {
  @"
Builds the Symphony++ installed-runtime artifact for the current platform.

This is the installed artifact workflow: it compiles the Elixir backend release,
builds static dashboard assets, then emits a package plus manifest. Developer
source workflows such as `make -C elixir all`, `mix sympp.cockpit`, and the Vite
dev server remain separate and available.

Usage:
  scripts/build-sympp-runtime-artifact.ps1 [-Revision <sha>] [-OutputDir <dir>] [-Platform <id>] [-DryRun]
"@ | Write-Host
}

if ($Help) {
  Show-Usage
  exit 0
}

function Resolve-RepoRoot {
  Split-Path -Parent $PSScriptRoot
}

function Resolve-Revision([string]$Candidate, [string]$RepoRoot) {
  if ([string]::IsNullOrWhiteSpace($Candidate)) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $git) {
      $Candidate = (& $git.Source -C $RepoRoot rev-parse --verify HEAD 2>$null)
    }
  }

  $normalized = ([string]$Candidate).Trim().ToLowerInvariant()
  if ($normalized -notmatch '^[0-9a-f]{40}$') {
    throw "Missing or invalid Symphony++ source revision. Set SYMPP_SOURCE_REVISION or run from a Git checkout."
  }

  $normalized
}

function Resolve-PluginIdentity([string]$RepoRoot) {
  $pluginPath = Join-Path $RepoRoot "plugins/symphony-plus-plus-mcp/.codex-plugin/plugin.json"
  Require-Path $pluginPath "MCP plugin manifest" | Out-Null

  $plugin = Get-Content -LiteralPath $pluginPath -Raw | ConvertFrom-Json
  $name = ([string]$plugin.name).Trim()
  $version = ([string]$plugin.version).Trim()
  if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($version)) {
    throw "MCP plugin manifest must declare name and version."
  }

  [pscustomobject]@{ name = $name; version = $version }
}

function Resolve-Platform([string]$Candidate) {
  if (-not [string]::IsNullOrWhiteSpace($Candidate)) {
    return $Candidate.Trim().ToLowerInvariant()
  }

  $os =
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { "windows" }
    elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) { "macos" }
    elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) { "linux" }
    else { "unknown" }

  $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
  "$os-$arch"
}

function Require-Command([string]$Name) {
  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -eq $command) {
    throw "Required command was not found on PATH: $Name"
  }

  $command.Source
}

function Require-Path([string]$Path, [string]$Label, [switch]$Directory) {
  $type = if ($Directory) { "Container" } else { "Leaf" }
  if (-not (Test-Path -LiteralPath $Path -PathType $type)) {
    throw "$Label is missing: $Path"
  }

  (Resolve-Path -LiteralPath $Path).Path
}

function Invoke-Checked([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory) {
  Push-Location $WorkingDirectory
  try {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
      throw "Command failed with exit ${LASTEXITCODE}: $Executable $($Arguments -join ' ')"
    }
  }
  finally {
    Pop-Location
  }
}

function Write-JsonFile([string]$Path, $Value) {
  $json = ($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine
  [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Get-FirstReleaseAppDir([string]$ReleaseDir) {
  $libDir = Join-Path $ReleaseDir "lib"
  Require-Path $libDir "Release lib directory" -Directory | Out-Null

  $matches = @(Get-ChildItem -LiteralPath $libDir -Directory | Where-Object { $_.Name -like "symphony_elixir-*" })
  if ($matches.Count -ne 1) {
    throw "Expected exactly one symphony_elixir release lib directory under $libDir; found $($matches.Count)."
  }

  $matches[0].FullName
}

function Get-FileSha256([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-DirectoryFingerprint([string]$Path) {
  $root = (Resolve-Path -LiteralPath $Path).Path
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse | Sort-Object FullName)) {
    $relativePath = [System.IO.Path]::GetRelativePath($root, $file.FullName).Replace("\", "/")
    $lines.Add("$relativePath $(Get-FileSha256 $file.FullName)")
  }

  $payload = [string]::Join("`n", $lines)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
  }
  finally {
    $sha.Dispose()
  }
}

function Get-McpContractFingerprint([string]$RepoRoot) {
  $contractPath = Join-Path $RepoRoot "elixir/priv/symphony_plus_plus/mcp_contract.json"
  $contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
  $fingerprint = [string]$contract.mcp_contract_fingerprint
  if ($fingerprint -notmatch '^[0-9a-fA-F]{64}$') {
    throw "Could not resolve MCP contract fingerprint from $contractPath."
  }

  $fingerprint.ToLowerInvariant()
}

$repoRoot = Resolve-RepoRoot
$elixirDir = Join-Path $repoRoot "elixir"
$assetsDir = Join-Path $elixirDir "assets"
$outputRoot = if ([System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $repoRoot $OutputDir }
$revision = Resolve-Revision $Revision $repoRoot
$pluginIdentity = Resolve-PluginIdentity $repoRoot
$platformId = Resolve-Platform $Platform
$packageBaseName = "sympp-runtime-$revision-$platformId"
$stagingDir = Join-Path $outputRoot "$packageBaseName-staging"
$releaseDir = Join-Path $elixirDir "_build/prod/rel/symphony_elixir"
$sourceStaticDir = Join-Path $elixirDir "priv/static"
$payloadManifestPath = Join-Path $stagingDir "runtime-manifest.json"
$archivePath = Join-Path $outputRoot "$packageBaseName.zip"
$manifestPath = Join-Path $outputRoot "$packageBaseName.manifest.json"

Require-Path $elixirDir "Elixir project directory" -Directory | Out-Null
Require-Path (Join-Path $elixirDir "mix.exs") "mix project" | Out-Null
Require-Path $assetsDir "Dashboard assets directory" -Directory | Out-Null

if ($DryRun) {
  Write-Host "Dry run: revision=$revision platform=$platformId output=$outputRoot"
  exit 0
}

$npm = Require-Command "npm"
$mix = Require-Command "mix"

Invoke-Checked $npm @("ci") $assetsDir
Invoke-Checked $npm @("run", "build") $assetsDir

Require-Path (Join-Path $sourceStaticDir "index.html") "Dashboard static index" | Out-Null
Require-Path (Join-Path $sourceStaticDir ".vite/manifest.json") "Dashboard Vite manifest" | Out-Null

$previousMixEnv = $env:MIX_ENV
$previousRevision = $env:SYMPP_SOURCE_REVISION
$env:MIX_ENV = "prod"
$env:SYMPP_SOURCE_REVISION = $revision

try {
  Invoke-Checked $mix @("deps.get", "--only", "prod") $elixirDir
  Invoke-Checked $mix @("release", "symphony_elixir", "--overwrite") $elixirDir
}
finally {
  $env:MIX_ENV = $previousMixEnv
  $env:SYMPP_SOURCE_REVISION = $previousRevision
}

Require-Path $releaseDir "Compiled backend release" -Directory | Out-Null
$releaseAppDir = Get-FirstReleaseAppDir $releaseDir
Require-Path (Join-Path $releaseAppDir "priv/static/index.html") "Release dashboard static index" | Out-Null
Require-Path (Join-Path $releaseAppDir "priv/static/.vite/manifest.json") "Release dashboard Vite manifest" | Out-Null
$dashboardFingerprint = Get-DirectoryFingerprint $sourceStaticDir
$mcpContractFingerprint = Get-McpContractFingerprint $repoRoot

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
Copy-Item -LiteralPath $releaseDir -Destination (Join-Path $stagingDir "runtime") -Recurse
Copy-Item -LiteralPath $sourceStaticDir -Destination (Join-Path $stagingDir "dashboard-static") -Recurse
@'
#!/usr/bin/env bash
set -euo pipefail

ack_flag="--i-understand-that-this-will-be-running-without-the-usual-guardrails"
workflow=""
logs_root=""
port=""
acknowledged=0

usage() {
  cat <<'USAGE'
Usage: start-runtime.sh --i-understand-that-this-will-be-running-without-the-usual-guardrails [--workflow <WORKFLOW.md>] --logs-root <dir> --port <port>
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    "$ack_flag")
      acknowledged=1
      shift
      ;;
    --workflow)
      workflow="${2:-}"
      shift 2
      ;;
    --logs-root)
      logs_root="${2:-}"
      shift 2
      ;;
    --port)
      port="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$acknowledged" -eq 1 ]] || { echo "Missing required acknowledgement: $ack_flag" >&2; exit 2; }
[[ -z "${workflow// }" || -f "$workflow" ]] || { echo "Workflow file not found: $workflow" >&2; exit 1; }
[[ -n "${logs_root// }" ]] || { echo "--logs-root is required." >&2; exit 2; }
[[ "$port" =~ ^[0-9]+$ ]] || { echo "--port must be a non-negative integer." >&2; exit 2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runtime_bin="$script_dir/runtime/bin/symphony_elixir"
chmod +x \
  "$runtime_bin" \
  "$script_dir"/runtime/bin/* \
  "$script_dir"/runtime/erts-*/bin/* \
  "$script_dir"/runtime/releases/*/elixir \
  2>/dev/null || true
release_tmp="$logs_root/release-tmp"
mkdir -p "$logs_root" "$release_tmp"
export SYMPP_RUNTIME_ARTIFACT=1
export SYMPP_RUNTIME_ARTIFACT_ACKNOWLEDGED=1
if [[ -n "${workflow// }" ]]; then
  export SYMPP_WORKFLOW_FILE="$workflow"
else
  unset SYMPP_WORKFLOW_FILE
fi
export SYMPP_LOGS_ROOT="$logs_root"
export SYMPP_BACKEND_PORT="$port"
export RELEASE_TMP="$release_tmp"
export PHX_SERVER=true
exec "$runtime_bin" start
'@ | Set-Content -LiteralPath (Join-Path $stagingDir "start-runtime.sh") -Encoding utf8NoBOM
@'
[CmdletBinding()]
param(
  [string]$Workflow = "",
  [string]$LogsRoot = "",
  [int]$Port = -1,
  [switch]$IUnderstandThatThisWillBeRunningWithoutTheUsualGuardrails,
  [switch]$Help
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Show-Usage {
  @"
Usage: start-runtime.ps1 -IUnderstandThatThisWillBeRunningWithoutTheUsualGuardrails [-Workflow <WORKFLOW.md>] -LogsRoot <dir> -Port <port>
"@ | Write-Host
}

if ($Help) {
  Show-Usage
  exit 0
}

if (-not $IUnderstandThatThisWillBeRunningWithoutTheUsualGuardrails) {
  throw "Missing required acknowledgement: -IUnderstandThatThisWillBeRunningWithoutTheUsualGuardrails"
}
if (-not [string]::IsNullOrWhiteSpace($Workflow) -and -not (Test-Path -LiteralPath $Workflow -PathType Leaf)) {
  throw "Workflow file not found: $Workflow"
}
if ([string]::IsNullOrWhiteSpace($LogsRoot)) {
  throw "-LogsRoot is required."
}
if ($Port -lt 0) {
  throw "-Port must be a non-negative integer."
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$releaseTmp = Join-Path $LogsRoot "release-tmp"
New-Item -ItemType Directory -Force -Path $LogsRoot | Out-Null
New-Item -ItemType Directory -Force -Path $releaseTmp | Out-Null
$env:SYMPP_RUNTIME_ARTIFACT = "1"
$env:SYMPP_RUNTIME_ARTIFACT_ACKNOWLEDGED = "1"
if (-not [string]::IsNullOrWhiteSpace($Workflow)) {
  $env:SYMPP_WORKFLOW_FILE = $Workflow
} else {
  Remove-Item Env:SYMPP_WORKFLOW_FILE -ErrorAction SilentlyContinue
}
$env:SYMPP_LOGS_ROOT = $LogsRoot
$env:SYMPP_BACKEND_PORT = [string]$Port
$env:RELEASE_TMP = $releaseTmp
$env:PHX_SERVER = "true"
& (Join-Path $scriptDir "runtime\bin\symphony_elixir.bat") start
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath (Join-Path $stagingDir "start-runtime.ps1") -Encoding utf8NoBOM

$payload = [ordered]@{
  schema_version = 1
  plugin = [ordered]@{
    marketplace = "symphony-plus-plus"
    name = $pluginIdentity.name
    version = $pluginIdentity.version
    packages = @("symphony-plus-plus", "symphony-plus-plus-mcp")
  }
  source_revision = $revision
  platform = $platformId
  built_at = (Get-Date).ToUniversalTime().ToString("o")
  backend = [ordered]@{
    kind = "mix_release"
    name = "symphony_elixir"
    relative_path = "runtime"
    entrypoints = [ordered]@{
      unix = "start-runtime.sh"
      windows = "start-runtime.ps1"
    }
  }
  dashboard = [ordered]@{
    kind = "vite_static"
    relative_path = "dashboard-static"
    index = "dashboard-static/index.html"
    vite_manifest = "dashboard-static/.vite/manifest.json"
    fingerprint = $dashboardFingerprint
  }
  launcher_contract = [ordered]@{
    manifest = "sympp-runtime-artifact"
    version = 1
    mcp_contract_fingerprint = $mcpContractFingerprint
  }
}

Write-JsonFile $payloadManifestPath $payload
Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
[System.IO.Compression.ZipFile]::CreateFromDirectory($stagingDir, $archivePath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

$archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
$payloadHash = Get-FileSha256 $payloadManifestPath
$archiveItem = Get-Item -LiteralPath $archivePath

$manifest = [ordered]@{
  schema_version = 1
  status = "built"
  plugin = $payload.plugin
  source_revision = $revision
  platform = $platformId
  created_at = (Get-Date).ToUniversalTime().ToString("o")
  artifact = [ordered]@{
    file = Split-Path -Leaf $archivePath
    relative_path = Split-Path -Leaf $archivePath
    size_bytes = $archiveItem.Length
    sha256 = $archiveHash
  }
  payload_manifest = [ordered]@{
    file = "runtime-manifest.json"
    sha256 = $payloadHash
  }
  backend = $payload.backend
  dashboard = $payload.dashboard
  launcher_contract = $payload.launcher_contract
}

Write-JsonFile $manifestPath $manifest
Write-Host "Built $archivePath"
Write-Host "Manifest $manifestPath"
