defmodule SymphonyElixir.SymphonyPlusPlus.Authorization.MCPErrorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Target

  test "allowed decisions do not produce MCP errors" do
    decision = Decision.allow(Actor.new(:worker, scopes: [Scope.work_package("wp-1")]), :task_plan_read, Target.work_package("wp-1"))

    assert MCPError.from_decision(decision, "read_task_plan") == :ok
  end

  test "authorization denials preserve legacy reason and expose stable reason code" do
    decision =
      Decision.authorization_denied(
        Actor.new(:worker, scopes: [Scope.work_package("wp-1")]),
        :task_plan_update,
        Target.work_package("wp-2"),
        :scope_mismatch,
        legacy_reason: "outside_session_scope"
      )

    assert {:error, -32_003, "Forbidden", data} = MCPError.from_decision(decision, "update_task_plan")
    assert data["reason"] == "outside_session_scope"
    assert data["legacy_reason"] == "outside_session_scope"
    assert data["reason_code"] == "scope_mismatch"
    assert data["decision_reason"] == "authorization_denied"
    assert data["target"]["work_package_id"] == "wp-2"
  end

  test "precondition and lifecycle denials use distinct MCP error categories" do
    actor = Actor.new(:architect, scopes: [Scope.work_request("wr-1")])

    precondition = Decision.precondition_denied(actor, :work_request_update, Target.work_request("wr-missing"), :target_not_found)
    lifecycle = Decision.lifecycle_denied(actor, :work_package_update, Target.work_package("wp-1"), :invalid_transition)

    assert {:error, -32_009, "Precondition Failed", %{"reason_code" => "target_not_found"}} =
             MCPError.from_decision(precondition, "update_work_request")

    assert {:error, -32_010, "Lifecycle Denied", %{"reason_code" => "invalid_transition"}} =
             MCPError.from_decision(lifecycle, "set_status")
  end

  test "MCP error conversion redacts secret-shaped details" do
    raw_secret = "wk_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"

    decision =
      Decision.authorization_denied(
        Actor.new(:worker, scopes: [Scope.work_package("wp-1")]),
        :review_evidence_append,
        Target.work_package("wp-2", metadata: %{secret: raw_secret}),
        :scope_mismatch,
        requirements: [%{token: "ghp_abcdefghijklmnopqrstuvwxyz"}],
        redactions: ["never include bearer abcdefghijklmnop"],
        legacy_reason: "outside_session_scope"
      )

    assert {:error, -32_003, "Forbidden", data} = MCPError.from_decision(decision, "append_progress")
    refute inspect(data) =~ raw_secret
    refute inspect(data) =~ "ghp_abcdefghijklmnopqrstuvwxyz"
    refute inspect(data) =~ "bearer abcdefghijklmnop"
    assert inspect(data) =~ "[REDACTED]"
  end
end
