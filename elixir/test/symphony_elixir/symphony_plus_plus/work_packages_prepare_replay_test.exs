Code.require_file("work_packages_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackagesPrepareReplayTest do
  use SymphonyElixir.SymphonyPlusPlus.WorkPackagesCase

  test "prepare replays legacy recorded managed worktree paths", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    package_id = "SYMPP-WT-LEGACY-001"
    branch = "feat/legacy-prepare-replay"

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: package_id, kind: "mcp", base_branch: "main"))

    legacy_path = legacy_worktree_path(codex_home, fixture.repo_root, package.id, branch)
    File.mkdir_p!(Path.dirname(legacy_path))
    TestSupport.git_output!(fixture.repo_root, ["worktree", "add", "-b", branch, legacy_path, "origin/main"])

    assert {:ok, _updated} = Repository.update(repo, package.id, %{worktree_path: legacy_path})

    assert {:ok, replayed} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => branch},
               codex_home: codex_home
             )

    assert replayed.status == "already_prepared"
    assert replayed.worktree_path == Path.expand(legacy_path)
    assert File.dir?(legacy_path)
  end

  test "prepare replays previous compact recorded managed worktree paths", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    package_id = "SYMPP-WT-PREV-COMPACT-001"
    branch = "feat/previous-compact-prepare-replay"

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: package_id, kind: "mcp", base_branch: "main"))

    previous_compact_path = previous_compact_worktree_path(codex_home, fixture.repo_root, package.id, branch)
    File.mkdir_p!(Path.dirname(previous_compact_path))
    TestSupport.git_output!(fixture.repo_root, ["worktree", "add", "-b", branch, previous_compact_path, "origin/main"])

    assert {:ok, _updated} = Repository.update(repo, package.id, %{worktree_path: previous_compact_path})

    assert {:ok, replayed} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => branch},
               codex_home: codex_home
             )

    assert replayed.status == "already_prepared"
    assert replayed.worktree_path == Path.expand(previous_compact_path)
    assert File.dir?(previous_compact_path)
  end

  test "prepare rejects legacy recorded managed paths for a different branch", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    package_id = "SYMPP-WT-LEGACY-BRANCH"
    recorded_branch = "feat/legacy-recorded"
    requested_branch = "feat/legacy-requested"

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: package_id, kind: "mcp", base_branch: "main"))

    legacy_path = legacy_worktree_path(codex_home, fixture.repo_root, package.id, recorded_branch)
    File.mkdir_p!(Path.dirname(legacy_path))
    TestSupport.git_output!(fixture.repo_root, ["worktree", "add", "-b", recorded_branch, legacy_path, "origin/main"])

    assert {:ok, _updated} = Repository.update(repo, package.id, %{worktree_path: legacy_path})

    assert {:error, {:worktree_path_already_recorded, recorded_path}} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => requested_branch},
               codex_home: codex_home
             )

    assert recorded_path == Path.expand(legacy_path)
  end
end
