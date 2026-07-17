# Symphony++ System Specification

## Core concepts

### WorkRequest

A WorkRequest is the top-level product intent and default cockpit row. It
captures the human's intended project or repo, base branch, work type,
description, constraints, desired dispatch shape, clarification history,
decisions, optional product plan tree, and WorkPackages.

WorkRequests are persisted in the Symphony++ runtime ledger. The local operator
dashboard can list, create, inspect, clarify, and prepare architect handoff for
WorkRequests, while scoped board views can create and manage WorkRequests only
inside their frozen repo/base-branch scope. Architect MCP sessions with explicit
WorkRequest capabilities can read, clarify, record decisions, author planned
slices, and dispatch approved WorkPackages through the normal ledger-backed
local assignment flow.

Architect MCP sessions can mutate the optional product tree with
`upsert_plan_node`,
`move_plan_node`,
`set_plan_node_completion`, and
`update_work_package` while the WorkRequest is in an
authoring status. Copied-ledger preview and migration flows may still seed plan
nodes through helpers, but helper seeding is not the normal architect authoring
path. Automatic question generation, automatic slicing/planning, live Linear
state creation, richer planner/intake plugin surfaces, and automatic Codex
spawning remain future work.

### ProductPlanNode

A product-facing grouping inside one WorkRequest. Nodes are optional and may be
nested as deeply as the architect needs. The schema does not require a fixed
hierarchy such as `layer -> capability`; `node_kind` is only a label.

Important fields:

```text
id
work_request_id
parent_id
title
description
node_kind
completion_mark
metadata
position
created_by
created_at
updated_at
```

### WorkPackage

The architect-to-worker execution unit. A WorkPackage belongs to one
WorkRequest and may link to one product plan node or sit directly under the
WorkRequest. Approved slices can dispatch into WorkPackages.

### WorkPackage

The scoped execution/audit unit for agent work. A WorkPackage represents a
dispatched WorkRequest slice, phase child package, or architect handoff anchor.
It is not the product-facing logical unit in the V3 cockpit.

Important fields:

```text
id
kind
title
repo
base_branch
branch_pattern
product_description
engineering_scope
acceptance_criteria
status
parent_id
owner_id
created_at
updated_at
```

### SoloSession

A local/private planning ledger for one caller, stable local session key, and
canonical workspace path. A SoloSession records task plan, finding, progress,
blocker, decision, and validation-note entries for normal single-agent Codex
work without creating WorkRequests, WorkPackages, grants, Linear state, worker
dispatch, or architect handoff.

Important fields:

```text
id
repo
base_branch
workspace_path
caller_id
session_key
title
status
last_activity_at
archived_at
created_at
updated_at
```

SoloSession statuses are `active`, `paused`, `completed`, and `archived`.
Active and paused sessions may later be archived as stale after about 30 days
through an explicit helper; this specification does not require a scheduler.
Current surfaces include `mix sympp.solo`, the plugin-installed
`symphony-plus-plus:symphony-solo-session` skill and `sympp-solo.ps1` wrapper,
and a local operator cockpit list/detail view. See
`14_SOLO_SESSION_CONTRACT.md` for the product boundary, data model direction,
current surfaces, remaining future MCP affordances, and runtime constraints.

### AccessGrant

A scoped authority object. Every agent action against Symphony++ must be backed by an AccessGrant.

Important fields:

```text
id
work_package_id or container_scope
display_key
secret_hash
role
capabilities
constraints
expires_at
claimed_at
bound_agent_run_id
revoked_at
created_at
```

### Access Grant Verifier

Internal access-grant verifier material is storage-only. Agents claim by
WorkRequest or WorkPackage id through the local claim tools and never receive a
raw verifier as bootstrap input.

### AgentRun

The runtime identity for a worker, architect, reviewer, or orchestrator session.

### Virtual planning files

Rendered Markdown resources backed by canonical state:

```text
sympp://work-packages/{id}/context.md
sympp://work-packages/{id}/task_plan.md
sympp://work-packages/{id}/findings.md
sympp://work-packages/{id}/progress.md
sympp://work-packages/{id}/acceptance.md
```

## State machines

### Single-slice WorkRequest package

```text
created
ready_for_worker
claimed
planning
implementing
reviewing
ci_waiting
ready_for_merge
merged
closed
blocked
abandoned
```

### Phase-child package

```text
created
ready_for_worker
claimed
planning
implementing
reviewing
ci_waiting
ready_for_architect_merge
merging_into_phase
merged_into_phase
closed
blocked
abandoned
```

`mark_ready` may move a package directly from `reviewing` to its terminal ready
status when that package policy does not require CI. Generic lifecycle updates
must still use `mark_ready` for ready statuses; `ci_waiting` remains required
when the package policy includes the `ci_waiting` required gate.

## Permission rule

A grant may only mint child grants narrower than itself.

Examples:

- A worker grant cannot mint grants.
- A phase architect grant can mint worker grants inside the same phase.
- A phase architect grant cannot mint grants against `main` unless explicitly allowed.
- A worker grant cannot read sibling packages.

## Read model

Workers receive:

- Their own work package.
- Their own virtual planning files.
- Explicit dependency/context slices.
- Their own PR/review state.

Workers do not receive:

- Sibling packages by default.
- Phase-wide private architect notes.
- Global grant lists.
- Raw secrets.

## Write model

Workers may:

- Update their own plan.
- Append their own findings/progress.
- Attach their own branch/PR/artifacts.
- Request context or scope expansion.
- Mark ready subject to gates.

Workers may not:

- Mark merged.
- Advance phase state.
- Mint grants.
- Reassign work.
- Expand scope silently.

## Readiness gates

A package cannot be marked ready if:

- It has active blockers.
- Required plan nodes are incomplete.
- Required review-suite artifacts are missing.
- Required PR is missing.
- CI is required by package policy and the package is not in `ci_waiting`.
- Changed files violate allowed scope.
- Acceptance evidence is missing.

## Source of truth split

```text
Symphony++ ledger
  agent state, work packages, virtual planning files, permissions, readiness

GitHub
  code, branches, PRs, commits, CI, review status

Linear
  optional mirror for human/product/project visibility

Codex/Symphony
  execution of isolated agent runs
```

## WorkRequest Product-Tree Boundary

A clarified WorkRequest may have no extra product structure, or it may become
an optional nested product plan tree plus one or more WorkPackages. Approved
slices can then be dispatched into WorkPackages through the local operator
dashboard, the work-package dispatch CLI, or the architect MCP dispatch tool
when the session has explicit dispatch scope. Existing WorkPackage status,
grants, virtual planning resources, readiness gates, review evidence, and
human merge rules remain authoritative after packages are created.

If a worker hits ambiguity after dispatch, it asks the architect first. The
architect may consult ask-pro for hard architecture or product calls. If the
architect still cannot make a defensible decision from durable request context,
the package records `human_info_needed` instead of inventing product behavior.
