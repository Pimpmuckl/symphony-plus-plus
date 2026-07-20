[database, port] = System.argv()
Logger.configure(level: :warning)

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
