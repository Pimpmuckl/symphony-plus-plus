repo_root = Path.expand("../../..", __DIR__)
Code.require_file(Path.join(repo_root, "elixir/test/support/work_package_factory.exs"))

import Ecto.Query, only: [from: 2]

defmodule SymphonyPlusPlusStateHotPathTelemetry do
  @moduledoc false

  def handle(_event, _measurements, metadata, {table, key}) do
    operation = :persistent_term.get(key, :setup)
    sequence = System.unique_integer([:monotonic, :positive])
    query = to_string(metadata.query || "")
    result = inspect(Map.get(metadata, :result))
    :ets.insert(table, {sequence, operation, query, result})
  end
end

alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, HTTPStateStore, HTTPTransport, Repository, Server, Session}
alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
alias SymphonyElixir.SymphonyPlusPlus.Repo
alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
alias SymphonyElixir.WorkPackageFactory
alias SymphonyElixirWeb.{Endpoint, MCPHTTPPlug}

{:ok, _apps} = Application.ensure_all_started(:ecto_sqlite3)
{:ok, _apps} = Application.ensure_all_started(:phoenix)

database = WorkPackageFactory.database_path()
original_endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])
original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
original_dynamic_repo = Repo.get_dynamic_repo()

Application.put_env(:symphony_elixir, :sympp_repo_database, database)

Application.put_env(
  :symphony_elixir,
  Endpoint,
  Keyword.merge(original_endpoint_config,
    sympp_repo: Repo,
    sympp_repo_root: repo_root,
    sympp_dashboard_origin: "http://127.0.0.1:4000"
  )
)

{:ok, repo_pid} = Repo.start_link(database: database, name: Repo.process_name(database), pool_size: 1, log: false)
Repo.put_dynamic_repo(repo_pid)
:ok = Repository.ensure_migrated(Repo)

if Process.whereis(HTTPStateStore) == nil do
  {:ok, _store_pid} = HTTPStateStore.start_link()
end

HTTPStateStore.reset!()

config =
  Config.default(
    mode: :http,
    repo: Repo,
    database: database,
    health_ledger_mode: :configured_identity,
    local_daemon_trusted: true
  )

query_table = :ets.new(:sympp_state_hot_path_queries, [:ordered_set, :public])
operation_key = {__MODULE__, :operation}
handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
query_event = Repo.config()[:telemetry_prefix] ++ [:query]

:ok =
  :telemetry.attach(
    handler_id,
    query_event,
    &SymphonyPlusPlusStateHotPathTelemetry.handle/4,
    {query_table, operation_key}
  )

percentile = fn samples, fraction ->
  sorted = Enum.sort(samples)
  index = max(ceil(length(sorted) * fraction) - 1, 0)
  Enum.at(sorted, index)
end

measure = fn operation, count, fun ->
  :persistent_term.put(operation_key, operation)

  start_sequence =
    case :ets.last(query_table) do
      :"$end_of_table" -> 0
      sequence -> sequence
    end

  samples =
    for index <- 1..count do
      started = System.monotonic_time(:microsecond)
      :ok = fun.(index)
      (System.monotonic_time(:microsecond) - started) / 1_000
    end

  end_sequence =
    case :ets.last(query_table) do
      :"$end_of_table" -> 0
      sequence -> sequence
    end

  rows =
    query_table
    |> :ets.tab2list()
    |> Enum.filter(fn {sequence, _row_operation, _query, _result} ->
      sequence > start_sequence and sequence <= end_sequence
    end)

  write_statements =
    Enum.count(rows, fn {_sequence, _row_operation, query, _result} ->
      Regex.match?(~r/^\s*(INSERT|UPDATE|DELETE|REPLACE)\b/i, query)
    end)

  busy_retries =
    Enum.count(rows, fn {_sequence, _row_operation, _query, result} ->
      String.contains?(String.downcase(result), "busy") or String.contains?(String.downcase(result), "locked")
    end)

  %{
    "samples" => count,
    "p50_ms" => Float.round(percentile.(samples, 0.50), 3),
    "p95_ms" => Float.round(percentile.(samples, 0.95), 3),
    "max_ms" => Float.round(percentile.(samples, 1.00), 3),
    "sql_statements" => length(rows),
    "write_statements" => write_statements,
    "busy_retries" => busy_retries
  }
end

query_rows = fn operation ->
  query_table
  |> :ets.tab2list()
  |> Enum.filter(fn {_sequence, row_operation, _query, _result} -> row_operation == operation end)
  |> Enum.sort_by(&elem(&1, 0))
end

state_cardinality = fn ->
  state = :sys.get_state(HTTPStateStore)

  %{
    "entries" => map_size(state.entries),
    "aliases" => map_size(state.aliases),
    "deadlines" => state |> Map.get(:deadlines, %{}) |> map_size()
  }
