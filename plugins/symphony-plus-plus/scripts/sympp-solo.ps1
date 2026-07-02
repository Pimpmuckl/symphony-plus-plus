param(
  [switch]$Help,
  [switch]$ValidateOnly,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$SoloArgs
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "sympp-launcher-runtime.ps1")

function Resolve-UsageScriptPath {
  $scriptParent = Split-Path -Parent $PSScriptRoot
  $packageRoot = Split-Path -Parent $scriptParent
  $marketplaceRoot = Split-Path -Parent $packageRoot
  $cacheRoot = Split-Path -Parent $marketplaceRoot
  $pluginsRoot = Split-Path -Parent $cacheRoot
  $pluginName = if ((Split-Path -Leaf $cacheRoot) -eq "cache" -and (Split-Path -Leaf $pluginsRoot) -eq "plugins") {
    Split-Path -Leaf $packageRoot
  } else {
    Split-Path -Leaf $scriptParent
  }
  $scriptName = Split-Path -Leaf $PSCommandPath
  if ([string]::IsNullOrWhiteSpace($scriptName)) {
    $scriptName = "sympp-solo.ps1"
  }

  return "plugins/$pluginName/scripts/$scriptName"
}

function Write-Usage {
  $scriptPath = Resolve-UsageScriptPath

  Write-Host "Runs the Symphony++ Solo Session CLI from any current repository."
  Write-Host ""
  Write-Host "Usage:"
  Write-Host "  pwsh $scriptPath -Help"
  Write-Host "  pwsh $scriptPath -ValidateOnly"
  Write-Host "  pwsh $scriptPath <mix sympp.solo command> [options]"
  Write-Host ""
  Write-Host "Environment:"
  Write-Host "  SYMPP_REPO_ROOT   Explicit developer-only Symphony++ source checkout override; not the caller/task repo. Marketplace installs are discovered automatically."
  Write-Host "  SYMPP_DATABASE    Optional SQLite ledger override passed to mix sympp.solo when --database is not already present. Relative paths resolve against the caller workspace. When omitted, mix sympp.solo prefers %USERPROFILE%\.agents\splusplus\symphony_plus_plus.sqlite3 and falls back under temp/relative .agents\splusplus if home is unavailable."
  Write-Host "  SYMPP_LAUNCHER    Optional launcher: 'direct' or 'mise'. Defaults to 'mise' when elixir/mise.toml can run through mise; otherwise 'direct'."
  Write-Host "  SYMPP_MIX         Optional mix executable path or name for direct launcher. Defaults to 'mix'."
  Write-Host "  SYMPP_MISE        Optional mise executable path or name for mise launcher. Defaults to 'mise'."
  Write-Host "  MIX_BUILD_ROOT    Optional Mix build-root override. Defaults under %USERPROFILE%\.agents\splusplus\build\solo for plugin wrapper runs."
  Write-Host ""
  Write-Host "Solo repo identity comes from --repo and --workspace-path. SYMPP_REPO_ROOT only locates the Symphony++ wrapper source for explicit developer validation."
  Write-Host "Installed plugins resolve through the Codex marketplace snapshot. .sympp-source-root hints are ignored."
}

function Resolve-OptionalPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  return [System.IO.Path]::GetFullPath($Path)
}

function Test-SymphonySourceRoot([string]$Path) {
  return (-not [string]::IsNullOrWhiteSpace($Path)) -and (Test-Path -LiteralPath (Join-Path $Path "elixir/mix.exs"))
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
    return $candidate
  }

  return $null
}

function Resolve-RepoRoot {
  $configuredRoot = Resolve-OptionalPath $env:SYMPP_REPO_ROOT
  if ($configuredRoot) {
    if (Test-SymphonySourceRoot $configuredRoot) {
      return $configuredRoot
    }

    throw "SYMPP_REPO_ROOT must point to the Symphony++ source checkout containing elixir/mix.exs, not the caller/task repo: $configuredRoot"
  }

  $pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
  $sourceCandidate = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../.."))
  if (Test-SymphonySourceRoot $sourceCandidate) {
    return $sourceCandidate
  }

  $marketplaceRoot = Resolve-RepoRootFromMarketplaceCache $pluginRoot
  if ($marketplaceRoot) {
    return $marketplaceRoot
  }

  throw "Cannot infer the Symphony++ runtime source. Run codex plugin marketplace upgrade, or set SYMPP_REPO_ROOT only for explicit developer validation. Do not set it to the caller/task repo; Solo identity comes from --repo and --workspace-path."
}

