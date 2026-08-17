defmodule SymphonyElixir.SymphonyPlusPlus.BaseBranch do
  @moduledoc false

  @main_refs ["main", "refs/heads/main", "origin/main", "refs/remotes/origin/main"]

  @spec canonicalize(term()) :: term()
  def canonicalize(value) when is_binary(value) do
    value = String.trim(value)
    if value in @main_refs, do: "main", else: value
  end

  def canonicalize(value), do: value

  @spec equivalent?(term(), term()) :: boolean()
  def equivalent?(left, right) when is_binary(left) and is_binary(right) do
    canonicalize(left) == canonicalize(right)
  end

  def equivalent?(_left, _right), do: false

  @spec equivalent_refs(term()) :: [term()]
  def equivalent_refs(value) do
    case canonicalize(value) do
      "main" -> @main_refs
      canonical -> [canonical]
    end
  end

  @spec canonicalize_attrs(map()) :: map()
  def canonicalize_attrs(attrs) when is_map(attrs) do
    case Map.fetch(attrs, "base_branch") do
      {:ok, value} -> Map.put(attrs, "base_branch", canonicalize(value))
      :error -> attrs
    end
  end
end
