defmodule SymphonyElixir.SymphonyPlusPlus.DashboardFixtureDatabase do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Repository, as: ClaimLeaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Repository, as: ProductTreeRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDispatch
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
    sympp_access_grants
    sympp_access_grant_scopes
    sympp_plan_nodes
  )

  @spec export!(Path.t()) :: :ok
  def export!(path) do
    path = Path.expand(path)
    File.mkdir_p!(Path.dirname(path))

    Enum.each([path, path <> "-wal", path <> "-shm"], fn stale_path ->
      if File.exists?(stale_path), do: File.rm!(stale_path)
    end)

    {:ok, pid} = Repo.start_link(database: path, name: nil, pool_size: 1, log: false)
    previous_repo = Repo.put_dynamic_repo(pid)

    try do
      :ok = WorkPackageRepository.migrate(Repo)
      seed_fanout_join!(Repo)
      seed_recovery!(Repo)
      seed_dense!(Repo)
      seed_kraken_scale!(Repo)
      normalize_generated_dispatch!(Repo)
      normalize_timestamps!(Repo)
      Repo.query!("PRAGMA wal_checkpoint(TRUNCATE)")
      :ok
    after
      Repo.put_dynamic_repo(previous_repo)
      GenServer.stop(pid)
      Enum.each([path <> "-wal", path <> "-shm"], &File.rm/1)
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
        repo: "example/ingestion-workers",
        base_branch: "release",
        review: %{"type" => "review-suite", "args" => %{"mode" => "normal", "current" => 1, "total" => 2, "step" => "analysis"}}
      )

    index =
      package!(repo, work_request, "WP-FANOUT-INDEX", "Build index", "ready_for_merge", workers.id, 3,
        repo: "example/ingestion-workers",
        base_branch: "release",
        review: %{"type" => "human", "args" => %{"team" => "fixture-reviewers"}}
      )

    join =
      package!(repo, work_request, "WP-FANOUT-JOIN", "Join parsed records and index", "ready_for_worker", output.id, 4,
        repo: "example/publish-service",
        base_branch: "main"
      )

    publish = package!(repo, work_request, "WP-FANOUT-PUBLISH", "Publish result", "planned", output.id, 5)
    playtest = package!(repo, work_request, "WP-FANOUT-PLAYTEST", "Claim-ready playtest", "planned", nil, 6, dispatched_at: nil)

    depends_on!(repo, work_request.id, parse.id, source.id, 1)
    depends_on!(repo, work_request.id, index.id, source.id, 2)
    depends_on!(repo, work_request.id, join.id, parse.id, 3)
    depends_on!(repo, work_request.id, join.id, index.id, 4)
    depends_on!(repo, work_request.id, publish.id, join.id, 5)
    depends_on!(repo, work_request.id, playtest.id, source.id, 6)

    {:ok, _dispatch} = WorkPackageDispatch.dispatch(repo, work_request.id, playtest.id, [])

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
      for {suffix, title, position} <- [{"A", "Baseline", 1}, {"B", "Runtime changes", 2}, {"C", "Cutover", 3}], into: %{} do
        {suffix, group!(repo, work_request.id, "GROUP-DENSE-#{suffix}", title, position)}
      end

    titles = %{
      1 => "Snapshot installed plugin state",
      2 => "Resolve marketplace revision",
      3 => "Audit runtime leases",
      4 => "Capture startup baseline",
      5 => "Unify source resolution",
      6 => "Batch cache validation",
      7 => "Harden singleton startup",
      8 => "Optimize dashboard bootstrap",
      9 => "Publish marketplace package",
      10 => "Validate fresh Codex session",
      11 => "Run parallel agent smoke",
      12 => "Cut over local runtime"
    }

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
        {index, package!(repo, work_request, id, titles[index], status, groups[suffix].id, index)}
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

  defp seed_kraken_scale!(repo) do
    work_request =
      request!(repo, "WR-FIXTURE-KRAKEN-SCALE", "Kraken-scale storage, provenance, and migration rollout", repo: "Pimpmuckl/nextide-saas-vod-kraken")

    groups =
      [
        contract: "Contract and simulation",
        storage: "Storage and retention",
        backup: "Backup and host migration",
        first_pass: "Provenance first pass",
        playback: "Proof playback",
        rebuild: "Exact provenance rebuild",
        integrity: "Proof integrity foundations",
        concurrency: "Concurrency cutover",
        convergence: "Current-main convergence",
        restore: "Restore-verified backups"
      ]
      |> Enum.with_index(1)
      |> Map.new(fn {{key, title}, position} ->
        {key, group!(repo, work_request.id, "GROUP-KRAKEN-#{String.upcase(to_string(key))}", title, position)}
      end)

    packages =
      kraken_package_specs()
      |> Map.new(fn {sequence, group, status, title, package_repo, pr_number} ->
        id = "WP-KRAKEN-#{String.pad_leading(to_string(sequence), 2, "0")}"

        work_package =
          package!(repo, work_request, id, title, status, groups[group].id, sequence, repo: package_repo)

        if pr_number do
          head_sha = "kraken-fixture-head-#{sequence}"
          branch!(repo, work_package.id, "fixture/kraken-#{sequence}", head_sha, 200 + sequence * 2)
          pr!(repo, work_package.id, pr_number, head_sha, %{conclusion: "success", completed: 4, total: 4}, status == "merged", 201 + sequence * 2, package_repo)
        end

        {sequence, work_package}
      end)

    [
      {2, 1},
      {4, 7},
      {7, 1},
      {13, 1},
      {18, 17},
      {22, 17},
      {27, 31},
      {37, 36},
      {44, 43},
      {47, 46},
      {10, 47}
    ]
    |> Enum.with_index(1)
    |> Enum.each(fn {{dependent, prerequisite}, index} ->
      depends_on!(repo, work_request.id, packages[dependent].id, packages[prerequisite].id, 200 + index)
    end)
  end

  defp kraken_package_specs do
    kraken = "Pimpmuckl/nextide-saas-vod-kraken"
    intelligence = "Pimpmuckl/nextide-saas-vod-intelligence"
    creator_data = "Pimpmuckl/nextide-saas-creator-data"

    [
      {1, :contract, "merged", "Lock the storage, retention, backup, and cutover contract", kraken, 1112},
      {2, :storage, "skipped", "Add Kraken's durable evidence-retention lease substrate", kraken, nil},
      {3, :storage, "skipped", "Implement Kraken's fail-closed hot-to-archive lifecycle executor", kraken, nil},
      {4, :storage, "ready_for_worker", "Make OVH BHS Standard S3 cutover repeatable and verifiable", kraken, nil},
      {5, :storage, "skipped", "Renew valuable proof leases from VOD Intelligence rollups", intelligence, nil},
      {6, :storage, "skipped", "Renew proof leases from persisted report workflows", intelligence, nil},
      {7, :backup, "closed", "Back up and restore Kraken host state through Hetzner Storage Box", kraken, nil},
      {8, :backup, "merged", "Add VOD Intelligence database backup and restore evidence", intelligence, 464},
      {9, :backup, "merged", "Add Creator Data database backup and restore evidence", creator_data, 218},
      {10, :backup, "planned", "Rehearse and execute the Beauharnois host migration", kraken, nil},
      {11, :contract, "closed", "Simulate bounded proof-retention policies on production-shaped data", kraken, nil},
      {12, :contract, "merged", "Simulate bounded proof-retention policies on production-shaped data (normal review)", kraken, 1113},
      {13, :first_pass, "skipped", "Emit canonical artifact and occurrence provenance from Kraken", kraken, nil},
      {14, :first_pass, "skipped", "Build fail-closed Kraken provenance repair tooling", kraken, nil},
      {15, :first_pass, "skipped", "Repair and replay current Kraken evidence provenance", kraken, nil},
      {16, :first_pass, "skipped", "Project artifact lineage and story-ready stream context in VOD Intelligence", intelligence, nil},
      {17, :first_pass, "skipped", "Rebuild and verify VOD Intelligence evidence provenance", intelligence, nil},
      {18, :playback, "ready_for_worker", "Serve verified original-object playback descriptors from Kraken", kraken, nil},
      {19, :playback, "planned", "Resolve product proof playback in VOD Intelligence", intelligence, nil},
      {20, :playback, "planned", "Expose authorized proof playback through VOD API", "Pimpmuckl/nextide-saas-vod-api", nil},
      {21, :playback, "planned", "Seek directly to exact audio evidence in VOD Intelligence UI", "Pimpmuckl/nextide-saas-vod-intelligence-ui", nil},
      {22, :rebuild, "closed", "Persist canonical artifact-local audio proof provenance in Kraken", kraken, nil},
      {23, :rebuild, "planned", "Build fail-closed artifact provenance repair and replay tooling", kraken, nil},
      {24, :rebuild, "planned", "Repair and replay production Kraken proof provenance", kraken, nil},
      {25, :rebuild, "planned", "Project exact artifact provenance and story context in VOD Intelligence", intelligence, nil},
      {26, :rebuild, "planned", "Rebuild and verify production VOD evidence provenance", intelligence, nil},
      {27, :rebuild, "planned", "Add durable artifact proof leases in Kraken", kraken, nil},
      {28, :rebuild, "skipped", "Renew bounded profile and safety proof leases from VOD Intelligence", intelligence, nil},
      {29, :rebuild, "skipped", "Renew bounded report proof leases from persisted report workflows", intelligence, nil},
      {30, :rebuild, "planned", "Execute and verify the Ubuntu-to-OVH hot-storage cutover", kraken, nil},
      {31, :integrity, "merged", "Preserve canonical artifact lineage through Kraken analysis", kraken, 1114},
      {32, :integrity, "closed", "Persist and serve verified artifact-local proof provenance", kraken, nil},
      {33, :integrity, "merged", "Make finalized Nemo audio objects content-bound and write-once", kraken, 1116},
      {34, :integrity, "merged", "Fix Creator Data Linux test-support module paths", creator_data, 219},
      {35, :integrity, "merged", "Resolve Creator Data Rust 1.97 some_filter lint", creator_data, 220},
      {36, :integrity, "merged", "Extract and harden the canonical audio-proof verifier", kraken, 1117},
      {37, :concurrency, "closed", "Persist current-generation audio proof provenance and serve internal reads", kraken, 1118},
      {38, :concurrency, "closed", "Serialize retry generations and incident persistence consistently", kraken, nil},
      {39, :concurrency, "skipped", "Persist and read current-generation proof provenance", kraken, nil},
      {40, :concurrency, "skipped", "Bound proof callbacks and align all materialization producers", kraken, nil},
      {41, :concurrency, "merged", "Add transaction-safe per-stream write serialization", kraken, 1120},
      {42, :concurrency, "closed", "Unify retry, incident, and product settlement lock order", kraken, nil},
      {43, :concurrency, "merged", "Complete the atomic retry, incident, settlement, callback, and repair cutover", kraken, 1122},
      {44, :convergence, "closed", "Persist and read current-generation proof provenance from current main", kraken, nil},
      {45, :convergence, "merged", "Persist and read current-generation proof provenance from current main", kraken, 1124},
      {46, :convergence, "merged", "Bound proof callbacks and align materialization producers from current main", kraken, 1131},
      {47, :restore, "merged", "Capture encrypted Kraken host backups with manifests and operations", kraken, 1130},
      {48, :restore, "merged", "Prove Kraken backup restoreability in disposable targets", kraken, 1136},
      {49, :restore, "merged", "Gate Kraken schema deploys on fresh restore-verified backups", kraken, nil}
    ]
  end

  defp request!(repo, id, title, opts \\ []) do
    {:ok, work_request} =
      WorkRequestRepository.create(repo, %{
        id: id,
        title: title,
        repo: Keyword.get(opts, :repo, @repo_name),
        base_branch: Keyword.get(opts, :base_branch, @base_branch),
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
        repo: Keyword.get(opts, :repo, work_request.repo),
        base_branch: Keyword.get(opts, :base_branch, work_request.base_branch),
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
        dispatched_at: Keyword.get(opts, :dispatched_at, at(sequence))
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

  defp pr!(repo, work_package_id, number, head_sha, checks, merged, offset, repository \\ "example/sympp-fixture") do
    progress!(repo, work_package_id, "PROGRESS-#{work_package_id}-PR-ATTACH", "Fixture PR attached", "pr_attached", offset, %{
      type: "pr",
      source_tool: "attach_pr",
      url: "https://github.com/#{repository}/pull/#{number}",
      number: number,
      repository: repository,
      head_sha: head_sha
    })

    progress!(repo, work_package_id, "PROGRESS-#{work_package_id}-PR", "Fixture PR synchronized", "pr_synced", offset, %{
      type: "pr",
      source_tool: "sync_pr",
      url: "https://github.com/#{repository}/pull/#{number}",
      number: number,
      repository: repository,
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

  defp normalize_generated_dispatch!(repo) do
    {:ok, _result} =
      repo.transaction(fn ->
        repo.query!("PRAGMA defer_foreign_keys = ON")

        %{rows: [[grant_id]]} =
          repo.query!("SELECT id FROM sympp_access_grants WHERE work_package_id = ?", ["WP-FANOUT-PLAYTEST"])

        repo.query!(
          "UPDATE sympp_access_grants SET id = ?, display_key = ?, secret_hash = ?, expires_at = ? WHERE id = ?",
          [
            "GRANT-FANOUT-PLAYTEST",
            "PLAY",
            :crypto.hash(:sha256, "fictional-playtest-worker") |> Base.encode16(case: :lower),
            ~U[2099-01-01 00:00:00.000000Z],
            grant_id
          ]
        )

        repo.query!("UPDATE sympp_access_grant_scopes SET access_grant_id = ? WHERE access_grant_id = ?", [
          "GRANT-FANOUT-PLAYTEST",
          grant_id
        ])

        %{rows: scopes} =
          repo.query!("SELECT id FROM sympp_access_grant_scopes WHERE access_grant_id = ? ORDER BY scope_key", [
            "GRANT-FANOUT-PLAYTEST"
          ])

        scopes
        |> Enum.with_index()
        |> Enum.each(fn {[id], index} ->
          scope_id = "SCOPE-FANOUT-PLAYTEST-#{String.pad_leading(to_string(index), 2, "0")}"
          repo.query!("UPDATE sympp_access_grant_scopes SET id = ? WHERE id = ?", [scope_id, id])
        end)
      end)

    %{rows: plan_nodes} =
      repo.query!("SELECT id, position FROM sympp_plan_nodes WHERE work_package_id = ? ORDER BY position", [
        "WP-FANOUT-PLAYTEST"
      ])

    Enum.each(plan_nodes, fn [id, position] ->
      deterministic_id = "PLAN-FANOUT-PLAYTEST-#{String.pad_leading(to_string(position), 2, "0")}"
      repo.query!("UPDATE sympp_plan_nodes SET id = ?, created_at = ? WHERE id = ?", [deterministic_id, at(position), id])
    end)

    repo.query!("UPDATE sympp_work_packages SET dispatched_at = ? WHERE id = ?", [at(6), "WP-FANOUT-PLAYTEST"])
  end

  defp at(offset), do: DateTime.add(@timestamp, offset, :second)
end
