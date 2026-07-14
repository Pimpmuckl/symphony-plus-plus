# WorkRequest Contract

A WorkRequest is the product-facing planning and delivery unit. It may contain
product plan nodes and planned slices. WorkPackages are execution/audit records
created from planned slices.

## Architect Bootstrap

`create_work_request` returns the created WorkRequest and a non-secret local
architect claim:

```json
{"tool":"claim_local_architect_assignment","arguments":{"work_request_id":"<WR id>"}}
```

## Planned Slice Dispatch

After all open clarification questions are answered or closed, there is no
separate clarification-complete step. `plan_slice` can
advance a `ready_for_clarification`, `clarifying`, or `human_info_needed`
WorkRequest with zero open questions to `ready_for_slicing` before it inserts
the slice. Open questions still block slicing.

After claiming one current WorkRequest, an architect may omit
`work_request_id`, delivery repo, and the primary repo's target base branch.
Pass the target base branch when selecting a secondary delivery repo. Ordinary
PR work also defaults to `standard_pr`; use `mcp` for MCP server, protocol,
tool, or plugin work. Branch pattern and forbidden globs may be omitted. Review
is also optional and provider-agnostic. Title, goal, owned
globs, acceptance criteria, validation, and stop conditions remain explicit.

Approved planned slices are dispatched with `work_request_id` and
`planned_slice_id`. Dispatch creates a linked WorkPackage and returns worker
bootstrap metadata for `claim_local_assignment`.

## Delivery

Closeout is recorded with `record_planned_slice_delivery` using one typed
`evidence` object matching the outcome: `evidence.pr_merged`,
`evidence.completed_no_pr`, `evidence.superseded`, or `evidence.abandoned`.
Skipped planned slices remain visible in normal delivery projection; there is no
separate scratch-planning projection.

All WorkRequest payloads must redact tokens, grant verifiers, secret hashes, and
secret-like prose.
