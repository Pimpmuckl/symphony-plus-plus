defmodule SymphonyElixir.SymphonyPlusPlus.Authorization.PolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Policy
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Target

  @architect_capabilities [
    "read:work_request",
    "write:work_request",
    "dispatch:work_request",
    "read:guidance_request",
    "write:guidance_request"
  ]

  test "worker can use package-scoped planning and evidence actions for its exact package" do
    actor = Actor.new(:worker, scopes: [Scope.work_package("wp-1")])
    target = Target.package_resource(:task_plan, "wp-1")

    assert %Decision{allowed?: true, reason_code: "allowed", matched_scope: %Scope{type: :work_package, id: "wp-1"}} =
             Policy.decide(actor, :task_plan_update, target)
  end

  test "worker cannot mutate sibling package targets" do
    actor = Actor.new(:worker, scopes: [Scope.work_package("wp-1")])
    target = Target.package_resource(:review_evidence, "wp-2")

    assert %Decision{
             allowed?: false,
             reason: :authorization_denied,
             reason_code: "scope_mismatch",
             legacy_reason: "outside_session_scope"
           } = Policy.decide(actor, :review_evidence_append, target)
  end

  test "worker package scope does not allow dispatch or dangerous actions" do
    actor = Actor.new(:worker, scopes: [Scope.work_package("wp-1")])
    target = Target.work_package("wrs-1", "wr-1", work_package_id: "wp-1")

    assert %Decision{allowed?: false, reason_code: "insufficient_role"} =
             Policy.decide(actor, :work_package_dispatch, target)

    assert %Decision{allowed?: false, reason_code: "dangerous_action_requires_operator"} =
             Policy.decide(actor, :dangerous_delete, Target.ledger())
  end

  test "architect can read scoped operational state but writes only claimed work request lineage" do
    actor = architect([Scope.work_request("wr-1"), Scope.repo("nextide/symphony-plus-plus", "main")])
    sibling_target = Target.work_request("wr-2", repo: "nextide/symphony-plus-plus", base_branch: "main")
    child_target = Target.work_package("wrs-1", "wr-1", work_package_id: "wp-1")

    assert %Decision{allowed?: true} = Policy.decide(actor, :work_request_read, sibling_target)

    assert %Decision{allowed?: true, matched_scope: %Scope{type: :work_request, id: "wr-1"}} =
             Policy.decide(actor, :work_package_update, child_target)

    assert %Decision{allowed?: false, reason_code: "scope_mismatch", legacy_reason: "outside_session_scope"} =
             Policy.decide(actor, :work_request_update, sibling_target)
  end

  test "architect repo read scope accepts trusted repo identity aliases without widening writes" do
    actor = architect([Scope.work_request("wr-1"), Scope.repo("symphony-plus-plus", "main")])

    trusted_alias_target =
      Target.work_request("wr-2",
        repo: "Pimpmuckl/symphony-plus-plus",
        base_branch: "main",
        metadata: %{repo_scope_trusted_remotes: ["https://github.com/Pimpmuckl/symphony-plus-plus.git"]}
      )

    trusted_alias_repo_target =
      Target.repo("Pimpmuckl/symphony-plus-plus", "main", metadata: %{repo_scope_trusted_remotes: ["https://github.com/Pimpmuckl/symphony-plus-plus.git"]})

    untrusted_alias_target =
      Target.work_request("wr-2",
        repo: "Pimpmuckl/symphony-plus-plus",
        base_branch: "main"
      )

    other_owner_target =
      Target.work_request("wr-3",
        repo: "Elsewhere/symphony-plus-plus",
        base_branch: "main",
        metadata: %{repo_scope_trusted_remotes: ["https://github.com/Pimpmuckl/symphony-plus-plus.git"]}
      )

    other_base_target =
      Target.work_request("wr-4",
        repo: "Pimpmuckl/symphony-plus-plus",
        base_branch: "release/wr-read",
        metadata: %{repo_scope_trusted_remotes: ["https://github.com/Pimpmuckl/symphony-plus-plus.git"]}
      )

    assert %Decision{allowed?: true, matched_scope: %Scope{type: :repo}} =
             Policy.decide(actor, :work_request_read, trusted_alias_target)

    assert %Decision{allowed?: true, matched_scope: %Scope{type: :repo}} =
             Policy.decide(actor, :work_request_read, trusted_alias_repo_target)

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(actor, :work_request_update, trusted_alias_target)

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(actor, :work_request_update, trusted_alias_repo_target)

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(actor, :work_request_read, untrusted_alias_target)

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(actor, :work_request_read, other_owner_target)

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(actor, :work_request_read, other_base_target)
  end

  test "architect reads and external comments deny without a matching scope" do
    actor = architect([Scope.work_request("wr-1")])
    sibling_target = Target.work_request("wr-2")

    assert %Decision{allowed?: false, reason_code: "scope_mismatch", legacy_reason: "outside_session_scope"} =
             Policy.decide(actor, :work_request_read, sibling_target)

    assert %Decision{allowed?: false, reason_code: "scope_mismatch", legacy_reason: "outside_session_scope"} =
             Policy.decide(actor, :external_comment_add, sibling_target)
  end

  test "repo scope alone does not authorize work request mutation" do
    actor = architect([Scope.repo("nextide/symphony-plus-plus", "main")])
    target = Target.work_request("wr-1", repo: "nextide/symphony-plus-plus", base_branch: "main")

    assert %Decision{allowed?: true, matched_scope: %Scope{type: :repo}} = Policy.decide(actor, :work_request_read, target)

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(actor, :work_request_update, target)
  end

  test "repo scope base branch must match when scope is branch pinned" do
    actor = architect([Scope.repo("nextide/symphony-plus-plus", "main")])

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(actor, :work_request_read, Target.work_request("wr-1", repo: "nextide/symphony-plus-plus"))

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(actor, :work_request_read, Target.work_request("wr-1", repo: "nextide/symphony-plus-plus", base_branch: "dev"))
  end

  test "explicit WorkRequest repo scopes allow multi-repo read without granting mutation" do
    target =
      Target.work_request("wr-multi",
        repo: "service-a",
        base_branch: "main",
        repo_scopes: [
          %{repo: "service-a", base_branch: "main"},
          %{repo: "service-b", base_branch: "release"}
        ]
      )

    assert %Decision{allowed?: true, matched_scope: %Scope{type: :repo, repo: "service-a"}} =
             Policy.decide(architect([Scope.repo("service-a", "main")]), :work_request_read, target)

    assert %Decision{allowed?: true, matched_scope: %Scope{type: :repo, repo: "service-b"}} =
             Policy.decide(architect([Scope.repo("service-b", "release")]), :work_request_read, target)

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(architect([Scope.repo("service-c", "main")]), :work_request_read, target)

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(architect([Scope.repo("service-b", "release")]), :work_request_update, target)
  end

  test "explicit WorkPackage scope authorizes WorkPackage actions only" do
    actor = architect([Scope.work_package("wrs-1")])
    target = Target.work_package("wrs-1", "wr-1")

    assert %Decision{allowed?: true, matched_scope: %Scope{type: :work_package, id: "wrs-1"}} =
             Policy.decide(actor, :work_package_update, target)

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(actor, :work_request_update, Target.work_request("wr-1"))
  end

  test "architect work package anchor authorizes package-scoped actions only" do
    actor = architect([Scope.work_package("wp-anchor")])

    assert %Decision{allowed?: true, matched_scope: %Scope{type: :work_package, id: "wp-anchor"}} =
             Policy.decide(actor, :task_plan_update, Target.package_resource(:task_plan, "wp-anchor"))

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(actor, :work_request_update, Target.work_request("wr-1"))
  end

  test "architect actions require migration capability metadata before scoped allow" do
    actor = Actor.new(:architect, scopes: [Scope.work_request("wr-1")], capabilities: [])

    assert %Decision{
             allowed?: false,
             reason_code: "insufficient_capability",
             legacy_reason: "insufficient_capability",
             requirements: [%{"capability" => "write:work_request"}]
           } = Policy.decide(actor, :work_request_update, Target.work_request("wr-1"))

    dispatch_actor = architect([Scope.work_request("wr-1")], ["write:work_request"])

    assert %Decision{allowed?: false, reason_code: "insufficient_capability"} =
             Policy.decide(dispatch_actor, :work_package_dispatch, Target.work_package("wrs-1", "wr-1"))
  end

  test "phase scope authorizes read discovery but not WorkRequest writes" do
    actor = architect([Scope.phase("phase-1", repo: "nextide/symphony-plus-plus", base_branch: "main")])

    assert %Decision{allowed?: true, matched_scope: %Scope{type: :phase, id: "phase-1"}} =
             Policy.decide(
               actor,
               :work_request_read,
               Target.work_request("wr-1", phase_id: "phase-1", repo: "nextide/symphony-plus-plus", base_branch: "main")
             )

    assert %Decision{allowed?: false, reason_code: "scope_mismatch", legacy_reason: "outside_session_scope"} =
             Policy.decide(
               actor,
               :work_package_dispatch,
               Target.work_package("wrs-1", "wr-1", phase_id: "phase-1", repo: "nextide/symphony-plus-plus", base_branch: "main")
             )
  end

  test "phase scope fails closed without matching frozen repo and base branch" do
    actor_without_snapshot = architect([Scope.phase("phase-1")])

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(
               actor_without_snapshot,
               :work_request_update,
               Target.work_request("wr-1", phase_id: "phase-1", repo: "nextide/symphony-plus-plus", base_branch: "main")
             )

    actor = architect([Scope.phase("phase-1", repo: "nextide/symphony-plus-plus", base_branch: "main")])

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(
               actor,
               :work_request_update,
               Target.work_request("wr-1", phase_id: "phase-1", repo: "nextide/symphony-plus-plus", base_branch: "dev")
             )
  end

  test "human operator ledger scope allows dangerous actions with audit marker" do
    actor = Actor.new(:human_operator, scopes: [Scope.ledger()])

    assert %Decision{
             allowed?: true,
             matched_scope: %Scope{type: :ledger},
             audit: %{dangerous_action: true, authority: "operator"}
           } = Policy.decide(actor, :dangerous_rekey, Target.ledger())
  end

  test "explicit human-granted ledger authority allows dangerous actions without changing role" do
    actor = architect([Scope.ledger(metadata: %{human_granted: true})])

    assert %Decision{
             allowed?: true,
             matched_scope: %Scope{type: :ledger},
             audit: %{dangerous_action: true, authority: "explicit_human_grant"}
           } = Policy.decide(actor, :dangerous_raw_repair, Target.ledger())
  end

  test "ledger scope alone does not grant dangerous action authority to ordinary actors" do
    actor = architect([Scope.ledger()])

    assert %Decision{allowed?: false, reason_code: "dangerous_action_requires_operator"} =
             Policy.decide(actor, :dangerous_override, Target.ledger())
  end

  test "policy represents precondition and lifecycle denials with stable reason codes" do
    actor = architect([Scope.work_request("wr-1")])

    assert %Decision{allowed?: false, reason: :precondition_denied, reason_code: "target_not_found"} =
             Policy.decide(actor, :work_request_update, Target.new(:work_request, "wr-missing", resolution: :not_found))

    assert %Decision{allowed?: false, reason: :precondition_denied, reason_code: "runtime_lease_conflict"} =
             Policy.decide(actor, :work_package_update, Target.new(:work_package, "wp-1", resolution: :runtime_lease_conflict))

    assert %Decision{allowed?: false, reason: :lifecycle_denied, reason_code: "invalid_transition"} =
             Policy.decide(actor, :work_package_update, Target.work_package("wp-1"), lifecycle_denial: :invalid_transition)
  end

  defp architect(scopes, capabilities \\ @architect_capabilities) do
    Actor.new(:architect, scopes: scopes, capabilities: capabilities)
  end
end
