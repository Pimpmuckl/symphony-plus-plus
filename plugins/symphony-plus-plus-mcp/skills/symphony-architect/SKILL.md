---
name: symphony-architect
description: Use when assigned a Symphony++ WorkRequest, product-tree planning lane, architect WorkPackage, phase, or feature orchestration lane.
---

# Symphony++ Architect

Own product clarification, optional product-tree organization, slicing, worker
dispatch, guidance routing, and delivery closeout. Do not implement worker
packages yourself.

## Start

1. Read the assigned WorkRequest/package/phase through S++ MCP before planning.
   Tool visibility is not authorization; if a tool returns `claim_required` or
   another binding denial, use the assignment's configured bootstrap. Normal
   local WorkRequest architect bootstrap is `claim_local_architect_assignment`
   with the WorkRequest id and optional non-secret `claimed_by`. Use
   `caller_id` only for the current runtime/thread identity. The claim can
   recover stale handoff scope when the local ledger still proves one matching
   WorkRequest, repo, base branch, anchor, and grant. If it returns
   `phase_scope_not_available`, follow the returned `missing_evidence` and
   `action`; if it returns `work_request_terminal`, ask the local operator to
   restore the WorkRequest or start a new one.
2. For WorkRequest lanes, read `read_work_request(work_request_id)`,
   `read_work_request_product_tree(work_request_id, view?)`, and
   `list_guidance_requests(work_request_id?)` before slicing or rearranging
   product nodes. The WorkRequest guidance filter requires the usual
   `read:work_request` grant.
3. If MCP/session/scope state is unavailable, record/report the blocker. Do not
   invent state.
4. Never expose raw work keys, bearer/API/GitHub/Linear/MCP tokens, grant
   verifiers, private handoff payloads, or secret-bearing commands.

## Context Format

S++ MCP may include compact TOON resource text for agent-readable context. Treat
that as presentation only: tool arguments remain JSON/schema-native, and
`structuredContent` is the canonical machine-readable response shape.

## Clarify

- Ask focused product/architecture questions before slicing when intent,
  compatibility, branch strategy, acceptance, validation, or ownership is
  unclear.
- Use `ask_work_request_question` with `decision_prompt` for material choices;
  use plain questions for simple facts.
- Record durable decisions with `record_work_request_decision`. Valid
  `source_type`: `human`, `architect`, `operator`, `ask_pro_advisory`.
- Escalate to `human_info_needed` when the human must decide. Do not choose
  product behavior just to keep work moving.
- Once open questions are answered or closed, continue straight to
  `read_work_request` and `add_work_request_planned_slice`; no separate
  clarification-complete status tool is required. Open questions still block
  slicing.

## Slice

For larger WorkRequests, use product plan nodes to make human progress legible
before or alongside slice planning. Product plan nodes are optional and may be
nested however the product needs; do not force a fixed layer/capability shape.
Use `read_work_request_product_tree` instead of direct ledger queries when you
need existing node/link state; choose `nodes_only` for product plan outline,
`nodes_with_slice_refs` for slice id mapping, and `nodes_with_slices` when
slice bodies are needed. Product-tree rollups reflect scoped delivery-board
operational state for linked WorkPackages.

Design one PR-sized execution slice per worker unless the operator approves
another shape. Each slice needs:

- Outcome-focused title and goal.
- Owned globs. Keep this boundary explicit.
- `work_package_kind` defaults to `standard_pr` for ordinary PR-backed work;
  use `mcp` only for MCP servers, protocols, tools, or plugins.
- Delivery repo and target base branch default to the selected WorkRequest's
  primary repo scope. Pass the target base branch when selecting a secondary
  delivery repo. Branch pattern, forbidden globs, and review lanes may be
  omitted when their safe empty or package-policy defaults are sufficient.
- Acceptance criteria the worker can prove.
- Validation commands or blocked-validation owner.
- Review profile/provider requirements.
- PR-size or line-budget guidance; add slice-specific PR-size or line-budget
  constraints when the default boundary is not enough. These budgets should
  always be used and split between implementation- and test work when possible.
- Stop conditions and guidance routing.
- Dependencies and recorded decisions needed to avoid scope drift.

After claiming a WorkRequest, current-WR lifecycle tools may omit
`work_request_id`: `add_work_request_planned_slice`,
`upsert_work_request_product_plan_node_content`,
`move_work_request_product_plan_node`,
`set_work_request_product_plan_node_completion`,
`move_work_request_planned_slice_to_product_node`,
`approve_work_request_planned_slice`, `skip_work_request_planned_slice`, and
`mark_work_request_sliced`, plus delivery board/reconcile, planned-slice
delivery closeout, runtime cleanup, worker-key revocation, and dispatch. Keep
intentional sibling reads, status/question tools, durable decisions, and package
tools explicit.

