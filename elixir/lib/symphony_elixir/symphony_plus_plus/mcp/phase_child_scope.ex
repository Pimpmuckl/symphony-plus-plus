defmodule SymphonyElixir.SymphonyPlusPlus.MCP.PhaseChildScope do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @type globs_result :: {:ok, [String.t()]} | {:tool_error, String.t()}
  @type scope_result :: :ok | {:tool_error, String.t()} | {:error, :phase_scope_not_available}

  @spec context_anchor(module(), WorkPackage.t()) :: {:ok, WorkPackage.t()} | {:error, term()}
  def context_anchor(_repo, %WorkPackage{kind: kind} = work_package) when kind != "phase_child", do: {:ok, work_package}

  def context_anchor(repo, %WorkPackage{parent_id: parent_id} = child) when is_binary(parent_id) do
    with {:ok, anchor} <- WorkPackageRepository.get(repo, parent_id),
         :ok <- require_scope(child, anchor) do
      {:ok, anchor}
    else
      {:error, :not_found} -> {:error, :forbidden}
      {:error, :phase_scope_not_available} -> {:error, :forbidden}
      {:tool_error, _reason} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  def context_anchor(_repo, %WorkPackage{}), do: {:error, :forbidden}

  @spec require_scope(WorkPackage.t(), WorkPackage.t()) :: scope_result()
  def require_scope(%WorkPackage{kind: "phase_child"} = child, %WorkPackage{} = anchor) do
    cond do
      child.parent_id != anchor.id -> {:error, :phase_scope_not_available}
      child.phase_id != anchor.phase_id -> {:error, :phase_scope_not_available}
      not repo_scope_match?(child.repo, anchor.repo) -> {:tool_error, "repo_scope_mismatch"}
      child.base_branch != anchor.base_branch -> {:tool_error, "base_branch_scope_mismatch"}
      true -> require_file_scope(child, anchor)
    end
  end

  def require_scope(%WorkPackage{}, %WorkPackage{}), do: {:error, :phase_scope_not_available}

  @spec require_file_scope(WorkPackage.t(), WorkPackage.t()) :: scope_result()
  def require_file_scope(%WorkPackage{} = child, %WorkPackage{} = anchor) do
    with {:ok, anchor_globs} <- normalize_child_scope_globs(anchor.allowed_file_globs || []),
         {:ok, child_globs} <- normalize_child_scope_globs(child.allowed_file_globs || []),
         :ok <- require_child_file_scope_present(child_globs),
         :ok <- reject_overbroad_child_globs(child_globs) do
      require_child_globs_within_anchor(child_globs, anchor_globs)
    end
  end

  @spec child_allowed_file_globs(map(), WorkPackage.t()) :: globs_result()
  def child_allowed_file_globs(package, %WorkPackage{} = anchor) do
    with {:ok, default_globs} <- normalize_child_scope_globs(anchor.allowed_file_globs || []),
         {:ok, globs} <- optional_child_string_list(package, "allowed_file_globs", default_globs),
         :ok <- require_child_file_scope_present(globs),
         :ok <- reject_overbroad_child_globs(globs),
         :ok <- require_child_globs_within_anchor(globs, default_globs) do
      {:ok, globs}
    end
  end

  defp require_child_file_scope_present([]), do: {:tool_error, "missing_allowed_file_globs"}
  defp require_child_file_scope_present(_globs), do: :ok

  defp reject_overbroad_child_globs(globs) do
    if Enum.any?(globs, &ScopeGuard.overbroad_glob?/1) do
      {:tool_error, "overbroad_allowed_file_globs"}
    else
      :ok
    end
  end

  defp require_child_globs_within_anchor(_child_globs, []), do: :ok

  defp require_child_globs_within_anchor(child_globs, anchor_globs) do
    if Enum.all?(child_globs, &glob_within_any_anchor?(&1, anchor_globs)) do
      :ok
    else
      {:tool_error, "child_scope_outside_phase"}
    end
  end

  defp glob_within_any_anchor?(child_glob, anchor_globs) do
    Enum.any?(anchor_globs, &glob_within_anchor?(child_glob, &1))
  end

  defp glob_within_anchor?(child_glob, anchor_glob) do
    with {:ok, child_segments} <- child_glob_segments(child_glob),
         {:ok, anchor_segments} <- child_glob_segments(anchor_glob) do
      glob_segments_within?(child_segments, anchor_segments)
    else
      {:tool_error, _reason} -> false
    end
  end

  defp child_glob_segments(glob) do
    glob = normalize_child_glob(glob)

    cond do
      glob == "" -> {:tool_error, "missing_allowed_file_globs"}
      traversal_glob?(glob) -> {:tool_error, "path_traversal_allowed_file_globs"}
      encoded_separator_glob?(glob) -> {:tool_error, "invalid_allowed_file_globs"}
      true -> {:ok, String.split(glob, "/", trim: true)}
    end
  end

  defp glob_segments_within?([], []), do: true
  defp glob_segments_within?([], _anchor_segments), do: false
  defp glob_segments_within?(_child_segments, []), do: false
  defp glob_segments_within?(child_segments, ["**"]), do: not Enum.any?(child_segments, &traversal_segment?/1)

  defp glob_segments_within?(["**" | child_tail], ["**" | anchor_tail]) do
    glob_segments_within?(child_tail, ["**" | anchor_tail])
  end

  defp glob_segments_within?([_child_head | child_tail] = child_segments, ["**" | anchor_tail]) do
    glob_segments_within?(child_segments, anchor_tail) or
      glob_segments_within?(child_tail, ["**" | anchor_tail])
  end

  defp glob_segments_within?(["**" | _child_tail], [_anchor_head | _anchor_tail]), do: false

  defp glob_segments_within?([child_head | child_tail], [anchor_head | anchor_tail]) do
    segment_within_anchor?(child_head, anchor_head) and glob_segments_within?(child_tail, anchor_tail)
  end

  defp segment_within_anchor?(child_segment, anchor_segment) do
    cond do
      child_segment == anchor_segment -> true
      anchor_segment == "*" -> child_segment != "**"
      child_segment == "**" -> false
      literal_glob?(child_segment) -> ScopeGuard.glob_match?(anchor_segment, child_segment)
      simple_star_segment_subset?(child_segment, anchor_segment) -> true
      true -> false
    end
  end

  defp literal_glob?(glob), do: not String.contains?(glob, ["*", "?", "["])

  defp simple_star_segment_subset?(child_segment, anchor_segment) do
    with {:ok, {anchor_prefix, anchor_suffix}} <- simple_star_bounds(anchor_segment),
         {child_prefix, child_suffix} <- segment_literal_bounds(child_segment) do
      String.starts_with?(child_prefix, anchor_prefix) and String.ends_with?(child_suffix, anchor_suffix)
    else
      :error -> false
    end
  end

  defp simple_star_bounds(segment) do
    cond do
      String.contains?(segment, ["?", "["]) -> :error
      segment |> String.graphemes() |> Enum.count(&(&1 == "*")) != 1 -> :error
      true -> {:ok, segment |> String.split("*", parts: 2) |> List.to_tuple()}
    end
  end

  defp segment_literal_bounds(segment) do
    tokens = segment_tokens(String.graphemes(segment), [])

    prefix =
      tokens
      |> Enum.take_while(&match?({:literal, _char}, &1))
      |> literal_token_string()

    suffix =
      tokens
      |> Enum.reverse()
      |> Enum.take_while(&match?({:literal, _char}, &1))
      |> Enum.reverse()
      |> literal_token_string()

    {prefix, suffix}
  end

  defp segment_tokens([], acc), do: Enum.reverse(acc)
  defp segment_tokens(["*" | rest], acc), do: segment_tokens(rest, [:wildcard | acc])
  defp segment_tokens(["?" | rest], acc), do: segment_tokens(rest, [:wildcard | acc])

  defp segment_tokens(["[" | rest], acc) do
    case drop_character_class(rest, false) do
      {:ok, rest} -> segment_tokens(rest, [:wildcard | acc])
      :error -> segment_tokens(rest, [{:literal, "["} | acc])
    end
  end

  defp segment_tokens([char | rest], acc), do: segment_tokens(rest, [{:literal, char} | acc])

  defp drop_character_class([], _has_content?), do: :error
  defp drop_character_class(["]" | _rest], false), do: :error
  defp drop_character_class(["]" | rest], true), do: {:ok, rest}
  defp drop_character_class([_char | rest], _has_content?), do: drop_character_class(rest, true)

  defp literal_token_string(tokens) do
    Enum.map_join(tokens, "", fn {:literal, char} -> char end)
  end

  defp optional_child_string_list(package, key, default) do
    case Map.fetch(package, key) do
      :error -> {:ok, default}
      {:ok, nil} -> {:ok, default}
      {:ok, values} when is_list(values) -> normalize_child_string_list(values, key)
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp normalize_child_string_list([], key), do: {:tool_error, "missing_#{key}"}

  defp normalize_child_string_list(values, key) do
    if Enum.all?(values, &(is_binary(&1) and normalize_child_glob(&1) != "")) do
      case normalize_child_scope_globs(values) do
        {:ok, []} -> {:tool_error, "missing_#{key}"}
        {:ok, globs} -> {:ok, globs}
        {:tool_error, reason} -> {:tool_error, reason}
      end
    else
      {:tool_error, "invalid_#{key}"}
    end
  end

  defp repo_scope_match?(repo, repo) when is_binary(repo), do: true

  defp repo_scope_match?(expected_repo, actual_repo) when is_binary(expected_repo) and is_binary(actual_repo) do
    RepoIdentity.scope_match?(expected_repo, actual_repo,
      trusted_remotes: Application.get_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes, []),
      local_path_remotes?: true
    )
  end

  defp repo_scope_match?(_expected_repo, _actual_repo), do: false

  defp normalize_child_scope_globs(globs) when is_list(globs) do
    normalized_globs =
      globs
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&normalize_child_glob/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      Enum.any?(normalized_globs, &traversal_glob?/1) ->
        {:tool_error, "path_traversal_allowed_file_globs"}

      Enum.any?(normalized_globs, &encoded_separator_glob?/1) ->
        {:tool_error, "invalid_allowed_file_globs"}

      true ->
        {:ok, normalized_globs}
    end
  end

  defp normalize_child_scope_globs(_globs), do: {:ok, []}

  defp normalize_child_glob(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.replace(~r/\A\.\//, "")
  end

  defp normalize_child_glob(_value), do: ""

  defp traversal_glob?(glob) when is_binary(glob) do
    glob
    |> String.split("/", trim: true)
    |> Enum.any?(&traversal_segment?/1)
  end

  defp traversal_glob?(_glob), do: false

  defp encoded_separator_glob?(glob) when is_binary(glob) do
    glob
    |> String.split("/", trim: true)
    |> Enum.any?(&encoded_separator_segment?/1)
  end

  defp encoded_separator_glob?(_glob), do: false

  defp encoded_separator_segment?(segment) when is_binary(segment) do
    segment
    |> String.trim()
    |> String.downcase()
    |> encoded_separator_segment?(0)
  end

  defp encoded_separator_segment?(_segment), do: false

  defp encoded_separator_segment?(segment, depth) do
    cond do
      String.contains?(segment, ["/", "\\"]) ->
        true

      depth >= 3 ->
        false

      true ->
        decoded_segment = URI.decode(segment)

        decoded_segment != segment and encoded_separator_segment?(decoded_segment, depth + 1)
    end
  rescue
    ArgumentError -> false
  end

  defp traversal_segment?(segment) when is_binary(segment) do
    segment
    |> String.trim()
    |> String.downcase()
    |> traversal_segment?(0)
  end

  defp traversal_segment?(_segment), do: false

  defp traversal_segment?(segment, depth) do
    cond do
      segment in [".", ".."] ->
        true

      segment |> path_separator_segments() |> Enum.any?(&(&1 in [".", ".."])) ->
        true

      depth >= 3 ->
        false

      true ->
        decoded_segment = segment |> URI.decode() |> String.replace("\\", "/")

        decoded_segment != segment and traversal_segment?(decoded_segment, depth + 1)
    end
  rescue
    ArgumentError -> false
  end

  defp path_separator_segments(segment) do
    segment
    |> String.replace("\\", "/")
    |> String.split("/", trim: true)
  end
end
