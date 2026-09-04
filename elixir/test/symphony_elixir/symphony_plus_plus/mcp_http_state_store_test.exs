defmodule SymphonyElixir.SymphonyPlusPlus.MCPHTTPStateStoreTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, HTTPStateStore, LedgerNamespace, Server, Session}
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.WorkPackageFactory

  @current_state_key "__sympp_mcp_current_state__"
  @unbound_client_key "__sympp_mcp_unbound__"
  @failing_dynamic_repo_key :sympp_mcp_http_state_store_test_dynamic_repo

  defmodule FailingDynamicRepo do
    def get_dynamic_repo, do: Process.get(:sympp_mcp_http_state_store_test_dynamic_repo)
    def database_key(database), do: database
  end

  setup_all do
    if Process.whereis(HTTPStateStore) == nil, do: start_supervised!(HTTPStateStore)
    :ok
  end

  setup do
    HTTPStateStore.reset!()
    :ok
  end

  test "state entries are scoped by client and configured ledger" do
    config = config("ledger-a")
    other_ledger_config = config("ledger-b")
    server = initialized_server(config, "shared-state")

    assert :ok = HTTPStateStore.put(config, "client-a", "shared-state", server)

    assert %Server{initialized: true} = HTTPStateStore.get(config, "client-a", "shared-state")
    assert HTTPStateStore.get(config, "client-b", "shared-state") == nil
    assert HTTPStateStore.get(other_ledger_config, "client-a", "shared-state") == nil
  end

  test "configured ledger scopes state even when the repo has a live database path" do
    database = WorkPackageFactory.database_path()
    original_repo = Repo.get_dynamic_repo()

    {:ok, pid} =
      Repo.start_link(database: database, name: Repo.process_name(database), pool_size: 1, log: false)

    try do
      Repo.put_dynamic_repo(pid)
      config = config("configured-ledger-a")
      other_config = config("configured-ledger-b")

      assert :ok = HTTPStateStore.put(config, "client", "same-state", initialized_server(config, "same-state"))
      assert HTTPStateStore.get(other_config, "client", "same-state") == nil
    after
      Repo.put_dynamic_repo(original_repo)
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm(database)
    end
  end

  test "recovery deadlines are throttled and scoped by ledger" do
    config = config("deadline-ledger-a")
    other_config = config("deadline-ledger-b")

    assert HTTPStateStore.recovery_persistence_due?(config, "binding", 60_000)
    assert :ok = HTTPStateStore.persist_recovery_if_due(config, "binding", 60_000, fn -> :ok end)
    refute HTTPStateStore.recovery_persistence_due?(config, "binding", 60_000)
    assert HTTPStateStore.recovery_persistence_due?(other_config, "binding", 60_000)

    assert HTTPStateStore.recovery_cleanup_due?(config, 60_000)
    assert :ok = HTTPStateStore.cleanup_recovery_if_due(config, 60_000, fn -> :ok end)
    refute HTTPStateStore.recovery_cleanup_due?(config, 60_000)
    assert HTTPStateStore.recovery_cleanup_due?(other_config, 60_000)

    assert :ok = HTTPStateStore.persist_recovery_if_due(config, "retry-binding", 60_000, fn -> {:error, :busy} end)
    assert HTTPStateStore.recovery_persistence_due?(config, "retry-binding", 60_000)

    assert_raise RuntimeError, fn ->
      HTTPStateStore.persist_recovery_if_due(config, "raised-binding", 60_000, fn -> raise "busy" end)
    end

    assert HTTPStateStore.recovery_persistence_due?(config, "raised-binding", 60_000)

    assert :ok = HTTPStateStore.defer_recovery_persistence(config, "deferred-binding", 60_000)
    refute HTTPStateStore.recovery_persistence_due?(config, "deferred-binding", 60_000)
  end

  test "unconfigured ledger fallback preserves dynamic repo isolation" do
    config = Config.default(mode: :http, repo: FailingDynamicRepo)

    try do
      Process.put(@failing_dynamic_repo_key, :ledger_a)
      assert :ok = HTTPStateStore.put(config, "client", "same-state", initialized_server(config, "same-state"))

      Process.put(@failing_dynamic_repo_key, :ledger_b)
      assert HTTPStateStore.get(config, "client", "same-state") == nil
    after
      Process.delete(@failing_dynamic_repo_key)
    end
  end

  test "state key continuity does not recover claimed state for another client" do
    config = config("non-bearer-state-key")
    claimed_server = initialized_server(config, "shared-state", session: worker_session())

    assert :ok = HTTPStateStore.put(config, "bound-client", "shared-state", claimed_server)

    assert %Server{session: %Session{}} = HTTPStateStore.get(config, "bound-client", "shared-state")
    assert HTTPStateStore.get(config, @unbound_client_key, "shared-state") == nil
    assert HTTPStateStore.get(config, "other-client", "shared-state") == nil
  end

  test "uninitialized update results are not persisted" do
    config = config("pre-initialize-error")

    assert {:server_not_initialized, :skipped} =
             HTTPStateStore.update_with_status(
               config,
               "client",
               "random-state",
               fn ->
                 Server.new(config, state_key: "random-state")
               end,
               fn server ->
                 {:server_not_initialized, server}
               end
             )

    assert HTTPStateStore.get(config, "client", "random-state") == nil
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "stale state requests cannot republish a superseded current alias" do
    config = config("stale-alias-publish")
    old_server = initialized_server(config, "old-state")
    new_server = initialized_server(config, "new-state")

    assert :ok = HTTPStateStore.put(config, "client", "old-state", old_server)
    assert HTTPStateStore.publish_alias(config, "client", "old-state", "client", @current_state_key, old_server)

    assert :ok = HTTPStateStore.put(config, "client", "new-state", new_server)
    assert HTTPStateStore.supersede_alias(config, "client", "new-state", "client", @current_state_key, new_server)

    refute HTTPStateStore.publish_alias(config, "client", "old-state", "client", @current_state_key, old_server)
    assert %Server{state_key: "new-state"} = HTTPStateStore.get(config, "client", @current_state_key)
    assert HTTPStateStore.get(config, "client", "old-state") == nil
  end

  test "invalidate and delete clear aliases for the removed state" do
    config = config("alias-invalidation")
    invalidated_server = initialized_server(config, "invalidated-state")
    deleted_server = initialized_server(config, "deleted-state")

    assert :ok = HTTPStateStore.put(config, "client", "invalidated-state", invalidated_server)
    assert HTTPStateStore.publish_alias(config, "client", "invalidated-state", "client", @current_state_key, invalidated_server)

    assert :ok = HTTPStateStore.invalidate(config, "client", "invalidated-state")
    assert HTTPStateStore.get(config, "client", "invalidated-state") == nil
    assert HTTPStateStore.get(config, "client", @current_state_key) == nil

    assert :ok = HTTPStateStore.put(config, "client", "deleted-state", deleted_server)
    assert HTTPStateStore.publish_alias(config, "client", "deleted-state", "client", @current_state_key, deleted_server)

    assert :ok = HTTPStateStore.delete(config, "client", "deleted-state")
    assert HTTPStateStore.get(config, "client", "deleted-state") == nil
    assert HTTPStateStore.get(config, "client", @current_state_key) == nil
  end

  test "alias reads refresh the backing source entry" do
    config = config("alias-refresh")
    source_server = initialized_server(config, "source-state")
    source_key = store_key(config, "client", "source-state")

    assert :ok = HTTPStateStore.put(config, "client", "source-state", source_server)
    assert HTTPStateStore.publish_alias(config, "client", "source-state", "client", @current_state_key, source_server)

    old_touched_at = System.monotonic_time(:millisecond) - 100

    :sys.replace_state(HTTPStateStore, fn state ->
      entries = Map.update!(state.entries, source_key, fn {server, _touched_at} -> {server, old_touched_at} end)
      %{state | entries: entries}
    end)

    assert %Server{state_key: "source-state"} = HTTPStateStore.get(config, "client", @current_state_key)

    %{entries: entries} = :sys.get_state(HTTPStateStore)
    assert {_server, refreshed_touched_at} = Map.fetch!(entries, source_key)
    assert refreshed_touched_at > old_touched_at
  end

  test "direct writes to an alias key detach stale alias metadata" do
    config = config("direct-alias-detach")
    source_server = initialized_server(config, "source-state")
    direct_server = initialized_server(config, "direct-current")

    assert :ok = HTTPStateStore.put(config, "client", "source-state", source_server)
    assert HTTPStateStore.publish_alias(config, "client", "source-state", "client", @current_state_key, source_server)
    assert :ok = HTTPStateStore.put(config, "client", @current_state_key, direct_server)

    assert :ok = HTTPStateStore.invalidate(config, "client", "source-state")
    assert %Server{state_key: "direct-current"} = HTTPStateStore.get(config, "client", @current_state_key)
  end

  test "queued updates started before invalidation cannot resurrect state" do
    config = config("queued-invalidate")
    parent = self()

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "state"))

    first =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:entered_first_update, self()})

          receive do
            :release_first_update -> :ok
          after
            1_000 -> raise "timed out waiting to release first update"
          end

          {:first, %{server | initialized: true}}
        end)
      end)

    assert_receive {:entered_first_update, first_pid}

    second =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:entered_second_update, server.initialized})
          {:second, %{server | initialized: true}}
        end)
      end)

    wait_for_queued_lock(config, "client", "state", 1)
    assert :ok = HTTPStateStore.invalidate(config, "client", "state")

    send(first_pid, :release_first_update)

    assert Task.await(first) == {:first, :dropped}
    assert_receive {:entered_second_update, false}
    assert Task.await(second) == {:second, :dropped}
    assert HTTPStateStore.get(config, "client", "state") == nil
  end

  test "direct put cannot be overwritten by an in-flight stale update" do
    config = config("put-race")
    parent = self()

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "initial"))

    update =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:holding_update, self()})

          receive do
            :release_update -> :ok
          after
            1_000 -> raise "timed out waiting to release update"
          end

          {:stale_update, %{server | state_key: "stale-update", initialized: true}}
        end)
      end)

    assert_receive {:holding_update, update_pid}

    put = Task.async(fn -> HTTPStateStore.put(config, "client", "state", initialized_server(config, "fresh-put")) end)
    refute Task.yield(put, 50)

    send(update_pid, :release_update)

    assert Task.await(update) == {:stale_update, :stored}
    assert Task.await(put) == :ok
    assert %Server{state_key: "fresh-put"} = HTTPStateStore.get(config, "client", "state")
  end

  test "newer successful writes prevent older queued puts from overwriting state" do
    config = config("queued-write-order")
    parent = self()

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "initial"))

    holder =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:holding_write_order_update, self()})

          receive do
            :release_write_order_update -> :ok
          after
            1_000 -> raise "timed out waiting to release write-order update"
          end

          {:held, %{server | state_key: "held-update", initialized: true}}
        end)
      end)

    assert_receive {:holding_write_order_update, holder_pid}

    stale_put =
      Task.async(fn ->
        HTTPStateStore.put(config, "client", "state", initialized_server(config, "stale-put"))
      end)

    wait_for_queued_lock(config, "client", "state", 1)

    fresh_put =
      Task.async(fn ->
        HTTPStateStore.put(config, "client", "state", initialized_server(config, "fresh-put"))
      end)

    wait_for_queued_lock(config, "client", "state", 2)
    reverse_queued_lock(config, "client", "state")
    send(holder_pid, :release_write_order_update)

    assert Task.await(holder) == {:held, :stored}
    assert Task.await(fresh_put) == :ok
    assert Task.await(stale_put) == :ok
    assert %Server{state_key: "fresh-put"} = HTTPStateStore.get(config, "client", "state")
  end

  test "bypassed updates do not supersede queued writes" do
    config = config("bypassed-write-order")
    parent = self()

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "initial"))

    holder =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:holding_bypassed_write_order, self()})

          receive do
            :release_bypassed_write_order -> :ok
          after
            1_000 -> raise "timed out waiting to release bypassed write order"
          end

          {:held, %{server | state_key: "held-update"}}
        end)
      end)

    assert_receive {:holding_bypassed_write_order, holder_pid}

    pending =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          {:pending, %{server | state_key: "pending-update"}}
        end)
      end)

    wait_for_queued_lock(config, "client", "state", 1)

    bypass =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn _server ->
          {:bypass, :route}
        end)
      end)

    wait_for_queued_lock(config, "client", "state", 2)
    reverse_queued_lock(config, "client", "state")
    send(holder_pid, :release_bypassed_write_order)

    assert Task.await(holder) == {:held, :stored}
    assert {{:route, %Server{state_key: "held-update"}}, :bypassed} = Task.await(bypass)
    assert Task.await(pending) == {:pending, :stored}
    assert %Server{state_key: "pending-update"} = HTTPStateStore.get(config, "client", "state")
  end

  test "alias publication cannot be overwritten by an in-flight stale alias update" do
    config = config("alias-publish-race")
    parent = self()
    source_server = initialized_server(config, "source-state")

    assert :ok = HTTPStateStore.put(config, "client", "source-state", source_server)
    assert HTTPStateStore.publish_alias(config, "client", "source-state", "client", @current_state_key, source_server)

    alias_default = default_server_fun(config, @current_state_key)

    update =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", @current_state_key, alias_default, fn
          server ->
            send(parent, {:holding_alias_update, self()})

            receive do
              :release_alias_update -> :ok
            after
              1_000 -> raise "timed out waiting to release alias update"
            end

            {:stale_alias_update, %{server | state_key: "stale-current", initialized: true}}
        end)
      end)

    assert_receive {:holding_alias_update, update_pid}

    fresh_alias_server = initialized_server(config, "fresh-current")
    publish = Task.async(fn -> HTTPStateStore.publish_alias(config, "client", "source-state", "client", @current_state_key, fresh_alias_server) end)

    wait_for_queued_lock(config, "client", @current_state_key, 1)

    send(update_pid, :release_alias_update)

    assert Task.await(update) == {:stale_alias_update, :stored}
    assert Task.await(publish)
    assert %Server{state_key: "fresh-current"} = HTTPStateStore.get(config, "client", @current_state_key)
  end

  test "queued alias writes started before invalidation cannot resurrect aliases" do
    publish_config = config("queued-alias-publish")

    assert_queued_alias_write_dropped_after_invalidation(publish_config, fn alias_server ->
      HTTPStateStore.publish_alias(publish_config, "client", "source-state", "client", @current_state_key, alias_server)
    end)

    HTTPStateStore.reset!()
    supersede_config = config("queued-alias-supersede")

    assert_queued_alias_write_dropped_after_invalidation(supersede_config, fn alias_server ->
      HTTPStateStore.supersede_alias(supersede_config, "client", "source-state", "client", @current_state_key, alias_server)
    end)
  end

  test "delete prevents queued updates from resurrecting deleted state" do
    config = config("queued-delete")
    parent = self()

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "state"))

    first =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:holding_update, self()})

          receive do
            :release_update -> :ok
          after
            1_000 -> raise "timed out waiting to release update"
          end

          {:first, %{server | initialized: true}}
        end)
      end)

    assert_receive {:holding_update, update_pid}

    delete = Task.async(fn -> HTTPStateStore.delete(config, "client", "state") end)
    wait_for_queued_lock(config, "client", "state", 1)

    second =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:entered_second_update, server.initialized})
          {:second, %{server | initialized: true}}
        end)
      end)

    wait_for_queued_lock(config, "client", "state", 2)
    send(update_pid, :release_update)

    assert Task.await(first) == {:first, :stored}
    assert Task.await(delete) == :ok
    assert_receive {:entered_second_update, false}
    assert Task.await(second) == {:second, :dropped}
    assert HTTPStateStore.get(config, "client", "state") == nil
  end

  test "queued direct puts started before invalidation cannot resurrect state" do
    config = config("queued-put-invalidate")
    parent = self()

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "state"))

    holder =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:holding_update, self()})

          receive do
            :release_update -> :ok
          after
            1_000 -> raise "timed out waiting to release update"
          end

          {:held, %{server | initialized: true}}
        end)
      end)

    assert_receive {:holding_update, holder_pid}

    stale_put =
      Task.async(fn ->
        HTTPStateStore.put(config, "client", "state", initialized_server(config, "stale-put"))
      end)

    wait_for_queued_lock(config, "client", "state", 1)
    assert :ok = HTTPStateStore.invalidate(config, "client", "state")
    send(holder_pid, :release_update)

    assert Task.await(holder) == {:held, :dropped}
    assert Task.await(stale_put) == :ok
    assert HTTPStateStore.get(config, "client", "state") == nil
  end

  test "ttl cleanup prevents queued updates from resurrecting expired state" do
    original_ttl_ms = :sys.get_state(HTTPStateStore).ttl_ms
    on_exit(fn -> :sys.replace_state(HTTPStateStore, &%{&1 | ttl_ms: original_ttl_ms}) end)

    config = config("queued-ttl-expire")
    parent = self()
    key = store_key(config, "client", "state")

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "state"))

    holder =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:holding_update, self()})

          receive do
            :release_update -> :ok
          after
            1_000 -> raise "timed out waiting to release update"
          end

          {:held, %{server | initialized: true}}
        end)
      end)

    assert_receive {:holding_update, holder_pid}

    queued =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          {:queued, %{server | initialized: true}}
        end)
      end)

    wait_for_queued_lock(config, "client", "state", 1)

    :sys.replace_state(HTTPStateStore, fn state ->
      entries = Map.update!(state.entries, key, fn {server, _touched_at} -> {server, System.monotonic_time(:millisecond) - 10} end)
      %{state | entries: entries, ttl_ms: 1}
    end)

    assert HTTPStateStore.get(config, "client", "state") == nil
    send(holder_pid, :release_update)

    assert Task.await(holder) == {:held, :dropped}
    assert Task.await(queued) == {:queued, :dropped}
    assert HTTPStateStore.get(config, "client", "state") == nil
  end

  test "first write after ttl cleanup can recreate expired state" do
    config = config("post-ttl-recreate")
    key = store_key(config, "client", "state")

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "expired"))
    expire_entry(key)

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "fresh-put"))
    assert %Server{state_key: "fresh-put"} = HTTPStateStore.get(config, "client", "state")

    expire_entry(key)

    assert {:fresh_update, :stored} =
             HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
               {:fresh_update, %{server | state_key: "fresh-update", initialized: true}}
             end)

    assert %Server{state_key: "fresh-update"} = HTTPStateStore.get(config, "client", "state")
  end

  test "first write after ttl cleanup can recreate expired state while queued" do
    config = config("post-ttl-queued-recreate")
    parent = self()
    key = store_key(config, "client", "state")

    assert :ok = HTTPStateStore.put(config, "client", "state", initialized_server(config, "expired"))

    holder =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", "state", default_server_fun(config, "state"), fn server ->
          send(parent, {:holding_update, self()})

          receive do
            :release_update -> :ok
          after
            1_000 -> raise "timed out waiting to release update"
          end

          {:held, %{server | initialized: true}}
        end)
      end)

    assert_receive {:holding_update, holder_pid}
    expire_entry(key)

    fresh_put =
      Task.async(fn ->
        HTTPStateStore.put(config, "client", "state", initialized_server(config, "fresh-put"))
      end)

    wait_for_queued_lock(config, "client", "state", 1)
    send(holder_pid, :release_update)

    assert Task.await(holder) == {:held, :dropped}
    assert Task.await(fresh_put) == :ok
    assert %Server{state_key: "fresh-put"} = HTTPStateStore.get(config, "client", "state")
  end

  test "state entries are scoped by active dynamic ledger" do
    first_database = WorkPackageFactory.database_path()
    second_database = WorkPackageFactory.database_path()
    original_repo = Repo.get_dynamic_repo()

    {:ok, first_pid} =
      Repo.start_link(database: first_database, name: Repo.process_name(first_database), pool_size: 1, log: false)

    {:ok, second_pid} =
      Repo.start_link(database: second_database, name: Repo.process_name(second_database), pool_size: 1, log: false)

    try do
      config = Config.default(mode: :http, repo: Repo)

      Repo.put_dynamic_repo(first_pid)
      assert :ok = HTTPStateStore.put(config, "client", "same-state", initialized_server(config, "same-state"))

      Repo.put_dynamic_repo(second_pid)
      assert HTTPStateStore.get(config, "client", "same-state") == nil

      Repo.put_dynamic_repo(first_pid)
      assert %Server{initialized: true} = HTTPStateStore.get(config, "client", "same-state")
    after
      Repo.put_dynamic_repo(original_repo)
      if Process.alive?(first_pid), do: GenServer.stop(first_pid)
      if Process.alive?(second_pid), do: GenServer.stop(second_pid)
      File.rm(first_database)
      File.rm(second_database)
    end
  end

  defp config(database), do: Config.default(mode: :http, repo: Repo, database: database)

  defp initialized_server(config, state_key, opts \\ []) do
    Server.new(config, state_key: state_key, initialized: true, session: Keyword.get(opts, :session))
  end

  defp default_server_fun(config, state_key) do
    fn -> Server.new(config, state_key: state_key) end
  end

  defp worker_session do
    Session.new(%Assignment{
      grant_id: "grant-http-state",
      work_package_id: "SYMPP-HTTP-STATE",
      display_key: "ABCD",
      grant_role: "worker",
      capabilities: ["read:own"],
      claimed_at: ~U[2026-05-17 00:00:00Z],
      claimed_by: "worker-1"
    })
  end

  defp wait_for_queued_lock(config, client_key, state_key, expected_len, attempts \\ 50)

  defp wait_for_queued_lock(_config, _client_key, _state_key, expected_len, 0) do
    flunk("timed out waiting for #{expected_len} queued HTTP state lock waiters")
  end

  defp wait_for_queued_lock(%Config{} = config, client_key, state_key, expected_len, attempts) do
    store = :sys.get_state(HTTPStateStore)
    key = store_key(config, client_key, state_key)

    queued? =
      case Map.get(store.locks, key) do
        %{queue: queue} -> :queue.len(queue) >= expected_len
        _missing -> false
      end

    if queued? do
      :ok
    else
      Process.sleep(10)
      wait_for_queued_lock(config, client_key, state_key, expected_len, attempts - 1)
    end
  end

  defp reverse_queued_lock(%Config{} = config, client_key, state_key) do
    key = store_key(config, client_key, state_key)

    :sys.replace_state(HTTPStateStore, fn state ->
      locks =
        Map.update!(state.locks, key, fn lock ->
          queue =
            lock.queue
            |> :queue.to_list()
            |> Enum.reverse()
            |> :queue.from_list()

          %{lock | queue: queue}
        end)

      %{state | locks: locks}
    end)

    :ok
  end

  defp store_key(%Config{} = config, client_key, state_key) do
    {config.mode, LedgerNamespace.key(config), client_key, state_key}
  end

  defp assert_queued_alias_write_dropped_after_invalidation(%Config{} = config, alias_fun) do
    parent = self()
    source_server = initialized_server(config, "source-state")

    assert :ok = HTTPStateStore.put(config, "client", "source-state", source_server)
    assert HTTPStateStore.publish_alias(config, "client", "source-state", "client", @current_state_key, source_server)
    alias_default = default_server_fun(config, @current_state_key)

    holder =
      Task.async(fn ->
        HTTPStateStore.update_with_status(config, "client", @current_state_key, alias_default, fn server ->
          send(parent, {:holding_alias_update, self()})

          receive do
            :release_alias_update -> :ok
          after
            1_000 -> raise "timed out waiting to release alias update"
          end

          {:held_alias, %{server | initialized: true}}
        end)
      end)

    assert_receive {:holding_alias_update, holder_pid}

    alias_write =
      Task.async(fn ->
        alias_fun.(initialized_server(config, "queued-current"))
      end)

    wait_for_queued_lock(config, "client", @current_state_key, 1)
    assert :ok = HTTPStateStore.invalidate(config, "client", @current_state_key)
    send(holder_pid, :release_alias_update)

    assert Task.await(holder) == {:held_alias, :dropped}
    refute Task.await(alias_write)
    assert HTTPStateStore.get(config, "client", @current_state_key) == nil
  end

  defp expire_entry(key) do
    :sys.replace_state(HTTPStateStore, fn state ->
      entries =
        Map.update!(state.entries, key, fn {server, _touched_at} ->
          {server, System.monotonic_time(:millisecond) - 86_400_001}
        end)

      %{state | entries: entries}
    end)
  end
end
