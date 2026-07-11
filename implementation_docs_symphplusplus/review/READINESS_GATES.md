# Readiness Gates

A WorkPackage can be marked ready only when all gates required by its policy template pass.

## Common gates

- WorkPackage status is eligible for readiness.
- No active blocker remains.
- Required plan nodes are complete or skipped with rationale.
- Acceptance criteria have evidence.
- Required PR exists.
- Required review-suite artifact exists in the latest review package for the current head SHA.
- Required CI/check status is green.
- Changed files are within allowed scope.
- Base branch matches package constraints.

These gates are readiness evidence for Symphony++ package state. They do not
automatically merge code, bypass branch protection, or prove production
readiness beyond the package's recorded validation. Use
`REVIEWER_CHECKLIST.md` for PR review and `../docs/11_RELEASE_VALIDATION.md`
for release-candidate evidence.

## Phase-child additional gates

- Parent phase is active.
- Child package belongs to the phase and remains inside the architect anchor repo, base branch, and allowed file globs.
- Architect approval is required after worker readiness.

## Hotfix additional gates

- Grant is live: not revoked, package authority is still valid, and any explicit `expires_at` is still in the future.
- Human merge is required.
- Hotfix review-suite profile passes.

## Docs additional gates

- Owned globs are documentation-only: they must live under documentation roots or target documentation-file globs.
- Docs validation evidence is recorded as focused test evidence.
- Normal review evidence is recorded.
- PR, findings, and investigation recommendation artifacts are not required by default.

## Investigation additional gates

- Recommendation evidence exists. `request_scope_expansion` records the protected worker recommendation and persists the canonical `recommendation.md` artifact for new investigation packages. Stored legacy `request_scope_expansion` rows do not satisfy readiness unless the canonical artifact already exists. It does not approve expanded scope.
- Findings are summarized.
- PR is not required unless package explicitly asks for one.
