# Architect operations

Read only the section needed for the current operation. Normal dispatch and
delivery invariants remain in `../SKILL.md`.

## Bootstrap recovery

A local architect claim can recover stale handoff scope when the ledger proves
one matching WorkRequest, repo, base branch, anchor, and grant. For
`phase_scope_not_available`, follow returned `missing_evidence` and `action`.
For `work_request_terminal`, ask the local operator to restore the WorkRequest
or start a new one. Do not invent state or bypass a binding denial.

## Planning operations

After claiming a WorkRequest, current-WR lifecycle tools may omit
`work_request_id`: `slice_work_request`,
`update_work_package`,
`upsert_group`,
`delete_group`,
`upsert_dependency`,
`delete_dependency`, and
`skip_work_package`, plus delivery board/reconcile, work-package
delivery closeout, runtime cleanup, worker-key revocation, and dispatch. Keep
intentional sibling reads, status/question tools, durable decisions, and package
tools explicit.

`slice_work_request` atomically creates one or more planned canonical
WorkPackages. The selected WorkRequest supplies the default primary delivery
repo and target base branch. Pass the target base branch with a secondary
  delivery repo. Package kind defaults to `standard_pr`; title, goal, owned
  globs, and acceptance criteria remain explicit. Validation steps and stop
  conditions are optional context.
Assign `group_id` only when the WorkPackage belongs in a real Group; root-level
WorkPackages need no synthetic wrapper Group.

Use `update_work_package` with `expected_contract_revision` to edit a planned
contract or move it between the WorkRequest root and an existing Group.

Use `upsert_group` for create, rename, reparent, and reorder. `delete_group`
ungroups its direct WorkPackages and child Groups into the deleted Group's
parent and removes dependency intents that named it. Groups never need manual
completion or blocker closeout.

Skip stale or superseded planned WorkPackages. The atomic planning call advances
the WorkRequest to its planned state; there is no separate approval or finish step.

## Claim repair

If a replacement worker is blocked by an old claim, call
`force_release_work_package_claim` with `work_package_id` and `reason`, then
retry `claim_local_assignment`. Any authenticated architect can release a
worker claim across WorkRequests, including active or paused claims. The old
worker loses session authority; package status and delivery evidence stay intact.

## Terminal evidence

Record other terminal outcomes with `record_work_package_delivery`:

- `outcome: "pr_merged"`: `evidence` is
  `{"pr_merged":{"pr_url":"...","pr_merged_at":"...","merge_commit_sha":"..."}}`.
  `pr_number` and `pr_repository` are optional inside `pr_merged`.
- `outcome: "completed_no_pr"`: `evidence` is
  `{"completed_no_pr":{"no_pr_evidence":"..."}}`.
- `outcome: "superseded"`: `evidence` is
  `{"superseded":{"successor_work_package_id":"...","superseded_reason":"..."}}`.
- `outcome: "abandoned"`: `evidence` is
  `{"abandoned":{"abandoned_rationale":"..."}}`.
