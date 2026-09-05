defmodule SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Retention do
  @moduledoc false

  use GenServer

  require Logger

  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.{Repository, RetentionThrottle, Settings}
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service, as: SoloSessionService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService

  @interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{repo: Keyword.fetch!(opts, :repo), interval_ms: Keyword.get(opts, :interval_ms, @interval_ms)}
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:retention, state) do
    with {:ok, settings} <- Repository.get(state.repo),
         :ok <- run(state.repo, settings) do
      :ok
    else
      {:error, reason} -> Logger.warning("Symphony++ retention skipped: #{inspect(reason)}")
    end

    schedule(state)
    {:noreply, state}
  end

  @spec run(module(), Settings.t(), keyword()) :: :ok | {:error, term()}
  def run(repo, %Settings{} = settings, opts \\ []) do
    RetentionThrottle.run(repo, settings, &run_pass(repo, settings, &1), opts)
  end

  defp run_pass(repo, settings, now) do
    with {:ok, _work_request_summary} <-
           WorkRequestService.retention_pass(repo,
             archive_after_days: settings.work_request_archive_after_days,
             delete_after_days: settings.solo_session_delete_after_days
           ),
         {:ok, _solo_summary} <- SoloSessionService.retention_pass(repo, now) do
      :ok
    end
  end

  defp schedule(state), do: Process.send_after(self(), :retention, state.interval_ms)
end
