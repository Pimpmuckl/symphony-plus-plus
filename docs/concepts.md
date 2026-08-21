# Concepts

Symphony++ is a local planning and orchestration cockpit. Humans see product
progress while agents receive bounded execution assignments from the same
ledger.

## WorkRequest

A WorkRequest is the product goal and the primary dashboard item. It records
the target repository, base branch, description, constraints, clarification,
decisions, plan, and delivery state.

WorkRequest completion is derived from its terminal WorkPackages, closed
questions, and recorded delivery evidence. `sliced` remains the stored planning
status; there is no manual `completed` status transition.

## Group

A Group is an optional title and nesting boundary inside one WorkRequest.
Groups make large plans readable. They have no lifecycle, blocker state, or
manual completion step.

Simple WorkRequests should contain WorkPackages directly. Do not create a
Group merely to wrap one package.

## WorkPackage

A WorkPackage is the canonical architect-to-worker unit from planning through
delivery. It owns:

- One bounded goal and file scope.
- Delivery repository and target base branch.
- Acceptance criteria plus optional validation, stop conditions, and review context.
- Worker claim, worktree, branch, pull request, progress, and findings.
- Provider-backed readiness, blockers, findings, and terminal delivery evidence.

Dispatch activates the planned WorkPackage; it does not create a second
execution record.

## Dependencies

Dependencies express execution order between WorkPackages or Groups. The
backend expands Group relationships into one effective WorkPackage graph and
uses that graph for topology, cycle detection, unmet prerequisites, and
dispatch readiness.

The visual order and grouping of cards do not create dependencies.

## Review And Delivery

A review requirement is provider-agnostic:

```json
{"type":"review-suite","args":{"mode":"normal"}}
```

The provider may instead be another plugin or a human process. Symphony++
records only that the declared review completed for the exact head, with an
optional opaque reference and note.

GitHub remains authoritative for commits, pull requests, CI, and merge state.
Symphony++ records the resulting delivery outcome so WorkRequest completion is
auditable and idempotent.

## Solo Session

A Solo Session is lightweight local planning memory for ordinary single-agent
work. It records plans, progress, findings, decisions, blockers, and validation
without creating a WorkRequest, WorkPackage, worker grant, or dispatch.
