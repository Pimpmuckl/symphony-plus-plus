param([Parameter(Mandatory)][string]$StateFile, [Parameter(Mandatory)][string]$ClientScript)
$ErrorActionPreference = "Stop"
Add-Type -Path $env:SYMPP_JOB_HELPER_ASSEMBLY
$job = [JobHandle]::new()
$gateFile = "$StateFile.gate"
try {
  Remove-Item -LiteralPath $gateFile -Force -ErrorAction SilentlyContinue
  $start = [System.Diagnostics.ProcessStartInfo]::new((Get-Command pwsh.exe -ErrorAction Stop).Source, '-NoProfile -NonInteractive -Command "while (-not (Test-Path -LiteralPath $env:SYMPP_JOB_GATE)) { Start-Sleep -Milliseconds 10 }; & $env:SYMPP_JOB_CLIENT_SCRIPT"')
  $start.UseShellExecute = $false
  $start.RedirectStandardInput = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.CreateNoWindow = $true
  $start.Environment["SYMPP_JOB_GATE"] = $gateFile
  $start.Environment["SYMPP_JOB_CLIENT_SCRIPT"] = $ClientScript
  $process = [System.Diagnostics.Process]::Start($start)
  $job.Assign($process)
  [System.IO.File]::WriteAllText($gateFile, "ready")
  [Console]::Error.WriteLine("JOB_READY:$($process.Id)")
  $inputTask = [JobHandle]::ProxyInput([Console]::OpenStandardInput(), $process.StandardInput.BaseStream)
  $outputTask = $process.StandardOutput.BaseStream.CopyToAsync([Console]::OpenStandardOutput())
  $errorTask = $process.StandardError.BaseStream.CopyToAsync([Console]::OpenStandardError())
  $seen = [System.Collections.Generic.HashSet[int]]::new()
  do {
    $active = @($job.Pids())
    foreach ($processId in $active) { [void]$seen.Add($processId) }
    [System.IO.File]::WriteAllText("$StateFile.tmp", (($active -join ",") + "`n" + (@($seen) -join ",")))
    [System.IO.File]::Move("$StateFile.tmp", $StateFile, $true)
  } while (-not $process.WaitForExit(25))
  [System.Threading.Tasks.Task]::WaitAll(@($outputTask, $errorTask))
  exit $process.ExitCode
} finally {
  $job.Dispose()
  Remove-Item -LiteralPath $gateFile -Force -ErrorAction SilentlyContinue
}
