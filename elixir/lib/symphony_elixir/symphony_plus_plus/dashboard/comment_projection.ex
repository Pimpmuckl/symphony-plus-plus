defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.CommentProjection do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.Sanitizer

  @spec comments_for(map() | nil, String.t(), String.t()) :: [map()]
  def comments_for(nil, _target_kind, _target_id), do: []

  def comments_for(%{comments: comments}, target_kind, target_id) do
    comments
    |> Map.get({target_kind, target_id}, [])
    |> Enum.map(&comment/1)
  end

  @spec counts_for(map() | nil, String.t(), String.t()) :: map()
  def counts_for(nil, _target_kind, _target_id), do: %{comment_count: 0, open_comment_count: 0}

  def counts_for(%{counts: counts}, target_kind, target_id) do
    Map.get(counts, {target_kind, target_id}, %{comment_count: 0, open_comment_count: 0})
  end

  @spec total_counts(map()) :: map()
  def total_counts(%{counts: counts}) do
    Enum.reduce(counts, %{comment_count: 0, open_comment_count: 0}, fn {_target, target_counts}, acc ->
      %{
        comment_count: acc.comment_count + Map.get(target_counts, :comment_count, 0),
        open_comment_count: acc.open_comment_count + Map.get(target_counts, :open_comment_count, 0)
      }
    end)
  end

  @spec work_request_counts(term(), term(), term()) :: map()
  def work_request_counts(%{counts: counts}, %{id: work_request_id}, work_packages) when is_list(work_packages) do
    total_counts(%{
      counts:
        counts
        |> Map.take([{"work_request", work_request_id} | Enum.flat_map(work_packages, &work_package_target/1)])
    })
  end

  def work_request_counts(_comment_context, _work_request, _work_packages), do: %{comment_count: 0, open_comment_count: 0}

  @spec put_counts(map(), map()) :: map()
  def put_counts(payload, counts) do
    payload
    |> Map.put(:comment_count, Map.get(counts, :comment_count, 0))
    |> Map.put(:open_comment_count, Map.get(counts, :open_comment_count, 0))
  end

  defp comment(%Comment{} = comment) do
    %{
      id: comment.id,
      target_kind: comment.target_kind,
      target_id: comment.target_id,
      body: Sanitizer.redacted_text(comment.body),
      source_type: comment.source_type,
      author_name: Sanitizer.redacted_text(comment.author_name),
      status: comment.status,
      resolved_by: Sanitizer.redacted_text(comment.resolved_by),
      resolved_source_type: comment.resolved_source_type,
      resolved_at: Sanitizer.timestamp(comment.resolved_at),
      resolution_note: Sanitizer.redacted_text(comment.resolution_note),
      inserted_at: Sanitizer.timestamp(comment.inserted_at),
      updated_at: Sanitizer.timestamp(comment.updated_at)
    }
  end

  defp work_package_target(%{id: id}), do: [{"work_package", id}]
  defp work_package_target(_work_package), do: []
end
