param([int]$Clients = 20)

$ErrorActionPreference = "Stop"
$helperPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../scripts/sympp-mcp-launcher-helpers.ps1"))
. $helperPath

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sympp-cold-smoke-" + [guid]::NewGuid().ToString("N"))
$runtimeFile = Join-Path $tempRoot "runtime.json"
$lockFile = Resolve-StartupLockFile $runtimeFile
$pool = $null
$jobs = [System.Collections.Generic.List[object]]::new()
try {
  $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
  foreach ($name in @("Enter-FileLock", "Exit-FileLock")) {
    $initialState.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name, (Get-Item "function:$name").Definition))
  }
  $pool = [runspacefactory]::CreateRunspacePool(1, $Clients, $initialState, $Host)
  $pool.Open()
  $clientScript = {
    param($LockFile, $RuntimeFile, $BackendPid)
    $lock = Enter-FileLock $LockFile 10
    try {
      if (Test-Path -LiteralPath $RuntimeFile) { return $false }
      Start-Sleep -Milliseconds 25
      [System.IO.File]::WriteAllText($RuntimeFile, "{`"backend_pid`":$BackendPid}")
      return $true
    } finally {
      Exit-FileLock $lock
    }
  }
  foreach ($index in 1..$Clients) {
    $powershell = [powershell]::Create()
    $powershell.RunspacePool = $pool
    [void]$powershell.AddScript($clientScript).AddArgument($lockFile).AddArgument($runtimeFile).AddArgument($PID)
    $jobs.Add([pscustomobject]@{ shell = $powershell; result = $powershell.BeginInvoke() })
  }
  $owners = @($jobs | ForEach-Object { @($_.shell.EndInvoke($_.result)); $_.shell.Dispose() })
  $state = Get-Content -LiteralPath $runtimeFile -Raw | ConvertFrom-Json
  [pscustomobject]@{
    clients = $Clients
    singleton_creations = @($owners | Where-Object { $_ -eq $true }).Count
    backend_processes = @(Get-Process -Id ([int]$state.backend_pid) -ErrorAction SilentlyContinue).Count
  } | ConvertTo-Json -Compress
} finally {
  foreach ($job in $jobs) { try { $job.shell.Dispose() } catch { } }
  if ($pool) { $pool.Dispose() }
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
