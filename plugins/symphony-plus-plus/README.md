# Symphony++ Codex Plugin

This plugin exposes Symphony++ MCP-free planning skills as a local Codex
plugin: Solo Session memory, the baseline worker playbook, and the lightweight
coordinator playbook. The default plugin package is physically MCP-free: it
must not ship a root `.mcp.json` and its manifest is skill-only. The sibling
`symphony-plus-plus-mcp` package owns the bundled MCP startup file and the full
MCP-mode skill set for dedicated S++ workflows. The canonical source for the runtime remains this
repository; the plugin cache under `~/.codex/plugins/cache/...` is generated
install state.

## Install

For normal use, install and update Symphony++ through the Codex marketplace:

```powershell
codex plugin marketplace add https://github.com/Pimpmuckl/symphony-plus-plus --ref main
codex plugin marketplace upgrade
```

Then install the default skill-only plugin with the active marketplace name:

```powershell
codex plugin add symphony-plus-plus@symphony-plus-plus
```

Do not point an installed plugin at a developer checkout or worktree. Use the
local source path below only for isolated plugin development:

```json
{
  "name": "symphony-plus-plus",
  "source": {
    "source": "local",
    "path": "./plugins/symphony-plus-plus"
  },
  "policy": {
    "installation": "AVAILABLE",
    "authentication": "ON_USE"
  },
  "category": "Developer Tools"
}
```

The committed repo marketplace at `.agents/plugins/marketplace.json` uses the
repo-root-relative source path `./plugins/symphony-plus-plus` for the default
skill-only plugin and also exposes the opt-in MCP companion at
`./plugins/symphony-plus-plus-mcp`.
The local refresh helper is for isolated development Codex homes only; it
refuses the default `~/.codex` cache unless explicitly overridden.

