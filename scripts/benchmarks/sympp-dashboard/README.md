# Symphony++ dashboard load benchmark

This benchmark exports the deterministic realistic graph fixture, serves it through an isolated cockpit, and records API response duration and bytes plus browser time-to-usable for cold load and refresh. Each browser sample uses a new context.

From `elixir/`, create the fixture:

```powershell
$env:MIX_ENV = "test"
mix run ../scripts/benchmarks/sympp-dashboard/fixture.exs -- ../scripts/benchmarks/sympp-dashboard/fixture.sqlite3
```

Start the isolated fixture server:

```powershell
$env:MIX_ENV = "dev"
mix run --no-start ../scripts/benchmarks/sympp-dashboard/serve.exs -- ../scripts/benchmarks/sympp-dashboard/fixture.sqlite3 20051
```

In another terminal, from the repository root:

```powershell
node scripts/benchmarks/sympp-dashboard/measure.mjs --url http://127.0.0.1:20051/sympp/board?operator_bootstrap=fixture-benchmark --samples 25
```

Pass `--details` to include every raw sample. Run the same commands at the baseline and candidate revisions. Report medians with the sample count; do not compare warm and cold server cohorts.
