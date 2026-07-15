repo_root = Path.expand("../../..", __DIR__)
Code.require_file(Path.join(repo_root, "elixir/test/support/work_package_factory.exs"))

defmodule SymphonyPlusPlusResponseListTelemetry do
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
alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.{ArchitectContext, WorkerContext}
alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Repository, Server, Session}
alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Node
alias SymphonyElixir.SymphonyPlusPlus.Repo
alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{RepoScope, WorkRequest}
alias SymphonyElixir.WorkPackageFactory

{:ok, _apps} = Application.ensure_all_started(:ecto_sqlite3)
{:module, ArchitectContext} = Code.ensure_loaded(ArchitectContext)
{:module, WorkerContext} = Code.ensure_loaded(WorkerContext)
database = WorkPackageFactory.database_path()
original_dynamic_repo = Repo.get_dynamic_repo()
{:ok, repo_pid} = Repo.start_link(database: database, name: Repo.process_name(database), pool_size: 1, log: false)
Repo.put_dynamic_repo(repo_pid)
:ok = Repository.ensure_migrated(Repo)

phase_id = "phase-response-list-perf"
repo_name = "nextide/symphony-plus-plus"
base_branch = "main"
now = DateTime.utc_now(:microsecond)

{:ok, _phase} = PhaseRepository.create(Repo, %{id: phase_id, title: "Response/list performance"})

{:ok, anchor} =
  WorkPackageRepository.create(
    Repo,
    WorkPackageFactory.attrs(
      id: "SYMPP-RESPONSE-LIST-PERF",
      kind: "mcp",
      repo: repo_name,
      base_branch: base_branch,
      phase_id: phase_id,
      status: "planning"
    )
  )

{:ok, minted} =
  AccessGrantService.mint_architect_grant(Repo, phase_id,
    work_package_id: anchor.id,
    capabilities: ["read:work_request"]
  )

{:ok, assignment} = AccessGrantService.claim(Repo, minted.work_key.secret, claimed_by: "response-list-perf")
session = Session.new(assignment, proof_hash: minted.grant.secret_hash)

list_rows =
  for index <- 1..1_000 do
    timestamp = DateTime.add(now, index, :microsecond)

    %{
      id: "WR-PERF-#{String.pad_leading(Integer.to_string(index), 4, "0")}",
      title: "Performance WorkRequest #{index}",
      repo: repo_name,
      base_branch: base_branch,
      work_type: "feature",
      human_description: "Measure authorized WorkRequest list response #{index}",
      constraints: %{},
      desired_dispatch_shape: "single_package",
      status: "ready_for_slicing",
      inserted_at: timestamp,
      updated_at: timestamp
    }
  end

{1_000, nil} = Repo.insert_all(WorkRequest, list_rows)

scope_rows =
  Enum.map(list_rows, fn row ->
    %{
      id: "WRRS-PERF-#{row.id}",
      work_request_id: row.id,
      repo: repo_name,
      base_branch: base_branch,
      scope_key: "repo:#{repo_name}:#{base_branch}",
      inserted_at: row.inserted_at,
      updated_at: row.updated_at
    }
  end)

{1_000, nil} = Repo.insert_all(RepoScope, scope_rows)

plan_id = "WR-PERF-PLAN"
plan_timestamp = DateTime.add(now, 2_000, :microsecond)

{1, nil} =
  Repo.insert_all(WorkRequest, [
    %{
      id: plan_id,
      title: "Large product plan",
      repo: repo_name,
      base_branch: base_branch,
      work_type: "feature",
      human_description: "Measure large read_plan response construction",
      constraints: %{},
      desired_dispatch_shape: "single_package",
      status: "draft",
      inserted_at: plan_timestamp,
      updated_at: plan_timestamp
    }
  ])

plan_nodes =
  for index <- 1..1_000 do
    %{
      id: "PTN-PERF-#{String.pad_leading(Integer.to_string(index), 4, "0")}",
      work_request_id: plan_id,
      title: "Plan item #{index}",
      description: String.duplicate("Measured product-plan detail. ", 6),
      node_kind: "task",
      completion_mark: "not_done",
      metadata: %{},
      position: index,
      created_by: "response-list-perf",
      created_at: plan_timestamp,
      inserted_at: DateTime.add(plan_timestamp, index, :microsecond),
      updated_at: DateTime.add(plan_timestamp, index, :microsecond)
    }
  end

{1_000, nil} = Repo.insert_all(Node, plan_nodes)

http_config =
  Config.default(
    mode: :http,
    surface_profile: :full,
    repo: Repo,
    database: database,
    repo_root: repo_root
  )

stdio_config = %{http_config | mode: :stdio}

request = fn id, name, arguments ->
  %{
    "jsonrpc" => "2.0",
    "id" => id,
    "method" => "tools/call",
    "params" => %{"name" => name, "arguments" => arguments}
  }
end

plan_request = request.("read-plan-perf", "read_plan", %{"work_request_id" => plan_id, "view" => "nodes_only"})
list_request = request.("list-work-requests-perf", "list_work_requests", %{"status" => "ready_for_slicing"})

