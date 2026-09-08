# Run between S++ tool calls: pwsh -File .\scripts\upgrade-spp.ps1
# Preview without restarting anything: add -WhatIf.
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This upgrade script requires PowerShell 7 on Windows.' }
$symppRoot = if ($env:SYMPP_HOME) { $env:SYMPP_HOME } else { Join-Path $env:USERPROFILE '.agents\splusplus' }
$runtimeFile = if ($env:SYMPP_RUNTIME_FILE) { [IO.Path]::GetFullPath($env:SYMPP_RUNTIME_FILE) } else { Join-Path $symppRoot 'runtime\codex-plugin.json' }
$state = Get-Content -LiteralPath $runtimeFile -Raw | ConvertFrom-Json
$launcher = Join-Path $state.plugin_root 'scripts\start-sympp-mcp.ps1'
if (-not (Test-Path -LiteralPath $launcher)) { throw "Installed S++ launcher not found: $launcher" }
if ($env:SYMPP_REPO_ROOT) { throw 'Clear SYMPP_REPO_ROOT to upgrade the installed runtime.' }
if (-not $state.backend.managed) { throw 'The current S++ backend is not managed by the plugin.' }

$backend = if ($state.backend.pid) { Get-Process -Id $state.backend.pid -ErrorAction SilentlyContinue }
if ($backend) {
    $runtimeRoot = [IO.Path]::GetFullPath($state.publication.backend.runtime_root).TrimEnd('\') + '\'
    if (-not $backend.Path.StartsWith($runtimeRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $backend.StartTime.ToUniversalTime().Ticks.ToString() -ne $state.publication.backend.process_start_time_utc_ticks) {
        throw 'The recorded S++ process identity changed. Refusing to stop it.'
    }
}

if (-not $PSCmdlet.ShouldProcess('S++', 'Stop server, upgrade marketplace, and restart server')) { return }

# Windows denies deletion while this handle is open, keeping bridge recovery out.
$lockPath = "$runtimeFile.cold.lock"
$lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    if ($backend) {
        Write-Host 'Stopping S++...'
        $backend.Kill()
        $backend.WaitForExit()
    }

    try {
        Write-Host 'Upgrading S++...'
        # The upgrade renames the marketplace directory, so run outside it.
        Push-Location $env:USERPROFILE
        try {
            & codex plugin marketplace upgrade symphony-plus-plus
            if ($LASTEXITCODE -ne 0) { throw "Marketplace upgrade failed (exit $LASTEXITCODE)." }
        } finally {
            Pop-Location
        }
    } finally {
        Write-Host 'Starting S++...'
        & pwsh -NoProfile -NonInteractive -File $launcher -PrepareRuntimeOnly
        if ($LASTEXITCODE -ne 0) { throw "S++ startup failed (exit $LASTEXITCODE)." }
    }

    $state = Get-Content -LiteralPath $runtimeFile -Raw | ConvertFrom-Json
    $health = Invoke-RestMethod "$($state.backend.url)/mcp/readiness" -TimeoutSec 10
    if ($health.status -ne 'ok') { throw 'S++ did not report healthy after restarting.' }
    Write-Host "S++ ready ($($health.source.revision)). Existing bridges can reconnect."
} finally {
    $lock.Dispose()
    Remove-Item -LiteralPath $lockPath
}
