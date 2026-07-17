defmodule SymphonyElixir.SymphonyPlusPlus.CanonicalWorkPackageMigrationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @cutover_version 20_260_716_190_000
  @pre_cutover_version 20_260_714_160_000

  test "populated legacy ledger migrates to one canonical WorkPackage identity" do
    database_path =
      Path.join(
        System.tmp_dir!(),
        "sympp-canonical-work-packages-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3"
      )

    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      migrated = Ecto.Migrator.run(Repo, Migrations.all(), :up, to: @pre_cutover_version, log: false)
      assert @pre_cutover_version in migrated

      seed_legacy_ledger!()

      assert [@cutover_version] = Ecto.Migrator.run(Repo, Migrations.all(), :up, all: true, log: false)

      assert [["WP-LINKED", "WR-CANONICAL-MIGRATION", "PTN-CANONICAL", 1, "Linked legacy goal", "ready_for_worker"]] =
               rows!("""
               SELECT id, work_request_id, product_tree_node_id, sequence, goal, status
               FROM sympp_work_packages
               WHERE id = 'WP-LINKED'
               """)

      assert [[generated_id, "WR-CANONICAL-MIGRATION", nil, 2, "Undispatched legacy goal", "planned"]] =
               rows!("""
               SELECT id, work_request_id, product_tree_node_id, sequence, goal, status
               FROM sympp_work_packages
               WHERE work_request_id = 'WR-CANONICAL-MIGRATION' AND sequence = 2
               """)

      assert String.starts_with?(generated_id, "wp_")
      refute generated_id == "WRS-UNDISPATCHED"

      assert [[quarantined_id, "skipped"]] =
               rows!("""
               SELECT id, status
               FROM sympp_work_packages
               WHERE work_request_id = 'WR-CANONICAL-MIGRATION' AND sequence = 3
               """)

      assert String.starts_with?(quarantined_id, "wp_")
      refute quarantined_id in ["WRS-UNAPPROVED", generated_id]

      assert [["sliced"]] = rows!("SELECT status FROM sympp_work_requests WHERE id = 'WR-CANONICAL-MIGRATION'")
      assert [["sliced"]] = rows!("SELECT status FROM sympp_work_requests WHERE id = 'WR-DISPATCHED-MIGRATION'")

      assert [["WP-DIRECT", nil, "phase_child", "PHASE-DIRECT"]] =
               rows!("SELECT id, work_request_id, kind, phase_id FROM sympp_work_packages WHERE id = 'WP-DIRECT'")

      assert [["work_package", "WP-LINKED", "work_package:WP-LINKED"]] =
               rows!("SELECT scope_type, scope_id, scope_key FROM sympp_access_grant_scopes WHERE id = 'AGS-LEGACY-SLICE'")

      assert [["work_package", "WP-LINKED"]] =
               rows!("SELECT target_kind, target_id FROM sympp_comments WHERE id = 'COMMENT-LEGACY-SLICE'")

      assert [["work_package", "WP-LINKED", "work_package", ^generated_id]] =
               rows!("""
               SELECT source_kind, source_id, target_kind, target_id
               FROM sympp_product_tree_dependency_edges
               WHERE id = 'EDGE-LEGACY-SLICES'
               """)

      assert [[^generated_id, "WP-LINKED"]] =
               rows!("""
               SELECT work_package_id, successor_work_package_id
               FROM sympp_work_package_deliveries
               WHERE id = 'DELIVERY-LEGACY-SLICE'
               """)

      assert [[encoded_payload]] = rows!("SELECT payload FROM sympp_progress_events WHERE id = 'PROGRESS-LEGACY-PAYLOAD'")

      assert %{
               "planned_slice_id" => "WRS-LINKED",
               "kind" => "planned_slice",
               "exact_note" => "WRS-LINKED",
               "note" => "planned slice WRS-LINKED remains prose"
             } = Jason.decode!(encoded_payload)

      assert [[encoded_blocker]] = rows!("SELECT payload FROM sympp_progress_events WHERE id = 'PROGRESS-LEGACY-BLOCKER'")

      assert %{
               "type" => "blocker",
               "source_tool" => "report_blocker",
               "blocked_by" => %{"kind" => "work_package", "id" => "WP-LINKED"},
               "blocked_item" => %{"kind" => "work_package", "id" => ^generated_id},
               "details" => %{"kind" => "planned_slice", "id" => "WRS-LINKED"}
             } = Jason.decode!(encoded_blocker)

      assert [["WP-CLOSEOUT", canonical_closeout_key, encoded_closeout]] =
               rows!("""
               SELECT work_package_id, idempotency_key, payload
               FROM sympp_progress_events
               WHERE id = 'PROGRESS-LEGACY-CLOSEOUT'
               """)

      assert canonical_closeout_key ==
               "work_request_delivery_closeout:WR-CANONICAL-MIGRATION:WP-CLOSEOUT:closeout-delivery"

      decoded_closeout = Jason.decode!(encoded_closeout)

      assert %{
               "type" => "work_request_delivery_closeout",
               "source_tool" => "record_work_package_delivery",
               "work_request_id" => "WR-CANONICAL-MIGRATION",
               "work_package_id" => "WP-CLOSEOUT",
               "delivery_id" => "DELIVERY-LEGACY-CLOSEOUT",
               "outcome" => "superseded",
               "next_status" => "closed",
               "successor_work_package_id" => "WP-LINKED"
             } = decoded_closeout

      refute Map.has_key?(decoded_closeout, "planned_slice_id")
      refute Map.has_key?(decoded_closeout, "successor_planned_slice_id")

      assert [[encoded_snapshot]] =
               rows!("SELECT tree_snapshot FROM sympp_product_tree_revisions WHERE id = 'REVISION-LEGACY-SNAPSHOT'")

      assert %{
               "mode" => "direct_work_packages",
               "root_work_package_ids" => [^generated_id],
               "nodes" => [
                 %{
                   "id" => "PTN-CANONICAL",
                   "work_package_ids" => ["WP-LINKED"],
                   "work_package_count" => 1,
                   "metadata" => %{"planned_slice_id" => "WRS-LINKED", "kind" => "planned_slice"}
                 }
               ],
               "dependency_edges" => [
                 %{
                   "source" => %{"kind" => "work_package", "id" => "WP-LINKED"},
                   "target" => %{"kind" => "work_package", "id" => ^generated_id}
                 }
               ],
               "summary" => %{
                 "root_work_package_count" => 1,
                 "work_package_count" => 2,
                 "node_work_package_count" => 1
               },
               "free_form" => %{"planned_slice_id" => "WRS-LINKED", "kind" => "planned_slice"}
             } = Jason.decode!(encoded_snapshot)

      assert [] == rows!("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '%planned_slice%'")
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
      File.rm(database_path)
    end
  end

  defp seed_legacy_ledger! do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(
      WorkRequest.create_changeset(%{
        id: "WR-CANONICAL-MIGRATION",
        title: "Canonical migration",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        work_type: "refactor",
        human_description: "Cut over legacy identities.",
        constraints: %{},
        desired_dispatch_shape: "single_package",
        status: "ready_for_slicing"
      })
    )

    Repo.insert!(
      WorkRequest.create_changeset(%{
        id: "WR-DISPATCHED-MIGRATION",
        title: "Dispatched canonical migration",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        work_type: "refactor",
        human_description: "Preserve a dispatched-only request.",
        constraints: %{},
        desired_dispatch_shape: "single_package",
        status: "ready_for_slicing"
      })
    )

    query!("INSERT INTO sympp_phases (id, title, status, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?)", [
      "PHASE-DIRECT",
      "Direct phase",
      "active",
      now,
      now
    ])

    insert_legacy_work_package!("WP-LINKED", "mcp", nil, "ready_for_worker", now)
    insert_legacy_work_package!("WP-CLOSEOUT", "mcp", nil, "closed", now)
    insert_legacy_work_package!("WP-DISPATCHED", "mcp", nil, "ready_for_worker", now)
    insert_legacy_work_package!("WP-DIRECT", "phase_child", "PHASE-DIRECT", "ready_for_worker", now)

    query!(
      """
      INSERT INTO sympp_product_tree_nodes
        (id, work_request_id, title, completion_mark, metadata, position, created_at, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      ["PTN-CANONICAL", "WR-CANONICAL-MIGRATION", "Canonical node", "unknown", "{}", 0, now, now, now]
    )

    insert_legacy_slice!(
      [
        id: "WRS-LINKED",
        sequence: 1,
        title: "Linked legacy package",
        goal: "Linked legacy goal",
        status: "approved",
        work_package_id: "WP-LINKED",
        dispatched_at: now
      ],
      now
    )

    insert_legacy_slice!(
      [
        id: "WRS-CLOSEOUT",
        sequence: 4,
        title: "Closed legacy package",
        goal: "Closed legacy goal",
        status: "dispatched",
        work_package_id: "WP-CLOSEOUT",
        dispatched_at: now
      ],
      now
    )

    insert_legacy_slice!(
      [
        id: "WRS-DISPATCHED",
        work_request_id: "WR-DISPATCHED-MIGRATION",
        sequence: 1,
        title: "Dispatched legacy package",
        goal: "Dispatched legacy goal",
        status: "dispatched",
        work_package_id: "WP-DISPATCHED",
        dispatched_at: now
      ],
      now
    )

    insert_legacy_slice!(
      [
        id: "WRS-UNDISPATCHED",
        sequence: 2,
        title: "Undispatched legacy package",
        goal: "Undispatched legacy goal",
        status: "approved"
      ],
      now
    )

    insert_legacy_slice!(
      [
        id: "WRS-UNAPPROVED",
        sequence: 3,
        title: "Unapproved legacy package",
        goal: "Unapproved legacy goal",
        status: "planned"
      ],
      now
    )

    query!(
      """
      INSERT INTO sympp_product_tree_slice_links
        (id, work_request_id, product_tree_node_id, planned_slice_id, role, position, created_at, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      ["PTSL-CANONICAL", "WR-CANONICAL-MIGRATION", "PTN-CANONICAL", "WRS-LINKED", "implementation_slice", 0, now, now, now]
    )

    grant =
      Repo.insert!(
        AccessGrant.create_changeset(%{
          id: "GRANT-LEGACY-SLICE",
          work_package_id: "WP-LINKED",
          display_key: "ABCD",
          secret_hash: String.duplicate("a", 64),
          grant_role: "worker",
          capabilities: ["read:assignment"],
          expires_at: DateTime.add(now, 3_600, :second)
        })
      )

    query!(
      """
      INSERT INTO sympp_access_grant_scopes
        (id, access_grant_id, scope_type, scope_key, scope_id, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      ["AGS-LEGACY-SLICE", grant.id, "planned_slice", "planned_slice:WRS-LINKED", "WRS-LINKED", now, now]
    )

    query!(
      """
      INSERT INTO sympp_comments
        (id, target_kind, target_id, body, source_type, author_name, status, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      ["COMMENT-LEGACY-SLICE", "planned_slice", "WRS-LINKED", "Legacy comment", "architect", "architect", "open", now, now]
    )

    query!(
      """
      INSERT INTO sympp_product_tree_dependency_edges
        (id, work_request_id, source_kind, source_id, target_kind, target_id, kind, reason, created_at, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        "EDGE-LEGACY-SLICES",
        "WR-CANONICAL-MIGRATION",
        "planned_slice",
        "WRS-LINKED",
        "planned_slice",
        "WRS-UNDISPATCHED",
        "related",
        "Migration evidence",
        now,
        now,
        now
      ]
    )

    query!(
      """
      INSERT INTO sympp_work_request_planned_slice_deliveries
        (id, work_request_id, planned_slice_id, outcome, idempotency_key, recorded_at,
         successor_planned_slice_id, superseded_reason, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        "DELIVERY-LEGACY-SLICE",
        "WR-CANONICAL-MIGRATION",
        "WRS-UNDISPATCHED",
        "superseded",
        "legacy-delivery",
        now,
        "WRS-LINKED",
        "Use the dispatched package",
        now,
        now
      ]
    )

    query!(
      """
      INSERT INTO sympp_work_request_planned_slice_deliveries
        (id, work_request_id, planned_slice_id, outcome, idempotency_key, recorded_at,
         successor_planned_slice_id, superseded_reason, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        "DELIVERY-LEGACY-CLOSEOUT",
        "WR-CANONICAL-MIGRATION",
        "WRS-CLOSEOUT",
        "superseded",
        "closeout-delivery",
        now,
        "WRS-LINKED",
        "Legacy closeout",
        now,
        now
      ]
    )

    query!(
      """
      INSERT INTO sympp_progress_events
        (id, work_package_id, summary, status, sequence, created_at, inserted_at, updated_at, payload)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        "PROGRESS-LEGACY-PAYLOAD",
        "WP-LINKED",
        "Legacy payload",
        "implementing",
        1,
        now,
        now,
        now,
        Jason.encode!(%{
          "planned_slice_id" => "WRS-LINKED",
          "kind" => "planned_slice",
          "exact_note" => "WRS-LINKED",
          "note" => "planned slice WRS-LINKED remains prose"
        })
      ]
    )

    query!(
      """
      INSERT INTO sympp_progress_events
        (id, work_package_id, summary, status, sequence, idempotency_key,
         created_at, inserted_at, updated_at, payload)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        "PROGRESS-LEGACY-CLOSEOUT",
        "WP-CLOSEOUT",
        "Legacy delivery closeout",
        "closed",
        1,
        "work_request_delivery_closeout:WR-CANONICAL-MIGRATION:WRS-CLOSEOUT:closeout-delivery",
        now,
        now,
        now,
        Jason.encode!(%{
          "type" => "work_request_delivery_closeout",
          "source_tool" => "record_planned_slice_delivery",
          "work_request_id" => "WR-CANONICAL-MIGRATION",
          "planned_slice_id" => "WRS-CLOSEOUT",
          "delivery_id" => "DELIVERY-LEGACY-CLOSEOUT",
          "outcome" => "superseded",
          "next_status" => "closed",
          "successor_planned_slice_id" => "WRS-LINKED"
        })
      ]
    )

    query!(
      """
      INSERT INTO sympp_product_tree_revisions
        (id, work_request_id, revision_number, tree_snapshot, reason, created_at, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        "REVISION-LEGACY-SNAPSHOT",
        "WR-CANONICAL-MIGRATION",
        1,
        Jason.encode!(%{
          "mode" => "direct_slices",
          "root_slice_ids" => ["WRS-UNDISPATCHED"],
          "nodes" => [
            %{
              "id" => "PTN-CANONICAL",
              "slice_ids" => ["WRS-LINKED"],
              "slice_count" => 1,
              "metadata" => %{"planned_slice_id" => "WRS-LINKED", "kind" => "planned_slice"}
            }
          ],
          "dependency_edges" => [
            %{
              "source" => %{"kind" => "planned_slice", "id" => "WRS-LINKED"},
              "target" => %{"kind" => "planned_slice", "id" => "WRS-UNDISPATCHED"}
            }
          ],
          "summary" => %{"root_slice_count" => 1, "slice_count" => 2, "linked_slice_count" => 1},
          "free_form" => %{"planned_slice_id" => "WRS-LINKED", "kind" => "planned_slice"}
        }),
        "Legacy snapshot",
        now,
        now,
        now
      ]
    )

    query!(
      """
      INSERT INTO sympp_progress_events
        (id, work_package_id, summary, status, sequence, created_at, inserted_at, updated_at, payload)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        "PROGRESS-LEGACY-BLOCKER",
        "WP-LINKED",
        "Legacy blocker",
        "blocked",
        2,
        now,
        now,
        now,
        Jason.encode!(%{
          "type" => "blocker",
          "source_tool" => "report_blocker",
          "blocked_by" => %{"kind" => "planned_slice", "id" => "WRS-LINKED"},
          "blocked_item" => %{"kind" => "slice", "id" => "WRS-UNDISPATCHED"},
          "details" => %{"kind" => "planned_slice", "id" => "WRS-LINKED"}
        })
      ]
    )
  end

  defp insert_legacy_work_package!(id, kind, phase_id, status, now) do
    query!(
      """
      INSERT INTO sympp_work_packages
        (id, kind, title, repo, base_branch, branch_pattern, product_description,
         engineering_scope, acceptance_criteria, status, parent_id, owner_id,
         inserted_at, updated_at, allowed_file_globs, policy_template, phase_id,
         worktree_path, worktree_target_repo_root, review_lanes, review_requirement)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        id,
        kind,
        "Legacy #{id}",
        "nextide/symphony-plus-plus",
        "main",
        "refactor/canonical-work-packages",
        "Canonical identity",
        "Preserve #{id}",
        ~s(["Preserved"]),
        status,
        nil,
        nil,
        now,
        now,
        ~s(["elixir/**"]),
        kind,
        phase_id,
        nil,
        nil,
        "[]",
        nil
      ]
    )
  end

  defp insert_legacy_slice!(attrs, now) do
    query!(
      """
      INSERT INTO sympp_work_request_planned_slices
        (id, work_request_id, sequence, title, goal, work_package_kind, target_base_branch,
         branch_pattern, owned_file_globs, forbidden_file_globs, acceptance_criteria,
         validation_steps, review_lanes, stop_conditions, status, work_package_id,
         dispatched_at, delivery_repo, review_requirement, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        Keyword.fetch!(attrs, :id),
        Keyword.get(attrs, :work_request_id, "WR-CANONICAL-MIGRATION"),
        Keyword.fetch!(attrs, :sequence),
        Keyword.fetch!(attrs, :title),
        Keyword.fetch!(attrs, :goal),
        "mcp",
        "main",
        "refactor/canonical-work-packages",
        ~s(["elixir/**"]),
        "[]",
        ~s(["Migrated"]),
        ~s(["mix test"]),
        "[]",
        ~s(["Stop on failure"]),
        Keyword.fetch!(attrs, :status),
        Keyword.get(attrs, :work_package_id),
        Keyword.get(attrs, :dispatched_at),
        "nextide/symphony-plus-plus",
        nil,
        now,
        now
      ]
    )
  end

  defp rows!(sql), do: query!(sql).rows
  defp query!(sql, params \\ []), do: Repo.query!(sql, params)
end