end

initialize_payload = fn id ->
  %{
    "jsonrpc" => "2.0",
    "id" => id,
    "method" => "initialize",
    "params" => %{
      "protocolVersion" => "2025-03-26",
      "clientInfo" => %{"name" => "state-hot-path-benchmark", "version" => "1"},
      "capabilities" => %{}
    }
  }
end

health_payload = fn id ->
  %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => "sympp.health", "arguments" => %{}}}
end

readiness_before = state_cardinality.()

readiness_latency =
  measure.(:readiness, 100, fn index ->
    conn =
      :get
      |> Plug.Test.conn("/mcp/readiness")
      |> Map.put(:host, "localhost")
      |> Map.put(:port, 4000)
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> MCPHTTPPlug.call([])

    if conn.halted and conn.status == 200 do
      readiness = Jason.decode!(conn.resp_body)

      unless readiness["status"] == "ok" and get_in(readiness, ["ledger", "reachable"]) == true do
        raise "stateless readiness probe was not healthy"
      end
    else
      client_key = "legacy-readiness-#{index}"
      {:ok, initialized} = HTTPTransport.handle(config, initialize_payload.("readiness-init-#{index}"), client_key: client_key)

      {:ok, healthy} =
        HTTPTransport.handle(config, health_payload.("readiness-health-#{index}"),
          client_key: client_key,
          state_key: initialized.state_key
        )

      unless get_in(healthy.response, ["result", "structuredContent", "status"]) == "ok" do
        raise "legacy MCP readiness probe was not healthy"
      end
    end

    :ok
  end)

readiness_after = state_cardinality.()

HTTPStateStore.reset!()
recovery_client = "steady-recovery-client"
{:ok, recovery_init} = HTTPTransport.handle(config, initialize_payload.("recovery-init"), client_key: recovery_client)

recovery_latency =
  measure.(:recovery_steady, 100, fn index ->
    {:ok, result} =
      HTTPTransport.handle(config, health_payload.("recovery-health-#{index}"),
        client_key: recovery_client,
        state_key: recovery_init.state_key
      )

    unless get_in(result.response, ["result", "structuredContent", "status"]) == "ok" do
      raise "steady recovery health request failed"
    end

    :ok
  end)

server_call = fn operation, session, payload ->
  measure.(operation, 20, fn index ->
    request = payload.(index)
    response = Server.handle(request, Server.new(config, initialized: true, session: session))
    if is_map(response) and Map.has_key?(response, "error"), do: raise("#{operation} failed: #{inspect(response["error"])}")
    :ok
  end)
end

{:ok, worker_package} =
  WorkPackageRepository.create(
    Repo,
    WorkPackageFactory.attrs(id: "SYMPP-PERF-WORKER", kind: "mcp", status: "ready_for_worker")
  )

{:ok, worker_minted} = AccessGrantService.mint_worker_grant(Repo, worker_package.id)
{:ok, worker_assignment} = AccessGrantService.claim(Repo, worker_minted.work_key.secret, claimed_by: "perf-worker")
worker_session = Session.new(worker_assignment, proof_hash: worker_minted.grant.secret_hash)

worker_read_latency =
  server_call.(:worker_read, worker_session, fn index ->
    %{
      "jsonrpc" => "2.0",
      "id" => "worker-read-#{index}",
      "method" => "tools/call",
      "params" => %{"name" => "get_current_assignment", "arguments" => %{}}
    }
  end)

worker_write_latency =
  server_call.(:worker_write, worker_session, fn index ->
    %{
      "jsonrpc" => "2.0",
      "id" => "worker-write-#{index}",
      "method" => "tools/call",
      "params" => %{
        "name" => "append_progress",
        "arguments" => %{"summary" => "Worker write #{index}", "idempotency_key" => "perf-worker-write-#{index}"}
      }
    }
  end)

{:ok, phase} = PhaseRepository.create(Repo, %{id: "phase-perf-architect", title: "Performance architect phase"})

{:ok, architect_package} =
  WorkPackageRepository.create(
    Repo,
    WorkPackageFactory.attrs(
      id: "SYMPP-PERF-ARCHITECT",
      kind: "mcp",
      phase_id: phase.id,
      status: "planning"
    )
  )

{:ok, architect_minted} =
  AccessGrantService.mint_architect_grant(Repo, phase.id,
    work_package_id: architect_package.id,
    capabilities: ["read:phase", "write:work_request"]
  )

{:ok, architect_assignment} =
  AccessGrantRepository.claim(
    Repo,
    architect_minted.work_key.secret,
    %{claimed_by: "perf-architect"},
    DateTime.utc_now(:microsecond)
  )

architect_session = Session.new(architect_assignment, proof_hash: architect_minted.grant.secret_hash)

