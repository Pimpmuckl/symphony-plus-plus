repo_root = Path.expand("../../..", __DIR__)
Code.require_file(Path.join(repo_root, "elixir/test/support/work_package_factory.exs"))

defmodule SymphonyPlusPlusToolCallLatencyTelemetry do
  @moduledoc false

  def handle(_event, _measurements, metadata, {table, operation_key}) do
    :ets.insert(table, {
      System.unique_integer([:monotonic, :positive]),
      :persistent_term.get(operation_key, :setup),
      to_string(metadata.query || "")
    })
  end
end

alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
alias SymphonyElixir.SymphonyPlusPlus.MCP.{Auth, Config, HTTPStateStore, Repository, Session}
alias SymphonyElixir.SymphonyPlusPlus.Repo
alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
alias SymphonyElixir.WorkPackageFactory
alias SymphonyElixirWeb.{Endpoint, MCPHTTPPlug}

sample_count = System.get_env("SYMPP_MCP_TOOL_CALL_SAMPLES", "100") |> String.to_integer()
database = WorkPackageFactory.database_path()
original_endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])
original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
original_migrated_databases = Application.get_env(:symphony_elixir, :sympp_board_live_migrated_databases)
original_dynamic_repo = Repo.get_dynamic_repo()

{:ok, _apps} = Application.ensure_all_started(:ecto_sqlite3)
{:ok, _apps} = Application.ensure_all_started(:bandit)
{:ok, _apps} = Application.ensure_all_started(:req)

Application.put_env(:symphony_elixir, :sympp_repo_database, database)

Application.put_env(
  :symphony_elixir,
  Endpoint,
  Keyword.merge(original_endpoint_config,
    sympp_repo: Repo,
    sympp_repo_root: repo_root,
    sympp_dashboard_origin: "http://127.0.0.1:0"
  )
)

{:ok, repo_pid} = Repo.start_link(database: database, pool_size: 1, log: false)
Repo.put_dynamic_repo(repo_pid)
:ok = Repository.ensure_migrated(Repo)
{:ok, %{rows: migrated_rows}} = Repo.query("SELECT version FROM schema_migrations", [])
migrated_versions = migrated_rows |> Enum.map(&(&1 |> hd() |> to_string())) |> MapSet.new()
true = MapSet.subset?(MapSet.new(Migrations.version_strings()), migrated_versions)

Application.put_env(
  :symphony_elixir,
  :sympp_board_live_migrated_databases,
  MapSet.new([{Repo, Repo.database_key(database)}])
)

{:ok, store_pid} = HTTPStateStore.start_link()

{:ok, work_package} =
  WorkPackageRepository.create(
    Repo,
    WorkPackageFactory.attrs(
      id: "SYMPP-MCP-TOOL-CALL-PERF",
      kind: "mcp",
      status: "ready_for_worker"
    )
  )

{:ok, minted} = AccessGrantService.mint_worker_grant(Repo, work_package.id)
{:ok, assignment} = AccessGrantService.claim(Repo, minted.work_key.secret, claimed_by: "tool-call-perf")

{:ok, lease} =
  ClaimLeaseService.claim(
    Repo,
    work_package.id,
    %{
      "actor_kind" => "agent",
      "actor_id" => "local:tool-call-perf",
      "actor_display_name" => "tool-call-perf"
    },
    access_grant_id: assignment.grant_id,
    stale_after_ms: :timer.minutes(5)
  )

session =
  assignment
  |> Session.new(proof_hash: minted.grant.secret_hash)
  |> Session.with_claim_lease(lease)

