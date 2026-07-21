defmodule SymphonyElixir.SymphonyPlusPlus.RepoIdentity do
  @moduledoc false
  @git_origin_timeout_ms 5_000
  @max_git_origin_output_bytes 8_192

  @type identity :: %{
          repo_key: String.t() | nil,
          repo_display: String.t() | nil,
          repo_remote: String.t() | nil,
          repo_aliases: [String.t()]
        }

  @type catalog :: %{optional(String.t()) => identity()}
  @type catalog_opts :: [trusted_remotes: [String.t()], local_path_remotes?: boolean()]

  @spec catalog([term()]) :: catalog()
  @spec catalog([term()], catalog_opts()) :: catalog()
  def catalog(repo_values, opts \\ []) do
    local_path_remotes? = Keyword.get(opts, :local_path_remotes?, false)

    infos =
      repo_values
      |> Enum.uniq_by(&repo_value_key/1)
      |> Enum.flat_map(&parse_repo_infos(&1, local_path_remotes?))

    groups = Enum.group_by(infos, & &1.group_key)

    trusted_remotes = trusted_remote_infos(opts)
    trusted_remote_keys = MapSet.union(remote_keys(trusted_remotes), explicit_path_derived_remote_keys(infos))
    remote_conflict_name_keys = remote_conflict_name_keys(infos ++ trusted_remotes)

    infos
    |> Enum.filter(& &1.catalog_key?)
    |> Map.new(fn info ->
      {info.raw, identity(info, Map.fetch!(groups, info.group_key), trusted_remote_keys, remote_conflict_name_keys)}
    end)
  end

  @spec fields(catalog(), term()) :: identity()
  def fields(catalog, raw_repo) when is_map(catalog) and is_binary(raw_repo) do
    Map.get(catalog, raw_repo) || fallback_fields(raw_repo)
  end

  def fields(_catalog, _raw_repo), do: empty_identity()

  @spec scope_match?(term(), term()) :: boolean()
  def scope_match?(expected_repo, actual_repo), do: scope_match?(expected_repo, actual_repo, [])

  @spec scope_match?(term(), term(), catalog_opts()) :: boolean()
  def scope_match?(expected_repo, actual_repo, opts)
      when is_binary(expected_repo) and is_binary(actual_repo) and is_list(opts) do
    catalog = catalog([expected_repo, actual_repo], opts)
    expected = fields(catalog, expected_repo)
    actual = fields(catalog, actual_repo)

    not MapSet.disjoint?(identity_values(expected), identity_values(actual))
  end

  def scope_match?(_expected_repo, _actual_repo, _opts), do: false

  @spec local_git_origin_remote(term()) :: String.t() | nil
  def local_git_origin_remote(repo_path) when is_binary(repo_path) do
    with true <- local_git_repo_path?(repo_path),
         git when is_binary(git) <- System.find_executable("git") || System.find_executable("git.exe"),
         {:ok, origin} <- git_origin_remote(git, repo_path),
         origin <- String.trim(origin),
         false <- origin == "" do
      origin
    else
      _result -> nil
    end
  end

  def local_git_origin_remote(_repo_path), do: nil

  defp fallback_fields(raw_repo) do
    [raw_repo]
    |> catalog()
    |> Map.get(raw_repo, empty_identity())
  end

  defp identity(info, group, trusted_remote_keys, remote_conflict_name_keys) do
    if path_derived_group?(group) and MapSet.member?(remote_conflict_name_keys, info.name_key) do
      owner_qualified_identity(group)
    else
      collapsed_identity(info, group, trusted_remote_keys, remote_conflict_name_keys)
    end
  end

  defp collapsed_identity(info, group, trusted_remote_keys, remote_conflict_name_keys) do
    collapsed_group? = collapsed_group?(group, trusted_remote_keys, remote_conflict_name_keys)
    identity_infos = identity_infos(group, info, collapsed_group?)
    remote = identity_infos |> Enum.find(&(&1.kind == :remote)) |> remote_display()

    %{
      repo_key: repo_key(info, collapsed_group?),
      repo_display: repo_display(info, group, collapsed_group?),
      repo_remote: remote,
      repo_aliases: aliases(identity_infos)
    }
  end

  defp owner_qualified_identity(group) do
    remote = Enum.find(group, &(&1.kind == :remote))

    %{
      repo_key: remote.full_key,
      repo_display: remote.full_display,
      repo_remote: remote.full_display,
      repo_aliases: group |> Enum.reject(& &1.generated_local_bare?) |> aliases()
    }
  end

  defp repo_key(info, false) when info.kind == :remote, do: info.full_key
  defp repo_key(info, _collapsed_group?), do: info.name_key

  defp repo_display(info, _group, false) when info.kind == :remote, do: info.full_display

  defp repo_display(_info, group, _collapsed_group?) do
    group
    |> Enum.find(&(&1.kind == :bare))
    |> case do
      nil -> group |> hd() |> Map.fetch!(:name_display)
      bare -> bare.name_display
    end
  end

  defp identity_infos(group, _info, true), do: group

  defp identity_infos(group, info, false) when info.kind == :remote do
    Enum.filter(group, &(&1.full_key == info.full_key))
  end

  defp identity_infos(group, _info, false), do: Enum.reject(group, &(&1.kind == :remote))

  defp collapsed_group?(group, trusted_remote_keys, remote_conflict_name_keys) do
    remote_keys =
      group
      |> Enum.filter(&(&1.kind == :remote))
      |> Enum.map(& &1.full_key)
      |> Enum.uniq()

    cond do
      remote_name_conflict?(group, remote_conflict_name_keys) -> false
      remote_keys == [] -> true
      length(remote_keys) > 1 -> false
      bare_alias?(group) -> MapSet.member?(trusted_remote_keys, hd(remote_keys)) or derived_remote_alias?(group, hd(remote_keys))
      true -> false
    end
  end

  defp remote_name_conflict?(group, remote_conflict_name_keys) do
    Enum.any?(group, &MapSet.member?(remote_conflict_name_keys, &1.name_key))
  end

  defp bare_alias?(group), do: Enum.any?(group, &(&1.kind == :bare))

  defp path_derived_group?(group), do: Enum.any?(group, & &1.derived_trusted_remote?)

  defp derived_remote_alias?(group, remote_key) do
    Enum.any?(group, &(&1.derived_trusted_remote? and &1.full_key == remote_key))
  end

  defp explicit_path_derived_remote_keys(infos) do
    derived_remote_keys =
      infos
      |> Enum.filter(&(&1.derived_trusted_remote? and &1.kind == :remote))
      |> Enum.map(& &1.full_key)
      |> MapSet.new()

    explicit_remote_keys =
      infos
      |> Enum.filter(&(&1.kind == :remote and not &1.derived_trusted_remote?))
      |> Enum.map(& &1.full_key)
      |> MapSet.new()

    MapSet.intersection(derived_remote_keys, explicit_remote_keys)
  end

  defp remote_conflict_name_keys(infos) do
    infos
    |> Enum.filter(&(&1.kind == :remote))
    |> Enum.group_by(& &1.name_key)
    |> Enum.filter(fn {_name_key, remotes} ->
      remotes
      |> Enum.map(& &1.full_key)
      |> Enum.uniq()
      |> length() > 1
    end)
    |> Enum.map(fn {name_key, _remotes} -> name_key end)
    |> MapSet.new()
  end

  defp trusted_remote_infos(opts) do
    opts
    |> Keyword.get(:trusted_remotes, [])
    |> List.wrap()
    |> Enum.map(&trusted_remote_info/1)
    |> Enum.reject(&is_nil/1)
  end

  defp trusted_remote_info(remote) when is_binary(remote) do
    case parse_repo(remote) do
      %{kind: :remote} = info -> info
      _other -> nil
    end
  end

  defp trusted_remote_info(_remote), do: nil

  defp remote_keys(infos) do
    infos
    |> Enum.map(& &1.full_key)
    |> MapSet.new()
  end

  defp aliases(infos) do
    infos
    |> Enum.map(& &1.alias)
    |> Enum.uniq()
    |> Enum.sort_by(&String.downcase/1)
  end

  defp identity_values(identity) do
    [identity.repo_key, identity.repo_display, identity.repo_remote | identity.repo_aliases]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp remote_display(nil), do: nil
  defp remote_display(info), do: info.full_display

  defp parse_repo_infos(raw, local_path_remotes?) when is_binary(raw) do
    repo = String.trim(raw)

    case local_path_repo_infos(raw, repo, local_path_remotes?) do
      [] ->
        repo
        |> normalized_repo_path()
        |> do_parse_repo(raw)
        |> List.wrap()

      infos ->
        infos
    end
  end

  defp parse_repo_infos(_raw, _local_path_remotes?), do: []

  defp parse_repo(raw) when is_binary(raw) do
    raw
    |> String.trim()
    |> normalized_repo_path()
    |> do_parse_repo(raw)
  end

  defp repo_value_key(raw) when is_binary(raw), do: {:repo, String.trim(raw)}
  defp repo_value_key(raw), do: {:other, raw}

  defp do_parse_repo("", _raw), do: nil

  defp do_parse_repo(repo_path, raw) do
    parts =
      repo_path
      |> trim_git_suffix()
      |> String.trim("/")
      |> String.split("/", trim: true)

    case parts do
      [name] ->
        repo_info(raw, :bare, name, name)

      [owner, name] ->
        repo_info(raw, :remote, "#{owner}/#{name}", name)

      _parts ->
        repo_info(raw, :opaque, repo_path, repo_path)
    end
  end

  defp local_path_repo_infos(raw, repo_path, true) do
    with true <- local_git_repo_path?(repo_path),
         origin when is_binary(origin) <- local_git_origin_remote(repo_path),
         %{kind: :remote} = remote <- parse_repo(origin) do
      group_key = {:local_path, key(raw)}

      [
        repo_info(raw, :bare, remote.name_display, remote.name_display, alias: raw, group_key: group_key),
        repo_info(remote.name_display, :bare, remote.name_display, remote.name_display,
          catalog_key?: false,
          generated_local_bare?: true,
          group_key: group_key
        ),
        repo_info(remote.full_display, :remote, remote.full_display, remote.name_display,
          catalog_key?: false,
          derived_trusted_remote?: true,
          group_key: group_key
        )
      ]
    else
      _result -> []
    end
  end

  defp local_path_repo_infos(_raw, _repo_path, false), do: []

  defp local_git_repo_path?(repo_path) when is_binary(repo_path) do
    local_absolute_path?(repo_path) and File.dir?(repo_path) and
      (File.exists?(Path.join(repo_path, ".git")) or bare_git_repo_path?(repo_path))
  end

  defp bare_git_repo_path?(repo_path) do
    File.regular?(Path.join(repo_path, "config")) and File.regular?(Path.join(repo_path, "HEAD")) and
      File.dir?(Path.join(repo_path, "objects"))
  end

  defp local_absolute_path?(path) do
    absolute_path?(path) and not unc_path?(path)
  end

  defp absolute_path?(path) do
    Path.type(path) == :absolute or Regex.match?(~r/\A(?:[a-zA-Z]:[\\\/]|\\\\)/, path)
  end

  defp unc_path?(path) do
    path = String.replace(path, "/", "\\")

    cond do
      String.starts_with?(path, "\\\\?\\UNC\\") -> true
      String.starts_with?(path, "\\\\?\\") -> false
      true -> String.starts_with?(path, "\\\\")
    end
  end

  defp git_origin_remote(git, repo_path) do
    port =
      Port.open({:spawn_executable, git}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, @max_git_origin_output_bytes},
        args: ["-C", repo_path, "remote", "get-url", "origin"]
      ])

    collect_git_origin_remote(port, "", @max_git_origin_output_bytes, nil, false)
  rescue
    _error -> nil
  end

  defp collect_git_origin_remote(port, output, remaining_bytes, exit_status, complete?) do
    cond do
      is_integer(exit_status) and exit_status != 0 ->
        close_port(port)
        nil

      exit_status == 0 and complete? ->
        close_port(port)
        {:ok, output}

      true ->
        receive do
          {^port, {:data, {:noeol, data}}} when byte_size(data) <= remaining_bytes ->
            collect_git_origin_remote(port, output <> data, remaining_bytes - byte_size(data), exit_status, false)

          {^port, {:data, {:eol, data}}} when byte_size(data) <= remaining_bytes ->
            collect_git_origin_remote(port, output <> data, remaining_bytes - byte_size(data), exit_status, true)

          {^port, {:data, _data}} ->
            close_port(port)
            nil

          {^port, {:exit_status, status}} ->
            collect_git_origin_remote(port, output, remaining_bytes, status, complete?)
        after
          @git_origin_timeout_ms ->
            close_port(port)
            nil
        end
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    _error -> :ok
  end

  defp repo_info(raw, kind, full_display, name_display, opts \\ []) do
    %{
      raw: raw,
      kind: kind,
      name_key: key(name_display),
      name_display: name_display,
      group_key: Keyword.get(opts, :group_key, key(name_display)),
      full_key: key(full_display),
      full_display: full_display,
      alias: Keyword.get(opts, :alias, full_display),
      catalog_key?: Keyword.get(opts, :catalog_key?, true),
      generated_local_bare?: Keyword.get(opts, :generated_local_bare?, false),
      derived_trusted_remote?: Keyword.get(opts, :derived_trusted_remote?, false)
    }
  end

  defp normalized_repo_path(repo) do
    case github_ssh_path(repo) do
      nil -> github_uri_path(repo)
      path -> path
    end
  end

  defp github_ssh_path(repo) do
    case Regex.run(~r/\Agit@github\.com:(?<repo>[^?#]+)\z/i, repo, capture: :all_names) do
      [path] -> path
      nil -> nil
    end
  end

  defp github_uri_path(repo) do
    uri = URI.parse(repo)
    github_host? = String.downcase(uri.host || "") == "github.com"
    github_scheme? = uri.scheme in ["http", "https"] or (uri.scheme == "ssh" and uri.userinfo in [nil, "git"])

    if github_host? and github_scheme? and is_binary(uri.path) do
      String.trim_leading(uri.path, "/")
    else
      repo
    end
  rescue
    _error in URI.Error -> repo
  end

  defp trim_git_suffix(repo) do
    if String.ends_with?(repo, ".git") do
      String.replace_suffix(repo, ".git", "")
    else
      repo
    end
  end

  defp key(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp empty_identity do
    %{
      repo_key: nil,
      repo_display: nil,
      repo_remote: nil,
      repo_aliases: []
    }
  end
end
