Code.require_file("work_packages_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackagesCleanupOwnershipTest do
  use SymphonyElixir.SymphonyPlusPlus.WorkPackagesCase

  test "cleanup removes disposable dirty worktrees and clears their records", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-002", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/cleanup"},
               codex_home: codex_home
             )

    dirty_path = Path.join(prepared.worktree_path, "dirty.txt")
    File.write!(dirty_path, "dirty")

    assert {:ok, cleaned} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
    assert cleaned.status == "cleaned"
    assert cleaned.worktree_path == prepared.worktree_path
    refute File.exists?(prepared.worktree_path)

    assert {:ok, fetched} = Repository.get(repo, package.id)
    assert fetched.worktree_path == nil
    assert fetched.worktree_target_repo_root == nil

    assert {:ok, replayed} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
    assert replayed.status == "already_clean"

    assert {:ok, prepared_again} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/cleanup"},
               codex_home: codex_home
             )

    assert prepared_again.status == "prepared"
    assert File.dir?(prepared_again.worktree_path)
  end

  test "cleanup recovers a stale recorded path after persistence failure", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-005", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/cleanup-persistence"},
               codex_home: codex_home
             )

    assert {:error, :database_busy} =
             WorktreeLifecycle.cleanup(UpdateFailsWorkPackageRepo, package.id,
               codex_home: codex_home,
               repo_root: fixture.repo_root
             )

    assert File.exists?(prepared.worktree_path)

    assert {:ok, fetched} = Repository.get(repo, package.id)
    assert fetched.worktree_path == prepared.worktree_path

    assert {:ok, recovered} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)
    assert recovered.status == "cleaned"

    assert {:ok, cleared} = Repository.get(repo, package.id)
    assert cleared.worktree_path == nil
  end
end
