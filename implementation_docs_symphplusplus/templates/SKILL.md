---
name: symphony-work-package
description: Use when assigned a Symphony++ WorkPackage; claims the ledger-backed local assignment by WorkPackage id and keeps scoped planning, progress, branch/PR metadata, review evidence, and readiness synchronized through the Symphony++ MCP server.
---

# Symphony++ Work Package

Use this skill for an assigned Symphony++ WorkPackage. It is the MCP-backed
WorkPackage state adapter, not the generic worker contract. Pair it with
`symphony-plus-plus:symphony-worker`.

The MCP server is the permission boundary and the WorkPackage is the worker
scope boundary. V3 product progress lives on the WorkRequest/product tree;
this skill handles only the dispatched execution/audit record.

## Start

1. Use a dedicated S++ MCP-enabled session connected to the same ledger as
   dispatch.
   Sessions may show worker WorkPackage tool schemas before claim; schema
   visibility is not authority, so claim first.
2. Claim with `claim_local_assignment` using the WorkPackage id:
   `{"work_package_id":"<WP id>"}`. Include `claimed_by` only when the
   dispatch payload or operator provided a stable worker identity.
3. Replay the same local claim after reconnects. The server heartbeats the
   current lease, reclaims stale leases with audit evidence, and rejects paused
   leases or another active owner.
4. Call `get_current_assignment()` and treat the returned WorkPackage as the
   only authority for scope.
5. Read the virtual planning resources before implementation:
   - `read_context()`
   - `read_task_plan()`
   - `sympp://work-packages/{id}/findings.md`
   - `sympp://work-packages/{id}/progress.md`
   - `sympp://work-packages/{id}/acceptance.md`
   - `sympp://work-packages/{id}/review_suite.md`
   - `sympp://work-packages/{id}/handoff.md`

Do not create local `task_plan.md`, `findings.md`, or `progress.md` files as
the source of truth for the WorkPackage. Local scratch notes are only temporary
process aids when the operator explicitly asks for them.

## Work Loop

- Update the virtual plan with `update_task_plan(patch, expected_version)`
  before implementation and after meaningful plan changes.
- Record durable discoveries with `append_finding(finding, idempotency_key)`.
- Record meaningful implementation and validation events with
  `append_progress(event, idempotency_key)`.
- Use `report_blocker(summary, idempotency_key, blocker_id?)` for active
  blockers.
- Use `resolve_blocker(blocker_id, resolution, summary, idempotency_key)` once
  the blocker is cleared.
- Use `add_comment(body)`, `list_comments()`, and
  `resolve_comment(comment_id, resolution_note?)` for package-scoped
  implementation comments that need to stay visible in the cockpit. Pass
  `target_kind` and `target_id` only for another authorized target.
- Use `set_status(expected_status, status, reason?)` for allowed non-ready
  lifecycle transitions.
- Use `request_scope_expansion(summary, idempotency_key, payload)` when the
  needed work exceeds the assignment. This records a request; it does not
  approve the expansion.
- Stay inside the assigned WorkPackage. Do not inspect or mutate sibling
  WorkPackages unless Symphony++ exposes a specific context slice.

Human-facing bodies, comments, blocker notes, findings, progress details, and
guidance context are Markdown. Keep titles, ids, statuses, branch names, and
other compact labels plain.

## Branch, PR, And Review Evidence

- Attach the implementation branch with `attach_branch(head_sha)` when the
  package branch pattern is literal. Pass `branch` only when the pattern is
  templated or absent.
- Attach the PR with `attach_pr(url, head_sha)` after it exists. Include
  current check, review, or merge metadata in that call when it is already
  available.
- Refresh current state only for the attached PR with `sync_pr()`. Pass
  top-level current-state fields when they changed; use explicit PR identity or
  `recovery` only for repair.
- Submit review evidence with `submit_review_package(summary, tests, artifacts)`
  after branch metadata is current.
- Prefer `mark_ready(review_suite_round_id)` when the package is otherwise
  ready and a passing local Review Suite round is available. Use
  `attach_review_suite_result(round_id)` only when recording review evidence
  before the finish call.
- If Review Suite is installed, run the current orchestrator with the required
  profile: `review.py --mode brief|normal|deep|emergency`.
- If Review Suite is not installed, use the package-approved review provider
  and record review progress through `append_progress`; include a payload such
  as `type=review_progress`, `provider`, `profile`, `step_current`,
  `step_total`, and `step_name` when available.
- Include review profile verdicts in the review package when the package policy
  requires them.
- Always use the current branch head SHA. Older review evidence can replay for
  lost-response stability, but readiness evaluates against the current head.

## Ready Gate

Before calling `mark_ready()`:

- Acceptance criteria are satisfied or explicitly blocked.
- Required tests and review profile evidence are complete.
- Virtual task plan, findings, and progress are current.
- Branch, PR, and review artifacts are attached when the policy requires them.
- Package-depth policies still require at least one terminal package plan node.
- Do not add lifecycle calls only to restate facts already present; `mark_ready`
  infers completed plan, PR, branch, and review facts from existing evidence
  when the matching facts are already recorded.
- No active blocker remains.
  If a finish transition must address active blockers, pass
  `blocker_closeout` to `set_status` or `mark_ready`.

After `mark_ready()` succeeds, evidence is frozen. Do not append new progress,
findings, blockers, branch/PR metadata, scope requests, or review packages
unless replaying a previously recorded idempotent write.

## Permission Model

- Prompts, skills, hooks, and dashboards are workflow aids; the MCP server is
  the permission boundary.
- Worker grants are scoped to exactly one WorkPackage.
- Worker grants cannot mint keys, approve scope expansion, merge PRs, advance
  phase state, or use architect tools.
- Never print, store, or commit raw grant secrets, worker secrets, private
  handoff payloads, bearer tokens, GitHub tokens, Linear tokens, MCP auth
  tokens, full secret-bearing claim URLs, or grant verifiers.

## Reconnect Notes

`state_key` preserves initialized MCP handshake continuity only. It is not a
bearer capability and does not restore worker authority. Replay
`claim_local_assignment` with the same WorkPackage id after reconnect
initialize.

## References

- `references/worker_prompt.md` has a paste-ready worker prompt.
- `references/mcp_wiring.md` describes the MCP dependency wiring.
- `references/handoff.md` has the final handoff format.
