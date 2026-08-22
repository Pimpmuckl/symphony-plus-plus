defmodule SymphonyElixir.SymphonyPlusPlus.LifecycleTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Repository, as: GuidanceRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Policies.Templates
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(GuidanceRequest)
    repo.delete_all(ProgressEvent)
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "allowed worker package transitions pass for quick work templates", %{repo: repo} do
    for kind <- ["quick_fix", "hotfix", "docs", "investigation"] do
      assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: kind))

      for status <- [
            "ready_for_worker",
            "active",
            "ready_for_merge"
          ] do
        assert {:ok, package} = Service.transition(repo, package.id, status, worker_actor!(repo, package))
        assert package.status == status
      end
    end
  end

  test "invalid worker package transitions fail for quick work templates", %{repo: repo} do
    for kind <- ["quick_fix", "hotfix", "docs", "investigation"] do
      assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: kind))

      assert {:error, :invalid_transition} =
               Service.transition(repo, package.id, "merged", architect_actor!(repo, package))

      assert {:ok, fetched} = Repository.get(repo, package.id)
      assert fetched.status == "created"
    end
  end

  test "policy templates expand into deterministic constraints and provider-backed gates" do
    assert {:ok, quick_fix} = Templates.expand("quick_fix")
    assert quick_fix.constraints.expiry_seconds == nil
    assert quick_fix.constraints.planning_depth == "brief"
    assert quick_fix.constraints.terminal_readiness_status == "ready_for_merge"

    assert {:ok, hotfix} = Templates.expand("hotfix")
    assert hotfix.constraints.expiry_seconds == nil
    assert hotfix.required_gates == ["human_merge"]
    assert hotfix.constraints.terminal_readiness_status == "ready_for_merge"

    assert {:ok, docs} = Templates.expand("docs")
    assert docs.constraints.expiry_seconds == nil
    assert docs.constraints.planning_depth == "brief"
    assert docs.constraints.terminal_readiness_status == "ready_for_merge"

    assert {:ok, phase_child} = Templates.expand("phase_child")
    assert phase_child.constraints.expiry_seconds == nil
    assert phase_child.constraints.planning_depth == "package"
    assert phase_child.constraints.terminal_readiness_status == "ready_for_architect_merge"

    assert {:ok, investigation} = Templates.expand("investigation")
    assert investigation.constraints.expiry_seconds == nil
    assert investigation.constraints.planning_depth == "findings"
    assert investigation.required_gates == ["findings_documented"]

    for kind <- ["mcp", "skill", "hooks"] do
      assert {:ok, policy} = Templates.expand(kind)
      assert policy.template == "worker_package"
      refute Map.has_key?(policy, :review_suite)
      assert policy.constraints.terminal_readiness_status == "ready_for_merge"
    end

    assert {:ok, current_pr_state_policy} = Templates.expand("mcp_current_pr_state")
    assert current_pr_state_policy.template == "worker_package"
    assert "current_pr_state" in current_pr_state_policy.required_gates

    assert {:ok, scope_guard_policy} = Templates.expand("mcp_changed_file_scope_guard")
    assert scope_guard_policy.template == "worker_package"
    assert "current_pr_state" in scope_guard_policy.required_gates
    assert "scope_guard" in scope_guard_policy.required_gates
  end

  test "policy can be computed from a persisted work package", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: "phase_child", parent_id: "phase-1"))

    assert {:ok, policy} = Service.policy_for(repo, package.id)
    assert policy.template == "phase_child"
    assert policy.constraints.terminal_readiness_status == "ready_for_architect_merge"
  end

  test "hotfix and phase child have different terminal readiness states" do
    assert {:ok, hotfix_policy} = Templates.expand("hotfix")
    assert {:ok, phase_child_policy} = Templates.expand("phase_child")

    assert hotfix_policy.constraints.terminal_readiness_status == "ready_for_merge"
    assert phase_child_policy.constraints.terminal_readiness_status == "ready_for_architect_merge"
  end

  test "worker capability cannot transition to merged", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: "hotfix", status: "ready_for_merge"))

    assert {:error, :worker_cannot_mark_merged} = Service.transition(repo, package.id, "merged", worker_actor!(repo, package))
  end

  test "hotfix happy path reaches ready for human merge", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: "hotfix"))

    assert {:ok, package} = Service.transition(repo, package.id, "ready_for_worker", worker_actor!(repo, package))
    assert {:ok, package} = Service.transition(repo, package.id, "active", worker_actor!(repo, package))
    assert {:ok, package} = Service.transition(repo, package.id, "ready_for_merge", worker_actor!(repo, package))

    assert package.status == "ready_for_merge"
  end

  test "phase child happy path reaches ready for architect merge", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: "phase_child", parent_id: "phase-1"))

    assert {:ok, package} = Service.transition(repo, package.id, "ready_for_worker", worker_actor!(repo, package))
    assert {:ok, package} = Service.transition(repo, package.id, "active", worker_actor!(repo, package))
    assert {:ok, package} = Service.transition(repo, package.id, "ready_for_architect_merge", worker_actor!(repo, package))

    assert package.status == "ready_for_architect_merge"
  end

  test "does not allow created to merged", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: "hotfix"))

    assert {:error, :invalid_transition} = Service.transition(repo, package.id, "merged", architect_actor!(repo, package))
  end

  test "does not allow worker to advance phase state", %{repo: repo} do
    assert {:ok, package} =
             Repository.create(
               repo,
               WorkPackageFactory.attrs(
                 kind: "phase_child",
                 parent_id: "phase-1",
                 status: "ready_for_architect_merge"
               )
             )

    assert {:error, :worker_cannot_advance_phase_state} =
             Service.transition(repo, package.id, "merging_into_phase", worker_actor!(repo, package))

    assert {:ok, package} = Service.transition(repo, package.id, "merging_into_phase", architect_actor!(repo, package))
    assert package.status == "merging_into_phase"
  end

  test "phase child merged into phase is terminal", %{repo: repo} do
    assert {:ok, package} =
             Repository.create(
               repo,
               WorkPackageFactory.attrs(
                 kind: "phase_child",
                 parent_id: "phase-1",
                 status: "merged_into_phase"
               )
             )

    assert {:error, :invalid_transition} = Service.transition(repo, package.id, "merged", architect_actor!(repo, package))
  end

  test "worker package merged remains a known terminal lifecycle status", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: "hotfix", status: "merged"))

    assert {:error, :invalid_transition} = Service.transition(repo, package.id, "closed", architect_actor!(repo, package))
  end

  test "terminal transition clears only the package's human-action residue and replays idempotently", %{repo: repo} do
    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(kind: "hotfix", status: "ready_for_merge"))

    assert {:ok, sibling} = Repository.create(repo, WorkPackageFactory.attrs(kind: "hotfix", status: "reviewing"))
    actor = architect_actor!(repo, package)

    assert {:ok, guidance} =
             GuidanceRequestRepository.create(repo, %{
               work_package_id: package.id,
               requester_grant_id: actor.grant_id,
               requested_by: "architect-1",
               idempotency_key: "terminal-guidance",
               summary: "Need a decision",
               question: "Which closeout path should be used?",
               context: "Terminal cleanup regression"
             })

    append_active_blocker!(repo, package.id, "terminal-blocker")
    append_active_blocker!(repo, sibling.id, "nonterminal-blocker")

    assert {:ok, _targeted_blocker} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: sibling.id,
               summary: "Terminal package is blocked",
               status: "blocked",
               idempotency_key: "report:terminal-target-blocker",
               payload: %{
                 type: "blocker",
                 source_tool: "report_blocker",
                 blocker_id: "terminal-target-blocker",
                 active: true,
                 blocked_item: %{kind: "work_package", id: package.id}
               }
             })

    assert {:ok, _outbound_blocker} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Sibling package is blocked",
               status: "blocked",
               idempotency_key: "report:sibling-target-blocker",
               payload: %{
                 type: "blocker",
                 source_tool: "report_blocker",
                 blocker_id: "sibling-target-blocker",
                 active: true,
                 blocked_item: %{kind: "work_package", id: sibling.id}
               }
             })

    assert {:ok, terminal} = Service.transition(repo, package.id, "merged", actor)
    assert repo.get!(GuidanceRequest, guidance.id).status == "answered"

    terminal_blocker_state = WorkPackageActivity.context(repo, package.id).blocker_state
    assert terminal_blocker_state.active?
    assert terminal_blocker_state.active_ids == ["sibling-target-blocker"]

    sibling_blocker_state = WorkPackageActivity.context(repo, sibling.id).blocker_state
    assert sibling_blocker_state.active?
    assert sibling_blocker_state.active_ids == ["nonterminal-blocker"]

    terminal_event_count = repo.aggregate(ProgressEvent, :count, :id)
    assert :ok = Repository.clear_terminal_attention(repo, terminal)
    assert repo.aggregate(ProgressEvent, :count, :id) == terminal_event_count
  end

  test "transition rejects phase child corrupted to worker package merged status", %{repo: repo} do
    package = insert_raw_package!(repo, kind: "phase_child", status: "merged", parent_id: "phase-1")

    assert {:error, :unknown_lifecycle_status} = Service.transition(repo, package.id, "closed", architect_actor!(repo, package))
  end

  test "transition requires explicit lifecycle capability", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: "hotfix"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id, capabilities: ["worker:claim"])
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    assert {:error, :missing_lifecycle_capability} =
             Service.transition(repo, package.id, "ready_for_worker", Map.from_struct(assignment))
  end

  test "default claimed worker assignment can drive lifecycle transition", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: "hotfix"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    assert {:ok, transitioned} = Service.transition(repo, package.id, "ready_for_worker", Map.from_struct(assignment))
    assert transitioned.status == "ready_for_worker"
  end

  test "worker assignment cannot transition a sibling work package", %{repo: repo} do
    assert {:ok, first} = Repository.create(repo, WorkPackageFactory.attrs(kind: "hotfix", title: "First"))
    assert {:ok, second} = Repository.create(repo, WorkPackageFactory.attrs(kind: "hotfix", title: "Second"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, first.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    assert {:error, :actor_scope_mismatch} =
             Service.transition(repo, second.id, "ready_for_worker", Map.from_struct(assignment))

    assert {:ok, fetched} = Repository.get(repo, second.id)
    assert fetched.status == "created"
  end

  test "worker actor payload cannot self-assert package scope", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: "hotfix"))

    assert {:error, :actor_scope_mismatch} =
             Service.transition(repo, package.id, "ready_for_worker", %{
               grant_role: "worker",
               capabilities: ["worker:lifecycle.transition"],
               work_package_id: package.id
             })
  end

  test "worker grant payload cannot forge architect role", %{repo: repo} do
    assert {:ok, package} =
             Repository.create(
               repo,
               WorkPackageFactory.attrs(
                 kind: "phase_child",
                 parent_id: "phase-1",
                 status: "ready_for_architect_merge"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    forged_actor =
      assignment
      |> Map.from_struct()
      |> Map.merge(%{grant_role: "architect", capabilities: ["architect:lifecycle.transition"]})

    assert {:error, :worker_cannot_advance_phase_state} =
             Service.transition(repo, package.id, "merging_into_phase", forged_actor)
  end

  test "grantless actor cannot self-assert architect capability", %{repo: repo} do
    assert {:ok, package} =
             Repository.create(
               repo,
               WorkPackageFactory.attrs(
                 kind: "phase_child",
                 parent_id: "phase-1",
                 status: "ready_for_architect_merge"
               )
             )

    assert {:error, :actor_scope_mismatch} =
             Service.transition(repo, package.id, "merging_into_phase", %{
               grant_role: "architect",
               capabilities: ["architect:lifecycle.transition"]
             })
  end

  test "state machine rejects malformed capability payloads without crashing", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: "hotfix"))

    assert {:error, :missing_lifecycle_capability} =
             StateMachine.validate_transition(package, "ready_for_worker", %{
               grant_role: "worker",
               capabilities: "worker:lifecycle.transition",
               work_package_id: package.id
             })
  end

  test "transition supports declared dispatchable lifecycle kinds", %{repo: repo} do
    package = insert_raw_package!(repo, kind: "mcp", status: "created")

    assert {:ok, updated} = Service.transition(repo, package.id, "ready_for_worker", worker_actor!(repo, package))
    assert updated.status == "ready_for_worker"
  end

  test "transition rejects unknown lifecycle kinds", %{repo: repo} do
    package = insert_raw_package!(repo, kind: "legacy_kind", status: "created")

    assert {:error, :unsupported_kind} = Service.transition(repo, package.id, "ready_for_worker", worker_actor!(repo, package))
  end

  test "transition rejects unknown persisted lifecycle statuses", %{repo: repo} do
    package = insert_raw_package!(repo, kind: "hotfix", status: "legacy_status")

    assert {:error, :unknown_lifecycle_status} = Service.transition(repo, package.id, "ready_for_worker", worker_actor!(repo, package))
  end

  test "transition rejects cross-kind persisted lifecycle statuses", %{repo: repo} do
    package = insert_raw_package!(repo, kind: "hotfix", status: "ready_for_architect_merge")

    assert {:error, :unknown_lifecycle_status} =
             Service.transition(repo, package.id, "merging_into_phase", architect_actor!(repo, package))
  end

  test "status updates are conditional on the validated current status", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: "hotfix", status: "reviewing"))

    assert {:ok, updated} = Repository.update_status(repo, package.id, "reviewing", "ci_waiting")
    assert updated.status == "ci_waiting"

    assert {:error, :stale_status} = Repository.update_status(repo, package.id, "reviewing", "implementing")
    assert {:ok, fetched} = Repository.get(repo, package.id)
    assert fetched.status == "ci_waiting"
  end

  test "snapshot transitions fail when the stored status has changed", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: "hotfix", status: "reviewing"))
    actor = worker_actor!(repo, package)

    assert {:ok, updated} = Repository.update_status(repo, package.id, "reviewing", "ci_waiting")
    assert updated.status == "ci_waiting"

    assert {:error, :stale_status} = Service.transition(repo, package, "ci_waiting", actor)
    assert {:ok, fetched} = Repository.get(repo, package.id)
    assert fetched.status == "ci_waiting"
  end

  test "conditional status update rejects unknown statuses before writing", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: "hotfix", status: "reviewing"))

    assert {:error, :invalid_status} = Repository.update_status(repo, package.id, "reviewing", "definitely_done")
    assert {:ok, fetched} = Repository.get(repo, package.id)
    assert fetched.status == "reviewing"
  end

  defp insert_raw_package!(repo, attrs) do
    now = DateTime.utc_now(:microsecond)
    attrs = WorkPackageFactory.attrs(attrs)

    repo.insert!(%WorkPackage{
      id: "raw-#{System.unique_integer([:positive])}",
      kind: attrs.kind,
      title: attrs.title,
      repo: attrs.repo,
      base_branch: attrs.base_branch,
      branch_pattern: attrs.branch_pattern,
      product_description: attrs.product_description,
      engineering_scope: attrs.engineering_scope,
      acceptance_criteria: attrs.acceptance_criteria,
      status: attrs.status,
      parent_id: attrs.parent_id,
      owner_id: attrs.owner_id,
      inserted_at: now,
      updated_at: now
    })
  end

  defp worker_actor!(repo, package) do
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    Map.from_struct(assignment)
  end

  defp append_active_blocker!(repo, work_package_id, blocker_id) do
    assert {:ok, _event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package_id,
               summary: "Blocked by #{blocker_id}",
               status: "blocked",
               idempotency_key: "report:#{blocker_id}",
               payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: blocker_id, active: true}
             })
  end

  defp architect_actor!(repo, package) do
    now = DateTime.utc_now(:microsecond)
    work_key = WorkKey.generate()

    assert {:ok, _grant} =
             AccessGrantRepository.create(repo, %{
               work_package_id: package.id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["architect:lifecycle.transition"],
               expires_at: DateTime.add(now, 3_600, :second)
             })

    assert {:ok, assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: "architect-1"}, now)

    Map.from_struct(assignment)
  end
end
