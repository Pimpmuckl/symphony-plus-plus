defmodule SymphonyElixirWeb.SymppWorkRequestLive.HelpersTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.SymppWorkRequestLive.Helpers

  test "work-package form defaults ordinary work and parses an optional generic review" do
    assert %{
             "kind" => "standard_pr",
             "base_branch" => "main"
           } = Helpers.work_package_form(%{}, %{base_branch: "main"})

    attrs = Helpers.work_package_attrs(%{"review_json" => " \n "})
    refute Map.has_key?(attrs, "review_requirement")

    review = %{"type" => "human", "args" => %{"team" => "maintainers"}}
    assert Helpers.work_package_attrs(%{"review_json" => Jason.encode!(review)})["review_requirement"] == review
  end

  test "work-package authoring follows the repository authoring states" do
    for status <- ["ready_for_clarification", "clarifying", "human_info_needed", "ready_for_slicing", "sliced"] do
      assert Helpers.can_author_work_package?(%{status: status})
      assert Helpers.can_author_work_package?(%{work_request: %{status: status}})
    end

    refute Helpers.can_author_work_package?(%{status: "draft"})
    refute Helpers.can_author_work_package?(%{status: "completed"})
  end
end
