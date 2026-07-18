defmodule SymphonyElixir.SymphonyPlusPlus.DashboardFixtureDatabase do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Repository, as: ClaimLeaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Repository, as: ProductTreeRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository

  @repo_name "example/symphony-graph-fixtures"
  @base_branch "main"
  @timestamp ~U[2026-07-18 08:00:00.000000Z]
  @timestamp_tables ~w(
    sympp_work_requests
    sympp_work_packages
    sympp_product_tree_nodes
    sympp_product_tree_dependency_edges
    sympp_progress_events
    sympp_agent_runs
    sympp_claim_leases
    sympp_work_package_deliveries
  )

  @spec export!(Path.t()) :: :ok
  def export!(path) do
    path = Path.expand(path)
    File.mkdir_p!(Path.dirname(path))
    if File.exists?(path), do: File.rm!(path)

    {:ok, pid} = Repo.start_link(database: path, name: nil, pool_size: 1, log: false)
    previous_repo = Repo.put_dynamic_repo(pid)

    try do
      :ok = WorkPackageRepository.migrate(Repo)
      seed_fanout_join!(Repo)
      seed_recovery!(Repo)
      seed_dense!(Repo)
      normalize_timestamps!(Repo)
      :ok
    after
      Repo.put_dynamic_repo(previous_repo)
      GenServer.stop(pid)
    end
  end

  defp seed_fanout_join!(repo) do
    work_request = request!(repo, "WR-FIXTURE-FANOUT", "Fictional ingestion fan-out and join")
    inputs = group!(repo, work_request.id, "GROUP-FANOUT-INPUTS", "Inputs", 1)
    workers = group!(repo, work_request.id, "GROUP-FANOUT-WORKERS", "Parallel workers", 2)
    output = group!(repo, work_request.id, "GROUP-FANOUT-OUTPUT", "Output", 3)

    source = package!(repo, work_request, "WP-FANOUT-SOURCE", "Source snapshot", "merged", inputs.id, 1)

    parse =
      package!(repo, work_request, "WP-FANOUT-PARSE", "Parse records", "implementing", workers.id, 2,
        review: %{"type" => "review-suite", "args" => %{"mode" => "normal", "current" => 1, "total" => 2, "step" => "analysis"}}
      )

    index =
      package!(repo, work_request, "WP-FANOUT-INDEX", "Build index", "ready_for_merge", workers.id, 3, review: %{"type" => "human", "args" => %{"team" => "fixture-reviewers"}})

    join = package!(repo, work_request, "WP-FANOUT-JOIN", "Join parsed records and index", "ready_for_worker", output.id, 4)
    publish = package!(repo, work_request, "WP-FANOUT-PUBLISH", "Publish result", "planned", output.id, 5)

    depends_on!(repo, work_request.id, parse.id, source.id, 1)
    depends_on!(repo, work_request.id, index.id, source.id, 2)
    depends_on!(repo, work_request.id, join.id, parse.id, 3)
    depends_on!(repo, work_request.id, join.id, index.id, 4)
    depends_on!(repo, work_request.id, publish.id, join.id, 5)

    run!(repo, parse.id, "RUN-FANOUT-PARSE", "fictional-parse-worker", 10)
    run!(repo, index.id, "RUN-FANOUT-INDEX", "fictional-index-worker", 20)

    branch!(repo, parse.id, "feat/fixture-parse", "parse-head", 30)

    pr!(repo, parse.id, 101, "parse-head", %{status: "pending", completed: 2, total: 5}, false, 31)

    review_package!(repo, parse.id, "parse-head", "running", "review-fanout-parse", 32)

    branch!(repo, index.id, "feat/fixture-index", "index-head", 40)
    pr!(repo, index.id, 102, "index-head", %{conclusion: "success", completed: 4, total: 4}, false, 41)
    review_completion!(repo, index, "index-head", "fixture-approval-102", 42)

    branch!(repo, source.id, "feat/fixture-source", "source-head", 50)
    pr!(repo, source.id, 100, "source-head", %{conclusion: "success", completed: 3, total: 3}, true, 51)
  end

  defp seed_recovery!(repo) do
    work_request = request!(repo, "WR-FIXTURE-RECOVERY", "Fictional recovery, skip, and successor history")
    history = group!(repo, work_request.id, "GROUP-RECOVERY-HISTORY", "History", 1)
    retry = group!(repo, work_request.id, "GROUP-RECOVERY-RETRY", "Retry", 2)

    old = package!(repo, work_request, "WP-RECOVERY-OLD", "Original attempt", "implementing", history.id, 1)
    skipped = package!(repo, work_request, "WP-RECOVERY-SKIPPED", "Optional audit", "skipped", history.id, 2)

    successor =
      package!(repo, work_request, "WP-RECOVERY-SUCCESSOR", "Narrow successor", "blocked", retry.id, 3, review: %{"type" => "review-suite", "args" => %{"mode" => "normal"}})

    validate = package!(repo, work_request, "WP-RECOVERY-VALIDATE", "Validate recovery", "ready_for_worker", retry.id, 4)

    depends_on!(repo, work_request.id, validate.id, successor.id, 1)
    depends_on!(repo, work_request.id, validate.id, skipped.id, 2)

    {:ok, _delivery} =
      WorkRequestRepository.record_work_package_delivery(repo, work_request.id, old.id, %{
        id: "DELIVERY-RECOVERY-OLD",
        outcome: "superseded",
        idempotency_key: "fixture-recovery-successor",
        recorded_by: "fixture",
        recorded_at: at(60),
        successor_work_package_id: successor.id,
        superseded_reason: "Fictional scope was narrowed."
      })

    progress!(repo, successor.id, "PROGRESS-RECOVERY-BLOCKER", "Blocked on fictional schema", "blocked", 61, %{
      type: "blocker",
      source_tool: "report_blocker",
      blocker_id: "fixture-schema",
      active: true
    })

    run!(repo, successor.id, "RUN-RECOVERY-SUCCESSOR", "fictional-recovery-worker", 62)
    branch!(repo, successor.id, "feat/fixture-recovery", "recovery-head", 63)
    pr!(repo, successor.id, 201, "recovery-head", %{conclusion: "failure", completed: 3, total: 4}, false, 64)
    review_package!(repo, successor.id, "recovery-head", "failed", "review-recovery-failed", 65)
  end

  defp seed_dense!(repo) do
    work_request = request!(repo, "WR-FIXTURE-DENSE", "Fictional dense dependency layout")

    groups =
      for {suffix, title, position} <- [{"A", "Sources", 1}, {"B", "Transforms", 2}, {"C", "Sinks", 3}], into: %{} do
        {suffix, group!(repo, work_request.id, "GROUP-DENSE-#{suffix}", title, position)}
      end

    packages =
      for index <- 1..12, into: %{} do
        suffix =
          cond do
            index <= 4 -> "A"
            index <= 8 -> "B"
            true -> "C"
          end

        status = if index in [3, 6, 10], do: "implementing", else: "ready_for_worker"
        id = "WP-DENSE-#{String.pad_leading(to_string(index), 2, "0")}"
        {index, package!(repo, work_request, id, "Dense node #{index}", status, groups[suffix].id, index)}
      end

    dense_pairs = [
      {5, 1},
      {5, 2},
      {6, 2},
      {6, 3},
      {7, 1},
      {7, 3},
      {7, 4},
      {8, 2},
      {8, 4},
      {9, 5},
      {9, 6},
      {10, 6},
      {10, 7},
      {11, 5},
      {11, 7},
      {11, 8},
      {12, 6},
      {12, 8}
    ]

    dense_pairs
    |> Enum.with_index(1)
    |> Enum.each(fn {{dependent, prerequisite}, index} ->
      depends_on!(repo, work_request.id, packages[dependent].id, packages[prerequisite].id, index)
    end)

    run!(repo, packages[3].id, "RUN-DENSE-03", "fictional-dense-worker-03", 80)
    run!(repo, packages[6].id, "RUN-DENSE-06", "fictional-dense-worker-06", 81)
    run!(repo, packages[10].id, "RUN-DENSE-10", "fictional-dense-worker-10", 82)
  end

  defp request!(repo, id, title) do
    {:ok, work_request} =
      WorkRequestRepository.create(repo, %{
        id: id,
        title: title,
        repo: @repo_name,
        base_branch: @base_branch,
        work_type: "feature",
        human_description: "Synthetic dashboard graph fixture.",
        constraints: %{"fixture" => true},
        desired_dispatch_shape: "architect_led_feature_branch",
        status: "sliced"
      })

    work_request
  end

  defp package!(repo, work_request, id, title, status, group_id, sequence, opts \\ []) do
    {:ok, work_package} =
      CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, %{
        id: id,
        title: title,
        goal: "Exercise a fictional execution-graph state.",
        kind: "standard_pr",
        sequence: sequence,
        product_tree_node_id: group_id,
        branch_pattern: "feat/#{String.downcase(id)}",
        allowed_file_globs: ["fixture/**"],
        forbidden_file_globs: [],
        acceptance_criteria: ["Synthetic fixture state is visible."],
        validation_steps: ["fixture validation"],
        stop_conditions: [],
        review_requirement: Keyword.get(opts, :review),
        status: status,
        dispatched_at: at(sequence)
      })

    work_package
  end

  defp group!(repo, work_request_id, id, title, position) do
    {:ok, node} =
      ProductTreeRepository.create_node(repo, %{
        id: id,
        work_request_id: work_request_id,
        title: title,
        node_kind: "group",
        position: position,
        created_by: "fixture",
        created_at: at(position)
      })

    node
  end

  defp depends_on!(repo, work_request_id, dependent_id, prerequisite_id, index) do
    {:ok, _edge} =
      ProductTreeRepository.create_dependency_edge(repo, %{
        id: "EDGE-#{work_request_id}-#{String.pad_leading(to_string(index), 2, "0")}",
        work_request_id: work_request_id,
        source_kind: "work_package",
        source_id: dependent_id,
        target_kind: "work_package",
        target_id: prerequisite_id,
        kind: "depends_on",
        reason: "Synthetic dependency #{index}.",
        created_by: "fixture",
        created_at: at(100 + index)
      })
  end

  defp run!(repo, work_package_id, id, label, offset) do
    {:ok, _run} =
      AgentRunRepository.start_run(repo, %{
        id: id,
        work_package_id: work_package_id,
        actor_id: "fixture-worker",
        status: "completed",
        attempt: 1,
        worker_task_handle: label,
        started_at: at(offset),
        last_seen_at: at(offset + 1),
        finished_at: at(offset + 1)
      })

    {:ok, _claim_lease} =
      ClaimLeaseRepository.claim(
        repo,
        %{
          id: "LEASE-#{id}",
          work_package_id: work_package_id,
          claim_group_id: "GROUP-#{id}",
          actor_kind: "agent",
          actor_id: "fixture:#{label}",
          actor_display_name: label,
          stale_after_ms: 3_153_600_000_000
        },
        now: at(offset)
      )
  end

  defp branch!(repo, work_package_id, branch, head_sha, offset) do
    progress!(repo, work_package_id, "PROGRESS-#{work_package_id}-BRANCH", "Fixture branch attached", "branch_attached", offset, %{
      type: "branch",
      source_tool: "attach_branch",
      branch: branch,
      head_sha: head_sha
    })
  end

  defp pr!(repo, work_package_id, number, head_sha, checks, merged, offset) do
    progress!(repo, work_package_id, "PROGRESS-#{work_package_id}-PR-ATTACH", "Fixture PR attached", "pr_attached", offset, %{
      type: "pr",
      source_tool: "attach_pr",
      url: "https://github.com/example/sympp-fixture/pull/#{number}",
      number: number,
      repository: "example/sympp-fixture",
      head_sha: head_sha
    })

    progress!(repo, work_package_id, "PROGRESS-#{work_package_id}-PR", "Fixture PR synchronized", "pr_synced", offset, %{
      type: "pr",
      source_tool: "sync_pr",
      url: "https://github.com/example/sympp-fixture/pull/#{number}",
      number: number,
      repository: "example/sympp-fixture",
      head_sha: head_sha,
      check_summary: checks,
      merge_state: %{merged: merged}
    })
  end

  defp review_package!(repo, work_package_id, head_sha, status, evidence_id, offset) do
    progress!(repo, work_package_id, "PROGRESS-#{work_package_id}-REVIEW", "Fixture review evidence", "review_package_submitted", offset, %{
      type: "review_package",
      source_tool: "submit_review_package",
      head_sha: head_sha,
      status: status,
      evidence_id: evidence_id,
      artifacts: ["fixture-review.txt"]
    })
  end

  defp review_completion!(repo, work_package, head_sha, reference, offset) do
    progress!(
      repo,
      work_package.id,
      "PROGRESS-#{work_package.id}-REVIEW-COMPLETE",
      "Fixture review passed",
      "review_completed",
      offset,
      %{
        type: "review_completion",
        source_tool: "complete_review",
        work_package_id: work_package.id,
        head_sha: head_sha,
        review: work_package.review_requirement,
        reference: reference
      },
      "complete_review:#{work_package.id}:#{head_sha}:fixture"
    )
  end

  defp progress!(repo, work_package_id, id, summary, status, offset, payload, idempotency_key \\ nil) do
    attrs = %{
      id: id,
      work_package_id: work_package_id,
      summary: summary,
      status: status,
      payload: payload,
      created_at: at(offset)
    }

    attrs = if idempotency_key, do: Map.put(attrs, :idempotency_key, idempotency_key), else: attrs
    {:ok, _event} = PlanningRepository.append_progress_event(repo, attrs)
  end

  defp normalize_timestamps!(repo) do
    Enum.each(@timestamp_tables, fn table ->
      repo.query!("UPDATE #{table} SET inserted_at = ?, updated_at = ?", [@timestamp, @timestamp])
    end)
  end

  defp at(offset), do: DateTime.add(@timestamp, offset, :second)
end
