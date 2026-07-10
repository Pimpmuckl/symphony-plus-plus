defmodule SymphonyElixir.SymphonyPlusPlus.OperatorDashboardOpener do
  @moduledoc false

  use GenServer

  require Logger

  alias SymphonyElixir.HttpServer
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixirWeb.Endpoint
  alias SymphonyElixirWeb.SymppDashboardApi.Runtime

  @board_path "/sympp/board"
  @default_open_delay_ms 5_000
  @open_dashboard_override_config_key :sympp_open_dashboard_override
  @operator_bootstrap_config_key :sympp_local_operator_bootstrap_token
  @operator_bootstrap_param "operator_bootstrap"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.delete(opts, :name), name: name)
  end

  @spec ensure_started(keyword()) :: :ok | {:error, :dashboard_opener_unavailable}
  def ensure_started(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case Process.whereis(name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case GenServer.start(__MODULE__, Keyword.delete(opts, :name), name: name) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, _reason} -> {:error, :dashboard_opener_unavailable}
        end
    end
  end

  @spec client_attached(GenServer.server()) :: :ok
  def client_attached(server \\ __MODULE__), do: GenServer.cast(server, :client_attached)

  @spec clients_idle(GenServer.server()) :: :ok
  def clients_idle(server \\ __MODULE__), do: GenServer.cast(server, :clients_idle)

  @spec dashboard_connected(pid(), GenServer.server()) :: :ok
  def dashboard_connected(pid \\ self(), server \\ __MODULE__),
    do: GenServer.cast(server, {:dashboard_connected, pid})

  @spec dashboard_disconnected(pid(), GenServer.server()) :: :ok
  def dashboard_disconnected(pid \\ self(), server \\ __MODULE__),
    do: GenServer.cast(server, {:dashboard_disconnected, pid})

  @doc false
  @spec open_once(keyword()) :: :ok
  def open_once(opts \\ []) do
    with true <- open_dashboard_on_boot?(opts),
         port when is_integer(port) and port > 0 <- Keyword.get(opts, :port) || HttpServer.bound_port() do
      port
      |> dashboard_url()
      |> open_url(Keyword.get(opts, :opener, &default_open_url/1))
    end

    :ok
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       activation_handled?: false,
       dashboards: %{},
       open_delay_ms: Keyword.get(opts, :open_delay_ms, @default_open_delay_ms),
       open_fun: Keyword.get(opts, :open_fun, fn -> open_once() end),
       open_id: nil,
       open_timer: nil
     }}
  end

  @impl true
  def handle_cast(:client_attached, %{activation_handled?: false, open_timer: nil} = state) do
    open_id = make_ref()
    open_timer = Process.send_after(self(), {:maybe_open, open_id}, state.open_delay_ms)
    {:noreply, %{state | open_id: open_id, open_timer: open_timer}}
  end

  def handle_cast(:client_attached, state), do: {:noreply, state}

  def handle_cast(:clients_idle, state) do
    cancel_timer(state.open_timer)
    {:noreply, %{state | activation_handled?: false, open_id: nil, open_timer: nil}}
  end

  def handle_cast({:dashboard_connected, pid}, state) do
    if Map.has_key?(state.dashboards, pid) do
      {:noreply, state}
    else
      {:noreply, %{state | dashboards: Map.put(state.dashboards, pid, Process.monitor(pid))}}
    end
  end

  def handle_cast({:dashboard_disconnected, pid}, state) do
    {:noreply, %{state | dashboards: remove_dashboard(state.dashboards, pid)}}
  end

  @impl true
  def handle_info({:maybe_open, open_id}, %{open_id: open_id} = state) do
    if map_size(state.dashboards) == 0 do
      Task.start(state.open_fun)
    end

    {:noreply, %{state | activation_handled?: true, open_id: nil, open_timer: nil}}
  end

  def handle_info({:maybe_open, _stale_open_id}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    dashboards =
      case Map.get(state.dashboards, pid) do
        ^ref -> Map.delete(state.dashboards, pid)
        _other -> state.dashboards
      end

    {:noreply, %{state | dashboards: dashboards}}
  end

  defp open_dashboard_on_boot?(opts) do
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])

    case Keyword.get(endpoint_config, @open_dashboard_override_config_key) do
      enabled when is_boolean(enabled) ->
        enabled

      _unset ->
        case System.get_env("SYMPP_OPEN_DASHBOARD") do
          value when is_binary(value) -> truthy?(value)
          _unset -> open_dashboard_from_settings?(opts)
        end
    end
  end

  defp open_dashboard_from_settings?(opts) do
    reader =
      Keyword.get(opts, :settings_reader, fn ->
        Runtime.with_dashboard_repo(&OperatorSettingsRepository.get/1)
      end)

    case reader.() do
      {:ok, settings} -> settings.open_dashboard_on_boot
      _error -> false
    end
  end

  defp dashboard_url(port) do
    origin =
      case System.get_env("SYMPP_DASHBOARD_ORIGIN") do
        value when is_binary(value) and value != "" -> String.trim_trailing(value, "/")
        _value -> "http://127.0.0.1:#{port}"
      end

    origin
    |> Kernel.<>(@board_path)
    |> maybe_put_operator_bootstrap_param()
  end

  defp maybe_put_operator_bootstrap_param(url) do
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])

    case Keyword.get(endpoint_config, @operator_bootstrap_config_key) do
      token when is_binary(token) and token != "" ->
        url
        |> URI.parse()
        |> URI.append_query(URI.encode_query([{@operator_bootstrap_param, token}]))
        |> URI.to_string()

      _token ->
        url
    end
  end

  defp open_url(url, opener) when is_function(opener, 1) do
    case opener.(url) do
      :ok -> :ok
      {:error, reason} -> Logger.info("Symphony++ dashboard browser open skipped: #{inspect(reason)}")
      _result -> :ok
    end
  end

  defp default_open_url(url) do
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

  defp remove_dashboard(dashboards, pid) do
    case Map.pop(dashboards, pid) do
      {nil, dashboards} ->
        dashboards

      {ref, dashboards} ->
        Process.demonitor(ref, [:flush])
        dashboards
    end
  end

  defp cancel_timer(timer) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_timer(_timer), do: false

  defp truthy?(value), do: value |> String.trim() |> String.downcase() |> then(&(&1 in ["1", "true", "yes", "on"]))
end
