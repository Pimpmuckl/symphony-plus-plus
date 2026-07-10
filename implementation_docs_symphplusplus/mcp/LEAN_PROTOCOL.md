# Lean MCP protocol surfaces

Set `SYMPP_MCP_SURFACE_PROFILE` before starting the MCP process, or pass
`--surface-profile` to `mix sympp.mcp` in direct STDIO mode. Supported values
are `worker`, `architect`, `coordinator`, `solo`, and `full`. `default` is an
alias for `full`.

Profiles are selected when `Config` is created, before `initialize` and the
first `tools/list`. They do not depend on a tools-list refresh after claim:

- `worker` exposes the worker claim plus every worker operation.
- `architect` exposes the architect claim plus every implemented architect
  operation.
- `coordinator` and `solo` expose health, assignment release, and the complete
  Solo Session operation set. Coordinators use Solo state for ordinary parent
  planning; WorkRequest orchestration uses the architect profile.
- `full` and the default expose complete implemented discovery for diagnostics.

Authorization is unchanged. A listed operation still requires its existing
session role, grant capabilities, target scope, lifecycle state, and local
daemon trust checks.

Explicit profiles remove redundant tool titles and generic worker descriptions.
Their successful calls keep `structuredContent` as the complete canonical
machine representation and emit only a small diagnostic text summary. Claim
results retain their already compact, redacted claim summary. Worker virtual
resources return one TOON representation instead of duplicating Markdown and
TOON.

## Measurements

Measurements serialize `%{"tools" => tools}` or the complete MCP tool result
with Jason. Token estimates are `ceil(serialized_bytes / 4)`. The before role
rows use the equivalent pre-change complete lane sets; before this change only
the full/default set was selectable on the first list. The full/default before
rows also describe the current PR head before the three verified unimplemented
tools were removed.

| Profile | Tools before | Bytes before | Tokens before | Tools after | Bytes after | Tokens after |
|---|---:|---:|---:|---:|---:|---:|
| worker | 24 | 13,713 | 3,429 | 24 | 11,812 | 2,953 |
| architect | 48 | 36,312 | 9,078 | 45 | 33,315 | 8,329 |
| coordinator | 16 | 7,896 | 1,974 | 16 | 7,461 | 1,866 |
| solo | 16 | 7,896 | 1,974 | 16 | 7,461 | 1,866 |
| full | 79 | 55,432 | 13,858 | 76 | 54,191 | 13,548 |
| default | 79 | 55,432 | 13,858 | 76 | 54,191 | 13,548 |

Representative results use fixed redacted fixtures for claim, a 40-line read,
and progress append:

| Result | Bytes before | Tokens before | Bytes after | Tokens after |
|---|---:|---:|---:|---:|
| claim | 424 | 106 | 424 | 106 |
| read | 1,963 | 491 | 1,071 | 268 |
| progress | 488 | 122 | 338 | 85 |
