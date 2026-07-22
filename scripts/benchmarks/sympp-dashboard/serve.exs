[database, port] = System.argv()
Logger.configure(level: :warning)

dashboard_index = Path.expand("../../../elixir/priv/static/index.html", __DIR__)

dashboard_built? =
  case File.read(dashboard_index) do
    {:ok, html} -> String.contains?(html, ~s(type="module"))
    {:error, _reason} -> false
  end

unless dashboard_built? do
  raise "Built dashboard assets missing. Compile dev first, then run npm ci and npm run build from elixir/assets."
end

Mix.Tasks.Sympp.Cockpit.run_cockpit_for_test(
  [
    host: "127.0.0.1",
    port: String.to_integer(port),
    database: Path.expand(database),
    open_dashboard: false,
    operator_bootstrap_token: "fixture-benchmark"
  ],
  fn -> Process.sleep(:infinity) end
)
