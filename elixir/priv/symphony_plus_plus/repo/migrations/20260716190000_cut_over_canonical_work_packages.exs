defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CutOverCanonicalWorkPackages do
  use Ecto.Migration

  @disable_ddl_transaction true
  def up do
    repo().checkout(&cut_over/0)
  end

  defp cut_over do
    query!("PRAGMA foreign_keys = OFF")

    try do
      transactional_cut_over()
    after
      query!("PRAGMA foreign_keys = ON")
    end
  end

  defp transactional_cut_over do
    query!("BEGIN IMMEDIATE")

    try do
      add_contract_columns()
      build_identity_map()
      migrate_work_packages()
      migrate_work_request_statuses()
      migrate_product_tree_links()
      migrate_deliveries()
      migrate_references()
      query!("DROP TABLE sympp_work_request_planned_slices")
      recreate_work_package_indexes()
      assert_cutover!()
      assert_foreign_keys!()
      query!("DROP TABLE sympp_canonical_work_package_map")
      query!("COMMIT")
    rescue
      exception ->
        query!("ROLLBACK")
        reraise exception, __STACKTRACE__
    end
  end

  def down do
    raise Ecto.MigrationError,
      message: "canonical WorkPackage cutover cannot restore removed PlannedSlice identities"
  end

  defp add_contract_columns do
    for statement <- [
          "ALTER TABLE sympp_work_packages ADD COLUMN work_request_id TEXT REFERENCES sympp_work_requests(id) ON DELETE CASCADE",
          "ALTER TABLE sympp_work_packages ADD COLUMN product_tree_node_id TEXT REFERENCES sympp_product_tree_nodes(id) ON DELETE SET NULL",
          "ALTER TABLE sympp_work_packages ADD COLUMN sequence INTEGER",
          "ALTER TABLE sympp_work_packages ADD COLUMN goal TEXT",
          "ALTER TABLE sympp_work_packages ADD COLUMN forbidden_file_globs TEXT NOT NULL DEFAULT '[]'",
          "ALTER TABLE sympp_work_packages ADD COLUMN validation_steps TEXT NOT NULL DEFAULT '[]'",
          "ALTER TABLE sympp_work_packages ADD COLUMN stop_conditions TEXT NOT NULL DEFAULT '[]'",
          "ALTER TABLE sympp_work_packages ADD COLUMN contract_revision INTEGER NOT NULL DEFAULT 1",
          "ALTER TABLE sympp_work_packages ADD COLUMN dispatched_at TEXT"
        ] do
      query!(statement)
    end
  end

  defp build_identity_map do
    query!("""
    CREATE TABLE sympp_canonical_work_package_map (
      old_id TEXT PRIMARY KEY NOT NULL,
      work_package_id TEXT NOT NULL UNIQUE
    )
    """)

    query!("""
    INSERT INTO sympp_canonical_work_package_map (old_id, work_package_id)
    SELECT slice.id, COALESCE(NULLIF(trim(slice.work_package_id), ''), 'wp_' || lower(hex(randomblob(12))))
    FROM sympp_work_request_planned_slices AS slice
    """)
  end

  defp migrate_work_packages do
    query!("""
    UPDATE sympp_work_packages
    SET
      work_request_id = (
        SELECT slice.work_request_id
        FROM sympp_work_request_planned_slices AS slice
        JOIN sympp_canonical_work_package_map AS identity ON identity.old_id = slice.id
        WHERE identity.work_package_id = sympp_work_packages.id
      ),
      product_tree_node_id = (
        SELECT link.product_tree_node_id
        FROM sympp_product_tree_slice_links AS link
        JOIN sympp_work_request_planned_slices AS slice ON slice.id = link.planned_slice_id
        JOIN sympp_canonical_work_package_map AS identity ON identity.old_id = slice.id
        WHERE identity.work_package_id = sympp_work_packages.id
      ),
      sequence = (
        SELECT slice.sequence
        FROM sympp_work_request_planned_slices AS slice
        JOIN sympp_canonical_work_package_map AS identity ON identity.old_id = slice.id
        WHERE identity.work_package_id = sympp_work_packages.id
      ),
      goal = (
        SELECT slice.goal
        FROM sympp_work_request_planned_slices AS slice
        JOIN sympp_canonical_work_package_map AS identity ON identity.old_id = slice.id
        WHERE identity.work_package_id = sympp_work_packages.id
      ),
      forbidden_file_globs = COALESCE((
        SELECT slice.forbidden_file_globs
        FROM sympp_work_request_planned_slices AS slice
        JOIN sympp_canonical_work_package_map AS identity ON identity.old_id = slice.id
        WHERE identity.work_package_id = sympp_work_packages.id
      ), '[]'),
      validation_steps = COALESCE((
        SELECT slice.validation_steps
        FROM sympp_work_request_planned_slices AS slice
        JOIN sympp_canonical_work_package_map AS identity ON identity.old_id = slice.id
        WHERE identity.work_package_id = sympp_work_packages.id
      ), '[]'),
      stop_conditions = COALESCE((
        SELECT slice.stop_conditions
        FROM sympp_work_request_planned_slices AS slice
        JOIN sympp_canonical_work_package_map AS identity ON identity.old_id = slice.id
        WHERE identity.work_package_id = sympp_work_packages.id
      ), '[]'),
      contract_revision = 1,
      dispatched_at = (
        SELECT slice.dispatched_at
        FROM sympp_work_request_planned_slices AS slice
        JOIN sympp_canonical_work_package_map AS identity ON identity.old_id = slice.id
        WHERE identity.work_package_id = sympp_work_packages.id
      )
    WHERE EXISTS (
      SELECT 1
      FROM sympp_work_request_planned_slices AS slice
      JOIN sympp_canonical_work_package_map AS identity ON identity.old_id = slice.id
      WHERE identity.work_package_id = sympp_work_packages.id
    )
    """)

    query!("""
    INSERT INTO sympp_work_packages (
      id,
      kind,
      title,
      repo,
      base_branch,
      branch_pattern,
      product_description,
      engineering_scope,
      acceptance_criteria,
      status,
      parent_id,
      owner_id,
      inserted_at,
      updated_at,
      allowed_file_globs,
      policy_template,
      phase_id,
      worktree_path,
      worktree_target_repo_root,
      review_lanes,
      review_requirement,
      work_request_id,
      product_tree_node_id,
      sequence,
      goal,
      forbidden_file_globs,
      validation_steps,
      stop_conditions,
      contract_revision,
      dispatched_at
    )
    SELECT
      identity.work_package_id,
      slice.work_package_kind,
      slice.title,
      COALESCE(NULLIF(slice.delivery_repo, ''), request.repo),
      slice.target_base_branch,
      slice.branch_pattern,
      request.human_description,
      slice.goal,
      slice.acceptance_criteria,
      CASE slice.status WHEN 'approved' THEN 'planned' ELSE 'skipped' END,
      NULL,
      NULL,
      slice.inserted_at,
      slice.updated_at,
      slice.owned_file_globs,
      slice.work_package_kind,
      NULL,
      NULL,
      NULL,
      slice.review_lanes,
      slice.review_requirement,
      slice.work_request_id,
      link.product_tree_node_id,
      slice.sequence,
      slice.goal,
      slice.forbidden_file_globs,
      slice.validation_steps,
      slice.stop_conditions,
      1,
      NULL
    FROM sympp_work_request_planned_slices AS slice
    JOIN sympp_canonical_work_package_map AS identity ON identity.old_id = slice.id
    JOIN sympp_work_requests AS request ON request.id = slice.work_request_id
    LEFT JOIN sympp_product_tree_slice_links AS link ON link.planned_slice_id = slice.id
    WHERE slice.work_package_id IS NULL OR trim(slice.work_package_id) = ''
    """)
  end

  defp migrate_work_request_statuses do
    query!("""
    UPDATE sympp_work_requests
    SET status = 'sliced'
    WHERE status = 'ready_for_slicing'
      AND EXISTS (
        SELECT 1
        FROM sympp_work_packages AS work_package
        WHERE work_package.work_request_id = sympp_work_requests.id
          AND (work_package.status = 'planned' OR work_package.dispatched_at IS NOT NULL)
      )
    """)
  end

  defp migrate_product_tree_links do
    query!("DROP TABLE sympp_product_tree_slice_links")
  end

  defp migrate_deliveries do
    query!("""
    CREATE TABLE sympp_work_package_deliveries (
      id TEXT PRIMARY KEY NOT NULL,
      work_request_id TEXT NOT NULL REFERENCES sympp_work_requests(id) ON DELETE CASCADE,
      work_package_id TEXT NOT NULL REFERENCES sympp_work_packages(id) ON DELETE CASCADE,
      outcome TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      recorded_by TEXT,
      recorded_at TEXT NOT NULL,
      pr_url TEXT,
      pr_number INTEGER,
      pr_repository TEXT,
      pr_merged_at TEXT,
      merge_commit_sha TEXT,
      no_pr_evidence TEXT,
      successor_work_package_id TEXT REFERENCES sympp_work_packages(id),
      superseded_reason TEXT,
      abandoned_rationale TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    query!("""
    INSERT INTO sympp_work_package_deliveries
    SELECT
      delivery.id,
      delivery.work_request_id,
      identity.work_package_id,
      delivery.outcome,
      delivery.idempotency_key,
      delivery.recorded_by,
      delivery.recorded_at,
      delivery.pr_url,
      delivery.pr_number,
      delivery.pr_repository,
      delivery.pr_merged_at,
      delivery.merge_commit_sha,
      delivery.no_pr_evidence,
      COALESCE(delivery.successor_work_package_id, successor.work_package_id),
      delivery.superseded_reason,
      delivery.abandoned_rationale,
      delivery.inserted_at,
      delivery.updated_at
    FROM sympp_work_request_planned_slice_deliveries AS delivery
    JOIN sympp_canonical_work_package_map AS identity ON identity.old_id = delivery.planned_slice_id
    LEFT JOIN sympp_canonical_work_package_map AS successor ON successor.old_id = delivery.successor_planned_slice_id
    """)

    query!("DROP TABLE sympp_work_request_planned_slice_deliveries")
    query!("CREATE UNIQUE INDEX sympp_work_package_deliveries_id_unique_index ON sympp_work_package_deliveries (id)")
    query!("CREATE UNIQUE INDEX sympp_work_package_deliveries_package_unique_index ON sympp_work_package_deliveries (work_package_id)")
  end

  defp migrate_references do
    query!("""
    DELETE FROM sympp_access_grant_scopes
    WHERE scope_type = 'planned_slice'
      AND EXISTS (
        SELECT 1
        FROM sympp_canonical_work_package_map AS identity
        JOIN sympp_access_grant_scopes AS package_scope
          ON package_scope.access_grant_id = sympp_access_grant_scopes.access_grant_id
         AND package_scope.scope_type = 'work_package'
         AND package_scope.scope_id = identity.work_package_id
        WHERE identity.old_id = sympp_access_grant_scopes.scope_id
      )
    """)

    query!("""
    UPDATE sympp_access_grant_scopes
    SET
      scope_type = 'work_package',
      scope_id = (SELECT work_package_id FROM sympp_canonical_work_package_map WHERE old_id = sympp_access_grant_scopes.scope_id),
      scope_key = 'work_package:' || (SELECT work_package_id FROM sympp_canonical_work_package_map WHERE old_id = sympp_access_grant_scopes.scope_id)
    WHERE scope_type = 'planned_slice'
    """)

    for {table, kind_column, id_column} <- [
          {"sympp_comments", "target_kind", "target_id"},
          {"sympp_operator_audit_events", "target_type", "target_id"},
          {"sympp_product_tree_dependency_edges", "source_kind", "source_id"},
          {"sympp_product_tree_dependency_edges", "target_kind", "target_id"}
        ] do
      query!("""
      UPDATE #{table}
      SET
        #{kind_column} = 'work_package',
        #{id_column} = (SELECT work_package_id FROM sympp_canonical_work_package_map WHERE old_id = #{table}.#{id_column})
      WHERE #{kind_column} = 'planned_slice'
      """)
    end

    rewrite_payload_references()
  end

  defp rewrite_payload_references do
    id_map =
      query!("SELECT old_id, work_package_id FROM sympp_canonical_work_package_map").rows
      |> Map.new(fn [old_id, work_package_id] -> {old_id, work_package_id} end)

    if column_exists?("sympp_product_tree_revisions", "tree_snapshot") do
      rewrite_product_tree_snapshots(id_map)
    end

    if column_exists?("sympp_progress_events", "payload") do
      rewrite_progress_references(id_map)
    end
  end

  defp rewrite_product_tree_snapshots(id_map) do
    %{rows: rows} = query!("SELECT id, tree_snapshot FROM sympp_product_tree_revisions WHERE tree_snapshot IS NOT NULL")

    for [id, encoded] <- rows,
        {:ok, payload} <- [Jason.decode(encoded)],
        rewritten = rewrite_product_tree_snapshot(payload, id_map),
        rewritten != payload do
      repo().query!("UPDATE sympp_product_tree_revisions SET tree_snapshot = ? WHERE id = ?", [Jason.encode!(rewritten), id])
    end
  end

  defp rewrite_product_tree_snapshot(%{} = snapshot, id_map) do
    snapshot
    |> move_key("root_slice_ids", "root_work_package_ids", &rewrite_ids(&1, id_map))
    |> update_known_value("mode", &if(&1 == "direct_slices", do: "direct_work_packages", else: &1))
    |> update_known_list("nodes", &rewrite_product_tree_node(&1, id_map))
    |> update_known_list("dependency_edges", &rewrite_product_tree_edge(&1, id_map))
    |> update_known_value("summary", &rewrite_product_tree_summary/1)
  end

  defp rewrite_product_tree_snapshot(value, _id_map), do: value

  defp rewrite_product_tree_node(%{} = node, id_map) do
    node
    |> move_key("slice_ids", "work_package_ids", &rewrite_ids(&1, id_map))
    |> move_key("slice_count", "work_package_count", & &1)
  end

  defp rewrite_product_tree_node(value, _id_map), do: value

  defp rewrite_product_tree_edge(%{} = edge, id_map) do
    edge
    |> update_known_value("source", &rewrite_product_tree_endpoint(&1, id_map))
    |> update_known_value("target", &rewrite_product_tree_endpoint(&1, id_map))
  end

  defp rewrite_product_tree_edge(value, _id_map), do: value

  defp rewrite_product_tree_endpoint(%{"kind" => "planned_slice"} = endpoint, id_map) do
    endpoint
    |> Map.put("kind", "work_package")
    |> update_known_value("id", &Map.get(id_map, &1, &1))
  end

  defp rewrite_product_tree_endpoint(value, _id_map), do: value

  defp rewrite_product_tree_summary(%{} = summary) do
    summary
    |> move_key("root_slice_count", "root_work_package_count", & &1)
    |> move_key("slice_count", "work_package_count", & &1)
    |> move_key("linked_slice_count", "node_work_package_count", & &1)
  end

  defp rewrite_product_tree_summary(value), do: value

  defp rewrite_progress_references(id_map) do
    %{rows: rows} =
      query!("SELECT id, work_package_id, idempotency_key, payload FROM sympp_progress_events WHERE payload IS NOT NULL")

    Enum.each(rows, fn [id, work_package_id, idempotency_key, encoded] ->
      with {:ok, payload} <- Jason.decode(encoded) do
        rewritten_payload = rewrite_progress_payload(payload, id_map)
        rewritten_key = rewrite_closeout_idempotency_key(idempotency_key, payload, id_map)
        rewritten_work_package_id = rewrite_closeout_work_package_id(work_package_id, payload, id_map)

        if {rewritten_payload, rewritten_key, rewritten_work_package_id} != {payload, idempotency_key, work_package_id} do
          repo().query!(
            "UPDATE sympp_progress_events SET work_package_id = ?, idempotency_key = ?, payload = ? WHERE id = ?",
            [rewritten_work_package_id, rewritten_key, Jason.encode!(rewritten_payload), id]
          )
        end
      end
    end)
  end

  defp rewrite_progress_payload(payload, id_map) do
    payload
    |> rewrite_blocker_progress_payload(id_map)
    |> rewrite_closeout_progress_payload(id_map)
  end

  defp rewrite_blocker_progress_payload(%{"type" => "blocker", "source_tool" => source_tool} = payload, id_map)
       when source_tool in ["report_blocker", "resolve_blocker"] do
    payload
    |> update_known_value("blocked_by", &rewrite_blocker_endpoint(&1, id_map))
    |> update_known_value("blocked_item", &rewrite_blocker_endpoint(&1, id_map))
  end

  defp rewrite_blocker_progress_payload(payload, _id_map), do: payload

  defp rewrite_closeout_progress_payload(
         %{
           "type" => "work_request_delivery_closeout",
           "source_tool" => "record_planned_slice_delivery",
           "planned_slice_id" => planned_slice_id
         } = payload,
         id_map
       ) do
    case Map.fetch(id_map, planned_slice_id) do
      {:ok, work_package_id} ->
        payload
        |> Map.delete("planned_slice_id")
        |> Map.put("source_tool", "record_work_package_delivery")
        |> Map.put("work_package_id", work_package_id)
        |> move_key("successor_planned_slice_id", "successor_work_package_id", &Map.get(id_map, &1, &1))

      :error ->
        payload
    end
  end

  defp rewrite_closeout_progress_payload(payload, _id_map), do: payload

  defp rewrite_closeout_idempotency_key(
         idempotency_key,
         %{
           "type" => "work_request_delivery_closeout",
           "source_tool" => "record_planned_slice_delivery",
           "work_request_id" => work_request_id,
           "planned_slice_id" => planned_slice_id
         },
         id_map
       )
       when is_binary(idempotency_key) and is_binary(work_request_id) and is_binary(planned_slice_id) do
    legacy_prefix = "work_request_delivery_closeout:#{work_request_id}:#{planned_slice_id}:"

    with {:ok, work_package_id} <- Map.fetch(id_map, planned_slice_id),
         true <- String.starts_with?(idempotency_key, legacy_prefix) do
      canonical_prefix = "work_request_delivery_closeout:#{work_request_id}:#{work_package_id}:"
      String.replace_prefix(idempotency_key, legacy_prefix, canonical_prefix)
    else
      _unmatched -> idempotency_key
    end
  end

  defp rewrite_closeout_idempotency_key(idempotency_key, _payload, _id_map), do: idempotency_key

  defp rewrite_closeout_work_package_id(
         work_package_id,
         %{
           "type" => "work_request_delivery_closeout",
           "source_tool" => "record_planned_slice_delivery",
           "planned_slice_id" => planned_slice_id
         },
         id_map
       ) do
    Map.get(id_map, planned_slice_id, work_package_id)
  end

  defp rewrite_closeout_work_package_id(work_package_id, _payload, _id_map), do: work_package_id

  defp rewrite_blocker_endpoint(%{"kind" => kind, "id" => id} = endpoint, id_map)
       when kind in ["planned_slice", "slice"] and is_binary(id) do
    case Map.fetch(id_map, id) do
      {:ok, work_package_id} -> %{endpoint | "kind" => "work_package", "id" => work_package_id}
      :error -> endpoint
    end
  end

  defp rewrite_blocker_endpoint(endpoint, _id_map), do: endpoint

  defp rewrite_ids(values, id_map) when is_list(values), do: Enum.map(values, &Map.get(id_map, &1, &1))
  defp rewrite_ids(value, _id_map), do: value

  defp update_known_list(map, key, fun) do
    update_known_value(map, key, fn
      values when is_list(values) -> Enum.map(values, fun)
      value -> value
    end)
  end

  defp update_known_value(map, key, fun) do
    case Map.fetch(map, key) do
      {:ok, value} -> Map.put(map, key, fun.(value))
      :error -> map
    end
  end

  defp move_key(map, legacy_key, canonical_key, fun) do
    case Map.fetch(map, legacy_key) do
      {:ok, value} -> map |> Map.delete(legacy_key) |> Map.put_new(canonical_key, fun.(value))
      :error -> map
    end
  end

  defp recreate_work_package_indexes do
    query!("CREATE UNIQUE INDEX sympp_work_packages_work_request_sequence_unique_index ON sympp_work_packages (work_request_id, sequence) WHERE work_request_id IS NOT NULL")
    query!("CREATE INDEX sympp_work_packages_work_request_status_index ON sympp_work_packages (work_request_id, status, sequence)")
    query!("CREATE INDEX sympp_work_packages_product_tree_node_index ON sympp_work_packages (product_tree_node_id, sequence)")
  end

  defp assert_cutover! do
    assert_zero!("SELECT count(*) FROM sqlite_master WHERE name LIKE '%planned_slice%'")
    assert_zero!("SELECT count(*) FROM sympp_access_grant_scopes WHERE scope_type = 'planned_slice'")
    assert_zero!("SELECT count(*) FROM sympp_comments WHERE target_kind = 'planned_slice'")
    assert_zero!("SELECT count(*) FROM sympp_product_tree_dependency_edges WHERE source_kind = 'planned_slice' OR target_kind = 'planned_slice'")
  end

  defp assert_zero!(sql) do
    case query!(sql) do
      %{rows: [[0]]} -> :ok
      %{rows: [[count]]} -> raise Ecto.MigrationError, message: "canonical WorkPackage cutover left #{count} stale identities"
    end
  end

  defp assert_foreign_keys! do
    case query!("PRAGMA foreign_key_check") do
      %{rows: []} -> :ok
      %{rows: rows} -> raise Ecto.MigrationError, message: "canonical WorkPackage cutover left foreign-key violations: #{inspect(rows)}"
    end
  end

  defp column_exists?(table, column) do
    %{rows: rows} = query!("PRAGMA table_info(#{table})")
    Enum.any?(rows, &(Enum.at(&1, 1) == column))
  end

  defp query!(sql), do: repo().query!(sql)
end
