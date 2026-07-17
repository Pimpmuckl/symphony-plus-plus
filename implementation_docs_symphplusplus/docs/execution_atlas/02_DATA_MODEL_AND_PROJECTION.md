# Execution Atlas Data Model Archive

This document was part of the earlier Execution Atlas brainstorm and is no
longer the V3 data model or projection contract.

Current contract:

- `implementation_docs_symphplusplus/docs/V3_PRODUCT_TREE_REWORK.md`
- `implementation_docs_symphplusplus/mcp/MCP_TOOLS_CONTRACT.md`
- `implementation_docs_symphplusplus/docs/13_WORKREQUEST_CONTRACT.md`

Current V3 persistence is the WorkRequest-scoped product tree:
`sympp_product_tree_nodes`, direct WorkPackage ownership,
`sympp_product_tree_dependency_edges`, and `sympp_product_tree_revisions`.
Product plan nodes are optional and arbitrarily nested.
