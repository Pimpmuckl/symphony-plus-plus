# Symphony++ V3 Product Tree Rework

## North Star

V3 makes the cockpit answer the product-progress question first:

```text
Can a human open the board, glance at one WorkRequest row, expand it, and see
what product work is done, partial, blocked, or still missing?
```

The v2 board exposes real state, but its top-level model is too technical:

```text
Requests | Slices | Work Packages
```

That reads like a dispatch ledger. V3 keeps the ledger authoritative, but the
default cockpit becomes:

```text
WorkRequest
|-- optional product plan node
|   |-- optional product plan node
|   |   `-- WorkPackages
|   `-- WorkPackages
`-- WorkPackages
```

The tree is optional. A simple hotfix can be a single WorkRequest with direct
slices and no extra product structure. A larger implementation can use as much
nesting as the architect thinks is useful.

## Product Contract

### WorkRequest

The WorkRequest remains the top-level product intent, operator surface, and
human-facing row on the cockpit.

The cockpit renders one collapsed line per WorkRequest. Expanding the line
shows the WorkRequest's optional product plan tree and WorkPackages.

### Product Plan Node

A product plan node is an architect-authored product grouping. It is not locked
to names such as layer, capability, topic, epic, or milestone.

Recommended examples:

```text
Backend
Kraken P1.1 contract alignment
VOD Intelligence serving substrate
Dashboard UX
Cutover and migration
```

Fields:

```text
id
work_request_id
parent_id nullable
title
description nullable
node_kind nullable
completion_mark
metadata
position
created_by
created_at
```

`node_kind` is only a label. The schema must not require a fixed hierarchy such
as `layer -> capability`.

### Canonical WorkPackage

A WorkPackage is the architect-to-worker execution unit from planning through
delivery.

In V3, WorkPackages can belong directly to one product plan node or remain
direct children of the WorkRequest. Direct WorkPackages are valid and expected
for simple work.

Do not create a plan node solely to wrap one WorkPackage. Leave simple packages direct
unless the node groups multiple units or records a real product boundary.

### WorkPackage

WorkPackages remain execution and audit records:

- worker claim scope
- grant ownership
- branch and PR metadata
- findings, progress, artifacts, reviews, readiness evidence
- lifecycle and recovery state

They are no longer a primary logical row in the product board. The cockpit can
still open package detail from a linked slice when a human needs evidence.

## Completion Marks

Product plan nodes use `completion_mark`, not `status`.

```text
done
partial
not_done
deferred
unknown
```

The projection also returns a computed mark from linked slices. Explicit marks
can encode product decisions; computed marks keep the board grounded in ledger
truth.

## Dependency Model

Dependency edges are explicit and optional.

Supported endpoints:

```text
product_node
work_package
```

Supported edge kinds:

```text
depends_on
blocks
enables
validates
replaces
supersedes
recut_from
related
```

Hard edges such as `depends_on` and `blocks` require a reason or decision
reference. This keeps the board from inventing blockers from vague proximity.

## Current Implementation Slice

This branch introduces the v3 foundation:

- `sympp_product_tree_nodes`
- `sympp_product_tree_dependency_edges`
- `sympp_product_tree_revisions`
- backend repository and projection modules
- `product_tree` on WorkRequest detail payloads
- `read_plan` MCP read projection for agent planning
- cockpit WorkRequest rows collapsed by default
- expanded arbitrary nested plan-node tree with canonical WorkPackage rows
- Vite port override for isolated preview servers

Architect-facing MCP mutation tools maintain product trees:

- `read_plan` reads the current scoped product tree without
  direct ledger queries. `nodes_only` returns product plan nodes, the default
  `nodes_with_work_package_refs` includes compact package id/status refs, and
  `nodes_with_work_packages` includes visible WorkPackage payloads. Completion and
  attention rollups use scoped delivery-board operational state for canonical
  WorkPackages.
- `upsert_plan_node` creates product plan nodes
  and edits their title, description, or node kind inside a scoped WorkRequest.
- `move_plan_node` reparents or reorders product plan nodes
  inside a scoped WorkRequest.
- `set_plan_node_completion` updates product plan node
  completion marks and uses the existing blocker closeout guard for terminal
  marks.
- `update_work_package` changes a planned WorkPackage contract, including its
  optional `product_tree_node_id`, using optimistic contract revision checking.

These tools are intentionally small rearrangement primitives. They do not
dispatch WorkPackages, create WorkPackages, mutate Linear, or force every WorkRequest
to use product plan nodes.

## Cutover Non-Goals And Follow-Ups

Do not add a human-facing reorganize UI for the V3 cutover. Reorganization is
agent-driven through the architect MCP tools above. The cockpit only needs to
make the resulting product tree readable and drillable for humans.

Do not rename or remove WorkPackage as part of this cutover. WorkPackage remains
the internal execution/audit record until a later, explicit migration decides
whether a name such as worker assignment or execution unit is worth the churn.

Do not fold the top-panel Finished-list performance redesign into the V3
cutover unless it becomes a blocker. The follow-up PR should cap, paginate, or
otherwise redesign Finished query/display behavior so repeated dashboard
polling cannot hold up the server.

## Cutover Shape

1. Land schema and read projection behind the existing local cockpit.
2. Migrate a copy of the current local SQLite DB and preview the v3 cockpit.
3. Seed representative WorkRequests with product plan nodes and canonical WorkPackages.
4. Backfill existing large WorkRequests opportunistically with the architect
   product-tree tools; leave simple work as
   direct-WorkPackage WorkRequests.
5. Make the product-tree cockpit the default board once the copied-DB preview
   proves stable.

The live ledger should not be rewritten in-place until the copied-DB preview is
validated.
