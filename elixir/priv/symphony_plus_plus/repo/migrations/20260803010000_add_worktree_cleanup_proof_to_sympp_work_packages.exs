defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddWorktreeCleanupProofToSymppWorkPackages do
  use Ecto.Migration

  def change do
    alter table(:sympp_work_packages) do
      add(:worktree_cleanup_proof, :text)
    end
  end
end
