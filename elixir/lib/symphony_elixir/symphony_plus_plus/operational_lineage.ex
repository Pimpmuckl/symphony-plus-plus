defmodule SymphonyElixir.SymphonyPlusPlus.OperationalLineage do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @type repo :: module()
  @type relationship :: String.t()
  @type lineage_error ::
          :invalid_relationship
          | :invalid_work_package_id
          | :missing_reason
          | :missing_decision_linkage
          | :self_relationship
          | PlanningRepository.error()
          | term()

  @lineage_type "operational_lineage"
  @source_tool "record_operational_lineage"
  @relationships ["superseded_by", "recut_as", "oracle_for"]
  @successor_relationships ["superseded_by", "recut_as"]
  @closed_statuses ["merged", "closed", "abandoned"]
  @lineage_unavailable_attention %{
    key: "lineage_unavailable",
    label: "Lineage Unavailable",
    tone: "warning",
    reason: "Operational lineage could not be read."
  }

  @spec record_superseded_by(repo(), String.t(), String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, lineage_error()}
  def record_superseded_by(repo, original_work_package_id, successor_work_package_id, attrs \\ %{}) do
    record(repo, original_work_package_id, "superseded_by", successor_work_package_id, attrs)
  end

  @spec record_recut_as(repo(), String.t(), String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, lineage_error()}
  def record_recut_as(repo, original_work_package_id, successor_work_package_id, attrs \\ %{}) do
    record(repo, original_work_package_id, "recut_as", successor_work_package_id, attrs)
  end

  @spec record_oracle_for(repo(), String.t(), String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, lineage_error()}
  def record_oracle_for(repo, oracle_work_package_id, target_work_package_id, attrs \\ %{}) do
    record(repo, oracle_work_package_id, "oracle_for", target_work_package_id, attrs)
  end

  @spec record(repo(), String.t(), relationship(), String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, lineage_error()}
  def record(repo, source_work_package_id, relationship, target_work_package_id, attrs)
      when is_atom(repo) and is_binary(relationship) do
    attrs = normalize_attrs(attrs)

    with {:ok, relationship} <- normalize_relationship(relationship),
         {:ok, source_work_package_id} <- normalize_work_package_id(source_work_package_id),
         {:ok, target_work_package_id} <- normalize_work_package_id(target_work_package_id),
         :ok <- reject_self_relationship(source_work_package_id, target_work_package_id),
         {:ok, reason} <- required_text(attrs, "reason", :missing_reason),
         {:ok, decision} <- decision_linkage(attrs),
         {:ok, %WorkPackage{} = source} <- WorkPackageRepository.get(repo, source_work_package_id),
         {:ok, %WorkPackage{} = target} <- WorkPackageRepository.get(repo, target_work_package_id),
         {:ok, event} <- append_relationship_event(repo, source, relationship, target, reason, decision, attrs) do
      {:ok, event_to_relationship(event, packages_by_id([source, target]))}
    end
  end

  @spec get(repo(), String.t()) :: {:ok, map()} | {:error, lineage_error()}
  def get(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    with {:ok, work_package_id} <- normalize_work_package_id(work_package_id),
         {:ok, %WorkPackage{} = work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, relationships} <- list_relationships(repo, [work_package_id]) do
      {:ok, package_lineage(work_package, relationships)}
    end
  end

  @spec empty_lineage(String.t()) :: map()
  def empty_lineage(work_package_id) do
    %{
      work_package_id: work_package_id,
      original_work: [],
      successor_work: [],
      superseded_by: [],
      recut_as: [],
      oracle_for: [],
      oracle_work: [],
      oracle_status: %{
        preserved: false,
        oracle_for_work_package_ids: [],
        has_oracle: false,
        oracle_work_package_ids: []
      },
      available: true,
      unavailable: false,
      cleanup_attention: []
    }
  end

  @spec unavailable_lineage(String.t(), term()) :: map()
  def unavailable_lineage(work_package_id, reason) do
    error = lineage_error_code(reason)

    work_package_id
    |> empty_lineage()
    |> Map.merge(%{
      available: false,
      unavailable: true,
      error: error,
      cleanup_attention: [Map.put(@lineage_unavailable_attention, :error, error)]
    })
  end

  @spec for_work_packages(repo(), [WorkPackage.t()]) :: {:ok, %{String.t() => map()}} | {:error, lineage_error()}
  def for_work_packages(repo, work_packages) when is_atom(repo) and is_list(work_packages) do
    work_package_ids = Enum.map(work_packages, & &1.id)

    with {:ok, relationships} <- list_relationships(repo, work_package_ids) do
      relationships = relationships_visible_to_packages(relationships, work_package_ids)

      {:ok,
       Map.new(work_packages, fn
         %WorkPackage{} = work_package -> {work_package.id, package_lineage(work_package, relationships)}
       end)}
    end
  end

  @spec list_relationships(repo()) :: {:ok, [map()]} | {:error, lineage_error()}
  def list_relationships(repo) when is_atom(repo) do
    with {:ok, events} <- lineage_progress_events(repo, :all),
         {:ok, packages_by_id} <- lineage_packages_by_id(repo, events) do
      relationships = Enum.flat_map(events, &event_to_relationship_list(&1, packages_by_id))
      {:ok, relationships}
    end
  end

  defp list_relationships(repo, work_package_ids) when is_atom(repo) and is_list(work_package_ids) do
    with {:ok, work_package_ids} <- normalize_work_package_ids(work_package_ids),
         {:ok, events} <- lineage_progress_events(repo, {:related_to, work_package_ids}),
         {:ok, packages_by_id} <- lineage_packages_by_id(repo, events) do
      relationships = Enum.flat_map(events, &event_to_relationship_list(&1, packages_by_id))
      {:ok, relationships}
    end
  end

  defp append_relationship_event(repo, %WorkPackage{} = source, relationship, %WorkPackage{} = target, reason, decision, attrs) do
    payload = %{
      "type" => @lineage_type,
      "source_tool" => @source_tool,
      "relationship" => relationship,
      "source_work_package_id" => source.id,
      "source_branch" => source.branch_pattern,
      "target_work_package_id" => target.id,
      "target_branch" => target.branch_pattern,
      "reason" => json_value(reason),
      "decision" => decision,
      "oracle_preserved" => oracle_preserved?(relationship, attrs)
    }

    PlanningRepository.append_progress_event(repo, %{
      work_package_id: source.id,
      summary: "Recorded #{relationship} lineage to #{target.id}",
      status: "operational_lineage_recorded",
      idempotency_key: lineage_idempotency_key(source.id, relationship, target.id, attrs),
      payload: payload
    })
  end

  defp package_lineage(%WorkPackage{} = work_package, relationships) do
    outgoing = Enum.filter(relationships, &(&1.source_work_package_id == work_package.id))
    incoming = Enum.filter(relationships, &(&1.target_work_package_id == work_package.id))
    outgoing_by_relationship = Enum.group_by(outgoing, & &1.relationship)
    incoming_by_relationship = Enum.group_by(incoming, & &1.relationship)
    outgoing_successors = Enum.filter(outgoing, &successor_relationship?/1)
    incoming_originals = Enum.filter(incoming, &successor_relationship?/1)
    superseded_by = Map.get(outgoing_by_relationship, "superseded_by", [])
    recut_as = Map.get(outgoing_by_relationship, "recut_as", [])
    outgoing_oracle = Map.get(outgoing_by_relationship, "oracle_for", [])
    incoming_oracle = Map.get(incoming_by_relationship, "oracle_for", [])

    %{
      work_package_id: work_package.id,
      original_work: Enum.map(incoming_originals, &original_work_entry/1),
      successor_work: Enum.map(outgoing_successors, &successor_work_entry/1),
      superseded_by: Enum.map(superseded_by, &successor_work_entry/1),
      recut_as: Enum.map(recut_as, &successor_work_entry/1),
      oracle_for: Enum.map(outgoing_oracle, &oracle_for_entry/1),
      oracle_work: Enum.map(incoming_oracle, &oracle_work_entry/1),
      oracle_status: oracle_status(outgoing_oracle, incoming_oracle),
      available: true,
      unavailable: false,
      cleanup_attention: cleanup_attention(work_package, outgoing_successors, incoming_originals)
    }
  end

  defp event_to_relationship_list(%ProgressEvent{} = event, packages_by_id) do
    case event_to_relationship(event, packages_by_id) do
      nil -> []
      relationship -> [relationship]
    end
  end

  defp event_to_relationship(%ProgressEvent{payload: payload} = event, packages_by_id) when is_map(payload) do
    with true <- payload_value(payload, "type") == @lineage_type,
         true <- payload_value(payload, "source_tool") == @source_tool,
         relationship when relationship in @relationships <- payload_value(payload, "relationship"),
         source_work_package_id when is_binary(source_work_package_id) <- source_work_package_id(event, payload),
         target_work_package_id when is_binary(target_work_package_id) <- payload_value(payload, "target_work_package_id") do
      source = Map.get(packages_by_id, source_work_package_id)
      target = Map.get(packages_by_id, target_work_package_id)

      %{
        relationship: relationship,
        source_work_package_id: source_work_package_id,
        source_branch: package_branch(source, payload_value(payload, "source_branch")),
        source_status: package_status(source),
        target_work_package_id: target_work_package_id,
        target_branch: package_branch(target, payload_value(payload, "target_branch")),
        target_status: package_status(target),
        reason: json_value(payload_value(payload, "reason")),
        decision: json_value(payload_value(payload, "decision") || %{}),
        oracle_preserved: truthy?(payload_value(payload, "oracle_preserved")),
        event_id: event.id,
        recorded_at: timestamp(event.created_at)
      }
    else
      _not_lineage -> nil
    end
  end

  defp event_to_relationship(%ProgressEvent{}, _packages_by_id), do: nil

  defp source_work_package_id(%ProgressEvent{} = event, payload), do: payload_value(payload, "source_work_package_id") || event.work_package_id

  defp payload_value(payload, key) when is_binary(key), do: Map.get(payload, key) || Map.get(payload, String.to_atom(key))

  defp relationships_visible_to_packages(relationships, work_package_ids) do
    visible_ids = MapSet.new(work_package_ids)

    Enum.filter(relationships, fn relationship ->
      MapSet.member?(visible_ids, relationship.source_work_package_id) and
        MapSet.member?(visible_ids, relationship.target_work_package_id)
    end)
  end

  defp lineage_progress_events(repo, scope) do
    {:ok, repo.all(lineage_progress_events_query(scope))}
  rescue
    error in Exqlite.Error -> {:error, normalize_exqlite_error(error)}
  end

  defp lineage_progress_events_query(scope) do
    from(event in ProgressEvent,
      where: event.status == "operational_lineage_recorded",
      where: fragment("json_extract(?, '$.type') = ?", event.payload, ^@lineage_type),
      where: fragment("json_extract(?, '$.source_tool') = ?", event.payload, ^@source_tool),
      where: fragment("json_extract(?, '$.relationship')", event.payload) in ^@relationships,
      order_by: [asc: event.created_at, asc: event.sequence, asc: event.id]
    )
    |> filter_lineage_progress_events_query(scope)
  end

  defp filter_lineage_progress_events_query(query, :all), do: query

  defp filter_lineage_progress_events_query(query, {:related_to, work_package_ids}) do
    from(event in query,
      where:
        event.work_package_id in ^work_package_ids or
          fragment("json_extract(?, '$.source_work_package_id')", event.payload) in ^work_package_ids or
          fragment("json_extract(?, '$.target_work_package_id')", event.payload) in ^work_package_ids
    )
  end

  defp lineage_packages_by_id(_repo, []), do: {:ok, %{}}

  defp lineage_packages_by_id(repo, events) do
    package_ids =
      events
      |> Enum.flat_map(fn event ->
        payload = event.payload || %{}
        [source_work_package_id(event, payload), payload_value(payload, "target_work_package_id")]
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    {:ok,
     repo.all(
       from(work_package in WorkPackage,
         where: work_package.id in ^package_ids
       )
     )
     |> packages_by_id()}
  rescue
    error in Exqlite.Error -> {:error, normalize_exqlite_error(error)}
  end

  defp original_work_entry(relationship) do
    relationship
    |> common_entry()
    |> Map.merge(%{
      work_package_id: relationship.source_work_package_id,
      branch: relationship.source_branch,
      status: relationship.source_status
    })
  end

  defp successor_work_entry(relationship) do
    relationship
    |> common_entry()
    |> Map.merge(%{
      work_package_id: relationship.target_work_package_id,
      branch: relationship.target_branch,
      status: relationship.target_status
    })
  end

  defp oracle_for_entry(relationship), do: successor_work_entry(relationship)
  defp oracle_work_entry(relationship), do: original_work_entry(relationship)

  defp common_entry(relationship) do
    %{
      relationship: relationship.relationship,
      source_work_package_id: relationship.source_work_package_id,
      source_branch: relationship.source_branch,
      source_status: relationship.source_status,
      target_work_package_id: relationship.target_work_package_id,
      target_branch: relationship.target_branch,
      target_status: relationship.target_status,
      reason: relationship.reason,
      decision: relationship.decision,
      oracle_preserved: relationship.oracle_preserved,
      event_id: relationship.event_id,
      recorded_at: relationship.recorded_at
    }
  end

  defp oracle_status(outgoing_oracle, incoming_oracle) do
    %{
      preserved: outgoing_oracle != [],
      oracle_for_work_package_ids: Enum.map(outgoing_oracle, & &1.target_work_package_id),
      has_oracle: incoming_oracle != [],
      oracle_work_package_ids: Enum.map(incoming_oracle, & &1.source_work_package_id)
    }
  end

  defp cleanup_attention(%WorkPackage{} = work_package, outgoing_successors, incoming_originals) do
    [
      original_still_open_attention(work_package, outgoing_successors),
      incoming_original_still_open_attention(incoming_originals)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp original_still_open_attention(%WorkPackage{status: status}, successors) do
    if successors != [] and open_status?(status) do
      %{
        key: "original_work_still_open",
        label: "Original Work Still Open",
        tone: "warning",
        reason: "This package has explicit successor lineage but raw status remains #{status}.",
        successor_work_package_ids: Enum.map(successors, & &1.target_work_package_id)
      }
    end
  end

  defp incoming_original_still_open_attention(incoming_originals) do
    open_originals = Enum.filter(incoming_originals, &open_status?(&1.source_status))

    if open_originals != [] do
      %{
        key: "successor_original_work_still_open",
        label: "Original Work Still Open",
        tone: "warning",
        reason: "One or more original packages that point to this successor remain open.",
        original_work_package_ids: Enum.map(open_originals, & &1.source_work_package_id)
      }
    end
  end

  defp open_status?(status) when is_binary(status), do: status not in @closed_statuses
  defp open_status?(_status), do: false

  defp successor_relationship?(%{relationship: relationship}), do: relationship in @successor_relationships

  defp normalize_relationship(relationship) do
    relationship = String.trim(relationship)

    if relationship in @relationships do
      {:ok, relationship}
    else
      {:error, :invalid_relationship}
    end
  end

  defp normalize_work_package_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_work_package_id}
      id -> {:ok, id}
    end
  end

  defp normalize_work_package_id(_value), do: {:error, :invalid_work_package_id}

  defp normalize_work_package_ids(work_package_ids) do
    normalized =
      work_package_ids
      |> Enum.map(&normalize_work_package_id/1)
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, work_package_id}, {:ok, acc} -> {:cont, {:ok, [work_package_id | acc]}}
        {:error, reason}, {:ok, _acc} -> {:halt, {:error, reason}}
      end)

    case normalized do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp reject_self_relationship(work_package_id, work_package_id), do: {:error, :self_relationship}
  defp reject_self_relationship(_source_work_package_id, _target_work_package_id), do: :ok

  defp required_text(attrs, key, error) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, error}
          text -> {:ok, text}
        end

      _value ->
        {:error, error}
    end
  end

  defp decision_linkage(attrs) do
    decision =
      attrs
      |> Map.get("decision", Map.get(attrs, "decision_linkage", %{}))
      |> normalize_decision_map()
      |> maybe_put_text("work_request_id", Map.get(attrs, "work_request_id"))
      |> maybe_put_text("decision_id", Map.get(attrs, "decision_id"))

    if map_size(decision) == 0 do
      {:error, :missing_decision_linkage}
    else
      {:ok, json_value(decision)}
    end
  end

  defp normalize_decision_map(%{} = decision) do
    decision
    |> normalize_attrs()
    |> prune_blank_decision_values()
  end

  defp normalize_decision_map(_decision), do: %{}

  defp prune_blank_decision_values(%{} = decision) do
    Enum.reduce(decision, %{}, fn {key, value}, pruned ->
      case normalize_decision_value(value) do
        :blank -> pruned
        normalized -> Map.put(pruned, key, normalized)
      end
    end)
  end

  defp normalize_decision_value(nil), do: :blank

  defp normalize_decision_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :blank
      text -> text
    end
  end

  defp normalize_decision_value(%{} = value) do
    case prune_blank_decision_values(value) do
      empty when map_size(empty) == 0 -> :blank
      pruned -> pruned
    end
  end

  defp normalize_decision_value(values) when is_list(values) do
    values =
      values
      |> Enum.map(&normalize_decision_value/1)
      |> Enum.reject(&(&1 == :blank))

    if values == [], do: :blank, else: values
  end

  defp normalize_decision_value(value), do: value

  defp maybe_put_text(map, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> map
      text -> Map.put_new(map, key, text)
    end
  end

  defp maybe_put_text(map, _key, _value), do: map

  defp oracle_preserved?("oracle_for", _attrs), do: true

  defp oracle_preserved?(_relationship, attrs) do
    truthy?(Map.get(attrs, "oracle_preserved"))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("yes"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_value), do: false

  defp lineage_idempotency_key(source_work_package_id, relationship, target_work_package_id, attrs) do
    case Map.get(attrs, "idempotency_key") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default_lineage_idempotency_key(source_work_package_id, relationship, target_work_package_id)
          key -> key
        end

      _value ->
        default_lineage_idempotency_key(source_work_package_id, relationship, target_work_package_id)
    end
  end

  defp default_lineage_idempotency_key(source_work_package_id, relationship, target_work_package_id) do
    Enum.join(["operational_lineage", relationship, source_work_package_id, target_work_package_id], ":")
  end

  defp packages_by_id(packages), do: Map.new(packages, &{&1.id, &1})

  defp package_branch(_work_package, fallback) when is_binary(fallback) and fallback != "", do: json_value(fallback)
  defp package_branch(%WorkPackage{branch_pattern: branch}, _fallback) when is_binary(branch) and branch != "", do: json_value(branch)
  defp package_branch(_work_package, _fallback), do: nil

  defp package_status(%WorkPackage{status: status}), do: status
  defp package_status(_work_package), do: nil

  defp json_value(value) do
    value
    |> Redactor.redact_output()
    |> Redactor.json_safe()
  end

  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp(_datetime), do: nil

  defp normalize_attrs(attrs) when is_list(attrs), do: attrs |> Enum.into(%{}) |> normalize_attrs()
  defp normalize_attrs(attrs) when is_map(attrs), do: Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  defp normalize_attrs(_attrs), do: %{}

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)

    if message |> String.downcase() |> String.contains?("busy") do
      :database_busy
    else
      {:storage_failed, message}
    end
  end

  defp lineage_error_code(:database_busy), do: "database_busy"
  defp lineage_error_code({:storage_failed, _message}), do: "storage_failed"
  defp lineage_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp lineage_error_code(_reason), do: "lineage_read_failed"
end
