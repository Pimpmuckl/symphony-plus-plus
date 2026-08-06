# Installed Runtime And MCP Startup

## Normal Installed Flow

The supported user path is:

```powershell
codex plugin marketplace upgrade symphony-plus-plus
```

Open a fresh Codex session after upgrading. The installed plugin resolves its
source from the owning marketplace clone, selects a compatible packaged
runtime artifact, starts or reuses the local backend, and attaches the MCP
client bridge.

The source checkout at `C:\Code\symphony-plus-plus` is a developer workspace.
Its uncommitted files and source-root hints must not determine an installed
session's runtime. Installed diagnostics must resolve the owning marketplace
source clone before considering a developer checkout.

## Runtime Identity

Artifact selection binds together:

- Plugin package and version.
- Marketplace source revision.
- Platform and architecture.
- Runtime artifact manifest.
- MCP contract fingerprint.

The fingerprint lets the launcher reject an artifact whose MCP surface does
not match the installed plugin before initialization.

## Developer Validation

Use `SYMPP_REPO_ROOT` only when deliberately testing a source checkout. It is
never the caller repository and never the normal installed-agent runtime path.

Developer builds write generated Mix output outside the installed plugin cache
so a new source build cannot collide with native libraries loaded by an older
backend.

## Isolated Beta Development

From the stable `main` checkout, this one command creates or reuses the fixed
adjacent `symphony-plus-plus-beta` worktree, starts the isolated source runtime,
and opens Codex with the normal authenticated Codex home:

```powershell
pwsh -NoProfile -File .\scripts\sympp-beta.ps1 -Action Codex
```

Resume an existing thread directly through the beta launcher. Do not open a
fresh beta TUI and then use `/resume`; that can retain the thread's prior MCP
attachment.

```powershell
pwsh -NoProfile -File .\scripts\sympp-beta.ps1 -Action Codex -ResumeSessionId <thread-id>
```

The source beta lane uses backend `20000`, Vite `20001`, and separate
`SYMPP_HOME`, `SYMPP_RUNTIME_FILE`, `SYMPP_LOG_DIR`, `MIX_BUILD_ROOT`, and SQLite
database paths. It keeps `CODEX_HOME` unchanged, so existing authentication and
the normal installed bridge remain available. Stable ports `19998/19999`, the
stable runtime state, and the default installed plugin cache are not control
targets.

Use the same command with `-Action Start`, `Restart`, `Status`, or `Stop` for
beta-only runtime control. Vite owns frontend hot reload. `Restart` restarts
only the source cockpit; the existing bridge reinitializes its MCP session when
the backend returns. Open a fresh beta Codex thread when an MCP tool schema
changes because tool discovery happens at thread startup.

Run `-Action Validate` for the declared launcher and environment check without
starting or stopping either runtime. `-Action Package` refreshes and validates
skill, plugin manifest, launcher, or marketplace changes through a separate beta
`CODEX_HOME`. The guarded repository refresh path makes repeated runs current
and refuses the default Codex plugin cache.

The default beta database is a sandbox ledger under the beta home. Pass
`-Database <copied-ledger>` for destructive lifecycle validation against a
copy. `-LiveLedger` alone selects the normal live ledger; the script rejects
that path without the switch and rejects alternate paths with the switch. Do
not run destructive lifecycle validation in live mode. Existing database paths
are compared by file identity, so aliases of the live ledger are also rejected.

Branch flow:

- Feature PRs target `beta`.
- Urgent fixes land on `main`, then merge `origin/main` forward into `beta`.
- Promotion is a squash PR from `beta` to `main`.
- After promotion, require a clean beta worktree, then recreate beta from main:

```powershell
git -C ..\symphony-plus-plus-beta fetch origin
git -C ..\symphony-plus-plus-beta diff --quiet
git -C ..\symphony-plus-plus-beta diff --cached --quiet
git -C ..\symphony-plus-plus-beta reset --hard origin/main
git -C ..\symphony-plus-plus-beta push --force-with-lease origin beta
```

## Diagnosis

When a fresh session cannot initialize:

1. Capture the exact Codex MCP startup error.
2. Check the current bridge/backend health without restarting working agents.
3. Run lifecycle diagnostics against the owning marketplace source clone.
4. Compare plugin version, source revision, artifact manifest, and contract
   fingerprint.
5. Use marketplace upgrade and a fresh session for installed repair.

Do not:

- Refresh the installed cache from a developer checkout.
- Rewrite runtime state while existing agents are healthy.
- Kill the shared backend merely because one client failed attachment.
- Treat a dirty developer checkout as evidence that the marketplace cache is
  stale.

## Performance Contract

The release gate enforces:

- One backend singleton.
- Exact shipped-command initialization.
- Bounded warm attachment latency.
- No warm Git, payload, contract, or manifest resolution.
- Client lease cleanup.
- Recovery after runtime failure, payload mutation, abandoned locks, and
  lifecycle races.
- Bounded tool discovery and representative result payloads.

Run:

```powershell
pwsh -NoProfile -File .\scripts\benchmarks\sympp-mcp\run-performance-gate.ps1
```

Use `-SelfTest` to exercise every threshold branch without starting a backend.
The gate's executable script owns numeric thresholds; this guide intentionally
does not duplicate them.