function Resolve-CallerWorkspace {
  $cwd = [System.IO.Path]::GetFullPath((Get-Location).Path)
  $git = Get-Command "git" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($git) {
    $gitRoot = (& git -C $cwd rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitRoot)) {
      return [System.IO.Path]::GetFullPath(([string]$gitRoot).Trim())
    }
  }

  return $cwd
}

function Test-IsWindowsAbsolutePath([string]$Path) {
  return $Path -match "^[A-Za-z]:[\\/]"
}

function Test-IsUriLikeDatabase([string]$Path) {
  return $Path -match "^[A-Za-z][A-Za-z0-9+.-]*:" -and -not (Test-IsWindowsAbsolutePath $Path)
}

function Resolve-DatabasePath([string]$Path, [string]$CallerWorkspace) {
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.StartsWith(":") -or (Test-IsUriLikeDatabase $Path)) {
    return $Path
  }

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $CallerWorkspace $Path))
}

function Resolve-DatabaseArgs([string[]]$InputArgs, [string]$CallerWorkspace) {
  $resolved = @()
  for ($index = 0; $index -lt $InputArgs.Count; $index++) {
    $arg = $InputArgs[$index]
    if ($arg -eq "--database" -and ($index + 1) -lt $InputArgs.Count) {
      $resolved += $arg
      $resolved += Resolve-DatabasePath $InputArgs[$index + 1] $CallerWorkspace
      $index += 1
    } elseif ($arg.StartsWith("--database=")) {
      $value = $arg.Substring("--database=".Length)
      $resolved += "--database=$(Resolve-DatabasePath $value $CallerWorkspace)"
    } else {
      $resolved += $arg
    }
  }

  return $resolved
}

function Test-IsMiseShim([string]$Path) {
  $normalized = $Path.Replace("\", "/").ToLowerInvariant()
  return ($normalized -match "/mise/" -or $normalized -match "/\.mise/") -and $normalized -match "/shims?/"
}

function Resolve-MixCommand {
  $command = Get-Command $mix -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $command) {
    throw "Could not find mix executable '$mix'. Install Elixir or set SYMPP_MIX."
  }

  $source = if ($command.Source) { [string]$command.Source } else { [string]$command.Path }
  if (Test-IsMiseShim $source) {
    throw "Direct launcher resolved mix to a mise shim: $source. Set SYMPP_MIX to a non-mise Mix executable, or set SYMPP_LAUNCHER=mise after trusting the checkout's mise config."
  }
}

function Assert-LauncherAvailable {
  switch ($launcher) {
    "direct" {
      Resolve-MixCommand
    }
    "mise" {
      if (-not (Get-Command $mise -ErrorAction SilentlyContinue)) {
        throw "Could not find mise executable '$mise'. Install mise or set SYMPP_MISE."
      }
    }
    default {
      throw "Unsupported SYMPP_LAUNCHER '$launcher'. Use 'direct' or 'mise'."
    }
  }
}

function Invoke-Launcher([string[]]$LauncherArgs) {
  switch ($launcher) {
    "direct" {
      & $mix @LauncherArgs
      $script:LauncherExitCode = $LASTEXITCODE
      return
    }
    "mise" {
      & $mise @("exec", "--", "mix") @LauncherArgs
      $script:LauncherExitCode = $LASTEXITCODE
      return
    }
    default {
      throw "Unsupported SYMPP_LAUNCHER '$launcher'. Use 'direct' or 'mise'."
    }
  }
}

