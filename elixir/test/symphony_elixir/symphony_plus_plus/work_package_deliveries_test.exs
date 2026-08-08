defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestWorkPackageDeliveriesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  defmodule UniqueConflictRepo do
    alias Ecto.Changeset

    def transaction(fun) do
      {:ok, fun.()}
    catch
      {:rollback, reason} -> {:error, reason}
    end

    def exists?(_query), do: true
    def all(_query), do: []
    def update_all(_query, _updates), do: {0, nil}

    def get(WorkPackage, "WRS-RACE") do
      %WorkPackage{id: "WRS-RACE", work_request_id: "WR-RACE", status: "closed"}
    end

    def one(_query) do
      if Process.get(:delivery_unique_conflict_insert_attempted) do
        Process.get(:delivery_unique_conflict_existing)
      end
    end

    def insert(%Changeset{} = changeset) do
      Process.put(:delivery_unique_conflict_insert_attempted, true)

      {:error,
       Changeset.add_error(changeset, :work_package_id, "has already been taken",
         constraint: :unique,
         constraint_name: "sympp_work_request_work_package_deliveries_work_package_id_unique_index"
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
    repo.delete_all(WorkPackageDelivery)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "records PR merged delivery outcomes and accepts exact replay", %{repo: repo} do
    work_request = create_work_request!(repo)
    work_package = create_work_package!(repo, work_request, id: "WRS-DELIVERY-PR")

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

    assert {:ok, delivery} = Service.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert delivery.outcome == "pr_merged"
    assert delivery.idempotency_key == "delivery-pr-merged"
    assert delivery.pr_url == "https://github.com/nextide/symphony-plus-plus/pull/123"
    assert delivery.pr_merged_at == ~U[2026-05-24 12:00:00.000000Z]

    assert {:ok, replay} = Repository.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)
    assert replay.id == delivery.id
    assert replay.inserted_at == delivery.inserted_at

    assert repo.get(WorkPackageDelivery, delivery.id).work_package_id == work_package.id
    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1

    assert {:ok, delivered_package} = Repository.get_work_package(repo, work_request.id, work_package.id)
    assert delivered_package.status == "merged"
    assert "merged" in WorkPackage.statuses()
  end

  test "rejects conflicting replay for an authoritative WorkPackage outcome", %{repo: repo} do
    work_request = create_work_request!(repo)
    work_package = create_work_package!(repo, work_request, id: "WRS-DELIVERY-CONFLICT")

    attrs =
      delivery_attrs(%{
        outcome: "completed_no_pr",
        idempotency_key: "delivery-no-pr",
        no_pr_evidence: "Operator confirmed the docs-only package was applied directly."
      })

    assert {:ok, delivery} = Repository.record_work_package_delivery(repo, work_request.id, work_package.id, attrs)

    conflicting_attrs = Map.put(attrs, :no_pr_evidence, "Different no-PR evidence.")

    assert {:error, :delivery_outcome_conflict} =
             Service.record_work_package_delivery(repo, work_request.id, work_package.id, conflicting_attrs)

    fetched = repo.get!(WorkPackageDelivery, delivery.id)
    assert fetched.id == delivery.id
    assert fetched.no_pr_evidence == "Operator confirmed the docs-only package was applied directly."
  end

  test "accepts exact replay after a concurrent unique conflict" do
    existing = %WorkPackageDelivery{
      work_request_id: "WR-RACE",
      work_package_id: "WRS-RACE",
      outcome: "completed_no_pr",
      idempotency_key: "delivery-race",
      recorded_by: "delivery-worker",
      no_pr_evidence: "Same no-PR evidence."
    }

    Process.put(:delivery_unique_conflict_existing, existing)
    Process.delete(:delivery_unique_conflict_insert_attempted)

    try do
      assert {:ok, ^existing} =
               Repository.record_work_package_delivery(
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
    work_package = create_work_package!(repo, work_request, id: "WRS-DELIVERY-VALIDATION")

    assert {:error, %Ecto.Changeset{} = pr_changeset} =
             Repository.record_work_package_delivery(repo, work_request.id, work_package.id, delivery_attrs(%{outcome: "pr_merged"}))

    assert "can't be blank" in errors_on(pr_changeset).pr_url
    assert "can't be blank" in errors_on(pr_changeset).pr_merged_at
    assert "can't be blank" in errors_on(pr_changeset).merge_commit_sha

    assert {:error,
            %{
              "missing_fields" => ["pr_merged_at", "merge_commit_sha"],
              "unexpected_fields" => ["no_pr_evidence"],
              "allowed_fields" => [
                "pr_url",
                "pr_number",
                "pr_repository",
                "pr_merged_at",
                "merge_commit_sha"
              ]
            }} =
             WorkPackageDelivery.validate_evidence("pr_merged", %{
               "pr_url" => "https://github.com/nextide/symphony-plus-plus/pull/123",
               "no_pr_evidence" => "Wrong outcome evidence."
             })

    assert {:error,
            %{
              "missing_fields" => [],
              "unexpected_fields" => ["no_pr_evidence"]
            }} =
             WorkPackageDelivery.validate_evidence("pr_merged", %{
               "pr_url" => "https://github.com/nextide/symphony-plus-plus/pull/123",
               "pr_merged_at" => "2026-08-03T02:00:00Z",
               "merge_commit_sha" => "abc123",
               "no_pr_evidence" => "   "
             })

    assert {:error, %Ecto.Changeset{} = no_pr_changeset} =
             Repository.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               delivery_attrs(%{outcome: "completed_no_pr"})
             )

    assert "can't be blank" in errors_on(no_pr_changeset).no_pr_evidence

    assert {:error, %Ecto.Changeset{} = unexpected_no_pr_changeset} =
             Repository.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 no_pr_evidence: "Direct completion.",
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/123"
               })
             )

    assert "is not allowed for outcome" in errors_on(unexpected_no_pr_changeset).pr_url

    assert {:error, %Ecto.Changeset{} = superseded_changeset} =
             Repository.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               delivery_attrs(%{outcome: "superseded"})
             )

    assert "can't be blank" in errors_on(superseded_changeset).successor_work_package_id
    assert "can't be blank" in errors_on(superseded_changeset).superseded_reason

    assert {:error, %Ecto.Changeset{} = abandoned_changeset} =
             Repository.record_work_package_delivery(repo, work_request.id, work_package.id, delivery_attrs(%{outcome: "abandoned"}))

    assert "can't be blank" in errors_on(abandoned_changeset).abandoned_rationale

    assert {:error, %Ecto.Changeset{} = outcome_changeset} =
             Repository.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               delivery_attrs(%{outcome: "finished"})
             )

    assert "is invalid" in errors_on(outcome_changeset).outcome
  end

  test "records superseded and abandoned outcomes with successor metadata", %{repo: repo} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")
    superseded_slice = create_work_package!(repo, work_request, id: "WRS-DELIVERY-SUPERSEDED")
    successor_slice = create_work_package!(repo, work_request, id: "WRS-DELIVERY-SUCCESSOR")
    abandoned_slice = create_work_package!(repo, work_request, id: "WRS-DELIVERY-ABANDONED")

    successor_package = dispatch_work_package!(repo, successor_slice)
    abandoned_slice = repo.update!(Ecto.Changeset.change(abandoned_slice, status: "ready_for_worker"))

    assert {:ok, superseded} =
             Repository.record_work_package_delivery(
               repo,
               work_request.id,
               superseded_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 idempotency_key: "delivery-superseded",
                 successor_work_package_id: successor_package.id,
                 superseded_reason: "Recut with narrower owned files."
               })
             )

    assert superseded.successor_work_package_id == successor_package.id
    assert superseded.superseded_reason == "Recut with narrower owned files."

    assert {:ok, abandoned} =
             Service.record_work_package_delivery(
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

    assert {:ok, persisted_packages} = Service.list_work_packages(repo, work_request.id)
    assert Enum.map(persisted_packages, & &1.status) == ["planned", "ready_for_worker", "abandoned"]
  end

  test "delivery outcomes are scoped to their WorkPackage WorkRequest", %{repo: repo} do
    work_request = create_work_request!(repo)
    sibling_request = create_work_request!(repo, id: "WR-DELIVERY-SIBLING")
    work_package = create_work_package!(repo, work_request, id: "WRS-DELIVERY-SCOPED")

    assert {:error, :not_found} =
             Repository.record_work_package_delivery(
               repo,
               sibling_request.id,
               work_package.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 no_pr_evidence: "Wrong WorkRequest must not claim this slice."
               })
             )

    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0

    successor_slice = create_work_package!(repo, sibling_request, id: "WRS-DELIVERY-CROSS-SUCCESSOR")

    assert {:error, :not_found} =
             Repository.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 successor_work_package_id: successor_slice.id,
                 superseded_reason: "Wrong WorkRequest successor must not be linked."
               })
             )

    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
  end

  test "superseded delivery rejects successor packages from another WorkRequest", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DELIVERY-SUCCESSOR-PACKAGE-SCOPE", status: "ready_for_slicing")
    work_package = create_work_package!(repo, work_request, id: "WRS-DELIVERY-SUCCESSOR-PACKAGE-SCOPED")

    other_request = create_work_request!(repo, id: "WR-DELIVERY-OTHER-SUCCESSOR", status: "ready_for_slicing")
    other_successor = create_dispatched_successor_slice!(repo, other_request, "OTHER-SUCCESSOR")

    assert {:error, :not_found} =
             Repository.record_work_package_delivery(
               repo,
               work_request.id,
               work_package.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 successor_work_package_id: other_successor.id,
                 superseded_reason: "A successor must belong to the same WorkRequest."
               })
             )

    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 0
  end

  test "migration creates delivery fields and indexes", %{repo: repo} do
    assert :ok = Repository.migrate(repo)

    assert_primary_key(repo, "sympp_work_package_deliveries")

    columns = column_names(repo, "sympp_work_package_deliveries")

    for column <- [
          "work_request_id",
          "work_package_id",
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
          "successor_work_package_id",
          "superseded_reason",
          "abandoned_rationale",
          "inserted_at",
          "updated_at"
        ] do
      assert column in columns
    end

    indexes = index_names(repo, "sympp_work_package_deliveries")

    assert "sympp_work_package_deliveries_id_unique_index" in indexes
    assert "sympp_work_package_deliveries_package_unique_index" in indexes
  end

  defp create_work_request!(repo, overrides \\ []) do
    assert {:ok, work_request} = Repository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_work_package!(repo, work_request, overrides) do
    assert {:ok, work_package} = CanonicalWorkPackageFixtures.add_work_package(repo, work_request.id, work_package_attrs(overrides))
    work_package
  end

  defp create_dispatched_successor_slice!(repo, work_request, suffix) do
    work_request
    |> then(&create_work_package!(repo, &1, id: "SYMPP-DELIVERY-#{suffix}"))
    |> then(&dispatch_work_package!(repo, &1))
  end

  defp dispatch_work_package!(repo, work_package) do
    repo.update!(
      Ecto.Changeset.change(work_package,
        status: "ready_for_worker",
        dispatched_at: DateTime.utc_now(:microsecond)
      )
    )
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-#{System.unique_integer([:positive])}",
      title: "Improve work-package delivery",
      repo: "nextide/example",
      base_branch: "main",
      work_type: "feature",
      human_description: "Record work-package delivery truth.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "architect_led_feature_branch"
    }

    Enum.into(overrides, defaults)
  end

  defp work_package_attrs(overrides) do
    defaults = %{
      title: "Add work-package delivery storage",
      goal: "Persist one authoritative delivery outcome for the WorkPackage.",
      kind: "mcp",
      base_branch: "main",
      branch_pattern: "feat/del-01-work-package-delivery-schema",
      allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/*.ex"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Delivery outcome persists independently of raw work-package status."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/work_request_work_package_deliveries_test.exs"],
      review_requirement: %{"type" => "review-suite", "args" => %{"mode" => "normal"}},
      stop_conditions: ["Do not add terminal work-package statuses."]
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
      "sympp-work-request-work-package-deliveries-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3"
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
