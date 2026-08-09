repo_root = Path.expand("../../..", __DIR__)
Code.require_file(Path.join(repo_root, "elixir/test/support/work_package_factory.exs"))
{:ok, _apps} = Application.ensure_all_started(:ecto_sqlite3)

import Ecto.Query, only: [from: 2]

alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Repository, as: ClaimLeaseRepository
alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
alias SymphonyElixir.SymphonyPlusPlus.MCP.LocalClaimLeases
alias SymphonyElixir.SymphonyPlusPlus.Repo
alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
alias SymphonyElixir.WorkPackageFactory

clients = 100
database = WorkPackageFactory.database_path()
original_dynamic_repo = Repo.get_dynamic_repo()
{:ok, repo_pid} = Repo.start_link(database: database, name: Repo.process_name(database), pool_size: 2, log: false)
Repo.put_dynamic_repo(repo_pid)

metrics =
  try do
    :ok = ClaimLeaseRepository.migrate(Repo)
    now = DateTime.utc_now(:microsecond)

    claims =
      for index <- 1..clients do
        id = "SYMPP-CONTENTION-#{index}"
        claimed_by = if index <= div(clients, 2), do: "worker-#{index}", else: "old-worker-#{index}"
        actor = LocalClaimLeases.worker_actor(%{work_package_id: id, claimed_by: claimed_by})
        stale? = index > div(clients, 2)

        {:ok, _package} =
          WorkPackageRepository.create(
            Repo,
            WorkPackageFactory.attrs(id: id, kind: "mcp", status: "ready_for_worker")
          )

        {:ok, _lease} =
          ClaimLeaseService.claim(Repo, id, actor,
            stale_after_ms: if(stale?, do: 1, else: 60_000),
            now: if(stale?, do: DateTime.add(now, -1, :second), else: now)
          )

        %{id: id, claimed_by: if(stale?, do: "worker-#{index}", else: claimed_by)}
      end

    parent = self()

    tasks =
      Enum.map(claims, fn claim ->
        Task.async(fn ->
          Repo.put_dynamic_repo(repo_pid)
          send(parent, {:ready, self()})

          receive do
            :go ->
              LocalClaimLeases.ensure(
                Repo,
                claim.id,
                LocalClaimLeases.worker_actor(%{work_package_id: claim.id, claimed_by: claim.claimed_by}),
                60_000,
                "performance_contention"
              )
          end
        end)
      end)

    for _index <- 1..clients do
      receive do
        {:ready, _pid} -> :ok
      after
        10_000 -> raise "claim contention clients did not reach the start barrier"
      end
    end

    started_at = System.monotonic_time(:millisecond)
    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks, 60_000)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    errors = Enum.reject(results, &match?({:ok, %ClaimLease{}, action} when action in [:heartbeat, :reclaimed], &1))
    actions = results |> Enum.filter(&match?({:ok, %ClaimLease{}, _action}, &1)) |> Enum.frequencies_by(&elem(&1, 2))

    current =
      Repo.all(
        from(claim in ClaimLease,
          where: claim.status in ^ClaimLease.active_statuses()
        )
      )

    active_by_package = Enum.frequencies_by(current, & &1.work_package_id)
    expected_ids = MapSet.new(Enum.map(claims, & &1.id))
    actual_ids = MapSet.new(Enum.map(current, & &1.work_package_id))

    %{
      "clients" => clients,
      "elapsed_ms" => elapsed_ms,
      "heartbeat" => Map.get(actions, :heartbeat, 0),
      "reclaimed" => Map.get(actions, :reclaimed, 0),
      "database_busy" => Enum.count(errors, &match?({:error, :database_busy}, &1)),
      "errors" => length(errors),
      "active_claims" => length(current),
      "duplicate_ownership" => Enum.count(active_by_package, fn {_id, count} -> count != 1 end),
      "lost_claim_state" => MapSet.size(MapSet.difference(expected_ids, actual_ids)),
      "total_claim_rows" => Repo.aggregate(ClaimLease, :count)
    }
  after
    Repo.put_dynamic_repo(original_dynamic_repo)
    GenServer.stop(repo_pid)
  end

database_files = [database, database <> "-wal", database <> "-shm"]

database_removed =
  Enum.reduce_while(1..20, false, fn _attempt, _removed ->
    Enum.each(database_files, &File.rm/1)

    if Enum.all?(database_files, &(not File.exists?(&1))) do
      {:halt, true}
    else
      Process.sleep(10)
      {:cont, false}
    end
  end)

metrics =
  Map.put(metrics, "cleanup", %{
    "repo_stopped" => not Process.alive?(repo_pid),
    "database_removed" => database_removed
  })

IO.write(Jason.encode!(metrics))
