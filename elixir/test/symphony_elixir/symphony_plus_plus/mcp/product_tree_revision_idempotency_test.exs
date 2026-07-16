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

  defp revision_count(repo, work_request_id) do
    Revision
    |> repo.all()
    |> Enum.count(&(&1.work_request_id == work_request_id))
  end
end
