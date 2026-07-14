defmodule SymphonyElixir.SymphonyPlusPlus.ReviewRequirement do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor

  @spec normalize(term()) :: {:ok, map() | nil} | {:error, :invalid_review_requirement | :sensitive_review_requirement}
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
      _invalid -> {:error, :invalid_review_requirement}
    end
  end

  def normalize(_requirement), do: {:error, :invalid_review_requirement}

  @spec validation_error(term()) :: String.t() | nil
  def validation_error(requirement) do
    case normalize(requirement) do
      {:ok, ^requirement} -> nil
      {:ok, _normalized} -> "must use string keys and a trimmed non-empty type"
      {:error, :sensitive_review_requirement} -> "must not contain secrets"
      {:error, :invalid_review_requirement} -> "must contain a non-empty type and optional args object"
    end
  end

  defp normalize_args(nil), do: {:ok, nil}
  defp normalize_args(args) when is_map(args), do: {:ok, Redactor.json_safe(args)}
  defp normalize_args(_args), do: {:error, :invalid_review_requirement}

  defp maybe_put_args(requirement, nil), do: requirement
  defp maybe_put_args(requirement, args), do: Map.put(requirement, "args", args)
end
