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
3. Call `get_current_assignment()` from the stable worker catalog and treat
   that assignment as the scope. Claim and release do not require another
   tool-list refresh.
4. If claim fails because the lease is paused, another active owner exists, or
   the local ledger scope mismatches, stop and ask the architect or operator to
   repair that state. Do not request raw secrets.
5. Read `read_context()`, findings, progress, acceptance, review, and handoff
   virtual resources. Read and update the task plan only when it contains
   useful execution context.
6. Stop and ask the architecture agent if dependency evidence, permission
   grants, or source context are missing.
7. If you need guidance, ask the parent or architect through ordinary agent
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
5. Send execution problems to the supervising parent through ordinary
   collaboration or the final worker message. Use comments only when the
   package note should remain in S++. Workers do not create or resolve human
   blockers.
6. Do not create local planning files as the WorkPackage source of truth.
7. Do not use broad Linear/GitHub state as permission authority.

Human-facing bodies, notes, findings, progress details, and guidance
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
5. If `review.md` declares a review requirement, consume and classify its
   provider-neutral structured result. Keep the result in the provider and
   final handoff; Symphony++ does not require a duplicate completion call.
   Use bounded `CONTINUE` only while the package contract is unchanged; return
   findings, contract ambiguity, `REPLAN`, or `RESLICE` to the architect.
6. Call `mark_ready()` after provider-backed branch/PR state, required
   review, human blockers, and investigation findings are settled. Do not add
   task-plan or progress calls only to restate work proved
   elsewhere. Human blockers require the architect or trusted local operator.

Final output:
- PR URL and final head SHA.
- Tests/validation run with results.
- Review evidence and anchors.
- Files changed.
- Residual risks or explicit out-of-scope items.
