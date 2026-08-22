defmodule Mix.Tasks.Sympp.DemoLedgerTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  @demo_repo "nextide/demo-operator"

  alias Ecto.Adapters.SQL
  alias Mix.Tasks.Sympp.DemoLedger, as: DemoLedgerTask
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.DependencyEdge
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository, as: SoloSessionsRepository
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  setup do
    Mix.Task.reenable("sympp.demo_ledger")
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
    end)

    :ok
  end

  test "prints help" do
    DemoLedgerTask.run(["--help"])

    assert_received {:mix_shell, :info, [message]}
    assert message =~ "mix sympp.demo_ledger --database <sqlite-path>"
    assert message =~ "--force"
  end

  test "Mix discovers and runs the task by documented CLI name" do
    database_path = WorkPackageFactory.database_path()

    try do
      assert Mix.Task.get("sympp.demo_ledger") == DemoLedgerTask

      Mix.Task.run("sympp.demo_ledger", ["--database", database_path])

      assert_received {:mix_shell, :info, [json]}
      assert %{"database" => database} = Jason.decode!(json)
      assert database == Path.expand(database_path)
    after
      File.rm(database_path)
    end
  end

  test "requires an explicit durable database path before creating a database" do
    database_path = WorkPackageFactory.database_path()

    assert_raise Mix.Error, ~r/Usage: mix sympp.demo_ledger/, fn ->
      DemoLedgerTask.run([])
    end

    refute File.exists?(database_path)

    assert_raise Mix.Error, ~r/durable local SQLite filesystem path/, fn ->
      DemoLedgerTask.run(["--database", ":memory:"])
    end
  end

  test "rejects unknown scenarios" do
    database_path = WorkPackageFactory.database_path()

    assert_raise Mix.Error, ~r/Scenarios: simple, multi-repo, superseded, large/, fn ->
      DemoLedgerTask.run(["--database", database_path, "--scenario", "unknown"])
    end

    refute File.exists?(database_path)
  end

  test "creates deterministic synthetic cockpit data and prints operator JSON" do
    database_path = WorkPackageFactory.database_path()

    try do
      DemoLedgerTask.run(["--database", database_path])

      assert_received {:mix_shell, :info, [json]}
      payload = Jason.decode!(json)

      assert payload["database"] == Path.expand(database_path)
      assert payload["cockpit_hint"] == "mix sympp.cockpit --database '#{Path.expand(database_path)}'"
      assert payload["cockpit_path"] == "/sympp/board"

      assert payload["seed"]["work_requests"] == [
               "SYMPP-DEMO-WR-CLARIFY",
               "SYMPP-DEMO-WR-HUMAN",
               "SYMPP-DEMO-WR-SLICING",
               "SYMPP-DEMO-WR-SLICED",
               "SYMPP-DEMO-WR-LIFECYCLE"
             ]

      with_repo(database_path, fn repo ->
        assert_statuses(repo, WorkRequest, %{
          "SYMPP-DEMO-WR-CLARIFY" => "clarifying",
          "SYMPP-DEMO-WR-HUMAN" => "human_info_needed",
          "SYMPP-DEMO-WR-SLICING" => "ready_for_slicing",
          "SYMPP-DEMO-WR-SLICED" => "sliced",
          "SYMPP-DEMO-WR-LIFECYCLE" => "sliced"
        })

        assert_statuses(repo, WorkPackage, %{
          "SYMPP-DEMO-WP-PLANNED" => "planned",
          "SYMPP-DEMO-WP-SKIPPED" => "skipped",
          "SYMPP-DEMO-WP-ACTIVE" => "implementing",
          "SYMPP-DEMO-WP-QUEUED" => "ready_for_worker",
          "SYMPP-DEMO-WP-PLANNING" => "planning",
          "SYMPP-DEMO-WP-REVIEW" => "reviewing",
          "SYMPP-DEMO-WP-CI" => "ci_waiting",
          "SYMPP-DEMO-WP-READY" => "ready_for_merge",
          "SYMPP-DEMO-WP-BLOCKED" => "blocked",
          "SYMPP-DEMO-WP-MERGED" => "merged",
          "SYMPP-DEMO-WP-MERGED-DOCS" => "merged",
          "SYMPP-DEMO-WP-CLOSED-SPIKE" => "closed"
        })

        assert payload["seed"]["comments"] == [
                 "SYMPP-DEMO-COMMENT-WR-SLICED",
                 "SYMPP-DEMO-COMMENT-WP-ACTIVE"
               ]

        assert_statuses(repo, Comment, %{
          "SYMPP-DEMO-COMMENT-WR-SLICED" => "open",
          "SYMPP-DEMO-COMMENT-WP-ACTIVE" => "open"
        })

        question = repo.get!(ClarificationQuestion, "SYMPP-DEMO-WRQ-STRUCTURED")
        assert question.decision_prompt["tl_dr"] == "Choose who owns the first cockpit guidance slice."

        guidance = repo.get!(GuidanceRequest, "SYMPP-DEMO-GUIDANCE-HUMAN")
        assert guidance.status == "human_info_needed"
        assert guidance.decision_prompt["tl_dr"] == "Pick the operator triage grouping."

        active_package = repo.get!(WorkPackage, "SYMPP-DEMO-WP-ACTIVE")
        assert active_package.work_request_id == "SYMPP-DEMO-WR-SLICED"
        assert active_package.dispatched_at

        assert {:ok, board} = Dashboard.board(repo)
        cards = board.groups |> Map.values() |> List.flatten()
        blocked = Enum.find(cards, &(&1.id == "SYMPP-DEMO-WP-BLOCKED"))
        assert blocked.active_blocker_count == 1

        ci = Enum.find(cards, &(&1.id == "SYMPP-DEMO-WP-CI"))
        assert ci.active_blocker_count == 1

        planning = Enum.find(cards, &(&1.id == "SYMPP-DEMO-WP-PLANNING"))
        assert planning.active_blocker_count == 1

        active = Enum.find(cards, &(&1.id == "SYMPP-DEMO-WP-ACTIVE"))
        assert active.open_comment_count == 1

        assert {:ok, work_request_board} = Dashboard.work_requests(repo)
        sliced_request = Enum.find(work_request_board.work_requests, &(&1.id == "SYMPP-DEMO-WR-SLICED"))
        assert sliced_request.open_comment_count == 2

        assert {:ok, sliced_detail} = Dashboard.work_request_detail(repo, "SYMPP-DEMO-WR-SLICED")
        active_package = Enum.find(sliced_detail.work_packages, &(&1.id == "SYMPP-DEMO-WP-ACTIVE"))
        assert active_package.open_comment_count == 1

        assert {:ok, operator_board} = Dashboard.operator_board(repo)

        assert Enum.any?(operator_board.active_blocking_edges, fn edge ->
                 edge.blocker_id == "demo-ci-smoke-dependency" and
                   edge.from == %{kind: "work_package", id: "SYMPP-DEMO-WP-REVIEW"} and
                   edge.to == %{kind: "work_package", id: "SYMPP-DEMO-WP-CI"}
               end)

        assert Enum.any?(operator_board.active_blocking_edges, fn edge ->
                 edge.blocker_id == "demo-slice-sequencing-dependency" and
                   edge.from == %{kind: "work_package", id: "SYMPP-DEMO-WP-QUEUED"} and
                   edge.to == %{kind: "work_package", id: "SYMPP-DEMO-WP-PLANNING"}
               end)

        ready = Enum.find(cards, &(&1.id == "SYMPP-DEMO-WP-READY"))
        assert ready.artifact_count == 1
        assert ready.finding_count == 1
        assert ready.latest_progress_at
      end)
    after
      File.rm(database_path)
    end
  end

  test "seeds Solo Sessions across lifecycle states with representative entries" do
    database_path = WorkPackageFactory.database_path()

    try do
      DemoLedgerTask.run(["--database", database_path])

      with_repo(database_path, fn repo ->
        sessions = repo.all(from(session in SoloSession, order_by: [asc: session.id]))

        assert Enum.map(sessions, &{&1.id, &1.status}) == [
                 {"SYMPP-DEMO-SOLO-ACTIVE", "active"},
                 {"SYMPP-DEMO-SOLO-ARCHIVED", "archived"},
                 {"SYMPP-DEMO-SOLO-COMPLETED", "completed"},
                 {"SYMPP-DEMO-SOLO-PAUSED", "paused"}
               ]

        entries =
          repo.all(
            from(entry in SoloSessionEntry,
              where: entry.solo_session_id == "SYMPP-DEMO-SOLO-ACTIVE",
              order_by: [asc: entry.sequence]
            )
          )

        assert Enum.map(entries, & &1.entry_kind) == [
                 "task_plan",
                 "finding",
                 "progress",
                 "decision",
                 "validation_note"
               ]

        assert Enum.all?(entries, &(&1.status in SoloSessionEntry.statuses()))

        active = Enum.find(sessions, &(&1.id == "SYMPP-DEMO-SOLO-ACTIVE"))
        assert {:ok, [^active]} = SoloSessionsRepository.list(repo, %{workspace_path: Path.join(active.workspace_path, ".")})
      end)
    after
      File.rm(database_path)
    end
  end

  test "fails when the target database exists unless force is explicit" do
    database_path = WorkPackageFactory.database_path()

    try do
      DemoLedgerTask.run(["--database", database_path])
      first_stable_rows = demo_stable_rows(database_path)

      assert_raise Mix.Error, ~r/Demo ledger already exists/, fn ->
        DemoLedgerTask.run(["--database", database_path])
      end

      DemoLedgerTask.run(["--database", database_path, "--force"])
      assert demo_stable_rows(database_path) == first_stable_rows

      with_repo(database_path, fn repo ->
        assert repo.aggregate(WorkPackage, :count) == 12
        assert repo.aggregate(WorkRequest, :count) == 5
      end)
    after
      File.rm(database_path)
    end
  end

  test "named scenarios have deterministic shapes and replace safely" do
    expected = %{
      "simple" => %{packages: 12, edges: 0, repos: [@demo_repo], deliveries: []},
      "multi-repo" => %{
        packages: 4,
        edges: 3,
        repos: ["nextide/demo-api", "nextide/demo-contracts", "nextide/demo-web", "nextide/demo-worker"],
        repo_scopes: ["nextide/demo-api", "nextide/demo-contracts", "nextide/demo-web", "nextide/demo-worker"],
        deliveries: []
      },
      "superseded" => %{
        packages: 3,
        edges: 1,
        repos: [@demo_repo],
        deliveries: [{"SYMPP-DEMO-WP-OLD", "superseded", "SYMPP-DEMO-WP-REPLACEMENT"}]
      },
      "large" => %{packages: 30, edges: 38, repos: [@demo_repo], deliveries: []}
    }

    for {scenario, expectation} <- expected do
      database_path = WorkPackageFactory.database_path()

      try do
        DemoLedgerTask.run(["--database", database_path, "--scenario", scenario])
        assert_received {:mix_shell, :info, [json]}
        assert Jason.decode!(json)["scenario"] == scenario

        first_shape = scenario_shape(database_path, scenario)
        assert Map.take(first_shape, Map.keys(expectation)) == expectation

        DemoLedgerTask.run(["--database", database_path, "--scenario", scenario, "--force"])
        assert_received {:mix_shell, :info, [_json]}
        assert scenario_shape(database_path, scenario) == first_shape
      after
        File.rm(database_path)
      end
    end
  end

  test "does not seed obvious secret or token markers" do
    database_path = WorkPackageFactory.database_path()

    try do
      DemoLedgerTask.run(["--database", database_path])
      assert_received {:mix_shell, :info, [json]}

      refute_secret_marker(json)

      with_repo(database_path, fn _repo ->
        for table <- [
              "sympp_work_requests",
              "sympp_work_packages",
              "sympp_progress_events",
              "sympp_findings",
              "sympp_artifacts",
              "sympp_solo_sessions",
              "sympp_solo_session_entries"
            ] do
          %{rows: rows} = SQL.query!(Repo.get_dynamic_repo(), "SELECT * FROM #{table}", [])
          rows |> inspect() |> refute_secret_marker()
        end
      end)
    after
      File.rm(database_path)
    end
  end

  defp assert_statuses(repo, schema, expected) do
    statuses =
      schema
      |> repo.all()
      |> Map.new(&{&1.id, &1.status})

    assert Map.take(statuses, Map.keys(expected)) == expected
  end

  defp refute_secret_marker(text) do
    refute text =~ "ghp_"
    refute text =~ "bearer "
    refute text =~ "Bearer "
    refute text =~ "api_key"
    refute text =~ "access_token"
    refute text =~ "secret_hash"
  end

  defp demo_stable_rows(database_path) do
    with_repo(database_path, fn _repo ->
      for table <- [
            "sympp_work_requests",
            "sympp_work_request_clarification_questions",
            "sympp_work_packages",
            "sympp_solo_sessions"
          ],
          into: %{} do
        %{rows: rows} =
          SQL.query!(
            Repo.get_dynamic_repo(),
            "SELECT id, inserted_at, updated_at FROM #{table} ORDER BY id",
            []
          )

        {table, rows}
      end
      |> Map.merge(
        for table <- [
              "sympp_plan_nodes",
              "sympp_progress_events",
              "sympp_findings",
              "sympp_artifacts"
            ],
            into: %{} do
          %{rows: rows} =
            SQL.query!(
              Repo.get_dynamic_repo(),
              "SELECT id, created_at, inserted_at, updated_at FROM #{table} ORDER BY id",
              []
            )

          {table, rows}
        end
      )
      |> Map.put(
        "sympp_solo_session_entries",
        SQL.query!(
          Repo.get_dynamic_repo(),
          "SELECT id, created_at, updated_at FROM sympp_solo_session_entries ORDER BY id",
          []
        ).rows
      )
    end)
  end

  defp scenario_shape(database_path, scenario) do
    with_repo(database_path, fn repo ->
      packages =
        WorkPackage
        |> repo.all()
        |> Enum.filter(&scenario_package?(&1.id, scenario))

      %{
        packages: length(packages),
        package_states: Enum.map(packages, &{&1.id, &1.status}),
        repos: packages |> Enum.map(& &1.repo) |> Enum.uniq() |> Enum.sort(),
        repo_scopes: scenario_repo_scopes(repo, scenario),
        edges:
          repo.aggregate(
            from(edge in DependencyEdge, where: like(edge.id, "SYMPP-DEMO-EDGE-%")),
            :count
          ),
        deliveries:
          WorkPackageDelivery
          |> repo.all()
          |> Enum.map(&{&1.work_package_id, &1.outcome, &1.successor_work_package_id})
          |> Enum.sort()
      }
    end)
  end

  defp scenario_package?(id, "simple"), do: not String.contains?(id, ["-MULTI-", "-LARGE-", "-OLD", "-REPLACEMENT", "-DEFERRED-"])
  defp scenario_package?(id, "multi-repo"), do: String.contains?(id, "-MULTI-")
  defp scenario_package?(id, "superseded"), do: String.contains?(id, ["-OLD", "-REPLACEMENT", "-DEFERRED-"])
  defp scenario_package?(id, "large"), do: String.contains?(id, "-LARGE-")

  defp scenario_repo_scopes(repo, "multi-repo") do
    {:ok, scopes} = WorkRequestRepository.list_repo_scopes(repo, "SYMPP-DEMO-WR-MULTI")
    scopes |> Enum.map(& &1.repo) |> Enum.sort()
  end

  defp scenario_repo_scopes(_repo, _scenario), do: []

  defp with_repo(database_path, fun) do
    original_repo = Repo.get_dynamic_repo()

    {:ok, pid} =
      Repo.start_link(database: Path.expand(database_path), name: Repo.process_name(Path.expand(database_path)), pool_size: 1, log: false)

    Repo.put_dynamic_repo(pid)

    try do
      fun.(Repo)
    after
      GenServer.stop(pid)
      Repo.put_dynamic_repo(original_repo)
      :erlang.garbage_collect()
    end
  end
end
