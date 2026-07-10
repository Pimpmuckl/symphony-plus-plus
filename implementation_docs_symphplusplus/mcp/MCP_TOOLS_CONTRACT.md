# MCP Tools Contract

This document mirrors `mcp_tools_contract.json` in readable form. The JSON file
is the compact machine-readable index of tool names plus required and optional
arguments. The runtime catalog owns the live tool surfaces; the JSON contract
publishes those names and the canonical `mcp_contract_fingerprint` consumed by
smoke checks and runtime artifact scripts. Removed legacy bootstrap paths are
intentionally absent.

Human-facing long text fields are Markdown unless a field is explicitly a
compact label, status, identifier, branch, PR URL, or other machine-readable
value. Dashboard renderers must not turn raw Markdown HTML into executable or
trusted HTML.

## Bootstrap

Agents claim existing ledger records by id:

| Tool | Required | Optional | Purpose |
|---|---|---|---|
| `claim_local_assignment` | `work_package_id` | `claimed_by` | Bind the current session to one WorkPackage. Runtime metadata is read from the ledger after claim; the WorkPackage id is the normal claim coordinate. |
| `claim_local_architect_assignment` | `work_request_id` | `claimed_by`, `architect_anchor_work_package_id`, `repo`, `base_branch`, `phase_id`, `caller_id` | Bind the current session to the architect grant for one WorkRequest. |
| `create_work_request` | `repo`, `base_branch`, `title`, `request_kind`, plus `description` or `human_description` | status/workflow/creator fields | In a trusted local HTTP session, create a WorkRequest and return a ledger claim bootstrap for the architect. |

Dispatch and mint responses return non-secret `worker_bootstrap` metadata:

```json
{"type":"ledger_claim","mode":"local_assignment","tool":"claim_local_assignment","args":{"work_package_id":"...","claimed_by":"..."}}
```

`claimed_by` is useful for stable audit ownership but is no longer a secret
carrier. Raw grant secrets, private files, and secret stores are not part of the
agent-facing surface. `caller_id`, when present, is correlation metadata only;
the active local claim owner is the ledger id plus `claimed_by`. Id-only
architect claims default to the standard architect handoff owner.

Local claim leases use heartbeat freshness. Successful bound MCP calls refresh
the current lease, and replayed claims may reclaim stale no-heartbeat residue.
Fresh worker leases continue to block other workers, while paused leases remain
operator-controlled.

## Worker Tools

Bound worker sessions expose health, assignment release, and:

```text
get_current_assignment
read_context
read_task_plan
update_task_plan
append_finding
append_progress
set_status
report_blocker
resolve_blocker
add_comment
list_comments
resolve_comment
create_guidance_request
read_guidance_request
request_scope_expansion
attach_branch
attach_pr
sync_pr
submit_review_package
attach_review_suite_result
mark_ready
```

Workers are scoped to exactly one WorkPackage. Worker tools never mint grants,
approve scope, merge PRs, advance phases, or close WorkRequest delivery.

Published unbound worker schemas keep explicit package selectors so local MCP
wrappers can target a package before a worker session is bound. Compact worker
calls should omit values the bound WorkPackage already carries:

- `add_comment(body)` comments on the current WorkPackage. Pass
  `target_kind` and `target_id` only for a WorkRequest or planned-slice comment.
- `list_comments()` lists comments on the current WorkPackage. Pass
  `target_kind` and `target_id` only for another authorized target.
- `attach_branch(head_sha)` uses the WorkPackage `branch_pattern` when it is a
  literal branch. Pass `branch` when the pattern is templated or absent.
- `attach_pr(url, head_sha)` may include current check, review, or merge
  metadata. That attachment satisfies current PR state when the metadata proves
  the attached PR and current head.
- `sync_pr()` refreshes the currently attached PR. Pass top-level current-state
  fields such as `head_sha`, `check_summary`, `review_state`, or `merge_state`
  when those facts changed. Pass explicit PR identity or `recovery` only for
  manual evidence repair.

For Review Suite evidence, prefer `mark_ready(review_suite_round_id)` when the
package is otherwise ready. The server attaches the passing local Review Suite
round before readiness checks. Use `attach_review_suite_result(round_id)` only
when recording review evidence before the finish call. Verbose fields remain a
fallback when the round cannot be resolved; `suite` must still identify Review
Suite.

