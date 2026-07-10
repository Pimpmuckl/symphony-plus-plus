# Lean MCP protocol surfaces

Set `SYMPP_MCP_SURFACE_PROFILE` before starting the MCP process, or pass
`--surface-profile` to `mix sympp.mcp` in direct STDIO mode. Supported values
are `worker`, `architect`, `coordinator`, `solo`, and `full`. `default` is an
alias for `full`.

Profiles are selected when `Config` is created, before `initialize` and the
first `tools/list`. The profile is process-wide for the shared HTTP singleton;
it is not selected per connection and does not depend on a tools-list refresh
after claim:

- `worker` exposes the worker claim plus every worker operation.
- `architect` exposes the architect claim plus every implemented architect
  operation.
- `coordinator` and `solo` expose health, assignment release, and the complete
  Solo Session operation set. Coordinators use Solo state for ordinary parent
  planning; WorkRequest orchestration uses the architect profile.
- `full` and the default expose complete implemented discovery. Use this profile
  for a shared singleton that serves mixed worker and architect sessions.

Authorization is unchanged. A listed operation still requires its existing
session role, grant capabilities, target scope, lifecycle state, and local
daemon trust checks.

All profiles remove redundant tool titles and generic worker descriptions.
HTTP calls keep `structuredContent` as the complete canonical machine
representation and emit only a small diagnostic text summary. Explicit STDIO
profiles retain the same lean result behavior; only STDIO `full` keeps the
legacy duplicated result/resource shape so already-open wrapper sessions can
drain without a mid-session protocol change. Claim results retain their already
compact, redacted claim summary. Worker virtual resources over HTTP return one
TOON representation instead of duplicating Markdown and TOON.

The installed MCP companion connects directly to
`http://127.0.0.1:19998/mcp`. Run the marketplace-backed
`scripts/sympp-mcp-cutover.ps1` before opening sessions after install or backend
failure. The helper starts or reuses one compatible singleton, validates the
HTTP endpoint, and never terminates active wrapper processes. New sessions do
not spawn `cmd.exe`, `powershell.exe`, or `pwsh.exe` transport bridges.

## Measurements

Measurements serialize `%{"tools" => tools}`, the complete MCP tool result, or
the complete MCP resource result with Jason. Token estimates are
`ceil(serialized_bytes / 4)`. The before column is the current 76-tool
full/default surface before applying lean decoration to it; tool membership is
unchanged.

| Profile | Tools before | Bytes before | Tokens before | Tools after | Bytes after | Tokens after |
|---|---:|---:|---:|---:|---:|---:|
| full | 76 | 54,437 | 13,610 | 76 | 50,951 | 12,738 |
| default | 76 | 54,437 | 13,610 | 76 | 50,951 | 12,738 |

Representative results use fixed redacted fixtures for claim, a 40-line read,
and progress append:

| Result | Bytes before | Tokens before | Bytes after | Tokens after |
|---|---:|---:|---:|---:|
| claim | 424 | 106 | 424 | 106 |
| read | 1,963 | 491 | 1,071 | 268 |
| progress | 488 | 122 | 338 | 85 |

The representative worker resource uses a fixed 40-line Markdown document and
a fixed 20-line TOON document for the same URI:

| Resource | Bytes before | Tokens before | Bytes after | Tokens after |
|---|---:|---:|---:|---:|
| worker virtual file | 1,459 | 365 | 448 | 112 |

The transport benchmark started one isolated loopback singleton on a
non-default port, then initialized 1, 10, and 100 direct HTTP clients. Every
cohort re-read the listener owner and start timestamp; all three observed the
same backend PID (`67028`) and start timestamp
(`639192928699486336` UTC ticks). Each cohort enqueued all initialize requests
before awaiting the burst, then issued `tools/list` concurrently. `Transport
processes` counts descendant
`cmd.exe`, `powershell.exe`, and `pwsh.exe` bridge processes owned by the
benchmark client:

| Clients | Backend listeners | Backend private bytes | Transport processes | Transport private bytes | Client host private-byte delta |
|---:|---:|---:|---:|---:|---:|
| 1 | 1 | 119,705,600 | 0 | 0 | 8,736,768 |
| 10 | 1 | 133,632,000 | 0 | 0 | 3,592,192 |
| 100 | 1 | 300,175,360 | 0 | 0 | 110,342,144 |

The same isolated endpoint passed the repository HTTP smoke before the
benchmark. The listener was stopped after measurement and the test port was
verified free.
