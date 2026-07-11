---
name: symphony-coordinator
description: Use when acting as a parent Codex agent coordinating ordinary non-MCP repo work across one or more subagents, including scouting, slicing, worker dispatch, review convergence, and PR/evidence integration.
---

# Symphony++ Coordinator

Use for ordinary non-MCP coordination. For WorkRequests, WorkPackages,
ledger-backed claims, scoped grants, delivery boards, or MCP merge gates, use
`symphony-plus-plus-mcp:symphony-architect`.

## Start

- Optionally attach a coordinator-owned `symphony-plus-plus:symphony-solo-session`
  for parent planning. Do not share that session with workers.
- Scout repo context before slicing.
- Identify outcome, base branch, acceptance, owned/forbidden areas,
  validation, review profile, risk, and line/PR-size budget.
- Resolve material ambiguity before dispatch.

## Slice

- Prefer one PR-sized slice per worker.
- Use fresh worktrees/branches when isolation or parallelism matters.
- Give workers goal, scope, base/branch/worktree, acceptance, validation,
  review profile, budget, stop conditions, and expected PR/evidence.
- PR-size or line-budget guidance; add slice-specific PR-size or line-budget
  constraints when the default boundary is not enough. These budgets should
  always be used and split between implementation- and test work when possible.
- For S++ WorkPackages, pass ledger claim metadata and local worktree scope.
  Do not prompt normal workers for work keys or private handoff secrets.
- Use explorers for reconnaissance only.

## Dispatch

Worker prompts should include:

- `symphony-plus-plus:symphony-worker`.
- `symphony-plus-plus:symphony-solo-session`, unless the worker is assigned a
  WorkPackage. Each worker uses its own session.
- Task-specific scope, evidence, constraints, and deviations from the baseline
  worker contract.
- Create a worktree for each worker agent to work in

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
