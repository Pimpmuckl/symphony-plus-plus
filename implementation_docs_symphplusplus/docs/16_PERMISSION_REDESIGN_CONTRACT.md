# Permission Redesign Contract

This is the target contract for the Symphony++ permission redesign.

The goal is not to replace WorkRequests, WorkPackages, WorkPackages,
questions, comments, planning/progress/findings, blockers, decisions, review
evidence, delivery closeout, or reconciliation. Those remain the product model.

The goal is to replace scattered tool-by-tool capability checks with one
resource-graph authorization model.

## Locked Actor Model

```text
Human / Operator
`-- ledger scope
    |-- can read/write/repair everything local
    |-- can override dangerous state
    |-- can revoke/rekey/archive/delete
    `-- dangerous writes are audited and redacted

Architect
|-- broad redacted read across local operational state
|   |-- WorkRequests
|   |-- WorkPackages
|   |-- WorkPackages
|   |-- comments / guidance / blockers
|   |-- progress / findings / review evidence
|   `-- delivery state and dashboard projections
`-- scoped writes
    |-- claimed WorkRequests and descendants
    |-- explicit human-granted extra scopes
    `-- no implicit Human / Operator powers

Worker
`-- exactly one WorkPackage scope
    |-- task plan / progress / findings
    |-- validation and review evidence
    |-- WP comments / blockers / guidance
    |-- branch / PR / worker-ready evidence
    `-- no sibling, dispatch, merge, or architect authority
```

There is no permanent `global_architect` role in the baseline design. A broad
architect is still an architect holding multiple explicit scopes.

## Core Rule

Every permission decision should reduce to:

```text
actor + role + scopes + target + action -> allow | deny(reason)
```

Tool schemas are not authority. Capability strings are migration metadata, not
the target permission source of truth.

## Resource Graph

Policy resolves raw ids into this graph before deciding:

```text
ledger
|-- repo_scope
|   |-- repo
|   |-- base_branch
|   |-- allowed_paths
|   `-- forbidden_paths
`-- work_request
    |-- repo_scopes
    |-- clarification_questions
    |-- decision_log
    |-- comments
    |-- work_packages
    |   |-- comments
    |   |-- delivery_closeout
    |   `-- work_package
    |       |-- task_plan
    |       |-- progress
    |       |-- findings
    |       |-- validation_notes
    |       |-- review_evidence
    |       |-- blockers
    |       |-- comments
    |       `-- guidance_requests
    `-- dashboard / cockpit projections
```

Do not authorize WorkRequest ownership from repo/base-branch alone. Repo and
base branch are useful metadata, but WorkRequest lineage is the architect write
boundary.

## Baseline Scope Semantics

| Scope | Normal holder | Meaning |
|---|---|---|
| `ledger` | Human / Operator | Full local authority. Dangerous actions require audit/redaction. |
| `work_request` | Architect | Write authority over the claimed WR and descendants. |
| `work_package` | Worker | Write authority inside exactly one WP. |
| `repo` | Architect or WR metadata | Discovery and multi-repo composition, not broad mutation by itself. |
| `work_package` | Rare explicit grant | Prefer reaching slices through WR or WP lineage. |

Architects also have broad redacted read visibility over operational state so
they can avoid duplicate work, understand dependencies, and scope slices
correctly. This read surface must never expose raw secrets, work keys, grant
verifiers, private handoff payloads, bearer/API tokens, or raw destructive
repair internals.

## Action Categories

Use stable action atoms instead of tool names as policy inputs.

```text
work_request_read
work_request_update
question_create / question_answer / question_close
decision_record
work_package_create / work_package_update / work_package_approve
work_package_skip / work_package_dispatch
work_package_read / work_package_update / work_package_repair_state
task_plan_read / task_plan_update
progress_append / finding_append
validation_note_append / review_evidence_append
blocker_report / blocker_resolve / blocker_unblock
comment_add / comment_list / comment_resolve / external_comment_add
guidance_request_create / guidance_request_read
guidance_request_answer / guidance_request_escalate
delivery_board_read / delivery_reconcile_dry_run
delivery_reconcile_apply / delivery_closeout_record
scope_expansion_request / scope_expansion_approve
dashboard_read
dangerous_override / dangerous_rekey / dangerous_delete / dangerous_raw_repair
```

Keep this list small. Add actions only when two callers genuinely need different
authorization behavior.

## Policy Modules

Target namespace:

