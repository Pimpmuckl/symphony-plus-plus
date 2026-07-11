---
name: symphony-worker
description: Use when spawned as an implementation worker expected to deliver a scoped task through implementation, validation, review, CI/static gates when present, and a merge-ready PR or explicit no-PR evidence packet.
---

# Symphony++ Worker

Use when you own a bounded implementation, investigation, docs, hotfix, or
PR-sized assignment.

## Contract

1. Understand scope, owned paths, forbidden paths, acceptance, validation,
   review profile, branch/base target, stop conditions, and any line or PR-size
   budget before coding.
2. Pick the correct state layer:
   - Assigned WorkPackage: use
     `symphony-plus-plus-mcp:symphony-work-package` and claim by WorkPackage
     id.
     If that MCP adapter is unavailable, report a blocker; do not fall back to
     Solo.
   - No WorkPackage: use
     `symphony-plus-plus:symphony-solo-session`.
     Each worker uses its own session.
3. Implement only the assigned scope.
4. Run required tests, static checks, CI/check status when present, Review
   Suite profile, and GitHub review when required.
5. Return a review-green, merge-ready PR, or a no-PR evidence packet for
   investigation/docs/read-only work.

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
- If CI/checks exist, make sure they are green or report the exact blocker. If
  no CI exists, say so.
- After material changes, rerun the same required review profile; do not step
  down to a lower review level.
- Record validation and review evidence in the active Symphony++ state. For
  WorkPackages, that state is the ledger-backed claim opened by the
  WorkPackage skill.

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
