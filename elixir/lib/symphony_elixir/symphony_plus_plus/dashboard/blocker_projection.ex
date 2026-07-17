defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.{MetadataProjection, Sanitizer}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent

  @spec blockers([ProgressEvent.t()]) :: [map()]
  def blockers(progress_events) do
    progress_events
    |> Enum.filter(&blocker_event?/1)
    |> MetadataProjection.chronological_progress_events()
    |> Enum.reduce(%{}, fn event, blockers ->
      payload = event.payload || %{}
      blocker_id = normalize_blocker_id(Map.get(payload, "blocker_id") || event.idempotency_key || event.id)

      Map.put(blockers, blocker_id, %{
        id: blocker_id,
        active: Map.get(payload, "active") == true,
        summary: Sanitizer.redacted_text(event.summary),
        body: Sanitizer.redacted_text(event.body),
        status: event.status,
        source_tool: Map.get(payload, "source_tool"),
        resolution: Map.get(payload, "resolution"),
        blocked_by: blocker_endpoint(Map.get(payload, "blocked_by")),
        blocked_item: blocker_endpoint(Map.get(payload, "blocked_item")),
        actor: actor(event),
        event_id: event.id,
        updated_at: Sanitizer.timestamp(event.created_at)
      })
    end)
    |> Map.values()
    |> Enum.sort_by(&{not &1.active, &1.updated_at || "", &1.id || ""})
  end

  @spec blocker_event?(ProgressEvent.t()) :: boolean()
  def blocker_event?(%ProgressEvent{payload: payload}) when is_map(payload) do
    Map.get(payload, "type") == "blocker" and Map.get(payload, "source_tool") in ["report_blocker", "resolve_blocker"]
  end

  def blocker_event?(%ProgressEvent{}), do: false

  defp blocker_endpoint(%{} = value) do
    kind = value |> Map.get("kind", Map.get(value, :kind)) |> normalize_blocker_endpoint_kind()
    id = value |> Map.get("id", Map.get(value, :id)) |> normalize_blocker_endpoint_id()

    if kind && id do
      %{kind: kind, id: id}
    end
  end

  defp blocker_endpoint(_value), do: nil

  defp normalize_blocker_endpoint_kind(value) when is_binary(value) do
    case String.trim(value) do
      "work_package" -> "work_package"
      _other -> nil
    end
  end

  defp normalize_blocker_endpoint_kind(_value), do: nil

  defp normalize_blocker_endpoint_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      id -> id
    end
  end

  defp normalize_blocker_endpoint_id(_value), do: nil

  @spec actor(ProgressEvent.t()) :: map()
  def actor(%ProgressEvent{} = event) do
    %{
      id: event.actor_id,
      type: event.actor_type,
      access_grant_id: event.access_grant_id
    }
  end

  defp normalize_blocker_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_blocker_id(value), do: to_string(value)
end
