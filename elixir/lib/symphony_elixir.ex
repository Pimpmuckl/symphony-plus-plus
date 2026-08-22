defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeCleanupQueue

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    Supervisor.start_link(
      children(),
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @doc false
  @spec children() :: [Supervisor.child_spec() | module() | {module(), keyword()}]
  def children do
    [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      SymphonyElixir.SymphonyPlusPlus.OperatorDashboardOpener
    ] ++
      legacy_daemon_children() ++
      mcp_runtime_children()
  end

  defp legacy_daemon_children do
    if artifact_runtime?() do
      []
    else
      [
        SymphonyElixir.WorkflowStore,
        SymphonyElixir.Orchestrator
      ]
    end
  end

  defp mcp_runtime_children do
    if artifact_runtime?() do
      [
        {Repo, Repo.child_options()},
        {WorktreeCleanupQueue, repo: Repo},
        SymphonyElixir.SymphonyPlusPlus.MCP.HTTPStateStore,
        SymphonyElixir.SymphonyPlusPlus.MCP.ClientLeases,
        {SymphonyElixir.HttpServer, host: "127.0.0.1"}
      ]
    else
      [
        SymphonyElixir.SymphonyPlusPlus.MCP.HTTPStateStore,
        SymphonyElixir.SymphonyPlusPlus.MCP.ClientLeases,
        SymphonyElixir.HttpServer,
        SymphonyElixir.StatusDashboard
      ]
    end
  end

  defp artifact_runtime? do
    case System.get_env("SYMPP_RUNTIME_ARTIFACT") do
      value when is_binary(value) -> (value |> String.trim() |> String.downcase()) in ["1", "true", "yes", "on"]
      _ -> false
    end
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
