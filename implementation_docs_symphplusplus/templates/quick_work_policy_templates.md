# Quick Work Policy Templates

These templates describe the current quick-work policies. They are package
policy references for implemented behavior, not a backlog or phase-history
roadmap.

| Template | Planning depth | Default grant expiry | Readiness status | Required gates | Required review profiles | PR required |
|---|---|---:|---|---|---|---|
| `quick_fix` | `brief` | `none` | `ready_for_merge` | `focused_tests, review_normal` | `normal` | No |
| `hotfix` | `incident` | `none` | `ready_for_merge` | `focused_tests, review_fast, human_merge` | `fast` | Yes |
| `docs` | `brief` | `none` | `ready_for_merge` | `focused_tests, review_normal` | `normal` | No |
| `investigation` | `findings` | `none` | `ready_for_merge` | `findings_documented, recommendation_artifact_recorded` | `` | No |

## Behavior

- `quick_fix` uses light planning. Readiness can be satisfied with focused test evidence plus current `normal` review evidence, without forcing branch or PR metadata.
- `hotfix` uses incident-depth planning. It requires branch and PR metadata, requires current-head review artifacts, and requires current `fast` review evidence. Workers can mark it ready for human merge but cannot mark it merged.
- `docs` uses light planning for docs-only work. Owned globs must stay under documentation roots or target documentation-file globs. Readiness can be satisfied with docs validation evidence plus current `normal` review evidence, without forcing branch, PR, findings, or recommendation artifacts.
- `investigation` records findings and a canonical recommendation artifact. New `request_scope_expansion` recommendations persist `recommendation.md`; stored legacy recommendation events do not satisfy readiness unless that canonical artifact already exists. It does not require a PR or review lane by default.

Default quick-work grants do not expire by clock. Authority ends through explicit
revocation, package completion/merge/close/archive lifecycle, or worker recycle.
