defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.MetadataProjection do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.Sanitizer
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequest
  alias SymphonyElixir.SymphonyPlusPlus.OperationalLineage
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @spec filled_string?(term()) :: boolean()
  def filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  @spec latest_current_head_sha([ProgressEvent.t()]) :: String.t() | nil
  def latest_current_head_sha(progress_events) do
    progress_events
    |> Enum.filter(&payload_type?(&1, "branch", "attach_branch"))
    |> Enum.reverse()
    |> Enum.find_value(fn
      %ProgressEvent{payload: payload} -> payload_head_sha(payload)
      _event -> nil
    end)
  end

  @spec metadata_present?([ProgressEvent.t()], String.t(), String.t()) :: boolean()
  def metadata_present?(progress_events, "pr", head_sha) when is_binary(head_sha) do
    case latest_attached_pr_ref(progress_events) do
      {:ok, attached_ref} ->
        Enum.any?(progress_events, fn
          %ProgressEvent{payload: payload} = event when is_map(payload) ->
            payload_type?(event, "pr", ["attach_pr", "sync_pr"]) and head_sha_matches?(Map.get(payload, "head_sha"), head_sha) and
              pr_payload_ref(payload) == attached_ref

          %ProgressEvent{} ->
            false
        end)

      {:error, :not_found} ->
        false
    end
  end

  def metadata_present?(progress_events, type, head_sha) when is_binary(head_sha) do
    tool = metadata_tool(type)

    Enum.any?(progress_events, fn
      %ProgressEvent{payload: payload} = event when is_map(payload) ->
        payload_type?(event, type, tool) and head_sha_matches?(Map.get(payload, "head_sha"), head_sha)

      %ProgressEvent{} ->
        false
    end)
  end

  def metadata_present?(_progress_events, _type, _head_sha), do: false

  @spec current_pr_state_present?([ProgressEvent.t()], String.t()) :: boolean()
  def current_pr_state_present?(progress_events, head_sha) when is_binary(head_sha) do
    case latest_attached_pr_ref_with_ledger_boundary(progress_events) do
      {:ok, attached_ref, attach_boundary} ->
        Enum.any?(progress_events, fn
          %ProgressEvent{payload: payload} = event when is_map(payload) ->
            current_pr_state_event?(event, attach_boundary) and
              head_sha_matches?(Map.get(payload, "head_sha"), head_sha) and
              pr_payload_ref(payload) == attached_ref and current_pr_state_payload?(payload)

          %ProgressEvent{} ->
            false
        end)

      {:error, :not_found} ->
        false
    end
  end

  def current_pr_state_present?(_progress_events, _head_sha), do: false

  defp progress_after_pr_attach_boundary?(%ProgressEvent{} = event, {:sequence, attach_boundary}) do
    progress_event_sequence_order(event) > attach_boundary
  end

  defp progress_after_pr_attach_boundary?(%ProgressEvent{} = event, {:chronological, attach_boundary}) do
    progress_event_order(event) > attach_boundary
  end

  defp progress_after_pr_attach_boundary?(%ProgressEvent{}, _attach_boundary), do: false

  defp current_pr_state_event?(%ProgressEvent{} = event, {:repair_sync, repair_boundary}) do
    payload_type?(event, "pr", "sync_pr") and
      (attach_boundary(event) == repair_boundary or progress_after_pr_attach_boundary?(event, repair_boundary))
  end

  defp current_pr_state_event?(%ProgressEvent{} = event, attach_boundary) do
    (payload_type?(event, "pr", "attach_pr") and attach_boundary(event) == attach_boundary) or
      (payload_type?(event, "pr", "sync_pr") and progress_after_pr_attach_boundary?(event, attach_boundary))
  end

  defp current_pr_state_payload?(payload) when is_map(payload), do: semantic_pr_payload?(payload)

  defp semantic_pr_payload?(payload) do
    semantic_pr_state?(payload, "check_summary", ["conclusion", "state", "status"]) or
      semantic_pr_state?(payload, "review_state", ["decision", "state", "status"]) or
      semantic_pr_state?(payload, "merge_state", ["mergeable_state", "state", "status"]) or
      semantic_pr_boolean?(payload, "merge_state", ["mergeable", "merged"])
  end

  defp semantic_pr_state?(payload, key, semantic_keys) do
    case Map.get(payload, key) do
      value when is_map(value) ->
        Enum.any?(semantic_keys, fn semantic_key ->
          semantic_pr_value?(value, semantic_key)
        end)

      _value ->
        false
    end
  end

  defp semantic_pr_value(value, key), do: Map.get(value, key) || Map.get(value, String.to_atom(key))

  defp semantic_pr_value?(value, "state") do
    case semantic_pr_value(value, "state") do
      state when is_binary(state) ->
        normalized = state |> String.trim() |> String.downcase()
        normalized != "" and normalized not in ["open", "closed"]

      _state ->
        false
    end
  end

  defp semantic_pr_value?(value, key), do: value |> semantic_pr_value(key) |> filled_string?()

  defp semantic_pr_boolean?(payload, key, semantic_keys) do
    case Map.get(payload, key) do
      value when is_map(value) ->
        Enum.any?(semantic_keys, fn semantic_key ->
          is_boolean(Map.get(value, semantic_key)) or is_boolean(Map.get(value, String.to_atom(semantic_key)))
        end)

      _value ->
        false
    end
  end

  defp metadata_tool("branch"), do: "attach_branch"
  defp metadata_tool("pr"), do: ["attach_pr", "sync_pr"]
  defp metadata_tool(_type), do: nil

  @spec normalized_status(term()) :: String.t()
  def normalized_status(status) when is_binary(status), do: status |> String.trim() |> String.downcase()
  def normalized_status(_status), do: ""

  @spec metadata([ProgressEvent.t()]) :: map()
  def metadata(progress_events) do
    branch = latest_payload(progress_events, "branch", "attach_branch")
    head_filter = metadata_head_filter(progress_events, branch)
    pr = latest_pr_payload(progress_events, head_filter)

    %{
      branch: branch,
      pr: pr_metadata(pr, head_filter)
    }
  end

  @spec package_lineage(module(), String.t()) :: map()
  def package_lineage(repo, work_package_id) do
    case OperationalLineage.get(repo, work_package_id) do
      {:ok, lineage} -> lineage
      {:error, reason} -> OperationalLineage.unavailable_lineage(work_package_id, reason)
    end
  end

  @spec package_lineages(module(), [WorkPackage.t()]) :: map()
  def package_lineages(_repo, []), do: %{}

  def package_lineages(repo, work_packages) do
    case OperationalLineage.for_work_packages(repo, work_packages) do
      {:ok, lineages_by_id} -> lineages_by_id
      {:error, reason} -> unavailable_lineages(work_packages, reason)
    end
  end

  @spec empty_lineage(String.t()) :: map()
  def empty_lineage(work_package_id), do: OperationalLineage.empty_lineage(work_package_id)

  defp unavailable_lineages(work_packages, reason) do
    Map.new(work_packages, fn %WorkPackage{} = work_package ->
      {work_package.id, OperationalLineage.unavailable_lineage(work_package.id, reason)}
    end)
  end

  defp pr_metadata(nil, _head_filter), do: nil

  defp pr_metadata(%{} = pr, {:head, current_head_sha}) do
    stale? = not head_sha_matches?(Map.get(pr, "head_sha"), current_head_sha)

    pr
    |> Map.put("stale", stale?)
    |> Map.put("current_head_sha", current_head_sha)
  end

  defp pr_metadata(%{} = pr, :none), do: pr

  defp latest_pr_payload(progress_events, :none) do
    case latest_attached_pr_ref_with_ledger_boundary(progress_events) do
      {:ok, attached_ref, attach_boundary} ->
        latest_preferred_pr_payload(progress_events, :any, attached_ref, attach_boundary)

      {:error, :not_found} ->
        nil
    end
  end

  defp latest_pr_payload(progress_events, head_filter) do
    case latest_attached_pr_ref_with_ledger_boundary(progress_events) do
      {:ok, attached_ref, attach_boundary} ->
        latest_preferred_pr_payload(progress_events, head_filter, attached_ref, attach_boundary) ||
          latest_preferred_pr_payload(progress_events, :any, attached_ref, attach_boundary)

      {:error, :not_found} ->
        nil
    end
  end

  defp latest_preferred_pr_payload(progress_events, head_filter, attached_ref, attach_sequence) do
    latest_payload = latest_pr_display_payload(progress_events, head_filter, attached_ref, attach_sequence)

    cond do
      is_nil(latest_payload) ->
        latest_current_pr_payload(progress_events, head_filter, attached_ref, attach_sequence)

      display_pr_payload?(latest_payload) ->
        latest_payload

      true ->
        latest_current_pr_payload(progress_events, head_filter, attached_ref, attach_sequence) || latest_payload
    end
  end

  defp display_pr_payload?(%{"source_tool" => "sync_pr"}), do: true
  defp display_pr_payload?(%{"source_tool" => "attach_pr"} = payload), do: semantic_pr_payload?(payload)
  defp display_pr_payload?(_payload), do: false

  defp latest_pr_display_payload(progress_events, head_filter, attached_ref, attach_sequence) do
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find(fn
      %ProgressEvent{payload: payload} = event when is_map(payload) ->
        pr_display_payload?(event, payload, head_filter, attached_ref, attach_sequence)

      %ProgressEvent{} ->
        false
    end)
    |> case do
      %ProgressEvent{payload: payload} -> Sanitizer.redacted_json(payload || %{})
      nil -> nil
    end
  end

  defp pr_display_payload?(event, payload, head_filter, attached_ref, attach_sequence) do
    cond do
      payload_type?(event, "pr", "attach_pr") ->
        payload_head_matches?(payload, head_filter) and pr_ref_matches?(payload, attached_ref)

      payload_type?(event, "pr", "sync_pr") ->
        current_pr_state_event?(event, attach_sequence) and payload_head_matches?(payload, head_filter) and
          pr_ref_matches?(payload, attached_ref)

      true ->
        false
    end
  end

  defp latest_current_pr_payload(progress_events, head_filter, attached_ref, attach_sequence) do
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find(fn
      %ProgressEvent{payload: payload} = event when is_map(payload) ->
        current_pr_state_event?(event, attach_sequence) and
          payload_head_matches?(payload, head_filter) and
          pr_ref_matches?(payload, attached_ref) and current_pr_state_payload?(payload)

      %ProgressEvent{} ->
        false
    end)
    |> case do
      %ProgressEvent{payload: payload} -> Sanitizer.redacted_json(payload || %{})
      nil -> nil
    end
  end

  defp latest_payload(progress_events, type, source_tool) do
    latest_payload(progress_events, type, source_tool, :any)
  end

  defp latest_payload(progress_events, type, source_tool, head_filter) do
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find(&(payload_type?(&1, type, source_tool) and payload_head_matches?(&1.payload, head_filter)))
    |> case do
      %ProgressEvent{payload: payload} -> Sanitizer.redacted_json(payload || %{})
      nil -> nil
    end
  end

  defp pr_ref_matches?(_payload, :any), do: true
  defp pr_ref_matches?(payload, pr_ref), do: pr_payload_ref(payload) == pr_ref

  defp latest_attached_pr_ref(progress_events) do
    case latest_attached_pr_ref_with_ledger_boundary(progress_events) do
      {:ok, ref, _boundary} -> {:ok, ref}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp latest_attached_pr_ref_with_ledger_boundary(progress_events) do
    # Attach selection follows event time so replay/backfill can record older PR
    # attachments later. The returned boundary preserves that selected event.
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find_value(&attached_or_repaired_pr_ref_with_boundary/1)
    |> case do
      nil -> {:error, :not_found}
      {ref, boundary} -> {:ok, ref, boundary}
    end
  end

  defp attached_or_repaired_pr_ref_with_boundary(%ProgressEvent{} = event) do
    attached_pr_ref_with_boundary(event) || repaired_pr_ref_with_boundary(event)
  end

  defp attached_pr_ref_with_boundary(%ProgressEvent{payload: payload} = event) when is_map(payload) do
    if payload_type?(event, "pr", "attach_pr"), do: pr_payload_ref_with_sequence(payload, attach_boundary(event))
  end

  defp attached_pr_ref_with_boundary(_event), do: nil

  defp repaired_pr_ref_with_boundary(%ProgressEvent{payload: payload} = event) when is_map(payload) do
    if payload_type?(event, "pr", "sync_pr") and Map.get(payload, "attachment_repair") == true do
      pr_payload_ref_with_sequence(payload, {:repair_sync, attach_boundary(event)})
    end
  end

  defp repaired_pr_ref_with_boundary(_event), do: nil

  defp pr_payload_ref_with_sequence(payload, sequence) do
    case pr_payload_ref(payload) do
      nil -> nil
      ref -> {ref, sequence}
    end
  end

  defp pr_payload_ref(%{"repository" => repository, "number" => number}) when is_binary(repository) and is_integer(number), do: normalized_pr_ref(repository, number)
  defp pr_payload_ref(%{"repository" => repository, "number" => number}) when is_binary(repository) and is_binary(number), do: normalized_pr_ref(repository, number)

  defp pr_payload_ref(%{"url" => url}) when is_binary(url) do
    case PullRequest.parse(%{"url" => url}, nil) do
      {:ok, ref} -> normalized_pr_ref(ref.repository, ref.number)
      {:error, _reason} -> legacy_url_ref(url)
    end
  end

  defp pr_payload_ref(_payload), do: nil

  defp normalized_pr_ref(repository, number) when is_binary(repository), do: {String.downcase(repository), number}

  defp legacy_url_ref(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        if String.downcase(host) == "github.com", do: nil, else: {:url, url}

      _uri ->
        {:url, url}
    end
  rescue
    _error in URI.Error -> {:url, url}
  end

  defp metadata_head_filter(_progress_events, nil), do: :none

  defp metadata_head_filter(progress_events, %{} = branch) do
    head_sha = payload_head_sha(branch) || latest_branch_head_sha(progress_events, payload_branch(branch))

    if is_binary(head_sha), do: {:head, head_sha}, else: :none
  end

  defp latest_branch_head_sha(_progress_events, nil), do: nil

  defp latest_branch_head_sha(progress_events, branch_name) do
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find_value(fn
      %ProgressEvent{payload: payload} when is_map(payload) ->
        if payload_type?(%ProgressEvent{payload: payload}, "branch", "attach_branch") and payload_branch(payload) == branch_name do
          payload_head_sha(payload)
        end

      _event ->
        nil
    end)
  end

  defp payload_head_matches?(_payload, :any), do: true
  defp payload_head_matches?(payload, {:head, head_sha}) when is_map(payload), do: head_sha_matches?(Map.get(payload, "head_sha"), head_sha)

  defp head_sha_matches?(left, right), do: PullRequest.head_sha_matches?(left, right)

  defp payload_branch(%{} = payload) do
    case Map.get(payload, "branch") do
      branch when is_binary(branch) ->
        branch = String.trim(branch)
        if branch == "", do: nil, else: branch

      _missing ->
        nil
    end
  end

  defp payload_head_sha(%{} = payload) do
    case Map.get(payload, "head_sha") do
      head_sha when is_binary(head_sha) ->
        if String.trim(head_sha) == "", do: nil, else: head_sha

      _missing ->
        nil
    end
  end

  defp payload_head_sha(_payload), do: nil

  @spec chronological_progress_events([ProgressEvent.t()]) :: [ProgressEvent.t()]
  def chronological_progress_events(progress_events) do
    Enum.sort_by(progress_events, &progress_event_order/1)
  end

  defp progress_event_order(%ProgressEvent{} = event) do
    {Sanitizer.timestamp_sort_value(event.created_at), event.sequence || 0, event.id || ""}
  end

  defp attach_boundary(%ProgressEvent{sequence: sequence} = event) when is_integer(sequence) do
    {:sequence, progress_event_sequence_order(event)}
  end

  defp attach_boundary(%ProgressEvent{} = event) do
    {:chronological, progress_event_order(event)}
  end

  defp progress_event_sequence_order(%ProgressEvent{sequence: sequence} = event) when is_integer(sequence) do
    {1, sequence, Sanitizer.timestamp_sort_value(event.created_at), event.id || ""}
  end

  defp progress_event_sequence_order(%ProgressEvent{} = event) do
    {0, Sanitizer.timestamp_sort_value(event.created_at), event.id || ""}
  end

  @spec payload_type?(ProgressEvent.t(), String.t(), String.t() | [String.t()] | nil) :: boolean()
  def payload_type?(%ProgressEvent{payload: payload}, type, source_tool) when is_map(payload) and is_list(source_tool) do
    Map.get(payload, "type") == type and Map.get(payload, "source_tool") in source_tool
  end

  def payload_type?(%ProgressEvent{payload: payload}, type, source_tool) when is_map(payload) do
    Map.get(payload, "type") == type and (is_nil(source_tool) or Map.get(payload, "source_tool") == source_tool)
  end

  def payload_type?(%ProgressEvent{}, _type, _source_tool), do: false
end
