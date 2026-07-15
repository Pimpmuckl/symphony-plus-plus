# MCP Performance Gates

Run the release gate from the repository root:

```powershell
pwsh -NoProfile -File .\scripts\benchmarks\sympp-mcp\run-performance-gate.ps1
```

The command creates unique non-default loopback ports and isolated database,
home, log, build, dependency, package-cache, temp, and XDG roots. It removes
them and verifies both ports are free before returning. It never uses `19998`
or `19999`, installed plugin state, a shared ledger, existing sessions, or
credentials.

Stdout is one TOON document; progress goes to stderr. Exit `0` means every gate
passed, `1` means a measurement or threshold failed, and `2` means invalid
arguments. Serialized token estimates are `ceil(bytes / 4)`.

## Thresholds

| Metric | Fail when |
|---|---:|
| Isolated dependency compile plus cold bootstrap | over 600,000 ms |
| 100-client production warm attach p95 | over 2,000 ms |
| Exact shipped-command warm attach p95 at 1, 10, or 100 clients | over 2,000 ms |
| Exact shipped-command median private bytes per client | over 66,864,537 bytes |
| 100-client direct HTTP cohort | over 30,000 ms |
| Backend listeners in cold, warm, or direct stage | not exactly 1 |
| Cold/direct backend identity | PID or start timestamp changes |
| Warm leases | peak is not 100 or any remain after clients exit |
| Cold launcher lease after stdin closes | not 0 |
| Warm artifact/remote resolution attempts | not 0 |
| Direct per-agent wrapper processes/private bytes | not 0 / not 0 |
| Backend private bytes after 100 direct clients | over 536,870,912 |

Tool surface caps are: `full` 80 tools/55,000 bytes, `worker` 35/25,000,
`architect` 65/45,000, `coordinator` 30/20,000, and `solo` 30/20,000.
Representative result caps are: claim 600 bytes, 40-line read 1,200 bytes,
and progress append 500 bytes.

The 600-second cold budget includes isolated dependency setup and compilation;
it is a reference-host bootstrap guard, not a new-agent startup SLO. The direct
plugin still fails startup after 10 seconds when the operator-managed singleton
is unavailable.

The cold stage owns one source launcher and singleton only for the lifetime of
the gate and requires its bridge lease to disappear before cleanup. The warm
stage executes the production launcher warm path against a stubbed healthy
endpoint so remote lookup attempts are observable. The direct stage uses the
real isolated backend through the merged HTTP transport probe and confirms
that 100 clients keep the same backend identity without agent wrappers.
The exact-command stage executes the command shipped in `.mcp.json` with Node
present at 1, 10, and 100 clients, then with Node absent to prove the
PowerShell compatibility path. Node cohorts must also perform zero warm Git,
payload, contract, or artifact-manifest resolution and recover after runtime
failure, installed-payload mutation, abandoned locks, and lifecycle races.

Run `-SelfTest` to prove every documented threshold branch without starting a
backend.
