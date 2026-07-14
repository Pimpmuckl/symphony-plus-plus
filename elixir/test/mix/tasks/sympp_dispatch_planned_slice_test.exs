defmodule Mix.Tasks.Sympp.DispatchPlannedSliceTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Sympp.DispatchPlannedSlice, as: DispatchTask
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.WorkPackageFactory

  setup do
    Mix.Task.reenable("sympp.dispatch_planned_slice")
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
    end)

    :ok
  end

  test "prints help" do
    DispatchTask.run(["--help"])
    assert_received {:mix_shell, :info, [message]}
    assert message =~ "mix sympp.dispatch_planned_slice"
    refute message =~ "secret"
    refute message =~ "legacy"
  end

  test "dispatches an approved planned slice and prints redacted JSON" do
    database_path = WorkPackageFactory.database_path()

    try do
      %{work_request: work_request, planned_slice: planned_slice} = seed_slice(database_path, status: "approved")

      DispatchTask.run([
        "--database",
        database_path,
        "--work-request-id",
        work_request.id,
        "--planned-slice-id",
        planned_slice.id,
        "--claimed-by",
        "worker-dispatch-planned-slice"
      ])

      assert_received {:mix_shell, :info, [json]}
      payload = Jason.decode!(json)
      create_work = payload["create_work"]

      assert create_work["work_package"]["title"] == planned_slice.title
      assert create_work["work_package"]["repo"] == work_request.repo
      assert create_work["work_package"]["base_branch"] == planned_slice.target_base_branch
      assert create_work["work_package"]["branch_pattern"] == planned_slice.branch_pattern
      assert create_work["work_package"]["allowed_file_globs"] == planned_slice.owned_file_globs
      assert create_work["work_package"]["engineering_scope"] =~ planned_slice.goal
      refute create_work["worker_grant"]["secret"]
      refute create_work["worker_grant"]["display_key"]
      refute create_work["worker_grant"]["secret_handoff"]
      assert create_work["worker_grant"]["secret_in_response"] == false
      refute create_work["worker_secret_handoff"]

      bootstrap = create_work["worker_bootstrap"]
      assert bootstrap["type"] == "ledger_claim"
      assert_same_database_path(bootstrap["ledger"]["database"], database_path)
      assert bootstrap["claim"]["tool"] == "claim_local_assignment"
      assert bootstrap["claim"]["arguments"]["claimed_by"] == "worker-dispatch-planned-slice"
      assert bootstrap["claim"]["arguments"]["work_package_id"] == create_work["work_package"]["id"]
      refute Map.has_key?(bootstrap["claim"]["arguments"], "caller_id")
      refute Map.has_key?(bootstrap["claim"]["arguments"], "work_request_id")
      refute Map.has_key?(bootstrap["claim"]["arguments"], "branch")
      assert bootstrap["claim"]["required_runtime_arguments"] == []

      assert bootstrap["preferred_skill_set"] == [
               "symphony-plus-plus-mcp:symphony-worker",
               "symphony-plus-plus-mcp:symphony-work-package"
             ]

      assert bootstrap["required_skills"] == bootstrap["preferred_skill_set"]

      assert [
               ["symphony-plus-plus-mcp:symphony-worker", "symphony-plus-plus-mcp:symphony-work-package"],
               ["symphony-plus-plus:symphony-worker", "symphony-work-package"]
             ] = bootstrap["supported_skill_sets"]

      refute json =~ "local-private-file"
      refute json =~ "run_mcp_command"
      refute json =~ ".secret"

      linkage = payload["planned_slice_linkage"]
      assert linkage["work_request_id"] == work_request.id
      assert linkage["planned_slice_id"] == planned_slice.id
      assert linkage["status"] == "dispatched"
      assert linkage["work_package_id"] == create_work["work_package"]["id"]
      assert is_binary(linkage["dispatched_at"])

      with_repo(database_path, fn repo ->
        persisted_slice = repo.get!(PlannedSlice, planned_slice.id)
        assert persisted_slice.status == "dispatched"
        assert persisted_slice.work_package_id == create_work["work_package"]["id"]

        persisted_package = repo.get!(WorkPackage, create_work["work_package"]["id"])
        assert persisted_package.status == "ready_for_worker"
      end)
    after
      File.rm(database_path)
    end
  end

  test "requires dispatch identifiers before opening the ledger" do
    database_path = WorkPackageFactory.database_path()

    assert_raise Mix.Error, ~r/Usage: mix sympp.dispatch_planned_slice/, fn ->
      DispatchTask.run(["--database", database_path])
    end

    refute File.exists?(database_path)
  end

  test "fails on blank explicit options before opening the ledger" do
    database_path = WorkPackageFactory.database_path()

    assert_raise Mix.Error, ~r/Usage: mix sympp.dispatch_planned_slice/, fn ->
      DispatchTask.run([
        "--database",
        database_path,
        "--work-request-id",
        "WR-1",
        "--planned-slice-id",
        " ",
        "--claimed-by",
        "worker"
      ])
    end

    refute File.exists?(database_path)
  end

  test "rejects removed secret handoff flags before opening the ledger" do
    database_path = WorkPackageFactory.database_path()

    assert_raise Mix.Error, ~r/Usage: mix sympp.dispatch_planned_slice/, fn ->
      DispatchTask.run([
        "--database",
        database_path,
        "--work-request-id",
        "WR-1",
        "--planned-slice-id",
        "WRS-1",
        "--claimed-by",
        "worker",
        "--secret-handoff",
        "local-private-file"
      ])
    end

    refute File.exists?(database_path)
  end

  defp seed_slice(database_path, opts) do
    with_repo(database_path, fn repo ->
      assert :ok = Repository.migrate(repo)
      assert {:ok, work_request} = Repository.create(repo, work_request_attrs())

      assert {:ok, planned_slice} =
               Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs())

      case Keyword.fetch!(opts, :status) do
        "approved" ->
          assert {:ok, approved} = Repository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")
          %{work_request: work_request, planned_slice: approved}
      end
    end)
  end

  defp assert_same_database_path(actual_path, expected_path) do
    assert is_binary(actual_path)
    assert Repo.same_database_path?(actual_path, expected_path)
  end

  defp with_repo(database_path, fun) do
    original_repo = Repo.get_dynamic_repo()

    {:ok, pid} =
      Repo.start_link(database: database_path, name: Repo.process_name(database_path), pool_size: 1, log: false)

    Repo.put_dynamic_repo(pid)

    try do
      fun.(Repo)
    after
      GenServer.stop(pid)
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp work_request_attrs do
    %{
      id: "WR-DISPATCH-#{System.unique_integer([:positive])}",
      title: "Dispatch approved slice",
      repo: "symphony-plus-plus",
      base_branch: "main",
      work_type: "feature",
      human_description: "Turn one approved slice into a WorkPackage.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "single_package",
      status: "ready_for_slicing"
    }
  end

  defp planned_slice_attrs do
    %{
      id: "WRS-DISPATCH-#{System.unique_integer([:positive])}",
      title: "Add dispatch CLI",
      goal: "Create one WorkPackage from this approved planned slice.",
      work_package_kind: "mcp",
      target_base_branch: "main",
      branch_pattern: "agent/SYMPP-V2-WR-012/planned-slice-dispatch-cli",
      owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/*.ex"],
      forbidden_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/**"],
      acceptance_criteria: ["Dispatch creates and links the WorkPackage."],
      validation_steps: ["mix test test/mix/tasks/sympp_dispatch_planned_slice_test.exs"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: ["Stop before dashboard buttons."]
    }
  end
end
