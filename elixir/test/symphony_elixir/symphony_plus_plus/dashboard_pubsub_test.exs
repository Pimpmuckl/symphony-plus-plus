defmodule SymphonyElixir.SymphonyPlusPlus.DashboardPubSubTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub

  test "broadcast_changed notifies subscribers" do
    assert :ok = DashboardPubSub.subscribe()
    assert :ok = DashboardPubSub.broadcast_changed()
    assert_receive :operator_dashboard_changed
  end
end
