defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequestProgress
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @ready_statuses ["ready_for_merge", "ready_for_human_merge", "ready_for_architect_merge"]
  @terminal_package_statuses ["merged", "merged_into_phase", "closed", "abandoned"]
  @runtime_merge_required_kinds ["hotfix", "adapter", "mcp", "skill", "hooks", "phase_child"]
  @delivery_lookup_chunk_size 400
  @context_lookup_chunk_size 400
  @review_package_artifact_limit 20
  @review_package_string_limit 240

  @delivery_states %{
    "pr_merged" => {"delivered", "Delivered", "success", "Recorded delivery outcome says the linked PR merged."},
    "completed_no_pr" => {"completed_no_pr", "Completed Without PR", "success", "Recorded delivery outcome says the slice completed without a PR."},
    "superseded" => {"superseded", "Superseded", "neutral", "Recorded delivery outcome says this slice was superseded by a successor."},
    "abandoned" => {"abandoned", "Abandoned", "neutral", "Recorded delivery outcome says this slice was abandoned."}
  }

  @attention_details %{
    "active_blocker" => {"Blocker", "critical", "Active blocker."},
    "active_runtime" => {"Active", "info", "Worker activity is still current."},
    "linked_package_active_after_delivery" => {"Active After Delivery", "warning", "Worker activity remains after delivery closeout."},
    "linked_package_blocked_after_delivery" => {"Blocked After Delivery", "warning", "A blocker remains after delivery closeout."},
    "linked_package_status_stale_after_delivery" => {"Status Needs Repair", "warning", "Package status does not match the delivery outcome."},
    "ambiguous_linked_work_package" => {"Ambiguous Package", "warning", "Multiple planned slices point at the same WorkPackage."},
    "missing_linked_work_package" => {"Missing Package", "warning", "Dispatched slice has no visible package."},
    "pr_merged_without_delivery_outcome" => {"Needs Closeout", "warning", "Merged PR needs delivery closeout."},
    "terminal_package_without_delivery_outcome" => {"Needs Closeout", "warning", "Terminal package needs delivery closeout."}
  }

  @type repo :: module()
  @type error :: Repository.error() | :database_busy | {:storage_failed, String.t()} | term()
  @type planned_slice_visibility :: %{
          visible_planned_slices: [PlannedSlice.t()]
        }

  @spec project(repo(), String.t()) :: {:ok, map()} | {:error, error()}
  @spec project(repo(), String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def project(repo, work_request_id, opts \\ []) when is_atom(repo) and is_binary(work_request_id) and is_list(opts) do
    with {:ok, _work_request} <- work_request(repo, work_request_id, opts),
         {:ok, planned_slices} <- planned_slices(repo, work_request_id, opts),
         {:ok, deliveries_by_slice_id} <- planned_slice_deliveries_by_id(repo, work_request_id, planned_slices),
         visible_planned_slices = planned_slices,
         {:ok, context} <- projection_context(repo, visible_planned_slices, deliveries_by_slice_id, opts) do
      slices_by_scope = planned_slices_by_scope(visible_planned_slices)

      slices =
        Enum.map(visible_planned_slices, fn %PlannedSlice{} = planned_slice ->
          project_slice(planned_slice, deliveries_by_slice_id, slices_by_scope, context, opts)
        end)

      {:ok, board_payload(work_request_id, slices)}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec visible_planned_slices(repo(), String.t(), [PlannedSlice.t()]) ::
          {:ok, [PlannedSlice.t()]} | {:error, error()}
  @spec visible_planned_slices(repo(), String.t(), [PlannedSlice.t()], keyword()) ::
          {:ok, [PlannedSlice.t()]} | {:error, error()}
  def visible_planned_slices(repo, work_request_id, planned_slices, opts \\ [])
      when is_atom(repo) and is_binary(work_request_id) and is_list(planned_slices) and is_list(opts) do
    with {:ok, visibility} <- planned_slice_visibility(repo, work_request_id, planned_slices, opts) do
      {:ok, Map.fetch!(visibility, :visible_planned_slices)}
    end
  end

  @spec planned_slice_visibility(repo(), String.t(), [PlannedSlice.t()]) ::
          {:ok, planned_slice_visibility()} | {:error, error()}
  @spec planned_slice_visibility(repo(), String.t(), [PlannedSlice.t()], keyword()) ::
          {:ok, planned_slice_visibility()} | {:error, error()}
  def planned_slice_visibility(_repo, _work_request_id, planned_slices, _opts \\ [])
      when is_list(planned_slices) do
    {:ok, %{visible_planned_slices: planned_slices}}
  end

  @spec project_many(repo(), [WorkRequest.t()], %{optional(String.t()) => [PlannedSlice.t()]}) ::
          {:ok, %{optional(String.t()) => map()}} | {:error, error()}
  @spec project_many(repo(), [WorkRequest.t()], %{optional(String.t()) => [PlannedSlice.t()]}, keyword()) ::
          {:ok, %{optional(String.t()) => map()}} | {:error, error()}
  def project_many(repo, work_requests, planned_slices_by_request, opts \\ [])
      when is_atom(repo) and is_list(work_requests) and is_map(planned_slices_by_request) and is_list(opts) do
    with :ok <- validate_planned_slices_by_request(work_requests, planned_slices_by_request),
         planned_slices = all_planned_slices(work_requests, planned_slices_by_request),
         {:ok, deliveries_by_slice_id} <- planned_slice_deliveries_by_id(repo, planned_slices),
         visible_planned_slices_by_request = planned_slices_by_request,
         visible_planned_slices = all_planned_slices(work_requests, visible_planned_slices_by_request),
         {:ok, context} <- projection_context(repo, visible_planned_slices, deliveries_by_slice_id, opts) do
      {:ok,
       Map.new(
         work_requests,
         &project_request_board(
           &1,
           planned_slices_by_request,
           visible_planned_slices_by_request,
           deliveries_by_slice_id,
           context,
           opts
         )
       )}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp project_request_board(
         %WorkRequest{} = work_request,
         _planned_slices_by_request,
         visible_planned_slices_by_request,
         deliveries_by_slice_id,
         context,
         opts
       ) do
    visible_request_planned_slices = Map.get(visible_planned_slices_by_request, work_request.id, [])
    slices_by_scope = planned_slices_by_scope(visible_request_planned_slices)
    slices = Enum.map(visible_request_planned_slices, &project_slice(&1, deliveries_by_slice_id, slices_by_scope, context, opts))

    {work_request.id, board_payload(work_request.id, slices)}
  end

  defp work_request(repo, work_request_id, opts) do
    case Keyword.get(opts, :work_request) do
      %WorkRequest{id: ^work_request_id} = work_request -> {:ok, work_request}
      nil -> Repository.get(repo, work_request_id)
      _other -> {:error, :not_found}
    end
  end

  defp planned_slices(repo, work_request_id, opts) do
    case Keyword.get(opts, :planned_slices) do
      nil ->
        Repository.list_planned_slices(repo, work_request_id)

      planned_slices when is_list(planned_slices) ->
        if Enum.all?(planned_slices, &planned_slice_for_work_request?(&1, work_request_id)) do
          {:ok, planned_slices}
        else
          {:error, :not_found}
        end

      _other ->
        {:error, :not_found}
    end
  end

  defp planned_slice_for_work_request?(%PlannedSlice{work_request_id: slice_work_request_id}, work_request_id) do
    slice_work_request_id == work_request_id
  end

  defp planned_slice_for_work_request?(_value, _work_request_id), do: false

  defp planned_slice_deliveries_by_id(_repo, _work_request_id, []), do: {:ok, %{}}

  defp planned_slice_deliveries_by_id(repo, work_request_id, planned_slices) do
    deliveries =
      Enum.flat_map(planned_slice_chunks(planned_slices), fn planned_slice_chunk ->
        planned_slice_ids = Enum.map(planned_slice_chunk, & &1.id)

        repo.all(
          from(delivery in PlannedSliceDelivery,
            where: delivery.work_request_id == ^work_request_id,
            where: delivery.planned_slice_id in ^planned_slice_ids
          )
        )
      end)

    {:ok, Map.new(deliveries, &{{&1.work_request_id, &1.planned_slice_id}, &1})}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp planned_slice_deliveries_by_id(_repo, []), do: {:ok, %{}}

  defp planned_slice_deliveries_by_id(repo, planned_slices) do
    deliveries =
      Enum.flat_map(planned_slice_chunks(planned_slices), fn planned_slice_chunk ->
        planned_slice_ids = Enum.map(planned_slice_chunk, & &1.id)
        work_request_ids = planned_slice_chunk |> Enum.map(& &1.work_request_id) |> Enum.uniq()

        repo.all(
          from(delivery in PlannedSliceDelivery,
            where: delivery.work_request_id in ^work_request_ids,
            where: delivery.planned_slice_id in ^planned_slice_ids
          )
        )
      end)

    {:ok, Map.new(deliveries, &{{&1.work_request_id, &1.planned_slice_id}, &1})}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp planned_slice_chunks(planned_slices), do: Enum.chunk_every(planned_slices, @delivery_lookup_chunk_size)
  defp context_lookup_chunks(work_package_ids), do: Enum.chunk_every(work_package_ids, @context_lookup_chunk_size)

  defp validate_planned_slices_by_request(work_requests, planned_slices_by_request) do
    if Enum.all?(work_requests, &planned_slices_match_work_request?(&1, planned_slices_by_request)) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp planned_slices_match_work_request?(%WorkRequest{} = work_request, planned_slices_by_request) do
    planned_slices_by_request
    |> Map.get(work_request.id, [])
    |> Enum.all?(&planned_slice_for_work_request?(&1, work_request.id))
  end

  defp all_planned_slices(work_requests, planned_slices_by_request) do
    Enum.flat_map(work_requests, &Map.get(planned_slices_by_request, &1.id, []))
  end

  defp board_payload(work_request_id, slices) do
    %{
      work_request_id: work_request_id,
      slice_count: length(slices),
      counts: state_counts(slices),
      slices: slices
    }
  end

  defp delivery_for_slice(deliveries_by_slice_id, %PlannedSlice{} = planned_slice) do
    Map.get(deliveries_by_slice_id, {planned_slice.work_request_id, planned_slice.id})
  end

  defp planned_slices_by_scope(planned_slices) do
    Map.new(planned_slices, &{{&1.work_request_id, &1.id}, &1})
  end

  defp projection_context(repo, planned_slices, deliveries_by_slice_id, opts) do
    all_work_package_ids =
      planned_slices
      |> Enum.flat_map(fn %PlannedSlice{} = planned_slice ->
        delivery = delivery_for_slice(deliveries_by_slice_id, planned_slice)
        [planned_slice.work_package_id, delivery && delivery.successor_work_package_id]
      end)
      |> Enum.filter(&filled_string?/1)
      |> Enum.uniq()

    ambiguous_work_package_ids = ambiguous_work_package_ids(repo, all_work_package_ids)
    work_package_ids = visible_work_package_ids(all_work_package_ids, Keyword.get(opts, :visible_work_package_ids, :all))
    hidden_work_package_ids = MapSet.difference(MapSet.new(all_work_package_ids), MapSet.new(work_package_ids))

    preloaded_contexts = Keyword.get(opts, :work_package_contexts, %{}) || %{}
    preloaded_work_packages = preloaded_work_packages(work_package_ids, preloaded_contexts)
    preloaded_activity_contexts = preloaded_activity_contexts(work_package_ids, preloaded_contexts)
    preloaded_metadata_contexts = preloaded_metadata_contexts(work_package_ids, preloaded_contexts)
    metadata_fallback_ids = missing_ids(work_package_ids, preloaded_metadata_contexts)

    work_packages =
      repo
      |> work_packages_by_id(missing_ids(work_package_ids, preloaded_work_packages))
      |> Map.merge(preloaded_work_packages)

    progress_events = progress_events_by_work_package_id(repo, metadata_fallback_ids)

    activity_contexts =
      repo
      |> activity_contexts_by_id(missing_ids(work_package_ids, preloaded_activity_contexts))
      |> Map.merge(preloaded_activity_contexts)

    {:ok,
     %{
       work_packages: work_packages,
       progress_events: progress_events,
       activity_contexts: activity_contexts,
       metadata_contexts: preloaded_metadata_contexts,
       hidden_work_package_ids: hidden_work_package_ids,
       ambiguous_work_package_ids: ambiguous_work_package_ids
     }}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp ambiguous_work_package_ids(_repo, []), do: MapSet.new()

  defp ambiguous_work_package_ids(repo, work_package_ids) do
    work_package_ids
    |> context_lookup_chunks()
    |> Enum.flat_map(fn work_package_id_chunk ->
      repo.all(
        from(planned_slice in PlannedSlice,
          where: planned_slice.work_package_id in ^work_package_id_chunk,
          group_by: planned_slice.work_package_id,
          having: count(planned_slice.id) > 1,
          select: planned_slice.work_package_id
        )
      )
    end)
    |> MapSet.new()
  end

  defp visible_work_package_ids(work_package_ids, :all), do: work_package_ids
  defp visible_work_package_ids(work_package_ids, nil), do: work_package_ids

  defp visible_work_package_ids(work_package_ids, visible_ids) when is_list(visible_ids) do
    visible_ids = MapSet.new(visible_ids)
    Enum.filter(work_package_ids, &MapSet.member?(visible_ids, &1))
  end

  defp work_packages_by_id(_repo, []), do: %{}

  defp work_packages_by_id(repo, work_package_ids) do
    work_package_ids
    |> context_lookup_chunks()
    |> Enum.flat_map(fn work_package_id_chunk ->
      repo.all(from(work_package in WorkPackage, where: work_package.id in ^work_package_id_chunk))
    end)
    |> Map.new(&{&1.id, &1})
  end

  defp preloaded_work_packages(work_package_ids, contexts) when is_map(contexts) do
    allowed_ids = MapSet.new(work_package_ids)

    contexts
    |> Enum.flat_map(&preloaded_work_package(&1, allowed_ids))
    |> Map.new()
  end

  defp preloaded_work_package({work_package_id, %{work_package: %WorkPackage{} = work_package}}, allowed_ids) do
    if MapSet.member?(allowed_ids, work_package_id) do
      [{work_package_id, work_package}]
    else
      []
    end
  end

  defp preloaded_work_package(_context, _allowed_ids), do: []

  defp preloaded_activity_contexts(work_package_ids, contexts) when is_map(contexts) do
    allowed_ids = MapSet.new(work_package_ids)

    contexts
    |> Enum.flat_map(&preloaded_activity_context(&1, allowed_ids))
    |> Map.new()
  end

  defp preloaded_activity_context({work_package_id, context}, allowed_ids) when is_map(context) do
    case {MapSet.member?(allowed_ids, work_package_id), preloaded_activity_context(context)} do
      {true, {:ok, activity_context}} -> [{work_package_id, activity_context}]
      _missing -> []
    end
  end

  defp preloaded_activity_context(_context, _allowed_ids), do: []

  defp preloaded_metadata_contexts(work_package_ids, contexts) when is_map(contexts) do
    allowed_ids = MapSet.new(work_package_ids)

    contexts
    |> Enum.flat_map(&preloaded_metadata_context(&1, allowed_ids))
    |> Map.new()
  end

  defp preloaded_metadata_context({work_package_id, context}, allowed_ids) when is_map(context) do
    case {MapSet.member?(allowed_ids, work_package_id), preloaded_metadata_context(context)} do
      {true, {:ok, metadata}} -> [{work_package_id, metadata}]
      _missing -> []
    end
  end

  defp preloaded_metadata_context(_context, _allowed_ids), do: []

  defp preloaded_metadata_context(%{metadata: metadata}) when is_map(metadata) and map_size(metadata) > 0 do
    {:ok, metadata}
  end

  defp preloaded_metadata_context(%{card: %{metadata: metadata}}) when is_map(metadata) and map_size(metadata) > 0 do
    {:ok, metadata}
  end

  defp preloaded_metadata_context(_context), do: :error

  defp preloaded_activity_context(%{blocker_state: blocker_state, runtime_state: runtime_state})
       when is_map(blocker_state) and is_map(runtime_state) do
    {:ok, %{blocker_state: blocker_state, runtime_state: runtime_state}}
  end

  defp preloaded_activity_context(%{card: %{operational_state: operational_state}}) when is_map(operational_state) do
    {:ok,
     %{
       blocker_state: %{active?: card_blocked?(operational_state), latest_gate_at: nil},
       runtime_state: %{active?: map_value(operational_state, "has_active_worker") == true, latest_gate_at: nil}
     }}
  end

  defp preloaded_activity_context(_context), do: :error

  defp card_blocked?(operational_state) do
    operational_state
    |> map_value("attention_items")
    |> List.wrap()
    |> Enum.any?(&(is_map(&1) and map_value(&1, "key") == "active_blocker"))
  end

  defp missing_ids(work_package_ids, preloaded_by_id) do
    Enum.reject(work_package_ids, &Map.has_key?(preloaded_by_id, &1))
  end

  defp progress_events_by_work_package_id(_repo, []), do: %{}

  defp progress_events_by_work_package_id(repo, work_package_ids) do
    work_package_ids
    |> context_lookup_chunks()
    |> Enum.flat_map(fn work_package_id_chunk ->
      repo.all(
        from(progress_event in ProgressEvent,
          where: progress_event.work_package_id in ^work_package_id_chunk,
          order_by: [asc: progress_event.work_package_id, asc: progress_event.sequence, asc: progress_event.created_at, asc: progress_event.id]
        )
      )
    end)
    |> Enum.group_by(& &1.work_package_id)
  end

  defp activity_contexts_by_id(_repo, []), do: %{}

  defp activity_contexts_by_id(repo, work_package_ids) do
    work_package_ids
    |> context_lookup_chunks()
    |> Enum.map(&WorkPackageActivity.contexts(repo, &1))
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  defp project_slice(%PlannedSlice{} = planned_slice, deliveries_by_slice_id, slices_by_scope, context, opts) do
    delivery = delivery_for_slice(deliveries_by_slice_id, planned_slice)
    work_package = slice_work_package_summary(planned_slice.work_package_id, context, opts)
    operational_work_package = work_package || hidden_work_package_marker(planned_slice, delivery, context)
    operational_state = operational_state(planned_slice, delivery, operational_work_package)

    if Keyword.get(opts, :slice_projection) == :operational_state do
      operational_slice(planned_slice, delivery, operational_state)
    else
      successor = successor_context(delivery, slices_by_scope, context)

      full_slice(planned_slice, delivery, context, work_package, successor, operational_state)
    end
  end

  defp operational_slice(%PlannedSlice{} = planned_slice, delivery, operational_state) do
    %{
      id: planned_slice.id,
      work_request_id: planned_slice.work_request_id,
      raw_status: planned_slice.status,
      delivery_outcome: delivery && delivery.outcome,
      operational_state: operational_state,
      attention_reason_codes: Map.fetch!(operational_state, :attention_reason_codes)
    }
  end

  defp full_slice(%PlannedSlice{} = planned_slice, delivery, context, work_package, successor, operational_state) do
    %{
      id: planned_slice.id,
      work_request_id: planned_slice.work_request_id,
      sequence: planned_slice.sequence,
      title: planned_slice.title,
      raw_status: planned_slice.status,
      delivery_outcome: delivery && delivery.outcome,
      delivery: delivery_summary(delivery, context),
      work_package: work_package,
      work_package_hidden?: hidden_work_package?(planned_slice.work_package_id, context),
      work_package_ambiguous?: visible_ambiguous_work_package?(planned_slice.work_package_id, context),
      successor: successor,
      operational_state: operational_state,
      attention_reason_codes: Map.fetch!(operational_state, :attention_reason_codes)
    }
  end

  defp slice_work_package_summary(work_package_id, context, opts) do
    if Keyword.get(opts, :slice_projection) == :operational_state do
      operational_work_package_summary(work_package_id, context)
    else
      work_package_summary(work_package_id, context)
    end
  end

  defp operational_work_package_summary(nil, _context), do: nil
  defp operational_work_package_summary("", _context), do: nil

  defp operational_work_package_summary(work_package_id, context) do
    if ambiguous_work_package?(work_package_id, context) do
      nil
    else
      visible_operational_work_package_summary(work_package_id, context)
    end
  end

  defp visible_operational_work_package_summary(work_package_id, context) do
    case get_in(context, [:work_packages, work_package_id]) do
      %WorkPackage{} = work_package ->
        events = Map.get(context.progress_events, work_package_id, [])
        activity = Map.get(context.activity_contexts, work_package_id, WorkPackageActivity.empty_context())
        metadata = Map.get(context.metadata_contexts, work_package_id) || metadata_from_progress_events(events)

        %{
          raw_status: work_package.status,
          merge_required: merge_required?(work_package),
          pr_required: pr_required?(work_package),
          pr: pr_summary(map_value(metadata, "pr")),
          blocker_state: Map.fetch!(activity, :blocker_state),
          runtime_state: Map.fetch!(activity, :runtime_state)
        }

      _missing ->
        nil
    end
  end

  defp delivery_summary(nil, _context), do: nil

  defp delivery_summary(%PlannedSliceDelivery{} = delivery, context) do
    %{
      id: delivery.id,
      outcome: delivery.outcome,
      recorded_by: delivery.recorded_by,
      recorded_at: delivery.recorded_at,
      pr_url: delivery.pr_url,
      pr_number: delivery.pr_number,
      pr_repository: delivery.pr_repository,
      pr_merged_at: delivery.pr_merged_at,
      merge_commit_sha: delivery.merge_commit_sha,
      no_pr_evidence: bounded_string(delivery.no_pr_evidence),
      successor_planned_slice_id: delivery.successor_planned_slice_id,
      successor_work_package_id: visible_work_package_id(delivery.successor_work_package_id, context),
      superseded_reason: bounded_string(delivery.superseded_reason),
      abandoned_rationale: bounded_string(delivery.abandoned_rationale)
    }
  end

  defp work_package_summary(nil, _context), do: nil
  defp work_package_summary("", _context), do: nil

  defp work_package_summary(work_package_id, context) do
    if ambiguous_work_package?(work_package_id, context) do
      nil
    else
      visible_work_package_summary(work_package_id, context)
    end
  end

  defp visible_work_package_summary(work_package_id, context) do
    case get_in(context, [:work_packages, work_package_id]) do
      %WorkPackage{} = work_package ->
        events = Map.get(context.progress_events, work_package_id, [])
        activity = Map.get(context.activity_contexts, work_package_id, WorkPackageActivity.empty_context())
        metadata = Map.get(context.metadata_contexts, work_package_id) || metadata_from_progress_events(events)

        %{
          id: work_package.id,
          title: work_package.title,
          kind: work_package.kind,
          repo: work_package.repo,
          base_branch: work_package.base_branch,
          branch_pattern: work_package.branch_pattern,
          raw_status: work_package.status,
          status: work_package.status,
          merge_required: merge_required?(work_package),
          pr_required: pr_required?(work_package),
          branch: branch_summary(map_value(metadata, "branch")),
          pr: pr_summary(map_value(metadata, "pr")),
          review: review_summary(metadata),
          blocker_state: Map.fetch!(activity, :blocker_state),
          runtime_state: Map.fetch!(activity, :runtime_state)
        }

      _missing ->
        nil
    end
  end

  defp metadata_from_progress_events(events) do
    %{
      branch: latest_payload(events, "branch", "attach_branch"),
      pr: latest_pr_payload(events),
      review_package: latest_payload(events, "review_package", "submit_review_package"),
      review_completion: latest_payload(events, "review_completion", "complete_review")
    }
  end

  defp review_summary(metadata) do
    %{
      package: review_package_summary(map_value(metadata, "review_package")),
      completion: review_completion_summary(map_value(metadata, "review_completion"))
    }
  end

  defp branch_summary(nil), do: nil
  defp branch_summary(payload) when not is_map(payload), do: nil

  defp branch_summary(%{} = payload) do
    %{
      type: bounded_string(map_value(payload, "type")),
      source_tool: bounded_string(map_value(payload, "source_tool")),
      branch: bounded_string(map_value(payload, "branch")),
      head_sha: bounded_string(map_value(payload, "head_sha"))
    }
    |> reject_nil_values()
    |> non_empty_map()
  end

  defp pr_summary(nil), do: nil
  defp pr_summary(payload) when not is_map(payload), do: nil

  defp pr_summary(%{} = payload) do
    %{
      type: bounded_string(map_value(payload, "type")),
      source_tool: bounded_string(map_value(payload, "source_tool")),
      url: bounded_string(map_value(payload, "url")),
      pr_number: integer_value(first_map_value(payload, ["pr_number", "number"])),
      pr_repository: bounded_string(first_map_value(payload, ["pr_repository", "repository"])),
      head_sha: bounded_string(map_value(payload, "head_sha")),
      current_head_sha: bounded_string(map_value(payload, "current_head_sha")),
      base_ref: bounded_string(map_value(payload, "base_ref")),
      head_ref: bounded_string(map_value(payload, "head_ref")),
      merged: boolean_or_bounded_string(map_value(payload, "merged")),
      state: bounded_string(map_value(payload, "state")),
      status: bounded_string(map_value(payload, "status")),
      conclusion: bounded_string(map_value(payload, "conclusion")),
      stale: boolean_or_bounded_string(map_value(payload, "stale")),
      merge_state: merge_state_summary(map_value(payload, "merge_state"))
    }
    |> reject_nil_values()
    |> non_empty_map()
  end

  defp merge_state_summary(%{} = merge_state) do
    %{
      merged: boolean_or_bounded_string(map_value(merge_state, "merged")),
      state: bounded_string(map_value(merge_state, "state")),
      status: bounded_string(map_value(merge_state, "status")),
      mergeable_state: bounded_string(map_value(merge_state, "mergeable_state"))
    }
    |> reject_nil_values()
    |> non_empty_map()
  end

  defp merge_state_summary(_merge_state), do: nil

  defp review_completion_summary(nil), do: nil
  defp review_completion_summary(payload) when not is_map(payload), do: nil

  defp review_completion_summary(%{} = payload) do
    %{
      type: bounded_string(map_value(payload, "type")),
      source_tool: bounded_string(map_value(payload, "source_tool")),
      work_package_id: bounded_string(map_value(payload, "work_package_id")),
      head_sha: bounded_string(map_value(payload, "head_sha")),
      review_type: payload |> map_value("review") |> map_value("type") |> bounded_string(),
      reference: bounded_string(map_value(payload, "reference")),
      note: bounded_string(map_value(payload, "note"))
    }
    |> reject_nil_values()
    |> non_empty_map()
  end

  defp review_package_summary(nil), do: nil
  defp review_package_summary(payload) when not is_map(payload), do: nil

  defp review_package_summary(%{} = payload) do
    %{
      type: bounded_string(map_value(payload, "type")),
      source_tool: bounded_string(map_value(payload, "source_tool")),
      head_sha: bounded_string(map_value(payload, "head_sha")),
      artifacts: bounded_string_list(map_value(payload, "artifacts"), @review_package_artifact_limit),
      acceptance_criteria_met: boolean_value(map_value(payload, "acceptance_criteria_met")),
      tests_passed: boolean_value(map_value(payload, "tests_passed"))
    }
    |> reject_nil_values()
  end

  defp successor_context(nil, _slices_by_scope, _context), do: nil

  defp successor_context(%PlannedSliceDelivery{outcome: "superseded"} = delivery, slices_by_scope, context) do
    successor_slice = Map.get(slices_by_scope, {delivery.work_request_id, delivery.successor_planned_slice_id})

    successor_work_package_id =
      delivery.successor_work_package_id || (successor_slice && successor_slice.work_package_id)

    %{
      planned_slice_id: delivery.successor_planned_slice_id,
      work_package_id: visible_work_package_id(successor_work_package_id, context),
      planned_slice: successor_slice_summary(successor_slice, context),
      work_package: work_package_summary(successor_work_package_id, context)
    }
  end

  defp successor_context(%PlannedSliceDelivery{}, _slices_by_scope, _context), do: nil

  defp successor_slice_summary(nil, _context), do: nil

  defp successor_slice_summary(%PlannedSlice{} = planned_slice, context) do
    %{
      id: planned_slice.id,
      sequence: planned_slice.sequence,
      title: planned_slice.title,
      raw_status: planned_slice.status,
      work_package_id: visible_work_package_id(planned_slice.work_package_id, context)
    }
  end

  defp operational_state(%PlannedSlice{} = planned_slice, %PlannedSliceDelivery{} = delivery, work_package) do
    {key, label, tone, reason} = Map.fetch!(@delivery_states, delivery.outcome)
    codes = terminal_delivery_attention_codes(delivery, work_package)

    state(key, label, tone, reason, planned_slice.status, delivery.outcome, work_package, codes)
  end

  defp operational_state(%PlannedSlice{} = planned_slice, nil, work_package) do
    no_delivery_operational_state(planned_slice, work_package)
  end

  defp hidden_work_package_marker(%PlannedSlice{} = planned_slice, _delivery, context) do
    cond do
      hidden_work_package?(planned_slice.work_package_id, context) -> :hidden
      ambiguous_work_package?(planned_slice.work_package_id, context) -> :ambiguous
      true -> nil
    end
  end

  defp no_delivery_operational_state(%PlannedSlice{status: "planned"} = planned_slice, nil) do
    state("planned", "Planned", "neutral", "Slice is planned and has no linked WorkPackage.", planned_slice.status, nil, nil, [])
  end

  defp no_delivery_operational_state(%PlannedSlice{status: "approved"} = planned_slice, nil) do
    state("ready_for_worker", "Ready", "neutral", "Approved slice has no linked package.", planned_slice.status, nil, nil, [])
  end

  defp no_delivery_operational_state(%PlannedSlice{status: "skipped"} = planned_slice, nil) do
    state("skipped", "Skipped", "neutral", "Slice was skipped before dispatch.", planned_slice.status, nil, nil, [])
  end

  defp no_delivery_operational_state(%PlannedSlice{} = planned_slice, :hidden) do
    state(
      "dispatched",
      "Dispatched",
      "neutral",
      "Slice is dispatched to a linked WorkPackage hidden by the current scope.",
      planned_slice.status,
      nil,
      nil,
      []
    )
  end

  defp no_delivery_operational_state(%PlannedSlice{} = planned_slice, :ambiguous) do
    state(
      "needs_repair",
      "Needs Repair",
      "warning",
      "Multiple planned slices point at the same WorkPackage.",
      planned_slice.status,
      nil,
      nil,
      ["ambiguous_linked_work_package"]
    )
  end

  defp no_delivery_operational_state(%PlannedSlice{} = planned_slice, nil) do
    state(
      "dispatched",
      "Dispatched",
      "warning",
      "Slice is marked dispatched but no linked WorkPackage or delivery outcome exists.",
      planned_slice.status,
      nil,
      nil,
      ["missing_linked_work_package"]
    )
  end

  defp no_delivery_operational_state(%PlannedSlice{} = planned_slice, work_package) when is_map(work_package) do
    {key, label, tone, reason, codes} = no_delivery_work_package_state(work_package)
    state(key, label, tone, reason, planned_slice.status, nil, work_package, codes)
  end

  defp no_delivery_work_package_state(work_package) do
    cond do
      pr_merged?(work_package.pr) ->
        {
          "needs_closeout",
          "Needs Closeout",
          "warning",
          "Merged PR needs delivery closeout.",
          ["pr_merged_without_delivery_outcome"]
        }

      terminal_package_status?(work_package.raw_status) ->
        {
          "needs_closeout",
          "Needs Closeout",
          "warning",
          "Terminal package needs delivery closeout.",
          ["terminal_package_without_delivery_outcome"]
        }

      true ->
        active_work_package_state(work_package)
    end
  end

  defp active_work_package_state(work_package) do
    cond do
      active_blocker?(work_package) ->
        {"blocked", "Blocked", "critical", "Active blocker.", ["active_blocker"]}

      active_runtime?(work_package) ->
        {"active", "Active", "info", "Worker activity is current.", ["active_runtime"]}

      true ->
        status_work_package_state(work_package)
    end
  end

  defp status_work_package_state(%{raw_status: raw_status, merge_required: true}) when raw_status in @ready_statuses do
    {"merge_ready", "Ready", "success", "Ready for merge.", []}
  end

  defp status_work_package_state(%{raw_status: raw_status}) when raw_status in @ready_statuses do
    {"ready_to_finish", "Ready To Finish", "success", "Ready to finish with closeout evidence.", []}
  end

  defp status_work_package_state(%{raw_status: "reviewing"}) do
    {"reviewing", "Reviewing", "info", "Review in progress.", []}
  end

  defp status_work_package_state(%{raw_status: "ci_waiting"}) do
    {"ci_waiting", "Validating", "info", "Waiting on validation.", []}
  end

  defp status_work_package_state(%{raw_status: "ready_for_worker"}) do
    {"ready_for_worker", "Ready", "neutral", "Ready for worker pickup.", []}
  end

  defp status_work_package_state(work_package) do
    key = work_package.raw_status || "unknown"
    {key, status_label(key), "neutral", "Package status: #{key}.", []}
  end

  defp terminal_delivery_attention_codes(%PlannedSliceDelivery{} = delivery, work_package) do
    [
      if(work_package == :ambiguous, do: "ambiguous_linked_work_package"),
      if(work_package && active_blocker?(work_package), do: "linked_package_blocked_after_delivery"),
      if(work_package && active_runtime?(work_package), do: "linked_package_active_after_delivery"),
      if(is_map(work_package) and not package_reconciled_with_delivery?(work_package.raw_status, delivery.outcome),
        do: "linked_package_status_stale_after_delivery"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp package_reconciled_with_delivery?(status, outcome) do
    is_nil(PlannedSliceDelivery.terminal_status_for_outcome(outcome)) or
      PlannedSliceDelivery.terminal_status_matches_outcome?(status, outcome)
  end

  defp state(key, label, tone, reason, raw_status, delivery_outcome, work_package, attention_reason_codes) do
    work_package = if is_map(work_package), do: work_package

    %{
      key: key,
      label: label,
      tone: tone,
      reason: reason,
      raw_status: raw_status,
      delivery_outcome: delivery_outcome,
      work_package_status: work_package && work_package.raw_status,
      merge_required: work_package && Map.get(work_package, :merge_required),
      pr_required: work_package && Map.get(work_package, :pr_required),
      attention_reason_codes: attention_reason_codes,
      attention_items: Enum.map(attention_reason_codes, &attention_item/1)
    }
  end

  defp attention_item(code) do
    {label, tone, reason} = Map.get(@attention_details, code, {status_label(code), "warning", "Delivery-board attention code #{code}."})

    %{
      key: code,
      label: label,
      tone: tone,
      reason: reason
    }
  end

  defp active_blocker?(work_package) when is_map(work_package), do: get_in(work_package, [:blocker_state, :active?]) == true
  defp active_blocker?(_work_package), do: false

  defp active_runtime?(work_package) when is_map(work_package), do: get_in(work_package, [:runtime_state, :active?]) == true
  defp active_runtime?(_work_package), do: false

  defp terminal_package_status?(status), do: status in @terminal_package_statuses

  defp merge_required?(%WorkPackage{} = work_package) do
    case LifecycleService.policy_for(work_package) do
      {:ok, policy} ->
        required_gates = Map.get(policy, :required_gates, [])
        "human_merge" in required_gates or "architect_merge" in required_gates

      {:error, _reason} ->
        work_package.kind in @runtime_merge_required_kinds
    end
  end

  defp pr_required?(%WorkPackage{} = work_package) do
    case LifecycleService.policy_for(work_package) do
      {:ok, policy} -> "human_merge" in Map.get(policy, :required_gates, [])
      {:error, _reason} -> work_package.kind in @runtime_merge_required_kinds
    end
  end

  defp latest_pr_payload(events) do
    latest_payload(events, "pr", ["attach_pr", "sync_pr"])
  end

  defp latest_payload(events, type, source_tool) do
    events
    |> Enum.reverse()
    |> Enum.find(&payload_matches?(&1, type, source_tool))
    |> case do
      %ProgressEvent{payload: payload} -> payload || %{}
      nil -> nil
    end
  end

  defp payload_matches?(%ProgressEvent{payload: payload}, type, source_tool) when is_map(payload) do
    map_value(payload, "type") == type and source_tool_matches?(map_value(payload, "source_tool"), source_tool)
  end

  defp payload_matches?(%ProgressEvent{}, _type, _source_tool), do: false

  defp source_tool_matches?(_value, nil), do: true
  defp source_tool_matches?(value, expected) when is_list(expected), do: value in expected
  defp source_tool_matches?(value, expected), do: value == expected

  defp pr_merged?(%{} = pr), do: PullRequestProgress.merged?(pr)
  defp pr_merged?(_pr), do: false

  defp state_counts(slices) do
    Enum.frequencies_by(slices, &get_in(&1, [:operational_state, :key]))
  end

  defp visible_work_package_id(nil, _context), do: nil
  defp visible_work_package_id("", _context), do: nil

  defp visible_work_package_id(work_package_id, context) do
    if hidden_work_package?(work_package_id, context) or ambiguous_work_package?(work_package_id, context) do
      nil
    else
      work_package_id
    end
  end

  defp hidden_work_package?(work_package_id, context) when is_binary(work_package_id) do
    MapSet.member?(Map.fetch!(context, :hidden_work_package_ids), work_package_id)
  end

  defp hidden_work_package?(_work_package_id, _context), do: false

  defp ambiguous_work_package?(work_package_id, context) when is_binary(work_package_id) do
    MapSet.member?(Map.fetch!(context, :ambiguous_work_package_ids), work_package_id)
  end

  defp ambiguous_work_package?(_work_package_id, _context), do: false

  defp visible_ambiguous_work_package?(work_package_id, context) when is_binary(work_package_id) do
    ambiguous_work_package?(work_package_id, context) and not hidden_work_package?(work_package_id, context)
  end

  defp visible_ambiguous_work_package?(_work_package_id, _context), do: false

  defp status_label(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp status_label(_value), do: "Unknown"

  defp bounded_string(value, limit \\ @review_package_string_limit)

  defp bounded_string(value, limit) when is_binary(value) and is_integer(limit) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, limit)
    end
  end

  defp bounded_string(_value, _limit), do: nil

  defp bounded_string_list(values, limit) when is_list(values) and is_integer(limit) do
    values
    |> Enum.flat_map(fn value ->
      case bounded_string(value) do
        nil -> []
        string -> [string]
      end
    end)
    |> Enum.take(limit)
  end

  defp bounded_string_list(_values, _limit), do: nil

  defp boolean_value(value) when is_boolean(value), do: value
  defp boolean_value(_value), do: nil

  defp boolean_or_bounded_string(value) when is_boolean(value), do: value
  defp boolean_or_bounded_string(value), do: bounded_string(value)

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: nil

  defp first_map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &map_value(map, &1))
  end

  defp reject_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp non_empty_map(map) when is_map(map) do
    if map_size(map) == 0, do: nil, else: map
  end

  defp map_value(%{} = map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> atom_map_value(map, key)
    end
  end

  defp map_value(_value, _key), do: nil

  defp atom_map_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    _error in ArgumentError -> nil
  end

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)

    if String.contains?(String.downcase(message), "busy") or String.contains?(String.downcase(message), "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end
end
