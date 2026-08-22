defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.WorkRequestCards do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.{
    CommentProjection,
    DeliveryWorkPackageProjection,
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

  @spec priority_cards(repo(), [WorkRequest.t()], keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def priority_cards(repo, work_requests, opts) do
    work_request_ids = Enum.map(work_requests, & &1.id)

    with {:ok, question_context} <- question_context(repo, work_request_ids),
         {:ok, work_packages} <- work_packages(repo, work_request_ids),
         {:ok, comment_context} <- card_comment_context(repo, work_requests, work_packages) do
      work_packages_by_request = Enum.group_by(work_packages, & &1.work_request_id)
      work_package_counts = work_packages |> Enum.map(&{&1.work_request_id, &1.status}) |> status_counts()

      summaries =
        Map.new(work_requests, fn work_request ->
          request_work_packages = Map.get(work_packages_by_request, work_request.id, [])
          comment_counts = CommentProjection.work_request_counts(comment_context, work_request, request_work_packages)

          {work_request.id,
           Map.merge(comment_counts, %{
             open_question_count: status_count(question_context.counts, work_request.id, "open"),
             answered_question_count: status_count(question_context.counts, work_request.id, "answered"),
             work_package_count: length(request_work_packages),
             planned_work_package_count: Enum.count(request_work_packages, &(&1.status == "planned")),
             dispatched_work_package_count: Enum.count(request_work_packages, &(not is_nil(&1.dispatched_at))),
             skipped_work_package_count: status_count(work_package_counts, work_request.id, "skipped"),
             completed_at: timestamp(work_request.completed_at),
             completion_source: work_request.completion_source,
             archived_at: timestamp(work_request.archived_at),
             archive_reason: work_request.archive_reason
           })}
        end)

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

  @spec visible_work_packages([WorkPackage.t()], map() | nil) :: [WorkPackage.t()]
  def visible_work_packages(work_packages, nil), do: work_packages

  def visible_work_packages(work_packages, delivery_board) do
    visible_by_id = DeliveryWorkPackageProjection.work_packages_by_id(delivery_board)

    Enum.filter(work_packages, &Map.has_key?(visible_by_id, &1.id))
  end

  @spec work_request_payload(
          WorkRequest.t(),
          [ClarificationQuestion.t()],
          [WorkPackage.t()],
          map(),
          map(),
          map(),
          keyword()
        ) :: map()
  def work_request_payload(
        %WorkRequest{} = work_request,
        questions,
        work_packages,
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
        work_packages,
        work_package_contexts,
        completion_deliveries_by_work_package_id(Keyword.get(opts, :delivery_board))
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
        work_packages,
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
        Keyword.get(opts, :comment_work_packages, work_packages)
      )
    )
  end

  defp card_summaries(_repo, [], _opts), do: {:ok, %{}}

  defp card_summaries(repo, work_requests, opts) do
    work_request_ids = Enum.map(work_requests, & &1.id)

    with {:ok, question_context} <- question_context(repo, work_request_ids),
         {:ok, decision_counts} <- decision_counts(repo, work_request_ids),
         {:ok, work_packages} <- work_packages(repo, work_request_ids),
         {:ok, comment_context} <- card_comment_context(repo, work_requests, work_packages),
         {:ok, work_package_contexts} <- card_work_package_contexts(repo, work_packages, opts) do
      question_counts = question_context.counts
      work_packages_by_request = Enum.group_by(work_packages, & &1.work_request_id)

      with {:ok, delivery_boards} <-
             card_delivery_boards(repo, work_requests, work_packages_by_request, work_package_contexts) do
        delivery_state_opts = delivery_state_opts(opts)

        card_summaries(
          work_requests,
          question_counts,
          question_context.states,
          decision_counts,
          work_packages_by_request,
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
         work_packages_by_request,
         comment_context,
         work_package_contexts,
         delivery_context
       ) do
    delivery_boards = Map.fetch!(delivery_context, :boards)
    delivery_state_opts = Map.fetch!(delivery_context, :state_opts)

    visible_work_packages_by_request =
      visible_work_packages_by_request(work_requests, work_packages_by_request, delivery_boards)

    work_package_counts =
      visible_work_packages_by_request
      |> Map.values()
      |> Enum.flat_map(& &1)
      |> Enum.map(&{&1.work_request_id, &1.status})
      |> status_counts()

    summaries =
      Map.new(work_requests, fn %WorkRequest{} = work_request ->
        work_packages = Map.get(visible_work_packages_by_request, work_request.id, [])
        all_work_packages = Map.get(work_packages_by_request, work_request.id, [])
        comment_counts = CommentProjection.work_request_counts(comment_context, work_request, all_work_packages)
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
            work_packages,
            work_package_contexts,
            completion_deliveries_by_work_package_id(Map.get(delivery_boards, work_request.id))
          )

        operational_state =
          operational_state(
            work_request,
            work_packages,
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
           work_package_count: length(work_packages),
           planned_work_package_count: Enum.count(work_packages, &(&1.status == "planned")),
           dispatched_work_package_count: Enum.count(work_packages, &(not is_nil(&1.dispatched_at))),
           skipped_work_package_count: status_count(work_package_counts, work_request.id, "skipped"),
           completed_at: timestamp(completion_state.completed_at),
           completion_source: work_request.completion_source,
           archived_at: timestamp(completion_state.archived_at),
           operational_state: operational_state
         }}
      end)

    {:ok, summaries}
  end

  defp card_delivery_boards(repo, work_requests, work_packages_by_request, work_package_contexts) do
    DeliveryBoard.project_many(
      repo,
      work_requests,
      work_packages_by_request,
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

  defp card_work_package_contexts(repo, work_packages, opts) do
    case Keyword.get(opts, :grant) do
      %AccessGrant{} = grant -> work_package_work_package_contexts_for_grant(repo, work_packages, grant)
      _grant -> Dashboard.work_package_work_package_contexts(repo, work_packages)
    end
  end

  defp work_package_work_package_contexts_for_grant(repo, work_packages, %AccessGrant{} = grant) do
    with {:ok, filters} <- Dashboard.work_request_filters_for_grant(repo, grant),
         {:ok, work_package_contexts} <- Dashboard.work_package_work_package_contexts(repo, work_packages) do
      {:ok,
       Map.filter(work_package_contexts, fn
         {_work_package_id, %{work_package: %WorkPackage{} = work_package}} ->
           Dashboard.phase_work_package_matches_filters?(work_package, filters)

         _context ->
           false
       end)}
    end
  end

  defp card_comment_context(repo, work_requests, work_packages) do
    targets =
      Enum.map(work_requests, &{"work_request", &1.id}) ++
        Enum.map(work_packages, &{"work_package", &1.id})

    Dashboard.comment_count_context(repo, targets)
  end

  defp visible_work_packages_by_request(work_requests, work_packages_by_request, delivery_boards) do
    Map.new(work_requests, fn %WorkRequest{} = work_request ->
      work_packages = Map.get(work_packages_by_request, work_request.id, [])
      delivery_board = Map.get(delivery_boards, work_request.id)

      {work_request.id, visible_work_packages(work_packages, delivery_board)}
    end)
  end

  defp completion_deliveries_by_work_package_id(delivery_board) do
    delivery_board
    |> DeliveryWorkPackageProjection.work_packages_by_id()
    |> Enum.flat_map(fn {slice_id, delivery_work_package} ->
      case completion_delivery_outcome(delivery_work_package) do
        outcome when is_binary(outcome) and outcome != "" -> [{slice_id, %{outcome: outcome}}]
        _outcome -> []
      end
    end)
    |> Map.new()
  end

  defp completion_delivery_outcome(%{} = delivery_work_package) do
    map_value(delivery_work_package, "delivery_outcome") ||
      case map_value(delivery_work_package, "delivery") do
        %{} = delivery -> map_value(delivery, "outcome")
        _delivery -> nil
      end
  end

  defp completion_delivery_outcome(_delivery_work_package), do: nil

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

  defp work_packages(repo, work_request_ids) do
    rows =
      chunked_work_request_rows(work_request_ids, fn chunk ->
        from(work_package in WorkPackage,
          where: work_package.work_request_id in ^chunk,
          order_by: [asc: work_package.work_request_id, asc: work_package.sequence, asc: work_package.inserted_at]
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
         work_packages,
         work_package_contexts,
         completion_state,
         delivery_board,
         delivery_state_opts
       ) do
    slice_states =
      work_package_operational_states(work_packages, work_package_contexts, delivery_board, delivery_state_opts)

    attention_items = aggregate_operational_attention(slice_states)
    promoted_state = primary_work_request_slice_state(slice_states)

    cond do
      completion_state.archived_at ->
        completed_operational_state(work_request, attention_items)

      operator_completed?(work_request, completion_state) ->
        completed_operational_state(work_request, attention_items)

      delivery_truth_operational_state?(promoted_state) ->
        promoted_operational_state(work_request, promoted_state, work_packages, attention_items)
        |> DeliveryWorkPackageProjection.redact_reasons(delivery_state_opts)

      completion_state.completed? ->
        completed_operational_state(work_request, attention_items)

      work_request.status in @delivery_promotion_blocking_work_request_statuses ->
        base_operational_state(work_request.status, attention_items)

      promoted_state ->
        promoted_operational_state(work_request, promoted_state, work_packages, attention_items)

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
      "All WorkRequest questions, WorkPackages, blockers, and active runtimes are terminal.",
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
      "WorkRequest is ready for an architect to author WorkPackages.",
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

  defp work_package_operational_states(work_packages, work_package_contexts, delivery_board, delivery_state_opts) do
    delivery_work_packages_by_id = DeliveryWorkPackageProjection.work_packages_by_id(delivery_board)

    Enum.map(work_packages, fn %WorkPackage{} = work_package ->
      OperationalProjection.work_package_operational_state(
        work_package,
        Map.get(work_package_contexts, work_package.id),
        Map.get(delivery_work_packages_by_id, work_package.id),
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

  defp promoted_operational_state(%WorkRequest{} = work_request, promoted_state, work_packages, attention_items) do
    promoted_state
    |> OperationalProjection.operational_activity_fields()
    |> Map.merge(
      operational_state_map(
        promoted_state.key,
        promoted_state.label,
        promoted_state.tone,
        "Most actionable WorkPackage state is #{promoted_state.label} across #{length(work_packages)} package(s).",
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
