# Execution Atlas Architect Workflow Archive

This document was part of the earlier Execution Atlas brainstorm and is no
longer the architect or MCP workflow contract.

Current contract:

- `implementation_docs_symphplusplus/docs/V3_PRODUCT_TREE_REWORK.md`
- `implementation_docs_symphplusplus/mcp/MCP_TOOLS_CONTRACT.md`
- `plugins/symphony-plus-plus-mcp/skills/symphony-architect/SKILL.md`

Architects may create or edit optional product plan node content with
`upsert_plan_node`, rearrange product plan nodes
with `move_plan_node`, set node completion marks with
`set_plan_node_completion`, and move planned slices with
`move_slice_to_plan_node`. These are agent-facing
control-plane tools and do not dispatch slices or create WorkPackages.
