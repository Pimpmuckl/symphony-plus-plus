defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CutOverWorkRequestReviewModes do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE sympp_work_request_planned_slices AS planned_slice
    SET review_lanes = (#{rewrite_array("planned_slice.review_lanes")})
    WHERE EXISTS (
      SELECT 1
      FROM sympp_work_requests AS work_request
      WHERE work_request.id = planned_slice.work_request_id
        AND work_request.completed_at IS NULL
        AND work_request.archived_at IS NULL
    )
      AND json_valid(planned_slice.review_lanes)
      AND json_type(planned_slice.review_lanes) = 'array'
      AND EXISTS (
        SELECT 1 FROM json_each(planned_slice.review_lanes)
        WHERE value IN ('brief', 'emergency')
      )
    """)

    execute("""
    UPDATE sympp_work_packages AS work_package
    SET review_lanes = (#{rewrite_array("work_package.review_lanes")})
    WHERE EXISTS (
      SELECT 1
      FROM sympp_work_request_planned_slices AS planned_slice
      JOIN sympp_work_requests AS work_request
        ON work_request.id = planned_slice.work_request_id
      WHERE planned_slice.work_package_id = work_package.id
        AND work_request.completed_at IS NULL
        AND work_request.archived_at IS NULL
    )
      AND json_valid(work_package.review_lanes)
      AND json_type(work_package.review_lanes) = 'array'
      AND EXISTS (
        SELECT 1 FROM json_each(work_package.review_lanes)
        WHERE value IN ('brief', 'emergency')
      )
    """)
  end

  def down, do: :ok

  defp rewrite_array(column) do
    """
    SELECT json_group_array(mode)
    FROM (
      SELECT
        CASE value
          WHEN 'brief' THEN 'normal'
          WHEN 'emergency' THEN 'fast'
          ELSE value
        END AS mode,
        MIN(CAST(key AS INTEGER)) AS first_position
      FROM json_each(#{column})
      GROUP BY mode
      ORDER BY first_position
    )
    """
  end
end
