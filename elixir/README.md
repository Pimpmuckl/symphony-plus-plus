# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Solo Sessions

Symphony++ Solo Sessions provide local planning memory for one repo/worktree
without creating WorkRequests, WorkPackages, Linear state, worker grants, or
dispatch. Agents can use the Mix task directly against a SQLite ledger;
successful command output is JSON, while failures exit non-zero with normal
`Mix.Error` messages:

```bash
mix sympp.solo attach \
  --repo nextide/symphony-plus-plus \
  --base-branch main \
  --workspace-path /path/to/worktree \
  --caller-id codex-local \
  --title "Solo CLI pass"
```

Record and read entries with the returned `solo_session.id`:

```bash
mix sympp.solo progress \
  --session-id <solo-session-id> \
  --summary "Implemented CLI surface" \
  --body "Added attach, progress, show, list, and lifecycle commands." \
  --idempotency-key solo-cli-progress-1

mix sympp.solo validation \
  --session-id <solo-session-id> \
  --summary "Focused tests passed" \
  --result passed \
  --command "mix test test/mix/tasks/sympp_solo_test.exs" \
  --idempotency-key solo-cli-validation-1

mix sympp.solo show --session-id <solo-session-id>
```

Entry commands are `plan`, `progress`, `finding`, `decision`, `blocker`,
`resolve-blocker`, and `validation`. Friendly status aliases such as `active`
and `done` are normalized by `plan`, `progress`, and `finding`; blockers use
`blocker` to open and `resolve-blocker` to clear. Validation records use the
typed `--result passed|failed|skipped|blocked|not_run`. The task also supports
`list` filters for `repo`, `base_branch`, `workspace_path`, `caller_id`, and
`status`, plus `pause`, `resume`, `complete`, and `archive` lifecycle verbs. If
`--database` is omitted, the task uses the shared machine-local Symphony++
default ledger, preferring `$HOME/.agents/splusplus/symphony_plus_plus.sqlite3`
(`%USERPROFILE%\.agents\splusplus\symphony_plus_plus.sqlite3` on Windows) and
falling back under a temp/relative `.agents/splusplus` root if home is
unavailable,
matching cockpit and WorkRequest/WorkPackage CLI defaults. The database must be
a durable local filesystem path; `:memory:` and SQLite `file:` URIs are
rejected because Solo Sessions must persist across CLI invocations. `attach`
may create the ledger database; other commands require the resolved local
database file to already exist. Pass `--database <sqlite-path>` only for
intentional isolation in tests, development, or manual experiments.

## WorkRequest Planned-Slice Dispatch

Normal Symphony++ WorkRequest planned-slice dispatch returns a ledger-backed
worker bootstrap instead of a private worker secret handoff. MCP responses expose
`worker_bootstrap`, and the Mix task includes the same data under
`create_work.worker_bootstrap`. The bootstrap uses `type: "ledger_claim"` and
`mode: "local_assignment"`, names the `claim_local_assignment` MCP claim path,
lists the required worker skills, and includes the resolved local ledger
database when dispatch can identify one.

Normal dispatch responses do not include a private handoff path, helper
command, or secret-retrieval metadata.

## Local Operator WorkRequest Notes

Trusted local HTTP MCP sessions may create WorkRequests and append non-secret
WorkRequest notes without claiming each WorkRequest as the owning architect.
The local-operator tools are:

- `add_work_request_comment`
- `list_comments`
- `record_work_request_operator_decision`

Both tools require an explicit local MCP state key, a trusted local daemon, and
a local filesystem ledger database. They remain visible with
`create_work_request` when the MCP wrapper is bound to a worker or architect
assignment, but they do not widen that assignment's package or WorkRequest
authority. They are rejected for remote/company database URLs. The tools reuse
the WorkRequest comment and decision services, store `source_type: "operator"`,
include caller provenance such as `created_by`, and apply the standard
redaction pass before persisting or returning note content.

Tool contracts are intentionally small: comments require `work_request_id`,
`body`, and `created_by`; decisions require `work_request_id`, `decision`,
`rationale`, `scope_impact`, and `created_by`, with optional `source_id`.
Unexpected, non-string, or overlong fields are rejected.

This path is note capture only. It does not grant dispatch, child-package
mutation, worker claim, status mutation, or lifecycle closeout authority.

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Symphony++ work package workflows can use `tracker.kind: Symphony_pp` (the lowercase
`symphony_pp` alias is also accepted) in a separate workflow file such as
`WORKFLOW.Symphony_pp.md`:

```md
---
tracker:
  kind: Symphony_pp
  assignee: "worker-1"
  active_states:
    - ready_for_worker
    - implementing
  terminal_states:
    - merged
    - closed
  filters:
    repos:
      - nextide/symphony-plus-plus
    base_branches:
      - origin/symphony-plus-plus/beta
    work_kinds:
      - adapter
workspace:
  root: ~/code/symphony-workspaces
codex:
  command: codex app-server
---

You are working on Symphony++ work package {{ issue.identifier }}.
```

Run it by passing the custom workflow path:

```bash
./bin/symphony /path/to/WORKFLOW.Symphony_pp.md
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- `tracker.kind: Symphony_pp` does not read Linear fallback secrets. Set `tracker.assignee` to the
  worker actor id that owns claimed Symphony++ worker grants.
- For Symphony++ workflows, `tracker.filters.repos`, `tracker.filters.base_branches`, and
  `tracker.filters.work_kinds` restrict which work packages can be exposed to dispatch. Empty
  lists mean no restriction for that dimension; use explicit filters when a workflow must stay
  scoped to one repo, base branch, or work kind.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

`make all` is the fast PR gate: format, specs, Credo, and fast tests. It is
quiet by default, prints one line per step, and writes full logs to
`_build/make-logs/`. Run `make all VERBOSE=1` to stream Mix output while
debugging.

Use split targets when validating one gate at a time:

```bash
make ci-static
make ci-test
make ci-dialyzer
make ci-coverage
```

Use `make ci-full` before release-style handoff when you need coverage and
Dialyzer in one local command.

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
