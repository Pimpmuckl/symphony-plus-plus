---
name: symphony-work-package
description: Use when assigned a Symphony++ WorkPackage; claims the ledger-backed local assignment by WorkPackage id and keeps scoped planning, progress, branch/PR metadata, review evidence, and readiness synchronized through the Symphony++ MCP server.
---

# Symphony++ Work Package

Use this skill for an assigned Symphony++ WorkPackage. It is the MCP-backed
WorkPackage state adapter, not the generic worker contract. Pair it with
`symphony-plus-plus-mcp:symphony-worker`.

The MCP server is the permission boundary and the WorkPackage is the worker
scope boundary. V3 product progress lives on the WorkRequest/product tree;
this skill handles only the dispatched execution/audit record.

For workers, the WorkPackage id is the primary execution coordinate. A linked
work-package id is product-planning/audit context inferred from the current
assignment when possible; pass both ids only when a tool explicitly needs a
cross-slice target, successor relation, audit closeout, or concurrency guard.

## Start

1. Use a dedicated S++ MCP-enabled session connected to the same ledger as
   dispatch.
   Sessions may show worker WorkPackage tool schemas before claim; schema
   visibility is not authority, so claim first.
2. Claim the package with `claim_local_assignment` using the WorkPackage id:
   `{"work_package_id":"<WP id>"}`. Include `claimed_by` only when the
   dispatch payload or operator provided a stable worker identity.
   A successful first claim atomically activates a `ready_for_worker` package.
3. Replay the same local claim after reconnects. The server heartbeats the
   current lease, reclaims stale leases with audit evidence, and rejects paused
   leases or another active owner. Reconnect does not rewrite lifecycle state.
   Stop and report those blockers instead of minting your own replacement.
4. Call `get_current_assignment()` and treat that WorkPackage as authoritative.
5. Read `sympp://work-packages/{id}/acceptance.md` with the other MCP-backed
   package resources.
6. Read current context before coding: `read_context()`, `read_task_plan()`,
   acceptance/review/handoff resources, findings, and progress.
7. Do not create local `task_plan.md`, `findings.md`, or `progress.md` files as
   the source of truth.

## Context Format

S++ MCP resources may include compact TOON text alongside Markdown or JSON for
agent-readable context. Use TOON only as presentation; MCP tool arguments remain
JSON/schema-native, and tool `structuredContent` remains the canonical
machine-readable response.

## Work Loop

Keep S++ current as the work changes:

- `update_task_plan({"expected_version": <read version>, "nodes": [...]})`.
  Each node is `{id?, title?, body?, status?}`. Omit `id` to create a node
  with a required `title`; use the returned server-owned `id` for updates.
  Statuses are `pending`, `in_progress`, `done`, and `skipped`.
- `append_finding(finding, idempotency_key)`.
- `append_progress(event, idempotency_key)`.
- `add_comment(body)`, `list_comments()`, and
  `resolve_comment(comment_id, resolution_note?)` for scoped package notes.
  Pass `target_kind` and `target_id` only for another authorized target.
- `report_blocker(summary, idempotency_key, blocker_id?)` when this worker is
  blocked. Resolve only that same worker-owned blocker with
  `resolve_blocker(blocker_id, resolution, summary, idempotency_key)`.
- `abandon(reason)` only when this worker must terminally abandon an active or
  blocked assignment.
  Active blocker facts remain preserved in the closeout audit trail.
- `request_scope_expansion` when the assignment must grow.
- Use comments for ordinary parent-agent coordination. Worker blocker tools
  record execution blockers; they do not create or resolve architect-owned
  human blockers or guidance.

Human-facing bodies, comments, blocker notes, findings, progress details, and
guidance context are Markdown. Keep titles, ids, statuses, branch names, and
other compact labels plain.

When you need direction, ask the parent or architect through ordinary agent
messaging or comments. State the decision, checked evidence, package impact,
candidate answers if known, and the smallest answer that unblocks you. Treat
architect escalation to `human_info_needed` as a blocker.

Stay inside the assigned WorkPackage. Do not inspect or mutate siblings unless
S++ explicitly gives scoped context.

## Branch, PR, Review

- `attach_branch(head_sha)` once implementation branch exists. Pass `branch`
  only when the package branch pattern is templated or absent.
- `attach_pr(url, head_sha)` after PR creation. Include current check, review,
  or merge metadata in the same call when it is already available.
- Use `sync_pr()` to refresh the currently attached PR. Add top-level current
  state fields such as `head_sha`, `check_summary`, `review_state`, or
  `merge_state` when they changed; use explicit `url`/`number` or `recovery`
  only when repairing missing attachment evidence.
- `submit_review_package(summary, tests, artifacts)` after branch metadata is
  current to record validation and acceptance evidence.
- If `review.md` declares a review requirement, use that provider and its
  optional arguments. After it succeeds for the attached exact head, call
  `complete_review(reference?, note?)`. The reference is an opaque provider or
  human review id; Symphony++ does not interpret provider-specific results.
- If `review.md` says no review is required, do not invent one.

## Ready

Before `mark_ready()`:

- Acceptance is satisfied or explicitly blocked.
- Required tests, static checks, review, and CI/check status are complete or
  accurately reported as absent/blocked.
- Task plan, findings, progress, branch, PR, and any required review completion are current.
  Package-depth policies still require at least one terminal task-plan node.
  Do not add lifecycle calls only to restate facts already present; `mark_ready`
  infers completed plan, PR, branch, and review facts from existing evidence
  when the matching facts are already recorded.
- No active blocker remains.
  Resolve worker-owned blockers with `resolve_blocker`. Architect-owned human
  blockers still require the architect or trusted local operator.

After `mark_ready()` succeeds, evidence is frozen except idempotent replay of
already-recorded writes.

## Safety

Worker grants and local claim leases are scoped to exactly one WorkPackage.
Workers cannot mint keys, approve scope, merge PRs, advance phase state, or use
architect tools. `state_key` preserves initialized MCP handshake continuity
only; the ledger-backed claim is the worker authority.

Never print, store, commit, or paste raw grant secrets, worker secrets,
private handoff payloads, bearer/API/GitHub/Linear tokens, MCP auth tokens,
secret-bearing commands, grant verifiers, or claim lease internals.

## References

- `references/worker_prompt.md`
- `references/mcp_wiring.md`
- `references/handoff.md`
