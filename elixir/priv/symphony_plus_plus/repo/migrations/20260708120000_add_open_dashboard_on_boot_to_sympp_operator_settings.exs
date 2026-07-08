defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddOpenDashboardOnBootToSymppOperatorSettings do
  use Ecto.Migration

  def change do
    alter table(:sympp_operator_settings) do
      add(:open_dashboard_on_boot, :boolean, null: false, default: true)
    end
  end
end
