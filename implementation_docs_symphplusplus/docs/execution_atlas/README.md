# Symphony++ V3: Execution Atlas Archive

Execution Atlas was the first V3 product brainstorm for the human-facing
Symphony++ cockpit. It is archived design context, not the binding V3
contract.

Use these current documents instead:

- `implementation_docs_symphplusplus/docs/V3_PRODUCT_TREE_REWORK.md`
- `implementation_docs_symphplusplus/runbooks/V3_PRODUCT_TREE_CUTOVER.md`
- `implementation_docs_symphplusplus/docs/13_WORKREQUEST_CONTRACT.md`
- `implementation_docs_symphplusplus/mcp/MCP_TOOLS_CONTRACT.md`

The current V3 model is:

```text
WorkRequest
|-- optional Group
|   |-- optional Group
|   `-- WorkPackages
`-- WorkPackages
```

Groups are optional and arbitrarily nested. They are not a fixed
Topic -> Capability, Layer -> Capability, or Atlas hierarchy. Simple WorkRequests
can stay as direct-slice rows.

WorkPackages remain architect-to-worker execution units. WorkPackages remain
internal execution and audit records: worker claim scope, grants, branches, PRs,
progress, findings, review evidence, readiness, and recovery state. They are no
longer a primary human-facing product board unit.

Reorganization is agent-driven through MCP tools:

- `upsert_group`
- `delete_group`
- `upsert_dependency`
- `delete_dependency`
- `update_work_package`

Do not add human-facing reorganize UI for V3 cutover unless a later product
decision explicitly reopens that scope.
