defmodule SymphonyElixir.ApplicationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Retention
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.RetentionThrottle
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)

  test "artifact runtime archives overdue WorkRequests without dashboard visits and reloads the cutoff" do
    database = Path.join(System.tmp_dir!(), "sympp-retention-#{System.unique_integer([:positive])}.sqlite3")
    on_exit(fn -> File.rm(database) end)

    with_env("SYMPP_RUNTIME_ARTIFACT", "1", fn ->
      children = SymphonyElixir.Application.children()
      {Repo, repo_opts} = Enum.find(children, &match?({Repo, _}, &1))
      start_supervised!({Repo, Keyword.put(repo_opts, :database, database)})
      assert :ok = WorkRequestRepository.migrate(Repo)
      assert {:ok, _settings} = OperatorSettingsRepository.update(Repo, %{"work_request_archive_after_days" => 7})

      overdue = completed_work_request!("overdue", 8)
      recent = completed_work_request!("recent", 2)
      assert {:ok, active} = WorkRequestRepository.create(Repo, work_request_attrs("active"))

      {Retention, retention_opts} = Enum.find(children, &match?({Retention, _}, &1))
      start_supervised!({Retention, Keyword.put(retention_opts, :interval_ms, 20)})

      assert %DateTime{} = wait_for_archive(overdue.id)
      assert Repo.get!(WorkRequest, recent.id).archived_at == nil
      assert Repo.get!(WorkRequest, active.id).archived_at == nil

      assert {:ok, _settings} = OperatorSettingsRepository.update(Repo, %{"work_request_archive_after_days" => 1})
      assert %DateTime{} = wait_for_archive(recent.id)
      assert Repo.get!(WorkRequest, active.id).archived_at == nil
      assert {:ok, [^active]} = WorkRequestRepository.list(Repo)
      stop_supervised!(Retention)
      RetentionThrottle.reset(Repo)
    end)
  end

  test "artifact runtime skips legacy workflow daemon children" do
    with_env("SYMPP_RUNTIME_ARTIFACT", " true ", fn ->
      children = SymphonyElixir.Application.children()
      repo_child = {Repo, Repo.child_options()}

      refute SymphonyElixir.WorkflowStore in children
      refute SymphonyElixir.Orchestrator in children
      assert repo_child in children
      assert SymphonyElixir.SymphonyPlusPlus.MCP.HTTPStateStore in children
      assert SymphonyElixir.SymphonyPlusPlus.MCP.ClientLeases in children
      assert SymphonyElixir.SymphonyPlusPlus.OperatorDashboardOpener in children
      assert {SymphonyElixir.HttpServer, host: "127.0.0.1"} in children
      refute SymphonyElixir.HttpServer in children
      refute SymphonyElixir.StatusDashboard in children

      assert Enum.find_index(children, &(&1 == repo_child)) <
               Enum.find_index(children, &(&1 == SymphonyElixir.SymphonyPlusPlus.MCP.HTTPStateStore))
    end)
  end

  test "prod artifact runtime config accepts missing workflow file" do
    logs_root = Path.join(System.tmp_dir!(), "sympp-runtime-config-#{System.unique_integer([:positive])}")

    with_envs(
      [
        {"SYMPP_RUNTIME_ARTIFACT", "1"},
        {"SYMPP_RUNTIME_ARTIFACT_ACKNOWLEDGED", "1"},
        {"SYMPP_WORKFLOW_FILE", ""},
        {"SYMPP_LOGS_ROOT", logs_root},
        {"SYMPP_BACKEND_PORT", "4157"}
      ],
      fn ->
        config = Config.Reader.read!(@runtime_config, env: :prod)
        symphony_config = Keyword.fetch!(config, :symphony_elixir)

        refute Keyword.has_key?(symphony_config, :workflow_file_path)
        assert Keyword.fetch!(symphony_config, :server_port_override) == 4157

        assert Keyword.fetch!(symphony_config, :log_file) ==
                 Path.join(Path.expand(logs_root), "log/symphony.log")
      end
    )
  end

  test "http server explicit options do not evaluate workflow-backed defaults" do
    previous_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    workflow_store_running? = is_pid(Process.whereis(SymphonyElixir.WorkflowStore))

    try do
      if workflow_store_running? do
        assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end

      missing_workflow =
        Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md")

      Application.put_env(:symphony_elixir, :workflow_file_path, missing_workflow)

      assert :ignore = SymphonyElixir.HttpServer.start_link(port: -1, host: "127.0.0.1")
    after
      if previous_workflow_path do
        Application.put_env(:symphony_elixir, :workflow_file_path, previous_workflow_path)
      else
        Application.delete_env(:symphony_elixir, :workflow_file_path)
      end

      if workflow_store_running? do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end
  end

  test "normal runtime keeps legacy workflow daemon children" do
    with_env("SYMPP_RUNTIME_ARTIFACT", nil, fn ->
      children = SymphonyElixir.Application.children()

      assert SymphonyElixir.WorkflowStore in children
      assert SymphonyElixir.Orchestrator in children
      assert SymphonyElixir.SymphonyPlusPlus.OperatorDashboardOpener in children
      refute Enum.any?(children, &match?({Repo, _opts}, &1))
    end)
  end

  defp with_env(name, value, fun) do
    with_envs([{name, value}], fun)
  end

  defp completed_work_request!(id, days_ago) do
    assert {:ok, request} = WorkRequestRepository.create(Repo, work_request_attrs(id))
    assert {:ok, completed} = WorkRequestService.force_complete(Repo, request.id)

    completed
    |> Ecto.Changeset.change(completed_at: DateTime.add(DateTime.utc_now(:microsecond), -days_ago * 86_400, :second))
    |> Repo.update!()
  end

  defp work_request_attrs(id) do
    %{
      id: id,
      title: id,
      repo: "test/retention",
      base_branch: "main",
      work_type: "hotfix",
      human_description: "Verify automatic retention.",
      desired_dispatch_shape: "single_package"
    }
  end

  defp wait_for_archive(id, attempts \\ 100) do
    case Repo.get!(WorkRequest, id).archived_at do
      nil when attempts > 0 ->
        Process.sleep(20)
        wait_for_archive(id, attempts - 1)

      archived_at ->
        archived_at
    end
  end

  defp with_envs(values, fun) do
    previous_values = Enum.map(values, fn {name, _value} -> {name, System.get_env(name)} end)

    try do
      for {name, value} <- values do
        if is_nil(value), do: System.delete_env(name), else: System.put_env(name, value)
      end

      fun.()
    after
      for {name, previous} <- previous_values do
        if is_nil(previous), do: System.delete_env(name), else: System.put_env(name, previous)
      end
    end
  end
end
