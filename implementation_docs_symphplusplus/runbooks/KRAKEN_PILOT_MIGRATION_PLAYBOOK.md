# Kraken Pilot Migration Playbook

The historical pilot bootstrap has been superseded by simplified ledger claims.
Use this current flow for any new or replayed Kraken pilot work.

## Architect

1. Claim the WorkRequest with `claim_local_architect_assignment`.
2. Read the WorkRequest, product tree, and delivery board.
3. Dispatch approved planned slices with `dispatch_slice`.

## Worker

1. Claim the dispatched WorkPackage with `claim_local_assignment`.
2. Read MCP context and task plan.
3. Record progress, findings, blockers, branch/PR metadata, review evidence,
   and readiness through MCP.

## Closeout

Use `record_planned_slice_delivery` with one typed `evidence` object matching
the outcome: `evidence.pr_merged`, `evidence.completed_no_pr`,
`evidence.superseded`, or `evidence.abandoned`.

Do not use historical secret bootstrap snippets from older pilot notes.
