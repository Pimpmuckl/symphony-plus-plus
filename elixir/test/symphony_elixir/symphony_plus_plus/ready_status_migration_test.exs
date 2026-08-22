defmodule SymphonyElixir.SymphonyPlusPlus.ReadyStatusMigrationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{WorkPackage, WorkPackageDelivery}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @migration_version 20_260_822_010_000
  @cleanup_queue_version 20_260_822_190_000
  @previous_version 20_260_803_143_000

  test "canonicalizes merge-ready status without changing claim or delivery records" do
    database_path =
      Path.join(
        System.tmp_dir!(),
        "sympp-ready-status-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3"
      )

    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      assert @previous_version in Ecto.Migrator.run(Repo, Migrations.all(), :up, to: @previous_version, log: false)

      seed_legacy_ready_package!()

      claim_before = rows!("SELECT * FROM sympp_claim_leases WHERE id = 'CLAIM-READY-STATUS'")
      delivery_before = rows!("SELECT * FROM sympp_work_package_deliveries WHERE id = 'DELIVERY-READY-STATUS'")

      assert [@migration_version, @cleanup_queue_version] =
               Ecto.Migrator.run(Repo, Migrations.all(), :up, all: true, log: false)

      assert [["ready_for_merge"]] = rows!("SELECT status FROM sympp_work_packages WHERE id = 'WP-READY-STATUS'")
      assert claim_before == rows!("SELECT * FROM sympp_claim_leases WHERE id = 'CLAIM-READY-STATUS'")
      assert delivery_before == rows!("SELECT * FROM sympp_work_package_deliveries WHERE id = 'DELIVERY-READY-STATUS'")
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
      File.rm(database_path)
    end
  end

  defp seed_legacy_ready_package! do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(
      WorkRequest.create_changeset(%{
        id: "WR-READY-STATUS",
        title: "Ready status migration",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        work_type: "refactor",
        human_description: "Canonicalize persisted readiness.",
        constraints: %{},
        desired_dispatch_shape: "single_package",
        status: "sliced"
      })
    )

    Repo.insert!(
      WorkPackage.create_changeset(%{
        id: "WP-READY-STATUS",
        work_request_id: "WR-READY-STATUS",
        sequence: 1,
        kind: "standard_pr",
        title: "Canonicalize readiness",
        goal: "Preserve delivery and claim state.",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        branch_pattern: "cleanup/ready-status",
        engineering_scope: "Update the persisted status only.",
        acceptance_criteria: ["Status is canonical."],
        status: "ready_for_merge"
      })
    )

    Repo.insert!(
      ClaimLease.create_changeset(
        %{
          id: "CLAIM-READY-STATUS",
          work_package_id: "WP-READY-STATUS",
          actor_id: "ready-status-worker",
          actor_display_name: "Ready status worker",
          stale_after_ms: 300_000
        },
        now: now
      )
    )

    Repo.insert!(
      WorkPackageDelivery.create_changeset(%{
        id: "DELIVERY-READY-STATUS",
        work_request_id: "WR-READY-STATUS",
        work_package_id: "WP-READY-STATUS",
        outcome: "completed_no_pr",
        idempotency_key: "ready-status-delivery",
        recorded_by: "ready-status-worker",
        recorded_at: now,
        no_pr_evidence: "Migration preservation evidence."
      })
    )

    Repo.query!("UPDATE sympp_work_packages SET status = 'ready_for_human_merge' WHERE id = 'WP-READY-STATUS'")
  end

  defp rows!(sql), do: Repo.query!(sql).rows
end
