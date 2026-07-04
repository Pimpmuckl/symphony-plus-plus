defmodule SymphonyElixir.SymphonyPlusPlus.MCP.HandoffDatabase do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.HandleStateStore
  alias SymphonyElixir.SymphonyPlusPlus.Repo

  @spec resolve(String.t() | nil, module()) :: {:ok, String.t()} | {:tool_error, String.t()}
  def resolve(nil, repo) do
    with {:ok, live_database} <- live_file_backed_dispatch_database(repo),
         configured_database <- configured_repo_dispatch_database(repo) do
      dispatch_handoff_database_for_default_config(configured_database, live_database)
    end
  end

  def resolve(database, repo) when is_binary(database) do
    database
    |> String.trim()
    |> dispatch_handoff_database_for_trimmed_config(database, repo)
  end

  defp dispatch_handoff_database_for_default_config({:ok, configured_database}, live_database) do
    cond do
      configured_dispatch_database_matches_live?(configured_database, live_database) and
          writable_dispatch_database?(configured_database) ->
        {:ok, configured_database}

      configured_dispatch_database_matches_live?(configured_database, live_database) ->
        {:tool_error, "read_only_database"}

      true ->
        {:ok, live_database}
    end
  end

  defp dispatch_handoff_database_for_default_config(:none, live_database), do: {:ok, live_database}

  defp dispatch_handoff_database_for_trimmed_config("", _database, repo), do: resolve(nil, repo)

  defp dispatch_handoff_database_for_trimmed_config(_trimmed_database, database, repo) do
    dispatch_handoff_database_for_configured_path(database, repo)
  end

  defp dispatch_handoff_database_for_configured_path(database, repo) when is_binary(database) do
    with false <- Repo.memory_database?(database),
         {:ok, live_database} <- live_file_backed_dispatch_database(repo) do
      database
      |> normalize_configured_dispatch_database()
      |> configured_dispatch_database_result(live_database)
    else
      true -> {:tool_error, "file_backed_database_required"}
      error -> error
    end
  end

  defp configured_dispatch_database_result(configured_database, live_database) do
    if configured_dispatch_database_matches_live?(configured_database, live_database) and
         writable_dispatch_database?(configured_database) do
      {:ok, configured_database}
    else
      configured_dispatch_database_error(configured_database, live_database)
    end
  end

  defp normalize_configured_dispatch_database("file:" <> _uri = database) do
    normalize_sqlite_file_uri(database)
  end

  defp normalize_configured_dispatch_database(database) when is_binary(database) do
    if Path.type(database) == :absolute do
      database
    else
      Path.expand(database)
    end
  end

  defp normalize_sqlite_file_uri(database) do
    case Repo.sqlite_file_uri_path(database) do
      path when is_binary(path) and path != "" ->
        put_sqlite_file_uri_path(database, Path.expand(path))

      _path ->
        database
    end
  end

  defp put_sqlite_file_uri_path("file:" <> uri, expanded_path) do
    encoded_path = encode_sqlite_file_uri_path(expanded_path)

    case String.split(uri, "?", parts: 2) do
      [_uri_path, query] -> "file:" <> encoded_path <> "?" <> query
      [_uri_path] -> "file:" <> encoded_path
    end
  end

  defp encode_sqlite_file_uri_path(path) do
    path
    |> String.replace("\\", "/")
    |> URI.encode(&sqlite_file_uri_path_char?/1)
  end

  defp sqlite_file_uri_path_char?(char), do: URI.char_unreserved?(char) or char in [?/, ?:]

  defp writable_dispatch_database?("file:" <> _uri = database) do
    query_params = sqlite_file_uri_query_params(database)
    mode = query_params |> Map.get("mode", "") |> String.downcase()

    mode not in ["ro", "memory"] and not truthy_sqlite_uri_param?(Map.get(query_params, "immutable"))
  end

  defp writable_dispatch_database?(_database), do: true

  defp configured_dispatch_database_error(configured_database, live_database) do
    if configured_dispatch_database_matches_live?(configured_database, live_database) do
      {:tool_error, "read_only_database"}
    else
      {:tool_error, "database_scope_mismatch"}
    end
  end

  defp configured_dispatch_database_matches_live?("file:" <> _uri = database, live_database) do
    case Repo.sqlite_file_uri_path(database) do
      path when is_binary(path) and path != "" -> Repo.same_database_path?(path, live_database)
      _path -> false
    end
  end

  defp configured_dispatch_database_matches_live?(database, live_database) do
    Repo.same_database_path?(database, live_database)
  end

  defp configured_repo_dispatch_database(repo) when is_atom(repo) do
    cond do
      function_exported?(repo, :database_path_if_present, 0) ->
        repo.database_path_if_present()
        |> configured_repo_dispatch_database_value()

      function_exported?(repo, :database_path, 0) ->
        repo.database_path()
        |> configured_repo_dispatch_database_value()

      true ->
        :none
    end
  rescue
    _error -> :none
  catch
    _kind, _reason -> :none
  end

  defp configured_repo_dispatch_database(_repo), do: :none

  defp configured_repo_dispatch_database_value(database) when is_binary(database) do
    if String.trim(database) == "" do
      :none
    else
      configured_repo_dispatch_database_path_value(database)
    end
  end

  defp configured_repo_dispatch_database_value(_database), do: :none

  defp configured_repo_dispatch_database_path_value(database) when is_binary(database) do
    if Repo.memory_database?(database) do
      :none
    else
      {:ok, normalize_configured_dispatch_database(database)}
    end
  end

  defp sqlite_file_uri_query_params("file:" <> uri) do
    case String.split(uri, "?", parts: 2) do
      [_path, query] -> URI.decode_query(query)
      [_path] -> %{}
    end
  end

  defp truthy_sqlite_uri_param?(value) when is_binary(value), do: String.downcase(value) in ["1", "true", "yes", "on"]
  defp truthy_sqlite_uri_param?(_value), do: false

  defp live_main_database_path(repo) do
    case HandleStateStore.repo_query(repo, "PRAGMA database_list", [], log: false) do
      {:ok, %{rows: rows}} ->
        case Enum.find(rows, &match?([_seq, "main", _path], &1)) do
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

  defp live_file_backed_dispatch_database(repo) do
    case live_main_database_path(repo) do
      {:ok, path} -> {:ok, path}
      :memory -> {:tool_error, "file_backed_database_required"}
      :error -> {:tool_error, "database_required"}
    end
  end
end
