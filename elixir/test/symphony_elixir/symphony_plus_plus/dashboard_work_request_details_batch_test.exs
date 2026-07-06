defmodule SymphonyElixir.SymphonyPlusPlus.DashboardWorkRequestDetailsBatchTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Service, as: CommentService
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.SymppDashboardApiController

  @endpoint SymphonyElixirWeb.Endpoint

  setup_all do
    database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = WorkPackageRepository.migrate(Repo)
    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)
    start_test_endpoint()

    on_exit(fn ->
      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end

      File.rm(database_path)
    end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(PlannedSliceDelivery)
    repo.delete_all(PlannedSlice)
    repo.delete_all(DecisionLogEntry)
    repo.delete_all(ClarificationQuestion)
    repo.delete_all(Comment)
    repo.delete_all(WorkRequest)
    repo.delete_all(WorkPackage)
    repo.delete_all(OperatorSettings)
    :ok
  end

  test "batch API preserves input order and single-detail payloads", %{repo: repo} do
    first = create_work_request!(repo, id: "WR-DASH-DETAIL-BATCH-1", status: "ready_for_slicing")
    second = create_work_request!(repo, id: "WR-DASH-DETAIL-BATCH-2", status: "ready_for_slicing")

    assert {:ok, _question} =
             WorkRequestRepository.ask_question(repo, first.id, question_attrs(id: "WRQ-DASH-DETAIL-BATCH-1"))

    assert {:ok, _decision} =
             WorkRequestRepository.record_decision(repo, second.id, decision_attrs(id: "WRD-DASH-DETAIL-BATCH-1"))

    assert {:ok, _slice} =
             WorkRequestRepository.add_planned_slice(repo, second.id, planned_slice_attrs(id: "WRS-DASH-DETAIL-BATCH-1"))

    assert {:ok, _first_comment} =
             CommentService.create(repo, %{
               target_kind: "work_request",
               target_id: first.id,
               body: "First note",
               source_type: "operator",
               author_name: "operator"
             })

    assert {:ok, _second_comment} =
             CommentService.create(repo, %{
               target_kind: "work_request",
               target_id: second.id,
               body: "Second note",
               source_type: "operator",
               author_name: "operator"
             })

    assert {:ok, [second_detail, first_detail]} = Dashboard.work_request_details(repo, [second.id, first.id])
    assert Enum.map([second_detail, first_detail], & &1.work_request.id) == [second.id, first.id]
    assert first_detail.summary.comment_count == 1
    assert second_detail.summary.comment_count == 1

    assert {:ok, single_first_detail} = Dashboard.work_request_detail(repo, first.id)
    assert {:ok, single_second_detail} = Dashboard.work_request_detail(repo, second.id)
    assert first_detail == single_first_detail
    assert second_detail == single_second_detail
  end

  test "local operator dashboard returns multiple WorkRequest details in card order", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      first = create_work_request!(repo, id: "WR-OPERATOR-BATCH-1", status: "ready_for_clarification")
      second = create_work_request!(repo, id: "WR-OPERATOR-BATCH-2", status: "ready_for_slicing")

      payload = local_operator_dashboard_payload()

      work_request_ids = Enum.map(payload["work_requests"]["work_requests"], & &1["id"])
      detail_ids = Enum.map(payload["work_request_details"], &get_in(&1, ["work_request", "id"]))
      assert payload["work_requests"]["total_count"] == 2
      assert work_request_ids == [first.id, second.id]
      assert detail_ids == work_request_ids
    end)
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-DASH-#{System.unique_integer([:positive])}",
      title: "Improve intake flow",
      repo: "nextide/symphony-plus-plus",
      base_branch: "main",
      work_type: "feature",
      human_description: "Record the human's desired outcome before slicing.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false},
      desired_dispatch_shape: "single_package",
      status: "draft"
    }

    Enum.into(overrides, defaults)
  end

  defp question_attrs(overrides) do
    defaults = %{
      category: "scope",
      question: "Which branch should this target?",
      why_needed: "The architect needs the target before slicing."
    }

    Enum.into(overrides, defaults)
  end

  defp decision_attrs(overrides) do
    defaults = %{
      source_type: "architect",
      decision: "Keep this WorkRequest narrow.",
      rationale: "The next slice owns broader orchestration.",
      scope_impact: "No new runtime tools.",
      created_by: "architect-1"
    }

    Enum.into(overrides, defaults)
  end

  defp planned_slice_attrs(overrides) do
    defaults = %{
      title: "Add WorkRequest dashboard API",
      goal: "Expose read-only dashboard view models.",
      work_package_kind: "mcp",
      target_base_branch: "main",
      branch_pattern: "agent/SYMPP-V2-WR-004/workrequest-read-api",
      owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/dashboard.ex"],
      forbidden_file_globs: ["elixir/lib/symphony_elixir_web/live/**"],
      acceptance_criteria: ["WorkRequest dashboard API reads are scoped and redacted."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/dashboard_api_test.exs"],
      review_lanes: ["brief", "normal"],
      stop_conditions: ["Stop before UI or dispatch wiring."]
    }

    Enum.into(overrides, defaults)
  end

  defp local_operator_conn do
    build_conn()
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("origin", "http://localhost")
    |> Plug.Test.init_test_session(%{})
    |> SymppDashboardApiController.put_local_operator_session()
  end

  defp local_operator_dashboard_payload do
    initial = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard"), 200)
    deferred = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard/deferred"), 200)

    Map.merge(initial, deferred)
  end

  defp with_local_operator_endpoint(fun) when is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, Keyword.put(endpoint_config, :sympp_local_operator, true))

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), sympp_repo: Repo)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
