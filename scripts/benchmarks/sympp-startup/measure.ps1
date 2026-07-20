param(
  [int]$ColdSamples = 7,
  [int]$WarmSamples = 50,
  [int]$TimeoutSeconds = 30,
  [switch]$Release
)

$ErrorActionPreference = "Stop"
if ($ColdSamples -lt 1 -or $WarmSamples -lt 1 -or $TimeoutSeconds -lt 1) {
  throw "ColdSamples, WarmSamples, and TimeoutSeconds must be positive."
}
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$elixirRoot = Join-Path $repoRoot "elixir"
$powershell = (Get-Process -Id $PID).Path
$mix = (Get-Command mix -ErrorAction Stop).Source
$commandHost = Join-Path $PSScriptRoot "invoke.ps1"
$releaseEntrypoint = Join-Path $elixirRoot "_build\prod\rel\symphony_elixir\bin\symphony_elixir.bat"
if ($Release -and -not (Test-Path -LiteralPath $releaseEntrypoint)) {
  throw "Release not found. Run `$env:MIX_ENV='prod'; mix release --overwrite from $elixirRoot."
}
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(2)

function Get-FreePort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try { return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}

function Get-Median([double[]]$Values) {
  $sorted = @($Values | Sort-Object)
  $middle = [int][Math]::Floor($sorted.Count / 2)
  if ($sorted.Count % 2) { return $sorted[$middle] }
  return ($sorted[$middle - 1] + $sorted[$middle]) / 2
}

function Invoke-Readiness([string]$Url) {
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $response = $client.GetAsync($Url).GetAwaiter().GetResult()
  $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  $watch.Stop()
  if (-not $response.IsSuccessStatusCode) { throw "Readiness returned HTTP $([int]$response.StatusCode)." }
  $payload = $body | ConvertFrom-Json
  if ($payload.status -ne "ok" -or $payload.ledger.reachable -ne $true) { throw "Readiness was not healthy." }
  return $watch.Elapsed.TotalMilliseconds
}

function Set-ReleaseEnvironment([Diagnostics.ProcessStartInfo]$StartInfo, [string]$RunRoot, [int]$Port) {
  $StartInfo.Environment["SYMPP_RUNTIME_ARTIFACT"] = "1"
  $StartInfo.Environment["SYMPP_RUNTIME_ARTIFACT_ACKNOWLEDGED"] = "1"
  $StartInfo.Environment["SYMPP_LOGS_ROOT"] = Join-Path $RunRoot "logs"
  $StartInfo.Environment["SYMPP_BACKEND_PORT"] = "$Port"
  $StartInfo.Environment["RELEASE_TMP"] = Join-Path $RunRoot "release-tmp"
  $StartInfo.Environment["PHX_SERVER"] = "true"
  $StartInfo.Environment["HOME"] = Join-Path $RunRoot "home"
  $StartInfo.Environment["USERPROFILE"] = Join-Path $RunRoot "home"
}

$cold = [Collections.Generic.List[double]]::new()
$warm = [Collections.Generic.List[double]]::new()

try {
  foreach ($sample in 1..$ColdSamples) {
    $port = Get-FreePort
    $runRoot = Join-Path ([IO.Path]::GetTempPath()) "sympp-startup-$([Guid]::NewGuid().ToString('N'))"
    $database = Join-Path $runRoot "ledger.sqlite3"
    [void](New-Item -ItemType Directory -Path $runRoot, (Join-Path $runRoot "home"), (Join-Path $runRoot "logs"), (Join-Path $runRoot "release-tmp"))

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.WorkingDirectory = $elixirRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    if ($Release) {
      $startInfo.FileName = $powershell
      $arguments = @("-NoLogo", "-NoProfile", "-File", $commandHost, $releaseEntrypoint, "start")
      Set-ReleaseEnvironment $startInfo $runRoot $port
    } else {
      $startInfo.FileName = $powershell
      $arguments = @(
        "-NoLogo", "-NoProfile", "-File", $commandHost, $mix, "sympp.cockpit", "--host", "127.0.0.1", "--port", "$port",
        "--database", $database, "--dashboard-origin", "http://127.0.0.1:1", "--no-open-dashboard"
      )
    }
    foreach ($argument in $arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $startInfo.Environment["SYMPP_DEFER_DASHBOARD_OPEN"] = "1"
    $startInfo.Environment["SYMPP_OPEN_DASHBOARD"] = "0"

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $watch = [Diagnostics.Stopwatch]::StartNew()
    [void]$process.Start()

    try {
      $url = "http://127.0.0.1:$port/mcp/readiness"
      $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
      while ($true) {
        if ($process.HasExited -and (-not $Release -or $process.ExitCode -ne 0)) {
          throw "Backend exited with $($process.ExitCode): $($process.StandardError.ReadToEnd())"
        }
        try {
          [void](Invoke-Readiness $url)
          $watch.Stop()
          $cold.Add($watch.Elapsed.TotalMilliseconds)
          break
        } catch {
          if ([DateTimeOffset]::UtcNow -ge $deadline) {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            throw "Backend timed out: $($process.StandardError.ReadToEnd()) $($process.StandardOutput.ReadToEnd())"
          }
          Start-Sleep -Milliseconds 10
        }
      }

      foreach ($probe in 1..$WarmSamples) { $warm.Add((Invoke-Readiness $url)) }
    } finally {
      if (-not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
      }
      Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  [ordered]@{
    mode = if ($Release) { "release" } else { "source" }
    cold_start = [ordered]@{
      samples = $cold.Count
      p50_ms = [Math]::Round((Get-Median $cold.ToArray()), 3)
      min_ms = [Math]::Round(($cold | Measure-Object -Minimum).Minimum, 3)
      max_ms = [Math]::Round(($cold | Measure-Object -Maximum).Maximum, 3)
    }
    warm_singleton_reuse = [ordered]@{
      samples = $warm.Count
      p50_ms = [Math]::Round((Get-Median $warm.ToArray()), 3)
      min_ms = [Math]::Round(($warm | Measure-Object -Minimum).Minimum, 3)
      max_ms = [Math]::Round(($warm | Measure-Object -Maximum).Maximum, 3)
    }
  } | ConvertTo-Json -Depth 4
} finally {
  $client.Dispose()
}
