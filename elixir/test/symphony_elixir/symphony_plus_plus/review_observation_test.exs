defmodule SymphonyElixir.SymphonyPlusPlus.ReviewObservationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.ReviewObservation
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard.Signals

  test "discovers the enabled plugin, projects status, and caches both commands", %{test: test} do
    %{worktree: worktree, plugin: plugin, package: package} = fixture(test)
    {:ok, calls} = Agent.start_link(fn -> [] end)

    runner = fn executable, args, timeout, max_bytes ->
      Agent.update(calls, &[{executable, args, timeout, max_bytes} | &1])

      case args do
        ["plugin", "list", "--json"] ->
          {:ok, plugin_json(plugin)}

        [_script, "--status", "--json", "--cd", ^worktree] ->
          {:ok,
           Jason.encode!(%{
             "review" => "rvw_observed",
             "status" => "reviewing",
             "progress" => "review 2/4 correctness",
             "next_action" => "continue",
             "reviewed_head" => "abc123"
           })}
      end
    end

    opts = test_opts(runner)

    assert %{
             package.id => %{
               evidence_id: "rvw_observed",
               status: "in_progress",
               current: 2,
               total: 4,
               step: "correctness",
               reviewed_head: "abc123"
             }
           } == ReviewObservation.observe([package], opts)

    assert ReviewObservation.observe([package], opts) != %{}
    assert length(Agent.get(calls, & &1)) == 2
  end

  test "only live review-suite packages with existing worktrees are observed", %{test: test} do
    %{package: package} = fixture(test)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    runner = fn _, _, _, _ ->
      Agent.update(calls, &(&1 + 1))
      :error
    end

    opts = test_opts(runner)

    human = %{package | id: "human", review_requirement: %{"type" => "human"}}
    terminal = %{package | id: "terminal", status: "merged"}
    skipped = %{package | id: "skipped", status: "skipped"}
    stale = %{package | id: "stale", worktree_path: Path.join(package.worktree_path, "missing")}

    assert ReviewObservation.observe([human, terminal, skipped, stale], opts) == %{}
    assert Agent.get(calls, & &1) == 0
  end

  test "missing, ambiguous, invalid, and failed providers degrade to no observation", %{test: test} do
    %{plugin: plugin, package: package} = fixture(test)

    for plugin_payload <- [
          %{"installed" => []},
          %{"installed" => [installed_plugin(plugin), installed_plugin(plugin)]},
          "not-json"
        ] do
      runner = fn _, args, _, _ ->
        case args do
          ["plugin", "list", "--json"] ->
            {:ok, if(is_binary(plugin_payload), do: plugin_payload, else: Jason.encode!(plugin_payload))}
        end
      end

      assert ReviewObservation.observe([package], test_opts(runner)) == %{}
    end

    runner = fn _, args, _, _ ->
      case args do
        ["plugin", "list", "--json"] -> {:ok, plugin_json(plugin)}
        [_script, "--status", "--json", "--cd", _worktree] -> :error
      end
    end

    assert ReviewObservation.observe([package], test_opts(runner)) == %{}
  end

  test "delivery signal overlays live progress but completed evidence stays authoritative", %{test: test} do
    %{package: package} = fixture(test)

    observation = %{
      evidence_id: "rvw_live",
      status: "in_progress",
      current: 1,
      total: 3,
      reviewed_head: "live-head"
    }

    assert %{
             type: "review-suite",
             args: %{"mode" => "fast"},
             status: "in_progress",
             current: 1,
             total: 3,
             evidence_id: "rvw_live",
             reviewed_head: "live-head"
           } == Signals.review(package, %{}, observation)

    completion = %{
      "status" => "passed",
      "reference" => "rvw_complete",
      "head_sha" => "complete-head"
    }

    signal = Signals.review(package, %{"review_completion" => completion}, observation)
    assert signal.status == "passed"
    assert signal.evidence_id == "rvw_complete"
    assert signal.reviewed_head == "complete-head"
    refute Map.has_key?(signal, :current)
  end

  test "concurrent refreshes share one provider invocation", %{test: test} do
    %{worktree: worktree, plugin: plugin, package: package} = fixture(test)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    runner = fn _, args, _, _ ->
      Agent.update(calls, &(&1 + 1))

      case args do
        ["plugin", "list", "--json"] ->
          Process.sleep(50)
          {:ok, plugin_json(plugin)}

        [_script, "--status", "--json", "--cd", ^worktree] ->
          {:ok, Jason.encode!(%{"review" => "rvw_shared", "status" => "reviewing"})}
      end
    end

    table = :ets.new(:review_observation_test, [:set, :public])
    opts = Keyword.put(test_opts(runner), :cache_table, table)
    tasks = for _ <- 1..2, do: Task.async(fn -> ReviewObservation.observe([package], opts) end)
    results = Enum.map(tasks, &Task.await/1)

    assert Enum.any?(results, &(&1 != %{}))
    assert Agent.get(calls, & &1) == 2
  end

  test "forced refresh cleanup removes only the killed owner lock" do
    table = :ets.new(:review_observation_test, [:set, :public])
    owner = spawn(fn -> Process.sleep(:infinity) end)
    other = spawn(fn -> Process.sleep(:infinity) end)
    true = :ets.insert(table, {:refreshing, owner})

    assert ReviewObservation.release_refresh(other, table) == :ok
    assert :ets.lookup(table, :refreshing) == [{:refreshing, owner}]
    assert ReviewObservation.release_refresh(owner, table) == :ok
    assert :ets.lookup(table, :refreshing) == []

    Process.exit(owner, :kill)
    Process.exit(other, :kill)
  end

  defp fixture(test) do
    root = Path.join(System.tmp_dir!(), "sympp-review-observation-#{test}")
    worktree = Path.join(root, "worktree")
    plugin = Path.join(root, "plugin")
    File.mkdir_p!(worktree)
    File.mkdir_p!(Path.join(plugin, "scripts"))
    File.write!(Path.join([plugin, "scripts", "review.py"]), "# fixture\n")

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      worktree: Path.expand(worktree),
      plugin: plugin,
      package: %WorkPackage{
        id: "wp-observed",
        status: "reviewing",
        worktree_path: worktree,
        review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "fast"}}
      }
    }
  end

  defp test_opts(runner) do
    [
      cache_table: :ets.new(:review_observation_test, [:set, :public]),
      runner: runner,
      find_executable: fn name -> name end,
      now_ms: 10_000
    ]
  end

  defp plugin_json(plugin), do: Jason.encode!(%{"installed" => [installed_plugin(plugin)]})

  defp installed_plugin(plugin) do
    %{
      "pluginId" => "review-suite@review-suite",
      "enabled" => true,
      "source" => %{"path" => plugin}
    }
  end
end
