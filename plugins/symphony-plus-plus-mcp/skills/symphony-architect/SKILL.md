---
name: symphony-architect
description: Use when assigned a Symphony++ WorkRequest, product-tree planning lane, architect WorkPackage, phase, or feature orchestration lane.
---

# Symphony++ Architect

Own product clarification, optional Group organization, WorkPackage planning, worker
dispatch, guidance routing, and delivery closeout. Do not implement worker
packages yourself. Workers own implementation, required validation/review,
CI/static gates, and exact-head PR readiness; send findings back to the owner.
Keep dispatch prompts task-specific; the worker skills supply the procedure.
Stop for material scope/product ambiguity, missing authority/evidence, branch
ambiguity, or global Codex/plugin configuration changes. Never expose raw work
keys, bearer/API/GitHub/Linear/MCP tokens, grant verifiers, private handoff
payloads, claim secrets, or secret-bearing commands.

## Start

1. Read the assigned WorkRequest/package/phase through S++ MCP before planning.
   Tool visibility is not authorization; if a tool returns `claim_required` or
   another binding denial, use the assignment's configured bootstrap. Normal
   local WorkRequest architect bootstrap is `claim_local_architect_assignment`
   with the WorkRequest id and optional non-secret `claimed_by`. Use
   `caller_id` only for the current runtime/thread identity. The claim can
   recover stale handoff scope only with matching ledger evidence. For
   `phase_scope_not_available` or `work_request_terminal`, follow
   [bootstrap recovery](references/operations.md#bootstrap-recovery).
2. For WorkRequest lanes, read `read_work_request(work_request_id)`,
   `read_plan(work_request_id, view?)`, and
   `list_guidance_requests(work_request_id?)` before planning WorkPackages or rearranging
   Groups. The WorkRequest guidance filter requires the usual
   `read:work_request` grant.
3. If MCP/session/scope state is unavailable, record/report the blocker. Do not
   invent state.

## Context Format

TOON is presentation only. Send schema-native JSON tool arguments;
`structuredContent` is the canonical machine-readable result.

## Clarify

- Ask focused product/architecture questions before planning WorkPackages when intent,
  compatibility, branch strategy, acceptance, validation, or ownership is
  unclear.
- Use `ask_question` with `decision_prompt` for material choices;
  use plain questions for simple facts.
- Record durable decisions with `record_decision`. Valid
  `source_type`: `human`, `architect`, `operator`, `ask_pro_advisory`.
- Escalate to `human_info_needed` when the human must decide. Do not choose
  product behavior just to keep work moving.
- Once open questions are answered or closed, continue straight to
  `read_work_request` and `slice_work_request`; no separate
  clarification-complete status tool is required. Open questions still block
  WorkPackage planning.

## Plan WorkPackages

Groups optionally organize larger WorkRequests; they have no lifecycle or
completion step. Use `read_plan`, not direct ledger queries: `groups_only`
for outlines, `groups_with_work_package_refs` for ids, or
`groups_with_work_packages` for bodies. It includes effective edges,
cycle/topology evidence, and unmet dependencies.

Design one cohesive PR-sized WorkPackage per worker unless the operator
approves another shape. Prefer smaller independently reviewable outcomes.

Each package needs a title/goal, explicit owned globs, provable acceptance,
and relevant dependencies/decisions. `kind` defaults to `standard_pr`; use
`mcp` for MCP servers/protocols/tools/plugins. Repo/base default to the WR's
primary scope; a secondary repo needs an explicit base. Branch/forbidden globs
may use safe empty defaults. Add validation or a blocked-validation owner,
provider-neutral review, stop conditions, and guidance routing when useful.
Honor assigned size budgets; numerical budgets are optional. Escalate material
scope growth or reviewability risk.

Use `upsert_dependency`/`delete_dependency` for ordering. Group endpoints expand
to the backend's effective WorkPackage graph; do not maintain another graph.

Use `slice_work_request` to create planned packages atomically; there is no
separate approval/finish step. Use `update_work_package` with
`expected_contract_revision` for planned contract changes. Root packages need
no synthetic Group. Skip stale/superseded planned packages. For Group edits,
secondary repo defaults, or omitted current-WR ids, read
[planning operations](references/operations.md#planning-operations).

## Dispatch

For an old claim blocking a replacement worker, an authenticated architect
may use `force_release_work_package_claim`; read
[claim repair](references/operations.md#claim-repair) before releasing authority.

Call `dispatch_work_package` for planned packages. It enforces the same graph
as `read_plan`, rejecting cycles/unmet dependencies, and atomically activates
the canonical row with worker grant/resources and ledger bootstrap:
`type=ledger_claim`, `mode=local_assignment`, `claim.tool=claim_local_assignment`.

Prepare/provide worktree scope before launch. Use
`prepare_work_package_worktree(work_package_id)` and its returned
`worker_launch.workspace_path` as cwd. Override `branch` only when needed;
absent/templated patterns derive a package-unique branch. Supply non-secret
runtime identity/validation context when required. On `target_repo_root_required`
from prepare/cleanup, retry with the product checkout owning the recorded path.

Worker prompts contain task-specific data only:

- `symphony-plus-plus-mcp:symphony-worker` plus
  `symphony-plus-plus-mcp:symphony-work-package`.
- WorkPackage id, goal, prepared workspace/branch/base, relevant evidence,
  decisions/dependencies, and contract deviations or assigned budgets.
- Ledger claim payload or explicit recovery/legacy bootstrap label. Normal
  claims use the WorkPackage id only; add runtime validation context only when
  needed, never raw secrets.
- Delivery owner and required PR/no-PR evidence. Scope, acceptance, validation,
  review, and stop conditions come from the current scoped package contract;
  include any task-specific context missing there.

Use [the template](../symphony-work-package/references/worker_prompt.md);
do not repeat the worker checklist. Workers return material product, architecture, dependency,
package-boundary, or reviewer-driven scope ambiguity to the architect. Let the
worker finish review convergence and delivery.

## Guidance

- Answer package guidance when recorded intent already decides it.
- Escalate with `escalate_guidance_request` when human product input is needed.
- For human choices, include a compact `decision_prompt`: `tl_dr`, `details`,
  concrete options with labels, exact answer text, descriptions, and useful
  pros/cons.

## Delivery Closeout

After dispatch, use `read_delivery_board` for lifecycle evidence.

For merged PR evidence, use `reconcile_work_request` first, then
`reconcile_work_request(apply: true)` when the proposed repair matches the
delivery board. That path uses attached/synced PR evidence and avoids repeating
PR URL or package facts. If you choose explicit PR closeout instead of
`apply: true`, replay the dry-run result's `action` payload through
`record_work_package_delivery`.

For explicit `pr_merged`, `completed_no_pr`, `superseded`, or `abandoned`
closeout payloads, read
[terminal evidence](references/operations.md#terminal-evidence) and use
`record_work_package_delivery`.

Do not infer delivery from prose decisions or chat. A successful terminal
closeout revokes live worker grants and releases
current claim leases, including paused leases; do not require a separate worker
or runtime-cleanup step first. Use `cleanup_work_request_work_package_runtime`
only to recycle runtime without terminal closeout or to clear recoverable worker
MCP session bindings explicitly.
If package evidence is missing or ambiguous, do not record WorkRequest delivery
closeout; repair evidence first.
