# Symphony++ Codex Plugin

This is the default, MCP-free Symphony++ plugin. It provides the Solo Session,
worker, and coordinator skills for ordinary repository work. Its manifest is
skill-only and the package does not contain a root `.mcp.json`, so enabling it
does not start Symphony++ MCP in generic sessions or review lanes.

WorkRequest and WorkPackage orchestration belongs to the sibling
`symphony-plus-plus-mcp` plugin. That package contains the authoritative
MCP-backed worker, WorkPackage, and architect skills.

## Install

Install or update Symphony++ through the Codex marketplace:

```powershell
codex plugin marketplace add https://github.com/Pimpmuckl/symphony-plus-plus --ref main
codex plugin marketplace upgrade symphony-plus-plus
codex plugin add symphony-plus-plus@symphony-plus-plus
```

Open a fresh Codex session after upgrading.

For a dedicated MCP-enabled Codex home, install the companion instead:

```powershell
codex plugin add symphony-plus-plus-mcp@symphony-plus-plus
```

Do not enable both packages in the same Codex home. Keep the MCP companion out
of generic worker and review configurations.

## Runtime

Installed sessions resolve from the owning Codex marketplace source clone and
select a compatible packaged runtime artifact. The MCP companion starts or
reuses the local backend, serves the packaged dashboard, and attaches its
client bridge. Runtime identity binds the plugin version, marketplace source
revision, platform, artifact manifest, and MCP contract fingerprint.

Do not point an installed plugin at a developer checkout or use
`SYMPP_REPO_ROOT` for normal installed operation. Repair installed state with a
marketplace upgrade and a fresh session, not a repo-local cache refresh.

See the authoritative operator docs:

- [Operations](../../docs/operations.md) for supported workflows.
- [Installed runtime and MCP startup](../../docs/runtime.md) for runtime
  ownership, diagnosis, and repair.
- [Architecture](../../docs/architecture.md) for the product boundary.
- [Development](../../docs/development.md) for source-checkout validation.

## Development

The committed marketplace entry at `.agents/plugins/marketplace.json` points
at `./plugins/symphony-plus-plus` for isolated source development. The local
refresh helper is only for isolated development Codex homes and refuses the
default `~/.codex` cache unless explicitly overridden.

Use the lifecycle doctor for non-destructive diagnostics:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -MarketplaceName symphony-plus-plus -Doctor
```

Do not refresh or validate the user's installed Symphony++ cache from a
developer checkout.
