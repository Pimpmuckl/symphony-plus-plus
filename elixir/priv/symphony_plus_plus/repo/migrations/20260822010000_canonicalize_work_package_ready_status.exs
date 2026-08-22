defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CanonicalizeWorkPackageReadyStatus do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE sympp_work_packages
    SET status = 'ready_for_merge'
    WHERE status = 'ready_for_human_merge'
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message: "canonical ready status migration cannot identify rows that previously used ready_for_human_merge"
  end
end
