defmodule SymphonyElixir.SymphonyPlusPlus.MCP.HTTPStateStore do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, LedgerNamespace, Server}

  @ttl_ms 86_400_000

  @type update_status :: :stored | :dropped | :skipped
  @type default_fun :: (-> Server.t())
  @type update_fun :: (Server.t() -> {term(), Server.t()})

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec ensure_started() :: :ok | {:error, :state_store_unavailable}
  def ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> :ok
      nil -> start_store()
    end
  end

  @spec get(Config.t(), String.t(), String.t()) :: Server.t() | nil
  def get(%Config{} = config, client_key, state_key) when is_binary(client_key) and is_binary(state_key) do
    GenServer.call(__MODULE__, {:get, store_key(config, client_key, state_key)})
  end

  @spec put(Config.t(), String.t(), String.t(), Server.t()) :: :ok
  def put(%Config{} = config, client_key, state_key, %Server{} = server)
      when is_binary(client_key) and is_binary(state_key) do
    key = store_key(config, client_key, state_key)
    write_ref = begin_write(key)
    with_lock(key, fn -> GenServer.call(__MODULE__, {:put, key, write_ref, server}) end)
  end

  @spec update_with_status(Config.t(), String.t(), String.t(), default_fun(), update_fun()) :: {term(), update_status()}
  def update_with_status(%Config{} = config, client_key, state_key, default_fun, update_fun)
      when is_binary(client_key) and is_binary(state_key) and is_function(default_fun, 0) and
             is_function(update_fun, 1) do
    key = store_key(config, client_key, state_key)
    write_ref = begin_write(key)

    with_lock(key, fn ->
      server = get_by_key(key) || default_fun.()
      {reply, %Server{} = updated_server} = update_fun.(server)
      {reply, put_by_key_if_current(key, write_ref, updated_server)}
    end)
  end

  @spec invalidate(Config.t(), String.t(), String.t()) :: :ok
  def invalidate(%Config{} = config, client_key, state_key) when is_binary(client_key) and is_binary(state_key) do
    GenServer.call(__MODULE__, {:invalidate, store_key(config, client_key, state_key)})
  end

  @spec delete(Config.t(), String.t(), String.t()) :: :ok
  def delete(%Config{} = config, client_key, state_key) when is_binary(client_key) and is_binary(state_key) do
    key = store_key(config, client_key, state_key)
    with_lock(key, fn -> GenServer.call(__MODULE__, {:delete, key}) end)
  end

  @spec publish_alias(Config.t(), String.t(), String.t(), String.t(), String.t(), Server.t()) :: boolean()
  def publish_alias(%Config{} = config, source_client_key, source_state_key, alias_client_key, alias_state_key, %Server{} = alias_server)
      when is_binary(source_client_key) and is_binary(source_state_key) and is_binary(alias_client_key) and
             is_binary(alias_state_key) do
    source_key = store_key(config, source_client_key, source_state_key)
    alias_key = store_key(config, alias_client_key, alias_state_key)
    write_ref = begin_write(alias_key)

    with_lock(alias_key, fn ->
      GenServer.call(__MODULE__, {:publish_alias, source_key, alias_key, write_ref, alias_server})
    end)
  end

  @spec supersede_alias(Config.t(), String.t(), String.t(), String.t(), String.t(), Server.t()) :: boolean()
  def supersede_alias(
        %Config{} = config,
        source_client_key,
        source_state_key,
        alias_client_key,
        alias_state_key,
        %Server{} = alias_server
      )
      when is_binary(source_client_key) and is_binary(source_state_key) and is_binary(alias_client_key) and
             is_binary(alias_state_key) do
    source_key = store_key(config, source_client_key, source_state_key)
    alias_key = store_key(config, alias_client_key, alias_state_key)
    write_ref = begin_write(alias_key)

    with_lock(alias_key, fn ->
      GenServer.call(__MODULE__, {:supersede_alias, source_key, alias_key, write_ref, alias_server})
    end)
  end

  @spec recovery_persistence_due?(Config.t(), String.t(), pos_integer()) :: boolean()
  def recovery_persistence_due?(%Config{} = config, binding_id, interval_ms)
      when is_binary(binding_id) and is_integer(interval_ms) and interval_ms > 0 do
    deadline_due?({:recovery_persistence, LedgerNamespace.key(config), binding_id}, interval_ms)
  end

  @spec defer_recovery_persistence(Config.t(), String.t(), pos_integer()) :: :ok
  def defer_recovery_persistence(%Config{} = config, binding_id, interval_ms)
      when is_binary(binding_id) and is_integer(interval_ms) and interval_ms > 0 do
    GenServer.call(__MODULE__, {:defer_deadline, {:recovery_persistence, LedgerNamespace.key(config), binding_id}, interval_ms})
  end

  @spec recovery_cleanup_due?(Config.t(), pos_integer()) :: boolean()
  def recovery_cleanup_due?(%Config{} = config, interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    deadline_due?({:recovery_cleanup, LedgerNamespace.key(config)}, interval_ms)
  end

  @spec reset!() :: :ok
  def reset!, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(opts) do
    {:ok,
     %{
       entries: %{},
       aliases: %{},
       key_versions: %{},
       key_version_touched_at: %{},
       next_write_tokens: %{},
       successful_write_tokens: %{},
       deadlines: %{},
       locks: %{},
       lock_refs: %{},
       ttl_ms: Keyword.get(opts, :ttl_ms, @ttl_ms)
     }}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    state = cleanup(state)

    case Map.fetch(state.entries, key) do
      {:ok, {server, _touched_at}} ->
        entries = touch_entry_and_alias_source(state, key, server)
        {:reply, server, %{state | entries: entries}}

      :error ->
        {:reply, nil, state}
    end
  end

  def handle_call({:put, key, write_ref, %Server{} = server}, _from, state) do
    state = cleanup(state)

    state =
      if current_write?(state, key, write_ref) and persistable?(server),
        do: put_entry(state, key, server, write_ref),
        else: state

    {:reply, :ok, state}
  end

  def handle_call({:put_if_current, key, write_ref, %Server{} = server}, _from, state) do
    state = cleanup(state)

    cond do
      not current_write?(state, key, write_ref) ->
        {:reply, :dropped, state}

      not persistable?(server) ->
        {:reply, :skipped, state}

      true ->
        {:reply, :stored, put_entry(state, key, server, write_ref)}
    end
  end

  def handle_call({operation, key}, _from, state) when operation in [:invalidate, :delete] do
    state = state |> cleanup() |> invalidate_key(key)
    {:reply, :ok, state}
  end

  def handle_call({:publish_alias, source_key, alias_key, write_ref, %Server{} = alias_server}, _from, state) do
    state = cleanup(state)

    cond do
      not current_write?(state, alias_key, write_ref) ->
        {:reply, false, state}

      not persistable?(alias_server) ->
        {:reply, false, state}

      not Map.has_key?(state.entries, source_key) ->
        {:reply, false, state}

      stale_alias?(state, alias_key, source_key) ->
        {:reply, false, state}

      true ->
        {:reply, true, put_alias(state, source_key, alias_key, alias_server, write_ref)}
    end
  end

  def handle_call({:supersede_alias, source_key, alias_key, write_ref, %Server{} = alias_server}, _from, state) do
    state = cleanup(state)

    cond do
      not current_write?(state, alias_key, write_ref) ->
        {:reply, false, state}

      not persistable?(alias_server) ->
        {:reply, false, state}

      not Map.has_key?(state.entries, source_key) ->
        {:reply, false, state}

      true ->
        state =
          state
          |> invalidate_superseded_source(alias_key, source_key)
          |> put_alias(source_key, alias_key, alias_server, write_ref)

        {:reply, true, state}
    end
  end

  def handle_call({:begin_write, key}, _from, state) do
    state = cleanup(state)
    token = Map.get(state.next_write_tokens, key, 0) + 1
    touched_at = now_ms()

    state = %{
      state
      | key_versions: Map.put_new(state.key_versions, key, 0),
        key_version_touched_at: Map.put(state.key_version_touched_at, key, touched_at),
        next_write_tokens: Map.put(state.next_write_tokens, key, token)
    }

    {:reply, {Map.get(state.key_versions, key, 0), token}, state}
  end

  def handle_call({:deadline_due, key, interval_ms}, _from, state) do
    state = cleanup(state)
    now = now_ms()

    case Map.fetch(state.deadlines, key) do
      :error ->
        {:reply, true, %{state | deadlines: Map.put(state.deadlines, key, now + interval_ms)}}

      {:ok, deadline} when deadline <= now ->
        {:reply, true, %{state | deadlines: Map.put(state.deadlines, key, now + interval_ms)}}

      {:ok, _deadline} ->
        {:reply, false, state}
    end
  end

  def handle_call({:defer_deadline, key, interval_ms}, _from, state) do
    state = cleanup(state)
    {:reply, :ok, %{state | deadlines: Map.put(state.deadlines, key, now_ms() + interval_ms)}}
  end

  def handle_call({:acquire_lock, key}, from, state) do
    case Map.fetch(state.locks, key) do
      {:ok, lock} ->
        lock = %{lock | queue: :queue.in(from, lock.queue)}
        {:noreply, %{state | locks: Map.put(state.locks, key, lock)}}

      :error ->
        {:reply, :ok, grant_lock(state, key, from, false)}
    end
  end

  def handle_call({:release_lock, key}, {owner_pid, _tag}, state) do
    {:reply, :ok, release_lock_owner(state, key, owner_pid)}
  end

  def handle_call(:reset, _from, state) do
    reset_lock_waiters(state)

    {:reply, :ok,
     %{
       state
       | entries: %{},
         aliases: %{},
         key_versions: %{},
         key_version_touched_at: %{},
         next_write_tokens: %{},
         successful_write_tokens: %{},
         deadlines: %{},
         locks: %{},
         lock_refs: %{},
         ttl_ms: @ttl_ms
     }}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", _table, _from, :mcp_repository_cache}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, release_lock_ref(state, ref)}
  end

  defp start_store do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) -> start_supervised_store()
      nil -> start_direct_store()
    end
  end

  defp start_supervised_store do
    case Supervisor.restart_child(SymphonyElixir.Supervisor, __MODULE__) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, :not_found} -> add_supervised_store()
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> {:error, :state_store_unavailable}
    end
  catch
    :exit, _reason -> {:error, :state_store_unavailable}
  end

  defp add_supervised_store do
    case Supervisor.start_child(SymphonyElixir.Supervisor, __MODULE__) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> {:error, :state_store_unavailable}
    end
  end

  defp start_direct_store do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> {:error, :state_store_unavailable}
    end
  end

  defp get_by_key(key), do: GenServer.call(__MODULE__, {:get, key})

  defp put_by_key_if_current(key, write_ref, %Server{} = server) do
    GenServer.call(__MODULE__, {:put_if_current, key, write_ref, server})
  end

  defp begin_write(key), do: GenServer.call(__MODULE__, {:begin_write, key})
  defp deadline_due?(key, interval_ms), do: GenServer.call(__MODULE__, {:deadline_due, key, interval_ms})
  defp acquire_lock(key), do: GenServer.call(__MODULE__, {:acquire_lock, key}, :infinity)
  defp release_lock_call(key), do: GenServer.call(__MODULE__, {:release_lock, key}, :infinity)

  defp with_lock(key, fun) do
    :ok = acquire_lock(key)

    try do
      fun.()
    after
      :ok = release_lock_call(key)
    end
  end

  defp grant_lock(state, key, {pid, _tag} = from, reply?) do
    ref = Process.monitor(pid)
    if reply?, do: GenServer.reply(from, :ok)

    lock = %{owner_pid: pid, owner_ref: ref, queue: :queue.new()}

    %{state | locks: Map.put(state.locks, key, lock), lock_refs: Map.put(state.lock_refs, ref, key)}
  end

  defp release_lock_owner(state, key, owner_pid) do
    case Map.fetch(state.locks, key) do
      {:ok, %{owner_pid: ^owner_pid} = lock} -> release_lock_state(state, key, lock)
      _missing_or_not_owner -> state
    end
  end

  defp release_lock_ref(state, ref) do
    case Map.fetch(state.lock_refs, ref) do
      {:ok, key} ->
        case Map.fetch(state.locks, key) do
          {:ok, %{owner_ref: ^ref} = lock} -> release_lock_state(state, key, lock)
          _missing_or_replaced -> %{state | lock_refs: Map.delete(state.lock_refs, ref)}
        end

      :error ->
        state
    end
  end

  defp release_lock_state(state, key, lock) do
    Process.demonitor(lock.owner_ref, [:flush])
    state = %{state | lock_refs: Map.delete(state.lock_refs, lock.owner_ref)}

    case :queue.out(lock.queue) do
      {{:value, next_from}, queue} ->
        state
        |> grant_lock(key, next_from, true)
        |> put_lock_queue(key, queue)

      {:empty, _queue} ->
        state
        |> Map.update!(:locks, &Map.delete(&1, key))
        |> prune_versions()
    end
  end

  defp put_lock_queue(state, key, queue) do
    lock = Map.fetch!(state.locks, key)
    %{state | locks: Map.put(state.locks, key, %{lock | queue: queue})}
  end

  defp reset_lock_waiters(state) do
    Enum.each(state.locks, fn {_key, lock} ->
      Process.demonitor(lock.owner_ref, [:flush])
      lock.queue |> :queue.to_list() |> Enum.each(&GenServer.reply(&1, {:error, :reset}))
    end)
  end

  defp store_key(%Config{} = config, client_key, state_key), do: {config.mode, LedgerNamespace.key(config), client_key, state_key}

  defp put_entry(state, key, %Server{} = server, write_ref) do
    state
    |> mark_successful_write(key, write_ref)
    |> then(fn state ->
      %{state | entries: Map.put(state.entries, key, {server, now_ms()}), aliases: Map.delete(state.aliases, key)}
    end)
  end

  defp touch_entry_and_alias_source(state, key, %Server{} = server) do
    touched_at = now_ms()
    entries = Map.put(state.entries, key, {server, touched_at})

    with source_key when not is_nil(source_key) <- Map.get(state.aliases, key),
         {:ok, {source_server, _source_touched_at}} <- Map.fetch(entries, source_key) do
      Map.put(entries, source_key, {source_server, touched_at})
    else
      _missing -> entries
    end
  end

  defp put_alias(state, source_key, alias_key, %Server{} = alias_server, write_ref) do
    state
    |> put_entry(alias_key, alias_server, write_ref)
    |> Map.update!(:aliases, &Map.put(&1, alias_key, source_key))
  end

  defp stale_alias?(state, alias_key, source_key) do
    case Map.get(state.aliases, alias_key) do
      nil -> false
      ^source_key -> false
      _other_source_key -> true
    end
  end

  defp invalidate_superseded_source(state, alias_key, source_key) do
    case Map.get(state.aliases, alias_key) do
      nil ->
        state

      ^source_key ->
        state

      previous_source_key ->
        invalidate_key(state, previous_source_key)
    end
  end

  defp invalidate_key(state, key) do
    {state, removed_keys} = remove_key_and_aliases(state, key)
    bump_versions(state, removed_keys)
  end

  defp remove_key_and_aliases(state, key) do
    alias_keys =
      state.aliases
      |> Enum.filter(fn {alias_key, source_key} -> alias_key == key or source_key == key end)
      |> Enum.map(fn {alias_key, _source_key} -> alias_key end)

    removed_keys = Enum.uniq([key | alias_keys])
    removed_key_set = MapSet.new(removed_keys)

    aliases =
      state.aliases
      |> Map.drop(alias_keys)
      |> Map.reject(fn {_alias_key, source_key} -> MapSet.member?(removed_key_set, source_key) end)

    {%{state | entries: Map.drop(state.entries, removed_keys), aliases: aliases}, removed_keys}
  end

  defp bump_versions(state, keys) do
    touched_at = now_ms()

    Enum.reduce(keys, state, fn key, state ->
      %{
        state
        | key_versions: Map.update(state.key_versions, key, 1, &(&1 + 1)),
          key_version_touched_at: Map.put(state.key_version_touched_at, key, touched_at)
      }
    end)
  end

  defp current_write?(state, key, {generation, token}) do
    Map.get(state.key_versions, key, 0) == generation and Map.get(state.successful_write_tokens, key, 0) < token
  end

  defp mark_successful_write(state, key, {_generation, token}) do
    %{state | successful_write_tokens: Map.put(state.successful_write_tokens, key, token)}
  end

  defp persistable?(%Server{initialized: true}), do: true
  defp persistable?(%Server{session: session}) when not is_nil(session), do: true
  defp persistable?(%Server{}), do: false

  defp cleanup(%{entries: entries, ttl_ms: ttl_ms} = state) do
    cutoff = now_ms() - ttl_ms
    expired_keys = for {key, {_server, touched_at}} <- entries, touched_at < cutoff, do: key
    deadlines = Map.filter(state.deadlines, fn {_key, deadline} -> deadline >= cutoff end)

    {state, orphan_alias_keys} =
      %{state | entries: Map.drop(entries, expired_keys), deadlines: deadlines}
      |> prune_aliases()

    state
    |> bump_versions(expired_keys ++ orphan_alias_keys)
    |> prune_versions()
  end

  defp prune_aliases(state) do
    active_keys = state.entries |> Map.keys() |> MapSet.new()

    {active_aliases, orphan_aliases} =
      Enum.split_with(state.aliases, fn {alias_key, source_key} ->
        MapSet.member?(active_keys, alias_key) and MapSet.member?(active_keys, source_key)
      end)

    orphan_alias_keys = Enum.map(orphan_aliases, &elem(&1, 0))
    {%{state | entries: Map.drop(state.entries, orphan_alias_keys), aliases: Map.new(active_aliases)}, orphan_alias_keys}
  end

  defp prune_versions(%{entries: entries, locks: locks, ttl_ms: ttl_ms} = state) do
    cutoff = now_ms() - ttl_ms
    active_keys = MapSet.new(Map.keys(entries) ++ Map.keys(locks))

    key_versions =
      Map.filter(state.key_versions, fn {key, _version} ->
        MapSet.member?(active_keys, key) or Map.get(state.key_version_touched_at, key, 0) >= cutoff
      end)

    retained_keys =
      active_keys
      |> MapSet.union(MapSet.new(Map.keys(key_versions)))
      |> MapSet.to_list()

    %{
      state
      | key_versions: key_versions,
        key_version_touched_at: Map.take(state.key_version_touched_at, Map.keys(key_versions)),
        next_write_tokens: Map.take(state.next_write_tokens, retained_keys),
        successful_write_tokens: Map.take(state.successful_write_tokens, retained_keys)
    }
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
