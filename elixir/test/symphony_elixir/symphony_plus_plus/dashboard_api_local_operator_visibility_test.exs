defmodule SymphonyElixir.SymphonyPlusPlus.DashboardApiLocalOperatorVisibilityTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.OperatorAudit
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
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
    repo.delete_all(OperatorAudit)
    repo.delete_all(AgentRun)
    repo.delete_all(Artifact)
    repo.delete_all(ProgressEvent)
    repo.delete_all(Finding)
    repo.delete_all(PlanNode)
    repo.delete_all(SoloSessionEntry)
    repo.delete_all(SoloSession)
    repo.delete_all(GuidanceRequest)
    repo.delete_all(Comment)
    repo.delete_all(AccessGrant)
    repo.delete_all(PlannedSliceDelivery)
    repo.delete_all(PlannedSlice)
    repo.delete_all(WorkPackage)
    repo.delete_all(Phase)
    repo.delete_all(DecisionLogEntry)
    repo.delete_all(ClarificationQuestion)
    repo.delete_all(WorkRequest)
    repo.delete_all(OperatorSettings)
    :ok
  end

  test "local operator dashboard hides packages linked only from archived WorkRequests", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      archived_request =
        create_work_request!(repo,
          id: "WR-LOCAL-ARCHIVED-LINKS",
          status: "ready_for_slicing",
          repo: "nextide/symphony-plus-plus",
          base_branch: "main"
        )

      terminal_package =
        create_dispatched_package!(repo, archived_request,
          slice_id: "WRS-LOCAL-ARCHIVED-TERMINAL",
          package_id: "WP-LOCAL-ARCHIVED-TERMINAL",
          status: "merged"
        )

      stale_package =
        create_dispatched_package!(repo, archived_request,
          slice_id: "WRS-LOCAL-ARCHIVED-STALE",
          package_id: "WP-LOCAL-ARCHIVED-STALE",
          status: "ready_for_worker"
        )

      active_request =
        create_work_request!(repo,
          id: "WR-LOCAL-ACTIVE-LINK",
          status: "ready_for_slicing",
          repo: archived_request.repo,
          base_branch: archived_request.base_branch
        )

      active_package =
        create_dispatched_package!(repo, active_request,
          slice_id: "WRS-LOCAL-ACTIVE-LINK",
          package_id: "WP-LOCAL-ACTIVE-LINK",
          status: "ready_for_worker"
        )

      archived_at = DateTime.utc_now(:microsecond)

      archived_request
      |> Ecto.Changeset.change(completed_at: archived_at, completion_source: "operator", archived_at: archived_at)
      |> repo.update!()

      payload = local_operator_dashboard_payload()

      package_ids = board_work_package_ids(payload)

      refute terminal_package.id in package_ids
      refute stale_package.id in package_ids
      assert active_package.id in package_ids

      assert terminal_package.id in payload["linked_work_package_ids"]
      assert stale_package.id in payload["linked_work_package_ids"]
      assert active_package.id in payload["linked_work_package_ids"]

      refute Enum.any?(payload["work_request_details"], &(get_in(&1, ["work_request", "id"]) == archived_request.id))

      active_detail = work_request_detail(payload, active_request.id)
      assert get_in(active_detail, ["planned_slices", Access.at(0), "work_package_id"]) == active_package.id
    end)
  end

  test "local operator dashboard hides architect handoff anchor WorkPackages", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      anchor =
        create_work_package!(repo,
          id: "SYMPP-WR-ARCH-DASHBOARD-ANCHOR",
          kind: "delegation",
          title: "Architect handoff: Dashboard cleanup",
          status: "planning",
          repo: "nextide/symphony-plus-plus",
          base_branch: "main"
        )

      ordinary_delegation =
        create_work_package!(repo,
          id: "WP-LOCAL-DELEGATION-NONANCHOR",
          kind: "delegation",
          title: "Delegation delivery package",
          status: "planning",
          repo: anchor.repo,
          base_branch: anchor.base_branch
        )

      prefixed_delivery_package =
        create_work_package!(repo,
          id: "SYMPP-WR-ARCH-DASHBOARD-DELIVERY",
          kind: "mcp",
          title: "Prefix-like delivery package",
          status: "planning",
          repo: anchor.repo,
          base_branch: anchor.base_branch
        )

      payload = local_operator_dashboard_payload()

      package_ids = board_work_package_ids(payload)

      refute anchor.id in package_ids
      assert ordinary_delegation.id in package_ids
      assert prefixed_delivery_package.id in package_ids
    end)
  end

  test "local operator can archive delivered unlinked WorkPackages without deleting them", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      delivered_package =
        create_work_package!(repo,
          id: "WP-LOCAL-ARCHIVE-UNLINKED",
          status: "merged",
          repo: "nextide/symphony-plus-plus",
          base_branch: "main"
        )

      active_package =
        create_work_package!(repo,
          id: "WP-LOCAL-ARCHIVE-ACTIVE",
          status: "implementing",
          repo: delivered_package.repo,
          base_branch: delivered_package.base_branch
        )

      archive_payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{delivered_package.id}/archive", %{})
        |> json_response(200)

      refute Map.has_key?(archive_payload, "dashboard")
      assert archive_payload["ok"] == true
      assert archive_payload["work_package_id"] == delivered_package.id
      assert get_in(archive_payload, ["refresh", "dashboard"]) == true
      assert get_in(archive_payload, ["refresh", "work_package_id"]) == delivered_package.id

      dashboard_payload = local_operator_dashboard_payload()

      assert get_in(dashboard_payload, ["settings", "hidden_work_package_ids"]) == [delivered_package.id]
      assert active_package.id in board_work_package_ids(dashboard_payload)
      refute delivered_package.id in board_work_package_ids(dashboard_payload)

      assert {:ok, persisted_package} = WorkPackageRepository.get(repo, delivered_package.id)
      assert persisted_package.status == "merged"
    end)
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_dispatched_package!(repo, work_request, opts) do
    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: Keyword.fetch!(opts, :slice_id), target_base_branch: work_request.base_branch))

    assert {:ok, approved} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    package =
      create_matching_work_package!(repo, work_request, approved,
        id: Keyword.fetch!(opts, :package_id),
        status: Keyword.fetch!(opts, :status)
      )

    assert {:ok, _dispatched} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved.id, "approved", package.id)

    package
  end

  defp create_work_package!(repo, overrides) do
    overrides
    |> WorkPackageFactory.attrs()
    |> then(&WorkPackageRepository.create(repo, &1))
    |> case do
      {:ok, work_package} -> work_package
      {:error, reason} -> flunk("failed to create WorkPackage: #{inspect(reason)}")
    end
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

    create_work_package!(repo, attrs)
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
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/dashboard_api_local_operator_visibility_test.exs"],
      review_lanes: ["brief", "normal"],
      stop_conditions: ["Stop before UI or dispatch wiring."]
    }

    Enum.into(overrides, defaults)
  end

  defp work_request_detail(dashboard, work_request_id) do
    dashboard
    |> get_in(["work_request_details"])
    |> Kernel.||([])
    |> Enum.find(&(get_in(&1, ["work_request", "id"]) == work_request_id))
  end

  defp board_work_package_ids(dashboard) do
    dashboard
    |> get_in(["board", "groups"])
    |> Kernel.||(%{})
    |> Map.values()
    |> List.flatten()
    |> Enum.map(& &1["id"])
  end

  defp local_operator_conn do
    build_conn()
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("origin", "http://localhost")
    |> Plug.Test.init_test_session(%{})
    |> SymppDashboardApiController.put_local_operator_session()
  end

  defp local_operator_csrf_conn do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    local_operator_conn()
    |> put_req_header("x-csrf-token", csrf_token)
  end

  defp local_operator_dashboard_payload do
    initial = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard"), 200)
    deferred = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard/deferred"), 200)

    Map.merge(initial, deferred)
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), sympp_repo: Repo)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp with_local_operator_endpoint(fun) when is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint_config, :sympp_local_operator, true)
    )

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end
  end
end
