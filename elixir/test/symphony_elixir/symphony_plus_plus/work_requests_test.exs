defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Service, as: CommentService
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Completion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.RepoScope
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.TestSupport

  defmodule LockedWorkRequestUpdateRepo do
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def all(query), do: Repo.all(query)
    def get(schema, id), do: Repo.get(schema, id)
    def rollback(reason), do: Repo.rollback(reason)
    def transaction(fun), do: Repo.transaction(fun)
    def update(_changeset), do: raise(%Exqlite.Error{message: "database is locked"})
    def update_all(query, updates), do: Repo.update_all(query, updates)
  end

  defmodule ReopeningArchiveRepo do
    import Ecto.Query, only: [from: 2]

    alias SymphonyElixir.SymphonyPlusPlus.Repo
    alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

    @race_key :sympp_reopen_during_archive_id

    def arm(work_request_id), do: Process.put(@race_key, work_request_id)
    def disarm, do: Process.delete(@race_key)

    def all(query), do: Repo.all(query)
    def get(schema, id), do: Repo.get(schema, id)
    def rollback(reason), do: Repo.rollback(reason)
    def transaction(fun), do: Repo.transaction(fun)
    def update(changeset), do: Repo.update(changeset)

    def update_all(query, updates) do
      case Process.get(@race_key) do
        work_request_id when is_binary(work_request_id) ->
          Process.delete(@race_key)

          Repo.update_all(
            from(work_request in WorkRequest, where: work_request.id == ^work_request_id),
            set: [completed_at: nil, archived_at: nil, archive_reason: nil, updated_at: DateTime.utc_now(:microsecond)]
          )

        _race ->
          :ok
      end

      Repo.update_all(query, updates)
    end
  end

  defmodule CompletionClearLockedPlanningRepo do
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def all(query), do: Repo.all(query)
    def get(schema, id), do: Repo.get(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def one(query), do: Repo.one(query)
    def rollback(reason), do: Repo.rollback(reason)
    def transaction(fun), do: Repo.transaction(fun)
    def update_all(_query, _updates), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  setup_all do
    database_path = database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(AgentRun)
    repo.delete_all(ProgressEvent)
    repo.delete_all(ClaimLease)
    repo.delete_all(AccessGrant)
    repo.delete_all(Comment)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkPackage)
    repo.delete_all(ClarificationQuestion)
    repo.delete_all(RepoScope)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "creates and fetches a draft work request", %{repo: repo} do
    assert {:ok, %WorkRequest{} = created} = Service.create(repo, attrs(constraints: nil))

    assert created.id =~ ~r/^wr_[a-z2-7]{16}$/
    assert created.status == "draft"
    assert created.constraints == %{}
    assert %DateTime{} = created.inserted_at
    assert %DateTime{} = created.updated_at
    assert created.completed_at == nil
    assert created.archived_at == nil
    assert {:ok, [primary_scope]} = Repository.list_repo_scopes(repo, created.id)
    assert primary_scope.repo == created.repo
    assert primary_scope.base_branch == created.base_branch

    assert {:ok, fetched} = Service.get(repo, created.id)
    assert fetched == created
  end

  test "lists work requests deterministically with status repo and base branch filters", %{repo: repo} do
    assert {:ok, first} =
             Repository.create(
               repo,
               attrs(
                 id: "WR-001",
                 title: "First",
                 status: "ready_for_slicing",
                 repo: "nextide/example",
                 base_branch: "main"
               )
             )

    assert {:ok, second} =
             Repository.create(
               repo,
               attrs(
                 id: "WR-002",
                 title: "Second",
                 status: "ready_for_slicing",
                 repo: "nextide/example",
                 base_branch: "main"
               )
             )

    assert {:ok, _third} =
             Repository.create(
               repo,
               attrs(
                 id: "WR-003",
                 title: "Third",
                 status: "draft",
                 repo: "nextide/example",
                 base_branch: "feature/v2"
               )
             )

    filters = %{status: "ready_for_slicing", repo: "nextide/example", base_branch: "main"}

    assert {:ok, [^first, ^second]} = Repository.list(repo, filters)
    assert {:ok, [^first, ^second]} = Service.list(repo, filters)
  end

  test "stores explicit WorkRequest repo scopes while primary list filters stay compatible", %{repo: repo} do
    assert {:ok, request} =
             Repository.create(
               repo,
               attrs(
                 id: "WR-MULTI-REPO",
                 repo: "service-a",
                 base_branch: "main",
                 repo_scopes: [
                   %{repo: "service-a", base_branch: "main"},
                   %{repo: "service-b", base_branch: "release"}
                 ]
               )
             )

    assert {:ok, scopes} = Repository.list_repo_scopes(repo, request.id)
    assert Enum.map(scopes, &{&1.repo, &1.base_branch}) == [{"service-a", "main"}, {"service-b", "release"}]

    scope_keys = MapSet.new(Enum.map(scopes, &{&1.repo, &1.base_branch}))
    assert MapSet.member?(scope_keys, {"service-a", "main"})
    assert MapSet.member?(scope_keys, {"service-b", "release"})
    refute MapSet.member?(scope_keys, {"service-c", "main"})

    assert {:ok, [^request]} = Repository.list(repo, %{repo: "service-a", base_branch: "main"})
    assert {:ok, []} = Repository.list(repo, %{repo: "service-b", base_branch: "release"})
  end

  test "primary repo updates preserve existing secondary repo scopes", %{repo: repo} do
    assert {:ok, request} =
             Repository.create(
               repo,
               attrs(
                 id: "WR-MULTI-REPO-UPDATE",
                 repo: "service-a",
                 base_branch: "main",
                 repo_scopes: [
                   %{repo: "service-a", base_branch: "main"},
                   %{repo: "service-b", base_branch: "release"}
                 ]
               )
             )

    assert {:ok, _updated} = Repository.update(repo, request.id, %{repo: "service-a-renamed"})

    assert {:ok, scopes} = Repository.list_repo_scopes(repo, request.id)
    assert Enum.map(scopes, &{&1.repo, &1.base_branch}) == [{"service-a-renamed", "main"}, {"service-b", "release"}]
  end

  test "repo scope primary attrs support repo-only scopes" do
    changeset = RepoScope.primary_attrs("WR-REPO-ONLY", "service-a", nil) |> RepoScope.create_changeset()

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :base_branch) == nil
    assert Ecto.Changeset.get_field(changeset, :scope_key) == "repo:service-a:"
  end

  test "updates fields while preserving stable id and inserted timestamp", %{repo: repo} do
    assert {:ok, created} = Repository.create(repo, attrs(status: "clarifying"))

    constraints = %{
      "allowed_paths" => ["elixir/lib/symphony_elixir"],
      "stop_conditions" => %{"needs_human" => true},
      "max_review_rounds" => 2
    }

    assert {:ok, updated} =
             Repository.update(repo, created.id, %{
               "updated_at" => ~U[2000-01-01 00:00:00Z],
               id: "ignored",
               title: "Updated title",
               work_type: "investigation",
               desired_dispatch_shape: "investigation_first",
               constraints: constraints,
               completed_at: ~U[2001-01-01 00:00:00Z],
               archived_at: ~U[2001-01-02 00:00:00Z],
               inserted_at: ~U[2000-01-01 00:00:00Z]
             })

    assert updated.id == created.id
    assert updated.inserted_at == created.inserted_at
    assert DateTime.compare(updated.updated_at, created.updated_at) != :lt
    assert updated.updated_at != ~U[2000-01-01 00:00:00Z]
    assert updated.title == "Updated title"
    assert updated.work_type == "investigation"
    assert updated.desired_dispatch_shape == "investigation_first"
    assert updated.constraints == constraints
    assert updated.completed_at == nil
    assert updated.archived_at == nil

    assert {:error, %Ecto.Changeset{} = status_changeset} =
             Service.update(repo, created.id, %{status: "ready_for_slicing"})

    assert "use update_status/4 for status transitions" in errors_on(status_changeset).status

    assert {:ok, service_updated} = Service.update_status(repo, created.id, "clarifying", "ready_for_slicing")
    assert service_updated.status == "ready_for_slicing"
  end

  test "rejects invalid status work type dispatch shape and non JSON-safe constraints", %{repo: repo} do
    assert {:error, %Ecto.Changeset{} = status_changeset} = Repository.create(repo, attrs(status: "created"))
    assert "is invalid" in errors_on(status_changeset).status

    assert {:error, %Ecto.Changeset{} = work_type_changeset} = Repository.create(repo, attrs(work_type: "fix"))
    assert "is invalid" in errors_on(work_type_changeset).work_type

    assert {:error, %Ecto.Changeset{} = dispatch_shape_changeset} =
             Repository.create(repo, attrs(desired_dispatch_shape: "single package"))

    assert "is invalid" in errors_on(dispatch_shape_changeset).desired_dispatch_shape

    assert {:error, %Ecto.Changeset{} = review_only_changeset} =
             Repository.create(repo, attrs(desired_dispatch_shape: "review_only"))

    assert "is invalid" in errors_on(review_only_changeset).desired_dispatch_shape

    assert {:error, %Ecto.Changeset{} = constraints_changeset} =
             Repository.create(repo, attrs(constraints: %{secret_name: :not_json_safe}))

    assert "must be a JSON-safe map" in errors_on(constraints_changeset).constraints
  end

  test "normalizes JSON-safe constraint atom keys recursively", %{repo: repo} do
    constraints = %{
      allowed_paths: ["elixir/lib/symphony_elixir"],
      stop_conditions: %{needs_human: true},
      review: [%{lane: "normal"}]
    }

    assert {:ok, request} = Repository.create(repo, attrs(constraints: constraints))

    assert request.constraints == %{
             "allowed_paths" => ["elixir/lib/symphony_elixir"],
             "stop_conditions" => %{"needs_human" => true},
             "review" => [%{"lane" => "normal"}]
           }
  end

  test "rejects duplicate caller-provided ids", %{repo: repo} do
    attrs = attrs(id: "WR-DUPLICATE")

    assert {:ok, request} = Repository.create(repo, attrs)
    assert request.id == "WR-DUPLICATE"
    assert {:error, :id_already_exists} = Repository.create(repo, attrs)
  end

  test "updates status optimistically and distinguishes stale from missing records", %{repo: repo} do
    assert {:ok, request} = Repository.create(repo, attrs(id: "WR-STATUS"))

    assert {:ok, ready} = Service.update_status(repo, request.id, "draft", "ready_for_clarification")
    assert ready.status == "ready_for_clarification"

    assert {:error, :stale_status} =
             Repository.update_status(repo, request.id, "draft", "clarifying")

    assert {:error, :not_found} =
             Repository.update_status(repo, "WR-MISSING", "draft", "clarifying")

    assert {:error, :invalid_status} =
             Repository.update_status(repo, request.id, "draft", "ready")
  end

  test "refreshes conservative completion and archive state without changing raw status", %{repo: repo} do
    assert {:ok, request} = Repository.create(repo, attrs(id: "WR-COMPLETE", status: "ready_for_slicing"))
    assert {:ok, slice} = CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WRS-COMPLETE"))
    assert {:ok, _skipped} = Repository.skip_work_package(repo, request.id, slice.id, "planned")

    assert {:ok, completed} = Service.refresh_completion(repo, request.id)
    assert completed.status == "ready_for_slicing"
    assert %DateTime{} = completed.completed_at
    assert completed.archived_at == nil

    assert {:ok, archived} = Service.archive(repo, request.id)
    assert archived.status == "ready_for_slicing"
    assert archived.completed_at == completed.completed_at
    assert %DateTime{} = archived.archived_at
    assert archived.archive_reason == "manual"
    assert {:ok, []} = Repository.list(repo)
    assert {:ok, [^archived]} = Repository.list(repo, include_archived: true)

    assert {:ok, _manual_retention} =
             Service.retention_pass(repo, now: DateTime.utc_now(:microsecond), archive_after_days: 3650)

    assert {:ok, manually_archived} = Repository.get(repo, request.id)
    assert manually_archived.archived_at == archived.archived_at
    assert manually_archived.archive_reason == "manual"

    assert {:ok, restored} = Service.restore(repo, request.id)
    assert restored.archived_at == nil
    assert restored.archive_reason == nil
    assert DateTime.compare(restored.completed_at, completed.completed_at) in [:gt, :eq]
  end

  test "archive starts best-effort linked worktree cleanup after hiding a completed WorkRequest", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-archive-worktree")
    codex_home = Path.join(fixture.root, "codex-home")
    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      {request, package} = completed_linked_request!(repo, "WR-ARCHIVE-CLEANS-WORKTREE", utc_usec(~U[2026-05-20 12:00:00Z]))
      prepared = prepare_managed_worktree!(repo, package, fixture.repo_root, codex_home, "feat/archive-cleans-worktree")

      assert File.dir?(prepared.worktree_path)
      assert {:ok, archived} = Service.archive(repo, request.id)
      assert %DateTime{} = archived.archived_at

      assert_eventually(fn ->
        refute File.exists?(prepared.worktree_path)
        assert repo.get!(WorkPackage, package.id).worktree_path == nil
        assert repo.get!(WorkPackage, package.id).worktree_target_repo_root == nil
      end)
    after
      restore_env("CODEX_HOME", previous_codex_home)
    end
  end

  test "archive ignores dirty linked worktree cleanup failures and keeps trying siblings", %{repo: repo} do
    completed_at = utc_usec(~U[2026-05-01 00:00:00Z])
    assert {:ok, request} = Repository.create(repo, attrs(id: "WR-ARCHIVE-MULTI-WORKTREE", status: "ready_for_slicing"))

    assert {:ok, clean_slice} =
             CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WRS-ARCHIVE-MULTI-CLEAN"))

    assert {:ok, dirty_slice} =
             CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WRS-ARCHIVE-MULTI-DIRTY"))

    assert {:ok, clean_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, request.id, clean_slice.id, "planned")
    assert {:ok, dirty_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, request.id, dirty_slice.id, "planned")

    clean_package = set_work_package_status!(repo, clean_slice, "merged")
    dirty_package = set_work_package_status!(repo, dirty_slice, "merged")
    assert {:ok, completed} = Service.refresh_completion(repo, request.id)

    completed
    |> Ecto.Changeset.change(completed_at: completed_at, archived_at: nil)
    |> repo.update!()

    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-archive-multi-worktree")
    codex_home = Path.join(fixture.root, "codex-home")
    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      clean_worktree = prepare_managed_worktree!(repo, clean_package, fixture.repo_root, codex_home, "feat/archive-multi-clean")
      dirty_worktree = prepare_managed_worktree!(repo, dirty_package, fixture.repo_root, codex_home, "feat/archive-multi-dirty")
      File.write!(Path.join(dirty_worktree.worktree_path, "dirty.txt"), "dirty\n")

      assert {:ok, archived} = Service.archive(repo, request.id)
      assert %DateTime{} = archived.archived_at

      assert_eventually(fn ->
        refute File.exists?(clean_worktree.worktree_path)
        assert repo.get!(WorkPackage, clean_package.id).worktree_path == nil
      end)

      assert File.dir?(dirty_worktree.worktree_path)
      assert repo.get!(WorkPackage, dirty_package.id).worktree_path == dirty_worktree.worktree_path
      assert %DateTime{} = repo.get!(WorkRequest, request.id).archived_at
    after
      restore_env("CODEX_HOME", previous_codex_home)
    end
  end

  test "completion write failures are normalized", %{repo: repo} do
    assert {:ok, request} = Repository.create(repo, attrs(id: "WR-COMPLETE-LOCKED", status: "ready_for_slicing"))
    assert {:ok, slice} = CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WRS-COMPLETE-LOCKED"))
    assert {:ok, _skipped} = Repository.skip_work_package(repo, request.id, slice.id, "planned")

    assert {:error, :database_busy} = Service.refresh_completion(LockedWorkRequestUpdateRepo, request.id)
    assert {:ok, unchanged} = Repository.get(repo, request.id)
    assert unchanged.completed_at == nil
    assert unchanged.archived_at == nil
  end

  test "archive rechecks current completion before hiding a request", %{repo: repo} do
    request = completed_skipped_request!(repo, "WR-ARCHIVE-REOPEN-RACE", utc_usec(~U[2026-05-01 00:00:00Z]))

    try do
      ReopeningArchiveRepo.arm(request.id)
      assert {:error, :not_completed} = Service.archive(ReopeningArchiveRepo, request.id)
    after
      ReopeningArchiveRepo.disarm()
    end

    assert {:ok, reopened} = Repository.get(repo, request.id)
    assert reopened.completed_at == nil
    assert reopened.archived_at == nil
    assert reopened.archive_reason == nil
  end

  test "archive refreshes stale completion evidence before hiding a request", %{repo: repo} do
    request = completed_skipped_request!(repo, "WR-ARCHIVE-STALE-COMPLETION", utc_usec(~U[2026-05-01 00:00:00Z]))
    assert {:ok, _question} = Repository.ask_question(repo, request.id, question_attrs(id: "WRQ-ARCHIVE-STALE-COMPLETION"))

    assert {:error, :not_completed} = Service.archive(repo, request.id)
    assert {:ok, reopened} = Repository.get(repo, request.id)
    assert reopened.completed_at == nil
    assert reopened.archived_at == nil
  end

  test "retention skips stale archive candidates", %{repo: repo} do
    now = utc_usec(~U[2026-05-23 12:00:00Z])
    request = completed_skipped_request!(repo, "WR-RETENTION-STALE-CANDIDATE", utc_usec(~U[2026-05-01 00:00:00Z]))

    try do
      ReopeningArchiveRepo.arm(request.id)

      assert {:ok, summary} =
               Service.retention_pass(ReopeningArchiveRepo,
                 now: now,
                 archive_after_days: 1
               )

      assert summary.archived_ids == []
      assert summary.archived_count == 0
    after
      ReopeningArchiveRepo.disarm()
    end

    assert {:ok, reopened} = Repository.get(repo, request.id)
    assert reopened.completed_at == nil
    assert reopened.archived_at == nil
  end

  test "blocker reopen events roll back when completion clearing fails", %{repo: repo} do
    assert {:ok, request} = Repository.create(repo, attrs(id: "WR-BLOCKER-ROLLBACK", status: "ready_for_slicing"))
    assert {:ok, work_package} = CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WRS-BLOCKER-ROLLBACK"))
    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, request.id, work_package.id, "planned")
    linked_package = set_work_package_status!(repo, approved_slice, "merged")
    assert {:ok, _completed} = Service.refresh_completion(repo, request.id)
    assert {:ok, archived} = Service.archive(repo, request.id)

    assert {:error, :database_busy} =
             PlanningRepository.append_progress_event(CompletionClearLockedPlanningRepo, %{
               work_package_id: linked_package.id,
               summary: "Blocked",
               status: "blocked",
               idempotency_key: "blocker-clear-rollback",
               payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: "clear-rollback", active: true}
             })

    assert {:ok, []} = PlanningRepository.list_progress_events(repo, linked_package.id)
    assert {:ok, still_archived} = Repository.get(repo, request.id)
    assert still_archived.archived_at == archived.archived_at
  end

  test "retention archives completed work requests after fourteen days and preserves history", %{repo: repo} do
    now = utc_usec(~U[2026-05-23 12:00:00Z])
    old_completed_at = utc_usec(~U[2026-05-09 12:00:00Z])
    recent_completed_at = utc_usec(~U[2026-05-20 12:00:00Z])

    old_request = completed_skipped_request!(repo, "WR-RETENTION-OLD", old_completed_at)
    recent_request = completed_skipped_request!(repo, "WR-RETENTION-RECENT", recent_completed_at)

    assert {:ok, _decision} =
             Repository.record_decision(repo, old_request.id, decision_attrs(id: "WRD-RETENTION-OLD"))

    assert {:ok, summary} = Service.retention_pass(repo, now: now)
    assert summary.archived_ids == [old_request.id]
    assert summary.archived_count == 1

    assert {:ok, archived} = Repository.get(repo, old_request.id)
    assert archived.completed_at == old_completed_at
    assert %DateTime{} = archived.archived_at

    assert {:ok, [_slice]} = Repository.list_work_packages(repo, old_request.id)
    assert {:ok, [_decision]} = Repository.list_decisions(repo, old_request.id)

    assert {:ok, [^recent_request]} = Repository.list(repo)
    assert {:ok, all_requests} = Repository.list(repo, %{include_archived: true})
    assert Enum.map(all_requests, & &1.id) == [old_request.id, recent_request.id]

    assert {:ok, all_requests} = Repository.list(repo, %{"include_archived" => "true"})
    assert Enum.map(all_requests, & &1.id) == [old_request.id, recent_request.id]

    assert {:ok, all_requests} = Repository.list(repo, include_archived: true)
    assert Enum.map(all_requests, & &1.id) == [old_request.id, recent_request.id]
  end

  test "retention accepts a custom archive day cutoff", %{repo: repo} do
    now = utc_usec(~U[2026-05-23 12:00:00Z])
    completed_at = utc_usec(~U[2026-05-20 12:00:00Z])
    request = completed_skipped_request!(repo, "WR-RETENTION-CUSTOM-CUTOFF", completed_at)

    assert {:ok, default_summary} = Service.retention_pass(repo, now: now)
    assert default_summary.archived_ids == []

    assert {:ok, custom_summary} = Service.retention_pass(repo, now: now, archive_after_days: 2)
    assert custom_summary.archived_ids == [request.id]
    assert {:ok, auto_archived} = Repository.get(repo, request.id)
    assert auto_archived.archive_reason == "age"

    assert {:ok, relaxed_summary} = Service.retention_pass(repo, now: now, archive_after_days: 14)
    assert relaxed_summary.archived_ids == []
    assert {:ok, relaxed} = Repository.get(repo, request.id)
    assert relaxed.completed_at == completed_at
    assert relaxed.archived_at == nil
  end

  test "retention deletes expired archived work requests after removing their comments", %{repo: repo} do
    now = utc_usec(~U[2026-05-23 12:00:00Z])
    stale_at = utc_usec(~U[2026-05-20 12:00:00Z])
    recent_at = utc_usec(~U[2026-05-22 12:00:00Z])

    expired = completed_skipped_request!(repo, "WR-RETENTION-DELETE-EXPIRED", stale_at)
    assert {:ok, expired_archived} = Service.archive(repo, expired.id)
    set_archived_at!(repo, expired_archived, stale_at)
    expired_slice_id = "WRS-#{expired.id}"

    assert {:ok, request_comment} =
             CommentService.create(repo, %{
               id: "comment-retention-delete-wr",
               target_kind: "work_request",
               target_id: expired.id,
               body: "Remove with WorkRequest",
               source_type: "operator",
               author_name: "retention-test"
             })

    assert {:ok, slice_comment} =
             CommentService.create(repo, %{
               id: "comment-retention-delete-slice",
               target_kind: "work_package",
               target_id: expired_slice_id,
               body: "Remove with WorkPackage",
               source_type: "operator",
               author_name: "retention-test"
             })

    active = completed_skipped_request!(repo, "WR-RETENTION-DELETE-ACTIVE", recent_at)

    assert {:ok, active_comment} =
             CommentService.create(repo, %{
               id: "comment-retention-keep-active",
               target_kind: "work_request",
               target_id: active.id,
               body: "Keep active",
               source_type: "operator",
               author_name: "retention-test"
             })

    scope_owner = create_activity_work_package!(repo, "WP-RETENTION-SCOPE-OWNER", status: "merged")
    grant = insert_claimed_activity_grant!(repo, scope_owner, "worker", "retention-worker")
    insert_grant_scope!(repo, grant.id, "work_request", expired.id)
    insert_grant_scope!(repo, grant.id, "work_package", expired_slice_id)

    completed = completed_skipped_request!(repo, "WR-RETENTION-DELETE-COMPLETED", stale_at)
    assert {:ok, open} = Repository.create(repo, attrs(id: "WR-RETENTION-DELETE-OPEN", status: "draft"))

    recent_archived = completed_skipped_request!(repo, "WR-RETENTION-DELETE-RECENT", stale_at)
    assert {:ok, recent_archived} = Service.archive(repo, recent_archived.id)
    recent_archived = set_archived_at!(repo, recent_archived, recent_at)

    assert {:ok, summary} =
             Service.retention_pass(repo,
               now: now,
               archive_after_days: 3650,
               delete_after_days: 1
             )

    assert summary.deleted_ids == [expired.id]
    assert summary.deleted_count == 1
    assert {:error, :not_found} = Service.get(repo, expired.id)
    assert {:error, :not_found} = CommentService.get(repo, request_comment.id)
    assert {:error, :not_found} = CommentService.get(repo, slice_comment.id)
    assert grant_scope_count(repo, "work_request", expired.id) == 0
    assert grant_scope_count(repo, "work_package", expired_slice_id) == 0

    assert {:ok, ^active} = Service.get(repo, active.id)
    assert {:ok, ^active_comment} = CommentService.get(repo, active_comment.id)
    assert grant_scope_count(repo, "work_package", expired_slice_id) == 0
    assert {:ok, ^completed} = Service.get(repo, completed.id)
    assert {:ok, ^open} = Service.get(repo, open.id)
    assert {:ok, ^recent_archived} = Service.get(repo, recent_archived.id)
  end

  test "retention deletes archived WorkRequests after forcing linked worktree cleanup", %{repo: repo} do
    now = utc_usec(~U[2026-05-23 12:00:00Z])
    stale_at = utc_usec(~U[2026-05-20 12:00:00Z])
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-retention-worktree")
    codex_home = Path.join(fixture.root, "codex-home")
    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      {clean_request, clean_package} = completed_linked_request!(repo, "WR-RETENTION-CLEAN-WORKTREE", stale_at)
      clean_worktree = prepare_managed_worktree!(repo, clean_package, fixture.repo_root, codex_home, "feat/retention-clean-worktree")
      set_archived_at!(repo, clean_request, stale_at)

      {dirty_request, dirty_package} = completed_linked_request!(repo, "WR-RETENTION-DIRTY-WORKTREE", stale_at)
      dirty_worktree = prepare_managed_worktree!(repo, dirty_package, fixture.repo_root, codex_home, "feat/retention-dirty-worktree")
      File.write!(Path.join(dirty_worktree.worktree_path, "dirty.txt"), "dirty\n")
      set_archived_at!(repo, dirty_request, stale_at)

      assert {:ok, summary} =
               Service.retention_pass(repo,
                 now: now,
                 archive_after_days: 3650,
                 delete_after_days: 1
               )

      assert summary.deleted_ids == [clean_request.id, dirty_request.id]
      assert {:error, :not_found} = Service.get(repo, clean_request.id)
      assert {:error, :not_found} = Service.get(repo, dirty_request.id)
      refute File.exists?(clean_worktree.worktree_path)
      refute File.exists?(dirty_worktree.worktree_path)
      assert repo.get(WorkPackage, clean_package.id) == nil
      assert repo.get(WorkPackage, dirty_package.id) == nil
    after
      restore_env("CODEX_HOME", previous_codex_home)
    end
  end

  test "retention caps visible completed work requests to ten per repo", %{repo: repo} do
    now = utc_usec(~U[2026-05-23 12:00:00Z])
    release_completed_at = utc_usec(~U[2026-05-11 00:00:00Z])

    completed_requests =
      for index <- 1..12 do
        day = 10 + index

        completed_at =
          ~U[2026-05-01 12:00:00Z]
          |> utc_usec()
          |> DateTime.add((day - 1) * 24 * 60 * 60, :second)

        completed_skipped_request!(repo, "WR-RETENTION-CAP-#{index}", completed_at)
      end

    release_request =
      completed_skipped_request!(repo, "WR-RETENTION-CAP-RELEASE", release_completed_at, base_branch: "release/1.0")

    assert {:ok, summary} = Service.retention_pass(repo, now: now)
    assert summary.archived_ids == ["WR-RETENTION-CAP-1", "WR-RETENTION-CAP-2"]
    assert summary.archived_count == 2
    assert {:ok, first_overflow} = Repository.get(repo, "WR-RETENTION-CAP-1")
    assert first_overflow.archive_reason == "limit"

    assert {:ok, visible_requests} = Repository.list(repo)
    expected_requests = Enum.drop(completed_requests, 2) ++ [release_request]
    assert Enum.map(visible_requests, & &1.id) == Enum.map(expected_requests, & &1.id)
    assert {:ok, second_summary} = Service.retention_pass(repo, now: now)
    assert second_summary.archived_ids == []
    assert {:ok, first_overflow_after_second_pass} = Repository.get(repo, "WR-RETENTION-CAP-1")
    assert first_overflow_after_second_pass.archived_at == first_overflow.archived_at
    assert first_overflow_after_second_pass.archive_reason == "limit"
  end

  test "retention overflow archives dirty worktree candidates and leaves best-effort cleanup to archive", %{repo: repo} do
    now = utc_usec(~U[2026-05-23 12:00:00Z])
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-retention-cap-worktree")
    codex_home = Path.join(fixture.root, "codex-home")
    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      {blocked_request, blocked_package} =
        completed_linked_request!(repo, "WR-RETENTION-CAP-BLOCKED", utc_usec(~U[2026-05-01 12:00:00Z]))

      blocked_worktree = prepare_managed_worktree!(repo, blocked_package, fixture.repo_root, codex_home, "feat/retention-cap-blocked")
      File.write!(Path.join(blocked_worktree.worktree_path, "dirty.txt"), "dirty\n")

      for index <- 1..11 do
        completed_at =
          ~U[2026-05-01 12:00:00Z]
          |> utc_usec()
          |> DateTime.add(index * 24 * 60 * 60, :second)

        completed_skipped_request!(repo, "WR-RETENTION-CAP-BACKFILL-#{index}", completed_at)
      end

      assert {:ok, summary} = Service.retention_pass(repo, now: now, archive_after_days: 3650)
      assert summary.archived_ids == [blocked_request.id, "WR-RETENTION-CAP-BACKFILL-1"]
      assert {:ok, blocked_archived} = Repository.get(repo, blocked_request.id)
      assert %DateTime{} = blocked_archived.archived_at
      assert File.dir?(blocked_worktree.worktree_path)
      assert repo.get!(WorkPackage, blocked_package.id).worktree_path == blocked_worktree.worktree_path

      assert {:ok, visible_requests} = Repository.list(repo)
      assert length(visible_requests) == 10
    after
      restore_env("CODEX_HOME", previous_codex_home)
    end
  end

  test "retention is idempotent and refuses unsafe completed-at rows", %{repo: repo} do
    now = utc_usec(~U[2026-05-23 12:00:00Z])
    stale_completed_at = utc_usec(~U[2026-05-01 12:00:00Z])
    request = completed_skipped_request!(repo, "WR-RETENTION-UNSAFE", stale_completed_at)
    assert {:ok, _question} = Repository.ask_question(repo, request.id, question_attrs(id: "WRQ-RETENTION-UNSAFE"))

    assert {:ok, first} = Service.retention_pass(repo, now: now)
    assert first.archived_ids == []

    assert {:ok, refreshed} = Repository.get(repo, request.id)
    assert refreshed.completed_at == nil
    assert refreshed.archived_at == nil

    assert {:ok, second} = Service.retention_pass(repo, now: now)
    assert second.archived_ids == []
    assert {:ok, [^refreshed]} = Repository.list(repo)
  end

  test "reopened archived work requests return to the visible list", %{repo: repo} do
    completed_at = utc_usec(~U[2026-05-01 00:00:00Z])
    request = completed_skipped_request!(repo, "WR-RETENTION-REOPEN", completed_at)
    assert {:ok, archived} = Service.archive(repo, request.id)
    assert %DateTime{} = archived.archived_at

    assert {:ok, _question} = Repository.ask_question(repo, request.id, question_attrs(id: "WRQ-RETENTION-REOPEN"))
    assert {:ok, reopened} = Repository.get(repo, request.id)
    assert reopened.completed_at == nil
    assert reopened.archived_at == nil

    assert {:ok, visible_requests} = Repository.list(repo)
    assert Enum.map(visible_requests, & &1.id) == [request.id]

    status_request = completed_skipped_request!(repo, "WR-RETENTION-STATUS-REOPEN", completed_at)
    assert {:ok, status_archived} = Service.archive(repo, status_request.id)
    assert %DateTime{} = status_archived.archived_at

    assert {:ok, _status_reopened} =
             Repository.update_status(repo, status_request.id, "ready_for_slicing", "human_info_needed")

    assert {:ok, reopened_by_status} = Repository.get(repo, status_request.id)
    assert reopened_by_status.completed_at == nil
    assert reopened_by_status.archived_at == nil
    assert reopened_by_status.archive_reason == nil
    assert {:ok, visible_requests} = Repository.list(repo)
    assert Enum.map(visible_requests, & &1.id) == [request.id, status_request.id]
  end

  test "dependency lifecycle changes reopen archived work requests", %{repo: repo} do
    assert {:ok, request} = Repository.create(repo, attrs(id: "WR-RETENTION-LINKED-REOPEN", status: "ready_for_slicing"))
    assert {:ok, work_package} = CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WRS-RETENTION-LINKED-REOPEN"))
    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, request.id, work_package.id, "planned")
    linked_package = set_work_package_status!(repo, approved_slice, "merged")
    assert {:ok, completed} = Service.refresh_completion(repo, request.id)
    assert %DateTime{} = completed.completed_at
    assert {:ok, archived} = Service.archive(repo, request.id)
    assert %DateTime{} = archived.archived_at

    assert {:ok, _closed_package} = WorkPackageRepository.update_status(repo, linked_package.id, "merged", "closed")
    assert {:ok, still_archived} = Repository.get(repo, request.id)
    assert still_archived.completed_at == archived.completed_at
    assert still_archived.archived_at == archived.archived_at

    assert {:ok, _reopened_package} = WorkPackageRepository.update_status(repo, linked_package.id, "closed", "planning")

    assert {:ok, reopened} = Repository.get(repo, request.id)
    assert reopened.completed_at == nil
    assert reopened.archived_at == nil
    assert {:ok, [^reopened]} = Repository.list(repo)

    assert {:ok, merged_again} = WorkPackageRepository.update_status(repo, linked_package.id, "planning", "merged")
    assert {:ok, recompleted} = Service.refresh_completion(repo, request.id)
    assert DateTime.compare(recompleted.completed_at, merged_again.updated_at) in [:eq, :gt]

    assert {:ok, archived_again} = Service.archive(repo, request.id)
    assert %DateTime{} = archived_again.archived_at

    assert {:ok, _note} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Informational note",
               status: "recorded",
               idempotency_key: "note-does-not-reopen"
             })

    assert {:ok, still_archived_again} = Repository.get(repo, request.id)
    assert still_archived_again.completed_at == archived_again.completed_at
    assert still_archived_again.archived_at == archived_again.archived_at

    assert {:ok, _non_canonical_blocker} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Non-canonical blocker note",
               status: "blocked",
               idempotency_key: "non-canonical-blocker-does-not-reopen",
               payload: %{type: "blocker", active: true, blocker_id: "non-canonical"}
             })

    assert {:ok, still_archived_with_non_canonical_blocker} = Repository.get(repo, request.id)
    assert still_archived_with_non_canonical_blocker.completed_at == archived_again.completed_at
    assert still_archived_with_non_canonical_blocker.archived_at == archived_again.archived_at

    blocker = append_blocker_event!(repo, linked_package.id, "blocker-reopen-archived", true)

    assert {:ok, blocker_reopened} = Repository.get(repo, request.id)
    assert blocker_reopened.completed_at == nil
    assert blocker_reopened.archived_at == nil
    assert DateTime.compare(blocker_reopened.updated_at, blocker.created_at) in [:eq, :gt]
  end

  test "revoking expired grants does not reopen archived work requests", %{repo: repo} do
    assert {:ok, request} = Repository.create(repo, attrs(id: "WR-RETENTION-GRANT-REVOKE", status: "ready_for_slicing"))
    assert {:ok, work_package} = CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WRS-RETENTION-GRANT-REVOKE"))
    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, request.id, work_package.id, "planned")

    dispatched_package = set_work_package_status!(repo, approved_slice, "ready_for_worker")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, dispatched_package.id)
    set_work_package_status!(repo, dispatched_package, "merged")

    expired_at = utc_usec(~U[2026-05-01 00:00:00Z])

    grant =
      minted.grant
      |> Ecto.Changeset.change(claimed_at: DateTime.add(expired_at, -60, :second), claimed_by: "worker-1", expires_at: expired_at)
      |> repo.update!()

    assert {:ok, completed} = Service.refresh_completion(repo, request.id)
    assert %DateTime{} = completed.completed_at
    assert {:ok, archived} = Service.archive(repo, request.id)
    assert %DateTime{} = archived.archived_at

    assert {:ok, _revoked_grant} = AccessGrantRepository.revoke(repo, grant.id, DateTime.utc_now(:microsecond))
    assert {:ok, still_archived} = Repository.get(repo, request.id)
    assert still_archived.completed_at == archived.completed_at
    assert still_archived.archived_at == archived.archived_at
  end

  test "completion ignores grant-only activity after the package is terminal", %{repo: repo} do
    assert {:ok, request} = Repository.create(repo, attrs(id: "WR-COMPLETE-UNNAMED-GRANT", status: "ready_for_slicing"))
    assert {:ok, work_package} = CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WRS-COMPLETE-UNNAMED-GRANT"))
    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, request.id, work_package.id, "planned")

    dispatched_package = set_work_package_status!(repo, approved_slice, "ready_for_worker")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, dispatched_package.id)
    set_work_package_status!(repo, dispatched_package, "merged")

    minted.grant
    |> Ecto.Changeset.change(claimed_at: DateTime.utc_now(:microsecond), claimed_by: nil)
    |> repo.update!()

    assert {:ok, with_grant} = Service.refresh_completion(repo, request.id)
    assert %DateTime{} = with_grant.completed_at

    assert {:ok, _revoked_grant} = AccessGrantRepository.revoke(repo, minted.grant.id, DateTime.utc_now(:microsecond))
    assert {:ok, without_grant} = Service.refresh_completion(repo, request.id)
    assert without_grant.completed_at == with_grant.completed_at
  end

  test "completion and archive wait for a paused current claim lease", %{repo: repo} do
    assert {:ok, request} = Repository.create(repo, attrs(id: "WR-COMPLETE-PAUSED-LEASE", status: "ready_for_slicing"))
    assert {:ok, work_package} = CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WRS-COMPLETE-PAUSED-LEASE"))
    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, request.id, work_package.id, "planned")
    linked_package = set_work_package_status!(repo, approved_slice, "merged")

    assert {:ok, claim_lease} =
             ClaimLeaseService.claim(repo, linked_package.id, activity_actor("paused-completion-worker"), stale_after_ms: 60_000)

    assert {:ok, paused_lease} = ClaimLeaseService.pause(repo, claim_lease.id, activity_actor("operator"), reason: "operator pause")

    paused_context = WorkPackageActivity.context(repo, linked_package.id)
    assert get_in(paused_context, [:runtime_state, :active?]) == true
    assert get_in(paused_context, [:runtime_state, :paused?]) == true
    assert get_in(paused_context, [:runtime_state, :lifecycle_state]) == "paused"
    assert "claim_lease_paused" in get_in(paused_context, [:runtime_state, :reason_codes])

    assert {:ok, with_paused_lease} = Service.refresh_completion(repo, request.id)
    assert with_paused_lease.completed_at == nil
    assert {:error, :not_completed} = Service.archive(repo, request.id)

    assert {:ok, _released_lease} = ClaimLeaseService.release(repo, paused_lease.id, reason: "operator resolved pause")

    released_context = WorkPackageActivity.context(repo, linked_package.id)
    assert get_in(released_context, [:runtime_state, :active?]) == false
    assert get_in(released_context, [:runtime_state, :paused?]) == false
    assert get_in(released_context, [:runtime_state, :lifecycle_state]) == "terminal"

    assert {:ok, completed} = Service.refresh_completion(repo, request.id)
    assert %DateTime{} = completed.completed_at
    assert {:ok, archived} = Service.archive(repo, request.id)
    assert %DateTime{} = archived.archived_at
  end

  test "completion waits for questions and runtime while clearing terminal package blockers", %{repo: repo} do
    assert {:ok, human_request} = Repository.create(repo, attrs(id: "WR-COMPLETE-HUMAN", status: "ready_for_slicing"))
    assert {:ok, human_slice} = CanonicalWorkPackageFixtures.add_work_package(repo, human_request.id, work_package_attrs(id: "WRS-COMPLETE-HUMAN"))
    assert {:ok, _human_skipped} = Repository.skip_work_package(repo, human_request.id, human_slice.id, "planned")
    human_request |> Ecto.Changeset.change(status: "human_info_needed") |> repo.update!()

    assert {:ok, waiting_for_human} = Service.refresh_completion(repo, human_request.id)
    assert waiting_for_human.completed_at == nil
    assert {:error, :not_completed} = Service.archive(repo, human_request.id)

    assert {:ok, question_request} = Repository.create(repo, attrs(id: "WR-COMPLETE-QUESTION", status: "ready_for_slicing"))
    assert {:ok, question_slice} = CanonicalWorkPackageFixtures.add_work_package(repo, question_request.id, work_package_attrs(id: "WRS-COMPLETE-QUESTION"))
    assert {:ok, _skipped} = Repository.skip_work_package(repo, question_request.id, question_slice.id, "planned")
    assert {:ok, open_question} = Repository.ask_question(repo, question_request.id, question_attrs(id: "WRQ-COMPLETE-OPEN"))

    assert {:ok, with_question} = Service.refresh_completion(repo, question_request.id)
    assert with_question.completed_at == nil

    assert {:ok, _closed} = Repository.close_question(repo, open_question.id, "open")
    assert {:ok, without_question} = Service.refresh_completion(repo, question_request.id)
    assert %DateTime{} = without_question.completed_at

    assert {:ok, linked_request} = Repository.create(repo, attrs(id: "WR-COMPLETE-LINKED", status: "ready_for_slicing"))
    assert {:ok, work_package} = CanonicalWorkPackageFixtures.add_work_package(repo, linked_request.id, work_package_attrs(id: "WRS-COMPLETE-LINKED"))
    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, linked_request.id, work_package.id, "planned")
    linked_package = set_work_package_status!(repo, approved_slice, "merged")

    append_blocker_event!(repo, linked_package.id, "blocker-completion", true)
    assert {:ok, completed_after_cleanup} = Service.refresh_completion(repo, linked_request.id)
    assert %DateTime{} = completed_after_cleanup.completed_at
    refute WorkPackageActivity.context(repo, linked_package.id).blocker_state.active?

    assert {:ok, ordered_request} = Repository.create(repo, attrs(id: "WR-COMPLETE-BLOCKER-ORDER", status: "ready_for_slicing"))
    assert {:ok, ordered_slice} = CanonicalWorkPackageFixtures.add_work_package(repo, ordered_request.id, work_package_attrs(id: "WRS-COMPLETE-BLOCKER-ORDER"))
    assert {:ok, ordered_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, ordered_request.id, ordered_slice.id, "planned")
    ordered_package = set_work_package_status!(repo, ordered_slice, "merged")

    event_time = utc_usec(~U[2026-05-23 12:00:00Z])
    append_blocker_event!(repo, ordered_package.id, "blocker-order", true, created_at: DateTime.add(event_time, 10, :second))
    append_blocker_event!(repo, ordered_package.id, "blocker-order", false, created_at: DateTime.add(event_time, -10, :second))
    assert {:ok, ordered_unblocked} = Service.refresh_completion(repo, ordered_request.id)
    assert %DateTime{} = ordered_unblocked.completed_at

    assert {:ok, runtime_request} = Repository.create(repo, attrs(id: "WR-COMPLETE-RUNTIME", status: "ready_for_slicing"))
    assert {:ok, runtime_slice} = CanonicalWorkPackageFixtures.add_work_package(repo, runtime_request.id, work_package_attrs(id: "WRS-COMPLETE-RUNTIME"))
    assert {:ok, runtime_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, runtime_request.id, runtime_slice.id, "planned")
    runtime_package = set_work_package_status!(repo, runtime_slice, "merged")

    assert {:ok, run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: runtime_package.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "completion-runtime"
             })

    assert {:ok, with_runtime} = Service.refresh_completion(repo, runtime_request.id)
    assert with_runtime.completed_at == nil
    assert {:error, :not_completed} = Service.archive(repo, runtime_request.id)

    assert {:ok, _completed_run} = AgentRunRepository.mark_completed(repo, run.id, "done")
    assert {:ok, without_runtime} = Service.refresh_completion(repo, runtime_request.id)
    assert %DateTime{} = without_runtime.completed_at
  end

  test "visible completion treats terminal package cards as terminal" do
    updated_at = utc_usec(~U[2026-05-23 12:00:00Z])
    work_request = %WorkRequest{id: "WR-COMPLETE-CARD", status: "ready_for_slicing", updated_at: updated_at}
    work_package = %WorkPackage{id: "WP-COMPLETE-CARD", status: "merged", updated_at: updated_at}

    state =
      Completion.visible_state(
        work_request,
        %{open_count: 0, latest_gate_at: nil},
        [work_package],
        %{"WP-COMPLETE-CARD" => %{card: %{operational_state: %{key: "merged"}}}}
      )

    assert state.completed? == true
    assert state.completed_at == updated_at

    running_state =
      Completion.visible_state(
        work_request,
        %{open_count: 0, latest_gate_at: nil},
        [work_package],
        %{"WP-COMPLETE-CARD" => %{card: %{operational_state: %{"key" => "merged", "has_active_worker" => true}}}}
      )

    refute running_state.completed?

    blocked_state =
      Completion.visible_state(
        work_request,
        %{open_count: 0, latest_gate_at: nil},
        [work_package],
        %{"WP-COMPLETE-CARD" => %{card: %{operational_state: %{"key" => "merged", "attention_items" => [%{"key" => "active_blocker"}]}}}}
      )

    refute blocked_state.completed?
  end

  test "visible completion preserves persisted state when only some terminal slices are visible" do
    completed_at = utc_usec(~U[2026-05-23 12:00:00Z])

    work_request = %WorkRequest{
      id: "WR-COMPLETE-FILTERED",
      status: "ready_for_slicing",
      completed_at: completed_at,
      updated_at: completed_at
    }

    visible_slice = %WorkPackage{id: "WP-COMPLETE-FILTERED-1", status: "merged", updated_at: completed_at}
    filtered_slice = %WorkPackage{id: "WP-COMPLETE-FILTERED-2", status: "merged", updated_at: completed_at}

    state =
      Completion.visible_state(
        work_request,
        %{open_count: 0, latest_gate_at: nil},
        [visible_slice, filtered_slice],
        %{"WP-COMPLETE-FILTERED-1" => %{card: %{operational_state: %{key: "merged"}}}}
      )

    assert state.completed? == true
    assert state.completed_at == completed_at
  end

  test "visible completion treats delivery-backed approved slices as terminal" do
    completed_at = utc_usec(~U[2026-05-23 12:00:00Z])
    archived_at = utc_usec(~U[2026-05-24 12:00:00Z])

    work_request = %WorkRequest{
      id: "WR-COMPLETE-DELIVERED-APPROVED",
      status: "ready_for_slicing",
      completed_at: completed_at,
      archived_at: archived_at,
      updated_at: completed_at
    }

    work_package = %WorkPackage{
      id: "WRS-COMPLETE-DELIVERED-APPROVED",
      work_request_id: work_request.id,
      status: "approved",
      updated_at: completed_at
    }

    state =
      Completion.visible_state(
        work_request,
        %{open_count: 0, latest_gate_at: nil},
        [work_package],
        %{},
        %{work_package.id => %{outcome: "completed_no_pr"}}
      )

    assert state.completed? == true
    assert state.completed_at == completed_at
    assert state.archived_at == archived_at

    derived_state =
      Completion.visible_state(
        %{work_request | completed_at: nil, archived_at: nil},
        %{open_count: 0, latest_gate_at: nil},
        [work_package],
        %{},
        %{work_package.id => %{outcome: "completed_no_pr"}}
      )

    assert derived_state.completed? == true
    assert derived_state.completed_at == completed_at
  end

  test "returns not found for missing work requests", %{repo: repo} do
    assert {:error, :not_found} = Repository.get(repo, "missing")
    assert {:error, :not_found} = Repository.update(repo, "missing", %{title: "Nope"})
  end

  test "activity context derives active stale paused recycled and terminal runtime state", %{repo: repo} do
    now = DateTime.utc_now(:microsecond)
    stale_seen_at = DateTime.add(now, -10, :second)

    active_package = create_activity_work_package!(repo, "WP-ACTIVITY-ACTIVE", status: "implementing")
    stale_package = create_activity_work_package!(repo, "WP-ACTIVITY-STALE", status: "implementing")
    mixed_package = create_activity_work_package!(repo, "WP-ACTIVITY-MIXED", status: "implementing")
    paused_package = create_activity_work_package!(repo, "WP-ACTIVITY-PAUSED", status: "implementing")
    recycled_package = create_activity_work_package!(repo, "WP-ACTIVITY-RECYCLED", status: "ready_for_worker")
    ready_package = create_activity_work_package!(repo, "WP-ACTIVITY-READY", status: "ready_for_merge")
    terminal_package = create_activity_work_package!(repo, "WP-ACTIVITY-TERMINAL", status: "closed")
    agent_package = create_activity_work_package!(repo, "WP-ACTIVITY-AGENT-STALE", status: "implementing")

    assert {:ok, _active_lease} =
             ClaimLeaseService.claim(repo, active_package.id, activity_actor("active-worker"), stale_after_ms: 60_000)

    insert_claimed_activity_grant!(repo, active_package, "architect", "active-architect")

    assert {:ok, _stale_lease} =
             ClaimLeaseService.claim(repo, stale_package.id, activity_actor("stale-worker"), now: stale_seen_at, stale_after_ms: 1)

    assert {:ok, _mixed_stale_lease} =
             ClaimLeaseService.claim(repo, mixed_package.id, activity_actor("mixed-worker"), now: stale_seen_at, stale_after_ms: 1)

    insert_claimed_activity_grant!(repo, mixed_package, "architect", "mixed-architect")

    assert {:ok, paused_lease} =
             ClaimLeaseService.claim(repo, paused_package.id, activity_actor("paused-worker"), stale_after_ms: 60_000)

    assert {:ok, paused_lease} = ClaimLeaseService.pause(repo, paused_lease.id, activity_actor("operator"), reason: "operator pause")

    paused_lease
    |> ClaimLease.update_changeset(%{last_seen_at: stale_seen_at, stale_after_ms: 1})
    |> repo.update!()

    insert_claimed_activity_grant!(repo, paused_package, "architect", "paused-architect")

    assert {:ok, _reclaimed_lease} =
             ClaimLeaseService.claim(repo, recycled_package.id, activity_actor("old-worker"), now: stale_seen_at, stale_after_ms: 1)

    assert {:ok, replacement_lease} =
             ClaimLeaseService.reclaim_stale(repo, recycled_package.id, activity_actor("replacement-worker"),
               reason: "worker_recycled",
               stale_after_ms: 60_000
             )

    insert_claimed_activity_grant!(repo, ready_package, "worker", "ready-worker")

    assert {:ok, ready_lease} =
             ClaimLeaseService.claim(repo, ready_package.id, activity_actor("ready-worker"), stale_after_ms: 60_000)

    assert {:ok, _released_ready_lease} = ClaimLeaseService.release(repo, ready_lease.id, reason: "worker finished")

    assert {:ok, _completed_ready_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: ready_package.id,
               status: "completed",
               started_at: DateTime.add(now, -60, :second),
               last_seen_at: now,
               finished_at: now
             })

    assert {:ok, agent_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: agent_package.id,
               status: "running",
               last_seen_at: DateTime.add(now, -301, :second)
             })

    assert {:ok, _terminal_lease} =
             ClaimLeaseService.claim(repo, terminal_package.id, activity_actor("terminal-worker"), now: stale_seen_at, stale_after_ms: 1)

    insert_claimed_activity_grant!(repo, terminal_package, "architect", "terminal-architect")

    assert {:ok, _terminal_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: terminal_package.id,
               status: "running",
               last_seen_at: DateTime.add(now, -301, :second)
             })

    contexts =
      WorkPackageActivity.contexts(repo, [
        active_package.id,
        stale_package.id,
        mixed_package.id,
        paused_package.id,
        recycled_package.id,
        ready_package.id,
        terminal_package.id,
        agent_package.id
      ])

    assert get_in(contexts, [active_package.id, :runtime_state, :lifecycle_state]) == "active"
    assert get_in(contexts, [active_package.id, :runtime_state, :reason_codes]) == ["claim_lease_active", "architect_grant_active"]

    stale_runtime = get_in(contexts, [stale_package.id, :runtime_state])
    assert stale_runtime.active? == true
    assert stale_runtime.stale? == true
    assert "claim_lease_stale" in stale_runtime.reason_codes
    assert DateTime.compare(stale_runtime.latest_gate_at, DateTime.add(stale_seen_at, 1, :millisecond)) == :eq

    mixed_runtime = get_in(contexts, [mixed_package.id, :runtime_state])
    assert mixed_runtime.active? == true
    assert mixed_runtime.stale? == true
    assert mixed_runtime.lifecycle_state == "stale"
    assert "claim_lease_stale" in mixed_runtime.reason_codes
    assert "architect_grant_active" in mixed_runtime.reason_codes

    paused_runtime = get_in(contexts, [paused_package.id, :runtime_state])
    assert paused_runtime.active? == true
    assert paused_runtime.paused? == true
    assert paused_runtime.stale? == false
    assert paused_runtime.lifecycle_state == "paused"
    assert paused_runtime.reason_codes == ["claim_lease_paused", "architect_grant_active"]

    recycled_runtime = get_in(contexts, [recycled_package.id, :runtime_state])
    assert recycled_runtime.active? == true
    assert recycled_runtime.recycled? == true
    assert recycled_runtime.lifecycle_state == "active"
    assert "worker_recycled" in recycled_runtime.reason_codes
    assert DateTime.compare(recycled_runtime.latest_gate_at, DateTime.add(stale_seen_at, 1, :millisecond)) == :gt
    assert get_in(contexts, [recycled_package.id, :worker_signal, :active_since]) == replacement_lease.lease_started_at

    ready_context = contexts[ready_package.id]
    assert ready_context.runtime_state.active? == false
    assert ready_context.runtime_state.lifecycle_state == "idle"
    assert ready_context.worker_signal.status == "idle"

    terminal_runtime = get_in(contexts, [terminal_package.id, :runtime_state])
    assert terminal_runtime.active? == true
    assert terminal_runtime.stale? == true
    assert terminal_runtime.terminal? == true
    assert terminal_runtime.lifecycle_state == "stale"
    assert "claim_lease_stale" in terminal_runtime.reason_codes
    assert "agent_run_stale" in terminal_runtime.reason_codes
    assert "architect_grant_active" in terminal_runtime.reason_codes
    assert "package_terminal" in terminal_runtime.reason_codes

    agent_runtime = get_in(contexts, [agent_package.id, :runtime_state])
    assert agent_runtime.active? == false
    assert agent_runtime.stale? == true
    assert agent_runtime.lifecycle_state == "stale"
    assert "agent_run_stale" in agent_runtime.reason_codes
    assert agent_runtime.active_agent_run_ids == []
    assert agent_runtime.stale_agent_run_ids == [agent_run.id]
  end

  test "migration is idempotent", %{repo: repo} do
    assert :ok = Repository.migrate(repo)
  end

  test "migration marks id as primary key and creates listing indexes", %{repo: repo} do
    %{rows: table_rows} = SQL.query!(repo, "PRAGMA table_info(sympp_work_requests)")

    assert [_cid, "id", _type, _not_null, _default, 1] = Enum.find(table_rows, &(Enum.at(&1, 1) == "id"))

    %{rows: index_rows} = SQL.query!(repo, "PRAGMA index_list(sympp_work_requests)")
    index_names = Enum.map(index_rows, &Enum.at(&1, 1))

    assert "sympp_work_requests_status_index" in index_names
    assert "sympp_work_requests_repo_base_branch_index" in index_names
    assert "sympp_work_requests_status_repo_base_branch_index" in index_names

    %{rows: repo_scope_index_rows} = SQL.query!(repo, "PRAGMA index_list(sympp_work_request_repo_scopes)")
    repo_scope_index_names = Enum.map(repo_scope_index_rows, &Enum.at(&1, 1))

    assert "sympp_work_request_repo_scopes_work_request_scope_key_unique_index" in repo_scope_index_names
    assert "sympp_work_request_repo_scopes_repo_base_branch_index" in repo_scope_index_names
  end

  defp attrs(overrides) do
    defaults = %{
      title: "Improve intake flow",
      repo: "nextide/example",
      base_branch: "main",
      work_type: "feature",
      human_description: "Record the human's desired outcome before slicing.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "single_package"
    }

    Enum.into(overrides, defaults)
  end

  defp work_package_attrs(overrides) do
    defaults = %{
      title: "Complete WorkRequest state",
      goal: "Track completed WorkRequests.",
      kind: "mcp",
      base_branch: "main",
      allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: [],
      acceptance_criteria: ["Completion state is explicit."],
      validation_steps: ["mix test"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: []
    }

    Enum.into(overrides, defaults)
  end

  defp question_attrs(overrides) do
    defaults = %{
      category: "product",
      question: "Is the WorkRequest done?",
      why_needed: "Open human questions keep the WorkRequest visible."
    }

    Enum.into(overrides, defaults)
  end

  defp decision_attrs(overrides) do
    defaults = %{
      source_type: "architect",
      decision: "Archive only after completion.",
      rationale: "The ledger remains the audit source.",
      scope_impact: "No hard delete.",
      created_by: "retention-test"
    }

    Enum.into(overrides, defaults)
  end

  defp completed_skipped_request!(repo, id, completed_at, overrides \\ []) do
    assert {:ok, request} = Repository.create(repo, attrs(Keyword.merge([id: id, status: "ready_for_slicing"], overrides)))

    assert {:ok, slice} =
             CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WRS-#{id}", base_branch: request.base_branch))

    assert {:ok, _skipped} = Repository.skip_work_package(repo, request.id, slice.id, "planned")
    assert {:ok, completed} = Service.refresh_completion(repo, request.id)

    completed
    |> Ecto.Changeset.change(completed_at: completed_at, archived_at: nil)
    |> repo.update!()
  end

  defp completed_linked_request!(repo, id, completed_at) do
    assert {:ok, request} = Repository.create(repo, attrs(id: id, status: "ready_for_slicing"))

    assert {:ok, slice} =
             CanonicalWorkPackageFixtures.add_work_package(repo, request.id, work_package_attrs(id: "WRS-#{id}", base_branch: request.base_branch))

    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, request.id, slice.id, "planned")
    package = set_work_package_status!(repo, approved_slice, "merged")
    assert {:ok, completed} = Service.refresh_completion(repo, request.id)

    completed =
      completed
      |> Ecto.Changeset.change(completed_at: completed_at, archived_at: nil)
      |> repo.update!()

    {completed, package}
  end

  defp prepare_managed_worktree!(repo, %WorkPackage{} = package, repo_root, codex_home, branch) do
    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{
                 "repo_root" => repo_root,
                 "base_branch" => package.base_branch,
                 "branch" => branch
               },
               codex_home: codex_home
             )

    prepared
  end

  defp create_activity_work_package!(repo, id, overrides) do
    attrs =
      overrides
      |> Map.new()
      |> Map.merge(%{
        id: id,
        kind: "mcp",
        title: id,
        repo: "nextide/example",
        base_branch: "main",
        acceptance_criteria: ["Activity context is projected."]
      })

    assert {:ok, work_package} = WorkPackageRepository.create(repo, attrs)
    work_package
  end

  defp activity_actor(name) do
    %{
      "actor_kind" => "agent",
      "actor_id" => "agent:#{name}",
      "actor_display_name" => name
    }
  end

  defp insert_claimed_activity_grant!(repo, work_package, role, claimed_by) do
    suffix = System.unique_integer([:positive]) |> Integer.to_string(36)

    assert {:ok, grant} =
             AccessGrantRepository.create(repo, %{
               id: "grant-#{work_package.id}-#{suffix}",
               work_package_id: work_package.id,
               display_key: suffix |> String.pad_leading(4, "0") |> String.slice(-4, 4),
               secret_hash: :crypto.hash(:sha256, "activity-#{work_package.id}-#{suffix}") |> Base.encode16(case: :lower),
               grant_role: role,
               capabilities: []
             })

    now = DateTime.utc_now(:microsecond)

    grant
    |> Ecto.Changeset.change(claimed_at: now, claimed_by: claimed_by, updated_at: now)
    |> repo.update!()
  end

  defp insert_grant_scope!(repo, access_grant_id, scope_type, scope_id) do
    now = DateTime.utc_now(:microsecond)

    assert {1, _rows} =
             repo.insert_all("sympp_access_grant_scopes", [
               %{
                 id: "ags-retention-#{access_grant_id}-#{scope_type}",
                 access_grant_id: access_grant_id,
                 scope_type: scope_type,
                 scope_key: "#{scope_type}:#{scope_id}",
                 scope_id: scope_id,
                 inserted_at: now,
                 updated_at: now
               }
             ])
  end

  defp grant_scope_count(repo, scope_type, scope_id) do
    %{rows: [[count]]} =
      SQL.query!(
        repo,
        "SELECT COUNT(*) FROM sympp_access_grant_scopes WHERE scope_type = ? AND scope_id = ?",
        [scope_type, scope_id]
      )

    count
  end

  defp utc_usec(%DateTime{} = datetime), do: %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}

  defp set_archived_at!(repo, %WorkRequest{} = work_request, %DateTime{} = archived_at) do
    work_request
    |> Ecto.Changeset.change(archived_at: archived_at, updated_at: archived_at)
    |> repo.update!()
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp assert_eventually(fun, attempts \\ 40)
  defp assert_eventually(_fun, 0), do: flunk("condition was not met before timeout")

  defp assert_eventually(fun, attempts) when is_function(fun, 0) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
  end

  defp set_work_package_status!(repo, work_package, status) do
    repo.update!(
      Ecto.Changeset.change(work_package,
        status: status,
        dispatched_at: DateTime.utc_now(:microsecond)
      )
    )
  end

  defp append_blocker_event!(repo, work_package_id, blocker_id, active, overrides \\ []) do
    assert {:ok, event} =
             PlanningRepository.append_progress_event(
               repo,
               Enum.into(overrides, %{
                 work_package_id: work_package_id,
                 summary: "Blocked",
                 status: if(active, do: "blocked", else: "unblocked"),
                 idempotency_key: "#{blocker_id}-#{active}-#{System.unique_integer([:positive])}",
                 payload: %{type: "blocker", source_tool: blocker_source_tool(active), blocker_id: blocker_id, active: active}
               })
             )

    event
  end

  defp blocker_source_tool(true), do: "report_blocker"
  defp blocker_source_tool(false), do: "resolve_blocker"

  defp database_path do
    Path.join(System.tmp_dir!(), "sympp-work-requests-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", inspect(value))
      end)
    end)
  end
end
