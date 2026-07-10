defmodule SymphonyElixir.SymphonyPlusPlus.Readiness.ReviewLanes do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.ReviewProfiles
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice

  @spec required(module() | nil, WorkPackage.t()) ::
          {:ok, {[String.t()], [map()]}} | {:error, {:storage_failed, String.t()}}
  def required(repo, %WorkPackage{} = work_package) when is_atom(repo) and not is_nil(repo) do
    with {:ok, linked_lanes} <- linked_planned_slice_review_lanes(repo, work_package.id) do
      {:ok, required_from_linked_planned_slice_lanes(work_package, linked_lanes)}
    end
  end

  def required(_repo, %WorkPackage{} = work_package), do: {:ok, {policy_required(work_package), []}}

  defp required_from_linked_planned_slice_lanes(work_package, {:one, slice_lanes}) do
    required_from_planned_slice_lanes(work_package, slice_lanes)
  end

  defp required_from_linked_planned_slice_lanes(work_package, :missing_or_ambiguous) do
    {policy_required(work_package), []}
  end

  @spec required_from_planned_slice_lanes(WorkPackage.t(), [String.t()] | nil) :: {[String.t()], [map()]}
  def required_from_planned_slice_lanes(%WorkPackage{}, slice_lanes) do
    {ReviewProfiles.normalize_review_suite_profiles(slice_lanes || []), []}
  end

  @spec policy_required(WorkPackage.t()) :: [String.t()]
  def policy_required(%WorkPackage{review_lanes: review_lanes}) when is_list(review_lanes) do
    ReviewProfiles.normalize_review_suite_profiles(review_lanes)
  end

  def policy_required(%WorkPackage{} = work_package) do
    case LifecycleService.policy_for(work_package) do
      {:ok, policy} ->
        policy
        |> get_in([:review_suite, :required])
        |> ReviewProfiles.normalize_profiles()

      {:error, _reason} ->
        []
    end
  end

  defp linked_planned_slice_review_lanes(repo, work_package_id) when is_binary(work_package_id) do
    planned_slices =
      repo.all(
        from(planned_slice in PlannedSlice,
          where: planned_slice.work_package_id == ^work_package_id,
          order_by: [asc: planned_slice.sequence, asc: planned_slice.id],
          limit: 2
        )
      )

    case planned_slices do
      [%PlannedSlice{review_lanes: review_lanes}] -> {:ok, {:one, review_lanes || []}}
      _missing_or_ambiguous -> {:ok, :missing_or_ambiguous}
    end
  rescue
    error in Exqlite.Error -> {:error, {:storage_failed, Exception.message(error)}}
  end

  defp linked_planned_slice_review_lanes(_repo, _work_package_id), do: {:ok, :missing_or_ambiguous}
end
