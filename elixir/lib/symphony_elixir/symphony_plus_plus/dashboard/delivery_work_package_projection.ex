defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.DeliveryWorkPackageProjection do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.Sanitizer

  @package_activity_fields [
    :has_started,
    :has_active_worker,
    :last_activity_at,
    :is_stale,
    :latest_progress_at,
    :latest_review_at,
    :latest_pr_at,
    :latest_merge_at
  ]

  @spec work_packages_by_id(term()) :: map()
  def work_packages_by_id(nil), do: %{}

  def work_packages_by_id(%{} = delivery_board) do
    delivery_board
    |> map_value("work_packages")
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = work_package ->
        case map_value(work_package, "id") do
          id when is_binary(id) and id != "" -> [{id, work_package}]
          _id -> []
        end

      _work_package ->
        []
    end)
    |> Map.new()
  end

  def work_packages_by_id(_delivery_board), do: %{}

  @spec primary_operational_state(term(), keyword()) :: map() | nil
  def primary_operational_state(%{} = work_package, opts) do
    operational_state = map_value(work_package, "operational_state")

    if primary_state?(work_package, operational_state) do
      operational_state_payload(operational_state, opts)
    end
  end

  def primary_operational_state(_work_package, _opts), do: nil

  @spec put_delivery_work_package(map(), term(), keyword()) :: map()
  def put_delivery_work_package(payload, nil, _opts), do: payload

  def put_delivery_work_package(payload, %{} = work_package, opts) do
    payload = Map.put(payload, :attention_reason_codes, map_value(work_package, "attention_reason_codes") || [])

    if Keyword.get(opts, :include_delivery_data?, true) do
      payload
      |> Map.put(:delivery, Sanitizer.redacted_json(map_value(work_package, "delivery")))
      |> Map.put(:successor, Sanitizer.redacted_json(map_value(work_package, "successor")))
    else
      payload
    end
  end

  @spec put_delivery_operational_state(map(), term()) :: map()
  def put_delivery_operational_state(payload, work_package) do
    case primary_operational_state(work_package, include_package_fields?: false) do
      nil -> payload
      operational_state -> Map.put(payload, :operational_state, operational_state)
    end
  end

  @spec redact_reasons(map(), keyword()) :: map()
  def redact_reasons(payload, opts) do
    if Keyword.get(opts, :include_package_fields?, true) do
      payload
    else
      attention_items = Enum.map(payload.attention_items, &Map.delete(&1, :reason))

      payload
      |> Map.delete(:reason)
      |> Map.drop(@package_activity_fields)
      |> Map.put(:attention_items, attention_items)
    end
  end

  defp primary_state?(%{} = work_package, %{} = operational_state) do
    delivery_outcome = map_value(work_package, "delivery_outcome") || map_value(operational_state, "delivery_outcome")
    key = map_value(operational_state, "key")
    attention_reason_codes = map_value(operational_state, "attention_reason_codes") || []

    is_binary(delivery_outcome) or
      (key == "needs_closeout" and "pr_merged_without_delivery_outcome" in attention_reason_codes) or
      terminal_without_delivery_state?(key, attention_reason_codes)
  end

  defp primary_state?(_work_package, _operational_state), do: false

  defp terminal_without_delivery_state?(key, attention_reason_codes) do
    "terminal_package_without_delivery_outcome" in attention_reason_codes and key in ["needs_closeout", "merged", "closed", "abandoned"]
  end

  defp operational_state_payload(%{} = operational_state, opts) do
    %{
      key: map_value(operational_state, "key"),
      label: map_value(operational_state, "label"),
      tone: map_value(operational_state, "tone"),
      reason: map_value(operational_state, "reason"),
      raw_status: map_value(operational_state, "raw_status"),
      delivery_outcome: map_value(operational_state, "delivery_outcome"),
      attention_reason_codes: map_value(operational_state, "attention_reason_codes") || [],
      attention_items:
        operational_state
        |> map_value("attention_items")
        |> List.wrap()
        |> Enum.flat_map(&attention_item_payload(&1, opts))
    }
    |> Map.merge(activity_fields(operational_state))
    |> maybe_put_work_package_status(operational_state, opts)
    |> redact_reasons(opts)
  end

  defp activity_fields(%{} = operational_state) do
    @package_activity_fields
    |> Enum.flat_map(fn field ->
      value = map_value(operational_state, Atom.to_string(field))
      if is_nil(value), do: [], else: [{field, value}]
    end)
    |> Map.new()
  end

  defp maybe_put_work_package_status(payload, operational_state, opts) do
    if Keyword.get(opts, :include_package_fields?, true) do
      Map.put(payload, :work_package_status, map_value(operational_state, "work_package_status"))
    else
      payload
    end
  end

  defp attention_item_payload(%{} = item, opts) do
    payload = %{
      key: map_value(item, "key"),
      label: map_value(item, "label"),
      tone: map_value(item, "tone")
    }

    payload =
      if Keyword.get(opts, :include_package_fields?, true) do
        Map.put(payload, :reason, map_value(item, "reason"))
      else
        payload
      end

    [payload]
  end

  defp attention_item_payload(_item, _opts), do: []

  defp map_value(%{} = map, key) when is_binary(key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
