param([Parameter(Mandatory)][string]$StateFile, [Parameter(Mandatory)][string]$ClientScript)
$ErrorActionPreference = "Stop"
Add-Type -Path $env:SYMPP_JOB_HELPER_ASSEMBLY
$job = [JobHandle]::new()
try {
  $start = [System.Diagnostics.ProcessStartInfo]::new("cmd.exe", "/d /s /c call `"$ClientScript`"")
  $start.UseShellExecute = $false
  $start.RedirectStandardInput = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.CreateNoWindow = $true
  $process = [System.Diagnostics.Process]::Start($start)
  $job.Assign($process)
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
}
