defmodule SymphonyElixir.SymphonyPlusPlus.ClaimLeasesTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Repository
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  defmodule ReclaimRefreshRaceRepo do
    alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    @race_key :sympp_claim_reclaim_refresh_race

    def arm(claim_id, last_seen_at), do: Process.put(@race_key, {claim_id, last_seen_at})
    def disarm, do: Process.delete(@race_key)

    def get(schema, id), do: Repo.get(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def one(query), do: Repo.one(query)

    def transaction(fun) do
      {:ok, fun.()}
    catch
      {:rollback, reason} -> {:error, reason}
    end

    def rollback(reason), do: throw({:rollback, reason})

    def update_all(query, updates) do
      case Process.get(@race_key) do
        {claim_id, last_seen_at} ->
          Process.delete(@race_key)

          Repo.update_all(
            from(claim in ClaimLease, where: claim.id == ^claim_id),
            set: [last_seen_at: last_seen_at, updated_at: last_seen_at]
          )

        _race ->
          :ok
      end

      Repo.update_all(query, updates)
    end
  end

  defmodule PrimaryKeyCollisionRepo do
    alias Ecto.Changeset
    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

    def get(WorkPackage, _id), do: %WorkPackage{status: "created"}

    def transaction(fun) do
      {:ok, fun.()}
    catch
      {:rollback, reason} -> {:error, reason}
    end

    def rollback(reason), do: throw({:rollback, reason})

    def insert(%Changeset{}) do
      raise %Ecto.ConstraintError{
        type: :unique,
        constraint: Process.get(:claim_lease_primary_key_collision_constraint),
        message: "primary key collision"
      }
    end
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(ClaimLease)
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "migration is idempotent and preserves existing package and grant rows", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CLAIM-MIGRATION"))
    assert {:ok, %{grant: grant}} = AccessGrantService.mint_worker_grant(repo, work_package.id)

    assert :ok = Repository.migrate(repo)
    assert :ok = Repository.migrate(repo)

    assert {:ok, ^work_package} = WorkPackageRepository.get(repo, work_package.id)
    assert %AccessGrant{} = persisted_grant = repo.get!(AccessGrant, grant.id)
    assert persisted_grant.id == grant.id
    assert persisted_grant.work_package_id == work_package.id

    columns = column_names(repo, "sympp_claim_leases")

    for column <- ~w(id work_package_id access_grant_id claim_group_id previous_claim_id actor_kind actor_id status last_seen_at stale_after_ms stale_at paused_at reclaimed_at released_at) do
      assert column in columns
    end

    %{rows: table_rows} = SQL.query!(repo, "PRAGMA table_info(sympp_claim_leases)")
    assert [_cid, "id", _type, _not_null, _default, 1] = Enum.find(table_rows, &(Enum.at(&1, 1) == "id"))

    indexes = index_names(repo, "sympp_claim_leases")
    refute "sympp_claim_leases_id_unique_index" in indexes
    assert "sympp_claim_leases_one_current_per_work_package_index" in indexes
    assert "sympp_claim_leases_status_last_seen_index" not in indexes
    assert "sympp_claim_leases_actor_index" not in indexes
  end

  test "claim lease transitions preserve actor identity and continuity through stale reclaim", %{repo: repo} do
    now = ~U[2026-05-26 10:00:00Z]
    heartbeat_at = DateTime.add(now, 500, :millisecond)
    pause_at = DateTime.add(now, 600, :millisecond)
    reclaim_at = DateTime.add(now, 2_000, :millisecond)

    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CLAIM-RECLAIM"))
    assert {:ok, %{grant: grant}} = AccessGrantService.mint_worker_grant(repo, work_package.id)

    assert {:ok, claim} =
             Service.claim(
               repo,
               work_package.id,
               %{actor_kind: "agent", actor_id: "agent-1", actor_display_name: "Agent One"},
               access_grant_id: grant.id,
               stale_after_ms: 1_000,
               now: now
             )

    assert claim.status == "active"
    assert claim.claim_group_id == claim.id
    assert claim.previous_claim_id == nil
    assert claim.actor_id == "agent-1"
    assert claim.access_grant_id == grant.id

    assert {:ok, claim} =
             Repository.heartbeat(
               repo,
               claim.id,
               %{
                 actor_kind: "human",
                 actor_id: "agent-9",
                 actor_display_name: "Wrong Actor",
                 access_grant_id: "grant_wrong",
                 status: "released",
                 released_at: heartbeat_at,
                 lease_expires_at: DateTime.add(now, 5, :second),
                 stale_after_ms: nil
               },
               now: heartbeat_at
             )

    assert DateTime.compare(claim.last_seen_at, heartbeat_at) == :eq
    assert claim.actor_kind == "agent"
    assert claim.actor_id == "agent-1"
    assert claim.actor_display_name == "Agent One"
    assert claim.access_grant_id == grant.id
    assert claim.status == "active"
    assert claim.stale_after_ms == 1_000
    assert claim.released_at == nil
    refute ClaimLease.stale?(claim, DateTime.add(now, 1_400, :millisecond))
    assert ClaimLease.stale?(claim, reclaim_at)

    assert {:ok, paused} = Service.pause(repo, claim.id, %{actor_id: "agent-1"}, now: pause_at, reason: "operator pause")
    assert paused.status == "paused"
    assert DateTime.compare(paused.paused_at, pause_at) == :eq
    assert paused.paused_by_actor_id == "agent-1"
    assert paused.pause_reason == "operator pause"

    assert {:ok, replacement} =
             Service.reclaim_stale(
               repo,
               work_package.id,
               %{actor_kind: "agent", actor_id: "agent-2", actor_display_name: "Agent Two"},
               now: reclaim_at,
               reason: "stale lease",
               stale_after_ms: nil
             )

    assert replacement.status == "active"
    assert replacement.actor_id == "agent-2"
    assert replacement.claim_group_id == claim.claim_group_id
    assert replacement.previous_claim_id == claim.id
    assert replacement.access_grant_id == grant.id
    assert replacement.stale_after_ms == 1_000
    assert replacement.stale_reason == nil
    assert replacement.reclaim_reason == nil
    assert replacement.reclaimed_at == nil
    assert replacement.released_at == nil
    assert DateTime.compare(replacement.lease_started_at, reclaim_at) == :eq
    assert ClaimLease.stale?(replacement, DateTime.add(reclaim_at, 1_001, :millisecond))

    assert {:ok, reclaimed} = Repository.get(repo, claim.id)
    assert reclaimed.status == "reclaimed"
    assert DateTime.compare(reclaimed.reclaimed_at, reclaim_at) == :eq
    assert reclaimed.reclaimed_by_actor_id == "agent-2"
    assert reclaimed.reclaim_reason == "stale lease"
    assert DateTime.compare(reclaimed.stale_at, reclaim_at) == :eq
    assert reclaimed.stale_reason == "stale lease"

    late_heartbeat_at = DateTime.add(reclaim_at, 1_001, :millisecond)
    assert {:error, :claim_stale} = Service.heartbeat(repo, replacement.id, now: late_heartbeat_at)

    assert {:ok, still_stale} = Repository.get(repo, replacement.id)
    assert DateTime.compare(still_stale.last_seen_at, reclaim_at) == :eq
  end

  test "stale reclaim can use a shorter current-lease recovery window without changing defaults", %{repo: repo} do
    now = ~U[2026-05-26 13:10:00Z]
    reclaim_at = DateTime.add(now, 6, :minute)

    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CLAIM-STALE-OVERRIDE"))

    assert {:ok, claim} =
             Service.claim(repo, work_package.id, %{actor_kind: "agent", actor_id: "agent-1"},
               now: now,
               stale_after_ms: :timer.hours(24)
             )

    refute ClaimLease.stale?(claim, reclaim_at)
    assert ClaimLease.stale?(claim, reclaim_at, :timer.minutes(5))

    assert {:error, :claim_not_stale} =
             Service.reclaim_stale(
               repo,
               work_package.id,
               %{actor_kind: "agent", actor_id: "agent-2"},
               now: reclaim_at,
               reason: "fast local recovery",
               stale_after_ms: :timer.minutes(5)
             )

    assert {:ok, replacement} =
             Service.reclaim_stale(
               repo,
               work_package.id,
               %{actor_kind: "agent", actor_id: "agent-2"},
               now: reclaim_at,
               reason: "fast local recovery",
               current_stale_after_ms: :timer.minutes(5),
               stale_after_ms: :timer.minutes(5)
             )

    assert replacement.actor_id == "agent-2"
    assert replacement.previous_claim_id == claim.id
    assert replacement.stale_after_ms == :timer.minutes(5)

    assert {:ok, reclaimed} = Repository.get(repo, claim.id)
    assert reclaimed.status == "reclaimed"
    assert reclaimed.reclaim_reason == "fast local recovery"
  end

  test "only one current claim exists per package and release frees the package", %{repo: repo} do
    now = ~U[2026-05-26 11:00:00Z]
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CLAIM-UNIQUE"))

    assert {:ok, first} =
             Service.claim(repo, work_package.id, %{actor_kind: "agent", actor_id: "agent-1"}, stale_after_ms: 1_000, now: now)

    assert {:error, :active_claim_exists} =
             Service.claim(repo, work_package.id, %{actor_kind: "agent", actor_id: "agent-2"}, stale_after_ms: 1_000, now: now)

    assert {:ok, current} = Service.current_for_work_package(repo, work_package.id)
    assert current.id == first.id

    released_at = DateTime.add(now, 500, :millisecond)
    assert {:ok, released} = Service.release(repo, first.id, now: released_at, reason: "worker finished")
    assert released.status == "released"
    assert released.release_reason == "worker finished"
    assert DateTime.compare(released.released_at, released_at) == :eq

    assert {:ok, second} =
             Repository.claim(
               repo,
               %{
                 "work_package_id" => work_package.id,
                 "claim_group_id" => "claim_group_wrong",
                 "previous_claim_id" => "claim_wrong",
                 "actor_kind" => "agent",
                 "actor_id" => "agent-2",
                 "stale_after_ms" => 1_000
               },
               now: released_at
             )

    assert second.status == "active"
    assert second.id != first.id
    assert second.work_package_id == work_package.id
    assert second.claim_group_id == second.id
    assert second.previous_claim_id == nil
  end

  test "terminal packages reject new claim leases", %{repo: repo} do
    for status <- ["skipped", "merged", "merged_into_phase", "closed", "abandoned"] do
      assert {:ok, work_package} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(id: "SYMPP-CLAIM-TERMINAL-#{status}", status: status)
               )

      assert {:error, :work_package_terminal} =
               Service.claim(
                 repo,
                 work_package.id,
                 %{actor_kind: "agent", actor_id: "agent-terminal"},
                 stale_after_ms: 1_000
               )

      assert {:error, :not_found} = Service.current_for_work_package(repo, work_package.id)
    end
  end

  test "duplicate caller-provided ids return stable primary key errors", %{repo: repo} do
    now = ~U[2026-05-26 11:30:00Z]
    assert {:ok, first_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CLAIM-DUPLICATE-ID-A"))
    assert {:ok, second_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CLAIM-DUPLICATE-ID-B"))

    attrs = %{
      id: "claim_duplicate_primary_key",
      actor_kind: "agent",
      actor_id: "agent-duplicate",
      stale_after_ms: 1_000
    }

    assert {:ok, claim} = Repository.claim(repo, Map.put(attrs, :work_package_id, first_package.id), now: now)
    assert claim.id == "claim_duplicate_primary_key"

    assert {:error, :id_already_exists} =
             Repository.claim(repo, Map.put(attrs, :work_package_id, second_package.id), now: now)
  end

  test "native primary key constraint names return stable duplicate-id errors" do
    now = ~U[2026-05-26 11:45:00Z]

    attrs = %{
      id: "claim_duplicate_native_primary_key",
      work_package_id: "SYMPP-CLAIM-DUPLICATE-NATIVE",
      actor_kind: "agent",
      actor_id: "agent-duplicate",
      stale_after_ms: 1_000
    }

    try do
      Process.put(:claim_lease_primary_key_collision_constraint, "sympp_claim_leases_pkey")
      assert {:error, :id_already_exists} = Repository.claim(PrimaryKeyCollisionRepo, attrs, now: now)

      Process.put(:claim_lease_primary_key_collision_constraint, "sympp_claim_leases_id_unique_index")
      assert {:error, :id_already_exists} = Repository.claim(PrimaryKeyCollisionRepo, attrs, now: now)

      Process.put(:claim_lease_primary_key_collision_constraint, "other_table_pkey")

      assert {:error, {:constraint_failed, "other_table_pkey"}} =
               Repository.claim(PrimaryKeyCollisionRepo, attrs, now: now)
    after
      Process.delete(:claim_lease_primary_key_collision_constraint)
    end
  end

  test "claims require a stale policy and package-scoped grant", %{repo: repo} do
    now = ~U[2026-05-26 12:00:00Z]
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CLAIM-SCOPE-A"))
    assert {:ok, other_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CLAIM-SCOPE-B"))
    assert {:ok, %{grant: other_grant}} = AccessGrantService.mint_worker_grant(repo, other_package.id)

    assert {:error, %Ecto.Changeset{} = changeset} =
             Service.claim(repo, work_package.id, %{actor_kind: "agent", actor_id: "agent-1"}, now: now)

    assert Keyword.has_key?(changeset.errors, :lease_expires_at)

    assert {:error, %Ecto.Changeset{} = changeset} =
             Service.claim(
               repo,
               work_package.id,
               %{actor_kind: "agent", actor_id: "agent-1"},
               access_grant_id: other_grant.id,
               stale_after_ms: 1_000,
               now: now
             )

    assert Keyword.has_key?(changeset.errors, :access_grant_id)

    assert {:ok, %{grant: grant}} = AccessGrantService.mint_worker_grant(repo, work_package.id)

    assert {:ok, claim} =
             Service.claim(
               repo,
               work_package.id,
               %{actor_kind: "agent", actor_id: "agent-1"},
               access_grant_id: grant.id,
               stale_after_ms: 1_000,
               now: now
             )

    reclaim_at = DateTime.add(now, 1_001, :millisecond)

    assert {:error, %Ecto.Changeset{} = changeset} =
             Service.reclaim_stale(
               repo,
               work_package.id,
               %{actor_kind: "agent", actor_id: "agent-2"},
               access_grant_id: other_grant.id,
               now: reclaim_at
             )

    assert Keyword.has_key?(changeset.errors, :access_grant_id)
    assert {:ok, still_current} = Repository.get(repo, claim.id)
    assert still_current.status == "active"
    assert still_current.reclaimed_at == nil
  end

  test "stale reclaim preserves expiry duration when replacement omits expiry", %{repo: repo} do
    now = ~U[2026-05-26 13:00:00Z]
    expires_at = DateTime.add(now, 1_000, :millisecond)
    reclaim_at = DateTime.add(now, 1_500, :millisecond)
    replacement_expires_at = DateTime.add(reclaim_at, 1_000, :millisecond)

    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CLAIM-EXPIRY"))

    assert {:ok, claim} =
             Service.claim(
               repo,
               work_package.id,
               %{actor_kind: "agent", actor_id: "agent-1"},
               lease_expires_at: expires_at,
               now: now
             )

    assert ClaimLease.stale?(claim, reclaim_at)

    assert {:ok, replacement} =
             Service.reclaim_stale(
               repo,
               work_package.id,
               %{actor_kind: "agent", actor_id: "agent-2"},
               now: reclaim_at,
               reason: "expired lease"
             )

    assert DateTime.compare(replacement.lease_expires_at, replacement_expires_at) == :eq
    refute ClaimLease.stale?(replacement, reclaim_at)
    assert ClaimLease.stale?(replacement, DateTime.add(replacement_expires_at, 1, :millisecond))
  end

  test "stale reclaim aborts when the observed lease refreshes before the terminal update", %{repo: repo} do
    now = ~U[2026-05-26 13:30:00Z]
    reclaim_at = DateTime.add(now, 1_500, :millisecond)
    refreshed_at = DateTime.add(reclaim_at, -100, :millisecond)

    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CLAIM-RACE"))

    assert {:ok, claim} =
             Service.claim(repo, work_package.id, %{actor_kind: "agent", actor_id: "agent-1"}, stale_after_ms: 1_000, now: now)

    assert ClaimLease.stale?(claim, reclaim_at)

    try do
      ReclaimRefreshRaceRepo.arm(claim.id, refreshed_at)

      assert {:error, :claim_not_stale} =
               Service.reclaim_stale(
                 ReclaimRefreshRaceRepo,
                 work_package.id,
                 %{actor_kind: "agent", actor_id: "agent-2"},
                 now: reclaim_at,
                 reason: "stale lease"
               )
    after
      ReclaimRefreshRaceRepo.disarm()
    end

    assert {:ok, current} = Service.current_for_work_package(repo, work_package.id)
    assert current.id == claim.id
    assert current.status == "active"
    assert DateTime.compare(current.last_seen_at, refreshed_at) == :eq
    refute ClaimLease.stale?(current, reclaim_at)
    assert repo.aggregate(ClaimLease, :count) == 1
  end

  test "service defaults and repository error paths return stable errors", %{repo: repo} do
    now = DateTime.utc_now(:microsecond)
    stale_started_at = ~U[2026-01-01 00:00:00Z]
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CLAIM-DEFAULTS"))
    assert {:ok, stale_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CLAIM-DEFAULTS-STALE"))

    assert {:error, :not_found} = Repository.get(repo, "claim_missing")
    assert {:error, :not_found} = Service.current_for_work_package(repo, "SYMPP-CLAIM-MISSING")

    assert {:error, %Ecto.Changeset{} = changeset} = Service.claim(repo, work_package.id, %{actor_id: "agent-default"})
    assert Keyword.has_key?(changeset.errors, :lease_expires_at)

    assert {:error, %Ecto.Changeset{} = changeset} =
             Service.claim(
               repo,
               work_package.id,
               %{actor_id: "agent-default"},
               access_grant_id: "ag_missing",
               stale_after_ms: 1_000,
               now: now
             )

    assert Keyword.has_key?(changeset.errors, :access_grant_id)

    assert {:ok, claim} =
             Repository.claim(
               repo,
               %{
                 work_package_id: work_package.id,
                 actor_id: "agent-default",
                 stale_after_ms: 10_000
               },
               now: now
             )

    assert {:ok, claim} = Repository.heartbeat(repo, claim.id)
    assert {:ok, claim} = Service.heartbeat(repo, claim.id)
    assert {:ok, paused} = Service.pause(repo, claim.id, %{"actor_id" => "agent-default"})
    assert paused.paused_by_actor_id == "agent-default"
    assert {:error, :not_active} = Service.heartbeat(repo, paused.id)
    assert {:ok, released} = Service.release(repo, paused.id)
    assert released.status == "released"
    assert {:error, :claim_not_current} = Service.release(repo, released.id)

    assert {:ok, stale_claim} =
             Repository.claim(
               repo,
               %{
                 work_package_id: stale_package.id,
                 actor_id: "agent-stale",
                 stale_after_ms: 1
               },
               now: stale_started_at
             )

    assert ClaimLease.stale?(stale_claim, DateTime.utc_now(:microsecond))

    assert {:ok, replacement} =
             Service.reclaim_stale(repo, stale_package.id, %{"actor_kind" => "agent", "actor_id" => "agent-reclaim"})

    assert replacement.actor_id == "agent-reclaim"
    assert replacement.previous_claim_id == stale_claim.id
  end

  defp column_names(repo, table) do
    %{rows: rows} = SQL.query!(repo, "PRAGMA table_info(#{table})")
    Enum.map(rows, &Enum.at(&1, 1))
  end

  defp index_names(repo, table) do
    %{rows: rows} = SQL.query!(repo, "PRAGMA index_list(#{table})")
    Enum.map(rows, &Enum.at(&1, 1))
  end
end
