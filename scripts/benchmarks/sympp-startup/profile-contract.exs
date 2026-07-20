alias SymphonyElixir.SymphonyPlusPlus.MCP.Health

samples =
  case System.argv() do
    [value] -> String.to_integer(value)
    [] -> 101
  end

if samples < 1, do: raise(ArgumentError, "sample count must be positive")

measure = fn ->
  started = System.monotonic_time()
  identity = Health.mcp_contract_identity()
  elapsed = System.monotonic_time() - started
  {System.convert_time_unit(elapsed, :native, :microsecond) / 1_000, identity}
end

{first_ms, identity} = measure.()
warm_ms = for _ <- 1..samples, do: elem(measure.(), 0)
sorted = Enum.sort(warm_ms)

IO.puts(
  Jason.encode!(%{
    fingerprint: identity["fingerprint"],
    first_ms: first_ms,
    warm_samples: samples,
    warm_p50_ms: Enum.at(sorted, div(samples, 2)),
    warm_min_ms: hd(sorted),
    warm_max_ms: List.last(sorted)
  })
)
