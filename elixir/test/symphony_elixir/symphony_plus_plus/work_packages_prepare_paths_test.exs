Code.require_file("work_packages_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackagesPreparePathsTest do
  use SymphonyElixir.SymphonyPlusPlus.WorkPackagesCase

  test "prepares a package worktree under CODEX_HOME and replays the recorded path", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-001", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{
                 "repo_root" => fixture.repo_root,
                 "base_branch" => "main",
                 "branch" => "feat/worktree-lifecycle"
               },
               codex_home: codex_home
             )

    expected_root =
      Path.expand(
        Path.join([
          codex_home,
          "worktrees",
          "spp_worktrees"
        ])
      )

    assert prepared.status == "prepared"
    assert String.starts_with?(prepared.worktree_path, expected_root)
    assert prepared.worktree_path |> Path.relative_to(expected_root) |> Path.split() |> length() == 1
    assert Path.basename(prepared.worktree_path) =~ ~r/^[a-z2-7]{8}$/
    refute prepared.worktree_path =~ "SYMPP-WT-001"
    assert prepared.branch == "feat/worktree-lifecycle"
    assert prepared.base_branch == "main"
    assert File.dir?(prepared.worktree_path)

    assert {:ok, fetched} = Repository.get(repo, package.id)
    assert fetched.worktree_path == prepared.worktree_path
    assert fetched.worktree_target_repo_root == prepared.target_repo_root

    assert {:ok, replayed} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{
                 "repo_root" => fixture.repo_root,
                 "base_branch" => "main",
                 "branch" => "feat/worktree-lifecycle"
               },
               codex_home: codex_home
             )

    assert replayed.status == "already_prepared"
    assert replayed.worktree_path == prepared.worktree_path
  end

  test "prepare keeps generated worktree paths compact for long ids and branches", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    long_id = "SYMPP-WT-LONG-" <> String.duplicate("PACKAGE-", 8)
    long_branch = "feat/" <> String.duplicate("very-long-worktree-branch-", 5) <> "tail"

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: long_id, kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => long_branch},
               codex_home: codex_home
             )

    assert {:ok, worktree_root} = WorktreeLifecycle.worktree_root(codex_home: codex_home)
    relative_path = Path.relative_to(prepared.worktree_path, worktree_root)

    assert String.length(relative_path) <= 52
    assert Path.split(relative_path) == [relative_path]
    assert relative_path =~ ~r/^[a-z2-7]{8}$/
    refute prepared.worktree_path =~ long_id
    refute prepared.worktree_path =~ String.replace(long_branch, "/", "-")
    assert File.dir?(prepared.worktree_path)
  end

  test "prepare falls back to a longer deterministic leaf on collision", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    package_id = "SYMPP-WT-COLLISION"
    branch = "feat/collision"

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: package_id, kind: "mcp", base_branch: "main"))

    assert {:ok, worktree_root} = WorktreeLifecycle.worktree_root(codex_home: codex_home)
    {:ok, normal_leaf} = WorktreePath.worktree_leaf(fixture.repo_root, package.id, branch)
    File.mkdir_p!(Path.join(worktree_root, normal_leaf))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => branch},
               codex_home: codex_home
             )

    fallback_leaf = Path.basename(prepared.worktree_path)
    refute fallback_leaf == normal_leaf
    assert fallback_leaf =~ ~r/^[a-z2-7]{12}$/
    assert prepared.worktree_path |> Path.relative_to(worktree_root) |> Path.split() == [fallback_leaf]
    assert File.dir?(prepared.worktree_path)

    File.rmdir!(Path.join(worktree_root, normal_leaf))

    assert {:ok, replayed} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => branch},
               codex_home: codex_home
             )

    assert replayed.status == "already_prepared"
    assert replayed.worktree_path == prepared.worktree_path
  end
end
