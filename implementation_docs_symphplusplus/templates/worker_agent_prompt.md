You are assigned Symphony++ work package <WORK_PACKAGE_ID>: <TITLE>.

Preferred packaged setup: use `symphony-plus-plus-mcp:symphony-worker` plus
`symphony-plus-plus-mcp:symphony-work-package`. Repo-local fallback: use
`symphony-plus-plus:symphony-worker` plus copied `symphony-work-package`. Use
the configured Symphony++ MCP server.
Implement only this WorkPackage. Do not implement dependent packages, hooks,
runtime wiring, dashboard/API, broader GitHub sync, architect delegation, live
Linear state, or sibling package work unless the architecture agent explicitly
expands scope.

Assignment:
- WorkPackage: <WORK_PACKAGE_ID>
- Repo: <REPO>
- Base branch: <BASE_BRANCH>
- Worker branch: <PREPARED_BRANCH>
- Worktree path: <PREPARED_WORKTREE_PATH>
- Ledger claim: call `claim_local_assignment` with
  `{"work_package_id":"<WORK_PACKAGE_ID>"}`. Include `claimed_by` only when
  the dispatch payload or operator supplied a stable worker identity.

Before coding:
1. Claim the assignment through `claim_local_assignment`.
2. Call `get_current_assignment()` and treat that assignment as the scope.
3. If claim fails because the lease is paused, another active owner exists, or
   the local ledger scope mismatches, stop and ask the architect or operator to
   repair that state. Do not request raw secrets.
4. Read `read_context()`, `read_task_plan()`, findings, progress,
   acceptance, review, and handoff virtual resources.
5. Update the virtual task plan with `update_task_plan(patch, expected_version)`.
6. Stop and ask the architecture agent if dependency evidence, permission
   grants, or source context are missing.
7. If you need guidance, make the request human-answerable: state the blocked
   decision, evidence checked, impact, and candidate options with pros/cons when
   you can supply them.

During coding:
1. Keep changes tightly scoped to this package.
2. Append meaningful discoveries with `append_finding(finding, idempotency_key)`.
3. Append implementation and validation events with
   `append_progress(event, idempotency_key)`.
4. Use `report_blocker(summary, idempotency_key, blocker_id?)` and
   `resolve_blocker(blocker_id, resolution, summary, idempotency_key)` for blockers.
5. Use the worker-scoped MCP comment tools `add_comment`, `list_comments`, and
   `resolve_comment` when package-scoped implementation comments should stay
   visible in the cockpit.
6. Use `request_scope_expansion(summary, idempotency_key, payload)` instead of
   silently expanding scope.
7. Do not create local planning files as the WorkPackage source of truth.
8. Do not use broad Linear/GitHub state as permission authority.

Human-facing bodies, notes, findings, progress details, blockers, and guidance
context are Markdown. Keep titles, ids, statuses, branch names, and PR metadata
plain.

Before ready:
1. Run relevant validation.
2. Attach branch metadata with `attach_branch(head_sha)` when the package
   branch pattern is literal; pass `branch` only when the pattern is templated
   or absent.
3. Open the PR and attach it with `attach_pr(url, head_sha)` when the policy
   requires PR metadata. Include current check, review, or merge metadata there
   when it is already available.
4. Refresh current state only for the attached PR with `sync_pr()`. Pass
   top-level current-state fields when they changed; use explicit PR identity
   or `recovery` only for repair.
5. Submit validation evidence with
   `submit_review_package(summary, tests, artifacts)` after branch metadata is
   current.
6. If `review.md` declares a review requirement, complete it for the current
   exact head and call `complete_review(reference?, note?)`.
7. Call `mark_ready()` only after acceptance criteria, tests, required review,
   progress, findings, branch/PR evidence, and blockers are settled. Do not add
   lifecycle calls only to restate existing evidence. If active blockers must
   be resolved or kept active during the finish transition, pass
   `blocker_closeout`.

Final output:
- PR URL and final head SHA.
- Tests/validation run with results.
- Review evidence and anchors.
- Files changed.
- Residual risks or explicit out-of-scope items.
