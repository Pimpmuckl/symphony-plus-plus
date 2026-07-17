defmodule Mix.Tasks.Sympp.DispatchWorkPackage do
  @moduledoc false

  use Mix.Task

  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDispatch
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.Workflow

  @shortdoc "Dispatches one planned Symphony++ WorkRequest WorkPackage"

  @switches [
    database: :string,
    work_request_id: :string,
    work_package_id: :string,
    claimed_by: :string,
    help: :boolean
  ]
  @blank_checked_options [:database, :work_request_id, :work_package_id, :claimed_by]

  @impl Mix.Task
  def run(args) do
    case parse_args(args) do
      :help ->
        Mix.shell().info(usage())

      {:ok, opts} ->
        run_dispatch(opts)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @spec usage() :: String.t()
  def usage do
    [
      "Usage: mix sympp.dispatch_work_package --work-request-id <id> --work-package-id <id>",
      "[--database <sqlite-path>]",
      "[--claimed-by <worker-id>]",
      Repo.default_database_help_text()
    ]
    |> Enum.join(" ")
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} -> validate_opts(opts)
      {_opts, _argv, _invalid} -> {:error, usage()}
    end
  end

  defp validate_opts(opts) do
    cond do
      Keyword.get(opts, :help, false) ->
        :help

      blank?(Keyword.get(opts, :work_request_id)) ->
        {:error, usage()}

      blank?(Keyword.get(opts, :work_package_id)) ->
        {:error, usage()}

      has_blank_option?(opts, @blank_checked_options) ->
        {:error, usage()}

      true ->
        {:ok, opts}
    end
  end

  defp run_dispatch(opts) do
    original_repo = Repo.get_dynamic_repo()

    case start_repo(Keyword.get(opts, :database)) do
      {:ok, repo_pid, database} ->
        try do
          with :ok <- WorkRequestRepository.migrate(Repo),
               {:ok, dispatch} <-
                 WorkPackageDispatch.dispatch(
                   Repo,
                   Keyword.fetch!(opts, :work_request_id),
                   Keyword.fetch!(opts, :work_package_id),
                   dispatch_bootstrap_opts(opts, database)
                 ) do
            dispatch
            |> WorkPackageDispatch.response_payload()
            |> Jason.encode!(pretty: true)
            |> Mix.shell().info()
          else
            {:error, reason} -> Mix.raise(WorkPackageDispatch.error_message(reason))
          end
        after
          stop_repo(repo_pid)
          Repo.put_dynamic_repo(original_repo)
        end

      {:error, reason} ->
        Repo.put_dynamic_repo(original_repo)
        Mix.raise(WorkPackageDispatch.error_message(reason))
    end
  end

  defp start_repo(database) do
    with :ok <- ensure_repo_dependencies_started() do
      database = resolved_database(database)

      case Repo.start_link(database: database, name: Repo.process_name(database), pool_size: 1, log: false) do
        {:ok, pid} ->
          Repo.put_dynamic_repo(pid)
          {:ok, pid, database}

        {:error, {:already_started, pid}} ->
          Repo.put_dynamic_repo(pid)
          {:ok, nil, database}

        {:error, reason} ->
          {:error, {:repo_start_failed, reason}}
      end
    end
  end

  defp stop_repo(pid) when is_pid(pid), do: GenServer.stop(pid)
  defp stop_repo(_pid), do: :ok

  defp dispatch_bootstrap_opts(opts, database) do
    [
      claimed_by: Keyword.get(opts, :claimed_by),
      database: database
    ]
    |> drop_nil_values()
  end

  defp drop_nil_values(opts), do: Enum.reject(opts, fn {_key, value} -> is_nil(value) end)

  defp ensure_repo_dependencies_started do
    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _started} -> :ok
      {:error, reason} -> {:error, {:ecto_start_failed, reason}}
    end
  end

  @doc false
  @spec database_path_for_test(String.t() | nil) :: String.t()
  def database_path_for_test(database), do: resolved_database(database)

  defp resolved_database(nil) do
    original_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    try do
      use_mix_project_workflow()
      Application.delete_env(:symphony_elixir, :sympp_repo_database)
      Repo.database_path()
    after
      restore_sympp_repo_database(original_database)
      restore_workflow(original_workflow)
    end
  end

  defp resolved_database(database) when is_binary(database) do
    cond do
      Repo.filesystem_database_path?(database) ->
        database = Path.expand(database)
        File.mkdir_p!(Path.dirname(database))
        database

      sqlite_file_uri?(database) and not Repo.memory_database?(database) ->
        normalize_sqlite_file_uri(database)

      true ->
        database
    end
  end

  defp sqlite_file_uri?("file:" <> _uri), do: true
  defp sqlite_file_uri?(_database), do: false

  defp normalize_sqlite_file_uri(database) do
    case Repo.sqlite_file_uri_path(database) do
      uri_path when is_binary(uri_path) and uri_path != "" ->
        expanded_path = Path.expand(uri_path)
        File.mkdir_p!(Path.dirname(expanded_path))
        put_sqlite_file_uri_path(database, expanded_path)

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

  defp use_mix_project_workflow do
    mix_project_workflow()
    |> case do
      path when is_binary(path) -> Workflow.set_workflow_file_path(path)
      nil -> :ok
    end
  end

  defp restore_workflow(nil), do: Workflow.clear_workflow_file_path()
  defp restore_workflow(path) when is_binary(path), do: Workflow.set_workflow_file_path(path)

  defp restore_sympp_repo_database(nil), do: Application.delete_env(:symphony_elixir, :sympp_repo_database)
  defp restore_sympp_repo_database(database), do: Application.put_env(:symphony_elixir, :sympp_repo_database, database)

  defp mix_project_workflow do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.expand()
    |> Path.join("WORKFLOW.md")
    |> existing_file()
  end

  defp existing_file(path) do
    if File.exists?(path), do: path
  end

  defp has_blank_option?(opts, keys) do
    Enum.any?(keys, &(Keyword.has_key?(opts, &1) and blank?(Keyword.get(opts, &1))))
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
