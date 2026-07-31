defmodule SymphonyElixir.ApplicationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Repo

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)

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
