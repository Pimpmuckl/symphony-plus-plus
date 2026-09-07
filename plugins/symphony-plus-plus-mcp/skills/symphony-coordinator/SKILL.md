---
name: symphony-coordinator
description: Use when acting as a parent Codex agent coordinating ordinary repo work from a dedicated Symphony++ MCP config across one or more subagents, including scouting, slicing, worker dispatch, review convergence, and PR/evidence integration.
---

# Symphony++ Coordinator

Use for ordinary coordination in a dedicated Symphony++ MCP config. For WorkRequests, WorkPackages,
ledger-backed claims, scoped grants, delivery boards, or MCP merge gates, use
`symphony-plus-plus-mcp:symphony-architect`.

## Start

- Optionally attach a coordinator-owned `symphony-plus-plus-mcp:symphony-solo-session`
  for parent planning. Do not share that session with workers.
- Scout repo context before slicing.
- Identify outcome, base branch, acceptance, owned/forbidden areas, optional
  validation and review context, risk, and any assigned size budget.
- Resolve material ambiguity before dispatch.

## Slice

- Prefer one PR-sized slice per worker.
- Use isolated worktrees/branches for implementation or conflicting parallel
  work. Read-only scouts may use the existing checkout.
- Give workers goal, scope, base/branch/worktree, acceptance, optional
  validation, review, and stop-condition context, any assigned budget, and expected
  PR/evidence.
- Honor assigned budgets; otherwise keep one cohesive outcome and escalate
  material scope growth or reviewability risk. Numerical budgets are optional.
- For S++ WorkPackages, pass ledger claim metadata and local worktree scope.
  Do not prompt normal workers for work keys or private handoff secrets.
- Use explorers for reconnaissance only.

## Dispatch

Worker prompts should include:

- `symphony-plus-plus-mcp:symphony-worker`.
- `symphony-plus-plus-mcp:symphony-solo-session` when durable task memory helps
  and no WorkPackage is assigned. Each worker uses its own session; short
  read-only scouts need no Solo ledger.
- Task-specific scope, evidence, constraints, and deviations from the baseline
  worker contract.
- For manual worktrees, use `C:\Code\.worktrees\<repo>\<feature>`. After
  delivery or abandonment, remove only your clean worktree and run
  `git worktree prune`. S++-managed worktrees use their own lifecycle.

## Supervise

- Do not take over worker implementation by default.
- Answer architecture questions; escalate human/product ambiguity.
- Treat review findings as risk signals, not scope authority.
- Stop or reslice when scope grows, workers collide, or PR budget is at risk.

## Integrate

- Verify PR/evidence against the assigned slice.
- Check changed files, validation, review, CI/check status, and residual risk.
- Merge only when authorized.
- Summarize PRs/no-PR evidence and follow-ups.
