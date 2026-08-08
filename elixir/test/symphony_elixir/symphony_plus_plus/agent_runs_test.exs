defmodule SymphonyElixir.SymphonyPlusPlus.AgentRunsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Service
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  defmodule LockedAgentRunRepo do
    def get(_schema, _id), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  defmodule BrokenAgentRunRepo do
    def get(_schema, _id), do: raise(%Exqlite.Error{message: "disk I/O failed"})
  end

  defmodule CompletionClearLockedAgentRunRepo do
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def all(query), do: Repo.all(query)
    def get(schema, id), do: Repo.get(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def one(query), do: Repo.one(query)
    def rollback(reason), do: Repo.rollback(reason)
    def transaction(fun), do: Repo.transaction(fun)
    def update(changeset), do: Repo.update(changeset)
    def update_all(_query, _updates), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  defmodule TerminalStartRaceRepo do
    import Ecto.Query, only: [from: 2]

    alias SymphonyElixir.SymphonyPlusPlus.Repo
    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

    @race_key :sympp_terminal_agent_run_start_race

    def arm(work_package_id), do: Process.put(@race_key, work_package_id)
    def disarm, do: Process.delete(@race_key)

    def all(query), do: Repo.all(query)
    def get(schema, id), do: Repo.get(schema, id)
    def one(query), do: Repo.one(query)
    def rollback(reason), do: Repo.rollback(reason)
    def update_all(query, updates), do: Repo.update_all(query, updates)

    def transaction(fun) do
      case Process.get(@race_key) do
        work_package_id when is_binary(work_package_id) ->
          Process.delete(@race_key)

          Repo.update_all(
            from(work_package in WorkPackage, where: work_package.id == ^work_package_id),
            set: [status: "merged", updated_at: DateTime.utc_now(:microsecond)]
          )

        _race ->
          :ok
      end

      Repo.transaction(fun)
    end
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(AgentRun)
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "starts an AgentRun bound to its work package and claimed worker grant", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-CREATE", status: "ready_for_worker"))

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "agent-1")

    assert {:ok, %AgentRun{} = run} =
             Service.start_dispatch(repo, issue(work_package.id), attempt: 2, worker_host: "worker-a")

    assert run.work_package_id == work_package.id
    assert run.access_grant_id == assignment.grant_id
    assert run.actor_id == "agent-1"
    assert run.status == "running"
    assert run.attempt == 2
    assert run.worker_host == "worker-a"
    assert %DateTime{} = run.started_at
    assert %DateTime{} = run.last_seen_at
    assert run.finished_at == nil
  end

  test "binds AgentRun to the grant for the issue assignee when multiple worker grants are claimed", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-ASSIGNEE", status: "ready_for_worker"))

    assert {:ok, other_grant} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, _other_assignment} = AccessGrantService.claim(repo, other_grant.work_key.secret, claimed_by: "agent-2")

    assert {:ok, assigned_grant} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, assigned_grant.work_key.secret, claimed_by: "agent-1")

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))

    assert run.access_grant_id == assignment.grant_id
    assert run.actor_id == "agent-1"
  end

  test "heartbeat updates last seen and runtime binding fields", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-HEARTBEAT", status: "ready_for_worker"))

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))

    assert {:ok, updated} =
             Service.heartbeat(repo, run.id, %{
               session_id: "thread-1-turn-1",
               workspace_path: "C:/tmp/workspace",
               worker_host: "worker-a",
               codex_input_tokens: 12,
               codex_output_tokens: 4,
               codex_total_tokens: 16,
               turn_count: 2
             })

    assert updated.id == run.id
    assert updated.session_id == "thread-1-turn-1"
    assert updated.workspace_path == "C:/tmp/workspace"
    assert updated.worker_host == "worker-a"
    assert updated.codex_input_tokens == 12
    assert updated.codex_output_tokens == 4
    assert updated.codex_total_tokens == 16
    assert updated.turn_count == 2
    assert DateTime.compare(updated.last_seen_at, run.last_seen_at) in [:gt, :eq]
  end

  test "prevents duplicate active runs for the same work package", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-DUPLICATE", status: "ready_for_worker"))

    assert {:ok, first} = Service.start_dispatch(repo, issue(work_package.id))
    assert first.status == "running"

    assert {:error, :active_run_exists} = Service.start_dispatch(repo, issue(work_package.id), attempt: 1)
  end

  test "terminal work package start race rejects atomically and retires the previous retry reservation", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-TERMINAL-RACE", status: "ready_for_worker"))

    assert {:ok, previous} =
             Repository.start_run(repo, %{
               work_package_id: work_package.id,
               status: "retrying",
               attempt: 1,
               worker_task_handle: "terminal-race-previous"
             })

    try do
      TerminalStartRaceRepo.arm(work_package.id)

      assert {:error, :work_package_terminal} =
               Repository.start_run(
                 TerminalStartRaceRepo,
                 %{
                   work_package_id: work_package.id,
                   status: "running",
                   attempt: 2,
                   worker_task_handle: "terminal-race-replacement"
                 },
                 replace_agent_run_id: previous.id
               )
    after
      TerminalStartRaceRepo.disarm()
    end

    assert repo.get!(WorkPackage, work_package.id).status == "merged"
    assert %AgentRun{status: "failed", reason: "work package became terminal before retry dispatch"} = repo.get!(AgentRun, previous.id)
    assert repo.aggregate(AgentRun, :count, :id) == 1
  end

  test "start run rolls back when completion clearing fails", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-CLEAR-LOCKED", status: "ready_for_worker"))

    assert {:error, :database_busy} =
             Repository.start_run(CompletionClearLockedAgentRunRepo, %{
               work_package_id: work_package.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "clear-lock"
             })

    assert {:error, :not_found} = Repository.active_for_work_package(repo, work_package.id)
  end

  test "starting reservation blocks duplicate dispatch until promoted", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-STARTING", status: "ready_for_worker"))

    assert {:ok, starting} = Service.start_dispatch(repo, issue(work_package.id), status: "starting")
    assert starting.status == "starting"

    assert {:error, :active_run_exists} = Service.start_dispatch(repo, issue(work_package.id), attempt: 1)

    assert {:ok, running} = Service.mark_running(repo, starting.id, "worker task started")
    assert running.status == "running"
  end

  test "stale starting reservation can be recovered before dispatch", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-STALE-STARTING", status: "ready_for_worker"))

    assert {:ok, starting} = Service.start_dispatch(repo, issue(work_package.id), status: "starting")
    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -5, :second)

    assert {:ok, _stale_starting} =
             starting
             |> AgentRun.update_changeset(%{last_seen_at: stale_seen_at})
             |> repo.update()

    assert {:ok, replacement} =
             Service.start_dispatch(repo, issue(work_package.id), attempt: 1, starting_stale_after_ms: 1_000)

    assert replacement.status == "running"

    assert {:ok, stale} = Repository.get(repo, starting.id)
    assert stale.status == "failed"
    assert stale.reason == "stale starting AgentRun released before dispatch"
  end

  test "replacement retry releases previous starting reservation by id", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-REPLACE-STARTING", status: "ready_for_worker"))

    assert {:ok, starting} = Service.start_dispatch(repo, issue(work_package.id), status: "starting")

    assert {:ok, replacement} =
             Service.start_dispatch(repo, issue(work_package.id), attempt: 1, replace_agent_run_id: starting.id)

    assert replacement.status == "running"

    assert {:ok, replaced} = Repository.get(repo, starting.id)
    assert replaced.status == "failed"
    assert replaced.reason == "replaced by retry dispatch"
  end

  test "repository normalizes SQLite read failures" do
    assert {:error, :database_busy} = Repository.get(LockedAgentRunRepo, "run-1")
    assert {:error, {:storage_failed, "disk I/O failed"}} = Repository.get(BrokenAgentRunRepo, "run-1")
  end

  test "replacement retry does not fail starting row that already promoted to running", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-REPLACE-PROMOTED", status: "ready_for_worker"))

    assert {:ok, starting} = Service.start_dispatch(repo, issue(work_package.id), status: "starting")
    assert {:ok, running} = Service.mark_running(repo, starting.id, "worker task started")
    assert running.status == "running"

    assert {:error, :active_run_exists} =
             Service.start_dispatch(repo, issue(work_package.id), attempt: 2, replace_agent_run_id: starting.id)

    assert {:ok, persisted} = Repository.get(repo, starting.id)
    assert persisted.status == "running"
  end

  test "retry reconciliation holds dispatch lock until replacement retry starts", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-RETRY-STOP", status: "ready_for_worker"))

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))

    assert {:ok, retrying} = Service.mark_retrying(repo, run.id, "worker exited")
    assert retrying.status == "retrying"
    assert retrying.reason == "worker exited"
    assert retrying.finished_at == nil

    assert {:error, :active_run_exists} = Service.start_dispatch(repo, issue(work_package.id), attempt: 1)

    assert {:ok, replacement} =
             Service.start_dispatch(repo, issue(work_package.id), attempt: 1, replace_agent_run_id: run.id)

    assert replacement.status == "running"

    assert {:ok, replaced} = Repository.get(repo, run.id)
    assert replaced.status == "failed"
    assert replaced.reason == "replaced by retry dispatch"
  end

  test "stop reconciliation updates AgentRun status", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-STOP", status: "ready_for_worker"))

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))

    assert {:ok, stopped} = Service.mark_stopped(repo, run.id, "package left active state")
    assert stopped.status == "stopped"
    assert stopped.reason == "package left active state"
    assert %DateTime{} = stopped.finished_at
  end

  test "running promotion revalidates terminal package state", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-PROMOTE-TERMINAL", status: "ready_for_worker"))

    assert {:ok, run} = Repository.start_run(repo, %{work_package_id: work_package.id, status: "starting"})
    assert {:ok, _terminal} = WorkPackageRepository.update(repo, work_package.id, %{status: "merged"})

    assert {:error, :work_package_terminal} = Service.mark_running(repo, run.id, "worker task started")
    assert {:ok, %AgentRun{status: "starting"}} = Repository.get(repo, run.id)
  end

  test "unassigned AgentRun does not bind an arbitrary claimed worker grant", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-UNASSIGNED", status: "ready_for_worker"))

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "agent-1")

    assert {:ok, run} = Service.start_dispatch(repo, unassigned_issue(work_package.id))

    assert run.access_grant_id == nil
    assert run.actor_id == nil
  end

  test "AgentRun grant binding requires worker assignment source of truth", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-NON-WORKER", status: "ready_for_worker"))

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "agent-1")

    assert {:ok, run} = Service.start_dispatch(repo, non_worker_assigned_issue(work_package.id))

    assert run.access_grant_id == nil
    assert run.actor_id == nil
  end

  test "failed start does not orphan an active AgentRun", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-FAILED-START", status: "ready_for_worker"))

    assert {:ok, failed_run} = Service.start_dispatch(repo, issue(work_package.id))
    assert {:ok, failed_run} = Service.mark_failed(repo, failed_run.id, "failed to spawn agent")
    assert failed_run.status == "failed"

    assert {:ok, replacement} = Service.start_dispatch(repo, issue(work_package.id), attempt: 1)
    assert replacement.id != failed_run.id
    assert replacement.status == "running"
    assert replacement.attempt == 1
  end

  test "stale running AgentRun is not released from heartbeat age alone", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-STALE", status: "ready_for_worker"))

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))
    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -5, :second)

    assert {:ok, _stale_run} =
             run
             |> AgentRun.update_changeset(%{last_seen_at: stale_seen_at})
             |> repo.update()

    assert {:error, :active_run_exists} =
             Service.start_dispatch(repo, issue(work_package.id), attempt: 2, stale_after_ms: 1_000)

    assert {:ok, active} = Repository.get(repo, run.id)
    assert active.status == "running"
    assert active.reason == nil
  end

  test "fresh active AgentRun is not reconciled as stale", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-FRESH", status: "ready_for_worker"))

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))

    assert {:error, :active_run_exists} =
             Service.start_dispatch(repo, issue(work_package.id), attempt: 2, stale_after_ms: 300_000)

    assert {:ok, active} = Repository.get(repo, run.id)
    assert active.status == "running"
  end

  test "replacement retry does not release a running attempt without liveness reconciliation", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-REPLACE", status: "ready_for_worker"))

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))

    assert {:error, :active_run_exists} =
             Service.start_dispatch(repo, issue(work_package.id), attempt: 2, replace_agent_run_id: run.id)

    assert {:ok, still_running} = Repository.get(repo, run.id)
    assert still_running.status == "running"
    assert still_running.reason == nil
  end

  test "replacement retry can release running attempt after confirmed worker exit", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-REPLACE-DEAD", status: "ready_for_worker"))

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))

    assert {:ok, replacement} =
             Service.start_dispatch(
               repo,
               issue(work_package.id),
               attempt: 2,
               replace_agent_run_id: run.id,
               replace_confirmed_dead_worker: true
             )

    assert replacement.status == "running"
    assert replacement.id != run.id

    assert {:ok, replaced} = Repository.get(repo, run.id)
    assert replaced.status == "failed"
    assert replaced.reason == "replaced after confirmed worker exit"
  end

  test "fresh dispatch can recover persisted retrying reservation after restart", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-RECOVER-RETRY", status: "ready_for_worker"))

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))
    assert {:ok, retrying} = Service.mark_retrying(repo, run.id, "worker exited")
    assert retrying.status == "retrying"

    assert {:ok, replacement} =
             Service.start_dispatch(repo, issue(work_package.id), attempt: 2, retry_recovery_base_ms: 0, retry_recovery_max_ms: 0)

    assert replacement.status == "running"
    assert replacement.id != run.id

    assert {:ok, recovered} = Repository.get(repo, run.id)
    assert recovered.status == "failed"
    assert recovered.reason == "retry reservation recovered by dispatch"
  end

  test "fresh retrying reservation is not recovered before recovery age", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-RECOVER-FRESH", status: "ready_for_worker"))

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))
    assert {:ok, retrying} = Service.mark_retrying(repo, run.id, "worker exited")
    assert retrying.status == "retrying"

    assert {:error, :active_run_exists} =
             Service.start_dispatch(
               repo,
               issue(work_package.id),
               attempt: 2,
               retry_recovery_base_ms: 60_000,
               retry_recovery_max_ms: 60_000
             )

    assert {:ok, reserved} = Repository.get(repo, run.id)
    assert reserved.status == "retrying"
  end

  test "generic stale active recovery does not release retrying reservations", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-RETRY-NOT-STALE", status: "ready_for_worker"))

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))
    assert {:ok, retrying} = Service.mark_retrying(repo, run.id, "worker exited")

    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -5, :second)

    assert {:ok, _retrying} =
             retrying
             |> AgentRun.update_changeset(%{last_seen_at: stale_seen_at})
             |> repo.update()

    assert {:error, :active_run_exists} =
             Service.start_dispatch(
               repo,
               issue(work_package.id),
               attempt: 2,
               stale_after_ms: 1_000,
               retry_recovery_base_ms: 60_000,
               retry_recovery_max_ms: 60_000
             )

    assert {:ok, reserved} = Repository.get(repo, run.id)
    assert reserved.status == "retrying"
  end

  test "retrying recovery age follows stored retry attempt backoff", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-RETRY-BACKOFF", status: "ready_for_worker"))

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id), attempt: 3)
    assert {:ok, retrying} = Service.mark_retrying(repo, run.id, "worker exited")

    nearly_old_enough_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -700, :millisecond)

    assert {:ok, _retrying} =
             retrying
             |> AgentRun.update_changeset(%{last_seen_at: nearly_old_enough_seen_at})
             |> repo.update()

    assert {:error, :active_run_exists} =
             Service.start_dispatch(
               repo,
               issue(work_package.id),
               attempt: 4,
               retry_recovery_base_ms: 100,
               retry_recovery_max_ms: 10_000
             )

    old_enough_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -1_000, :millisecond)

    assert {:ok, _retrying} =
             retrying
             |> AgentRun.update_changeset(%{last_seen_at: old_enough_seen_at})
             |> repo.update()

    assert {:ok, replacement} =
             Service.start_dispatch(
               repo,
               issue(work_package.id),
               attempt: 4,
               retry_recovery_base_ms: 100,
               retry_recovery_max_ms: 10_000
             )

    assert replacement.status == "running"
    assert replacement.id != run.id

    assert {:ok, recovered} = Repository.get(repo, run.id)
    assert recovered.status == "failed"
    assert recovered.reason == "retry reservation recovered by dispatch"
  end

  test "terminal AgentRun rows reject late lifecycle updates", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-TERMINAL", status: "ready_for_worker"))

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))
    assert {:ok, completed} = Service.mark_completed(repo, run.id, "worker completed")
    assert completed.status == "completed"

    assert {:error, :not_active} = Service.mark_stopped(repo, run.id, "late cleanup")
    assert {:error, :not_active} = Service.heartbeat(repo, run.id, %{worker_host: "late"})

    assert {:ok, terminal} = Repository.get(repo, run.id)
    assert terminal.status == "completed"
    assert terminal.reason == "worker completed"
  end

  test "replacement release rolls back when new AgentRun insert fails", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-ROLLBACK", status: "ready_for_worker"))

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))

    assert {:error, _reason} =
             Repository.start_run(
               repo,
               %{
                 work_package_id: work_package.id,
                 access_grant_id: "missing-grant",
                 status: "running",
                 attempt: 2
               },
               replace_agent_run_id: run.id
             )

    assert {:ok, active} = Repository.get(repo, run.id)
    assert active.status == "running"
    assert active.reason == nil
  end

  defp issue(id) do
    %Issue{
      id: id,
      identifier: id,
      title: "Run package",
      description: "Dispatch package",
      state: "ready_for_worker",
      assignee_id: "agent-1",
      assigned_to_worker: true
    }
  end

  defp unassigned_issue(id) do
    %Issue{
      id: id,
      identifier: id,
      title: "Run package",
      description: "Dispatch package",
      state: "ready_for_worker",
      assigned_to_worker: false
    }
  end

  defp non_worker_assigned_issue(id) do
    %Issue{
      id: id,
      identifier: id,
      title: "Run package",
      description: "Dispatch package",
      state: "ready_for_worker",
      assignee_id: "agent-1",
      assigned_to_worker: false
    }
  end
end
