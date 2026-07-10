defmodule SymphonyElixir.SymphonyPlusPlus.MCPClientLeasesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.MCP.ClientLeases
  alias SymphonyElixir.SymphonyPlusPlus.OperatorDashboardOpener

  test "tracks clients by lease id" do
    server = start_supervised!({ClientLeases, name: :"#{__MODULE__}.tracks"})

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    assert {:ok, %{active_client_count: 1}} = ClientLeases.heartbeat("client-a", server)
    assert {:ok, %{active_client_count: 2}} = ClientLeases.attach("client-b", server)
    assert {:ok, %{active_client_count: 1}} = ClientLeases.detach("client-a", server)
    assert ClientLeases.active_count(server) == 1
  end

  test "opens the dashboard once when the first client attaches after idle" do
    parent = self()

    opener = start_opener("once", parent)

    server =
      start_lease_server("dashboard-once",
        dashboard_opener: opener,
        ttl_ms: 1_000
      )

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    assert_receive :dashboard_opened, 100

    assert {:ok, %{active_client_count: 2}} = ClientLeases.attach("client-b", server)
    refute_receive :dashboard_opened, 20

    assert {:ok, %{active_client_count: 1}} = ClientLeases.detach("client-a", server)
    assert {:ok, %{active_client_count: 0}} = ClientLeases.detach("client-b", server)
    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-c", server)
    assert_receive :dashboard_opened, 100
  end

  test "does not open when a dashboard event stream is already connected" do
    parent = self()

    opener = start_opener("connected", parent)

    server =
      start_lease_server("dashboard-connected",
        dashboard_opener: opener,
        ttl_ms: 1_000
      )

    OperatorDashboardOpener.dashboard_connected(self(), opener)
    :sys.get_state(opener)

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    refute_receive :dashboard_opened, 20
  end

  test "stale leases are pruned without runtime shutdown authority" do
    server = start_lease_server("stale-prune")

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    Process.sleep(10)
    send(server, :sweep)

    assert ClientLeases.active_count(server) == 0
  end

  test "stale leases stop runtime when shutdown-on-idle is enabled" do
    parent = self()

    server =
      start_lease_server("shutdown",
        shutdown_fun: fn -> send(parent, :shutdown_requested) end,
        shutdown_delay_ms: 1,
        shutdown_on_idle: true
      )

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    Process.sleep(10)
    send(server, :sweep)

    assert_receive :shutdown_requested, 100
  end

  test "shutdown-on-idle waits for the first lease before stopping runtime" do
    parent = self()

    server =
      start_lease_server("no-lease-yet",
        shutdown_fun: fn -> send(parent, :shutdown_requested) end,
        shutdown_delay_ms: 1,
        shutdown_on_idle: true
      )

    send(server, :sweep)
    refute_receive :shutdown_requested, 30

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    assert {:ok, %{active_client_count: 0}} = ClientLeases.detach("client-a", server)
    assert_receive :shutdown_requested, 100
  end

  test "shutdown-on-idle remains telemetry without runtime policy" do
    parent = self()

    server =
      start_lease_server("client-requested-shutdown",
        shutdown_fun: fn -> send(parent, :shutdown_requested) end,
        shutdown_delay_ms: 1
      )

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    Process.sleep(10)
    send(server, :sweep)

    refute_receive :shutdown_requested, 30
    assert ClientLeases.active_count(server) == 0
  end

  test "new client cancels pending idle shutdown" do
    parent = self()

    server =
      start_lease_server("cancel-shutdown",
        shutdown_fun: fn -> send(parent, :shutdown_requested) end,
        shutdown_delay_ms: 30,
        shutdown_on_idle: true
      )

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    assert {:ok, %{active_client_count: 0}} = ClientLeases.detach("client-a", server)
    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-b", server)

    refute_receive :shutdown_requested, 50

    assert {:ok, %{active_client_count: 0}} = ClientLeases.detach("client-b", server)
    assert_receive :shutdown_requested, 100
  end

  test "stale idle shutdown messages do not bypass the current grace period" do
    parent = self()

    server =
      start_lease_server("stale-shutdown-message",
        shutdown_fun: fn -> send(parent, :shutdown_requested) end,
        shutdown_delay_ms: 40,
        shutdown_on_idle: true
      )

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    assert {:ok, %{active_client_count: 0}} = ClientLeases.detach("client-a", server)

    send(server, {:shutdown_on_idle, make_ref()})
    refute_receive :shutdown_requested, 30
    assert_receive :shutdown_requested, 100
  end

  test "heartbeats without shutdown authority remain telemetry only" do
    server = start_lease_server("telemetry")

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    Process.sleep(10)
    send(server, :sweep)

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    Process.sleep(10)
    send(server, :sweep)

    Process.sleep(10)
    send(server, :sweep)
    assert ClientLeases.active_count(server) == 0
  end

  defp start_lease_server(name, extra_opts \\ []) do
    opts =
      [
        name: :"#{__MODULE__}.#{name}",
        ttl_ms: 5,
        sweep_ms: 60_000
      ]
      |> Keyword.merge(extra_opts)

    start_supervised!({ClientLeases, opts})
  end

  defp start_opener(name, parent) do
    opts = [
      name: :"#{__MODULE__}.opener.#{name}",
      open_delay_ms: 1,
      open_fun: fn -> send(parent, :dashboard_opened) end
    ]

    start_supervised!({OperatorDashboardOpener, opts})
  end
end
