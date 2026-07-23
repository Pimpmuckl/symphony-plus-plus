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
