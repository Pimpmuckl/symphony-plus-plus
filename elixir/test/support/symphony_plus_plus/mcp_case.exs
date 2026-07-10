Code.require_file("../mcp_harness.exs", __DIR__)
Code.require_file("mcp_common_helpers.exs", __DIR__)
Code.require_file("mcp_session_helpers.exs", __DIR__)
Code.require_file("mcp_handoff_helpers.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPCase do
  @moduledoc false

  import Ecto.Query, only: [from: 2]
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  @architect_phase_id "phase-mcp-architect-test"
  @child_worker_grant_provenance "child_worker_delegation"
  @handoff_store_process_key :sympp_mcp_test_handoff_store_dir

  @architect_phase_id "phase-mcp-architect-test"
  @child_worker_grant_provenance "child_worker_delegation"
  @handoff_store_process_key :sympp_mcp_test_handoff_store_dir
  @architect_tool_names [
    "create_child_work_package",
    "mint_child_worker_key",
    "revoke_child_worker_key",
    "list_work_requests",
    "read_work_request",
    "read_plan",
    "add_comment",
    "list_comments",
    "resolve_comment",
    "resolve_blocker",
    "read_delivery_board",
    "reconcile_work_request",
    "cleanup_work_request_planned_slice_runtime",
    "record_planned_slice_delivery",
    "revoke_planned_slice_worker_key",
    "list_guidance_requests",
    "read_guidance_request",
    "answer_guidance_request",
    "escalate_guidance_request",
    "set_work_request_status",
    "ask_question",
    "answer_question",
    "answer_question_and_record_decision",
    "close_question",
    "record_decision",
    "plan_slice",
    "upsert_plan_node",
    "move_plan_node",
    "set_plan_node_completion",
    "move_slice_to_plan_node",
    "approve_slice",
    "skip_slice",
    "finish_slicing",
    "dispatch_slice",
    "prepare_work_package_worktree",
    "cleanup_work_package_worktree",
    "read_child_status",
    "approve_scope_expansion",
    "read_phase_board",
    "approve_child_ready_state",
    "merge_child_into_phase"
  ]
  @worker_tool_names [
    "get_current_assignment",
    "read_context",
    "read_task_plan",
    "update_task_plan",
    "append_finding",
    "append_progress",
    "set_status",
    "report_blocker",
    "resolve_blocker",
    "add_comment",
    "list_comments",
    "resolve_comment",
    "create_guidance_request",
    "read_guidance_request",
    "request_scope_expansion",
    "attach_branch",
    "attach_pr",
    "sync_pr",
    "submit_review_package",
    "attach_review_suite_result",
    "mark_ready"
  ]
  @codex_forbidden_top_level_schema_keys ["oneOf", "anyOf", "allOf", "enum", "not"]

  def architect_phase_id, do: @architect_phase_id
  def child_worker_grant_provenance, do: @child_worker_grant_provenance
  def handoff_store_process_key, do: @handoff_store_process_key
  def architect_tool_names, do: @architect_tool_names
  def worker_tool_names, do: @worker_tool_names
  def codex_forbidden_top_level_schema_keys, do: @codex_forbidden_top_level_schema_keys

  defmodule FailingAuthRepo do
    def get(_schema, _id), do: raise(RuntimeError, "ledger unavailable")
  end

  defmodule UnexpectedAuthRepo do
    def get(_schema, _id), do: {:error, :ledger_down}
  end

  defmodule FailingHealthRepo do
    def query(_sql, _params, _opts), do: {:error, %RuntimeError{message: "C:/secret/path.sqlite"}}
  end

  defmodule DefaultRemoteHealthRepo do
    def config, do: [hostname: "ledger-prod.example.test", port: 15_432, database: "sympp"]
    def query("PRAGMA database_list", _params, _opts), do: {:error, :unsupported}
    def query(sql, _params, _opts) when is_binary(sql), do: {:ok, %{rows: [[1]]}}
  end

  defmodule DefaultRemoteIpv6HealthRepo do
    def config, do: [hostname: "::1", port: 15_432, database: "sympp"]
    def query("PRAGMA database_list", _params, _opts), do: {:error, :unsupported}
    def query(sql, _params, _opts) when is_binary(sql), do: {:ok, %{rows: [[1]]}}
  end

  defmodule DefaultRemoteDbnameHealthRepo do
    def config, do: [database: "dbname=sympp"]
    def query("PRAGMA database_list", _params, _opts), do: {:error, :unsupported}
    def query(sql, _params, _opts) when is_binary(sql), do: {:ok, %{rows: [[1]]}}
  end

  defmodule BusyPrSyncRepo do
    def get(AccessGrant, "grant-pr-sync-service") do
      %AccessGrant{
        id: "grant-pr-sync-service",
        work_package_id: "SYMPP-PR-SERVICE-ERROR",
        display_key: "ABCD",
        grant_role: "worker",
        capabilities: ["read:own", "write:own"],
        claimed_at: ~U[2026-05-05 00:00:00Z],
        claimed_by: "worker-1",
        expires_at: ~U[2030-01-01 00:00:00Z],
        secret_hash: "proof"
      }
    end

    def get(WorkPackage, "SYMPP-PR-SERVICE-ERROR") do
      %WorkPackage{
        id: "SYMPP-PR-SERVICE-ERROR",
        kind: "mcp",
        repo: "nextide/symphony-plus-plus",
        status: "ci_waiting"
      }
    end

    def one(_query), do: raise(%Exqlite.Error{message: "database is locked"})
    def all(_query), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  defmodule LocalClaimAuditFailureRepo do
    alias Ecto.Changeset
    alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def transaction(fun), do: Repo.transaction(fun)
    def rollback(value), do: Repo.rollback(value)
    def database_path, do: Repo.database_path()
    def get(schema, id), do: Repo.get(schema, id)
    def one(query), do: Repo.one(query)
    def all(query), do: Repo.all(query)
    def query(sql, params, opts), do: Repo.query(sql, params, opts)
    def update(changeset), do: Repo.update(changeset)
    def update_all(query, updates), do: Repo.update_all(query, truncate_claim_timestamps(updates))

    def insert(%Ecto.Changeset{data: %ProgressEvent{}, changes: %{status: "claim_lease_reclaimed"}}) do
      {:error, Changeset.add_error(Changeset.change(%ProgressEvent{}), :id, "forced_reclaim_audit_failure")}
    end

    def insert(changeset), do: Repo.insert(changeset)

    defp truncate_claim_timestamps(set: fields) do
      [
        set:
          Enum.map(fields, fn
            {field, %DateTime{} = timestamp} when field in [:claimed_at, :updated_at] ->
              {field, DateTime.truncate(timestamp, :second)}

            field ->
              field
          end)
      ]
    end

    defp truncate_claim_timestamps(updates), do: updates
  end

  defmodule LocalClaimInsertRaceRepo do
    alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    @race_key :sympp_local_claim_insert_race

    def arm(actor_overrides \\ %{}), do: Process.put(@race_key, actor_overrides)
    def disarm, do: Process.delete(@race_key)

    def transaction(fun), do: Repo.transaction(fun)
    def rollback(value), do: Repo.rollback(value)
    def database_path, do: Repo.database_path()
    def get(schema, id), do: Repo.get(schema, id)
    def one(query), do: Repo.one(query)
    def all(query), do: Repo.all(query)
    def query(sql, params, opts), do: Repo.query(sql, params, opts)
    def update(changeset), do: Repo.update(changeset)
    def update_all(query, updates), do: Repo.update_all(query, updates)

    def insert(%Ecto.Changeset{data: %ClaimLease{}} = changeset) do
      if actor_overrides = Process.get(@race_key) do
        Process.delete(@race_key)

        changeset.changes
        |> Map.take([:work_package_id, :actor_kind, :actor_id, :actor_display_name, :stale_after_ms])
        |> Map.merge(actor_overrides)
        |> ClaimLease.create_changeset(now: DateTime.utc_now(:microsecond))
        |> Repo.insert()
      end

      Repo.insert(changeset)
    end

    def insert(changeset), do: Repo.insert(changeset)
  end

  defmodule MintReadyRaceRepo do
    import Ecto.Query, only: [from: 2]

    alias SymphonyElixir.SymphonyPlusPlus.Repo
    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

    @race_key :sympp_mint_child_ready_race_id

    def arm(child_id, attrs \\ %{status: "claimed"}), do: Process.put(@race_key, {child_id, attrs})
    def disarm, do: Process.delete(@race_key)

    def transaction(fun) do
      Repo.transaction(fn ->
        case Process.get(@race_key) do
          {child_id, attrs} when is_binary(child_id) and is_map(attrs) ->
            Process.delete(@race_key)
            updates = Map.to_list(attrs) ++ [updated_at: DateTime.utc_now(:microsecond)]

            Repo.update_all(
              from(work_package in WorkPackage, where: work_package.id == ^child_id),
              set: updates
            )

          _child_id ->
            :ok
        end

        fun.()
      end)
    end

    def get(schema, id), do: Repo.get(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def all(query), do: Repo.all(query)
    def one(query), do: Repo.one(query)
    def update(changeset), do: Repo.update(changeset)
    def update_all(query, updates), do: Repo.update_all(query, updates)
    def rollback(value), do: Repo.rollback(value)
  end

  defmodule MintChildScopeRaceRepo do
    import Ecto.Query, only: [from: 2]

    alias SymphonyElixir.SymphonyPlusPlus.Repo
    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

    @race_key :sympp_mint_child_scope_race

    def arm(child_id, attrs), do: Process.put(@race_key, {child_id, attrs, 0})
    def disarm, do: Process.delete(@race_key)

    def transaction(fun), do: Repo.transaction(fun)

    def get(schema, id), do: Repo.get(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def all(query), do: Repo.all(query)
    def one(query), do: Repo.one(query)
    def update(changeset), do: Repo.update(changeset)

    def update_all(query, updates) do
      case Process.get(@race_key) do
        {child_id, attrs, 2} when is_binary(child_id) and is_map(attrs) ->
          Process.put(@race_key, {child_id, attrs, 3})
          drift_updates = Map.to_list(attrs) ++ [updated_at: DateTime.utc_now(:microsecond)]
          Repo.update_all(from(work_package in WorkPackage, where: work_package.id == ^child_id), set: drift_updates)

        {child_id, attrs, count} when is_integer(count) ->
          Process.put(@race_key, {child_id, attrs, count + 1})

        _race ->
          :ok
      end

      Repo.update_all(query, updates)
    end

    def rollback(value), do: Repo.rollback(value)
  end

  defmodule CreateChildAnchorRaceRepo do
    import Ecto.Query, only: [from: 2]

    alias SymphonyElixir.SymphonyPlusPlus.Repo
    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

    @race_key :sympp_create_child_anchor_race

    def arm(anchor_id, attrs), do: Process.put(@race_key, {anchor_id, attrs})
    def disarm, do: Process.delete(@race_key)

    def transaction(fun) do
      Repo.transaction(fn ->
        case Process.get(@race_key) do
          {anchor_id, attrs} when is_binary(anchor_id) and is_map(attrs) ->
            Process.delete(@race_key)
            updates = Map.to_list(attrs) ++ [updated_at: DateTime.utc_now(:microsecond)]
            Repo.update_all(from(work_package in WorkPackage, where: work_package.id == ^anchor_id), set: updates)

          _race ->
            :ok
        end

        fun.()
      end)
    end

    def get(schema, id), do: Repo.get(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def all(query), do: Repo.all(query)
    def one(query), do: Repo.one(query)
    def query(sql, params, opts), do: Repo.query(sql, params, opts)
    def update_all(query, updates), do: Repo.update_all(query, updates)
    def rollback(value), do: Repo.rollback(value)
  end

  defmodule MintParentGrantRaceRepo do
    import Ecto.Query, only: [from: 2]

    alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    @race_key :sympp_mint_parent_grant_race

    def arm(grant_id, attrs), do: Process.put(@race_key, {grant_id, attrs})
    def disarm, do: Process.delete(@race_key)
    def database_path, do: Repo.database_path()

    def transaction(fun) do
      Repo.transaction(fn ->
        case Process.get(@race_key) do
          {grant_id, attrs} when is_binary(grant_id) and is_map(attrs) ->
            Process.delete(@race_key)
            updates = Map.to_list(attrs) ++ [updated_at: DateTime.utc_now(:microsecond)]
            Repo.update_all(from(grant in AccessGrant, where: grant.id == ^grant_id), set: updates)

          _race ->
            :ok
        end

        fun.()
      end)
    end

    def get(schema, id), do: Repo.get(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def all(query), do: Repo.all(query)
    def one(query), do: Repo.one(query)
    def query(sql, params, opts), do: Repo.query(sql, params, opts)
    def update_all(query, updates), do: Repo.update_all(query, updates)
    def rollback(value), do: Repo.rollback(value)
  end

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: false

      import Ecto.Query, only: [from: 2]
      import ExUnit.CaptureLog
      import ExUnit.CaptureIO

      alias Ecto.Adapters.SQL
      alias Mix.Tasks.Sympp.Mcp, as: McpTask
      alias SymphonyElixir.MCPHarness
      alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
      alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
      alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.GrantScope
      alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
      alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
      alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
      alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.ArchitectContext
      alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
      alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
      alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
      alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
      alias SymphonyElixir.SymphonyPlusPlus.Comments.Service, as: CommentService
      alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
      alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine
      alias SymphonyElixir.SymphonyPlusPlus.MCP.Auth
      alias SymphonyElixir.SymphonyPlusPlus.MCP.Config
      alias SymphonyElixir.SymphonyPlusPlus.MCP.Repository, as: MCPRepository
      alias SymphonyElixir.SymphonyPlusPlus.MCP.Server
      alias SymphonyElixir.SymphonyPlusPlus.MCP.Session
      alias SymphonyElixir.SymphonyPlusPlus.MCP.Stdio
      alias SymphonyElixir.SymphonyPlusPlus.MCPCase
      alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
      alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
      alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
      alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
      alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
      alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
      alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
      alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
      alias SymphonyElixir.SymphonyPlusPlus.Repo
      alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository, as: SoloSessionRepository
      alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
      alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
      alias SymphonyElixir.SymphonyPlusPlus.TrackerAdapter
      alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
      alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
      alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
      alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
      alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
      alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
      alias SymphonyElixir.TestSupport
      alias SymphonyElixir.WorkPackageFactory

      @architect_phase_id SymphonyElixir.SymphonyPlusPlus.MCPCase.architect_phase_id()
      @child_worker_grant_provenance SymphonyElixir.SymphonyPlusPlus.MCPCase.child_worker_grant_provenance()
      @handoff_store_process_key SymphonyElixir.SymphonyPlusPlus.MCPCase.handoff_store_process_key()
      @architect_tool_names SymphonyElixir.SymphonyPlusPlus.MCPCase.architect_tool_names()
      @worker_tool_names SymphonyElixir.SymphonyPlusPlus.MCPCase.worker_tool_names()
      @codex_forbidden_top_level_schema_keys MCPCase.codex_forbidden_top_level_schema_keys()

      import SymphonyElixir.SymphonyPlusPlus.MCPCase.CommonHelpers
      import SymphonyElixir.SymphonyPlusPlus.MCPCase.SessionHelpers
      import SymphonyElixir.SymphonyPlusPlus.MCPCase.HandoffHelpers

      alias SymphonyElixir.SymphonyPlusPlus.MCPCase.{
        BusyPrSyncRepo,
        CreateChildAnchorRaceRepo,
        DefaultRemoteDbnameHealthRepo,
        DefaultRemoteHealthRepo,
        DefaultRemoteIpv6HealthRepo,
        FailingAuthRepo,
        FailingHealthRepo,
        LocalClaimAuditFailureRepo,
        LocalClaimInsertRaceRepo,
        MintChildScopeRaceRepo,
        MintParentGrantRaceRepo,
        MintReadyRaceRepo,
        UnexpectedAuthRepo
      }

      setup_all do
        database_path = WorkPackageFactory.database_path()

        start_supervised!({Repo, database: database_path, pool_size: 1})
        assert :ok = WorkPackageRepository.migrate(Repo)
        assert :ok = SoloSessionRepository.migrate(Repo)

        on_exit(fn -> File.rm(database_path) end)

        {:ok, repo: Repo}
      end

      setup %{repo: repo} do
        reset_handle_state_store()
        handoff_store_dir = unique_test_handoff_store_dir()
        Process.put(@handoff_store_process_key, handoff_store_dir)
        File.rm_rf(handoff_store_dir)
        repo.delete_all(Artifact)
        repo.delete_all(ProgressEvent)
        repo.delete_all(Finding)
        repo.delete_all(PlanNode)
        repo.delete_all(SoloSessionEntry)
        repo.delete_all(SoloSession)
        repo.delete_all(Comment)
        repo.delete_all(ClaimLease)
        repo.delete_all(GrantScope)
        repo.delete_all(GuidanceRequest)
        repo.delete_all(AccessGrant)
        repo.delete_all(WorkRequest)
        repo.delete_all(WorkPackage)
        repo.delete_all(Phase)

        on_exit(fn -> File.rm_rf(handoff_store_dir) end)

        :ok
      end
    end
  end
end
