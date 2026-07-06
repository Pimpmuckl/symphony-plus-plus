defmodule SymphonyElixir.SymphonyPlusPlus.DashboardPubSub do
  @moduledoc false

  @pubsub SymphonyElixir.PubSub
  @topic "sympp:operator_dashboard"
  @changed :operator_dashboard_changed

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @spec broadcast_changed() :: :ok
  def broadcast_changed do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) -> Phoenix.PubSub.broadcast(@pubsub, @topic, @changed)
      _missing -> :ok
    end
  end
end
