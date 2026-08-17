defmodule SymphonyElixirWeb.SymppWorkRequestLive.ScopeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.Endpoint
  alias SymphonyElixirWeb.SymppWorkRequestLive

  setup_all do
    database_path = WorkPackageFactory.database_path()
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])

    start_supervised!({Repo, database: database_path, pool_size: 2})
    assert :ok = WorkPackageRepository.migrate(Repo)
    Application.put_env(:symphony_elixir, Endpoint, Keyword.put(endpoint_config, :sympp_repo, Repo))

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
      File.rm(database_path)
    end)

    {:ok, repo: Repo}
  end

  test "legacy main grant creates and operates on a canonical WorkRequest", %{repo: repo} do
    grant = %AccessGrant{
      grant_role: "architect",
      phase_id: "phase-live-scope",
      scope_repo: "nextide/symphony-plus-plus",
      scope_base_branch: "origin/main"
    }

    assert {:ok, work_request} =
             SymppWorkRequestLive.__test_create_work_request(grant, %{
               "title" => "Preserve legacy grant operations",
               "work_type" => "feature",
               "human_description" => "Keep canonical main WorkRequests operable.",
               "desired_dispatch_shape" => "single_package"
             })

    assert work_request.base_branch == "main"
    assert {:ok, ready} = SymppWorkRequestLive.__test_mark_ready_in_repo(repo, grant, work_request.id)
    assert ready.status == "ready_for_clarification"
    assert {:ok, %WorkRequest{id: id}} = SymppWorkRequestLive.__test_scoped_work_request(repo, grant, work_request.id)
    assert id == work_request.id
  end
end