To inspect installed cache readiness, use the lifecycle doctor from the
installed package or a source checkout:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -MarketplaceName symphony-plus-plus -Doctor
```

Restart or reload Codex after a marketplace upgrade so the refreshed skill list
and manifest metadata are loaded. Existing Codex sessions can continue using
already-loaded plugin
metadata.

For isolated development Codex homes, the refresh script writes a local
Codex marketplace source snapshot under
`<codex-home>/.tmp/marketplaces/<marketplace>` and the
GitHub-marketplace-shaped manifest-version cache directory, for example
`~/.codex/plugins/cache/<marketplace>/symphony-plus-plus/<version>`, and prunes the
older generated `local` cache root when it carries the script's
`.sympp-generated-cache` marker after the versioned cache has been written and,
when requested, validated. Local refresh also writes a non-secret
`.sympp-source-revision` marker so launchers can keep strict source matching
when a future Codex host shell lacks `git` on `PATH`. Unmarked `local`
directories stop refresh with a manual cleanup message instead of being deleted
or silently ignored. Because the default package must be
MCP-inert even if a host scans cache-root `.mcp.json` files directly, refresh
also repairs generated default-cache entries in place by removing stale root
`.mcp.json` files and stripping stale manifest `mcpServers` declarations. It
also prunes removed managed package entries, including stale skill directories
inside refreshed versioned cache roots. It does not delete superseded version
directories. Cleanup is scoped to generated
`~/.codex/plugins/cache/<marketplace>/symphony-plus-plus/*` cache entries;
manual scratch directories without generated-entry markers are left alone.
If an existing cache parent, cache directory, or child path is a junction or
symlink, refresh stops with a manual cleanup message instead of recursively
deleting or copying through the link.

## MCP Lifecycle And Explicit Use

The default `symphony-plus-plus` plugin is intentionally skill-only: its
manifest does not declare `mcpServers`. Do not add a bundled generic MCP server
to this default plugin. Current Codex host behavior can eagerly start
plugin-bundled MCP servers for generic sessions, review-suite lanes, and
`codex review` calls whenever the plugin is enabled; that creates needless S++
Elixir process churn when the session does not explicitly need S++ tools.
The default manifest points at the standard root `skills/` directory, which
contains only MCP-free base skills: Solo Session, worker, and coordinator. The
MCP-dependent WorkPackage and architect skills ship only in the sibling opt-in
MCP plugin.

The default plugin source and refreshed default cache must not contain root
`.mcp.json`. Planned-slice WorkPackage workers should use the ledger-backed
`claim_local_assignment` metadata emitted by Symphony++ dispatch. Dedicated
plugin-based S++ MCP sessions can install the sibling
`plugins/symphony-plus-plus-mcp` package in an explicit Codex config or
alternate Codex home. Do not enable that opt-in MCP plugin in a generic/global
config unless every session on that config should start S++ MCP.

The target installed-runtime product contract for that opt-in companion lives in
the source repository operator docs as `docs/runtime.md`. It
defines the future verified release-artifact flow, release-channel gating,
manifest fields, static dashboard asset expectations, source-checkout fallback
semantics, and operator diagnostics. Installed plugin cache copies of this
README are self-contained: the current launcher still resolves a compatible
source checkout or marketplace source clone and is documented below as today's
behavior, not as the final artifact-backed install path.

The preferred MCP runtime shape is a singleton local HTTP daemon, not one
stdio Elixir tree per Codex session. A dogfood snapshot on Windows with the
local cockpit already running showed the unbound `tools/list` response at about
2.6 KB, roughly 650 token-equivalent by a simple chars/4 estimate, and local
initialize plus `tools/list` handshakes averaging about 19 ms across ten
samples, with the warm samples around 8-14 ms after one cold 105 ms sample. On
the Chocolatey Elixir install, the singleton listener appeared as a tiny parent
`erl.exe` launcher around 2 MB plus one real `erl.exe` VM around 25 MB working
set. That is small enough for dedicated S++ sessions; the remaining product
choice is tool visibility in generic sessions, not daemon CPU churn.

Repo validation proves only the plugin package contract:

- `.codex-plugin/plugin.json` does not declare `mcpServers`, and root
  `.mcp.json` is absent, so enabling the default plugin does not ask Codex to
  start S++ MCP in generic/review sessions.
- `plugins/symphony-plus-plus-mcp/.mcp.json` defines a command-backed generic
  `symphony_plus_plus` launcher using a documented direct server map, not a
  nested `mcpServers` object, for explicit opt-in use. Each plugin MCP process
  is a lightweight stdio bridge into a local HTTP runtime. The launcher reuses a
  healthy runtime when its advertised `source_revision` exactly matches the
  launcher-resolved commit, starts a new managed runtime for a new commit, and
  lets older managed runtimes drain until their bridge leases exit.
- `scripts/refresh-local-plugin.ps1` is limited to isolated development cache
  refreshes by default. It removes stale managed default-cache
  `.mcp.json` files, strips stale manifest `mcpServers` from generated default
  cache entries, prunes removed managed skill directories, and writes a
  `.sympp-generated-cache` marker for local developer cache refreshes.
- `scripts/refresh-local-plugin.ps1 -ValidateInstalledCache` validates the
  isolated cache copies, confirms the default manifest remains skill-only,
  confirms default cache roots do not contain `.mcp.json`, checks the opt-in
  `symphony_plus_plus` command-backed launcher entry, and validates the Solo
  Session wrapper from each cache root.
- `plugins/symphony-plus-plus/scripts/diagnose-mcp-lifecycle.ps1 -Doctor`
  compares installed cache fingerprints with the Codex marketplace snapshot so a
  same-version stale cache reports an explicit marketplace upgrade action instead of a
  shape-only ready result.
- `scripts/start-sympp-mcp.cmd -ValidateOnly` can resolve the checkout and
  launch through `pwsh.exe` or Windows PowerShell. Installed marketplace
  launchers discover the full marketplace source clone automatically; they do
  not require operators to set `SYMPP_REPO_ROOT`.
- `scripts/sympp-solo.ps1 -ValidateOnly` can resolve the checkout and validate
  the launcher without writing ledger state or requiring a source build.

Plugin skill visibility, explicit MCP configuration, global MCP settings
visibility, and current-session tool availability are separate states. Skill
visibility proves Codex loaded the skill directory. The default plugin should
stop there. An MCP configuration proves a session was intentionally given a
server dependency.
On Windows, when a plugin manifest does declare a generic S++ `mcpServers`
entry, current Codex host behavior can start a plugin stdio process for
each Codex app session, `codex exec`, `codex review`, resumed session, review
lane, or subagent that loads the enabled plugin. The opt-in companion keeps
that behavior scoped to dedicated S++ configs; a typical launcher tree is:

```text
cmd.exe /d /s /c scripts\start-sympp-mcp.cmd
  (background, logged) artifact runtime on <actual-backend-port>
```

That per-session startup is host-managed by a plugin `mcpServers` declaration.
The foreground process bridges stdio MCP to the backend HTTP `/mcp`, records a
local bridge lease while Codex is connected, and removes that lease when stdin
closes. Runtime identity is the exact S++ source revision plus the backend and
dashboard endpoints. New Codex sessions attach to a healthy matching runtime;
if the running runtime is for an older commit, the launcher starts a new
managed runtime and records a lease against that new runtime key. Runtime
output is redirected to the log paths recorded in the runtime file. When the
last bridge lease for a runtime key exits, the launcher stops only the managed
PIDs for that key whose command lines still match Symphony++. The backend
`/mcp/client-lease` endpoint is heartbeat telemetry for bridge pacing, not a
runtime shutdown authority.

For non-destructive lifecycle forensics, run the installed diagnostic from the
plugin root:

```powershell
.\scripts\diagnose-mcp-lifecycle.ps1
.\scripts\diagnose-mcp-lifecycle.ps1 -Doctor
.\scripts\diagnose-mcp-lifecycle.ps1 -Json
.\scripts\diagnose-mcp-lifecycle.ps1 -MarketplaceName symphony-plus-plus -Json
.\scripts\diagnose-mcp-lifecycle.ps1 -RepoRoot C:\Code\symphony-plus-plus -Json
.\scripts\diagnose-mcp-lifecycle.ps1 -SkipProcessScan -Json
.\scripts\diagnose-mcp-lifecycle.ps1 -CodexHome <dedicated-codex-home> -MarketplaceName symphony-plus-plus -EnableMcpCompanion
.\scripts\diagnose-mcp-lifecycle.ps1 -SelfTest
```

The diagnostic reports installed cache versions, manifest lifecycle status,
root `.mcp.json` presence/shape, legacy source-root hints when present, whether
the plugin is enabled in Codex config, whether a global `[mcp_servers.symphony_plus_plus]`
entry exists, whether opt-in cache `.mcp.json` defines the expected
`symphony_plus_plus` command-backed launcher, and focused live process counts for
`start-sympp-mcp.ps1`,
`mix.bat sympp.mcp`, and `erl.exe sympp.mcp`.
By default it scans every `symphony-plus-plus` marketplace cache under the
Codex home; pass `-MarketplaceName` to narrow cache and config checks to one
marketplace. Default cache entries that still declare `mcpServers` or still
contain a root `.mcp.json` are reported as
`incompatible_default_plugin_bundles_mcp`, and missing manifests are reported as
`missing_manifest`.
Use it to distinguish stale installed caches, explicit MCP sessions, and
host-managed eager startup from duplicated marketplace entries. If the default
skill-only plugin is upgraded and a fresh Codex host still starts S++ MCP for
generic or review sessions, file a product issue for lazy or opt-in-only plugin
MCP startup with the diagnostic JSON attached as evidence.
Use `-Doctor` when the operator symptom is "I see the Symphony++ skill but no
`symphony_plus_plus` MCP tools." The doctor adds a readiness summary that
separates default Solo Session readiness from WorkRequest MCP readiness. The
common healthy-default/missing-tools state is
`solo_ready_mcp_companion_not_enabled`: the skill-only
`symphony-plus-plus@<marketplace>` plugin is installed, but the
`symphony-plus-plus-mcp@<marketplace>` companion is not installed for the
current Codex session. The next action is to install the companion from the
dedicated S++ MCP Codex home:

```powershell
codex plugin add symphony-plus-plus-mcp@symphony-plus-plus
```

After it succeeds, restart or reload that dedicated session and keep generic
workers, review-suite lanes, and `codex review` on the clean skill-only
default.
The doctor verifies marketplace/cache/config plus local HTTP daemon readiness. It
cannot inspect the tool list already registered inside an open Codex model
session, so after config/cache changes the final repair step is always to
restart or reload the dedicated MCP-enabled session and verify the tools there.
For installed plugin cache repair, the doctor tells the operator to run
`codex plugin marketplace upgrade`. It no longer uses `.sympp-source-root`
hints as repair authority. Source checkouts are used only when explicitly
provided with `-RepoRoot` or when the diagnostic itself is being run from a
checkout for developer validation.
If more than one Symphony++ marketplace cache is installed and no
`-MarketplaceName` is supplied, the doctor does not emit package-specific repair
commands; rerun it with the intended marketplace. If it reports
`global_footgun_present`, remove or relocate the top-level
`[mcp_servers.symphony_plus_plus]` entry into a dedicated S++ config instead of
leaving it in generic worker/review configs.
Live process counts are scoped to `-RepoRoot` when supplied. Without
`-RepoRoot`, the diagnostic scopes process scans only through the Codex
marketplace source clone matching the selected installed cache. Legacy
`.sympp-source-root` hints are reported but do not provide process-scan or
repair authority. Fresh MCP-free default caches do not provide implicit process
scope. Superseded version directories, missing manifests, malformed manifests,
and broken MCP entries are reported but do not provide implicit process scope.
If no valid marketplace scope is available, or if usable current caches point at
multiple marketplace clones, the scoped process scan is skipped instead of
reporting machine-wide processes for the selected Codex home.
When `-RepoRoot` supplies an explicit checkout scope, unmatched
`start-sympp-mcp.ps1` launchers are reported separately as unattributed so a
wrapper stuck before `mix` starts is visible without assigning it to another
checkout. The diagnostic rejects `-RepoRoot` values that do not resolve to a
checkout with `elixir/mix.exs`.
The live count includes the default direct `mix.bat` path and the opt-in
`mise exec -- mix` launcher path.
Use `-SkipProcessScan` when the operator or test only needs cache, config, and
readiness output and does not need a live `Win32_Process` inventory. Diagnostic
JSON sets `process_scan_performed` so skipped scans are explicit even though
live count fields remain numeric.
Malformed installed cache JSON is reported on the affected cache entry instead
of aborting the whole diagnostic.
On non-Windows hosts, the diagnostic still reports cache/config state and marks
the Windows process scan as unsupported.
The diagnostic truncates and redacts common secret-bearing command-line forms,
including bearer headers and `--token` or `--api-key` flag values; run
`-SelfTest` after editing that sanitizer.
The installed-cache validation proves the skill-only default package is
physically MCP-free and the opt-in MCP package still carries the explicit MCP
file and wrappers. It does not prove that an already-running Codex host has
reloaded plugin metadata. After refreshing the cache, reload Codex and open a
new session before treating old generic S++ MCP startup as a current package
failure. Do not work around missing explicit MCP tools by adding a global
`[mcp_servers]` entry to generic worker config.

### Default Planning And Opt-In MCP

Symphony++ remains the default durable planning substrate for real agents
without requiring default MCP startup. Ordinary implementation workers should
use `symphony-plus-plus:symphony-worker`, and ordinary parent agents should use
`symphony-plus-plus:symphony-coordinator`. Both can attach
`symphony-plus-plus:symphony-solo-session` plus `scripts/sympp-solo.ps1` for
task plans, findings, progress, blockers, decisions, validation notes, and
local ledger reads. That path is available from the default skill-only plugin
and does not require Codex to start or register the `symphony_plus_plus` MCP
server.

Heavy WorkPackage and architect orchestration still needs explicit MCP tools.
In dedicated MCP homes, the opt-in companion plugin starts or reuses managed
local servers automatically when Codex starts. Reuse is keyed by the exact
S++ source revision reported by MCP health, so marketplace/plugin updates can
start a new runtime while older sessions drain. For manual operation, start the local
cockpit/daemon:

```powershell
cd elixir
mix sympp.cockpit --dashboard-origin http://127.0.0.1:19999
```

By default it prints `http://127.0.0.1:19999/sympp/board` without opening a
browser and serves MCP at `http://127.0.0.1:19998/mcp`, backed by the shared
local Symphony++ default ledger, preferring
`$HOME/.agents/splusplus/symphony_plus_plus.sqlite3`
(`%USERPROFILE%\.agents\splusplus\symphony_plus_plus.sqlite3` on Windows) and
falling back under a temp/relative `.agents/splusplus` root if home is
unavailable. Pass `--open-dashboard` only for a deliberate browser launch, and
pass `--database <ledger.sqlite3>` only for isolation. Codex must load an MCP server
configuration before the model session starts for the tools to be registered in
that session. The
sibling `plugins/symphony-plus-plus-mcp` plugin is the bundled opt-in package
for dedicated configs and owns the command-backed launcher for that local HTTP
daemon and dashboard.

Before debugging Codex plugin visibility, verify the daemon itself from the
source repository checkout root. This helper is not copied into installed
plugin cache directories:

```powershell
.\scripts\smoke-sympp-mcp-http.ps1 -RepoRoot .
```

Use `-Url http://127.0.0.1:<port>/mcp` for a non-default cockpit port and
`-Json` for structured output. Passing this smoke means the local HTTP MCP
daemon initialized, preserved the returned `Mcp-Session-Id`, reported the same
source revision as the checkout, and advertised the expected generic tools.
Codex app plugin enabling/visibility is a separate startup/config step. If the
smoke reports `stale_or_unverified_daemon` or
`stale_daemon_source_revision_mismatch`, an old manual cockpit may still own
the port. Dedicated plugin launchers reuse local backends only when their MCP
health reports the same source revision.
If this smoke passes but a Codex session still lacks S++ MCP tools, run:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -MarketplaceName symphony-plus-plus -Doctor
```

The expected repair is config/session activation, not daemon debugging. Enable
the companion only in the dedicated S++ MCP config:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -CodexHome <dedicated-codex-home> -MarketplaceName symphony-plus-plus -EnableMcpCompanion
```

Then start a new/reloaded session so Codex registers the plugin MCP server
before the model starts.

Example explicit TOML for an opt-in S++ session:

```toml
[mcp_servers.symphony_plus_plus]
command = "cmd.exe"
args = ["/d", "/s", "/c", "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.cmd"]
cwd = "<repo>"
```

Once Codex supports profile-scoped MCP, the preferred product shape is a
`sympp-agent` profile that contains the same explicit server config and is used
only for S++ architect or worker launches, for example
`codex --profile sympp-agent -C <worktree> ...`. The default plugin should
remain skill/docs/lightweight so `codex review`, review-suite lanes, generic
workers, and unrelated `codex exec` calls do not start S++ MCP merely because
the plugin is installed.

The Windows desktop app currently has no proven per-thread S++ profile picker.
`codex app --help` exposes a workspace path and `-c` config overrides, while
`--profile` is only a global CLI option before the `app` subcommand. Even when
the launcher accepts that global flag, current Codex profile schema does not
support profile-scoped MCP servers, so do not design the user-visible app
cockpit around `codex --profile sympp-agent app <path>` as the mechanism for
registering S++ MCP tools in one visible desktop thread. The app-thread UX
should keep the default skill-only plugin and use Solo Session skill/CLI
planning; heavy S++ MCP orchestration should happen in a managed architect or
worker subprocess/app-server session launched with explicit top-level MCP
configuration before session start.

That managed subprocess is the supported replacement for app-visible
WorkPackage and architect execution when the desktop host cannot attach MCP
tools to one already-open thread. The visible cockpit thread records durable
planning state through Solo Session CLI entries, then launches or hands off to a
dedicated Codex CLI/app-server session whose startup config includes the
top-level `mcp_servers.symphony_plus_plus` entry or enables the sibling
`symphony-plus-plus-mcp` plugin in that dedicated config. The same
`symphony-work-package` and `symphony-architect` skills are usable in that
managed session because the tools are registered before the session starts.
Do not invoke those MCP-dependent skills from a generic visible app thread that
does not already show S++ MCP tools; use the Solo/cockpit handoff path instead.

The explicit MCP reference entry runs
`plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.cmd` through `cmd.exe`.
That wrapper prefers `pwsh.exe` and falls back to Windows PowerShell so hosts do
not need a hard-coded PowerShell executable in Codex MCP config.
When the plugin is executed from this source checkout, the wrapper can infer the
repository root. When it runs from an installed plugin cache, the wrapper uses
the Codex marketplace source clone that matches the installed payload and
ignores local source-root hints. Run `codex plugin marketplace upgrade` when the
installed payload is stale. Set `SYMPP_REPO_ROOT` only as a temporary override to the
Symphony++ source checkout containing `elixir/mix.exs`; it is not the
caller/task repository root. Set `SYMPP_DATABASE` only when the MCP server
should use a specific SQLite ledger instead of the runtime default.

The wrapper defaults to `SYMPP_LAUNCHER=mise` when the resolved Symphony++
checkout contains `elixir/mise.toml` and `mise exec -- mix --version` succeeds;
otherwise it falls back to running `mix` directly from `PATH`. Explicit
`SYMPP_LAUNCHER=direct` still works when `mix` resolves to a real Elixir
executable. If direct mode resolves to a mise shim, validation fails with
guidance to set `SYMPP_MIX` to a non-mise Mix executable or use
`SYMPP_LAUNCHER=mise` after trusting the checkout's mise config.

Unless `MIX_BUILD_ROOT` is set, plugin wrapper runs write generated Mix output
under `%USERPROFILE%\.agents\splusplus\build`, keyed by wrapper purpose,
launcher, and source revision. This keeps freshly refreshed marketplace source
builds from trying to remove `exqlite` NIF DLLs that are still loaded by older
running MCP companion processes on Windows.

Static plugin files must not contain raw worker secrets, private-store handoff
targets, bearer tokens, or one-off operator-local secret material.

## Solo Session Use

Normal single-agent Codex work can use the plugin-installed
`symphony-plus-plus:symphony-solo-session` skill for lightweight local planning
memory without WorkRequest, WorkPackage, Linear, architect handoff, or worker
dispatch semantics.

That skill uses `scripts/sympp-solo.ps1`, which resolves Symphony++ from the
source checkout during developer validation or from the Codex marketplace
snapshot in installed use, then passes commands through to `mix sympp.solo`
from the resolved `elixir/` directory. Use it to attach a local Solo Session,
record `plan`, `finding`, `progress`, `blocker`, `decision`, and `validation`
entries, read the ledger, and pause, resume, complete, or archive the session.
The Solo caller repository identity comes from the CLI arguments `--repo` and
`--workspace-path`; `SYMPP_REPO_ROOT` only locates the Symphony++ source
checkout used to run the wrapper.

The generic `symphony_plus_plus` MCP server also advertises first-slice Solo
tools for unbound sessions: `solo_attach`, `solo_show`, `solo_list`,
intent-shaped entry tools such as `solo_append_progress` and
`solo_record_validation`, and lifecycle verbs `solo_pause`, `solo_resume`,
`solo_complete`, and `solo_archive`. Bound worker or architect WorkPackage
sessions do not advertise those tools, and direct calls from bound sessions are
rejected before mutation. `solo_show` returns the latest 50 entries plus
count/truncation metadata. Use the CLI wrapper when the host has not loaded the
MCP entry or full ledger history is required.

When neither `--database` nor `SYMPP_DATABASE` is supplied, the wrapper lets
`mix sympp.solo` use the shared local Symphony++ default ledger, matching
cockpit and WorkRequest/WorkPackage CLI defaults in the preferred
`$HOME/.agents/splusplus/` home or the existing fallback root.
The wrapper resolves relative database overrides against the caller workspace
and restores the original current directory after invoking Mix.

Solo Session planning is explicitly separate from WorkPackage orchestration.
Use this default package for non-MCP Solo, worker, and coordinator sessions.
Use `symphony-plus-plus-mcp:symphony-worker` plus
`symphony-plus-plus-mcp:symphony-work-package` for the preferred packaged MCP
WorkPackage path. Downstream repos that copy only the repo-local
`symphony-work-package` skill should pair it with
`symphony-plus-plus:symphony-worker` and an explicit S++ MCP session. Use
`symphony-plus-plus-mcp:symphony-architect` for WorkRequest-led orchestration.
Solo Session entries must not include raw secrets, tokens, access-grant
verifiers, claim lease internals, or private grant material.
Solo entry bodies are human-facing Markdown; titles, statuses, repo names, and
other compact labels remain plain text.

## Worker And Coordinator Use

The default plugin owns the MCP-free worker and coordinator playbooks:

- `symphony-plus-plus:symphony-worker` for bounded implementation,
  investigation, docs, hotfix, validation, review, and PR readiness.
- `symphony-plus-plus:symphony-coordinator` for ordinary non-MCP parent agents
  that scout, slice, dispatch, supervise, and integrate one or more workers.

WorkPackage workers also use the opt-in MCP plugin together with the
Symphony++ local HTTP daemon. The operator creates or dispatches a WorkPackage,
and the worker receives the WorkPackage id plus optional stable `claimed_by`
identity.
Human-facing WorkRequest descriptions, comments, findings, progress bodies,
blocker notes, guidance context, and decision rationale/scope-impact text are
Markdown. Identifiers, titles, statuses, branch names, PR metadata, and badges
remain plain text.

The MCP WorkPackage skill then instructs the worker to load the current
assignment, read MCP-backed planning resources, update plan/findings/progress
through MCP, attach branch/PR/review evidence, and mark ready only after package
gates pass. Do not paste raw worker secrets into prompts, command lines, PR
bodies, review text, or durable logs.

Plugin install is not a substitute for a per-worker claim. Planned-slice worker
package dispatch should use the emitted ledger-backed
`claim_local_assignment` bootstrap with `work_package_id` and optional
`claimed_by` for exactly one WorkPackage.

## Architect Use

Architect agents use the plugin-installed
`symphony-plus-plus-mcp:symphony-architect` skill before worker dispatch. That skill
is for WorkRequest-led orchestration: read current WorkRequest or architect
package context, ask and record product clarification, record decisions and
assumptions, author/approve WorkPackages, dispatch approved slices, route
package guidance, and stop instead of inventing product behavior.
For higher-impact human choices, architects should include the existing
`decision_prompt` structure so the cockpit can show a TL;DR, details, bounded
options, tradeoffs, and the freeform redirect path. Plain questions remain
appropriate for simple missing facts.

Use `symphony-plus-plus-mcp:symphony-architect` when assigned a Symphony++
WorkRequest, product-tree planning lane, an architect WorkPackage, phase, or
feature orchestration. Dispatch worker prompts for MCP WorkPackages should name
the packaged MCP pair, `symphony-plus-plus-mcp:symphony-worker` and
`symphony-plus-plus-mcp:symphony-work-package`, or the repo-local fallback pair,
`symphony-plus-plus:symphony-worker` and copied `symphony-work-package`.

The architect skill expects the same secret hygiene as worker flow. It may
route workers to private-store handoff metadata, but static plugin docs and
prompts must not include raw work keys, bearer tokens, MCP auth tokens, GitHub
tokens, Linear tokens, private-store payloads, or full secret-bearing commands.
