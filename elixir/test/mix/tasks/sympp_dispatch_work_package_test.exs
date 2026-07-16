defmodule Mix.Tasks.Sympp.DispatchWorkPackageTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Sympp.DispatchWorkPackage, as: DispatchTask
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.WorkPackageFactory

  setup do
    Mix.Task.reenable("sympp.dispatch_work_package")
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)
    :ok
  end

  test "prints help" do
    DispatchTask.run(["--help"])
    assert_received {:mix_shell, :info, [message]}
    assert message =~ "mix sympp.dispatch_work_package"
    refute message =~ "secret"
    refute message =~ "legacy"
  end

  test "activates one planned WorkPackage in place and prints redacted JSON" do
    database_path = WorkPackageFactory.database_path()

    try do
      %{work_request: work_request, work_package: work_package} = seed_package(database_path)

      DispatchTask.run([
        "--database",
        database_path,
        "--work-request-id",
        work_request.id,
        "--work-package-id",
        work_package.id,
        "--claimed-by",
        "worker-dispatch-work-package"
      ])

      assert_received {:mix_shell, :info, [json]}
      payload = Jason.decode!(json)
      assert payload["work_package"]["id"] == work_package.id
      assert payload["work_package"]["status"] == "ready_for_worker"
      assert is_binary(payload["work_package"]["dispatched_at"])

      dispatch = payload["dispatch"]
      assert dispatch["work_package"]["id"] == work_package.id
      assert dispatch["work_package"]["title"] == work_package.title
      assert dispatch["work_package"]["repo"] == work_request.repo
      assert dispatch["worker_grant"]["secret_in_response"] == false
      refute dispatch["worker_grant"]["secret"]

      bootstrap = dispatch["worker_bootstrap"]
      assert bootstrap["type"] == "ledger_claim"
      assert_same_database_path(bootstrap["ledger"]["database"], database_path)
      assert bootstrap["claim"]["tool"] == "claim_local_assignment"

      assert bootstrap["claim"]["arguments"] == %{
               "claimed_by" => "worker-dispatch-work-package",
               "work_package_id" => work_package.id
             }

      assert bootstrap["coordinates"]["primary_execution"] == %{
               "kind" => "work_package",
               "work_package_id" => work_package.id
             }

      refute json =~ "local-private-file"
      refute json =~ "run_mcp_command"
      refute json =~ ".secret"

      with_repo(database_path, fn repo ->
        persisted = repo.get!(WorkPackage, work_package.id)
        assert persisted.status == "ready_for_worker"
        assert persisted.work_request_id == work_request.id
        assert repo.aggregate(WorkPackage, :count) == 1
      end)
    after
      File.rm(database_path)
    end
  end

  test "requires dispatch identifiers before opening the ledger" do
    database_path = WorkPackageFactory.database_path()

    assert_raise Mix.Error, ~r/Usage: mix sympp.dispatch_work_package/, fn ->
      DispatchTask.run(["--database", database_path])
    end

    refute File.exists?(database_path)
  end

  test "rejects removed secret handoff flags before opening the ledger" do
    database_path = WorkPackageFactory.database_path()

    assert_raise Mix.Error, ~r/Usage: mix sympp.dispatch_work_package/, fn ->
      DispatchTask.run([
        "--database",
        database_path,
        "--work-request-id",
        "WR-1",
        "--work-package-id",
        "WP-1",
        "--secret-handoff",
        "local-private-file"
      ])
    end

    refute File.exists?(database_path)
  end

  defp seed_package(database_path) do
    with_repo(database_path, fn repo ->
      assert :ok = Repository.migrate(repo)
      assert {:ok, work_request} = Repository.create(repo, work_request_attrs())

      assert {:ok, %{work_packages: [work_package]}} =
               Repository.slice_work_request(repo, work_request.id, [work_package_attrs()])

      %{work_request: %{work_request | status: "sliced"}, work_package: work_package}
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
      title: "Dispatch canonical package",
      repo: "symphony-plus-plus",
      base_branch: "main",
      work_type: "feature",
      human_description: "Activate one canonical WorkPackage.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "single_package",
      status: "ready_for_slicing"
    }
  end

  defp work_package_attrs do
    %{
      id: "WP-DISPATCH-#{System.unique_integer([:positive])}",
      title: "Add dispatch CLI",
      goal: "Activate this WorkPackage without copying it.",
      kind: "mcp",
      base_branch: "main",
      branch_pattern: "refactor/canonical-work-packages",
      allowed_file_globs: ["elixir/lib/**"],
      forbidden_file_globs: [],
      acceptance_criteria: ["Dispatch retains the WorkPackage id."],
      validation_steps: ["mix test test/mix/tasks/sympp_dispatch_work_package_test.exs"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: ["Stop on identity drift."]
    }
  end
end
