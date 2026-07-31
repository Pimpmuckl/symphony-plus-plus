# Symphony++ dashboard load benchmark

This benchmark exports the deterministic realistic graph fixture, serves it through an isolated cockpit, and records API response duration and bytes plus browser time-to-usable, focus-board expansion and large-graph collapse, and refresh. Each browser sample uses a new context.

From `elixir/`, create the fixture:

```powershell
$env:MIX_ENV = "test"
mise exec -- mix run ../scripts/benchmarks/sympp-dashboard/fixture.exs ../scripts/benchmarks/sympp-dashboard/fixture.sqlite3
```

Start the isolated fixture server:

```powershell
$env:MIX_ENV = "dev"
mise exec -- mix compile
Push-Location assets
npm ci
npm run build
Pop-Location
mise exec -- mix run --no-start ../scripts/benchmarks/sympp-dashboard/serve.exs ../scripts/benchmarks/sympp-dashboard/fixture.sqlite3 20051
```

In another terminal, from the repository root:

```powershell
node scripts/benchmarks/sympp-dashboard/measure.mjs --url http://127.0.0.1:20051/sympp/board?operator_bootstrap=fixture-benchmark --samples 25
```

Pass `--details` to include every raw sample. Run the same commands at the baseline and candidate revisions. Report medians with the sample count; do not compare warm and cold server cohorts.

Pass repeatable `--limit metric=value` arguments to fail after printing the JSON when a summary metric exceeds its limit. Supported metrics are `cold` or `refresh` plus `api_ms_p50`, `browser_usable_ms_p50`, `bytes_p50`, or `request_count`, for example:

```powershell
node scripts/benchmarks/sympp-dashboard/measure.mjs --url http://127.0.0.1:20051/sympp/board?operator_bootstrap=fixture-benchmark --samples 25 --limit cold.bytes_p50=200000
```

The weekly canary retains detailed measurements without limits. Current-main fixture runs produce variable byte and request counts, so no deterministic ceiling is enforced yet. Timing also remains observational until three comparable hosted runs establish stability.

Profile backend assembly, JSON encoding, response bytes, and the largest serialized fields against the same fixture:

```powershell
$env:MIX_ENV = "test"
mise exec -- mix run ../scripts/benchmarks/sympp-dashboard/profile.exs ../scripts/benchmarks/sympp-dashboard/fixture.sqlite3 11
```
