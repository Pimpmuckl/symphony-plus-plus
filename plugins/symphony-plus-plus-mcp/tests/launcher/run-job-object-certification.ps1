[System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
$ErrorActionPreference = "Stop"
$inheritedPriority = & (Get-Command pwsh -ErrorAction Stop).Source -NoProfile -NonInteractive -Command '[System.Diagnostics.Process]::GetCurrentProcess().PriorityClass'
if ($inheritedPriority -ne "BelowNormal") { throw "Job certification descendants must inherit BelowNormal priority." }
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("sympp-job-client-" + [guid]::NewGuid().ToString("N"))
$previousRunner = $env:SYMPP_JOB_CLIENT
$previousAssembly = $env:SYMPP_JOB_HELPER_ASSEMBLY
$previousCertification = $env:SYMPP_JOB_CERTIFICATION
try {
  New-Item -ItemType Directory -Path $root | Out-Null
  $assembly = Join-Path $root "job-client.dll"
  Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $PSScriptRoot "job-client.cs") -Raw) -Language CSharp -OutputAssembly $assembly
  $env:SYMPP_JOB_CLIENT = Join-Path $PSScriptRoot "job-client.ps1"
  $env:SYMPP_JOB_HELPER_ASSEMBLY = $assembly
  $env:SYMPP_JOB_CERTIFICATION = "1"
  & (Get-Command node.exe -ErrorAction Stop).Source (Join-Path $PSScriptRoot "cold-start-singleton-smoke.js")
  if ($LASTEXITCODE -ne 0) { throw "Windows Job Object certification failed with exit code $LASTEXITCODE." }
} finally {
  $env:SYMPP_JOB_CLIENT = $previousRunner
  $env:SYMPP_JOB_HELPER_ASSEMBLY = $previousAssembly
  $env:SYMPP_JOB_CERTIFICATION = $previousCertification
  $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
  $resolvedRoot = [System.IO.Path]::GetFullPath($root)
  if ($resolvedRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
