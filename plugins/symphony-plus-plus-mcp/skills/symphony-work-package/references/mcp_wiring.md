# Symphony++ MCP Wiring

The skill assumes the worker session has access to the Symphony++ MCP server
from this repository's Elixir implementation.

## Plugin And MCP Boundary

The installable Codex plugin is skill-only by default. Its
`plugins/symphony-plus-plus/.codex-plugin/plugin.json` manifest must not declare
`mcpServers`; generic Codex sessions, review-suite lanes, and `codex review`
calls should not start Symphony++ MCP merely because the plugin is enabled.

The default package must not include `plugins/symphony-plus-plus/.mcp.json` at
all. The sibling `plugins/symphony-plus-plus-mcp` opt-in package owns the
bundled root `.mcp.json` that uses the documented direct server-map shape.
Dedicated S++ workflows can copy or reference that package's generic
command-backed `symphony_plus_plus` launcher when they explicitly need MCP.

MCP discovery is loaded by the Codex host, not by the skill text in an
already-running thread. During normal feature-branch development, do not
refresh or sync user-local plugin caches just to test repo skill edits; local
cache/plugin adoption happens only at final feature-branch cutover. After that
cutover, restart or reload Codex and open a new session before treating stale
skill metadata as a repo packaging failure.

Skill visibility, explicit MCP configuration, global MCP settings visibility,
and current-session tool availability are distinct. A visible skill proves
Codex loaded the skill directory. Explicit MCP configuration proves a worker
session was intentionally given a server dependency. That server may not appear
as a global MCP settings entry. Current-session tools appear only after the host
loads the MCP configuration for that session.

When Codex starts a dedicated session with the opt-in MCP plugin enabled, the
plugin launcher starts fresh managed local backend/dashboard processes before
bridging MCP traffic and reuses them only while another Codex bridge lease is
alive. For manual operation, run the local cockpit/daemon from
`elixir/`:

```bash
mix sympp.cockpit --dashboard-origin http://127.0.0.1:19999
```

By default it binds `127.0.0.1:19998`, prints
`http://127.0.0.1:19999/sympp/board` when a dashboard origin is supplied, and
serves MCP at `http://127.0.0.1:19998/mcp`, backed by the default local ledger. The preferred
home is
`$HOME/.agents/splusplus/symphony_plus_plus.sqlite3`
(`%USERPROFILE%\.agents\splusplus\symphony_plus_plus.sqlite3` on Windows);
if that home is unavailable, Symphony++ falls back under a temp/relative
`.agents/splusplus` root. Pass
`--port 0` for dynamic-port manual tests, or `--port <n>` for a different
explicit port. The bundled opt-in plugin prefers backend port `19998` and
dashboard port `19999`, chooses fallback ports when defaults are occupied by
other services, and records the actual runtime in
`$HOME/.agents/splusplus/runtime/codex-plugin.json` unless
`SYMPP_RUNTIME_FILE` overrides it.

Starting the legacy stdio process from a shell does not register tools with an
already-running model session. S++ MCP opt-in should use a one-session top-level
MCP config, a dedicated alternate Codex config selected before launch, the
sibling `plugins/symphony-plus-plus-mcp` opt-in plugin, or a dedicated S++
agent config file. Do not add S++ MCP to generic worker, reviewer, or
review-suite configs.

The Windows desktop app has no proven per-visible-thread S++ profile picker.
App cockpit threads should use the default skill-only plugin plus Solo Session
CLI planning. When the cockpit needs heavy S++ orchestration, launch a managed
architect or worker subprocess/app-server session with explicit top-level MCP
configuration or the sibling opt-in MCP plugin before that session starts.
That managed subprocess is the supported replacement for app-visible
WorkPackage and architect execution until the desktop host can attach MCP tools
to one already-open thread. Do not invoke this MCP-dependent skill from a
generic visible app thread that does not already show S++ MCP tools; use the
Solo/cockpit handoff path instead.

The opt-in MCP package reference is intentionally generic. It should not embed
bearer tokens, access-grant verifiers, or operator-local secret material.
Installed plugin caches are marketplace-owned. Use `codex plugin marketplace
upgrade` during cutover; do not point the installed plugin at a developer
checkout, worktree, or source-root hint. Repo-local refresh scripts are for
isolated development Codex homes only. The bundled MCP target itself is a local
command-backed stdio-to-HTTP bridge, not a static URL.
Do not refresh user-local plugin caches as part of normal feature-branch worker
dispatch.

Plugin installation is not worker package dispatch. Normal work-package worker
dispatch emits a `worker_bootstrap` payload with `type: ledger_claim`, `mode:
local_assignment`, and `claim.tool: claim_local_assignment`. The worker claims
with only the WorkPackage id and optional `claimed_by` owner, follows the
claim response's explicit re-list action, then calls `get_current_assignment`.

## Local HTTP Server

Run the local daemon from `elixir/`:

```bash
mix sympp.cockpit
```

Use `--database <path>` only when the daemon must connect to a specific
isolated Symphony++ SQLite ledger instead of the default local ledger.

## Codex MCP Dependency

Configure Codex before the model session starts. The bundled opt-in plugin uses
a command-backed launcher so Codex startup can bootstrap the local backend and
dashboard before MCP tools are listed:

```toml
[mcp_servers.symphony_plus_plus]
command = "cmd.exe"
args = ["/d", "/s", "/c", "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.cmd"]
cwd = "<repo>"
```

The launcher forwards Codex stdio MCP messages to the backend HTTP `/mcp`
endpoint while preserving the returned `Mcp-Session-Id`/state key across
`initialize`, `tools/list`, claim, and follow-up calls. A URL-only config can
still be used for explicit local experiments:

```toml
[mcp_servers.symphony_plus_plus]
url = "http://127.0.0.1:19998/mcp"
```

That URL-only shape works only when the backend is already listening on the
configured port before Codex starts; it cannot follow the launcher's dynamic
fallback port selection. Stateless one-shot URL probes may prove health, but
do not treat a fresh probe as a recovered worker session. Claim on the actual
MCP session that will do the WorkPackage work.

## Worker Claim

Workers start by calling `claim_local_assignment` in a dedicated S++ MCP
session connected to the same ledger as dispatch. Pass `work_package_id` and,
when provided, `claimed_by`. Before claim, `get_current_assignment()` succeeds
with `assignment: null` and a claim or reclaim action. After claim, follow
`relist.next_action`, refresh the tool list, then call
`get_current_assignment()` and read package context. The first successful claim
atomically activates a `ready_for_worker` package. Release also returns an
explicit re-list action.

Replaying the same claim heartbeats the current claim lease. If the prior lease
is stale, the server may reclaim it and records audit evidence without
rewriting the current package lifecycle. If the lease is
paused or another active owner still has authority, stop and ask the
architect/operator to repair that state. A configured `state_key` only
preserves initialized handshake continuity for stateless transports; it does
not restore worker authorization by itself.
