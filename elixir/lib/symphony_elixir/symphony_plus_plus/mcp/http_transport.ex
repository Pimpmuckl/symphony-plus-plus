defmodule SymphonyElixir.SymphonyPlusPlus.MCP.HTTPTransport do
  @moduledoc """
  Route-free HTTP MCP transport core for decoded JSON-RPC payloads.

  This module preserves initialized HTTP MCP state, including bound sessions
  returned by local WR/WP claim tools. It does not own Plug, CORS, cookie,
  current-alias, explicit reconnect, or browser auth semantics.
  """

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, FailedCall, HerdrBinding, HTTPStateStore}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Server, Session, SessionRecovery}

  @assignment_resource "sympp://assignment/current"
  @work_package_resource_prefix "sympp://work-packages/"
  @client_lock_key "__sympp_mcp_client_lock__"
  @current_state_key "__sympp_mcp_current_state__"
  @unbound_client_key "__sympp_mcp_unbound__"
  @state_key_bytes 32
  @max_state_key_size 256
  @max_client_key_size 512

  defmodule Result do
    @moduledoc false

    @enforce_keys [:response, :state_key, :status]
    defstruct [:herdr_binding, :response, :state_key, :status]

    @type status :: :ok | :no_response | :error
    @type t :: %__MODULE__{
            response: map() | [map()] | nil,
            herdr_binding: map() | :clear | nil,
            state_key: String.t() | nil,
            status: status()
          }
  end

  @typep handle_result :: {:ok, Result.t()} | {:error, :invalid_client_key} | {:error, :ledger_unavailable, term()}

  @spec new_state_key() :: String.t()
  def new_state_key do
    @state_key_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @doc false
  @spec reserved_state_key?(term()) :: boolean()
  def reserved_state_key?(state_key) when is_binary(state_key) do
    state_key in [@client_lock_key, @current_state_key, @unbound_client_key]
  end

  def reserved_state_key?(_state_key), do: false

  @spec handle(Config.t(), term(), keyword()) :: handle_result()
  def handle(%Config{} = config, payload, opts \\ []) when is_list(opts) do
    started_at = FailedCall.monotonic_now()

    FailedCall.protect(config, payload, :bridge, started_at, fn ->
      result =
        with {:ok, client_key} <- normalize_client_key(Keyword.get(opts, :client_key)),
             {:ok, state_key} <- normalize_state_key(Keyword.get(opts, :state_key)) do
          handle_payload(config, payload, client_key, state_key, Keyword.get(opts, :live_handle))
        else
          {:error, :invalid_client_key} ->
            {:error, :invalid_client_key}

          {:error, reason} ->
            {:ok, result(json_rpc_error(payload, -32_600, "Invalid Request", %{"reason" => Atom.to_string(reason)}), nil)}
        end

      observe_result(config, payload, result, started_at)
    end)
  end

  defp observe_result(config, payload, {:ok, %Result{} = result}, started_at) do
    response = FailedCall.observe_response(config, payload, result.response, :bridge, started_at)
    {:ok, %{result | response: response, status: response_status(response)}}
  end

  defp observe_result(config, payload, {:error, :invalid_client_key} = result, started_at) do
    :ok = FailedCall.observe_error(config, payload, -32_600, "Invalid Request", %{"reason" => "invalid_client_key"}, :bridge, started_at)
    result
  end

  defp observe_result(config, payload, {:error, :ledger_unavailable, _payload} = result, started_at) do
    :ok = FailedCall.observe_error(config, payload, -32_000, "Server error", %{"reason" => "ledger_unavailable"}, :bridge, started_at)
    result
  end

  defp handle_payload(%Config{} = config, payload, client_key, nil, _live_handle) do
    if initialize_request?(payload) do
      process_new_initialize(config, payload, client_key)
    else
      {:ok, result(transient_response(config, payload), nil)}
    end
  end

  defp handle_payload(%Config{} = config, payload, client_key, state_key, live_handle) do
    case HTTPStateStore.get(config, client_key, state_key) do
      %Server{} ->
        process_existing_state(config, payload, client_key, state_key, live_handle)

      nil ->
        handle_missing_state(config, payload, client_key, state_key, live_handle)
    end
  end

  defp handle_missing_state(%Config{} = config, payload, client_key, state_key, live_handle) when is_function(live_handle, 3) do
    case handle_with_live_repo(payload, client_key, state_key, live_handle) do
      {:error, :ledger_unavailable, ^payload} -> recover_or_unknown_state(config, payload, client_key, state_key)
      result -> result
    end
  end

  defp handle_missing_state(%Config{} = config, payload, client_key, state_key, _live_handle) do
    recover_or_unknown_state(config, payload, client_key, state_key)
  end

  defp handle_with_live_repo(payload, client_key, state_key, live_handle) do
    case live_handle.(payload, client_key, state_key) do
      %Result{} = result -> {:ok, result}
      {:ok, %Result{}} = result -> result
      {:error, :ledger_unavailable, ^payload} = error -> error
      {:error, _reason} -> {:error, :ledger_unavailable, payload}
    end
  end

  defp recover_or_unknown_state(%Config{} = config, payload, client_key, state_key) do
    case recover_existing_state(config, client_key, state_key) do
      {:ok, %Server{} = server} ->
        :ok = HTTPStateStore.put(config, client_key, state_key, server)
        process_existing_state(config, payload, client_key, state_key)

      :not_found ->
        {:ok, result(unknown_state_key_error(payload), nil)}
    end
  end

  defp process_new_initialize(%Config{} = config, payload, client_key) do
    state_key = new_state_key()

    process_state(config, payload, client_key, state_key, true, nil, fn ->
      Server.new(config, state_key: state_key, local_daemon_trusted: config.local_daemon_trusted)
    end)
  end

  defp process_existing_state(%Config{} = config, payload, client_key, state_key, live_handle \\ nil) do
    process_state(config, payload, client_key, state_key, false, live_handle, fn ->
      Server.new(config, state_key: state_key, local_daemon_trusted: config.local_daemon_trusted)
    end)
  end

  defp process_state(%Config{} = config, payload, client_key, state_key, allow_new_state?, live_handle, default_fun) do
    {{response, maybe_updated_server}, status} =
      HTTPStateStore.update_with_status(config, client_key, state_key, default_fun, fn %Server{} = server ->
        update_server(payload, allow_new_state?, live_handle, server)
      end)

    if response == :live_repo do
      handle_with_live_repo(payload, client_key, state_key, live_handle)
    else
      case status do
        :stored ->
          %Server{} = updated_server = maybe_updated_server
          SessionRecovery.remember(config, client_key, state_key, payload, updated_server, response)
          {:ok, result(response, state_key, HerdrBinding.response_binding(payload, response, updated_server))}

        :skipped ->
          {:ok, result(response, nil)}

        :dropped ->
          {:ok, result(state_update_lost_error(payload), nil)}
      end
    end
  end

  defp update_server(payload, allow_new_state?, live_handle, %Server{} = server) do
    cond do
      missing_state?(server) and not allow_new_state? ->
        # Keep the fallback server non-persistable so raced missing state keys stay absent.
        {{state_update_lost_error(payload), server}, server}

      repo_backed_followup?(payload, server) and is_function(live_handle, 3) ->
        {:bypass, :live_repo}

      true ->
        {response, %Server{} = updated_server} = Server.handle_response_state(payload, server)
        {{response, updated_server}, updated_server}
    end
  end

  defp recover_existing_state(%Config{} = config, client_key, state_key) do
    SessionRecovery.rehydrate(config, client_key, state_key)
  end

  defp transient_response(%Config{} = config, payload) do
    {response, _server} = Server.handle_response_state(payload, Server.new(config))
    response
  end

  defp missing_state?(%Server{initialized: false, session: nil}), do: true
  defp missing_state?(%Server{}), do: false

  defp result(response, state_key, herdr_binding \\ nil) do
    %Result{response: response, state_key: state_key, status: response_status(response), herdr_binding: herdr_binding}
  end

  defp response_status(nil), do: :no_response
  defp response_status([]), do: :no_response
  defp response_status(%{"error" => _error}), do: :error

  defp response_status(responses) when is_list(responses) do
    if Enum.all?(responses, &match?(%{"error" => _error}, &1)), do: :error, else: :ok
  end

  defp response_status(_response), do: :ok

  defp initialize_request?(%{"jsonrpc" => "2.0", "method" => "initialize"}), do: true
  defp initialize_request?(payloads) when is_list(payloads), do: Enum.any?(payloads, &initialize_request?/1)
  defp initialize_request?(_payload), do: false

  defp repo_backed_followup?(%{"method" => "tools/list"}, %Server{session: %Session{}}), do: true
  defp repo_backed_followup?(%{"method" => "resources/list"}, %Server{session: nil}), do: false
  defp repo_backed_followup?(payload, %Server{}), do: repo_backed_followup?(payload)

  defp repo_backed_followup?(%{"method" => "resources/list"}), do: true
  defp repo_backed_followup?(%{"method" => "resources/read", "params" => %{"uri" => uri}}), do: protected_resource_uri?(uri)
  defp repo_backed_followup?(%{"method" => "tools/call", "params" => %{"name" => "sympp.health"}}), do: false
  defp repo_backed_followup?(%{"method" => "tools/call"}), do: true
  defp repo_backed_followup?(_payload), do: false

  defp protected_resource_uri?(uri) when is_binary(uri) do
    uri == @assignment_resource or String.starts_with?(uri, @work_package_resource_prefix)
  end

  defp protected_resource_uri?(_uri), do: false

  defp normalize_client_key(client_key) when is_binary(client_key) do
    cond do
      client_key == "" -> {:error, :invalid_client_key}
      String.trim(client_key) == "" -> {:error, :invalid_client_key}
      byte_size(client_key) > @max_client_key_size -> {:error, :invalid_client_key}
      client_key in [@client_lock_key, @current_state_key, @unbound_client_key] -> {:error, :invalid_client_key}
      true -> {:ok, client_key}
    end
  end

  defp normalize_client_key(_client_key), do: {:error, :invalid_client_key}

  defp normalize_state_key(nil), do: {:ok, nil}
  defp normalize_state_key(""), do: {:ok, nil}

  defp normalize_state_key(state_key) when is_binary(state_key) do
    cond do
      String.trim(state_key) == "" -> {:error, :invalid_state_key}
      byte_size(state_key) > @max_state_key_size -> {:error, :invalid_state_key}
      reserved_state_key?(state_key) -> {:error, :reserved_state_key}
      true -> {:ok, state_key}
    end
  end

  defp normalize_state_key(_state_key), do: {:error, :invalid_state_key}

  defp unknown_state_key_error(payload) do
    json_rpc_error(payload, -32_600, "Invalid Request", %{"reason" => "unknown_state_key"})
  end

  defp state_update_lost_error(payload) do
    json_rpc_error(payload, -32_000, "Server error", %{"reason" => "state_update_lost"})
  end

  defp json_rpc_error([], code, message, data), do: error_response(nil, code, message, data)

  defp json_rpc_error(payloads, code, message, data) when is_list(payloads) do
    payloads
    |> Enum.map(&json_rpc_error(&1, code, message, data))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      errors -> errors
    end
  end

  defp json_rpc_error(%{"jsonrpc" => "2.0", "method" => method} = payload, code, message, data)
       when is_binary(method) do
    if Map.has_key?(payload, "id"), do: error_response(request_id(payload), code, message, data)
  end

  defp json_rpc_error(payload, code, message, data), do: error_response(request_id(payload), code, message, data)

  defp error_response(id, code, message, data) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message, "data" => data}}
  end

  defp request_id(%{"id" => id}) when is_binary(id) or is_number(id) or is_nil(id), do: id
  defp request_id(_payload), do: nil
end
