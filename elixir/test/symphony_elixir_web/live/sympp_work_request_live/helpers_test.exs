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
end
