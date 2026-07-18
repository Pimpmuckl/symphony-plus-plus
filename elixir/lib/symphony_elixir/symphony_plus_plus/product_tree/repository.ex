defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree.Repository do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.{Attrs, DependencyEdge, Node, Revision}
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @revision_number_retry_count 3
  @revision_number_unique_index "sympp_product_tree_revisions_work_request_revision_unique_index"
  @id_collision_constraints [
    "sympp_product_tree_nodes_pkey",
    "sympp_product_tree_nodes_id_index",
    "sympp_product_tree_nodes_id_unique_index",
    "sympp_product_tree_dependency_edges_pkey",
    "sympp_product_tree_dependency_edges_id_index",
    "sympp_product_tree_dependency_edges_id_unique_index",
    "sympp_product_tree_revisions_pkey",
    "sympp_product_tree_revisions_id_index",
    "sympp_product_tree_revisions_id_unique_index"
  ]
  @sqlite_primary_key_messages [
    "unique constraint failed: sympp_product_tree_nodes.id",
    "unique constraint failed: sympp_product_tree_dependency_edges.id",
    "unique constraint failed: sympp_product_tree_revisions.id"
  ]

  @type repo :: module()
  @type error ::
          :not_found
          | :database_busy
          | :id_already_exists
          | {:constraint_failed, String.t()}
          | {:storage_failed, String.t()}
          | Changeset.t()

  @spec tree_for_work_request(repo(), String.t()) ::
          {:ok,
           %{
             nodes: [Node.t()],
             dependency_edges: [DependencyEdge.t()],
             latest_revision: Revision.t() | nil
           }}
          | {:error, error()}
  def tree_for_work_request(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    {:ok,
     %{
       nodes: list_nodes!(repo, work_request_id),
       dependency_edges: list_dependency_edges!(repo, work_request_id),
       latest_revision: latest_revision!(repo, work_request_id)
     }}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec create_node(repo(), map()) :: {:ok, Node.t()} | {:error, error()}
  def create_node(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs = Attrs.normalize_keys(attrs)

    with :ok <- validate_parent_scope(repo, attrs) do
      attrs
      |> Node.create_changeset()
      |> repo.insert()
      |> normalize_insert_result()
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec upsert_node(repo(), map()) :: {:ok, Node.t()} | {:error, error()}
  def upsert_node(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs = attrs |> Attrs.normalize_keys() |> normalize_blank_id("parent_id")

    case Map.get(attrs, "product_tree_node_id") || Map.get(attrs, "id") do
      id when is_binary(id) and id != "" -> update_node(repo, Map.put(attrs, "id", id))
      _id -> create_node(repo, attrs)
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec create_dependency_edge(repo(), map()) :: {:ok, DependencyEdge.t()} | {:error, error()}
  def create_dependency_edge(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs = Attrs.normalize_keys(attrs)

    with :ok <- validate_dependency_edge_scope(repo, attrs) do
      attrs
      |> DependencyEdge.create_changeset()
      |> repo.insert()
      |> normalize_insert_result()
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec upsert_dependency_edge(repo(), map()) :: {:ok, DependencyEdge.t()} | {:error, error()}
  def upsert_dependency_edge(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs = Attrs.normalize_keys(attrs)

    case Map.get(attrs, "id") do
      id when is_binary(id) and id != "" -> update_dependency_edge_by_id(repo, id, attrs)
      _id -> create_dependency_edge(repo, attrs)
    end
  end

  @spec delete_dependency_edge(repo(), String.t(), String.t()) :: {:ok, DependencyEdge.t()} | {:error, error()}
  def delete_dependency_edge(repo, work_request_id, id)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(id) do
    case repo.get(DependencyEdge, id) do
      %DependencyEdge{work_request_id: ^work_request_id} = edge -> repo.delete(edge)
      _edge -> {:error, :not_found}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec delete_group(repo(), String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def delete_group(repo, work_request_id, id)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(id) do
    case repo.get(Node, id) do
      %Node{work_request_id: ^work_request_id} = group ->
        delete_group_record(repo, work_request_id, group)

      _group ->
        {:error, :not_found}
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp delete_group_record(repo, work_request_id, %Node{} = group) do
    moved_group_count = reparent_child_groups(repo, work_request_id, group)
    moved_work_package_count = ungroup_work_packages(repo, work_request_id, group)
    removed_dependency_count = delete_group_dependencies(repo, work_request_id, group.id)

    with {:ok, deleted_group} <- repo.delete(group) do
      {:ok,
       %{
         group: deleted_group,
         parent_group_id: group.parent_id,
         moved_group_count: moved_group_count,
         moved_work_package_count: moved_work_package_count,
         removed_dependency_count: removed_dependency_count
       }}
    end
  end

  defp reparent_child_groups(repo, work_request_id, group) do
    {count, _} =
      repo.update_all(
        from(node in Node, where: node.work_request_id == ^work_request_id and node.parent_id == ^group.id),
        set: [parent_id: group.parent_id]
      )

    count
  end

  defp ungroup_work_packages(repo, work_request_id, group) do
    now = DateTime.utc_now(:microsecond)

    {count, _} =
      repo.update_all(
        from(work_package in WorkPackage,
          where: work_package.work_request_id == ^work_request_id and work_package.product_tree_node_id == ^group.id
        ),
        set: [product_tree_node_id: group.parent_id, updated_at: now],
        inc: [contract_revision: 1]
      )

    count
  end

  defp delete_group_dependencies(repo, work_request_id, group_id) do
    {count, _} =
      repo.delete_all(
        from(edge in DependencyEdge,
          where:
            edge.work_request_id == ^work_request_id and
              ((edge.source_kind == "product_node" and edge.source_id == ^group_id) or
                 (edge.target_kind == "product_node" and edge.target_id == ^group_id))
        )
      )

    count
  end

  @spec record_revision(repo(), String.t(), map()) :: {:ok, Revision.t()} | {:error, error()}
  def record_revision(repo, work_request_id, attrs) when is_atom(repo) and is_binary(work_request_id) and is_map(attrs) do
    record_revision(repo, work_request_id, attrs, @revision_number_retry_count)
  end

  defp record_revision(repo, work_request_id, attrs, attempts_left) do
    attrs =
      attrs
      |> Attrs.normalize_keys()
      |> Map.put("work_request_id", work_request_id)
      |> Map.put("revision_number", next_revision_number(repo, work_request_id))

    case repo.insert(Revision.create_changeset(attrs)) do
      {:ok, revision} ->
        {:ok, revision}

      {:error, %Changeset{} = changeset} = error ->
        if revision_number_conflict?(changeset) and attempts_left > 0 do
          record_revision(repo, work_request_id, attrs, attempts_left - 1)
        else
          normalize_insert_result(error)
        end
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp list_nodes!(repo, work_request_id) do
    repo.all(
      from(node in Node,
        where: node.work_request_id == ^work_request_id,
        order_by: [asc: node.parent_id, asc: node.position, asc: node.created_at, asc: node.id]
      )
    )
  end

  defp list_dependency_edges!(repo, work_request_id) do
    repo.all(
      from(edge in DependencyEdge,
        where: edge.work_request_id == ^work_request_id,
        order_by: [asc: edge.kind, asc: edge.created_at, asc: edge.id]
      )
    )
  end

  defp latest_revision!(repo, work_request_id) do
    repo.one(
      from(revision in Revision,
        where: revision.work_request_id == ^work_request_id,
        order_by: [desc: revision.revision_number],
        limit: 1
      )
    )
  end

  defp update_node(repo, %{"id" => id, "work_request_id" => work_request_id} = attrs)
       when is_binary(work_request_id) and work_request_id != "" do
    case repo.get(Node, id) do
      nil ->
        {:error, :not_found}

      %Node{work_request_id: ^work_request_id} = node ->
        with :ok <- validate_parent_scope(repo, attrs),
             :ok <- validate_parent_cycle(repo, node, attrs) do
          node
          |> Node.update_changeset(Map.put(attrs, "work_request_id", work_request_id))
          |> repo.update()
          |> normalize_insert_result()
        end

      %Node{} ->
        {:error, {:constraint_failed, "product_tree_node_work_request_scope"}}
    end
  end

  defp update_node(repo, attrs), do: create_node(repo, attrs)

  defp update_dependency_edge_by_id(repo, id, attrs) do
    case repo.get(DependencyEdge, id) do
      nil ->
        create_dependency_edge(repo, attrs)

      %DependencyEdge{work_request_id: work_request_id} = edge ->
        update_existing_dependency_edge(repo, edge, Map.put_new(attrs, "work_request_id", work_request_id))
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp update_existing_dependency_edge(
         repo,
         %DependencyEdge{work_request_id: work_request_id} = edge,
         %{"work_request_id" => work_request_id} = attrs
       ) do
    with :ok <- validate_dependency_edge_scope(repo, attrs) do
      edge
      |> DependencyEdge.update_changeset(attrs)
      |> repo.update()
      |> normalize_insert_result()
    end
  end

  defp update_existing_dependency_edge(_repo, %DependencyEdge{}, _attrs),
    do: {:error, {:constraint_failed, "product_tree_dependency_work_request_scope"}}

  defp validate_parent_scope(_repo, %{"parent_id" => parent_id}) when parent_id in [nil, ""], do: :ok
  defp validate_parent_scope(_repo, %{"work_request_id" => work_request_id}) when work_request_id in [nil, ""], do: :ok

  defp validate_parent_scope(repo, %{"work_request_id" => work_request_id, "parent_id" => parent_id}) do
    validate_record_scope(repo, Node, parent_id, work_request_id, "product_tree_node_parent_scope")
  end

  defp validate_parent_scope(_repo, _attrs), do: :ok

  defp validate_parent_cycle(_repo, _node, %{"parent_id" => parent_id}) when parent_id in [nil, ""], do: :ok

  defp validate_parent_cycle(repo, %Node{id: id}, %{"parent_id" => parent_id}) do
    if parent_reaches_node?(repo, parent_id, id, []) do
      {:error, {:constraint_failed, "product_tree_node_parent_cycle"}}
    else
      :ok
    end
  end

  defp validate_parent_cycle(_repo, _node, _attrs), do: :ok

  @spec parent_reaches_node?(repo(), String.t() | nil, String.t(), [String.t()]) :: boolean()
  defp parent_reaches_node?(_repo, current_id, target_id, _visited) when current_id in [nil, ""], do: current_id == target_id
  defp parent_reaches_node?(_repo, target_id, target_id, _visited), do: true

  defp parent_reaches_node?(repo, current_id, target_id, visited) do
    if current_id in visited do
      false
    else
      case repo.get(Node, current_id) do
        %Node{parent_id: parent_id} ->
          parent_reaches_node?(repo, parent_id, target_id, [current_id | visited])

        _record ->
          false
      end
    end
  end

  defp validate_dependency_edge_scope(repo, %{"work_request_id" => work_request_id} = attrs) when is_binary(work_request_id) and work_request_id != "" do
    with :ok <- validate_dependency_endpoint_scope(repo, work_request_id, Map.get(attrs, "source_kind"), Map.get(attrs, "source_id"), "source") do
      validate_dependency_endpoint_scope(repo, work_request_id, Map.get(attrs, "target_kind"), Map.get(attrs, "target_id"), "target")
    end
  end

  defp validate_dependency_edge_scope(_repo, _attrs), do: :ok

  defp validate_dependency_endpoint_scope(repo, work_request_id, "product_node", id, label) do
    validate_record_scope(repo, Node, id, work_request_id, "product_tree_dependency_#{label}_scope")
  end

  defp validate_dependency_endpoint_scope(repo, work_request_id, "work_package", id, label) do
    validate_record_scope(repo, WorkPackage, id, work_request_id, "product_tree_dependency_#{label}_scope")
  end

  defp validate_dependency_endpoint_scope(_repo, _work_request_id, _kind, _id, _label), do: :ok

  defp validate_record_scope(_repo, _schema, id, _work_request_id, _constraint) when id in [nil, ""], do: :ok

  defp validate_record_scope(repo, schema, id, work_request_id, constraint) do
    case repo.get(schema, id) do
      nil -> {:error, {:constraint_failed, constraint}}
      %{work_request_id: ^work_request_id} -> :ok
      _record -> {:error, {:constraint_failed, constraint}}
    end
  end

  defp next_revision_number(repo, work_request_id) do
    repo.one(
      from(revision in Revision,
        where: revision.work_request_id == ^work_request_id,
        select: max(revision.revision_number)
      )
    )
    |> case do
      number when is_integer(number) -> number + 1
      _number -> 1
    end
  end

  defp normalize_blank_id(attrs, key) do
    case Map.get(attrs, key) do
      value when value in [nil, ""] -> Map.put(attrs, key, nil)
      value when is_binary(value) -> Map.put(attrs, key, String.trim(value))
      _value -> attrs
    end
  end

  defp normalize_insert_result({:ok, record}), do: {:ok, record}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    if duplicate_id?(changeset), do: {:error, :id_already_exists}, else: {:error, changeset}
  end

  defp duplicate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp revision_number_conflict?(%Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, options}} ->
        Keyword.get(options, :constraint) == :unique and
          Keyword.get(options, :constraint_name) == @revision_number_unique_index
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when constraint in @id_collision_constraints,
    do: {:error, :id_already_exists}

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint),
    do: {:error, {:constraint_failed, constraint}}

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}), do: {:error, {:constraint_failed, Atom.to_string(type)}}

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    cond do
      Enum.any?(@sqlite_primary_key_messages, &String.contains?(normalized_message, &1)) ->
        {:error, :id_already_exists}

      String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") ->
        {:error, :database_busy}

      true ->
        {:error, {:storage_failed, message}}
    end
  end
end
