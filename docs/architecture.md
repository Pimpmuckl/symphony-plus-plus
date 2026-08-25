# Architecture

## Runtime Shape

The installed MCP plugin launches a lightweight client bridge. The first
client starts the local Symphony++ backend when necessary; later clients attach
to the same singleton.

```text
Codex MCP client
  -> installed plugin bridge
  -> local HTTP MCP endpoint
  -> Symphony++ Elixir runtime
  -> local SQLite ledger
```

The installed launcher chooses an available loopback backend port. The MCP
endpoint and packaged dashboard share it, and the runtime state records both
URLs. Port `19999` is a source-development Vite detail, not part of the
installed product.

## Product Layers

- **Ledger:** WorkRequests, Groups, WorkPackages, questions, decisions,
  dependencies, grants, progress, review completion, and delivery evidence.
- **MCP:** discovery, claims, scoped reads and mutations, dispatch, readiness,
  and recovery.
- **Dashboard:** human projection of the ledger, GitHub state, and active
  runtime.
- **Plugin packages:** installation, launcher scripts, and authoritative agent
  skills.
- **GitHub:** branches, commits, pull requests, checks, reviews, and merge
  truth.

## Identity And Scope

Workers claim one WorkPackage. Architects claim one WorkRequest. The MCP server
derives repository, base branch, phase, anchor, worktree, and grant context from
the ledger and validates any supplied context against it.

Tool discovery is not authorization. Every call still checks the active
session, role, capabilities, resource scope, and lifecycle state.

## Upstream Symphony Boundary

`SPEC.md` and the non-Symphony++ parts of `elixir/` describe the upstream
Symphony runner: tracker polling, workspace management, Codex app-server
execution, and runtime observability.

Symphony++ adds the local ledger, MCP orchestration, plugin runtime, dashboard
cockpit, and GitHub-backed delivery workflow alongside that behavior.

## Contract Ownership

`ToolCatalog` and MCP server handlers own live tool schemas and behavior.
[`mcp_contract.json`](../elixir/priv/symphony_plus_plus/mcp_contract.json)
exports the artifact fingerprint and complete tool-name sets needed by
non-Elixir release smoke tests. A runtime test keeps those names aligned with
`ToolCatalog`; the file does not duplicate schemas.