server_call = fn config, payload ->
  Server.handle(payload, Server.new(config, initialized: true, session: session))
end

percentile = fn samples, fraction ->
  sorted = Enum.sort(samples)
  Enum.at(sorted, max(ceil(length(sorted) * fraction) - 1, 0))
end

measure = fn fun ->
  samples =
    for _index <- 1..8 do
      :erlang.garbage_collect()
      {:memory, memory_before} = :erlang.process_info(self(), :memory)
      {reductions_before, _} = :erlang.statistics(:reductions)
      started = System.monotonic_time(:microsecond)
      encoded = fun.() |> Jason.encode!()
      elapsed_us = System.monotonic_time(:microsecond) - started
      {reductions_after, _} = :erlang.statistics(:reductions)
      {:memory, memory_after} = :erlang.process_info(self(), :memory)

      %{
        elapsed_ms: elapsed_us / 1_000,
        bytes: byte_size(encoded),
        allocation_bytes: max(memory_after - memory_before, 0),
        reductions: reductions_after - reductions_before
      }
    end

  %{
    "bytes" => samples |> hd() |> Map.fetch!(:bytes),
    "p50_ms" => percentile.(Enum.map(samples, & &1.elapsed_ms), 0.50),
    "p95_ms" => percentile.(Enum.map(samples, & &1.elapsed_ms), 0.95),
    "allocation_bytes_p50" => percentile.(Enum.map(samples, & &1.allocation_bytes), 0.50),
    "reductions_p50" => percentile.(Enum.map(samples, & &1.reductions), 0.50)
  }
end

trace_encoders = fn fun ->
  :erlang.trace_pattern({ArchitectContext, :encode_tool_payload, 2}, true, [:call_count])
  :erlang.trace_pattern({WorkerContext, :encode_tool_payload, 1}, true, [:call_count])
  _result = fun.()
  {:call_count, architect_count} = :erlang.trace_info({ArchitectContext, :encode_tool_payload, 2}, :call_count)
  {:call_count, worker_count} = :erlang.trace_info({WorkerContext, :encode_tool_payload, 1}, :call_count)
  :erlang.trace_pattern({ArchitectContext, :encode_tool_payload, 2}, false, [:call_count])
  :erlang.trace_pattern({WorkerContext, :encode_tool_payload, 1}, false, [:call_count])
  %{"full" => architect_count, "canonical" => worker_count}
end

query_table = :ets.new(:sympp_response_list_queries, [:ordered_set, :public])
operation_key = {__MODULE__, :operation}
handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
query_event = Repo.config()[:telemetry_prefix] ++ [:query]

:ok =
  :telemetry.attach(
    handler_id,
    query_event,
    &SymphonyPlusPlusResponseListTelemetry.handle/4,
    {query_table, operation_key}
  )

:persistent_term.put(operation_key, :list_query_probe)
list_probe_response = server_call.(http_config, list_request)

query_rows =
  :ets.tab2list(query_table)
  |> Enum.filter(fn {_sequence, operation, _query} -> operation == :list_query_probe end)

list_payload = get_in(list_probe_response, ["result", "structuredContent"])
http_plan_probe = server_call.(http_config, plan_request)
stdio_plan_probe = server_call.(stdio_config, plan_request)

result = %{
  "fixture" => %{"plan_items" => 1_000, "work_requests" => 1_000, "repo_scopes" => 1_000},
  "read_plan" => %{
    "http" =>
      measure.(fn -> server_call.(http_config, plan_request) end)
      |> Map.put("text_encodes", trace_encoders.(fn -> server_call.(http_config, plan_request) end))
      |> Map.put("structured_nodes", http_plan_probe |> get_in(["result", "structuredContent", "product_tree", "nodes"]) |> length()),
    "legacy_full_stdio" =>
      measure.(fn -> server_call.(stdio_config, plan_request) end)
      |> Map.put("text_encodes", trace_encoders.(fn -> server_call.(stdio_config, plan_request) end))
      |> Map.put("structured_nodes", stdio_plan_probe |> get_in(["result", "structuredContent", "product_tree", "nodes"]) |> length())
  },
  "list_work_requests" =>
    measure.(fn -> server_call.(http_config, list_request) end)
    |> Map.merge(%{
      "returned" => length(list_payload["work_requests"]),
      "has_next_cursor" => is_binary(list_payload["next_cursor"]),
      "query_count" => length(query_rows),
      "work_request_queries" => Enum.count(query_rows, fn {_sequence, _operation, query} -> String.contains?(query, "FROM \"sympp_work_requests\"") end),
      "repo_scope_queries" => Enum.count(query_rows, fn {_sequence, _operation, query} -> String.contains?(query, "FROM \"sympp_work_request_repo_scopes\"") end)
    })
}

IO.write(Jason.encode!(result))

:telemetry.detach(handler_id)
:persistent_term.erase(operation_key)
Repo.put_dynamic_repo(original_dynamic_repo)
GenServer.stop(repo_pid)
File.rm(database)
