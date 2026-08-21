defmodule SymphonyElixir.SymphonyPlusPlus.MCP.FailedCall do
  @moduledoc false

  require Logger

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Health, Surface, ToolCatalog}
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository

  @event "sympp_failed_mcp_call"
  @boundary_key {__MODULE__, :boundary}
  @store Module.concat(__MODULE__, Store)
  @max_argument_keys 16
  @safe_argument_key ~r/\A[A-Za-z][A-Za-z0-9_]{0,63}\z/
  @sensitive_argument_key ~r/(authorization|bearer|cookie|credential|password|secret|token)/i
  @safe_identity ~r/\A[0-9a-f]{7,64}\z/i
  @safe_reasons ~w(
    already_initialized
    architect_grant_required
    batch_not_supported
    branch_scope_mismatch
    body_read_failed
    body_too_large
    claim_required
    dangerous_action_requires_operator
    empty_batch
    initialize_must_be_standalone
    insufficient_capability
    insufficient_role
    invalid_client_key
    invalid_json
    invalid_method
    invalid_params
    invalid_request
    invalid_request_id
    invalid_session_id
    invalid_tool_arguments
    invalid_transition
    ledger_unavailable
    local_daemon_trust_required
    local_mcp_required
    local_mcp_session_required
    method_not_found
    missing_method
    missing_protocol_version
    missing_session
    missing_session_id
    not_found
    outside_session_scope
    params_must_be_object
    params_must_be_object_or_array
    precondition_failed
    request_must_be_object
    runtime_lease_conflict
    scope_mismatch
    server_not_initialized
    state_update_lost
    target_ambiguous
    target_not_found
    unexpected_argument
    unhandled_tool_failure
    unknown_action
    unknown_state_key
    worker_grant_required
  )

  defmodule Descriptor do
    @moduledoc false

    @enforce_keys [:classification, :reason, :layer, :public_data, :recovery]
    defstruct [:classification, :reason, :layer, :public_data, :recovery, :cause_kind]

    @type t :: %__MODULE__{
            classification: String.t(),
            reason: String.t(),
            layer: String.t(),
            public_data: map(),
            recovery: map(),
            cause_kind: String.t() | nil
          }
  end

  @spec monotonic_now() :: integer()
  def monotonic_now, do: System.monotonic_time()

  @spec protect(Config.t() | map(), term(), atom(), integer(), (-> result)) :: result when result: term()
  def protect(context, payload, layer, started_at, fun) when is_function(fun, 0) do
    root? = Process.get(@boundary_key) == nil
    if root?, do: Process.put(@boundary_key, %{failure: nil})

    try do
      fun.()
    rescue
      exception ->
        observe_cause_once(context, payload, layer, "exception", started_at)
        reraise(exception, __STACKTRACE__)
    catch
      kind, reason ->
        observe_cause_once(context, payload, layer, cause_kind(kind), started_at)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      if root?, do: Process.delete(@boundary_key)
    end
  end

  @spec observe_response(Config.t() | map(), term(), term(), atom(), integer()) :: term()
  def observe_response(context, payload, response, layer, started_at) do
    cond do
      not tool_call?(payload) ->
        response

      diagnostic_response?(response) ->
        response

      failure = remembered_failure() ->
        attach_diagnostic(response, failure)

      descriptor = descriptor_from_response(response, layer) ->
        capture_response(context, payload, response, descriptor, started_at)

      true ->
        response
    end
  end

  @spec observe_error(Config.t() | map(), term(), integer(), String.t(), map(), atom(), integer()) :: :ok
  def observe_error(context, payload, code, message, data, layer, started_at)
      when is_integer(code) and is_binary(message) and is_map(data) do
    if remembered_failure() == nil do
      payload
      |> tool_call_items()
      |> Enum.each(&observe_error_item(context, &1, code, data, layer, started_at))
    end

    :ok
  end

  defp observe_error_item(context, item, code, data, layer, started_at) do
    case capture(context, item, descriptor(code, data, layer), started_at) do
      nil -> :ok
      failure -> remember_failure(failure)
    end
  end

  @spec summary() :: map()
  def summary do
    case store() do
      pid when is_pid(pid) -> Agent.get(pid, &summary_payload/1, 1_000)
      _unavailable -> unavailable_summary()
    end
  rescue
    _error -> unavailable_summary()
  catch
    _kind, _reason -> unavailable_summary()
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    case store() do
      pid when is_pid(pid) -> Agent.update(pid, &reset_store_state/1)
      _unavailable -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp capture_response(context, payload, response, descriptor, started_at) do
    case capture(context, payload, descriptor, started_at) do
      nil -> response
      failure -> attach_diagnostic(response, failure)
    end
  end

  defp capture(context, payload, %Descriptor{} = descriptor, started_at) do
    with true <- capture_enabled?(context),
         diagnostic_id = diagnostic_id(),
         envelope = envelope(context, payload, descriptor, diagnostic_id, started_at),
         :ok <- emit(envelope) do
      {diagnostic_id, descriptor}
    else
      _disabled_or_unavailable -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp capture_enabled?(context) do
    case OperatorSettingsRepository.get(config(context).repo) do
      {:ok, %{capture_failed_mcp_calls: true}} -> true
      _disabled_or_unavailable -> false
    end
  end

  defp config(%Config{} = config), do: config
  defp config(%{config: %Config{} = config}), do: config

  defp descriptor_from_response(%{"error" => %{"code" => code, "data" => data}}, layer)
       when is_integer(code) and is_map(data),
       do: descriptor(code, data, layer)

  defp descriptor_from_response(_response, _layer), do: nil

  defp descriptor(code, data, layer) do
    classification = classification(code)
    reason = failure_reason(data, classification)
    default_recovery = recovery(classification, reason)
    recovery = safe_existing_recovery(data["recovery"]) || default_recovery

    %Descriptor{
      classification: classification,
      reason: reason,
      layer: Atom.to_string(layer),
      public_data: Map.put_new(data, "recovery", default_recovery),
      recovery: recovery
    }
  end

  defp exception_descriptor(layer, cause_kind) do
    classification = "server_error"
    reason = "unhandled_tool_failure"
    recovery = recovery(classification, reason)

    %Descriptor{
      classification: classification,
      reason: reason,
      layer: Atom.to_string(layer),
      public_data: %{"reason" => reason, "recovery" => recovery},
      recovery: recovery,
      cause_kind: cause_kind
    }
  end

  defp observe_cause_once(config, payload, layer, cause_kind, started_at) do
    if remembered_failure() == nil and tool_call?(payload) do
      case capture(config, payload, exception_descriptor(layer, cause_kind), started_at) do
        nil -> :ok
        failure -> remember_failure(failure)
      end
    end
  end

  defp envelope(context, payload, descriptor, diagnostic_id, started_at) do
    {tool_name, argument_keys, unsafe_count, truncated_count} = safe_tool_metadata(context, payload)
    source = source_identity(config(context))

    %{
      "argument_keys" => argument_keys,
      "argument_keys_truncated" => truncated_count,
      "cause_kind" => descriptor.cause_kind,
      "diagnostic_id" => diagnostic_id,
      "duration_ms" => duration_ms(started_at),
      "error_classification" => descriptor.classification,
      "event" => @event,
      "failure_layer" => descriptor.layer,
      "failure_reason" => descriptor.reason,
      "mcp_contract_fingerprint" => source.fingerprint,
      "observed_at" => observed_at(),
      "recovery" => descriptor.recovery,
      "source_revision" => source.revision,
      "tool_name" => tool_name,
      "unsafe_argument_name_count" => unsafe_count
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp emit(envelope) do
    Logger.warning(Jason.encode!(envelope))
    record(envelope)
    :ok
  end

  defp record(envelope) do
    case store() do
      pid when is_pid(pid) -> Agent.update(pid, &record_envelope(&1, envelope), 1_000)
      _unavailable -> :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp store do
    case Process.whereis(@store) do
      pid when is_pid(pid) -> pid
      nil -> start_store()
    end
  end

  defp start_store do
    case Agent.start(fn -> new_store_state() end, name: @store) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
      {:error, _reason} -> nil
    end
  rescue
    _error -> nil
  end

  defp new_store_state do
    now = observed_at()
    %{observation_started_at: now, last_reset_at: now, groups: %{}}
  end

  defp reset_store_state(state) do
    %{observation_started_at: state.observation_started_at, last_reset_at: observed_at(), groups: %{}}
  end

  defp record_envelope(state, envelope) do
    key = group_key(envelope)
    observed_at = envelope["observed_at"]

    groups =
      Map.update(state.groups, key, new_group(envelope), fn group ->
        %{group | "count" => group["count"] + 1, "last_observed_at" => observed_at}
      end)

    %{state | groups: groups}
  end

  defp group_key(envelope) do
    {
      envelope["source_revision"],
      envelope["mcp_contract_fingerprint"],
      envelope["error_classification"],
      envelope["failure_reason"],
      envelope["failure_layer"],
      envelope["tool_name"],
      get_in(envelope, ["recovery", "next_action"])
    }
  end

  defp new_group(envelope) do
    %{
      "count" => 1,
      "error_classification" => envelope["error_classification"],
      "failure_layer" => envelope["failure_layer"],
      "failure_reason" => envelope["failure_reason"],
      "first_observed_at" => envelope["observed_at"],
      "last_observed_at" => envelope["observed_at"],
      "recovery" => envelope["recovery"],
      "source_identity" => %{
        "mcp_contract_fingerprint" => envelope["mcp_contract_fingerprint"],
        "source_revision" => envelope["source_revision"]
      },
      "tool_name" => envelope["tool_name"]
    }
  end

  defp summary_payload(state) do
    groups = state.groups |> Map.values() |> Enum.sort_by(&summary_sort_key/1)

    %{
      "durability" => "process_local",
      "groups" => groups,
      "last_reset_at" => state.last_reset_at,
      "observation_started_at" => state.observation_started_at,
      "source_identities" => groups |> Enum.map(& &1["source_identity"]) |> Enum.uniq(),
      "status" => "ok",
      "total_failures" => Enum.sum(Enum.map(groups, & &1["count"]))
    }
  end

  defp summary_sort_key(group) do
    [
      get_in(group, ["source_identity", "source_revision"]) || "",
      group["error_classification"],
      group["failure_reason"],
      group["failure_layer"],
      group["tool_name"],
      get_in(group, ["recovery", "next_action"])
    ]
  end

  defp unavailable_summary do
    %{
      "durability" => "process_local",
      "groups" => [],
      "last_reset_at" => nil,
      "observation_started_at" => nil,
      "source_identities" => [],
      "status" => "unavailable",
      "total_failures" => 0
    }
  end

  defp safe_tool_metadata(context, %{"params" => %{"name" => tool_name} = params}) when is_binary(tool_name) do
    with {:ok, specs} <- tool_specs(context),
         %{"name" => safe_tool_name} = spec <- Enum.find(specs, &(&1["name"] == tool_name)) do
      {keys, unsafe_count, truncated_count} = safe_argument_keys(params, spec)
      {safe_tool_name, keys, unsafe_count, truncated_count}
    else
      _unknown_or_unavailable -> {if(ToolCatalog.known_tool?(tool_name), do: tool_name, else: "unknown"), [], 0, 0}
    end
  end

  defp safe_tool_metadata(_context, _payload), do: {"unknown", [], 0, 0}

  defp tool_specs(%{config: %Config{}} = server), do: Surface.tool_specs_for_server(server)
  defp tool_specs(%Config{}), do: {:error, :server_context_required}

  defp safe_argument_keys(%{"arguments" => arguments}, %{"inputSchema" => %{"properties" => properties}})
       when is_map(arguments) and is_map(properties) do
    known = properties |> Map.keys() |> Enum.filter(&Map.has_key?(arguments, &1))
    unexpected = Map.keys(arguments) -- Map.keys(properties)
    safe_unexpected = Enum.filter(unexpected, &safe_unexpected_argument_key?/1)
    unsafe_count = length(unexpected) - length(safe_unexpected)
    safe_keys = (known ++ safe_unexpected) |> Enum.uniq() |> Enum.sort()
    {Enum.take(safe_keys, @max_argument_keys), unsafe_count, max(length(safe_keys) - @max_argument_keys, 0)}
  end

  defp safe_argument_keys(_params, _spec), do: {[], 0, 0}

  defp safe_unexpected_argument_key?(key) when is_binary(key),
    do: Regex.match?(@safe_argument_key, key) and not Regex.match?(@sensitive_argument_key, key)

  defp safe_unexpected_argument_key?(_key), do: false

  defp source_identity(config) do
    source = Health.source_identity(config)

    %{
      revision: safe_identity(source["revision"]),
      fingerprint: safe_identity(get_in(source, ["mcp_contract", "fingerprint"]))
    }
  end

  defp safe_identity(value) when is_binary(value) do
    if Regex.match?(@safe_identity, value), do: String.downcase(value)
  end

  defp safe_identity(_value), do: nil

  defp failure_reason(data, classification) do
    Enum.find_value([data["reason_code"], data["reason"]], fn
      reason when reason in @safe_reasons -> reason
      _unsafe -> nil
    end) || default_reason(classification)
  end

  defp default_reason("method_not_found"), do: "method_not_found"
  defp default_reason("invalid_request"), do: "invalid_request"
  defp default_reason("invalid_params"), do: "invalid_params"
  defp default_reason("unauthorized"), do: "missing_session"
  defp default_reason("forbidden"), do: "outside_session_scope"
  defp default_reason("not_found"), do: "not_found"
  defp default_reason("precondition_failed"), do: "precondition_failed"
  defp default_reason(_classification), do: "unhandled_tool_failure"

  defp classification(-32_600), do: "invalid_request"
  defp classification(-32_601), do: "method_not_found"
  defp classification(-32_602), do: "invalid_params"
  defp classification(-32_001), do: "unauthorized"
  defp classification(-32_003), do: "forbidden"
  defp classification(-32_004), do: "not_found"
  defp classification(-32_009), do: "precondition_failed"
  defp classification(_code), do: "server_error"

  defp recovery("method_not_found", _reason), do: %{"next_action" => "list_available_tools"}
  defp recovery("invalid_request", _reason), do: %{"next_action" => "fix_request"}
  defp recovery("invalid_params", _reason), do: %{"next_action" => "fix_tool_arguments"}
  defp recovery("unauthorized", _reason), do: %{"next_action" => "claim_or_reconnect"}
  defp recovery("forbidden", _reason), do: %{"next_action" => "use_authorized_scope"}
  defp recovery("not_found", _reason), do: %{"next_action" => "verify_target"}
  defp recovery("precondition_failed", _reason), do: %{"next_action" => "satisfy_precondition"}
  defp recovery(_classification, _reason), do: %{"next_action" => "retry_or_check_health"}

  defp safe_existing_recovery(%{
         "fresh_mcp_session_required" => fresh_session?,
         "next_action" => "call_release_current_assignment_then_retry_solo_tool",
         "tool" => "release_current_assignment"
       })
       when is_boolean(fresh_session?) do
    %{
      "fresh_mcp_session_required" => fresh_session?,
      "next_action" => "call_release_current_assignment_then_retry_solo_tool",
      "tool" => "release_current_assignment"
    }
  end

  defp safe_existing_recovery(_recovery), do: nil

  defp attach_diagnostic(response, {diagnostic_id, %Descriptor{} = descriptor}) do
    case response do
      %{"error" => %{"data" => data} = error} when is_map(data) ->
        %{response | "error" => %{error | "data" => descriptor.public_data |> Map.put("diagnostic_id", diagnostic_id)}}

      _response ->
        response
    end
  end

  defp diagnostic_response?(%{"error" => %{"data" => %{"diagnostic_id" => id}}}) when is_binary(id), do: true
  defp diagnostic_response?(_response), do: false

  defp tool_call?(%{"jsonrpc" => "2.0", "method" => "tools/call"}), do: true
  defp tool_call?(_payload), do: false

  defp tool_call_items(payloads) when is_list(payloads), do: Enum.filter(payloads, &tool_call?/1)
  defp tool_call_items(payload), do: if(tool_call?(payload), do: [payload], else: [])

  defp duration_ms(started_at) do
    monotonic_now()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
    |> max(0)
  end

  defp observed_at, do: DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
  defp diagnostic_id, do: "mcpdiag_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp remembered_failure do
    case Process.get(@boundary_key) do
      %{failure: failure} -> failure
      _missing -> nil
    end
  end

  defp remember_failure(failure) do
    case Process.get(@boundary_key) do
      %{} = boundary -> Process.put(@boundary_key, %{boundary | failure: boundary.failure || failure})
      _missing -> :ok
    end
  end

  defp cause_kind(:exit), do: "exit"
  defp cause_kind(:throw), do: "throw"
  defp cause_kind(_kind), do: "exception"
end
