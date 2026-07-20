# MCP And Skill Contract

The authoritative machine-readable MCP surface is
`implementation_docs_symphplusplus/mcp/mcp_tools_contract.json`; the readable
summary is `implementation_docs_symphplusplus/mcp/MCP_TOOLS_CONTRACT.md`.

## Normal Claims

Worker:

```json
{"tool":"claim_local_assignment","arguments":{"work_package_id":"<WP id>"}}
```

Architect:

```json
{"tool":"claim_local_architect_assignment","arguments":{"work_request_id":"<WR id>"}}
```

`claimed_by` may be supplied for stable audit identity; id-only architect claims
default to the standard architect handoff owner. `caller_id` is optional
correlation metadata, not claim ownership. Other claim fields are optional
validation context and should be omitted unless already known.

Local claim leases are heartbeat-based. Replaying the claim or making
successful calls from the bound MCP session refreshes the lease. Stale
no-heartbeat leases may be reclaimed quickly; fresh worker conflicts and paused
leases remain protected.

`release_current_assignment` is idempotent. If the current session, binding, or
matching lease is already absent, stale, or mismatched, the tool returns a
compact successful cleanup result and leaves audit detail in
`structuredContent`.

## Skill Responsibilities

- `symphony-plus-plus-mcp:symphony-work-package` claims by WorkPackage id, reads
  the assigned context, records plan/progress/findings/blockers/review evidence,
  and marks ready when gates pass.
- `symphony-plus-plus-mcp:symphony-architect` claims by WorkRequest id, slices
  product work, dispatches workers, answers/records decisions, and closes out
  delivery.
- `symphony-plus-plus-mcp:symphony-solo-session` is only for ordinary
  single-agent planning memory without WorkRequest or WorkPackage authority.

## Dispatch

`dispatch_work_package(work_request_id, work_package_id,
claimed_by?)` returns a `worker_bootstrap` payload for
`claim_local_assignment`. Workers should not need repository root, helper
script, private file, or raw secret metadata.

## Compact Worker Calls

Bound workers should omit values the current WorkPackage already supplies.
`add_comment(body)` and `list_comments()` default to the current WorkPackage.
`attach_branch(head_sha)` infers a literal WorkPackage branch pattern; pass
`branch` only for templated or absent patterns. If `review.md` declares a
review, complete its opaque provider requirement for the current exact head,
then call `complete_review(reference?, note?)` before `mark_ready()`.

`sync_pr()` only refreshes the already attached PR when state changed after
attachment or the attach call did not include current-state metadata required by
policy. Pass top-level current-state fields when they changed; use explicit PR
identity or `recovery` only for repair.
Worker `set_status` and `mark_ready` accept `blocker_closeout` when active
blockers must be resolved or kept active as part of a finish transition.

## Compact Architect Planning Calls

After `claim_local_architect_assignment`, planning writes that only target the
claimed current WorkRequest may omit `work_request_id`:
`slice_work_request`, `update_work_package`, `upsert_group`, `delete_group`,
`upsert_dependency`, `delete_dependency`,
and `skip_work_package`. Reads, lists, delivery closeout, dispatch,
status/question tools, durable decision tools, and package tools still require
their explicit target ids.

For ordinary PR-backed work, each package in `slice_work_request` defaults
`kind` to `standard_pr`, delivery repo and target base branch to
the selected WorkRequest's primary repo scope. Review is omitted unless the
architect supplies one opaque `review` requirement. Pass the target base branch
when selecting a secondary delivery repo. Branch pattern and forbidden globs may also be omitted. Title, goal,
owned globs, acceptance criteria, validation, and stop conditions stay
required. Use `mcp` only for MCP server, protocol, tool, or plugin work.

Groups organize WorkPackages without carrying lifecycle or completion state.
Use `upsert_group` and `delete_group` for Group structure, and
`upsert_dependency` and `delete_dependency` for execution intent between
Groups or WorkPackages. `read_plan` exposes `groups_only`,
`groups_with_work_package_refs`, and `groups_with_work_packages` views backed by
the same derived execution graph used at dispatch.

## Delivery Closeout

Architect delivery closeout uses:

```text
read_delivery_board(work_request_id)
cleanup_work_request_work_package_runtime(work_request_id, work_package_id, outcome, reason, ...)
record_work_package_delivery(work_request_id, work_package_id, outcome, idempotency_key, evidence)
reconcile_work_request
```

Closeout outcomes include `pr_merged`, `completed_no_pr`, `superseded`, and
`abandoned`. `record_work_package_delivery` groups proof under one typed
`evidence` object matching `outcome`: `evidence.pr_merged`,
`evidence.completed_no_pr`, `evidence.superseded`, or `evidence.abandoned`.
PR/GitHub evidence may also drive deterministic closeout repairs through
`reconcile_work_request`. Use `cleanup_work_request_work_package_runtime`
before closeout when stale linked worker grants, local claim leases, or
recoverable worker MCP session bindings are the remaining runtime blocker;
cleanup keeps the flat superseded or abandoned fields that authorize cleanup
before the typed closeout call. See
`../runbooks/WORK_REQUEST_DELIVERY_CLOSEOUT.md` for the operator runbook.

## Discovery

`tools/list` may show schemas before authorization. A call is authorized only
after the relevant local claim succeeds and the live grant has the required
role, capability, scope, and lifecycle state.
