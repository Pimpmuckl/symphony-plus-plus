Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools08Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "protected resources revalidate injected sessions against live grants", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P3-001"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 8, "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        repo: repo,
        session: MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
      )

    assert get_in(response, ["error", "code"]) == -32_001
    assert get_in(response, ["error", "data", "reason"]) == "revoked"

    list_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 9, "method" => "resources/list", "params" => %{}},
        repo: repo,
        session: MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
      )

    resource_uris = list_response |> get_in(["result", "resources"]) |> Enum.map(& &1["uri"])
    refute "sympp://assignment/current" in resource_uris

    progress_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "revoked-progress",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_progress",
            "arguments" => %{"summary" => "Should not write", "idempotency_key" => "revoked-progress"}
          }
        },
        repo: repo,
        session: MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
      )

    assert get_in(progress_response, ["error", "data", "reason"]) == "revoked"

    assert {:ok, status_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-REVOKED-STATUS", kind: "mcp", status: "active"))

    assert {:ok, status_minted} = AccessGrantService.mint_worker_grant(repo, status_package.id)
    assert {:ok, status_assignment} = AccessGrantService.claim(repo, status_minted.work_key.secret, claimed_by: "worker-1")
    assert {:ok, _revoked_status} = AccessGrantService.revoke(repo, status_minted.grant.id)

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "revoked-ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: MCPHarness.session(status_assignment, proof_hash: status_minted.grant.secret_hash)
      )

    assert get_in(ready_response, ["error", "data", "reason"]) == "revoked"
  end

  test "transactional assignment revalidation rejects expired grants", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-EXPIRED-TX"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    repo.update_all(AccessGrant, set: [expires_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)])

    assert {:error, :expired} =
             PlanningRepository.append_audit_progress_event(repo, assignment, %{
               "summary" => "Should not write",
               "idempotency_key" => "expired-progress"
             })

    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    progress_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "expired-progress",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"summary" => "Should not write", "idempotency_key" => "expired-progress-mcp"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(progress_response, ["error", "code"]) == -32_001
    assert get_in(progress_response, ["error", "data", "reason"]) == "expired"

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, work_package.id)
    assert events == []
  end

  test "idempotent progress replay revalidates live grants", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-REPLAY-REVOKED"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    first_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "first-progress",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"summary" => "Stored once", "idempotency_key" => "replay-progress"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(first_response, ["result", "structuredContent", "progress_event", "idempotency_key"]) == "append_progress:replay-progress"

    first_event_id = get_in(first_response, ["result", "structuredContent", "progress_event", "id"])
    assert {:ok, second_minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, second_assignment} = AccessGrantService.claim(repo, second_minted.work_key.secret, claimed_by: "worker-2")
    second_session = MCPHarness.session(second_assignment, proof_hash: second_minted.grant.secret_hash)

    renewed_replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "renewed-replay-progress",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"summary" => "Stored once", "idempotency_key" => "replay-progress"}}
        },
        repo: repo,
        session: second_session
      )

    assert get_in(renewed_replay_response, ["result", "structuredContent", "progress_event", "id"]) == first_event_id

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)

    replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "replay-progress",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"summary" => "Stored once", "idempotency_key" => "replay-progress"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(replay_response, ["error", "data", "reason"]) == "revoked"
  end

  test "protected resources require injected session proof of possession", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P3-001"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 8, "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        repo: repo,
        session: MCPHarness.session(assignment)
      )

    assert get_in(response, ["error", "code"]) == -32_001
    assert get_in(response, ["error", "data", "reason"]) == "missing_session_proof"

    list_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 9, "method" => "resources/list", "params" => %{}},
        repo: repo,
        session: MCPHarness.session(assignment)
      )

    resource_uris = list_response |> get_in(["result", "resources"]) |> Enum.map(& &1["uri"])
    refute "sympp://assignment/current" in resource_uris
  end

  test "protected resource reads surface structured ledger failures" do
    session =
      Session.new(%Assignment{
        grant_id: "grant-1",
        work_package_id: "SYMPP-P3-001",
        display_key: "ABCD",
        grant_role: "worker",
        capabilities: [],
        claimed_at: DateTime.utc_now(:microsecond),
        claimed_by: "worker-1"
      })

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 10, "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        config: Config.default(repo: FailingAuthRepo),
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_000
    assert get_in(response, ["error", "data", "reason"]) == "ledger_unavailable"
    refute Map.has_key?(get_in(response, ["error", "data"]), "detail")
  end

  test "malformed injected sessions fail closed without protected resources", %{repo: repo} do
    read_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 10, "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        repo: repo,
        session: %{"grant_id" => "grant-1"}
      )

    assert get_in(read_response, ["error", "code"]) == -32_001
    assert get_in(read_response, ["error", "data", "reason"]) == "invalid_session"

    list_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 11, "method" => "resources/list", "params" => %{}},
        repo: repo,
        session: %{"grant_id" => "grant-1"}
      )

    resource_uris = list_response |> get_in(["result", "resources"]) |> Enum.map(& &1["uri"])
    refute "sympp://assignment/current" in resource_uris
  end

  test "protected resources surface unexpected grant lookup results as ledger failures" do
    session =
      Session.new(%Assignment{
        grant_id: "grant-1",
        work_package_id: "SYMPP-P3-001",
        display_key: "ABCD",
        grant_role: "worker",
        capabilities: [],
        claimed_at: DateTime.utc_now(:microsecond),
        claimed_by: "worker-1"
      })

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 10, "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        config: Config.default(repo: UnexpectedAuthRepo),
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_000
    assert get_in(response, ["error", "data", "reason"]) == "ledger_unavailable"
    refute Map.has_key?(get_in(response, ["error", "data"]), "detail")
  end

  test "resource listing surfaces ledger failures for injected sessions" do
    session =
      Session.new(%Assignment{
        grant_id: "grant-1",
        work_package_id: "SYMPP-P3-001",
        display_key: "ABCD",
        grant_role: "worker",
        capabilities: [],
        claimed_at: DateTime.utc_now(:microsecond),
        claimed_by: "worker-1"
      })

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 11, "method" => "resources/list", "params" => %{}},
        config: Config.default(repo: FailingAuthRepo),
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_000
    assert get_in(response, ["error", "data", "reason"]) == "ledger_unavailable"
    refute Map.has_key?(get_in(response, ["error", "data"]), "detail")
  end

  test "malformed work package resource URIs fail before auth", %{repo: repo} do
    Enum.each(
      [
        "sympp://work-packages/",
        "sympp://work-packages//task_plan.md",
        "sympp://work-packages/SYMPP-P3-001/",
        "sympp://work-packages/SYMPP-P3-001//task_plan.md",
        "sympp://work-packages/SYMPP-P3-001/path/to/file.md"
      ],
      fn uri ->
        response =
          MCPHarness.request(
            %{"jsonrpc" => "2.0", "id" => uri, "method" => "resources/read", "params" => %{"uri" => uri}},
            repo: repo
          )

        assert get_in(response, ["error", "code"]) == -32_602
        assert get_in(response, ["error", "data", "reason"]) == "invalid_work_package_resource_uri"
      end
    )
  end

  test "invalid health arguments do not log bearer tokens or grant secrets", %{repo: repo} do
    secret = "wk_secret_that_must_not_be_logged"

    log =
      capture_log(fn ->
        response =
          MCPHarness.request(
            %{
              "jsonrpc" => "2.0",
              "id" => "health",
              "method" => "tools/call",
              "params" => %{"name" => "sympp.health", "arguments" => %{"bearer" => "Bearer #{secret}"}}
            },
            repo: repo
          )

        assert get_in(response, ["error", "data", "reason"]) == "invalid_tool_arguments"
      end)

    refute log =~ secret
    refute log =~ "Bearer"
  end
end
