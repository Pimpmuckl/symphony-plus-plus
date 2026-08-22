Code.require_file(Path.expand("../../support/symphony_plus_plus/dashboard_fixture_database_test.exs", __DIR__))

defmodule SymphonyElixir.SymphonyPlusPlus.DashboardApiTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.FakeAuthenticatedGitHubClient
  alias SymphonyElixir.FakeGhCli
  alias SymphonyElixir.FakeGitHubClient
  alias SymphonyElixir.GitHubPullRequestFixtures
  alias SymphonyElixir.GitHubTestSupport
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Service, as: CommentService
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.MetadataProjection
  alias SymphonyElixir.SymphonyPlusPlus.DashboardFixtureDatabase
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Repository, as: GuidanceRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Config
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Server
  alias SymphonyElixir.SymphonyPlusPlus.OperatorAudit
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.RetentionThrottle
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service, as: SoloSessionsService
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.TestSupport
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.ReactDashboardController
  alias SymphonyElixirWeb.SymppDashboardAPI.LocalOperatorDashboard

  @endpoint SymphonyElixirWeb.Endpoint
  @repo_root Path.expand("../../../../", __DIR__)

  defmodule BusyRepo do
    @moduledoc false

    def all(_query), do: raise(%Exqlite.Error{message: "database is locked"})
    def one(_query), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  defmodule CountingRepo do
    @moduledoc false

    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def all(query) do
      count_artifact_list_query(query)
      Repo.all(query)
    end

    def one(query), do: Repo.one(query)
    def get(queryable, id), do: Repo.get(queryable, id)
    def transaction(fun), do: Repo.transaction(fun)

    def counter(counter), do: :persistent_term.put({__MODULE__, :counter}, counter)
    def clear_counter, do: :persistent_term.erase({__MODULE__, :counter})

    defp count_artifact_list_query(%Ecto.Query{from: %{source: {"sympp_artifacts", _schema}}, order_bys: [_ | _]}) do
      case :persistent_term.get({__MODULE__, :counter}, nil) do
        nil -> :ok
        counter -> Agent.update(counter, &(&1 + 1))
      end
    end

    defp count_artifact_list_query(_query), do: :ok
  end

  defmodule WorkRequestCardCountingRepo do
    @moduledoc false

    alias SymphonyElixir.SymphonyPlusPlus.Repo

    @counted_tables [
      "sympp_work_requests",
      "sympp_work_request_clarification_questions",
      "sympp_work_request_decision_logs",
      "sympp_work_packages",
      "sympp_work_package_deliveries",
      "sympp_comments"
    ]

    def all(query) do
      count_query(query)
      Repo.all(query)
    end

    def one(query), do: Repo.one(query)
    def get(queryable, id), do: Repo.get(queryable, id)
    def transaction(fun), do: Repo.transaction(fun)

    def counter(counter), do: :persistent_term.put({__MODULE__, :counter}, counter)
    def clear_counter, do: :persistent_term.erase({__MODULE__, :counter})

    defp count_query(%Ecto.Query{from: %{source: {table, _schema}}}) when table in @counted_tables do
      case :persistent_term.get({__MODULE__, :counter}, nil) do
        nil -> :ok
        counter -> Agent.update(counter, &Map.update(&1, table, 1, fn count -> count + 1 end))
      end
    end

    defp count_query(_query), do: :ok
  end

  defmodule DashboardQueryCountingRepo do
    @moduledoc false

    alias SymphonyElixir.SymphonyPlusPlus.Repo

    @counter_key {__MODULE__, :query_count}

    def reset, do: Process.put(@counter_key, 0)
    def count, do: Process.get(@counter_key, 0)

    def all(query), do: counted(fn -> Repo.all(query) end)
    def one(query), do: counted(fn -> Repo.one(query) end)
    def get(queryable, id), do: counted(fn -> Repo.get(queryable, id) end)
    def get!(queryable, id), do: counted(fn -> Repo.get!(queryable, id) end)
    def query(sql, params), do: counted(fn -> Repo.query(sql, params) end)
    def update_all(query, updates), do: counted(fn -> Repo.update_all(query, updates) end)
    def transaction(fun), do: Repo.transaction(fun)

    defp counted(fun) do
      Process.put(@counter_key, count() + 1)
      fun.()
    end
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = WorkPackageRepository.migrate(Repo)
    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)
    start_test_endpoint()

    on_exit(fn ->
      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end

      File.rm(database_path)
    end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(OperatorAudit)
    repo.delete_all(AgentRun)
    repo.delete_all(ClaimLease)
    repo.delete_all(Artifact)
    repo.delete_all(ProgressEvent)
    repo.delete_all(Finding)
    repo.delete_all(PlanNode)
    repo.delete_all(SoloSessionEntry)
    repo.delete_all(SoloSession)
    repo.delete_all(GuidanceRequest)
    repo.delete_all(Comment)
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackageDelivery)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkPackage)
    repo.delete_all(Phase)
    repo.delete_all(DecisionLogEntry)
    repo.delete_all(ClarificationQuestion)
    repo.delete_all(WorkRequest)
    repo.delete_all(OperatorSettings)
    RetentionThrottle.reset(repo)
    :ok
  end

  test "package operational state splits active work from historical activity", %{repo: repo} do
    assert {:ok, ready} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-READY", status: "ready_for_worker"))

    assert {:ok, card} = Dashboard.card(repo, ready)
    assert card.operational_state.key == "ready_for_worker"
    assert card.operational_state.attention_items == []
    assert card.operational_state.has_started == false
    assert card.operational_state.has_active_worker == false

    assert {:ok, started} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-READY-STARTED", status: "active"))

    create_claimed_worker_grant(repo, started.id, "worker-started")

    assert {:ok, started_card} = Dashboard.card(repo, started)
    assert started_card.operational_state.key == "active"
    assert started_card.operational_state.label == "Active"
    assert started_card.operational_state.raw_status == "active"
    assert started_card.operational_state.has_started == true
    assert started_card.operational_state.has_active_worker == true
    assert started_card.operational_state.attention_items == []

    assert {:ok, prepared} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-READY-PREPARED", status: "ready_for_worker"))

    assert {:ok, _worktree_prepared} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: prepared.id,
               summary: "Prepared WorkPackage worktree",
               status: "prepared",
               payload: %{
                 type: "worktree_lifecycle",
                 source_tool: "prepare_work_package_worktree",
                 status: "prepared",
                 worktree_path: "/tmp/sympp-worktree",
                 branch: "agent/prepared"
               },
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, prepared_card} = Dashboard.card(repo, prepared)
    assert prepared_card.operational_state.key == "prepared"
    assert prepared_card.operational_state.label == "Prepared"
    assert prepared_card.operational_state.attention_items == []
    assert prepared_card.operational_state.has_started == false
    assert prepared_card.operational_state.has_active_worker == false
    assert prepared_card.operational_state.has_prepared_worktree == true
    assert prepared_card.operational_state.is_stale == false

    assert {:ok, failed_prepare} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-READY-PREP-FAILED", status: "ready_for_worker"))

    assert {:ok, _worktree_prepare_failed} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: failed_prepare.id,
               summary: "Failed preparing WorkPackage worktree",
               status: "failed",
               payload: %{
                 type: "worktree_lifecycle",
                 source_tool: "prepare_work_package_worktree",
                 status: "failed",
                 worktree_path: "/tmp/sympp-worktree",
                 branch: "agent/prepared"
               },
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, failed_prepare_card} = Dashboard.card(repo, failed_prepare)
    assert failed_prepare_card.operational_state.key == "needs_attention"
    assert failed_prepare_card.operational_state.has_started == true
    assert failed_prepare_card.operational_state.has_prepared_worktree == false

    assert {:ok, ready_with_history} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-READY-HISTORY", status: "ready_for_worker"))

    assert {:ok, _old_progress} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: ready_with_history.id,
               summary: "Worker made progress earlier",
               status: "progress",
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, ready_history_card} = Dashboard.card(repo, ready_with_history)
    assert ready_history_card.operational_state.key == "needs_attention"
    assert ready_history_card.operational_state.has_started == true
    assert ready_history_card.operational_state.has_active_worker == false
    assert ready_history_card.operational_state.is_stale == true

    assert {:ok, ready_with_run_history} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-READY-RUN-HISTORY", status: "ready_for_worker"))

    assert {:ok, ready_history_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: ready_with_run_history.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "ready-history-run"
             })

    assert {:ok, _completed_ready_history_run} = AgentRunRepository.mark_completed(repo, ready_history_run.id, "done earlier")

    assert {:ok, ready_run_history_card} = Dashboard.card(repo, ready_with_run_history)
    assert ready_run_history_card.operational_state.key == "needs_attention"
    assert ready_run_history_card.operational_state.has_started == true
    assert ready_run_history_card.operational_state.has_active_worker == false
    assert ready_run_history_card.operational_state.is_stale == true

    assert {:ok, historical} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-HISTORICAL", status: "implementing"))

    assert {:ok, run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: historical.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "historical-run"
             })

    assert {:ok, _completed_run} = AgentRunRepository.mark_completed(repo, run.id, "done earlier")

    assert {:ok, historical_card} = Dashboard.card(repo, historical)
    assert historical_card.operational_state.key == "started_paused"
    assert historical_card.operational_state.raw_status == "implementing"
    assert historical_card.operational_state.has_started == true
    assert historical_card.operational_state.has_active_worker == false
    assert historical_card.operational_state.is_stale == true
    assert is_binary(historical_card.operational_state.last_activity_at)

    assert {:ok, active} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-ACTIVE", status: "implementing"))

    assert {:ok, _active_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: active.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "active-run"
             })

    assert {:ok, active_card} = Dashboard.card(repo, active)
    assert active_card.operational_state.key == "active"
    assert active_card.operational_state.label == "Active"
    assert active_card.operational_state.has_started == true
    assert active_card.operational_state.has_active_worker == true

    assert {:ok, stale_active} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-STALE-ACTIVE", status: "implementing"))

    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -600, :second)

    assert {:ok, _stale_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: stale_active.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "stale-active-run",
               last_seen_at: stale_seen_at
             })

    assert {:ok, stale_active_card} = Dashboard.card(repo, stale_active)
    assert stale_active_card.active_agent_run == nil
    assert stale_active_card.operational_state.key == "started_paused"
    assert stale_active_card.operational_state.has_started == true
    assert stale_active_card.operational_state.has_active_worker == false
    assert stale_active_card.operational_state.is_stale == true

    assert {:ok, ci_waiting} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-CI-WAITING", status: "ci_waiting"))

    assert {:ok, _review_progress} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: ci_waiting.id,
               summary: "Review started",
               status: "review_started",
               payload: %{type: "review_progress", source_tool: "review_suite"},
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, ci_card} = Dashboard.card(repo, ci_waiting)
    assert ci_card.operational_state.key == "started_paused"
  end

  test "package operational state follows provider-backed merged PR state", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-OP-MERGED-PR",
                 kind: "mcp",
                 status: "ready_for_merge",
                 policy_template: "mcp"
               )
             )

    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-a"},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/77", head_sha: "head-a"},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _pr_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/77",
                 repository: "example/repo",
                 number: 77,
                 head_sha: "head-a",
                 merge_state: %{merged: true}
               },
               created_at: DateTime.add(timestamp, 3, :second)
             })

    assert {:ok, card} = Dashboard.card(repo, work_package)
    assert card.operational_state.key == "merged"
    assert card.operational_state.raw_status == "ready_for_merge"

    attention_by_key = Map.new(card.operational_state.attention_items, &{&1.key, &1})
    refute Map.has_key?(attention_by_key, "pr_merged_raw_status_open")

    assert {:ok, _new_branch_head} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch advanced",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-b"},
               created_at: DateTime.add(timestamp, 4, :second)
             })

    assert {:ok, stale_card} = Dashboard.card(repo, work_package)
    assert stale_card.operational_state.key == "merge_ready"
    refute Enum.any?(stale_card.operational_state.attention_items, &(&1.key == "pr_merged_raw_status_open"))
  end

  test "phase board status filters keep repo identity from the phase scope", %{repo: repo} do
    with_trusted_repo_remotes(["Pimpmuckl/symphony-plus-plus"], fn ->
      assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-dashboard-repo-identity", title: "Repo identity phase"})

      assert {:ok, bare} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(
                   id: "SYMPP-DASH-PHASE-REPO-BARE",
                   kind: "delegation",
                   phase_id: phase.id,
                   status: "planning",
                   repo: "symphony-plus-plus",
                   base_branch: "main"
                 )
               )

      assert {:ok, _owner} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(
                   id: "SYMPP-DASH-PHASE-REPO-OWNER",
                   kind: "delegation",
                   phase_id: phase.id,
                   status: "blocked",
                   repo: "Pimpmuckl/symphony-plus-plus",
                   base_branch: "main"
                 )
               )

      assert {:ok, board} = Dashboard.phase_board(repo, phase.id, status: "planning")
      assert [%{id: bare_id} = card] = board.groups["planning"]
      assert bare_id == bare.id
      assert card.repo == "symphony-plus-plus"
      assert card.repo_key == "symphony-plus-plus"
      assert card.repo_display == "symphony-plus-plus"
      assert card.repo_remote == "Pimpmuckl/symphony-plus-plus"
      assert card.repo_aliases == ["Pimpmuckl/symphony-plus-plus", "symphony-plus-plus"]
    end)
  end

  test "dashboard WorkRequest list batches related card count reads", %{repo: repo} do
    first = create_work_request!(repo, id: "WR-DASH-BATCH-1")
    second = create_work_request!(repo, id: "WR-DASH-BATCH-2")

    assert {:ok, _question} = WorkRequestRepository.ask_question(repo, first.id, question_attrs(id: "WRQ-DASH-BATCH-1"))
    assert {:ok, _decision} = WorkRequestRepository.record_decision(repo, second.id, decision_attrs(id: "WRD-DASH-BATCH-1"))
    assert {:ok, _slice} = CanonicalWorkPackageFixtures.add_work_package(repo, second.id, work_package_attrs(id: "WRS-DASH-BATCH-1"))

    {:ok, counter} = Agent.start_link(fn -> %{} end)
    WorkRequestCardCountingRepo.counter(counter)

    try do
      assert {:ok, payload} = Dashboard.work_requests(WorkRequestCardCountingRepo)
      assert payload.total_count == 2
      assert Enum.map(payload.work_requests, & &1.id) == [first.id, second.id]

      assert Agent.get(counter, & &1) == %{
               "sympp_work_requests" => 2,
               "sympp_work_request_clarification_questions" => 1,
               "sympp_work_request_decision_logs" => 1,
               "sympp_work_packages" => 2,
               "sympp_work_package_deliveries" => 1,
               "sympp_comments" => 1
             }
    after
      WorkRequestCardCountingRepo.clear_counter()
      Agent.stop(counter)
    end
  end

  test "local WorkRequest detail includes work-package operational state from linked package activity", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-OP-SLICES", status: "ready_for_slicing")

    assert {:ok, approved_ready} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-READY"))

    set_canonical_package_status!(repo, approved_ready, "ready_for_worker")

    assert {:ok, approved_idle_linked} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-IDLE-LINKED"))

    set_canonical_package_status!(repo, approved_idle_linked, "ready_for_worker")

    assert {:ok, approved_prepared_linked} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-PREPARED-LINKED"))

    prepared_package = set_canonical_package_status!(repo, approved_prepared_linked, "ready_for_worker")

    assert {:ok, _prepared_progress} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: prepared_package.id,
               summary: "Prepared WorkPackage worktree",
               status: "prepared",
               payload: %{
                 type: "worktree_lifecycle",
                 source_tool: "prepare_work_package_worktree",
                 status: "prepared",
                 worktree_path: "/tmp/sympp-worktree",
                 branch: "agent/prepared"
               },
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, approved_linked} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-LINKED"))

    set_canonical_package_status!(repo, approved_linked, "implementing")

    assert {:ok, approved_terminal} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-TERMINAL"))

    set_canonical_package_status!(repo, approved_terminal, "abandoned")

    assert {:ok, payload} = Dashboard.work_request_detail(repo, work_request.id)
    slices_by_id = Map.new(payload.work_packages, &{&1.id, &1})

    assert get_in(slices_by_id, ["WRS-OP-READY", :operational_state, :key]) == "ready_for_worker"
    assert get_in(slices_by_id, ["WRS-OP-READY", :operational_state, :raw_status]) == "ready_for_worker"
    assert get_in(slices_by_id, ["WRS-OP-IDLE-LINKED", :operational_state, :key]) == "ready_for_worker"

    prepared_linked_slice = Map.fetch!(slices_by_id, "WRS-OP-PREPARED-LINKED")
    assert prepared_linked_slice.work_package_status == "ready_for_worker"
    assert prepared_linked_slice.operational_state.key == "prepared"
    assert prepared_linked_slice.operational_state.raw_status == "ready_for_worker"
    assert prepared_linked_slice.operational_state.has_started == false
    assert prepared_linked_slice.operational_state.has_prepared_worktree == true
    refute Enum.any?(prepared_linked_slice.operational_state.attention_items, &(&1.key == "linked_package_started_while_slice_idle"))

    linked_slice = Map.fetch!(slices_by_id, "WRS-OP-LINKED")
    assert linked_slice.work_package_status == "implementing"
    assert linked_slice.operational_state.key == "started_paused"
    assert linked_slice.operational_state.raw_status == "implementing"

    terminal_slice = Map.fetch!(slices_by_id, "WRS-OP-TERMINAL")
    assert terminal_slice.work_package_status == "abandoned"
    assert terminal_slice.operational_state.key == "needs_closeout"
    assert terminal_slice.attention_reason_codes == ["terminal_package_without_delivery_outcome"]
  end

  test "WorkRequest cards promote linked package operational state over raw ready-for-slicing", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-OP-REQUEST", status: "ready_for_slicing")

    assert {:ok, active_slice} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-REQUEST-ACTIVE"))

    assert {:ok, active_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, active_slice.id, "planned")

    active_package =
      create_matching_work_package!(repo, work_request, active_slice,
        id: "SYMPP-OP-REQUEST-ACTIVE",
        status: "implementing"
      )

    assert {:ok, _active_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: active_package.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "request-active-run"
             })

    assert {:ok, _dispatched_active} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, active_slice.id, "approved", active_package.id)

    assert {:ok, merged_slice} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-REQUEST-MERGED"))

    assert {:ok, merged_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, merged_slice.id, "planned")

    merged_package =
      create_matching_work_package!(repo, work_request, merged_slice,
        id: "SYMPP-OP-REQUEST-MERGED",
        status: "merged"
      )

    assert {:ok, _dispatched_merged} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, merged_slice.id, "approved", merged_package.id)

    assert {:ok, payload} = Dashboard.work_requests(repo)
    request_card = Enum.find(payload.work_requests, &(&1.id == work_request.id))

    assert request_card.status == "sliced"
    assert request_card.dispatched_work_package_count == 2
    assert request_card.operational_state.key == "active"
    assert request_card.operational_state.label == "Active"
    assert request_card.operational_state.raw_status == "sliced"
    assert request_card.operational_state.has_started == true
    assert request_card.operational_state.has_active_worker == true

    prepared_request = create_work_request!(repo, id: "WR-DASH-OP-REQUEST-PREPARED", status: "ready_for_slicing")

    assert {:ok, prepared_slice} =
             CanonicalWorkPackageFixtures.add_work_package(repo, prepared_request.id, work_package_attrs(id: "WRS-OP-REQUEST-PREPARED"))

    assert {:ok, prepared_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, prepared_request.id, prepared_slice.id, "planned")

    prepared_package =
      create_matching_work_package!(repo, prepared_request, prepared_slice,
        id: "SYMPP-OP-REQUEST-PREPARED",
        status: "ready_for_worker"
      )

    assert {:ok, _prepared_progress} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: prepared_package.id,
               summary: "Prepared WorkPackage worktree",
               status: "prepared",
               payload: %{
                 type: "worktree_lifecycle",
                 source_tool: "prepare_work_package_worktree",
                 status: "prepared",
                 worktree_path: "/tmp/sympp-worktree",
                 branch: "agent/prepared"
               },
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, _dispatched_prepared} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, prepared_request.id, prepared_slice.id, "approved", prepared_package.id)

    assert {:ok, prepared_payload} = Dashboard.work_requests(repo)
    prepared_request_card = Enum.find(prepared_payload.work_requests, &(&1.id == prepared_request.id))

    assert prepared_request_card.operational_state.key == "prepared"
    assert prepared_request_card.operational_state.label == "Prepared"
    assert prepared_request_card.operational_state.raw_status == "sliced"
    assert prepared_request_card.operational_state.has_prepared_worktree == true
  end

  test "WorkRequest completion shows needs closeout while dispatched slice preserves merged package truth", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-OP-MERGED", status: "ready_for_slicing")

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-MERGED"))

    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

    merged_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "SYMPP-OP-MERGED",
        status: "merged"
      )

    assert {:ok, dispatched_slice} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", merged_package.id)

    assert dispatched_slice.status == "merged"

    assert {:ok, payload} = Dashboard.work_request_detail(repo, work_request.id)
    assert payload.work_request.status == "sliced"
    assert payload.work_request.completed_at != nil
    assert payload.work_request.archived_at == nil
    assert payload.work_request.operational_state.key == "needs_closeout"
    assert payload.work_request.operational_state.label == "Needs Closeout"
    assert payload.work_request.operational_state.raw_status == "sliced"

    assert {:ok, read_request} = WorkRequestRepository.get(repo, work_request.id)
    assert read_request.completed_at == nil

    [slice] = payload.work_packages
    assert slice.status == "merged"
    assert slice.work_package_status == "merged"
    assert slice.operational_state.key == "needs_closeout"
    assert slice.operational_state.raw_status == "merged"
    assert slice.attention_reason_codes == ["terminal_package_without_delivery_outcome"]
  end

  test "WorkRequest delivery truth stays primary over lifecycle gates", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-OP-GATED-DELIVERY", status: "ready_for_slicing")

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-GATED-DELIVERY"))

    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

    work_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "SYMPP-OP-GATED-DELIVERY",
        status: "ready_for_worker"
      )

    assert {:ok, _dispatched_slice} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", work_package.id)

    assert {:ok, _delivery} =
             WorkRequestRepository.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: "dashboard-gated-delivery",
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/904",
                 pr_merged_at: ~U[2026-05-24 11:30:00.000000Z],
                 merge_commit_sha: "merge-904"
               })
             )

    work_request
    |> Ecto.Changeset.change(status: "human_info_needed")
    |> repo.update!()

    assert {:ok, payload} = Dashboard.work_requests(repo)
    card = Enum.find(payload.work_requests, &(&1.id == work_request.id))

    assert card.operational_state.key == "delivered"
    assert card.operational_state.raw_status == "human_info_needed"

    assert {:ok, detail} = Dashboard.work_request_detail(repo, work_request.id)
    assert detail.work_request.operational_state.key == "delivered"
    assert detail.work_request.operational_state.raw_status == "human_info_needed"

    [slice] = detail.work_packages
    assert slice.operational_state.key == "delivered"
  end

  test "operator-completed WorkRequest stays completed over lifecycle gates", %{repo: repo} do
    completed_at = ~U[2026-05-25 10:00:00.000000Z]

    work_request =
      create_work_request!(repo, id: "WR-DASH-OPERATOR-COMPLETED-GATED", status: "human_info_needed")
      |> Ecto.Changeset.change(completed_at: completed_at, completion_source: "operator")
      |> repo.update!()

    assert {:ok, payload} = Dashboard.work_requests(repo)
    card = Enum.find(payload.work_requests, &(&1.id == work_request.id))

    assert card.operational_state.key == "completed"
    assert card.operational_state.raw_status == "human_info_needed"

    assert {:ok, detail} = Dashboard.work_request_detail(repo, work_request.id)
    assert detail.work_request.operational_state.key == "completed"
    assert detail.work_request.operational_state.raw_status == "human_info_needed"
  end

  test "derived completed WorkRequest stays completed over clarification gates", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-DERIVED-COMPLETED-GATED", status: "ready_for_slicing")

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-DERIVED-COMPLETED-GATED"))

    assert {:ok, _skipped_slice} = WorkRequestRepository.skip_work_package(repo, work_request.id, work_package.id, "planned")
    mark_non_scratch_skipped_slice!(repo, work_package.id)

    work_request
    |> Ecto.Changeset.change(status: "clarifying")
    |> repo.update!()

    assert {:ok, payload} = Dashboard.work_requests(repo)
    card = Enum.find(payload.work_requests, &(&1.id == work_request.id))

    assert card.operational_state.key == "completed"
    assert card.operational_state.raw_status == "clarifying"

    assert {:ok, detail} = Dashboard.work_request_detail(repo, work_request.id)
    assert detail.work_request.operational_state.key == "completed"
    assert detail.work_request.operational_state.raw_status == "clarifying"
  end

  test "archived WorkRequest lifecycle stays primary over delivery promotion", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-OP-ARCHIVED-DELIVERY", status: "ready_for_slicing")

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-OP-ARCHIVED-DELIVERY"))

    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

    work_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "SYMPP-OP-ARCHIVED-DELIVERY",
        status: "ready_for_worker"
      )

    assert {:ok, _dispatched_slice} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", work_package.id)

    assert {:ok, _delivery} =
             WorkRequestRepository.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: "dashboard-archived-delivery",
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/906",
                 pr_merged_at: ~U[2026-05-24 12:00:00.000000Z],
                 merge_commit_sha: "merge-906"
               })
             )

    archived_at = ~U[2026-05-25 09:00:00.000000Z]

    work_request
    |> Ecto.Changeset.change(completed_at: archived_at, completion_source: "operator", archived_at: archived_at)
    |> repo.update!()

    assert {:ok, detail} = Dashboard.work_request_detail(repo, work_request.id)
    assert detail.work_request.operational_state.key == "completed"

    [slice] = detail.work_packages
    assert slice.operational_state.key == "delivered"
  end

  test "board artifact reads are limited to packages that need artifact-backed readiness", %{repo: repo} do
    assert {:ok, plain_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-PLAIN-ARTIFACTS", kind: "quick_fix", status: "planning", policy_template: "quick_fix")
             )

    assert {:ok, validation_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-VALIDATION-ARTIFACTS",
                 kind: "mcp",
                 status: "planning",
                 policy_template: "mcp"
               )
             )

    assert {:ok, _plain_artifact} =
             PlanningService.append_artifact(repo, %{
               work_package_id: plain_package.id,
               path: "plain.txt",
               title: "Plain artifact",
               kind: "note"
             })

    assert {:ok, _validation_artifact} =
             PlanningService.append_artifact(repo, %{
               work_package_id: validation_package.id,
               path: "validation.txt",
               title: "Validation evidence",
               kind: "review"
             })

    assert {:ok, counter} = Agent.start_link(fn -> 0 end)
    CountingRepo.counter(counter)

    try do
      assert {:ok, board} = Dashboard.board(CountingRepo)
      assert board.total_count == 2
      assert Agent.get(counter, & &1) == 1
    after
      CountingRepo.clear_counter()
      Agent.stop(counter)
    end
  end

  test "stale calculation only flags active or queued runs past the threshold", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUNTIME-STALE", status: "ready_for_worker"))

    now = DateTime.utc_now(:microsecond)

    fresh_run =
      %AgentRun{
        work_package_id: work_package.id,
        status: "running",
        last_seen_at: DateTime.add(now, -299, :second)
      }

    stale_run =
      %AgentRun{
        work_package_id: work_package.id,
        status: "starting",
        last_seen_at: DateTime.add(now, -300, :second)
      }

    stopped_run =
      %AgentRun{
        work_package_id: work_package.id,
        status: "stopped",
        last_seen_at: DateTime.add(now, -900, :second)
      }

    refute Dashboard.stale_agent_run?(fresh_run, now, 300)
    assert Dashboard.stale_agent_run?(stale_run, now, 300)
    refute Dashboard.stale_agent_run?(stopped_run, now, 300)
  end

  test "metadata projection does not reuse sequence-less attach state after bare reattach" do
    timestamp = ~U[2026-05-05 00:00:00Z]

    branch =
      progress_event("branch", nil, DateTime.add(timestamp, 1, :second), %{
        "type" => "branch",
        "source_tool" => "attach_branch",
        "branch" => "agent/SYMPP-SEQUENCELESS",
        "head_sha" => "head-a"
      })

    semantic_attach =
      progress_event("attach-state", nil, DateTime.add(timestamp, 2, :second), %{
        "type" => "pr",
        "source_tool" => "attach_pr",
        "url" => "https://github.com/example/repo/pull/10",
        "repository" => "example/repo",
        "number" => 10,
        "head_sha" => "head-a",
        "check_summary" => %{"conclusion" => "success"},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      })

    semantic_events = [branch, semantic_attach]

    assert MetadataProjection.current_pr_state_present?(semantic_events, "head-a")

    bare_reattach =
      progress_event("attach-bare", nil, DateTime.add(timestamp, 3, :second), %{
        "type" => "pr",
        "source_tool" => "attach_pr",
        "url" => "https://github.com/example/repo/pull/10",
        "repository" => "example/repo",
        "number" => 10,
        "head_sha" => "head-a"
      })

    stale_events = semantic_events ++ [bare_reattach]

    refute MetadataProjection.current_pr_state_present?(stale_events, "head-a")
    assert MetadataProjection.metadata(stale_events).pr["source_tool"] == "attach_pr"
    refute Map.has_key?(MetadataProjection.metadata(stale_events).pr, "check_summary")

    fresh_sync =
      progress_event("sync-state", nil, DateTime.add(timestamp, 4, :second), %{
        "type" => "pr",
        "source_tool" => "sync_pr",
        "url" => "https://github.com/example/repo/pull/10",
        "repository" => "example/repo",
        "number" => 10,
        "head_sha" => "head-a",
        "check_summary" => %{"conclusion" => "success"},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      })

    fresh_events = stale_events ++ [fresh_sync]

    assert MetadataProjection.current_pr_state_present?(fresh_events, "head-a")
    assert MetadataProjection.metadata(fresh_events).pr["source_tool"] == "sync_pr"
  end

  test "card summaries use total counts and full progress metadata", %{repo: repo} do
    %{work_package: work_package} = create_dashboard_fixture(repo)
    timestamp = ~U[2026-05-05 00:02:00Z]

    for index <- 1..105 do
      assert {:ok, _event} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: work_package.id,
                 summary: "Heartbeat #{index}",
                 status: "working",
                 payload: %{type: "status", source_tool: "test"},
                 created_at: DateTime.add(timestamp, index, :second)
               })
    end

    assert {:ok, _backfilled_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Backfilled older event",
               status: "working",
               payload: %{type: "status", source_tool: "test"},
               created_at: DateTime.add(timestamp, -1, :second)
             })

    for index <- 1..101 do
      assert {:ok, _finding} =
               PlanningRepository.append_finding(repo, %{
                 work_package_id: work_package.id,
                 title: "Finding #{index}",
                 body: "Finding body #{index}",
                 severity: "low",
                 created_at: DateTime.add(timestamp, 200 + index, :second)
               })

      assert {:ok, _artifact} =
               PlanningService.append_artifact(repo, %{
                 work_package_id: work_package.id,
                 path: "artifact-#{index}.txt",
                 title: "Artifact #{index}",
                 kind: "log",
                 created_at: DateTime.add(timestamp, 400 + index, :second)
               })
    end

    assert {:ok, card} = Dashboard.card(repo, work_package)
    assert card.finding_count == 102
    assert card.artifact_count == 102
    assert card.active_blocker_count == 1
    assert {:ok, latest_progress_at, _offset} = DateTime.from_iso8601(card.latest_progress_at)
    assert DateTime.compare(latest_progress_at, DateTime.add(timestamp, 105, :second)) == :eq
    assert card.metadata.pr["url"] == "https://github.com/example/repo/pull/1"
  end

  test "local operator dashboard returns aggregate workflow state", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      assert {:ok, work_request} =
               WorkRequestRepository.create(repo, %{
                 title: "Operator intake",
                 repo: "symphony-plus-plus",
                 base_branch: "main",
                 work_type: "feature",
                 human_description: "Build the dashboard.",
                 constraints: %{},
                 desired_dispatch_shape: "architect_led_feature_branch",
                 status: "ready_for_clarification"
               })

      assert {:ok, archived_request} =
               WorkRequestRepository.create(repo, %{
                 title: "Archived operator intake",
                 repo: "symphony-plus-plus",
                 base_branch: "main",
                 work_type: "feature",
                 human_description: "Completed earlier.",
                 constraints: %{},
                 desired_dispatch_shape: "single_package",
                 status: "ready_for_slicing"
               })

      assert {:ok, slice} = CanonicalWorkPackageFixtures.add_work_package(repo, archived_request.id, work_package_attrs(id: "WRS-OPERATOR-ARCHIVE"))
      assert {:ok, _skipped} = WorkRequestRepository.skip_work_package(repo, archived_request.id, slice.id, "planned")
      mark_non_scratch_skipped_slice!(repo, slice.id)

      archived_request
      |> Ecto.Changeset.change(completed_at: %{~U[2026-05-01 00:00:00Z] | microsecond: {0, 6}})
      |> Ecto.Changeset.change(archived_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :day))
      |> repo.update!()

      initial_payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard"), 200)
      deferred_payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard/deferred"), 200)
      archived_payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard?surface=archived"), 200)
      solo_payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard?surface=solo"), 200)
      hydrated_payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard/hydrated"), 200)

      assert initial_payload["work_requests"]["total_count"] == 1

      assert [%{"id" => work_request_id, "repo" => "symphony-plus-plus", "base_branch" => "main", "status" => "ready_for_clarification"}] =
               initial_payload["work_requests"]["work_requests"]

      assert work_request_id == work_request.id
      refute Enum.any?(initial_payload["work_requests"]["work_requests"], &(&1["id"] == archived_request.id))
      refute Map.has_key?(initial_payload, "board")
      refute Map.has_key?(initial_payload, "work_request_details")
      refute Map.has_key?(initial_payload, "archived_work_requests")
      refute Map.has_key?(initial_payload, "solo_sessions")
      assert initial_payload["deferred"] == %{"dashboard_sections" => true}

      assert [%{"work_request" => %{"id" => ^work_request_id}}] = deferred_payload["work_request_details"]
      refute Map.has_key?(deferred_payload, "board")
      assert is_list(deferred_payload["work_packages"])
      refute Map.has_key?(initial_payload, "work_request_work_package_ids")
      refute Map.has_key?(deferred_payload, "archived_work_requests")
      refute Map.has_key?(deferred_payload, "solo_sessions")
      assert deferred_payload["deferred"] == %{"dashboard_sections" => false}

      assert [%{"id" => archived_id}] = archived_payload["archived_work_requests"]["work_requests"]
      assert archived_id == archived_request.id
      refute Map.has_key?(archived_payload, "work_request_details")
      refute Map.has_key?(archived_payload, "solo_sessions")
      assert solo_payload["solo_sessions"] == %{"total_count" => 0, "solo_sessions" => []}
      refute Map.has_key?(solo_payload, "archived_work_requests")
      refute Map.has_key?(solo_payload, "work_request_details")

      assert hydrated_payload["deferred"] == %{"dashboard_sections" => false}
      assert hydrated_payload["work_requests"] == initial_payload["work_requests"]
      assert hydrated_payload["work_request_details"] == deferred_payload["work_request_details"]
      refute Map.has_key?(hydrated_payload, "archived_work_requests")
      refute Map.has_key?(hydrated_payload, "solo_sessions")

      assert {:ok, archived} = WorkRequestRepository.get(repo, archived_request.id)
      assert %DateTime{} = archived.archived_at
    end)
  end

  test "priority dashboard responds before compact execution signals for a deterministic workload", %{repo: repo} do
    for index <- 1..20 do
      work_request =
        create_work_request!(repo,
          id: "WR-PERF-#{String.pad_leading(to_string(index), 2, "0")}",
          title: "Perf request #{String.pad_leading(to_string(index), 2, "0")}",
          repo: "symphony-plus-plus",
          base_branch: "main",
          status: "ready_for_clarification"
        )

      if index == 1 do
        work_request
        |> Ecto.Changeset.change(completed_at: DateTime.utc_now(:microsecond), completion_source: "operator")
        |> repo.update!()
      end
    end

    for index <- 1..50 do
      create_work_package!(repo,
        id: "SYMPP-PERF-#{String.pad_leading(to_string(index), 2, "0")}",
        status: "created"
      )
    end

    RetentionThrottle.reset(DashboardQueryCountingRepo)
    assert {:ok, _payload} = LocalOperatorDashboard.operator_dashboard_hydrated_payload(DashboardQueryCountingRepo)

    {base_payload, priority_metrics} =
      dashboard_benchmark(1, fn ->
        LocalOperatorDashboard.operator_dashboard_payload(DashboardQueryCountingRepo)
      end)

    {hydrated_payload, hydrated_metrics} =
      dashboard_benchmark(1, fn ->
        LocalOperatorDashboard.operator_dashboard_hydrated_payload(DashboardQueryCountingRepo)
      end)

    {:ok, deferred_payload} = LocalOperatorDashboard.operator_dashboard_deferred_payload(DashboardQueryCountingRepo)
    priority_metrics = Map.put(priority_metrics, :bytes, byte_size(Jason.encode!(base_payload)))
    hydrated_metrics = Map.put(hydrated_metrics, :bytes, byte_size(Jason.encode!(hydrated_payload)))

    assert base_payload.deferred == %{dashboard_sections: true}
    assert deferred_payload.deferred == %{dashboard_sections: false}
    assert hydrated_payload.deferred == %{dashboard_sections: false}
    assert hydrated_payload.work_requests.total_count == 20
    assert hydrated_payload.work_packages == []
    assert priority_metrics.queries <= 20
    assert hydrated_metrics.queries <= 105
    assert priority_metrics.queries < hydrated_metrics.queries
    assert priority_metrics.bytes < hydrated_metrics.bytes

    maybe_export_dashboard_fixture(repo)

    if System.get_env("SYMPP_DASHBOARD_BENCHMARK") == "1" do
      IO.puts("DASHBOARD_BENCHMARK " <> Jason.encode!(%{priority: priority_metrics, hydrated: hydrated_metrics}))
    end
  end

  test "local operator dashboard reads do not write after migration bootstrap" do
    {bootstrap_queries, queries} =
      with_local_operator_endpoint(fn ->
        {_bootstrap_payload, bootstrap_queries} = capture_queries(&local_operator_dashboard_payload/0)
        {_payload, queries} = capture_queries(&local_operator_dashboard_payload/0)
        {bootstrap_queries, queries}
      end)

    write_query? = &Regex.match?(~r/^\s*(INSERT|UPDATE|DELETE|REPLACE|CREATE|ALTER|DROP)\b/i, &1)

    assert Enum.filter(bootstrap_queries, write_query?) in [
             [],
             ["CREATE TABLE IF NOT EXISTS \"schema_migrations\" (\"version\" INTEGER PRIMARY KEY, \"inserted_at\" TEXT)"]
           ]

    assert Enum.filter(queries, write_query?) == []
  end

  test "dashboard fixture export builds a deterministic isolated graph ledger" do
    path = Path.join(System.tmp_dir!(), "sympp-dashboard-graph-fixture-#{System.unique_integer([:positive])}.sqlite3")
    clone_path = path <> ".clone"
    on_exit(fn -> Enum.each([path, path <> "-wal", path <> "-shm", clone_path, clone_path <> "-wal", clone_path <> "-shm"], &File.rm/1) end)

    assert :ok = DashboardFixtureDatabase.export!(path)
    File.cp!(path, clone_path)
    refute File.exists?(clone_path <> "-wal")
    refute File.exists?(clone_path <> "-shm")

    {:ok, pid} = Repo.start_link(database: clone_path, name: nil, pool_size: 1, log: false)
    previous_repo = Repo.put_dynamic_repo(pid)

    try do
      assert %{rows: [["ok"]]} = Repo.query!("PRAGMA quick_check")
      assert {:ok, _fixture_payload} = LocalOperatorDashboard.operator_dashboard_hydrated_payload(Repo)
      assert {:ok, fixture_deferred_payload} = LocalOperatorDashboard.operator_dashboard_deferred_payload(Repo)
      assert byte_size(Jason.encode!(fixture_deferred_payload)) <= 180_000
      refute Map.has_key?(fixture_deferred_payload, :board)

      expected_signal_keys =
        MapSet.new([
          :active_agent_run,
          :active_blocker_count,
          :active_blockers,
          :id,
          :inserted_at,
          :latest_progress_at,
          :metadata,
          :runtime,
          :updated_at
        ])

      assert Enum.all?(fixture_deferred_payload.work_packages, &(MapSet.new(Map.keys(&1)) == expected_signal_keys))

      parse_signal = Enum.find(fixture_deferred_payload.work_packages, &(&1.id == "WP-FANOUT-PARSE"))
      assert parse_signal.runtime.completed_count == 1
      assert is_map(parse_signal.metadata.pr)
      assert is_binary(parse_signal.latest_progress_at)

      blocker_signal = Enum.find(fixture_deferred_payload.work_packages, &(&1.id == "WP-RECOVERY-SUCCESSOR"))
      assert blocker_signal.active_blocker_count == 1
      assert [%{id: "fixture-schema", active: true}] = blocker_signal.active_blockers
      assert is_binary(blocker_signal.inserted_at)
      assert is_binary(blocker_signal.updated_at)

      assert Repo.all(WorkRequest) |> Enum.map(& &1.id) |> Enum.sort() == [
               "WR-FIXTURE-DENSE",
               "WR-FIXTURE-FANOUT",
               "WR-FIXTURE-KRAKEN-SCALE",
               "WR-FIXTURE-RECOVERY"
             ]

      assert Repo.all(WorkRequest) |> Enum.all?(&(&1.inserted_at == ~U[2026-07-18 08:00:00.000000Z]))

      assert {:ok, fanout} = DeliveryBoard.project(Repo, "WR-FIXTURE-FANOUT")
      fanout_packages = Map.new(fanout.work_packages, &{&1.id, &1})
      assert fanout_packages["WP-FANOUT-PARSE"].work_package.worker_signal.status == "active"
      assert fanout_packages["WP-FANOUT-SOURCE"].work_package.pr_signal.status == "merged"
      assert fanout_packages["WP-FANOUT-INDEX"].work_package.review_signal.status == "pending"
      assert fanout_packages["WP-FANOUT-JOIN"].work_package.dependency_signal.required == 2
      assert fanout_packages["WP-FANOUT-JOIN"].operational_state.key == "dependency_blocked"
      assert fanout_packages["WP-FANOUT-PLAYTEST"].operational_state.key == "ready_for_worker"
      assert fanout_packages["WP-FANOUT-PLAYTEST"].work_package.dependency_signal.satisfied == 1

      assert {:ok, [fanout_detail]} = Dashboard.work_request_board_details(Repo, ["WR-FIXTURE-FANOUT"])
      assert fanout_detail.product_tree.execution_graph.available
      assert length(fanout_detail.product_tree.execution_graph.effective_edges) == 6
      assert length(fanout_detail.product_tree.execution_graph.topological_order) == 6
      assert fanout_detail.product_tree.root_work_package_ids == ["WP-FANOUT-PLAYTEST"]

      assert {:ok, [kraken_detail]} = Dashboard.work_request_board_details(Repo, ["WR-FIXTURE-KRAKEN-SCALE"])
      assert length(kraken_detail.work_packages) == 49
      refute Map.has_key?(kraken_detail, :delivery_board)
      assert length(kraken_detail.product_tree.nodes) == 10
      assert length(kraken_detail.product_tree.execution_graph.effective_edges) == 11

      kraken_edges =
        kraken_detail.product_tree.execution_graph.effective_edges
        |> Enum.map(&{&1.prerequisite_work_package_id, &1.dependent_work_package_id})
        |> MapSet.new()

      assert MapSet.subset?(
               MapSet.new([
                 {"WP-KRAKEN-07", "WP-KRAKEN-04"},
                 {"WP-KRAKEN-31", "WP-KRAKEN-27"},
                 {"WP-KRAKEN-47", "WP-KRAKEN-10"}
               ]),
               kraken_edges
             )

      projected_parse =
        Enum.find(fanout_detail.work_packages, &(&1.id == "WP-FANOUT-PARSE"))

      assert projected_parse.worker_signal["status"] == "active"
      assert get_in(projected_parse.pr_signal, ["checks", "status"]) == "pending"

      parse = Repo.get!(WorkPackage, "WP-FANOUT-PARSE")
      parse_context = Dashboard.work_package_contexts(Repo, [parse])[parse.id]
      assert parse_context.worker_signal.status == "active"
      assert parse_context.runtime_state.active?

      Repo.get!(ClaimLease, "LEASE-RUN-FANOUT-PARSE")
      |> ClaimLease.update_changeset(%{status: "released", released_at: ~U[2026-07-18 09:00:00.000000Z]})
      |> Repo.update!()

      Repo.get!(AgentRun, "RUN-FANOUT-PARSE")
      |> AgentRun.update_changeset(%{status: "running", last_seen_at: ~U[2020-01-01 00:00:00.000000Z]})
      |> Repo.update!()

      stale_context = Dashboard.work_package_contexts(Repo, [parse])[parse.id]
      assert stale_context.worker_signal.status == "stale"
      refute stale_context.runtime_state.active?
      refute stale_context.card.operational_state.has_active_worker

      assert {:ok, _branch_advance} =
               PlanningRepository.append_progress_event(Repo, %{
                 work_package_id: parse.id,
                 summary: "Fixture branch advanced",
                 status: "branch_attached",
                 payload: %{type: "branch", source_tool: "attach_branch", branch: "feat/fixture-parse", head_sha: "parse-next-head"},
                 created_at: ~U[2026-07-18 09:01:00.000000Z]
               })

      assert {:ok, advanced_fanout} = DeliveryBoard.project(Repo, "WR-FIXTURE-FANOUT")
      advanced_parse = Enum.find(advanced_fanout.work_packages, &(&1.id == parse.id))
      assert advanced_parse.work_package.review_signal.status == "pending"

      assert {:ok, recovery} = DeliveryBoard.project(Repo, "WR-FIXTURE-RECOVERY")
      recovery_packages = Map.new(recovery.work_packages, &{&1.id, &1})
      assert recovery_packages["WP-RECOVERY-OLD"].successor.work_package_id == "WP-RECOVERY-SUCCESSOR"
      assert recovery_packages["WP-RECOVERY-SKIPPED"].raw_status == "skipped"
      assert recovery_packages["WP-RECOVERY-SUCCESSOR"].work_package.review_signal.status == "pending"
      assert Enum.count(recovery.work_packages, &(get_in(&1, [:work_package, :blocker_state, :active?]) == true)) == 1
      assert Repo.all(ClaimLease) |> length() == 6

      assert {:ok, [recovery_detail]} = Dashboard.work_request_board_details(Repo, ["WR-FIXTURE-RECOVERY"])
      assert recovery_detail.product_tree.summary.blocker_count == 1

      architect_anchor =
        Repo.get!(WorkPackage, "WP-RECOVERY-VALIDATE")
        |> Ecto.Changeset.change(kind: "delegation")
        |> Repo.update!()

      assert {:ok, _architect_lease} =
               ClaimLeaseService.claim(
                 Repo,
                 architect_anchor.id,
                 %{"actor_kind" => "agent", "actor_id" => "fixture:architect", "actor_display_name" => "fixture-architect"},
                 stale_after_ms: 60_000
               )

      architect_context = Dashboard.work_package_contexts(Repo, [architect_anchor])[architect_anchor.id]
      assert architect_context.runtime_state.active?
      assert is_nil(architect_context.worker_signal)
      refute architect_context.card.operational_state.has_active_worker

      assert {:ok, dense_tree} = ProductTree.tree_for_work_request(Repo, "WR-FIXTURE-DENSE")
      assert length(dense_tree.nodes) == 3
      assert length(dense_tree.dependency_edges) == 18
      assert Repo.all(AgentRun) |> length() == 6

      assert %AccessGrant{
               id: "GRANT-FANOUT-PLAYTEST",
               display_key: "PLAY",
               claimed_at: nil,
               grant_role: "worker",
               expires_at: ~U[2099-01-01 00:00:00.000000Z]
             } = Repo.get_by(AccessGrant, work_package_id: "WP-FANOUT-PLAYTEST")

      assert Repo.all(PlanNode)
             |> Enum.filter(&(&1.work_package_id == "WP-FANOUT-PLAYTEST"))
             |> Enum.map(& &1.id)
             |> Enum.sort() == ["PLAN-FANOUT-PLAYTEST-01"]

      {claim_response, claimed_server} =
        Server.handle_response_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "fixture-playtest-claim",
            "method" => "tools/call",
            "params" => %{
              "name" => "claim_local_assignment",
              "arguments" => %{
                "work_package_id" => "WP-FANOUT-PLAYTEST",
                "claimed_by" => "fictional-playtest-worker"
              }
            }
          },
          Server.new(Config.default(repo: Repo, repo_root: @repo_root), initialized: true)
        )

      assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) ==
               "WP-FANOUT-PLAYTEST"

      playtest = Repo.get!(WorkPackage, "WP-FANOUT-PLAYTEST")
      active_context = Dashboard.work_package_contexts(Repo, [playtest])[playtest.id]
      assert active_context.worker_signal.status == "active"
      assert active_context.runtime_state.active?
      assert active_context.card.operational_state.has_active_worker

      ready_playtest = playtest |> Ecto.Changeset.change(status: "ready_for_merge") |> Repo.update!()

      {release_response, _released_server} =
        Server.handle_response_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "fixture-playtest-release",
            "method" => "tools/call",
            "params" => %{
              "name" => "release_current_assignment",
              "arguments" => %{"reason" => "fixture playtest ready"}
            }
          },
          claimed_server
        )

      assert get_in(release_response, ["result", "structuredContent", "binding_cleared"]) == true

      released_context = Dashboard.work_package_contexts(Repo, [ready_playtest])[ready_playtest.id]
      assert released_context.worker_signal.status == "idle"
      refute released_context.runtime_state.active?
      refute released_context.card.operational_state.has_active_worker
    after
      Repo.put_dynamic_repo(previous_repo)
      GenServer.stop(pid)
    end
  end

  test "hydrated dashboard rejects unsupported methods" do
    assert json_response(post(build_conn(), "/api/v1/sympp/operator/dashboard/hydrated", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}
  end

  test "local operator dashboard returns compact WorkRequest board details and lean modal enrichment", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request =
        create_work_request!(
          repo,
          id: "WR-LOCAL-COMPACT-DETAIL",
          status: "ready_for_slicing",
          human_description: "Full operator detail should stay lazy.",
          constraints: %{heavy: "constraint"}
        )

      assert {:ok, _decision} =
               WorkRequestRepository.record_decision(repo, work_request.id, decision_attrs(id: "WRD-LOCAL-COMPACT-DETAIL"))

      Enum.each(2..5, fn sequence ->
        assert {:ok, _decision} =
                 WorkRequestRepository.record_decision(
                   repo,
                   work_request.id,
                   decision_attrs(id: "WRD-LOCAL-COMPACT-DETAIL-#{sequence}")
                 )
      end)

      assert {:ok, work_package} =
               CanonicalWorkPackageFixtures.add_work_package(
                 repo,
                 work_request.id,
                 work_package_attrs(
                   id: "WRS-LOCAL-COMPACT-DETAIL",
                   acceptance_criteria: ["Large acceptance text"],
                   validation_steps: ["Large validation text"],
                   allowed_file_globs: ["large/**"],
                   stop_conditions: ["Large stop condition"]
                 )
               )

      assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

      work_package =
        create_matching_work_package!(repo, work_request, approved_slice,
          id: "SYMPP-LOCAL-COMPACT-DETAIL",
          status: "ready_for_worker"
        )

      assert {:ok, _dispatched_slice} =
               CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", work_package.id)

      assert {:ok, _delivery} =
               WorkRequestRepository.record_work_package_delivery(
                 repo,
                 work_request.id,
                 work_package.id,
                 delivery_attrs(%{
                   outcome: "completed_no_pr",
                   idempotency_key: "local-operator-compact-detail",
                   no_pr_evidence: "Full delivery evidence should stay lazy."
                 })
               )

      assert {:ok, _comment} =
               CommentService.create(repo, %{
                 target_kind: "work_request",
                 target_id: work_request.id,
                 body: "Full comment should stay lazy.",
                 source_type: "operator",
                 author_name: "operator"
               })

      dashboard = local_operator_dashboard_payload()
      compact_detail = work_request_detail(dashboard, work_request.id)
      [compact_slice] = compact_detail["work_packages"]

      refute Map.has_key?(compact_detail, "decision_logs")
      refute Map.has_key?(compact_detail, "comments")
      refute Map.has_key?(compact_detail["work_request"], "human_description")
      refute Map.has_key?(compact_detail["work_request"], "constraints")
      refute Map.has_key?(compact_slice, "acceptance_criteria")
      refute Map.has_key?(compact_slice, "validation_steps")
      refute Map.has_key?(compact_slice, "allowed_file_globs")
      refute Map.has_key?(compact_slice, "stop_conditions")
      refute Map.has_key?(compact_slice["delivery"], "no_pr_evidence")
      assert compact_slice["operational_state"]["key"] == "completed_no_pr"

      enrichment =
        local_operator_conn()
        |> get("/api/v1/sympp/operator/work-requests/#{work_request.id}")
        |> json_response(200)

      assert Enum.map(enrichment["decision_logs"], & &1["id"]) == [
               "WRD-LOCAL-COMPACT-DETAIL-5",
               "WRD-LOCAL-COMPACT-DETAIL-4",
               "WRD-LOCAL-COMPACT-DETAIL-3"
             ]

      assert [%{"body" => "Full comment should stay lazy."}] = enrichment["comments"]
      assert enrichment["work_request"]["human_description"] == "Full operator detail should stay lazy."
      assert enrichment["work_request"]["constraints"] == %{"heavy" => "constraint"}
      assert enrichment["summary"]["decision_count"] == 5
      assert enrichment["summary"]["comment_count"] == 1
      refute Map.has_key?(enrichment, "work_packages")
      refute Map.has_key?(enrichment, "product_tree")
      refute Map.has_key?(enrichment, "delivery_board")

      slice_enrichment =
        local_operator_conn()
        |> get("/api/v1/sympp/operator/work-requests/#{work_request.id}?work_package_id=#{compact_slice["id"]}")
        |> json_response(200)

      assert [full_slice] = slice_enrichment["work_packages"]
      assert full_slice["id"] == compact_slice["id"]
      assert full_slice["acceptance_criteria"] == ["Large acceptance text"]
      assert full_slice["validation_steps"] == ["Large validation text"]
      assert full_slice["allowed_file_globs"] == ["large/**"]
      assert full_slice["stop_conditions"] == ["Large stop condition"]
      refute Map.has_key?(slice_enrichment, "product_tree")
      refute Map.has_key?(slice_enrichment, "delivery_board")
    end)
  end

  test "local operator dashboard projects delivery closeout states into slice cards", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-DELIVERY", status: "ready_for_slicing")

      assert {:ok, work_package} =
               CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-LOCAL-DELIVERY-MERGED"))

      assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

      work_package =
        create_matching_work_package!(repo, work_request, approved_slice,
          id: "SYMPP-LOCAL-DELIVERY-MERGED",
          status: "ready_for_worker"
        )

      assert {:ok, _progress} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: work_package.id,
                 summary: "Worker progress exists",
                 status: "progress",
                 payload: %{type: "progress"}
               })

      assert {:ok, _dispatched_slice} =
               CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", work_package.id)

      assert {:ok, _delivery} =
               WorkRequestRepository.record_work_package_delivery(
                 repo,
                 work_request.id,
                 work_package.id,
                 delivery_attrs(%{
                   outcome: "pr_merged",
                   idempotency_key: "local-operator-dashboard-delivery-merged",
                   pr_url: "https://github.com/Pimpmuckl/symphony-plus-plus/pull/905",
                   pr_merged_at: ~U[2026-05-24 12:30:00.000000Z],
                   merge_commit_sha: "merge-905"
                 })
               )

      payload = local_operator_dashboard_payload()
      detail = work_request_detail(payload, work_request.id)
      [slice] = detail["work_packages"]
      [card] = Enum.filter(payload["work_requests"]["work_requests"], &(&1["id"] == work_request.id))

      assert card["status"] == "sliced"
      refute Map.has_key?(card, "operational_state")
      assert get_in(detail, ["work_request", "operational_state", "key"]) == "delivered"
      assert get_in(detail, ["work_request", "operational_state", "has_started"]) == true
      assert get_in(detail, ["work_request", "operational_state", "has_active_worker"]) == false
      assert get_in(detail, ["work_request", "operational_state", "is_stale"]) == true
      assert get_in(slice, ["operational_state", "key"]) == "delivered"
      assert get_in(slice, ["operational_state", "label"]) == "Delivered"
      assert get_in(slice, ["operational_state", "raw_status"]) == "ready_for_worker"
      assert get_in(slice, ["operational_state", "work_package_status"]) == "ready_for_worker"
      assert get_in(slice, ["delivery", "outcome"]) == "pr_merged"
      assert slice["attention_reason_codes"] == []
      assert get_in(slice, ["operational_state", "attention_items"]) == []
    end)
  end

  test "local operator dashboard infers canonical repo identity from local origin", %{repo: repo} do
    with_local_repo_origin("https://github.com/Pimpmuckl/symphony-plus-plus.git", fn ->
      with_local_operator_endpoint(fn ->
        assert {:ok, work_package} =
                 WorkPackageRepository.create(
                   repo,
                   WorkPackageFactory.attrs(
                     id: "SYMPP-REPO-IDENTITY",
                     repo: "symphony-plus-plus",
                     base_branch: "main"
                   )
                 )

        assert {:ok, _work_request} =
                 WorkRequestRepository.create(repo, %{
                   title: "Operator intake",
                   repo: "symphony-plus-plus",
                   base_branch: "main",
                   work_type: "feature",
                   human_description: "Build the dashboard.",
                   constraints: %{},
                   desired_dispatch_shape: "architect_led_feature_branch",
                   status: "ready_for_clarification"
                 })

        assert {:ok, owner_session} =
                 SoloSessionsService.create_or_attach_current(repo, %{
                   repo: "Pimpmuckl/symphony-plus-plus",
                   base_branch: "main",
                   workspace_path: Path.join(@repo_root, "repo-identity-owner"),
                   caller_id: "repo-identity-owner",
                   title: "Owner scoped solo"
                 })

        assert {:ok, bare_session} =
                 SoloSessionsService.create_or_attach_current(repo, %{
                   repo: "symphony-plus-plus",
                   base_branch: "main",
                   workspace_path: Path.join(@repo_root, "repo-identity-bare"),
                   caller_id: "repo-identity-bare",
                   title: "Bare scoped solo"
                 })

        guidance_grant = create_claimed_worker_grant(repo, work_package.id, "repo-identity-worker")

        assert {:ok, _guidance_request} =
                 GuidanceRequestRepository.create(repo, %{
                   work_package_id: work_package.id,
                   requester_grant_id: guidance_grant.id,
                   requested_by: "repo-identity-worker",
                   idempotency_key: "repo-identity-guidance",
                   summary: "Needs repo identity decision",
                   question: "Which repo identity should the dashboard show?",
                   context: "Operator dashboard canonical repo identity coverage.",
                   status: "human_info_needed"
                 })

        payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard"), 200)
        deferred_payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard/deferred"), 200)
        archived_payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard?surface=archived"), 200)
        solo_payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard?surface=solo"), 200)

        refute Enum.any?(deferred_payload["work_packages"], &(&1["id"] == work_package.id))

        assert [%{"repo_key" => "symphony-plus-plus", "repo_remote" => "Pimpmuckl/symphony-plus-plus"}] =
                 payload["work_requests"]["work_requests"]

        assert [%{"work_request" => %{"repo_key" => "symphony-plus-plus", "repo_remote" => "Pimpmuckl/symphony-plus-plus"}}] =
                 deferred_payload["work_request_details"]

        assert [
                 %{
                   "repo" => "symphony-plus-plus",
                   "repo_key" => "symphony-plus-plus",
                   "repo_display" => "symphony-plus-plus",
                   "repo_remote" => "Pimpmuckl/symphony-plus-plus",
                   "repo_aliases" => ["Pimpmuckl/symphony-plus-plus", "symphony-plus-plus"]
                 }
               ] = deferred_payload["guidance_requests"]["guidance_requests"]

        refute Map.has_key?(payload, "archived_work_requests")
        refute Map.has_key?(payload, "solo_sessions")
        refute Map.has_key?(payload, "work_request_details")
        refute Map.has_key?(payload, "board")
        assert payload["deferred"] == %{"dashboard_sections" => true}
        assert deferred_payload["deferred"] == %{"dashboard_sections" => false}
        assert archived_payload["archived_work_requests"] == %{"total_count" => 0, "work_requests" => []}

        solo_sessions = solo_payload["solo_sessions"]["solo_sessions"]
        assert Enum.map(solo_sessions, & &1["id"]) |> Enum.sort() == Enum.sort([owner_session.id, bare_session.id])
        assert Enum.all?(solo_sessions, &(&1["repo_key"] == "symphony-plus-plus"))
        assert Enum.all?(solo_sessions, &(&1["repo_display"] == "symphony-plus-plus"))
        assert Enum.all?(solo_sessions, &(&1["repo_remote"] == "Pimpmuckl/symphony-plus-plus"))

        assert {:ok, repo_identity_catalog} = Dashboard.local_operator_repo_identity_catalog(repo)
        assert {:ok, streams} = Dashboard.solo_session_streams(repo, repo_identity_catalog: repo_identity_catalog)

        assert [
                 %{
                   repo_key: "symphony-plus-plus",
                   repo_display: "symphony-plus-plus",
                   repo_remote: "Pimpmuckl/symphony-plus-plus",
                   repo_aliases: ["Pimpmuckl/symphony-plus-plus", "symphony-plus-plus"],
                   base_branch: "main",
                   solo_session_count: 2
                 } = stream
               ] = streams

        assert stream.repo == "symphony-plus-plus"
      end)
    end)
  end

  test "local operator dashboard invalidates after MCP-side WorkPackage writes", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-DASHBOARD-INVALIDATE",
        repo: "symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    assert :ok = DashboardPubSub.subscribe()

    assert {:ok, _slice} =
             CanonicalWorkPackageFixtures.add_work_package_for_authoring(
               repo,
               work_request.id,
               work_package_attrs(id: "WRS-DASHBOARD-INVALIDATE", title: "Refresh dashboard")
             )

    assert_receive :operator_dashboard_changed
    refute_receive :operator_dashboard_changed, 50
  end

  test "local operator WorkRequest mutations invalidate exactly once", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request =
        create_work_request!(repo,
          id: "WR-DASHBOARD-LOCAL-INVALIDATE",
          repo: "symphony-plus-plus",
          base_branch: "main",
          status: "ready_for_slicing"
        )

      work_request
      |> Ecto.Changeset.change(completed_at: DateTime.utc_now(:microsecond), completion_source: "operator")
      |> repo.update!()

      assert :ok = DashboardPubSub.subscribe()

      local_operator_conn()
      |> post("/api/v1/sympp/operator/work-requests/#{work_request.id}/archive", %{})
      |> json_response(200)

      assert_receive :operator_dashboard_changed
      refute_receive :operator_dashboard_changed, 50
    end)
  end

  test "coalesced mutation invalidation survives later response failure" do
    assert :ok = DashboardPubSub.subscribe()

    assert {{:error, :response_failed}, true} =
             DashboardPubSub.coalesce_changed(fn ->
               assert :ok = DashboardPubSub.broadcast_changed()
               assert :ok = DashboardPubSub.broadcast_changed()
               {:error, :response_failed}
             end)

    assert_receive :operator_dashboard_changed
    refute_receive :operator_dashboard_changed, 50
  end

  test "local operator dashboard invalidates after local operator comment writes", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request =
        create_work_request!(repo,
          id: "WR-DASHBOARD-COMMENT-INVALIDATE",
          repo: "symphony-plus-plus",
          base_branch: "main",
          status: "ready_for_slicing"
        )

      assert :ok = DashboardPubSub.subscribe()

      local_operator_conn()
      |> post("/api/v1/sympp/operator/comments", %{
        "target_kind" => "work_request",
        "target_id" => work_request.id,
        "body" => "Refresh dashboard after comment."
      })
      |> json_response(201)

      assert_receive :operator_dashboard_changed
      refute_receive :operator_dashboard_changed, 50
    end)
  end

  test "local operator dashboard invalidates after work package status writes", %{repo: repo} do
    work_package =
      create_work_package!(repo,
        id: "SYMPP-DASHBOARD-PACKAGE-INVALIDATE",
        status: "claimed"
      )

    assert :ok = DashboardPubSub.subscribe()
    assert {:ok, _work_package} = WorkPackageRepository.update_status(repo, work_package.id, "claimed", "planning")
    assert_receive :operator_dashboard_changed
    refute_receive :operator_dashboard_changed, 50
  end

  test "rolled-back WorkPackage writes do not invalidate the dashboard", %{repo: repo} do
    work_package = create_work_package!(repo, id: "SYMPP-DASHBOARD-PACKAGE-ROLLBACK")
    assert :ok = DashboardPubSub.subscribe()

    assert {:error, :forced_rollback} =
             repo.transaction(fn ->
               assert {:ok, _work_package} =
                        WorkPackageRepository.update(repo, work_package.id, %{title: "Rolled back title"})

               repo.rollback(:forced_rollback)
             end)

    refute_receive :operator_dashboard_changed, 50
    assert {:ok, persisted} = WorkPackageRepository.get(repo, work_package.id)
    assert persisted.title == work_package.title
  end

  test "local operator dashboard projects persisted local path repos through their git origin", %{repo: repo} do
    repo_path =
      TestSupport.git_repo_with_origin_fixture!(
        "https://github.com/Pimpmuckl/nextide-saas-live-chat.git",
        prefix: "sympp-dashboard-repo-path"
      )

    try do
      with_local_operator_endpoint(fn ->
        assert {:ok, work_package} =
                 WorkPackageRepository.create(
                   repo,
                   WorkPackageFactory.attrs(
                     id: "SYMPP-REPO-PATH-IDENTITY",
                     repo: repo_path,
                     base_branch: "main"
                   )
                 )

        assert {:ok, work_request} =
                 WorkRequestRepository.create(repo, %{
                   title: "Path repo projection",
                   repo: repo_path,
                   base_branch: "main",
                   work_type: "feature",
                   human_description: "Project the path repo through local git origin.",
                   constraints: %{},
                   desired_dispatch_shape: "architect_led_feature_branch",
                   status: "ready_for_clarification"
                 })

        assert {:ok, solo_session} =
                 SoloSessionsService.create_or_attach_current(repo, %{
                   repo: repo_path,
                   base_branch: "main",
                   workspace_path: Path.join(@repo_root, "repo-path-identity-solo"),
                   caller_id: "repo-path-identity-solo",
                   title: "Path scoped solo"
                 })

        payload = local_operator_dashboard_payload()
        refute Enum.any?(payload["work_packages"], &(&1["id"] == work_package.id))

        assert [%{"repo" => ^repo_path, "repo_key" => "nextide-saas-live-chat", "repo_remote" => "Pimpmuckl/nextide-saas-live-chat"}] =
                 payload["work_requests"]["work_requests"]

        solo_session_id = solo_session.id

        assert [%{"id" => ^solo_session_id, "repo" => ^repo_path, "repo_key" => "nextide-saas-live-chat", "repo_remote" => "Pimpmuckl/nextide-saas-live-chat"}] =
                 payload["solo_sessions"]["solo_sessions"]

        assert {:ok, persisted_package} = WorkPackageRepository.get(repo, work_package.id)
        assert {:ok, persisted_request} = WorkRequestRepository.get(repo, work_request.id)
        assert {:ok, persisted_session} = SoloSessionsService.get(repo, solo_session.id)

        assert persisted_package.repo == repo_path
        assert persisted_request.repo == repo_path
        assert persisted_session.repo == repo_path
      end)
    after
      File.rm_rf(repo_path)
    end
  end

  test "local operator dashboard collapses raw remote bare and local path repo identities", %{repo: repo} do
    repo_path =
      TestSupport.git_repo_with_origin_fixture!(
        "https://github.com/Pimpmuckl/nextide-saas-vod-intelligence.git",
        prefix: "sympp-dashboard-repo-mixed"
      )

    try do
      with_local_operator_endpoint(fn ->
        raw_remote = "Pimpmuckl/nextide-saas-vod-intelligence"
        bare_repo = "nextide-saas-vod-intelligence"

        assert {:ok, work_package} =
                 WorkPackageRepository.create(
                   repo,
                   WorkPackageFactory.attrs(
                     id: "SYMPP-REPO-MIXED-REMOTE",
                     repo: raw_remote,
                     base_branch: "main"
                   )
                 )

        assert {:ok, work_request} =
                 WorkRequestRepository.create(repo, %{
                   title: "Mixed repo identity projection",
                   repo: bare_repo,
                   base_branch: "main",
                   work_type: "feature",
                   human_description: "Collapse raw remote, bare repo, and local path identities.",
                   constraints: %{},
                   desired_dispatch_shape: "architect_led_feature_branch",
                   status: "ready_for_clarification"
                 })

        assert {:ok, solo_session} =
                 SoloSessionsService.create_or_attach_current(repo, %{
                   repo: repo_path,
                   base_branch: "main",
                   workspace_path: Path.join(@repo_root, "repo-mixed-identity-solo"),
                   caller_id: "repo-mixed-identity-solo",
                   title: "Path scoped solo"
                 })

        payload = local_operator_dashboard_payload()

        refute Enum.any?(payload["work_packages"], &(&1["id"] == work_package.id))

        assert [%{"id" => work_request_id, "repo" => ^bare_repo, "repo_key" => ^bare_repo, "repo_remote" => ^raw_remote}] =
                 payload["work_requests"]["work_requests"]

        assert work_request_id == work_request.id

        assert %{"work_request" => %{"repo" => ^bare_repo, "repo_key" => ^bare_repo, "repo_remote" => ^raw_remote}} =
                 work_request_detail(payload, work_request.id)

        solo_session_id = solo_session.id

        assert [%{"id" => ^solo_session_id, "repo" => ^repo_path, "repo_key" => ^bare_repo, "repo_remote" => ^raw_remote}] =
                 payload["solo_sessions"]["solo_sessions"]

        assert {:ok, repo_identity_catalog} = Dashboard.local_operator_repo_identity_catalog(repo)
        assert {:ok, streams} = Dashboard.solo_session_streams(repo, repo_identity_catalog: repo_identity_catalog)

        assert [
                 %{
                   repo: ^repo_path,
                   repo_key: ^bare_repo,
                   repo_remote: ^raw_remote,
                   base_branch: "main",
                   solo_session_count: 1
                 }
               ] = streams

        assert {:ok, persisted_package} = WorkPackageRepository.get(repo, work_package.id)
        assert {:ok, persisted_request} = WorkRequestRepository.get(repo, work_request.id)
        assert {:ok, persisted_session} = SoloSessionsService.get(repo, solo_session.id)

        assert persisted_package.repo == raw_remote
        assert persisted_request.repo == bare_repo
        assert persisted_session.repo == repo_path
      end)
    after
      File.rm_rf(repo_path)
    end
  end

  test "record detail repo identity stays scoped unless a catalog is passed", %{repo: repo} do
    with_trusted_repo_remotes(["Pimpmuckl/symphony-plus-plus"], fn ->
      assert {:ok, _unrelated} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(
                   id: "SYMPP-REPO-DETAIL-CATALOG-SOURCE",
                   repo: "Pimpmuckl/symphony-plus-plus",
                   base_branch: "main"
                 )
               )

      assert {:ok, work_request} =
               WorkRequestRepository.create(repo, %{
                 title: "Scoped detail request",
                 repo: "symphony-plus-plus",
                 base_branch: "main",
                 work_type: "feature",
                 human_description: "Keep detail identity scoped.",
                 constraints: %{},
                 desired_dispatch_shape: "architect_led_feature_branch",
                 status: "ready_for_clarification"
               })

      assert {:ok, solo_session} =
               SoloSessionsService.create_or_attach_current(repo, %{
                 repo: "symphony-plus-plus",
                 base_branch: "main",
                 workspace_path: Path.join(@repo_root, "repo-detail-scoped-solo"),
                 caller_id: "repo-detail-scoped-solo",
                 title: "Scoped solo detail"
               })

      assert {:ok, request_detail} = Dashboard.work_request_detail(repo, work_request.id)
      assert request_detail.work_request.repo_remote == nil
      assert request_detail.work_request.repo_aliases == ["symphony-plus-plus"]

      assert {:ok, solo_detail} = Dashboard.solo_session_detail(repo, solo_session.id)
      assert solo_detail.solo_session.repo_remote == nil
      assert solo_detail.solo_session.repo_aliases == ["symphony-plus-plus"]
    end)
  end

  test "dashboard repo identity keeps conflicting owner-qualified repos separate", %{repo: repo} do
    with_local_repo_origin("https://github.com/alpha/shared.git", fn ->
      repo_cases = [
        {:bare, "SYMPP-REPO-CONFLICT-BARE", "shared"},
        {:alpha, "SYMPP-REPO-CONFLICT-A", "alpha/shared"},
        {:beta, "SYMPP-REPO-CONFLICT-B", "beta/shared"}
      ]

      packages = Map.new(repo_cases, &create_repo_identity_package!(repo, &1))
      requests = Map.new(repo_cases, &create_repo_identity_request!(repo, &1))
      expectations = Map.new(repo_cases, fn {key, _id, raw_repo} -> {key, repo_identity_expectation(raw_repo)} end)

      assert {:ok, repo_identity_catalog} = Dashboard.local_operator_repo_identity_catalog(repo)
      opts = [repo_identity_catalog: repo_identity_catalog]

      assert {:ok, board} = Dashboard.operator_board(repo, opts)

      cards_by_id =
        board.groups["created"]
        |> Map.new(&{&1.id, &1})

      Enum.each(repo_cases, fn {key, _id, _raw_repo} ->
        package_card = Map.fetch!(cards_by_id, Map.fetch!(packages, key).id)
        assert_repo_identity(package_card, Map.fetch!(expectations, key))
      end)

      assert {:ok, work_requests} = Dashboard.work_requests(repo, opts)

      request_cards_by_id =
        work_requests.work_requests
        |> Map.new(&{&1.id, &1})

      Enum.each(repo_cases, fn {key, _id, _raw_repo} ->
        request = Map.fetch!(requests, key)

        request_card = Map.fetch!(request_cards_by_id, request.id)
        assert_repo_identity(request_card, Map.fetch!(expectations, key))

        assert {:ok, detail} = Dashboard.work_request_detail(repo, request.id, opts)
        assert_repo_identity(detail.work_request, Map.fetch!(expectations, key))
      end)
    end)
  end

  test "local operator dashboard exposes active blocking edges", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request =
        create_work_request!(
          repo,
          id: "WR-ACTIVE-BLOCKING-EDGES",
          status: "ready_for_slicing",
          repo: "nextide/symphony-plus-plus",
          base_branch: "main"
        )

      assert {:ok, work_package} =
               CanonicalWorkPackageFixtures.add_work_package(
                 repo,
                 work_request.id,
                 work_package_attrs(id: "WRS-ACTIVE-BLOCKING-EDGES")
               )

      assert {:ok, approved_slice} =
               CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

      linked_package =
        create_matching_work_package!(
          repo,
          work_request,
          approved_slice,
          id: "SYMPP-ACTIVE-BLOCKING-LINKED",
          status: "planning"
        )

      assert {:ok, _dispatched_slice} =
               CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", linked_package.id)

      unlinked_package =
        create_work_package!(
          repo,
          id: "SYMPP-ACTIVE-BLOCKING-UNLINKED",
          status: "planning"
        )

      timestamp = ~U[2026-05-20 10:00:00Z]

      append_blocker_event!(repo, linked_package.id, "blocker-linked", true,
        summary: "Blocked by sk-secret123",
        body: "Bearer raw-secret-value",
        created_at: DateTime.add(timestamp, 1, :second)
      )

      append_blocker_event!(repo, linked_package.id, "blocker-resolved", true,
        summary: "Temporary blocker",
        created_at: DateTime.add(timestamp, 2, :second)
      )

      append_blocker_event!(repo, linked_package.id, "blocker-resolved", false,
        summary: "Resolved blocker",
        created_at: DateTime.add(timestamp, 3, :second)
      )

      append_blocker_event!(repo, unlinked_package.id, "blocker-unlinked", true,
        summary: "Blocked on review",
        created_at: DateTime.add(timestamp, 4, :second)
      )

      payload = local_operator_dashboard_payload()
      edges = payload["active_blocking_edges"]

      assert Enum.map(edges, & &1["blocker_id"]) == ["blocker-linked"]
      refute Enum.any?(edges, &(&1["blocker_id"] == "blocker-resolved"))

      assert [linked_edge] = edges
      assert linked_edge["from"] == %{"kind" => "work_package", "id" => linked_package.id}
      assert linked_edge["to"] == %{"kind" => "work_package", "id" => linked_package.id}
      assert linked_edge["work_request_id"] == work_request.id
      assert linked_edge["work_package_id"] == linked_package.id
      assert linked_edge["summary"] == "[REDACTED]"
      assert linked_edge["body"] == "[REDACTED]"

      linked_card =
        payload["work_packages"]
        |> Enum.find(&(&1["id"] == linked_package.id))

      assert linked_card["active_blocker_count"] == 1
      assert [%{"id" => "blocker-linked", "summary" => "[REDACTED]", "active" => true}] = linked_card["active_blockers"]

      repeated_payload = local_operator_dashboard_payload()
      assert Enum.map(repeated_payload["active_blocking_edges"], & &1["id"]) == Enum.map(edges, & &1["id"])

      assert {:ok, _outbound_blocker} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: unlinked_package.id,
                 summary: "Linked package is blocked",
                 status: "blocked",
                 idempotency_key: "blocker-unlinked-owner",
                 payload: %{
                   type: "blocker",
                   source_tool: "report_blocker",
                   blocker_id: "blocker-unlinked-owner",
                   active: true,
                   blocked_by: %{kind: "work_package", id: unlinked_package.id},
                   blocked_item: %{kind: "work_package", id: linked_package.id}
                 }
               })

      assert {:ok, %{active_blocking_edges: scoped_edges}} =
               Dashboard.operator_work_package_signals(repo, [linked_package.id], [])

      assert Enum.any?(scoped_edges, fn edge ->
               edge.blocker_id == "blocker-unlinked-owner" and
                 edge.work_package_id == unlinked_package.id and
                 edge.to == %{kind: "work_package", id: linked_package.id}
             end)
    end)
  end

  test "local operator config returns runtime paths" do
    with_local_operator_endpoint(fn ->
      payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/config"), 200)

      assert payload["apiBase"] == "/api/v1/sympp/operator"
      assert payload["basePath"] == ""
      assert payload["logoUrl"] == "/splusplus-logo.png"
      assert payload["dashboard"]["deferred"] == %{"dashboard_sections" => true}
    end)
  end

  test "local operator config keeps runtime bootstrap usable when priority data is unavailable" do
    with_local_operator_endpoint(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, sympp_repo: BusyRepo)

      payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/config"), 200)

      refute Map.has_key?(payload, "dashboard")
    end)
  end

  test "localhost requests without same-origin browser metadata are rejected" do
    with_local_operator_endpoint(fn ->
      conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(
                 post(conn, "/api/v1/sympp/operator/work-requests", %{
                   "title" => "Cross-origin request",
                   "repo" => "symphony-plus-plus",
                   "base_branch" => "main"
                 }),
                 401
               )
    end)
  end

  test "ordinary local dashboard load can mutate directly", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-ORDINARY-MUTATION", status: "ready_for_slicing")
      index = "<!doctype html><html><head></head><body><div id=\"root\"></div></body></html>"

      with_static_dashboard_file("index.html", index, fn ->
        shell_conn =
          build_conn(:get, "/sympp/board")
          |> Map.put(:host, "localhost")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> put_req_header("sec-fetch-site", "none")
          |> put_req_header("sec-fetch-mode", "navigate")
          |> get("/sympp/board")

        html_response(shell_conn, 200)

        payload =
          shell_conn
          |> recycle_local_operator_conn("http://localhost")
          |> post("/api/v1/sympp/operator/work-requests/#{work_request.id}/state", %{"state" => "completed"})
          |> json_response(200)

        assert payload["work_request"]["operational_state"]["key"] == "completed"
        assert is_binary(payload["work_request"]["completed_at"])

        assert {:ok, %{completed_at: %DateTime{}, completion_source: "operator"}} =
                 WorkRequestRepository.get(repo, work_request.id)
      end)
    end)
  end

  test "spp.localhost dashboard origin can load local operator config" do
    with_local_operator_endpoint(fn ->
      with_local_operator_dashboard_origin("http://spp.localhost:5174", fn ->
        index = "<!doctype html><html><head></head><body><div id=\"root\"></div></body></html>"

        with_static_dashboard_file("index.html", index, fn ->
          shell_conn =
            build_conn(:get, "/sympp/board")
            |> Map.put(:host, "spp.localhost")
            |> Map.put(:remote_ip, {127, 0, 0, 1})
            |> put_req_header("sec-fetch-site", "none")
            |> put_req_header("sec-fetch-mode", "navigate")
            |> ReactDashboardController.index(%{})

          assert redirected_to(shell_conn, 302) == "http://spp.localhost:5174/sympp/board"

          conn =
            build_conn()
            |> Map.put(:host, "127.0.0.1")
            |> Map.put(:remote_ip, {127, 0, 0, 1})
            |> put_req_header("origin", "http://spp.localhost:5174")
            |> put_req_header("sec-fetch-site", "same-site")
            |> put_req_header("sec-fetch-mode", "cors")
            |> put_req_header("sec-fetch-dest", "empty")
            |> get("/api/v1/sympp/operator/config")

          json_response(conn, 200)
        end)
      end)
    end)
  end

  test "same-origin local dashboard config is available without bootstrap state" do
    with_local_operator_endpoint(fn ->
      conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("sec-fetch-site", "same-origin")
        |> put_req_header("sec-fetch-mode", "cors")
        |> put_req_header("sec-fetch-dest", "empty")
        |> get("/api/v1/sympp/operator/config")

      json_response(conn, 200)
    end)
  end

  test "configured nonlocal dashboard origin is rejected" do
    with_local_operator_endpoint(fn ->
      with_local_operator_dashboard_origin("http://example.com:5174", fn ->
        conn =
          build_conn()
          |> Map.put(:host, "127.0.0.1")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> put_req_header("origin", "http://example.com:5174")
          |> put_req_header("sec-fetch-site", "same-site")
          |> put_req_header("sec-fetch-mode", "cors")
          |> put_req_header("sec-fetch-dest", "empty")
          |> get("/api/v1/sympp/operator/config")

        assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
      end)
    end)
  end

  test "local-looking cross-origin requests do not become local operator" do
    with_local_operator_endpoint(fn ->
      conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("origin", "http://localhost:3000")
        |> put_req_header("sec-fetch-site", "cross-site")

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(
                 post(conn, "/api/v1/sympp/operator/work-requests", %{
                   "title" => "Cross-origin request",
                   "repo" => "symphony-plus-plus",
                   "base_branch" => "main"
                 }),
                 401
               )
    end)
  end

  test "configured dashboard origin can load local operator config" do
    with_local_operator_endpoint(fn ->
      with_local_operator_dashboard_origin("http://127.0.0.1:5174", fn ->
        conn =
          build_conn()
          |> Map.put(:host, "127.0.0.1")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> put_req_header("origin", "http://127.0.0.1:5174")
          |> put_req_header("sec-fetch-site", "same-site")
          |> put_req_header("sec-fetch-mode", "cors")
          |> put_req_header("sec-fetch-dest", "empty")
          |> get("/api/v1/sympp/operator/config")

        json_response(conn, 200)
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == ["http://127.0.0.1:5174"]
      end)
    end)
  end

  test "configured local dashboard origin receives operator API preflight" do
    with_local_operator_endpoint(fn ->
      with_local_operator_dashboard_origin("http://127.0.0.1:5174", fn ->
        conn =
          build_conn(:options, "/api/v1/sympp/operator/work-requests")
          |> Map.put(:host, "127.0.0.1")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> put_req_header("origin", "http://127.0.0.1:5174")
          |> put_req_header("access-control-request-method", "POST")
          |> put_req_header("access-control-request-headers", "content-type")
          |> options("/api/v1/sympp/operator/work-requests")

        assert response(conn, 204) == ""
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == ["http://127.0.0.1:5174"]
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-methods") == ["GET, POST, OPTIONS"]
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-headers") == ["accept, content-type"]
      end)
    end)
  end

  test "configured dashboard origin rejects a different localhost hostname" do
    with_local_operator_endpoint(fn ->
      with_local_operator_dashboard_origin("http://spp.localhost:5174", fn ->
        conn =
          build_conn()
          |> Map.put(:host, "127.0.0.1")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> put_req_header("origin", "http://other.localhost:5174")
          |> put_req_header("sec-fetch-site", "same-site")
          |> put_req_header("sec-fetch-mode", "cors")
          |> put_req_header("sec-fetch-dest", "empty")
          |> get("/api/v1/sympp/operator/config")

        assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == []
      end)
    end)
  end

  test "local operator can fetch package detail through the dashboard API", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      %{work_package: work_package} = create_dashboard_fixture(repo, id: "SYMPP-LOCAL-OPERATOR-DETAIL")

      payload =
        local_operator_conn()
        |> get("/api/v1/sympp/operator/work-packages/#{work_package.id}")
        |> json_response(200)

      assert payload["work_package"]["id"] == work_package.id
      assert is_list(payload["progress"])
      assert is_map(payload["summary"])
    end)
  end

  test "local operator can sync GitHub PR merge state and request dashboard refresh", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      with_operator_github_client(fn ->
        work_package =
          create_work_package!(repo,
            id: "SYMPP-LOCAL-OPERATOR-GH-SYNC",
            kind: "hotfix",
            repo: "nextide/repo",
            status: "ready_for_merge"
          )

        assert {:ok, _branch} =
                 PlanningRepository.append_progress_event(repo, %{
                   work_package_id: work_package.id,
                   summary: "Branch attached",
                   status: "branch_attached",
                   payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-a"}
                 })

        assert {:ok, _pr} =
                 PlanningRepository.append_progress_event(repo, %{
                   work_package_id: work_package.id,
                   summary: "PR attached",
                   status: "pr_attached",
                   payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/repo/pull/22", head_sha: "head-a"}
                 })

        FakeGitHubClient.put_response("nextide/repo", 22, GitHubPullRequestFixtures.metadata(22, "head-a", merged?: true))

        payload =
          local_operator_conn()
          |> post("/api/v1/sympp/operator/github/sync-prs", %{})
          |> json_response(200)

        assert payload["sync"]["merged_count"] == 1
        assert [%{"work_package_id" => "SYMPP-LOCAL-OPERATOR-GH-SYNC", "status" => "merged"}] = payload["sync"]["results"]
        refute Map.has_key?(payload, "dashboard")
        assert get_in(payload, ["refresh", "dashboard"]) == true

        assert {:ok, updated} = WorkPackageRepository.get(repo, work_package.id)
        assert updated.status == "merged"
      end)
    end)
  end

  test "local operator auto GitHub sync uses gh CLI without token env", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      with_operator_gh_cli_runner(fn ->
        GitHubTestSupport.with_github_token_env(nil, fn ->
          work_package =
            create_work_package!(repo,
              id: "SYMPP-LOCAL-OPERATOR-GH-CLI-AUTO",
              kind: "hotfix",
              repo: "nextide/repo",
              status: "ready_for_merge"
            )

          assert {:ok, _branch} =
                   PlanningRepository.append_progress_event(repo, %{
                     work_package_id: work_package.id,
                     summary: "Branch attached",
                     status: "branch_attached",
                     payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-a"}
                   })

          assert {:ok, _pr} =
                   PlanningRepository.append_progress_event(repo, %{
                     work_package_id: work_package.id,
                     summary: "PR attached",
                     status: "pr_attached",
                     payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/repo/pull/23", head_sha: "head-a"}
                   })

          FakeGhCli.authenticate(:ok)
          FakeGhCli.put_response("nextide/repo", 23, GitHubPullRequestFixtures.gh_view(23, "head-a", merged?: true))

          payload =
            local_operator_conn()
            |> post("/api/v1/sympp/operator/github/sync-prs", %{mode: "auto"})
            |> json_response(200)

          assert payload["sync"]["merged_count"] == 1
          assert [%{"work_package_id" => "SYMPP-LOCAL-OPERATOR-GH-CLI-AUTO", "status" => "merged"}] = payload["sync"]["results"]
          refute Map.has_key?(payload, "dashboard")
          assert get_in(payload, ["refresh", "dashboard"]) == true

          assert {:ok, updated} = WorkPackageRepository.get(repo, work_package.id)
          assert updated.status == "merged"

          assert [
                   %{args: ["auth", "status", "--hostname", "github.com"]},
                   %{args: ["pr", "view", "23", "--repo", "nextide/repo", "--json", _fields]}
                 ] = FakeGhCli.commands()
        end)
      end)
    end)
  end

  test "local operator auto GitHub sync respects configured GitHub client", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      with_operator_authenticated_github_client(fn ->
        GitHubTestSupport.with_github_token_env(nil, fn ->
          work_package =
            create_work_package!(repo,
              id: "SYMPP-LOCAL-OPERATOR-GH-CONFIGURED-AUTO",
              kind: "hotfix",
              repo: "nextide/repo",
              status: "ready_for_merge"
            )

          assert {:ok, _branch} =
                   PlanningRepository.append_progress_event(repo, %{
                     work_package_id: work_package.id,
                     summary: "Branch attached",
                     status: "branch_attached",
                     payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-a"}
                   })

          assert {:ok, _pr} =
                   PlanningRepository.append_progress_event(repo, %{
                     work_package_id: work_package.id,
                     summary: "PR attached",
                     status: "pr_attached",
                     payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/repo/pull/25", head_sha: "head-a"}
                   })

          FakeGitHubClient.put_response("nextide/repo", 25, GitHubPullRequestFixtures.metadata(25, "head-a", merged?: true))

          payload =
            local_operator_conn()
            |> post("/api/v1/sympp/operator/github/sync-prs", %{mode: "auto"})
            |> json_response(200)

          assert payload["sync"]["merged_count"] == 1
          assert [%{"work_package_id" => "SYMPP-LOCAL-OPERATOR-GH-CONFIGURED-AUTO", "status" => "merged"}] = payload["sync"]["results"]
          assert FakeGhCli.commands() == []
        end)
      end)
    end)
  end

  test "local operator can fetch Solo Session detail through the dashboard API", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      assert {:ok, session} =
               SoloSessionsService.create_or_attach_current(repo, %{
                 repo: "nextide/demo-operator",
                 base_branch: "main",
                 workspace_path: @repo_root,
                 caller_id: "local-dashboard-test",
                 title: "Inspect solo modal"
               })

      assert {:ok, _entry} =
               SoloSessionsService.append_entry(repo, session.id, %{
                 entry_kind: "task_plan",
                 title: "Plan the solo session card",
                 body: "## Plan\n- Keep the card quiet.\n- Put the detail in the modal.",
                 status: "in_progress",
                 idempotency_key: "solo-dashboard-detail-test:plan"
               })

      payload =
        local_operator_conn()
        |> get("/api/v1/sympp/operator/solo-sessions/#{session.id}")
        |> json_response(200)

      assert payload["solo_session"]["id"] == session.id
      assert payload["entry_count"] == 1
      assert [%{"kind" => "task_plan", "body" => body}] = payload["entries"]
      assert body =~ "Keep the card quiet"
    end)
  end

  test "local operator can create a WorkRequest through the dashboard API", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-requests", %{
          "title" => "Fresh dashboard request",
          "repo" => "symphony-plus-plus",
          "base_branch" => "main",
          "work_type" => "feature",
          "human_description" => "Create a first-class operator cockpit.",
          "desired_dispatch_shape" => "architect_led_feature_branch",
          "constraints" => %{"allowed_paths" => ["elixir"]}
        })
        |> json_response(201)

      assert payload["work_request"]["work_request"]["status"] == "ready_for_clarification"
      refute Map.has_key?(payload, "dashboard")
      assert get_in(payload, ["refresh", "dashboard"]) == true

      dashboard_payload = local_operator_dashboard_payload()

      assert dashboard_payload["work_requests"]["total_count"] == 1

      assert {:ok, [stored]} = WorkRequestRepository.list(repo)
      assert stored.title == "Fresh dashboard request"
    end)
  end

  test "local operator can create a local-claim architect handoff", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      request =
        create_work_request!(repo,
          id: "WR-LOCAL-ARCHITECT-HANDOFF",
          status: "ready_for_slicing",
          desired_dispatch_shape: "architect_led_feature_branch"
        )

      payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-requests/#{request.id}/architect-handoff", %{})
        |> json_response(200)

      assert get_in(payload, ["architect_handoff", "status"]) == "created"

      assert get_in(payload, ["architect_handoff", "local_architect_claim"]) == %{
               "tool" => "claim_local_architect_assignment",
               "arguments" => %{"work_request_id" => request.id, "claimed_by" => "symphony-architect"},
               "required_runtime_arguments" => [],
               "secret_in_response" => false
             }
    end)
  end

  test "local operator can tune archive cutoff and restore archived WorkRequests", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      completed_at = DateTime.add(DateTime.utc_now(:microsecond), -2 * 24 * 60 * 60, :second)
      request = create_completed_skipped_work_request!(repo, "WR-LOCAL-ARCHIVE-SETTINGS", completed_at)

      dashboard_payload = local_operator_dashboard_payload()

      assert dashboard_payload["settings"]["work_request_archive_after_days"] == 14
      assert dashboard_payload["settings"]["solo_session_delete_after_days"] == 30
      assert dashboard_payload["settings"]["open_dashboard_on_boot"] == true
      assert dashboard_payload["settings"]["capture_failed_mcp_calls"] == false
      assert Enum.any?(dashboard_payload["work_requests"]["work_requests"], &(&1["id"] == request.id))
      assert dashboard_payload["archived_work_requests"]["work_requests"] == []

      archive_payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/settings", %{
          "work_request_archive_after_days" => 1,
          "open_dashboard_on_boot" => false,
          "capture_failed_mcp_calls" => true
        })
        |> json_response(200)

      assert archive_payload["settings"]["work_request_archive_after_days"] == 1
      assert archive_payload["settings"]["solo_session_delete_after_days"] == 30
      assert archive_payload["settings"]["open_dashboard_on_boot"] == false
      assert archive_payload["settings"]["capture_failed_mcp_calls"] == true
      refute Map.has_key?(archive_payload, "dashboard")

      archived_dashboard_payload = local_operator_dashboard_payload()

      refute Enum.any?(archived_dashboard_payload["work_requests"]["work_requests"], &(&1["id"] == request.id))
      assert [%{"id" => "WR-LOCAL-ARCHIVE-SETTINGS", "archived_at" => archived_at}] = archived_dashboard_payload["archived_work_requests"]["work_requests"]
      assert is_binary(archived_at)

      restore_payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-requests/#{request.id}/restore", %{})
        |> json_response(200)

      refute Map.has_key?(restore_payload, "dashboard")
      assert get_in(restore_payload, ["work_request", "archived_at"]) == nil

      restored_dashboard_payload = local_operator_dashboard_payload()

      assert Enum.any?(restored_dashboard_payload["work_requests"]["work_requests"], &(&1["id"] == request.id))
      refute Enum.any?(restored_dashboard_payload["archived_work_requests"]["work_requests"], &(&1["id"] == request.id))
    end)
  end

  test "local operator retention archives and deletes Solo Sessions", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      assert {:ok, _settings} =
               OperatorSettingsRepository.update(repo, %{
                 "work_request_archive_after_days" => 1,
                 "solo_session_delete_after_days" => 1
               })

      stale_at = DateTime.add(DateTime.utc_now(:microsecond), -8 * 24 * 60 * 60, :second)
      expired_at = DateTime.add(DateTime.utc_now(:microsecond), -15 * 24 * 60 * 60, :second)
      retained_at = DateTime.add(DateTime.utc_now(:microsecond), -13 * 24 * 60 * 60, :second)

      stale_active =
        repo
        |> create_solo_session!("solo-retention-stale-active")
        |> set_solo_session_last_activity!(repo, stale_at)

      old_archived = create_solo_session!(repo, "solo-retention-old-archived")

      assert {:ok, old_entry} = SoloSessionsService.append_progress(repo, old_archived.id, %{summary: "Old archived note"})

      old_archived =
        old_archived
        |> archive_solo_session!(repo)
        |> set_solo_session_last_activity!(repo, expired_at)

      recent_archived =
        repo
        |> create_solo_session!("solo-retention-recent-archived")
        |> archive_solo_session!(repo)
        |> set_solo_session_last_activity!(repo, retained_at)

      run_operator_retention(repo)
      payload = local_operator_dashboard_payload()

      solo_sessions = get_in(payload, ["solo_sessions", "solo_sessions"])
      stale_active_card = Enum.find(solo_sessions, &(&1["id"] == stale_active.id))

      assert stale_active_card["status"] == "archived"
      assert {:error, :not_found} = SoloSessionsService.get(repo, old_archived.id)
      refute Enum.any?(solo_sessions, &(&1["id"] == old_archived.id))
      refute Enum.any?(repo.all(SoloSessionEntry), &(&1.id == old_entry.id))
      assert Enum.any?(solo_sessions, &(&1["id"] == recent_archived.id and &1["status"] == "archived"))
      assert payload["settings"]["work_request_archive_after_days"] == 1
      assert payload["settings"]["solo_session_delete_after_days"] == 1
    end)
  end

  test "local operator retention deletes expired archived WorkRequests", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      assert {:ok, _settings} =
               OperatorSettingsRepository.update(repo, %{
                 "work_request_archive_after_days" => 1,
                 "solo_session_delete_after_days" => 1
               })

      stale_at = DateTime.add(DateTime.utc_now(:microsecond), -2 * 24 * 60 * 60, :second)
      fresh_at = DateTime.utc_now(:microsecond)

      expired = create_completed_skipped_work_request!(repo, "WR-LOCAL-DELETE-ARCHIVED", stale_at)
      assert {:ok, expired} = WorkRequestService.archive(repo, expired.id)
      expired = set_work_request_archived_at!(expired, repo, stale_at)
      expired_slice_id = "WRS-#{expired.id}"

      linked_expired = create_work_request!(repo, id: "WR-LOCAL-DELETE-LINKED", status: "ready_for_slicing")

      assert {:ok, linked_slice} =
               CanonicalWorkPackageFixtures.add_work_package(
                 repo,
                 linked_expired.id,
                 work_package_attrs(id: "WRS-LOCAL-DELETE-LINKED", base_branch: linked_expired.base_branch)
               )

      assert {:ok, linked_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, linked_expired.id, linked_slice.id, "planned")

      linked_package =
        create_matching_work_package!(repo, linked_expired, linked_slice,
          id: "WP-LOCAL-DELETE-LINKED",
          status: "merged"
        )
        |> set_work_package_updated_at!(repo, fresh_at)

      assert {:ok, _dispatched} =
               CanonicalWorkPackageFixtures.dispatch_work_package(repo, linked_expired.id, linked_slice.id, "approved", linked_package.id)

      linked_expired =
        linked_expired
        |> Ecto.Changeset.change(status: "sliced", completed_at: stale_at, archived_at: stale_at, updated_at: stale_at)
        |> repo.update!()

      recent = create_completed_skipped_work_request!(repo, "WR-LOCAL-KEEP-ARCHIVED", stale_at)
      assert {:ok, recent} = WorkRequestService.archive(repo, recent.id)
      recent = set_work_request_archived_at!(recent, repo, fresh_at)

      assert {:ok, request_comment} =
               CommentService.create(repo, %{
                 id: "comment-local-delete-wr",
                 target_kind: "work_request",
                 target_id: expired.id,
                 body: "Remove with archived request",
                 source_type: "operator",
                 author_name: "dashboard-test"
               })

      assert {:ok, slice_comment} =
               CommentService.create(repo, %{
                 id: "comment-local-delete-slice",
                 target_kind: "work_package",
                 target_id: expired_slice_id,
                 body: "Remove with archived slice",
                 source_type: "operator",
                 author_name: "dashboard-test"
               })

      assert {:ok, kept_comment} =
               CommentService.create(repo, %{
                 id: "comment-local-keep-archived",
                 target_kind: "work_request",
                 target_id: recent.id,
                 body: "Keep recent archive",
                 source_type: "operator",
                 author_name: "dashboard-test"
               })

      run_operator_retention(repo)
      payload = local_operator_dashboard_payload()

      archived_ids = payload["archived_work_requests"]["work_requests"] |> Enum.map(& &1["id"])

      refute expired.id in archived_ids
      refute linked_expired.id in archived_ids
      assert recent.id in archived_ids
      assert {:error, :not_found} = WorkRequestService.get(repo, expired.id)
      assert {:error, :not_found} = WorkRequestService.get(repo, linked_expired.id)
      assert {:error, :not_found} = CommentService.get(repo, request_comment.id)
      assert {:error, :not_found} = CommentService.get(repo, slice_comment.id)
      assert {:ok, ^recent} = WorkRequestService.get(repo, recent.id)
      assert {:ok, ^kept_comment} = CommentService.get(repo, kept_comment.id)
      assert linked_package.id in payload["settings"]["hidden_work_package_ids"]
      refute linked_package.id in dashboard_work_package_ids(payload)
    end)
  end

  test "local operator retention archives completed WorkRequests", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      assert {:ok, _settings} = OperatorSettingsRepository.update(repo, %{"work_request_archive_after_days" => 1})

      completed_at = DateTime.add(DateTime.utc_now(:microsecond), -2 * 24 * 60 * 60, :second)
      request = create_completed_skipped_work_request!(repo, "WR-LOCAL-REFRESH-RETENTION", completed_at)

      run_operator_retention(repo)
      payload = local_operator_dashboard_payload()

      refute Enum.any?(payload["work_requests"]["work_requests"], &(&1["id"] == request.id))
      assert [%{"id" => "WR-LOCAL-REFRESH-RETENTION", "archived_at" => archived_at}] = payload["archived_work_requests"]["work_requests"]
      assert is_binary(archived_at)
    end)
  end

  test "local operator retention skips repeated passes inside the throttle window", %{repo: repo} do
    with_retention_throttle_ms(60_000, fn ->
      with_local_operator_endpoint(fn ->
        assert {:ok, _settings} =
                 OperatorSettingsRepository.update(repo, %{
                   "work_request_archive_after_days" => 1,
                   "solo_session_delete_after_days" => 1
                 })

        stale_at = DateTime.add(DateTime.utc_now(:microsecond), -8 * 24 * 60 * 60, :second)

        first_request = create_completed_skipped_work_request!(repo, "WR-LOCAL-THROTTLE-FIRST", stale_at)

        first_solo =
          repo
          |> create_solo_session!("solo-retention-throttle-first")
          |> set_solo_session_last_activity!(repo, stale_at)

        run_operator_retention(repo)
        first_payload = local_operator_dashboard_payload()

        assert Enum.any?(first_payload["archived_work_requests"]["work_requests"], &(&1["id"] == first_request.id))
        assert Enum.any?(first_payload["solo_sessions"]["solo_sessions"], &(&1["id"] == first_solo.id and &1["status"] == "archived"))

        second_request = create_completed_skipped_work_request!(repo, "WR-LOCAL-THROTTLE-SECOND", stale_at)

        second_solo =
          repo
          |> create_solo_session!("solo-retention-throttle-second")
          |> set_solo_session_last_activity!(repo, stale_at)

        run_operator_retention(repo)
        second_payload = local_operator_dashboard_payload()

        assert Enum.any?(second_payload["work_requests"]["work_requests"], &(&1["id"] == second_request.id))
        refute Enum.any?(second_payload["archived_work_requests"]["work_requests"], &(&1["id"] == second_request.id))
        assert Enum.any?(second_payload["solo_sessions"]["solo_sessions"], &(&1["id"] == second_solo.id and &1["status"] == "active"))
      end)
    end)
  end

  test "local operator retention runs after the throttle window expires", %{repo: repo} do
    with_retention_throttle_ms(10, fn ->
      with_local_operator_endpoint(fn ->
        assert {:ok, _settings} =
                 OperatorSettingsRepository.update(repo, %{
                   "work_request_archive_after_days" => 1,
                   "solo_session_delete_after_days" => 1
                 })

        stale_at = DateTime.add(DateTime.utc_now(:microsecond), -2 * 24 * 60 * 60, :second)
        first_request = create_completed_skipped_work_request!(repo, "WR-LOCAL-THROTTLE-EXPIRED-FIRST", stale_at)

        run_operator_retention(repo)
        first_payload = local_operator_dashboard_payload()

        assert Enum.any?(first_payload["archived_work_requests"]["work_requests"], &(&1["id"] == first_request.id))

        second_request = create_completed_skipped_work_request!(repo, "WR-LOCAL-THROTTLE-EXPIRED-SECOND", stale_at)

        Process.sleep(25)

        run_operator_retention(repo)
        second_payload = local_operator_dashboard_payload()

        refute Enum.any?(second_payload["work_requests"]["work_requests"], &(&1["id"] == second_request.id))
        assert Enum.any?(second_payload["archived_work_requests"]["work_requests"], &(&1["id"] == second_request.id))
      end)
    end)
  end

  test "local operator retention keeps only linked WorkPackage signals", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      assert {:ok, _settings} = OperatorSettingsRepository.update(repo, %{"work_request_archive_after_days" => 1})

      stale_at = DateTime.add(DateTime.utc_now(:microsecond), -2 * 24 * 60 * 60, :second)
      recent_at = DateTime.utc_now(:microsecond)

      stale_terminal_package =
        create_work_package!(repo,
          id: "WP-LOCAL-RETENTION-STALE-TERMINAL",
          status: "merged",
          repo: "nextide/symphony-plus-plus",
          base_branch: "main"
        )
        |> set_work_package_updated_at!(repo, stale_at)

      recent_terminal_package =
        create_work_package!(repo,
          id: "WP-LOCAL-RETENTION-RECENT-TERMINAL",
          status: "closed",
          repo: stale_terminal_package.repo,
          base_branch: stale_terminal_package.base_branch
        )
        |> set_work_package_updated_at!(repo, recent_at)

      active_package =
        create_work_package!(repo,
          id: "WP-LOCAL-RETENTION-ACTIVE",
          status: "ready_for_worker",
          repo: stale_terminal_package.repo,
          base_branch: stale_terminal_package.base_branch
        )
        |> set_work_package_updated_at!(repo, stale_at)

      existing_hidden_package =
        create_work_package!(repo,
          id: "WP-LOCAL-RETENTION-EXISTING-HIDDEN",
          status: "closed",
          repo: stale_terminal_package.repo,
          base_branch: stale_terminal_package.base_branch
        )
        |> set_work_package_updated_at!(repo, stale_at)

      terminal_parent_package =
        create_work_package!(repo,
          id: "WP-LOCAL-RETENTION-TERMINAL-PARENT",
          status: "merged",
          repo: stale_terminal_package.repo,
          base_branch: stale_terminal_package.base_branch
        )
        |> set_work_package_updated_at!(repo, stale_at)

      child_package =
        create_work_package!(repo,
          id: "WP-LOCAL-RETENTION-PARENT-CHILD",
          status: "ready_for_worker",
          parent_id: terminal_parent_package.id,
          repo: stale_terminal_package.repo,
          base_branch: stale_terminal_package.base_branch
        )
        |> set_work_package_updated_at!(repo, stale_at)

      work_request =
        create_work_request!(repo,
          id: "WR-LOCAL-RETENTION-LINKED",
          status: "ready_for_slicing",
          repo: stale_terminal_package.repo,
          base_branch: stale_terminal_package.base_branch
        )

      assert {:ok, slice} =
               CanonicalWorkPackageFixtures.add_work_package(
                 repo,
                 work_request.id,
                 work_package_attrs(id: "WRS-LOCAL-RETENTION-LINKED", base_branch: work_request.base_branch)
               )

      assert {:ok, approved} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, slice.id, "planned")

      linked_terminal_package =
        create_matching_work_package!(repo, work_request, approved,
          id: "WP-LOCAL-RETENTION-LINKED-TERMINAL",
          status: "merged"
        )
        |> set_work_package_updated_at!(repo, stale_at)

      assert {:ok, _dispatched} =
               CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved.id, "approved", linked_terminal_package.id)

      assert {:ok, _settings} =
               OperatorSettingsRepository.update(repo, %{
                 "hidden_work_package_ids" => [existing_hidden_package.id, existing_hidden_package.id]
               })

      run_operator_retention(repo)
      payload = local_operator_dashboard_payload()

      assert get_in(payload, ["settings", "hidden_work_package_ids"]) == [
               existing_hidden_package.id
             ]

      package_ids = dashboard_work_package_ids(payload)

      refute stale_terminal_package.id in package_ids
      refute existing_hidden_package.id in package_ids
      refute recent_terminal_package.id in package_ids
      refute active_package.id in package_ids
      refute terminal_parent_package.id in package_ids
      refute child_package.id in package_ids
      assert linked_terminal_package.id in package_ids
      refute Map.has_key?(payload, "work_request_work_package_ids")
    end)
  end

  test "local operator can manually archive completed WorkRequests only", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      completed_at = DateTime.add(DateTime.utc_now(:microsecond), -24 * 60 * 60, :second)
      completed = create_completed_skipped_work_request!(repo, "WR-LOCAL-MANUAL-ARCHIVE", completed_at)

      archive_payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-requests/#{completed.id}/archive", %{})
        |> json_response(200)

      refute Map.has_key?(archive_payload, "dashboard")
      assert get_in(archive_payload, ["refresh", "work_request_id"]) == completed.id
      assert get_in(archive_payload, ["refresh", "dashboard"]) == true
      assert get_in(archive_payload, ["work_request", "id"]) == completed.id
      assert is_binary(get_in(archive_payload, ["work_request", "archived_at"]))

      dashboard_payload = local_operator_dashboard_payload()

      refute Enum.any?(dashboard_payload["work_requests"]["work_requests"], &(&1["id"] == completed.id))
      assert [%{"id" => "WR-LOCAL-MANUAL-ARCHIVE"}] = dashboard_payload["archived_work_requests"]["work_requests"]

      delivered = create_work_request!(repo, id: "WR-LOCAL-MANUAL-ARCHIVE-DELIVERED", status: "ready_for_slicing")

      assert {:ok, delivered_slice} =
               CanonicalWorkPackageFixtures.add_work_package(repo, delivered.id, work_package_attrs(id: "WRS-LOCAL-MANUAL-ARCHIVE-DELIVERED"))

      assert {:ok, _approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, delivered.id, delivered_slice.id, "planned")

      assert {:ok, _delivery} =
               WorkRequestRepository.record_work_package_delivery(
                 repo,
                 delivered.id,
                 delivered_slice.id,
                 delivery_attrs(%{
                   outcome: "completed_no_pr",
                   idempotency_key: "local-manual-archive-delivered",
                   no_pr_evidence: "Dashboard operator archive regression coverage."
                 })
               )

      delivered_archive_payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-requests/#{delivered.id}/archive", %{})
        |> json_response(200)

      refute Map.has_key?(delivered_archive_payload, "dashboard")
      assert get_in(delivered_archive_payload, ["refresh", "dashboard"]) == true
      assert get_in(delivered_archive_payload, ["work_request", "id"]) == delivered.id
      assert is_binary(get_in(delivered_archive_payload, ["work_request", "archived_at"]))

      delivered_dashboard_payload = local_operator_dashboard_payload()

      refute Enum.any?(delivered_dashboard_payload["work_requests"]["work_requests"], &(&1["id"] == delivered.id))
      assert Enum.any?(delivered_dashboard_payload["archived_work_requests"]["work_requests"], &(&1["id"] == delivered.id and is_binary(&1["archived_at"])))

      incomplete = create_work_request!(repo, id: "WR-LOCAL-MANUAL-NOT-COMPLETE", status: "ready_for_slicing")

      error_payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-requests/#{incomplete.id}/archive", %{})
        |> json_response(422)

      assert error_payload["error"]["code"] == "not_completed"
    end)
  end

  test "local operator can mark WorkPackages merged and refresh WorkRequest completion", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-MARK-PACKAGE-MERGED", status: "ready_for_slicing")

      assert {:ok, slice} =
               CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-LOCAL-MARK-PACKAGE-MERGED"))

      assert {:ok, approved} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, slice.id, "planned")

      work_package =
        create_matching_work_package!(repo, work_request, approved,
          id: "WP-LOCAL-MARK-PACKAGE-MERGED",
          status: "implementing"
        )

      assert {:ok, _dispatched} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved.id, "approved", work_package.id)

      payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/state", %{"status" => "merged"})
        |> json_response(200)

      assert {:ok, persisted_package} = WorkPackageRepository.get(repo, work_package.id)
      assert persisted_package.status == "merged"

      refute Map.has_key?(payload, "dashboard")

      dashboard_payload = local_operator_dashboard_payload()

      assert get_in(work_request_detail(dashboard_payload, work_request.id), ["work_request", "operational_state", "key"]) ==
               "needs_closeout"
    end)
  end

  test "local operator can clear a WorkPackage blocker without changing package delivery state", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-CLEAR-BLOCKER", status: "ready_for_slicing")

      assert {:ok, slice} =
               CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-LOCAL-CLEAR-BLOCKER"))

      assert {:ok, approved} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, slice.id, "planned")

      work_package =
        create_matching_work_package!(repo, work_request, approved,
          id: "WP-LOCAL-CLEAR-BLOCKER",
          status: "implementing"
        )

      assert {:ok, _dispatched} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved.id, "approved", work_package.id)

      assert {:ok, _blocker} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: work_package.id,
                 summary: "Review scope blocker",
                 body: "Reviewer requested an out-of-scope file change.",
                 status: "blocked",
                 idempotency_key: "local-clear-blocker",
                 payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: "local-clear-blocker", active: true}
               })

      _payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/blockers/local-clear-blocker/clear", %{})
        |> json_response(200)

      assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, work_package.id)
      refute Enum.any?(BlockerProjection.blockers(progress_events), & &1.active)
      assert Enum.any?(progress_events, &(get_in(&1.payload, ["source_tool"]) == "resolve_blocker" and get_in(&1.payload, ["blocker_id"]) == "local-clear-blocker"))
      assert length(resolve_blocker_events(progress_events, "local-clear-blocker")) == 1

      assert {:ok, _blocker} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: work_package.id,
                 summary: "Review scope blocker returned",
                 body: "Reviewer re-raised the same blocker id after more review.",
                 status: "blocked",
                 idempotency_key: "local-clear-blocker-reraised",
                 payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: "local-clear-blocker", active: true}
               })

      second_payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/blockers/local-clear-blocker/clear", %{})
        |> json_response(200)

      assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, work_package.id)
      refute Enum.any?(BlockerProjection.blockers(progress_events), & &1.active)
      assert length(resolve_blocker_events(progress_events, "local-clear-blocker")) == 2

      assert {:ok, persisted_package} = WorkPackageRepository.get(repo, work_package.id)
      assert persisted_package.status == "implementing"

      refute Map.has_key?(second_payload, "dashboard")

      dashboard_payload = local_operator_dashboard_payload()

      package_card = Enum.find(dashboard_payload["work_packages"], &(&1["id"] == work_package.id))
      assert package_card["active_blocker_count"] == 0
      assert package_card["active_blockers"] == []
    end)
  end

  test "local operator can clear a status-only blocked WorkPackage", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      assert {:ok, work_package} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(id: "WP-LOCAL-UNBLOCK", status: "blocked")
               )

      local_operator_conn()
      |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/state", %{"status" => "unblock"})
      |> json_response(200)

      assert {:ok, unblocked} = WorkPackageRepository.get(repo, work_package.id)
      assert unblocked.status == "ready_for_worker"

      retry_payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/state", %{"status" => "unblock"})
        |> json_response(409)

      assert get_in(retry_payload, ["error", "code"]) == "stale_status"
    end)
  end

  test "local operator dashboard recovers malformed hidden package ids before clearing blockers and archiving", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-CLEAR-BLOCKER-STALE-DASHBOARD", status: "ready_for_slicing")

      assert {:ok, slice} =
               CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-LOCAL-CLEAR-BLOCKER-STALE-DASHBOARD"))

      assert {:ok, approved} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, slice.id, "planned")

      work_package =
        create_matching_work_package!(repo, work_request, approved,
          id: "WP-LOCAL-CLEAR-BLOCKER-STALE-DASHBOARD",
          status: "implementing"
        )

      archive_package =
        create_work_package!(repo,
          id: "WP-LOCAL-ARCHIVE-STALE-DASHBOARD",
          status: "merged",
          repo: work_package.repo,
          base_branch: work_package.base_branch
        )

      assert {:ok, _dispatched} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved.id, "approved", work_package.id)

      assert {:ok, _blocker} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: work_package.id,
                 summary: "Review scope blocker",
                 body: "Reviewer requested an out-of-scope file change.",
                 status: "blocked",
                 idempotency_key: "local-clear-blocker-stale-dashboard",
                 payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: "local-clear-blocker-stale-dashboard", active: true}
               })

      assert {:ok, _settings} = OperatorSettingsRepository.update(repo, %{"hidden_work_package_ids" => []})

      repo.query!("UPDATE sympp_operator_settings SET hidden_work_package_ids = ? WHERE id = ?", [
        "not-json",
        OperatorSettings.settings_id()
      ])

      dashboard_payload = local_operator_dashboard_payload()

      assert get_in(dashboard_payload, ["settings", "hidden_work_package_ids"]) == []
      assert %{rows: [["not-json"]]} = repo.query!("SELECT hidden_work_package_ids FROM sympp_operator_settings WHERE id = ?", [OperatorSettings.settings_id()])

      payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/blockers/local-clear-blocker-stale-dashboard/clear", %{})
        |> json_response(200)

      assert %{"progress_event" => %{"blocker_id" => "local-clear-blocker-stale-dashboard"}} = payload
      refute Map.has_key?(payload, "dashboard")
      refute Map.has_key?(payload, "error")

      assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, work_package.id)
      refute Enum.any?(BlockerProjection.blockers(progress_events), & &1.active)
      assert length(resolve_blocker_events(progress_events, "local-clear-blocker-stale-dashboard")) == 1

      assert {:ok, persisted_package} = WorkPackageRepository.get(repo, work_package.id)
      assert persisted_package.status == "implementing"

      archive_payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{archive_package.id}/archive", %{})
        |> json_response(200)

      refute Map.has_key?(archive_payload, "dashboard")

      refreshed_dashboard_payload = local_operator_dashboard_payload()

      assert get_in(refreshed_dashboard_payload, ["settings", "hidden_work_package_ids"]) == [archive_package.id]
      refute archive_package.id in dashboard_work_package_ids(refreshed_dashboard_payload)
    end)
  end

  test "local operator can close linked WorkPackages with no-PR evidence", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-NO-PR", status: "ready_for_slicing")

      assert {:ok, slice} =
               CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-LOCAL-NO-PR"))

      assert {:ok, approved} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, slice.id, "planned")

      work_package =
        create_matching_work_package!(repo, work_request, approved,
          id: "WP-LOCAL-NO-PR",
          status: "reviewing"
        )

      assert {:ok, _dispatched} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved.id, "approved", work_package.id)

      append_blocker_event!(repo, work_package.id, "local-no-pr-closeout", true, [])

      payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/state", %{
          "status" => "completed_no_pr",
          "no_pr_evidence" => "Operator confirmed the exploratory work landed without a PR."
        })
        |> json_response(200)

      assert [%WorkPackageDelivery{} = delivery] = repo.all(WorkPackageDelivery)
      assert delivery.outcome == "completed_no_pr"
      assert delivery.idempotency_key == "local-operator-completed-no-pr:#{work_package.id}"
      assert delivery.no_pr_evidence == "Operator confirmed the exploratory work landed without a PR."

      assert {:ok, persisted_package} = WorkPackageRepository.get(repo, work_package.id)
      assert persisted_package.status == "closed"
      refute WorkPackageActivity.context(repo, work_package.id).blocker_state.active?

      refute Map.has_key?(payload, "dashboard")

      dashboard_payload = local_operator_dashboard_payload()

      detail = work_request_detail(dashboard_payload, work_request.id)
      assert get_in(detail, ["work_packages", Access.at(0), "delivery", "outcome"]) == "completed_no_pr"
    end)
  end

  test "local operator no-PR closeout retires active claim authority", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-NO-PR-ACTIVE-RUNTIME", status: "ready_for_slicing")

      assert {:ok, slice} =
               CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-LOCAL-NO-PR-ACTIVE-RUNTIME"))

      assert {:ok, approved} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, slice.id, "planned")

      work_package =
        create_matching_work_package!(repo, work_request, approved,
          id: "WP-LOCAL-NO-PR-ACTIVE-RUNTIME",
          status: "ready_for_merge"
        )

      assert {:ok, _dispatched} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved.id, "approved", work_package.id)

      assert {:ok, claim_lease} =
               ClaimLeaseService.claim(
                 repo,
                 work_package.id,
                 %{"actor_kind" => "agent", "actor_id" => "local:active-runtime", "actor_display_name" => "active-worker"},
                 stale_after_ms: 60_000
               )

      payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/state", %{
          "status" => "completed_no_pr",
          "no_pr_evidence" => "Operator closed the package while worker runtime was active."
        })
        |> json_response(200)

      assert payload["ok"] == true
      assert [%WorkPackageDelivery{outcome: "completed_no_pr"}] = repo.all(WorkPackageDelivery)

      assert %ClaimLease{status: "released", release_reason: "completed_no_pr_delivery_closeout"} =
               repo.get!(ClaimLease, claim_lease.id)
    end)
  end

  test "local operator cannot close terminal linked WorkPackages with no-PR evidence", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-NO-PR-TERMINAL", status: "ready_for_slicing")

      assert {:ok, slice} =
               CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-LOCAL-NO-PR-TERMINAL"))

      assert {:ok, approved} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, slice.id, "planned")

      work_package =
        create_matching_work_package!(repo, work_request, approved,
          id: "WP-LOCAL-NO-PR-TERMINAL",
          status: "merged"
        )

      assert {:ok, _dispatched} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved.id, "approved", work_package.id)

      error =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/state", %{
          "status" => "completed_no_pr",
          "no_pr_evidence" => "Operator tried to close an already merged package without PR."
        })
        |> json_response(422)

      assert error["error"]["code"] == "invalid_status"
      assert [] = repo.all(WorkPackageDelivery)
    end)
  end

  test "local operator can change and archive unlinked WorkPackages in one action", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      merge_package =
        create_work_package!(repo,
          id: "WP-LOCAL-MERGE-ARCHIVE",
          status: "implementing",
          repo: "nextide/symphony-plus-plus",
          base_branch: "main"
        )

      close_package =
        create_work_package!(repo,
          id: "WP-LOCAL-CLOSE-ARCHIVE",
          status: "planning",
          repo: merge_package.repo,
          base_branch: merge_package.base_branch
        )

      merge_payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{merge_package.id}/state", %{"status" => "merged_and_archive"})
        |> json_response(200)

      close_payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{close_package.id}/state", %{"status" => "closed_and_archive"})
        |> json_response(200)

      refute Map.has_key?(merge_payload, "dashboard")
      refute Map.has_key?(close_payload, "dashboard")

      dashboard_payload = local_operator_dashboard_payload()

      assert get_in(dashboard_payload, ["settings", "hidden_work_package_ids"]) == [merge_package.id, close_package.id]
      refute merge_package.id in dashboard_work_package_ids(dashboard_payload)
      refute close_package.id in dashboard_work_package_ids(dashboard_payload)

      assert {:ok, persisted_merge_package} = WorkPackageRepository.get(repo, merge_package.id)
      assert persisted_merge_package.status == "merged"

      assert {:ok, persisted_close_package} = WorkPackageRepository.get(repo, close_package.id)
      assert persisted_close_package.status == "closed"
    end)
  end

  test "local operator cannot archive active or linked WorkPackages", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      active_package =
        create_work_package!(repo,
          id: "WP-LOCAL-ARCHIVE-ACTIVE-REJECTED",
          status: "implementing",
          repo: "nextide/symphony-plus-plus",
          base_branch: "main"
        )

      active_error =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{active_package.id}/archive", %{})
        |> json_response(422)

      assert active_error["error"]["code"] == "not_delivered"

      work_request = create_work_request!(repo, id: "WR-LOCAL-ARCHIVE-LINKED", status: "ready_for_slicing")

      assert {:ok, slice} =
               CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-LOCAL-ARCHIVE-LINKED"))

      assert {:ok, approved} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, slice.id, "planned")

      linked_package =
        create_matching_work_package!(repo, work_request, approved,
          id: "WP-LOCAL-ARCHIVE-LINKED",
          status: "merged"
        )

      assert {:ok, _dispatched} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved.id, "approved", linked_package.id)

      linked_error =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{linked_package.id}/archive", %{})
        |> json_response(422)

      assert linked_error["error"]["code"] == "work_request_package"
    end)
  end

  test "local operator cannot mark non-merged terminal WorkPackages merged", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      assert {:ok, work_package} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(id: "WP-LOCAL-MARK-CLOSED", status: "closed")
               )

      local_operator_conn()
      |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/state", %{"status" => "merged"})
      |> json_response(422)

      assert {:ok, persisted_package} = WorkPackageRepository.get(repo, work_package.id)
      assert persisted_package.status == "closed"
    end)
  end

  test "local operator can clear every status-only WorkRequest clarification state", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      for status <- ["ready_for_clarification", "clarifying", "human_info_needed"] do
        clearable = create_work_request!(repo, id: "WR-LOCAL-CLEAR-#{status}", status: status)

        payload =
          local_operator_conn()
          |> post("/api/v1/sympp/operator/work-requests/#{clearable.id}/state", %{"state" => "ready_for_slicing"})
          |> json_response(200)

        assert get_in(payload, ["refresh", "work_request_id"]) == clearable.id
        assert get_in(payload, ["work_request", "status"]) == "ready_for_slicing"
        assert {:ok, %{status: "ready_for_slicing"}} = WorkRequestRepository.get(repo, clearable.id)
      end

      guarded = create_work_request!(repo, id: "WR-LOCAL-GUARD-HUMAN-INFO", status: "human_info_needed")
      assert {:ok, _question} = WorkRequestRepository.ask_question(repo, guarded.id, question_attrs(id: "WRQ-LOCAL-GUARD-HUMAN-INFO"))

      error =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-requests/#{guarded.id}/state", %{"state" => "ready_for_slicing"})
        |> json_response(409)

      assert get_in(error, ["error", "code"]) == "open_questions"
      assert {:ok, %{status: "human_info_needed"}} = WorkRequestRepository.get(repo, guarded.id)
    end)
  end

  test "local operator can force complete an unfinished WorkRequest", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-COMPLETE-STATE", status: "ready_for_slicing")

      assert {:ok, work_package} =
               CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-LOCAL-COMPLETE-STATE"))

      assert {:ok, open_question} =
               WorkRequestRepository.ask_question(repo, work_request.id, question_attrs(id: "WRQ-LOCAL-COMPLETE-STATE"))

      guidance_grant = create_claimed_worker_grant(repo, work_package.id, "worker-local-complete")

      assert {:ok, guidance_request} =
               GuidanceRequestRepository.create(repo, %{
                 work_package_id: work_package.id,
                 requester_grant_id: guidance_grant.id,
                 requested_by: "worker-local-complete",
                 idempotency_key: "guidance-local-complete",
                 summary: "Needs a terminal decision",
                 question: "Should this unfinished package continue?",
                 context: "Force completion must clear attached attention.",
                 status: "human_info_needed"
               })

      assert {:ok, _blocker} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: work_package.id,
                 summary: "Unfinished work",
                 body: "The package is waiting for operator action.",
                 status: "blocked",
                 idempotency_key: "blocker-local-complete",
                 payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: "blocker-local-complete", active: true}
               })

      payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-requests/#{work_request.id}/state", %{"state" => "completed"})
        |> json_response(200)

      refute Map.has_key?(payload, "dashboard")
      assert get_in(payload, ["refresh", "work_request_id"]) == work_request.id
      assert get_in(payload, ["refresh", "dashboard"]) == false
      assert get_in(payload, ["work_request", "id"]) == work_request.id
      assert get_in(payload, ["work_request", "completion_source"]) == "operator"
      assert get_in(payload, ["work_request", "operational_state", "key"]) == "completed"

      detail_payload =
        local_operator_conn()
        |> get("/api/v1/sympp/operator/work-requests/#{work_request.id}")
        |> json_response(200)

      assert get_in(detail_payload, ["work_request", "completion_source"]) == "operator"

      dashboard_payload = local_operator_dashboard_payload()

      assert get_in(work_request_detail(dashboard_payload, work_request.id), ["work_request", "operational_state", "key"]) ==
               "completed"

      assert {:ok, persisted_request} = WorkRequestRepository.get(repo, work_request.id)
      assert %DateTime{} = persisted_request.completed_at
      assert persisted_request.completion_source == "operator"

      assert {:ok, [persisted_slice]} = WorkRequestRepository.list_work_packages(repo, work_request.id)
      assert persisted_slice.id == work_package.id
      assert persisted_slice.status == "planned"

      assert {:ok, [persisted_question]} = WorkRequestRepository.list_questions(repo, work_request.id)
      assert persisted_question.id == open_question.id
      assert persisted_question.status == "closed"

      assert {:error, :not_found} = GuidanceRequestRepository.get(repo, guidance_request.id)

      assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, work_package.id)
      refute Enum.any?(BlockerProjection.blockers(progress_events), & &1.active)

      assert {:ok, refreshed_request} = WorkRequestService.refresh_completion(repo, work_request.id)
      assert refreshed_request.completed_at == persisted_request.completed_at
      assert refreshed_request.completion_source == "operator"

      assert [%OperatorAudit{} = audit] = repo.all(OperatorAudit)
      assert audit.actor_id == "local-operator"
      assert audit.actor_role == "human_operator"
      assert audit.actor_source == "local_operator"
      assert audit.action == "dangerous_override"
      assert audit.target_type == "work_request"
      assert audit.target_id == work_request.id
      assert audit.target_work_request_id == work_request.id
      assert audit.decision == "not_applicable"
      assert audit.reason == "trusted_local_human"
      assert audit.request_metadata["method"] == "POST"
      assert audit.request_metadata["path"] == "/api/v1/sympp/operator/work-requests/#{work_request.id}/state"
      assert audit.tool_metadata["name"] == "operator_update_work_request_state"
    end)
  end

  test "local operator can delete any WorkRequest", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-DELETE-DIRECT", status: "ready_for_slicing")

      assert {:ok, work_package} =
               CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-LOCAL-DELETE-DIRECT"))

      assert {:ok, work_package} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")
      assert {:ok, open_question} = WorkRequestRepository.ask_question(repo, work_request.id, question_attrs(id: "WRQ-LOCAL-DELETE-DIRECT"))

      linked_package =
        create_matching_work_package!(repo, work_request, work_package,
          id: "WP-LOCAL-DELETE-DIRECT",
          status: "claimed"
        )

      assert {:ok, _dispatched} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, work_package.id, "approved", linked_package.id)

      guidance_grant = create_claimed_worker_grant(repo, linked_package.id, "worker-local-delete")

      assert {:ok, guidance_request} =
               GuidanceRequestRepository.create(repo, %{
                 work_package_id: linked_package.id,
                 requester_grant_id: guidance_grant.id,
                 requested_by: "worker-local-delete",
                 idempotency_key: "guidance-local-delete",
                 summary: "Delete attached guidance",
                 question: "Should this request be deleted?",
                 context: "Deletion must remove attached attention.",
                 status: "human_info_needed"
               })

      assert {:ok, blocker_event} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: linked_package.id,
                 summary: "Delete attached blocker",
                 body: "This blocker belongs only to the deleted WorkRequest.",
                 status: "blocked",
                 idempotency_key: "blocker-local-delete",
                 payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: "blocker-local-delete", active: true}
               })

      assert {:ok, request_comment} =
               CommentService.create(repo, %{
                 id: "comment-local-delete-direct-wr",
                 target_kind: "work_request",
                 target_id: work_request.id,
                 body: "Delete with request",
                 source_type: "operator",
                 author_name: "dashboard-test"
               })

      payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-requests/#{work_request.id}/delete", %{})
        |> json_response(200)

      assert get_in(payload, ["work_request", "id"]) == work_request.id
      assert get_in(payload, ["refresh", "work_request_id"]) == work_request.id
      assert {:error, :not_found} = WorkRequestService.get(repo, work_request.id)
      assert {:error, :not_found} = CommentService.get(repo, request_comment.id)
      assert {:error, :not_found} = WorkPackageRepository.get(repo, linked_package.id)
      assert {:error, :not_found} = GuidanceRequestRepository.get(repo, guidance_request.id)
      assert repo.get(ProgressEvent, blocker_event.id) == nil
      assert repo.get(ClarificationQuestion, open_question.id) == nil
      assert {:ok, settings} = OperatorSettingsRepository.get(repo)
      assert linked_package.id in settings.hidden_work_package_ids

      dashboard_payload = local_operator_dashboard_payload()

      refute Enum.any?(dashboard_payload["work_requests"]["work_requests"], &(&1["id"] == work_request.id))
      refute Enum.any?(dashboard_payload["archived_work_requests"]["work_requests"], &(&1["id"] == work_request.id))
      refute linked_package.id in dashboard_work_package_ids(dashboard_payload)

      assert [%OperatorAudit{} = audit] = repo.all(OperatorAudit)
      assert audit.action == "dangerous_delete"
      assert audit.target_id == work_request.id
      assert audit.tool_metadata["name"] == "operator_delete_work_request"
    end)
  end

  test "local operator delete reports cleanup failures without declaring the dashboard unavailable", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-DELETE-CLEANUP-FAILURE", status: "ready_for_slicing")

      assert {:ok, work_package} =
               CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-LOCAL-DELETE-CLEANUP-FAILURE"))

      assert {:ok, _linked_package} =
               WorkPackageRepository.update(repo, work_package.id, %{
                 worktree_path: Path.join(System.tmp_dir!(), "outside-sympp-managed-root")
               })

      payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/work-requests/#{work_request.id}/delete", %{})
        |> json_response(409)

      assert get_in(payload, ["error", "code"]) == "request_delete_cleanup_failed"
      assert get_in(payload, ["error", "message"]) == "Request could not be deleted safely"
      assert {:ok, _work_request} = WorkRequestService.get(repo, work_request.id)
    end)
  end

  test "local operator can create and resolve comments through the dashboard API", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-COMMENTS", status: "ready_for_slicing")

      create_payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/comments", %{
          "target_kind" => "work_request",
          "target_id" => work_request.id,
          "body" => "Operator note sk-secret123",
          "source_type" => "worker",
          "author_name" => "github_pat_12345678"
        })
        |> json_response(201)

      assert %{"comment" => %{"id" => comment_id, "status" => "open"}} = create_payload
      assert get_in(create_payload, ["comment", "body"]) == "Operator note [REDACTED]"
      assert get_in(create_payload, ["comment", "source_type"]) == "operator"
      assert get_in(create_payload, ["comment", "author_name"]) == "local-operator"
      refute Map.has_key?(create_payload, "dashboard")
      assert get_in(create_payload, ["refresh", "comment_target_kind"]) == "work_request"
      assert get_in(create_payload, ["refresh", "comment_target_id"]) == work_request.id

      created_detail_payload =
        local_operator_conn()
        |> get("/api/v1/sympp/operator/work-requests/#{work_request.id}")
        |> json_response(200)

      assert get_in(created_detail_payload, ["summary", "open_comment_count"]) == 1

      assert {:ok, %Comment{source_type: "operator", author_name: "local-operator", body: "Operator note [REDACTED]"}} = CommentService.get(repo, comment_id)

      resolve_payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/comments/#{comment_id}/resolve", %{
          "resolved_by" => "spoofed-worker",
          "resolved_source_type" => "worker",
          "resolution_note" => "Handled bearer abcdefgh"
        })
        |> json_response(200)

      assert get_in(resolve_payload, ["comment", "status"]) == "resolved"
      assert get_in(resolve_payload, ["comment", "resolved_by"]) == "local-operator"
      assert get_in(resolve_payload, ["comment", "resolved_source_type"]) == "operator"
      assert get_in(resolve_payload, ["comment", "resolution_note"]) == "Handled [REDACTED]"
      refute Map.has_key?(resolve_payload, "dashboard")

      resolved_detail_payload =
        local_operator_conn()
        |> get("/api/v1/sympp/operator/work-requests/#{work_request.id}")
        |> json_response(200)

      assert get_in(resolved_detail_payload, ["summary", "comment_count"]) == 1
      assert get_in(resolved_detail_payload, ["summary", "open_comment_count"]) == 0
      assert {:ok, %Comment{resolution_note: "Handled [REDACTED]"}} = CommentService.get(repo, comment_id)

      overlong_payload =
        local_operator_conn()
        |> post("/api/v1/sympp/operator/comments", %{
          "target_kind" => "work_request",
          "target_id" => work_request.id,
          "body" => String.duplicate("x", Comment.max_body_length() + 1)
        })
        |> json_response(422)

      assert get_in(overlong_payload, ["error", "code"]) == "invalid_request"
      assert get_in(overlong_payload, ["error", "message"]) =~ "body"
    end)
  end

  test "react dashboard shell injects prefix-aware runtime config" do
    index = """
    <!doctype html>
    <html>
      <head>
        <link rel="icon" href="/splusplus-logo.png">
        <script type="module" src="/assets/index.js"></script>
      </head>
      <body><div id="root"></div></body>
    </html>
    """

    with_static_dashboard_file("index.html", index, fn ->
      html =
        build_conn(:get, "/sympp/board")
        |> Map.put(:script_name, ["app"])
        |> ReactDashboardController.index(%{})
        |> html_response(200)

      assert html =~ ~s(href="/app/splusplus-logo.png")
      assert html =~ ~s(src="/app/assets/index.js")
      assert html =~ "window.SYMPP_DASHBOARD_CONFIG"
      assert html =~ ~s("apiBase":"/app/api/v1/sympp/operator")
      assert html =~ ~s("logoUrl":"/app/splusplus-logo.png")
    end)
  end

  test "endpoint serves the built dashboard logo asset" do
    with_static_dashboard_file("splusplus-logo.png", "logo-bytes", fn ->
      assert response(get(build_conn(), "/splusplus-logo.png"), 200) == "logo-bytes"
    end)
  end

  test "endpoint caches hashed dashboard assets immutably" do
    with_static_dashboard_file("assets/index-deadbeef.js", "asset-bytes", fn ->
      conn = get(build_conn(), "/assets/index-deadbeef.js")

      assert response(conn, 200) == "asset-bytes"
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    end)
  end

  test "Phoenix request logger filters dashboard session secret parameters" do
    sentinel = "sympp-dashboard-log-secret-sentinel"

    params = %{
      "work_key" => sentinel,
      "work_key_secret" => "#{sentinel}-work-key-secret",
      "grant_secret" => "#{sentinel}-grant-secret",
      "secret" => "#{sentinel}-generic-secret",
      "operator_bootstrap" => "#{sentinel}-operator-bootstrap",
      "work_package_id" => "SYMPP-P10-LOG-FILTER"
    }

    filtered = Phoenix.Logger.filter_values(params)
    filtered_text = inspect(filtered)

    refute filtered_text =~ sentinel
    assert filtered["work_key"] == "[FILTERED]"
    assert filtered["work_key_secret"] == "[FILTERED]"
    assert filtered["grant_secret"] == "[FILTERED]"
    assert filtered["secret"] == "[FILTERED]"
    assert filtered["operator_bootstrap"] == "[FILTERED]"
    assert filtered["work_package_id"] == "SYMPP-P10-LOG-FILTER"
  end

  test "dashboard auth preflight treats in-memory SQLite ledgers as absent" do
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    try do
      for database_path <- [":memory:", "file::memory:?cache=shared", "file:?mode=rwc"] do
        Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)
        assert Repo.database_path() == database_path
        assert Repo.database_path_if_present() == nil
      end
    after
      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end
    end
  end

  test "dashboard reads normalize SQLite busy errors" do
    assert {:error, :database_busy} = Dashboard.board(BusyRepo)
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_completed_skipped_work_request!(repo, id, completed_at) do
    work_request = create_work_request!(repo, id: id, status: "ready_for_slicing")

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(id: "WRS-#{id}"))

    assert {:ok, _skipped} = WorkRequestRepository.skip_work_package(repo, work_request.id, work_package.id, "planned")
    mark_non_scratch_skipped_slice!(repo, work_package.id)
    assert {:ok, completed} = WorkRequestService.refresh_completion(repo, work_request.id)

    completed
    |> Ecto.Changeset.change(completed_at: completed_at, archived_at: nil)
    |> repo.update!()
  end

  defp mark_non_scratch_skipped_slice!(repo, work_package_id) do
    work_package = repo.get!(WorkPackage, work_package_id)

    work_package
    |> Ecto.Changeset.change(dispatched_at: DateTime.utc_now(:microsecond))
    |> repo.update!()
  end

  defp create_work_package!(repo, overrides) do
    overrides
    |> WorkPackageFactory.attrs()
    |> then(&WorkPackageRepository.create(repo, &1))
    |> case do
      {:ok, work_package} -> work_package
      {:error, reason} -> flunk("failed to create WorkPackage: #{inspect(reason)}")
    end
  end

  defp set_work_package_updated_at!(%WorkPackage{} = work_package, repo, %DateTime{} = updated_at) do
    work_package
    |> Ecto.Changeset.change(updated_at: updated_at)
    |> repo.update!()
  end

  defp create_solo_session!(repo, caller_id) do
    assert {:ok, session} =
             SoloSessionsService.create_or_attach_current(repo, %{
               repo: "symphony-plus-plus",
               base_branch: "main",
               workspace_path: Path.join(@repo_root, "solo-retention-#{caller_id}"),
               caller_id: caller_id,
               title: caller_id
             })

    session
  end

  defp archive_solo_session!(%SoloSession{} = session, repo) do
    assert {:ok, archived} = SoloSessionsService.archive(repo, session.id, session.status)
    archived
  end

  defp set_solo_session_last_activity!(%SoloSession{} = session, repo, %DateTime{} = timestamp) do
    session
    |> Ecto.Changeset.change(last_activity_at: timestamp, updated_at: timestamp)
    |> repo.update!()
  end

  defp set_work_request_archived_at!(%WorkRequest{} = work_request, repo, %DateTime{} = timestamp) do
    work_request
    |> Ecto.Changeset.change(archived_at: timestamp, updated_at: timestamp)
    |> repo.update!()
  end

  defp create_matching_work_package!(repo, work_request, work_package, overrides) do
    attrs =
      [
        kind: work_package.kind,
        title: work_package.title,
        repo: work_request.repo,
        base_branch: work_package.base_branch,
        branch_pattern: work_package.branch_pattern,
        product_description: work_request.human_description,
        allowed_file_globs: work_package.allowed_file_globs,
        acceptance_criteria: work_package.acceptance_criteria,
        review_requirement: work_package.review_requirement
      ]
      |> Keyword.merge(overrides)

    create_work_package!(repo, attrs)
  end

  defp set_canonical_package_status!(repo, work_package, status) do
    repo.update!(
      Ecto.Changeset.change(work_package,
        status: status,
        dispatched_at: DateTime.utc_now(:microsecond)
      )
    )
  end

  defp append_blocker_event!(repo, work_package_id, blocker_id, active, overrides) do
    attrs =
      [
        work_package_id: work_package_id,
        summary: "Blocked",
        status: if(active, do: "blocked", else: "unblocked"),
        idempotency_key: "#{blocker_id}-#{active}-#{System.unique_integer([:positive])}",
        payload: %{type: "blocker", source_tool: blocker_source_tool(active), blocker_id: blocker_id, active: active}
      ]
      |> Keyword.merge(overrides)
      |> Map.new()

    assert {:ok, event} = PlanningRepository.append_progress_event(repo, attrs)
    event
  end

  defp blocker_source_tool(true), do: "report_blocker"
  defp blocker_source_tool(false), do: "resolve_blocker"

  defp resolve_blocker_events(progress_events, blocker_id) do
    Enum.filter(progress_events, &(get_in(&1.payload, ["source_tool"]) == "resolve_blocker" and get_in(&1.payload, ["blocker_id"]) == blocker_id))
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-DASH-#{System.unique_integer([:positive])}",
      title: "Improve intake flow",
      repo: "nextide/symphony-plus-plus",
      base_branch: "main",
      work_type: "feature",
      human_description: "Record the human's desired outcome before slicing.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false},
      desired_dispatch_shape: "single_package",
      status: "draft"
    }

    Enum.into(overrides, defaults)
  end

  defp question_attrs(overrides) do
    defaults = %{
      category: "scope",
      question: "Which branch should this target?",
      why_needed: "The architect needs the target before slicing."
    }

    Enum.into(overrides, defaults)
  end

  defp decision_attrs(overrides) do
    defaults = %{
      source_type: "architect",
      decision: "Keep this WorkRequest narrow.",
      rationale: "The next slice owns broader orchestration.",
      scope_impact: "No new runtime tools.",
      created_by: "architect-1"
    }

    Enum.into(overrides, defaults)
  end

  defp work_package_attrs(overrides) do
    defaults = %{
      title: "Add WorkRequest dashboard API",
      goal: "Expose read-only dashboard view models.",
      kind: "mcp",
      base_branch: "main",
      branch_pattern: "agent/SYMPP-V2-WR-004/workrequest-read-api",
      allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/dashboard.ex"],
      forbidden_file_globs: ["elixir/lib/symphony_elixir_web/live/**"],
      acceptance_criteria: ["WorkRequest dashboard API reads are scoped and redacted."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/dashboard_api_test.exs"],
      stop_conditions: ["Stop before UI or dispatch wiring."]
    }

    Enum.into(overrides, defaults)
  end

  defp delivery_attrs(overrides) do
    defaults = %{
      idempotency_key: "dashboard-delivery-#{System.unique_integer([:positive])}",
      recorded_by: "dashboard-api-test"
    }

    Enum.into(overrides, defaults)
  end

  defp create_dashboard_fixture(repo, opts \\ []) do
    id = Keyword.get(opts, :id, "SYMPP-DASH-API")
    status = Keyword.get(opts, :status, "planning")

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: id,
                 kind: "mcp",
                 status: status,
                 title: "Dashboard API raw-secret-value",
                 branch_pattern: "agent/#{id}",
                 product_description: "Build dashboard with raw-secret-value",
                 engineering_scope: "No credential handling",
                 acceptance_criteria: ["Expose read API", "Redact raw-secret-value"]
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    assert {:ok, grant} = AccessGrantRepository.get(repo, minted.grant.id)

    append_state(repo, work_package, grant)

    %{work_package: work_package, grant: grant, work_key_secret: minted.work_key.secret}
  end

  defp append_state(repo, work_package, grant) do
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _plan_node} =
             PlanningRepository.append_plan_node(repo, %{
               work_package_id: work_package.id,
               title: "Implement API",
               body: "Add read endpoints",
               status: "done",
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "abc123"},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/1", head_sha: "abc123"},
               created_at: DateTime.add(timestamp, 3, :second)
             })

    assert {:ok, _blocker} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Blocked on validation",
               status: "blocked",
               idempotency_key: "blocker-a",
               payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: "blocker-a", active: true},
               created_at: DateTime.add(timestamp, 4, :second)
             })

    assert {:ok, _finding} =
             PlanningRepository.append_finding(repo, %{
               work_package_id: work_package.id,
               title: "Finding one",
               body: "Needs attention",
               severity: "medium",
               access_grant_id: grant.id,
               created_at: DateTime.add(timestamp, 5, :second)
             })

    assert {:ok, _artifact} =
             PlanningService.append_artifact(repo, %{
               work_package_id: work_package.id,
               path: "review-log-raw-secret-value.txt",
               title: "Review log raw-secret-value",
               kind: "review",
               uri: "https://example.test/review-log.txt?X-Amz-Signature=raw-secret-value",
               metadata: %{"access_grant_id" => "grant-other-worker", "agent_run_id" => "run-other-worker"},
               created_at: DateTime.add(timestamp, 7, :second)
             })

    assert {:ok, _run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: work_package.id,
               access_grant_id: grant.id,
               actor_id: "worker-1",
               status: "running",
               attempt: 1,
               worker_host: "local",
               worker_task_handle: "task-1",
               workspace_path: "C:/tmp/workspace",
               session_id: "session-1"
             })
  end

  defp progress_event(id, sequence, created_at, payload) do
    %ProgressEvent{
      id: id,
      work_package_id: "SYMPP-SEQUENCELESS",
      summary: id,
      status: "recorded",
      sequence: sequence,
      created_at: created_at,
      payload: payload
    }
  end

  defp create_claimed_worker_grant(repo, work_package_id, claimed_by) do
    {grant, _work_key} = create_claimed_worker_key(repo, work_package_id, claimed_by)
    grant
  end

  defp create_claimed_worker_key(repo, work_package_id, claimed_by) do
    work_key = WorkKey.generate()

    assert {:ok, grant} =
             AccessGrantRepository.create(repo, %{
               work_package_id: work_package_id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "worker",
               capabilities: ["read:package"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
             })

    assert {:ok, _assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: claimed_by}, DateTime.utc_now(:microsecond))

    assert {:ok, grant} = AccessGrantRepository.get(repo, grant.id)
    {grant, work_key}
  end

  defp with_retention_throttle_ms(window_ms, fun) when is_integer(window_ms) and is_function(fun, 0) do
    original = Application.fetch_env(:symphony_elixir, :sympp_operator_retention_throttle_ms)
    Application.put_env(:symphony_elixir, :sympp_operator_retention_throttle_ms, window_ms)

    try do
      fun.()
    after
      restore_fetched_app_env(:sympp_operator_retention_throttle_ms, original)
    end
  end

  defp with_trusted_repo_remotes(remotes, fun) when is_list(remotes) and is_function(fun, 0) do
    original = Application.fetch_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)
    Application.put_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes, remotes)

    try do
      fun.()
    after
      restore_fetched_app_env(:sympp_repo_identity_trusted_remotes, original)
    end
  end

  defp create_repo_identity_package!(repo, {key, id, raw_repo}) do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: id, repo: raw_repo, base_branch: "main")
             )

    {key, package}
  end

  defp create_repo_identity_request!(repo, {key, id, raw_repo}) do
    assert {:ok, request} =
             WorkRequestRepository.create(repo, %{
               title: "#{id} request",
               repo: raw_repo,
               base_branch: "main",
               work_type: "feature",
               human_description: "#{raw_repo} repo identity coverage.",
               constraints: %{},
               desired_dispatch_shape: "architect_led_feature_branch",
               status: "ready_for_clarification"
             })

    {key, request}
  end

  defp repo_identity_expectation(raw_repo) do
    %{
      repo: raw_repo,
      repo_key: String.downcase(raw_repo),
      repo_display: raw_repo,
      repo_remote: if(String.contains?(raw_repo, "/"), do: raw_repo),
      repo_aliases: [raw_repo]
    }
  end

  defp assert_repo_identity(record, expected) do
    Enum.each(expected, fn {field, value} ->
      assert Map.fetch!(record, field) == value
    end)
  end

  defp with_local_repo_origin(origin, fun) when is_binary(origin) and is_function(fun, 0) do
    original_repo_root = Application.fetch_env(:symphony_elixir, :sympp_repo_root)
    original_trusted_remotes = Application.fetch_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)
    repo_root = TestSupport.git_repo_with_origin_fixture!(origin, prefix: "sympp-dashboard-repo-root")

    Application.put_env(:symphony_elixir, :sympp_repo_root, repo_root)
    Application.delete_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)

    try do
      fun.()
    after
      restore_fetched_app_env(:sympp_repo_root, original_repo_root)
      restore_fetched_app_env(:sympp_repo_identity_trusted_remotes, original_trusted_remotes)
    end
  end

  defp restore_fetched_app_env(key, {:ok, value}), do: Application.put_env(:symphony_elixir, key, value)
  defp restore_fetched_app_env(key, :error), do: Application.delete_env(:symphony_elixir, key)

  defp local_operator_dashboard_payload do
    initial = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard"), 200)
    deferred = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard/deferred"), 200)
    archived = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard?surface=archived"), 200)
    solo = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard?surface=solo"), 200)

    initial
    |> Map.merge(deferred)
    |> Map.merge(archived)
    |> Map.merge(solo)
  end

  defp run_operator_retention(repo) do
    assert {:ok, settings} = OperatorSettingsRepository.get(repo)
    assert :ok = LocalOperatorDashboard.run_operator_retention(repo, settings)
  end

  defp capture_queries(fun) do
    handler_id = {__MODULE__, self(), make_ref()}
    event = Repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, test_pid -> send(test_pid, {handler_id, to_string(metadata.query || "")}) end,
        self()
      )

    try do
      result = fun.()
      {result, drain_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, queries) do
    receive do
      {^handler_id, query} -> drain_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp dashboard_benchmark(requests, fun) do
    DashboardQueryCountingRepo.reset()
    started_at = System.monotonic_time()
    assert {:ok, payload} = fun.()

    elapsed_ms =
      System.monotonic_time()
      |> Kernel.-(started_at)
      |> System.convert_time_unit(:native, :microsecond)
      |> Kernel./(1000)

    {payload, %{requests: requests, queries: DashboardQueryCountingRepo.count(), settle_ms: elapsed_ms}}
  end

  defp maybe_export_dashboard_fixture(_repo) do
    case System.get_env("SYMPP_DASHBOARD_FIXTURE_DATABASE") do
      path when is_binary(path) and path != "" ->
        DashboardFixtureDatabase.export!(path)

      _path ->
        :ok
    end
  end

  defp work_request_detail(dashboard, work_request_id) do
    dashboard
    |> get_in(["work_request_details"])
    |> Kernel.||([])
    |> Enum.find(&(get_in(&1, ["work_request", "id"]) == work_request_id))
  end

  defp dashboard_work_package_ids(dashboard) do
    dashboard
    |> Map.get("work_packages", [])
    |> Enum.map(& &1["id"])
  end

  defp local_operator_conn do
    build_conn()
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("origin", "http://localhost")
  end

  defp recycle_local_operator_conn(conn, origin) do
    conn
    |> recycle()
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("origin", origin)
  end

  defp with_operator_github_client(fun) when is_function(fun, 0) do
    original = Application.get_env(:symphony_elixir, :sympp_github_client)
    Application.put_env(:symphony_elixir, :sympp_github_client, FakeGitHubClient)

    try do
      fun.()
    after
      FakeGitHubClient.clear()

      case original do
        nil -> Application.delete_env(:symphony_elixir, :sympp_github_client)
        value -> Application.put_env(:symphony_elixir, :sympp_github_client, value)
      end
    end
  end

  defp with_operator_authenticated_github_client(fun) when is_function(fun, 0) do
    original = Application.get_env(:symphony_elixir, :sympp_github_client)
    Application.put_env(:symphony_elixir, :sympp_github_client, FakeAuthenticatedGitHubClient)
    FakeGhCli.clear()

    try do
      fun.()
    after
      FakeGitHubClient.clear()
      FakeGhCli.clear()

      case original do
        nil -> Application.delete_env(:symphony_elixir, :sympp_github_client)
        value -> Application.put_env(:symphony_elixir, :sympp_github_client, value)
      end
    end
  end

  defp with_operator_gh_cli_runner(fun) when is_function(fun, 0) do
    original_client = Application.get_env(:symphony_elixir, :sympp_github_client)
    original_runner = Application.get_env(:symphony_elixir, :sympp_gh_command_runner)

    Application.delete_env(:symphony_elixir, :sympp_github_client)
    Application.put_env(:symphony_elixir, :sympp_gh_command_runner, &FakeGhCli.run/3)

    try do
      fun.()
    after
      FakeGhCli.clear()

      case original_client do
        nil -> Application.delete_env(:symphony_elixir, :sympp_github_client)
        value -> Application.put_env(:symphony_elixir, :sympp_github_client, value)
      end

      case original_runner do
        nil -> Application.delete_env(:symphony_elixir, :sympp_gh_command_runner)
        value -> Application.put_env(:symphony_elixir, :sympp_gh_command_runner, value)
      end
    end
  end

  defp with_static_dashboard_file(file_name, contents, fun) when is_function(fun, 0) do
    static_dir =
      :symphony_elixir
      |> :code.priv_dir()
      |> Path.join("static")

    path = Path.join(static_dir, file_name)
    original = File.read(path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)

    try do
      fun.()
    after
      case original do
        {:ok, previous} -> File.write!(path, previous)
        {:error, _reason} -> File.rm(path)
      end
    end
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), sympp_repo: Repo)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp with_local_operator_endpoint(fun) when is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end
  end

  defp with_local_operator_dashboard_origin(origin, fun) when is_binary(origin) and is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint_config, :sympp_dashboard_origin, origin)
    )

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end
  end
end
