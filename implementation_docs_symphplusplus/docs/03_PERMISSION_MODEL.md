# Permission Model

The MCP server is the permission boundary. Prompts, skills, docs, and dashboard
UI are workflow aids only.

## Claim Coordinates

- Workers claim one WorkPackage with `claim_local_assignment`.
- Architects claim one WorkRequest with `claim_local_architect_assignment`.
- `claimed_by` is optional audit ownership, not a secret carrier.
- Repo, base branch, phase, anchor package, worktree, branch, and caller fields
  are derived from the ledger when omitted and are validation context when
  supplied.
- Local claim leases use a short heartbeat freshness window. Replaying the
  same claim or using a bound MCP session refreshes the lease; stale
  no-heartbeat residue may be reclaimed without operator database repair.
- Fresh worker leases still block other workers. Paused leases remain an
  intentional operator state, not reboot residue.

## Role Boundaries

Workers can update task plan, findings, progress, blockers, comments, branch/PR
metadata, review evidence, and readiness for their assigned WorkPackage.
Workers cannot mint grants, dispatch WorkPackages, approve scope, merge PRs,
or close WorkRequest delivery.

Architects can slice WorkRequests, manage product-plan nodes, dispatch planned
slices, coordinate phase children, answer guidance, reconcile delivery, and
record closeout.
Architects may resolve blockers only for policy-scoped descendant WorkPackages
visible from their claimed WorkRequest or phase scope. They cannot report new
worker blockers, mutate sibling or out-of-scope packages, or use blocker resolution
as scope expansion.

## Safety

Agent-facing tools do not require private files, secret stores, or raw grant
secrets. Responses and durable notes redact bearer/API/GitHub/Linear/MCP tokens,
grant verifiers, secret hashes, and secret-like prose.
Normal claim/release tool text is compact and omits claim lease ids, grant ids,
caller ids, and raw recovery maps. Structured MCP results retain those
non-secret audit details for debuggers and cockpit projections.
