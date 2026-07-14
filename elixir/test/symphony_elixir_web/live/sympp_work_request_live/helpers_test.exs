defmodule SymphonyElixirWeb.SymppWorkRequestLive.HelpersTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.SymppWorkRequestLive.Helpers

  test "planned-slice form defaults ordinary work and parses an optional generic review" do
    assert %{
             "work_package_kind" => "standard_pr",
             "target_base_branch" => "main"
           } = Helpers.planned_slice_form(%{}, %{base_branch: "main"})

    attrs = Helpers.planned_slice_attrs(%{"review_json" => " \n "})
    refute Map.has_key?(attrs, "review_requirement")

    review = %{"type" => "human", "args" => %{"team" => "maintainers"}}
    assert Helpers.planned_slice_attrs(%{"review_json" => Jason.encode!(review)})["review_requirement"] == review
  end
end
