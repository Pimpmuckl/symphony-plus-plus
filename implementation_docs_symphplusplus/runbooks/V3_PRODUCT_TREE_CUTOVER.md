# V3 Product Tree Cutover Runbook

## Goal

Validate the v3 cockpit against a migrated copy of the current Symphony++
ledger before touching the live local database.

## Preview Procedure

1. Create a migrated copied-ledger preview from `elixir/`:

```powershell
cd elixir
mix run scripts/sympp_v3_preview.exs
```

The helper snapshots the default local ledger with SQLite `VACUUM INTO`, runs
the current Symphony++ migrations against the copy, and prints the preview
database path. To seed a representative product tree for one larger
WorkRequest, pass its id:

```powershell
cd elixir
mix run scripts/sympp_v3_preview.exs -- --seed_work_request <work-request-id>
```

Use `--source <sqlite>` or `--target <sqlite>` only for explicit alternate
ledger experiments.

2. Start the cockpit API bridge against the copied DB:

```powershell
cd elixir
mix sympp.cockpit --database ..\tmp\v3-preview\symphony_plus_plus_v3_preview.sqlite3 --port 20000 --dashboard-origin http://127.0.0.1:20001
```

Ports `20000/20001` are preview-only overrides; the standard local operator
defaults remain `19998/19999`.

3. Start the Vite cockpit against that API:

```powershell
cd elixir\assets
$env:SYMPP_API_ORIGIN = "http://127.0.0.1:20000"
$env:SYMPP_DASHBOARD_PORT = "20001"
npm run dev
```

4. Open:

```text
http://127.0.0.1:20001/sympp/board
```

## Acceptance Checks

- The live database path is not the same as the preview database path.
- The preview database has all four `sympp_product_tree_*` tables.
- The cockpit renders one collapsed row per WorkRequest.
- Expanding a WorkRequest renders product plan nodes when present.
- A `--seed_work_request` preview shows nested product plan nodes linked to
  planned slices for that request.
- WorkRequests without product plan nodes render direct slice rows.
- Package detail remains reachable from linked slice rows.
- Existing WorkRequest detail drawers still open.
- No work keys, raw grants, private handoff payloads, tokens, or secret-bearing
  commands appear in the payload or UI.

## Dogfood Checks

Exercise three WorkRequest shapes before live cutover:

1. Simple hotfix: no product plan nodes, direct planned slices only.
2. Medium implementation: a WorkRequest with direct slices and no forced extra
   hierarchy.
3. Large implementation: nested product plan nodes with planned slices moved
   under the nodes through architect MCP tools.

The preview passes only when all three read correctly in the cockpit and the
large implementation can be rearranged by agents without needing a human
reorganize UI.

## PR And Review Gates

Before live cutover:

1. Push the `v3` branch and open a draft PR against `main`.
2. Complete any declared review requirement on the final PR head.
3. Run GitHub review for the PR, or record an explicit waiver if no PR review is
   available.
4. Wait for CI/checks when present, or record that no checks are configured.
5. Confirm plugin and MCP adoption from the final checkout:

```powershell
.\scripts\refresh-local-plugin.ps1 -ValidateInstalledCache
.\scripts\smoke-sympp-mcp-http.ps1 -RepoRoot .
```

After plugin cache refresh, restart or reload the dedicated MCP-enabled Codex
session before treating its tool palette as current. A still-running session may
keep the old MCP tool list even when the source server and smoke test are
correct.

6. Confirm `git status --short` is clean and no copied SQLite preview database
   is tracked.

## Live Cutover

After preview acceptance:

1. Stop old local cockpit servers.
2. Back up the live ledger.
3. Run the same migration against the live ledger through `mix sympp.cockpit`.
4. Start Vite/API with the standard operator ports.
5. Refresh local plugin caches and restart/reload dedicated MCP-enabled Codex
   sessions so architect agents can discover the V3 product-tree tools.
6. Seed product plan nodes only for large WorkRequests that benefit from the
   product tree.
7. Leave small hotfix WorkRequests as direct-slice rows.

## Rollback

If the preview fails, discard `tmp\v3-preview/symphony_plus_plus_v3_preview.sqlite3`
and fix the branch. No live database action is required.

If live cutover fails after migration, stop the cockpit, restore the backed-up
SQLite file, and reopen the previous branch.
