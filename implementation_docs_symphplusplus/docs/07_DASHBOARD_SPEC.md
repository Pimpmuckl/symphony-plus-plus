# Dashboard Specification

## Goal

Give the human overseer fast situational awareness without reading agent transcripts.

## Local Operator Mode

Start the local operator cockpit from `elixir/` with:

```powershell
mix sympp.cockpit --dashboard-origin http://spp.localhost:19999
```

The launcher binds to `127.0.0.1:19998` by default, prints
`http://spp.localhost:19999/sympp/board` when a dashboard origin is supplied,
does not open a browser unless `--open-dashboard` or `SYMPP_OPEN_DASHBOARD=1`
is set, enables `sympp_local_operator: true`, and serves Streamable HTTP MCP at
`http://127.0.0.1:19998/mcp`. Pass `--port 0` for
an OS-assigned port during manual or test runs, or `--port <n>` for a different
stable port. Omit `--database` to use the shared local ledger at
the preferred `$HOME/.agents/splusplus/symphony_plus_plus.sqlite3` or
`%USERPROFILE%\.agents\splusplus\symphony_plus_plus.sqlite3` home, falling back
under a temp/relative `.agents/splusplus` root if home is unavailable; pass
`--database <ledger.sqlite3>` only for isolation, tests, or manual experiments.

When the Phoenix endpoint is configured with `sympp_local_operator: true`, the
local browser dashboard can open `/sympp/board` as the operator cockpit without
first entering a board work key. This mode is for the human machine owner
inspecting local Symphony++ state and creating or managing local WorkRequests
before WorkPackages exist.

For live React dashboard development, register the friendly local hostname once
from an elevated PowerShell session if Windows does not already resolve it:

```powershell
.\scripts\register-spp-localhost.ps1
```

Then start the API bridge and Vite shell as separate processes:

```powershell
cd elixir
mix sympp.cockpit --dashboard-origin http://spp.localhost:19999

cd assets
npm run dev
```

The Vite shell binds to `127.0.0.1:19999`, accepts `spp.localhost`, and redirects
`http://spp.localhost:19999/` to `/sympp/board`.

Local operator mode:

- requires a direct loopback request to a local host name with browser Fetch
  Metadata;
- rejects forwarded/proxy headers for operator entry;
- renders redacted dashboard projections only;
- shows `/sympp/work-requests/new` with explicit repo and base branch fields;
- lets the local operator create draft WorkRequests and use a human-owned
  `Start agent questions` action to move draft requests to
  `ready_for_clarification`;
- lets the local operator dispatch approved, undispatched WorkPackages into
  WorkPackages through the ledger-backed local assignment claim flow;
- lets the local operator prepare/replay a WorkRequest architect handoff with a
  scoped phase, architect anchor package, unclaimed architect grant, and
  non-secret local architect claim metadata;
- lets the local operator add and resolve contextual comments on WorkRequests,
  WorkPackages, and WorkPackages from detail views;
- shows package guidance requests that need human input in the operator
  priority watchlist and lets the local operator answer only
  `human_info_needed` guidance from the WorkPackage detail page;
- records local operator WorkRequest answers with the stable actor label
  `local-operator`;
- records local browser work-package dispatch grants with the stable worker
  identity `local-operator-worker`;
- keeps board-grant WorkRequest intake locked to the grant's frozen repo/base
  scope and ignores submitted repo/base values in board-grant mode;
- preserves explicit `?auth=work_key` paths for grant-scoped board and package
  views.

This is not a worker/agent permission grant. Worker and architect write access
still comes from scoped MCP grants and ledger-backed assignment claims.

## Views

### Board view

V3 local operator mode defaults to a product-tree board:

```text
Repository group
|-- collapsed WorkRequest row
|   |-- optional product plan node
|   |   |-- optional product plan node
|   |   `-- WorkPackage rows
|   `-- direct WorkPackage rows
```

The collapsed WorkRequest row is the first-glance product progress unit. It
shows request title, repo/base branch, plan-node count, slice count, guidance
count, blocker count, completion percentage, and operational state. Expanding a
row renders optional nested product plan nodes and direct or linked planned
slices. WorkPackages are opened from linked slice/package details when a human
needs execution evidence; they are not the primary product rows.

