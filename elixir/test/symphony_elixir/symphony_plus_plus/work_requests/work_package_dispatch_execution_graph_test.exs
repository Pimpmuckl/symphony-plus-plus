defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkPackageDispatchExecutionGraphTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.DependencyEdge
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{WorkPackage, WorkPackageDispatch}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{Repository, WorkRequest}
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()
    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)
    on_exit(fn -> File.rm(database_path) end)
    {:ok, repo: Repo, database_path: database_path}
  end

  setup %{repo: repo} do
    repo.delete_all(AccessGrant)
    repo.delete_all(DependencyEdge)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "dispatch uses evaluator evidence and terminal skip semantics", %{repo: repo, database_path: database_path} do
    work_request = work_request!(repo)

    assert {:ok, %{work_packages: [prerequisite, dependent]}} =
             Repository.slice_work_request(repo, work_request.id, [package("wp_prerequisite"), package("wp_dependent")])

    assert {:ok, _dependency} =
             ProductTree.create_dependency_edge(repo, %{
               id: "dep_dispatch",
               work_request_id: work_request.id,
               source_kind: "work_package",
               source_id: dependent.id,
               target_kind: "work_package",
               target_id: prerequisite.id,
               kind: "depends_on",
               reason: "The prerequisite owns the shared contract."
             })

    assert {:error, {:unmet_work_package_dependencies, "wp_dependent", ["wp_prerequisite"]}} =
             WorkPackageDispatch.dispatch(repo, work_request.id, dependent.id, database: database_path)

    assert repo.get!(WorkPackage, dependent.id).status == "planned"
    assert {:ok, %{status: "skipped"}} = Repository.skip_work_package(repo, work_request.id, prerequisite.id, "planned")
    assert :ok = DashboardPubSub.subscribe()

    assert {:ok, %{work_package: %{id: "wp_dependent", status: "ready_for_worker"}}} =
             WorkPackageDispatch.dispatch(repo, work_request.id, dependent.id, database: database_path)

    assert_receive :operator_dashboard_changed
    refute_receive :operator_dashboard_changed, 50
  end

  defp work_request!(repo) do
    assert {:ok, work_request} =
             Repository.create(repo, %{
               id: "WR-GRAPH-DISPATCH",
               title: "Graph dispatch",
               repo: "nextide/example",
               base_branch: "main",
               work_type: "feature",
               human_description: "Dispatch through the effective graph.",
               constraints: %{},
               desired_dispatch_shape: "single_package",
               status: "ready_for_slicing"
             })

    work_request
  end

  defp package(id) do
    %{
      id: id,
      title: id,
      goal: "Deliver #{id}.",
      kind: "mcp",
      branch_pattern: "feat/#{id}",
      allowed_file_globs: ["elixir/lib/**"],
      acceptance_criteria: ["#{id} is delivered."],
      validation_steps: ["mix test"],
      stop_conditions: ["Stop on scope mismatch."]
    }
  end
end
