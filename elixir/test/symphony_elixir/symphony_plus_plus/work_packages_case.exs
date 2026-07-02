defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackagesCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      @moduletag :ci_slow
      alias Ecto.Adapters.SQL
      alias SymphonyElixir.SymphonyPlusPlus.Repo
      alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
      alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Service
      alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.StringList
      alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
      alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle
      alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreePath
      alias SymphonyElixir.TestSupport
      alias SymphonyElixir.WorkPackageFactory

      defmodule LockedWorkPackageRepo do
        def get(_schema, _id), do: raise(%Exqlite.Error{message: "database is locked"})
      end

      defmodule BrokenWorkPackageRepo do
        def get(_schema, _id), do: raise(%Exqlite.Error{message: "disk I/O failed"})
      end

      defmodule UpdateFailsWorkPackageRepo do
        alias SymphonyElixir.SymphonyPlusPlus.Repo

        def get(schema, id), do: Repo.get(schema, id)
        def update(_changeset), do: raise(%Exqlite.Error{message: "database is locked"})
      end

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

      defp errors_on(changeset) do
        Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
          Enum.reduce(options, message, fn {key, value}, acc ->
            String.replace(acc, "%{#{key}}", inspect(value))
          end)
        end)
      end

      defp normalized_path(path) do
        path
        |> String.replace("\\", "/")
        |> String.downcase()
      end

      defp legacy_worktree_path(codex_home, repo_root, package_id, branch) do
        {:ok, worktree_root} = WorktreeLifecycle.worktree_root(codex_home: codex_home)
        {:ok, repo_root} = SymphonyElixir.PathSafety.canonicalize(repo_root)

        Path.join([
          worktree_root,
          legacy_unique_segment(Path.basename(repo_root), repo_root),
          "#{safe_segment(package_id)}-#{legacy_unique_segment(branch, branch)}"
        ])
      end

      defp previous_compact_worktree_path(codex_home, repo_root, package_id, branch) do
        {:ok, worktree_root} = WorktreeLifecycle.worktree_root(codex_home: codex_home)
        {:ok, repo_root} = SymphonyElixir.PathSafety.canonicalize(repo_root)

        Path.join([
          worktree_root,
          previous_compact_unique_segment(Path.basename(repo_root), repo_root),
          "#{previous_compact_unique_segment(package_id, package_id)}_#{previous_compact_unique_segment(branch, branch)}"
        ])
      end

      defp legacy_unique_segment(display_value, fingerprint_value) do
        "#{safe_segment(display_value)}-#{test_short_hash(fingerprint_value)}"
      end

      defp safe_segment(value) do
        value
        |> String.trim()
        |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
        |> String.trim("-")
      end

      defp test_short_hash(value) do
        :sha256
        |> :crypto.hash(value)
        |> Base.url_encode64(padding: false)
        |> binary_part(0, 10)
      end

      defp previous_compact_unique_segment(display_value, fingerprint_value) do
        safe_segment(display_value)

        :sha256
        |> :crypto.hash(fingerprint_value)
        |> Base.encode32(case: :lower, padding: false)
        |> binary_part(0, 16)
      end
    end
  end
end