architect_read_latency =
  server_call.(:architect_read, architect_session, fn index ->
    %{
      "jsonrpc" => "2.0",
      "id" => "architect-read-#{index}",
      "method" => "tools/call",
      "params" => %{"name" => "get_current_assignment", "arguments" => %{}}
    }
  end)

architect_write_latency =
  server_call.(:architect_write, architect_session, fn index ->
    %{
      "jsonrpc" => "2.0",
      "id" => "architect-write-#{index}",
      "method" => "tools/call",
      "params" => %{
        "name" => "add_comment",
        "arguments" => %{
          "target_kind" => "work_package",
          "target_id" => architect_package.id,
          "body" => "Architect comment #{index}"
        }
      }
    }
  end)

{:ok, guard_package} =
  WorkPackageRepository.create(
    Repo,
    WorkPackageFactory.attrs(id: "SYMPP-PERF-READY-GUARD", kind: "mcp", status: "ready_for_worker")
  )

{:ok, guard_minted} = AccessGrantService.mint_worker_grant(Repo, guard_package.id)
{:ok, guard_assignment} = AccessGrantService.claim(Repo, guard_minted.work_key.secret, claimed_by: "perf-ready-guard")
guard_session = Session.new(guard_assignment, proof_hash: guard_minted.grant.secret_hash)

{1, nil} =
  Repo.update_all(
    from(work_package in WorkPackage, where: work_package.id == ^guard_package.id),
    set: [status: "ready_for_merge"]
  )

now = DateTime.utc_now(:microsecond)

history_rows =
  for sequence <- 1..1_000 do
    %{
      id: "progress-perf-guard-#{sequence}",
      work_package_id: guard_package.id,
      summary: "Historical progress #{sequence}",
      status: "recorded",
      sequence: sequence,
      idempotency_scope: "direct",
      payload: %{},
      created_at: now,
      inserted_at: now,
      updated_at: now
    }
  end

{1_000, nil} = Repo.insert_all(ProgressEvent, history_rows)

ready_guard_latency =
  measure.(:ready_guard_1000, 1, fn _index ->
    response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "ready-guard",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_progress",
            "arguments" => %{"summary" => "Rejected", "idempotency_key" => "perf-ready-guard"}
          }
        },
        Server.new(config, initialized: true, session: guard_session)
      )

    unless get_in(response, ["error", "data", "reason"]) == "already_ready" do
      raise "ready guard did not reject a ready package"
    end

    :ok
  end)

ready_guard_queries = query_rows.(:ready_guard_1000)

lock_index =
  Enum.find_index(ready_guard_queries, fn {_sequence, _operation, query, _result} ->
    String.starts_with?(query, "UPDATE \"sympp_work_packages\"") and String.contains?(query, "SET \"id\"")
  end)

if is_nil(lock_index), do: raise("ready guard package lock query was not observed")
guard_tail = Enum.drop(ready_guard_queries, lock_index + 1)

operation_latencies = %{
  readiness: readiness_latency,
  recovery_steady: recovery_latency,
  worker_read: worker_read_latency,
  worker_write: worker_write_latency,
  architect_read: architect_read_latency,
  architect_write: architect_write_latency,
  ready_guard_1000: ready_guard_latency
}

operations =
  Map.new(operation_latencies, fn {operation, metrics} -> {Atom.to_string(operation), metrics} end)

result = %{
  "operations" => operations,
  "readiness_state" => %{
    "before" => readiness_before,
    "after" => readiness_after,
    "entry_growth" => readiness_after["entries"] - readiness_before["entries"],
    "alias_growth" => readiness_after["aliases"] - readiness_before["aliases"],
    "deadline_growth" => readiness_after["deadlines"] - readiness_before["deadlines"]
  },
  "ready_guard" => %{
    "history_rows" => 1_000,
    "package_reads_after_lock" =>
      Enum.count(guard_tail, fn {_sequence, _operation, query, _result} ->
        String.contains?(query, "FROM \"sympp_work_packages\"")
      end),
    "history_reads_after_lock" =>
      Enum.count(guard_tail, fn {_sequence, _operation, query, _result} ->
        String.contains?(query, "FROM \"sympp_progress_events\"")
      end)
  }
}

IO.write(Jason.encode!(result))

:telemetry.detach(handler_id)
:persistent_term.erase(operation_key)
Repo.put_dynamic_repo(original_dynamic_repo)
GenServer.stop(repo_pid)
Application.put_env(:symphony_elixir, Endpoint, original_endpoint_config)

if is_nil(original_database) do
  Application.delete_env(:symphony_elixir, :sympp_repo_database)
else
  Application.put_env(:symphony_elixir, :sympp_repo_database, original_database)
end

File.rm(database)
