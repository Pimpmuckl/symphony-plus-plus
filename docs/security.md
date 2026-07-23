# Security

The MCP server is the permission boundary. Skills, prompts, hooks, and the
dashboard improve workflow but cannot grant authority.

## Claims

- A worker claims exactly one WorkPackage.
- An architect claims exactly one WorkRequest.
- `claimed_by` is an optional audit label, not a secret.
- Repository, branch, worktree, phase, and anchor values are derived from the
  ledger and treated as validation context when supplied.
- Fresh claims block competing workers; stale unpaused residue can be
  reclaimed; paused claims remain operator-controlled.

## Capabilities And Scope

Workers may update their own plan, progress, findings, blockers, comments,
branch, pull request, review, and readiness evidence. They cannot mint grants,
dispatch siblings, expand scope silently, merge pull requests, or record
WorkRequest delivery.

Architects may clarify and plan their WorkRequest, organize Groups, author and
dispatch WorkPackages, answer descendant guidance, approve allowed scope
expansion, and reconcile delivery. They do not gain global ledger authority.

## Secret Hygiene

Never place raw API keys, bearer tokens, GitHub or Linear tokens, MCP tokens,
grant verifiers, secret hashes, private handoff payloads, or secret-bearing
commands in:

- Agent prompts or durable ledger prose.
- Documentation, comments, pull requests, or reviews.
- Dashboard payloads or normal tool output.
- Logs, fixtures, or copied plugin assets.

Report missing secret-dependent validation as blocked. Do not substitute real
credentials into examples.

## Incidents

For suspected permission widening or secret exposure, follow
[Security incident response](runbooks/security-incident.md).