```text
SymphonyElixir.SymphonyPlusPlus.Authorization
|-- Actor
|-- Scope
|-- Target
|-- Decision
|-- ActorResolver
|-- TargetResolver
|-- Policy
`-- MCPError
```

Recommended decision shape:

```elixir
%Decision{
  allowed?: boolean(),
  actor: Actor.t(),
  action: atom(),
  target: Target.t(),
  reason: atom(),
  reason_code: String.t(),
  matched_scope: Scope.t() | nil,
  requirements: list(),
  audit: map(),
  redactions: list(),
  legacy_reason: String.t() | nil
}
```

Repositories should persist data only. MCP, dashboard, and services should
resolve actors/targets and call policy rather than reimplementing role,
capability, repo, phase, or WorkRequest checks.

## Discovery Rules

Discovery is session-shape information, not authorization.

```text
Unbound session
`-- health, claim/reconnect, safe bootstrap/create tools only

Bound worker
`-- health, current assignment, worker tools only

Bound architect
`-- health, current assignment, all architect tools
    `-- calls still target-check through policy

Local operator
`-- operator tools in trusted local operator mode
    `-- calls still policy-check and audit dangerous writes
```

## Repair Categories

Do not collapse all repair into one permission.

```text
safe reconcile / stale descendant repair
`-- architect allowed inside claimed WR

live runtime override / destructive repair
`-- operator only unless explicit human grant exists

raw DB or secret-bearing repair
`-- operator only
```

`active_runtime` and lease conflicts are lifecycle/precondition denials, not
capability denials.

## Multi-Repo Direction

Future multi-repo work should use one WorkRequest with explicit repo scopes.

```text
WorkRequest WR-1
|-- repo_scope service-a/main
|-- repo_scope service-b/main
|-- slice S-1 -> service-a/main -> WP-1
`-- slice S-2 -> service-b/main -> WP-2
```

The architect claim remains `work_request:WR-1`. The worker claim remains one
`work_package` scope. Repo C remains denied unless added explicitly.

For the first implementation, `sympp_work_request_repo_scopes` is the durable
repo-scope primitive. `sympp_work_requests.repo` and
`sympp_work_requests.base_branch` remain the primary compatibility scope and are
backfilled into repo-scope rows for historical records. Authorization targets
may carry explicit WorkRequest repo scopes so repo-scoped read/discovery allows
service A and service B while denying service C. Repo scope alone still does
not authorize WorkRequest mutation, and workers remain limited to one
`work_package` scope.

This slice does not force full multi-repo dashboard, dispatch, or worker-UX
behavior. WorkPackages and WorkPackages remain single-repo execution units
until a later slice adds explicit per-slice repo selection.

## Reviewable PR Slices

1. Policy skeleton and target contract, with no behavior change.
2. Tool discovery cleanup.
3. Explicit grant scopes and grant-to-actor resolution.
4. WorkRequest and work-package authorization through policy.
5. Delivery board, reconciliation, closeout, and safe repair through policy.
6. Comments, guidance, blockers, and planning authorization through policy.
7. Human/operator actor and audit for dangerous actions.
8. Multi-repo repo-scope groundwork.
9. Remove old capability/phase/repo helper checks after policy coverage is real.

P8 cleanup decision: no remaining legacy capability/phase/repo helper path is
deleted here. The compatibility helpers still protect existing MCP WorkRequest,
phase, and dispatch flows while policy coverage is being completed. P9 may
remove a helper only when the equivalent policy check, stable denial code, and
focused regression test exist for that exact caller.

Each slice should be PR-sized and independently testable. Do not hide behavior
changes inside the skeleton slice.

## Required Regression Tests

- Architect can read all redacted operational state.
- Architect can write claimed WR and descendant slices/packages only.
- Architect can read but not mutate sibling WorkRequests.
- Architect can add narrow external comments to non-claimed WRs.
- Worker can complete every package-scoped planning/progress/review surface for
  its exact WP.
- Worker cannot mutate siblings, dispatch, reconcile, close out, or merge.
- Operator can perform dangerous local repair and audit is written.
- Raw secrets, work keys, private handoff payloads, bearer/API tokens, and grant
  verifiers never appear in broad read responses, audit payloads, PR text, or
  review evidence.
- Denials use stable reason categories such as `scope_mismatch`,
  `target_not_found`, `target_ambiguous`, `runtime_lease_conflict`,
  `dangerous_action_requires_operator`, and `invalid_transition`.
