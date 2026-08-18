Code.require_file("../work_packages_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.BlockerLifecycleTest do
  use SymphonyElixir.SymphonyPlusPlus.WorkPackagesCase

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository

  test "reactivates a blocked package only after its final blocker is resolved", %{repo: repo} do
    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BLOCKER-LIFECYCLE", status: "blocked"))

    append_blocker(repo, package.id, "first", true)
    append_blocker(repo, package.id, "second", true)
    append_blocker(repo, package.id, "first", false)

    assert {:ok, %{status: "blocked"}} = Repository.reactivate_if_unblocked(repo, package.id)

    append_blocker(repo, package.id, "second", false)

    assert {:ok, active} = Repository.reactivate_if_unblocked(repo, package.id)
    assert active.status == "active"
    assert {:ok, ^active} = Repository.reactivate_if_unblocked(repo, package.id)
  end

  test "never reactivates terminal, abandoned, or deleted packages", %{repo: repo} do
    for status <- ["merged", "closed", "abandoned"] do
      assert {:ok, package} =
               Repository.create(
                 repo,
                 WorkPackageFactory.attrs(id: "SYMPP-BLOCKER-#{status}", status: status)
               )

      assert {:ok, unchanged} = Repository.reactivate_if_unblocked(repo, package.id)
      assert unchanged.status == status
    end

    assert {:ok, deleted} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BLOCKER-DELETED", status: "blocked"))

    repo.delete!(deleted)
    assert {:error, :not_found} = Repository.reactivate_if_unblocked(repo, deleted.id)
  end

  defp append_blocker(repo, work_package_id, blocker_id, active?) do
    source_tool = if active?, do: "report_blocker", else: "resolve_blocker"

    assert {:ok, _event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package_id,
               summary: "#{source_tool} #{blocker_id}",
               status: if(active?, do: "blocked", else: "resolved"),
               payload: %{
                 "type" => "blocker",
                 "source_tool" => source_tool,
                 "blocker_id" => blocker_id,
                 "active" => active?
               }
             })
  end
end
