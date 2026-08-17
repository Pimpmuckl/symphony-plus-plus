Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ProductTreeRevisionIdempotencyTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Revision
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery

  test "delivery replay does not record another product tree revision", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-DELIVERY-REVISION-REPLAY", status: "sliced")

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(id: "WRS-MCP-DELIVERY-REVISION-REPLAY")
             )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, work_request, ArchitectHandoff.capabilities())

    args = %{
      "work_request_id" => work_request.id,
      "work_package_id" => work_package.id,
      "outcome" => "completed_no_pr",
      "evidence" => %{
        "completed_no_pr" => %{"no_pr_evidence" => "Operator confirmed the no-PR closeout."}
      },
      "idempotency_key" => "delivery-revision-replay"
    }

    closeout = mcp_tool(repo, session, "record_work_package_delivery", args)
    assert get_in(closeout, ["result", "structuredContent", "work_package_delivery", "id"])
    assert revision_count(repo, work_request.id) == 1

    replay = mcp_tool(repo, session, "record_work_package_delivery", args)

    assert get_in(replay, ["result", "structuredContent", "work_package_delivery", "id"]) ==
             get_in(closeout, ["result", "structuredContent", "work_package_delivery", "id"])

    assert repo.aggregate(WorkPackageDelivery, :count, :id) == 1
    assert revision_count(repo, work_request.id) == 1
  end

  test "package contract failures preserve revision-first lifecycle recovery", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-CONTRACT-LIFECYCLE", status: "sliced")

    assert {:ok, package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(id: "WRS-MCP-CONTRACT-LIFECYCLE", base_branch: work_request.base_branch)
             )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, work_request, ArchitectHandoff.capabilities())

    package = repo.update!(Ecto.Changeset.change(package, status: "active"))
    args = update_args(work_request.id, package.id, package.contract_revision)

    conflict = mcp_tool(repo, session, "update_work_package", put_in(args["expected_contract_revision"], package.contract_revision + 1))

    assert_lifecycle_error(conflict, "contract_revision_conflict", "active", ["planned"], package.contract_revision, "read_work_request")

    frozen = mcp_tool(repo, session, "update_work_package", args)

    assert_lifecycle_error(
      frozen,
      "work_package_contract_frozen",
      "active",
      ["planned"],
      package.contract_revision,
      "request_scope_expansion"
    )

    repo.update!(Ecto.Changeset.change(package, status: "closed"))
    terminal = mcp_tool(repo, session, "update_work_package", args)

    assert_lifecycle_error(
      terminal,
      "work_package_terminal",
      "closed",
      ["planned"],
      package.contract_revision,
      "create_successor"
    )

    assert revision_count(repo, work_request.id) == 0
  end

  defp update_args(work_request_id, work_package_id, revision) do
    %{
      "work_request_id" => work_request_id,
      "work_package_id" => work_package_id,
      "expected_contract_revision" => revision,
      "patch" => %{"title" => "Must not persist"}
    }
  end

  defp assert_lifecycle_error(response, reason, status, allowed, revision, next_action) do
    data = response["error"]["data"]
    assert response["error"]["code"] == -32_009
    assert data["reason"] == reason
    assert data["actual_status"] == status
    assert data["allowed_authoring_states"] == allowed
    assert data["current_contract_revision"] == revision
    assert data["recovery"] == %{"next_action" => next_action}
  end

  defp revision_count(repo, work_request_id) do
    Revision
    |> repo.all()
    |> Enum.count(&(&1.work_request_id == work_request_id))
  end
end
