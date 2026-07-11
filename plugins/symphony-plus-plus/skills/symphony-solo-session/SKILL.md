---
name: symphony-solo-session
description: Use when Codex needs lightweight local planning memory for one normal single-agent repo, worktree, or task without Symphony++ WorkRequest or WorkPackage orchestration. Creates or attaches a local Solo Session, appends task plan, finding, progress, blocker, decision, and validation entries, reads the ledger, and completes or archives the session through the Symphony++ plugin wrapper.
---

# Symphony++ Solo Session

Use Solo Sessions for ordinary single-agent work, non-MCP worker tasks, and
lightweight parent coordination that needs durable local planning memory
without WorkRequest or WorkPackage orchestration. This is the default MCP-free
Symphony++ planning path for real agents.

Do not use this as authority for assigned WorkPackages, WorkRequests,
architect orchestration, bound MCP planning resources, ledger-backed claims, or
merge gates. Use
`symphony-plus-plus-mcp:symphony-work-package` for WorkPackages and
`symphony-plus-plus-mcp:symphony-architect` for WorkRequest orchestration.

## Source Of Truth

The Solo Session ledger replaces local `task_plan.md`, `findings.md`, and
`progress.md` for this task. Keep entries small and non-secret.
Do not create local `task_plan.md`, `findings.md`, or `progress.md` files for
Solo Session state.

Never store raw API keys, bearer/GitHub/Linear/MCP tokens, worker secrets, raw
WorkKeys, access grants, private handoff payloads, access-grant verifiers,
secret hashes, secret-bearing commands, or claim lease internals.

## Tools

Prefer MCP tools from the `symphony_plus_plus` namespace when available in an
unbound session. The exposed tool names are:

```text
solo_attach
solo_show
solo_list
solo_record_task_plan
solo_append_progress
solo_append_finding
solo_record_decision
solo_report_blocker
solo_resolve_blocker
solo_record_validation
solo_pause
solo_resume
solo_complete
solo_archive
```

Otherwise use the wrapper:

```powershell
pwsh <plugin-root>/scripts/sympp-solo.ps1 -Help
pwsh <plugin-root>/scripts/sympp-solo.ps1 -ValidateOnly
```

Do not set `SYMPP_REPO_ROOT` to the caller/task repository. It is an optional
Symphony++ source-checkout override only, used when installed cache source hints
cannot locate the checkout that contains `elixir/mix.exs`.

By default the wrapper uses the shared local ledger at
`$HOME/.agents/splusplus/symphony_plus_plus.sqlite3`. Set `SYMPP_DATABASE` or
`--database` only for an intentional isolated ledger.

## Attach

Attach once near the start and retain the returned `solo_session.id`.

Derive:

- `workspace_path`: repo root from `git rev-parse --show-toplevel`, else
  absolute current directory.
- `repo`: stable remote slug or directory name.
- `base_branch`: assigned target base, upstream/default branch, or current
  branch as fallback.
- `caller_id`: stable local id like `codex:<repo>:<workspace-leaf>`.
- `title`: short task title.

```powershell
pwsh <plugin-root>/scripts/sympp-solo.ps1 attach `
  --repo <repo> --base-branch <base> --workspace-path <path> `
  --caller-id <caller> --title "<task title>"
```

## Record

Record only meaningful state changes. Use non-secret idempotency keys.
Entry bodies are human-facing Markdown; keep summaries and status labels plain.

Use intent-shaped commands rather than choosing raw entry kinds:

- `plan` / `solo_record_task_plan`: phases, strategy changes, current next steps.
- `progress` / `solo_append_progress`: implementation step, handoff, or status update.
- `finding` / `solo_append_finding`: durable discovery, root cause, rejected hypothesis, evidence.
- `decision` / `solo_record_decision`: local technical decision with rationale.
- `blocker` / `solo_report_blocker`: active issue requiring user/operator input.
- `resolve-blocker` / `solo_resolve_blocker`: append-only blocker resolution by `blocker_id`.
- `validation` / `solo_record_validation`: command result, blocked validation, residual risk.

```powershell
pwsh <plugin-root>/scripts/sympp-solo.ps1 progress `
  --session-id <id> --summary "Implemented Solo helper surface" `
  --status active --idempotency-key "solo:<id>:progress:helpers"

pwsh <plugin-root>/scripts/sympp-solo.ps1 validation `
  --session-id <id> --summary "Focused tests passed" `
  --result passed --command "<command>" `
  --idempotency-key "solo:<id>:validation:focused"
```

Keep large logs out of the ledger; summarize and reference local files if
needed.

## Read And Lifecycle

Use `show` after pauses, before major decisions, and before final response.
Use `list` to recover active sessions by repo/base/workspace/caller.
When using MCP tools, close or move sessions with `solo_pause`, `solo_resume`,
`solo_complete`, or `solo_archive`. The tool reads the current status itself.

Lifecycle:

- `active`: work in progress.
- `paused`: intentionally stopped but resumable.
- `completed`: requested work done and validation/review status recorded.
- `archived`: stale or no-longer-needed history.

```powershell
pwsh <plugin-root>/scripts/sympp-solo.ps1 show --session-id <id>
pwsh <plugin-root>/scripts/sympp-solo.ps1 complete --session-id <id>
```
