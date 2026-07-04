defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.WorkRequestCards do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.{
    CommentProjection,
    DeliverySliceProjection,
    OperationalProjection,
    Sanitizer
  }

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Completion, as: WorkRequestCompletion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @work_request_slice_state_priority [
    "blocked",
    "active",
    "needs_attention",
    "started_paused",
    "reviewing",
    "ci_waiting",
    "merge_ready",
    "ready_to_finish",
    "ready_for_merge",
    "ready_for_human_merge",
    "merging",
    "needs_closeout",
    "prepared",
    "ready_for_worker",
    "planned",
    "merged",
    "delivered",
    "completed_no_pr",
    "closed",
    "superseded",
    "abandoned",
    "skipped"
  ]
  @delivery_promotion_blocking_work_request_statuses ["human_info_needed", "ready_for_clarification", "clarifying"]
  @work_request_count_chunk_size 500

  @type repo :: module()
  @type dashboard_error :: Dashboard.dashboard_error()

  @spec cards(repo(), [WorkRequest.t()], keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def cards(repo, work_requests, opts) do
    with {:ok, summaries} <- card_summaries(repo, work_requests, opts) do
      repo_identity_catalog = Dashboard.repo_identity_catalog_from_opts(opts, Enum.map(work_requests, & &1.repo))
      {:ok, Enum.map(work_requests, &card(&1, summaries, repo_identity_catalog))}
    end
  end

  @spec visible_cards([map()]) :: [map()]
  def visible_cards(cards), do: Enum.reject(cards, &(not is_nil(&1.archived_at)))

  @spec ordered_work_requests([WorkRequest.t()]) :: [WorkRequest.t()]
  def ordered_work_requests(work_requests) do
    Enum.sort_by(work_requests, fn %WorkRequest{} = work_request ->
      {sortable_timestamp(work_request.inserted_at), work_request.id || ""}
    end)
  end

  @spec visible_planned_slices([PlannedSlice.t()], map() | nil) :: [PlannedSlice.t()]
  def visible_planned_slices(planned_slices, nil), do: planned_slices

  def visible_planned_slices(planned_slices, delivery_board) do
    visible_by_id = DeliverySliceProjection.slices_by_id(delivery_board)

    Enum.filter(planned_slices, &Map.has_key?(visible_by_id, &1.id))
  end

  @spec work_request_payload(
          WorkRequest.t(),
          [ClarificationQuestion.t()],
          [PlannedSlice.t()],
          map(),
          map(),
          map(),
          keyword()
        ) :: map()
  def work_request_payload(
        %WorkRequest{} = work_request,
        questions,
        planned_slices,
        work_package_contexts,
        repo_identity_catalog,
        comment_context,
        opts
      ) do
    question_state = %{
      open_count: Enum.count(questions, &(&1.status == "open")),
      latest_gate_at: latest_datetime(Enum.map(questions, & &1.updated_at))
    }

    completion_state =
      work_request
      |> WorkRequestCompletion.visible_state(
        question_state,
        planned_slices,
        work_package_contexts,
        completion_deliveries_by_slice_id(Keyword.get(opts, :delivery_board))
      )

    work_request
    |> base_payload(repo_identity_catalog)
    |> Map.put(:completed_at, timestamp(completion_state.completed_at))
    |> Map.put(:completion_source, work_request.completion_source)
    |> Map.put(:archived_at, timestamp(completion_state.archived_at))
    |> Map.put(:archive_reason, work_request.archive_reason)
    |> Map.put(
      :operational_state,
      operational_state(
        work_request,
        planned_slices,
        work_package_contexts,
        completion_state,
        Keyword.get(opts, :delivery_board),
        Keyword.get(opts, :delivery_state_opts, [])
      )
    )
    |> CommentProjection.put_counts(
      CommentProjection.work_request_counts(
        comment_context,
        work_request,
        Keyword.get(opts, :comment_planned_slices, planned_slices)
      )
    )
  end

  defp card_summaries(_repo, [], _opts), do: {:ok, %{}}

  defp card_summaries(repo, work_requests, opts) do
    work_request_ids = Enum.map(work_requests, & &1.id)

    with {:ok, question_context} <- question_context(repo, work_request_ids),
         {:ok, decision_counts} <- decision_counts(repo, work_request_ids),
         {:ok, planned_slices} <- planned_slices(repo, work_request_ids),
         {:ok, comment_context} <- card_comment_context(repo, work_requests, planned_slices),
         {:ok, work_package_contexts} <- card_work_package_contexts(repo, planned_slices, opts) do
      question_counts = question_context.counts
      planned_slices_by_request = Enum.group_by(planned_slices, & &1.work_request_id)

      with {:ok, delivery_boards} <-
             card_delivery_boards(repo, work_requests, planned_slices_by_request, work_package_contexts) do
        delivery_state_opts = delivery_state_opts(opts)

        card_summaries(
          work_requests,
          question_counts,
          question_context.states,
          decision_counts,
          planned_slices_by_request,
          comment_context,
          work_package_contexts,
          %{boards: delivery_boards, state_opts: delivery_state_opts}
        )
      end
    end
  end

  defp card_summaries(
         work_requests,
         question_counts,
         question_states,
         decision_counts,
         planned_slices_by_request,
         comment_context,
         work_package_contexts,
         delivery_context
       ) do
    delivery_boards = Map.fetch!(delivery_context, :boards)
    delivery_state_opts = Map.fetch!(delivery_context, :state_opts)

    visible_planned_slices_by_request =
      visible_planned_slices_by_request(work_requests, planned_slices_by_request, delivery_boards)

    planned_slice_counts =
      visible_planned_slices_by_request
      |> Map.values()
      |> Enum.flat_map(& &1)
      |> Enum.map(&{&1.work_request_id, &1.status})
      |> status_counts()

    summaries =
      Map.new(work_requests, fn %WorkRequest{} = work_request ->
        planned_slices = Map.get(visible_planned_slices_by_request, work_request.id, [])
        all_planned_slices = Map.get(planned_slices_by_request, work_request.id, [])
        comment_counts = CommentProjection.work_request_counts(comment_context, work_request, all_planned_slices)
        open_question_count = status_count(question_counts, work_request.id, "open")

        question_state =
          Map.get(question_states, work_request.id, %{
            open_count: open_question_count,
            latest_gate_at: nil
          })

        completion_state =
          work_request
          |> WorkRequestCompletion.visible_state(
            question_state,
            planned_slices,
            work_package_contexts,
            completion_deliveries_by_slice_id(Map.get(delivery_boards, work_request.id))
          )

        operational_state =
          operational_state(
            work_request,
            planned_slices,
            work_package_contexts,
            completion_state,
            Map.get(delivery_boards, work_request.id),
            delivery_state_opts
          )

        {work_request.id,
         %{
           open_question_count: open_question_count,
           answered_question_count: status_count(question_counts, work_request.id, "answered"),
           closed_question_count: status_count(question_counts, work_request.id, "closed"),
           decision_count: Map.get(decision_counts, work_request.id, 0),
           comment_count: comment_counts.comment_count,
           open_comment_count: comment_counts.open_comment_count,
           planned_slice_count: status_count(planned_slice_counts, work_request.id, "planned"),
           approved_slice_count: status_count(planned_slice_counts, work_request.id, "approved"),
           dispatched_slice_count: status_count(planned_slice_counts, work_request.id, "dispatched"),
           skipped_slice_count: status_count(planned_slice_counts, work_request.id, "skipped"),
           completed_at: timestamp(completion_state.completed_at),
           completion_source: work_request.completion_source,
           archived_at: timestamp(completion_state.archived_at),
           operational_state: operational_state
         }}
      end)

    {:ok, summaries}
  end

  defp card_delivery_boards(repo, work_requests, planned_slices_by_request, work_package_contexts) do
    DeliveryBoard.project_many(
      repo,
      work_requests,
      planned_slices_by_request,
      delivery_board_card_opts(work_package_contexts)
    )
  end

  defp delivery_board_card_opts(work_package_contexts) do
    [
      slice_projection: :operational_state,
      visible_work_package_ids: Map.keys(work_package_contexts),
      work_package_contexts: work_package_contexts
    ]
  end

  defp delivery_state_opts(opts) do
    case Keyword.get(opts, :grant) do
      %AccessGrant{} -> [include_package_fields?: false]
      _other -> []
    end
  end

  defp card_work_package_contexts(repo, planned_slices, opts) do
    case Keyword.get(opts, :grant) do
      %AccessGrant{} = grant -> planned_slice_work_package_contexts_for_grant(repo, planned_slices, grant)
      _grant -> Dashboard.planned_slice_work_package_contexts(repo, planned_slices)
    end
  end

  defp planned_slice_work_package_contexts_for_grant(repo, planned_slices, %AccessGrant{} = grant) do
    with {:ok, filters} <- Dashboard.work_request_filters_for_grant(repo, grant),
         {:ok, work_package_contexts} <- Dashboard.planned_slice_work_package_contexts(repo, planned_slices) do
      {:ok,
       Map.filter(work_package_contexts, fn
         {_work_package_id, %{work_package: %WorkPackage{} = work_package}} ->
           Dashboard.phase_work_package_matches_filters?(work_package, filters)

         _context ->
           false
       end)}
    end
  end

  defp card_comment_context(repo, work_requests, planned_slices) do
    targets =
      Enum.map(work_requests, &{"work_request", &1.id}) ++
        Enum.map(planned_slices, &{"planned_slice", &1.id})

    Dashboard.comment_count_context(repo, targets)
  end

  defp visible_planned_slices_by_request(work_requests, planned_slices_by_request, delivery_boards) do
    Map.new(work_requests, fn %WorkRequest{} = work_request ->
      planned_slices = Map.get(planned_slices_by_request, work_request.id, [])
      delivery_board = Map.get(delivery_boards, work_request.id)

      {work_request.id, visible_planned_slices(planned_slices, delivery_board)}
    end)
  end

  defp completion_deliveries_by_slice_id(delivery_board) do
    delivery_board
    |> DeliverySliceProjection.slices_by_id()
    |> Enum.flat_map(fn {slice_id, delivery_slice} ->
      case completion_delivery_outcome(delivery_slice) do
        outcome when is_binary(outcome) and outcome != "" -> [{slice_id, %{outcome: outcome}}]
        _outcome -> []
      end
    end)
    |> Map.new()
  end

  defp completion_delivery_outcome(%{} = delivery_slice) do
    map_value(delivery_slice, "delivery_outcome") ||
      case map_value(delivery_slice, "delivery") do
        %{} = delivery -> map_value(delivery, "outcome")
        _delivery -> nil
      end
  end

  defp completion_delivery_outcome(_delivery_slice), do: nil

  defp question_context(repo, work_request_ids) do
    rows =
      chunked_work_request_rows(work_request_ids, fn chunk ->
        from(question in ClarificationQuestion,
          where: question.work_request_id in ^chunk,
          select: {question.work_request_id, question.status, question.updated_at}
        )
        |> repo.all()
      end)

    counts =
      rows
      |> Enum.map(fn {work_request_id, status, _updated_at} -> {work_request_id, status} end)
      |> status_counts()

    states =
      rows
      |> Enum.group_by(fn {work_request_id, _status, _updated_at} -> work_request_id end)
      |> Map.new(fn {work_request_id, questions} ->
        {work_request_id,
         %{
           open_count: Enum.count(questions, fn {_work_request_id, status, _updated_at} -> status == "open" end),
           latest_gate_at: latest_datetime(Enum.map(questions, fn {_work_request_id, _status, updated_at} -> updated_at end))
         }}
      end)

    {:ok, %{counts: counts, states: states}}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp decision_counts(repo, work_request_ids) do
    rows =
      chunked_work_request_rows(work_request_ids, fn chunk ->
        from(decision in DecisionLogEntry,
          where: decision.work_request_id in ^chunk,
          select: decision.work_request_id
        )
        |> repo.all()
      end)

    {:ok, Enum.frequencies(rows)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp planned_slices(repo, work_request_ids) do
    rows =
      chunked_work_request_rows(work_request_ids, fn chunk ->
        from(planned_slice in PlannedSlice,
          where: planned_slice.work_request_id in ^chunk,
          order_by: [asc: planned_slice.work_request_id, asc: planned_slice.sequence, asc: planned_slice.inserted_at]
        )
        |> repo.all()
      end)

    {:ok, rows}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp chunked_work_request_rows(work_request_ids, fetch_chunk) do
    work_request_ids
    |> Enum.chunk_every(@work_request_count_chunk_size)
    |> Enum.flat_map(fetch_chunk)
  end

  defp status_counts(rows) do
    Enum.reduce(rows, %{}, fn {work_request_id, status}, counts ->
      Map.update(counts, work_request_id, %{status => 1}, &Map.update(&1, status, 1, fn count -> count + 1 end))
    end)
  end

  defp status_count(counts, work_request_id, status) do
    counts
    |> Map.get(work_request_id, %{})
    |> Map.get(status, 0)
  end

  defp card(%WorkRequest{} = work_request, summaries, repo_identity_catalog) do
    Map.merge(Map.fetch!(summaries, work_request.id), %{
      id: work_request.id,
      title: redacted_text(work_request.title),
      repo: work_request.repo,
      base_branch: work_request.base_branch,
      work_type: work_request.work_type,
      desired_dispatch_shape: work_request.desired_dispatch_shape,
      creator: creator(work_request),
      status: work_request.status,
      inserted_at: timestamp(work_request.inserted_at),
      updated_at: timestamp(work_request.updated_at)
    })
    |> put_repo_identity_fields(repo_identity_catalog, work_request.repo)
  end

  defp base_payload(%WorkRequest{} = work_request, repo_identity_catalog) do
    %{
      id: work_request.id,
      title: redacted_text(work_request.title),
      repo: work_request.repo,
      base_branch: work_request.base_branch,
      work_type: work_request.work_type,
      human_description: redacted_text(work_request.human_description),
      constraints: redacted_json(work_request.constraints || %{}),
      desired_dispatch_shape: work_request.desired_dispatch_shape,
      creator: creator(work_request),
      status: work_request.status,
      inserted_at: timestamp(work_request.inserted_at),
      updated_at: timestamp(work_request.updated_at)
    }
    |> put_repo_identity_fields(repo_identity_catalog, work_request.repo)
  end

  defp creator(%WorkRequest{} = work_request) do
    %{
      kind: work_request.creator_kind,
      name: redacted_text(work_request.creator_name),
      via: work_request.created_via
    }
  end

  defp operational_state(
         %WorkRequest{} = work_request,
         planned_slices,
         work_package_contexts,
         completion_state,
         delivery_board,
         delivery_state_opts
       ) do
    slice_states =
      planned_slice_operational_states(planned_slices, work_package_contexts, delivery_board, delivery_state_opts)

    attention_items = aggregate_operational_attention(slice_states)
    promoted_state = primary_work_request_slice_state(slice_states)

    cond do
      completion_state.archived_at ->
        completed_operational_state(work_request, attention_items)

      operator_completed?(work_request, completion_state) ->
        completed_operational_state(work_request, attention_items)

      delivery_truth_operational_state?(promoted_state) ->
        promoted_operational_state(work_request, promoted_state, planned_slices, attention_items)
        |> DeliverySliceProjection.redact_reasons(delivery_state_opts)

      completion_state.completed? ->
        completed_operational_state(work_request, attention_items)

      work_request.status in @delivery_promotion_blocking_work_request_statuses ->
        base_operational_state(work_request.status, attention_items)

      promoted_state ->
        promoted_operational_state(work_request, promoted_state, planned_slices, attention_items)

      true ->
        base_operational_state(work_request.status, attention_items)
    end
  end

  defp operator_completed?(%WorkRequest{completion_source: "operator"}, %{completed?: true}), do: true
  defp operator_completed?(%WorkRequest{}, _completion_state), do: false

  defp completed_operational_state(%WorkRequest{completion_source: "operator"} = work_request, attention_items) do
    operational_state_map(
      "completed",
      "Completed",
      "success",
      "WorkRequest was manually marked completed by the local operator.",
      work_request.status,
      attention_items
    )
  end

  defp completed_operational_state(%WorkRequest{} = work_request, attention_items) do
    operational_state_map(
      "completed",
      "Completed",
      "success",
      "All WorkRequest questions, slices, linked packages, blockers, and active runtimes are terminal.",
      work_request.status,
      attention_items
    )
  end

  defp base_operational_state("human_info_needed" = status, attention_items) do
    operational_state_map(
      "human_info_needed",
      "Human Info Needed",
      "warning",
      "WorkRequest is waiting for a human answer before architecture can proceed.",
      status,
      attention_items
    )
  end

  defp base_operational_state("ready_for_clarification" = status, attention_items) do
    operational_state_map("clarifying", "Clarifying", "warning", "WorkRequest is still in clarification.", status, attention_items)
  end

  defp base_operational_state("clarifying" = status, attention_items) do
    operational_state_map("clarifying", "Clarifying", "warning", "WorkRequest is still in clarification.", status, attention_items)
  end

  defp base_operational_state("draft" = status, attention_items) do
    operational_state_map("not_started", "Not Started", "neutral", "WorkRequest is still a draft.", status, attention_items)
  end

  defp base_operational_state("ready_for_slicing" = status, attention_items) do
    operational_state_map(
      "ready_for_slicing",
      "Ready For Slicing",
      "neutral",
      "WorkRequest is ready for an architect to author planned slices.",
      status,
      attention_items
    )
  end

  defp base_operational_state("sliced" = status, attention_items) do
    operational_state_map("sliced", "Sliced", "neutral", "WorkRequest has been marked sliced.", status, attention_items)
  end

  defp base_operational_state(status, attention_items) do
    key = status || "unknown"
    operational_state_map(key, status_label(key), "neutral", "Raw WorkRequest lifecycle status is #{key}.", status, attention_items)
  end

  defp planned_slice_operational_states(planned_slices, work_package_contexts, delivery_board, delivery_state_opts) do
    delivery_slices_by_id = DeliverySliceProjection.slices_by_id(delivery_board)

    Enum.map(planned_slices, fn %PlannedSlice{} = planned_slice ->
      OperationalProjection.planned_slice_operational_state(
        planned_slice,
        Map.get(work_package_contexts, planned_slice.work_package_id),
        Map.get(delivery_slices_by_id, planned_slice.id),
        delivery_state_opts
      )
    end)
  end

  defp primary_work_request_slice_state([]), do: nil

  defp primary_work_request_slice_state(slice_states) do
    Enum.find_value(@work_request_slice_state_priority, fn key ->
      Enum.find(slice_states, &(Map.get(&1, :key) == key))
    end)
  end

  defp delivery_truth_operational_state?(%{key: "needs_closeout"}), do: true
  defp delivery_truth_operational_state?(%{delivery_outcome: outcome}) when is_binary(outcome), do: true
  defp delivery_truth_operational_state?(_state), do: false

  defp promoted_operational_state(%WorkRequest{} = work_request, promoted_state, planned_slices, attention_items) do
    promoted_state
    |> OperationalProjection.operational_activity_fields()
    |> Map.merge(
      operational_state_map(
        promoted_state.key,
        promoted_state.label,
        promoted_state.tone,
        "Most actionable planned-slice or linked-package state is #{promoted_state.label} across #{length(planned_slices)} slice(s).",
        work_request.status,
        attention_items
      )
    )
  end

  defp aggregate_operational_attention(operational_states) do
    operational_states
    |> Enum.flat_map(&Map.get(&1, :attention_items, []))
    |> Enum.uniq_by(&Map.get(&1, :key))
  end

  defp operational_state_map(key, label, tone, reason, raw_status, attention_items) do
    %{
      key: key,
      label: label,
      tone: tone,
      reason: reason,
      raw_status: raw_status,
      attention_items: attention_items
    }
  end

  defp put_repo_identity_fields(payload, repo_identity_catalog, repo_value) when is_map(payload) do
    Map.merge(payload, RepoIdentity.fields(repo_identity_catalog, repo_value))
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)

    if message |> String.downcase() |> busy_message?() do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end

  defp busy_message?(message) do
    String.contains?(message, "busy") or String.contains?(message, "locked")
  end

  defp latest_datetime(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp sortable_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp sortable_timestamp(_timestamp), do: ""

  defp status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp status_label(status), do: to_string(status)

  defp map_value(%{} = map, key) when is_binary(key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
  defp redacted_json(value), do: Sanitizer.redacted_json(value)
  defp redacted_text(value), do: Sanitizer.redacted_text(value)
  defp timestamp(value), do: Sanitizer.timestamp(value)
end
