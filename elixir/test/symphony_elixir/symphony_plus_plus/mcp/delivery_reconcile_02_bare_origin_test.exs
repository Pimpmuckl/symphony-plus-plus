Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.DeliveryReconcile02BareOriginTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  @moduletag :ci_slow

  test "WorkPackage worktree MCP prepare and cleanup accept bare repo with owner-qualified target origin", %{repo: repo} do
    fixture =
      "symphony-plus-plus/beta"
      |> TestSupport.git_repo_fixture!(prefix: "sympp-mcp-bare-origin-worktree")
      |> set_relative_owner_origin!("Pimpmuckl/symphony-plus-plus")

    codex_home = Path.join(fixture.root, "codex-home")
    config = Config.default(repo: repo, repo_root: fixture.repo_root)

    {anchor, session, _grant} =
      create_phase_architect_session(
        repo,
        "SYMPP-ARCHITECT-WORKTREE-BARE-ORIGIN",
        ["dispatch:work_request"],
        repo: "symphony-plus-plus"
      )

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WORKTREE-BARE-ORIGIN",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced"
      )

    assert {:ok, work_package} =
             CanonicalWorkPackageFixtures.add_work_package(
               repo,
               work_request.id,
               work_request_work_package_attrs(
                 id: "WRS-MCP-WORKTREE-BARE-ORIGIN",
                 title: "Prepare bare repo target origin worktree",
                 base_branch: anchor.base_branch,
                 branch_pattern: "feat/bare-origin-worktree",
                 allowed_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
                 acceptance_criteria: ["Accept unambiguous owner-qualified target origin."]
               )
             )

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WORKTREE-BARE-ORIGIN",
                 kind: work_package.kind,
                 title: work_package.title,
                 repo: work_request.repo,
                 base_branch: work_package.base_branch,
                 branch_pattern: work_package.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: work_package.allowed_file_globs,
                 acceptance_criteria: work_package.acceptance_criteria,
                 status: "ready_for_worker"
               )
             )

    assert {:ok, approved_slice} = CanonicalWorkPackageFixtures.approve_work_package(repo, work_request.id, work_package.id, "planned")
    assert {:ok, _linked_slice} = CanonicalWorkPackageFixtures.dispatch_work_package(repo, work_request.id, approved_slice.id, "approved", package.id)

    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      prepare_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: config
        )

      prepare_payload = get_in(prepare_response, ["result", "structuredContent"])
      assert prepare_payload["worktree"]["status"] == "prepared"
      assert comparable_path(prepare_payload["worktree"]["target_repo_root"]) == comparable_path(fixture.repo_root)
      assert File.dir?(prepare_payload["worktree"]["path"])

      cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: config
        )

      cleanup_payload = get_in(cleanup_response, ["result", "structuredContent"])
      assert cleanup_payload["worktree"]["status"] == "cleaned"
      assert cleanup_payload["work_package"]["worktree_path"] == nil
      refute File.exists?(prepare_payload["worktree"]["path"])

      legacy_prepare_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: config
        )

      legacy_prepare_payload = get_in(legacy_prepare_response, ["result", "structuredContent"])
      assert legacy_prepare_payload["worktree"]["status"] == "prepared"

      assert {:ok, _legacy_package} = WorkPackageRepository.update(repo, package.id, %{worktree_target_repo_root: nil})
      File.rm_rf!(legacy_prepare_payload["worktree"]["path"])

      legacy_cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: config
        )

      legacy_cleanup_payload = get_in(legacy_cleanup_response, ["result", "structuredContent"])
      assert legacy_cleanup_payload["worktree"]["status"] == "stale_record_cleared"
      assert legacy_cleanup_payload["work_package"]["worktree_path"] == nil
    after
      restore_env("CODEX_HOME", previous_codex_home)
    end
  end
end
