defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.ApiCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
      alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
      alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
      alias SymphonyElixir.SymphonyPlusPlus.Dashboard
      alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
      alias SymphonyElixir.SymphonyPlusPlus.OperatorAudit
      alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
      alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
      alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
      alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
      alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
      alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
      alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
      alias SymphonyElixir.SymphonyPlusPlus.Repo
      alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
      alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
      alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
      alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
      alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
      alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
      alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
      alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
      alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
      alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
      alias SymphonyElixir.WorkPackageFactory

      import SymphonyElixir.SymphonyPlusPlus.Dashboard.ApiCase
    end
  end

  setup_all do
    database_path = SymphonyElixir.WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    start_supervised!({SymphonyElixir.SymphonyPlusPlus.Repo, database: database_path, pool_size: 5})
    assert :ok = SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository.migrate(SymphonyElixir.SymphonyPlusPlus.Repo)
    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

    on_exit(fn ->
      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end

      File.rm(database_path)
    end)

    {:ok, repo: SymphonyElixir.SymphonyPlusPlus.Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.OperatorAudit)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.Planning.Artifact)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.Planning.Finding)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.Comments.Comment)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.Phases.Phase)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest)
    repo.delete_all(SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings)
    :ok
  end

  def create_work_request!(repo, overrides) do
    assert {:ok, work_request} =
             SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository.create(repo, work_request_attrs(overrides))

    work_request
  end

  def create_work_package!(repo, overrides) do
    assert {:ok, work_package} =
             SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository.create(
               repo,
               SymphonyElixir.WorkPackageFactory.attrs(overrides)
             )

    work_package
  end

  def create_matching_work_package!(repo, work_request, planned_slice, overrides) do
    create_work_package!(
      repo,
      Keyword.merge(
        [
          id: planned_slice.work_package_id || "SYMPP-#{planned_slice.id}",
          kind: planned_slice.work_package_kind,
          repo: planned_slice.delivery_repo || work_request.repo,
          base_branch: planned_slice.target_base_branch || work_request.base_branch,
          branch_pattern: planned_slice.branch_pattern,
          product_description: work_request.human_description,
          allowed_file_globs: planned_slice.owned_file_globs,
          acceptance_criteria: planned_slice.acceptance_criteria,
          title: planned_slice.title
        ],
        overrides
      )
    )
  end

  def work_request_attrs(overrides) do
    %{
      id: "WR-DASH-1",
      title: "Dashboard WorkRequest",
      repo: "nextide/symphony-plus-plus",
      base_branch: "main",
      work_type: "feature",
      human_description: "Exercise dashboard payload projection.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false},
      desired_dispatch_shape: "single_package",
      status: "ready_for_slicing",
      created_by_kind: "agent",
      created_by_name: "dashboard-test",
      created_via: "test"
    }
    |> Map.merge(Enum.into(overrides, %{}))
  end

  def planned_slice_attrs(overrides) do
    %{
      title: "Dashboard slice",
      goal: "Exercise dashboard projection",
      work_package_kind: "mcp",
      target_base_branch: "main",
      owned_file_globs: ["elixir/lib/**"],
      forbidden_file_globs: ["plugins/**"],
      acceptance_criteria: ["payload remains stable"],
      validation_steps: ["mix test"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: ["payload drift"]
    }
    |> Map.merge(Enum.into(overrides, %{}))
  end

  def delivery_attrs(overrides) do
    %{
      idempotency_key: "dashboard-delivery-test",
      recorded_by: "dashboard-test"
    }
    |> Map.merge(Enum.into(overrides, %{}))
  end
end
