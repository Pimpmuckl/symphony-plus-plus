# SYMPP-V2-DOGFOOD-002 Multi-PR Rehearsal Evidence

Date: 2026-05-18

## Scope

This DOGFOOD-002 pass ran the first tiny multi-PR rehearsal inside the
Symphony++ repository. The rehearsal stayed docs/evidence-only under
`implementation_docs_symphplusplus/dogfood/` and did not change product,
runtime, workflow, plugin, or global Codex configuration behavior.

## Symphony++ Usage

The current worker session did not expose a native `symphony_plus_plus` MCP tool
namespace. Tool discovery for assignment and WorkRequest tools returned no
matching S++ MCP tools, so this pass used the requested fallback path:

- Dedicated temp Codex home:
  `C:\Users\jonat\AppData\Local\Temp\sympp-v2-dogfood-002-codex-home`
- Temp ledger:
  `C:\Users\jonat\AppData\Local\Temp\sympp-v2-dogfood-002\dogfood-002.sqlite3`
- Activation doctor status: `healthy_local_workrequest_mcp`
- Unbound HTTP MCP smoke: passed against `http://127.0.0.1:4057/mcp`
- HTTP smoke self-test: passed
- Bound worker HTTP smoke: passed against an isolated dynamic-port cockpit for
  WorkPackage `wp_ZtFeuFtbjHyAXvNY2jllEA`

The fallback ledger created WorkRequest `SYMPP-V2-DOGFOOD-002-WR`, recorded the
two child WorkPackages, marked the WorkRequest `sliced`, and dispatched both
slices into quick-fix WorkPackages. Dispatch output reported
`secret_in_stdout: false`. Raw work keys, grant secrets, private handoff
payloads, and MCP session ids are intentionally not recorded here.

## Rehearsal Plan

| Item | Value |
| --- | --- |
| WorkRequest | `SYMPP-V2-DOGFOOD-002-WR` |
| Child A slice | `SYMPP-V2-DOGFOOD-002-SLICE-A` |
| Child A WorkPackage | `wp_ZtFeuFtbjHyAXvNY2jllEA` |
| Child B slice | `SYMPP-V2-DOGFOOD-002-SLICE-B` |
| Child B WorkPackage | `wp_sHfN93m9r_YI13w7TOqeXw` |

## Child PRs

| Child | PR | Head SHA | Merge SHA | Evidence |
| --- | --- | --- | --- | --- |
| A | `https://github.com/Pimpmuckl/symphony-plus-plus/pull/162` | `a425495130664fecfd8d7300fdc8349c07f12b33` | `9be966822e34e6bcf731e157479a6813beb5741d` | `SYMPP-V2-DOGFOOD-002-child-a-naming.md` |
| B | `https://github.com/Pimpmuckl/symphony-plus-plus/pull/163` | `33de6128a730ca83e773e1dbfa02a3c3d733c774` | `a9e2a4a64ac470f4e786581c5409bd3276d747d6` | `SYMPP-V2-DOGFOOD-002-child-b-handoff.md` |

Child B was created from updated `origin/main` after child A landed, so the
rehearsal exercised a real sequential two-child merge flow.

## Validation And Review

Child A:

- `git diff --check`: passed
- `git diff --cached --check`: passed
- PR body check: passed with `mix pr_body.check`
- Review-suite T1: clean from both reviewers, graded `tie_clean`
- Review-suite T2: clean from all four reviewers, gate closed `clean`
- GitHub review: "Didn't find any major issues."
- GitHub branch checks: none reported

Child B:

- `git diff --check`: passed
- `git diff --cached --check`: passed
- PR body check: passed with `mix pr_body.check`
- Review-suite T1: clean from both reviewers, graded `tie_clean`
- Review-suite T2: clean from all four reviewers, gate closed `clean`
- GitHub review: "Didn't find any major issues."
- GitHub branch checks: none reported

Final evidence PR validation is recorded on the final PR.

## Friction

- Native S++ MCP tools were not visible in this already-running worker session.
  The reusable path is to start or reload a dedicated MCP-enabled Codex session
  before expecting `symphony_plus_plus` tools in the model tool namespace.
- Elixir dependencies were not installed in this worktree at first. `mix deps.get`
  fixed the local setup blocker.
- First compile emitted the known Windows Phoenix LiveView colocated JS symlink
  warning (`:eperm`). It did not block the ledger seed or focused checks.
- `gh pr merge --delete-branch` merged the PRs remotely but failed local branch
  cleanup because `main` is checked out in the parent worktree. The remote child
  branches were deleted explicitly afterward.
- The requested full suite was intentionally not run for child PRs; this
  rehearsal used the docs-only focused validation path and review-suite gates.

## Recommendation

Creator-data orchestration can start, with one operational condition: launch it
from a fresh or reloaded dedicated S++ MCP-enabled Codex session so the native
`symphony_plus_plus` MCP namespace is present before the model starts. The
doctor, HTTP smoke, isolated ledger, WorkRequest/work-package dispatch, bound
worker smoke, child PR reviews, and two sequential child merges all passed.

Already-running sessions that cannot see the S++ MCP namespace remain blocked
for native MCP tool-call dogfooding and should use the documented
doctor/HTTP/ledger fallback only for diagnosis.
