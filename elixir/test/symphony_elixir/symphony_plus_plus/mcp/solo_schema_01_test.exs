Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.SoloSchema01Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  @solo_tool_names [
    "solo_attach",
    "solo_show",
    "solo_list",
    "solo_record_task_plan",
    "solo_append_progress",
    "solo_append_finding",
    "solo_record_decision",
    "solo_report_blocker",
    "solo_resolve_blocker",
    "solo_record_validation",
    "solo_pause",
    "solo_resume",
    "solo_complete",
    "solo_archive"
  ]

  defmodule WorkKeyClaimRaceRepo do
    import Ecto.Query, only: [from: 2]

    alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    @race_key :sympp_work_key_claim_race

    def arm(grant_id, claimed_by), do: Process.put(@race_key, {grant_id, claimed_by})
    def disarm, do: Process.delete(@race_key)

    def transaction(fun) do
      {:ok, fun.()}
    catch
      {:rollback, value} -> {:error, value}
    end

    def rollback(value), do: throw({:rollback, value})
    def get(schema, id), do: Repo.get(schema, id)
    def one(query), do: Repo.one(query)
    def all(query), do: Repo.all(query)
    def insert(changeset), do: Repo.insert(changeset)
    def update(changeset), do: Repo.update(changeset)

    def update_all(query, updates) do
      inject_claim_race(updates)
      Repo.update_all(query, updates)
    end

    defp inject_claim_race(set: fields) do
      if Keyword.has_key?(fields, :claimed_at) do
        case Process.get(@race_key) do
          {grant_id, claimed_by} ->
            Process.delete(@race_key)
            now = DateTime.utc_now(:microsecond)

            Repo.update_all(
              from(grant in AccessGrant, where: grant.id == ^grant_id and is_nil(grant.claimed_at)),
              set: [claimed_at: now, claimed_by: claimed_by, updated_at: now]
            )

          _race ->
            :ok
        end
      end
    end

    defp inject_claim_race(_updates), do: :ok
  end

  test "tools list advertises Solo tools for unbound sessions only", %{repo: repo} do
    unbound_server = Server.new(Config.default(repo: repo), initialized: true)

    unbound_response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "solo-tools", "method" => "tools/list", "params" => %{}}, unbound_server)

    unbound_tools_by_name =
      unbound_response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    for tool <- @solo_tool_names do
      assert Map.has_key?(unbound_tools_by_name, tool)
    end

    refute Map.has_key?(unbound_tools_by_name, "solo_append")
    refute Map.has_key?(unbound_tools_by_name, "solo_update_status")

    assert get_in(unbound_tools_by_name, ["solo_attach", "inputSchema", "required"]) == ["repo", "base_branch", "workspace_path", "caller_id"]
    assert get_in(unbound_tools_by_name, ["solo_append_progress", "inputSchema", "required"]) == ["session_id", "summary"]
    assert get_in(unbound_tools_by_name, ["solo_append_progress", "inputSchema", "properties", "payload", "type"]) == "object"
    assert get_in(unbound_tools_by_name, ["solo_record_validation", "inputSchema", "required"]) == ["session_id", "summary", "result"]
    assert get_in(unbound_tools_by_name, ["solo_show", "inputSchema", "required"]) == ["session_id"]
    assert get_in(unbound_tools_by_name, ["solo_list", "inputSchema", "required"]) == []
    assert get_in(unbound_tools_by_name, ["solo_pause", "inputSchema", "required"]) == ["session_id"]

    unbound_release_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "release-current-assignment-unbound",
          "method" => "tools/call",
          "params" => %{"name" => "release_current_assignment", "arguments" => %{"reason" => "done"}}
        },
        unbound_server
      )

    assert get_in(unbound_release_response, ["result", "structuredContent", "status"]) == "ok"
    assert get_in(unbound_release_response, ["result", "structuredContent", "binding_cleared"]) == true
    assert get_in(unbound_release_response, ["result", "structuredContent", "claim_lease_release", "reason"]) == "not_bound"

    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-SOLO-WORKER-TOOLS", kind: "mcp"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: minted.grant.secret_hash)

    worker_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "solo-worker-tools", "method" => "tools/list", "params" => %{}},
        Server.new(Config.default(repo: repo), initialized: true, session: worker_session)
      )

    worker_tools_by_name =
      worker_response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    for tool <- @solo_tool_names do
      refute Map.has_key?(worker_tools_by_name, tool)
    end

    assert Map.has_key?(worker_tools_by_name, "release_current_assignment")

    {_anchor, architect_session, _grant} = create_phase_architect_session(repo, "SYMPP-SOLO-ARCH-TOOLS", ["read:phase"])

    architect_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "solo-architect-tools", "method" => "tools/list", "params" => %{}},
        Server.new(test_mcp_config(repo), initialized: true, session: architect_session)
      )

    architect_tools_by_name =
      architect_response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    for tool <- @solo_tool_names do
      refute Map.has_key?(architect_tools_by_name, tool)
    end

    assert Map.has_key?(architect_tools_by_name, "release_current_assignment")
  end

  test "Solo MCP tools attach record progress show list redact and replay idempotent entries", %{repo: repo} do
    workspace_path = solo_workspace_path("happy")

    attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => workspace_path,
        "caller_id" => "codex-local",
        "title" => "Plan bearer abcdefghijkl"
      })

    assert get_in(attach_response, ["result", "structuredContent", "action"]) == "solo_attach"
    attach_text = assert_toon_tool_text!(attach_response)
    assert attach_text =~ "action: solo_attach"
    assert attach_text =~ "solo_session:"
    refute attach_text =~ ~s("solo_session")

    session = get_in(attach_response, ["result", "structuredContent", "solo_session"])
    assert session["id"] =~ "solo_"
    assert session["session_key"] =~ "solo_key_"
    assert session["title"] == "Plan [REDACTED]"

    progress_args = %{
      "session_id" => session["id"],
      "summary" => "Use ghp_abcdefgh",
      "body" => "Body bearer abcdefghijkl",
      "status" => "active",
      "idempotency_key" => "solo-entry-1",
      "payload" => %{"token" => "ghp_abcdefgh", "nested" => %{"url" => "https://example.test/?token=ghp_abcdefgh"}}
    }

    progress_response = mcp_tool(repo, nil, "solo_append_progress", progress_args)
    entry = get_in(progress_response, ["result", "structuredContent", "entry"])
    progress_text = assert_toon_tool_text!(progress_response)
    assert progress_text =~ "action: solo_append_progress"
    assert progress_text =~ "[REDACTED]"
    refute progress_text =~ "ghp_abcdefgh"

    assert entry["entry_kind"] == "progress"
    assert entry["title"] == "Use [REDACTED]"
    assert entry["body"] == "Body [REDACTED]"
    assert entry["status"] == "in_progress"
    assert entry["payload"]["token"] == "[REDACTED]"
    assert entry["payload"]["nested"]["url"] == "https://example.test/?token=[REDACTED]"

    replay_response = mcp_tool(repo, nil, "solo_append_progress", %{progress_args | "summary" => "Changed retry"})
    replay_entry = get_in(replay_response, ["result", "structuredContent", "entry"])
    assert replay_entry["id"] == entry["id"]
    assert replay_entry["title"] == entry["title"]

    show_response = mcp_tool(repo, nil, "solo_show", %{"session_id" => session["id"]})
    show_text = assert_toon_tool_text!(show_response)
    assert show_text =~ "action: solo_show"
    assert show_text =~ "entries_returned: 1"
    assert get_in(show_response, ["result", "structuredContent", "solo_session", "id"]) == session["id"]
    assert [shown_entry] = get_in(show_response, ["result", "structuredContent", "entries"])
    assert shown_entry["id"] == entry["id"]

    list_response =
      mcp_tool(repo, nil, "solo_list", %{
        "repo" => " nextide/example ",
        "base_branch" => "main",
        "workspace_path" => workspace_path,
        "caller_id" => "codex-local",
        "status" => "active"
      })

    assert get_in(list_response, ["result", "structuredContent", "solo_sessions"]) |> Enum.map(& &1["id"]) == [session["id"]]
    list_text = assert_toon_tool_text!(list_response)
    assert list_text =~ "action: solo_list"
    assert list_text =~ "solo_sessions[1]"
  end

  test "Solo MCP lifecycle updates follow the Solo Session service contract", %{repo: repo} do
    attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => solo_workspace_path("lifecycle"),
        "caller_id" => "codex-local"
      })

    session_id = get_in(attach_response, ["result", "structuredContent", "solo_session", "id"])

    pause_response =
      mcp_tool(repo, nil, "solo_pause", %{"session_id" => session_id})

    assert get_in(pause_response, ["result", "structuredContent", "action"]) == "solo_pause"
    assert get_in(pause_response, ["result", "structuredContent", "solo_session", "status"]) == "paused"

    resume_response =
      mcp_tool(repo, nil, "solo_resume", %{"session_id" => session_id})

    assert get_in(resume_response, ["result", "structuredContent", "solo_session", "status"]) == "active"

    complete_response =
      mcp_tool(repo, nil, "solo_complete", %{"session_id" => session_id})

    assert get_in(complete_response, ["result", "structuredContent", "solo_session", "status"]) == "completed"

    archive_response =
      mcp_tool(repo, nil, "solo_archive", %{"session_id" => session_id})

    assert get_in(archive_response, ["result", "structuredContent", "solo_session", "status"]) == "archived"
    assert is_binary(get_in(archive_response, ["result", "structuredContent", "solo_session", "archived_at"]))

    paused_attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => solo_workspace_path("paused-complete"),
        "caller_id" => "codex-local"
      })

    paused_session_id = get_in(paused_attach_response, ["result", "structuredContent", "solo_session", "id"])

    assert get_in(
             mcp_tool(repo, nil, "solo_pause", %{"session_id" => paused_session_id}),
             ["result", "structuredContent", "solo_session", "status"]
           ) == "paused"

    assert get_in(
             mcp_tool(repo, nil, "solo_complete", %{"session_id" => paused_session_id}),
             ["result", "structuredContent", "solo_session", "status"]
           ) == "completed"
  end

  test "Solo MCP show returns a bounded recent entry window", %{repo: repo} do
    attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => solo_workspace_path("recent-window"),
        "caller_id" => "codex-local"
      })

    session_id = get_in(attach_response, ["result", "structuredContent", "solo_session", "id"])

    for index <- 1..55 do
      response =
        mcp_tool(repo, nil, "solo_append_progress", %{
          "session_id" => session_id,
          "summary" => "Entry #{index}",
          "idempotency_key" => "recent-window-#{index}"
        })

      assert get_in(response, ["result", "structuredContent", "entry", "sequence"]) == index
    end

    show_response = mcp_tool(repo, nil, "solo_show", %{"session_id" => session_id})
    show = get_in(show_response, ["result", "structuredContent"])

    assert show["entry_count"] == 55
    assert show["entries_returned"] == 50
    assert show["entries_truncated"] == true
    assert Enum.map(show["entries"], & &1["sequence"]) == Enum.to_list(6..55)
  end

  test "Solo MCP tools surface validation errors without mutating state", %{repo: repo} do
    invalid_attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => "relative/workspace",
        "caller_id" => "codex-local"
      })

    assert get_in(invalid_attach_response, ["error", "data", "reason"]) == "invalid_workspace_path"
    assert repo.aggregate(SoloSession, :count, :id) == 0

    attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => solo_workspace_path("validation"),
        "caller_id" => "codex-local"
      })

    session_id = get_in(attach_response, ["result", "structuredContent", "solo_session", "id"])

    invalid_append_response =
      mcp_tool(repo, nil, "solo_append_progress", %{
        "session_id" => session_id,
        "summary" => "Reject secret key",
        "idempotency_key" => "wk_" <> String.duplicate("A", 43)
      })

    assert get_in(invalid_append_response, ["error", "data", "reason"]) == "invalid_entry_idempotency_key"

    invalid_validation_response =
      mcp_tool(repo, nil, "solo_record_validation", %{
        "session_id" => session_id,
        "summary" => "Reject bad result",
        "result" => "maybe"
      })

    assert get_in(invalid_validation_response, ["error", "data", "reason"]) == "invalid_solo_validation_result"
    assert "passed" in get_in(invalid_validation_response, ["error", "data", "allowed_values"])

    missing_blocker_response =
      mcp_tool(repo, nil, "solo_resolve_blocker", %{
        "session_id" => session_id,
        "blocker_id" => "missing-blocker",
        "resolution" => "Nothing to resolve"
      })

    assert get_in(missing_blocker_response, ["error", "data", "reason"]) == "solo_blocker_not_open"
    assert repo.aggregate(SoloSessionEntry, :count, :id) == 0
  end

  test "Solo MCP lifecycle errors are clean and do not mutate sessions", %{repo: repo} do
    attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => solo_workspace_path("lifecycle-errors"),
        "caller_id" => "codex-local"
      })

    session_id = get_in(attach_response, ["result", "structuredContent", "solo_session", "id"])
    assert {:ok, active_before} = SoloSessionRepository.get(repo, session_id)

    same_status_response = mcp_tool(repo, nil, "solo_resume", %{"session_id" => session_id})

    assert get_in(same_status_response, ["result", "structuredContent", "solo_session", "status"]) == "active"
    assert {:ok, active_after_same_status} = SoloSessionRepository.get(repo, session_id)
    assert active_after_same_status.status == "active"
    assert active_after_same_status.last_activity_at == active_before.last_activity_at
    assert active_after_same_status.updated_at == active_before.updated_at
    assert active_after_same_status.archived_at == active_before.archived_at

    missing_response =
      mcp_tool(repo, nil, "solo_pause", %{"session_id" => "solo_missing"})

    assert get_in(missing_response, ["error", "code"]) == -32_004
    assert get_in(missing_response, ["error", "data", "reason"]) == "not_found"
    assert repo.aggregate(SoloSession, :count, :id) == 1

    complete_response =
      mcp_tool(repo, nil, "solo_complete", %{"session_id" => session_id})

    assert get_in(complete_response, ["result", "structuredContent", "solo_session", "status"]) == "completed"
    assert {:ok, completed_before} = SoloSessionRepository.get(repo, session_id)

    completed_again_response = mcp_tool(repo, nil, "solo_complete", %{"session_id" => session_id})

    assert get_in(completed_again_response, ["result", "structuredContent", "solo_session", "status"]) == "completed"
    assert {:ok, completed_after_same_status} = SoloSessionRepository.get(repo, session_id)
    assert completed_after_same_status.last_activity_at == completed_before.last_activity_at
    assert completed_after_same_status.updated_at == completed_before.updated_at

    completed_to_active_response =
      mcp_tool(repo, nil, "solo_resume", %{"session_id" => session_id})

    assert get_in(completed_to_active_response, ["error", "data", "reason"]) == "invalid_transition"
    assert {:ok, completed_after_invalid_transition} = SoloSessionRepository.get(repo, session_id)
    assert completed_after_invalid_transition.status == "completed"
    assert completed_after_invalid_transition.last_activity_at == completed_before.last_activity_at
    assert completed_after_invalid_transition.updated_at == completed_before.updated_at
  end

  test "Solo MCP calls from bound sessions fail before mutation", %{repo: repo} do
    {package, work_request, minted, _claim_response, claimed_server} = claim_local_bound_assignment!(repo, "SYMPP-SOLO-BOUND-DENY")

    {response, _server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "solo-bound-deny",
          "method" => "tools/call",
          "params" => %{
            "name" => "solo_attach",
            "arguments" => %{
              "repo" => "nextide/example",
              "base_branch" => "main",
              "workspace_path" => solo_workspace_path("bound"),
              "caller_id" => "codex-local"
            }
          }
        },
        claimed_server
      )

    data = get_in(response, ["error", "data"])
    context = data["current_assignment"]

    assert get_in(response, ["error", "code"]) == -32_001
    assert data["reason"] == "solo_tools_require_unbound_session"
    assert data["action"] == "release_current_assignment"
    assert get_in(data, ["recovery", "tool"]) == "release_current_assignment"
    assert get_in(data, ["recovery", "next_action"]) == "call_release_current_assignment_then_retry_solo_tool"
    assert context["role"] == "worker"
    assert context["repo"] == package.repo
    assert context["base_branch"] == package.base_branch
    assert context["work_package_id"] == package.id
    assert context["work_request_id"] == work_request.id
    assert context["claimed_by"] == "local-worker-1"
    assert context["claim_lease_id"] =~ "claim_"
    assert context["claim_lease_status"] == "active"
    refute inspect(data) =~ minted.work_key.secret
    refute inspect(data) =~ "private_handoff"
    refute inspect(data) =~ "proof_hash"
    refute inspect(data) =~ "secret_hash"
    assert repo.aggregate(SoloSession, :count, :id) == 0

    attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => solo_workspace_path("bound-lifecycle"),
        "caller_id" => "codex-local"
      })

    session_id = get_in(attach_response, ["result", "structuredContent", "solo_session", "id"])

    {update_response, _server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "solo-pause-bound-deny",
          "method" => "tools/call",
          "params" => %{
            "name" => "solo_pause",
            "arguments" => %{"session_id" => session_id}
          }
        },
        claimed_server
      )

    assert get_in(update_response, ["error", "code"]) == -32_001
    assert get_in(update_response, ["error", "data", "reason"]) == "solo_tools_require_unbound_session"
    assert get_in(update_response, ["error", "data", "current_assignment", "work_package_id"]) == package.id
    assert {:ok, session} = SoloSessionRepository.get(repo, session_id)
    assert session.status == "active"
  end

  test "release_current_assignment releases the current lease and allows Solo tools in the same server", %{repo: repo} do
    {package, _work_request, minted, claim_response, claimed_server} = claim_local_bound_assignment!(repo, "SYMPP-SOLO-RELEASE")
    lease_id = get_in(claim_response, ["result", "structuredContent", "local_claim", "claim_lease_id"])

    {release_response, released_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "release-current-assignment",
          "method" => "tools/call",
          "params" => %{
            "name" => "release_current_assignment",
            "arguments" => %{"reason" => "done; bearer abcdefghijkl"}
          }
        },
        claimed_server
      )

    payload = get_in(release_response, ["result", "structuredContent"])

    assert payload["action"] == "release_current_assignment"
    assert payload["binding_cleared"] == true
    assert payload["solo_tools_available"] == true
    assert payload["fresh_mcp_session_required"] == false
    assert get_in(payload, ["released_assignment", "work_package_id"]) == package.id
    assert get_in(payload, ["released_assignment", "claim_lease_id"]) == lease_id
    assert get_in(payload, ["released_assignment", "claim_lease_status"]) == "released"
    assert payload["claim_lease_release"] == %{"status" => "released", "claim_lease_id" => lease_id, "claim_lease_status" => "released"}
    assert released_server.session == nil
    refute inspect(release_response) =~ minted.work_key.secret
    refute inspect(release_response) =~ "abcdefghijkl"
    refute inspect(release_response) =~ "private_handoff"
    refute inspect(release_response) =~ "proof_hash"
    refute inspect(release_response) =~ "secret_hash"

    assert {:error, :not_found} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert %ClaimLease{status: "released", release_reason: "done; [REDACTED]"} = repo.get(ClaimLease, lease_id)

    solo_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "solo-after-release",
          "method" => "tools/call",
          "params" => %{
            "name" => "solo_attach",
            "arguments" => %{
              "repo" => "nextide/example",
              "base_branch" => "main",
              "workspace_path" => solo_workspace_path("after-release"),
              "caller_id" => "codex-local"
            }
          }
        },
        released_server
      )

    assert get_in(solo_response, ["result", "structuredContent", "action"]) == "solo_attach"

    worker_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "worker-after-release", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        released_server
      )

    assert get_in(worker_response, ["error", "data", "reason"]) == "claim_required"
  end

  test "batched release_current_assignment updates the live server state", %{repo: repo} do
    {package, _work_request, _minted, claim_response, claimed_server} = claim_local_bound_assignment!(repo, "SYMPP-SOLO-RELEASE-BATCH")
    lease_id = get_in(claim_response, ["result", "structuredContent", "local_claim", "claim_lease_id"])

    {batch_response, released_server} =
      Server.handle_response_state(
        [
          %{
            "jsonrpc" => "2.0",
            "id" => "release-current-assignment-batch",
            "method" => "tools/call",
            "params" => %{"name" => "release_current_assignment", "arguments" => %{"reason" => "done"}}
          }
        ],
        claimed_server
      )

    assert [release_response] = batch_response
    assert get_in(release_response, ["result", "structuredContent", "binding_cleared"]) == true
    assert get_in(release_response, ["result", "structuredContent", "claim_lease_release", "claim_lease_id"]) == lease_id
    assert released_server.session == nil
    assert {:error, :not_found} = ClaimLeaseService.current_for_work_package(repo, package.id)

    solo_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "solo-after-batch-release",
          "method" => "tools/call",
          "params" => %{
            "name" => "solo_attach",
            "arguments" => %{
              "repo" => "nextide/example",
              "base_branch" => "main",
              "workspace_path" => solo_workspace_path("after-batch-release"),
              "caller_id" => "codex-local"
            }
          }
        },
        released_server
      )

    assert get_in(solo_response, ["result", "structuredContent", "action"]) == "solo_attach"
  end

  test "release_current_assignment releases a local assignment lease and allows Solo tools in the same server", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-SOLO-RELEASE-WORK-KEY", kind: "mcp"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {claim_response, claimed_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-work-key-release",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => %{"work_package_id" => package.id, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert claimed_server.session.assignment.grant_id == minted.grant.id
    assert {:ok, %ClaimLease{id: lease_id, actor_id: "local:" <> _hash}} = ClaimLeaseService.current_for_work_package(repo, package.id)

    {release_response, released_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "release-work-key-current-assignment",
          "method" => "tools/call",
          "params" => %{"name" => "release_current_assignment", "arguments" => %{"reason" => "done"}}
        },
        claimed_server
      )

    payload = get_in(release_response, ["result", "structuredContent"])

    assert payload["binding_cleared"] == true
    assert payload["solo_tools_available"] == true
    assert payload["fresh_mcp_session_required"] == false
    assert get_in(payload, ["claim_lease_release", "status"]) == "released"
    assert get_in(payload, ["claim_lease_release", "claim_lease_id"]) == lease_id
    assert released_server.session == nil
    assert {:error, :not_found} = ClaimLeaseService.current_for_work_package(repo, package.id)

    solo_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "solo-after-work-key-release",
          "method" => "tools/call",
          "params" => %{
            "name" => "solo_attach",
            "arguments" => %{
              "repo" => "nextide/example",
              "base_branch" => "main",
              "workspace_path" => solo_workspace_path("after-work-key-release"),
              "caller_id" => "codex-local"
            }
          }
        },
        released_server
      )

    assert get_in(solo_response, ["result", "structuredContent", "action"]) == "solo_attach"
  end

  test "release_current_assignment keeps binding when claim lease identity is unavailable", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-SOLO-RELEASE-LEGACY", kind: "mcp"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-legacy-release",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => %{"work_package_id" => package.id, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert {:ok, %ClaimLease{}} = ClaimLeaseService.current_for_work_package(repo, package.id)

    legacy_session = %{
      claimed_server.session
      | claim_lease_id: nil,
        claim_actor_kind: nil,
        claim_actor_id: nil,
        claim_actor_display_name: nil
    }

    {release_response, still_bound_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "release-legacy-current-assignment",
          "method" => "tools/call",
          "params" => %{"name" => "release_current_assignment", "arguments" => %{"reason" => "done"}}
        },
        %{claimed_server | session: legacy_session}
      )

    payload = get_in(release_response, ["result", "structuredContent"])

    assert payload["binding_cleared"] == true
    assert payload["solo_tools_available"] == true
    assert payload["fresh_mcp_session_required"] == false
    assert get_in(payload, ["claim_lease_release", "status"]) == "skipped"
    assert get_in(payload, ["claim_lease_release", "reason"]) == "claim_lease_identity_unavailable"
    assert get_in(payload, ["recovery", "next_action"]) == "retry_solo_tool"
    assert get_in(payload, ["recovery", "fresh_mcp_session_required"]) == false
    assert still_bound_server.session == nil
    assert still_bound_server.session_refresh_required == false
    assert {:ok, %ClaimLease{status: "active"}} = ClaimLeaseService.current_for_work_package(repo, package.id)
    refute inspect(release_response) =~ minted.work_key.secret
  end

  test "release_current_assignment does not clear the binding when the matched lease cannot be released", %{repo: repo} do
    {package, _work_request, _minted, claim_response, claimed_server} = claim_local_bound_assignment!(repo, "SYMPP-SOLO-RELEASE-STALE")
    lease_id = get_in(claim_response, ["result", "structuredContent", "local_claim", "claim_lease_id"])

    assert {1, nil} =
             repo.update_all(
               from(claim_lease in ClaimLease, where: claim_lease.id == ^lease_id),
               set: [last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -2, :second), stale_after_ms: 1]
             )

    stale_claimed_server = %{claimed_server | session_refresh_required: true}

    {release_response, still_bound_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "release-stale-current-assignment",
          "method" => "tools/call",
          "params" => %{"name" => "release_current_assignment", "arguments" => %{"reason" => "done"}}
        },
        stale_claimed_server
      )

    payload = get_in(release_response, ["result", "structuredContent"])

    assert payload["binding_cleared"] == true
    assert payload["solo_tools_available"] == true
    assert get_in(payload, ["claim_lease_release", "status"]) == "skipped"
    assert get_in(payload, ["claim_lease_release", "reason"]) == "claim_stale"
    assert get_in(payload, ["recovery", "next_action"]) == "retry_solo_tool"
    assert get_in(payload, ["recovery", "fresh_mcp_session_required"]) == false
    assert still_bound_server.session == nil
    assert still_bound_server.session_refresh_required == false
    assert {:ok, %ClaimLease{id: ^lease_id, status: "active"}} = ClaimLeaseService.current_for_work_package(repo, package.id)
  end

  test "release_current_assignment never releases a newer active lease for a stale bound session", %{repo: repo} do
    {package, _work_request, _minted, claim_response, claimed_server} = claim_local_bound_assignment!(repo, "SYMPP-SOLO-RELEASE-MISMATCH")
    old_lease_id = get_in(claim_response, ["result", "structuredContent", "local_claim", "claim_lease_id"])
    assert {:ok, %ClaimLease{status: "released"}} = ClaimLeaseService.release(repo, old_lease_id, reason: "simulate_reclaim")

    assert {:ok, %ClaimLease{} = newer_lease} =
             ClaimLeaseService.claim(
               repo,
               package.id,
               %{
                 "actor_kind" => "agent",
                 "actor_id" => "local:new-owner:new-actor",
                 "actor_display_name" => "local-worker-1"
               },
               stale_after_ms: 86_400_000
             )

    newer_lease_id = newer_lease.id

    {release_response, still_bound_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "release-mismatched-current-assignment",
          "method" => "tools/call",
          "params" => %{"name" => "release_current_assignment", "arguments" => %{"reason" => "done"}}
        },
        claimed_server
      )

    payload = get_in(release_response, ["result", "structuredContent"])

    assert payload["binding_cleared"] == true
    assert payload["solo_tools_available"] == true
    assert payload["fresh_mcp_session_required"] == false
    assert get_in(payload, ["claim_lease_release", "status"]) == "skipped"
    assert get_in(payload, ["claim_lease_release", "reason"]) == "claim_lease_mismatch"
    assert get_in(payload, ["recovery", "next_action"]) == "retry_solo_tool"
    assert still_bound_server.session == nil
    assert still_bound_server.session_refresh_required == false
    assert {:ok, %ClaimLease{id: ^newer_lease_id, status: "active"}} = ClaimLeaseService.current_for_work_package(repo, package.id)
  end

  test "tools list advertises static architect schemas for architect sessions", %{repo: repo} do
    {_anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-TOOLS-LIST", [
        "create:child_work_package",
        "read:child_progress",
        "read:child_findings",
        "read:work_request",
        "write:work_request",
        "read:guidance_request",
        "write:guidance_request",
        "mint:child_worker_key",
        "revoke:child_worker_key",
        "read:phase",
        "dispatch:work_request",
        "approve:child_ready_state",
        "approve:scope_expansion",
        "merge:child_into_phase"
      ])

    server = Server.new(test_mcp_config(repo), initialized: true, session: session)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "architect-tools", "method" => "tools/list", "params" => %{}}, server)
    tools = get_in(response, ["result", "tools"])
    tools_by_name = Map.new(tools, &{&1["name"], &1})

    assert Map.has_key?(tools_by_name, "sympp.health")
    assert Map.has_key?(tools_by_name, "get_current_assignment")
    refute Map.has_key?(tools_by_name, "claim_work_key")
    refute Map.has_key?(tools_by_name, "claim_private_handoff")

    for tool <- @architect_tool_names do
      assert Map.has_key?(tools_by_name, tool)
    end

    assert get_in(tools_by_name, ["list_work_requests", "inputSchema", "required"]) == []
    assert get_in(tools_by_name, ["list_work_requests", "inputSchema", "properties", "status", "type"]) == "string"
    assert get_in(tools_by_name, ["read_work_request", "inputSchema", "required"]) == ["work_request_id"]
    assert get_in(tools_by_name, ["read_work_request", "inputSchema", "properties", "work_request_id", "type"]) == "string"
    refute Map.has_key?(get_in(tools_by_name, ["read_work_request", "inputSchema", "properties"]), "include_planning_scratch")
    assert get_in(tools_by_name, ["read_plan", "inputSchema", "required"]) == ["work_request_id"]

    assert get_in(tools_by_name, ["read_plan", "inputSchema", "properties", "view", "enum"]) == [
             "nodes_only",
             "nodes_with_slice_refs",
             "nodes_with_slices"
           ]

    refute Map.has_key?(get_in(tools_by_name, ["read_plan", "inputSchema", "properties"]), "include_planning_scratch")
    assert get_in(tools_by_name, ["add_comment", "inputSchema", "required"]) == ["target_kind", "target_id", "body"]
    assert get_in(tools_by_name, ["list_comments", "inputSchema", "required"]) == ["target_kind", "target_id"]
    assert get_in(tools_by_name, ["resolve_comment", "inputSchema", "required"]) == ["comment_id"]
    assert get_in(tools_by_name, ["resolve_blocker", "inputSchema", "required"]) == ["blocker_id", "resolution", "summary", "idempotency_key"]
    assert get_in(tools_by_name, ["read_delivery_board", "inputSchema", "required"]) == ["work_request_id"]
    refute Map.has_key?(get_in(tools_by_name, ["read_delivery_board", "inputSchema", "properties"]), "include_planning_scratch")
    assert get_in(tools_by_name, ["reconcile_work_request", "inputSchema", "required"]) == ["work_request_id"]
    assert get_in(tools_by_name, ["reconcile_work_request", "inputSchema", "properties", "apply", "type"]) == "boolean"

    cleanup_schema = get_in(tools_by_name, ["cleanup_work_request_planned_slice_runtime", "inputSchema"])
    delivery_schema = get_in(tools_by_name, ["record_planned_slice_delivery", "inputSchema"])
    revoke_schema = get_in(tools_by_name, ["revoke_planned_slice_worker_key", "inputSchema"])

    assert cleanup_schema["required"] == ["work_request_id", "planned_slice_id", "outcome", "reason"]
    assert get_in(cleanup_schema, ["properties", "outcome", "enum"]) == ["superseded", "abandoned"]
    assert get_in(cleanup_schema, ["properties", "reason", "description"]) =~ "audit reason"

    assert delivery_schema["required"] == ["work_request_id", "planned_slice_id", "outcome", "idempotency_key", "evidence"]
    assert get_in(delivery_schema, ["properties", "outcome", "enum"]) == ["pr_merged", "completed_no_pr", "superseded", "abandoned"]
    assert get_in(delivery_schema, ["properties", "idempotency_key", "description"]) =~ "Reusing the same key"
    refute Map.has_key?(delivery_schema["properties"], "merge_commit_sha")
    assert get_in(delivery_schema, ["properties", "evidence", "properties", "pr_merged", "properties", "merge_commit_sha", "description"]) =~ "strong evidence"

    assert get_in(delivery_schema, ["properties", "evidence", "oneOf"]) == [
             %{"required" => ["pr_merged"]},
             %{"required" => ["completed_no_pr"]},
             %{"required" => ["superseded"]},
             %{"required" => ["abandoned"]}
           ]

    assert revoke_schema["required"] == ["work_request_id", "planned_slice_id", "grant_id", "reason"]
    assert get_in(revoke_schema, ["properties", "grant_id", "description"]) =~ "Raw worker secrets are never accepted or returned"

    assert get_in(tools_by_name, ["set_work_request_status", "inputSchema", "required"]) == ["work_request_id", "current_status", "next_status"]
    assert get_in(tools_by_name, ["ask_question", "inputSchema", "required"]) == ["work_request_id", "category", "question", "why_needed"]
    assert get_in(tools_by_name, ["ask_question", "inputSchema", "properties", "decision_prompt", "required"]) == ["tl_dr", "details", "options"]

    assert get_in(tools_by_name, ["answer_question", "inputSchema", "required"]) == [
             "work_request_id",
             "question_id",
             "answer"
           ]

    assert get_in(tools_by_name, ["answer_question", "inputSchema", "properties", "answered_by", "type"]) == "string"
    assert get_in(tools_by_name, ["answer_question", "inputSchema", "properties", "current_status", "description"]) =~ "Deprecated alias"
    assert get_in(tools_by_name, ["escalate_guidance_request", "inputSchema", "properties", "decision_prompt", "required"]) == ["tl_dr", "details", "options"]
    assert get_in(tools_by_name, ["close_question", "inputSchema", "required"]) == ["work_request_id", "question_id"]

    assert get_in(tools_by_name, ["answer_question_and_record_decision", "inputSchema", "required"]) == [
             "work_request_id",
             "question_id",
             "answer",
             "source_type",
             "decision",
             "rationale",
             "scope_impact"
           ]

    assert get_in(tools_by_name, ["record_decision", "inputSchema", "required"]) == [
             "work_request_id",
             "source_type",
             "decision",
             "rationale",
             "scope_impact",
             "created_by"
           ]

    assert get_in(tools_by_name, ["record_decision", "inputSchema", "properties", "source_id", "type"]) == "string"
    assert get_in(tools_by_name, ["record_decision", "inputSchema", "properties", "source_type", "enum"]) == DecisionLogEntry.source_types()

    assert get_in(tools_by_name, ["plan_slice", "inputSchema", "required"]) == [
             "work_request_id",
             "title",
             "goal",
             "owned_file_globs",
             "acceptance_criteria",
             "validation_steps",
             "stop_conditions"
           ]

    assert get_in(tools_by_name, ["plan_slice", "inputSchema", "properties", "review_lanes", "items", "enum"]) == [
             "fast",
             "normal",
             "deep"
           ]

    assert get_in(tools_by_name, ["plan_slice", "inputSchema", "properties", "work_request_id", "description"]) =~
             "Required WorkRequest id"

    assert get_in(tools_by_name, ["plan_slice", "inputSchema", "properties", "owned_file_globs", "type"]) == "array"

    assert get_in(tools_by_name, ["plan_slice", "inputSchema", "properties", "owned_file_globs", "description"]) =~
             "`**` must be a complete path segment"

    planned_slice_kinds = get_in(tools_by_name, ["plan_slice", "inputSchema", "properties", "work_package_kind", "enum"])
    assert planned_slice_kinds == WorkPackage.planned_slice_kinds()
    assert "standard_pr" in planned_slice_kinds
    assert "docs" in planned_slice_kinds

    refute Map.has_key?(get_in(tools_by_name, ["plan_slice", "inputSchema", "properties", "forbidden_file_globs"]), "minItems")
    assert get_in(tools_by_name, ["plan_slice", "inputSchema", "properties", "branch_pattern", "type"]) == "string"

    assert get_in(tools_by_name, ["approve_slice", "inputSchema", "required"]) == [
             "work_request_id",
             "planned_slice_id",
             "current_status"
           ]

    assert get_in(tools_by_name, ["skip_slice", "inputSchema", "required"]) == [
             "work_request_id",
             "planned_slice_id",
             "current_status"
           ]

    assert get_in(tools_by_name, ["finish_slicing", "inputSchema", "required"]) == ["work_request_id", "current_status"]

    assert get_in(tools_by_name, ["dispatch_slice", "inputSchema", "required"]) == [
             "work_request_id",
             "planned_slice_id"
           ]

    dispatch_properties = get_in(tools_by_name, ["dispatch_slice", "inputSchema", "properties"])
    assert get_in(dispatch_properties, ["claimed_by", "type"]) == "string"
    refute Map.has_key?(dispatch_properties, "secret_handoff")
    refute Map.has_key?(dispatch_properties, "secret_store_dir")
    refute Map.has_key?(dispatch_properties, "legacy_private_handoff")
    refute Map.has_key?(dispatch_properties, "symphony_repo_root")
    refute Map.has_key?(dispatch_properties, "repo_root")

    assert get_in(tools_by_name, ["prepare_work_package_worktree", "inputSchema", "required"]) == [
             "work_package_id"
           ]

    assert get_in(tools_by_name, ["prepare_work_package_worktree", "inputSchema", "properties", "target_repo_root", "description"]) =~
             "target product repository root"

    assert get_in(tools_by_name, ["prepare_work_package_worktree", "inputSchema", "properties", "branch", "description"]) =~
             "Optional branch override"

    assert get_in(tools_by_name, ["cleanup_work_package_worktree", "inputSchema", "required"]) == [
             "work_package_id"
           ]

    assert get_in(tools_by_name, ["cleanup_work_package_worktree", "inputSchema", "properties", "target_repo_root", "description"]) =~
             "Optional target product repository root"

    assert get_in(tools_by_name, ["read_child_status", "inputSchema", "required"]) == ["work_package_id"]
    assert get_in(tools_by_name, ["read_child_status", "inputSchema", "properties", "work_package_id", "type"]) == "string"
    assert get_in(tools_by_name, ["read_phase_board", "inputSchema", "required"]) == ["phase_id"]
    assert get_in(tools_by_name, ["approve_scope_expansion", "inputSchema", "required"]) == ["work_package_id", "allowed_file_globs", "rationale"]
    assert get_in(tools_by_name, ["approve_scope_expansion", "inputSchema", "properties", "allowed_file_globs", "minItems"]) == 1
    assert get_in(tools_by_name, ["approve_child_ready_state", "inputSchema", "required"]) == ["work_package_id", "rationale"]
    assert get_in(tools_by_name, ["approve_child_ready_state", "inputSchema", "properties", "request_id", "type"]) == "string"
    assert get_in(tools_by_name, ["mint_child_worker_key", "inputSchema", "required"]) == ["work_package_id"]
    assert get_in(tools_by_name, ["mint_child_worker_key", "inputSchema", "properties", "template", "type"]) == "object"
    assert get_in(tools_by_name, ["revoke_child_worker_key", "inputSchema", "required"]) == ["grant_id", "reason"]
    assert get_in(tools_by_name, ["revoke_child_worker_key", "inputSchema", "properties", "grant_id", "type"]) == "string"
    assert get_in(tools_by_name, ["merge_child_into_phase", "inputSchema", "required"]) == ["work_package_id", "merge_artifact"]
    assert get_in(tools_by_name, ["merge_child_into_phase", "inputSchema", "properties", "merge_artifact", "required"]) == ["status", "uri"]
  end

  test "tools list advertises planned-slice dispatch even when repo_root is not configured", %{repo: repo} do
    {_anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-DISPATCH-TOOLS-NO-ROOT", [
        "read:work_request",
        "write:work_request",
        "dispatch:work_request",
        "read:phase"
      ])

    server = Server.new(Config.default(repo: repo), initialized: true, session: session)

    response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "architect-tools-no-root", "method" => "tools/list", "params" => %{}}, server)

    tools_by_name =
      response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(tools_by_name, "list_work_requests")
    assert Map.has_key?(tools_by_name, "plan_slice")
    assert Map.has_key?(tools_by_name, "dispatch_slice")
  end

  test "tools list advertises planned-slice dispatch when the ledger cannot be handed off", %{repo: repo} do
    {_anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-DISPATCH-TOOLS-MEMORY-DB", [
        "read:work_request",
        "write:work_request",
        "dispatch:work_request",
        "read:phase"
      ])

    server = Server.new(Config.default(repo: repo, repo_root: test_repo_root(), database: ":memory:"), initialized: true, session: session)

    response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "architect-tools-memory-db", "method" => "tools/list", "params" => %{}}, server)

    tools_by_name =
      response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(tools_by_name, "list_work_requests")
    assert Map.has_key?(tools_by_name, "plan_slice")
    assert Map.has_key?(tools_by_name, "dispatch_slice")
  end

  test "tools list cannot receive legacy WorkRequest architect sessions from grant creation", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-WR-TOOLS-LEGACY", kind: "mcp"))

    assert {:error, %Ecto.Changeset{} = changeset} =
             create_architect_work_key(repo, package.id, ["read:work_request", "write:work_request"])

    assert {"architect phase-scoped grants require phase scope", []} in Keyword.get_values(changeset.errors, :phase_id)
  end

  test "tools list keeps static architect schemas when phase scope snapshot is missing", %{repo: repo} do
    {_anchor, session, grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-TOOLS-MISSING-SCOPE", [
        "read:work_request",
        "write:work_request"
      ])

    repo.update_all(
      from(access_grant in AccessGrant, where: access_grant.id == ^grant.id),
      set: [scope_base_branch: nil]
    )

    server = Server.new(Config.default(repo: repo), initialized: true, session: session)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "missing-scope-architect-tools", "method" => "tools/list", "params" => %{}}, server)
    tools_by_name = response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    for tool <- @architect_tool_names do
      assert Map.has_key?(tools_by_name, tool)
    end
  end

  test "tools list keeps static architect schemas when phase anchor no longer matches frozen scope", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-TOOLS-DRIFTED-ANCHOR", [
        "read:work_request",
        "write:work_request"
      ])

    assert {:ok, _anchor} = WorkPackageRepository.update(repo, anchor.id, %{repo: "nextide/other"})

    server = Server.new(Config.default(repo: repo), initialized: true, session: session)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "drifted-anchor-architect-tools", "method" => "tools/list", "params" => %{}}, server)
    tools_by_name = response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(tools_by_name, "sympp.health")
    assert Map.has_key?(tools_by_name, "get_current_assignment")

    for tool <- @architect_tool_names do
      assert Map.has_key?(tools_by_name, tool)
    end
  end

  test "tools list exposes only claim refresh for stale architect sessions after grant revocation", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-TOOLS-REVOKED", kind: "mcp"))
    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["read:phase"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))
    server = Server.new(Config.default(repo: repo), initialized: true, session: session)

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, architect_assignment.grant_id)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "revoked-architect-tools", "method" => "tools/list", "params" => %{}}, server)
    tools_by_name = response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    assert Map.keys(tools_by_name) |> Enum.sort() == ["claim_local_architect_assignment", "claim_local_assignment", "sympp.health"]
  end

  test "tools list preserves ledger failures while revalidating bound sessions" do
    session =
      Session.new(%Assignment{
        grant_id: "grant-1",
        work_package_id: "SYMPP-LEDGER-TOOLS-LIST",
        display_key: "ABCD",
        grant_role: "architect",
        capabilities: ["read:phase"],
        claimed_at: DateTime.utc_now(:microsecond),
        claimed_by: "architect-1"
      })

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "tools-list-ledger-failure", "method" => "tools/list", "params" => %{}},
        config: Config.default(repo: FailingAuthRepo),
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_000
    assert get_in(response, ["error", "data", "reason"]) == "ledger_unavailable"
  end

  test "tools list keeps static architect schemas while calls use live capabilities", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-LIVE-CAPABILITY-LIST", kind: "mcp"))

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["read:phase"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(%{architect_assignment | capabilities: []}, proof_hash: WorkKey.secret_hash(architect_work_key.secret))
    server = Server.new(Config.default(repo: repo), initialized: true, session: session)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "live-capability-architect-tools", "method" => "tools/list", "params" => %{}}, server)
    tools_by_name = response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(tools_by_name, "get_current_assignment")
    assert Map.has_key?(tools_by_name, "sympp.health")

    for tool <- @architect_tool_names do
      assert Map.has_key?(tools_by_name, tool)
    end

    denied_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "lifecycle-only-read-work-request",
          "method" => "tools/call",
          "params" => %{"name" => "list_work_requests", "arguments" => %{}}
        },
        server
      )

    assert get_in(denied_response, ["error", "code"]) == -32_003
    assert get_in(denied_response, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(denied_response, ["error", "data", "reason_code"]) == "insufficient_capability"
  end

  test "architect tools reject arguments outside their advertised schemas", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-STRICT", kind: "mcp"))
    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["read:child_progress", "read:child_findings"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "strict-architect-args",
          "method" => "tools/call",
          "params" => %{"name" => "read_child_status", "arguments" => %{"work_package_id" => package.id, "unexpected" => "value"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(response, ["error", "data", "arguments"]) == ["unexpected"]
  end

  defp claim_local_bound_assignment!(repo, id) do
    package = create_local_claim_package!(repo, id, base_branch: "main")

    work_request =
      create_work_request!(repo,
        id: "WR-#{id}",
        repo: package.repo,
        base_branch: package.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-#{id}",
                 target_base_branch: package.base_branch,
                 branch_pattern: package.branch_pattern
               )
             )

    repo.update!(Ecto.Changeset.change(planned_slice, status: "dispatched", work_package_id: package.id))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-#{id}",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => local_assignment_claim_args(package, %{"work_request_id" => work_request.id})
          }
        },
        local_mcp_server(local_mcp_config(repo), "state-#{id}")
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    refute inspect(claim_response) =~ minted.work_key.secret
    {package, work_request, minted, claim_response, claimed_server}
  end
end
