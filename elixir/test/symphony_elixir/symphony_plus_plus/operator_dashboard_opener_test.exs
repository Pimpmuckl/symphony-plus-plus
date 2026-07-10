defmodule SymphonyElixir.SymphonyPlusPlus.OperatorDashboardOpenerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.OperatorDashboardOpener
  alias SymphonyElixirWeb.Endpoint

  setup do
    previous = System.get_env("SYMPP_OPEN_DASHBOARD")
    previous_dashboard_origin = System.get_env("SYMPP_DASHBOARD_ORIGIN")
    previous_endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])

    System.delete_env("SYMPP_DASHBOARD_ORIGIN")
    Application.put_env(:symphony_elixir, Endpoint, Keyword.delete(previous_endpoint_config, :sympp_local_operator_bootstrap_token))

    on_exit(fn ->
      if is_nil(previous),
        do: System.delete_env("SYMPP_OPEN_DASHBOARD"),
        else: System.put_env("SYMPP_OPEN_DASHBOARD", previous)

      if is_nil(previous_dashboard_origin),
        do: System.delete_env("SYMPP_DASHBOARD_ORIGIN"),
        else: System.put_env("SYMPP_DASHBOARD_ORIGIN", previous_dashboard_origin)

      Application.put_env(:symphony_elixir, Endpoint, previous_endpoint_config)
    end)
  end

  test "explicit disable wins without reading settings" do
    System.put_env("SYMPP_OPEN_DASHBOARD", "0")

    assert :ok =
             OperatorDashboardOpener.open_once(
               port: 54_321,
               settings_reader: fn -> flunk("settings should not be read") end,
               opener: fn _url -> flunk("browser should not open") end
             )
  end

  test "cockpit disable wins over environment and settings" do
    System.put_env("SYMPP_OPEN_DASHBOARD", "1")
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])
    Application.put_env(:symphony_elixir, Endpoint, Keyword.put(endpoint_config, :sympp_open_dashboard_override, false))

    assert :ok =
             OperatorDashboardOpener.open_once(
               port: 54_321,
               settings_reader: fn -> flunk("settings should not be read") end,
               opener: fn _url -> flunk("browser should not open") end
             )
  end

  test "settings read failures fail closed" do
    System.delete_env("SYMPP_OPEN_DASHBOARD")

    assert :ok =
             OperatorDashboardOpener.open_once(
               port: 54_321,
               settings_reader: fn -> {:error, :database_busy} end,
               opener: fn _url -> flunk("browser should not open") end
             )
  end

  test "enabled settings open the current dashboard URL" do
    System.delete_env("SYMPP_OPEN_DASHBOARD")
    parent = self()

    assert :ok =
             OperatorDashboardOpener.open_once(
               port: 54_321,
               settings_reader: fn -> {:ok, %{open_dashboard_on_boot: true}} end,
               opener: fn url -> send(parent, {:opened, url}) end
             )

    assert_receive {:opened, "http://127.0.0.1:54321/sympp/board"}
  end

  test "enabled settings preserve the cockpit bootstrap token" do
    System.delete_env("SYMPP_OPEN_DASHBOARD")
    parent = self()

    endpoint_config =
      Application.get_env(:symphony_elixir, Endpoint, [])
      |> Keyword.put(:sympp_dashboard_origin, "http://127.0.0.1:5174")
      |> Keyword.put(:sympp_local_operator_bootstrap_token, "test-bootstrap-token")

    Application.put_env(:symphony_elixir, Endpoint, endpoint_config)

    assert :ok =
             OperatorDashboardOpener.open_once(
               port: 54_321,
               settings_reader: fn -> {:ok, %{open_dashboard_on_boot: true}} end,
               opener: fn url -> send(parent, {:opened, url}) end
             )

    assert_receive {:opened, "http://127.0.0.1:5174/sympp/board?operator_bootstrap=test-bootstrap-token"}
  end

  test "direct runtimes start one shared opener" do
    name = :"#{__MODULE__}.direct"
    on_exit(fn -> if pid = Process.whereis(name), do: GenServer.stop(pid) end)

    assert :ok = OperatorDashboardOpener.ensure_started(name: name)
    pid = Process.whereis(name)
    assert is_pid(pid)

    assert :ok = OperatorDashboardOpener.ensure_started(name: name)
    assert Process.whereis(name) == pid
  end
end
