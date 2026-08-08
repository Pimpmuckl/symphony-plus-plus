# Development

## Toolchain

The Elixir project pins its toolchain through `elixir/mise.toml`.

```powershell
mise trust .\elixir\mise.toml
Push-Location .\elixir
mise install
mise exec -- mix deps.get
Pop-Location
```

## Main Gate

Run the repository gate from the root:

```powershell
make all
```

For the fast Elixir-only loop, run `make -C elixir all`.

Frontend-only iteration can use:

```powershell
Push-Location .\elixir\assets
npm test
npm run quality
npm run build
Pop-Location
```

## Performance

The MCP release gate is:

```powershell
pwsh -NoProfile -File .\scripts\benchmarks\sympp-mcp\run-performance-gate.ps1
```

It uses isolated ports, homes, databases, caches, and temporary directories.
It must not touch the default dashboard ports, installed plugin state, shared
ledger, existing sessions, or credentials.

Backend startup probes:

```powershell
pwsh -NoProfile -File .\scripts\benchmarks\sympp-startup\measure.ps1
pwsh -NoProfile -File .\scripts\benchmarks\sympp-startup\measure.ps1 -Release
```

Dashboard measurements and the realistic focus-board journey live under
`scripts/benchmarks/sympp-dashboard/`.

## Release Discipline

- Validate the exact pull-request head.
- Keep runtime contract identity synchronized with the live MCP catalog.
- Build marketplace artifacts from the intended source revision.
- Treat installed-cache and fresh-session validation as release/cutover work,
  not ordinary feature-branch development.
- Do not mutate the user's installed plugin or running daemon during tests.

See [Runtime](runtime.md) for installed artifact ownership and repair.

## Documentation Changes

Document only current behavior. Update the owning skill when agent procedure
changes, the code/tests when behavior changes, and these docs when the human
model changes. Do not add migration diaries or completed implementation plans
to the active tree.
