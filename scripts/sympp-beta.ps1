[CmdletBinding()]
param(
  [ValidateSet("Setup", "Validate", "Start", "Restart", "Status", "Stop", "Package", "Codex")]
  [string]$Action = "Setup",
  [string]$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..")),
  [string]$BetaWorktree,
  [string]$SymppHome,
  [string]$Database,
  [switch]$LiveLedger,
  [int]$BackendPort = 20000,
  [int]$DashboardPort = 20001,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

function Test-SamePath([string]$Left, [string]$Right) {
  $leftPath = [System.IO.Path]::GetFullPath($Left).TrimEnd("\", "/")
  $rightPath = [System.IO.Path]::GetFullPath($Right).TrimEnd("\", "/")
  return $leftPath.Equals($rightPath, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PathInside([string]$Path, [string]$Root) {
  $pathValue = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
  $rootValue = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
  return $pathValue.Equals($rootValue, [System.StringComparison]::OrdinalIgnoreCase) -or
    $pathValue.StartsWith($rootValue + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-BetaConfiguration(
  [string]$SourceRoot,
  [string]$Worktree,
  [string]$HomeRoot,
  [string]$DatabasePath,
  [bool]$UseLiveLedger,
  [int]$Backend,
  [int]$Dashboard
) {
  $source = [System.IO.Path]::GetFullPath($SourceRoot)
  if ([string]::IsNullOrWhiteSpace($Worktree)) {
    $Worktree = Join-Path (Split-Path -Parent $source) "symphony-plus-plus-beta"
  }
  if ([string]::IsNullOrWhiteSpace($HomeRoot)) {
    $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $HomeRoot = Join-Path $profile ".agents/splusplus-beta"
  }

  $homePath = [System.IO.Path]::GetFullPath($HomeRoot)
  $worktreePath = [System.IO.Path]::GetFullPath($Worktree)
  if (Test-SamePath $source $worktreePath) { throw "The beta worktree must differ from the source checkout." }
  if ($Backend -in @(19998, 19999) -or $Dashboard -in @(19998, 19999) -or $Backend -eq $Dashboard) {
    throw "Beta ports must be distinct and must not use stable ports 19998/19999."
  }
  if ($Backend -lt 1 -or $Backend -gt 65535 -or $Dashboard -lt 1 -or $Dashboard -gt 65535) {
    throw "Beta ports must be between 1 and 65535."
  }

  $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
  $liveDatabase = [System.IO.Path]::GetFullPath((Join-Path $profile ".agents/splusplus/symphony_plus_plus.sqlite3"))
  if ([string]::IsNullOrWhiteSpace($DatabasePath)) {
    $DatabasePath = if ($UseLiveLedger) { $liveDatabase } else { Join-Path $homePath "ledger/beta.sqlite3" }
  } else {
    $resolvedDatabase = [System.IO.Path]::GetFullPath($DatabasePath)
    if ((Test-SamePath $resolvedDatabase $liveDatabase) -ne $UseLiveLedger) {
      throw "-LiveLedger must select the normal live ledger, and that ledger requires -LiveLedger."
    }
    $DatabasePath = $resolvedDatabase
  }

  return [pscustomobject]@{
    repo_root = $source
    worktree = $worktreePath
    sympp_home = $homePath
    runtime_file = Join-Path $homePath "runtime/beta.json"
    log_dir = Join-Path $homePath "logs"
    mix_build_root = Join-Path $homePath "build/source"
    codex_home = Join-Path $homePath "codex"
    database = [System.IO.Path]::GetFullPath($DatabasePath)
    ledger_mode = if ($UseLiveLedger) { "live" } else { "sandbox" }
    backend_port = $Backend
    dashboard_port = $Dashboard
  }
}

function Invoke-BetaGit([string]$Root, [string[]]$Arguments) {
  $output = @(& git -C $Root @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "git -C '$Root' $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  return $output
}

function Get-BetaGitWorktrees([string]$Root) {
  $result = @()
  $current = $null
  foreach ($line in @(Invoke-BetaGit $Root @("worktree", "list", "--porcelain"))) {
    if ($line -like "worktree *") {
      if ($current) { $result += [pscustomobject]$current }
      $current = @{ path = [System.IO.Path]::GetFullPath($line.Substring(9)); branch = $null }
    } elseif ($current -and $line -like "branch *") {
      $current.branch = $line.Substring(7)
    }
  }
  if ($current) { $result += [pscustomobject]$current }
  return $result
}

function Initialize-BetaWorktree($Config) {
  [void](Invoke-BetaGit $Config.repo_root @("rev-parse", "--show-toplevel"))
  [void](Invoke-BetaGit $Config.repo_root @("fetch", "origin", "beta"))
  $worktrees = @(Get-BetaGitWorktrees $Config.repo_root)
  $target = @($worktrees | Where-Object { Test-SamePath $_.path $Config.worktree }) | Select-Object -First 1

  if (Test-Path -LiteralPath $Config.worktree) {
    if (-not $target) { throw "Refusing to overwrite a path that is not this repository's beta worktree: $($Config.worktree)" }
    if ($target.branch -ne "refs/heads/beta") { throw "Refusing to reuse $($Config.worktree): it has $($target.branch), not beta." }
  } else {
    $otherBeta = @($worktrees | Where-Object { $_.branch -eq "refs/heads/beta" }) | Select-Object -First 1
    if ($otherBeta) { throw "Local branch beta is already checked out at $($otherBeta.path)." }
    $localBeta = @(& git -C $Config.repo_root branch --list beta)
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect local branch beta." }
    if ($localBeta.Count -gt 0) {
      [void](Invoke-BetaGit $Config.repo_root @("worktree", "add", $Config.worktree, "beta"))
    } else {
      [void](Invoke-BetaGit $Config.repo_root @("worktree", "add", "--track", "-b", "beta", $Config.worktree, "origin/beta"))
    }
  }

  [void](Invoke-BetaGit $Config.worktree @("branch", "--set-upstream-to=origin/beta", "beta"))
  $remote = @(Invoke-BetaGit $Config.worktree @("config", "--get", "branch.beta.remote")) | Select-Object -First 1
  $merge = @(Invoke-BetaGit $Config.worktree @("config", "--get", "branch.beta.merge")) | Select-Object -First 1
  if ($remote -ne "origin" -or $merge -ne "refs/heads/beta") { throw "Beta branch is not tracking origin/beta." }
}

function Get-BetaEnvironment($Config, [switch]$Package) {
  $environment = [ordered]@{
    SYMPP_HOME = $Config.sympp_home
    SYMPP_RUNTIME_FILE = $Config.runtime_file
    SYMPP_LOG_DIR = $Config.log_dir
    MIX_BUILD_ROOT = $Config.mix_build_root
    SYMPP_REPO_ROOT = $Config.worktree
    SYMPP_DATABASE = $Config.database
    SYMPP_BACKEND_PORT = [string]$Config.backend_port
    SYMPP_DASHBOARD_PORT = [string]$Config.dashboard_port
    SYMPP_BACKEND_URL = $null
    SYMPP_DASHBOARD_ORIGIN = $null
    SYMPP_AUTOSTART_SERVERS = $null
    SYMPP_AUTOSTART_BACKEND = $null
    SYMPP_AUTOSTART_FRONTEND = $null
    SYMPP_LAUNCHER = $null
    SYMPP_MIX = $null
    SYMPP_MCP_BRIDGE_MODE = $null
  }
  if ($Package) { $environment.CODEX_HOME = $Config.codex_home }
  return $environment
}

function Invoke-WithBetaEnvironment($Config, [scriptblock]$Command, [switch]$Package) {
  $previous = @{}
  $environment = Get-BetaEnvironment $Config -Package:$Package
  try {
    foreach ($name in $environment.Keys) {
      $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
      [Environment]::SetEnvironmentVariable($name, [string]$environment[$name], "Process")
    }
    & $Command
  } finally {
    foreach ($name in $environment.Keys) {
      [Environment]::SetEnvironmentVariable($name, $previous[$name], "Process")
    }
  }
}

function Assert-BetaRuntimeIdentity($Config, $State) {
  if ($null -eq $State) { return }
  $sourcePlugin = Join-Path $Config.worktree "plugins/symphony-plus-plus-mcp"
  if (-not (Test-SamePath $State.repo_root $Config.worktree) -or
      (-not (Test-PathInside $State.plugin_root $sourcePlugin) -and -not (Test-PathInside $State.plugin_root $Config.codex_home)) -or
      [int]$State.backend.port -ne $Config.backend_port -or [int]$State.frontend.port -ne $Config.dashboard_port -or
      $State.backend.url -ne "http://127.0.0.1:$($Config.backend_port)" -or
      $State.frontend.origin -ne "http://127.0.0.1:$($Config.dashboard_port)" -or $State.runtime_mode -ne "source") {
    throw "Refusing to control runtime state that does not match the isolated beta identity: $($Config.runtime_file)"
  }
}

function Get-BetaRuntimeState($Config) {
  if (-not (Test-Path -LiteralPath $Config.runtime_file -PathType Leaf)) { return $null }
  $state = Get-Content -LiteralPath $Config.runtime_file -Raw | ConvertFrom-Json
  Assert-BetaRuntimeIdentity $Config $state
  return $state
}

function Get-BetaProcessCommandLine([int]$ProcessId) {
  if ($ProcessId -le 0) { return $null }
  if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
    try { return [string](Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop).CommandLine } catch { }
  }
  $path = "/proc/$ProcessId/cmdline"
  if (Test-Path -LiteralPath $path) {
    try { return ([System.IO.File]::ReadAllText($path) -replace [char]0, " ").Trim() } catch { }
  }
  return $null
}

function Stop-BetaRuntimeEntry([string]$Role, $Entry) {
  if ($null -eq $Entry -or $Entry.managed -ne $true) { return $false }
  $processId = 0
  if (-not [int]::TryParse([string]$Entry.pid, [ref]$processId) -or $processId -le 0) { return $false }
  $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if (-not $process) { return $false }
  $commandLine = Get-BetaProcessCommandLine $processId
  $expected = if ($Role -eq "backend") { "(?i)\bsympp\.cockpit\b" } else { "(?i)\bvite\b" }
  $port = [int]$Entry.port
  if ([string]::IsNullOrWhiteSpace($commandLine) -or $commandLine -notmatch $expected -or $commandLine -notmatch "(?i)--port\s+`"?$port`"?(?=\s|$)") {
    throw "Refusing to stop beta $Role pid=$processId because its command line does not prove role and port ownership."
  }
  Stop-Process -Id $processId -Force
  try { [void]$process.WaitForExit(5000) } catch { }
  return $true
}

function Stop-BetaRuntime($Config, [switch]$BackendOnly) {
  $state = Get-BetaRuntimeState $Config
  if ($null -eq $state) { return }
  if (-not $BackendOnly) { [void](Stop-BetaRuntimeEntry "frontend" $state.frontend) }
  [void](Stop-BetaRuntimeEntry "backend" $state.backend)
}

function Start-BetaRuntime($Config) {
  $launcher = Join-Path $Config.worktree "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1"
  if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "Beta MCP launcher is missing: $launcher" }
  Invoke-WithBetaEnvironment $Config {
    & $launcher -PrepareRuntimeOnly
    if ($LASTEXITCODE -ne 0) { throw "Beta runtime launcher failed with exit code $LASTEXITCODE." }
  }
}

function Test-BetaBootstrap($Config) {
  [void](Invoke-BetaGit $Config.repo_root @("rev-parse", "--show-toplevel"))
  $launcher = Join-Path $Config.repo_root "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.ps1"
  if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "MCP launcher is missing: $launcher" }
  $sourceConfig = $Config.PSObject.Copy()
  $sourceConfig.worktree = $Config.repo_root
  Invoke-WithBetaEnvironment $sourceConfig {
    & $launcher -ValidateOnly
    if ($LASTEXITCODE -ne 0) { throw "Beta bootstrap validation failed with exit code $LASTEXITCODE." }
  }
}

function Install-BetaPlugin($Config) {
  $refresh = Join-Path $Config.worktree "scripts/refresh-local-plugin.ps1"
  New-Item -ItemType Directory -Path $Config.codex_home -Force | Out-Null
  Invoke-WithBetaEnvironment $Config -Package {
    $marketplaces = (& codex plugin marketplace list --json | ConvertFrom-Json).marketplaces
    $marketplace = @($marketplaces | Where-Object { $_.name -eq "symphony-plus-plus" }) | Select-Object -First 1
    if ($marketplace -and -not (Test-SamePath $marketplace.root $Config.worktree)) {
      throw "The isolated Codex home has an unexpected symphony-plus-plus marketplace: $($marketplace.root)"
    }
    if (-not $marketplace) {
      & codex plugin marketplace add $Config.worktree --json
      if ($LASTEXITCODE -ne 0) { throw "Could not add the beta marketplace to the isolated Codex home." }
    }
    & $refresh -CodexHome $Config.codex_home -PluginName symphony-plus-plus-mcp -ValidateInstalledCache
    if ($LASTEXITCODE -ne 0) { throw "Could not refresh the beta MCP plugin in the isolated Codex home." }
    $plugins = (& codex plugin list --json | ConvertFrom-Json).installed
    if (-not @($plugins | Where-Object { $_.pluginId -eq "symphony-plus-plus-mcp@symphony-plus-plus" -and $_.installed -eq $true })) {
      & codex plugin add symphony-plus-plus-mcp@symphony-plus-plus --json
      if ($LASTEXITCODE -ne 0) { throw "Could not install the beta MCP plugin in the isolated Codex home." }
    }
  }
}

function Get-BetaStatus($Config) {
  $state = Get-BetaRuntimeState $Config
  return [pscustomobject]@{
    worktree = $Config.worktree
    branch = if (Test-Path -LiteralPath $Config.worktree) { (@(Invoke-BetaGit $Config.worktree @("branch", "--show-current")) | Select-Object -First 1) } else { $null }
    ledger_mode = $Config.ledger_mode
    environment = Get-BetaEnvironment $Config
    backend_running = $null -ne $state -and $null -ne (Get-Process -Id ([int]$state.backend.pid) -ErrorAction SilentlyContinue)
    frontend_running = $null -ne $state -and $null -ne (Get-Process -Id ([int]$state.frontend.pid) -ErrorAction SilentlyContinue)
    runtime_file = $Config.runtime_file
  }
}

function Write-BetaResult($Value, [bool]$AsJson) {
  if ($AsJson) { $Value | ConvertTo-Json -Depth 6 } else { $Value | Format-List }
}

$config = Resolve-BetaConfiguration $RepoRoot $BetaWorktree $SymppHome $Database $LiveLedger.IsPresent $BackendPort $DashboardPort

switch ($Action) {
  "Setup" {
    Initialize-BetaWorktree $config
  }
  "Validate" { Test-BetaBootstrap $config }
  "Start" {
    Initialize-BetaWorktree $config
    Start-BetaRuntime $config
  }
  "Restart" {
    Initialize-BetaWorktree $config
    Stop-BetaRuntime $config -BackendOnly
    Start-BetaRuntime $config
  }
  "Status" { }
  "Stop" { Stop-BetaRuntime $config }
  "Package" {
    Initialize-BetaWorktree $config
    Install-BetaPlugin $config
  }
  "Codex" {
    Initialize-BetaWorktree $config
    Start-BetaRuntime $config
    Invoke-WithBetaEnvironment $config { & codex -C $config.worktree }
  }
}

Write-BetaResult (Get-BetaStatus $config) $Json.IsPresent
