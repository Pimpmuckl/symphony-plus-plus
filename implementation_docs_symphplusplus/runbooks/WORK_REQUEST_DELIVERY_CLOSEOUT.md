# WorkRequest Delivery Closeout

Use this runbook after a WorkRequest planned slice has been dispatched and the
worker has produced current S++ evidence: implementation, review, CI/static
gates when present, and a mergeable green PR when a PR exists.

## Default Sequence

1. Read `read_delivery_board()` when the claim has exactly one
   current WorkRequest. Pass `work_request_id` when the session is unbound,
   multi-WorkRequest, or targeting another authorized WorkRequest.
2. If the board shows merged PR evidence without a delivery outcome, dry-run
   `reconcile_work_request()` in the same single-current-WorkRequest scope.
3. If the dry-run proposes the expected PR-merged repair, apply
   `reconcile_work_request(apply: true)` or record the same
   truth explicitly by replaying the proposed result's `action` payload through
   `record_planned_slice_delivery`.
4. For no-PR completion, supersession, or abandonment, call
   `record_planned_slice_delivery` directly with the required typed evidence.
5. Re-read the delivery board and verify `needs_closeout` no longer describes
   the slice.

Decision log entries explain rationale and scope. They do not close delivery.
Worker WorkPackage progress proves what the worker did. It does not decide the
WorkRequest delivery outcome.

## Outcome Examples

No-PR completion:

```json
{
  "work_request_id": "wr_kraken_docs",
  "planned_slice_id": "wrs_docs_hygiene",
  "outcome": "completed_no_pr",
  "idempotency_key": "kraken-docs-hygiene-no-pr",
  "evidence": {
    "completed_no_pr": {
      "no_pr_evidence": "Operator confirmed the docs-only update landed directly."
    }
  }
}
```

Supersession:

```json
{
  "work_request_id": "wr_kraken_docs",
  "planned_slice_id": "wrs_broad_docs",
  "outcome": "superseded",
  "idempotency_key": "kraken-broad-docs-recut",
  "evidence": {
    "superseded": {
      "successor_planned_slice_id": "wrs_narrow_docs",
      "successor_work_package_id": "wp_narrow_docs",
      "superseded_reason": "Recut with narrower owned files."
    }
  }
}
```

## Kraken-Style Stale Delivery-Board Verification

Fixture shape:

- WorkRequest: `wr_kraken_closeout`.
- Planned slice: raw status `dispatched`.
- Linked WorkPackage: raw package status: `ready_for_worker`.
- Either structured merged-PR evidence exists, or the operator has direct
  no-PR completion evidence.

Expected projection before closeout:

- `read_delivery_board` preserves raw slice status `dispatched`.
- The linked package raw status remains visible as `ready_for_worker`.
- If merged-PR evidence is present, the slice reports `Needs Closeout` rather
  than pretending the stale package card is still the human next action.

Expected projection after closeout:

- `record_planned_slice_delivery` records the outcome idempotently.
- `pr_merged` moves the compatible linked package to `merged`;
  `completed_no_pr` and `superseded` move it to `closed`; `abandoned` moves it
  to `abandoned`.
- The delivery board reports the outcome (`Delivered`, `Completed Without PR`,
  `Superseded`, or `Abandoned`) and no longer presents the stale
  `ready_for_worker` package as dispatchable work.
- WorkRequest completion refreshes when every planned slice has terminal
  delivery truth.

Closeout treats stale AgentRun rows the same way the delivery board does: stale
rows that are no longer operationally active do not block delivery recording,
and their ids/reason codes are preserved on the closeout progress event. Fresh
active AgentRun rows still fail closed.

Merged-PR recovery may close a compatible stale linked package even if its raw
lifecycle, worker grant, local claim-lease state, or AgentRun row is stale, but
it requires strong PR evidence: `pr_url`, `pr_merged_at`, and
`merge_commit_sha`. Live worker grants are revoked, active/stale local claim
leases are released, ignored stale AgentRun ids are audited, and that evidence
is listed in the closeout progress event. Active blockers, paused claim leases,
fresh active agent runs, malformed PR URLs, PR URL metadata mismatches, package
metadata mismatches, and weak merge evidence still fail closed.

Supersession may close a compatible stale linked package even when active
blocker events remain. The blocker events are not resolved or deleted; the
closeout progress event records the active blocker ids and the delivery board
keeps blocker attention on the terminal superseded slice.

Supersession and abandonment can follow explicit WorkRequest-scoped runtime
cleanup when stale linked runtime is the remaining blocker. Call
`cleanup_work_request_planned_slice_runtime(work_request_id, planned_slice_id,
outcome, reason, ...)` for the linked planned slice with the same superseded or
abandoned evidence that will be used inside `record_planned_slice_delivery`'s
typed `evidence` object, then rerun `record_planned_slice_delivery` with that
evidence. The cleanup tool
revokes linked live worker grants, releases non-paused current local claim
leases, clears recoverable worker MCP session bindings for the linked package,
and records a redacted audit event. It does not expose raw worker secrets.

Cleanup is not a general worker stop button. `outcome=superseded` requires
`successor_planned_slice_id` and `superseded_reason`; `outcome=abandoned`
requires `abandoned_rationale` and only applies to no-code packages that are
still `planning` or `ready_for_worker`.

Paused claim leases and fresh active AgentRun rows still fail closed. If only a
single live worker grant must be retired and claim/session cleanup is not
needed, `revoke_planned_slice_worker_key(work_request_id, planned_slice_id,
grant_id, reason)` remains available as a narrower compatibility path.

If closeout rejects because of active runtime on an unsupported outcome,
package metadata mismatch, weak PR evidence, or stale terminal conflict, do not
paper over it with a decision note. Fix the evidence or ask the
operator/architect for the next lifecycle decision.