{:ok, bandit_pid} = Bandit.start_link(plug: MCPHTTPPlug, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
{:ok, {_address, port}} = ThousandIsland.listener_info(bandit_pid)
url = "http://127.0.0.1:#{port}/mcp"

request = fn payload, session_id ->
  headers = if session_id, do: [{"mcp-session-id", session_id}], else: []
  response = Req.post!(url, json: payload, headers: headers, receive_timeout: 30_000)
  body = response.body

  unless response.status == 200 and is_map(body) and not Map.has_key?(body, "error") do
    raise "MCP request failed: status=#{response.status} body=#{inspect(body)}"
  end

  response
end

initialize = %{
  "jsonrpc" => "2.0",
  "id" => "initialize",
  "method" => "initialize",
  "params" => %{
    "protocolVersion" => "2025-03-26",
    "clientInfo" => %{"name" => "tool-call-latency-benchmark", "version" => "1"},
    "capabilities" => %{}
  }
}

initialize_response = request.(initialize, nil)
session_id = initialize_response.headers |> Map.fetch!("mcp-session-id") |> List.first()
client_key = "__sympp_mcp_local_http_client__"

config =
  Config.default(
    mode: :http,
    repo: Repo,
    database: database,
    repo_root: repo_root,
    health_ledger_mode: :configured_identity,
    local_daemon_trusted: true
  )

server = HTTPStateStore.get(config, client_key, session_id)
:ok = HTTPStateStore.put(config, client_key, session_id, %{server | session: session})

payload = fn id, name, arguments ->
  %{
    "jsonrpc" => "2.0",
    "id" => id,
    "method" => "tools/call",
    "params" => %{"name" => name, "arguments" => arguments}
  }
end

health = fn index -> payload.("health-#{index}", "sympp.health", %{}) end
read = fn label, index -> payload.("read-#{label}-#{index}", "get_current_assignment", %{}) end

write = fn label, index ->
  payload.("write-#{label}-#{index}", "append_progress", %{
    "summary" => "Tool-call latency #{label} sample #{index}",
    "idempotency_key" => "tool-call-latency-#{label}-#{index}"
  })
end

for index <- 1..10, do: request.(health.("warm-#{index}"), session_id)
for index <- 1..10, do: request.(read.("warm", index), session_id)
for index <- 1..5, do: request.(write.("warm", index), session_id)

query_table = :ets.new(:sympp_tool_call_latency_queries, [:ordered_set, :public])
operation_key = {__MODULE__, :operation}
handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
query_event = Repo.config()[:telemetry_prefix] ++ [:query]

:ok =
  :telemetry.attach(
    handler_id,
    query_event,
    &SymphonyPlusPlusToolCallLatencyTelemetry.handle/4,
    {query_table, operation_key}
  )

percentile = fn samples, fraction ->
  sorted = Enum.sort(samples)
  Enum.at(sorted, max(ceil(length(sorted) * fraction) - 1, 0))
end

measure = fn variants, verify ->
  timings =
    for index <- 1..sample_count,
        {operation, build_payload, prepare, timed_prepare} <- if(rem(index, 2) == 0, do: Enum.reverse(variants), else: variants) do
      :persistent_term.put(operation_key, :setup)
      prepare.()
      :persistent_term.put(operation_key, operation)
      started = System.monotonic_time(:microsecond)
      timed_prepare.()
      response = request.(build_payload.(index), session_id)
      verify.(response.body)
      {operation, (System.monotonic_time(:microsecond) - started) / 1_000}
    end

  Map.new(variants, fn {operation, _build_payload, _prepare, _timed_prepare} ->
    samples = for {^operation, elapsed} <- timings, do: elapsed

    queries =
      query_table
      |> :ets.tab2list()
      |> Enum.filter(fn {_sequence, query_operation, _query} -> query_operation == operation end)
      |> Enum.map(&elem(&1, 2))

    write_count = Enum.count(queries, &Regex.match?(~r/^\s*(INSERT|UPDATE|DELETE|REPLACE)\b/i, &1))

    {operation,
     %{
       "samples" => sample_count,
       "p50_ms" => Float.round(percentile.(samples, 0.50), 3),
       "p95_ms" => Float.round(percentile.(samples, 0.95), 3),
       "max_ms" => Float.round(percentile.(samples, 1.00), 3),
       "sql_per_call" => Float.round(length(queries) / sample_count, 2),
       "writes_per_call" => Float.round(write_count / sample_count, 2)
     }}
  end)
end

health_metrics =
  measure.([{:health, health, fn -> :ok end, fn -> :ok end}], fn body ->
    unless get_in(body, ["result", "structuredContent", "status"]) == "ok", do: raise("health response changed")
  end).health

# Reproduce the removed costs in the before variants: a due heartbeat plus the
# middle grant/package/scope authorization that the handler immediately repeats.
age_lease = fn ->
  lease = Repo.get!(ClaimLease, lease.id)
  lease |> ClaimLease.update_changeset(%{last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -31, :second)}) |> Repo.update!()
end

read_metrics =
  measure.(
    [{:read_before, &read.("before", &1), age_lease, fn -> {:ok, _session} = Auth.require_session(session, Repo) end}, {:read_after, &read.("after", &1), fn -> :ok end, fn -> :ok end}],
    fn body ->
      unless get_in(body, ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id,
        do: raise("read response changed")
    end
  )

write_metrics =
  measure.(
    [{:write_before, &write.("before", &1), age_lease, fn -> {:ok, _session} = Auth.require_session(session, Repo) end}, {:write_after, &write.("after", &1), fn -> :ok end, fn -> :ok end}],
    fn body ->
      unless get_in(body, ["result", "structuredContent", "progress_event", "summary"]), do: raise("write response changed")
    end
  )

IO.write(
  Jason.encode!(%{
    "transport" => "isolated_loopback_http",
    "operations" => %{
      "health" => health_metrics,
      "scoped_read_before" => read_metrics.read_before,
      "scoped_read_after" => read_metrics.read_after,
      "scoped_write_before" => write_metrics.write_before,
      "scoped_write_after" => write_metrics.write_after
    }
  })
)

:telemetry.detach(handler_id)
:persistent_term.erase(operation_key)
GenServer.stop(bandit_pid)
GenServer.stop(store_pid)
Repo.put_dynamic_repo(original_dynamic_repo)
GenServer.stop(repo_pid)
Application.put_env(:symphony_elixir, Endpoint, original_endpoint_config)

if is_nil(original_database) do
  Application.delete_env(:symphony_elixir, :sympp_repo_database)
else
  Application.put_env(:symphony_elixir, :sympp_repo_database, original_database)
end

if is_nil(original_migrated_databases) do
  Application.delete_env(:symphony_elixir, :sympp_board_live_migrated_databases)
else
  Application.put_env(:symphony_elixir, :sympp_board_live_migrated_databases, original_migrated_databases)
end

File.rm(database)
