Code.require_file("work_packages_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackagesTest do
  use SymphonyElixir.SymphonyPlusPlus.WorkPackagesCase

  test "creates and fetches a standalone parentless work package", %{repo: repo} do
    assert {:ok, %WorkPackage{} = created} = Service.create(repo, WorkPackageFactory.attrs(parent_id: nil))

    assert created.id =~ ~r/^wp_[a-z2-7]{16}$/
    assert created.status == "created"
    assert created.parent_id == nil
    assert %DateTime{} = created.inserted_at
    assert %DateTime{} = created.updated_at

    assert {:ok, fetched} = Service.get(repo, created.id)
    assert fetched == created
  end

  test "lists created work packages deterministically", %{repo: repo} do
    assert {:ok, first} = Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-001-A", title: "First"))
    assert {:ok, second} = Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-001-B", title: "Second"))

    assert {:ok, [^first, ^second]} = Repository.list(repo)
    assert {:ok, [^first, ^second]} = Service.list(repo)
  end

  test "updates fields while preserving stable id and inserted timestamp", %{repo: repo} do
    assert {:ok, created} = Repository.create(repo, WorkPackageFactory.attrs(status: "planning"))

    assert {:ok, updated} =
             Repository.update(repo, created.id, %{
               "updated_at" => ~U[2000-01-01 00:00:00Z],
               id: "ignored",
               status: "implementing",
               title: "Updated title",
               inserted_at: ~U[2000-01-01 00:00:00Z]
             })

    assert updated.id == created.id
    assert updated.inserted_at == created.inserted_at
    assert DateTime.compare(updated.updated_at, created.updated_at) != :lt
    assert updated.updated_at != ~U[2000-01-01 00:00:00Z]
    assert updated.status == "implementing"
    assert updated.title == "Updated title"

    assert {:ok, service_updated} = Service.update(repo, created.id, %{status: "ready_for_worker"})
    assert service_updated.status == "ready_for_worker"
  end

  test "rejects invalid kind and status", %{repo: repo} do
    assert {:error, %Ecto.Changeset{} = kind_changeset} =
             Repository.create(repo, WorkPackageFactory.attrs(kind: "legacy_kind"))

    assert "is invalid" in errors_on(kind_changeset).kind

    assert {:ok, created} = Repository.create(repo, WorkPackageFactory.attrs())

    assert {:error, %Ecto.Changeset{} = status_changeset} =
             Repository.update(repo, created.id, %{status: "done_for_real"})

    assert "is invalid" in errors_on(status_changeset).status

    assert {:error, %Ecto.Changeset{} = branch_pattern_changeset} =
             Repository.create(repo, WorkPackageFactory.attrs(branch_pattern: "feat/live-triggers-v1-native-audio-evidence-*"))

    assert "must be an exact branch or a {{placeholder}} template; '*' wildcards are not supported" in errors_on(branch_pattern_changeset).branch_pattern
  end

  test "updates metadata on persisted legacy kind rows", %{repo: repo} do
    legacy_package =
      WorkPackageFactory.attrs(
        id: "SYMPP-LEGACY-KIND-UPDATE",
        kind: "standard_pr",
        status: "ready_for_worker"
      )
      |> then(&struct!(WorkPackage, &1))
      |> repo.insert!()

    assert {:ok, updated} =
             Repository.update(repo, legacy_package.id, %{
               title: "Updated legacy title",
               worktree_path: "C:/tmp/legacy-worktree"
             })

    assert updated.kind == "standard_pr"
    assert updated.title == "Updated legacy title"
    assert updated.worktree_path == "C:/tmp/legacy-worktree"
  end

  test "rejects updates that convert current packages to legacy kinds", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-LEGACY-KIND-CHANGE", kind: "hotfix"))

    assert {:error, %Ecto.Changeset{} = changeset} = Repository.update(repo, package.id, %{kind: "standard_pr"})

    assert "is invalid" in errors_on(changeset).kind
  end

  test "rejects noncanonical policy templates", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: "mcp", policy_template: "mcp"))
    assert package.policy_template == "mcp"

    assert {:ok, current_pr_state_package} =
             Repository.create(repo, WorkPackageFactory.attrs(kind: "mcp", policy_template: "mcp_current_pr_state"))

    assert current_pr_state_package.policy_template == "mcp_current_pr_state"

    assert {:error, %Ecto.Changeset{} = mismatch_changeset} =
             Repository.create(repo, WorkPackageFactory.attrs(kind: "quick_fix", policy_template: "hotfix"))

    assert "is invalid" in errors_on(mismatch_changeset).policy_template

    assert {:error, %Ecto.Changeset{} = alias_changeset} =
             Repository.create(repo, WorkPackageFactory.attrs(kind: "mcp", policy_template: "worker_package"))

    assert "is invalid" in errors_on(alias_changeset).policy_template

    assert {:error, %Ecto.Changeset{} = typo_changeset} =
             Repository.create(repo, WorkPackageFactory.attrs(kind: "mcp", policy_template: "mc"))

    assert "is invalid" in errors_on(typo_changeset).policy_template

    assert {:error, %Ecto.Changeset{} = missing_kind_changeset} =
             Repository.create(repo, WorkPackageFactory.attrs(policy_template: "mcp") |> Map.delete(:kind))

    assert "can't be blank" in errors_on(missing_kind_changeset).kind
    assert "is invalid" in errors_on(missing_kind_changeset).policy_template
  end

  test "returns not found for missing work packages", %{repo: repo} do
    assert {:error, :not_found} = Repository.get(repo, "missing")
    assert {:error, :not_found} = Repository.update(repo, "missing", %{title: "Nope"})
  end

  test "repository normalizes SQLite read failures" do
    assert {:error, :database_busy} = Repository.get(LockedWorkPackageRepo, "wp-1")
    assert {:error, {:storage_failed, "disk I/O failed"}} = Repository.get(BrokenWorkPackageRepo, "wp-1")
  end

  test "rejects duplicate caller-provided ids", %{repo: repo} do
    attrs = WorkPackageFactory.attrs(id: "SYMPP-P1-001")

    assert {:ok, package} = Repository.create(repo, attrs)
    assert package.id == "SYMPP-P1-001"
    assert {:error, :id_already_exists} = Repository.create(repo, attrs)
  end

  test "rejects nil acceptance criteria without crashing", %{repo: repo} do
    assert {:error, %Ecto.Changeset{} = changeset} =
             Repository.create(repo, WorkPackageFactory.attrs(acceptance_criteria: nil))

    assert "can't be blank" in errors_on(changeset).acceptance_criteria
  end

  test "stores acceptance criteria through SQLite", %{repo: repo} do
    criteria = ["Create package", "Fetch package"]

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-001", acceptance_criteria: criteria))

    assert {:ok, fetched} = Repository.get(repo, package.id)
    assert fetched.acceptance_criteria == criteria
  end

  test "stores allowed file globs through SQLite", %{repo: repo} do
    globs = ["src/kraken/**", "test/kraken/**"]

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-001", allowed_file_globs: globs))

    assert {:ok, fetched} = Repository.get(repo, package.id)
    assert fetched.allowed_file_globs == globs
  end

  test "string list type rejects malformed values" do
    assert StringList.type() == :string
    assert StringList.embed_as(:json) == :self
    assert StringList.equal?(["a"], ["a"])

    assert StringList.cast(["a", "b"]) == {:ok, ["a", "b"]}
    assert StringList.cast(["a", 1]) == :error
    assert StringList.cast("not-list") == :error

    assert StringList.load(~s(["a","b"])) == {:ok, ["a", "b"]}
    assert StringList.load(~s(["a",1])) == :error
    assert StringList.load(~s({"not":"list"})) == :error
    assert StringList.load("not-json") == :error
    assert StringList.load(123) == :error

    assert StringList.dump(["a", "b"]) == {:ok, ~s(["a","b"])}
    assert StringList.dump(["a", 1]) == :error
    assert StringList.dump("not-list") == :error
  end

  test "migration is idempotent", %{repo: repo} do
    assert :ok = Repository.migrate(repo)
  end

  test "migration marks id as primary key", %{repo: repo} do
    %{rows: rows} = SQL.query!(repo, "PRAGMA table_info(sympp_work_packages)")

    assert [_cid, "id", _type, _not_null, _default, 1] = Enum.find(rows, &(Enum.at(&1, 1) == "id"))
  end

  test "migration includes worktree target repo root", %{repo: repo} do
    %{rows: rows} = SQL.query!(repo, "PRAGMA table_info(sympp_work_packages)")

    assert Enum.any?(rows, &(Enum.at(&1, 1) == "worktree_target_repo_root"))
  end
end
