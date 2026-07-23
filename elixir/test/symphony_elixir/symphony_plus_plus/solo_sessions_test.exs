defmodule SymphonyElixir.SymphonyPlusPlus.SoloSessionsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
  alias SymphonyElixir.WorkPackageFactory

  defmodule BusyOnceRepo do
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def transaction(fun) do
      if Process.get(:sympp_solo_busy_once) do
        Repo.transaction(fun)
      else
        Process.put(:sympp_solo_busy_once, true)
        raise %Exqlite.Error{message: "database is locked"}
      end
    end

    def rollback(reason), do: Repo.rollback(reason)
    def one(query), do: Repo.one(query)
    def all(query), do: Repo.all(query)
    def get(schema, id), do: Repo.get(schema, id)
    def get!(schema, id), do: Repo.get!(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def update_all(query, updates), do: Repo.update_all(query, updates)
  end

  defmodule StaleCurrentReadRepo do
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def transaction(fun), do: Repo.transaction(fun)
    def rollback(reason), do: Repo.rollback(reason)

    def one(query) do
      if Process.get(:sympp_solo_stale_current_read) do
        Repo.one(query)
      else
        Process.put(:sympp_solo_stale_current_read, true)
        nil
      end
    end

    def all(query), do: Repo.all(query)
    def get(schema, id), do: Repo.get(schema, id)
    def get!(schema, id), do: Repo.get!(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def update_all(query, updates), do: Repo.update_all(query, updates)
  end

  defmodule StaleEntryIdempotencyReadRepo do
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def transaction(fun), do: Repo.transaction(fun)
    def rollback(reason), do: Repo.rollback(reason)

    def one(query) do
      if Process.get(:sympp_solo_stale_entry_idempotency_read) do
        Repo.one(query)
      else
        Process.put(:sympp_solo_stale_entry_idempotency_read, true)
        nil
      end
    end

    def all(query), do: Repo.all(query)
    def get(schema, id), do: Repo.get(schema, id)
    def get!(schema, id), do: Repo.get!(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def update_all(query, updates), do: Repo.update_all(query, updates)
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(SoloSessionEntry)
    repo.delete_all(SoloSession)
    Process.delete(:sympp_solo_busy_once)
    Process.delete(:sympp_solo_stale_current_read)
    Process.delete(:sympp_solo_stale_entry_idempotency_read)
    :ok
  end

  test "creates and reattaches the active current session by lookup scope", %{repo: repo} do
    attrs = session_attrs()
    before_create = DateTime.utc_now(:microsecond)

    assert {:ok, %SoloSession{} = first} = Service.create_or_attach_current(repo, attrs)
    assert first.id =~ "solo_"
    assert first.session_key =~ "solo_key_"
    assert first.status == "active"
    assert DateTime.compare(first.last_activity_at, before_create) in [:eq, :gt]
    assert %DateTime{} = first.inserted_at
    assert %DateTime{} = first.updated_at

    Process.sleep(5)

    assert {:ok, second} =
             Service.create_or_attach_current(
               repo,
               Map.merge(attrs, %{id: "caller-id", session_key: "caller-key", status: "archived", title: "Replay"})
             )

    assert second.id == first.id
    assert second.session_key == first.session_key
    assert second.title == first.title
    assert DateTime.compare(second.last_activity_at, first.last_activity_at) == :gt

    assert {:ok, [listed]} = Service.list(repo)
    assert listed.id == first.id
  end

  test "reattaches paused sessions and does not attach completed or archived sessions", %{repo: repo} do
    attrs = session_attrs()

    assert {:ok, active} = Service.create_or_attach_current(repo, attrs)
    assert {:ok, paused} = Service.pause(repo, active.id, "active")
    Process.sleep(5)

    assert {:ok, attached_paused} = Service.create_or_attach_current(repo, attrs)
    assert attached_paused.id == paused.id
    assert attached_paused.status == "paused"
    assert DateTime.compare(attached_paused.last_activity_at, paused.last_activity_at) == :gt

    assert {:ok, completed} = Service.complete(repo, attached_paused.id, "paused")
    assert {:ok, new_after_completed} = Service.create_or_attach_current(repo, attrs)

    assert completed.status == "completed"
    assert new_after_completed.id != completed.id
    assert new_after_completed.status == "active"

    assert {:ok, archived} = Service.archive(repo, new_after_completed.id, "active")
    assert {:ok, new_after_archived} = Service.create_or_attach_current(repo, attrs)

    assert archived.status == "archived"
    refute new_after_archived.id in [completed.id, archived.id]
    assert new_after_archived.status == "active"
  end

  test "active and paused uniqueness is enforced at the SQLite index", %{repo: repo} do
    attrs = session_attrs()
    assert {:ok, current} = Service.create_or_attach_current(repo, attrs)

    duplicate_attrs = %{
      repo: current.repo,
      base_branch: current.base_branch,
      workspace_path: current.workspace_path,
      caller_id: current.caller_id,
      title: "Duplicate current"
    }

    assert {:error, %Changeset{} = changeset} = Repo.insert(SoloSession.create_changeset(duplicate_attrs))
    assert "has already been taken" in errors_on(changeset).repo
  end

  test "caller-owned identifiers status and timestamps are ignored on create attach", %{repo: repo} do
    caller_time = ~U[2001-01-01 00:00:00.000000Z]
    before_create = DateTime.utc_now(:microsecond)

    attrs =
      session_attrs(
        id: "caller-session-id",
        session_key: "caller-session-key",
        status: "archived",
        last_activity_at: caller_time,
        archived_at: caller_time,
        inserted_at: caller_time,
        updated_at: caller_time,
        created_at: caller_time
      )

    assert {:ok, session} = Service.create_or_attach_current(repo, attrs)

    refute session.id == "caller-session-id"
    refute session.session_key == "caller-session-key"
    assert session.status == "active"
    assert is_nil(session.archived_at)
    assert DateTime.compare(session.last_activity_at, before_create) in [:eq, :gt]
    refute session.inserted_at == caller_time
    refute session.updated_at == caller_time
  end

  test "lifecycle transitions match the Solo Session contract", %{repo: repo} do
    valid_transitions = [
      {"active", "paused"},
      {"active", "completed"},
      {"active", "archived"},
      {"paused", "active"},
      {"paused", "completed"},
      {"paused", "archived"},
      {"completed", "archived"}
    ]

    for {current_status, next_status} <- valid_transitions do
      assert {:ok, session} = session_in_status(repo, current_status, "#{current_status}-#{next_status}")
      Process.sleep(5)

      assert {:ok, updated} = Service.update_status(repo, session.id, current_status, next_status)
      assert updated.status == next_status
      assert DateTime.compare(updated.last_activity_at, session.last_activity_at) == :gt

      if next_status == "archived" do
        assert %DateTime{} = updated.archived_at
      end
    end

    assert {:ok, completed} = session_in_status(repo, "completed", "completed-active")
    assert {:error, :invalid_transition} = Service.update_status(repo, completed.id, "completed", "active")

    assert {:ok, archived} = session_in_status(repo, "archived", "archived-active")
    assert {:error, :invalid_transition} = Service.update_status(repo, archived.id, "archived", "active")
    assert {:error, :invalid_status} = Service.update_status(repo, archived.id, "archived", "claimed")
  end

  test "same-status active and paused no-ops are rejected without mutating timestamps", %{repo: repo} do
    assert {:ok, active} = Service.create_or_attach_current(repo, session_attrs(caller_id: "active-no-op"))
    Process.sleep(5)

    assert {:error, :invalid_transition} = Service.update_status(repo, active.id, "active", "active")
    assert {:ok, active_after_noop} = Service.get(repo, active.id)
    assert active_after_noop.last_activity_at == active.last_activity_at
    assert active_after_noop.updated_at == active.updated_at
    assert active_after_noop.archived_at == active.archived_at

    assert {:ok, paused} = Service.pause(repo, active.id, "active")
    Process.sleep(5)

    assert {:error, :invalid_transition} = Service.update_status(repo, paused.id, "paused", "paused")
    assert {:ok, paused_after_noop} = Service.get(repo, paused.id)
    assert paused_after_noop.last_activity_at == paused.last_activity_at
    assert paused_after_noop.updated_at == paused.updated_at
    assert paused_after_noop.archived_at == paused.archived_at
  end

  test "retention archives active, paused, and completed sessions at seven inactive days", %{repo: repo} do
    now = ~U[2026-05-15 12:00:00.000000Z]
    cutoff = DateTime.add(now, -7 * 24 * 60 * 60, :second)
    fresh = DateTime.add(cutoff, 1, :second)

    assert {:ok, old_active} = Service.create_or_attach_current(repo, session_attrs(caller_id: "old-active"))
    old_active = set_last_activity!(repo, old_active, cutoff)

    assert {:ok, old_paused} = Service.create_or_attach_current(repo, session_attrs(caller_id: "old-paused"))
    assert {:ok, old_paused} = Service.pause(repo, old_paused.id, "active")
    old_paused = set_last_activity!(repo, old_paused, cutoff)

    assert {:ok, fresh_session} = Service.create_or_attach_current(repo, session_attrs(caller_id: "fresh"))
    fresh_session = set_last_activity!(repo, fresh_session, fresh)

    assert {:ok, completed} = Service.create_or_attach_current(repo, session_attrs(caller_id: "completed-old"))
    assert {:ok, completed} = Service.complete(repo, completed.id, "active")
    completed = set_last_activity!(repo, completed, cutoff)

    assert {:ok, %{archived: 3, deleted: 0}} = Service.retention_pass(repo, now)

    assert {:ok, old_active} = Service.get(repo, old_active.id)
    assert {:ok, old_paused} = Service.get(repo, old_paused.id)
    assert {:ok, fresh_session} = Service.get(repo, fresh_session.id)
    assert {:ok, completed} = Service.get(repo, completed.id)

    assert old_active.status == "archived"
    assert old_active.last_activity_at == cutoff
    assert old_active.archived_at == now
    assert old_paused.status == "archived"
    assert old_paused.archived_at == now
    assert fresh_session.status == "active"
    assert completed.status == "archived"
  end

  test "retention deletes at fourteen inactive days, including late archives, and cascades entries", %{repo: repo} do
    now = ~U[2026-05-15 12:00:00.000000Z]
    cutoff = DateTime.add(now, -14 * 24 * 60 * 60, :second)
    fresh = DateTime.add(cutoff, 1, :second)

    assert {:ok, late} = Service.create_or_attach_current(repo, session_attrs(caller_id: "late-completed"))
    assert {:ok, late_entry} = Service.append_progress(repo, late.id, %{summary: "Late note"})
    assert {:ok, late} = Service.complete(repo, late.id, "active")
    late = set_last_activity!(repo, late, cutoff)

    assert {:ok, archived} = Service.create_or_attach_current(repo, session_attrs(caller_id: "boundary-archived"))
    assert {:ok, archived_entry} = Service.append_progress(repo, archived.id, %{summary: "Old note"})
    assert {:ok, archived} = Service.archive(repo, archived.id, "active")
    archived = set_last_activity!(repo, archived, cutoff)
    archived = set_archived_at!(repo, archived, now)

    assert {:ok, recent} = Service.create_or_attach_current(repo, session_attrs(caller_id: "recent-archived"))
    assert {:ok, recent} = Service.archive(repo, recent.id, "active")
    recent = set_last_activity!(repo, recent, fresh)
    recent = set_archived_at!(repo, recent, DateTime.add(now, -30 * 24 * 60 * 60, :second))

    assert {:ok, %{archived: 1, deleted: 2}} = Service.retention_pass(repo, now)

    assert late.last_activity_at == cutoff
    assert archived.last_activity_at == cutoff
    assert {:error, :not_found} = Service.get(repo, late.id)
    assert {:error, :not_found} = Service.get(repo, archived.id)
    refute Enum.any?(repo.all(SoloSessionEntry), &(&1.id in [late_entry.id, archived_entry.id]))

    assert {:ok, ^recent} = Service.get(repo, recent.id)
  end

  test "read and list do not advance activity", %{repo: repo} do
    assert {:ok, session} = Service.create_or_attach_current(repo, session_attrs())
    Process.sleep(5)

    assert {:ok, read} = Service.get(repo, session.id)
    assert read.last_activity_at == session.last_activity_at

    assert {:ok, [listed]} = Service.list(repo, %{repo: session.repo})
    assert listed.id == session.id
    assert listed.last_activity_at == session.last_activity_at
  end

  test "appends ordered entries to active and paused sessions and redacts persisted text and payload", %{repo: repo} do
    caller_time = ~U[2001-01-01 00:00:00.000000Z]
    assert {:ok, session} = Service.create_or_attach_current(repo, session_attrs())
    Process.sleep(5)

    assert {:ok, first} =
             Service.append_entry(repo, session.id, %{
               id: "caller-entry-id",
               solo_session_id: "caller-session-id",
               entry_kind: " task_plan ",
               title: "Plan bearer abcdefghijkl",
               body: "Use ghp_abcdefgh as a fake token",
               status: " pending ",
               sequence: 99,
               idempotency_key: " entry-1 ",
               payload: %{
                 token: "ghp_abcdefgh",
                 nested: [%{url: "https://example.test/path?token=ghp_abcdefgh"}],
                 at: caller_time
               },
               created_at: caller_time,
               updated_at: caller_time
             })

    assert first.id =~ "solo_entry_"
    assert first.solo_session_id == session.id
    assert first.entry_kind == "task_plan"
    assert first.title == "Plan [REDACTED]"
    assert first.body == "Use [REDACTED] as a fake token"
    assert first.status == "pending"
    assert first.sequence == 1
    assert first.idempotency_key == "entry-1"
    assert first.payload["token"] == "[REDACTED]"
    assert first.payload["nested"] == [%{"url" => "https://example.test/path?token=[REDACTED]"}]
    assert first.payload["at"] == DateTime.to_iso8601(caller_time)
    refute first.id == "caller-entry-id"
    refute first.solo_session_id == "caller-session-id"
    refute first.created_at == caller_time
    refute first.updated_at == caller_time

    assert {:ok, touched} = Service.get(repo, session.id)
    assert DateTime.compare(touched.last_activity_at, session.last_activity_at) == :gt

    assert {:ok, paused} = Service.pause(repo, session.id, "active")
    Process.sleep(5)

    assert {:ok, second} =
             Service.append_entry(repo, paused.id, %{
               entry_kind: "progress",
               title: "Paused session progress",
               status: "recorded"
             })

    assert second.sequence == 2
    assert {:ok, [^first, ^second]} = Service.list_entries(repo, session.id)
  end

  test "friendly entry helpers normalize agent labels and typed payloads", %{repo: repo} do
    assert {:ok, session} = Service.create_or_attach_current(repo, session_attrs())

    assert {:error, {:unsupported_solo_field, "status"}} =
             Service.report_blocker(repo, session.id, %{
               summary: "Bad blocker status",
               status: "resolved"
             })

    assert {:ok, progress} =
             Service.append_progress(repo, session.id, %{
               summary: "Implementation started",
               status: "active",
               idempotency_key: "friendly-progress"
             })

    assert progress.entry_kind == "progress"
    assert progress.status == "in_progress"
    assert progress.title == "Implementation started"

    assert {:ok, validation} =
             Service.record_validation(repo, session.id, %{
               summary: "Focused tests",
               result: "pass",
               command: "mix test test/symphony_elixir/symphony_plus_plus/solo_sessions_test.exs",
               evidence: "Passed locally"
             })

    assert validation.entry_kind == "validation_note"
    assert validation.status == "completed"
    assert validation.payload["result"] == "passed"
    assert validation.payload["command"] =~ "mix test"
    assert validation.payload["evidence"] == "Passed locally"

    assert {:ok, blocker} =
             Service.report_blocker(repo, session.id, %{
               summary: "Review asked for broader scope",
               blocker_id: "scope-review"
             })

    assert blocker.entry_kind == "blocker"
    assert blocker.status == "blocked"
    assert blocker.payload["blocker_id"] == "scope-review"
    assert blocker.payload["blocker_status"] == "open"

    assert {:ok, resolved} =
             Service.resolve_blocker(repo, session.id, %{
               blocker_id: "scope-review",
               resolution: "Architect approved the broader file set",
               idempotency_key: "resolve-scope-review"
             })

    assert resolved.entry_kind == "blocker"
    assert resolved.status == "resolved"
    assert resolved.payload["blocker_id"] == "scope-review"
    assert resolved.payload["blocker_status"] == "resolved"
    assert resolved.payload["resolution"] == "Architect approved the broader file set"

    assert {:ok, retried_resolved} =
             Service.resolve_blocker(repo, session.id, %{
               blocker_id: "scope-review",
               resolution: "Architect approved the broader file set",
               idempotency_key: "resolve-scope-review"
             })

    assert retried_resolved.id == resolved.id
    assert {:ok, entries_after_retry} = Service.list_entries(repo, session.id)
    assert Enum.count(entries_after_retry, &(&1.idempotency_key == "resolve-scope-review")) == 1

    assert {:error, :solo_blocker_not_open} =
             Service.resolve_blocker(repo, session.id, %{
               blocker_id: "scope-review",
               resolution: "Already resolved"
             })

    assert {:error, :solo_blocker_not_open} =
             Service.resolve_blocker(repo, session.id, %{
               blocker_id: "typo-scope-review",
               resolution: "Never existed"
             })

    assert {:ok, legacy_blocker} =
             Service.append_entry(repo, session.id, %{
               entry_kind: "blocker",
               title: "Legacy blocker row",
               status: "blocked"
             })

    assert {:ok, legacy_resolved} =
             Service.resolve_blocker(repo, session.id, %{
               blocker_id: legacy_blocker.id,
               resolution: "Resolved a legacy blocker by row id"
             })

    assert legacy_resolved.payload["blocker_id"] == legacy_blocker.id
    assert legacy_resolved.payload["blocker_status"] == "resolved"

    assert {:ok, decision} =
             Service.record_decision(repo, session.id, %{
               decision: "Keep Solo Session lifecycle soft",
               rationale: "Solo tracks progress, not merge readiness",
               scope_impact: "No WorkPackage readiness gates are added"
             })

    assert decision.entry_kind == "decision"
    assert decision.status == "recorded"
    assert decision.payload["decision"] == "Keep Solo Session lifecycle soft"
    assert decision.body =~ "Rationale: Solo tracks progress"
    assert decision.body =~ "Scope impact: No WorkPackage readiness gates"
  end

  test "entry validation rejects invalid kind and status without advancing activity", %{repo: repo} do
    assert {:ok, session} = Service.create_or_attach_current(repo, session_attrs())
    Process.sleep(5)

    assert {:error, %Changeset{} = kind_changeset} =
             Service.append_entry(repo, session.id, %{entry_kind: "claimed", title: "Bad kind"})

    assert "is invalid" in errors_on(kind_changeset).entry_kind

    assert {:error, %Changeset{} = status_changeset} =
             Service.append_entry(repo, session.id, %{entry_kind: "finding", title: "Bad status", status: "ready_for_merge"})

    assert "is invalid" in errors_on(status_changeset).status

    assert {:ok, after_failures} = Service.get(repo, session.id)
    assert after_failures.last_activity_at == session.last_activity_at
    assert {:ok, []} = Service.list_entries(repo, session.id)
  end

  test "completed and archived sessions reject new entries without advancing activity", %{repo: repo} do
    assert {:ok, completed} = session_in_status(repo, "completed", "completed-entry")
    Process.sleep(5)

    assert {:error, :session_not_mutable} =
             Service.append_entry(repo, completed.id, %{entry_kind: "progress", title: "Too late"})

    assert {:ok, completed_after_failure} = Service.get(repo, completed.id)
    assert completed_after_failure.last_activity_at == completed.last_activity_at

    assert {:ok, archived} = session_in_status(repo, "archived", "archived-entry")
    Process.sleep(5)

    assert {:error, :session_not_mutable} =
             Service.append_entry(repo, archived.id, %{entry_kind: "progress", title: "Too late"})

    assert {:ok, archived_after_failure} = Service.get(repo, archived.id)
    assert archived_after_failure.last_activity_at == archived.last_activity_at
  end

  test "idempotency keys replay per session and secret-like keys are rejected before persistence", %{repo: repo} do
    assert {:ok, first_session} =
             Service.create_or_attach_current(repo, session_attrs(workspace_path: workspace_path("idempotent-1")))

    assert {:ok, second_session} =
             Service.create_or_attach_current(repo, session_attrs(workspace_path: workspace_path("idempotent-2")))

    assert {:ok, first_entry} =
             Service.append_entry(repo, first_session.id, %{
               entry_kind: "decision",
               title: "Use entries",
               idempotency_key: "same-key"
             })

    Process.sleep(5)

    assert {:ok, replayed} =
             Service.append_entry(repo, first_session.id, %{
               entry_kind: "decision",
               title: "Changed on retry",
               idempotency_key: " same-key "
             })

    assert replayed.id == first_entry.id
    assert replayed.title == first_entry.title
    assert replayed.sequence == first_entry.sequence
    assert {:ok, [only_first_session_entry]} = Service.list_entries(repo, first_session.id)
    assert only_first_session_entry.id == first_entry.id

    assert {:ok, other_session_entry} =
             Service.append_entry(repo, second_session.id, %{
               entry_kind: "decision",
               title: "Same key elsewhere",
               idempotency_key: "same-key"
             })

    assert other_session_entry.id != first_entry.id
    assert other_session_entry.sequence == 1

    assert {:ok, before_secret_rejection} = Service.get(repo, first_session.id)
    Process.sleep(5)

    assert {:error, :invalid_entry_idempotency_key} =
             Service.append_entry(repo, first_session.id, %{
               entry_kind: "progress",
               title: "Reject secret key",
               idempotency_key: "wk_" <> String.duplicate("A", 43)
             })

    assert {:ok, after_secret_rejection} = Service.get(repo, first_session.id)
    assert after_secret_rejection.last_activity_at == before_secret_rejection.last_activity_at

    assert {:error, :invalid_entry_idempotency_key} =
             Service.append_entry(repo, first_session.id, %{
               entry_kind: "progress",
               title: "Reject non-string key",
               idempotency_key: 123
             })

    assert {:ok, after_non_string_rejection} = Service.get(repo, first_session.id)
    assert after_non_string_rejection.last_activity_at == before_secret_rejection.last_activity_at
  end

  test "idempotent replays survive completed and archived session transitions", %{repo: repo} do
    assert {:ok, session} =
             Service.create_or_attach_current(
               repo,
               session_attrs(workspace_path: workspace_path("idempotent-lifecycle"))
             )

    assert {:ok, entry} =
             Service.append_entry(repo, session.id, %{
               entry_kind: "validation_note",
               title: "Validated once",
               idempotency_key: "lifecycle-entry-key"
             })

    assert {:ok, completed} = Service.complete(repo, session.id, "active")
    Process.sleep(5)

    assert {:ok, completed_replay} =
             Service.append_entry(repo, session.id, %{
               entry_kind: "validation_note",
               title: "Retry after complete",
               idempotency_key: "lifecycle-entry-key"
             })

    assert completed_replay.id == entry.id
    assert {:ok, completed_after_replay} = Service.get(repo, session.id)
    assert completed_after_replay.last_activity_at == completed.last_activity_at

    Process.delete(:sympp_solo_stale_entry_idempotency_read)
    Process.sleep(5)

    assert {:ok, stale_completed_replay} =
             Service.append_entry(StaleEntryIdempotencyReadRepo, session.id, %{
               entry_kind: "validation_note",
               title: "Stale retry after complete",
               idempotency_key: "lifecycle-entry-key"
             })

    assert stale_completed_replay.id == entry.id
    assert {:ok, completed_after_stale_replay} = Service.get(repo, session.id)
    assert completed_after_stale_replay.last_activity_at == completed.last_activity_at

    assert {:ok, archived} = Service.archive(repo, session.id, "completed")
    Process.delete(:sympp_solo_stale_entry_idempotency_read)
    Process.sleep(5)

    assert {:ok, archived_replay} =
             Service.append_entry(StaleEntryIdempotencyReadRepo, session.id, %{
               entry_kind: "validation_note",
               title: "Stale retry after archive",
               idempotency_key: "lifecycle-entry-key"
             })

    assert archived_replay.id == entry.id
    assert {:ok, archived_after_replay} = Service.get(repo, session.id)
    assert archived_after_replay.last_activity_at == archived.last_activity_at
    assert {:ok, [only_entry]} = Service.list_entries(repo, session.id)
    assert only_entry.id == entry.id
  end

  test "idempotent append conflict replays from a fresh read path", %{repo: repo} do
    assert {:ok, session} = Service.create_or_attach_current(repo, session_attrs(workspace_path: workspace_path("entry-conflict")))

    assert {:ok, existing} =
             Service.append_entry(repo, session.id, %{
               entry_kind: "finding",
               title: "Already persisted",
               idempotency_key: "entry-conflict-key"
             })

    assert {:ok, replayed} =
             Service.append_entry(StaleEntryIdempotencyReadRepo, session.id, %{
               entry_kind: "finding",
               title: "Retry after stale read",
               idempotency_key: "entry-conflict-key"
             })

    assert replayed.id == existing.id
    assert {:ok, [only_entry]} = Service.list_entries(repo, session.id)
    assert only_entry.id == existing.id
  end

  test "entry reads and lists are scoped and do not advance activity", %{repo: repo} do
    assert {:ok, first_session} =
             Service.create_or_attach_current(repo, session_attrs(workspace_path: workspace_path("read-1")))

    assert {:ok, second_session} =
             Service.create_or_attach_current(repo, session_attrs(workspace_path: workspace_path("read-2")))

    assert {:ok, first_entry} =
             Service.append_entry(repo, first_session.id, %{entry_kind: "progress", title: "First session"})

    assert {:ok, second_entry} =
             Service.append_entry(repo, second_session.id, %{entry_kind: "progress", title: "Second session"})

    assert {:ok, first_after_append} = Service.get(repo, first_session.id)
    Process.sleep(5)

    assert {:ok, [listed]} = Service.list_entries(repo, first_session.id)
    assert listed.id == first_entry.id
    assert {:ok, ^first_entry} = Service.get_entry(repo, first_session.id, first_entry.id)
    assert {:error, :not_found} = Service.get_entry(repo, first_session.id, second_entry.id)

    assert {:ok, first_after_reads} = Service.get(repo, first_session.id)
    assert first_after_reads.last_activity_at == first_after_append.last_activity_at
  end

  test "concurrent appends allocate unique monotonically increasing sequences", %{repo: repo} do
    assert {:ok, session} = Service.create_or_attach_current(repo, session_attrs(workspace_path: workspace_path("concurrent-entries")))

    results =
      1..20
      |> Task.async_stream(
        fn index ->
          Service.append_entry(repo, session.id, %{
            entry_kind: "progress",
            title: "Concurrent #{index}",
            idempotency_key: "concurrent-entry-#{index}"
          })
        end,
        max_concurrency: 20,
        timeout: 15_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn
             {:ok, {:ok, %SoloSessionEntry{}}} -> true
             _result -> false
           end)

    assert {:ok, entries} = Service.list_entries(repo, session.id)
    assert Enum.map(entries, & &1.sequence) == Enum.to_list(1..20)
    assert entries |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 20
  end

  test "create attach and list filters trim and canonicalize lookup fields", %{repo: repo} do
    workspace_path = workspace_path("trimmed-filters")
    dotted_workspace = Path.join(workspace_path, ".")

    assert {:ok, session} =
             Service.create_or_attach_current(repo, %{
               repo: " nextide/example ",
               base_branch: " main ",
               workspace_path: " #{dotted_workspace} ",
               caller_id: " codex-local ",
               title: " Trimmed title "
             })

    assert session.repo == "nextide/example"
    assert session.base_branch == "main"
    assert session.caller_id == "codex-local"
    assert session.title == "Trimmed title"

    assert {:ok, [listed]} =
             Service.list(repo, %{
               repo: " nextide/example ",
               base_branch: " main ",
               workspace_path: " #{workspace_path} ",
               caller_id: " codex-local ",
               status: " active "
             })

    assert listed.id == session.id

    Process.sleep(5)

    assert {:ok, attached} =
             Service.create_or_attach_current(repo, %{
               repo: "nextide/example",
               base_branch: "main",
               workspace_path: workspace_path,
               caller_id: "codex-local"
             })

    assert attached.id == session.id
    assert DateTime.compare(attached.last_activity_at, session.last_activity_at) == :gt
  end

  test "relative workspace paths are rejected instead of using service cwd", %{repo: repo} do
    assert {:error, :invalid_workspace_path} =
             Service.create_or_attach_current(repo, session_attrs(workspace_path: "."))

    assert {:error, :invalid_workspace_path} = Service.list(repo, %{workspace_path: Path.join("relative", "workspace")})
    assert {:ok, []} = Service.list(repo)
  end

  test "concurrent first attaches converge on one active session", %{repo: repo} do
    attrs = session_attrs(workspace_path: workspace_path("concurrent"))

    results =
      1..20
      |> Task.async_stream(fn _index -> Service.create_or_attach_current(repo, attrs) end,
        max_concurrency: 20,
        timeout: 15_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn
             {:ok, {:ok, %SoloSession{}}} -> true
             _result -> false
           end)

    sessions = Enum.map(results, fn {:ok, {:ok, session}} -> session end)
    assert sessions |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1

    assert {:ok, [current]} =
             Service.list(repo, %{
               repo: attrs.repo,
               base_branch: attrs.base_branch,
               workspace_path: attrs.workspace_path,
               caller_id: attrs.caller_id,
               status: "active"
             })

    assert current.id == hd(sessions).id
  end

  test "insert conflicts replay by reading the current session in a fresh transaction", %{repo: repo} do
    attrs = session_attrs(workspace_path: workspace_path("insert-conflict"))
    assert {:ok, existing} = Service.create_or_attach_current(repo, attrs)
    Process.sleep(5)

    assert {:ok, attached} = Service.create_or_attach_current(StaleCurrentReadRepo, attrs)

    assert attached.id == existing.id
    assert DateTime.compare(attached.last_activity_at, existing.last_activity_at) == :gt
  end

  test "database busy during create attach is retried", %{repo: repo} do
    attrs = session_attrs(workspace_path: workspace_path("busy-retry"))

    assert {:ok, session} = Service.create_or_attach_current(BusyOnceRepo, attrs)
    assert {:ok, [listed]} = Service.list(repo, %{workspace_path: attrs.workspace_path})
    assert listed.id == session.id
  end

  test "migration is idempotent and limited to sessions plus entries", %{repo: repo} do
    assert :ok = Repository.migrate(repo)

    %{rows: rows} = SQL.query!(repo, "PRAGMA table_info(sympp_solo_sessions)")
    assert [_cid, "id", _type, _not_null, _default, 1] = Enum.find(rows, &(Enum.at(&1, 1) == "id"))
    assert Enum.any?(rows, &(Enum.at(&1, 1) == "workspace_path"))

    %{rows: entry_rows} = SQL.query!(repo, "PRAGMA table_info(sympp_solo_session_entries)")
    assert [_cid, "id", _type, _not_null, _default, 1] = Enum.find(entry_rows, &(Enum.at(&1, 1) == "id"))
    assert Enum.any?(entry_rows, &(Enum.at(&1, 1) == "solo_session_id"))
    assert Enum.any?(entry_rows, &(Enum.at(&1, 1) == "idempotency_key"))

    %{rows: entry_indexes} = SQL.query!(repo, "PRAGMA index_list(sympp_solo_session_entries)")
    entry_index_names = Enum.map(entry_indexes, &Enum.at(&1, 1))
    assert "sympp_solo_session_entries_session_sequence_unique_index" in entry_index_names
    assert "sympp_solo_session_entries_session_idempotency_key_unique_index" in entry_index_names

    refute table_exists?(repo, "sympp_work_packages")
    refute table_exists?(repo, "sympp_work_requests")
    refute table_exists?(repo, "sympp_access_grants")
  end

  defp session_in_status(repo, "active", caller_id) do
    attrs = session_attrs(caller_id: caller_id, workspace_path: workspace_path(caller_id))
    Service.create_or_attach_current(repo, attrs)
  end

  defp session_in_status(repo, "paused", caller_id) do
    with {:ok, session} <- session_in_status(repo, "active", caller_id) do
      Service.pause(repo, session.id, "active")
    end
  end

  defp session_in_status(repo, "completed", caller_id) do
    with {:ok, session} <- session_in_status(repo, "active", caller_id) do
      Service.complete(repo, session.id, "active")
    end
  end

  defp session_in_status(repo, "archived", caller_id) do
    with {:ok, session} <- session_in_status(repo, "active", caller_id) do
      Service.archive(repo, session.id, "active")
    end
  end

  defp set_last_activity!(repo, %SoloSession{} = session, timestamp) do
    session
    |> Changeset.change(last_activity_at: timestamp, updated_at: timestamp)
    |> repo.update!()
  end

  defp set_archived_at!(repo, %SoloSession{} = session, timestamp) do
    session
    |> Changeset.change(archived_at: timestamp, updated_at: timestamp)
    |> repo.update!()
  end

  defp session_attrs(overrides \\ []) do
    defaults = %{
      repo: "nextide/example",
      base_branch: "main",
      workspace_path: workspace_path("default"),
      caller_id: "codex-local",
      title: "Local planning"
    }

    Enum.into(overrides, defaults)
  end

  defp workspace_path(name) do
    path = Path.join(System.tmp_dir!(), "sympp-solo-session-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", inspect(value))
      end)
    end)
  end

  defp table_exists?(repo, table_name) do
    %{rows: rows} =
      SQL.query!(repo, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [table_name])

    rows != []
  end
end
