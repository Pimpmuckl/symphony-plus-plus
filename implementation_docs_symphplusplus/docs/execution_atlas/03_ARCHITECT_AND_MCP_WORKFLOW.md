# Execution Atlas Architect Workflow Archive

This document was part of the earlier Execution Atlas brainstorm and is no
longer the architect or MCP workflow contract.

Current contract:

- `implementation_docs_symphplusplus/docs/V3_PRODUCT_TREE_REWORK.md`
- `implementation_docs_symphplusplus/mcp/MCP_TOOLS_CONTRACT.md`
- `plugins/symphony-plus-plus-mcp/skills/symphony-architect/SKILL.md`

Architects may create, edit, reparent, or reorder optional Groups with
`upsert_group`, remove them with `delete_group`, maintain execution intent with
`upsert_dependency` and `delete_dependency`, and assign planned WorkPackages
with `update_work_package`. These are agent-facing control-plane tools and do
not dispatch WorkPackages.
