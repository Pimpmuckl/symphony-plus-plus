defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestWorkPackagesTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.CreateWork
  alias SymphonyElixir.SymphonyPlusPlus.Planning.{Artifact, Finding, PlanNode, ProgressEvent}
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Node
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDispatch
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  setup_all do
    database_path = database_path()
    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)
    on_exit(fn -> File.rm(database_path) end)
    {:ok, repo: Repo, database_path: database_path}
  end

  setup %{repo: repo} do
    repo.delete_all(Artifact)
    repo.delete_all(ProgressEvent)
    repo.delete_all(Finding)
    repo.delete_all(PlanNode)
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackageDelivery)
    repo.delete_all(ClarificationQuestion)
    repo.delete_all(WorkPackage)
    repo.delete_all(Node)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "slices a WorkRequest atomically into canonical WorkPackages", %{repo: repo} do
    work_request = create_work_request!(repo)
    node = create_node!(repo, work_request.id)

    assert {:ok, %{work_request: sliced, work_packages: [first, second]}} =
             Repository.slice_work_request(repo, work_request.id, [
               package_attrs(id: "wp_first", product_tree_node_id: node.id),
               package_attrs(id: "wp_second", title: "Second package")
             ])

    assert sliced.status == "sliced"
    assert first.id == "wp_first"
    assert first.work_request_id == work_request.id
    assert first.product_tree_node_id == node.id
    assert first.sequence == 1
    assert first.status == "planned"
    assert first.contract_revision == 1
    assert second.sequence == 2

    assert {:ok, [^first, ^second]} = Repository.list_work_packages(repo, work_request.id)
    assert Repo.aggregate(WorkPackage, :count) == 2
  end

  test "rolls back the full slice batch on an invalid package", %{repo: repo} do
    work_request = create_work_request!(repo)

    assert {:error, :invalid_work_package} =
             Repository.slice_work_request(repo, work_request.id, [
               package_attrs(id: "wp_valid"),
               package_attrs(id: "wp_invalid", kind: "not_a_kind")
             ])

    assert {:ok, []} = Repository.list_work_packages(repo, work_request.id)
    assert {:ok, %{status: "ready_for_slicing"}} = Repository.get(repo, work_request.id)
  end

  test "rejects phase-child packages from WorkRequest slicing", %{repo: repo} do
    work_request = create_work_request!(repo)

    assert {:error, :invalid_work_package} =
             Repository.slice_work_request(repo, work_request.id, [package_attrs(kind: "phase_child")])

    assert {:ok, []} = Repository.list_work_packages(repo, work_request.id)
    assert {:ok, %{status: "ready_for_slicing"}} = Repository.get(repo, work_request.id)
  end

  test "requires a nonempty batch and no open clarification questions", %{repo: repo} do
    work_request = create_work_request!(repo)

    assert {:error, :invalid_work_package} = Repository.slice_work_request(repo, work_request.id, [])
    assert {:ok, _question} = Repository.ask_question(repo, work_request.id, question_attrs())
    assert {:error, :open_questions} = Repository.slice_work_request(repo, work_request.id, [package_attrs()])
  end

  test "atomically advances a clarified WorkRequest while slicing", %{repo: repo} do
    work_request = create_work_request!(repo, status: "clarifying")

    assert {:error, :invalid_work_package} =
             Repository.slice_work_request(repo, work_request.id, [package_attrs(kind: "phase_child")])

    assert {:ok, %{status: "clarifying"}} = Repository.get(repo, work_request.id)

    assert {:ok, %{work_request: sliced, work_packages: [_package]}} =
             Repository.slice_work_request(repo, work_request.id, [package_attrs()])

    assert sliced.status == "sliced"
  end

  test "updates contracts with optimistic revisions and direct product-tree placement", %{repo: repo} do
    work_request = create_work_request!(repo)
    first_node = create_node!(repo, work_request.id, id: "node_first")
    second_node = create_node!(repo, work_request.id, id: "node_second")
    package = slice_one!(repo, work_request.id, package_attrs(product_tree_node_id: first_node.id))

    assert {:ok, updated} =
             Repository.update_work_package(repo, work_request.id, package.id, 1, %{
               title: "Updated contract",
               product_tree_node_id: second_node.id
             })

    assert updated.title == "Updated contract"
    assert updated.product_tree_node_id == second_node.id
    assert updated.contract_revision == 2

    assert {:error, :stale_status} =
             Repository.update_work_package(repo, work_request.id, package.id, 1, %{title: "Stale"})
  end

  test "keeps updated packages executable and inside an allowed repo scope", %{repo: repo} do
    work_request = create_work_request!(repo)
    package = slice_one!(repo, work_request.id)

    assert {:error, :invalid_work_package} =
             Repository.update_work_package(repo, work_request.id, package.id, 1, %{kind: "phase_child"})

    assert {:error, :work_package_delivery_scope_out_of_scope} =
             Repository.update_work_package(repo, work_request.id, package.id, 1, %{base_branch: "release"})
  end

  test "rejects package creation outside an allowed same-repo base branch", %{repo: repo} do
    work_request = create_work_request!(repo)

    assert {:error, :work_package_delivery_scope_out_of_scope} =
             Repository.slice_work_request(repo, work_request.id, [package_attrs(base_branch: "release")])

    assert {:ok, []} = Repository.list_work_packages(repo, work_request.id)
    assert {:ok, %{status: "ready_for_slicing"}} = Repository.get(repo, work_request.id)
  end

  test "requires an explicit base branch for a secondary delivery repo", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        repo_scopes: [%{repo: "nextide/secondary-service"}]
      )

    assert {:error, :work_package_delivery_scope_out_of_scope} =
             Repository.slice_work_request(repo, work_request.id, [
               package_attrs(repo: "nextide/secondary-service")
             ])

    assert {:ok, []} = Repository.list_work_packages(repo, work_request.id)
    assert {:ok, %{status: "ready_for_slicing"}} = Repository.get(repo, work_request.id)
  end

  test "rejects product-tree placement outside the owning WorkRequest", %{repo: repo} do
    owner = create_work_request!(repo, id: "WR-OWNER")
    other = create_work_request!(repo, id: "WR-OTHER")
    foreign_node = create_node!(repo, other.id)

    assert {:error, :not_found} =
             Repository.slice_work_request(repo, owner.id, [package_attrs(product_tree_node_id: foreign_node.id)])
  end

  test "keeps one active package in sliced requests and protects stale skips", %{repo: repo} do
    work_request = create_work_request!(repo)
    first_attrs = package_attrs(id: "wp_skip_first")
    second_attrs = package_attrs(id: "wp_skip_second")

    assert {:ok, %{work_packages: [first, second]}} =
             Repository.slice_work_request(repo, work_request.id, [first_attrs, second_attrs])

    assert {:ok, skipped} = Repository.skip_work_package(repo, work_request.id, first.id, "planned")
    assert skipped.status == "skipped"
    assert {:error, :stale_status} = Repository.skip_work_package(repo, work_request.id, first.id, "planned")
    assert {:error, :last_active_work_package} = Repository.skip_work_package(repo, work_request.id, second.id, "planned")
    assert {:ok, %{status: "planned"}} = WorkPackageRepository.get(repo, second.id)
  end

  test "does not count terminal sibling packages as active", %{repo: repo} do
    for terminal_status <- ["merged", "merged_into_phase", "closed", "abandoned"] do
      work_request = create_work_request!(repo)

      assert {:ok, %{work_packages: [terminal, planned]}} =
               Repository.slice_work_request(repo, work_request.id, [
                 package_attrs(),
                 package_attrs()
               ])

      terminal
      |> Ecto.Changeset.change(status: terminal_status)
      |> repo.update!()

      assert {:error, :last_active_work_package} =
               Repository.skip_work_package(repo, work_request.id, planned.id, "planned")
    end
  end

  test "dispatch activates the canonical package in place", %{repo: repo, database_path: database_path} do
    work_request = create_work_request!(repo)
    package = slice_one!(repo, work_request.id)

    assert {:ok, dispatch} =
             WorkPackageDispatch.dispatch(repo, work_request.id, package.id,
               claimed_by: "canonical-worker",
               database: database_path
             )

    assert dispatch.work_package.id == package.id
    assert dispatch.creation.work_package.id == package.id
    assert dispatch.work_package.status == "ready_for_worker"
    assert %DateTime{} = dispatch.work_package.dispatched_at

    assert dispatch.worker_bootstrap.coordinates.primary_execution ==
             %{kind: "work_package", work_package_id: package.id}

    assert Repo.aggregate(WorkPackage, :count) == 1
  end

  test "dispatch enforces the effective package policy before activation", %{repo: repo, database_path: database_path} do
    work_request = create_work_request!(repo)
    package = slice_one!(repo, work_request.id, package_attrs(acceptance_criteria: []))

    assert {:error, :missing_acceptance_criteria} =
             WorkPackageDispatch.dispatch(repo, work_request.id, package.id,
               claimed_by: "canonical-worker",
               database: database_path
             )

    assert {:ok, persisted} = WorkPackageRepository.get(repo, package.id)
    assert persisted.status == "planned"
    assert persisted.dispatched_at == nil
    assert Repo.aggregate(AccessGrant, :count) == 0
  end

  test "activation returns a stale-status error when the planned package changed", %{repo: repo} do
    work_request = create_work_request!(repo)
    package = slice_one!(repo, work_request.id)

    assert {:ok, skipped} = WorkPackageRepository.update_status(repo, package.id, "planned", "skipped")
    assert skipped.status == "skipped"
    assert {:error, :stale_status} = CreateWork.activate(repo, package)
  end

  test "keeps direct phase and delegated WorkPackage creation intact", %{repo: repo} do
    assert {:ok, parent} =
             WorkPackageRepository.create(repo, %{
               id: "wp_direct_parent",
               kind: "standard_pr",
               title: "Direct parent",
               repo: "nextide/example",
               base_branch: "main",
               acceptance_criteria: ["Parent remains independently executable."]
             })

    assert {:ok, child} =
             WorkPackageRepository.create(repo, %{
               id: "wp_direct_child",
               kind: "standard_pr",
               title: "Direct child",
               repo: "nextide/example",
               base_branch: "main",
               acceptance_criteria: ["Child remains independently executable."],
               parent_id: parent.id
             })

    assert parent.work_request_id == nil
    assert child.work_request_id == nil
    assert child.parent_id == parent.id
  end

  defp slice_one!(repo, work_request_id, attrs \\ package_attrs()) do
    assert {:ok, %{work_packages: [package]}} = Repository.slice_work_request(repo, work_request_id, [attrs])
    package
  end

  defp create_work_request!(repo, overrides \\ []) do
    attrs =
      Enum.into(overrides, %{
        id: "WR-#{System.unique_integer([:positive])}",
        title: "Canonical package cutover",
        repo: "nextide/example",
        base_branch: "main",
        work_type: "feature",
        human_description: "Create one canonical package identity.",
        constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
        desired_dispatch_shape: "single_package",
        status: "ready_for_slicing"
      })

    assert {:ok, work_request} = Repository.create(repo, attrs)
    work_request
  end

  defp create_node!(repo, work_request_id, overrides \\ []) do
    attrs =
      Enum.into(overrides, %{
        id: "node_#{System.unique_integer([:positive])}",
        work_request_id: work_request_id,
        title: "Product boundary",
        position: 0,
        created_by: "test"
      })

    assert {:ok, node} = ProductTree.create_node(repo, attrs)
    node
  end

  defp package_attrs(overrides \\ []) do
    Enum.into(overrides, %{
      id: "wp_#{System.unique_integer([:positive])}",
      title: "Canonical WorkPackage",
      goal: "Execute the package without a second identity.",
      kind: "mcp",
      branch_pattern: "refactor/canonical-work-packages",
      allowed_file_globs: ["elixir/lib/**"],
      forbidden_file_globs: [],
      acceptance_criteria: ["One WorkPackage id is used end to end."],
      validation_steps: ["mix test"],
      review: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: ["Stop on migration data loss."]
    })
  end

  defp question_attrs do
    %{
      category: "scope",
      question: "What is in scope?",
      why_needed: "The package boundary must be explicit."
    }
  end

  defp database_path do
    Path.join(
      System.tmp_dir!(),
      "sympp-canonical-work-packages-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3"
    )
  end
end
