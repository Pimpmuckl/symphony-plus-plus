Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ProductTreeRevisionIdempotencyTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Revision
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
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

  test "architect package updates preserve revision conflicts and terminal rejection", %{repo: repo} do
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

    authoring_states = WorkPackage.statuses() -- ["skipped", "merged", "closed", "abandoned"]
    assert_lifecycle_error(conflict, "contract_revision_conflict", "active", authoring_states, package.contract_revision, "read_work_request")

    updated = mcp_tool(repo, session, "update_work_package", args)
    updated_revision = get_in(updated, ["result", "structuredContent", "contract_revision"])

    assert updated_revision == package.contract_revision + 1
    assert get_in(updated, ["result", "structuredContent", "status", "work_package_status"]) == "active"
    assert repo.get!(WorkPackage, package.id).title == "Updated package"

    ready_package = repo.get!(WorkPackage, package.id)
    repo.update!(Ecto.Changeset.change(ready_package, status: "ready_for_merge"))

    readiness_args =
      work_request.id
      |> update_args(package.id, updated_revision)
      |> put_in(["patch", "title"], "Updated from readiness")

    readiness_update = mcp_tool(repo, session, "update_work_package", readiness_args)
    readiness_revision = get_in(readiness_update, ["result", "structuredContent", "contract_revision"])

    assert readiness_revision == updated_revision + 1
    assert get_in(readiness_update, ["result", "structuredContent", "status", "work_package_status"]) == "implementing"
    assert repo.get!(WorkPackage, package.id).title == "Updated from readiness"

    implementing_package = repo.get!(WorkPackage, package.id)
    repo.update!(Ecto.Changeset.change(implementing_package, status: "closed"))
    terminal = mcp_tool(repo, session, "update_work_package", update_args(work_request.id, package.id, readiness_revision))

    assert_lifecycle_error(
      terminal,
      "work_package_terminal",
      "closed",
      authoring_states,
      readiness_revision,
      "create_successor"
    )

    skipped =
      mcp_tool(repo, session, "skip_work_package", %{
        "work_request_id" => work_request.id,
        "work_package_id" => package.id,
        "current_status" => "closed"
      })

    assert_lifecycle_error(
      skipped,
      "work_package_terminal",
      "closed",
      ["planned"],
      readiness_revision,
      "create_successor"
    )

    assert revision_count(repo, work_request.id) == 1
  end

  defp update_args(work_request_id, work_package_id, revision) do
    %{
      "work_request_id" => work_request_id,
      "work_package_id" => work_package_id,
      "expected_contract_revision" => revision,
      "patch" => %{"title" => "Updated package"}
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
