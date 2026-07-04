defmodule SymphonyElixirWeb.SymppDashboardApi.Runtime do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.TrackerAdapter
  alias SymphonyElixirWeb.Endpoint

  @access_grant_lazy_migration_columns ["phase_id", "scope_repo", "scope_base_branch", "provenance"]

  @spec dashboard_ledger_database(module()) :: term()
  def dashboard_ledger_database(repo) do
    Repo.operator_database_path(repo)
  end

  @spec dashboard_storage_present?() :: boolean()
  def dashboard_storage_present? do
    case configured_repo() do
      Repo -> configured_repo_storage_present?()
      nil -> configured_repo_storage_present?()
      configured_repo -> custom_repo_storage_present?(configured_repo)
    end
  end

  defp configured_repo_storage_present? do
    configured_repo_storage_present?(Repo.database_path_if_present(), Process.whereis(Repo))
  end

  defp configured_repo_storage_present?(nil, pid) when is_pid(pid), do: local_repo_storage_present?(pid)
  defp configured_repo_storage_present?(nil, nil), do: false

  defp configured_repo_storage_present?(path, pid) when is_pid(pid) do
    local_repo_storage_present?(pid) or repo_matches_database?(pid, path) or
      :global.whereis_name(Repo.process_key(path)) != :undefined or persistent_database_present?(path)
  end

  defp configured_repo_storage_present?(path, nil), do: persistent_database_present?(path)

  defp local_repo_storage_present?(pid), do: not explicit_database_configured?() and repo_persistent_storage_present?(pid)

  defp explicit_database_configured? do
    Application.get_env(:symphony_elixir, :sympp_repo_database) != nil or configured_repo_database_configured?()
  end

  defp configured_repo_database_configured? do
    :symphony_elixir
    |> Application.get_env(Repo, [])
    |> Keyword.get(:database)
    |> configured_database_value?()
  end

  defp configured_database_value?(database_path) when is_binary(database_path), do: String.trim(database_path) != ""
  defp configured_database_value?(nil), do: false
  defp configured_database_value?(_database_path), do: true

  defp custom_repo_storage_present?(repo) do
    if ecto_repo?(repo) do
      custom_ecto_repo_storage_present?(repo)
    else
      true
    end
  end

  defp custom_ecto_repo_storage_present?(repo) do
    database_path = custom_repo_database_path(repo)

    case Process.whereis(repo) do
      pid when is_pid(pid) ->
        persistent_database_present?(database_path) and custom_repo_matches_database?(repo, database_path)

      nil ->
        persistent_database_present?(database_path)
    end
  end

  defp persistent_database_present?(database_path) do
    cond do
      Repo.memory_database?(database_path) -> false
      is_binary(database_path) -> filesystem_database_present?(database_path)
      true -> false
    end
  end

  defp filesystem_database_present?(database_path) do
    case filesystem_database_path(database_path) do
      path when is_binary(path) -> String.trim(path) != "" and File.exists?(path)
      _path -> false
    end
  end

  defp repo_persistent_storage_present?(pid) when is_pid(pid) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      case Repo.query("PRAGMA database_list", []) do
        {:ok, %{rows: rows}} ->
          Enum.any?(rows, fn
            [_seq, "main", path] when is_binary(path) and path != "" -> File.exists?(path)
            _row -> false
          end)

        {:error, _reason} ->
          false
      end
    rescue
      _error in Exqlite.Error -> false
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp filesystem_database_path("file:" <> _rest = database_path) do
    case Repo.sqlite_file_uri_path(database_path) do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _path -> nil
    end
  end

  defp filesystem_database_path(database_path), do: Path.expand(database_path)

  @spec normalize_storage_errors((-> term())) :: term()
  def normalize_storage_errors(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)

    if message |> String.downcase() |> busy_message?() do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end

  defp busy_message?(message) do
    String.contains?(message, "busy") or String.contains?(message, "locked")
  end

  @spec missing_schema_message?(String.t()) :: boolean()
  def missing_schema_message?(message) do
    message
    |> String.downcase()
    |> String.contains?("no such table")
  end

  @spec missing_access_grant_migration_column_message?(String.t()) :: boolean()
  def missing_access_grant_migration_column_message?(message) do
    message = String.downcase(message)

    String.contains?(message, "no such column") and
      Enum.any?(@access_grant_lazy_migration_columns, &String.contains?(message, &1))
  end

  @spec with_dashboard_repo((module() -> term()), keyword()) :: term()
  def with_dashboard_repo(fun, opts \\ []) when is_function(fun, 1) and is_list(opts) do
    migrate? = Keyword.get(opts, :migrate?, true)

    case configured_repo() do
      Repo -> with_configured_sympp_repo(fun, migrate?)
      repo when is_atom(repo) and not is_nil(repo) -> with_custom_repo(repo, fun, migrate?)
      nil -> with_dynamic_dashboard_repo(fun, migrate?)
    end
  end

  defp configured_repo do
    :symphony_elixir
    |> Application.get_env(Endpoint, [])
    |> Keyword.get(:sympp_repo)
    |> Kernel.||(Endpoint.config(:sympp_repo))
  end

  defp with_configured_sympp_repo(fun, migrate?) do
    database_path = Repo.database_path()

    with {:ok, pid, owner} <- configured_sympp_repo(database_path) do
      with_optional_migrated_repo(
        migrate?,
        pid,
        owner,
        database_path,
        fn -> ensure_configured_repo_migrated(pid, owner, database_path) end,
        fn -> call_configured_repo(pid, owner, fun) end
      )
    end
  end

  defp configured_sympp_repo(database_path) do
    case Process.whereis(Repo) do
      pid when is_pid(pid) -> local_configured_repo(pid, database_path)
      nil -> global_or_started_configured_repo(database_path)
    end
  end

  defp local_configured_repo(pid, database_path) do
    if not explicit_database_configured?() or repo_matches_database?(pid, database_path) do
      {:ok, pid, :local}
    else
      global_or_started_configured_repo(database_path)
    end
  end

  defp global_or_started_configured_repo(database_path) do
    case :global.whereis_name(Repo.process_key(database_path)) do
      pid when is_pid(pid) -> {:ok, pid, :dynamic}
      :undefined -> start_linked_repo(database_path)
    end
  end

  defp ensure_configured_repo_migrated(pid, :local, database_path) do
    ensure_repo_migrated(Repo, pid, local_repo_database_path(database_path))
  end

  defp ensure_configured_repo_migrated(pid, _owner, database_path), do: ensure_repo_migrated(Repo, pid, database_path)

  defp local_repo_database_path(fallback) do
    Repo.config()
    |> Keyword.get(:database)
    |> Kernel.||(fallback)
  end

  defp repo_matches_database?(pid, database_path) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      case Repo.query("PRAGMA database_list", []) do
        {:ok, %{rows: rows}} ->
          database_rows_match?(rows, database_path)

        {:error, _reason} ->
          false
      end
    rescue
      _error in Exqlite.Error -> false
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp call_configured_repo(pid, :dynamic, fun), do: call_dynamic_repo(pid, fun)
  defp call_configured_repo(pid, {:direct, _direct_pid}, fun), do: call_dynamic_repo(pid, fun)
  defp call_configured_repo(_pid, _owner, fun), do: fun.(Repo)

  defp call_dynamic_repo(pid, fun) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      fun.(Repo)
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp with_dynamic_dashboard_repo(fun, migrate?) do
    case Process.whereis(Repo) do
      pid when is_pid(pid) ->
        if explicit_database_configured?() do
          with_started_dynamic_dashboard_repo(fun, migrate?)
        else
          with_running_dynamic_dashboard_repo(pid, fun, migrate?)
        end

      nil ->
        with_started_dynamic_dashboard_repo(fun, migrate?)
    end
  end

  defp with_started_dynamic_dashboard_repo(fun, migrate?) do
    database_path = Repo.database_path()

    with {:ok, pid, owner} <- ensure_repo_started(database_path) do
      with_optional_migrated_repo(
        migrate?,
        pid,
        owner,
        database_path,
        fn -> ensure_repo_migrated(Repo, pid, database_path) end,
        fn -> call_dynamic_repo(pid, fun) end
      )
    end
  end

  defp with_running_dynamic_dashboard_repo(pid, fun, migrate?) do
    database_path = local_repo_database_path(Repo.database_path())

    with_optional_migrated_repo(
      migrate?,
      pid,
      :local,
      database_path,
      fn -> ensure_repo_migrated(Repo, pid, database_path) end,
      fn -> call_dynamic_repo(pid, fun) end
    )
  end

  defp ensure_repo_started(database_path) do
    case :global.whereis_name(Repo.process_key(database_path)) do
      pid when is_pid(pid) -> {:ok, pid, :shared}
      :undefined -> start_repo(database_path)
    end
  end

  defp start_repo(database_path) do
    child_spec =
      Supervisor.child_spec(
        {Repo, Repo.child_options(database: database_path, name: Repo.process_name(database_path))},
        id: Repo.child_id(database_path)
      )

    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) -> start_supervised_repo(child_spec)
      nil -> start_linked_repo(database_path)
    end
  end

  defp start_supervised_repo(child_spec) do
    case Supervisor.start_child(SymphonyElixir.Supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid, :shared}
      {:ok, pid, _info} -> {:ok, pid, :shared}
      {:error, {:already_started, pid}} -> {:ok, pid, :shared}
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp start_linked_repo(database_path) do
    options = Repo.child_options(database: database_path, name: nil)

    case Repo.start_link(options) do
      {:ok, pid} -> unlink_started_repo(pid, {:direct, pid})
      {:error, {:already_started, pid}} -> {:ok, pid, :shared}
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp unlink_started_repo(pid, owner) do
    Process.unlink(pid)
    {:ok, pid, owner}
  end

  defp stop_owned_repo(_pid, {:direct, direct_pid}, _database_path), do: stop_direct_repo(direct_pid)

  defp stop_owned_repo(_pid, _owner, _database_path), do: :ok

  defp stop_direct_repo(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp with_custom_repo(repo, fun, migrate?) do
    if ecto_repo?(repo) do
      with_ecto_custom_repo(repo, fun, migrate?)
    else
      fun.(repo)
    end
  end

  defp with_ecto_custom_repo(repo, fun, migrate?) do
    :global.trans({{__MODULE__, :custom_repo}, repo}, fn ->
      with_ecto_custom_repo_locked(repo, fun, migrate?)
    end)
  end

  defp with_ecto_custom_repo_locked(repo, fun, migrate?) do
    database_path = custom_repo_database_path(repo)

    with {:ok, pid, owner} <- ensure_custom_repo_started(repo, database_path) do
      with_optional_migrated_repo(
        migrate?,
        pid,
        owner,
        database_path,
        fn -> ensure_repo_migrated(repo, pid, database_path) end,
        fn -> fun.(repo) end
      )
    end
  end

  defp with_optional_migrated_repo(true, pid, owner, database_path, migrate_fun, call_fun) do
    with_migrated_repo(pid, owner, database_path, migrate_fun, call_fun)
  end

  defp with_optional_migrated_repo(false, pid, owner, database_path, _migrate_fun, call_fun) do
    call_unmigrated_repo(pid, owner, database_path, call_fun)
  end

  defp call_unmigrated_repo(pid, owner, database_path, call_fun) do
    call_fun.()
  after
    stop_owned_repo(pid, owner, database_path)
  end

  defp ecto_repo?(repo) do
    Code.ensure_loaded?(repo) and function_exported?(repo, :__adapter__, 0) and function_exported?(repo, :start_link, 1)
  end

  defp custom_repo_database_path(repo) do
    repo.config()
    |> Keyword.get(:database)
    |> normalize_custom_repo_database_config()
    |> Kernel.||(Repo.database_path())
  end

  defp normalize_custom_repo_database_config(database_path) when is_binary(database_path) do
    if String.trim(database_path) == "", do: nil, else: database_path
  end

  defp normalize_custom_repo_database_config(database_path), do: database_path

  defp ensure_custom_repo_started(repo, database_path) do
    case Process.whereis(repo) do
      pid when is_pid(pid) -> reuse_custom_repo(repo, pid, database_path)
      nil -> start_custom_repo(repo, database_path)
    end
  end

  defp reuse_custom_repo(repo, pid, database_path) do
    if custom_repo_matches_database?(repo, database_path) do
      {:ok, pid, :local}
    else
      {:error, {:storage_failed, :database_mismatch}}
    end
  end

  defp custom_repo_matches_database?(repo, database_path) do
    case repo.query("PRAGMA database_list", []) do
      {:ok, %{rows: rows}} ->
        database_rows_match?(rows, database_path)

      {:error, _reason} ->
        false
    end
  rescue
    _error in Exqlite.Error -> false
  end

  defp database_rows_match?(rows, database_path) do
    Enum.any?(rows, fn
      [_seq, "main", path] when path in [nil, ""] -> Repo.memory_database?(database_path)
      [_seq, _name, path] when is_binary(path) and path != "" -> database_row_path_matches?(path, database_path)
      _row -> false
    end)
  end

  defp database_row_path_matches?(path, "file:" <> _rest = database_path) do
    Repo.same_database_path?(path, Repo.sqlite_file_uri_path(database_path))
  end

  defp database_row_path_matches?(path, database_path), do: Repo.same_database_path?(path, database_path)

  defp start_custom_repo(repo, database_path) do
    case repo.start_link(database: database_path, name: repo) do
      {:ok, pid} -> unlink_started_repo(pid, {:direct, pid})
      {:error, {:already_started, pid}} -> {:ok, pid, :local}
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp with_migrated_repo(pid, owner, database_path, migrate_fun, call_fun) do
    case migrate_fun.() do
      :ok ->
        try do
          call_fun.()
        after
          stop_owned_repo(pid, owner, database_path)
        end

      {:error, _reason} = error ->
        stop_owned_repo(pid, owner, database_path)
        error
    end
  end

  defp ensure_repo_migrated(repo, pid, database_path) when is_atom(repo) and is_pid(pid) do
    database_key = {repo, Repo.database_key(database_path)}

    if migrated_database?(database_key) and migrated_schema?(repo, pid) do
      :ok
    else
      migrate_with_lock(repo, pid, database_path, database_key)
    end
  end

  defp migrate_with_lock(repo, pid, database_path, database_key) do
    TrackerAdapter.run_with_migration_file_lock(database_path, fn ->
      migrate_if_needed(repo, pid, database_key)
    end)
  end

  defp migrate_if_needed(repo, pid, database_key) do
    if migrated_database?(database_key) and migrated_schema?(repo, pid) do
      :ok
    else
      migrate_repo(repo, pid, database_key)
    end
  end

  defp migrate_repo(Repo, pid, database_key) do
    migration_opts = [all: true, dynamic_repo: pid, log: false]

    Ecto.Migrator.run(Repo, Migrations.all(), :up, migration_opts)

    mark_database_migrated(database_key)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
    error -> {:error, {:migration_failed, error}}
  end

  defp migrate_repo(repo, _pid, database_key) do
    Ecto.Migrator.run(repo, Migrations.all(), :up, all: true, log: false)

    mark_database_migrated(database_key)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
    error -> {:error, {:migration_failed, error}}
  end

  defp migrated_database?(database_key), do: MapSet.member?(migrated_databases(), database_key)

  defp migrated_schema?(Repo, pid) when is_pid(pid) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      repo_schema_migrated?(Repo)
    rescue
      _error in Exqlite.Error -> false
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp migrated_schema?(repo, _pid), do: repo_schema_migrated?(repo)

  defp repo_schema_migrated?(repo) do
    expected_versions = migration_versions()

    case repo.query("SELECT version FROM schema_migrations", []) do
      {:ok, %{rows: rows}} ->
        migrated_versions =
          rows
          |> Enum.map(fn [version] -> to_string(version) end)
          |> MapSet.new()

        expected_versions != [] and MapSet.subset?(MapSet.new(expected_versions), migrated_versions)

      {:error, _reason} ->
        false
    end
  rescue
    _error in Exqlite.Error -> false
  end

  defp migration_versions do
    Migrations.version_strings()
  end

  defp mark_database_migrated(database_key) do
    migrated_databases = MapSet.put(migrated_databases(), database_key)
    Application.put_env(:symphony_elixir, :sympp_dashboard_api_migrated_databases, migrated_databases)
    :ok
  end

  defp migrated_databases do
    case Application.get_env(:symphony_elixir, :sympp_dashboard_api_migrated_databases, MapSet.new()) do
      %MapSet{} = migrated_databases -> migrated_databases
      _invalid -> MapSet.new()
    end
  end
end
