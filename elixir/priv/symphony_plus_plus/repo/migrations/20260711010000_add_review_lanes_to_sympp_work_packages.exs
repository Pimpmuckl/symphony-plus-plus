defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddReviewLanesToSymppWorkPackages do
  use Ecto.Migration

  def change do
    alter table(:sympp_work_packages) do
      add(:review_lanes, :text)
    end
  end
end
