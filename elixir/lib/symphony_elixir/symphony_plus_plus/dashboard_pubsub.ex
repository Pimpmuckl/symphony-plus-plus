defmodule SymphonyElixir.SymphonyPlusPlus.DashboardPubSub do
  @moduledoc false

  @pubsub SymphonyElixir.PubSub
  @topic "sympp:operator_dashboard"
  @changed :operator_dashboard_changed
  @suppressed_key {__MODULE__, :broadcast_suppressed}
  @changed_key {__MODULE__, :broadcast_changed}

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @spec broadcast_changed() :: :ok
  def broadcast_changed do
    if Process.get(@suppressed_key) do
      Process.put(@changed_key, true)
      :ok
    else
      publish_changed()
    end
  end

  @doc false
  @spec broadcast_changed_on_success(result) :: result when result: var
  def broadcast_changed_on_success({:ok, _value} = result) do
    broadcast_changed()
    result
  end

  def broadcast_changed_on_success(result), do: result

  @doc false
  @spec coalesce_changed((-> result)) :: {result, boolean()} when result: var
  def coalesce_changed(fun) when is_function(fun, 0) do
    previous_suppressed = Process.put(@suppressed_key, true)
    previous_changed = Process.put(@changed_key, false)

    try do
      result = fun.()
      {result, Process.get(@changed_key, false)}
    after
      changed? = Process.get(@changed_key, false)
      restore_process_value(@suppressed_key, previous_suppressed)
      restore_process_value(@changed_key, previous_changed)
      relay_changed(changed?, previous_suppressed)
    end
  end

  defp relay_changed(false, _previous_suppressed), do: :ok
  defp relay_changed(true, previous_suppressed) when previous_suppressed in [false, nil], do: publish_changed()
  defp relay_changed(true, _previous_suppressed), do: Process.put(@changed_key, true)

  defp restore_process_value(key, nil), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)

  defp publish_changed do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) -> Phoenix.PubSub.broadcast(@pubsub, @topic, @changed)
      _missing -> :ok
    end
  end
end