Product plan nodes are optional. Simple hotfixes may render as one WorkRequest
with direct slices and a compact unplanned note until an architect adds
structure. Larger product implementations can use arbitrary nesting; the UI
must not require a fixed `layer -> capability` hierarchy.

Legacy/package execution views may still expose raw WorkPackage lifecycle lanes
for audit and recovery. Those lanes use the raw package statuses below and must
not override the product-tree board as the default human cockpit.

Columns:

```text
created
ready_for_worker
claimed
planning
implementing
reviewing
ci_waiting
ready_for_merge
ready_for_architect_merge
merged
blocked
abandoned
```

Card fields:

```text
WorkPackage ID
Title
Kind
Repo/base branch
Assigned agent run
Last progress timestamp
PR link
CI/review status
Active blocker count
Scope guard status
Plan completion
Open/total comment count
```

WorkPackage card payloads preserve the raw lifecycle `status` for backend
control and board grouping. They also include a read-only `operational_state`
projection for human delivery truth:

```text
key
label
tone
reason
raw_status
has_started
has_active_worker
last_activity_at
is_stale
attention_items
```

The projection is derived from raw package status, active blockers, worker or
runtime activity, progress events, PR/review/readiness evidence, and merge
metadata. Active blockers override otherwise healthy-looking cards to blocked
operational truth and add an attention item. Contradictions, including merged
PR metadata while a package remains open or merge-ready, ready packages missing
readiness evidence, or `ready_for_worker` packages with delivery activity, are
reported as `attention_items` instead of changing raw lifecycle status.
Historical activity is separate from currently active work: terminal AgentRun
or runtime history, old progress, or metadata evidence may set `has_started`
and project as `Started / Paused` or `Needs Attention`, while `Active` is
reserved for visible active worker, AgentRun, or runtime evidence.

WorkPackage card and detail payloads also include a backend-derived `lineage`
projection. It is recorded as explicit operational lineage evidence, not inferred
from titles or prose. The v1 payload includes:

```text
original_work
successor_work
superseded_by
recut_as
oracle_for
oracle_work
oracle_status
available
unavailable
cleanup_attention
```

Lineage relationships are limited to `superseded_by`, `recut_as`, and
`oracle_for`. Each entry carries source and target WorkPackage ids, branch
snapshots, current package statuses when available, reason text, decision
linkage, recorded event id/time, and the oracle-preserved flag. Cleanup
attention is projected when original work that points to a successor still has
an open raw lifecycle status, including from the successor side. If lineage
storage cannot be read, the backend reports an explicit unavailable lineage
payload and warning attention instead of returning the empty no-lineage shape.
Scoped board payloads only serialize relationships where both the source and
target WorkPackage are already visible in that board scope.

WorkRequest-owned WorkPackage payloads project `operational_state` from the same
canonical row plus its runtime and delivery evidence. A planned package projects
as planned; dispatch activates that row as `ready_for_worker`. Active,
started/paused, attention, review, merge-ready, merged, and blocked states remain
visible without joining a second identity.

WorkRequest-led delivery closeout is projected through the backend delivery
board. Delivery closeout, not raw package status alone, is the source of
human delivery truth after work lands. A stale `ready_for_worker` package can
project as `Needs Closeout`
from structured merged-PR evidence before closeout, then as `Delivered`,
`Completed Without PR`, `Superseded`, or `Abandoned` after closeout while raw
status remains available for audit.

WorkRequest, work-package, and WorkPackage projections may include
`comment_count`, `open_comment_count`, and `comments` detail arrays. Comment
bodies, author names, resolver names, and resolution notes are redacted in
dashboard projections. Cards show an attention signal only when comments remain
open; detail views show the scoped comment list and local operator add/resolve
controls. The local operator mutation surface stamps operator provenance
server-side, caps comment bodies at 4,000 characters and resolution notes at
1,000 characters, and returns at most 100 comments per target in detail arrays.
Dashboard detail views render human-facing long text as Markdown, including
WorkRequest descriptions, comments, guidance context, decision rationale/scope
impact, findings, progress bodies, blockers, and no-PR evidence. Raw HTML from
Markdown is not rendered; compact labels, statuses, ids, branch names, PR URLs,
and badges remain plain text.

