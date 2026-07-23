# Symphony++ Repository Conventions

## Work Package PRs

- Use one Symphony++ work package per PR unless the overseeing architecture agent explicitly splits or combines scope.
- Keep each worker branch scoped to its assigned package and ignore sibling worktrees or branches.
- Use PR titles in the form `[SYMPP-...] <title>`.
- Fill `.github/pull_request_template.md` concretely, including acceptance evidence, tests run, and any blocked validation.
- Do not implement dependent packages or adjacent cleanup unless the architecture agent explicitly expands scope.
- A WorkRequest is the product-facing unit. Optional Groups organize larger
  plans, while canonical WorkPackages carry bounded worker execution and audit
  evidence from planning through delivery.

## Documentation And Planning Assets

- Treat `docs/` as the current human-facing product and operator guide.
- Treat packaged `plugins/**/skills/**/SKILL.md` files as the authoritative
  agent procedures. Link to them instead of copying their workflows into docs.
- Use the WorkPackage ledger, MCP resources, and package-specific assignment
  text as the source of truth for worker scope, acceptance, validation, and
  readiness evidence.
- Use Git history for completed designs, cutovers, and experiments. Do not keep
  active archive or migration-diary documents.

## Worker Prompt Conventions

- Keep worker prompts short and outcome-first: state the package goal, success criteria, constraints, available evidence, and required final output.
- For tool-heavy work, use brief preambles before tool calls so the operator can see the next step and why it matters.
- Include explicit dependency checks, missing-evidence behavior, validation loops, stopping conditions, and safety checks before external side effects.
- Avoid process-heavy prompt stacks or verbose formatting unless the extra structure improves comprehension.

## Runtime Boundary

- Preserve upstream Symphony and Linear behavior unless the assigned package explicitly changes it.
- Do not replace `elixir/WORKFLOW.md` with the Symphony++ draft workflow template.
- Do not wire unfinished Symphony++ config into runtime defaults.
- Do not create live Linear state unless the assigned package and operator explicitly require it.
- For production-like Symphony++ MCP cutovers, the running plugin runtime must
  resolve from the installed plugin/marketplace cache, not from the local source
  checkout, worktree, or `.sympp-source-root` hint. Normal Codex plugin use is
  `codex plugin marketplace upgrade` plus a fresh session. Use `SYMPP_REPO_ROOT`
  only for explicit developer validation, never as the installed-agent runtime
  path.
- Do not refresh, pin, or validate the installed Symphony++ MCP plugin cache
  from `C:\Code\symphony-plus-plus` for an agent-ready runtime. That checkout is
  a developer workspace and can diverge from the marketplace source clone under
  `C:\Users\jonat\.codex\.tmp\marketplaces\symphony-plus-plus`. A mixed cache can
  make fresh Codex sessions fail MCP startup with a closed `initialize` response,
  for example when `.sympp-source-revision` in the installed cache says one commit
  but the marketplace clone reports another. For installed-cache repair/cutover,
  run the marketplace-backed upgrade/cutover/refresh path from the marketplace
  source clone, or explicitly document that the session is checkout-backed debug
  only.

## Security

- Never commit, print, or place raw API keys, bearer tokens, GitHub tokens, Linear tokens, MCP auth tokens, or worker secrets in files, prompts, logs, PR bodies, or review text.
- Document missing secret-dependent validation as blocked rather than substituting real token values.
