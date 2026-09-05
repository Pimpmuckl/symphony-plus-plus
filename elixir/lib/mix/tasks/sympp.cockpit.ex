defmodule Mix.Tasks.Sympp.Cockpit do
  @moduledoc false

  use Mix.Task

  alias SymphonyElixir.HttpServer
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Config, as: MCPConfig
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Retention
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixirWeb.Endpoint

  @shortdoc "Starts the local Symphony++ operator cockpit"
  @default_host "127.0.0.1"
  @default_port 19_998
  @retention_interval_ms 30 * 60_000
  @board_path "/sympp/board"
  @open_dashboard_override_config_key :sympp_open_dashboard_override
  @open_dashboard_env "SYMPP_OPEN_DASHBOARD"
  @defer_dashboard_open_env "SYMPP_DEFER_DASHBOARD_OPEN"
  @switches [
    database: :string,
    host: :string,
    port: :integer,
    dashboard_origin: :string,
    open_dashboard: :boolean,
    help: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    case parse_args(args) do
      :help ->
        Mix.shell().info(usage())

      {:ok, opts} ->
        run_cockpit(opts)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @spec usage() :: String.t()
  def usage do
    [
      "Usage: mix sympp.cockpit [--host <loopback-host>] [--port <port>] " <>
        "[--database <sqlite-path>] [--dashboard-origin <vite-origin>] [--open-dashboard|--no-open-dashboard]",
      Repo.default_database_help_text()
    ]
    |> Enum.join("\n")
  end

  @doc false
  @spec parse_args_for_test([String.t()]) :: :help | {:ok, keyword()} | {:error, String.t()}
  def parse_args_for_test(args), do: parse_args(args)

  @doc false
  @spec endpoint_config_for_test(keyword()) :: keyword()
  def endpoint_config_for_test(opts), do: endpoint_config(Keyword.get(opts, :endpoint_config, []), opts)

  @doc false
  @spec cockpit_url_for_test(keyword(), non_neg_integer()) :: String.t()
  def cockpit_url_for_test(opts, port), do: cockpit_url(opts, port)

  @doc false
  @spec run_cockpit_for_test(keyword(), (-> term())) :: term()
  def run_cockpit_for_test(opts, wait_fun) when is_function(wait_fun, 0) do
    opts = Keyword.put_new(opts, :operator_dashboard_opener, fn _url -> :ok end)

    run_cockpit(opts, wait_fun)
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} -> validate_opts(opts)
      {_opts, _argv, _invalid} -> {:error, usage()}
    end
  end

  defp validate_opts(opts) do
    normalized_opts = normalize_opts(opts)

    cond do
      Keyword.get(opts, :help, false) ->
        :help

      has_blank_option?(opts, [:database, :host]) ->
        {:error, usage()}

      has_blank_option?(opts, [:dashboard_origin]) ->
        {:error, usage()}

      invalid_dashboard_origin?(Keyword.get(normalized_opts, :dashboard_origin)) ->
        {:error, "Symphony++ cockpit dashboard origin must be a loopback http origin."}

      not loopback_host?(Keyword.fetch!(normalized_opts, :host)) ->
        {:error, "Symphony++ cockpit host must be loopback: #{@default_host}, localhost, ::1, or [::1]."}

      invalid_port?(Keyword.fetch!(normalized_opts, :port)) ->
        {:error, "Symphony++ cockpit port must be an integer from 0 to 65535."}

      true ->
        {:ok, normalized_opts}
    end
  end

  defp normalize_opts(opts) do
    opts
    |> Keyword.put_new(:host, @default_host)
    |> Keyword.put_new(:port, @default_port)
    |> maybe_put_dashboard_origin_from_env()
    |> maybe_put_open_dashboard_from_env()
    |> maybe_resolve_database()
  end

  defp maybe_put_dashboard_origin_from_env(opts) do
    if Keyword.has_key?(opts, :dashboard_origin) do
      opts
    else
      case dashboard_origin_from_env() do
        nil -> opts
        origin -> Keyword.put(opts, :dashboard_origin, origin)
      end
    end
  end

  defp dashboard_origin_from_env do
    case System.get_env("SYMPP_DASHBOARD_ORIGIN") do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp maybe_put_open_dashboard_from_env(opts) do
    if Keyword.has_key?(opts, :open_dashboard) do
      opts
    else
      case open_dashboard_from_env() do
        :unset -> opts
        enabled -> Keyword.put(opts, :open_dashboard, enabled)
      end
    end
  end

  defp open_dashboard_from_env do
    case System.get_env(@open_dashboard_env) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> String.downcase()
        |> then(&(&1 in ["1", "true", "yes", "on"]))

      _value ->
        :unset
    end
  end

  defp maybe_resolve_database(opts) do
    if Keyword.has_key?(opts, :database) do
      Keyword.update!(opts, :database, &resolved_database/1)
    else
      opts
    end
  end

  defp run_cockpit(opts), do: run_cockpit(opts, &wait_forever/0)

  defp run_cockpit(opts, wait_fun) when is_function(wait_fun, 0) do
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    original_endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])
    original_dynamic_repo = Repo.get_dynamic_repo()

    try do
      :ok = ensure_dashboard_assets(opts)
      # Freeze daemon source identity at startup so smoke checks can detect a later checkout update.
      MCPConfig.source_revision()
      configure_cockpit(opts, original_endpoint_config)
      {:ok, _started} = ensure_runtime_started()
      :ok = prepare_work_request_ledger()
      opts = put_open_dashboard_default(opts)
      :ok = start_http_server_or_raise(opts)
      port = wait_for_bound_port()

      Mix.shell().info("Symphony++ local operator dashboard: #{cockpit_url(opts, port)}")
      Mix.shell().info("Symphony++ API bridge: #{api_url(opts, port)}")
      :ok = maybe_open_operator_dashboard(opts, port)
      Mix.shell().info(dashboard_open_message(opts))
      Mix.shell().info("Press Ctrl+C to stop.")

      wait_fun.()
    after
      restore_env(:sympp_repo_database, original_database)
      Application.put_env(:symphony_elixir, Endpoint, original_endpoint_config)
      Repo.put_dynamic_repo(original_dynamic_repo)
      stop_owned_endpoint(Process.delete(:sympp_cockpit_endpoint_pid))
      stop_owned_endpoint(Process.delete(:sympp_cockpit_repo_pid))
      stop_owned_processes(Process.delete(:sympp_cockpit_pubsub_pids))
      stop_owned_endpoint(Process.delete(:sympp_cockpit_task_supervisor_pid))
    end
  end

  defp start_http_server_or_raise(opts) do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      case HttpServer.start_link(host: server_host(Keyword.fetch!(opts, :host)), port: Keyword.fetch!(opts, :port)) do
        {:ok, pid} ->
          Process.put(:sympp_cockpit_endpoint_pid, pid)
          :ok

        {:error, reason} ->
          flush_exit_messages()
          Mix.raise(cockpit_bind_error(opts, reason))
      end
    catch
      :exit, reason ->
        flush_exit_messages()
        Mix.raise(cockpit_bind_error(opts, reason))
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp flush_exit_messages do
    receive do
      {:EXIT, _pid, _reason} -> flush_exit_messages()
    after
      0 -> :ok
    end
  end

  defp cockpit_bind_error(opts, reason) do
    host = opts |> Keyword.fetch!(:host) |> url_host()
    port = Keyword.fetch!(opts, :port)

    "Symphony++ cockpit could not bind http://#{host}:#{port}. " <>
      "Stop the existing local daemon or pass --port 0 / --port <port>. " <>
      "Reason: #{inspect(reason)}"
  end

  defp configure_cockpit(opts, original_endpoint_config) do
    if database = Keyword.get(opts, :database) do
      Application.put_env(:symphony_elixir, :sympp_repo_database, database)
    end

    Application.put_env(:symphony_elixir, Endpoint, endpoint_config(original_endpoint_config, opts))
  end

  defp ensure_dashboard_assets(opts) do
    if Keyword.has_key?(opts, :dashboard_origin) do
      :ok
    else
      ensure_built_dashboard_assets()
    end
  end

  defp ensure_built_dashboard_assets do
    if File.exists?(runtime_dashboard_index_path()) do
      :ok
    else
      build_dashboard_assets()
    end
  end

  defp build_dashboard_assets do
    assets_dir = Path.expand("assets", File.cwd!())
    npm = System.find_executable("npm") || System.find_executable("npm.cmd")

    cond do
      not File.dir?(assets_dir) ->
        Mix.raise("Symphony++ dashboard assets directory is missing: #{assets_dir}")

      is_nil(npm) ->
        Mix.raise("Symphony++ dashboard assets are missing and npm was not found. Run npm install/build in #{assets_dir}.")

      true ->
        {executable, args} = SymphonyElixir.LocalCommand.executable_invocation(npm, ["run", "build"])

        case System.cmd(executable, args, cd: assets_dir, stderr_to_stdout: true) do
          {_output, 0} ->
            sync_dashboard_static_assets()

          {output, status} ->
            Mix.raise("Symphony++ dashboard asset build failed with exit #{status}:\n#{output}")
        end
    end
  end

  defp sync_dashboard_static_assets do
    source_static_dir = Path.expand("priv/static", File.cwd!())
    target_static_dir = :symphony_elixir |> :code.priv_dir() |> Path.join("static")

    if Path.expand(source_static_dir) != Path.expand(target_static_dir) do
      File.mkdir_p!(Path.dirname(target_static_dir))
      File.cp_r!(source_static_dir, target_static_dir)
    end

    unless File.exists?(runtime_dashboard_index_path()) do
      Mix.raise("Symphony++ dashboard asset build completed but #{runtime_dashboard_index_path()} was not created.")
    end

    :ok
  end

  defp runtime_dashboard_index_path do
    :symphony_elixir
    |> :code.priv_dir()
    |> Path.join("static/index.html")
  end

  defp endpoint_config(original_endpoint_config, opts) do
    original_endpoint_config
    |> Keyword.merge(server: false)
    |> Keyword.delete(:sympp_dashboard_origin)
    |> Keyword.delete(@open_dashboard_override_config_key)
    |> maybe_put_open_dashboard_override(opts)
    |> maybe_put_dashboard_origin(opts)
    |> maybe_force_default_repo(opts)
  end

  defp maybe_put_open_dashboard_override(endpoint_config, opts) do
    case Keyword.fetch(opts, :open_dashboard) do
      {:ok, enabled} when is_boolean(enabled) -> Keyword.put(endpoint_config, @open_dashboard_override_config_key, enabled)
      :error -> endpoint_config
    end
  end

  defp maybe_put_dashboard_origin(endpoint_config, opts) do
    case Keyword.get(opts, :dashboard_origin) do
      origin when is_binary(origin) and origin != "" -> Keyword.put(endpoint_config, :sympp_dashboard_origin, origin)
      _origin -> endpoint_config
    end
  end

  defp maybe_force_default_repo(endpoint_config, opts) do
    if Keyword.has_key?(opts, :database) do
      Keyword.put(endpoint_config, :sympp_repo, Repo)
    else
      endpoint_config
    end
  end

  defp ensure_runtime_started do
    with {:ok, _started} <- Application.ensure_all_started(:phoenix),
         {:ok, _started} <- Application.ensure_all_started(:bandit),
         {:ok, _started} <- Application.ensure_all_started(:ecto_sql),
         {:ok, _started} <- ensure_pubsub_started(),
         {:ok, _started} <- ensure_task_supervisor_started() do
      {:ok, []}
    end
  end

  defp ensure_task_supervisor_started do
    case Process.whereis(SymphonyElixir.TaskSupervisor) do
      pid when is_pid(pid) ->
        {:ok, []}

      nil ->
        case Task.Supervisor.start_link(name: SymphonyElixir.TaskSupervisor) do
          {:ok, pid} ->
            Process.put(:sympp_cockpit_task_supervisor_pid, pid)
            {:ok, [Task.Supervisor]}

          {:error, {:already_started, _pid}} ->
            {:ok, []}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp ensure_pubsub_started do
    case Process.whereis(SymphonyElixir.PubSub) do
      pid when is_pid(pid) ->
        {:ok, []}

      nil ->
        case Phoenix.PubSub.Supervisor.start_link(name: SymphonyElixir.PubSub) do
          {:ok, pid} ->
            Process.put(:sympp_cockpit_pubsub_pids, [Process.whereis(SymphonyElixir.PubSub), pid])
            {:ok, [Phoenix.PubSub]}

          {:error, {:already_started, _pid}} ->
            {:ok, []}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp prepare_work_request_ledger do
    case start_retention_repo() do
      {:ok, repo_pid} ->
        Process.put(:sympp_cockpit_repo_pid, repo_pid)
        migrate_work_request_ledger()

      {:error, reason} ->
        Mix.raise("Symphony++ cockpit WorkRequest ledger open failed: #{inspect(reason)}")
    end
  end

  defp migrate_work_request_ledger do
    case WorkRequestRepository.migrate(Repo) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("Symphony++ cockpit WorkRequest ledger migration failed: #{inspect(reason)}")
    end
  end

  defp run_work_request_retention_pass do
    with {:ok, settings} <- OperatorSettingsRepository.get(Repo),
         :ok <- Retention.run(Repo, settings) do
      :ok
    else
      {:error, reason} -> skip_operator_retention(reason)
    end
  end

  defp put_open_dashboard_default(opts) do
    if Keyword.has_key?(opts, :open_dashboard) do
      opts
    else
      Keyword.put(opts, :open_dashboard, open_dashboard_from_settings?())
    end
  end

  defp open_dashboard_from_settings? do
    case OperatorSettingsRepository.get(Repo) do
      {:ok, settings} -> settings.open_dashboard_on_boot
      _error -> true
    end
  end

  defp skip_operator_retention(reason) do
    Mix.shell().info("Symphony++ cockpit retention skipped: #{inspect(reason)}")
    :ok
  end

  defp start_retention_repo do
    database = Repo.database_path()

    with :ok <- validate_retention_database_path(database) do
      case Repo.start_link(Repo.child_options(database: database, name: Repo.process_name(database), log: false)) do
        {:ok, pid} ->
          Repo.put_dynamic_repo(pid)
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          Repo.put_dynamic_repo(pid)
          {:ok, nil}

        {:error, reason} ->
          {:error, {:repo_start_failed, reason}}
      end
    end
  end

  defp validate_retention_database_path(database) when is_binary(database) do
    if Repo.filesystem_database_path?(database) and File.dir?(database) do
      {:error, {:database_path_is_directory, database}}
    else
      :ok
    end
  end

  defp wait_for_bound_port do
    Enum.reduce_while(1..500, nil, fn _attempt, _port ->
      case HttpServer.bound_port() do
        port when is_integer(port) and port > 0 ->
          {:halt, port}

        _port ->
          Process.sleep(20)
          {:cont, nil}
      end
    end) || Mix.raise("Symphony++ cockpit started but no bound HTTP port was reported.")
  end

  defp cockpit_url(opts, port) do
    dashboard_origin =
      opts
      |> Keyword.get(:dashboard_origin, api_url(opts, port))
      |> String.trim_trailing("/")

    "#{dashboard_origin}#{@board_path}"
  end

  defp maybe_open_operator_dashboard(opts, port) do
    if Keyword.get(opts, :open_dashboard, false) and not defer_dashboard_open?() do
      open_operator_dashboard(opts, port)
    else
      :ok
    end
  end

  defp dashboard_open_message(opts) do
    cond do
      Keyword.get(opts, :open_dashboard, false) and defer_dashboard_open?() ->
        "Dashboard browser open deferred until an MCP client connects."

      Keyword.get(opts, :open_dashboard, false) ->
        "Dashboard browser open attempted."

      true ->
        "Dashboard browser auto-open disabled; pass --open-dashboard or set #{@open_dashboard_env}=1 to open it."
    end
  end

  defp defer_dashboard_open?, do: System.get_env(@defer_dashboard_open_env) == "1"

  defp open_operator_dashboard(opts, port) do
    opener = Keyword.get(opts, :operator_dashboard_opener, &default_open_operator_dashboard/1)

    opts
    |> operator_dashboard_open_urls(port)
    |> Enum.reduce(:ok, fn url, first_result ->
      result = url |> opener.() |> normalize_open_result()

      case first_result do
        :ok -> result
        other -> other
      end
    end)
  end

  defp operator_dashboard_open_urls(opts, port) do
    [cockpit_url(opts, port)]
  end

  defp normalize_open_result(:ok), do: :ok

  defp normalize_open_result({:error, reason}) do
    Mix.shell().info("Symphony++ dashboard browser open skipped: #{inspect(reason)}")
    :ok
  end

  defp normalize_open_result(_result), do: :ok

  defp default_open_operator_dashboard(url) do
    case browser_open_command(url) do
      {executable, args} -> run_browser_open_command(executable, args)
      :error -> {:error, :no_browser_open_command}
    end
  end

  defp browser_open_command(url) do
    case :os.type() do
      {:win32, _name} -> browser_open_command("rundll32.exe", ["url.dll,FileProtocolHandler", url])
      {:unix, :darwin} -> browser_open_command("open", [url])
      {:unix, _name} -> browser_open_command("xdg-open", [url])
    end
  end

  defp browser_open_command(executable, args) do
    case System.find_executable(executable) do
      nil -> :error
      path -> {path, args}
    end
  end

  defp run_browser_open_command(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:exit_status, status}}
    end
  end

  defp api_url(opts, port) do
    host = opts |> Keyword.fetch!(:host) |> url_host()
    "http://#{host}:#{port}"
  end

  defp url_host("::1"), do: "[::1]"
  defp url_host(host), do: host

  defp stop_owned_endpoint(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp stop_owned_endpoint(_pid), do: :ok

  defp stop_owned_processes(pids) when is_list(pids) do
    pids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(&stop_owned_process/1)
  end

  defp stop_owned_processes(_pids), do: :ok

  defp stop_owned_process(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      stop_otp_process(pid)
    else
      :ok
    end
  end

  defp stop_owned_process(_pid), do: :ok

  defp stop_otp_process(pid) do
    Supervisor.stop(pid, :shutdown, 1_000)
  catch
    :exit, _reason -> stop_gen_server(pid)
  end

  defp stop_gen_server(pid) do
    GenServer.stop(pid, :shutdown, 1_000)
  catch
    :exit, _reason -> :ok
  end

  defp wait_forever do
    receive do
    after
      @retention_interval_ms ->
        run_work_request_retention_pass()
        wait_forever()
    end
  end

  defp resolved_database(nil), do: nil

  defp resolved_database(database) when is_binary(database) do
    if Repo.filesystem_database_path?(database) do
      database = Path.expand(database)
      File.mkdir_p!(Path.dirname(database))
      database
    else
      database
    end
  end

  defp loopback_host?(host) when is_binary(host) do
    host |> String.downcase() |> then(&(&1 in ["127.0.0.1", "localhost", "::1", "[::1]"]))
  end

  defp loopback_host?({127, _second, _third, _fourth}), do: true
  defp loopback_host?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_host?(_host), do: false

  defp invalid_port?(port), do: not (is_integer(port) and port >= 0 and port <= 65_535)

  defp server_host("[::1]"), do: "::1"
  defp server_host(host), do: host

  defp invalid_dashboard_origin?(nil), do: false

  defp invalid_dashboard_origin?(origin) when is_binary(origin) do
    case URI.parse(String.trim(origin)) do
      %URI{scheme: "http", host: host} when is_binary(host) -> not local_dashboard_host?(host)
      _origin -> true
    end
  end

  defp invalid_dashboard_origin?(_origin), do: true

  defp local_dashboard_host?(host) when is_binary(host) do
    host = String.downcase(host)
    host in ["localhost", "127.0.0.1", "::1", "[::1]"] or String.ends_with?(host, ".localhost")
  end

  defp has_blank_option?(opts, keys) do
    Enum.any?(keys, &(Keyword.has_key?(opts, &1) and blank?(Keyword.get(opts, &1))))
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
