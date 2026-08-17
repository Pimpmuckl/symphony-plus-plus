You are assigned Symphony++ work package <WORK_PACKAGE_ID>: <TITLE>.

Use `symphony-plus-plus-mcp:symphony-worker` plus
`symphony-plus-plus-mcp:symphony-work-package` and the configured Symphony++
MCP server.
Implement only this WorkPackage. Do not implement dependent packages, hooks,
runtime wiring, dashboard/API, broader GitHub sync, architect delegation, live
Linear state, or sibling package work unless the architecture agent explicitly
expands scope.

Assignment:
- WorkPackage: <WORK_PACKAGE_ID>
- Primary worker coordinate: <WORK_PACKAGE_ID>
- Repo: <REPO>
- Base branch: <BASE_BRANCH>
- Worker branch: <PREPARED_BRANCH>
- Worktree path: <PREPARED_WORKTREE_PATH>
- Ledger claim: call `claim_local_assignment` with
  `{"work_package_id":"<WORK_PACKAGE_ID>"}`. Include `claimed_by` only when
  the dispatch payload or operator supplied a stable worker identity.

Before coding:
1. Call `get_current_assignment()`. If it reports an unbound or stale binding,
   follow its profile-aware claim or reclaim action.
2. Claim the assignment through `claim_local_assignment`.
   The first successful claim activates the package atomically; reconnecting
   the same claim does not change lifecycle state.
3. Follow the successful claim's `relist.next_action`, refresh the MCP tool
   list, then call `get_current_assignment()` and treat that assignment as the
   scope.
4. If claim fails because the lease is paused, another active owner exists, or
   the local ledger scope mismatches, stop and ask the architect or operator to
   repair that state. Do not request raw secrets.
5. Read `read_context()`, `read_task_plan()`, findings, progress,
   acceptance, review, and handoff virtual resources.
6. Update the virtual task plan with
   `update_task_plan({"expected_version": <read version>, "nodes": [...]})`.
   Omit a node `id` only to create it with a required `title`; use the
   returned server-owned `id` for updates. Use `pending`, `in_progress`,
   `done`, or `skipped`.
7. Stop and ask the architecture agent if dependency evidence, permission
   grants, or source context are missing.
8. If you need guidance, ask the parent or architect through ordinary agent
   messaging. State the decision, evidence checked, impact, and candidate
   options with pros/cons when you can supply them.

During coding:
1. Keep changes tightly scoped to this package.
   Treat linked work-package and WorkRequest ids as product/audit context
   unless a tool explicitly asks for a delivery closeout, successor, repair, or
   concurrency-protection target.
2. Append meaningful discoveries with `append_finding(finding, idempotency_key)`.
3. Append implementation and validation events with
   `append_progress(event, idempotency_key)`.
4. Use the worker-scoped MCP comment tools `add_comment`, `list_comments`, and
   `resolve_comment` when package-scoped implementation comments should stay
   visible in the cockpit.
5. Use comments for ordinary parent-agent coordination. If execution is
   blocked, call `report_blocker(summary, idempotency_key, blocker_id?)` and
   resolve only that same worker-owned blocker with
   `resolve_blocker(blocker_id, resolution, summary, idempotency_key)`.
   Architect-owned human blockers and guidance remain architect/operator work.
6. Use `request_scope_expansion(summary, idempotency_key, payload)` instead of
   silently expanding scope.
7. Do not create local planning files as the WorkPackage source of truth.
8. Do not use broad Linear/GitHub state as permission authority.

Human-facing bodies, notes, findings, progress details, blockers, and guidance
context are Markdown. Keep titles, ids, statuses, branch names, and PR metadata
plain.

Before ready:
1. Run relevant validation.
   For a Review Suite requirement, build a concise Markdown `review_brief`
   from the available WorkPackage title, engineering scope, allowed file scope,
   and acceptance criteria. Include stop conditions only when the assignment
   context supplies them. Add the parent title and goal only as intent, never
   as broader authority. Pass it through Review Suite's ordinary interface.
2. Attach branch metadata with `attach_branch(head_sha)` when the package
   branch pattern is literal; pass `branch` only when the pattern is templated
   or absent.
3. Open the PR and attach it with `attach_pr(url, head_sha)` when the policy
   requires PR metadata. Include current check, review, or merge metadata there
   when it is already available.
4. Refresh current state only for the attached PR with zero-state-argument
   `sync_pr()`. Use explicit PR identity only to repair a missing attachment;
   put manual canonical state only in the validated `recovery` import.
5. Submit validation evidence with
   `submit_review_package(summary, tests, artifacts)`. Policy-approved no-PR
   work may omit branch/head metadata; PR-backed or review-required work must
   use its current exact head.
6. If `review.md` declares a review requirement, consume and classify its
   provider-neutral structured result. Call `complete_review(reference?, note?)`
   only after accepting a terminal result for the current exact head.
   Use bounded `CONTINUE` only while the package contract is unchanged; return
   findings, contract ambiguity, `REPLAN`, or `RESLICE` to the architect
   without calling `complete_review`.
7. Call `mark_ready()` only after acceptance criteria, tests, required review,
   progress, findings, branch/PR evidence, and blockers are settled. Do not add
   lifecycle calls only to restate existing evidence. Resolve worker-owned
   blockers with `resolve_blocker`; architect-owned human blockers still
   require the architect or trusted local operator.

Final output:
- PR URL and final head SHA.
- Tests/validation run with results.
- Review evidence and anchors.
- Files changed.
- Residual risks or explicit out-of-scope items.