Local operator cockpit stream rail:

- Local operator mode renders a compact Projects / Work Streams rail above the
  operator priority summary.
- Streams are repo/base-branch pairs derived from local WorkPackages,
  WorkRequests, package guidance requests, and Solo Sessions. Each stream shows
  compact counts for package, request-side work, and solo-session surfaces;
  package guidance requests count with request-side work.
- Selecting a stream is stream-first navigation: it sets the repo and
  base-branch query filters for the whole cockpit and clears package-only
  `kind` and `phase` filters. This prevents request-only or solo-only streams
  from looking empty because of stale package filters.
- After a stream is selected, the toolbar remains available for explicit
  intersections such as selecting a package kind, phase, or editing the visible
  base-branch filter.
- `Show All` clears all cockpit filters and restores the complete local
  cockpit.
- Pin and unpin controls store pinned stream ids in browser `localStorage`.
  Pins only affect local visual priority/highlight; they are not persisted to
  the Symphony++ ledger, MCP state, or any backend schema.
- Board-grant mode does not render the stream rail or depend on browser-local
  pins.

### Work package detail

Sections:

```text
Overview
Product outcome
Engineering scope
Acceptance criteria
Guidance requests
Virtual task plan
Findings
Progress timeline
Comments
Artifacts
Branch/PR state
Review-suite state
Grant/agent run state
Controls
```

Controls should start minimal:

```text
Pause package
Revoke grant
Request replan
Approve/deny scope expansion
Mark abandoned
```

Do not add dangerous controls like merge-to-main until Phase 7+ and branch protection is proven.

The WorkPackage detail guidance section shows package guidance request status,
summary, question, context, requester, blocker id, escalation language, and any
recorded answer. In local operator mode, a request in `human_info_needed`
renders a compact answer form. Submitting it records the answer with
`answered_by = local-operator`, moves the guidance request to answered, and
records a matching blocker resolution event so the existing readiness gate no
longer fails on that guidance blocker. Ordinary open guidance remains an
architect responsibility and is not answerable from the local cockpit.
Board-grant and package-grant views can inspect safe guidance fields but cannot
submit guidance answers.

### WorkRequest intake and detail

`/sympp/work-requests` lists visible WorkRequests. In local operator mode it
shows all local WorkRequests plus a `New WorkRequest` action. In board-grant
mode it remains filtered by the grant's board scope.

WorkRequest cards and detail payloads preserve raw lifecycle `status` and also
include `operational_state` with the same projection shape as WorkPackages.
The WorkRequest projection aggregates work-package and linked WorkPackage
truth so a request with active, reviewing, merge-ready, merged, blocked, or
paused package work no longer presents `ready_for_slicing` as its primary human
state. Raw WorkRequest status remains available for controls and lifecycle
transitions. Grant-scoped WorkRequest list and detail responses promote only
WorkPackages that remain inside the grant's frozen repo/base scope;
out-of-scope packages are treated as unavailable instead of leaking hidden package
state.

Local operator dashboard refresh applies the operator archive-age setting to
completed WorkRequests and to terminal root WorkPackages with no WorkRequest,
parent, or phase relationship. Stale standalone root packages are hidden from the
active board during refresh; manual package hides remain stored in the local
hidden-package list. WorkRequest-owned or parent/phase packages remain visible
for their WorkRequest, parent, or phase retention path.

The delivery-board projection is the closeout detail source for WorkRequest-led
delivery. It shows per-WorkPackage delivery outcomes, closeout evidence summaries,
package raw status, attention reason codes, successor links, and counts
such as `needs_closeout`. Dashboard clients should display those backend
projections rather than deriving delivery truth from package cards or decision
text.

`/sympp/work-requests/new` behaves differently by mode:

- local operator mode requires the operator to enter repo and base branch
  explicitly;
- board-grant mode displays the locked repo/base branch and server-side creation
  uses only the frozen grant scope.