Retained explicit-id operations and their reasons:

- `record_planned_slice_delivery` and
  `cleanup_work_request_planned_slice_runtime` still require a planned-slice id
  because they mutate product delivery truth and linked runtime authority.
  `work_request_id` may be inferred from the claimed current WorkRequest.
- `cleanup_work_request_planned_slice_runtime` and
  `revoke_planned_slice_worker_key` fail closed when duplicate planned-slice
  links share the same WorkPackage runtime; repair the linkage before mutating
  package-wide runtime authority.
- Superseded closeout keeps `successor_planned_slice_id`, and optional
  `successor_work_package_id`, because the caller is naming a cross-slice
  successor relation.
- `revoke_planned_slice_worker_key` keeps `grant_id` because revocation is a
  concurrency-sensitive runtime operation on one live worker grant.
- Architect package tools such as `read_child_status`,
  `approve_scope_expansion`, `prepare_work_package_worktree`, and
  `cleanup_work_package_worktree` still require WorkPackage ids because
  architect sessions may see more than one package.
- `sync_pr()` is only a refresh path for the already attached PR when state
  changed after attachment or the attach call did not include current-state
  metadata required by policy.

Completion mutations that can encounter active package blockers expose
`blocker_closeout`. Use `decision=resolved` with a resolution when active
blockers are no longer true, or `decision=still_active` when they must remain
active after the attempted transition. This applies to worker `set_status` and
`mark_ready`.

## Health, Solo, And Local Operator Tools

Unbound sessions expose `sympp.health`, `release_current_assignment`, Solo
Session tools, scoped worker/architect schemas, and the local claim tools.
Trusted local HTTP sessions with explicit state-key continuity and a
file-backed ledger also expose safe local bootstrap/operator tools:

```text
create_work_request
add_work_request_comment
list_comments
record_work_request_operator_decision
```

Trusted local sessions keep `create_work_request` and these safe local
operator tools visible even when the wrapper is bound to a worker or architect
assignment, or when that binding needs refresh. They do not widen the active
assignment's package or WorkRequest authority.

Solo Session tools are for ordinary local planning memory. They do not claim a
WorkRequest or WorkPackage and do not grant dispatch or lifecycle authority.
The unbound Solo MCP surface is intentionally intent-shaped:

```text
solo_attach
solo_show
solo_list
solo_record_task_plan
solo_append_progress
solo_append_finding
solo_record_decision
solo_report_blocker
solo_resolve_blocker
solo_record_validation
solo_pause
solo_resume
solo_complete
solo_archive
```

## Architect Tools

Bound architect sessions expose WorkRequest, product-tree, planned-slice,
phase-child, guidance, closeout, and delivery tools listed in the JSON contract.
Architect claims are WorkRequest-centric; WorkPackage anchor, repo, base branch,
and phase fields are derived from the ledger when omitted.

Some names are shared across worker and architect sessions. For example,
`resolve_blocker` is worker-scoped for workers and descendant-package-scoped
for architects; the live handler applies the role-specific authorization and
target-scope checks.

Clarification has no extra completion ceremony. After open clarification
questions are answered or closed, architects may read the WorkRequest and call
`add_work_request_planned_slice`; the tool safely advances
`ready_for_clarification`, `clarifying`, or `human_info_needed` WorkRequests to
`ready_for_slicing` before inserting the slice. Open clarification questions
still block the call with `open_questions`.

Current-WorkRequest lifecycle tools may omit `work_request_id` after
`claim_local_architect_assignment` has bound the session to exactly one
WorkRequest. This compact path applies to `add_work_request_planned_slice`,
`upsert_work_request_product_plan_node_content`,
`move_work_request_product_plan_node`,
`set_work_request_product_plan_node_completion`,
`move_work_request_planned_slice_to_product_node`,
`approve_work_request_planned_slice`, `skip_work_request_planned_slice`, and
`mark_work_request_sliced`, plus delivery board/reconcile, planned-slice delivery
closeout, runtime cleanup, worker-key revocation, and dispatch. Supplying
`work_request_id` is still allowed and is checked against the same architect
grant scope. Reads that can intentionally target sibling WorkRequests,
status/question tools, durable decision tools, and package tools keep explicit
target ids.

