# Symphony++ MCP Opt-In Plugin

This package is the explicit MCP-backed companion to the default
`symphony-plus-plus` Codex plugin. It is the complete MCP-mode plugin for
dedicated Symphony++ WorkRequest and WorkPackage sessions.

Use the default plugin for generic sessions, review-suite lanes, `codex review`,
visible desktop cockpit threads, and MCP-free planning. Use this opt-in
plugin only in a dedicated Codex config, alternate Codex home, managed
app-server session, or worker/architect subprocess where starting
`symphony_plus_plus` MCP before session startup is intentional. In MCP mode,
this package provides the full skill set under the `symphony-plus-plus-mcp:`
prefix: Solo Session, worker, coordinator, WorkPackage, and architect.

Do not enable this plugin in the normal global Codex config unless every
generic Codex session on that config should start Symphony++ MCP. Current Codex
host behavior can eagerly start plugin-bundled MCP servers for each enabled
plugin session.

This plugin intentionally bundles:

- `mcpServers: "./.mcp.json"` for the bundled command-backed launcher. The first
  MCP-enabled Codex session starts the local backend/dashboard singleton when it
  is missing; later sessions reuse it and bridge stdio to its HTTP MCP endpoint.
  Installed artifact runtimes serve the packaged dashboard from the backend
  origin by default.
- The same `assets/splusplus-logo.png` icon used by the default Symphony++ plugin.
- `assets/sympp-runtime-artifacts.json`, a stable release-channel pointer for
  prebuilt installed-runtime artifacts.
- The MCP-mode Solo Session, worker, coordinator, architect, and WorkPackage skills.
- The local MCP launcher plus the Solo wrapper script needed after
  marketplace/cache packaging. The cutover helper
  discovers the full Codex marketplace source clone automatically, so normal
  marketplace installs do not require users to set `SYMPP_REPO_ROOT`.

The installed-runtime contract lives in the source repository operator docs as
`docs/runtime.md`. It defines the verified artifact path,
release-channel gate, manifest fields, static dashboard expectations,
source-checkout fallback semantics, and diagnostics. Installed plugin cache
copies of this README are self-contained and include the stable channel pointer
used by the launcher artifact lookup path.

The default `symphony-plus-plus` plugin must remain skill-only and should stay
enabled broadly for non-MCP work. Dedicated MCP homes should enable this
companion plugin instead of the default plugin so the session has the full MCP
skill set and the `symphony_plus_plus` tool namespace from one package. Do not
enable both packages in the same Codex home unless you intentionally want both
skill prefixes visible. Codex starts a quiet bridge that launches or reuses the
loopback HTTP singleton; background backend/frontend logs remain under the local
runtime log directory instead of streaming through every MCP call.

## Activation

Install this package only from the Codex home used for dedicated Symphony++
WorkRequest or WorkPackage sessions:

```powershell
codex plugin add symphony-plus-plus-mcp@symphony-plus-plus
```

Then restart or reload that dedicated Codex session. Plugin MCP tools are
registered at session startup; an already-open session that only loaded
`symphony-plus-plus@symphony-plus-plus` can show the default Solo skill while still
having no `symphony_plus_plus` MCP tool namespace.

From the repository root, the activation doctor explains the current state and
next action:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -MarketplaceName symphony-plus-plus -Doctor
```

The doctor checks cache, launcher config, singleton reachability, and package
fingerprints against the Codex marketplace snapshot. It cannot inspect tools
already registered inside an open Codex model session; if the doctor is healthy
but tools are still absent, restart or reload the dedicated MCP-enabled session.

Keep this companion out of generic worker, `worker_smart`, review-suite, and
`codex review` configs so ordinary review and execution sessions stay MCP-clean.

Use `codex plugin marketplace upgrade` to install a new marketplace payload,
then start or reload the dedicated Codex session. Its launcher resolves runtime
code from the marketplace-installed plugin payload, starts a compatible
singleton when none is healthy, and reuses an existing one when possible. The
cutover helper remains available from the marketplace source clone for explicit
operator preflight and repair; ordinary startup and crash recovery do not
require it.

Runtime identity is the agent-facing MCP contract fingerprint plus the backend
and dashboard endpoints. In artifact mode, the launcher prefers loopback port
`19998`, falls back to the next available port, and serves the dashboard from
the same endpoint; a separate `19999` listener is only expected for source/Vite
dashboard development. The actual endpoints are recorded in the runtime state.
If the singleton disappears, the next MCP-enabled Codex session starts it again.

To prove the daemon independently of Codex plugin loading, run this from the
marketplace source checkout after cutover or `mix sympp.cockpit` is running.
This helper is not copied into installed plugin cache directories:

```powershell
.\scripts\smoke-sympp-mcp-http.ps1 -RepoRoot .
```

Passing this smoke confirms the local HTTP MCP endpoint handshakes, exposes the
expected unbound tools, and reports source diagnostics for the checkout. It
does not confirm that a Codex app session has loaded this opt-in plugin or the
latest skill Markdown; refresh the local plugin cache, then reload or start
that dedicated MCP-enabled session after changing plugin config, cache state,
or skill files. If the smoke reports `stale_or_unverified_daemon` or
`stale_daemon_source_revision_mismatch`, an old manual cockpit may still own
the configured port. Resolve that operator state before cutover; do not point
the installed plugin at a developer checkout as a workaround.
