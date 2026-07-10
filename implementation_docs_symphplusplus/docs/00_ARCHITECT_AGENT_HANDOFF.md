# Architect Agent Handoff

Use the opt-in `symphony-plus-plus-mcp:symphony-architect` skill with the
current Symphony++ MCP server. The architect claim coordinate is the
WorkRequest id.

## Start

1. Connect from an MCP-enabled Symphony++ session.
2. Call `claim_local_architect_assignment` with:

```json
{"work_request_id":"<WR id>"}
```

3. Include `claimed_by` only when the operator supplied a stable architect
identity.
4. Call `read_work_request`, `read_plan`, and
`read_delivery_board` before slicing or dispatch.

The claim may recover stale handoff scope when the local ledger still proves
one matching WorkRequest, repo, base branch, anchor package, phase id, and
architect grant. Remaining `phase_scope_not_available` errors include
`missing_evidence` and an operator repair action. Archived or manually
completed WorkRequests return `work_request_terminal`; restore them through the
local operator or start a new WorkRequest.

## Product Tree Shape

Do not create a plan node solely to wrap one slice. Leave simple slices direct
unless the node groups multiple units or records a real product boundary.

## Dispatch

Dispatch planned slices with `dispatch_slice` using only
`work_request_id`, `planned_slice_id`, and optional `claimed_by`. The response
creates the worker WorkPackage and returns a non-secret `worker_bootstrap`
object for `claim_local_assignment`.

Workers claim with:

```json
{"work_package_id":"<WP id>"}
```

## References

- `.codex/skills/symphony-work-package/`
- `plugins/symphony-plus-plus-mcp/`
- `implementation_docs_symphplusplus/templates/references/mcp_wiring.md`
- `implementation_docs_symphplusplus/templates/worker_agent_prompt.md`

Do not ask agents for raw grant secrets or private handoff metadata.
