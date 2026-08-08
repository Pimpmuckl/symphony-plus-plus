Code.require_file("work_packages_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackagesPrepareFailureTest do
  use SymphonyElixir.SymphonyPlusPlus.WorkPackagesCase

  test "prepare prunes stale git worktree metadata after missing-path cleanup", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-011", kind: "mcp", base_branch: "main"))

    attrs = %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/stale-prune"}

    assert {:ok, prepared} = WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)

    File.rm_rf!(prepared.worktree_path)

    assert normalized_path(TestSupport.git_output!(fixture.repo_root, ["worktree", "list", "--porcelain"])) =~
             normalized_path(prepared.worktree_path)

    assert {:ok, recovered} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)
    assert recovered.status == "stale_record_cleared"

    refute normalized_path(TestSupport.git_output!(fixture.repo_root, ["worktree", "list", "--porcelain"])) =~
             normalized_path(prepared.worktree_path)

    assert {:ok, prepared_again} = WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)
    assert prepared_again.status == "prepared"
    assert prepared_again.worktree_path == prepared.worktree_path
    assert File.dir?(prepared_again.worktree_path)
  end

  test "prepare returns sanitized git command failures", %{repo: repo} do
    non_repo_root =
      Path.join(System.tmp_dir!(), "sympp-worktree-secret-token-#{System.unique_integer([:positive])}")

    File.mkdir_p!(non_repo_root)
    on_exit(fn -> File.rm_rf(non_repo_root) end)

    sensitive_ref = "raw_secret_abcd1234"
    base_branch = "main-#{sensitive_ref}"
    branch = "feat/#{sensitive_ref}"

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-012", kind: "mcp", base_branch: base_branch))

    attrs = %{"target_repo_root" => non_repo_root, "base_branch" => base_branch, "branch" => branch}

    assert {:error, {:git_failed, status, details} = reason} =
             WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: Path.join(non_repo_root, "codex-home"))

    assert is_integer(status)
    assert details.status == status
    assert details.target_repo_root == "[REDACTED]"
    assert details.base_branch == "main-[REDACTED]"
    assert details.branch == "feat/[REDACTED]"
    assert is_binary(details.stderr)
    assert details.stderr =~ "fatal"
    refute inspect(details.git_args) =~ sensitive_ref
    refute inspect(reason) =~ "secret-token"
    refute inspect(reason) =~ sensitive_ref
  end

  test "prepare updates the remote-tracking base before creating new branches", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    updater_root = Path.join(fixture.root, "updater")

    TestSupport.git_output!(fixture.repo_root, ["config", "--unset-all", "remote.origin.fetch"])
    TestSupport.git_output!(fixture.root, ["clone", fixture.origin, updater_root])
    TestSupport.git_output!(updater_root, ["checkout", "main"])
    TestSupport.git_output!(updater_root, ["config", "user.email", "sympp@example.com"])
    TestSupport.git_output!(updater_root, ["config", "user.name", "Symphony Test"])
    File.write!(Path.join(updater_root, "remote-update.txt"), "remote update\n")
    TestSupport.git_output!(updater_root, ["add", "remote-update.txt"])
    TestSupport.git_output!(updater_root, ["commit", "-m", "Remote update"])
    TestSupport.git_output!(updater_root, ["push", "origin", "main"])

    stale_origin_revision = fixture.repo_root |> TestSupport.git_output!(["rev-parse", "origin/main"]) |> String.trim()
    remote_revision = updater_root |> TestSupport.git_output!(["rev-parse", "HEAD"]) |> String.trim()
    refute stale_origin_revision == remote_revision

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-013", kind: "mcp", base_branch: "main"))

    assert {:ok, _prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/fresh-base"},
               codex_home: codex_home
             )

    assert fixture.repo_root |> TestSupport.git_output!(["rev-parse", "origin/main"]) |> String.trim() == remote_revision
    assert fixture.repo_root |> TestSupport.git_output!(["rev-parse", "feat/fresh-base"]) |> String.trim() == remote_revision
  end

  test "prepare replay rejects recorded paths that are no longer git worktrees", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-009", kind: "mcp", base_branch: "main"))

    attrs = %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/replay-invalid"}

    assert {:ok, prepared} = WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)

    File.rm_rf!(prepared.worktree_path)
    File.mkdir_p!(prepared.worktree_path)

    assert {:error, :invalid_worktree_path} = WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)

    assert {:ok, recorded} = Repository.get(repo, package.id)
    assert recorded.worktree_path == prepared.worktree_path
  end

  test "prepare rejects stale existing local branches", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-008", kind: "mcp", base_branch: "main"))

    attrs = %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/stale"}

    assert {:ok, prepared} = WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)
    assert {:ok, _cleaned} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)

    TestSupport.git_output!(fixture.repo_root, ["checkout", "feat/stale"])
    File.write!(Path.join(fixture.repo_root, "stale.txt"), "stale\n")
    TestSupport.git_output!(fixture.repo_root, ["add", "stale.txt"])
    TestSupport.git_output!(fixture.repo_root, ["commit", "-m", "Stale branch commit"])

    assert {:error, {:stale_existing_branch, details}} =
             WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)

    assert details.branch == "feat/stale"
    assert details.existing_revision == fixture.repo_root |> TestSupport.git_output!(["rev-parse", "feat/stale"]) |> String.trim()
    assert details.base_revision == fixture.repo_root |> TestSupport.git_output!(["rev-parse", "origin/main"]) |> String.trim()
    assert details.base_ref == "origin/main"
    assert details.remediation =~ "Retry without branch"
    refute File.exists?(prepared.worktree_path)
  end

  test "prepare uses collision-resistant paths for distinct branch names", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, first_package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-006-A", kind: "mcp", base_branch: "main"))

    assert {:ok, second_package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-006-B", kind: "mcp", base_branch: "main"))

    assert {:ok, first} =
             WorktreeLifecycle.prepare(
               repo,
               first_package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/a-b"},
               codex_home: codex_home
             )

    assert {:ok, second} =
             WorktreeLifecycle.prepare(
               repo,
               second_package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat-a/b"},
               codex_home: codex_home
             )

    refute first.worktree_path == second.worktree_path
    assert File.dir?(first.worktree_path)
    assert File.dir?(second.worktree_path)
  end

  test "prepare rollback deletes the local branch it created when persistence fails", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-007", kind: "mcp", base_branch: "main"))

    assert {:error, {:worktree_record_failed, :database_busy}} =
             WorktreeLifecycle.prepare(
               UpdateFailsWorkPackageRepo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/rollback"},
               codex_home: codex_home
             )

    assert TestSupport.git_output!(fixture.repo_root, ["branch", "--list", "feat/rollback"]) == ""
  end

  test "prepare rejects existing unrecorded worktree target path", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-004", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/collision"},
               codex_home: codex_home
             )

    assert File.dir?(prepared.worktree_path)
    assert {:ok, _cleared} = Repository.update(repo, package.id, %{worktree_path: nil})

    assert {:error, :worktree_path_exists} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/collision"},
               codex_home: codex_home
             )
  end
end
