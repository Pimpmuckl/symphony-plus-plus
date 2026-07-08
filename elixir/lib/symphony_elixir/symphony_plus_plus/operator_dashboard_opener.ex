defmodule SymphonyElixir.SymphonyPlusPlus.OperatorDashboardOpener do
  @moduledoc false

  require Logger

  alias SymphonyElixir.HttpServer
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixirWeb.SymppDashboardApi.Runtime

  @board_path "/sympp/board"
  @default_attempts 500
  @default_sleep_ms 20

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [fn -> open_once(opts) end]},
      restart: :temporary
    }
  end

  @doc false
  @spec open_once(keyword()) :: :ok
  def open_once(opts \\ []) do
    with true <- open_dashboard_on_boot?(),
         port when is_integer(port) <- wait_for_port(opts) do
      port
      |> dashboard_url()
      |> open_url(Keyword.get(opts, :opener, &default_open_url/1))
    end

    :ok
  end

  defp open_dashboard_on_boot? do
    case Runtime.with_dashboard_repo(&OperatorSettingsRepository.get/1) do
      {:ok, settings} -> settings.open_dashboard_on_boot
      _error -> true
    end
  end

  defp wait_for_port(opts) do
    attempts = Keyword.get(opts, :attempts, @default_attempts)
    sleep_ms = Keyword.get(opts, :sleep_ms, @default_sleep_ms)

    Enum.reduce_while(1..attempts, nil, fn _attempt, _port ->
      case HttpServer.bound_port() do
        port when is_integer(port) and port > 0 ->
          {:halt, port}

        _port ->
          Process.sleep(sleep_ms)
          {:cont, nil}
      end
    end)
  end

  defp dashboard_url(port) do
    origin =
      case System.get_env("SYMPP_DASHBOARD_ORIGIN") do
        value when is_binary(value) and value != "" -> String.trim_trailing(value, "/")
        _value -> "http://127.0.0.1:#{port}"
      end

    origin <> @board_path
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
end
