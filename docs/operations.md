# Operations

This page maps each job to its authoritative entrypoint. Agent procedures live
in packaged skills and are not repeated here.

## Install And Open

Install or update the marketplace package as described in the root
[`README.md`](../README.md). The launcher chooses an available loopback port.
On Windows, read the active dashboard URL with:

```powershell
(Get-Content "$env:USERPROFILE\.agents\splusplus\runtime\codex-plugin.json" -Raw | ConvertFrom-Json).frontend.url
```

The installed MCP companion starts or reuses the local backend and serves the
packaged dashboard from the same runtime.

## Choose A Flow

| Need | Entry point |
|---|---|
| Ordinary single-agent planning | `symphony-plus-plus:symphony-solo-session` |
| Implement one assigned package | `symphony-plus-plus-mcp:symphony-worker` and `symphony-plus-plus-mcp:symphony-work-package` |
| Clarify and slice a WorkRequest | `symphony-plus-plus-mcp:symphony-architect` |
| Coordinate non-MCP repository work | `symphony-plus-plus:symphony-coordinator` |
| Inspect human progress | Dashboard focus board and execution graph |

The packaged skill is the procedure. Assignment text should contain only the
specific goal, scope, evidence, constraints, review requirement, and desired
output.

## WorkRequest Flow

1. Create a WorkRequest in the dashboard or trusted local MCP session.
2. Give an architect the returned WorkRequest claim.
3. Answer material clarification questions.
4. Let the architect create optional Groups, WorkPackages, and dependencies.
5. Dispatch dependency-ready WorkPackages to isolated workers.
6. Merge reviewed pull requests.
7. Reconcile or record terminal delivery evidence.

Use [delivery recovery](runbooks/delivery-recovery.md) when GitHub and the
ledger disagree after a merge or abandoned execution.

## Demo Ledger Visual QA

Create a disposable deterministic ledger with one of `simple`, `multi-repo`,
`superseded`, or `large`:

```powershell
cd elixir
mix sympp.demo_ledger --database .tmp/demo.sqlite3 --scenario large --force
mix sympp.cockpit --database .tmp/demo.sqlite3
```

Then run the existing browser smoke against the printed cockpit URL:

```powershell
node assets/scripts/browser-smoke.mjs --url http://127.0.0.1:19998/sympp/board
```

The scenarios only seed synthetic local ledger data; production dashboard code
does not select or depend on them.

## Runtime Problems

Use [Runtime](runtime.md) for marketplace ownership, startup, cache identity,
and diagnostics. Do not repair an installed runtime from a developer checkout.
