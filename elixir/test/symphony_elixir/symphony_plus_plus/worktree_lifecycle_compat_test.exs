defmodule SymphonyElixir.SymphonyPlusPlus.WorktreeLifecycleCompatTest do
  use ExUnit.Case, async: false

  @moduletag :ci_slow

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreePath
  alias SymphonyElixir.TestSupport
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(WorkPackage)
    :ok
  end

  test "prepare replays immediately previous managed worktree paths", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    branch = "feat/previous-prepare-replay"

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-PREVIOUS-001", kind: "mcp", base_branch: "main"))

    previous_path = previous_worktree_path(codex_home, fixture.repo_root, package.id, branch)
    File.mkdir_p!(Path.dirname(previous_path))
    TestSupport.git_output!(fixture.repo_root, ["worktree", "add", "-b", branch, previous_path, "origin/main"])

    assert {:ok, _updated} = Repository.update(repo, package.id, %{worktree_path: previous_path})

    assert {:ok, replayed} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => branch},
               codex_home: codex_home
             )

    assert replayed.status == "already_prepared"
    assert replayed.worktree_path == Path.expand(previous_path)
  end

  test "stores nullable worktree metadata through SQLite", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-001"))
    assert package.worktree_path == nil
    assert package.worktree_target_repo_root == nil

    worktree_path = Path.join(System.tmp_dir!(), "sympp-worktree-path")
    target_repo_root = Path.join(System.tmp_dir!(), "sympp-target-repo-root")

    assert {:ok, updated} =
             Repository.update(repo, package.id, %{
               worktree_path: worktree_path,
               worktree_target_repo_root: target_repo_root
             })

    assert updated.worktree_path == worktree_path
    assert updated.worktree_target_repo_root == target_repo_root

    assert {:ok, cleared} = Repository.update(repo, package.id, %{worktree_path: nil, worktree_target_repo_root: nil})
    assert cleared.worktree_path == nil
    assert cleared.worktree_target_repo_root == nil
  end

  defp previous_worktree_path(codex_home, repo_root, package_id, branch) do
    {:ok, worktree_root} = WorktreeLifecycle.worktree_root(codex_home: codex_home)
    {:ok, repo_root} = PathSafety.canonicalize(repo_root)
    {:ok, repo_segment} = WorktreePath.previous_unique_segment(Path.basename(repo_root), repo_root)
    {:ok, package_segment} = WorktreePath.previous_unique_segment(package_id, package_id)
    {:ok, branch_segment} = WorktreePath.previous_unique_segment(branch, branch)

    Path.join([worktree_root, repo_segment, "#{package_segment}-#{branch_segment}"])
  end
end