function Test-LauncherVersion {
  switch ($launcher) {
    "direct" {
      & $mix "--version" | Out-Host
      return $LASTEXITCODE
    }
    "mise" {
      & $mise @("exec", "--", "mix", "--version") | Out-Host
      return $LASTEXITCODE
    }
    default {
      throw "Unsupported SYMPP_LAUNCHER '$launcher'. Use 'direct' or 'mise'."
    }
  }
}

function Invoke-CheckedLauncher([string[]]$LauncherArgs, [string]$Description) {
  Invoke-Launcher -LauncherArgs $LauncherArgs
  if ($script:LauncherExitCode -ne 0) {
    throw "$Description failed with exit code $($script:LauncherExitCode)."
  }
}

function Test-HasDatabaseArg([string[]]$InputArgs) {
  foreach ($arg in $InputArgs) {
    if ($arg -eq "--database" -or $arg.StartsWith("--database=")) {
      return $true
    }
  }

  return $false
}

if ($Help) {
  Write-Usage
  exit 0
}

$repoRoot = Resolve-RepoRoot
$callerWorkspace = if ($ValidateOnly) { $null } else { Resolve-CallerWorkspace }
$resolvedSoloArgs = if ($ValidateOnly) { @() } else { Resolve-DatabaseArgs -InputArgs $SoloArgs -CallerWorkspace $callerWorkspace }
$elixirDir = Join-Path $repoRoot "elixir"
$soloTaskPath = Join-Path $elixirDir "lib/mix/tasks/sympp.solo.ex"
$mix = if ([string]::IsNullOrWhiteSpace($env:SYMPP_MIX)) { "mix" } else { $env:SYMPP_MIX }
$mise = if ([string]::IsNullOrWhiteSpace($env:SYMPP_MISE)) { "mise" } else { $env:SYMPP_MISE }
$launcher = if ([string]::IsNullOrWhiteSpace($env:SYMPP_LAUNCHER)) { Resolve-SymppDefaultLauncher $elixirDir $mise } else { $env:SYMPP_LAUNCHER.Trim().ToLowerInvariant() }
Set-SymppWindowsNativeTargetEnvironment
$defaultMixBuildRoot = Resolve-SymppDefaultMixBuildRoot $repoRoot $launcher "solo"
Set-SymppDefaultMixBuildRoot $repoRoot $launcher "solo"

$script:FinalExitCode = 0

Push-Location -LiteralPath $elixirDir
try {
  Assert-LauncherAvailable

  if ($ValidateOnly) {
    if (-not (Test-Path -LiteralPath $soloTaskPath)) {
      throw "Resolved Symphony++ checkout is missing the Solo Session Mix task: $soloTaskPath"
    }

    $validationExitCode = Test-LauncherVersion
    if ($validationExitCode -ne 0) {
      throw "Selected Symphony++ Solo Session launcher failed validation with exit code $validationExitCode."
    }

    Invoke-CheckedLauncher -LauncherArgs @("deps.get", "--check-locked") -Description "mix deps.get --check-locked"
    Invoke-CheckedLauncher -LauncherArgs @("sympp.solo", "--help") -Description "mix sympp.solo --help"

    Write-Host "Symphony++ Solo Session wrapper validation passed."
    Write-Host "  repoRoot: $repoRoot"
    Write-Host "  elixirDir: $elixirDir"
    Write-Host "  launcher: $launcher"
    Write-Host "  mixBuildRoot: $defaultMixBuildRoot"
    $script:FinalExitCode = 0
  } else {
    Invoke-CheckedLauncher -LauncherArgs @("deps.get", "--check-locked") -Description "mix deps.get --check-locked"
    $soloCommandArgs = @("sympp.solo") + $resolvedSoloArgs
    if (-not (Test-HasDatabaseArg -InputArgs $resolvedSoloArgs)) {
      if (-not [string]::IsNullOrWhiteSpace($env:SYMPP_DATABASE)) {
        $soloCommandArgs += @("--database", (Resolve-DatabasePath $env:SYMPP_DATABASE $callerWorkspace))
      }
    }
    Invoke-Launcher -LauncherArgs $soloCommandArgs
    $script:FinalExitCode = $script:LauncherExitCode
  }
} finally {
  Pop-Location
}

exit $script:FinalExitCode
