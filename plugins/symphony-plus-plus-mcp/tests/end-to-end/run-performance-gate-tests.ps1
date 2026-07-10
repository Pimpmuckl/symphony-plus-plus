$ErrorActionPreference = "Stop"

function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../../.."))
$gate = Join-Path $repoRoot "scripts/benchmarks/sympp-mcp/run-performance-gate.ps1"
$docs = @(
  Join-Path $repoRoot "implementation_docs_symphplusplus/docs/18_MCP_PERFORMANCE_GATES.md"
  Join-Path $repoRoot "implementation_docs_symphplusplus/runbooks/SYMPP_MCP_HIGH_CONCURRENCY_CUTOVER.md"
)

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($gate, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) "performance gate must parse as PowerShell"

$selfTest = @(& (Get-Command pwsh -ErrorAction Stop).Source -NoProfile -File $gate -SelfTest)
Assert-True ($LASTEXITCODE -eq 0) "threshold self-test must pass"
Assert-True ($selfTest -contains "status: pass") "threshold self-test must emit TOON status"
$expectedFailures = @(
  "cold.isolated_bootstrap_ms", "warm.p95_ms", "direct.elapsed_ms", "cohort.clients", "backend.singleton", "backend.identity",
  "warm.lease_lifecycle", "warm.network_attempts", "direct.wrapper_processes",
  "direct.wrapper_private_bytes", "direct.backend_private_bytes", "cleanup"
) + @("full", "worker", "architect", "coordinator", "solo" | ForEach-Object { "profiles.$_.tools"; "profiles.$_.bytes" }) +
  @("claim", "read", "progress" | ForEach-Object { "results.$_.bytes" })
$failureLine = [string]($selfTest | Where-Object { $_ -like "intentional_failures*" } | Select-Object -First 1)
Assert-True $failureLine.StartsWith("intentional_failures[$($expectedFailures.Count)]") "self-test must enumerate every threshold branch"
foreach ($failure in $expectedFailures) {
  Assert-True $failureLine.Contains($failure) "self-test must prove intentional failure '$failure'"
}

$usageError = @(& (Get-Command pwsh -ErrorAction Stop).Source -NoProfile -File $gate -Clients 99)
Assert-True ($LASTEXITCODE -eq 2) "invalid release client count must use exit code 2"
Assert-True ($usageError -contains "error: -Clients must be 100 for the release gate") "usage error must be structured and actionable"

foreach ($path in $docs) {
  Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "missing performance gate documentation: $path"
}
$runbook = Get-Content -LiteralPath $docs[1] -Raw
Assert-True ($runbook.Contains("codex plugin marketplace upgrade symphony-plus-plus")) "runbook must use marketplace upgrade"
Assert-True ($runbook.Contains("marketplace source clone")) "runbook must anchor installed cutover to the marketplace source clone"
Assert-True (-not $runbook.Contains("refresh-local-plugin.ps1")) "runbook must not refresh installed cache from a developer checkout"

Write-Host "Performance gate parsing, structured output, threshold failures, and cutover contract passed."
