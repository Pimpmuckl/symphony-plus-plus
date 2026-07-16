defmodule SymphonyElixir.SymphonyPlusPlus.Comments.Repository do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type repo :: module()
  @type target :: {String.t(), String.t()}
  @default_list_limit 100
  @delete_target_chunk_size 500
  @type error ::
          :already_resolved
          | :database_busy
          | :id_already_exists
          | :invalid_status
          | :invalid_target
          | :not_found
          | {:constraint_failed, String.t()}
          | {:migration_failed, term()}
          | {:storage_failed, String.t()}
          | Changeset.t()

  @spec migrate(repo()) :: :ok | {:error, error()}
  def migrate(repo) when is_atom(repo) do
    Ecto.Migrator.run(repo, Migrations.all(), :up, all: true, log: false)
    :ok
  rescue
    error -> {:error, {:migration_failed, error}}
  end

  @spec create(repo(), map()) :: {:ok, Comment.t()} | {:error, error()}
  def create(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> redact_comment_text()

    with :ok <- validate_target(repo, Map.get(attrs, "target_kind"), Map.get(attrs, "target_id")) do
      attrs
      |> Comment.create_changeset()
      |> repo.insert()
      |> normalize_insert_result()
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec get(repo(), String.t()) :: {:ok, Comment.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(Comment, id) do
      nil -> {:error, :not_found}
      comment -> {:ok, comment}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_for_target(repo(), String.t(), String.t()) :: {:ok, [Comment.t()]} | {:error, error()}
  def list_for_target(repo, target_kind, target_id)
      when is_atom(repo) and is_binary(target_kind) and is_binary(target_id) do
    comments =
      repo.all(
        from(comment in Comment,
          where: comment.target_kind == ^target_kind and comment.target_id == ^target_id,
          order_by: [desc: comment.inserted_at, desc: comment.id],
          limit: ^@default_list_limit
        )
      )
      |> Enum.reverse()

    {:ok, comments}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_for_targets(repo(), [target()]) :: {:ok, %{target() => [Comment.t()]}} | {:error, error()}
  def list_for_targets(_repo, []), do: {:ok, %{}}

  def list_for_targets(repo, targets) when is_atom(repo) and is_list(targets) do
    target_set = targets |> normalize_targets() |> MapSet.new()
    target_kinds = target_set |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    target_ids = target_set |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    comments =
      repo.all(
        from(comment in capped_comment_query(target_kinds, target_ids),
          where: comment.target_kind in ^target_kinds and comment.target_id in ^target_ids,
          order_by: [asc: comment.inserted_at, asc: comment.id]
        )
      )

    grouped_comments =
      comments
      |> Enum.filter(&MapSet.member?(target_set, {&1.target_kind, &1.target_id}))
      |> Enum.group_by(&{&1.target_kind, &1.target_id})

    {:ok, Map.merge(default_comment_lists(target_set), grouped_comments)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec delete_for_targets(repo(), [target()]) :: {:ok, non_neg_integer()} | {:error, error()}
  def delete_for_targets(_repo, []), do: {:ok, 0}

  def delete_for_targets(repo, targets) when is_atom(repo) and is_list(targets) do
    targets
    |> normalize_targets()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce({:ok, 0}, fn
      {_target_kind, _target_ids}, {:error, reason} ->
        {:error, reason}

      {target_kind, target_ids}, {:ok, deleted_count} ->
        case delete_target_ids(repo, target_kind, target_ids) do
          {:ok, count} -> {:ok, deleted_count + count}
          {:error, reason} -> {:error, reason}
        end
    end)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec counts_for_targets(repo(), [target()]) ::
          {:ok, %{target() => %{comment_count: non_neg_integer(), open_comment_count: non_neg_integer()}}}
          | {:error, error()}
  def counts_for_targets(_repo, []), do: {:ok, %{}}

  def counts_for_targets(repo, targets) when is_atom(repo) and is_list(targets) do
    target_set = targets |> normalize_targets() |> MapSet.new()
    target_kinds = target_set |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    target_ids = target_set |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    rows =
      repo.all(
        from(comment in Comment,
          where: comment.target_kind in ^target_kinds and comment.target_id in ^target_ids,
          group_by: [comment.target_kind, comment.target_id, comment.status],
          select: {comment.target_kind, comment.target_id, comment.status, count(comment.id)}
        )
      )

    counts = Enum.reduce(rows, default_counts(target_set), &add_count_row(&1, &2, target_set))

    {:ok, counts}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp add_count_row({target_kind, target_id, status, count}, acc, target_set) do
    target = {target_kind, target_id}

    if MapSet.member?(target_set, target) do
      Map.update!(acc, target, &add_count_to_target(&1, status, count))
    else
      acc
    end
  end

  defp add_count_to_target(target_counts, status, count) do
    target_counts
    |> Map.update!(:comment_count, &(&1 + count))
    |> maybe_add_open_count(status, count)
  end

  @spec resolve(repo(), String.t(), map()) :: {:ok, Comment.t()} | {:error, error()}
  def resolve(repo, id, attrs) when is_atom(repo) and is_binary(id) and is_map(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> redact_resolution_text()
      |> Map.put("status", "resolved")
      |> Map.put_new("resolved_at", DateTime.utc_now(:microsecond))

    changeset = Comment.resolve_changeset(%Comment{id: id, status: "open"}, attrs)

    if changeset.valid? do
      updates = changeset.changes |> Map.put(:updated_at, DateTime.utc_now(:microsecond)) |> Map.to_list()

      query = from(comment in Comment, where: comment.id == ^id and comment.status == "open")

      case repo.update_all(query, set: updates) do
        {1, _rows} -> get(repo, id)
        {0, _rows} -> resolve_miss(repo, id)
      end
    else
      {:error, changeset}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp validate_target(repo, "work_request", target_id) when is_binary(target_id) do
    case repo.get(WorkRequest, target_id) do
      %WorkRequest{} -> :ok
      nil -> {:error, :not_found}
    end
  end

  defp validate_target(repo, "work_package", target_id) when is_binary(target_id) do
    case repo.get(WorkPackage, target_id) do
      %WorkPackage{} -> :ok
      nil -> {:error, :not_found}
    end
  end

  defp validate_target(repo, "work_package", target_id) when is_binary(target_id) do
    case repo.get(WorkPackage, target_id) do
      %WorkPackage{} -> :ok
      nil -> {:error, :not_found}
    end
  end

  defp validate_target(_repo, _target_kind, _target_id), do: {:error, :invalid_target}

  defp delete_target_ids(repo, target_kind, target_ids) do
    target_ids
    |> Enum.uniq()
    |> Enum.chunk_every(@delete_target_chunk_size)
    |> Enum.reduce({:ok, 0}, fn
      _chunk, {:error, reason} ->
        {:error, reason}

      ids, {:ok, deleted_count} ->
        {count, _rows} =
          repo.delete_all(
            from(comment in Comment,
              where: comment.target_kind == ^target_kind,
              where: comment.target_id in ^ids
            )
          )

        {:ok, deleted_count + count}
    end)
  end

  defp capped_comment_query(target_kinds, target_ids) do
    ranked_ids =
      from(comment in Comment,
        where: comment.target_kind in ^target_kinds and comment.target_id in ^target_ids,
        windows: [
          target: [
            partition_by: [comment.target_kind, comment.target_id],
            order_by: [desc: comment.inserted_at, desc: comment.id]
          ]
        ],
        select: %{id: comment.id, row_number: over(row_number(), :target)}
      )

    from(comment in Comment,
      join: ranked in subquery(ranked_ids),
      on: ranked.id == comment.id,
      where: ranked.row_number <= ^@default_list_limit
    )
  end

  defp resolve_miss(repo, id) do
    case get(repo, id) do
      {:ok, %Comment{status: "resolved"}} -> {:error, :already_resolved}
      {:ok, %Comment{}} -> {:error, :invalid_status}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_targets(targets) do
    targets
    |> Enum.filter(fn
      {target_kind, target_id} -> is_binary(target_kind) and is_binary(target_id)
      _target -> false
    end)
    |> Enum.uniq()
  end

  defp default_counts(target_set) do
    Map.new(target_set, &{&1, %{comment_count: 0, open_comment_count: 0}})
  end

  defp default_comment_lists(target_set), do: Map.new(target_set, &{&1, []})

  defp maybe_add_open_count(counts, "open", count), do: Map.update!(counts, :open_comment_count, &(&1 + count))
  defp maybe_add_open_count(counts, _status, _count), do: counts

  defp normalize_insert_result({:ok, comment}), do: {:ok, comment}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    if duplicate_id?(changeset), do: {:error, :id_already_exists}, else: {:error, changeset}
  end

  defp duplicate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_comments_id_unique_index"}) do
    {:error, :id_already_exists}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    {:error, {:constraint_failed, constraint}}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}) do
    {:error, {:constraint_failed, Atom.to_string(type)}}
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    if String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp redact_comment_text(attrs), do: Map.update(attrs, "body", nil, &Redactor.redact_text/1)
  defp redact_resolution_text(attrs), do: Map.update(attrs, "resolution_note", nil, &Redactor.redact_text/1)
end
