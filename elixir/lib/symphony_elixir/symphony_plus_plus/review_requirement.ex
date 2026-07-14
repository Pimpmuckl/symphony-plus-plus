defmodule SymphonyElixir.SymphonyPlusPlus.ReviewRequirement do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor

  @max_args_bytes 16_384
  @max_args_depth 8

  @type error_reason ::
          :invalid_review_requirement
          | :review_requirement_args_too_deep
          | :review_requirement_args_too_large
          | :sensitive_review_requirement

  @spec normalize(term()) :: {:ok, map() | nil} | {:error, error_reason()}
  def normalize(nil), do: {:ok, nil}

  def normalize(requirement) when is_map(requirement) do
    requirement = Map.new(requirement, fn {key, value} -> {to_string(key), value} end)

    with true <- Map.keys(requirement) |> Enum.all?(&(&1 in ["type", "args"])),
         type when is_binary(type) <- Map.get(requirement, "type"),
         type when type != "" <- String.trim(type),
         {:ok, args} <- normalize_args(Map.get(requirement, "args")) do
      normalized = %{"type" => type} |> maybe_put_args(args)

      if Redactor.redact_output(normalized) == normalized,
        do: {:ok, normalized},
        else: {:error, :sensitive_review_requirement}
    else
      {:error, reason}
      when reason in [:review_requirement_args_too_deep, :review_requirement_args_too_large] ->
        {:error, reason}

      _invalid ->
        {:error, :invalid_review_requirement}
    end
  end

  def normalize(_requirement), do: {:error, :invalid_review_requirement}

  @spec validation_error(term()) :: String.t() | nil
  def validation_error(requirement) do
    case normalize(requirement) do
      {:ok, ^requirement} -> nil
      {:ok, _normalized} -> "must use string keys and a trimmed non-empty type"
      {:error, :review_requirement_args_too_deep} -> "args must not exceed #{@max_args_depth} nested containers"
      {:error, :review_requirement_args_too_large} -> "args must not exceed #{@max_args_bytes} encoded bytes"
      {:error, :sensitive_review_requirement} -> "must not contain secrets"
      {:error, :invalid_review_requirement} -> "must contain a non-empty type and optional args object"
    end
  end

  defp normalize_args(nil), do: {:ok, nil}

  defp normalize_args(args) when is_map(args) do
    normalized = Redactor.json_safe(args)

    with true <- within_depth?(normalized, @max_args_depth),
         {:ok, encoded} <- Jason.encode(normalized) do
      if byte_size(encoded) <= @max_args_bytes,
        do: {:ok, normalized},
        else: {:error, :review_requirement_args_too_large}
    else
      false -> {:error, :review_requirement_args_too_deep}
      {:error, _reason} -> {:error, :invalid_review_requirement}
    end
  end

  defp normalize_args(_args), do: {:error, :invalid_review_requirement}

  defp within_depth?(value, remaining) when is_map(value) and remaining > 0,
    do: Enum.all?(value, fn {_key, nested} -> within_depth?(nested, remaining - 1) end)

  defp within_depth?(value, remaining) when is_list(value) and remaining > 0,
    do: Enum.all?(value, &within_depth?(&1, remaining - 1))

  defp within_depth?(value, _remaining) when is_map(value) or is_list(value), do: false
  defp within_depth?(_value, _remaining), do: true

  defp maybe_put_args(requirement, nil), do: requirement
  defp maybe_put_args(requirement, args), do: Map.put(requirement, "args", args)
end
