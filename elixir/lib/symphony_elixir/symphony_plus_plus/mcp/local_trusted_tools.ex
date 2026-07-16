defmodule SymphonyElixir.SymphonyPlusPlus.MCP.LocalTrustedTools do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Service, as: CommentService
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, ToolCatalog}
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @spec enabled?(map()) :: boolean()
  def enabled?(server), do: authorize(server, "tools/list") == :ok

  @spec authorize(map(), String.t()) :: :ok | {:error, integer(), String.t(), map()}
  def authorize(
        %{
          initialized: true,
          config: %Config{mode: :http, local_daemon_trusted: true} = config,
          local_daemon_trusted: true,
          state_key_explicit: true
        },
        tool
      ) do
    case require_database(config) do
      :ok -> :ok
      {:error, reason} -> {:error, -32_001, "Unauthorized", %{"tool" => tool, "reason" => reason_text(reason)}}
    end
  end

  def authorize(%{initialized: false}, tool), do: {:error, -32_000, "Server error", %{"tool" => tool, "reason" => "server_not_initialized"}}

  def authorize(%{config: %Config{mode: :http}, state_key_explicit: false}, tool),
    do: {:error, -32_001, "Unauthorized", %{"tool" => tool, "reason" => "local_mcp_session_required"}}

  def authorize(%{config: %Config{mode: :http}}, tool),
    do: {:error, -32_001, "Unauthorized", %{"tool" => tool, "reason" => "local_daemon_trust_required"}}

  def authorize(_server, tool), do: {:error, -32_001, "Unauthorized", %{"tool" => tool, "reason" => "local_mcp_required"}}

  @spec tool_specs(Config.t()) :: [ToolCatalog.tool_spec()]
  def tool_specs(%Config{} = config) do
    unbound_specs = ToolCatalog.unbound_tool_specs_for_config(config)
    bootstrap_names = ToolCatalog.bootstrap_tools()

    Enum.filter(unbound_specs, &(&1["name"] in bootstrap_names)) ++
      ToolCatalog.local_operator_tool_specs() ++
      Enum.filter(unbound_specs, &(&1["name"] == "list_comments"))
  end

  @spec list_comments(module(), map(), (Comment.t() -> map())) ::
          {:ok, map()} | {:tool_error, term()} | {:error, term()}
  def list_comments(repo, arguments, comment_payload) when is_atom(repo) and is_map(arguments) and is_function(comment_payload, 1) do
    with {:ok, target_kind} <- required_argument(arguments, "target_kind"),
         :ok <- require_comment_target_kind(target_kind),
         {:ok, target_id} <- required_argument(arguments, "target_id"),
         :ok <- require_comment_target(repo, target_kind, target_id),
         {:ok, comments} <- CommentService.list_for_target(repo, target_kind, target_id) do
      {:ok,
       %{
         "comments" => Enum.map(comments, comment_payload),
         "target" => %{"kind" => target_kind, "id" => target_id}
       }}
    end
  end

  @spec require_database(Config.t()) :: :ok | {:error, atom()}
  def require_database(%Config{repo: repo, database: database}) do
    case normalized_database(database) do
      nil -> require_live_database(repo)
      database -> require_configured_database(database)
    end
  end

  defp require_configured_database(database) do
    cond do
      Repo.memory_database?(database) -> {:error, :file_backed_database_required}
      remote_database_identity?(database) -> {:error, :local_database_required}
      true -> :ok
    end
  end

  defp require_live_database(repo) do
    case live_main_database_path(repo) do
      {:ok, _path} -> :ok
      :memory -> {:error, :file_backed_database_required}
      :error -> {:error, :database_required}
    end
  end

  defp normalized_database(database) when is_binary(database) do
    case String.trim(database) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalized_database(database) when is_list(database), do: Keyword.get(database, :database)
  defp normalized_database(_database), do: nil

  defp remote_database_identity?(database) when is_binary(database) do
    remote_database_uri?(database) or server_database_dsn?(database) or credential_bearing_database_string?(database)
  end

  defp remote_database_uri?(database) do
    case URI.parse(database) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and scheme != "file" and is_binary(host) -> true
      %URI{scheme: scheme} when scheme in ["http", "https", "postgres", "postgresql", "mysql", "mssql"] -> true
      _uri -> false
    end
  rescue
    _error -> false
  end

  defp credential_bearing_database_string?(database) do
    database =~ ~r/(^|[;?\s])(password|passwd|pwd|secret|token|api[_-]?key)=/i
  end

  defp live_main_database_path(repo) when is_atom(repo) do
    case repo.query("PRAGMA database_list", [], log: false) do
      {:ok, %{rows: rows}} ->
        case Enum.find(rows, &main_database_row?/1) do
          [_seq, "main", path] when is_binary(path) and path != "" -> {:ok, path}
          [_seq, "main", ""] -> :memory
          _row -> :error
        end

      _result ->
        :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp live_main_database_path(_repo), do: :error

  defp main_database_row?([_seq, "main", _path]), do: true
  defp main_database_row?(_row), do: false

  defp server_database_dsn?(database) do
    values = server_database_dsn_values(database)

    Enum.any?(["host", "hostname", "server", "addr", "address", "datasource"], &Map.has_key?(values, &1)) or
      Map.has_key?(values, "dbname") or
      (Map.has_key?(values, "database") and (Map.has_key?(values, "port") or Map.has_key?(values, "trustedconnection")))
  end

  defp server_database_dsn_values(database) do
    case normalized_database(database) do
      nil ->
        %{}

      database ->
        ~r/(?:^|[;\s])([A-Za-z][A-Za-z _-]*)\s*=\s*([^;\s]+)/
        |> Regex.scan(database)
        |> Map.new(fn [_match, key, value] -> {normalize_server_dsn_key(key), trim_server_dsn_value(value)} end)
    end
  end

  defp normalize_server_dsn_key(key) do
    key
    |> String.downcase()
    |> String.replace(~r/[\s_-]/, "")
  end

  defp trim_server_dsn_value(value) do
    value
    |> String.trim()
    |> String.trim("\"'")
  end

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp require_comment_target_kind(target_kind) do
    if target_kind in Comment.target_kinds(), do: :ok, else: {:tool_error, "invalid_target_kind"}
  end

  defp require_comment_target(repo, "work_request", target_id) do
    case WorkRequestService.get(repo, target_id) do
      {:ok, %WorkRequest{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_comment_target(repo, "work_package", target_id) do
    case repo.get(WorkPackage, target_id) do
      %WorkPackage{} -> :ok
      nil -> {:error, :not_found}
    end
  end

  defp require_comment_target(_repo, _target_kind, _target_id), do: {:tool_error, "invalid_target_kind"}

  defp required_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:tool_error, {:invalid_argument, key}}
      :error -> {:tool_error, {:missing_argument, key}}
    end
  end
end