The intake form captures common constraints through structured fields for
allowed paths, forbidden paths, compatibility stance, validation expectations,
dependencies or notes, and stop conditions. Those values are stored in the
existing WorkRequest constraints map. Advanced JSON remains available for
uncommon constraint keys and complex shapes.

`/sympp/work-requests/:id` exposes WorkRequest controls based on product
ownership. In local operator mode, the page stays human-owned: the operator can
start agent questions for a draft request, answer product questions,
prepare/replay an architect handoff, inspect architect-owned context, and
dispatch approved slices. It does not expose architect authoring controls for
questions, decisions, or WorkPackages.

Scoped board-grant detail remains the architect/planning surface:

```text
Mark ready for clarification
Ask / answer / close clarification questions
Record decisions
Mark human info needed
Mark ready for slicing
Add / approve / skip WorkPackages
Mark sliced
```

Local operator detail keeps this smaller action set:

```text
Start agent questions
Answer open human questions
Prepare architect handoff
Dispatch approved WorkPackages
```

Architect handoff is local-operator-only and appears for WorkRequests in
`ready_for_clarification`, `clarifying`, `human_info_needed`,
`ready_for_slicing`, or `sliced`. It creates or reuses the WorkRequest-scoped
phase and architect anchor WorkPackage, mints an unclaimed architect grant with
WorkRequest/guidance capabilities, and stores the secret through private
handoff. Repeated use replays the existing active unclaimed handoff when
possible, otherwise reuses the same phase/anchor and renews the unclaimed grant.
Active handoff metadata that can be safely proven stale is retired before
renewal; missing or otherwise unverifiable metadata fails closed rather than
minting a duplicate active grant.
On reload, local-operator detail may display an already prepared active
unclaimed handoff only when the existing metadata is safely readable and
replayable; the load-time path is read-only and does not mint, renew, revoke, or
clean up handoffs.
The panel may show WorkRequest id, phase id, anchor package id, grant display
metadata, capability/scope metadata, redacted handoff coordinates, and the
plugin skill prompt. It must not show raw grant secrets, secret hashes, or
full MCP secret-retrieval commands. Board-grant WorkRequest detail does not show
or run this control.

WorkPackage dispatch is local-operator-only. Package authoring stays in the
architect workflow; dispatch is the explicit operator action that activates the
planned canonical WorkPackage. It reuses the existing `WorkPackageDispatch`
flow to update that row, create its worker grant and resources, return
ledger-backed local assignment bootstrap metadata, and refresh the page
with the WorkPackage id/status. It does not prepare worktrees or record
worktree scope; operators must complete the separate worktree preparation flow
before launching a worker. The browser may show only non-secret claim metadata
such as WorkPackage id, repo/base, optional WorkRequest id, claim owner, and
the prepared branch/worktree/caller id values after they exist. It must not
show raw worker secrets, secret-bearing commands, or private-store payloads.
Dispatch does not spawn Codex agents and does not call Linear.
Board-grant WorkRequest detail remains scoped to planning controls and does not
show the local dispatch control.

The WorkPackage detail handoff panel reads durable non-secret bootstrap
metadata from the ledger. The panel may show claim rows for non-expired,
non-revoked worker grants, but it must present `claim_local_assignment` with
the WorkPackage id and optional `claimed_by` only. It must not emit helper
script commands, private-store payloads, or raw grant material.

### Runtime view

Show:

```text
Active runs
Queued packages
Retry state
Last heartbeat
Workspace path
Orchestrator events
Recent failures
```

## Readiness indicators

Use distinct indicators for:

```text
Agent says ready
Review suite says ready
GitHub says ready
Architect says ready
Human says ready
```

Do not collapse these into one boolean.

## V3 Product Tree

The current V3 cockpit contract is documented in:

```text
implementation_docs_symphplusplus/docs/V3_PRODUCT_TREE_REWORK.md
```

Execution Atlas remains historical design context only. The implemented V3
direction is the WorkRequest product tree: optional nested product plan nodes,
WorkPackages as execution units, and WorkPackages as linked execution/audit
evidence. Dashboard changes should preserve raw ledger truth while making the
product tree the default operator reading order.
