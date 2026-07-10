# Symphony++ MCP High-Concurrency Cutover

## 1. Repository evidence

After all launcher, protocol, transport, and gate changes are on the intended
revision, run the performance gate twice from that clean checkout:

```powershell
pwsh -NoProfile -File .\scripts\benchmarks\sympp-mcp\run-performance-gate.ps1
pwsh -NoProfile -File .\scripts\benchmarks\sympp-mcp\run-performance-gate.ps1
```

Keep both TOON outputs with the release evidence. Require `status: pass`, empty
`failures`, Boolean cleanup fields `true`, and `cold_leases_after_close: 0`.
This is repo validation only; it authorizes no cache or session changes.

## 2. Marketplace-backed upgrade

Schedule the installed cutover with the operator. First update the configured
marketplace snapshot:

```powershell
codex plugin marketplace upgrade symphony-plus-plus --json
```

Then change directory to the marketplace source clone under the active Codex
home (normally
`%USERPROFILE%\.codex\.tmp\marketplaces\symphony-plus-plus`). Verify its Git
revision is the released revision. From that marketplace source clone, inspect
the cutover and then run it:

```powershell
pwsh -NoProfile -File .\scripts\sympp-mcp-cutover.ps1 -WhatIf
pwsh -NoProfile -File .\scripts\sympp-mcp-cutover.ps1 -ExpectedSourceRevision (git rev-parse HEAD)
```

Do not run installed-cache refresh/cutover from a developer checkout or
worktree, and do not use `SYMPP_REPO_ROOT` for an agent-ready runtime. Stop on
revision, contract, listener-owner, or cache evidence mismatch.

## 3. Fresh-session activation

After the marketplace-backed cutover passes, open a fresh MCP-enabled Codex
session. Confirm health, direct HTTP discovery, the expected source revision,
the expected contract fingerprint, and the shared HTTP singleton's 76-tool
full/default mixed-role first-list surface. Authorization remains role-scoped
after claim. Already-open sessions do not hot-reload transport or `tools/list`.

## 4. Later hot-swap

A live hot-swap is a separate operator change window. Preserve active sessions
unless the operator explicitly authorizes interruption. Inventory listener
owners and leases, run the marketplace-clone cutover with the released SHA,
verify singleton and HTTP health, and start fresh sessions. An incompatible
existing listener makes cutover fail closed and requires operator-coordinated
singleton replacement; there is no seamless claim. Let legacy sessions drain;
never repoint them at a developer checkout or replace runtime state by hand.

Rollback means rerunning the same marketplace-backed upgrade and cutover for a
known-good released revision, followed by fresh-session verification.
