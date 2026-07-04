defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.WorkRequestDetails do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.CommentProjection
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.BulkRepository, as: WorkRequestBulkRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @work_request_detail_comment_target_chunk_size 500

  @type repo :: module()
  @type dashboard_error :: Dashboard.dashboard_error()

  @spec details(repo(), [String.t()], keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def details(repo, work_request_ids, opts) do
    with {:ok, context} <- work_request_details_context(repo, work_request_ids, opts) do
      build_work_request_details(repo, context, opts)
    end
  end

  @spec board_details(repo(), [String.t()], keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def board_details(repo, work_request_ids, opts) do
    with {:ok, context} <- work_request_board_details_context(repo, work_request_ids, opts) do
      build_work_request_board_details(repo, context, opts)
    end
  end

  defp work_request_details_context(repo, work_request_ids, opts) do
    with {:ok, work_requests_by_id} <- WorkRequestBulkRepository.get_many(repo, work_request_ids),
         {:ok, work_requests} <- Dashboard.work_requests_in_input_order(work_request_ids, work_requests_by_id),
         {:ok, questions_by_request} <- WorkRequestBulkRepository.list_questions_many(repo, work_request_ids),
         {:ok, decisions_by_request} <- WorkRequestBulkRepository.list_decisions_many(repo, work_request_ids),
         {:ok, planned_slices_by_request} <- WorkRequestBulkRepository.list_planned_slices_many(repo, work_request_ids),
         all_planned_slices = Dashboard.all_planned_slices(work_requests, planned_slices_by_request),
         {:ok, work_package_contexts} <- Dashboard.planned_slice_work_package_contexts(repo, all_planned_slices),
         {:ok, comment_context} <- work_request_detail_comment_context(repo, work_requests, all_planned_slices) do
      {:ok,
       %{
         work_requests: work_requests,
         questions_by_request: questions_by_request,
         decisions_by_request: decisions_by_request,
         planned_slices_by_request: planned_slices_by_request,
         work_package_contexts: work_package_contexts,
         repo_identity_catalog: Dashboard.repo_identity_catalog_from_opts(opts, Enum.map(work_requests, & &1.repo)),
         comment_context: comment_context
       }}
    end
  end

  defp build_work_request_details(repo, %{work_requests: work_requests} = context, opts) do
    work_requests
    |> Enum.reduce_while([], fn %WorkRequest{} = work_request, details ->
      case build_work_request_detail(repo, work_request, context, opts) do
        {:ok, detail} -> {:cont, [detail | details]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      details -> {:ok, Enum.reverse(details)}
    end
  end

  defp work_request_board_details_context(repo, work_request_ids, opts) do
    with {:ok, work_requests_by_id} <- WorkRequestBulkRepository.get_many(repo, work_request_ids),
         {:ok, work_requests} <- Dashboard.work_requests_in_input_order(work_request_ids, work_requests_by_id),
         {:ok, questions_by_request} <- WorkRequestBulkRepository.list_questions_many(repo, work_request_ids),
         {:ok, planned_slices_by_request} <- WorkRequestBulkRepository.list_planned_slices_many(repo, work_request_ids),
         all_planned_slices = Dashboard.all_planned_slices(work_requests, planned_slices_by_request),
         {:ok, work_package_contexts} <- Dashboard.planned_slice_work_package_contexts(repo, all_planned_slices),
         {:ok, comment_context} <- work_request_board_detail_comment_context(repo, work_requests, all_planned_slices) do
      {:ok,
       %{
         work_requests: work_requests,
         questions_by_request: questions_by_request,
         planned_slices_by_request: planned_slices_by_request,
         work_package_contexts: work_package_contexts,
         repo_identity_catalog: Dashboard.repo_identity_catalog_from_opts(opts, Enum.map(work_requests, & &1.repo)),
         comment_context: comment_context
       }}
    end
  end

  defp build_work_request_board_details(repo, %{work_requests: work_requests} = context, opts) do
    with {:ok, delivery_boards} <- work_request_board_delivery_boards(repo, context, opts) do
      context = Map.put(context, :delivery_boards, delivery_boards)

      work_requests
      |> Enum.map(fn work_request ->
        build_work_request_board_detail(repo, work_request, context, opts, Map.fetch(delivery_boards, work_request.id))
      end)
      |> Dashboard.collect_or_error()
    end
  end

  defp work_request_board_delivery_boards(_repo, %{work_requests: []}, _opts), do: {:ok, %{}}

  defp work_request_board_delivery_boards(
         repo,
         %{
           work_requests: work_requests,
           planned_slices_by_request: planned_slices_by_request,
           work_package_contexts: work_package_contexts
         },
         opts
       ) do
    work_requests
    |> Enum.group_by(&{&1.repo, &1.base_branch})
    |> Enum.reduce_while({:ok, %{}}, fn {_scope, scoped_work_requests}, {:ok, acc} ->
      scoped_planned_slices = Dashboard.all_planned_slices(scoped_work_requests, planned_slices_by_request)
      scoped_work_package_contexts = request_work_package_contexts(scoped_planned_slices, work_package_contexts)

      with {:ok, delivery_board_contexts} <-
             delivery_board_work_package_contexts(repo, scoped_work_requests, scoped_work_package_contexts),
           {:ok, delivery_boards} <-
             DeliveryBoard.project_many(
               repo,
               scoped_work_requests,
               planned_slices_by_request,
               delivery_board_many_opts(delivery_board_contexts, opts)
             ) do
        {:cont, {:ok, Map.merge(acc, delivery_boards)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_work_request_board_detail(
         repo,
         %WorkRequest{} = work_request,
         %{
           questions_by_request: questions_by_request,
           planned_slices_by_request: planned_slices_by_request,
           work_package_contexts: work_package_contexts,
           repo_identity_catalog: repo_identity_catalog,
           comment_context: comment_context
         },
         _opts,
         {:ok, delivery_board}
       ) do
    questions = Map.get(questions_by_request, work_request.id, [])
    planned_slices = Map.get(planned_slices_by_request, work_request.id, [])
    request_work_package_contexts = request_work_package_contexts(planned_slices, work_package_contexts)

    questions = Dashboard.ordered_sequence_records(questions)
    all_planned_slices = Dashboard.ordered_sequence_records(planned_slices)

    planned_slices =
      planned_slices
      |> Dashboard.visible_planned_slices(delivery_board)
      |> Dashboard.ordered_sequence_records()

    work_request_comment_context = request_comment_context(comment_context, work_request, all_planned_slices)

    work_request_payload =
      work_request
      |> Dashboard.work_request_payload(
        questions,
        planned_slices,
        request_work_package_contexts,
        repo_identity_catalog,
        work_request_comment_context,
        delivery_board: delivery_board,
        comment_planned_slices: all_planned_slices
      )
      |> Map.drop([:human_description, :constraints, :creator])

    planned_slice_payloads =
      planned_slices
      |> Dashboard.planned_slice_payloads(
        request_work_package_contexts,
        true,
        work_request_comment_context,
        delivery_board: delivery_board
      )
      |> Enum.map(&Dashboard.compact_planned_slice/1)

    {:ok,
     %{
       work_request: work_request_payload,
       clarification_questions: Enum.map(questions, &Dashboard.clarification_question/1),
       planned_slices: planned_slice_payloads,
       product_tree: ProductTree.project(repo, work_request.id, planned_slice_payloads),
       delivery_board: Dashboard.compact_delivery_evidence(Dashboard.redacted_json(delivery_board)),
       summary: Dashboard.work_request_board_summary(questions, planned_slices, work_request_comment_context)
     }}
  end

  defp build_work_request_board_detail(_repo, %WorkRequest{}, _context, _opts, :error) do
    {:error, :not_found}
  end

  defp work_request_board_detail_comment_context(repo, work_requests, planned_slices) do
    targets =
      Enum.map(work_requests, &{"work_request", &1.id}) ++
        Enum.map(planned_slices, &{"planned_slice", &1.id})

    Dashboard.comment_count_context(repo, targets)
  end

  defp work_request_detail_comment_context(repo, work_requests, planned_slices) do
    targets =
      Enum.map(work_requests, &{"work_request", &1.id}) ++
        Enum.map(planned_slices, &{"planned_slice", &1.id})

    targets
    |> Enum.chunk_every(@work_request_detail_comment_target_chunk_size)
    |> Enum.reduce_while({:ok, %{comments: %{}, counts: %{}}}, fn target_chunk, {:ok, acc} ->
      case Dashboard.comment_context(repo, target_chunk) do
        {:ok, context} ->
          {:cont, {:ok, %{comments: Map.merge(acc.comments, context.comments), counts: Map.merge(acc.counts, context.counts)}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp build_work_request_detail(
         repo,
         %WorkRequest{} = work_request,
         %{
           questions_by_request: questions_by_request,
           decisions_by_request: decisions_by_request,
           planned_slices_by_request: planned_slices_by_request,
           work_package_contexts: work_package_contexts,
           repo_identity_catalog: repo_identity_catalog,
           comment_context: comment_context
         },
         opts
       ) do
    questions = Map.get(questions_by_request, work_request.id, [])
    decisions = Map.get(decisions_by_request, work_request.id, [])
    planned_slices = Map.get(planned_slices_by_request, work_request.id, [])
    request_work_package_contexts = request_work_package_contexts(planned_slices, work_package_contexts)

    with {:ok, delivery_board_contexts} <-
           delivery_board_work_package_contexts(repo, work_request, request_work_package_contexts),
         delivery_board_opts = delivery_board_opts(work_request, planned_slices, delivery_board_contexts, opts),
         {:ok, delivery_board} <- DeliveryBoard.project(repo, work_request.id, delivery_board_opts) do
      all_planned_slices = Dashboard.ordered_sequence_records(planned_slices)
      questions = Dashboard.ordered_sequence_records(questions)
      decisions = Dashboard.ordered_sequence_records(decisions)

      planned_slices =
        planned_slices
        |> Dashboard.visible_planned_slices(delivery_board)
        |> Dashboard.ordered_sequence_records()

      comment_context = request_comment_context(comment_context, work_request, all_planned_slices)

      work_request_payload =
        Dashboard.work_request_payload(
          work_request,
          questions,
          planned_slices,
          request_work_package_contexts,
          repo_identity_catalog,
          comment_context,
          delivery_board: delivery_board,
          comment_planned_slices: all_planned_slices
        )

      planned_slice_payloads =
        Dashboard.planned_slice_payloads(
          planned_slices,
          request_work_package_contexts,
          true,
          comment_context,
          delivery_board: delivery_board
        )

      {:ok,
       %{
         work_request: work_request_payload,
         clarification_questions: Enum.map(questions, &Dashboard.clarification_question/1),
         decision_logs: Enum.map(decisions, &Dashboard.decision_log_entry/1),
         planned_slices: planned_slice_payloads,
         product_tree: ProductTree.project(repo, work_request.id, planned_slice_payloads),
         delivery_board: Dashboard.redacted_json(delivery_board),
         comments: CommentProjection.comments_for(comment_context, "work_request", work_request.id),
         summary: Dashboard.work_request_summary(questions, decisions, planned_slices, comment_context)
       }}
    end
  end

  defp request_work_package_contexts(planned_slices, work_package_contexts) do
    work_package_ids =
      planned_slices
      |> Enum.map(& &1.work_package_id)
      |> Enum.filter(&Dashboard.filled_string?/1)
      |> MapSet.new()

    Map.filter(work_package_contexts, fn {work_package_id, _context} -> MapSet.member?(work_package_ids, work_package_id) end)
  end

  defp request_comment_context(comment_context, %WorkRequest{} = work_request, planned_slices) do
    targets = [{"work_request", work_request.id} | Enum.map(planned_slices, &{"planned_slice", &1.id})]

    %{
      comments: Map.take(comment_context.comments, targets),
      counts: Map.take(comment_context.counts, targets)
    }
  end

  defp delivery_board_opts(%WorkRequest{} = work_request, planned_slices, work_package_contexts, _opts) do
    [
      work_request: work_request,
      planned_slices: planned_slices,
      visible_work_package_ids: Map.keys(work_package_contexts),
      work_package_contexts: work_package_contexts
    ]
  end

  defp delivery_board_many_opts(work_package_contexts, _opts) do
    [
      visible_work_package_ids: Map.keys(work_package_contexts),
      work_package_contexts: work_package_contexts
    ]
  end

  defp delivery_board_work_package_contexts(repo, work_requests, work_package_contexts) when is_list(work_requests) do
    loaded_ids = Map.keys(work_package_contexts)
    successor_ids = delivery_board_successor_work_package_ids(repo, Enum.map(work_requests, & &1.id))
    missing_successor_ids = Enum.reject(successor_ids, &(&1 in loaded_ids))

    successor_contexts =
      repo
      |> work_packages_by_ids(missing_successor_ids)
      |> Enum.filter(&delivery_board_successor_visible?(&1, work_requests))
      |> then(&Dashboard.linked_work_package_contexts(repo, &1))

    {:ok, Map.merge(work_package_contexts, successor_contexts)}
  end

  defp delivery_board_work_package_contexts(repo, %WorkRequest{} = work_request, work_package_contexts) do
    loaded_ids = Map.keys(work_package_contexts)
    successor_ids = delivery_board_successor_work_package_ids(repo, work_request.id)
    missing_successor_ids = Enum.reject(successor_ids, &(&1 in loaded_ids))

    successor_contexts =
      repo
      |> work_packages_by_ids(missing_successor_ids)
      |> Enum.filter(&delivery_board_successor_visible?(&1, work_request))
      |> then(&Dashboard.linked_work_package_contexts(repo, &1))

    {:ok, Map.merge(work_package_contexts, successor_contexts)}
  end

  defp delivery_board_successor_visible?(%WorkPackage{} = work_package, %WorkRequest{} = work_request) do
    Dashboard.phase_work_package_matches_filters?(work_package, repo: work_request.repo, base_branch: work_request.base_branch)
  end

  defp delivery_board_successor_visible?(%WorkPackage{} = work_package, work_requests) when is_list(work_requests) do
    Enum.any?(work_requests, &delivery_board_successor_visible?(work_package, &1))
  end

  defp work_packages_by_ids(_repo, []), do: []

  defp work_packages_by_ids(repo, work_package_ids) do
    repo.all(
      from(work_package in WorkPackage,
        where: work_package.id in ^work_package_ids
      )
    )
  end

  defp delivery_board_successor_work_package_ids(_repo, []), do: []

  defp delivery_board_successor_work_package_ids(repo, work_request_ids) when is_list(work_request_ids) do
    repo.all(
      from(delivery in PlannedSliceDelivery,
        where: delivery.work_request_id in ^work_request_ids,
        where: not is_nil(delivery.successor_work_package_id),
        select: delivery.successor_work_package_id
      )
    )
    |> Enum.filter(&Dashboard.filled_string?/1)
    |> Enum.uniq()
  end

  defp delivery_board_successor_work_package_ids(repo, work_request_id) do
    delivery_board_successor_work_package_ids(repo, [work_request_id])
  end
end
