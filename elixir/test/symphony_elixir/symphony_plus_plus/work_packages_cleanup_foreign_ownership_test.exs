Code.require_file("work_packages_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackagesCleanupForeignOwnershipTest do
  use SymphonyElixir.SymphonyPlusPlus.WorkPackagesCase

  test "cleanup rejects worktrees that belong to another repository", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    other_fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle-other")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-014", kind: "mcp", base_branch: "main"))

    assert {:ok, other_package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-015", kind: "mcp", base_branch: "main"))

    assert {:ok, other_prepared} =
             WorktreeLifecycle.prepare(
               repo,
               other_package.id,
               %{"repo_root" => other_fixture.repo_root, "base_branch" => "main", "branch" => "feat/other-repo"},
               codex_home: codex_home
             )

    assert {:ok, _corrupted} = Repository.update(repo, package.id, %{worktree_path: other_prepared.worktree_path})

    assert {:error, :invalid_worktree_path} =
             WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)

    assert File.dir?(other_prepared.worktree_path)
    assert {:ok, recorded} = Repository.get(repo, package.id)
    assert recorded.worktree_path == other_prepared.worktree_path
  end

  test "cleanup rejects same-origin clones that do not own the recorded worktree", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    second_clone_root = TestSupport.git_repo_with_origin_fixture!(fixture.origin, prefix: "sympp-worktree-second-clone")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-016", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/clone-owner"},
               codex_home: codex_home
             )

    assert {:error, :invalid_worktree_path} =
             WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: second_clone_root)

    assert File.dir?(prepared.worktree_path)
    assert {:ok, recorded} = Repository.get(repo, package.id)
    assert recorded.worktree_path == prepared.worktree_path
  end

  test "cleanup rejects missing recorded paths from same-origin non-owning clones", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    second_clone_parent = Path.join(fixture.root, "same-name-second-clone")
    second_clone_root = Path.join(second_clone_parent, Path.basename(fixture.repo_root))
    File.mkdir_p!(second_clone_parent)
    TestSupport.git_output!(fixture.root, ["clone", fixture.origin, second_clone_root])

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-018", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/stale-clone-owner"},
               codex_home: codex_home
             )

    File.rm_rf!(prepared.worktree_path)

    assert {:error, :invalid_worktree_path} =
             WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: second_clone_root)

    assert normalized_path(TestSupport.git_output!(fixture.repo_root, ["worktree", "list", "--porcelain"])) =~
             normalized_path(prepared.worktree_path)

    assert {:ok, recovered} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)
    assert recovered.status == "stale_record_cleared"
  end
end
