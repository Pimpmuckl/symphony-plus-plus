defmodule Mix.Tasks.Sympp.CockpitTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Sympp.Cockpit, as: CockpitTask
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.Endpoint

  setup do
    Mix.Task.reenable("sympp.cockpit")
    previous_shell = Mix.shell()
    previous_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    previous_endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])
    previous_dashboard_origin = System.get_env("SYMPP_DASHBOARD_ORIGIN")
    previous_open_dashboard = System.get_env("SYMPP_OPEN_DASHBOARD")
    previous_defer_dashboard_open = System.get_env("SYMPP_DEFER_DASHBOARD_OPEN")

    Mix.shell(Mix.Shell.Process)
    System.delete_env("SYMPP_DASHBOARD_ORIGIN")
    System.delete_env("SYMPP_OPEN_DASHBOARD")
    System.delete_env("SYMPP_DEFER_DASHBOARD_OPEN")
    ensure_cockpit_dashboard_asset!()

    on_exit(fn ->
      Mix.shell(previous_shell)
      restore_env(:sympp_repo_database, previous_database)
      Application.put_env(:symphony_elixir, Endpoint, previous_endpoint_config)
      restore_system_env("SYMPP_DASHBOARD_ORIGIN", previous_dashboard_origin)
      restore_system_env("SYMPP_OPEN_DASHBOARD", previous_open_dashboard)
      restore_system_env("SYMPP_DEFER_DASHBOARD_OPEN", previous_defer_dashboard_open)
      stop_endpoint()
    end)

    :ok
  end

  test "prints help" do
    CockpitTask.run(["--help"])
    assert_received {:mix_shell, :info, [message]}
    assert message =~ "mix sympp.cockpit"
    assert message =~ "--database <sqlite-path>"
  end

  test "parses safe defaults and explicit options" do
    relative_database = Path.join("tmp", "sympp-cockpit-#{System.unique_integer([:positive])}.sqlite3")

    try do
      assert {:ok, default_opts} = CockpitTask.parse_args_for_test([])
      assert Keyword.fetch!(default_opts, :host) == "127.0.0.1"
      assert Keyword.fetch!(default_opts, :port) == 19_998
      refute Keyword.has_key?(default_opts, :open_dashboard)
      refute Keyword.has_key?(default_opts, :dashboard_origin)
      assert CockpitTask.cockpit_url_for_test(default_opts, 19_998) == "http://127.0.0.1:19998/sympp/board"

      assert {:ok, opts} =
               CockpitTask.parse_args_for_test([
                 "--database",
                 relative_database,
                 "--host",
                 "localhost",
                 "--port",
                 "0",
                 "--dashboard-origin",
                 "http://127.0.0.1:5174"
               ])

      assert Keyword.fetch!(opts, :host) == "localhost"
      assert Keyword.fetch!(opts, :port) == 0
      assert Keyword.fetch!(opts, :dashboard_origin) == "http://127.0.0.1:5174"
      assert Repo.same_database_path?(Keyword.fetch!(opts, :database), Path.expand(relative_database))

      token_opts = Keyword.put(opts, :operator_bootstrap_token, "test-bootstrap-token")
      endpoint_config = CockpitTask.endpoint_config_for_test(token_opts)
      assert endpoint_config[:sympp_local_operator] == true
      assert endpoint_config[:sympp_local_operator_bootstrap_token] == "test-bootstrap-token"
      assert endpoint_config[:sympp_repo] == Repo
      assert endpoint_config[:server] == false
      assert endpoint_config[:sympp_dashboard_origin] == "http://127.0.0.1:5174"

      assert CockpitTask.endpoint_config_for_test(open_dashboard: false)[:sympp_open_dashboard_override] == false
      assert CockpitTask.endpoint_config_for_test(open_dashboard: true)[:sympp_open_dashboard_override] == true

      assert CockpitTask.cockpit_url_for_test(token_opts, 4567) ==
               "http://127.0.0.1:5174/sympp/board?operator_bootstrap=test-bootstrap-token"

      assert {:ok, ipv6_opts} = CockpitTask.parse_args_for_test(["--host", "[::1]"])
      assert CockpitTask.cockpit_url_for_test(ipv6_opts, 4567) == "http://[::1]:4567/sympp/board"
    after
      File.rm(Path.expand(relative_database))
    end
  end

  test "preserves configured custom repo unless database is explicit" do
    custom_repo = Module.concat(__MODULE__, CustomRepo)
    original_config = [sympp_repo: custom_repo, other: :kept]

    no_database_config = CockpitTask.endpoint_config_for_test(endpoint_config: original_config)

    assert no_database_config[:sympp_local_operator] == true
    assert no_database_config[:sympp_repo] == custom_repo
    assert no_database_config[:other] == :kept
    refute Keyword.has_key?(no_database_config, :sympp_dashboard_origin)

    database_config = CockpitTask.endpoint_config_for_test(endpoint_config: original_config, database: ":memory:")

    assert database_config[:sympp_local_operator] == true
    assert database_config[:sympp_repo] == Repo
    assert database_config[:other] == :kept
  end

  test "rejects blank options, non-loopback hosts, and invalid ports" do
    assert {:error, usage} = CockpitTask.parse_args_for_test(["--database", " "])
    assert usage =~ "mix sympp.cockpit"

    assert {:error, host_error} = CockpitTask.parse_args_for_test(["--host", "0.0.0.0"])
    assert host_error =~ "host must be loopback"

    assert {:error, dashboard_origin_usage} = CockpitTask.parse_args_for_test(["--dashboard-origin", " "])
    assert dashboard_origin_usage =~ "mix sympp.cockpit"

    assert {:error, remote_dashboard_origin_error} = CockpitTask.parse_args_for_test(["--dashboard-origin", "http://example.com:5174"])
    assert remote_dashboard_origin_error =~ "dashboard origin must be a loopback http origin"

    assert {:ok, spp_dashboard_origin_opts} = CockpitTask.parse_args_for_test(["--dashboard-origin", "http://spp.localhost:5174"])
    assert Keyword.fetch!(spp_dashboard_origin_opts, :dashboard_origin) == "http://spp.localhost:5174"

    assert {:error, port_error} = CockpitTask.parse_args_for_test(["--port", "65536"])
    assert port_error =~ "port must be an integer"
  end

  test "validates dashboard origin from environment fallback" do
    System.put_env("SYMPP_DASHBOARD_ORIGIN", "http://example.com:5174")

    assert {:error, remote_dashboard_origin_error} = CockpitTask.parse_args_for_test([])
    assert remote_dashboard_origin_error =~ "dashboard origin must be a loopback http origin"

    System.put_env("SYMPP_DASHBOARD_ORIGIN", "http://spp.localhost:5174")

    assert {:ok, opts} = CockpitTask.parse_args_for_test([])
    assert Keyword.fetch!(opts, :dashboard_origin) == "http://spp.localhost:5174"
  end

  test "parses dashboard browser opener opt-in from flag and environment" do
    assert {:ok, flag_opts} = CockpitTask.parse_args_for_test(["--open-dashboard"])
    assert Keyword.fetch!(flag_opts, :open_dashboard) == true

    System.put_env("SYMPP_OPEN_DASHBOARD", "1")

    assert {:ok, env_opts} = CockpitTask.parse_args_for_test([])
    assert Keyword.fetch!(env_opts, :open_dashboard) == true

    System.put_env("SYMPP_OPEN_DASHBOARD", "false")

    assert {:ok, disabled_env_opts} = CockpitTask.parse_args_for_test([])
    assert Keyword.fetch!(disabled_env_opts, :open_dashboard) == false
  end

  test "starts a local operator cockpit, prints bridge URLs, and serves an empty ledger API" do
    database_path = WorkPackageFactory.database_path()

    try do
      assert {:ok, opts} = CockpitTask.parse_args_for_test(["--database", database_path, "--port", "0"])

      opts =
        Keyword.put(opts, :operator_dashboard_opener, fn url ->
          send(self(), {:operator_dashboard_opened, url})
          :ok
        end)

      CockpitTask.run_cockpit_for_test(opts, fn ->
        port = wait_for_bound_port()

        response =
          Req.get!(operator_shell_url(port),
            headers: browser_navigation_headers(),
            redirect: false
          )

        direct_api_response =
          Req.get!("http://127.0.0.1:#{port}/api/v1/sympp/operator/dashboard",
            headers: browser_api_headers()
          )

        api_response =
          Req.get!("http://127.0.0.1:#{port}/api/v1/sympp/operator/dashboard",
            headers: browser_api_headers(local_operator_session_cookie(response))
          )

        send(
          self(),
          {:cockpit_response, response.status, response.headers["location"], direct_api_response.status, api_response.status, api_response.body}
        )
      end)

      assert_received {:mix_shell, :info, [url]}
      assert url =~ ~r{Symphony\+\+ local operator dashboard: http://127\.0\.0\.1:\d+/sympp/board\?operator_bootstrap=\[REDACTED\]}
      assert_received {:operator_dashboard_opened, opened_url}
      assert opened_url =~ ~r{http://127\.0\.0\.1:\d+/sympp/board\?operator_bootstrap=[^&]+}
      assert_received {:mix_shell, :info, [bridge]}
      assert bridge =~ ~r{Symphony\+\+ API bridge: http://127\.0\.0\.1:\d+}
      assert_received {:mix_shell, :info, ["Bootstrap URL browser open attempted; token redacted from logs."]}
      assert_received {:mix_shell, :info, ["Press Ctrl+C to stop."]}
      assert_received {:cockpit_response, 200, nil, 401, 200, payload}
      assert payload["board"]["total_count"] == 0
      assert File.exists?(database_path)
    after
      File.rm(database_path)
    end
  end

  test "runs WorkRequest retention before serving the local operator cockpit" do
    database_path = WorkPackageFactory.database_path()
    original_dynamic_repo = Repo.get_dynamic_repo()

    try do
      pid = start_supervised!({Repo, database: database_path, name: Repo.process_name(database_path), pool_size: 1})
      Repo.put_dynamic_repo(pid)
      assert :ok = WorkRequestRepository.migrate(Repo)
      request = completed_skipped_request!(~U[2026-05-01 00:00:00Z])

      assert {:ok, opts} =
               CockpitTask.parse_args_for_test([
                 "--database",
                 database_path,
                 "--port",
                 "0",
                 "--dashboard-origin",
                 "http://127.0.0.1:5174",
                 "--no-open-dashboard"
               ])

      opts =
        Keyword.put(opts, :operator_dashboard_opener, fn url ->
          send(self(), {:operator_dashboard_opened, url})
          :ok
        end)

      CockpitTask.run_cockpit_for_test(opts, fn ->
        port = wait_for_bound_port()

        config_response =
          Req.get!(operator_config_url(port),
            headers: configured_dashboard_api_headers(nil, "http://127.0.0.1:5174")
          )

        api_response =
          Req.get!("http://127.0.0.1:#{port}/api/v1/sympp/operator/dashboard",
            headers: configured_dashboard_api_headers(local_operator_session_cookie(config_response), "http://127.0.0.1:5174")
          )

        send(self(), {:retention_payload, config_response.status, api_response.status, api_response.body})
      end)

      refute_received {:operator_dashboard_opened, _url}
      assert_received {:retention_payload, 200, 200, payload}
      assert payload["work_requests"]["work_requests"] == []

      assert %WorkRequest{archived_at: %DateTime{}} = Repo.get!(WorkRequest, request.id)
      assert [_slice] = Repo.all(PlannedSlice)
    after
      Repo.put_dynamic_repo(original_dynamic_repo)
      File.rm(database_path)
    end
  end

  test "opens dashboard bootstrap URLs when explicitly requested" do
    database_path = WorkPackageFactory.database_path()

    try do
      assert {:ok, opts} =
               CockpitTask.parse_args_for_test([
                 "--database",
                 database_path,
                 "--port",
                 "0",
                 "--dashboard-origin",
                 "http://127.0.0.1:5174",
                 "--open-dashboard"
               ])

      opts =
        Keyword.put(opts, :operator_dashboard_opener, fn url ->
          send(self(), {:operator_dashboard_opened, url})
          :ok
        end)

      CockpitTask.run_cockpit_for_test(opts, fn -> :ok end)

      assert_received {:operator_dashboard_opened, bootstrap_url}
      assert bootstrap_url =~ ~r{http://127\.0\.0\.1:5174/api/v1/sympp/operator/config\?operator_bootstrap=[^&]+}
      assert_received {:operator_dashboard_opened, dashboard_url}
      assert dashboard_url =~ ~r{http://127\.0\.0\.1:5174/sympp/board\?operator_bootstrap=[^&]+}
      assert_received {:mix_shell, :info, ["Bootstrap URL browser open attempted; token redacted from logs."]}
    after
      File.rm(database_path)
    end
  end

  test "managed backend defers the immediate dashboard open" do
    database_path = WorkPackageFactory.database_path()
    System.put_env("SYMPP_DEFER_DASHBOARD_OPEN", "1")

    try do
      assert {:ok, opts} = CockpitTask.parse_args_for_test(["--database", database_path, "--port", "0", "--open-dashboard"])

      opts =
        Keyword.put(opts, :operator_dashboard_opener, fn url ->
          send(self(), {:operator_dashboard_opened, url})
          :ok
        end)

      CockpitTask.run_cockpit_for_test(opts, fn -> :ok end)

      refute_received {:operator_dashboard_opened, _url}
      assert_received {:mix_shell, :info, ["Dashboard browser open deferred until an MCP client connects."]}
    after
      File.rm(database_path)
    end
  end

  test "uses operator settings to suppress dashboard browser opening" do
    database_path = WorkPackageFactory.database_path()
    original_dynamic_repo = Repo.get_dynamic_repo()

    try do
      pid = start_supervised!({Repo, database: database_path, name: Repo.process_name(database_path), pool_size: 1})
      Repo.put_dynamic_repo(pid)
      assert :ok = WorkRequestRepository.migrate(Repo)
      assert {:ok, _settings} = SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository.update(Repo, %{"open_dashboard_on_boot" => false})

      assert {:ok, opts} = CockpitTask.parse_args_for_test(["--database", database_path, "--port", "0"])

      opts =
        Keyword.put(opts, :operator_dashboard_opener, fn url ->
          send(self(), {:operator_dashboard_opened, url})
          :ok
        end)

      CockpitTask.run_cockpit_for_test(opts, fn -> :ok end)

      refute_received {:operator_dashboard_opened, _url}
      assert_received {:mix_shell, :info, ["Dashboard browser auto-open disabled; pass --open-dashboard or set SYMPP_OPEN_DASHBOARD=1 to open it."]}
    after
      Repo.put_dynamic_repo(original_dynamic_repo)
      File.rm(database_path)
    end
  end

  test "reports an actionable error when WorkRequest retention cannot use the ledger" do
    database_path =
      System.tmp_dir!()
      |> Path.join("sympp-cockpit-missing-#{System.unique_integer([:positive])}")
      |> Path.join("ledger.sqlite3")

    assert {:ok, opts} =
             CockpitTask.parse_args_for_test([
               "--database",
               database_path,
               "--port",
               "0",
               "--dashboard-origin",
               "http://127.0.0.1:5174"
             ])

    try do
      File.mkdir_p!(database_path)

      assert_raise Mix.Error, ~r/Symphony\+\+ cockpit WorkRequest ledger (open|migration) failed:/, fn ->
        CockpitTask.run_cockpit_for_test(opts, fn ->
          assert is_integer(wait_for_bound_port())
        end)
      end
    after
      File.rm_rf(database_path)
    end
  end

  test "reports an actionable error when the configured port is already occupied" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    database_path = WorkPackageFactory.database_path()

    try do
      assert {:ok, opts} = CockpitTask.parse_args_for_test(["--database", database_path, "--port", Integer.to_string(port)])

      assert_raise Mix.Error, ~r/could not bind http:\/\/127\.0\.0\.1:#{port}/, fn ->
        CockpitTask.run_cockpit_for_test(opts, fn -> :ok end)
      end
    after
      :gen_tcp.close(socket)
      File.rm(database_path)
    end
  end

  test "cleans up the owned endpoint so the cockpit can restart in the same runtime" do
    database_path = WorkPackageFactory.database_path()

    try do
      assert {:ok, opts} = CockpitTask.parse_args_for_test(["--database", database_path, "--port", "0"])

      CockpitTask.run_cockpit_for_test(opts, fn ->
        assert is_integer(wait_for_bound_port())
      end)

      CockpitTask.run_cockpit_for_test(opts, fn ->
        assert is_integer(wait_for_bound_port())
      end)
    after
      File.rm(database_path)
    end
  end

  defp wait_for_bound_port do
    Enum.reduce_while(1..500, nil, fn _attempt, _port ->
      case SymphonyElixir.HttpServer.bound_port() do
        port when is_integer(port) and port > 0 ->
          {:halt, port}

        _port ->
          Process.sleep(20)
          {:cont, nil}
      end
    end)
  end

  defp operator_shell_url(port) do
    "http://127.0.0.1:#{port}/sympp/board?operator_bootstrap=#{URI.encode_www_form(operator_bootstrap_token())}"
  end

  defp operator_config_url(port) do
    "http://127.0.0.1:#{port}/api/v1/sympp/operator/config?operator_bootstrap=#{URI.encode_www_form(operator_bootstrap_token())}"
  end

  defp operator_bootstrap_token do
    token =
      :symphony_elixir
      |> Application.get_env(Endpoint, [])
      |> Keyword.fetch!(:sympp_local_operator_bootstrap_token)

    token
  end

  defp browser_navigation_headers do
    [{"sec-fetch-site", "none"}, {"sec-fetch-mode", "navigate"}]
  end

  defp browser_api_headers(cookie_header \\ nil) do
    [
      {"sec-fetch-site", "same-origin"},
      {"sec-fetch-mode", "cors"},
      {"sec-fetch-dest", "empty"}
    ]
    |> maybe_put_cookie_header(cookie_header)
  end

  defp configured_dashboard_api_headers(cookie_header, origin) do
    [
      {"origin", origin},
      {"sec-fetch-site", "same-site"},
      {"sec-fetch-mode", "cors"},
      {"sec-fetch-dest", "empty"}
    ]
    |> maybe_put_cookie_header(cookie_header)
  end

  defp maybe_put_cookie_header(headers, cookie_header) when is_binary(cookie_header) and cookie_header != "" do
    [{"cookie", cookie_header} | headers]
  end

  defp maybe_put_cookie_header(headers, _cookie_header), do: headers

  defp local_operator_session_cookie(response) do
    response.headers
    |> Map.get("set-cookie", [])
    |> List.wrap()
    |> Enum.map_join("; ", &(&1 |> String.split(";", parts: 2) |> hd()))
  end

  defp ensure_cockpit_dashboard_asset! do
    index_path =
      :symphony_elixir
      |> :code.priv_dir()
      |> Path.join("static/index.html")

    File.mkdir_p!(Path.dirname(index_path))
    File.write!(index_path, "<!doctype html><html><head></head><body><div id=\"root\"></div></body></html>")
  end

  defp completed_skipped_request!(completed_at) do
    assert {:ok, request} =
             WorkRequestRepository.create(Repo, %{
               title: "Finished request",
               repo: "symphony-plus-plus",
               base_branch: "main",
               work_type: "feature",
               human_description: "Already done.",
               constraints: %{},
               desired_dispatch_shape: "single_package",
               status: "ready_for_slicing"
             })

    assert {:ok, slice} =
             WorkRequestRepository.add_planned_slice(Repo, request.id, %{
               title: "Done slice",
               goal: "Finish the request.",
               work_package_kind: "mcp",
               target_base_branch: "main",
               owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
               forbidden_file_globs: [],
               acceptance_criteria: ["Done."],
               validation_steps: ["mix test"],
               review_lanes: ["normal"],
               stop_conditions: []
             })

    assert {:ok, _skipped} = WorkRequestRepository.skip_planned_slice(Repo, request.id, slice.id, "planned")

    assert {:ok, _delivery} =
             WorkRequestRepository.record_planned_slice_delivery(Repo, request.id, slice.id, %{
               outcome: "abandoned",
               idempotency_key: "cockpit-retention-skipped-delivery",
               recorded_by: "cockpit-test",
               abandoned_rationale: "Skipped retention fixture has a terminal delivery record."
             })

    request
    |> Ecto.Changeset.change(completed_at: utc_usec(completed_at))
    |> Repo.update!()
  end

  defp utc_usec(%DateTime{} = datetime), do: %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp stop_endpoint do
    case Process.whereis(Endpoint) do
      pid when is_pid(pid) -> GenServer.stop(pid)
      nil -> :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
