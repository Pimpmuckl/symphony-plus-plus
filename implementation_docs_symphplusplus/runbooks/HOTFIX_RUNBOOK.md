# Hotfix Runbook

Use this for hotfix WorkRequests that need a bounded PR and current
review evidence. For role context, start with
`../docs/12_OPERATOR_TRAINING.md`.

## Create The WorkRequest

1. Open the local operator cockpit.
2. Create a WorkRequest with `work_type: hotfix` and
   `desired_dispatch_shape: single_package`.
3. Add one direct planned slice with the repo, base branch, branch pattern,
   owned paths, acceptance criteria, validation, review-suite requirement, and
   stop conditions.
4. Dispatch the approved slice from the dashboard, architect MCP tool, or CLI:

```powershell
Set-Location elixir
mise exec -- mix sympp.dispatch_planned_slice --work-request-id <WR id> --planned-slice-id <slice id> --claimed-by <stable-worker-id>
```

5. Confirm dispatch output returns only non-secret handoff metadata. It must not
   print raw claim secrets, bearer tokens, or secret-bearing URLs.

## Dispatch The Worker

Send the worker:

- WorkRequest id, planned-slice id, WorkPackage id, base branch, target branch
  convention, and PR title format.
- WorkPackage claim call and optional stable `claimed_by` identity.
- Package scope, owned files, acceptance criteria, and stop conditions.
- Validation target and optional review requirement.
- Reminder to use the `symphony-plus-plus` plugin or repo-local skill with MCP
  local claim bootstrap.

Do not send raw secrets, raw WorkKeys, private handoff payloads,
secret-bearing commands, bearer tokens, files, PR bodies, review text, or
durable logs.

## Review And Merge

1. Watch claim, plan, findings, progress, blockers, branch, PR, tests, and
   review evidence in Symphony++ state.
2. Require the worker to attach PR URL and current head SHA before readiness.
3. Confirm review evidence applies to the current PR head.
4. Check changed files against the package scope.
5. Use `../review/REVIEWER_CHECKLIST.md` and
   `../docs/11_RELEASE_VALIDATION.md` before merge.
6. Record skipped validation as blocked with exact blocker and owner.
7. Human merge only after branch protection and hotfix gates pass.

## Quick Fix

For a quick fix, use the same single-slice WorkRequest flow with
`desired_dispatch_shape: single_package`.

Quick-fix packages still need truthful acceptance and review evidence, but may
use their package policy instead of hotfix-specific gates.

## Investigation

For an investigation, create a WorkRequest with `work_type: investigation` and
`desired_dispatch_shape: investigation_first`.

The investigation policy does not require a PR unless the slice says so. It
requires findings plus the canonical `recommendation.md` artifact recorded
through `request_scope_expansion`; stored legacy recommendation events do not
satisfy readiness unless that canonical artifact already exists.
