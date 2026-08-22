Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerToolsReadyGateTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "mark_ready uses provider state without duplicate review attestation", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-READY-PROVIDER",
                 kind: "standard_pr",
                 status: "ci_waiting",
                 review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "fast"}}
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_merge_evidence_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "missing-merge-evidence", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "pr_attached" in get_in(missing_merge_evidence_response, ["error", "data", "missing"])

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-PROVIDER/worker", "head_sha" => "abc125"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/125", "head_sha" => "abc125"})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/125", "abc125")

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-provider", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "ready evidence guard reads only the package with 1,000 history rows", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-GUARD-BOUNDED", kind: "mcp", status: "ready_for_worker")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    assert {1, nil} =
             repo.update_all(
               from(work_package in WorkPackage, where: work_package.id == ^package.id),
               set: [status: "ready_for_merge"]
             )

    now = DateTime.utc_now(:microsecond)

    rows =
      for sequence <- 1..1_000 do
        %{
          id: "progress-ready-guard-#{sequence}",
          work_package_id: package.id,
          summary: "Historical progress #{sequence}",
          status: "recorded",
          sequence: sequence,
          idempotency_scope: "direct",
          payload: %{},
          created_at: now,
          inserted_at: now,
          updated_at: now
        }
      end

    assert {1_000, nil} = repo.insert_all(ProgressEvent, rows)

    {response, queries} =
      capture_queries(repo, fn ->
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "ready-guard-bounded",
            "method" => "tools/call",
            "params" => %{
              "name" => "append_progress",
              "arguments" => %{"summary" => "Must remain rejected", "idempotency_key" => "ready-guard-bounded"}
            }
          },
          repo: repo,
          session: session
        )
      end)

    assert get_in(response, ["error", "data", "reason"]) == "already_ready"

    lock_index =
      Enum.find_index(queries, fn query ->
        String.starts_with?(query, "UPDATE \"sympp_work_packages\"") and String.contains?(query, "SET \"id\"")
      end)

    assert is_integer(lock_index)
    guard_queries = Enum.drop(queries, lock_index + 1)

    assert Enum.count(guard_queries, &String.contains?(&1, "FROM \"sympp_work_packages\"")) == 1
    refute Enum.any?(guard_queries, &String.contains?(&1, "FROM \"sympp_progress_events\""))
  end

  defp capture_queries(repo, fun) do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    event = repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, test_pid -> send(test_pid, {handler_id, metadata.query}) end,
        self()
      )

    try do
      result = fun.()
      {result, drain_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, queries) do
    receive do
      {^handler_id, query} -> drain_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
