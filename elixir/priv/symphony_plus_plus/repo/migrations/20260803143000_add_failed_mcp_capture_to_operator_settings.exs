defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddFailedMcpCaptureToOperatorSettings do
  use Ecto.Migration

  def change do
    alter table(:sympp_operator_settings) do
      add(:capture_failed_mcp_calls, :boolean, null: false, default: false)
    end
  end
end