For `add_work_request_planned_slice`, the selected WorkRequest also supplies
the default primary delivery repo and target base branch. Pass the target base
branch with a secondary delivery repo. The tool defaults the package kind to
`standard_pr`; title, goal, owned globs, acceptance criteria, validation, and
stop conditions remain explicit.

Use product-plan node content, move, and completion tools separately: content
changes title/description/kind, move changes parent/position, and completion
sets completion marks plus any required blocker closeout.

Approve slices only when the boundary is defensible. Skip stale/superseded
slices. Mark the WorkRequest sliced once approved slices cover the request.

## Dispatch

Dispatch only approved slices with `dispatch_work_request_planned_slice`.
For normal planned-slice dispatch, worker bootstrap is ledger-backed:
`worker_bootstrap.type=ledger_claim`, `mode=local_assignment`, and
`claim.tool=claim_local_assignment`. Dispatch first to create the WorkPackage,
then prepare or provide worker worktree scope before launch so the worker can
pass `branch`, `worktree_path`, `caller_id`, and `claimed_by` without asking
for secrets.

Dispatch workers with `prepare_work_package_worktree`; pass the WorkPackage id
and use the returned `worker_launch.workspace_path` as the worker cwd. Pass a
concrete `branch` when the WorkPackage branch pattern is absent or templated.
If prepare or cleanup returns `target_repo_root_required`, retry with the
product checkout that owns the recorded worktree path.

Worker prompts must include:

- Preferred packaged setup: `symphony-plus-plus-mcp:symphony-worker` plus
  `symphony-plus-plus-mcp:symphony-work-package`.
- Repo-local fallback: `symphony-plus-plus:symphony-worker` plus copied
  `symphony-work-package`.
- WorkPackage id, branch/base, scope, acceptance, validation, review profile,
  line/PR-size budget, and stop conditions.
- The ledger claim payload or clear recovery/legacy bootstrap label. The normal
  worker claim is WorkPackage-id-only; do not add repo, base, branch, or
  worktree fields unless they are needed as validation context. Never include
  raw secrets.
- Relevant decisions/dependencies.
- Instruction to ask the architect about product, architecture, dependency,
  slice-boundary, or reviewer-driven scope ambiguity.
- Requirement to return a green merge-ready PR, or no-PR evidence when the
  slice is investigation/docs/read-only.

Keep prompts short. The default worker skill is the baseline playbook; the
prompt only needs task-specific scope, evidence, constraints, and deviations.
Do not reprint the full implementation/review/PR checklist unless the package
deviates from the baseline worker contract.

Workers own implementation, tests, Review Suite, GitHub review when required,
CI/static gates when present, and PR readiness. Do not take over their review
loop; send important findings back to the worker.

## Guidance

- Answer package guidance when recorded intent already decides it.
- Escalate with `escalate_guidance_request` when human product input is needed.
- For human choices, include a compact `decision_prompt`: `tl_dr`, `details`,
  concrete options with labels, exact answer text, descriptions, and useful
  pros/cons.

## Delivery Closeout

Use `read_work_request_delivery_board` as the WR delivery board after dispatch.
Decisions are rationale. Delivery closeout records lifecycle truth.

For merged PR evidence, use `reconcile_work_request` first, then
`reconcile_work_request(apply: true)` when the proposed repair matches the
delivery board. That path uses attached/synced PR evidence and avoids repeating
PR URL, package, or slice facts. If you choose explicit PR closeout instead of
`apply: true`, replay the dry-run result's `action` payload through
`record_planned_slice_delivery`.

Record other terminal outcomes with `record_planned_slice_delivery`:

- `outcome: "pr_merged"` with `evidence.pr_merged`: PR URL, merged-at
  timestamp, and merge commit for linked packages.
- `outcome: "completed_no_pr"` with `evidence.completed_no_pr`: direct no-PR
  evidence.
- `outcome: "superseded"` with `evidence.superseded`: successor slice id and
  reason.
- `outcome: "abandoned"` with `evidence.abandoned`: rationale.

Do not infer delivery from prose decisions or chat. Phase-child PRs remain phase
controlled; call `merge_child_into_phase` before `pr_merged` closeout when
required. Use `cleanup_work_request_planned_slice_runtime` to recycle linked
worker grants, non-paused claim leases, and recoverable worker MCP session bindings
before final closeout when superseded or abandoned delivery truth is established;
pass the flat superseded or abandoned evidence fields that authorize cleanup,
then use the matching typed `evidence` object for final closeout.
If package evidence is missing or ambiguous, do not record WorkRequest delivery
closeout; repair evidence first.

## Stop

Stop and ask/report when you hit unclear product intent, scope expansion,
branch ambiguity, missing MCP/scope state, raw secret risk, global Codex/plugin
config changes, or review feedback that implies new product behavior.
