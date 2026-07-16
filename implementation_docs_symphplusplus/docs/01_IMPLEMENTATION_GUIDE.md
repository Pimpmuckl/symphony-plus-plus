# Symphony++ Operator Guide

This guide describes the product as it exists now. It is not an implementation
backlog. Use it to decide which Symphony++ flow to run, what evidence belongs
in the ledger, and when a package is ready for human merge.

## What Symphony++ Is

Symphony++ is a product-tree cockpit plus a permissioned execution layer on top
of the upstream Symphony Elixir runtime. Operators and architects manage
`WorkRequest` records as the human-facing product unit. Larger requests can add
optional nested product plan nodes so progress is visible by product area.
Architects dispatch WorkPackages to workers. The resulting `WorkPackage`
records remain scoped execution/audit units for grants, worktrees, virtual
planning resources, branch/PR/review evidence, and readiness gates.

The source-of-truth split is:

- Symphony++ ledger: WorkRequests, product plan nodes, WorkPackages,
  WorkPackages, permissions, virtual planning files, blockers, findings,
  progress, readiness evidence, and audit events.
- GitHub: code, branches, commits, pull requests, CI, and review status.
- Linear: optional human/project mirror when configured.
- Codex/Symphony: execution of isolated agent runs.

## Choose The Work Shape

Use a `WorkRequest` for product-facing work. It captures the product goal,
target repo/project, branch guidance, constraints, and desired dispatch shape.
For small hotfixes it may stay as one direct request with one slice. For larger
implementations, the architect can organize it with optional product plan nodes
before dispatching slices. See `V3_PRODUCT_TREE_REWORK.md`,
`13_WORKREQUEST_CONTRACT.md`, and `09_OPERATIONAL_RUNBOOK.md`.

The normal human flow is: create the WorkRequest in the local operator cockpit,
choose `Start agent questions` on the WorkRequest detail page, prepare the
architect handoff from the detail page, let the architect use the
`symphony-plus-plus-mcp:symphony-architect` skill and scoped MCP tools to clarify,
record decisions, author/approve WorkPackages, and dispatch approved slices,
then let workers handle their assigned WorkPackages. Workers route product or
architecture ambiguity back to the architect first; unresolved human intent is
recorded as `human_info_needed` for the operator instead of being guessed.
Simple missing facts can stay as plain clarification questions. Higher-impact
human decisions should use the structured `decision_prompt` shape so the
operator sees a TL;DR, details, concrete options with pros/cons, and the always
available freeform redirect path.

Use a single-slice WorkRequest for one already-bounded quick fix, hotfix, or
investigation that does not need product-tree planning.
These requests do not need extra product plan nodes or a phase branch; the
worker still starts from work-package dispatch and the normal ledger-backed
local claim.

Use an architect-led package when the work must be split across multiple child
packages, dependency order matters, or one operator wants an architect agent to
sequence worker dispatch. The architect grant can create narrower child
packages and mint child worker grants inside its explicit phase scope.

Do not create live Linear state or broaden runtime behavior unless the assigned
package explicitly requires it.

## Branch And PR Model

Each worker owns one branch and one PR per dispatched WorkPackage/WorkPackage
unless the overseeing architect explicitly splits or combines scope. PR titles
use:

```text
[SYMPP-...] <package title>
```

Prefer worker branch names that include the package id and a short slug:

```text
agent/<work_package_id>/<short-slug>
```

Target the base branch recorded on the package. Do not assume a historical beta
branch. Human merge remains controlled by branch protection, required reviews,
and package readiness evidence.

## Canonical WorkPackage Worker Lifecycle

1. Architect creates the planned WorkPackage with repo, base branch, owned paths,
   acceptance criteria, test plan, and review-suite requirements.
2. Operator dispatches that same WorkPackage row and prepares a scoped worker
   worktree. Normal output returns only non-secret ledger claim metadata for
   `claim_local_assignment`.
3. Worker starts in a dedicated S++ MCP-enabled session connected to the same
   local ledger.
4. Worker claims or reconnects with `claim_local_assignment`, using the stable
   `claimed_by`, branch, worktree path, and caller id, then reads the current
   assignment and all package virtual resources.
5. Worker updates the package task plan before implementation and records
   findings/progress through MCP as the work changes.
6. Worker implements only the assigned package, requests scope expansion for
   anything outside the grant, and reports blockers instead of silently
   changing direction.
7. Worker attaches branch, PR, validation, and review evidence for the current
   head SHA.
8. Worker calls `mark_ready()` only when acceptance criteria, validation,
   review evidence, and readiness gates are satisfied.

## Architect Lifecycle

An architect agent starts from `00_ARCHITECT_AGENT_HANDOFF.md`, the live
WorkRequest, optional product plan tree, canonical WorkPackage execution records,
and the operator-approved scope. It may create same-phase child packages, mint
narrower child worker grants, inspect child progress, and approve ready
children for phase integration when gates still pass.

For WorkRequest-led work, the architect clarifies product intent, adds optional
product plan nodes when they improve one-glance progress, and turns the result
into a slice plan. Feature work defaults to one feature branch with smaller PRs
targeting that feature branch. Narrow fixes may target `main` directly when the
plan records why a feature branch would add no value.

Architect tools record local Symphony++ state; `merge_child_into_phase` records
a merge artifact and lifecycle transition but does not perform a live Git
merge. The architect or operator still owns the actual Git integration and PR
review discipline outside the MCP tool.

## Evidence Flow

Keep these facts current in Symphony++ state:

- Task plan: active plan, completed/skipped steps, and blockers.
- Findings: discoveries that affect scope, implementation, validation, or
  follow-up decisions.
- Progress: meaningful implementation, validation, review, branch, PR, and
  blocker events.
- Acceptance: proof for every criterion or a precise blocked-validation note.
- Review package: review-suite lanes, artifacts, tests, PR URL, and current
  head SHA.

Local planning files are useful for non-MCP operator lanes only when explicitly
requested. In a normal Symphony++ worker run, the MCP-backed virtual planning
files are the package source of truth.

## Readiness And Merge

Readiness is server-gated. A worker cannot make a package ready while active
blockers, missing acceptance evidence, stale required review artifacts,
required CI failures, missing required PR evidence, base-branch mismatches, or
scope violations remain.

Readiness does not merge code. Human merge remains separate and must respect
GitHub branch protection, current-head review evidence, and the package's
release-validation requirements.
