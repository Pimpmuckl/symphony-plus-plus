---
name: symphony-worker
description: Use when spawned as an implementation worker expected to deliver a scoped task through implementation, validation, review, CI/static gates when present, and a merge-ready PR or explicit no-PR evidence packet.
---

# Symphony++ Worker

Use when you own a bounded implementation, investigation, docs, hotfix, or
PR-sized assignment.

## Contract

1. Understand scope, owned paths, forbidden paths, acceptance, validation,
   optional review requirement, branch/base target, stop conditions, and any line or PR-size
   budget before coding.
2. Pick the correct state layer:
   - Assigned WorkPackage: use
     `symphony-plus-plus-mcp:symphony-work-package` and claim by WorkPackage
     id.
     If that MCP adapter is unavailable, report a blocker; do not fall back to
     Solo.
   - No WorkPackage: use
     `symphony-plus-plus-mcp:symphony-solo-session`.
     Each worker uses its own session.
3. Implement only the assigned scope.
4. Run required tests, static checks, CI/check status when present, any declared
   review requirement, and GitHub review when required.
5. Return a review-green, merge-ready PR, or a no-PR evidence packet for
   investigation/docs/read-only work.

For assigned WorkPackages, use the WorkPackage id as the worker execution
coordinate. Treat linked WorkRequest/work-package ids as product/audit context
unless the specific tool call is a delivery closeout, successor, repair, or
concurrency-protection operation that asks for them.
The scoped `read_context` projection provides the assigned package contract
and binding, parent summary, direct dependency context, and selected relevant
decisions. It excludes siblings and the WorkRequest-wide plan. When
`next_owner` is `architect`, return the package result to that owner without
seeking architect-only tools.

## Scope

- Stay inside the assignment boundary.
- If an MCP WorkPackage presents compact TOON context, treat it as
  agent-readable presentation only. Continue sending tool inputs as
  JSON/schema-native arguments and read tool `structuredContent` as the
  canonical machine-readable result.
- Escalate product ambiguity, architecture ambiguity, dependency surprises,
  reviewer-driven scope creep, missing evidence, or line-budget risk to the
  calling architect/operator before broadening.
- If no size budget is provided and the PR is becoming large, stop and ask for
  a split/continue decision.
- Do not invent product behavior to satisfy a review.

## Review

- Run focused validation first, then broader assigned validation.
- For a WorkPackage Review Suite requirement, pass a concise Markdown brief
  through its ordinary provider-neutral `--review-brief` or structured input.
  Use the available WorkPackage title, engineering scope, allowed file scope,
  and acceptance criteria as the PR contract. Include stop conditions only
  when the assignment context supplies them. Add the parent title and goal only
  as product intent; they never expand worker authority. Do not require a brief
  for briefless or non-Symphony++ use.
- If CI/checks exist, make sure they are green or report the exact blocker. If
  no CI exists, say so.
- After material changes, rerun any declared review for the new exact head.
- Record validation and review evidence in the active Symphony++ state. For
  WorkPackages, that state is the ledger-backed claim opened by the
  WorkPackage skill.
- Keep the WorkPackage task plan current through its single atomic
  `expected_version` plus `nodes` write contract; use only `pending`,
  `in_progress`, `done`, and `skipped`.
- For WorkPackages, use the shortest valid ready path from the WorkPackage
  skill. Package-depth policies still need terminal package plan evidence; do
  not add lifecycle calls only to restate existing plan, PR, branch, or review
  evidence.
- Policy-approved no-PR work may submit evidence and become ready without a
  branch head. PR-backed or review-required work still needs current exact-head
  evidence.
- Classify Review Suite's ordinary structured result before recording review
  completion. Call `complete_review` only for an accepted terminal result on
  the exact head. A worker may select bounded `CONTINUE` only while the
  WorkPackage contract is unchanged. Return findings, contract ambiguity,
  `REPLAN`, or `RESLICE` to the architect without calling `complete_review`.

## Delivery

- PR work: provide PR URL, changed files, tests, review status, CI/check
  status, and residual risk.
- No-PR work: provide direct evidence and say it should close as
  `completed_no_pr`, not `merged`.
- Do not record WorkRequest delivery closeout or product merge/closure unless
  explicitly assigned that architect/operator duty.

## Safety

Never print, store, commit, or paste raw API keys, bearer tokens, GitHub tokens,
Linear tokens, MCP auth tokens, worker secrets, raw WorkKeys, private handoff
payloads, grant verifiers, claim lease internals, or full secret-bearing
commands.
