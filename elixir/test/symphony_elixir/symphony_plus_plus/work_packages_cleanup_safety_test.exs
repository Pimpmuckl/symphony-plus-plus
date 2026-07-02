Code.require_file("work_packages_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackagesCleanupSafetyTest do
  use SymphonyElixir.SymphonyPlusPlus.WorkPackagesCase

  test "cleanup clears empty managed directories without using parent git state", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-017", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/cleanup-git-failure"},
               codex_home: codex_home
             )

    File.rm_rf!(prepared.worktree_path)
    File.mkdir_p!(prepared.worktree_path)
    File.mkdir_p!(codex_home)
    TestSupport.git_output!(codex_home, ["init"])
    File.write!(Path.join(codex_home, "ambient-dirty.txt"), "parent repo state must not matter\n")

    assert {:ok, cleaned} =
             WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)

    assert cleaned.status == "stale_record_cleared"
    assert cleaned.worktree_path == nil
    refute File.exists?(prepared.worktree_path)

    assert {:ok, recorded} = Repository.get(repo, package.id)
    assert recorded.worktree_path == nil
  end

  test "cleanup rejects non-empty non-git managed directories without using parent git state", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-019", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/cleanup-non-git"},
               codex_home: codex_home
             )

    File.rm_rf!(prepared.worktree_path)
    File.mkdir_p!(prepared.worktree_path)
    File.write!(Path.join(prepared.worktree_path, "leftover.txt"), "not empty\n")
    File.mkdir_p!(codex_home)
    TestSupport.git_output!(codex_home, ["init"])
    File.write!(Path.join(codex_home, "ambient-dirty.txt"), "parent repo state must not matter\n")

    assert {:error, :invalid_worktree_path} =
             WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)

    assert File.dir?(prepared.worktree_path)
    assert File.exists?(Path.join(prepared.worktree_path, "leftover.txt"))

    assert {:ok, recorded} = Repository.get(repo, package.id)
    assert recorded.worktree_path == prepared.worktree_path
  end

  test "cleanup clears managed directories containing only broken git metadata", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-021", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/cleanup-broken-git"},
               codex_home: codex_home
             )

    File.rm_rf!(prepared.worktree_path)
    File.mkdir_p!(prepared.worktree_path)
    File.write!(Path.join(prepared.worktree_path, ".git"), "gitdir: missing-git-dir\n")

    assert {:ok, cleaned} =
             WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)

    assert cleaned.status == "stale_record_cleared"
    refute File.exists?(prepared.worktree_path)

    assert {:ok, recorded} = Repository.get(repo, package.id)
    assert recorded.worktree_path == nil
  end

  test "cleanup returns sanitized git command failures with target and worktree paths", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-020", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/cleanup-git-failure"},
               codex_home: codex_home
             )

    File.rm_rf!(prepared.worktree_path)
    File.mkdir_p!(prepared.worktree_path)
    fake_git_dir = Path.join(fixture.root, "fake-git-dir")
    File.mkdir_p!(fake_git_dir)
    File.write!(Path.join(fake_git_dir, "HEAD"), "ref: refs/heads/main\n")
    File.write!(Path.join(prepared.worktree_path, ".git"), "gitdir: #{fake_git_dir}\n")

    assert {:error, {:git_failed, status, details}} =
             WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)

    assert is_integer(status)
    assert details.status == status
    assert normalized_path(details.target_repo_root) == normalized_path(fixture.repo_root)
    assert normalized_path(details.worktree_path) == normalized_path(prepared.worktree_path)
    assert details.git_args == ["status", "--porcelain"]
    assert details.stderr =~ "fatal"
  end

  test "cleanup rejects recorded paths that exist as non-directories", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-010", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/cleanup-invalid"},
               codex_home: codex_home
             )

    File.rm_rf!(prepared.worktree_path)
    File.write!(prepared.worktree_path, "not a directory")

    assert {:error, :invalid_worktree_path} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)

    assert {:ok, recorded} = Repository.get(repo, package.id)
    assert recorded.worktree_path == prepared.worktree_path
  end

  test "cleanup rejects recorded worktree paths outside the managed root", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WT-003",
                 kind: "mcp",
                 base_branch: "main",
                 worktree_path: Path.join(fixture.root, "outside")
               )
             )

    assert {:error, :unsafe_worktree_path} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
  end
end
