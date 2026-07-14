defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestPlannedSliceDeliveriesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  defmodule UniqueConflictRepo do
    alias Ecto.Changeset

    def transaction(fun) do
      {:ok, fun.()}
    catch
      {:rollback, reason} -> {:error, reason}
    end

    def exists?(_query), do: true

    def one(_query) do
      if Process.get(:delivery_unique_conflict_insert_attempted) do
        Process.get(:delivery_unique_conflict_existing)
      end
    end

    def insert(%Changeset{} = changeset) do
      Process.put(:delivery_unique_conflict_insert_attempted, true)

      {:error,
       Changeset.add_error(changeset, :planned_slice_id, "has already been taken",
         constraint: :unique,
         constraint_name: "sympp_work_request_planned_slice_deliveries_planned_slice_id_unique_index"
       )}
    end

    def rollback(reason), do: throw({:rollback, reason})
  end

  setup_all do
    database_path = database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(PlannedSliceDelivery)
    repo.delete_all(PlannedSlice)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "records PR merged delivery outcomes and accepts exact replay", %{repo: repo} do
    work_request = create_work_request!(repo)
    planned_slice = create_planned_slice!(repo, work_request, id: "WRS-DELIVERY-PR")

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-pr-merged",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/123",
        pr_number: 123,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 12:00:00.000000Z],
        merge_commit_sha: "abc123"
      })

    assert {:ok, delivery} = Service.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)
    assert delivery.outcome == "pr_merged"
    assert delivery.idempotency_key == "delivery-pr-merged"
    assert delivery.pr_url == "https://github.com/nextide/symphony-plus-plus/pull/123"
    assert delivery.pr_merged_at == ~U[2026-05-24 12:00:00.000000Z]

    assert {:ok, replay} = Repository.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)
    assert replay.id == delivery.id
    assert replay.inserted_at == delivery.inserted_at

    assert repo.get(PlannedSliceDelivery, delivery.id).planned_slice_id == planned_slice.id
    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 1

    assert {:ok, unchanged_slice} = Repository.get_planned_slice(repo, work_request.id, planned_slice.id)
    assert unchanged_slice.status == "planned"
    assert PlannedSlice.statuses() == ["planned", "approved", "dispatched", "skipped"]
  end

  test "rejects conflicting replay for an authoritative planned slice outcome", %{repo: repo} do
    work_request = create_work_request!(repo)
    planned_slice = create_planned_slice!(repo, work_request, id: "WRS-DELIVERY-CONFLICT")

    attrs =
      delivery_attrs(%{
        outcome: "completed_no_pr",
        idempotency_key: "delivery-no-pr",
        no_pr_evidence: "Operator confirmed the docs-only package was applied directly."
      })

    assert {:ok, delivery} = Repository.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)

    conflicting_attrs = Map.put(attrs, :no_pr_evidence, "Different no-PR evidence.")

    assert {:error, :delivery_outcome_conflict} =
             Service.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, conflicting_attrs)

    fetched = repo.get!(PlannedSliceDelivery, delivery.id)
    assert fetched.id == delivery.id
    assert fetched.no_pr_evidence == "Operator confirmed the docs-only package was applied directly."
  end

  test "accepts exact replay after a concurrent unique conflict" do
    existing = %PlannedSliceDelivery{
      work_request_id: "WR-RACE",
      planned_slice_id: "WRS-RACE",
      outcome: "completed_no_pr",
      idempotency_key: "delivery-race",
      recorded_by: "delivery-worker",
      no_pr_evidence: "Same no-PR evidence."
    }

    Process.put(:delivery_unique_conflict_existing, existing)
    Process.delete(:delivery_unique_conflict_insert_attempted)

    try do
      assert {:ok, ^existing} =
               Repository.record_planned_slice_delivery(
                 UniqueConflictRepo,
                 "WR-RACE",
                 "WRS-RACE",
                 delivery_attrs(%{
                   outcome: "completed_no_pr",
                   idempotency_key: "delivery-race",
                   no_pr_evidence: "Same no-PR evidence."
                 })
               )
    after
      Process.delete(:delivery_unique_conflict_existing)
      Process.delete(:delivery_unique_conflict_insert_attempted)
    end
  end

  test "validates outcome-specific evidence", %{repo: repo} do
    work_request = create_work_request!(repo)
    planned_slice = create_planned_slice!(repo, work_request, id: "WRS-DELIVERY-VALIDATION")

    assert {:error, %Ecto.Changeset{} = pr_changeset} =
             Repository.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, delivery_attrs(%{outcome: "pr_merged"}))

    assert "can't be blank" in errors_on(pr_changeset).pr_url
    assert "can't be blank" in errors_on(pr_changeset).pr_merged_at

    assert {:error, %Ecto.Changeset{} = no_pr_changeset} =
             Repository.record_planned_slice_delivery(
               repo,
               work_request.id,
               planned_slice.id,
               delivery_attrs(%{outcome: "completed_no_pr"})
             )

    assert "can't be blank" in errors_on(no_pr_changeset).no_pr_evidence

    assert {:error, %Ecto.Changeset{} = superseded_changeset} =
             Repository.record_planned_slice_delivery(
               repo,
               work_request.id,
               planned_slice.id,
               delivery_attrs(%{outcome: "superseded"})
             )

    assert "can't be blank" in errors_on(superseded_changeset).successor_planned_slice_id
    assert "can't be blank" in errors_on(superseded_changeset).superseded_reason

    assert {:error, %Ecto.Changeset{} = abandoned_changeset} =
             Repository.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, delivery_attrs(%{outcome: "abandoned"}))

    assert "can't be blank" in errors_on(abandoned_changeset).abandoned_rationale

    assert {:error, %Ecto.Changeset{} = outcome_changeset} =
             Repository.record_planned_slice_delivery(
               repo,
               work_request.id,
               planned_slice.id,
               delivery_attrs(%{outcome: "finished"})
             )

    assert "is invalid" in errors_on(outcome_changeset).outcome
  end

  test "records superseded and abandoned outcomes with successor metadata", %{repo: repo} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")
    superseded_slice = create_planned_slice!(repo, work_request, id: "WRS-DELIVERY-SUPERSEDED")
    successor_slice = create_planned_slice!(repo, work_request, id: "WRS-DELIVERY-SUCCESSOR")
    abandoned_slice = create_planned_slice!(repo, work_request, id: "WRS-DELIVERY-ABANDONED")

    assert {:ok, approved_successor} = Repository.approve_planned_slice(repo, work_request.id, successor_slice.id, "planned")
    successor_package = create_matching_work_package!(repo, work_request, approved_successor, id: "SYMPP-DELIVERY-SUCCESSOR")
    assert {:ok, dispatched_successor} = Repository.dispatch_planned_slice(repo, work_request.id, approved_successor.id, "approved", successor_package.id)

    assert {:ok, superseded} =
             Repository.record_planned_slice_delivery(
               repo,
               work_request.id,
               superseded_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 idempotency_key: "delivery-superseded",
                 successor_planned_slice_id: dispatched_successor.id,
                 successor_work_package_id: successor_package.id,
                 superseded_reason: "Recut with narrower owned files."
               })
             )

    assert superseded.successor_planned_slice_id == successor_slice.id
    assert superseded.successor_work_package_id == successor_package.id
    assert superseded.superseded_reason == "Recut with narrower owned files."

    assert {:ok, abandoned} =
             Service.record_planned_slice_delivery(
               repo,
               work_request.id,
               abandoned_slice.id,
               delivery_attrs(%{
                 outcome: "abandoned",
                 idempotency_key: "delivery-abandoned",
                 abandoned_rationale: "Package was no longer needed after architecture decision."
               })
             )

    assert abandoned.abandoned_rationale == "Package was no longer needed after architecture decision."

    assert {:ok, persisted_slices} = Service.list_planned_slices(repo, work_request.id)
    assert Enum.map(persisted_slices, & &1.status) == ["planned", "dispatched", "planned"]
  end

  test "delivery outcomes are scoped to their planned slice WorkRequest", %{repo: repo} do
    work_request = create_work_request!(repo)
    sibling_request = create_work_request!(repo, id: "WR-DELIVERY-SIBLING")
    planned_slice = create_planned_slice!(repo, work_request, id: "WRS-DELIVERY-SCOPED")

    assert {:error, :not_found} =
             Repository.record_planned_slice_delivery(
               repo,
               sibling_request.id,
               planned_slice.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 no_pr_evidence: "Wrong WorkRequest must not claim this slice."
               })
             )

    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0

    successor_slice = create_planned_slice!(repo, sibling_request, id: "WRS-DELIVERY-CROSS-SUCCESSOR")

    assert {:error, :not_found} =
             Repository.record_planned_slice_delivery(
               repo,
               work_request.id,
               planned_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 successor_planned_slice_id: successor_slice.id,
                 superseded_reason: "Wrong WorkRequest successor must not be linked."
               })
             )

    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
  end

  test "superseded delivery rejects successor packages outside the declared successor slice", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DELIVERY-SUCCESSOR-PACKAGE-SCOPE", status: "ready_for_slicing")
    planned_slice = create_planned_slice!(repo, work_request, id: "WRS-DELIVERY-SUCCESSOR-PACKAGE-SCOPED")

    successor_slice = create_dispatched_successor_slice!(repo, work_request, "SUCCESSOR")
    other_successor_slice = create_dispatched_successor_slice!(repo, work_request, "OTHER-SUCCESSOR")

    assert {:error, :not_found} =
             Repository.record_planned_slice_delivery(
               repo,
               work_request.id,
               planned_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 successor_planned_slice_id: successor_slice.id,
                 successor_work_package_id: other_successor_slice.work_package_id,
                 superseded_reason: "Wrong same-request package must not be linked."
               })
             )

    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
  end

  test "migration creates delivery fields and indexes", %{repo: repo} do
    assert :ok = Repository.migrate(repo)

    assert_primary_key(repo, "sympp_work_request_planned_slice_deliveries")

    columns = column_names(repo, "sympp_work_request_planned_slice_deliveries")

    for column <- [
          "work_request_id",
          "planned_slice_id",
          "outcome",
          "idempotency_key",
          "recorded_by",
          "recorded_at",
          "pr_url",
          "pr_number",
          "pr_repository",
          "pr_merged_at",
          "merge_commit_sha",
          "no_pr_evidence",
          "successor_planned_slice_id",
          "successor_work_package_id",
          "superseded_reason",
          "abandoned_rationale",
          "inserted_at",
          "updated_at"
        ] do
      assert column in columns
    end

    indexes = index_names(repo, "sympp_work_request_planned_slice_deliveries")

    assert "sympp_work_request_planned_slice_deliveries_id_unique_index" in indexes
    assert "sympp_work_request_planned_slice_deliveries_planned_slice_id_unique_index" in indexes
  end

  defp create_work_request!(repo, overrides \\ []) do
    assert {:ok, work_request} = Repository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_planned_slice!(repo, work_request, overrides) do
    assert {:ok, planned_slice} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(overrides))
    planned_slice
  end

  defp create_matching_work_package!(repo, work_request, planned_slice, overrides) do
    attrs =
      [
        kind: planned_slice.work_package_kind,
        title: planned_slice.title,
        repo: work_request.repo,
        base_branch: planned_slice.target_base_branch,
        branch_pattern: planned_slice.branch_pattern,
        product_description: work_request.human_description,
        allowed_file_globs: planned_slice.owned_file_globs,
        acceptance_criteria: planned_slice.acceptance_criteria
      ]
      |> Keyword.merge(overrides)
      |> WorkPackageFactory.attrs()

    assert {:ok, work_package} = WorkPackageRepository.create(repo, attrs)
    work_package
  end

  defp create_dispatched_successor_slice!(repo, work_request, suffix) do
    successor_slice = create_planned_slice!(repo, work_request, id: "WRS-DELIVERY-#{suffix}")
    assert {:ok, approved_successor} = Repository.approve_planned_slice(repo, work_request.id, successor_slice.id, "planned")
    successor_package = create_matching_work_package!(repo, work_request, approved_successor, id: "SYMPP-DELIVERY-#{suffix}")
    assert {:ok, dispatched_successor} = Repository.dispatch_planned_slice(repo, work_request.id, approved_successor.id, "approved", successor_package.id)
    dispatched_successor
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-#{System.unique_integer([:positive])}",
      title: "Improve planned-slice delivery",
      repo: "nextide/example",
      base_branch: "main",
      work_type: "feature",
      human_description: "Record planned-slice delivery truth.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "architect_led_feature_branch"
    }

    Enum.into(overrides, defaults)
  end

  defp planned_slice_attrs(overrides) do
    defaults = %{
      title: "Add planned-slice delivery storage",
      goal: "Persist one authoritative delivery outcome for the planned slice.",
      work_package_kind: "mcp",
      target_base_branch: "main",
      branch_pattern: "feat/del-01-planned-slice-delivery-schema",
      owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/*.ex"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Delivery outcome persists independently of raw planned-slice status."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/work_request_planned_slice_deliveries_test.exs"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: ["Do not add terminal planned-slice statuses."]
    }

    Enum.into(overrides, defaults)
  end

  defp delivery_attrs(overrides) do
    defaults = %{
      idempotency_key: "delivery-#{System.unique_integer([:positive])}",
      recorded_by: "delivery-worker"
    }

    Enum.into(overrides, defaults)
  end

  defp assert_primary_key(repo, table) do
    %{rows: table_rows} = SQL.query!(repo, "PRAGMA table_info(#{table})")
    assert [_cid, "id", _type, _not_null, _default, 1] = Enum.find(table_rows, &(Enum.at(&1, 1) == "id"))
  end

  defp column_names(repo, table) do
    %{rows: table_rows} = SQL.query!(repo, "PRAGMA table_info(#{table})")
    Enum.map(table_rows, &Enum.at(&1, 1))
  end

  defp index_names(repo, table) do
    %{rows: index_rows} = SQL.query!(repo, "PRAGMA index_list(#{table})")
    Enum.map(index_rows, &Enum.at(&1, 1))
  end

  defp database_path do
    Path.join(
      System.tmp_dir!(),
      "sympp-work-request-planned-slice-deliveries-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3"
    )
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", inspect(value))
      end)
    end)
  end
end