`add_work_request_planned_slice` defaults ordinary PR-backed work to
`standard_pr`; reserve `mcp` for MCP servers, protocols, tools, or plugins.
The selected WorkRequest supplies the default delivery repo and target base
branch for its primary repo; pass the target base branch when selecting a
secondary delivery repo. Branch pattern, forbidden globs, and review lanes may
be omitted, while title, goal, owned globs, acceptance criteria, validation,
and stop conditions remain required. Without a single current WorkRequest,
callers must supply `work_request_id` explicitly.

Product-plan node authoring is split by intent: use
`upsert_work_request_product_plan_node_content` for title, description, or kind,
`move_work_request_product_plan_node` for parent or position, and
`set_work_request_product_plan_node_completion` for completion marks and
required blocker closeout.

`dispatch_work_request_planned_slice` requires only `planned_slice_id` once a
single current WorkRequest is claimed; `claimed_by` is optional. It creates the
linked WorkPackage, mints a worker grant, and returns the same simple
`claim_local_assignment` bootstrap shape with primary execution and product
audit coordinates.

`cleanup_work_request_planned_slice_runtime` is the WR architect cleanup path
for linked planned-slice runtime that has been superseded or abandoned by
delivery truth. It requires `outcome` plus the same superseded or abandoned
evidence that will be used for closeout. It revokes linked worker grants,
releases non-paused local claim leases, clears recoverable worker MCP session
bindings for the linked WorkPackage, and records audit progress. Paused leases
and fresh active AgentRun evidence fail closed; after cleanup, record the
delivery outcome with
`record_planned_slice_delivery`.

`record_planned_slice_delivery` keeps `work_request_id`, `planned_slice_id`,
`outcome`, and `idempotency_key` explicit, and groups closeout proof under one
typed `evidence` object. Provide exactly one key matching `outcome`:
`evidence.pr_merged`, `evidence.completed_no_pr`, `evidence.superseded`, or
`evidence.abandoned`. `pr_merged` evidence still requires PR URL and merged-at
timestamp, and linked packages still require `merge_commit_sha`; active blocker
closeout remains an explicit `blocker_closeout` argument.

`mint_child_worker_key` accepts an optional `template` object. The template may
set non-secret `claimed_by`, `capabilities`, and `expires_at`; it cannot provide
secret handoff options.

## Discovery And Authorization

`tools/list` is schema discovery, not authorization. Healthy unbound sessions
show health, Solo tools, scoped schemas, and local claim tools. Trusted local
HTTP sessions with explicit state also show `create_work_request` and safe local
operator tools when a file-backed local ledger is available. Bound worker
sessions show worker tools plus trusted local bootstrap/operator tools when
available. Bound architect sessions show architect tools plus trusted local
bootstrap/operator tools when available.
Calls still enforce live session role, capabilities, grant scope, lifecycle
state, local daemon trust, and handler-specific checks.

Stale or revoked sessions recover by replaying the relevant local claim tool on
the same id or by starting a new session and claiming the same id.
`claim_local_architect_assignment` can recover stale handoff scope only when
the ledger proves exactly one matching WorkRequest, repo, base branch, anchor,
phase, and architect grant. Remaining `phase_scope_not_available` responses include
`missing_evidence` plus an operator repair action; archived or manually
completed WorkRequests return `work_request_terminal`.
`release_current_assignment` is safe to call repeatedly; absent, stale, or
mismatched bindings return a compact ok-style cleanup result. Normal visible
claim/release text omits claim lease ids, grant ids, caller ids, and raw
recovery maps; `structuredContent` keeps non-secret audit details.

## Resources

Bound sessions may read:

```text
sympp://assignment/current
sympp://work-packages/{id}/context.md
sympp://work-packages/{id}/task_plan.md
sympp://work-packages/{id}/findings.md
sympp://work-packages/{id}/progress.md
sympp://work-packages/{id}/acceptance.md
sympp://work-packages/{id}/review_suite.md
sympp://work-packages/{id}/handoff.md
```

Resources may include compact `text/vnd.toon` alongside Markdown or JSON for
agent-facing context. Tool inputs and structured results remain schema-native
JSON.

## Safety

Responses must redact bearer/API/GitHub/Linear/MCP tokens, grant verifiers,
secret hashes, and secret-like prose. Agent prompts, docs, launch payloads, and
tool responses must not ask for raw grant secrets or local private-file handoff
metadata.
