# Execution Atlas Dashboard UX Archive

This document was part of the earlier Execution Atlas brainstorm and is no
longer the V3 dashboard UX contract.

Current contract:

- `implementation_docs_symphplusplus/docs/V3_PRODUCT_TREE_REWORK.md`
- `implementation_docs_symphplusplus/runbooks/V3_PRODUCT_TREE_CUTOVER.md`

Current V3 cockpit behavior: each WorkRequest is the primary collapsed row.
Expanding a row shows optional product plan nodes and WorkPackages. Simple
WorkRequests with no product tree remain valid. WorkPackage details stay
reachable as execution evidence, not as primary product rows.

Human-facing reorganize UI is not part of the V3 cutover scope; rearrangement is
agent-driven through MCP tools.
