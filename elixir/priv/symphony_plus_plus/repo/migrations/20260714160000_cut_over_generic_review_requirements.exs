defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CutOverGenericReviewRequirements do
  use Ecto.Migration

  def up do
    alter table(:sympp_work_request_planned_slices) do
      add(:review_requirement, :map)
    end

    alter table(:sympp_work_packages) do
      add(:review_requirement, :map)
    end

    migrate_review_lanes("sympp_work_request_planned_slices")
    migrate_review_lanes("sympp_work_packages")

    execute("""
    UPDATE sympp_work_packages
    SET policy_template = 'mcp'
    WHERE policy_template = 'mcp_review_suite_artifact'
    """)

    execute("""
    UPDATE sympp_work_packages
    SET review_requirement = json_object(
      'type', 'review-suite',
      'args', json_object('mode', CASE WHEN kind = 'hotfix' THEN 'fast' ELSE 'normal' END)
    )
    WHERE review_requirement IS NULL
      AND kind != 'investigation'
      AND review_lanes IS NULL
    """)
  end

  def down do
    alter table(:sympp_work_packages) do
      remove(:review_requirement)
    end

    alter table(:sympp_work_request_planned_slices) do
      remove(:review_requirement)
    end
  end

  defp migrate_review_lanes(table) do
    execute("""
    UPDATE #{table}
    SET review_requirement = json_object(
      'type', 'review-suite',
      'args', json_object(
        'mode', CASE
          WHEN EXISTS (SELECT 1 FROM json_each(#{table}.review_lanes) WHERE value = 'deep') THEN 'deep'
          WHEN EXISTS (SELECT 1 FROM json_each(#{table}.review_lanes) WHERE value IN ('normal', 'brief')) THEN 'normal'
          WHEN EXISTS (SELECT 1 FROM json_each(#{table}.review_lanes) WHERE value IN ('fast', 'emergency')) THEN 'fast'
        END
      )
    )
    WHERE review_requirement IS NULL
      AND json_valid(review_lanes)
      AND json_type(review_lanes) = 'array'
      AND EXISTS (
        SELECT 1 FROM json_each(review_lanes)
        WHERE value IN ('fast', 'normal', 'deep', 'brief', 'emergency')
      )
    """)
  end
end
