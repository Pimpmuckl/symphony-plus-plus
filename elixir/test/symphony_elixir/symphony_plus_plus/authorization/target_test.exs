defmodule SymphonyElixir.SymphonyPlusPlus.Authorization.TargetTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Target

  test "canonical target constructors do not keep conflicting caller-supplied scope ids" do
    assert %Target{work_request_id: "wr-1"} = Target.work_request("wr-1", work_request_id: "wr-spoofed")

    assert %Target{work_request_id: "wr-1", work_package_id: "wrs-1"} =
             Target.work_package("wrs-1", "wr-1", work_request_id: "wr-spoofed", work_package_id: "wrs-spoofed")

    assert %Target{work_package_id: "wp-1"} = Target.work_package("wp-1", work_package_id: "wp-spoofed")

    assert %Target{work_package_id: "wp-1"} =
             Target.package_resource(:task_plan, "wp-1", work_package_id: "wp-spoofed")
  end
end
