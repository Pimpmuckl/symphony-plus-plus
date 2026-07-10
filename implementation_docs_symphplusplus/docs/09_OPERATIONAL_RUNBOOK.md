# Operational Runbook

## Local Daemon

From `elixir/`:

```bash
mix sympp.cockpit
```

The daemon serves MCP at `http://127.0.0.1:19998/mcp` by default and uses the
local Symphony++ ledger unless `--database <path>` is supplied.

## Installed MCP Cutover

For production-like local Codex usage, keep the running MCP/dashboard pair on
the installed marketplace/cache copy, not on a debug checkout hinted by
`.sympp-source-root`. Use the cutover helper from a current checkout:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sympp-mcp-cutover.ps1 -ExpectedSourceRevision $(git rev-parse HEAD)
```

Before running it for real, inspect the candidate process list without mutating
runtime state:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sympp-mcp-cutover.ps1 -WhatIf
```

The helper inventories `19998`, `19999`, and `20000-20120`, shows the exact S++
launcher/cockpit/Vite PIDs it would stop, leaves unrelated listeners alone,
checks whether the installed plugin cache matches the marketplace snapshot,
runs `codex plugin marketplace upgrade`, validates the installed MCP launcher,
starts the singleton backend/dashboard from the marketplace cache, refreshes
contract-keyed runtime state, runs the MCP HTTP smoke, checks the dashboard
route, and prints both stopped and left-running PIDs. Installed artifact
runtimes normally serve both MCP and the packaged dashboard from `19998`;
`19999` is only a source/Vite development detail.

If `codex plugin marketplace upgrade` cannot move the old installed cache out
of the way, the helper can still recover when the marketplace source snapshot is
already at the expected revision. After the verified S++ processes are stopped,
it refreshes the installed `symphony-plus-plus-mcp` cache payload in place from
the marketplace snapshot, and also refreshes the skill-only
`symphony-plus-plus` cache payload when that package is installed in the target
Codex home. It writes `.sympp-source-revision` markers and verifies file hashes
before starting the singleton.

The fallback does not delete or rename installed cache directories. It refuses
in-place refresh when the marketplace manifest version does not match the
existing cache directory version, when a cache path contains a reparse point, or
when removed marketplace files, old source-root hints, active handles, or copy
failures leave extra/stale installed cache files behind. It also requires
marketplace-side revision evidence; an installed cache marker is not enough to
prove the source snapshot being copied. Treat the printed message as the blocker
and inspect that residue before retrying.

Already-running Codex sessions do not hot-reload their MCP wrapper or cached
`tools/list`. If only the singleton backend/dashboard restarted and the
agent-facing MCP contract did not change, new sessions should attach cleanly and
existing wrapper sessions may recover on their next request. Reboot Codex
sessions when their MCP transport is already closed, when `tools/list` or tool
schemas changed, or when the session still reports stale startup/runtime state
after the singleton cutover.

## Worker Dispatch Check

1. Architect dispatches a planned slice with `dispatch_slice`.
2. Confirm the response includes `work_package.id` and `worker_bootstrap`.
3. Prepare the worker's product-repo worktree with
   `prepare_work_package_worktree`. Pass the WorkPackage id; pass
   `target_repo_root` only when the helper cannot infer the product checkout,
   and pass a concrete `branch` when the WorkPackage branch pattern is absent
   or templated.
   If prepare or cleanup returns `target_repo_root_required`, retry with the
   product checkout that owns the recorded worktree path.
   Use the returned `worker_launch.workspace_path` as the worker cwd.
4. Start a worker MCP-enabled session in that worktree.
5. Worker calls `claim_local_assignment` with the WorkPackage id.
6. Worker calls `get_current_assignment` and proceeds from ledger context.

Worktree path and branch are launch context for coding. They are not required
claim proof in the normal id-first claim path.

## Architect Check

1. Start an MCP-enabled architect session.
2. Call `claim_local_architect_assignment` with the WorkRequest id.
3. Read the WorkRequest, product tree, and delivery board before acting.

## Troubleshooting

- If a claim is rejected for another active owner, inspect/release the claim
  lease or wait for stale-lease recovery.
- If a claim is rejected for scope mismatch, verify the WorkRequest or
  WorkPackage belongs to the intended repo/base branch.
- If tools are missing, verify the opt-in MCP plugin/config was loaded before
  the session started.

## References

- `../../.codex/skills/symphony-work-package/`
- `../../plugins/symphony-plus-plus-mcp/`
- `../templates/references/mcp_wiring.md`
- `../templates/worker_agent_prompt.md`
