defmodule SymphonyElixir.SymphonyPlusPlus.PlanningTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(Artifact)
    repo.delete_all(ProgressEvent)
    repo.delete_all(Finding)
    repo.delete_all(PlanNode)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "renders empty virtual planning files for a new work package", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, rendered} = Renderer.render_all(repo, work_package.id)

    assert Enum.sort(Map.keys(rendered)) == [
             "acceptance.md",
             "context.md",
             "findings.md",
             "handoff.md",
             "progress.md",
             "review_suite.md",
             "task_plan.md"
           ]

    assert rendered["context.md"] =~ "# source: `Implement package`\n"
    assert rendered["task_plan.md"] =~ "No plan nodes recorded.\n"
    assert rendered["findings.md"] =~ "No findings recorded.\n"
    assert rendered["progress.md"] =~ "No progress events recorded.\n"
    assert rendered["acceptance.md"] =~ "- [ ] source: `Create and fetch package`\n"
  end

  test "renders plan nodes as deterministic done pending and skipped checklists", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, _node} =
             Service.append_plan_node(repo, %{
               id: "plan-first",
               work_package_id: work_package.id,
               title: "Implement schemas",
               body: "Create canonical planning tables.",
               status: "done",
               position: 2,
               created_at: ~U[2026-05-01 10:01:00Z]
             })

    assert {:ok, _node} =
             Service.append_plan_node(repo, %{
               id: "plan-second",
               work_package_id: work_package.id,
               title: "Run validation",
               status: "pending",
               position: 1,
               created_at: ~U[2026-05-01 10:02:00Z]
             })

    assert {:ok, _node} =
             Service.append_plan_node(repo, %{
               id: "plan-third",
               work_package_id: work_package.id,
               title: "Backfill markdown exports",
               status: "skipped",
               position: 3,
               created_at: ~U[2026-05-01 10:03:00Z]
             })

    assert {:ok, markdown} = Renderer.render(repo, work_package.id, "task_plan.md")

    assert markdown =~ "# Task Plan\n"
    assert markdown =~ "- [x] source: `Implement schemas`\n"

    assert markdown =~
             ["  Source material (inert text):", "  ", "  ```text", "  Create canonical planning tables.", "  ```"]
             |> Enum.join("\n")

    assert markdown =~ "- [ ] source: `Run validation` _(pending)_\n"
    assert markdown =~ "- [ ] source: `Backfill markdown exports` _(skipped)_\n"
  end

  test "renders findings in append order with canonical timestamps", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, _finding} =
             Service.append_finding(repo, %{
               id: "finding-late",
               work_package_id: work_package.id,
               title: "Later finding",
               body: "Second in append-only order.",
               severity: "warning",
               created_at: ~U[2026-05-01 10:10:00Z]
             })

    assert {:ok, _finding} =
             Service.append_finding(repo, %{
               id: "finding-early",
               work_package_id: work_package.id,
               title: "Early finding",
               body: "First in append-only order.",
               severity: "info",
               created_at: ~U[2026-05-01 10:00:00Z]
             })

    assert {:ok, markdown} = Renderer.render(repo, work_package.id, "findings.md")

    assert markdown == """
           # Findings

           ## 2026-05-01T10:10:00.000000Z - source: `Later finding`

           - Severity: `warning`

           Source material (inert text):

           ```text
           Second in append-only order.
           ```
           ## 2026-05-01T10:00:00.000000Z - source: `Early finding`

           - Severity: `info`

           Source material (inert text):

           ```text
           First in append-only order.
           ```
           """
  end

  test "renders progress timeline in append order with canonical timestamps", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, _progress} =
             Service.append_progress_event(repo, %{
               id: "progress-later",
               work_package_id: work_package.id,
               summary: "Validation complete",
               status: "done",
               created_at: ~U[2026-05-01 10:20:00Z]
             })

    assert {:ok, _progress} =
             Service.append_progress_event(repo, %{
               id: "progress-earlier",
               work_package_id: work_package.id,
               summary: "Implementation started",
               body: "Created planning namespace.",
               status: "working",
               created_at: ~U[2026-05-01 10:05:00Z]
             })

    assert {:ok, markdown} = Renderer.render(repo, work_package.id, "progress.md")

    assert markdown == """
           # Progress

           ## 2026-05-01T10:20:00.000000Z - source: `Validation complete`

           - Status: `done`

           Source material (inert text):

           ```text
           Not recorded.
           ```
           ## 2026-05-01T10:05:00.000000Z - source: `Implementation started`

           - Status: `working`

           Source material (inert text):

           ```text
           Created planning namespace.
           ```
           """
  end

  test "creates package planning state and renders every virtual file", %{repo: repo} do
    assert {:ok, work_package} =
             create_work_package(repo,
               kind: "phase_child",
               acceptance_criteria: ["Render context", "Render task plan"]
             )

    assert {:ok, _node} =
             Service.append_plan_node(repo, %{
               work_package_id: work_package.id,
               title: "Render all virtual files",
               status: "done"
             })

    assert {:ok, _finding} =
             Service.append_finding(repo, %{
               work_package_id: work_package.id,
               title: "Scope stays local",
               body: "Renderer does not wire runtime startup."
             })

    assert {:ok, _progress} =
             Service.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Renderer added",
               body: "All virtual files render from canonical rows."
             })

    assert {:ok, _artifact} =
             Service.append_artifact(repo, %{
               work_package_id: work_package.id,
               path: "implementation_docs_symphplusplus/docs/02_SYSTEM_SPEC.md",
               title: "Package spec",
               kind: "spec"
             })

    assert {:ok, rendered} = Renderer.render_all(repo, work_package.id)

    assert map_size(rendered) == 7
    assert rendered["context.md"] =~ "## Engineering Scope\n"
    assert rendered["task_plan.md"] =~ "- [x] source: `Render all virtual files`\n"
    assert rendered["findings.md"] =~ "Scope stays local"
    assert rendered["progress.md"] =~ "Renderer added"
    assert rendered["acceptance.md"] =~ "- [ ] source: `Render context`\n"
    assert rendered["review_suite.md"] =~ "architect_merge"
    assert rendered["handoff.md"] =~ "Package spec"
  end

  test "assigns omitted plan positions from append order", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, first} = Service.append_plan_node(repo, %{work_package_id: work_package.id, title: "First"})
    assert {:ok, second} = Service.append_plan_node(repo, %{work_package_id: work_package.id, title: "Second"})

    assert first.position == 1
    assert second.position == 2

    assert {:ok, markdown} = Renderer.render(repo, work_package.id, "task_plan.md")
    assert markdown =~ "- [ ] source: `First` _(pending)_\n- [ ] source: `Second` _(pending)_\n"
  end

  test "append plan node owns position assignment", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, first} =
             Service.append_plan_node(repo, %{
               work_package_id: work_package.id,
               title: "Caller position ignored",
               position: 50
             })

    assert {:ok, second} =
             Service.append_plan_node(repo, %{
               work_package_id: work_package.id,
               title: "Next append",
               position: 1
             })

    assert first.position == 1
    assert second.position == 2
  end

  test "updates plan node status through an explicit mutation API", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)
    assert {:ok, plan_node} = Service.append_plan_node(repo, %{work_package_id: work_package.id, title: "Mutable"})

    assert {:ok, updated} = Service.update_plan_node_status(repo, plan_node.id, "done")
    assert updated.status == "done"

    assert {:ok, task_plan} = Renderer.render(repo, work_package.id, "task_plan.md")
    assert task_plan =~ "- [x] source: `Mutable`"
    assert {:error, :not_found} = Service.update_plan_node_status(repo, "missing-plan-node", "done")
    assert {:error, :not_found} = Repository.update_plan_node_status(__MODULE__.StalePlanNodeRepo, "stale", "done")
  end

  test "uses append sequence as deterministic order for findings and progress", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)
    timestamp = ~U[2026-05-01 10:00:00.123456Z]

    assert {:ok, first_finding} =
             Service.append_finding(repo, %{
               work_package_id: work_package.id,
               title: "First finding",
               body: "Appended first.",
               created_at: timestamp
             })

    assert {:ok, second_finding} =
             Service.append_finding(repo, %{
               work_package_id: work_package.id,
               title: "Second finding",
               body: "Appended second.",
               created_at: timestamp
             })

    assert {:ok, first_progress} =
             Service.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "First progress",
               created_at: timestamp
             })

    assert {:ok, second_progress} =
             Service.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Second progress",
               created_at: timestamp
             })

    assert first_finding.sequence == 1
    assert second_finding.sequence == 2
    assert first_progress.sequence == 1
    assert second_progress.sequence == 2

    assert {:ok, findings} = Renderer.render(repo, work_package.id, "findings.md")
    assert {:ok, progress} = Renderer.render(repo, work_package.id, "progress.md")

    assert findings =~ "2026-05-01T10:00:00.123456Z - source: `First finding`"
    assert findings =~ "source: `First finding`\n\n- Severity: `info`"
    assert findings =~ "source: `Second finding`\n\n- Severity: `info`"
    assert progress =~ "2026-05-01T10:00:00.123456Z - source: `First progress`"
    assert progress =~ "source: `First progress`\n\n- Status: `recorded`"
    assert progress =~ "source: `Second progress`\n\n- Status: `recorded`"
  end

  test "allocates append sequence uniquely during concurrent findings", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    results =
      1..8
      |> Task.async_stream(
        fn index ->
          Service.append_finding(repo, %{
            work_package_id: work_package.id,
            title: "Finding #{index}",
            body: "Concurrent append #{index}"
          })
        end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %Finding{}}, &1))

    sequences =
      results
      |> Enum.map(fn {:ok, finding} -> finding.sequence end)
      |> Enum.sort()

    assert sequences == Enum.to_list(1..8)
  end

  test "append APIs own sequence assignment for append-only rows", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, first} =
             Service.append_finding(repo, %{
               work_package_id: work_package.id,
               title: "Caller sequence ignored",
               body: "First",
               sequence: 999
             })

    assert {:ok, second} =
             Service.append_finding(repo, %{
               work_package_id: work_package.id,
               title: "Next append",
               body: "Second",
               sequence: 1
             })

    assert first.sequence == 1
    assert second.sequence == 2
  end

  test "preserves database busy when append retries are exhausted" do
    previous_attempts = Application.get_env(:symphony_elixir, :sympp_planning_append_retry_attempts)
    Application.put_env(:symphony_elixir, :sympp_planning_append_retry_attempts, -1)

    on_exit(fn ->
      if is_nil(previous_attempts) do
        Application.delete_env(:symphony_elixir, :sympp_planning_append_retry_attempts)
      else
        Application.put_env(:symphony_elixir, :sympp_planning_append_retry_attempts, previous_attempts)
      end
    end)

    assert {:error, :database_busy} =
             Repository.append_finding(__MODULE__.BusyPlanningRepo, %{work_package_id: "SYMPP-P1-004", title: "Locked"})
  end

  test "preserves database busy when state read retries are exhausted" do
    previous_attempts = Application.get_env(:symphony_elixir, :sympp_planning_state_read_retry_attempts)
    Application.put_env(:symphony_elixir, :sympp_planning_state_read_retry_attempts, -1)

    on_exit(fn ->
      if is_nil(previous_attempts) do
        Application.delete_env(:symphony_elixir, :sympp_planning_state_read_retry_attempts)
      else
        Application.put_env(:symphony_elixir, :sympp_planning_state_read_retry_attempts, previous_attempts)
      end
    end)

    assert {:error, :database_busy} = Repository.get_state(__MODULE__.BusyPlanningRepo, "SYMPP-P1-004")
  end

  test "valid assignment checks preserve access-grant lookup storage errors" do
    now = DateTime.utc_now(:microsecond)

    assignment = %Assignment{
      grant_id: "grant-storage-failure",
      work_package_id: "SYMPP-P1-004",
      display_key: "ABCD",
      grant_role: "worker",
      capabilities: ["worker:claim"],
      claimed_at: now,
      claimed_by: "agent"
    }

    assert {:error, :database_busy} =
             Service.require_valid_assignment(__MODULE__.BusyAssignmentLookupRepo, assignment)

    assert {:error, {:storage_failed, "disk I/O failed"}} =
             Service.require_valid_assignment(__MODULE__.BrokenAssignmentLookupRepo, assignment)

    assert {:error, :assignment_mismatch} =
             Service.require_valid_assignment(__MODULE__.LiveAssignmentMismatchRepo, assignment)
  end

  test "state read retry delay is independent from append retry attempts" do
    previous_append_attempts = Application.get_env(:symphony_elixir, :sympp_planning_append_retry_attempts)
    previous_read_attempts = Application.get_env(:symphony_elixir, :sympp_planning_state_read_retry_attempts)

    Application.put_env(:symphony_elixir, :sympp_planning_append_retry_attempts, 0)
    Application.put_env(:symphony_elixir, :sympp_planning_state_read_retry_attempts, 1)

    on_exit(fn ->
      restore_retry_env(:sympp_planning_append_retry_attempts, previous_append_attempts)
      restore_retry_env(:sympp_planning_state_read_retry_attempts, previous_read_attempts)
    end)

    assert {:error, :database_busy} = Repository.get_state(__MODULE__.BusyPlanningRepo, "SYMPP-P1-004")
  end

  test "reports non-busy sqlite errors as storage failures" do
    assert {:error, {:storage_failed, message}} = Repository.get_state(__MODULE__.StorageFailureRepo, "SYMPP-P1-004")
    assert message =~ "no such table"
  end

  test "allocates append sequence uniquely during concurrent artifacts", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    results =
      1..8
      |> Task.async_stream(
        fn index ->
          Service.append_artifact(repo, %{
            work_package_id: work_package.id,
            path: "artifact-#{index}.md",
            title: "Artifact #{index}"
          })
        end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %Artifact{}}, &1))

    sequences =
      results
      |> Enum.map(fn {:ok, artifact} -> artifact.sequence end)
      |> Enum.sort()

    assert sequences == Enum.to_list(1..8)
  end

  test "labels and bounds external planning text in virtual files", %{repo: repo} do
    long_description = String.duplicate("x", 4_050)
    assert {:ok, work_package} = create_work_package(repo, product_description: long_description)

    assert {:ok, context} = Renderer.render(repo, work_package.id, "context.md")

    assert context =~ "Source material (inert text):"
    assert context =~ "```text\n" <> String.duplicate("x", 20)
    assert context =~ "[truncated]\n```"
    refute context =~ String.duplicate("x", 4_050)
  end

  test "bounds non-ascii source text without breaking UTF-8 rendering", %{repo: repo} do
    long_description = String.duplicate("é", 4_050)
    assert {:ok, work_package} = create_work_package(repo, product_description: long_description)

    assert {:ok, context} = Renderer.render(repo, work_package.id, "context.md")

    assert String.valid?(context)
    assert context =~ "[truncated]\n```"
  end

  test "escapes source-owned inline markdown", %{repo: repo} do
    assert {:ok, work_package} =
             create_work_package(repo,
               title: "# Run [setup](x) `code` | table",
               acceptance_criteria: ["- [ ] Treat this as text"]
             )

    assert {:ok, _node} =
             Service.append_plan_node(repo, %{
               work_package_id: work_package.id,
               title: "Body boundary",
               body: "# Heading\n- [ ] run `cmd`\n1. ordered"
             })

    assert {:ok, context} = Renderer.render(repo, work_package.id, "context.md")
    assert {:ok, acceptance} = Renderer.render(repo, work_package.id, "acceptance.md")
    assert {:ok, task_plan} = Renderer.render(repo, work_package.id, "task_plan.md")

    assert context =~ "# source: ``# Run [setup](x) `code` | table``"
    refute context =~ "# source: # Run [setup](x) `code` | table"
    assert acceptance =~ "- [ ] source: `- [ ] Treat this as text`"
    assert task_plan =~ "  ```text\n  # Heading\n  - [ ] run `cmd`\n  1. ordered\n  ```"
  end

  test "preserves literal edge backticks in inline source text", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo, title: "`cmd`")

    assert {:ok, context} = Renderer.render(repo, work_package.id, "context.md")

    assert context =~ "# source: `` `cmd` ``"
  end

  test "caps rendered append-only history with an omission notice", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    for index <- 1..105 do
      assert {:ok, _finding} =
               Service.append_finding(repo, %{
                 work_package_id: work_package.id,
                 title: "Finding #{index}",
                 body: "Body #{index}"
               })
    end

    assert {:ok, findings} = Renderer.render(repo, work_package.id, "findings.md")

    assert findings =~ "_5 older findings omitted from this virtual file._"
    refute findings =~ "source: `Finding 1`\n\n- Severity"
    assert findings =~ "source: `Finding 6`"
    assert findings =~ "source: `Finding 105`"

    assert {:ok, state} = Service.get_state(repo, work_package.id)
    assert length(state.findings) == 105
    assert state.findings_omitted_count == 0

    assert {:ok, rendered_from_full_state} = Renderer.render_state(state, "findings.md")
    assert rendered_from_full_state =~ "_5 older findings omitted from this virtual file._"
    refute rendered_from_full_state =~ "source: `Finding 1`\n\n- Severity"
    assert rendered_from_full_state =~ "source: `Finding 105`"
  end

  test "canonical state is not silently render-capped", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    for index <- 1..105 do
      assert {:ok, _node} =
               Service.append_plan_node(repo, %{
                 work_package_id: work_package.id,
                 title: "Plan #{index}"
               })
    end

    assert {:ok, state} = Service.get_state(repo, work_package.id)
    assert length(state.plan_nodes) == 105
    assert state.plan_nodes_omitted_count == 0
  end

  test "public list helpers normalize sqlite storage failures" do
    assert {:error, {:storage_failed, message}} = Repository.list_plan_nodes(__MODULE__.StorageListFailureRepo, "SYMPP-P1-004")
    assert message =~ "no such table"

    assert {:error, {:storage_failed, _message}} =
             Repository.list_findings(__MODULE__.StorageListFailureRepo, "SYMPP-P1-004")

    assert {:error, {:storage_failed, _message}} =
             Repository.list_progress_events(__MODULE__.StorageListFailureRepo, "SYMPP-P1-004")

    assert {:error, {:storage_failed, _message}} =
             Repository.list_artifacts(__MODULE__.StorageListFailureRepo, "SYMPP-P1-004")
  end

  test "caps aggregate rendered virtual file size", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)
    large_body = String.duplicate("x", 4_050)

    for index <- 1..105 do
      assert {:ok, _finding} =
               Service.append_finding(repo, %{
                 work_package_id: work_package.id,
                 title: "Finding #{index}",
                 body: large_body
               })
    end

    assert {:ok, findings} = Renderer.render(repo, work_package.id, "findings.md")

    assert String.length(findings) < 125_000
    assert findings =~ "[virtual file truncated]"
    assert findings =~ "[virtual file truncated]\n\n## "
    assert findings =~ "source: `Finding 105`"
    refute findings =~ "source: `Finding 6`"
    assert findings |> fenced_source_count() |> rem(2) == 0
  end

  test "caps ordered plan and acceptance lists from the head", %{repo: repo} do
    acceptance_criteria = Enum.map(1..105, &"Criterion #{&1}")
    assert {:ok, work_package} = create_work_package(repo, acceptance_criteria: acceptance_criteria)

    for index <- 1..105 do
      assert {:ok, _node} =
               Service.append_plan_node(repo, %{
                 work_package_id: work_package.id,
                 title: "Plan #{index}"
               })
    end

    assert {:ok, task_plan} = Renderer.render(repo, work_package.id, "task_plan.md")
    assert {:ok, acceptance} = Renderer.render(repo, work_package.id, "acceptance.md")

    assert task_plan =~ "_5 later plan nodes omitted from this virtual file._"
    assert task_plan =~ "source: `Plan 1`"
    assert task_plan =~ "source: `Plan 100`"
    refute task_plan =~ "source: `Plan 101`"

    assert acceptance =~ "_5 later acceptance criteria omitted from this virtual file._"
    assert acceptance =~ "source: `Criterion 1`"
    assert acceptance =~ "source: `Criterion 100`"
    refute acceptance =~ "source: `Criterion 101`"
  end

  test "renders artifacts in append order for handoff", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, first} =
             Service.append_artifact(repo, %{
               work_package_id: work_package.id,
               path: "z-last.md",
               title: "First artifact"
             })

    assert {:ok, second} =
             Service.append_artifact(repo, %{
               work_package_id: work_package.id,
               path: "a-first.md",
               title: "Second artifact"
             })

    assert first.sequence == 1
    assert second.sequence == 2

    assert {:ok, handoff} = Renderer.render(repo, work_package.id, "handoff.md")

    assert handoff =~
             "source: `z-last.md` - source: `First artifact` (`reference`)\n- source: `a-first.md` - source: `Second artifact` (`reference`)"
  end

  test "renders review suite for hotfix and phase-child policy templates", %{repo: repo} do
    assert {:ok, hotfix} = create_work_package(repo, id: "SYMPP-HOTFIX", kind: "hotfix")
    assert {:ok, phase_child} = create_work_package(repo, id: "SYMPP-PHASE", kind: "phase_child")

    assert {:ok, hotfix_markdown} = Renderer.render(repo, hotfix.id, "review_suite.md")
    assert {:ok, phase_child_markdown} = Renderer.render(repo, phase_child.id, "review_suite.md")

    assert hotfix_markdown =~ "Policy template: `hotfix`"
    assert hotfix_markdown =~ "human_merge"
    assert hotfix_markdown =~ "- Required: fast"
    assert phase_child_markdown =~ "Policy template: `phase_child`"
    assert phase_child_markdown =~ "package_acceptance"
    assert phase_child_markdown =~ "- Optional: deep"
  end

  test "renders resolved review suite profiles when state provides them", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo, id: "SYMPP-RENDER-RESOLVED-REVIEW", kind: "mcp", policy_template: "mcp")

    state = %State{work_package: work_package, review_suite_required_profiles: ["deep", "raw_secret_review_lane"]}

    assert {:ok, markdown} = Renderer.render_state(state, "review_suite.md")
    assert markdown =~ "- Required: deep, [REDACTED]"
    refute markdown =~ "- Required: normal"
    refute markdown =~ "raw_secret_review_lane"
  end

  test "rendering does not mutate canonical planning state", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)
    assert {:ok, _node} = Service.append_plan_node(repo, %{work_package_id: work_package.id, title: "Stable"})

    assert {:ok, before_state} = Service.get_state(repo, work_package.id)
    assert {:ok, _markdown} = Renderer.render_all(repo, work_package.id)
    assert {:ok, after_state} = Service.get_state(repo, work_package.id)

    assert after_state == before_state
  end

  test "generated markdown exports are not authoritative planning writes", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, _artifact} =
             Service.append_artifact(repo, %{
               work_package_id: work_package.id,
               path: "task_plan.md",
               title: "Generated markdown export",
               kind: "export",
               uri: "file:///tmp/task_plan.md"
             })

    assert {:ok, task_plan} = Renderer.render(repo, work_package.id, "task_plan.md")
    assert {:ok, handoff} = Renderer.render(repo, work_package.id, "handoff.md")

    assert task_plan =~ "No plan nodes recorded."

    assert handoff =~
             "source: `task_plan.md` - source: `Generated markdown export` (`export`) - source: `file:///tmp/task_plan.md`"
  end

  test "rejects unknown virtual files", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:error, :unknown_virtual_file} = Renderer.render(repo, work_package.id, "artifact.md")
  end

  test "normalizes duplicate planning ids", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    attrs = %{id: "finding-duplicate", work_package_id: work_package.id, title: "Duplicate", body: "First insert"}

    assert {:ok, _finding} = Service.append_finding(repo, attrs)
    assert {:error, :id_already_exists} = Service.append_finding(repo, Map.put(attrs, :body, "Second insert"))
  end

  defp create_work_package(repo, overrides \\ []) do
    attrs =
      Keyword.merge([id: "SYMPP-P1-004", kind: "mcp"], overrides)
      |> WorkPackageFactory.attrs()

    WorkPackageRepository.create(repo, attrs)
  end

  defp restore_retry_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_retry_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp fenced_source_count(markdown), do: length(Regex.scan(~r/^```(?:text)?$/m, markdown))

  defmodule BusyPlanningRepo do
    def transaction(_fun), do: {:error, :database_busy}
  end

  defmodule StorageFailureRepo do
    def transaction(_fun), do: raise(%Exqlite.Error{message: "no such table: sympp_plan_nodes"})
  end

  defmodule StorageListFailureRepo do
    def all(_query), do: raise(%Exqlite.Error{message: "no such table: sympp_plan_nodes"})
  end

  defmodule BusyAssignmentLookupRepo do
    def update_all(_query, _updates), do: {0, []}
    def get(AccessGrant, _id), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  defmodule BrokenAssignmentLookupRepo do
    def update_all(_query, _updates), do: {0, []}
    def get(AccessGrant, _id), do: raise(%Exqlite.Error{message: "disk I/O failed"})
  end

  defmodule LiveAssignmentMismatchRepo do
    def update_all(_query, _updates), do: {0, []}
    def get(AccessGrant, _id), do: %AccessGrant{expires_at: nil}
  end

  defmodule StalePlanNodeRepo do
    def get(SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode, "stale") do
      %SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode{id: "stale", status: "pending"}
    end

    def update(changeset) do
      raise Ecto.StaleEntryError, action: :update, changeset: changeset
    end
  end
end
