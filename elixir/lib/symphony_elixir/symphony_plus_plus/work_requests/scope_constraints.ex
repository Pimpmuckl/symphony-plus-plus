defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.ScopeConstraints do
  @moduledoc """
  Pure path-scope validation for WorkRequest-backed WorkPackage file globs.

  The validator does not inspect the host filesystem. It checks repo-relative
  slash-separated path/glob syntax and proves package ownership stays
  inside `constraints.allowed_paths` while avoiding `constraints.forbidden_paths`.
  """

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type field :: :constraints | :allowed_paths | :forbidden_paths | :allowed_file_globs
  @type path_error_reason ::
          :absolute_path
          | :backslash_separator
          | :dot_segment
          | :drive_qualified_path
          | :empty_segment
          | :unsupported_globstar
  @type error ::
          {:invalid_constraints, field()}
          | {:invalid_allowed_file_globs, :allowed_file_globs}
          | {:invalid_path, field(), String.t(), path_error_reason()}
          | {:non_documentation_owned_glob, String.t()}
          | {:outside_allowed_paths, String.t(), [String.t()]}
          | {:forbidden_path_overlap, String.t(), String.t()}

  @docs_path_roots MapSet.new([
                     "doc",
                     "docs",
                     "documentation",
                     "implementation_docs",
                     "implementation_docs_symphplusplus"
                   ])
  @docs_extensions [".adoc", ".md", ".mdx", ".rst", ".txt"]

  @doc """
  Validates WorkPackage owned file globs against WorkRequest scope constraints.

  Missing or empty `allowed_paths` means no allow-list restriction.
  `forbidden_paths` still apply. The result is `:ok` or a non-empty list of
  typed, safe errors.
  """
  @spec validate_allowed_file_globs(WorkRequest.t() | map(), WorkPackage.t() | [String.t()]) ::
          :ok | {:error, [error()]}
  def validate_allowed_file_globs(%WorkRequest{constraints: constraints}, %WorkPackage{} = work_package) do
    validate_allowed_file_globs(constraints, work_package.allowed_file_globs || [])
  end

  def validate_allowed_file_globs(%WorkRequest{constraints: constraints}, allowed_file_globs) do
    validate_allowed_file_globs(constraints, allowed_file_globs)
  end

  def validate_allowed_file_globs(constraints, %WorkPackage{} = work_package) do
    validate_allowed_file_globs(constraints, work_package.allowed_file_globs || [])
  end

  def validate_allowed_file_globs(%{constraints: constraints}, allowed_file_globs) do
    validate_allowed_file_globs(constraints, allowed_file_globs)
  end

  def validate_allowed_file_globs(%{"constraints" => constraints}, allowed_file_globs) do
    validate_allowed_file_globs(constraints, allowed_file_globs)
  end

  def validate_allowed_file_globs(constraints, allowed_file_globs) when is_map(constraints) do
    with {:ok, allowed_paths} <- constraint_entries(constraints, :allowed_paths),
         {:ok, forbidden_paths} <- constraint_entries(constraints, :forbidden_paths),
         {:ok, owned_entries} <- owned_entries(allowed_file_globs) do
      validate_patterns(owned_entries, allowed_paths, forbidden_paths)
    else
      {:error, errors} -> {:error, errors}
    end
  end

  def validate_allowed_file_globs(_constraints, _allowed_file_globs), do: {:error, [{:invalid_constraints, :constraints}]}

  @doc """
  Validates that a `docs` WorkPackage scope is documentation-only.

  This is intentionally syntactic and repo-agnostic. Documentation-owned globs
  either live under a known documentation root or point at documentation files
  by extension.
  """
  @spec validate_docs_allowed_file_globs([String.t()]) :: :ok | {:error, [error()]}
  def validate_docs_allowed_file_globs(allowed_file_globs) do
    with {:ok, owned_entries} <- owned_entries(allowed_file_globs),
         {:ok, owned_patterns} <- parse_docs_owned_patterns(owned_entries) do
      validate_documentation_patterns(owned_patterns)
    end
  end

  defp validate_patterns(owned_entries, allowed_entries, forbidden_entries) do
    {owned_patterns, owned_errors} = parse_entries(:allowed_file_globs, owned_entries)
    {allowed_patterns, allowed_errors} = parse_entries(:allowed_paths, allowed_entries)
    {forbidden_patterns, forbidden_errors} = parse_entries(:forbidden_paths, forbidden_entries)

    syntax_errors = owned_errors ++ allowed_errors ++ forbidden_errors

    if syntax_errors == [] do
      errors =
        []
        |> add_allowed_path_errors(owned_patterns, allowed_patterns)
        |> add_forbidden_path_errors(owned_patterns, forbidden_patterns)
        |> Enum.reverse()

      if errors == [], do: :ok, else: {:error, errors}
    else
      {:error, syntax_errors}
    end
  end

  defp constraint_entries(constraints, field) do
    case fetch_optional_constraint(constraints, field) do
      :missing ->
        {:ok, []}

      value when is_list(value) ->
        string_entries(value, field, {:invalid_constraints, field})

      _value ->
        {:error, [{:invalid_constraints, field}]}
    end
  end

  defp owned_entries(value) when is_list(value), do: string_entries(value, :allowed_file_globs, {:invalid_allowed_file_globs, :allowed_file_globs})
  defp owned_entries(_value), do: {:error, [{:invalid_allowed_file_globs, :allowed_file_globs}]}

  defp string_entries(values, _field, error) do
    if Enum.all?(values, &nonblank_string?/1) do
      {:ok, Enum.map(values, &String.trim/1)}
    else
      {:error, [error]}
    end
  end

  defp fetch_optional_constraint(constraints, field) do
    string_key = Atom.to_string(field)

    cond do
      Map.has_key?(constraints, string_key) -> Map.fetch!(constraints, string_key)
      Map.has_key?(constraints, field) -> Map.fetch!(constraints, field)
      true -> :missing
    end
  end

  defp nonblank_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank_string?(_value), do: false

  defp parse_entries(field, entries) do
    entries
    |> Enum.map(&parse_pattern(field, &1))
    |> Enum.reduce({[], []}, fn
      {:ok, pattern}, {patterns, errors} -> {[pattern | patterns], errors}
      {:error, error}, {patterns, errors} -> {patterns, [error | errors]}
    end)
    |> then(fn {patterns, errors} -> {Enum.reverse(patterns), Enum.reverse(errors)} end)
  end

  defp parse_docs_owned_patterns(owned_entries) do
    case parse_entries(:allowed_file_globs, owned_entries) do
      {_owned_patterns, [_error | _rest] = owned_errors} -> {:error, owned_errors}
      {[], []} -> {:error, [{:invalid_allowed_file_globs, :allowed_file_globs}]}
      {owned_patterns, []} -> {:ok, owned_patterns}
    end
  end

  defp parse_pattern(field, value) do
    with :ok <- validate_repo_relative_path(value),
         {:ok, segments} <- parse_segments(value) do
      {:ok, %{raw: value, segments: segments}}
    else
      {:error, reason} -> {:error, {:invalid_path, field, value, reason}}
    end
  end

  defp validate_repo_relative_path(value) do
    cond do
      String.starts_with?(value, "/") ->
        {:error, :absolute_path}

      Regex.match?(~r/^[A-Za-z]:/, value) ->
        {:error, :drive_qualified_path}

      String.contains?(value, "\\") ->
        {:error, :backslash_separator}

      true ->
        :ok
    end
  end

  defp parse_segments(value) do
    segments = String.split(value, "/", trim: false)

    cond do
      Enum.any?(segments, &(&1 == "")) ->
        {:error, :empty_segment}

      Enum.any?(segments, &(&1 in [".", ".."])) ->
        {:error, :dot_segment}

      true ->
        parse_segments(segments, [])
    end
  end

  defp parse_segments([], parsed), do: {:ok, Enum.reverse(parsed)}

  defp parse_segments([segment | rest], parsed) do
    case parse_segment(segment) do
      {:ok, parsed_segment} -> parse_segments(rest, [parsed_segment | parsed])
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_segment("**"), do: {:ok, :globstar}

  defp parse_segment(segment) do
    cond do
      String.contains?(segment, "**") ->
        {:error, :unsupported_globstar}

      String.contains?(segment, "*") or String.contains?(segment, "?") ->
        {:ok, {:wildcard, segment, segment_regex(segment)}}

      true ->
        {:ok, {:literal, segment}}
    end
  end

  defp documentation_pattern?(%{segments: segments}) do
    docs_path_root?(List.first(segments)) or docs_file_pattern?(List.last(segments))
  end

  defp docs_path_root?({:literal, segment}) do
    normalized = String.downcase(segment)
    MapSet.member?(@docs_path_roots, normalized) or String.ends_with?(normalized, ["_docs", "-docs"])
  end

  defp docs_path_root?(_segment), do: false

  defp docs_file_pattern?({:literal, segment}) do
    segment
    |> String.downcase()
    |> String.ends_with?(@docs_extensions)
  end

  defp docs_file_pattern?({:wildcard, source, _regex}) do
    source
    |> String.downcase()
    |> String.ends_with?(@docs_extensions)
  end

  defp docs_file_pattern?(_segment), do: false

  defp validate_documentation_patterns(owned_patterns) do
    owned_patterns
    |> Enum.reject(&documentation_pattern?/1)
    |> Enum.map(&{:non_documentation_owned_glob, &1.raw})
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp segment_regex(segment) do
    source =
      segment
      |> String.graphemes()
      |> Enum.map_join(fn
        "*" -> ".*"
        "?" -> "."
        char -> Regex.escape(char)
      end)

    Regex.compile!("^" <> source <> "$")
  end

  defp add_allowed_path_errors(errors, _owned_patterns, []), do: errors

  defp add_allowed_path_errors(errors, owned_patterns, allowed_patterns) do
    Enum.reduce(owned_patterns, errors, fn owned_pattern, acc ->
      if Enum.any?(allowed_patterns, &owned_under_allowed?(&1, owned_pattern)) do
        acc
      else
        [{:outside_allowed_paths, owned_pattern.raw, Enum.map(allowed_patterns, & &1.raw)} | acc]
      end
    end)
  end

  defp owned_under_allowed?(allowed_pattern, owned_pattern) do
    path_subset?(owned_pattern.segments, allowed_pattern.segments, descendant_scope?(allowed_pattern.segments))
  end

  defp descendant_scope?(segments) do
    Enum.any?(segments, &(&1 == :globstar)) or Enum.all?(segments, &literal_segment?/1)
  end

  defp literal_segment?({:literal, _value}), do: true
  defp literal_segment?(_segment), do: false

  defp path_subset?([], [], _descendant_scope?), do: true
  defp path_subset?(_owned_segments, [], true), do: true
  defp path_subset?(_owned_segments, [], false), do: false
  defp path_subset?(_owned_segments, [:globstar], _descendant_scope?), do: true

  defp path_subset?([], [:globstar | allowed_segments], descendant_scope?), do: path_subset?([], allowed_segments, descendant_scope?)
  defp path_subset?([], _allowed_segments, _descendant_scope?), do: false

  defp path_subset?([:globstar | owned_segments], [:globstar | allowed_segments], descendant_scope?) do
    path_subset?(owned_segments, allowed_segments, descendant_scope?) or
      path_subset?(owned_segments, [:globstar | allowed_segments], descendant_scope?)
  end

  defp path_subset?([_owned_segment | rest_owned] = owned_segments, [:globstar | allowed_segments], descendant_scope?) do
    path_subset?(owned_segments, allowed_segments, descendant_scope?) or
      path_subset?(rest_owned, [:globstar | allowed_segments], descendant_scope?)
  end

  defp path_subset?([:globstar | _owned_segments], [{:wildcard, "*", _regex}, :globstar], _descendant_scope?), do: true

  defp path_subset?([:globstar | _owned_segments], _allowed_segments, _descendant_scope?), do: false

  defp path_subset?([owned_segment | rest_owned], [allowed_segment | rest_allowed], descendant_scope?) do
    segment_subset?(owned_segment, allowed_segment) and path_subset?(rest_owned, rest_allowed, descendant_scope?)
  end

  defp segment_subset?(:globstar, _allowed_segment), do: false
  defp segment_subset?(_owned_segment, :globstar), do: true
  defp segment_subset?({:literal, value}, {:literal, value}), do: true
  defp segment_subset?({:literal, value}, {:wildcard, _source, regex}), do: Regex.match?(regex, value)
  defp segment_subset?({:wildcard, source, _regex}, {:wildcard, allowed_source, _allowed_regex}), do: glob_segment_subset?(source, allowed_source)
  defp segment_subset?(_owned_segment, _allowed_segment), do: false

  defp add_forbidden_path_errors(errors, owned_patterns, forbidden_patterns) do
    Enum.reduce(owned_patterns, errors, fn owned_pattern, acc ->
      case Enum.find(forbidden_patterns, &owned_overlaps_forbidden?(&1, owned_pattern)) do
        nil -> acc
        forbidden_pattern -> [{:forbidden_path_overlap, owned_pattern.raw, forbidden_pattern.raw} | acc]
      end
    end)
  end

  defp owned_overlaps_forbidden?(forbidden_pattern, owned_pattern) do
    can_match_prefix?(owned_pattern.segments, forbidden_pattern.segments)
  end

  defp can_match_prefix?(_owned_segments, []), do: true
  defp can_match_prefix?([], forbidden_segments), do: Enum.all?(forbidden_segments, &(&1 == :globstar))

  defp can_match_prefix?([:globstar | rest_owned] = owned_segments, [_forbidden_segment | rest_forbidden] = forbidden_segments) do
    can_match_prefix?(rest_owned, forbidden_segments) or can_match_prefix?(owned_segments, rest_forbidden)
  end

  defp can_match_prefix?([_owned_segment | _rest_owned], [:globstar]), do: true

  defp can_match_prefix?([_owned_segment | rest_owned] = owned_segments, [:globstar | rest_forbidden]) do
    can_match_prefix?(owned_segments, rest_forbidden) or
      can_match_prefix?(rest_owned, [:globstar | rest_forbidden])
  end

  defp can_match_prefix?([owned_segment | rest_owned], [forbidden_segment | rest_forbidden]) do
    segment_intersects?(owned_segment, forbidden_segment) and can_match_prefix?(rest_owned, rest_forbidden)
  end

  defp segment_intersects?(:globstar, _segment), do: true
  defp segment_intersects?(_segment, :globstar), do: true
  defp segment_intersects?({:literal, left}, {:literal, right}), do: left == right
  defp segment_intersects?({:literal, value}, {:wildcard, _source, regex}), do: Regex.match?(regex, value)
  defp segment_intersects?({:wildcard, _source, regex}, {:literal, value}), do: Regex.match?(regex, value)
  defp segment_intersects?({:wildcard, left, _left_regex}, {:wildcard, right, _right_regex}), do: glob_segment_intersects?(left, right)

  defp glob_segment_subset?(owned_source, allowed_source) do
    owned_tokens = String.graphemes(owned_source)
    allowed_tokens = String.graphemes(allowed_source)
    alphabet = segment_alphabet(owned_tokens, allowed_tokens)

    owned_start = epsilon_closure(owned_tokens, MapSet.new([0]))
    allowed_start = epsilon_closure(allowed_tokens, MapSet.new([0]))

    not segment_counterexample?(owned_tokens, allowed_tokens, alphabet, [{owned_start, allowed_start, false}], [])
  end

  defp segment_counterexample?(_owned_tokens, _allowed_tokens, _alphabet, [], _seen), do: false

  defp segment_counterexample?(owned_tokens, allowed_tokens, alphabet, [{owned_states, allowed_states, consumed?} | rest], seen) do
    key = {owned_states, allowed_states, consumed?}

    cond do
      key in seen ->
        segment_counterexample?(owned_tokens, allowed_tokens, alphabet, rest, seen)

      consumed? and accepting?(owned_tokens, owned_states) and not accepting?(allowed_tokens, allowed_states) ->
        true

      true ->
        next =
          alphabet
          |> Enum.map(fn char ->
            {segment_move(owned_tokens, owned_states, char), segment_move(allowed_tokens, allowed_states, char), true}
          end)
          |> Enum.reject(fn {owned_next, _allowed_next, _consumed?} -> MapSet.size(owned_next) == 0 end)

        segment_counterexample?(owned_tokens, allowed_tokens, alphabet, rest ++ next, [key | seen])
    end
  end

  defp glob_segment_intersects?(left_source, right_source) do
    left_tokens = String.graphemes(left_source)
    right_tokens = String.graphemes(right_source)
    alphabet = segment_alphabet(left_tokens, right_tokens)

    left_start = epsilon_closure(left_tokens, MapSet.new([0]))
    right_start = epsilon_closure(right_tokens, MapSet.new([0]))

    segment_intersection?(left_tokens, right_tokens, alphabet, [{left_start, right_start, false}], [])
  end

  defp segment_intersection?(_left_tokens, _right_tokens, _alphabet, [], _seen), do: false

  defp segment_intersection?(left_tokens, right_tokens, alphabet, [{left_states, right_states, consumed?} | rest], seen) do
    key = {left_states, right_states, consumed?}

    cond do
      key in seen ->
        segment_intersection?(left_tokens, right_tokens, alphabet, rest, seen)

      consumed? and accepting?(left_tokens, left_states) and accepting?(right_tokens, right_states) ->
        true

      true ->
        next =
          alphabet
          |> Enum.map(fn char ->
            {segment_move(left_tokens, left_states, char), segment_move(right_tokens, right_states, char), true}
          end)
          |> Enum.reject(fn {left_next, right_next, _consumed?} -> MapSet.size(left_next) == 0 or MapSet.size(right_next) == 0 end)

        segment_intersection?(left_tokens, right_tokens, alphabet, rest ++ next, [key | seen])
    end
  end

  defp segment_alphabet(left_tokens, right_tokens) do
    [left_tokens, right_tokens]
    |> Enum.flat_map(&literal_tokens/1)
    |> Enum.uniq()
    |> Kernel.++([:other])
  end

  defp literal_tokens(tokens), do: Enum.reject(tokens, &(&1 in ["*", "?"]))

  defp segment_move(tokens, states, char) do
    tokens
    |> do_segment_move(states, char)
    |> then(&epsilon_closure(tokens, &1))
  end

  defp do_segment_move(tokens, states, char) do
    Enum.reduce(states, MapSet.new(), fn state, acc ->
      case next_segment_state(tokens, state, char) do
        nil -> acc
        next_state -> MapSet.put(acc, next_state)
      end
    end)
  end

  defp next_segment_state(tokens, state, char) do
    case Enum.at(tokens, state) do
      "*" -> state
      "?" -> state + 1
      ^char -> state + 1
      _token -> nil
    end
  end

  defp epsilon_closure(tokens, states) do
    next_states =
      Enum.reduce(states, states, fn state, acc ->
        if Enum.at(tokens, state) == "*" do
          MapSet.put(acc, state + 1)
        else
          acc
        end
      end)

    if MapSet.equal?(states, next_states), do: states, else: epsilon_closure(tokens, next_states)
  end

  defp accepting?(tokens, states), do: MapSet.member?(states, length(tokens))
end
