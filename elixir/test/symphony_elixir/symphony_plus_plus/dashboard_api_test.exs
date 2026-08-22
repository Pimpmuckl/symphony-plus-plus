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
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
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
  alias SymphonyElixirWeb.SymppDashboardApiController

  @endpoint SymphonyElixirWeb.Endpoint
  @dashboard_phase_id "phase-dashboard-test"
  @repo_root Path.expand("../../../../", __DIR__)

  defmodule BusyRepo do
    @moduledoc false

    def all(_query), do: raise(%Exqlite.Error{message: "database is locked"})
    def one(_query), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  defmodule LockedPhaseAnchorRepo do
    @moduledoc false

    @grant_key {__MODULE__, :grant}

    def put_grant(%AccessGrant{} = grant), do: :persistent_term.put(@grant_key, grant)
    def clear_grant, do: :persistent_term.erase(@grant_key)

    def one(_query), do: :persistent_term.get(@grant_key)
    def get(AccessGrant, _id), do: :persistent_term.get(@grant_key)
    def get(WorkPackage, _id), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  defmodule MissingCustomRepo do
    @moduledoc false

    def __adapter__, do: Ecto.Adapters.SQLite3
    def config, do: [database: SymphonyElixir.WorkPackageFactory.database_path()]
    def start_link(_opts), do: raise("custom repo should not start for invalid bearer probes")
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

  defmodule PhaseBoardMaterializationRepo do
    @moduledoc false

    alias SymphonyElixir.SymphonyPlusPlus.Repo
    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

    @blocked_key :sympp_api_phase_board_blocked_card_id

    def block_materialization(work_package_id), do: Process.put(@blocked_key, work_package_id)
    def clear_materialization_block, do: Process.delete(@blocked_key)

    def all(query), do: Repo.all(query)
    def one(query), do: Repo.one(query)
    def transaction(fun), do: Repo.transaction(fun)

    def get(WorkPackage, id) do
      if Process.get(@blocked_key) == id do
        raise "out-of-scope API phase board card materialized: #{id}"
      else
        Repo.get(WorkPackage, id)
      end
    end

    def get(schema, id), do: Repo.get(schema, id)
  end

  defmodule MalformedPhaseGrantRepo do
    @moduledoc false

    def one(_query), do: :persistent_term.get({__MODULE__, :grant})
    def get(_schema, _id), do: raise("non-null malformed phase scope must not derive from anchor")
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

  test "serializes package cards and groups the board by status", %{repo: repo} do
    %{work_package: first} = create_dashboard_fixture(repo, id: "SYMPP-DASH-1", status: "planning")
    assert {:ok, _second} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-DASH-2", status: "blocked"))
    assert {:ok, legacy_ready} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-DASH-LEGACY-READY", status: "ready_for_merge"))
    repo.query!("UPDATE sympp_work_packages SET status = ? WHERE id = ?", ["ready_for_human_merge", legacy_ready.id])
    architect_secret = create_architect_grant_secret(repo, first.id)

    assert {:ok, card} = Dashboard.card(repo, first)
    assert card.id == "SYMPP-DASH-1"
    assert card.status == "planning"
    assert card.active_blocker_count == 1
    assert card.artifact_count == 1
    assert card.finding_count == 1
    assert card.metadata.pr["url"] == "https://github.com/example/repo/pull/1"
    assert card.operational_state.key == "blocked"
    assert card.operational_state.raw_status == "planning"
    assert [%{key: "active_blocker", blocker_ids: ["blocker-a"]}] = card.operational_state.attention_items

    payload = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/board"), 200)

    assert payload["total_count"] == 3
    assert [%{"id" => "SYMPP-DASH-1", "operational_state" => %{"key" => "blocked", "raw_status" => "planning"}}] = payload["groups"]["planning"]
    assert [%{"id" => "SYMPP-DASH-2"}] = payload["groups"]["blocked"]
    assert [%{"id" => "SYMPP-DASH-LEGACY-READY"}] = payload["groups"]["ready_for_human_merge"]
    assert "ready_for_human_merge" in payload["statuses"]
    assert payload["groups"]["created"] == []

    assert %{
             "work_package" => %{"id" => "SYMPP-DASH-1"},
             "summary" => %{"artifact_count" => 1, "progress_event_count" => 4}
           } = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/SYMPP-DASH-1"), 200)

    assert %{
             "work_package" => %{"id" => "SYMPP-DASH-2"},
             "summary" => %{"artifact_count" => 0, "progress_event_count" => 0}
           } = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/SYMPP-DASH-2"), 200)
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
               payload: %{type: "review_progress", source_tool: "submit_review_package"},
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

  test "phase board authorization preserves exact persisted phase ids", %{repo: repo} do
    phase_id = "phase-dashboard-exact "
    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Exact phase"})

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-EXACT-PHASE", kind: "phase_child", phase_id: phase_id, status: "planning")
             )

    work_key = WorkKey.generate()

    assert {:ok, grant} =
             AccessGrantRepository.create(repo, %{
               work_package_id: work_package.id,
               phase_id: phase_id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["read:phase"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
             })

    assert {:ok, _assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    assert grant.phase_id == phase_id

    payload = json_response(get(auth_conn(work_key.secret), "/api/v1/sympp/board"), 200)

    assert payload["phase"]["id"] == phase_id
    assert payload["total_count"] == 1
    assert [%{"id" => "SYMPP-DASH-EXACT-PHASE"}] = payload["groups"]["planning"]
  end

  test "phase board exposes scoped child merge progress summary", %{repo: repo} do
    phase_id = "phase-dashboard-progress"
    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Progress phase"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-PROGRESS-ANCHOR",
                 kind: "mcp",
                 phase_id: phase_id,
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta",
                 status: "planning"
               )
             )

    for {id, status} <- [
          {"SYMPP-DASH-PROGRESS-MERGED", "merged_into_phase"},
          {"SYMPP-DASH-PROGRESS-READY", "ready_for_architect_merge"},
          {"SYMPP-DASH-PROGRESS-CLOSED", "closed"},
          {"SYMPP-DASH-PROGRESS-ABANDONED", "abandoned"}
        ] do
      assert {:ok, _child} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(
                   id: id,
                   kind: "phase_child",
                   policy_template: "phase_child",
                   phase_id: phase_id,
                   parent_id: anchor.id,
                   repo: anchor.repo,
                   base_branch: anchor.base_branch,
                   status: status
                 )
               )
    end

    assert {:ok, _out_of_scope_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-PROGRESS-OUT-OF-SCOPE",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: phase_id,
                 parent_id: anchor.id,
                 repo: "nextide/other",
                 base_branch: anchor.base_branch,
                 status: "merged_into_phase"
               )
             )

    assert {:ok, _out_of_scope_base_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-PROGRESS-OUT-OF-BASE",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: phase_id,
                 parent_id: anchor.id,
                 repo: anchor.repo,
                 base_branch: "main",
                 status: "merged_into_phase"
               )
             )

    work_key = WorkKey.generate()

    assert {:ok, _grant} =
             AccessGrantRepository.create(repo, %{
               work_package_id: anchor.id,
               phase_id: phase_id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["read:phase"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
             })

    assert {:ok, _assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    payload = json_response(get(auth_conn(work_key.secret), "/api/v1/sympp/board"), 200)

    assert payload["total_count"] == 5

    assert payload["summary"] == %{
             "child_count" => 3,
             "merged_child_count" => 1,
             "ready_child_count" => 1,
             "merging_child_count" => 0,
             "open_child_count" => 1
           }

    assert {:ok, filtered_board} =
             Dashboard.phase_board(repo, phase_id,
               repo: anchor.repo,
               base_branch: anchor.base_branch,
               status: "merged_into_phase"
             )

    assert filtered_board.summary == %{
             child_count: 3,
             merged_child_count: 1,
             ready_child_count: 1,
             merging_child_count: 0,
             open_child_count: 1
           }
  end

  test "phase board status filters keep repo identity from the phase scope", %{repo: repo} do
    with_trusted_repo_remotes(["Pimpmuckl/symphony-plus-plus"], fn ->
      assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-dashboard-repo-identity", title: "Repo identity phase"})

      assert {:ok, bare} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(
                   id: "SYMPP-DASH-PHASE-REPO-BARE",
                   kind: "phase_child",
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
                   kind: "phase_child",
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

  test "legacy null phase grants derive dashboard scope from their phased anchor", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-dashboard-legacy", title: "Legacy phase"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-LEGACY-ANCHOR", kind: "phase_child", phase_id: phase.id, status: "planning")
             )

    assert {:ok, sibling} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-LEGACY-SIBLING", kind: "phase_child", phase_id: phase.id, status: "blocked")
             )

    secret = create_legacy_phase_grant_secret(repo, anchor.id, "grant-dashboard-legacy-derived")

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 200)

    assert payload["phase"]["id"] == phase.id
    assert payload["total_count"] == 2
    assert [%{"id" => "SYMPP-DASH-LEGACY-ANCHOR"}] = payload["groups"]["planning"]
    assert [%{"id" => "SYMPP-DASH-LEGACY-SIBLING"}] = payload["groups"]["blocked"]
    assert payload["summary"]["child_count"] == 0
    assert payload["summary"]["merged_child_count"] == 0

    phase_id = phase.id
    sibling_id = sibling.id

    assert %{"work_package" => %{"id" => ^sibling_id, "phase_id" => ^phase_id}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{sibling.id}"), 200)
  end

  test "legacy null phase grants with unphased anchors are denied dashboard phase reads", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-LEGACY-UNPHASED", kind: "hotfix", parent_id: nil, phase_id: nil)
             )

    secret = create_legacy_phase_grant_secret(repo, anchor.id, "grant-dashboard-legacy-unphased")

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 403)
  end

  test "legacy null phase grants cannot read packages outside anchor phase", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-dashboard-legacy-own", title: "Legacy own"})
    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-dashboard-legacy-other", title: "Legacy other"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-LEGACY-OWN", kind: "phase_child", phase_id: phase.id, status: "planning")
             )

    assert {:ok, other_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-LEGACY-OTHER", kind: "phase_child", phase_id: other_phase.id, status: "planning")
             )

    secret = create_legacy_phase_grant_secret(repo, anchor.id, "grant-dashboard-legacy-other")
    phase_id = phase.id

    assert %{"phase" => %{"id" => ^phase_id}} = json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 200)

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{other_package.id}"), 403)
  end

  test "dashboard anchor fallback applies only to null phase grant scopes" do
    now = DateTime.utc_now(:microsecond)
    work_key = WorkKey.generate()

    :persistent_term.put(
      {MalformedPhaseGrantRepo, :grant},
      %AccessGrant{
        id: "grant-dashboard-malformed-phase",
        work_package_id: "SYMPP-DASH-MALFORMED-PHASE",
        phase_id: :malformed,
        display_key: work_key.display_key,
        secret_hash: WorkKey.secret_hash(work_key.secret),
        grant_role: "architect",
        capabilities: ["read:phase"],
        expires_at: DateTime.add(now, 3600, :second),
        claimed_at: now,
        claimed_by: "architect-malformed"
      }
    )

    on_exit(fn -> :persistent_term.erase({MalformedPhaseGrantRepo, :grant}) end)

    with_endpoint_repo(MalformedPhaseGrantRepo, fn ->
      assert %{"error" => %{"code" => "forbidden"}} =
               json_response(get(auth_conn(work_key.secret), "/api/v1/sympp/board"), 403)
    end)
  end

  test "phase board grants are denied after their architect anchor leaves the phase", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-dashboard-anchor", title: "Anchor phase"})
    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-dashboard-anchor-other", title: "Other phase"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-ANCHOR", kind: "phase_child", phase_id: phase.id, status: "planning")
             )

    assert {:ok, sibling} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-ANCHOR-SIBLING", kind: "phase_child", phase_id: phase.id, status: "planning")
             )

    assert {:ok, other_sibling} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-ANCHOR-OTHER-SIBLING", kind: "phase_child", phase_id: other_phase.id, status: "planning")
             )

    work_key = WorkKey.generate()

    assert {:ok, _grant} =
             AccessGrantRepository.create(repo, %{
               work_package_id: anchor.id,
               phase_id: phase.id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["read:phase"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
             })

    assert {:ok, _assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    assert %{"phase" => %{"id" => "phase-dashboard-anchor"}} =
             json_response(get(auth_conn(work_key.secret), "/api/v1/sympp/board"), 200)

    assert {:ok, _updated_anchor} = WorkPackageRepository.update(repo, anchor.id, %{phase_id: other_phase.id})

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(work_key.secret), "/api/v1/sympp/board"), 403)

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(work_key.secret), "/api/v1/sympp/work-packages/#{sibling.id}"), 403)

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(work_key.secret), "/api/v1/sympp/work-packages/#{other_sibling.id}"), 403)
  end

  test "dashboard API phase board filters scoped grants before card materialization", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-SCOPED-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    assert {:ok, in_scope_sibling} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-SCOPED-SIBLING",
                 kind: "phase_child",
                 status: "blocked",
                 repo: "symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    assert {:ok, other_repo} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-SCOPED-OTHER-REPO",
                 kind: "phase_child",
                 status: "planning",
                 repo: "Pimpmuckl/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    assert {:ok, other_base} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-SCOPED-OTHER-BASE",
                 kind: "phase_child",
                 status: "planning",
                 repo: "symphony-plus-plus",
                 base_branch: "main"
               )
             )

    secret = create_architect_grant_secret(repo, anchor.id)
    PhaseBoardMaterializationRepo.block_materialization(other_repo.id)

    payload =
      try do
        with_endpoint_repo(PhaseBoardMaterializationRepo, fn ->
          json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 200)
        end)
      after
        PhaseBoardMaterializationRepo.clear_materialization_block()
      end

    encoded = Jason.encode!(payload)

    assert payload["total_count"] == 2

    visible_cards =
      payload["groups"]
      |> Map.values()
      |> List.flatten()

    assert Enum.map(visible_cards, & &1["id"]) |> Enum.sort() == Enum.sort([anchor.id, in_scope_sibling.id])
    assert Enum.all?(visible_cards, &(&1["repo"] == "symphony-plus-plus"))
    assert Enum.all?(visible_cards, &(&1["repo_key"] == "symphony-plus-plus"))
    assert Enum.all?(visible_cards, &(&1["repo_remote"] == nil))
    assert Enum.all?(visible_cards, &(&1["repo_aliases"] == ["symphony-plus-plus"]))

    assert encoded =~ anchor.id
    assert encoded =~ in_scope_sibling.id
    refute encoded =~ other_repo.id
    refute encoded =~ other_base.id
  end

  test "dashboard API package detail rejects scoped phase siblings outside frozen repo and base", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-DETAIL-SCOPED-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    assert {:ok, in_scope_sibling} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-DETAIL-SCOPED-SIBLING",
                 kind: "phase_child",
                 status: "blocked",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    assert {:ok, other_repo} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-DETAIL-SCOPED-OTHER-REPO",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/other-repo",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    assert {:ok, other_base} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-DETAIL-SCOPED-OTHER-BASE",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "main"
               )
             )

    secret = create_architect_grant_secret(repo, anchor.id)

    assert %{"work_package" => %{"id" => "SYMPP-DASH-DETAIL-SCOPED-SIBLING"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{in_scope_sibling.id}"), 200)

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{other_repo.id}"), 403)

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{other_base.id}"), 403)
  end

  test "dashboard API lists scoped WorkRequest cards with counts", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-WR-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    in_scope =
      create_work_request!(
        repo,
        id: "WR-DASH-IN-SCOPE",
        title: "Read WorkRequests",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    _out_of_scope =
      create_work_request!(
        repo,
        id: "WR-DASH-OUT-OF-SCOPE",
        repo: "nextide/other",
        base_branch: anchor.base_branch
      )

    assert {:ok, _open_question} = WorkRequestRepository.ask_question(repo, in_scope.id, question_attrs(id: "WRQ-DASH-OPEN"))

    assert {:ok, answered_question} =
             WorkRequestRepository.ask_question(repo, in_scope.id, question_attrs(id: "WRQ-DASH-ANSWERED"))

    assert {:ok, _answered} =
             WorkRequestRepository.answer_question(repo, answered_question.id, "open", %{
               answer: "Use the backend API only.",
               answered_by: "operator-1"
             })

    assert {:ok, closed_question} = WorkRequestRepository.ask_question(repo, in_scope.id, question_attrs(id: "WRQ-DASH-CLOSED"))
    assert {:ok, _closed} = WorkRequestRepository.close_question(repo, closed_question.id, "open")

    assert {:ok, _decision} = WorkRequestRepository.record_decision(repo, in_scope.id, decision_attrs(id: "WRD-DASH-1"))
    assert {:ok, planned} = CanonicalWorkPackageFixtures.add_work_package(repo, in_scope.id, work_package_attrs(id: "WRS-DASH-PLANNED"))
    assert {:ok, approved} = CanonicalWorkPackageFixtures.add_work_package(repo, in_scope.id, work_package_attrs(id: "WRS-DASH-APPROVED"))
    assert {:ok, dispatched} = CanonicalWorkPackageFixtures.add_work_package(repo, in_scope.id, work_package_attrs(id: "WRS-DASH-DISPATCHED"))
    assert {:ok, skipped} = CanonicalWorkPackageFixtures.add_work_package(repo, in_scope.id, work_package_attrs(id: "WRS-DASH-SKIPPED"))

    assert planned.status == "planned"
    repo.update!(Ecto.Changeset.change(approved, status: "planned"))

    repo.update!(
      Ecto.Changeset.change(dispatched,
        status: "ready_for_worker",
        dispatched_at: DateTime.utc_now(:microsecond)
      )
    )

    repo.update!(Ecto.Changeset.change(skipped, status: "skipped"))

    secret = create_architect_grant_secret(repo, anchor.id)
    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests"), 200)

    assert payload["total_count"] == 1

    assert [
             %{
               "id" => "WR-DASH-IN-SCOPE",
               "title" => "Read WorkRequests",
               "repo" => "nextide/symphony-plus-plus",
               "base_branch" => "symphony-plus-plus/beta",
               "work_type" => "feature",
               "desired_dispatch_shape" => "single_package",
               "status" => "ready_for_slicing",
               "open_question_count" => 1,
               "answered_question_count" => 1,
               "closed_question_count" => 1,
               "decision_count" => 1,
               "work_package_count" => 4,
               "planned_work_package_count" => 2,
               "dispatched_work_package_count" => 1,
               "skipped_work_package_count" => 1
             }
           ] = payload["work_requests"]
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
      grant = %AccessGrant{
        grant_role: "architect",
        capabilities: ["read:phase"],
        phase_id: "phase-batch",
        scope_repo: "nextide/symphony-plus-plus",
        scope_base_branch: "main"
      }

      assert {:ok, payload} = Dashboard.work_requests_for_grant(WorkRequestCardCountingRepo, grant)
      assert payload.total_count == 2
      assert Enum.map(payload.work_requests, & &1.id) == [first.id, second.id]

      assert Agent.get(counter, & &1) == %{
               "sympp_work_requests" => 1,
               "sympp_work_request_clarification_questions" => 1,
               "sympp_work_request_decision_logs" => 1,
               "sympp_work_packages" => 1,
               "sympp_work_package_deliveries" => 1,
               "sympp_comments" => 1
             }
    after
      WorkRequestCardCountingRepo.clear_counter()
      Agent.stop(counter)
    end
  end

  test "dashboard WorkRequest list has deterministic card order", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-WR-ORDER-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    newer = create_work_request!(repo, id: "WR-DASH-ORDER-B", repo: anchor.repo, base_branch: anchor.base_branch)
    older = create_work_request!(repo, id: "WR-DASH-ORDER-A", repo: anchor.repo, base_branch: anchor.base_branch)

    older_inserted_at = DateTime.add(newer.inserted_at, -60, :second)
    repo.update!(Ecto.Changeset.change(older, inserted_at: older_inserted_at))

    secret = create_architect_grant_secret(repo, anchor.id)
    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests"), 200)

    assert Enum.map(payload["work_requests"], & &1["id"]) == [older.id, newer.id]
  end

  test "dashboard API returns redacted deterministic WorkRequest detail", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-WR-DETAIL-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    work_request =
      create_work_request!(
        repo,
        id: "WR-DASH-DETAIL",
        title: "Detail WorkRequest",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        human_description: "Use Bearer raw-secret-value for validation",
        constraints: %{"token" => "raw-secret-value", "safe" => "visible"}
      )

    assert {:ok, product_node} =
             ProductTree.create_node(repo, %{
               id: "PTN-DASH-DETAIL",
               work_request_id: work_request.id,
               title: "Dashboard detail node"
             })

    assert {:ok, second_question} =
             WorkRequestRepository.ask_question(repo, work_request.id, question_attrs(id: "WRQ-DETAIL-B", question: "Second?"))

    assert {:ok, first_question} =
             WorkRequestRepository.ask_question(repo, work_request.id, question_attrs(id: "WRQ-DETAIL-A", question: "First sk-secret123?"))

    assert {:ok, _answered} =
             WorkRequestRepository.answer_question(repo, first_question.id, "open", %{
               answer: "Bearer raw-secret-value",
               answered_by: "operator-1"
             })

    assert {:ok, second_decision} =
             WorkRequestRepository.record_decision(
               repo,
               work_request.id,
               decision_attrs(id: "WRD-DETAIL-B", decision: "Second decision")
             )

    assert {:ok, first_decision} =
             WorkRequestRepository.record_decision(
               repo,
               work_request.id,
               decision_attrs(id: "WRD-DETAIL-A", decision: "Use https://example.test/path?sig=raw-secret-value")
             )

    assert {:ok, second_slice} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_package_attrs(id: "WRS-DETAIL-B", title: "Second slice")
             )

    assert {:ok, first_slice} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_package_attrs(
                 id: "WRS-DETAIL-A",
                 title: "Slice with ghp_secret123",
                 product_tree_node_id: product_node.id
               )
             )

    secret = create_architect_grant_secret(repo, anchor.id)
    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/#{work_request.id}"), 200)

    assert payload["work_request"]["title"] == "Detail WorkRequest"
    assert payload["work_request"]["human_description"] == "[REDACTED]"
    assert payload["work_request"]["constraints"]["token"] == "[REDACTED]"
    assert payload["work_request"]["constraints"]["safe"] == "visible"
    assert Enum.map(payload["clarification_questions"], & &1["id"]) == [second_question.id, first_question.id]
    assert Enum.at(payload["clarification_questions"], 1)["question"] == "[REDACTED]"
    assert Enum.at(payload["clarification_questions"], 1)["answer"] == "[REDACTED]"
    assert Enum.map(payload["decision_logs"], & &1["id"]) == [second_decision.id, first_decision.id]
    assert Enum.at(payload["decision_logs"], 1)["decision"] == "[REDACTED]"
    assert Enum.map(payload["work_packages"], & &1["id"]) == [second_slice.id, first_slice.id]
    assert Enum.at(payload["work_packages"], 1)["title"] == "[REDACTED]"

    work_packages_by_id = Map.new(payload["work_packages"], &{&1["id"], &1})
    assert work_packages_by_id[first_slice.id]["product_tree_node_id"] == product_node.id
    assert payload["product_tree"]["root_work_package_ids"] == [second_slice.id]

    product_node_id = product_node.id
    first_slice_id = first_slice.id
    assert [%{"id" => ^product_node_id, "work_package_ids" => [^first_slice_id]}] = payload["product_tree"]["nodes"]

    assert payload["summary"] == %{
             "open_question_count" => 1,
             "answered_question_count" => 1,
             "closed_question_count" => 0,
             "decision_count" => 2,
             "comment_count" => 0,
             "open_comment_count" => 0,
             "work_package_count" => 2,
             "planned_work_package_count" => 2,
             "dispatched_work_package_count" => 0,
             "skipped_work_package_count" => 0
           }
  end

  test "dashboard WorkRequest detail keeps skipped WorkPackages visible", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-SCRATCH-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    work_request =
      create_work_request!(
        repo,
        id: "WR-DASH-SKIPPED-SCRATCH",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, visible_slice} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_package_attrs(id: "WRS-DASH-SCRATCH-VISIBLE")
             )

    assert {:ok, scratch_slice} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_package_attrs(id: "WRS-DASH-SCRATCH-HIDDEN")
             )

    assert {:ok, scratch_slice} = WorkRequestRepository.skip_work_package(repo, work_request.id, scratch_slice.id, "planned")

    assert {:ok, scratch_comment} =
             CommentService.create(repo, %{
               target_kind: "work_package",
               target_id: scratch_slice.id,
               body: "Scratch planning note",
               source_type: "architect",
               author_name: "architect"
             })

    assert {:ok, delivered_slice} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_package_attrs(id: "WRS-DASH-SCRATCH-DELIVERY")
             )

    assert {:ok, delivered_slice} = WorkRequestRepository.skip_work_package(repo, work_request.id, delivered_slice.id, "planned")

    assert {:ok, _delivery} =
             WorkRequestRepository.record_work_package_delivery(
               repo,
               work_request.id,
               delivered_slice.id,
               delivery_attrs(%{
                 outcome: "abandoned",
                 idempotency_key: "dashboard-skipped-scratch-delivery",
                 abandoned_rationale: "Operator recorded a terminal delivery outcome."
               })
             )

    secret = create_architect_grant_secret(repo, anchor.id)
    default_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/#{work_request.id}"), 200)

    assert Enum.map(default_payload["work_packages"], & &1["id"]) == [visible_slice.id, scratch_slice.id, delivered_slice.id]
    assert default_payload["summary"]["work_package_count"] == 3
    assert default_payload["summary"]["planned_work_package_count"] == 1
    assert default_payload["summary"]["skipped_work_package_count"] == 2
    assert default_payload["work_request"]["comment_count"] == 1
    assert default_payload["summary"]["comment_count"] == 1

    included_by_id = Map.new(default_payload["work_packages"], &{&1["id"], &1})
    assert get_in(included_by_id, [scratch_slice.id, "comment_count"]) == 1
    assert [%{"id" => scratch_comment_id}] = get_in(included_by_id, [scratch_slice.id, "comments"])
    assert scratch_comment_id == scratch_comment.id
  end

  test "dashboard WorkRequest detail includes redacted comments and aggregate counts", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-COMMENT-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    work_request =
      create_work_request!(
        repo,
        id: "WR-DASH-COMMENTS",
        repo: anchor.repo,
        base_branch: anchor.base_branch
      )

    assert {:ok, slice} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_package_attrs(id: "WRS-DASH-COMMENTS")
             )

    assert {:ok, request_comment} =
             CommentService.create(repo, %{
               target_kind: "work_request",
               target_id: work_request.id,
               body: "Request note includes sk-secret123",
               source_type: "operator",
               author_name: "operator"
             })

    assert {:ok, slice_comment} =
             CommentService.create(repo, %{
               target_kind: "work_package",
               target_id: slice.id,
               body: "Slice note",
               source_type: "architect",
               author_name: "architect"
             })

    request_comment_id = request_comment.id
    slice_comment_id = slice_comment.id

    assert {:ok, _resolved} =
             CommentService.resolve(repo, slice_comment.id, %{
               resolved_by: "operator",
               resolved_source_type: "operator",
               resolution_note: "Closed"
             })

    secret = create_architect_grant_secret(repo, anchor.id)
    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/#{work_request.id}"), 200)

    assert payload["work_request"]["comment_count"] == 2
    assert payload["work_request"]["open_comment_count"] == 1
    assert payload["summary"]["comment_count"] == 2
    assert payload["summary"]["open_comment_count"] == 1

    assert [%{"id" => ^request_comment_id, "body" => "Request note includes [REDACTED]", "status" => "open"}] = payload["comments"]

    assert [slice_payload] = payload["work_packages"]
    assert slice_payload["comment_count"] == 1
    assert slice_payload["open_comment_count"] == 0
    assert [%{"id" => ^slice_comment_id, "status" => "resolved", "resolution_note" => "Closed"}] = slice_payload["comments"]
  end

  test "dashboard WorkRequest detail caps comments per target to newest entries", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-COMMENT-CAP-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    work_request =
      create_work_request!(
        repo,
        id: "WR-DASH-COMMENT-CAP",
        repo: anchor.repo,
        base_branch: anchor.base_branch
      )

    assert {:ok, slice} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_package_attrs(id: "WRS-DASH-COMMENT-CAP")
             )

    Enum.each(1..105, fn index ->
      create_comment_at!(repo, index, %{
        id: numbered_comment_id("comment-wr", index),
        target_kind: "work_request",
        target_id: work_request.id,
        body: "Request comment #{index}",
        source_type: "operator",
        author_name: "operator"
      })

      create_comment_at!(repo, index, %{
        id: numbered_comment_id("comment-slice", index),
        target_kind: "work_package",
        target_id: slice.id,
        body: "Slice comment #{index}",
        source_type: "operator",
        author_name: "operator"
      })
    end)

    expected_request_ids = Enum.map(6..105, &numbered_comment_id("comment-wr", &1))
    expected_slice_ids = Enum.map(6..105, &numbered_comment_id("comment-slice", &1))

    assert {:ok, listed_comments} = CommentService.list_for_target(repo, "work_request", work_request.id)
    assert Enum.map(listed_comments, & &1.id) == expected_request_ids

    secret = create_architect_grant_secret(repo, anchor.id)
    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/#{work_request.id}"), 200)

    assert payload["work_request"]["comment_count"] == 210
    assert payload["summary"]["comment_count"] == 210
    assert Enum.map(payload["comments"], & &1["id"]) == expected_request_ids

    assert [slice_payload] = payload["work_packages"]
    assert Enum.map(slice_payload["comments"], & &1["id"]) == expected_slice_ids
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

  test "grant WorkRequest list and detail promote scoped packages consistently", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-OP-GRANT-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    work_request =
      create_work_request!(
        repo,
        id: "WR-DASH-OP-GRANT-MERGED",
        status: "ready_for_slicing",
        repo: anchor.repo,
        base_branch: anchor.base_branch
      )

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_package_attrs(id: "WRS-OP-GRANT-MERGED", base_branch: anchor.base_branch)
             )

    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")

    merged_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "SYMPP-OP-GRANT-MERGED",
        status: "merged"
      )

    assert {:ok, _dispatched_slice} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", merged_package.id)

    assert {:ok, _delivery} =
             WorkRequestRepository.record_work_package_delivery(
               repo,
               work_request.id,
               merged_package.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: "grant-dashboard-delivery-merged",
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/903",
                 pr_merged_at: ~U[2026-05-24 11:00:00.000000Z],
                 merge_commit_sha: "merge-903"
               })
             )

    assert {:ok, terminal_slice} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_package_attrs(id: "WRS-OP-GRANT-TERMINAL", base_branch: anchor.base_branch)
             )

    assert {:ok, terminal_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, terminal_slice.id, "planned")

    terminal_package =
      create_matching_work_package!(repo, work_request, terminal_slice,
        id: "SYMPP-OP-GRANT-TERMINAL",
        status: "merged"
      )

    assert {:ok, _terminal_dispatched_slice} =
             CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, terminal_slice.id, "approved", terminal_package.id)

    secret = create_architect_grant_secret(repo, anchor.id)
    list_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests"), 200)
    detail_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/#{work_request.id}"), 200)

    [card] = Enum.filter(list_payload["work_requests"], &(&1["id"] == work_request.id))

    assert card["status"] == "sliced"
    assert card["completed_at"] != nil
    assert card["archived_at"] == nil
    assert card["operational_state"]["key"] == "needs_closeout"
    assert card["operational_state"]["label"] == "Needs Closeout"
    assert card["operational_state"]["raw_status"] == "sliced"
    refute Map.has_key?(card["operational_state"], "reason")
    refute Map.has_key?(card["operational_state"], "work_package_status")
    refute Enum.any?(card["operational_state"]["attention_items"] || [], &Map.has_key?(&1, "reason"))
    refute Map.has_key?(card["operational_state"], "has_started")
    refute Map.has_key?(card["operational_state"], "has_active_worker")
    refute Map.has_key?(card["operational_state"], "last_activity_at")
    refute Map.has_key?(card["operational_state"], "is_stale")

    assert detail_payload["work_request"]["operational_state"]["key"] == card["operational_state"]["key"]
    assert detail_payload["work_request"]["completed_at"] == card["completed_at"]
    refute Map.has_key?(detail_payload["work_request"]["operational_state"], "reason")
    refute Map.has_key?(detail_payload["work_request"]["operational_state"], "work_package_status")
    refute Enum.any?(detail_payload["work_request"]["operational_state"]["attention_items"] || [], &Map.has_key?(&1, "reason"))
    refute Map.has_key?(detail_payload["work_request"]["operational_state"], "has_started")
    refute Map.has_key?(detail_payload["work_request"]["operational_state"], "has_active_worker")
    refute Map.has_key?(detail_payload["work_request"]["operational_state"], "last_activity_at")
    refute Map.has_key?(detail_payload["work_request"]["operational_state"], "is_stale")

    grant_packages = Map.new(detail_payload["work_packages"], &{&1["id"], &1})

    assert %{"status" => "merged"} = grant_package = Map.fetch!(grant_packages, merged_package.id)
    assert get_in(grant_package, ["operational_state", "key"]) == "delivered"
    refute Map.has_key?(grant_package, "delivery")
    refute Map.has_key?(grant_package, "successor")
    refute Map.has_key?(grant_package, "work_package_status")
    refute Map.has_key?(grant_package["operational_state"], "reason")
    refute Map.has_key?(grant_package["operational_state"], "work_package_status")
    refute Enum.any?(grant_package["operational_state"]["attention_items"] || [], &Map.has_key?(&1, "reason"))

    assert %{"status" => "merged"} = terminal_grant_package = Map.fetch!(grant_packages, terminal_package.id)
    assert get_in(terminal_grant_package, ["operational_state", "key"]) == "needs_closeout"
    assert terminal_grant_package["attention_reason_codes"] == ["terminal_package_without_delivery_outcome"]
    refute Map.has_key?(terminal_grant_package, "delivery")
    refute Map.has_key?(terminal_grant_package, "successor")
    refute Map.has_key?(terminal_grant_package, "work_package_status")
    refute Map.has_key?(terminal_grant_package["operational_state"], "reason")
    refute Map.has_key?(terminal_grant_package["operational_state"], "work_package_status")
    refute Enum.any?(terminal_grant_package["operational_state"]["attention_items"] || [], &Map.has_key?(&1, "reason"))
    refute Map.has_key?(detail_payload, "delivery_board")
  end

  test "dashboard API WorkRequest endpoints enforce board reader authorization and scope", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-WR-AUTH-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "main"
               )
             )

    in_scope = create_work_request!(repo, id: "WR-DASH-AUTH-IN", repo: anchor.repo, base_branch: anchor.base_branch)
    other_repo = create_work_request!(repo, id: "WR-DASH-AUTH-OTHER", repo: "nextide/other", base_branch: anchor.base_branch)
    other_branch = create_work_request!(repo, id: "WR-DASH-AUTH-BRANCH", repo: anchor.repo, base_branch: "feature/dashboard-auth")

    assert {:ok, legacy_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-WR-AUTH-LEGACY-PACKAGE",
                 kind: "phase_child",
                 status: "blocked",
                 repo: anchor.repo,
                 base_branch: anchor.base_branch
               )
             )

    secret = create_architect_grant_secret(repo, anchor.id)
    legacy_secret = create_legacy_phase_grant_secret(repo, anchor.id, "grant-dashboard-wr-legacy")

    in_scope = repo.update!(Ecto.Changeset.change(in_scope, base_branch: "origin/main"))
    legacy_package = repo.update!(Ecto.Changeset.change(legacy_package, base_branch: "origin/main"))

    assert %{"work_requests" => [%{"id" => "WR-DASH-AUTH-IN"}]} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests"), 200)

    assert %{"work_requests" => [%{"id" => "WR-DASH-AUTH-IN"}]} =
             json_response(get(auth_conn(legacy_secret), "/api/v1/sympp/work-requests"), 200)

    assert %{"work_request" => %{"id" => "WR-DASH-AUTH-IN"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/#{in_scope.id}"), 200)

    assert %{"error" => %{"code" => "not_found"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/#{other_repo.id}"), 404)

    assert %{"error" => %{"code" => "not_found"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/#{other_branch.id}"), 404)

    assert %{"work_request" => %{"id" => "WR-DASH-AUTH-IN"}} =
             json_response(get(auth_conn(legacy_secret), "/api/v1/sympp/work-requests/#{in_scope.id}"), 200)

    assert %{"error" => %{"code" => "not_found"}} =
             json_response(get(auth_conn(legacy_secret), "/api/v1/sympp/work-requests/#{other_repo.id}"), 404)

    assert %{"error" => %{"code" => "not_found"}} =
             json_response(get(auth_conn(legacy_secret), "/api/v1/sympp/work-requests/#{other_branch.id}"), 404)

    legacy_package_id = legacy_package.id

    assert %{"groups" => %{"blocked" => [%{"id" => ^legacy_package_id}]}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 200)

    assert %{"work_package" => %{"id" => ^legacy_package_id}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{legacy_package.id}"), 200)

    assert {:error, :forbidden} =
             Dashboard.work_requests_for_grant(repo, %AccessGrant{grant_role: "operator", capabilities: ["read:phase"]})

    assert %{"error" => %{"code" => "not_found"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/WR-DASH-MISSING"), 404)

    assert %{"error" => %{"code" => "unauthorized"}} =
             json_response(get(build_conn(), "/api/v1/sympp/work-requests"), 401)

    %{work_key_secret: package_secret} = create_dashboard_fixture(repo, id: "SYMPP-DASH-WR-PACKAGE-ONLY")

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(package_secret), "/api/v1/sympp/work-requests"), 403)
  end

  test "dashboard WorkRequest reads normalize database busy errors" do
    grant = %AccessGrant{
      grant_role: "architect",
      capabilities: ["read:phase"],
      phase_id: "phase-busy",
      scope_repo: "nextide/symphony-plus-plus",
      scope_base_branch: "main"
    }

    assert {:error, :database_busy} = Dashboard.work_requests_for_grant(BusyRepo, grant)
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

  test "detail endpoint returns package state with redacted events, artifacts, grants, blockers, and runs", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret, grant: grant} = create_dashboard_fixture(repo)
    sibling_grant = create_claimed_worker_grant(repo, work_package.id, "worker-2")
    assert {:ok, [own_run]} = AgentRunRepository.list_for_work_package(repo, work_package.id)
    assert {:ok, _completed_run} = AgentRunRepository.mark_completed(repo, own_run.id)

    assert {:ok, sibling_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: work_package.id,
               access_grant_id: sibling_grant.id,
               actor_id: "worker-2",
               status: "running",
               attempt: 1,
               worker_host: "other-host",
               worker_task_handle: "task-2",
               workspace_path: "C:/tmp/other-workspace",
               session_id: "session-2"
             })

    assert {:ok, _sibling_progress} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Sibling package progress",
               status: "working",
               actor_id: "worker-2",
               actor_type: "worker",
               access_grant_id: sibling_grant.id,
               agent_run_id: sibling_run.id,
               payload: %{type: "status", source_tool: "test"}
             })

    assert {:ok, _sibling_finding} =
             PlanningRepository.append_finding(repo, %{
               work_package_id: work_package.id,
               title: "Sibling package finding",
               body: "Shared package context",
               severity: "low",
               access_grant_id: sibling_grant.id
             })

    assert {:ok, _sibling_metadata} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Sibling metadata",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/example/repo/pull/2",
                 head_sha: "abc123",
                 access_grant_id: sibling_grant.id,
                 agent_run_id: sibling_run.id,
                 actor: %{id: "worker-2", type: "worker"}
               }
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["work_package"]["id"] == work_package.id
    assert payload["summary"]["artifact_count"] == 1
    assert payload["summary"]["grant_count"] == 1
    assert payload["summary"]["agent_run_count"] == 1
    assert payload["summary"]["active_agent_run_count"] == 0
    assert payload["summary"]["runtime"]["active_count"] == 0
    assert payload["summary"]["runtime"]["failed_count"] == 0
    assert payload["summary"]["runtime"]["stale_count"] == 0
    assert [%{"path" => "[REDACTED]", "title" => "[REDACTED]", "kind" => "review"}] = payload["artifacts"]
    assert [%{"id" => "blocker-a", "active" => true}] = payload["blockers"]
    assert [%{"id" => grant_id, "display_key" => display_key, "status" => "active"}] = payload["grants"]
    assert grant_id == grant.id
    assert display_key == grant.display_key
    assert [%{"status" => "completed", "session_id" => "session-1"}] = payload["agent_runs"]
    assert [%{"runtime_state" => "terminal", "stale" => false}] = payload["agent_runs"]
    assert [%{"access_grant_id" => ^grant_id, "actor_id" => "worker-1"}] = payload["agent_runs"]
    assert is_nil(payload["active_agent_run"])
    alerts = Map.new(payload["alert_indicators"], &{&1["type"], &1})
    refute alerts["stale_heartbeat"]["active"]
    refute alerts["failed_run"]["active"]

    encoded = Jason.encode!(payload)
    assert encoded =~ "Sibling package progress"
    assert encoded =~ "Sibling package finding"
    refute encoded =~ secret
    refute encoded =~ grant.secret_hash
    refute encoded =~ sibling_grant.id
    refute encoded =~ sibling_run.id
    refute encoded =~ "worker-2"
    refute encoded =~ "other-workspace"
    refute encoded =~ "raw-secret-value"
    assert encoded =~ "[REDACTED]"
  end

  test "worker-scoped stale alerts keep the configured threshold", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret, grant: grant} =
      create_dashboard_fixture(repo, id: "SYMPP-RUNTIME-SCOPED-STALE")

    assert {:ok, [run]} = AgentRunRepository.list_for_work_package(repo, work_package.id)
    assert {:ok, _completed_run} = AgentRunRepository.mark_completed(repo, run.id)

    assert {:ok, stale_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: work_package.id,
               access_grant_id: grant.id,
               actor_id: "worker-1",
               status: "starting",
               attempt: 2,
               worker_task_handle: "queued-task"
             })

    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -600, :second)

    assert {:ok, _stale_run} =
             stale_run
             |> AgentRun.update_changeset(%{last_seen_at: stale_seen_at})
             |> repo.update()

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    alerts = Map.new(payload["alert_indicators"], &{&1["type"], &1})

    assert payload["summary"]["runtime"]["stale_heartbeat_after_seconds"] == 300
    assert payload["summary"]["active_agent_run_count"] == 1
    assert payload["summary"]["queued_agent_run_count"] == 1
    assert payload["summary"]["runtime"]["stale_count"] == 1
    assert payload["active_agent_run"]["runtime_state"] == "queued"
    assert alerts["stale_heartbeat"]["active"] == true
    assert alerts["stale_heartbeat"]["detail"] == "1 run(s) past 300s"
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

  test "runtime alert indicators expose stale, blocker, failed, stopped, and queued states without secrets", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret, grant: grant} =
      create_dashboard_fixture(repo, id: "SYMPP-RUNTIME-API", status: "blocked")

    assert {:ok, [run]} = AgentRunRepository.list_for_work_package(repo, work_package.id)
    assert {:ok, failed_run} = AgentRunRepository.mark_failed(repo, run.id, "failed with Bearer raw-secret-value")

    assert {:ok, stopped_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: work_package.id,
               access_grant_id: grant.id,
               actor_id: "worker-1",
               status: "running",
               attempt: 2,
               worker_task_handle: "stopped-task"
             })

    assert {:ok, _stopped_run} = AgentRunRepository.mark_stopped(repo, stopped_run.id, "operator stopped raw-secret-value")

    assert {:ok, queued_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: work_package.id,
               access_grant_id: grant.id,
               actor_id: "worker-1",
               status: "starting",
               attempt: 3,
               worker_task_handle: "queued-task",
               session_id: "session-queued"
             })

    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -600, :second)

    assert {:ok, _stale_queued_run} =
             queued_run
             |> AgentRun.update_changeset(%{last_seen_at: stale_seen_at})
             |> repo.update()

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["summary"]["active_agent_run_count"] == 1
    assert payload["summary"]["queued_agent_run_count"] == 1
    assert payload["summary"]["stopped_agent_run_count"] == 1
    assert payload["summary"]["failed_agent_run_count"] == 1
    assert payload["summary"]["stale_agent_run_count"] == 1
    assert payload["summary"]["runtime"]["stale_heartbeat_after_seconds"] == 300

    assert Enum.any?(payload["agent_runs"], &(&1["id"] == failed_run.id and &1["runtime_state"] == "terminal"))
    assert Enum.any?(payload["agent_runs"], &(&1["runtime_state"] == "stopped"))
    assert Enum.any?(payload["agent_runs"], &(&1["runtime_state"] == "queued" and &1["stale"] == true))

    alerts = Map.new(payload["alert_indicators"], &{&1["type"], &1})
    assert alerts["blocker"]["active"] == true
    assert alerts["stale_heartbeat"]["active"] == true
    assert alerts["failed_run"]["active"] == true
    assert alerts["scope_drift"]["placeholder"] == false
    assert alerts["scope_drift"]["reasons"] == []
    refute alerts["scope_drift"]["active"]

    encoded = Jason.encode!(payload)
    refute encoded =~ "raw-secret-value"
    refute encoded =~ "Bearer "
  end

  test "blocked packages do not show an active blocker alert after blockers are resolved", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUNTIME-RESOLVED-BLOCKER", status: "blocked"))

    secret = create_architect_grant_secret(repo, work_package.id)
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _reported} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Blocked",
               status: "blocked",
               payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: "blocker-a", active: true},
               created_at: timestamp
             })

    assert {:ok, _resolved} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Unblocked",
               status: "unblocked",
               payload: %{type: "blocker", source_tool: "resolve_blocker", blocker_id: "blocker-a", active: false},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    alerts = Map.new(payload["alert_indicators"], &{&1["type"], &1})

    assert payload["summary"]["active_blocker_count"] == 0
    refute alerts["blocker"]["active"]
    assert alerts["blocker"]["detail"] == "0 active blockers"
  end

  test "stale alert uses the latest active run heartbeat", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUNTIME-CURRENT", status: "implementing"))

    secret = create_architect_grant_secret(repo, work_package.id)
    now = DateTime.utc_now(:microsecond)

    assert {:ok, _older_stale_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: work_package.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "older-stale",
               last_seen_at: DateTime.add(now, -600, :second)
             })

    assert {:ok, [older_stale_run]} = AgentRunRepository.list_for_work_package(repo, work_package.id)
    assert {:ok, _stopped_run} = AgentRunRepository.mark_stopped(repo, older_stale_run.id, "superseded")

    assert {:ok, _fresh_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: work_package.id,
               status: "running",
               attempt: 2,
               worker_task_handle: "fresh-active",
               last_seen_at: now
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    alerts = Map.new(payload["alert_indicators"], &{&1["type"], &1})

    assert payload["summary"]["active_agent_run_count"] == 1
    assert payload["summary"]["stale_agent_run_count"] == 0
    refute alerts["stale_heartbeat"]["active"]
  end

  test "ready packages missing provider-backed delivery evidence are flagged in API", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-MISSING",
                 kind: "mcp",
                 status: "ready_for_merge",
                 policy_template: "mcp"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert missing["active"] == true
    assert "branch_attached" in missing["missing"]
    assert "pr_attached" in missing["missing"]
  end

  test "headless investigation evidence is projected without a recommendation artifact gate", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-HEADLESS-INVESTIGATION",
                 kind: "investigation",
                 status: "ready_for_merge"
               )
             )

    assert {:ok, _finding} =
             PlanningRepository.append_finding(repo, %{
               work_package_id: work_package.id,
               title: "Recommendation",
               body: "No code change needed.",
               idempotency_key: "headless-investigation-finding"
             })

    assert {:ok, _review_package} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Headless evidence submitted",
               status: "review_package_submitted",
               payload: %{
                 type: "review_package",
                 source_tool: "submit_review_package",
                 tests: ["Investigation evidence reviewed"],
                 artifacts: []
               }
             })

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, work_package.id)

    assert %{review_package: %{"type" => "review_package"} = review_package} =
             MetadataProjection.metadata(progress_events, [], work_package.id, nil)

    refute Map.has_key?(review_package, "head_sha")

    secret = create_architect_grant_secret(repo, work_package.id)
    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert missing["active"] == false
    assert missing["missing"] == []
  end

  test "ready package detail follows the dispatched generic review requirement", %{repo: repo} do
    review = %{"type" => "human", "args" => %{"team" => "maintainers"}}
    work_request = create_work_request!(repo, id: "WR-DASH-FAST-READY", status: "ready_for_slicing")

    assert {:ok, planned} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_package_attrs(
                 id: "WRS-DASH-FAST-READY",
                 title: "Generic review dashboard readiness",
                 review_requirement: review
               )
             )

    assert {:ok, approved} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, planned.id, "planned")

    work_package =
      create_matching_work_package!(repo, work_request, approved,
        id: "SYMPP-DASH-FAST-READY",
        status: "ready_for_merge",
        policy_template: "mcp"
      )

    assert {:ok, _linked} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved.id, "approved", work_package.id)

    secret = create_architect_grant_secret(repo, work_package.id)
    append_ready_delivery_evidence(repo, work_package)

    assert {:ok, _completion} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               idempotency_key: "complete_review:#{work_package.id}:current:dashboard",
               summary: "Required review completed",
               status: "review_complete",
               payload: %{
                 type: "review_completion",
                 source_tool: "complete_review",
                 work_package_id: work_package.id,
                 head_sha: "abc123",
                 review: review,
                 reference: "human-review-42"
               }
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert missing["active"] == false
    refute "review_complete" in missing["missing"]
  end

  test "package detail exposes sanitized generic review completion evidence", %{repo: repo} do
    review = %{"type" => "human", "args" => %{"team" => "maintainers"}}

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-REVIEW-COMPLETION",
                 kind: "mcp",
                 status: "ready_for_merge",
                 policy_template: "mcp",
                 review_requirement: review
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    append_ready_delivery_evidence(repo, work_package)

    assert {:ok, _completion} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               actor_id: "worker-1",
               summary: "Required review completed",
               idempotency_key: "complete_review:#{work_package.id}:current:dashboard",
               status: "review_complete",
               created_at: ~U[2026-05-05 00:00:10Z],
               payload: %{
                 type: "review_completion",
                 source_tool: "complete_review",
                 work_package_id: work_package.id,
                 head_sha: "abc123",
                 review: review,
                 reference: "human-review-42",
                 note: "Bearer raw-review-token"
               }
             })

    assert {:ok, _stale_completion} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Stale review completion",
               idempotency_key: "complete_review:#{work_package.id}:current:stale",
               status: "review_complete",
               created_at: ~U[2026-05-05 00:00:00Z],
               payload: %{
                 type: "review_completion",
                 source_tool: "complete_review",
                 work_package_id: work_package.id,
                 head_sha: "older-head",
                 review: review,
                 reference: "stale-review"
               }
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert payload["metadata"]["review_completion"]["review"] == review
    assert payload["metadata"]["review_completion"]["reference"] == "human-review-42"
    refute "review_complete" in missing["missing"]
    refute inspect(payload) =~ "Bearer "

    work_package
    |> Ecto.Changeset.change(review_requirement: %{"type" => "automated"})
    |> repo.update!()

    changed_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    changed_missing = Enum.find(changed_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert changed_payload["metadata"]["review_completion"] == nil
    assert "review_complete" in changed_missing["missing"]
  end

  test "dashboard generic review readiness requires dedicated exact-head completion", %{repo: repo} do
    review = %{"type" => "human", "args" => %{"team" => "maintainers"}}

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-GENERIC-REVIEW",
                 kind: "quick_fix",
                 status: "ready_for_merge",
                 policy_template: "quick_fix",
                 review_requirement: review
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "abc123"},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _spoofed_completion} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Spoofed completion",
               status: "review_complete",
               payload: %{type: "review_completion", source_tool: "append_progress", head_sha: "abc123", review: review},
               created_at: DateTime.add(timestamp, 3, :second)
             })

    missing_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(missing_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert missing["active"] == true
    assert "review_complete" in missing["missing"]

    assert {:ok, _completion} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               idempotency_key: "complete_review:#{work_package.id}:current:dashboard",
               summary: "Required review completed",
               status: "review_complete",
               payload: %{
                 type: "review_completion",
                 source_tool: "complete_review",
                 work_package_id: work_package.id,
                 head_sha: "abc123",
                 review: review
               },
               created_at: DateTime.add(timestamp, 4, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    complete = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert complete["active"] == false
  end

  test "readiness remains anchored to the latest branch head after PR attach", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-PR-HEAD",
                 kind: "mcp",
                 status: "ready_for_merge",
                 policy_template: "mcp"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "old-head"},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/7", head_sha: "new-head"},
               created_at: DateTime.add(timestamp, 3, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert missing["active"] == true
    refute "branch_attached" in missing["missing"]
    assert "pr_attached" in missing["missing"]
  end

  test "dashboard readiness does not accept PR sync without attached PR identity", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-SYNC-WITHOUT-ATTACH",
                 kind: "mcp",
                 status: "ready_for_merge",
                 policy_template: "mcp"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-a"},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _pr_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced without attach",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/7",
                 head_sha: "head-a",
                 check_summary: %{conclusion: "success"}
               },
               created_at: DateTime.add(timestamp, 2, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert "pr_attached" in missing["missing"]
    assert payload["metadata"]["pr"] == nil
  end

  test "dashboard current PR state gate validates synced state separately from attachment", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-CURRENT-PR-STATE",
                 kind: "mcp",
                 status: "ready_for_merge",
                 policy_template: "mcp_current_pr_state"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
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
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/8", head_sha: "head-a"},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    refute "pr_attached" in missing["missing"]
    assert "current_pr_state" in missing["missing"]

    assert {:ok, _invalid_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/8",
                 head_sha: "head-a",
                 check_summary: %{token: "x"}
               },
               created_at: DateTime.add(timestamp, 3, :second)
             })

    invalid_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    invalid_missing = Enum.find(invalid_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert "current_pr_state" in invalid_missing["missing"]

    assert {:ok, _raw_state_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/8",
                 head_sha: "head-a",
                 review_state: %{draft: false},
                 merge_state: %{state: "open"}
               },
               created_at: DateTime.add(timestamp, 4, :second)
             })

    raw_state_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    raw_state_missing = Enum.find(raw_state_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert "current_pr_state" in raw_state_missing["missing"]

    assert {:ok, _boolean_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/8",
                 head_sha: "head-a",
                 merge_state: %{mergeable: true, merged: false}
               },
               created_at: DateTime.add(timestamp, 5, :second)
             })

    boolean_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    boolean_missing = Enum.find(boolean_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    refute "current_pr_state" in boolean_missing["missing"]

    assert {:ok, _valid_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/8",
                 head_sha: "head-a",
                 check_summary: %{conclusion: "success"}
               },
               created_at: DateTime.add(timestamp, 6, :second)
             })

    valid_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    valid_missing = Enum.find(valid_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    refute "current_pr_state" in valid_missing["missing"]

    assert {:ok, _same_pr_reattach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR reattached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/8", head_sha: "head-a"},
               created_at: DateTime.add(timestamp, 7, :second)
             })

    reattach_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    reattach_missing = Enum.find(reattach_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert "current_pr_state" in reattach_missing["missing"]
    assert reattach_payload["metadata"]["pr"]["source_tool"] == "attach_pr"
    refute Map.has_key?(reattach_payload["metadata"]["pr"], "check_summary")

    assert {:ok, _resync_after_reattach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/8",
                 head_sha: "head-a",
                 check_summary: %{conclusion: "success"}
               },
               created_at: DateTime.add(timestamp, 8, :second)
             })

    assert {:ok, _new_pr_attach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Different PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/9", head_sha: "head-a"},
               created_at: DateTime.add(timestamp, 9, :second)
             })

    different_pr_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    different_pr_missing = Enum.find(different_pr_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert "current_pr_state" in different_pr_missing["missing"]
    assert different_pr_payload["metadata"]["pr"]["url"] == "https://github.com/example/repo/pull/9"
    refute Map.has_key?(different_pr_payload["metadata"]["pr"], "check_summary")

    assert {:ok, _new_branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch advanced",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-b"},
               created_at: DateTime.add(timestamp, 10, :second)
             })

    stale_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    stale_missing = Enum.find(stale_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert "current_pr_state" in stale_missing["missing"]
  end

  test "dashboard current PR state accepts semantic attach_pr metadata", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-ATTACH-PR-STATE",
                 kind: "mcp",
                 status: "ready_for_merge",
                 policy_template: "mcp_current_pr_state"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
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
               summary: "PR attached with state",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/example/repo/pull/10",
                 repository: "example/repo",
                 number: 10,
                 head_sha: "head-a",
                 check_summary: %{conclusion: "success"},
                 review_state: %{state: "approved"},
                 merge_state: %{state: "clean"}
               },
               created_at: DateTime.add(timestamp, 2, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    refute "pr_attached" in missing["missing"]
    refute "current_pr_state" in missing["missing"]
    assert payload["metadata"]["pr"]["source_tool"] == "attach_pr"
    assert payload["metadata"]["pr"]["check_summary"]["conclusion"] == "success"
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
    assert MetadataProjection.metadata(stale_events, [], "SYMPP-SEQUENCELESS", nil).pr["source_tool"] == "attach_pr"
    refute Map.has_key?(MetadataProjection.metadata(stale_events, [], "SYMPP-SEQUENCELESS", nil).pr, "check_summary")

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
    assert MetadataProjection.metadata(fresh_events, [], "SYMPP-SEQUENCELESS", nil).pr["source_tool"] == "sync_pr"
  end

  test "dashboard exposes structured scope guard readiness reasons without synced secrets", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-SCOPE-GUARD",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta",
                 status: "ready_for_merge",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: ["elixir/lib/**"]
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    timestamp = ~U[2026-05-05 00:00:00Z]
    head_sha = "scope-dashboard-head"

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/#{work_package.id}", "head_sha" => head_sha},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/nextide/symphony-plus-plus/pull/12", "head_sha" => head_sha},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 "type" => "pr",
                 "source_tool" => "sync_pr",
                 "url" => "https://github.com/nextide/symphony-plus-plus/pull/12",
                 "head_sha" => head_sha,
                 "base_branch" => "symphony-plus-plus/beta",
                 "changed_files" => [
                   %{"path" => "elixir/lib/symphony_elixir/symphony_plus_plus/dashboard.ex"},
                   %{"path" => "docs/scope-dashboard.md", "token" => "ghp_dashboard_secret"}
                 ],
                 "changed_files_count" => 2,
                 "check_summary" => %{"conclusion" => "success", "token" => "ghp_dashboard_secret"},
                 "review_state" => %{"state" => "approved"},
                 "merge_state" => %{"state" => "clean"}
               },
               created_at: DateTime.add(timestamp, 3, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    alerts = Map.new(payload["alert_indicators"], &{&1["type"], &1})
    missing = alerts["missing_readiness_evidence"]
    scope = alerts["scope_drift"]

    assert "scope_guard" in missing["missing"]
    assert [%{"code" => "out_of_scope_files", "files" => ["docs/scope-dashboard.md"]}] = missing["reasons"]
    assert scope["active"] == true
    assert scope["reasons"] == missing["reasons"]
    refute Jason.encode!(payload) =~ "ghp_dashboard_secret"
  end

  test "dashboard does not treat missing scope preconditions as critical drift", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-SCOPE-PRECONDITION",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta",
                 status: "ready_for_merge",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: ["elixir/lib/**"]
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    alerts = Map.new(payload["alert_indicators"], &{&1["type"], &1})
    scope = alerts["scope_drift"]

    assert scope["active"] == false
    assert scope["severity"] == "info"
    assert [%{"code" => "missing_current_head"}] = scope["reasons"]

    timestamp = ~U[2026-05-05 00:00:00Z]
    head_sha = "scope-precondition-head"

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/#{work_package.id}", "head_sha" => head_sha},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/nextide/symphony-plus-plus/pull/13", "head_sha" => head_sha},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 "type" => "pr",
                 "source_tool" => "sync_pr",
                 "url" => "https://github.com/nextide/symphony-plus-plus/pull/13",
                 "head_sha" => head_sha,
                 "base_branch" => "symphony-plus-plus/beta",
                 "changed_files" => [],
                 "changed_files_count" => 0,
                 "changed_files_available" => false
               },
               created_at: DateTime.add(timestamp, 3, :second)
             })

    blocked_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    blocked_alerts = Map.new(blocked_payload["alert_indicators"], &{&1["type"], &1})
    blocked_scope = blocked_alerts["scope_drift"]

    assert blocked_scope["active"] == true
    assert blocked_scope["severity"] == "warning"
    assert blocked_scope["detail"] == "Scope guard evidence unavailable: changed_files_unavailable"
    assert [%{"code" => "changed_files_unavailable"}] = blocked_scope["reasons"]
  end

  test "detail API exposes stale synced PR metadata without secrets", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-STALE-PR",
                 kind: "mcp",
                 status: "ready_for_merge",
                 policy_template: "mcp"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "branch-head"},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _attached_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/44", head_sha: "old-pr-head"},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/44",
                 repository: "example/repo",
                 number: 44,
                 head_sha: "old-pr-head",
                 changed_files: [%{path: "elixir/lib/example.ex"}],
                 check_summary: %{token: "ghp_should_be_redacted"}
               },
               created_at: DateTime.add(timestamp, 3, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["metadata"]["pr"]["url"] == "https://github.com/example/repo/pull/44"
    assert payload["metadata"]["pr"]["stale"] == true
    assert payload["metadata"]["pr"]["current_head_sha"] == "branch-head"
    assert payload["metadata"]["pr"]["check_summary"]["token"] == "[REDACTED]"
    refute inspect(payload) =~ "ghp_should_be_redacted"
  end

  test "metadata prefers current-head PR over newer stale PR", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-CURRENT-PREFERRED", status: "planning"))

    architect_secret = create_architect_grant_secret(repo, work_package.id)

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{
                 type: "branch",
                 source_tool: "attach_branch",
                 branch: "agent/#{work_package.id}",
                 head_sha: "abcdef1234567890abcdef1234567890abcdef12"
               },
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, _current_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Current PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "abcdef1234567890abcdef1234567890abcdef12"
               },
               created_at: ~U[2026-05-05 00:00:01Z]
             })

    assert {:ok, _current_pr_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Current PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "abcdef1234567890abcdef1234567890abcdef12"
               },
               created_at: ~U[2026-05-05 00:00:02Z]
             })

    assert {:ok, _stale_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Older PR sync arrived late",
               status: "pr_synced",
               payload: %{type: "pr", source_tool: "sync_pr", url: "https://github.com/example/repo/pull/10", head_sha: "old-head"},
               created_at: ~U[2026-05-05 00:00:03Z]
             })

    payload = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["metadata"]["pr"]["head_sha"] == "abcdef1234567890abcdef1234567890abcdef12"
    assert payload["metadata"]["pr"]["stale"] == false
    assert payload["metadata"]["pr"]["current_head_sha"] == "abcdef1234567890abcdef1234567890abcdef12"
  end

  test "metadata treats abbreviated branch head as current against full PR head", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-SHORT-HEAD-STALE", status: "planning"))

    architect_secret = create_architect_grant_secret(repo, work_package.id)

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "abcdef1"},
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "abcdef1234567890abcdef1234567890abcdef12"
               },
               created_at: ~U[2026-05-05 00:00:01Z]
             })

    assert {:ok, _sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "abcdef1234567890abcdef1234567890abcdef12"
               },
               created_at: ~U[2026-05-05 00:00:02Z]
             })

    payload = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["metadata"]["pr"]["stale"] == false
    assert payload["metadata"]["pr"]["current_head_sha"] == "abcdef1"
  end

  test "metadata stays scoped to latest attached PR after reattach", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-REATTACHED", status: "planning"))

    architect_secret = create_architect_grant_secret(repo, work_package.id)

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "current-head"},
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, _first_pr_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "First PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 repository: "example/repo",
                 number: 10,
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "current-head"
               },
               created_at: ~U[2026-05-05 00:00:01Z]
             })

    assert {:ok, _reattached_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR reattached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 repository: "example/repo",
                 number: 11,
                 url: "https://github.com/example/repo/pull/11",
                 head_sha: "old-head"
               },
               created_at: ~U[2026-05-05 00:00:02Z]
             })

    payload = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["metadata"]["pr"]["url"] == "https://github.com/example/repo/pull/11"
    assert payload["metadata"]["pr"]["stale"] == true
    assert payload["metadata"]["pr"]["current_head_sha"] == "current-head"
  end

  test "metadata does not display stale synced PR state after later reattach", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-SYNC-DISPLAY-PREFERRED", status: "planning"))

    architect_secret = create_architect_grant_secret(repo, work_package.id)

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{
                 type: "branch",
                 source_tool: "attach_branch",
                 branch: "agent/#{work_package.id}",
                 head_sha: "current-head"
               },
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, _first_attach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 repository: "example/repo",
                 number: 10,
                 url: "https://github.com/example/repo/pull/10"
               },
               created_at: ~U[2026-05-05 00:00:01Z]
             })

    assert {:ok, _sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 repository: "example/repo",
                 number: 10,
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "current-head",
                 check_summary: %{conclusion: "success"},
                 review_state: %{state: "approved"},
                 merge_state: %{state: "clean"}
               },
               created_at: ~U[2026-05-05 00:00:02Z]
             })

    assert {:ok, _reattach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR reattached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 repository: "example/repo",
                 number: 10,
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "current-head"
               },
               created_at: ~U[2026-05-05 00:00:03Z]
             })

    payload = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["metadata"]["pr"]["source_tool"] == "attach_pr"
    refute Map.has_key?(payload["metadata"]["pr"], "check_summary")
    refute Map.has_key?(payload["metadata"]["pr"], "review_state")
    refute Map.has_key?(payload["metadata"]["pr"], "merge_state")

    assert {:ok, _rich_reattach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR reattached with richer metadata",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 repository: "example/repo",
                 number: 10,
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "current-head",
                 check_summary: %{conclusion: "success", total_count: 7},
                 review_state: %{state: "approved"},
                 merge_state: %{state: "clean"}
               },
               created_at: ~U[2026-05-05 00:00:04Z]
             })

    rich_payload = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert rich_payload["metadata"]["pr"]["source_tool"] == "attach_pr"
    assert rich_payload["metadata"]["pr"]["check_summary"]["total_count"] == 7
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

  test "metadata preserves PR and suppresses review payloads without a current branch head", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BRANCHLESS", status: "planning"))

    architect_secret = create_architect_grant_secret(repo, work_package.id)

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached without branch",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/99", head_sha: "stale"}
             })

    assert {:ok, _review_package} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Review submitted without branch",
               status: "review_package_submitted",
               payload: %{type: "review_package", source_tool: "submit_review_package", head_sha: "stale", artifacts: ["review.txt"]}
             })

    payload = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["metadata"]["branch"] == nil
    assert payload["metadata"]["pr"]["url"] == "https://github.com/example/repo/pull/99"
    assert payload["metadata"]["pr"]["head_sha"] == "stale"
    refute Map.has_key?(payload["metadata"]["pr"], "stale")
    refute Map.has_key?(payload["metadata"]["pr"], "current_head_sha")
    assert payload["metadata"]["review_package"] == nil
  end

  test "timeline endpoint includes progress, finding, and status events in useful order", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret, grant: grant} = create_dashboard_fixture(repo)
    assert {:ok, [run]} = AgentRunRepository.list_for_work_package(repo, work_package.id)

    assert {:ok, _run_bound_progress} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Run-bound package progress",
               status: "working",
               actor_id: "worker-1",
               actor_type: "worker",
               access_grant_id: grant.id,
               agent_run_id: run.id,
               payload: %{type: "status", source_tool: "test"}
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}/timeline"), 200)

    assert [
             %{"type" => "progress", "status" => "branch_attached"},
             %{"type" => "progress", "status" => "pr_attached"},
             %{"type" => "progress", "status" => "blocked"},
             %{"type" => "finding", "severity" => "medium"}
           ] = Enum.take(payload["events"], 4)

    assert Enum.any?(payload["events"], &(&1["status"] == "review_package_submitted"))
    assert Enum.any?(payload["events"], &(&1["summary"] == "Run-bound package progress"))

    encoded = Jason.encode!(payload)
    refute encoded =~ grant.id
    refute encoded =~ run.id
    refute encoded =~ "worker-1"
    assert encoded =~ "[REDACTED]"
  end

  test "dashboard detail redacts text and reports current-head summaries", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret} = create_dashboard_fixture(repo)
    timestamp = ~U[2026-05-05 00:01:00Z]
    unclaimed_key = WorkKey.generate()

    assert {:ok, _skipped} =
             PlanningRepository.append_plan_node(repo, %{
               work_package_id: work_package.id,
               title: "Skipped follow-up",
               body: "No longer needed",
               status: "skipped",
               created_at: timestamp
             })

    assert {:ok, _secret_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Leaked signed URL https://example.test/file.txt?sig=raw-secret-value",
               body: "Bearer raw-secret-value",
               status: "blocked",
               payload: %{type: "status", source_tool: "test"},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _secret_finding} =
             PlanningRepository.append_finding(repo, %{
               work_package_id: work_package.id,
               title: "Token raw-secret-value",
               body: "secret raw-secret-value",
               severity: "high",
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _normal_finding} =
             PlanningRepository.append_finding(repo, %{
               work_package_id: work_package.id,
               title: "Token bucket note",
               body: "Secretary review is not a credential",
               severity: "low",
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _new_branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "New branch head attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "def456"},
               created_at: DateTime.add(timestamp, 3, :second)
             })

    assert {:ok, _blank_changed_branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Changed branch without head",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}-new", head_sha: ""},
               created_at: DateTime.add(timestamp, 3, :second)
             })

    assert {:ok, _backfilled_old_branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Backfilled old branch",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}-old", head_sha: "old123"},
               created_at: DateTime.add(timestamp, -30, :second)
             })

    assert {:ok, _backfilled_old_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Backfilled old PR",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/old", head_sha: "old123"},
               created_at: DateTime.add(timestamp, -29, :second)
             })

    assert {:ok, _spoofed_blocker} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Spoofed blocker",
               status: "blocked",
               payload: %{type: "blocker", source_tool: "append_progress", blocker_id: "spoofed", active: true},
               created_at: DateTime.add(timestamp, 4, :second)
             })

    assert {:ok, _backfilled_old_blocker_resolution} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Backfilled old blocker resolution",
               status: "unblocked",
               payload: %{
                 type: "blocker",
                 source_tool: "resolve_blocker",
                 blocker_id: "blocker-a",
                 active: false,
                 resolution: "historical"
               },
               created_at: DateTime.add(timestamp, -120, :second)
             })

    assert {:ok, _unclaimed} =
             AccessGrantRepository.create(repo, %{
               work_package_id: work_package.id,
               display_key: unclaimed_key.display_key,
               secret_hash: WorkKey.secret_hash(unclaimed_key.secret),
               grant_role: "worker",
               capabilities: ["read:work_package"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    encoded = inspect(payload)

    refute encoded =~ "raw-secret-value"
    refute encoded =~ "wk_"
    assert Enum.any?(payload["progress"], &(&1["summary"] == "[REDACTED]"))
    assert Enum.any?(payload["progress"], &(&1["body"] == "[REDACTED]"))
    assert Enum.any?(payload["findings"], &(&1["title"] == "[REDACTED]"))
    assert Enum.any?(payload["findings"], &(&1["title"] == "Token bucket note"))
    assert payload["summary"]["plan"] == %{"completed_count" => 2, "open_count" => 0, "total_count" => 2}
    assert payload["summary"]["active_blocker_count"] == 1
    assert Enum.any?(payload["blockers"], &(&1["id"] == "blocker-a" and &1["active"] == true))
    refute Enum.any?(payload["blockers"], &(&1["id"] == "spoofed"))
    assert payload["summary"]["grant_count"] == 1
    assert payload["summary"]["active_grant_count"] == 1
    assert Enum.any?(payload["grants"], &(&1["status"] == "active"))
    refute Enum.any?(payload["grants"], &(&1["status"] == "unclaimed"))
    assert payload["metadata"]["branch"]["branch"] == "agent/#{work_package.id}-new"
    assert payload["metadata"]["branch"]["head_sha"] == ""
    assert payload["metadata"]["pr"]["url"] == "https://github.com/example/repo/pull/1"
    assert payload["metadata"]["pr"]["head_sha"] == "abc123"
    refute Map.has_key?(payload["metadata"]["pr"], "stale")
    assert payload["metadata"]["review_package"] == nil
  end

  test "blank branch head sha reuses latest head for the same branch", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret} = create_dashboard_fixture(repo)

    assert {:ok, _blank_branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached without head",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: ""},
               created_at: ~U[2026-05-05 00:03:00Z]
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["metadata"]["branch"]["head_sha"] == ""
    assert payload["metadata"]["pr"]["url"] == "https://github.com/example/repo/pull/1"
  end

  test "dedicated collection endpoints fetch artifacts, blockers, grants, and agent runs", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret} = create_dashboard_fixture(repo)

    assert %{"artifacts" => [%{"path" => "[REDACTED]", "title" => "[REDACTED]"} = artifact]} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}/artifacts"), 200)

    refute Map.has_key?(artifact, "metadata")

    assert %{"blockers" => [%{"id" => "blocker-a", "active" => true}]} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}/blockers"), 200)

    assert %{"grants" => [%{"grant_role" => "worker"}]} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}/grants"), 200)

    assert %{"agent_runs" => [%{"worker_task_handle" => "task-1"}]} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}/agent-runs"), 200)
  end

  test "worker-scoped API cannot fetch global board and cannot fetch sibling packages", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret} = create_dashboard_fixture(repo)
    assert {:ok, sibling} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-SIBLING"))

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 403)

    assert %{"work_package" => %{"id" => fetched_id}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert fetched_id == work_package.id

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{sibling.id}"), 403)
  end

  test "dashboard API rejects unauthenticated reads", %{repo: repo} do
    %{work_package: work_package} = create_dashboard_fixture(repo)

    assert %{"error" => %{"code" => "unauthorized"}} =
             json_response(get(build_conn(), "/api/v1/sympp/board"), 401)

    assert %{"error" => %{"code" => "unauthorized"}} =
             json_response(get(build_conn(), "/api/v1/sympp/work-packages/#{work_package.id}"), 401)

    unknown_work_key_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{WorkKey.generate().secret}")

    assert %{"error" => %{"code" => "unauthorized"}} =
             json_response(get(unknown_work_key_conn, "/api/v1/sympp/board"), 401)
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

  test "local operator dashboard reads do not write to SQLite" do
    {_payload, queries} =
      with_local_operator_endpoint(fn ->
        capture_queries(&local_operator_dashboard_payload/0)
      end)

    assert Enum.filter(queries, &Regex.match?(~r/^\s*(INSERT|UPDATE|DELETE|REPLACE|CREATE|ALTER|DROP)\b/i, &1)) == []
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
      assert is_map(parse_signal.metadata.review_package)
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
      assert fanout_packages["WP-FANOUT-INDEX"].work_package.review_signal.status == "passed"
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
      assert recovery_packages["WP-RECOVERY-SUCCESSOR"].work_package.review_signal.status == "failed"
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

      local_operator_csrf_conn()
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

      local_operator_csrf_conn()
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

  test "package detail repo identity stays scoped to the authorized package", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-REPO-DETAIL-SCOPED",
                 repo: "symphony-plus-plus",
                 base_branch: "main"
               )
             )

    assert {:ok, _unrelated} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-REPO-DETAIL-UNRELATED",
                 repo: "Pimpmuckl/symphony-plus-plus",
                 base_branch: "main"
               )
             )

    secret = create_worker_grant_secret(repo, work_package.id, "repo-detail-worker")
    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["work_package"]["repo"] == "symphony-plus-plus"
    assert payload["work_package"]["repo_key"] == "symphony-plus-plus"
    assert payload["work_package"]["repo_display"] == "symphony-plus-plus"
    assert payload["work_package"]["repo_remote"] == nil
    assert payload["work_package"]["repo_aliases"] == ["symphony-plus-plus"]
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

  test "local operator config returns runtime csrf and asset paths" do
    with_local_operator_endpoint(fn ->
      payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/config"), 200)

      assert payload["apiBase"] == "/api/v1/sympp/operator"
      assert payload["basePath"] == ""
      assert payload["logoUrl"] == "/splusplus-logo.png"
      assert is_binary(payload["csrfToken"])
      assert byte_size(payload["csrfToken"]) > 20
      assert payload["dashboard"]["deferred"] == %{"dashboard_sections" => true}
    end)
  end

  test "local operator config keeps runtime bootstrap usable when priority data is unavailable" do
    with_local_operator_endpoint(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, sympp_repo: BusyRepo)

      payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/config"), 200)

      refute Map.has_key?(payload, "operatorMode")
      assert is_binary(payload["csrfToken"])
      refute Map.has_key?(payload, "dashboard")
    end)
  end

  test "unbound localhost agent requests do not become local operator" do
    with_local_operator_endpoint(fn ->
      conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(get(conn, "/api/v1/sympp/operator/config"), 401)
    end)
  end

  test "ordinary local dashboard load injects CSRF and can mutate without operator mode or bootstrap", %{repo: repo} do
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

        config = dashboard_shell_config(html_response(shell_conn, 200))
        refute Map.has_key?(config, "operatorMode")
        assert is_binary(config["csrfToken"])

        payload =
          shell_conn
          |> recycle_local_operator_conn("http://localhost")
          |> put_req_header("x-csrf-token", config["csrfToken"])
          |> post("/api/v1/sympp/operator/work-requests/#{work_request.id}/state", %{"state" => "completed"})
          |> json_response(200)

        assert payload["work_request"]["operational_state"]["key"] == "completed"
        assert is_binary(payload["work_request"]["completed_at"])

        assert {:ok, %{completed_at: %DateTime{}, completion_source: "operator"}} =
                 WorkRequestRepository.get(repo, work_request.id)
      end)
    end)
  end

  test "ordinary local requests ignore stale work-key session state", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      %{work_package: work_package} = create_dashboard_fixture(repo, id: "SYMPP-LOCAL-RECONNECT")

      stale_session = %{
        "sympp_board_grant_id" => "stale-board-grant",
        "sympp_package_grant_ids" => %{work_package.id => "stale-package-grant"},
        "sympp_package_grant_order" => [work_package.id]
      }

      stale_conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("origin", "http://localhost")
        |> Plug.Test.init_test_session(stale_session)
        |> get("/api/v1/sympp/operator/dashboard")

      assert %{"deferred" => %{"dashboard_sections" => true}} = json_response(stale_conn, 200)

      config_conn =
        build_conn()
        |> Map.put(:host, "localhost")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("origin", "http://localhost")
        |> put_req_header("sec-fetch-site", "same-origin")
        |> put_req_header("sec-fetch-mode", "cors")
        |> put_req_header("sec-fetch-dest", "empty")
        |> Plug.Test.init_test_session(stale_session)
        |> get("/api/v1/sympp/operator/config")

      config = json_response(config_conn, 200)
      refute Map.has_key?(config, "operatorMode")
      csrf_token = config["csrfToken"]
      assert is_binary(csrf_token)

      payload =
        config_conn
        |> recycle_local_operator_conn("http://localhost")
        |> get("/api/v1/sympp/operator/dashboard/deferred")
        |> json_response(200)

      refute Enum.any?(dashboard_work_package_ids(payload), &(&1 == work_package.id))
    end)
  end

  test "spp.localhost dashboard origin can load local operator config" do
    with_local_operator_endpoint(fn ->
      with_local_operator_dashboard_origin("http://127.0.0.1:5174", fn ->
        index = "<!doctype html><html><head></head><body><div id=\"root\"></div></body></html>"

        with_static_dashboard_file("index.html", index, fn ->
          shell_conn =
            build_conn(:get, "/sympp/board")
            |> Map.put(:host, "spp.localhost")
            |> Map.put(:remote_ip, {127, 0, 0, 1})
            |> put_req_header("sec-fetch-site", "none")
            |> put_req_header("sec-fetch-mode", "navigate")
            |> Plug.Test.init_test_session(%{})
            |> ReactDashboardController.index(%{})

          assert redirected_to(shell_conn, 302) == "http://127.0.0.1:5174/sympp/board"

          conn =
            build_conn()
            |> Map.put(:host, "127.0.0.1")
            |> Map.put(:remote_ip, {127, 0, 0, 1})
            |> put_req_header("origin", "http://spp.localhost:5174")
            |> put_req_header("sec-fetch-site", "same-site")
            |> put_req_header("sec-fetch-mode", "cors")
            |> put_req_header("sec-fetch-dest", "empty")
            |> Plug.Test.init_test_session(%{})
            |> get("/api/v1/sympp/operator/config")

          payload = json_response(conn, 200)
          refute Map.has_key?(payload, "operatorMode")
          assert is_binary(payload["csrfToken"])
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
        |> Plug.Test.init_test_session(%{})
        |> get("/api/v1/sympp/operator/config")

      payload = json_response(conn, 200)
      refute Map.has_key?(payload, "operatorMode")
      assert is_binary(payload["csrfToken"])
    end)
  end

  test "configured nonlocal dashboard origin cannot bootstrap local operator API session" do
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
          |> Plug.Test.init_test_session(%{})
          |> get("/api/v1/sympp/operator/config")

        assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
        refute SymppDashboardApiController.local_operator_session?(conn.private.plug_session)
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
               json_response(get(conn, "/api/v1/sympp/operator/config"), 401)
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
          |> Plug.Test.init_test_session(%{})
          |> get("/api/v1/sympp/operator/config")

        payload = json_response(conn, 200)
        refute Map.has_key?(payload, "operatorMode")
        assert is_binary(payload["csrfToken"])
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == ["http://127.0.0.1:5174"]
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-credentials") == ["true"]
      end)
    end)
  end

  test "configured local dashboard origin receives credentialed operator API preflight" do
    with_local_operator_endpoint(fn ->
      with_local_operator_dashboard_origin("http://127.0.0.1:5174", fn ->
        conn =
          build_conn(:options, "/api/v1/sympp/operator/work-requests")
          |> Map.put(:host, "127.0.0.1")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> put_req_header("origin", "http://127.0.0.1:5174")
          |> put_req_header("access-control-request-method", "POST")
          |> put_req_header("access-control-request-headers", "content-type,x-csrf-token")
          |> options("/api/v1/sympp/operator/work-requests")

        assert response(conn, 204) == ""
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == ["http://127.0.0.1:5174"]
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-credentials") == ["true"]
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-methods") == ["GET, POST, OPTIONS"]
        assert Plug.Conn.get_resp_header(conn, "access-control-allow-headers") == ["accept, content-type, x-csrf-token"]
      end)
    end)
  end

  test "configured dashboard origin accepts localhost aliases" do
    with_local_operator_endpoint(fn ->
      with_local_operator_dashboard_origin("http://127.0.0.1:5174", fn ->
        conn =
          build_conn()
          |> Map.put(:host, "127.0.0.1")
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> put_req_header("origin", "http://spp.localhost:5174")
          |> put_req_header("sec-fetch-site", "same-site")
          |> put_req_header("sec-fetch-mode", "cors")
          |> put_req_header("sec-fetch-dest", "empty")
          |> Plug.Test.init_test_session(%{})
          |> get("/api/v1/sympp/operator/config")

        payload = json_response(conn, 200)
        refute Map.has_key?(payload, "operatorMode")
      end)
    end)
  end

  test "local operator accepts configured dashboard origin without session state" do
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
          |> Plug.Test.init_test_session(%{})

        payload = json_response(get(conn, "/api/v1/sympp/operator/config"), 200)
        refute Map.has_key?(payload, "operatorMode")
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
          local_operator_csrf_conn()
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
            local_operator_csrf_conn()
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
            local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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

      local_operator_csrf_conn()
      |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/state", %{"status" => "unblock"})
      |> json_response(200)

      assert {:ok, unblocked} = WorkPackageRepository.get(repo, work_package.id)
      assert unblocked.status == "ready_for_worker"

      retry_payload =
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{merge_package.id}/state", %{"status" => "merged_and_archive"})
        |> json_response(200)

      close_payload =
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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

      local_operator_csrf_conn()
      |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/state", %{"status" => "merged"})
      |> json_response(422)

      assert {:ok, persisted_package} = WorkPackageRepository.get(repo, work_package.id)
      assert persisted_package.status == "closed"
    end)
  end

  test "local operator can clear status-only WorkRequest human info", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      clearable = create_work_request!(repo, id: "WR-LOCAL-CLEAR-HUMAN-INFO", status: "human_info_needed")

      payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-requests/#{clearable.id}/state", %{"state" => "ready_for_slicing"})
        |> json_response(200)

      assert get_in(payload, ["refresh", "work_request_id"]) == clearable.id
      assert get_in(payload, ["work_request", "status"]) == "ready_for_slicing"
      assert {:ok, %{status: "ready_for_slicing"}} = WorkRequestRepository.get(repo, clearable.id)

      guarded = create_work_request!(repo, id: "WR-LOCAL-GUARD-HUMAN-INFO", status: "human_info_needed")
      assert {:ok, _question} = WorkRequestRepository.ask_question(repo, guarded.id, question_attrs(id: "WRQ-LOCAL-GUARD-HUMAN-INFO"))

      error =
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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

      assert {:ok, persisted_guidance} = GuidanceRequestRepository.get(repo, guidance_request.id)
      assert persisted_guidance.status == "answered"
      assert persisted_guidance.answered_by == "terminal-cleanup"

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
      assert audit.decision == "allowed"
      assert audit.reason == "allowed"
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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
        local_operator_csrf_conn()
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

  test "local operator mutations require CSRF protection" do
    with_local_operator_endpoint(fn ->
      index = "<!doctype html><html><head></head><body><div id=\"root\"></div></body></html>"

      with_static_dashboard_file("index.html", index, fn ->
        shell_conn =
          local_operator_conn()
          |> ReactDashboardController.index(%{})

        assert html_response(shell_conn, 200) =~ "csrfToken"

        assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
          shell_conn
          |> recycle_local_operator_conn("http://evil.example")
          |> post("/api/v1/sympp/operator/work-requests", %{
            "title" => "Cross-site dashboard request",
            "repo" => "symphony-plus-plus",
            "base_branch" => "main",
            "work_type" => "feature",
            "human_description" => "This should not reach the local ledger.",
            "desired_dispatch_shape" => "architect_led_feature_branch"
          })
        end
      end)
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
        |> Plug.Test.init_test_session(%{})
        |> Map.put(:script_name, ["app"])
        |> ReactDashboardController.index(%{})
        |> html_response(200)

      assert html =~ ~s(href="/app/splusplus-logo.png")
      assert html =~ ~s(src="/app/assets/index.js")
      assert html =~ "window.SYMPP_DASHBOARD_CONFIG"
      assert html =~ ~s("apiBase":"/app/api/v1/sympp/operator")
      assert html =~ ~s("logoUrl":"/app/splusplus-logo.png")
      assert is_binary(dashboard_shell_config(html)["csrfToken"])
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

  test "dashboard API rejects grants after package authority reaches terminal state", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret} = create_dashboard_fixture(repo, status: "planning")

    assert %{"work_package" => %{"id" => fetched_id}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert fetched_id == work_package.id
    assert {:ok, _terminal_package} = WorkPackageRepository.update(repo, work_package.id, %{status: "merged"})

    assert %{"error" => %{"code" => "unauthorized"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 401)
  end

  test "dashboard browser sessions reject unknown work keys with login responses", %{repo: repo} do
    %{work_package: work_package} = create_dashboard_fixture(repo)
    unknown_secret = WorkKey.generate().secret

    board_conn = post(build_conn(), "/sympp/board/session", %{"work_key" => unknown_secret})

    assert response(board_conn, 401) =~ "The work key could not access the board."

    package_conn =
      post(build_conn(), "/sympp/work-packages/#{work_package.id}/session", %{"work_key" => unknown_secret})

    assert response(package_conn, 401) =~ "The work key could not access this package."
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

  test "dashboard API rejects missing bearer auth before dynamic repo bootstrap" do
    database_path = WorkPackageFactory.database_path()
    File.rm(database_path)

    with_dynamic_endpoint_database(database_path, fn ->
      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(get(build_conn(), "/api/v1/sympp/board"), 401)

      invalid_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer garbage")

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(get(invalid_conn, "/api/v1/sympp/board"), 401)

      unknown_work_key_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{WorkKey.generate().secret}")

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(get(unknown_work_key_conn, "/api/v1/sympp/board"), 401)
    end)

    refute File.exists?(database_path)
  end

  test "dashboard API rejects unknown bearer before missing file URI repo bootstrap" do
    database_path = WorkPackageFactory.database_path()
    File.rm(database_path)
    database_uri = "file:#{String.replace(database_path, "\\", "/")}?mode=rwc"

    with_dynamic_endpoint_database(database_uri, fn ->
      unknown_work_key_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{WorkKey.generate().secret}")

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(get(unknown_work_key_conn, "/api/v1/sympp/board"), 401)
    end)

    refute File.exists?(database_path)
  end

  test "dashboard API rejects invalid bearer against an unmigrated existing database without migration" do
    database_path = WorkPackageFactory.database_path()

    try do
      File.write!(database_path, "")

      unknown_work_key_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{WorkKey.generate().secret}")

      with_configured_endpoint_database(database_path, fn ->
        assert %{"error" => %{"code" => "unauthorized"}} =
                 json_response(get(unknown_work_key_conn, "/api/v1/sympp/board"), 401)
      end)
    after
      File.rm(database_path)
    end
  end

  test "dashboard API migrates existing ledgers before auth reads new phase columns" do
    database_path = WorkPackageFactory.database_path()

    try do
      {work_package_id, secret} = seed_pre_phase_dashboard_database(database_path)

      refute "phase_id" in table_columns(database_path, "sympp_access_grants")
      refute "phase_id" in table_columns(database_path, "sympp_work_packages")

      with_configured_endpoint_database(database_path, fn ->
        assert %{"work_package" => %{"id" => ^work_package_id}} =
                 json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package_id}"), 200)
      end)

      assert "phase_id" in table_columns(database_path, "sympp_access_grants")
      assert "phase_id" in table_columns(database_path, "sympp_work_packages")
    after
      File.rm(database_path)
    end
  end

  test "dashboard board grant auth migrates pre-phase ledgers before phase auth reads phase columns" do
    database_path = WorkPackageFactory.database_path()

    try do
      {_work_package_id, _secret} =
        seed_pre_phase_dashboard_database(database_path,
          work_package_id: "SYMPP-PRE-PHASE-BOARD-AUTH",
          grant_id: "grant-pre-phase-board-auth",
          grant_role: "architect",
          capabilities: ["read:phase"],
          claimed_by: "architect-pre-phase"
        )

      refute "phase_id" in table_columns(database_path, "sympp_access_grants")
      refute "phase_id" in table_columns(database_path, "sympp_work_packages")

      with_configured_endpoint_database(database_path, fn ->
        assert {:error, :forbidden} = SymppDashboardApiController.authorize_board_grant_id("grant-pre-phase-board-auth")
      end)

      assert "phase_id" in table_columns(database_path, "sympp_access_grants")
      assert "phase_id" in table_columns(database_path, "sympp_work_packages")
    after
      File.rm(database_path)
    end
  end

  test "dashboard API board endpoint migrates pristine pre-phase ledgers before phase auth reads" do
    database_path = WorkPackageFactory.database_path()

    try do
      {_work_package_id, secret} =
        seed_pre_phase_dashboard_database(database_path,
          work_package_id: "SYMPP-PRE-PHASE-BOARD-ENDPOINT",
          grant_id: "grant-pre-phase-board-endpoint",
          grant_role: "architect",
          capabilities: ["read:phase"],
          claimed_by: "architect-pre-phase"
        )

      refute "phase_id" in table_columns(database_path, "sympp_access_grants")
      refute "phase_id" in table_columns(database_path, "sympp_work_packages")

      with_configured_endpoint_database(database_path, fn ->
        assert %{"error" => %{"code" => "forbidden"}} =
                 json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 403)
      end)

      assert "phase_id" in table_columns(database_path, "sympp_access_grants")
      assert "phase_id" in table_columns(database_path, "sympp_work_packages")
    after
      File.rm(database_path)
    end
  end

  test "dashboard package grant auth migrates pre-phase ledgers before phase package auth reads" do
    database_path = WorkPackageFactory.database_path()

    try do
      {work_package_id, _secret} =
        seed_pre_phase_dashboard_database(database_path,
          work_package_id: "SYMPP-PRE-PHASE-PACKAGE-AUTH",
          grant_id: "grant-pre-phase-package-auth",
          grant_role: "architect",
          capabilities: ["read:phase"],
          claimed_by: "architect-pre-phase"
        )

      refute "phase_id" in table_columns(database_path, "sympp_access_grants")
      refute "phase_id" in table_columns(database_path, "sympp_work_packages")

      with_configured_endpoint_database(database_path, fn ->
        assert {:error, :forbidden} =
                 SymppDashboardApiController.authorize_package_grant_id("grant-pre-phase-package-auth", work_package_id)
      end)

      assert "phase_id" in table_columns(database_path, "sympp_access_grants")
      assert "phase_id" in table_columns(database_path, "sympp_work_packages")
    after
      File.rm(database_path)
    end
  end

  test "dashboard package session migrates pristine pre-phase ledgers before phase package auth reads" do
    database_path = WorkPackageFactory.database_path()

    try do
      {work_package_id, secret} =
        seed_pre_phase_dashboard_database(database_path,
          work_package_id: "SYMPP-PRE-PHASE-PACKAGE-SESSION",
          grant_id: "grant-pre-phase-package-session",
          grant_role: "architect",
          capabilities: ["read:phase"],
          claimed_by: "architect-pre-phase"
        )

      refute "phase_id" in table_columns(database_path, "sympp_access_grants")
      refute "phase_id" in table_columns(database_path, "sympp_work_packages")

      with_configured_endpoint_database(database_path, fn ->
        conn = post(build_conn(), "/sympp/work-packages/#{work_package_id}/session", %{"work_key" => secret})

        assert response(conn, 403) =~ "The work key is not allowed to open this package."
      end)

      assert "phase_id" in table_columns(database_path, "sympp_access_grants")
      assert "phase_id" in table_columns(database_path, "sympp_work_packages")
    after
      File.rm(database_path)
    end
  end

  test "dashboard API migrates existing ledgers before auth reads scope grant columns" do
    database_path = WorkPackageFactory.database_path()

    try do
      {work_package_id, secret} =
        seed_dashboard_database_at_migration(database_path, 20_260_506_120_000,
          work_package_id: "SYMPP-PRE-SCOPE-AUTH",
          grant_id: "grant-pre-scope-auth"
        )

      assert "phase_id" in table_columns(database_path, "sympp_access_grants")
      refute "scope_repo" in table_columns(database_path, "sympp_access_grants")
      refute "scope_base_branch" in table_columns(database_path, "sympp_access_grants")
      refute "provenance" in table_columns(database_path, "sympp_access_grants")

      with_configured_endpoint_database(database_path, fn ->
        assert %{"work_package" => %{"id" => ^work_package_id}} =
                 json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package_id}"), 200)
      end)

      assert "scope_repo" in table_columns(database_path, "sympp_access_grants")
      assert "scope_base_branch" in table_columns(database_path, "sympp_access_grants")
      assert "provenance" in table_columns(database_path, "sympp_access_grants")
    after
      File.rm(database_path)
    end
  end

  test "dashboard package session migrates existing ledgers before auth reads provenance" do
    database_path = WorkPackageFactory.database_path()

    try do
      {work_package_id, secret} =
        seed_dashboard_database_at_migration(database_path, 20_260_506_143_000,
          work_package_id: "SYMPP-PRE-PROVENANCE-SESSION",
          grant_id: "grant-pre-provenance-session"
        )

      assert "scope_repo" in table_columns(database_path, "sympp_access_grants")
      assert "scope_base_branch" in table_columns(database_path, "sympp_access_grants")
      refute "provenance" in table_columns(database_path, "sympp_access_grants")

      with_configured_endpoint_database(database_path, fn ->
        conn = post(build_conn(), "/sympp/work-packages/#{work_package_id}/session", %{"work_key" => secret})

        assert redirected_to(conn) == "/sympp/work-packages/#{work_package_id}"
      end)

      assert "provenance" in table_columns(database_path, "sympp_access_grants")
    after
      File.rm(database_path)
    end
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

  test "dashboard API rejects invalid non-string database config before auth storage access" do
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    try do
      Application.put_env(:symphony_elixir, :sympp_repo_database, :invalid_database_path)

      unknown_work_key_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{WorkKey.generate().secret}")

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(get(unknown_work_key_conn, "/api/v1/sympp/board"), 401)
    after
      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end
    end
  end

  test "dashboard browser sessions use the default database when endpoint sympp_repo is unset" do
    database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    try do
      {work_package_id, board_secret, package_secret} = seed_dashboard_session_database(database_path)
      Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

      with_runtime_endpoint_repo(nil, fn ->
        board_conn = post(build_conn(), "/sympp/board/session", %{"work_key" => board_secret})
        assert redirected_to(board_conn) == "/sympp/board"

        package_conn =
          post(build_conn(), "/sympp/work-packages/#{work_package_id}/session", %{"work_key" => package_secret})

        assert redirected_to(package_conn) == "/sympp/work-packages/#{work_package_id}"
      end)
    after
      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end

      File.rm(database_path)
    end
  end

  test "dashboard API authenticates an existing explicit database while local Repo uses another ledger" do
    database_path = WorkPackageFactory.database_path()

    try do
      {work_package_id, secret} = seed_dashboard_database(database_path)

      with_configured_endpoint_database(database_path, fn ->
        assert %{"work_package" => %{"id" => ^work_package_id}} =
                 json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package_id}"), 200)
      end)
    after
      File.rm(database_path)
    end
  end

  test "dashboard API honors repo-configured database while local Repo uses another ledger" do
    database_path = WorkPackageFactory.database_path()

    try do
      {work_package_id, secret} = seed_dashboard_database(database_path)

      with_repo_configured_endpoint_database(database_path, fn ->
        assert %{"work_package" => %{"id" => ^work_package_id}} =
                 json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package_id}"), 200)
      end)
    after
      File.rm(database_path)
    end
  end

  test "dashboard API accepts case-insensitive bearer auth", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret} = create_dashboard_fixture(repo)

    conn =
      build_conn()
      |> put_req_header("authorization", "bearer #{secret}")

    assert %{"work_package" => %{"id" => fetched_id}} =
             json_response(get(conn, "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert fetched_id == work_package.id
  end

  test "dashboard reads normalize SQLite busy errors" do
    assert {:error, :database_busy} = Dashboard.board(BusyRepo)
  end

  test "dashboard API normalizes SQLite busy errors during bearer auth" do
    secret = WorkKey.generate().secret

    with_endpoint_repo(BusyRepo, fn ->
      assert %{"error" => %{"code" => "database_busy"}} =
               json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 503)
    end)
  end

  test "dashboard API preserves SQLite busy errors during phase anchor authorization" do
    secret = WorkKey.generate().secret
    now = DateTime.utc_now(:microsecond)

    grant = %AccessGrant{
      id: "grant-locked-phase-anchor",
      work_package_id: "SYMPP-ANCHOR",
      phase_id: @dashboard_phase_id,
      display_key: "ABCD",
      secret_hash: WorkKey.secret_hash(secret),
      grant_role: "architect",
      capabilities: ["read:phase"],
      claimed_at: now,
      claimed_by: "reviewer",
      expires_at: DateTime.add(now, 3600, :second),
      inserted_at: now,
      updated_at: now
    }

    LockedPhaseAnchorRepo.put_grant(grant)
    on_exit(fn -> LockedPhaseAnchorRepo.clear_grant() end)

    with_endpoint_repo(LockedPhaseAnchorRepo, fn ->
      assert {:error, :database_busy} = SymppDashboardApiController.authorize_board_grant_id(grant.id)

      assert %{"error" => %{"code" => "database_busy"}} =
               json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 503)
    end)
  end

  test "custom dashboard repo rejects invalid bearer probes before storage bootstrap" do
    with_endpoint_repo(MissingCustomRepo, fn ->
      unknown_work_key_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{WorkKey.generate().secret}")

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(get(unknown_work_key_conn, "/api/v1/sympp/board"), 401)
    end)
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

  defp create_comment_at!(repo, offset_seconds, attrs) do
    timestamp = DateTime.add(~U[2026-05-23 12:00:00.000000Z], offset_seconds, :second)

    assert {:ok, comment} = CommentService.create(repo, attrs)
    repo.update!(Ecto.Changeset.change(comment, inserted_at: timestamp, updated_at: timestamp))
  end

  defp numbered_comment_id(prefix, index), do: "#{prefix}-#{String.pad_leading(Integer.to_string(index), 3, "0")}"

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

    assert {:ok, _review_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Review submitted #{WorkKey.generate().secret}",
               status: "review_package_submitted",
               payload: %{
                 type: "review_package",
                 source_tool: "submit_review_package",
                 artifacts: ["review-log.txt"],
                 head_sha: "abc123",
                 url: "https://example.test/review?sig=raw-secret-value",
                 urls: ["https://example.test/one?sig=raw-secret-value"],
                 note: "Bearer raw-secret-value",
                 raw_secret: "raw-secret-value",
                 secret_hash: grant.secret_hash
               },
               created_at: DateTime.add(timestamp, 6, :second)
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

  defp append_ready_delivery_evidence(repo, work_package) do
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{
                 type: "branch",
                 source_tool: "attach_branch",
                 branch: "agent/#{work_package.id}",
                 head_sha: "abc123"
               },
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/example/repo/pull/7",
                 head_sha: "abc123"
               },
               created_at: DateTime.add(timestamp, 3, :second)
             })

    assert {:ok, _pr_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/7",
                 repository: "example/repo",
                 number: 7,
                 head_sha: "abc123",
                 check_summary: %{conclusion: "success"},
                 review_state: %{state: "approved"},
                 merge_state: %{state: "clean"}
               },
               created_at: DateTime.add(timestamp, 3, :second)
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

  defp create_architect_grant_secret(repo, work_package_id) do
    phase_id = ensure_dashboard_phase(repo)
    assign_existing_packages_to_phase(repo, phase_id)
    work_key = WorkKey.generate()

    assert {:ok, grant} =
             AccessGrantRepository.create(repo, %{
               work_package_id: work_package_id,
               phase_id: phase_id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["read:phase"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
             })

    assert {:ok, _assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    assert grant.display_key == work_key.display_key
    work_key.secret
  end

  defp create_legacy_phase_grant_secret(repo, work_package_id, grant_id) do
    now = DateTime.utc_now(:microsecond)
    work_key = WorkKey.generate()

    repo.insert!(%AccessGrant{
      id: grant_id,
      work_package_id: work_package_id,
      phase_id: nil,
      display_key: work_key.display_key,
      secret_hash: WorkKey.secret_hash(work_key.secret),
      grant_role: "architect",
      capabilities: ["read:phase"],
      expires_at: DateTime.add(now, 3600, :second)
    })

    assert {:ok, assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: "architect-legacy"}, DateTime.utc_now(:microsecond))

    assert assignment.phase_id == nil
    work_key.secret
  end

  defp ensure_dashboard_phase(repo) do
    case PhaseRepository.get(repo, @dashboard_phase_id) do
      {:ok, phase} ->
        phase.id

      {:error, :not_found} ->
        assert {:ok, phase} = PhaseRepository.create(repo, %{id: @dashboard_phase_id, title: "Dashboard test phase"})
        phase.id
    end
  end

  defp assign_existing_packages_to_phase(repo, phase_id) do
    assert {:ok, packages} = WorkPackageRepository.list(repo)

    Enum.each(packages, fn package ->
      assert {:ok, _updated} = WorkPackageRepository.update(repo, package.id, %{phase_id: phase_id})
    end)
  end

  defp create_claimed_worker_grant(repo, work_package_id, claimed_by) do
    {grant, _work_key} = create_claimed_worker_key(repo, work_package_id, claimed_by)
    grant
  end

  defp create_worker_grant_secret(repo, work_package_id, claimed_by) do
    {_grant, work_key} = create_claimed_worker_key(repo, work_package_id, claimed_by)
    work_key.secret
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

  defp auth_conn(secret) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{secret}")
  end

  defp local_operator_conn do
    build_conn()
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("origin", "http://localhost")
    |> Plug.Test.init_test_session(%{})
  end

  defp local_operator_csrf_conn do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    local_operator_conn()
    |> put_req_header("x-csrf-token", csrf_token)
  end

  defp recycle_local_operator_conn(conn, origin) do
    conn
    |> recycle()
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("origin", origin)
  end

  defp dashboard_shell_config(html) do
    [_, encoded] = Regex.run(~r/window\.SYMPP_DASHBOARD_CONFIG = (\{.*\});<\/script>/, html)
    Jason.decode!(encoded)
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

  defp with_endpoint_repo(repo, fun) when is_atom(repo) and is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint_config, :sympp_repo, repo)
    )

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end
  end

  defp with_runtime_endpoint_repo(repo, fun) when is_atom(repo) and is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    original_runtime_repo = SymphonyElixirWeb.Endpoint.config(:sympp_repo)

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint_config, :sympp_repo, repo)
    )

    SymphonyElixirWeb.Endpoint.config_change([{SymphonyElixirWeb.Endpoint, [sympp_repo: repo]}], [])

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
      SymphonyElixirWeb.Endpoint.config_change([{SymphonyElixirWeb.Endpoint, [sympp_repo: original_runtime_repo]}], [])
    end
  end

  defp with_dynamic_endpoint_database(database_path, fun) when is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.delete(endpoint_config, :sympp_repo)
    )

    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)

      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end
    end
  end

  defp with_configured_endpoint_database(database_path, fun) when is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint_config, :sympp_repo, Repo)
    )

    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)

      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end
    end
  end

  defp with_repo_configured_endpoint_database(database_path, fun) when is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    original_repo_config = Application.get_env(:symphony_elixir, Repo, [])

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint_config, :sympp_repo, Repo)
    )

    Application.delete_env(:symphony_elixir, :sympp_repo_database)
    Application.put_env(:symphony_elixir, Repo, Keyword.put(original_repo_config, :database, database_path))

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
      Application.put_env(:symphony_elixir, Repo, original_repo_config)

      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end
    end
  end

  defp seed_dashboard_database(database_path) do
    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      assert :ok = WorkPackageRepository.migrate(Repo)
      %{work_package: work_package, work_key_secret: secret} = create_dashboard_fixture(Repo, id: "SYMPP-ALT-DB")
      {work_package.id, secret}
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
    end
  end

  defp seed_dashboard_session_database(database_path) do
    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      assert :ok = WorkPackageRepository.migrate(Repo)

      %{work_package: work_package, work_key_secret: package_secret} =
        create_dashboard_fixture(Repo, id: "SYMPP-DEFAULT-SESSION")

      board_secret = create_architect_grant_secret(Repo, work_package.id)

      {work_package.id, board_secret, package_secret}
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
    end
  end

  defp seed_pre_phase_dashboard_database(database_path, opts \\ []) do
    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      pre_phase_migration = 20_260_503_192_500

      migrated_versions =
        Ecto.Migrator.run(Repo, Migrations.all(), :up,
          to: pre_phase_migration,
          log: false
        )

      assert pre_phase_migration in migrated_versions

      now = DateTime.utc_now(:microsecond)
      expires_at = DateTime.add(now, 86_400, :second)
      work_key = WorkKey.generate()
      work_package_id = Keyword.get(opts, :work_package_id, "SYMPP-PRE-PHASE-AUTH")
      grant_id = Keyword.get(opts, :grant_id, "grant-pre-phase-auth")
      grant_role = Keyword.get(opts, :grant_role, "worker")
      capabilities = opts |> Keyword.get(:capabilities, ["read:package"]) |> Jason.encode!()
      claimed_by = Keyword.get(opts, :claimed_by, "worker-1")

      Repo.query!(
        """
        INSERT INTO sympp_work_packages
          (id, kind, title, repo, base_branch, branch_pattern, product_description,
           engineering_scope, acceptance_criteria, status, parent_id, owner_id,
           allowed_file_globs, policy_template, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          work_package_id,
          "mcp",
          "Pre-phase auth package",
          "Pimpmuckl/symphony-plus-plus",
          "symphony-plus-plus/beta",
          nil,
          nil,
          nil,
          "[]",
          "created",
          nil,
          nil,
          "[]",
          nil,
          now,
          now
        ]
      )

      Repo.query!(
        """
        INSERT INTO sympp_access_grants
          (id, work_package_id, display_key, secret_hash, grant_role, capabilities,
           expires_at, revoked_at, claimed_at, claimed_by, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          grant_id,
          work_package_id,
          work_key.display_key,
          WorkKey.secret_hash(work_key.secret),
          grant_role,
          capabilities,
          expires_at,
          nil,
          now,
          claimed_by,
          now,
          now
        ]
      )

      {work_package_id, work_key.secret}
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
    end
  end

  defp seed_dashboard_database_at_migration(database_path, migration_version, opts) do
    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      migrated_versions =
        Ecto.Migrator.run(Repo, Migrations.all(), :up,
          to: migration_version,
          log: false
        )

      assert migration_version in migrated_versions

      now = DateTime.utc_now(:microsecond)
      expires_at = DateTime.add(now, 86_400, :second)
      work_key = WorkKey.generate()
      work_package_id = Keyword.fetch!(opts, :work_package_id)
      grant_id = Keyword.fetch!(opts, :grant_id)
      capabilities = opts |> Keyword.get(:capabilities, ["read:package"]) |> Jason.encode!()

      insert_legacy_dashboard_row("sympp_work_packages", [
        {"id", work_package_id},
        {"kind", "mcp"},
        {"title", "Legacy auth package"},
        {"repo", "Pimpmuckl/symphony-plus-plus"},
        {"base_branch", "symphony-plus-plus/beta"},
        {"branch_pattern", nil},
        {"product_description", nil},
        {"engineering_scope", nil},
        {"acceptance_criteria", "[]"},
        {"status", "created"},
        {"parent_id", nil},
        {"owner_id", nil},
        {"allowed_file_globs", "[]"},
        {"policy_template", nil},
        {"phase_id", Keyword.get(opts, :work_package_phase_id, nil)},
        {"inserted_at", now},
        {"updated_at", now}
      ])

      insert_legacy_dashboard_row("sympp_access_grants", [
        {"id", grant_id},
        {"work_package_id", work_package_id},
        {"phase_id", Keyword.get(opts, :grant_phase_id, nil)},
        {"scope_repo", Keyword.get(opts, :scope_repo, nil)},
        {"scope_base_branch", Keyword.get(opts, :scope_base_branch, nil)},
        {"display_key", work_key.display_key},
        {"secret_hash", WorkKey.secret_hash(work_key.secret)},
        {"grant_role", Keyword.get(opts, :grant_role, "worker")},
        {"provenance", Keyword.get(opts, :provenance, nil)},
        {"capabilities", capabilities},
        {"expires_at", expires_at},
        {"revoked_at", nil},
        {"claimed_at", now},
        {"claimed_by", Keyword.get(opts, :claimed_by, "worker-1")},
        {"inserted_at", now},
        {"updated_at", now}
      ])

      {work_package_id, work_key.secret}
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
    end
  end

  defp insert_legacy_dashboard_row(table, attrs)
       when table in ["sympp_access_grants", "sympp_work_packages"] and is_list(attrs) do
    columns = table_columns_for_repo(table)
    row = Enum.filter(attrs, fn {column, _value} -> column in columns end)
    column_sql = Enum.map_join(row, ", ", &elem(&1, 0))
    placeholders = Enum.map_join(row, ", ", fn _field -> "?" end)
    values = Enum.map(row, &elem(&1, 1))

    Repo.query!("INSERT INTO #{table} (#{column_sql}) VALUES (#{placeholders})", values)
  end

  defp table_columns_for_repo(table) when table in ["sympp_access_grants", "sympp_work_packages"] do
    "PRAGMA table_info(#{table})"
    |> Repo.query!([])
    |> Map.fetch!(:rows)
    |> Enum.map(fn [_index, name | _rest] -> name end)
  end

  defp table_columns(database_path, table) when table in ["sympp_access_grants", "sympp_work_packages"] do
    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      "PRAGMA table_info(#{table})"
      |> Repo.query!([])
      |> Map.fetch!(:rows)
      |> Enum.map(fn [_index, name | _rest] -> name end)
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
    end
  end
end
