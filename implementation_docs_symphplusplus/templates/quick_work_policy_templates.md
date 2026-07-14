# Quick Work Policy Templates

These templates describe the current quick-work policies. They are package
policy references for implemented behavior, not a backlog or phase-history
roadmap.

| Template | Planning depth | Default grant expiry | Readiness status | Required gates | PR required |
|---|---|---:|---|---|---|
| `quick_fix` | `brief` | `none` | `ready_for_merge` | `focused_tests` | No |
| `hotfix` | `incident` | `none` | `ready_for_merge` | `focused_tests, human_merge` | Yes |
| `docs` | `brief` | `none` | `ready_for_merge` | `focused_tests` | No |
| `investigation` | `findings` | `none` | `ready_for_merge` | `findings_documented, recommendation_artifact_recorded` | No |

## Behavior

- `quick_fix` uses light planning and requires focused test evidence without forcing branch or PR metadata.
- `hotfix` uses incident-depth planning and requires branch, PR, tests, and human merge. Workers can mark it ready for human merge but cannot mark it merged.
- `docs` uses light planning for docs-only work. Owned globs must stay under documentation roots or target documentation-file globs. Readiness requires docs validation without forcing branch, PR, findings, or recommendation artifacts.
- `investigation` records findings and a canonical recommendation artifact. New `request_scope_expansion` recommendations persist `recommendation.md`; stored legacy recommendation events do not satisfy readiness unless that canonical artifact already exists.

Review is independent of the policy template. A planned slice may declare one
provider-agnostic review requirement; when absent, no review is required.

Default quick-work grants do not expire by clock. Authority ends through explicit
revocation, package completion/merge/close/archive lifecycle, or worker recycle.
