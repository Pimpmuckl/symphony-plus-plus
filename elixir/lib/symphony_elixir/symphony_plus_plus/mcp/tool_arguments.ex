defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog

  @assignment_release_tool ToolCatalog.assignment_release_tool()
  @local_architect_assignment_claim_tool ToolCatalog.local_architect_assignment_claim_tool()

  @type arguments :: %{optional(String.t()) => term()}
  @type tool_call_result :: {:ok, arguments()} | {:error, integer(), String.t(), map()}
  @type tool_error :: {:tool_error, String.t()}

  @spec solo_tool_arguments(map(), String.t()) :: tool_call_result()
  def solo_tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_solo_arguments(name, arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  @spec worker_tool_arguments(map(), String.t()) :: tool_call_result()
  def worker_tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_worker_arguments(name, arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  @spec local_architect_assignment_claim_tool_arguments(map()) :: tool_call_result()
  def local_architect_assignment_claim_tool_arguments(params) do
    schema_tool_arguments(
      params,
      @local_architect_assignment_claim_tool,
      ToolCatalog.local_architect_assignment_claim_tool_input_schema()
    )
  end

  @spec assignment_release_tool_arguments(map()) :: tool_call_result()
  def assignment_release_tool_arguments(params) do
    schema_tool_arguments(params, @assignment_release_tool, ToolCatalog.assignment_release_tool_input_schema())
  end

  defp schema_tool_arguments(params, name, schema) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_schema_arguments(name, schema, arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  @spec local_operator_tool_arguments(map(), String.t()) :: tool_call_result()
  def local_operator_tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_local_operator_arguments(name, arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  @spec architect_tool_arguments(map(), String.t()) :: tool_call_result()
  def architect_tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_architect_arguments(name, arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  @spec bootstrap_tool_arguments(map(), String.t()) :: tool_call_result()
  def bootstrap_tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_bootstrap_arguments(name, arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  @spec optional_string_argument(arguments(), String.t(), String.t() | nil) ::
          {:ok, String.t() | nil} | tool_error()
  def optional_string_argument(arguments, key, default \\ nil) do
    case Map.fetch(arguments, key) do
      :error ->
        {:ok, default}

      {:ok, nil} ->
        {:ok, default}

      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, default}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _value} ->
        {:tool_error, "invalid_#{key}"}
    end
  end

  @spec optional_string_list_argument(arguments(), String.t()) :: {:ok, [String.t()]} | tool_error()
  def optional_string_list_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error ->
        {:ok, []}

      {:ok, nil} ->
        {:ok, []}

      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &is_binary/1) do
          values =
            values
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.uniq()

          {:ok, values}
        else
          {:tool_error, "invalid_#{key}"}
        end

      {:ok, _value} ->
        {:tool_error, "invalid_#{key}"}
    end
  end

  @spec optional_positive_integer_argument(arguments(), String.t()) :: {:ok, pos_integer() | nil} | tool_error()
  def optional_positive_integer_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  @spec optional_nonnegative_integer_argument(arguments(), String.t()) :: {:ok, non_neg_integer() | nil} | tool_error()
  def optional_nonnegative_integer_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  @spec required_string_array(arguments(), String.t()) :: {:ok, [String.t()]} | tool_error()
  def required_string_array(arguments, key) do
    case Map.fetch(arguments, key) do
      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
          {:ok, Enum.map(values, &String.trim/1)}
        else
          {:tool_error, "invalid_#{key}"}
        end

      :error ->
        {:tool_error, "missing_#{key}"}

      {:ok, _values} ->
        {:tool_error, "invalid_#{key}"}
    end
  end

  @spec required_argument(arguments(), String.t()) :: {:ok, String.t()} | tool_error()
  def required_argument(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "missing_#{key}"}
    end
  end

  @spec required_object(arguments(), String.t()) :: {:ok, map()} | tool_error()
  def required_object(arguments, key) do
    case Map.get(arguments, key) do
      value when is_map(value) -> {:ok, value}
      _value -> {:tool_error, "missing_#{key}"}
    end
  end

  @spec optional_object_argument(arguments(), String.t()) :: {:ok, map() | nil} | tool_error()
  def optional_object_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  @spec optional_list_argument(arguments(), String.t()) :: {:ok, list() | nil} | tool_error()
  def optional_list_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_list(value) -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  @spec optional_boolean(arguments(), String.t(), boolean()) :: {:ok, boolean()} | tool_error()
  def optional_boolean(arguments, key, default) do
    case Map.fetch(arguments, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
      :error -> {:ok, default}
    end
  end

  @spec optional_argument(arguments(), String.t(), term()) :: term()
  def optional_argument(arguments, key, default) do
    case Map.get(arguments, key, default) do
      value when is_binary(value) -> if String.trim(value) == "", do: default, else: value
      nil -> default
      value -> value
    end
  end

  @spec validate_tool_required_arguments(map(), arguments()) :: :ok | {:error, String.t()}
  def validate_tool_required_arguments(schema, arguments) do
    properties = Map.get(schema, "properties", %{})

    schema
    |> Map.get("required", [])
    |> Enum.find_value(:ok, fn key ->
      case validate_required_architect_argument(arguments, properties, key) do
        :ok -> nil
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp validate_worker_arguments(name, arguments) do
    allowed = MapSet.new(allowed_worker_argument_keys(name))
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected == [] do
      normalize_implied_status(name, arguments)
    else
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    end
  end

  defp validate_solo_arguments(name, arguments) do
    allowed = MapSet.new(allowed_solo_argument_keys(name))
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected == [] do
      {:ok, arguments}
    else
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    end
  end

  defp validate_schema_arguments(name, schema, arguments) do
    allowed = schema |> Map.get("properties", %{}) |> Map.keys() |> MapSet.new()
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected != [] do
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    else
      case validate_tool_required_arguments(schema, arguments) do
        :ok -> {:ok, arguments}
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => reason}}
      end
    end
  end

  defp validate_local_operator_arguments(name, arguments) do
    allowed = MapSet.new(allowed_local_operator_argument_keys(name))
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected != [] do
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    else
      schema = ToolCatalog.local_operator_tool_input_schema(name)

      case validate_tool_required_arguments(schema, arguments) do
        :ok -> validate_local_operator_argument_values(name, schema, arguments)
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => reason}}
      end
    end
  end

  defp validate_local_operator_argument_values(name, schema, arguments) do
    properties = Map.get(schema, "properties", %{})

    arguments
    |> Enum.find_value(:ok, fn {key, value} ->
      case validate_local_operator_argument_value(properties, key, value) do
        :ok -> nil
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => reason}}
      end
    end)
    |> case do
      :ok -> {:ok, arguments}
      error -> error
    end
  end

  defp validate_local_operator_argument_value(properties, key, value) do
    case Map.get(properties, key, %{}) do
      %{"type" => "string"} = property -> validate_local_operator_string_argument(key, value, property)
      _property -> :ok
    end
  end

  defp validate_local_operator_string_argument(key, value, property) when is_binary(value) do
    max_length = Map.get(property, "maxLength")

    if is_integer(max_length) and String.length(value) > max_length,
      do: {:error, "#{key}_too_long"},
      else: :ok
  end

  defp validate_local_operator_string_argument(key, _value, _property), do: {:error, "invalid_#{key}"}

  defp validate_architect_arguments(name, arguments) do
    allowed = MapSet.new(allowed_architect_argument_keys(name))
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected != [] do
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    else
      case validate_tool_required_arguments(ToolCatalog.architect_tool_input_schema(name), arguments) do
        :ok -> normalize_implied_status(name, arguments)
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => reason}}
      end
    end
  end

  defp normalize_implied_status(name, arguments) do
    expected_status = %{"resolve_blocker" => "resolved"}[name]

    case {expected_status, Map.fetch(arguments, "status")} do
      {nil, _status} ->
        {:ok, arguments}

      {_expected, :error} ->
        {:ok, arguments}

      {expected, {:ok, status}} when status == expected ->
        {:ok, Map.delete(arguments, "status")}

      {expected, {:ok, _status}} ->
        {:error, -32_602, "Invalid params",
         %{
           "tool" => name,
           "reason" => "implied_status_mismatch",
           "expected_status" => expected,
           "recovery" => %{"next_action" => "omit_status_or_use_expected", "expected_status" => expected}
         }}
    end
  end

  defp validate_bootstrap_arguments(name, arguments) do
    allowed = MapSet.new(allowed_bootstrap_argument_keys(name))
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected != [] do
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    else
      validation_arguments = bootstrap_validation_arguments(name, arguments)

      case validate_tool_required_arguments(ToolCatalog.bootstrap_tool_input_schema(name), validation_arguments) do
        :ok -> {:ok, arguments}
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => reason}}
      end
    end
  end

  defp allowed_solo_argument_keys(name) do
    name
    |> ToolCatalog.solo_tool_input_schema()
    |> Map.get("properties", %{})
    |> Map.keys()
  end

  defp allowed_worker_argument_keys(name) do
    name
    |> ToolCatalog.worker_tool_input_schema()
    |> Map.get("properties", %{})
    |> Map.keys()
    |> Kernel.++(ToolCatalog.hidden_worker_argument_keys(name))
  end

  defp allowed_local_operator_argument_keys(name) do
    name
    |> ToolCatalog.local_operator_tool_input_schema()
    |> Map.get("properties", %{})
    |> Map.keys()
  end

  defp allowed_architect_argument_keys(name) do
    name
    |> ToolCatalog.architect_tool_input_schema()
    |> Map.get("properties", %{})
    |> Map.keys()
  end

  defp allowed_bootstrap_argument_keys(name) do
    name
    |> ToolCatalog.bootstrap_tool_input_schema()
    |> Map.get("properties", %{})
    |> Map.keys()
  end

  defp bootstrap_validation_arguments("create_work_request", arguments) do
    if blank_argument?(Map.get(arguments, "description")) and nonblank_argument?(Map.get(arguments, "human_description")) do
      Map.put(arguments, "description", Map.get(arguments, "human_description"))
    else
      arguments
    end
  end

  defp bootstrap_validation_arguments(_name, arguments), do: arguments

  defp blank_argument?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_argument?(nil), do: true
  defp blank_argument?(_value), do: false

  defp nonblank_argument?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank_argument?(_value), do: false

  defp validate_required_architect_argument(arguments, properties, key) do
    case Map.fetch(arguments, key) do
      :error -> {:error, "missing_#{key}"}
      {:ok, nil} -> {:error, "missing_#{key}"}
      {:ok, value} -> validate_required_architect_argument_value(properties, key, value)
    end
  end

  defp validate_required_architect_argument_value(properties, key, value) do
    case get_in(properties, [key, "type"]) do
      "string" -> validate_required_architect_string_argument(key, value)
      "object" -> validate_required_architect_object_argument(key, value)
      "array" -> validate_required_architect_array_argument_value(properties, key, value)
      "integer" -> validate_required_architect_integer_argument(properties, key, value)
      _type -> {:error, "invalid_#{key}"}
    end
  end

  defp validate_required_architect_string_argument(key, value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, "missing_#{key}"}, else: :ok
  end

  defp validate_required_architect_string_argument(key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_architect_object_argument(_key, value) when is_map(value), do: :ok
  defp validate_required_architect_object_argument(key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_architect_integer_argument(properties, key, value) when is_integer(value) do
    minimum = properties |> Map.get(key, %{}) |> Map.get("minimum")

    if is_integer(minimum) and value < minimum, do: {:error, "invalid_#{key}"}, else: :ok
  end

  defp validate_required_architect_integer_argument(_properties, key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_architect_array_argument_value(properties, key, values) when is_list(values) do
    validate_required_architect_array_argument(properties, key, values)
  end

  defp validate_required_architect_array_argument_value(_properties, key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_architect_array_argument(properties, key, values) do
    cond do
      properties |> Map.get(key, %{}) |> Map.get("minItems", 0) > 0 and values == [] ->
        {:error, "missing_#{key}"}

      get_in(properties, [key, "items", "type"]) == "string" ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")), do: :ok, else: {:error, "invalid_#{key}"}

      true ->
        if Enum.all?(values, &is_map/1), do: :ok, else: {:error, "invalid_#{key}"}
    end
  end
end
