# AGENTS.md - Symphony++ WorkPackage Conventions

## PR conventions

- One dispatched WorkPackage/WorkPackage per PR.
- PR title format: `[SYMPP-...] <title>`.
- PR body must list acceptance criteria and tests run.
- Do not implement dependent packages unless explicitly assigned.
- Preserve upstream Symphony behavior unless the package says otherwise.

## Security conventions

- Never log raw grant secrets, bearer tokens, GitHub tokens, Linear tokens, or MCP auth tokens.
- Store only hashed/verifier forms of secrets.
- Server-side permission checks are mandatory for every Symphony++ API/MCP action.
- Worker grants are scoped to exactly one WorkPackage.

## Testing conventions

- Every code-changing package must add or update tests matching the package's
  test plan unless the package explicitly documents why validation is blocked.
- Existing tests must continue to pass.
- If a test cannot be run locally, document the exact reason in the PR summary.

## Documentation conventions

- Update package notes when discovering constraints.
- Keep live WorkPackage state, findings, progress, acceptance evidence, and
  review evidence current when packages are split or merged.
