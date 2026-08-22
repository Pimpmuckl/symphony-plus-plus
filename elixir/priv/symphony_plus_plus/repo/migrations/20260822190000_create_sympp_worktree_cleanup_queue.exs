defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppWorktreeCleanupQueue do
  use Ecto.Migration

  def change do
    create table(:sympp_worktree_cleanup_queue, primary_key: false) do
      add(:worktree_path, :text, primary_key: true, null: false)
      add(:work_package_id, :text, null: false)
      add(:target_repo_root, :text, null: false)
      add(:cleanup_proof, :text, null: false)
      add(:attempts, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:last_error, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:sympp_worktree_cleanup_queue, [:next_attempt_at]))
  end
end
