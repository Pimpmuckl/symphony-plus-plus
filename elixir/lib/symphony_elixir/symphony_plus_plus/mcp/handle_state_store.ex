defmodule SymphonyElixir.SymphonyPlusPlus.MCP.HandleStateStore do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{LedgerNamespace, Server, Session}

  @server Server
  @agent Module.concat(Server, HandleState)
  @handle_state_ttl_ms 86_400_000
  @explicit_handle_state_ttl_ms 604_800_000

  @spec cleanup_default_handle_states() :: :ok
  def cleanup_default_handle_states do
    now = monotonic_ms()

    update(fn store ->
      Map.reject(store, fn
        {_state_key, {%{__struct__: @server}, timestamp_ms, false}} -> now - timestamp_ms > @handle_state_ttl_ms
        {_state_key, {%{__struct__: @server}, timestamp_ms, true}} -> now - timestamp_ms > @explicit_handle_state_ttl_ms
        _entry -> false
      end)
    end)

    :ok
  end

  @spec restore(term(), Server.t()) :: Server.t()
  def restore(payload, %{__struct__: @server, initialized: false, session: nil, state_key_explicit: true} = server) do
    if initialize_request?(payload), do: server, else: restore_explicit(server)
  end

  def restore(payload, %{__struct__: @server, state_key_explicit: true} = server) do
    if initialize_request?(payload) do
      if server.initialized, do: restore_explicit(server), else: %{server | initialized: false, session: nil}
    else
      restore_explicit(server)
    end
  end

  def restore(payload, %{__struct__: @server, state_key_explicit: false} = server) do
    if initialize_request?(payload) do
      case {server.initialized, lookup(server)} do
        {true, _stored} ->
          server

        {false, {%{__struct__: @server}, _timestamp_ms, _explicit?}} ->
          delete(server)
          %{server | initialized: false, session: nil}

        _stored ->
          server
      end
    else
      restore(server)
    end
  end

  def restore(_payload, %{__struct__: @server} = server), do: restore(server)

  @spec persist(term(), map() | [map()] | nil, Server.t(), Server.t()) :: Server.t()
  def persist(payload, response, %{__struct__: @server, state_key_explicit: true} = server, %{__struct__: @server} = updated_server) do
    if initialize_request?(payload) do
      case response do
        %{"result" => _result} ->
          timestamp_ms = put(updated_server)
          %{updated_server | state_key_version: timestamp_ms}

        %{"error" => %{"data" => %{"reason" => "already_initialized"}}} ->
          updated_server

        _response ->
          invalidate_explicit(server)
          %{updated_server | state_key_version: nil}
      end
    else
      persist(server, updated_server)
    end
  end

  def persist(_payload, _response, %{__struct__: @server} = server, %{__struct__: @server} = updated_server), do: persist(server, updated_server)

  @spec repo_query(term(), String.t(), list(), keyword()) :: term()
  def repo_query(repo, sql, params, opts) when is_atom(repo) do
    if repo_module_query?(repo) do
      repo.query(sql, params, opts)
    else
      case dynamic_repo_identity(repo) do
        pid when is_pid(pid) -> SQL.query(pid, sql, params, opts)
        dynamic_repo when is_atom(dynamic_repo) and dynamic_repo != repo -> SQL.query(dynamic_repo, sql, params, opts)
        _repo -> SQL.query(repo, sql, params, opts)
      end
    end
  end

  def repo_query(repo, sql, params, opts), do: SQL.query(repo, sql, params, opts)

  defp restore_explicit(%{__struct__: @server} = server) do
    case lookup(server) do
      {%{__struct__: @server} = stored, timestamp_ms, _explicit?} ->
        state_key_version = stored.state_key_version || timestamp_ms

        session_refresh_required? =
          stored.session_refresh_required or stale_explicit_session?(server, state_key_version)

        session = if session_refresh_required?, do: nil, else: server.session

        %{
          server
          | initialized: server.initialized or stored.initialized,
            session: session,
            state_key_version: state_key_version,
            session_refresh_required: session_refresh_required?
        }

      _stored ->
        server
    end
  end

  defp restore(%{__struct__: @server} = server) do
    case lookup(server) do
      {%{__struct__: @server} = stored, _timestamp_ms, _explicit?} ->
        %{server | initialized: server.initialized or stored.initialized, session: server.session || stored.session}

      _stored ->
        server
    end
  end

  defp persist(%{__struct__: @server} = server, %{__struct__: @server} = updated_server) do
    timestamp_ms =
      cond do
        updated_server.session_refresh_required ->
          put(updated_server)

        server.session_refresh_required != updated_server.session_refresh_required ->
          put(updated_server)

        server.initialized != updated_server.initialized or server.session != updated_server.session ->
          put(updated_server)

        lookup(updated_server) != nil ->
          refresh(updated_server)

        true ->
          nil
      end

    if is_integer(timestamp_ms), do: %{updated_server | state_key_version: timestamp_ms}, else: updated_server
  end

  defp stale_explicit_session?(%{__struct__: @server, session_refresh_required: true, state_key_version: version}, timestamp_ms) when version == timestamp_ms, do: true
  defp stale_explicit_session?(%{__struct__: @server, session: nil}, _timestamp_ms), do: false
  defp stale_explicit_session?(%{__struct__: @server, session: %Session{}, state_key_version: nil}, _timestamp_ms), do: false
  defp stale_explicit_session?(%{__struct__: @server, state_key_version: nil}, _timestamp_ms), do: true
  defp stale_explicit_session?(%{__struct__: @server, state_key_version: state_key_version}, timestamp_ms), do: timestamp_ms > state_key_version

  defp put(%{__struct__: @server} = server) do
    key = key(server)
    timestamp_ms = monotonic_ms()
    state_key_version = System.unique_integer([:monotonic, :positive])
    stored_server = %{stored_server(server) | state_key_version: state_key_version}
    update(&Map.put(&1, key, {stored_server, timestamp_ms, server.state_key_explicit}))
    state_key_version
  end

  defp delete(%{__struct__: @server} = server) do
    update(&Map.delete(&1, key(server)))
    :ok
  end

  defp invalidate_explicit(%{__struct__: @server} = server) do
    timestamp_ms = monotonic_ms()
    state_key_version = System.unique_integer([:monotonic, :positive])

    tombstone =
      server
      |> stored_server()
      |> Map.merge(%{initialized: false, session: nil, state_key_version: state_key_version})

    update(&Map.put(&1, key(server), {tombstone, timestamp_ms, true}))
    :ok
  end

  defp stored_server(%{__struct__: @server, state_key_explicit: true} = server), do: %{server | session: nil}
  defp stored_server(%{__struct__: @server} = server), do: server

  defp lookup(%{__struct__: @server} = server), do: get() |> Map.get(key(server))

  defp refresh(%{__struct__: @server} = server) do
    case lookup(server) do
      {%{__struct__: @server} = stored_server, _timestamp_ms, _explicit?} -> put(stored_server)
      _state -> nil
    end
  end

  defp update(fun) do
    ensure_agent()
    Agent.update(@agent, fun)
  end

  defp get do
    ensure_agent()
    Agent.get(@agent, & &1)
  end

  defp ensure_agent do
    case Process.whereis(@agent) do
      nil ->
        case Agent.start(fn -> %{} end, name: @agent) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp key(%{__struct__: @server} = server), do: {{server.config.mode, LedgerNamespace.key(server.config)}, server.state_key}

  defp repo_module_query?(repo) do
    case Code.ensure_loaded(repo) do
      {:module, _module} -> function_exported?(repo, :query, 3)
      {:error, _reason} -> false
    end
  end

  defp dynamic_repo_identity(repo) when is_atom(repo), do: if(function_exported?(repo, :get_dynamic_repo, 0), do: repo.get_dynamic_repo())
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp initialize_request?(%{"jsonrpc" => "2.0", "method" => "initialize"}), do: true
  defp initialize_request?(_payload), do: false
end
