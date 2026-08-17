defmodule SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequestProgress do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequest
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent

  @spec chronological_events([ProgressEvent.t()]) :: [ProgressEvent.t()]
  def chronological_events(events) when is_list(events) do
    Enum.sort_by(events, fn %ProgressEvent{sequence: sequence, created_at: created_at, id: id} ->
      {timestamp_sort_value(created_at), sequence || 0, id || ""}
    end)
  end

  @spec current_pr_state([ProgressEvent.t()], [String.t()]) ::
          {:ok, %{payload: map(), ref: map(), sequence: integer()}} | {:error, term()}
  def current_pr_state(events, source_tools \\ ["attach_pr"]) when is_list(source_tools) do
    events
    |> chronological_events()
    |> Enum.reverse()
    |> Enum.find_value(&pr_state_from_event(&1, source_tools))
    |> case do
      nil -> {:error, :missing_attached_pr}
      result -> result
    end
  end

  @spec expected_head_sha([ProgressEvent.t()], map()) :: String.t() | nil
  def expected_head_sha(events, ref) do
    events
    |> chronological_events()
    |> Enum.reverse()
    |> Enum.find_value(fn %ProgressEvent{payload: payload} ->
      payload
      |> stringify_keys()
      |> head_evidence_sha(ref)
    end)
  end

  @spec same_pr?(map(), map()) :: boolean()
  def same_pr?(payload, ref) do
    case PullRequest.parse(payload, nil) do
      {:ok, payload_ref} -> payload_ref.repository == ref.repository and payload_ref.number == ref.number
      {:error, _reason} -> false
    end
  end

  @spec merged?(map() | nil) :: boolean()
  def merged?(%{} = payload) do
    payload = stringify_keys(payload)

    not merged_value?(map_value(payload, "stale")) and
      (merged_value?(map_value(payload, "merged")) or
         merged_value?(map_value(payload, "state")) or
         merged_value?(map_value(payload, "status")) or
         merged_value?(map_value(payload, "conclusion")) or
         merge_state_merged?(map_value(payload, "merge_state")))
  end

  def merged?(_payload), do: false

  @spec stringify_keys(map() | term()) :: map()
  def stringify_keys(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), stringify_nested_keys(value)} end)
  def stringify_keys(_value), do: %{}

  defp pr_state_payload?(%{"type" => "pr", "source_tool" => source_tool} = payload, source_tools) do
    source_tool in source_tools or repaired_sync_pr_state_payload?(payload, source_tools)
  end

  defp pr_state_payload?(_payload, _source_tools), do: false

  defp repaired_sync_pr_state_payload?(%{"source_tool" => "sync_pr", "attachment_repair" => true}, source_tools), do: "attach_pr" in source_tools
  defp repaired_sync_pr_state_payload?(_payload, _source_tools), do: false

  defp pr_state_from_event(%ProgressEvent{} = event, source_tools) do
    payload = stringify_keys(event.payload || %{})

    if pr_state_payload?(payload, source_tools) do
      pr_state_from_payload(payload, event)
    end
  end

  defp pr_state_from_payload(payload, %ProgressEvent{} = event) do
    case PullRequest.parse(payload, nil) do
      {:ok, ref} -> {:ok, %{payload: payload, ref: ref, sequence: event.sequence || 0}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp head_evidence_sha(%{"type" => "branch", "source_tool" => "attach_branch"} = payload, _ref), do: clean_string(payload["head_sha"])

  defp head_evidence_sha(%{"type" => "pr", "source_tool" => "attach_pr"} = payload, ref) do
    if same_pr?(payload, ref), do: clean_string(payload["head_sha"])
  end

  defp head_evidence_sha(_payload, _ref), do: nil

  defp merge_state_merged?(%{} = merge_state) do
    merged_value?(map_value(merge_state, "merged")) or
      merged_value?(map_value(merge_state, "state")) or
      merged_value?(map_value(merge_state, "status")) or
      merged_value?(map_value(merge_state, "mergeable_state"))
  end

  defp merge_state_merged?(_merge_state), do: false

  defp merged_value?(true), do: true

  defp merged_value?(value) when is_binary(value) do
    value |> String.trim() |> String.downcase() |> then(&(&1 in ["merged", "true"]))
  end

  defp merged_value?(_value), do: false

  defp stringify_nested_keys(%{} = map), do: stringify_keys(map)
  defp stringify_nested_keys(value), do: value

  defp map_value(%{} = map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp timestamp_sort_value(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp timestamp_sort_value(_value), do: 0
end
