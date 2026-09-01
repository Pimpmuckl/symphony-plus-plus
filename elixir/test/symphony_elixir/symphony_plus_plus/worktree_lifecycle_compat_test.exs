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

  test "prepares legacy frozen origin/main contracts without rewriting them", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-legacy-base")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-LEGACY-BASE", kind: "mcp", base_branch: "main"))

    package = repo.update!(Ecto.Changeset.change(package, base_branch: "origin/main", status: "active"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "origin/main", "branch" => "feat/legacy-base"},
               codex_home: codex_home
             )

    assert prepared.status == "prepared"
    assert prepared.base_branch == "main"
    assert File.exists?(Path.join(prepared.worktree_path, "README.md"))
    assert repo.get!(WorkPackage, package.id).base_branch == "origin/main"
  end

  test "stores nullable worktree metadata through SQLite", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-001"))
    assert package.worktree_path == nil
    assert package.worktree_target_repo_root == nil
    assert package.worktree_cleanup_proof == nil

    worktree_path = Path.join(System.tmp_dir!(), "sympp-worktree-path")
    target_repo_root = Path.join(System.tmp_dir!(), "sympp-target-repo-root")

    assert {:ok, updated} =
             Repository.update(repo, package.id, %{
               worktree_path: worktree_path,
               worktree_target_repo_root: target_repo_root,
               worktree_cleanup_proof: "proof"
             })

    assert updated.worktree_path == worktree_path
    assert updated.worktree_target_repo_root == target_repo_root
    assert updated.worktree_cleanup_proof == "proof"

    assert {:ok, cleared} =
             Repository.update(repo, package.id, %{
               worktree_path: nil,
               worktree_target_repo_root: nil,
               worktree_cleanup_proof: nil
             })

    assert cleared.worktree_path == nil
    assert cleared.worktree_target_repo_root == nil
    assert cleared.worktree_cleanup_proof == nil
  end

  test "cleanup retries a proven Windows partial worktree removal", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-recovery")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-RECOVERY", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/partial-remove"},
               codex_home: codex_home
             )

    fake_git = partial_remove_git(prepared.worktree_path)

    assert {:error, {:git_failed, 255, details}} =
             WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, git: fake_git)

    assert details.stage == "git_worktree_remove"
    assert details.rule == "durable_preflight_proof"
    assert Path.expand(details.recorded_worktree_path) == Path.expand(prepared.worktree_path)
    assert Path.expand(details.resolved_worktree_path) == Path.expand(prepared.worktree_path)
    assert File.exists?(Path.join(prepared.worktree_path, "README.md"))
    refute File.exists?(Path.join(prepared.worktree_path, ".git"))

    assert {:ok, failed_package} = Repository.get(repo, package.id)
    assert is_binary(failed_package.worktree_cleanup_proof)

    assert {:ok, recovered} =
             File.cd!(fixture.root, fn ->
               WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, git: fake_git)
             end)

    assert recovered.stage == "residue_removal"
    assert recovered.rule == "durable_preflight_proof"
    refute File.exists?(prepared.worktree_path)

    assert {:ok, cleaned_package} = Repository.get(repo, package.id)
    assert cleaned_package.worktree_path == nil
    assert cleaned_package.worktree_target_repo_root == nil
    assert cleaned_package.worktree_cleanup_proof == nil
  end

  test "cleanup removes residue after Git reports successful worktree removal", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-residue")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-RESIDUE", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/residue-remove"},
               codex_home: codex_home
             )

    residue = Path.join([prepared.worktree_path, "node_modules", "residue"])
    File.mkdir_p!(residue)

    preserved_target =
      if match?({:win32, _name}, :os.type()) do
        target = Path.join(fixture.root, "broken-junction-target")
        preserved_target = Path.join(fixture.root, "preserved-junction-target")
        File.mkdir_p!(target)
        File.mkdir_p!(preserved_target)
        File.write!(Path.join(preserved_target, "sentinel"), "keep")
        junction = Path.join(residue, "broken")
        preserved_junction = Path.join(residue, "preserved")
        script = Path.join(fixture.root, "junction.ps1")
        File.write!(script, "param($Path, $Target)\nNew-Item -ItemType Junction -Path $Path -Target $Target | Out-Null\n")

        {_output, 0} =
          System.cmd("powershell.exe", ["-NoProfile", "-File", script, "-Path", junction, "-Target", target], stderr_to_stdout: true)

        {_output, 0} =
          System.cmd("powershell.exe", ["-NoProfile", "-File", script, "-Path", preserved_junction, "-Target", preserved_target], stderr_to_stdout: true)

        File.rmdir!(target)

        on_exit(fn ->
          for path <- [junction, preserved_junction], match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)), do: File.rmdir(path)
        end)

        preserved_target
      else
        File.write!(Path.join(residue, "leftover"), "ignored")
        nil
      end

    assert {:ok, cleaned} =
             WorktreeLifecycle.cleanup(repo, package.id,
               codex_home: codex_home,
               git: partial_remove_git(prepared.worktree_path, 0)
             )

    assert cleaned.status == "cleaned"
    refute File.exists?(prepared.worktree_path)
    if preserved_target, do: assert(File.read!(Path.join(preserved_target, "sentinel")) == "keep")

    assert {:ok, cleaned_package} = Repository.get(repo, package.id)
    assert cleaned_package.worktree_path == nil
    assert cleaned_package.worktree_target_repo_root == nil
    assert cleaned_package.worktree_cleanup_proof == nil
  end

  defp partial_remove_git(worktree_path, status \\ 255) do
    git = System.find_executable("git") || flunk("git executable is required")

    fn repo_root, args ->
      case args do
        ["worktree", "remove", "--force", ^worktree_path] ->
          File.rm!(Path.join(worktree_path, ".git"))
          {_output, 0} = System.cmd(git, ["-C", repo_root, "worktree", "prune"], stderr_to_stdout: true)
          {"simulated Windows partial worktree removal\n", status}

        _args ->
          System.cmd(git, ["-C", repo_root | args], stderr_to_stdout: true)
      end
    end
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
