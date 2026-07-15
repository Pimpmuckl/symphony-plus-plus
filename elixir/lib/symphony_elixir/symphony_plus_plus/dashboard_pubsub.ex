defmodule SymphonyElixir.SymphonyPlusPlus.DashboardPubSub do
  @moduledoc false

  @pubsub SymphonyElixir.PubSub
  @topic "sympp:operator_dashboard"
  @changed :operator_dashboard_changed
  @suppressed_key {__MODULE__, :broadcast_suppressed}

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @spec broadcast_changed() :: :ok
  def broadcast_changed do
    if Process.get(@suppressed_key) do
      :ok
    else
      case Process.whereis(@pubsub) do
        pid when is_pid(pid) -> Phoenix.PubSub.broadcast(@pubsub, @topic, @changed)
        _missing -> :ok
      end
    end
  end

  @spec without_broadcast((-> result)) :: result when result: var
  def without_broadcast(fun) when is_function(fun, 0) do
    previous = Process.put(@suppressed_key, true)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(@suppressed_key), else: Process.put(@suppressed_key, previous)
    end
  end
end
