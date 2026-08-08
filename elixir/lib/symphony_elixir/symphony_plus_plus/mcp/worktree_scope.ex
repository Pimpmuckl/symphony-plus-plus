defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorktreeScope do
  @moduledoc false

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.SymphonyPlusPlus.BranchPattern
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Config
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreePath
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeTargetRoot

  @local_branch_template_fields %{
    "work_package_id" => :id,
    "id" => :id,
    "phase_id" => :phase_id,
    "parent_id" => :parent_id,
    "owner_id" => :owner_id
  }

  @type tool_error :: {:tool_error, String.t() | tuple()}
  @type target_repo_root_result :: {:ok, String.t() | nil} | tool_error
  @type scope_result :: :ok | {:error, atom()} | tool_error

  @spec require_local_branch_pattern_scope(WorkPackage.t(), String.t() | nil, keyword()) :: scope_result()
  def require_local_branch_pattern_scope(%WorkPackage{branch_pattern: branch_pattern} = work_package, branch, opts) do
    case normalize_optional_value(branch_pattern) do
      nil ->
        :ok

      pattern ->
        case require_supported_branch_pattern(pattern) do
          :ok -> require_local_supported_branch_pattern_scope(work_package, pattern, branch, opts)
          error -> error
        end
    end
  end

  @spec cleanup_target_repo_root(String.t() | nil, WorkPackage.t(), Config.t()) :: target_repo_root_result()
  def cleanup_target_repo_root(target_repo_root, %WorkPackage{}, %Config{}) when is_binary(target_repo_root),
    do: {:ok, target_repo_root}

  def cleanup_target_repo_root(nil, %WorkPackage{worktree_path: nil}, %Config{}), do: {:ok, nil}

  def cleanup_target_repo_root(nil, %WorkPackage{worktree_target_repo_root: target_repo_root}, %Config{})
      when is_binary(target_repo_root),
      do: {:ok, target_repo_root}

  def cleanup_target_repo_root(nil, %WorkPackage{} = work_package, %Config{} = config) do
    resolve_target_repo_root(nil, work_package, config)
  end

  @spec target_repo_root_argument(String.t() | nil, WorkPackage.t(), Config.t()) :: target_repo_root_result()
  def target_repo_root_argument(explicit_root, %WorkPackage{} = work_package, %Config{} = config) do
    resolve_target_repo_root(explicit_root, work_package, config)
  end

  @spec resolve_target_repo_root(String.t() | nil, WorkPackage.t(), Config.t()) :: target_repo_root_result()
  def resolve_target_repo_root(target_repo_root, %WorkPackage{}, %Config{}) when is_binary(target_repo_root),
    do: {:ok, target_repo_root}

  def resolve_target_repo_root(nil, %WorkPackage{worktree_path: worktree_path} = work_package, %Config{} = config)
      when is_binary(worktree_path) do
    work_package
    |> recorded_worktree_target_repo_root_candidates(config, worktree_path)
    |> scoped_target_repo_root(work_package, config)
  end

  def resolve_target_repo_root(nil, %WorkPackage{} = work_package, %Config{} = config) do
    work_package
    |> target_repo_root_candidates(config)
    |> scoped_target_repo_root(work_package, config)
  end

  @spec require_target_repo_root_scope(String.t() | nil, WorkPackage.t(), Config.t()) :: scope_result()
  def require_target_repo_root_scope(target_repo_root, %WorkPackage{repo: expected_repo}, %Config{} = config) do
    with {:ok, target_repo_root} <- PathSafety.canonicalize(target_repo_root),
         true <- File.dir?(target_repo_root) do
      if target_repo_root_matches_repo_scope?(target_repo_root, expected_repo, config) do
        :ok
      else
        {:tool_error, "target_repo_root_scope_mismatch"}
      end
    else
      false -> {:error, :invalid_target_repo_root}
      {:error, _reason} -> {:error, :invalid_target_repo_root}
    end
  end

  @spec require_cleanup_target_repo_root_scope(String.t() | nil, WorkPackage.t(), Config.t()) :: scope_result()
  def require_cleanup_target_repo_root_scope(nil, %WorkPackage{}, %Config{}), do: :ok
  def require_cleanup_target_repo_root_scope(_target_repo_root, %WorkPackage{worktree_path: nil}, %Config{}), do: :ok

  def require_cleanup_target_repo_root_scope(target_repo_root, %WorkPackage{} = work_package, %Config{} = config),
    do: require_target_repo_root_scope(target_repo_root, work_package, config)

  @spec prepare_branch(WorkPackage.t(), String.t() | nil) :: {:ok, String.t()} | tool_error()
  def prepare_branch(%WorkPackage{} = work_package, branch) when is_binary(branch) do
    case require_local_branch_pattern_scope(work_package, branch, prepared_worktree?: true) do
      :ok -> {:ok, branch}
      {:error, :branch_scope_mismatch} -> {:tool_error, "branch_scope_mismatch"}
      {:tool_error, reason} -> {:tool_error, reason}
    end
  end

  def prepare_branch(%WorkPackage{branch_pattern: branch_pattern} = work_package, nil) do
    case normalize_optional_value(branch_pattern) do
      nil ->
        package_branch_segment(work_package.id)

      pattern ->
        if local_branch_template_pattern?(pattern) do
          {:ok, materialize_local_branch_template(work_package, pattern)}
        else
          {:ok, pattern}
        end
    end
  end

  defp require_local_supported_branch_pattern_scope(%WorkPackage{} = work_package, pattern, branch, opts) do
    cond do
      pattern == branch and not local_branch_template_pattern?(pattern) ->
        :ok

      Keyword.get(opts, :prepared_worktree?, false) and local_branch_template_matches?(work_package, pattern, branch) ->
        :ok

      true ->
        {:error, :branch_scope_mismatch}
    end
  end

  @spec local_branch_template_pattern?(term()) :: boolean()
  def local_branch_template_pattern?(pattern) when is_binary(pattern) do
    Regex.match?(~r/\{\{\s*[a-zA-Z0-9_]+\s*\}\}/, pattern)
  end

  def local_branch_template_pattern?(_pattern), do: false

  defp local_branch_template_matches?(%WorkPackage{} = work_package, pattern, branch)
       when is_binary(pattern) and is_binary(branch) do
    case Regex.scan(~r/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/, pattern, return: :index) do
      [] ->
        false

      matches ->
        source = "^" <> local_branch_template_regex_source(pattern, matches, work_package) <> "$"
        Regex.match?(Regex.compile!(source), branch)
    end
  end

  defp local_branch_template_matches?(%WorkPackage{}, _pattern, _branch), do: false

  defp local_branch_template_regex_source(pattern, matches, work_package) do
    {parts, cursor} =
      Enum.reduce(matches, {[], 0}, fn [{match_start, match_length}, {capture_start, capture_length}], {parts, cursor} ->
        literal = pattern |> binary_part(cursor, match_start - cursor) |> Regex.escape()
        placeholder = binary_part(pattern, capture_start, capture_length)
        replacement = local_branch_template_placeholder_regex(work_package, placeholder)

        {[replacement, literal | parts], match_start + match_length}
      end)

    suffix = pattern |> binary_part(cursor, byte_size(pattern) - cursor) |> Regex.escape()
    IO.iodata_to_binary(Enum.reverse([suffix | parts]))
  end

  defp local_branch_template_placeholder_regex(%WorkPackage{} = work_package, placeholder) do
    case Map.fetch(@local_branch_template_fields, placeholder) do
      {:ok, field} ->
        literal = work_package |> Map.get(field) |> local_branch_template_literal_regex()
        derived = work_package |> local_branch_template_placeholder(placeholder) |> Regex.escape()
        "(?:#{literal}|#{derived})"

      :error ->
        "[^/]+"
    end
  end

  defp materialize_local_branch_template(%WorkPackage{} = work_package, pattern) do
    Regex.replace(~r/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/, pattern, fn _match, placeholder ->
      local_branch_template_placeholder(work_package, placeholder)
    end)
  end

  defp local_branch_template_placeholder(%WorkPackage{} = work_package, placeholder) do
    field = Map.get(@local_branch_template_fields, placeholder, :id)
    value = normalize_optional_value(Map.get(work_package, field)) || work_package.id
    fingerprint = if field == :id, do: work_package.id, else: Enum.join([value, work_package.id], <<0>>)
    {:ok, segment} = WorktreePath.previous_compact_unique_segment(value, fingerprint)
    segment
  end

  defp package_branch_segment(id) do
    case WorktreePath.previous_compact_unique_segment(id, id) do
      {:ok, branch} -> {:ok, branch}
      {:error, _reason} -> {:tool_error, "invalid_work_package_id"}
    end
  end

  defp local_branch_template_literal_regex(value) do
    case normalize_optional_value(value) do
      nil -> "[^/]+"
      value -> Regex.escape(value)
    end
  end

  defp scoped_target_repo_root(candidates, %WorkPackage{} = work_package, %Config{} = config) do
    candidates
    |> Enum.find_value(fn target_repo_root ->
      case require_target_repo_root_scope(target_repo_root, work_package, config) do
        :ok -> {:ok, target_repo_root}
        _error -> nil
      end
    end)
    |> case do
      nil -> {:tool_error, "target_repo_root_required"}
      result -> result
    end
  end

  defp target_repo_root_candidates(%WorkPackage{repo: repo}, %Config{repo_root: repo_root}) do
    WorktreeTargetRoot.checkout_candidates(repo, repo_root)
  end

  defp recorded_worktree_target_repo_root_candidates(%WorkPackage{} = work_package, %Config{} = config, worktree_path) do
    [live_worktree_target_repo_root(worktree_path) | target_repo_root_candidates(work_package, config)]
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn target_repo_root ->
      with {:ok, target_repo_root} <- PathSafety.canonicalize(target_repo_root),
           true <- recorded_worktree_matches_target_repo_root?(target_repo_root, work_package, worktree_path) do
        [target_repo_root]
      else
        _result -> []
      end
    end)
    |> Enum.uniq()
  end

  defp recorded_worktree_matches_target_repo_root?(target_repo_root, %WorkPackage{} = work_package, worktree_path) do
    WorktreeTargetRoot.target_root_matches_worktree?(target_repo_root, work_package, worktree_path) or
      recorded_flat_worktree_matches_target_repo_root?(target_repo_root, work_package, worktree_path)
  end

  defp recorded_flat_worktree_matches_target_repo_root?(target_repo_root, %WorkPackage{} = work_package, worktree_path) do
    case prepare_branch(work_package, nil) do
      {:ok, branch} -> WorktreePath.current_worktree_path?(target_repo_root, work_package.id, branch, worktree_path)
      _result -> false
    end
  end

  defp live_worktree_target_repo_root(worktree_path) do
    with true <- File.dir?(worktree_path),
         true <- WorktreeTargetRoot.git_metadata_present?(worktree_path),
         {:ok, repo_root} <- WorktreeTargetRoot.from_live_worktree(worktree_path, []) do
      repo_root
    else
      _result -> nil
    end
  end

  defp target_repo_root_matches_repo_scope?(target_repo_root, expected_repo, %Config{} = config) when is_binary(expected_repo) do
    origin = RepoIdentity.local_git_origin_remote(target_repo_root)

    same_existing_path?(target_repo_root, expected_repo) or
      local_repo_checkout_matches_scope?(target_repo_root, expected_repo, origin, config) or
      origin_matches_repo_scope?(origin, expected_repo, target_repo_root, config)
  end

  defp target_repo_root_matches_repo_scope?(_target_repo_root, _expected_repo, _config), do: false

  defp local_repo_checkout_matches_scope?(
         target_repo_root,
         expected_repo,
         origin,
         %Config{repo_root: repo_root} = config
       )
       when is_binary(target_repo_root) and is_binary(expected_repo) and is_binary(origin) do
    expected_repo = String.trim(expected_repo)
    trusted_remotes = [origin | repo_scope_trusted_remotes(config, target_repo_root)]

    bare_repo_name?(expected_repo) and
      expected_repo
      |> WorktreeTargetRoot.checkout_candidates(repo_root)
      |> Enum.reject(&same_existing_path?(&1, repo_root))
      |> Enum.any?(&same_existing_path?(target_repo_root, &1)) and
      RepoIdentity.scope_match?(expected_repo, origin, trusted_remotes: trusted_remotes)
  end

  defp local_repo_checkout_matches_scope?(_target_repo_root, _expected_repo, _origin, _config), do: false

  defp origin_matches_repo_scope?(origin, expected_repo, target_repo_root, %Config{} = config) when is_binary(origin) do
    trusted_remotes = repo_scope_trusted_remotes(config, target_repo_root)

    same_existing_path?(origin, expected_repo) or
      same_owner_bare_repo_origin_match?(expected_repo, origin, config) or
      RepoIdentity.scope_match?(expected_repo, origin, trusted_remotes: trusted_remotes)
  end

  defp origin_matches_repo_scope?(_origin, _expected_repo, _target_repo_root, _config), do: false

  @spec repo_scope_trusted_remotes(Config.t(), String.t() | nil) :: [String.t()]
  def repo_scope_trusted_remotes(%Config{repo_root: repo_root}, target_repo_root) do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_identity_trusted_remotes, [])
    |> List.wrap()
    |> Kernel.++([same_checkout_origin_remote(repo_root, target_repo_root)])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp same_owner_bare_repo_origin_match?(expected_repo, target_origin, %Config{repo_root: repo_root})
       when is_binary(expected_repo) and is_binary(repo_root) do
    with true <- bare_repo_name?(expected_repo),
         %{owner: target_owner, repo: ^expected_repo, host: target_host} <- remote_owner_repo_parts(target_origin),
         host_origin when is_binary(host_origin) <- RepoIdentity.local_git_origin_remote(repo_root),
         %{owner: ^target_owner, host: host_host} <- remote_owner_repo_parts(host_origin),
         true <- same_remote_host?(target_host, host_host) do
      true
    else
      _result -> false
    end
  end

  defp same_owner_bare_repo_origin_match?(_expected_repo, _target_origin, _config), do: false

  defp bare_repo_name?(repo) when is_binary(repo) do
    repo = String.trim(repo)
    repo != "" and not String.contains?(repo, ["/", "\\", ":"])
  end

  defp remote_owner_repo_parts(remote) when is_binary(remote) do
    remote = remote |> String.trim() |> String.replace_suffix(".git", "")

    cond do
      scp_remote = Regex.run(~r/^[^@]+@([^:]+):([^\/\\]+)[\/\\]([^\/\\]+)$/, remote) ->
        [_match, host, owner, repo] = scp_remote
        %{host: normalize_remote_host(host), owner: String.downcase(owner), repo: repo}

      parts = uri_owner_repo_parts(remote) ->
        parts

      owner_repo = Regex.run(~r/^([^\/\\]+)[\/\\]([^\/\\]+)$/, remote) ->
        [_match, owner, repo] = owner_repo
        %{host: nil, owner: String.downcase(owner), repo: repo}

      true ->
        nil
    end
  end

  defp uri_owner_repo_parts(remote) do
    uri = URI.parse(remote)

    with host when is_binary(host) <- uri.host,
         path when is_binary(path) <- uri.path,
         [owner, repo | _rest] <- path |> String.trim_leading("/") |> String.split(~r/[\/\\]/, trim: true) do
      %{host: normalize_remote_host(host), owner: String.downcase(owner), repo: repo}
    else
      _result -> nil
    end
  end

  defp normalize_remote_host(host) when is_binary(host), do: String.downcase(host)
  defp normalize_remote_host(_host), do: nil

  defp same_remote_host?(nil, nil), do: true
  defp same_remote_host?(host, host) when is_binary(host), do: true
  defp same_remote_host?(_target_host, _host_host), do: false

  defp same_checkout_origin_remote(repo_root, target_repo_root) when is_binary(repo_root) and is_binary(target_repo_root) do
    if same_existing_path?(repo_root, target_repo_root), do: RepoIdentity.local_git_origin_remote(repo_root)
  end

  defp same_checkout_origin_remote(_repo_root, _target_repo_root), do: nil

  defp same_existing_path?(left, right) when is_binary(left) and is_binary(right) do
    with {:ok, left} <- PathSafety.canonicalize(left),
         {:ok, right} <- PathSafety.canonicalize(right) do
      same_filesystem_path?(left, right)
    else
      _result -> false
    end
  end

  defp same_existing_path?(_left, _right), do: false

  defp same_filesystem_path?(left, right), do: comparable_filesystem_path(left) == comparable_filesystem_path(right)

  defp comparable_filesystem_path(path) do
    path =
      path
      |> Path.expand()
      |> String.replace("\\", "/")
      |> String.trim_trailing("/")

    if match?({:win32, _name}, :os.type()), do: String.downcase(path), else: path
  end

  defp require_supported_branch_pattern(branch_pattern) do
    case BranchPattern.validate(branch_pattern) do
      :ok -> :ok
      {:error, reason} -> {:tool_error, {:branch_pattern, branch_pattern, reason}}
    end
  end

  defp normalize_optional_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_value(nil), do: nil
  defp normalize_optional_value(value), do: value
end
