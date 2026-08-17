Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools09Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "worker blocker commands accept only their redundant implied status", %{repo: repo} do
    {package, session} = worker_package_and_session!(repo, "SYMPP-BLOCKER-STATUS")

    mismatch =
      mcp_tool(repo, session, "report_blocker", %{
        "summary" => "Waiting",
        "status" => "resolved",
        "idempotency_key" => "status-mismatch"
      })

    assert get_in(mismatch, ["error", "data"]) == %{
             "tool" => "report_blocker",
             "reason" => "implied_status_mismatch",
             "expected_status" => "blocked",
             "recovery" => %{"next_action" => "omit_status_or_use_expected", "expected_status" => "blocked"}
           }

    assert {:ok, []} = PlanningRepository.list_progress_events(repo, package.id)

    report =
      mcp_tool(repo, session, "report_blocker", %{
        "blocker_id" => "status-blocker",
        "summary" => "Waiting",
        "status" => "blocked",
        "idempotency_key" => "status-report"
      })

    report_id = get_in(report, ["result", "structuredContent", "progress_event", "id"])
    assert repo.get!(ProgressEvent, report_id).status == "blocked"

    mismatch =
      mcp_tool(repo, session, "resolve_blocker", %{
        "blocker_id" => "status-blocker",
        "resolution" => "Ready",
        "summary" => "Ready",
        "status" => "blocked",
        "idempotency_key" => "resolve-mismatch"
      })

    assert get_in(mismatch, ["error", "data", "reason"]) == "implied_status_mismatch"
    assert get_in(mismatch, ["error", "data", "expected_status"]) == "resolved"

    resolve =
      mcp_tool(repo, session, "resolve_blocker", %{
        "blocker_id" => "status-blocker",
        "resolution" => "Ready",
        "summary" => "Ready",
        "status" => "resolved",
        "idempotency_key" => "status-resolve"
      })

    resolve_id = get_in(resolve, ["result", "structuredContent", "progress_event", "id"])
    assert repo.get!(ProgressEvent, resolve_id).status == "resolved"
    assert repo.get!(WorkPackage, package.id).status == "active"
  end

  test "resolved worker blockers replay or no-op while ownership and unblocking stay strict", %{repo: repo} do
    {package, session} = worker_package_and_session!(repo, "SYMPP-BLOCKER-IDEMPOTENCY")

    for blocker_id <- ["first", "second"] do
      assert get_in(
               mcp_tool(repo, session, "report_blocker", %{
                 "blocker_id" => blocker_id,
                 "summary" => "Waiting on #{blocker_id}",
                 "idempotency_key" => "report-#{blocker_id}"
               }),
               ["result", "structuredContent", "progress_event", "id"]
             )
    end

    first_args = %{
      "blocker_id" => "first",
      "resolution" => "First ready",
      "summary" => "Resolved first",
      "idempotency_key" => "resolve-first"
    }

    first = mcp_tool(repo, session, "resolve_blocker", first_args)
    first_id = get_in(first, ["result", "structuredContent", "progress_event", "id"])
    assert repo.get!(WorkPackage, package.id).status == "blocked"

    replay = mcp_tool(repo, session, "resolve_blocker", first_args)
    assert get_in(replay, ["result", "structuredContent", "progress_event", "id"]) == first_id

    assert {:ok, events_before_noop} = PlanningRepository.list_progress_events(repo, package.id)

    no_op =
      mcp_tool(repo, session, "resolve_blocker", %{
        "blocker_id" => "first",
        "resolution" => "Different prose must not be stored",
        "summary" => "Different no-op prose",
        "idempotency_key" => "resolve-first-again"
      })

    assert get_in(no_op, ["result", "structuredContent", "already_resolved"]) == true
    refute get_in(no_op, ["result", "structuredContent", "progress_event"])
    assert {:ok, ^events_before_noop} = PlanningRepository.list_progress_events(repo, package.id)

    unknown =
      mcp_tool(repo, session, "resolve_blocker", %{
        "blocker_id" => "unknown",
        "resolution" => "No",
        "summary" => "No",
        "idempotency_key" => "resolve-unknown"
      })

    assert get_in(unknown, ["error", "data", "reason"]) == "blocker_not_found"

    other_session = worker_session!(repo, package, "worker-2")

    assert get_in(
             mcp_tool(repo, other_session, "report_blocker", %{
               "blocker_id" => "other-owner",
               "summary" => "Owned elsewhere",
               "idempotency_key" => "report-other-owner"
             }),
             ["result", "structuredContent", "progress_event", "id"]
           )

    protected =
      mcp_tool(repo, session, "resolve_blocker", %{
        "blocker_id" => "other-owner",
        "resolution" => "No",
        "summary" => "No",
        "idempotency_key" => "resolve-other-owner"
      })

    assert get_in(protected, ["error", "data", "reason"]) == "blocker_owned_by_another_actor"

    assert get_in(
             mcp_tool(repo, session, "resolve_blocker", %{
               "blocker_id" => "second",
               "resolution" => "Second ready",
               "summary" => "Resolved second",
               "idempotency_key" => "resolve-second"
             }),
             ["result", "structuredContent", "progress_event", "id"]
           )

    assert repo.get!(WorkPackage, package.id).status == "blocked"

    assert get_in(
             mcp_tool(repo, other_session, "resolve_blocker", %{
               "blocker_id" => "other-owner",
               "resolution" => "Owner resolved",
               "summary" => "Owner resolved",
               "idempotency_key" => "resolve-other-owner-by-owner"
             }),
             ["result", "structuredContent", "progress_event", "id"]
           )

    assert repo.get!(WorkPackage, package.id).status == "active"

    assert {:ok, _ready} = WorkPackageRepository.update(repo, package.id, %{status: "ready_for_merge"})
    assert {:ok, events_before_ready_retries} = PlanningRepository.list_progress_events(repo, package.id)

    ready_replay = mcp_tool(repo, session, "resolve_blocker", first_args)
    assert get_in(ready_replay, ["result", "structuredContent", "progress_event", "id"]) == first_id

    ready_no_op =
      mcp_tool(repo, session, "resolve_blocker", %{
        "blocker_id" => "second",
        "resolution" => "Ready retry",
        "summary" => "Resolved retry",
        "idempotency_key" => "resolve-second-ready-retry"
      })

    assert get_in(ready_no_op, ["result", "structuredContent", "already_resolved"]) == true
    assert {:ok, ^events_before_ready_retries} = PlanningRepository.list_progress_events(repo, package.id)
  end

  test "concurrent worker resolution stores one immutable event and returns two successes", %{repo: repo} do
    {package, session} = worker_package_and_session!(repo, "SYMPP-BLOCKER-CONCURRENT")

    assert get_in(
             mcp_tool(repo, session, "report_blocker", %{
               "blocker_id" => "concurrent",
               "summary" => "Waiting",
               "idempotency_key" => "report-concurrent"
             }),
             ["result", "structuredContent", "progress_event", "id"]
           )

    parent = self()

    tasks =
      for attempt <- 1..2 do
        Task.async(fn ->
          send(parent, {:resolver_ready, self()})
          receive do: (:resolve -> :ok)

          mcp_tool(repo, session, "resolve_blocker", %{
            "blocker_id" => "concurrent",
            "resolution" => "Ready #{attempt}",
            "summary" => "Resolved #{attempt}",
            "idempotency_key" => "resolve-concurrent-#{attempt}"
          })
        end)
      end

    resolver_pids =
      for _task <- tasks,
          do:
            (
              assert_receive {:resolver_ready, pid}, 5_000
              pid
            )

    Enum.each(resolver_pids, &send(&1, :resolve))
    responses = Enum.map(tasks, &Task.await(&1, 10_000))

    assert Enum.all?(responses, &get_in(&1, ["result", "structuredContent"]))
    assert Enum.count(responses, &get_in(&1, ["result", "structuredContent", "progress_event"])) == 1
    assert Enum.count(responses, &get_in(&1, ["result", "structuredContent", "already_resolved"])) == 1

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, package.id)

    assert [resolution_event] =
             Enum.filter(events, fn event ->
               event.payload["source_tool"] == "resolve_blocker" and event.payload["blocker_id"] == "concurrent"
             end)

    assert repo.get!(ProgressEvent, resolution_event.id) == resolution_event
    assert repo.get!(WorkPackage, package.id).status == "active"
  end

  defp worker_package_and_session!(repo, id) do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: id, kind: "mcp", status: "active")
             )

    {package, worker_session!(repo, package, "worker-1")}
  end

  defp worker_session!(repo, package, claimed_by) do
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: claimed_by)
    MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
  end
end
