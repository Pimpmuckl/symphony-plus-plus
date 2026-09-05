# Symphony++

Symphony++ gives Codex agents a local planning board, MCP tools, and a
dashboard for coordinating real work across WorkRequests, WorkPackages,
reviews, blockers, and delivery evidence.

## Install

Add the marketplace once:

```powershell
codex plugin marketplace add https://github.com/Pimpmuckl/symphony-plus-plus --ref main
```

Install the default skill-only plugin for ordinary planning:

```powershell
codex plugin add symphony-plus-plus@symphony-plus-plus
```

Install the MCP companion for dedicated WorkRequest or WorkPackage sessions:

```powershell
codex plugin add symphony-plus-plus-mcp@symphony-plus-plus
```

Update installed packages:

```powershell
codex plugin marketplace upgrade
```

Restart or open a fresh Codex session after installing or upgrading so Codex
loads the new plugin metadata. Do not install both plugins in the same Codex
home unless you intentionally want both skill prefixes visible.

## Dashboard

When the MCP companion starts, it launches or reuses the local Symphony++
runtime.

The launcher prefers loopback port `19998`, then tries higher available ports. On Windows, read the active
dashboard URL with:

```powershell
(Get-Content "$env:USERPROFILE\.agents\splusplus\runtime\codex-plugin.json" -Raw | ConvertFrom-Json).frontend.url
```

The same runtime file records the MCP endpoint as `backend.mcp_url`.

Installed artifact runtimes serve the packaged dashboard from the selected
backend endpoint. A separate `19999` dashboard listener is only a source/Vite
development detail. Set `SYMPP_BACKEND_PORT` only to prefer a specific backend
port; the launcher can fall back when it is unavailable.

The launcher records the actual URLs here:

```text
%USERPROFILE%\.agents\splusplus\runtime\codex-plugin.json
```

## Features

- Solo Sessions: lightweight local planning memory for normal single-agent
  work.
- WorkRequests: product-facing work with decisions, comments, WorkPackages,
  and delivery status.
- WorkPackages: scoped execution records for agents, including branch, PR,
  validation, blocker, review, and readiness evidence.
- Architect flows: split larger requests, dispatch workers, answer guidance,
  and close delivery cleanly.
- Dashboard: scan active work, blockers, PRs, reviews, and runtime status from
  one local page.
- Herdr execution inspector: keep the active architect or coordinator frontier
  beside its agent pane without changing Herdr itself.
- Marketplace runtime: installed sessions use the marketplace cache and
  runtime artifacts instead of compiling from a developer checkout.

## Need More Detail?

- Default plugin: `plugins/symphony-plus-plus/README.md`
- MCP companion: `plugins/symphony-plus-plus-mcp/README.md`
- Product and operator docs: `docs/README.md`
- Installed runtime and MCP startup: `docs/runtime.md`

## License

Apache 2.0. See `LICENSE`.
