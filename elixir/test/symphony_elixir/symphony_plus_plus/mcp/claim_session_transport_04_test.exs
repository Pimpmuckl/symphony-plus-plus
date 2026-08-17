Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionTransport04Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{HTTPStateStore, HTTPTransport, Session, SessionBindingTools}

  defmodule BusyAssignmentIntrospectionRepo do
    def get(schema, id), do: delegate().get(schema, id)
    def all(query), do: delegate().all(query)
    def one(_query), do: raise(%Exqlite.Error{message: "database is locked"})
    defp delegate, do: Process.get({__MODULE__, :delegate})
  end

  defmodule BusyScopeAssignmentIntrospectionRepo do
    def get(schema, id), do: delegate().get(schema, id)
    def one(query), do: delegate().one(query)
    def all(_query), do: raise(%Exqlite.Error{message: "database is locked"})
    defp delegate, do: Process.get({__MODULE__, :delegate})
  end

  test "response-only handle supports explicit state keys for recreated servers through local claim replay", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATELESS-HANDLE")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)
    state_key = make_ref()

    init_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    claim_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    reconnect_claim_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-again",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    assert get_in(init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    refute inspect(claim_response) =~ minted.work_key.secret
    assert get_in(assignment_response, ["result", "structuredContent", "assignment"]) == nil
    assert get_in(assignment_response, ["result", "structuredContent", "binding", "state"]) in ["unbound", "stale"]
    assert get_in(reconnect_claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
  end

  test "response-only handle supports explicit state keys across processes", %{repo: repo} do
    state_key = make_ref()

    init_response =
      Task.async(fn ->
        Server.handle(
          %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
          Server.new(Config.default(repo: repo), state_key: state_key)
        )
      end)
      |> Task.await()

    tools_response =
      Task.async(fn ->
        Server.handle(
          %{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}},
          Server.new(Config.default(repo: repo), state_key: state_key)
        )
      end)
      |> Task.await()

    assert get_in(init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert is_list(get_in(tools_response, ["result", "tools"]))
  end

  test "HTTP transport preserves distinct sessions across concurrent initialization", %{repo: repo} do
    config = local_mcp_config(repo)
    client_key = "concurrent-initialize-client"

    initialized =
      1..20
      |> Task.async_stream(
        fn index ->
          HTTPTransport.handle(
            config,
            %{"jsonrpc" => "2.0", "id" => "init-#{index}", "method" => "initialize", "params" => initialize_params()},
            client_key: client_key
          )
        end,
        max_concurrency: 20,
        ordered: true,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, {:ok, result}} -> result end)

    state_keys = Enum.map(initialized, & &1.state_key)
    assert length(Enum.uniq(state_keys)) == 20

    initialized
    |> Task.async_stream(
      fn init_result ->
        HTTPTransport.handle(
          config,
          %{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}},
          client_key: client_key,
          state_key: init_result.state_key
        )
      end,
      max_concurrency: 20,
      ordered: false,
      timeout: 30_000
    )
    |> Enum.each(fn {:ok, {:ok, result}} ->
      assert is_list(get_in(result.response, ["result", "tools"]))
    end)
  end

  test "response-only handle namespaces explicit state keys by config", %{repo: repo} do
    state_key = make_ref()

    init_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    other_repo_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}},
        Server.new(Config.default(repo: UnexpectedAuthRepo), state_key: state_key)
      )

    assert get_in(init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert get_in(other_repo_response, ["error", "data", "reason"]) == "server_not_initialized"
  end

  test "explicit state key stale live server keeps the configured catalog", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-STALE-LIVE")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    assert {:ok, comment} =
             CommentService.create(repo, %{
               "target_kind" => "work_package",
               "target_id" => package.id,
               "body" => "stale session local comment",
               "source_type" => "operator",
               "author_name" => "operator"
             })

    arguments = local_assignment_claim_args(package)
    state_key = make_ref()

    {_init_response, initialized_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    {_claim_response, claimed_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        initialized_server
      )

    reinit_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "init-again", "method" => "initialize", "params" => initialize_params()},
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    {tools_response, tools_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "tools-after-stale-reinit", "method" => "tools/list", "params" => %{}},
        claimed_server
      )

    tools_by_name = tools_response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    {stale_solo_response, _stale_solo_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "solo-after-stale-init", "method" => "tools/call", "params" => %{"name" => "solo_attach", "arguments" => %{}}},
        tools_server
      )

    {stale_list_comments_response, _stale_comments_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "list-comments-after-stale-init",
          "method" => "tools/call",
          "params" => %{"name" => "list_comments", "arguments" => %{"target_kind" => "work_package", "target_id" => package.id}}
        },
        tools_server
      )

    {fresh_init_response, fresh_initialized_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "fresh-init-after-stale", "method" => "initialize", "params" => initialize_params()},
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    {fresh_tools_response, _fresh_tools_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "tools-after-fresh-init", "method" => "tools/list", "params" => %{}},
        fresh_initialized_server
      )

    fresh_tools_by_name = fresh_tools_response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    assert get_in(reinit_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"

    assert tools_by_name == fresh_tools_by_name

    assert get_in(stale_solo_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(stale_solo_response, ["error", "data", "action"]) == "claim_local_assignment"
    assert [%{"id" => stale_comment_id}] = get_in(stale_list_comments_response, ["result", "structuredContent", "comments"])
    assert stale_comment_id == comment.id
    assert get_in(fresh_init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert Map.has_key?(tools_by_name, "get_current_assignment")
    assert Map.has_key?(fresh_tools_by_name, "read_work_request")
    assert Map.has_key?(fresh_tools_by_name, "claim_local_architect_assignment")
    assert Map.has_key?(fresh_tools_by_name, "solo_attach")
    assert Map.has_key?(fresh_tools_by_name, "get_current_assignment")
  end

  test "explicit state key duplicate initialize preserves active live session", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-LIVE-DUP")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    state_key = make_ref()

    {_init_response, initialized_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    {_claim_response, claimed_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        initialized_server
      )

    {duplicate_init_response, duplicate_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "init-again", "method" => "initialize", "params" => initialize_params()},
        claimed_server
      )

    {assignment_response, _server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "assignment-after-duplicate", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        duplicate_server
      )

    assert get_in(duplicate_init_response, ["error", "data", "reason"]) == "already_initialized"
    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
  end

  test "bound notification tool calls skip fresh and refresh aging current claim leases", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-NOTIFICATION-HEARTBEAT")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-notification-heartbeat",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "claim-notification-heartbeat-state")
      )

    assert {:ok, lease} = ClaimLeaseService.current_for_work_package(repo, package.id)

    {nil, fresh_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "params" => %{"name" => "get_current_assignment", "arguments" => %{}}
        },
        claimed_server
      )

    assert {:ok, unchanged_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert DateTime.compare(unchanged_lease.last_seen_at, lease.last_seen_at) == :eq

    old_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -4, :minute)
    lease |> ClaimLease.update_changeset(%{last_seen_at: old_seen_at}) |> repo.update!()

    {nil, notified_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "params" => %{"name" => "get_current_assignment", "arguments" => %{}}
        },
        fresh_server
      )

    assert notified_server.session.assignment.work_package_id == package.id
    assert {:ok, refreshed_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert DateTime.compare(refreshed_lease.last_seen_at, old_seen_at) == :gt
  end

  test "fresh claim worker calls stay within query and write budgets", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-QUERY-BUDGET")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-query-budget",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "claim-query-budget-state")
      )

    {{assignment_response, read_server}, read_queries} =
      capture_queries(repo, fn ->
        Server.handle_state(
          %{"jsonrpc" => "2.0", "id" => "read-query-budget", "method" => "tools/call", "params" => %{"name" => "get_current_assignment", "arguments" => %{}}},
          claimed_server
        )
      end)

    {{progress_response, _server}, write_queries} =
      capture_queries(repo, fn ->
        Server.handle_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "write-query-budget",
            "method" => "tools/call",
            "params" => %{
              "name" => "append_progress",
              "arguments" => %{"summary" => "Query budget write", "idempotency_key" => "query-budget-write"}
            }
          },
          read_server
        )
      end)

    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(progress_response, ["result", "structuredContent", "progress_event", "summary"]) == "Query budget write"
    assert length(read_queries) <= 9
    assert write_query_count(read_queries) == 0
    assert length(write_queries) <= 25
    assert write_query_count(write_queries) <= 4
  end

  test "batched bound tool calls preserve refreshed claim lease state", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-BATCH-HEARTBEAT")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-batch-heartbeat",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "claim-batch-heartbeat-state")
      )

    assert {:ok, lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    old_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -6, :minute)
    lease |> ClaimLease.update_changeset(%{last_seen_at: old_seen_at}) |> repo.update!()

    {responses, updated_server} =
      Server.handle_state(
        [
          %{
            "jsonrpc" => "2.0",
            "id" => "batch-assignment-heartbeat",
            "method" => "tools/call",
            "params" => %{"name" => "get_current_assignment", "arguments" => %{}}
          },
          %{
            "jsonrpc" => "2.0",
            "id" => "batch-assignment-after-heartbeat",
            "method" => "tools/call",
            "params" => %{"name" => "get_current_assignment", "arguments" => %{}}
          }
        ],
        claimed_server
      )

    assert [assignment_response, second_assignment_response] = responses
    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(second_assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert {:ok, refreshed_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert updated_server.session.claim_lease_id == refreshed_lease.id
    assert DateTime.compare(refreshed_lease.last_seen_at, old_seen_at) == :gt
  end

  test "bound worker tools reclaim old current claim leases before mutation", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-STALE-PREFLIGHT")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-stale-preflight",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "claim-stale-preflight-state")
      )

    assert {:ok, original_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    old_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -6, :minute)

    original_lease =
      original_lease
      |> ClaimLease.update_changeset(%{last_seen_at: old_seen_at, stale_after_ms: :timer.hours(24)})
      |> repo.update!()

    refute ClaimLease.stale?(original_lease, DateTime.utc_now(:microsecond))

    {progress_response, updated_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "append-after-stale-preflight",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_progress",
            "arguments" => %{
              "summary" => "Recorded after preflight reclaim",
              "status" => "in_progress",
              "idempotency_key" => "stale-preflight-progress"
            }
          }
        },
        claimed_server
      )

    assert get_in(progress_response, ["result", "structuredContent", "progress_event", "summary"]) == "Recorded after preflight reclaim"
    assert {:ok, refreshed_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert refreshed_lease.id != original_lease.id
    assert updated_server.session.claim_lease_id == refreshed_lease.id
    assert {:ok, [event]} = PlanningRepository.list_progress_events(repo, package.id)
    assert event.summary == "Recorded after preflight reclaim"
  end

  test "discovery-only requests do not refresh revoked session claim leases", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-DISCOVERY-NO-HEARTBEAT")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-discovery-no-heartbeat",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "claim-discovery-no-heartbeat-state")
      )

    assert {:ok, lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    old_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -4, :minute)
    lease |> ClaimLease.update_changeset(%{last_seen_at: old_seen_at}) |> repo.update!()
    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)

    {tools_response, _tools_server} =
      Server.handle_state(
        %{"jsonrpc" => "2.0", "id" => "tools-after-revoke", "method" => "tools/list", "params" => %{}},
        claimed_server
      )

    assert is_list(get_in(tools_response, ["result", "tools"]))
    assert {:ok, unchanged_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert DateTime.compare(unchanged_lease.last_seen_at, old_seen_at) == :eq
  end

  test "bound worker tools do not refresh revoked session claim leases", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-REVOKED-NO-HEARTBEAT")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-revoked-no-heartbeat",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "claim-revoked-no-heartbeat-state")
      )

    assert {:ok, lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    old_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -4, :minute)
    lease |> ClaimLease.update_changeset(%{last_seen_at: old_seen_at}) |> repo.update!()
    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)

    {blocked_response, updated_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "append-after-revoked-grant",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"summary" => "This should not be recorded", "status" => "in_progress"}}
        },
        claimed_server
      )

    assert get_in(blocked_response, ["error", "data", "reason"]) == "revoked"
    assert get_in(blocked_response, ["error", "data", "claim_lease_reason"]) == "revoked"
    assert updated_server.session == nil
    assert {:ok, unchanged_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert DateTime.compare(unchanged_lease.last_seen_at, old_seen_at) == :eq
    assert {:ok, []} = PlanningRepository.list_progress_events(repo, package.id)
  end

  test "bound worker tools do not refresh claim leases for tampered session proofs", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-BAD-PROOF-NO-HEARTBEAT")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-bad-proof-no-heartbeat",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "claim-bad-proof-no-heartbeat-state")
      )

    assert {:ok, lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    old_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -4, :minute)
    lease |> ClaimLease.update_changeset(%{last_seen_at: old_seen_at}) |> repo.update!()
    tampered_server = %{claimed_server | session: %{claimed_server.session | proof_hash: "bad-proof"}}

    {blocked_response, updated_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "append-after-bad-proof",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"summary" => "This should not be recorded", "status" => "in_progress"}}
        },
        tampered_server
      )

    assert get_in(blocked_response, ["error", "data", "reason"]) == "claim_lease_lost"
    assert get_in(blocked_response, ["error", "data", "claim_lease_reason"]) == "invalid_session_proof"
    assert updated_server.session == nil
    assert {:ok, unchanged_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert DateTime.compare(unchanged_lease.last_seen_at, old_seen_at) == :eq
    assert {:ok, []} = PlanningRepository.list_progress_events(repo, package.id)
  end

  test "bound worker tools stop before mutation when the current claim lease is paused", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-PAUSED-PREFLIGHT")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-paused-preflight",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "claim-paused-preflight-state")
      )

    assert {:ok, lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert {:ok, _paused_lease} = ClaimLeaseService.pause(repo, lease.id, %{"actor_id" => "operator"}, reason: "operator pause")

    {blocked_response, updated_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "append-after-pause",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"summary" => "This should not be recorded", "status" => "in_progress"}}
        },
        claimed_server
      )

    assert get_in(blocked_response, ["error", "data", "reason"]) == "claim_lease_lost"
    assert get_in(blocked_response, ["error", "data", "claim_lease_reason"]) == "claim_lease_paused"
    assert updated_server.session == nil
    assert updated_server.session_refresh_required == true
    assert updated_server.stale_assignment_role == "worker"

    {stale_tools, _relisted_server} =
      Server.handle_state(
        %{"jsonrpc" => "2.0", "id" => "tools-after-pause", "method" => "tools/list", "params" => %{}},
        updated_server
      )

    stale_tool_names = stale_tools |> get_in(["result", "tools"]) |> Enum.map(& &1["name"])
    assert "get_current_assignment" in stale_tool_names
    assert "claim_local_assignment" in stale_tool_names
    assert "claim_local_architect_assignment" in stale_tool_names
    assert "append_progress" in stale_tool_names
    assert {:ok, []} = PlanningRepository.list_progress_events(repo, package.id)
  end

  test "bound worker tools fail closed when current claim lease lookup fails", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-PREFLIGHT-LEDGER-FAIL")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-preflight-ledger-fail",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "claim-preflight-ledger-fail-state")
      )

    failed_server = %{claimed_server | config: local_mcp_config(FailingAuthRepo)}

    {blocked_response, updated_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "append-after-lease-lookup-failure",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"summary" => "This should not be recorded", "status" => "in_progress"}}
        },
        failed_server
      )

    assert get_in(blocked_response, ["error", "data", "reason"]) == "claim_lease_lost"
    assert get_in(blocked_response, ["error", "data", "claim_lease_reason"]) == "claim_lease_check_failed"
    assert updated_server.session == nil
    assert updated_server.session_refresh_required == true
    assert {:ok, []} = PlanningRepository.list_progress_events(repo, package.id)
  end

  test "assignment introspection preserves the binding when claim lease lookup returns database busy", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-ASSIGNMENT-LEDGER-FAIL")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-assignment-ledger-fail",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "claim-assignment-ledger-fail-state")
      )

    Process.put({BusyAssignmentIntrospectionRepo, :delegate}, repo)
    on_exit(fn -> Process.delete({BusyAssignmentIntrospectionRepo, :delegate}) end)
    failed_server = %{claimed_server | config: local_mcp_config(BusyAssignmentIntrospectionRepo)}

    {response, updated_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "get-assignment-ledger-fail",
          "method" => "tools/call",
          "params" => %{"name" => "get_current_assignment", "arguments" => %{}}
        },
        failed_server
      )

    assert get_in(response, ["error", "code"]) == -32_000
    assert get_in(response, ["error", "data", "reason"]) == "ledger_unavailable"
    assert updated_server.session == failed_server.session
    assert updated_server.session_refresh_required == false
    assert updated_server.stale_assignment_role == nil
  end

  test "assignment introspection preserves the binding when grant scope lookup returns database busy", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-ASSIGNMENT-SCOPE-FAIL")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-assignment-scope-fail",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "claim-assignment-scope-fail-state")
      )

    Process.put({BusyScopeAssignmentIntrospectionRepo, :delegate}, repo)
    on_exit(fn -> Process.delete({BusyScopeAssignmentIntrospectionRepo, :delegate}) end)
    failed_server = %{claimed_server | config: local_mcp_config(BusyScopeAssignmentIntrospectionRepo)}

    assert {:error, {:scope_lookup_failed, :database_busy}} = SessionBindingTools.get_current_assignment(failed_server)
    assert failed_server.session == claimed_server.session
    assert failed_server.session_refresh_required == false
  end

  test "tools list stays available when claim lease storage fails", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-LIST-LEDGER-FAIL")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-list-ledger-fail",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "claim-list-ledger-fail-state")
      )

    Process.put({BusyAssignmentIntrospectionRepo, :delegate}, repo)
    on_exit(fn -> Process.delete({BusyAssignmentIntrospectionRepo, :delegate}) end)
    failed_server = %{claimed_server | config: local_mcp_config(BusyAssignmentIntrospectionRepo)}

    {response, updated_server} =
      Server.handle_state(
        %{"jsonrpc" => "2.0", "id" => "list-ledger-fail", "method" => "tools/list", "params" => %{}},
        failed_server
      )

    assert is_list(get_in(response, ["result", "tools"]))
    assert updated_server.session == failed_server.session
    assert updated_server.session_refresh_required == false
  end

  test "HTTP local assignment release clears the current claim lease", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-HTTP-LOCAL-RELEASE")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    config = local_mcp_config(repo)
    client_key = "client-http-local-release"

    {:ok, init_result} =
      HTTPTransport.handle(config, %{"jsonrpc" => "2.0", "id" => "init-local-release", "method" => "initialize", "params" => initialize_params()}, client_key: client_key)

    {:ok, claim_result} =
      HTTPTransport.handle(
        config,
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-local-release",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert get_in(claim_result.response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert {:ok, %ClaimLease{id: lease_id, actor_id: "local:" <> _hash}} = ClaimLeaseService.current_for_work_package(repo, package.id)

    {:ok, release_result} =
      HTTPTransport.handle(
        config,
        %{
          "jsonrpc" => "2.0",
          "id" => "release-live-local",
          "method" => "tools/call",
          "params" => %{"name" => "release_current_assignment", "arguments" => %{"reason" => "done"}}
        },
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert get_in(release_result.response, ["result", "structuredContent", "binding_cleared"]) == true
    assert get_in(release_result.response, ["result", "structuredContent", "claim_lease_release", "claim_lease_id"]) == lease_id
    release_text = assert_toon_tool_text!(release_result.response)
    assert release_text =~ "status: ok"
    assert release_text =~ "binding_cleared: true"
    refute release_text =~ "claim_lease_id"
    refute release_text =~ "grant_id"
    refute release_text =~ "caller_id"
    assert {:error, :not_found} = ClaimLeaseService.current_for_work_package(repo, package.id)

    {:ok, second_release_result} =
      HTTPTransport.handle(
        config,
        %{
          "jsonrpc" => "2.0",
          "id" => "release-already-clear-local",
          "method" => "tools/call",
          "params" => %{"name" => "release_current_assignment", "arguments" => %{"reason" => "already done"}}
        },
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert get_in(second_release_result.response, ["result", "structuredContent", "status"]) == "ok"
    assert get_in(second_release_result.response, ["result", "structuredContent", "binding_cleared"]) == true
    assert get_in(second_release_result.response, ["result", "structuredContent", "claim_lease_release", "reason"]) == "not_bound"
  end

  test "release_current_assignment clears stale or mismatched claim bindings idempotently", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-HTTP-LOCAL-RELEASE-MISMATCH")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-release-mismatch",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "claim-release-mismatch-state")
      )

    assert {:ok, original_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)

    original_lease
    |> ClaimLease.update_changeset(%{last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -6, :minute)})
    |> repo.update!()

    assert {:ok, replacement_lease} =
             ClaimLeaseService.reclaim_stale(
               repo,
               package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:replacement", "actor_display_name" => "replacement"},
               reason: "test replacement",
               stale_after_ms: :timer.minutes(5)
             )

    assert replacement_lease.previous_claim_id == original_lease.id

    {release_response, released_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "release-mismatched-binding",
          "method" => "tools/call",
          "params" => %{"name" => "release_current_assignment", "arguments" => %{"reason" => "stale local session"}}
        },
        claimed_server
      )

    assert get_in(release_response, ["result", "structuredContent", "status"]) == "ok"
    assert get_in(release_response, ["result", "structuredContent", "binding_cleared"]) == true
    assert get_in(release_response, ["result", "structuredContent", "claim_lease_release", "reason"]) == "claim_lease_mismatch"
    assert released_server.session == nil
    assert_toon_tool_text!(release_response)
  end

  test "bound worker tools stop before mutation after another actor reclaims the lease", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-RECLAIMED-BLOCKS-OLD-SESSION")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-reclaimed-blocks-old-session",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(%{local_mcp_config(repo) | surface_profile: :worker}, "claim-reclaimed-blocks-old-session-state")
      )

    assert {:ok, original_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    original_lease |> ClaimLease.update_changeset(%{last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -6, :minute)}) |> repo.update!()

    assert {:ok, replacement_lease} =
             ClaimLeaseService.reclaim_stale(
               repo,
               package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:replacement", "actor_display_name" => "replacement"},
               reason: "test replacement",
               stale_after_ms: :timer.minutes(5)
             )

    assert replacement_lease.previous_claim_id == original_lease.id

    {introspection_response, stale_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "introspect-after-reclaim",
          "method" => "tools/call",
          "params" => %{"name" => "get_current_assignment", "arguments" => %{}}
        },
        claimed_server
      )

    assert get_in(introspection_response, ["result", "structuredContent", "assignment"]) == nil
    assert get_in(introspection_response, ["result", "structuredContent", "binding", "state"]) == "stale"
    assert get_in(introspection_response, ["result", "structuredContent", "next_action"]) == "reclaim_assignment"
    assert get_in(introspection_response, ["result", "structuredContent", "recovery", "tools"]) == ["claim_local_assignment"]
    assert stale_server.session == nil
    assert stale_server.session_refresh_required == true

    {stale_tools_response, _stale_server} =
      Server.handle_state(
        %{"jsonrpc" => "2.0", "id" => "tools-after-reclaim", "method" => "tools/list", "params" => %{}},
        stale_server
      )

    stale_tool_names = stale_tools_response |> get_in(["result", "tools"]) |> Enum.map(& &1["name"])
    assert "get_current_assignment" in stale_tool_names
    assert "claim_local_assignment" in stale_tool_names
    assert "read_context" in stale_tool_names

    {blocked_response, blocked_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "append-after-reclaim",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_progress",
            "arguments" => %{"summary" => "This should not be recorded", "status" => "in_progress"}
          }
        },
        claimed_server
      )

    assert get_in(blocked_response, ["error", "data", "reason"]) == "claim_lease_lost"
    assert get_in(blocked_response, ["error", "data", "claim_lease_reason"]) == "claim_lease_mismatch"
    assert blocked_server.session == nil
    assert {:ok, []} = PlanningRepository.list_progress_events(repo, package.id)
  end

  test "batched bound worker tools preserve lost-lease cleanup state", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-BATCH-RECLAIMED-BLOCKS")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-batch-reclaimed-blocks",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "claim-batch-reclaimed-blocks-state")
      )

    assert {:ok, original_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    original_lease |> ClaimLease.update_changeset(%{last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -6, :minute)}) |> repo.update!()

    assert {:ok, _replacement_lease} =
             ClaimLeaseService.reclaim_stale(
               repo,
               package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:replacement", "actor_display_name" => "replacement"},
               reason: "test replacement",
               stale_after_ms: :timer.minutes(5)
             )

    {responses, updated_server} =
      Server.handle_state(
        [
          %{
            "jsonrpc" => "2.0",
            "id" => "batch-append-after-reclaim",
            "method" => "tools/call",
            "params" => %{
              "name" => "append_progress",
              "arguments" => %{"summary" => "This should not be recorded", "status" => "in_progress"}
            }
          },
          %{
            "jsonrpc" => "2.0",
            "id" => "batch-tools-after-reclaim",
            "method" => "tools/list",
            "params" => %{}
          }
        ],
        claimed_server
      )

    assert [blocked_response, tools_response] = responses
    assert get_in(blocked_response, ["error", "data", "reason"]) == "claim_lease_lost"
    assert is_list(get_in(tools_response, ["result", "tools"]))
    assert updated_server.session == nil
    assert updated_server.session_refresh_required == true
    assert {:ok, []} = PlanningRepository.list_progress_events(repo, package.id)
  end

  test "HTTP local assignment recovery rehydrates a worker session", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-HTTP-LOCAL-RECOVERY")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    config = local_mcp_config(repo)
    client_key = "client-http-local-recovery"

    {:ok, init_result} =
      HTTPTransport.handle(config, %{"jsonrpc" => "2.0", "id" => "init-local-recovery", "method" => "initialize", "params" => initialize_params()}, client_key: client_key)

    {:ok, claim_result} =
      HTTPTransport.handle(
        config,
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-local-recovery",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert get_in(claim_result.response, ["result", "structuredContent", "assignment", "grant_id"]) == minted.grant.id

    HTTPStateStore.reset!()

    {:ok, assignment_result} =
      HTTPTransport.handle(
        config,
        %{"jsonrpc" => "2.0", "id" => "assignment-after-reset", "method" => "tools/call", "params" => %{"name" => "get_current_assignment", "arguments" => %{}}},
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert get_in(assignment_result.response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert %Server{session: %Session{assignment: %{work_package_id: package_id}}} = HTTPStateStore.get(config, client_key, init_result.state_key)
    assert package_id == package.id
  end

  defp capture_queries(repo, fun) do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    event = repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, test_pid -> send(test_pid, {handler_id, to_string(metadata.query || "")}) end,
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

  defp write_query_count(queries), do: Enum.count(queries, &Regex.match?(~r/^\s*(INSERT|UPDATE|DELETE|REPLACE)\b/i, &1))
end
