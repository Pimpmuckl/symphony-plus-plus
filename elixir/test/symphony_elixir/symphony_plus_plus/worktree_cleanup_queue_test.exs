defmodule SymphonyElixir.SymphonyPlusPlus.WorktreeCleanupQueueTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeCleanupQueue
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeCleanupQueue.Entry
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.TestSupport
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()
    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkPackageRepository.migrate(Repo)
    on_exit(fn -> File.rm(database_path) end)
    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(Entry)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "transient filesystem obstruction stays queued and clears after recovery", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-cleanup-queue-retry")
    codex_home = use_codex_home!(fixture.root)
    package = prepared_package!(repo, fixture.repo_root, codex_home, "WP-CLEANUP-RETRY", "fix/cleanup-retry")

    assert {:ok, _terminal} = WorkPackageRepository.update_status(repo, package.id, "created", "merged")
    assert [%Entry{attempts: 0}] = repo.all(Entry)

    unavailable_root = fixture.repo_root <> "-unavailable"
    File.rename!(fixture.repo_root, unavailable_root)

    assert :ok = WorktreeCleanupQueue.reconcile(repo, codex_home: codex_home, base_backoff_ms: 1, max_backoff_ms: 1)
    assert [%Entry{attempts: 1}] = repo.all(Entry)
    assert File.dir?(package.worktree_path)

    File.rename!(unavailable_root, fixture.repo_root)
    Process.sleep(5)

    assert :ok = WorktreeCleanupQueue.reconcile(repo, codex_home: codex_home, base_backoff_ms: 1, max_backoff_ms: 1)
    assert repo.all(Entry) == []
    refute File.exists?(package.worktree_path)
    assert repo.get!(WorkPackage, package.id).worktree_path == nil
  end

  test "supervised startup resumes an archived request cleanup", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-cleanup-queue-startup")
    codex_home = use_codex_home!(fixture.root)
    {request, package} = prepared_linked_package!(repo, fixture.repo_root, codex_home, "WR-CLEANUP-STARTUP", "fix/cleanup-startup")

    repo.update!(Ecto.Changeset.change(package, status: "merged"))
    repo.update!(Ecto.Changeset.change(request, completed_at: DateTime.utc_now(:microsecond)))

    assert {:ok, _archived} = WorkRequestService.archive(repo, request.id)
    assert [%Entry{}] = repo.all(Entry)

    name = Module.concat(__MODULE__, StartupReconciler)

    reconciler_opts =
      [repo: repo, name: name, cleanup_opts: [codex_home: codex_home], base_backoff_ms: 1]

    start_supervised!({WorktreeCleanupQueue, reconciler_opts})

    assert_eventually(fn ->
      assert repo.all(Entry) == []
      refute File.exists?(package.worktree_path)
    end)
  end

  test "request deletion keeps cleanup after the owning rows are gone", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-cleanup-queue-delete")
    codex_home = use_codex_home!(fixture.root)
    {request, package} = prepared_linked_package!(repo, fixture.repo_root, codex_home, "WR-CLEANUP-DELETE", "fix/cleanup-delete")

    assert {:ok, deleted_id} = WorkRequestService.delete(repo, request.id)
    assert deleted_id == request.id
    assert repo.get(WorkRequest, request.id) == nil
    assert repo.get(WorkPackage, package.id) == nil
    assert [%Entry{work_package_id: package_id}] = repo.all(Entry)
    assert package_id == package.id

    assert :ok = WorktreeCleanupQueue.reconcile(repo, codex_home: codex_home)
    assert repo.all(Entry) == []
    refute File.exists?(package.worktree_path)
  end

  test "active packages do not create cleanup obligations", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-cleanup-queue-active")
    codex_home = use_codex_home!(fixture.root)
    package = prepared_package!(repo, fixture.repo_root, codex_home, "WP-CLEANUP-ACTIVE", "fix/cleanup-active")
    active = repo.update!(Ecto.Changeset.change(package, status: "active"))

    assert :ok = WorktreeCleanupQueue.enqueue_terminal(repo, active, codex_home: codex_home)
    assert repo.all(Entry) == []
    assert File.dir?(package.worktree_path)
  end

  test "manual retryable cleanup reports queued while preserving its durable obligation", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-cleanup-queue-manual")
    codex_home = use_codex_home!(fixture.root)
    package = prepared_package!(repo, fixture.repo_root, codex_home, "WP-CLEANUP-MANUAL", "fix/cleanup-manual")

    failure =
      {:git_failed, 1,
       %{
         stage: "git_worktree_remove",
         rule: "durable_preflight_proof"
       }}

    assert {:ok, queued} = WorktreeCleanupQueue.queue_retryable_cleanup(repo, package, failure, codex_home: codex_home)
    assert queued.status == "cleanup_queued"
    assert queued.worktree_path == package.worktree_path
    assert [%Entry{work_package_id: package_id, worktree_path: worktree_path}] = repo.all(Entry)
    assert package_id == package.id
    assert worktree_path == package.worktree_path

    assert {:error, :invalid_worktree_path} =
             WorktreeCleanupQueue.queue_retryable_cleanup(repo, package, :invalid_worktree_path, codex_home: codex_home)

    assert {:error, :unsafe_worktree_path} =
             WorktreeCleanupQueue.queue_retryable_cleanup(
               repo,
               %{package | worktree_path: fixture.repo_root},
               failure,
               codex_home: codex_home
             )
  end

  defp prepared_linked_package!(repo, repo_root, codex_home, request_id, branch) do
    assert {:ok, request} = WorkRequestRepository.create(repo, work_request_attrs(request_id))
    package = prepared_package!(repo, repo_root, codex_home, "#{request_id}-WP", branch, work_request_id: request.id)
    {request, package}
  end

  defp prepared_package!(repo, repo_root, codex_home, id, branch, overrides \\ []) do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(Keyword.merge([id: id], overrides)))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => repo_root, "base_branch" => "main", "branch" => branch},
               codex_home: codex_home
             )

    prepared.work_package
  end

  defp work_request_attrs(id) do
    %{
      id: id,
      title: id,
      repo: "nextide/example",
      base_branch: "main",
      work_type: "feature",
      human_description: "Test durable cleanup.",
      constraints: %{},
      desired_dispatch_shape: "single_package",
      status: "ready_for_slicing"
    }
  end

  defp use_codex_home!(root) do
    codex_home = Path.join(root, "codex-home")
    previous = System.get_env("CODEX_HOME")
    System.put_env("CODEX_HOME", codex_home)
    on_exit(fn -> if(previous, do: System.put_env("CODEX_HOME", previous), else: System.delete_env("CODEX_HOME")) end)
    codex_home
  end

  defp assert_eventually(assertion, attempts \\ 80)
  defp assert_eventually(_assertion, 0), do: flunk("condition was not met before timeout")

  defp assert_eventually(assertion, attempts) do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(25)
      assert_eventually(assertion, attempts - 1)
  end
end
