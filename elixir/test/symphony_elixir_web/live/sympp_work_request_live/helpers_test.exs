defmodule SymphonyElixirWeb.SymppWorkRequestLive.HelpersTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.SymppWorkRequestLive.Helpers

  test "planned-slice form defaults ordinary work and preserves policy-derived review lanes" do
    assert %{
             "work_package_kind" => "standard_pr",
             "target_base_branch" => "main"
           } = Helpers.planned_slice_form(%{}, %{base_branch: "main"})

    attrs = Helpers.planned_slice_attrs(%{"review_lanes" => " \n "})
    refute Map.has_key?(attrs, "review_lanes")

    assert Helpers.planned_slice_attrs(%{"review_lanes" => "fast\nnormal"})["review_lanes"] == ["fast", "normal"]
  end
end
