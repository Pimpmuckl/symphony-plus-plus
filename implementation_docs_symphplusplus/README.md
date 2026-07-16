# Symphony++ Operator Documentation

This directory is the durable operator/product guide for Symphony++. It explains
how the current system works: how operators and architects manage WorkRequests
as product-facing rows, how optional product plan nodes make large work
one-glance-readable, how WorkPackages dispatch to workers, how WorkPackages
remain scoped execution/audit records, how MCP-backed planning resources are
updated, and how readiness evidence flows into human merge decisions.

Historical phase, package, and Execution Atlas brainstorm notes are not the
active source of truth. Current product planning starts from WorkRequests and
the V3 product-tree contract; assigned worker execution starts from live
WorkPackages, MCP resources, and package-specific scope.

## Contents

- `docs/` - operator guide, V3 product-tree contract, product spec,
  permission, MCP, testing, dashboard, GitHub, release, role-boundary, and
  historical Execution Atlas design context.
- `templates/` - worker/architect/reviewer prompts, Symphony++ workflow
  template, skill template, status templates, quick-work examples, and optional
  Codex hook nudges.
- `mcp/` - MCP tool/resource contracts for Symphony++.
- `schemas/` - JSON schema sketches for core records.
- `review/` - review-suite contract and readiness-gate definitions.
- `runbooks/` - hotfix, incident, migration, and pilot runbooks. Pilot
  migration notes are historical/conditional unless an operator explicitly
  assigns that pilot.

## Start Here

- Local operator golden path: `runbooks/LOCAL_OPERATOR_GOLDEN_PATH.md`
- V3 product-tree cockpit contract: `docs/V3_PRODUCT_TREE_REWORK.md`
- V3 copied-ledger preview and cutover: `runbooks/V3_PRODUCT_TREE_CUTOVER.md`
- Product/operator guide: `docs/01_IMPLEMENTATION_GUIDE.md`
- WorkRequest and work-package product contract: `docs/13_WORKREQUEST_CONTRACT.md`
- Solo Session product contract: `docs/14_SOLO_SESSION_CONTRACT.md`
- Target permission redesign contract: `docs/16_PERMISSION_REDESIGN_CONTRACT.md`
- Marketplace runtime artifact contract: `docs/17_RUNTIME_ARTIFACT_CONTRACT.md`
- Execution Atlas brainstorm/design context: `docs/execution_atlas/README.md`
- Role-oriented walkthrough: `docs/12_OPERATOR_TRAINING.md`
- Short command-flow runbook: `docs/09_OPERATIONAL_RUNBOOK.md`
- Release gate: `docs/11_RELEASE_VALIDATION.md`
- Historical V2.1 final local cutover: `runbooks/V21_FINAL_CUTOVER.md`
- Security and guardrails: `docs/06_SECURITY_AND_GUARDRAILS.md`
- MCP and skill contract: `docs/04_MCP_AND_SKILL_CONTRACT.md`
- Local plugin package notes: `../plugins/symphony-plus-plus/README.md`

Local plugin/cache sync is a final feature-branch cutover task. During normal
feature-branch work, update repo docs and skill sources only; do not edit or
refresh user-local plugin cache paths.

## Merge Policy

- One WorkPackage = one PR unless the overseeing architecture agent explicitly
  splits or combines scope.
- Every PR must record acceptance evidence, tests run, and any blocked
  validation.
- Workers may request scope expansion, but cannot silently expand scope.
- Human merge remains gated by branch protection, review-suite evidence, and
  package-specific readiness.
