Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.PhaseArchitectTools02Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "child worker key minting ignores normal worker grants when checking active child mint", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-NORMAL-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-NORMAL-CHILD")

    assert {:ok, pending_normal} = AccessGrantService.mint_worker_grant(repo, child_id)
    assert pending_normal.grant.provenance == nil

    assert {:ok, claimed_normal} = AccessGrantService.mint_worker_grant(repo, child_id)
    assert claimed_normal.grant.provenance == nil
    assert {:ok, _normal_assignment} = AccessGrantService.claim(repo, claimed_normal.work_key.secret, claimed_by: "normal-worker")

    mint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id
      })

    child_worker_grant_id = get_in(mint_response, ["result", "structuredContent", "worker_grant", "id"])
    assert is_binary(child_worker_grant_id)

    assert {:ok, child_worker_grant} = AccessGrantRepository.get(repo, child_worker_grant_id)
    assert child_worker_grant.provenance == @child_worker_grant_provenance

    remint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id
      })

    assert get_in(remint_response, ["error", "code"]) == -32_602
    assert get_in(remint_response, ["error", "data", "reason"]) == "active_child_worker_grant_exists"

    assert {:ok, pending_normal_grant} = AccessGrantRepository.get(repo, pending_normal.grant.id)
    assert pending_normal_grant.revoked_at == nil
    assert pending_normal_grant.claimed_at == nil
    assert pending_normal_grant.provenance == nil

    assert {:ok, claimed_normal_grant} = AccessGrantRepository.get(repo, claimed_normal.grant.id)
    assert claimed_normal_grant.revoked_at == nil
    assert %DateTime{} = claimed_normal_grant.claimed_at
    assert claimed_normal_grant.provenance == nil

    assert {:ok, active_child_worker_grant} = AccessGrantRepository.get(repo, child_worker_grant_id)
    assert active_child_worker_grant.revoked_at == nil
    assert active_child_worker_grant.claimed_at == nil
    assert active_child_worker_grant.provenance == @child_worker_grant_provenance
  end

  test "child worker key minting rejects remint while active child worker grant exists", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-DUPLICATE-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-DUPLICATE-CHILD")

    first_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id
      })

    first_grant_id = get_in(first_response, ["result", "structuredContent", "worker_grant", "id"])
    assert is_binary(first_grant_id)
    assert get_in(first_response, ["result", "structuredContent", "worker_grant", "secret_in_response"]) == false
    grants_before_remint = repo.aggregate(AccessGrant, :count)

    second_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id
      })

    assert get_in(second_response, ["error", "code"]) == -32_602
    assert get_in(second_response, ["error", "data", "reason"]) == "active_child_worker_grant_exists"
    assert repo.aggregate(AccessGrant, :count) == grants_before_remint

    assert {:ok, first_grant} = AccessGrantRepository.get(repo, first_grant_id)
    assert first_grant.provenance == @child_worker_grant_provenance
    assert first_grant.revoked_at == nil
    assert first_grant.claimed_at == nil

    _worker_session = claim_child_worker_from_mint_response(repo, first_response, "sympp-child-worker:#{child_id}")
    grants_before_claimed_remint = repo.aggregate(AccessGrant, :count)

    third_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id
      })

    assert get_in(third_response, ["error", "code"]) == -32_602
    assert get_in(third_response, ["error", "data", "reason"]) == "active_child_worker_grant_exists"
    assert repo.aggregate(AccessGrant, :count) == grants_before_claimed_remint

    assert {:ok, claimed_grant} = AccessGrantRepository.get(repo, first_grant_id)
    assert claimed_grant.revoked_at == nil
    assert %DateTime{} = claimed_grant.claimed_at
    assert claimed_grant.provenance == @child_worker_grant_provenance
  end

  test "phase architect revokes child worker grant and can remint same child", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-RECYCLE-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "revoke:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-RECYCLE-CHILD")

    first_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id
      })

    first_grant_id = get_in(first_response, ["result", "structuredContent", "worker_grant", "id"])
    assert is_binary(first_grant_id)
    assert {:ok, first_grant_before_revoke} = AccessGrantRepository.get(repo, first_grant_id)
    assert first_grant_before_revoke.revoked_at == nil
    assert first_grant_before_revoke.provenance == @child_worker_grant_provenance

    revoke_response =
      mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
        "grant_id" => first_grant_id,
        "reason" => "worker lost heartbeat"
      })

    revoked_grant = get_in(revoke_response, ["result", "structuredContent", "revoked_worker_grant"])
    assert revoked_grant["id"] == first_grant_id
    assert revoked_grant["work_package_id"] == child_id
    assert revoked_grant["secret_in_response"] == false
    assert is_binary(revoked_grant["revoked_at"])
    refute Map.has_key?(revoked_grant, "display_key")
    refute Map.has_key?(revoked_grant, "secret")
    refute Map.has_key?(revoked_grant, "secret_hash")
    refute Map.has_key?(revoked_grant, "secret_returned_once")

    recycle = get_in(revoke_response, ["result", "structuredContent", "recycle"])
    assert recycle["status"] == "revoked"
    assert recycle["reason"] == "worker lost heartbeat"
    assert recycle["previous_child_status"] == "ready_for_worker"
    assert recycle["new_child_status"] == "ready_for_worker"
    assert recycle["status_reset"] == false
    assert recycle["remint_available"] == true
    assert recycle["lifecycle_state"] == "recycled"
    assert recycle["reason_codes"] == ["worker_recycled"]

    event = get_in(revoke_response, ["result", "structuredContent", "revocation_event"])
    assert event["status"] == "child_worker_key_revoked"
    assert event["payload"]["type"] == "child_worker_key_revoke"
    assert event["payload"]["source_tool"] == "revoke_child_worker_key"
    assert event["payload"]["work_package_id"] == child_id
    assert event["payload"]["grant_id"] == first_grant_id
    assert event["payload"]["reason"] == "worker lost heartbeat"
    assert event["payload"]["previous_status"] == "ready_for_worker"
    assert event["payload"]["new_status"] == "ready_for_worker"
    assert event["payload"]["status_reset"] == false
    assert event["payload"]["lifecycle_state"] == "recycled"
    assert event["payload"]["reason_codes"] == ["worker_recycled"]

    content_text = get_in(revoke_response, ["result", "content", Access.at(0), "text"])
    refute content_text =~ "display_key"
    refute content_text =~ "secret_hash"
    refute content_text =~ "secret_returned_once"

    assert {:ok, first_grant_after_revoke} = AccessGrantRepository.get(repo, first_grant_id)
    assert %DateTime{} = first_grant_after_revoke.revoked_at

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, child_id)
    assert Enum.any?(progress_events, &(&1.status == "child_worker_key_revoked" and &1.payload["grant_id"] == first_grant_id))

    second_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id
      })

    second_grant_id = get_in(second_response, ["result", "structuredContent", "worker_grant", "id"])
    assert is_binary(second_grant_id)
    assert second_grant_id != first_grant_id
    assert get_in(second_response, ["result", "structuredContent", "worker_grant", "work_package_id"]) == child_id
  end

  test "phase architect revokes in-progress child worker grant, resets child, and remints", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-RECYCLE-RESET-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "revoke:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-RECYCLE-RESET-CHILD")

    first_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => %{"claimed_by" => "worker-1"}
      })

    first_grant_id = get_in(first_response, ["result", "structuredContent", "worker_grant", "id"])
    assert is_binary(first_grant_id)

    worker_session = claim_child_worker_from_mint_response(repo, first_response, "worker-1")
    assert_child_worker_active(repo, worker_session)

    assert {:ok, in_progress_child} = WorkPackageRepository.get(repo, child_id)
    assert in_progress_child.status == "active"

    revoke_response =
      mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
        "grant_id" => first_grant_id,
        "reason" => "worker died during implementation"
      })

    assert get_in(revoke_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_worker"

    recycle = get_in(revoke_response, ["result", "structuredContent", "recycle"])
    assert recycle["status"] == "revoked"
    assert recycle["previous_child_status"] == "active"
    assert recycle["new_child_status"] == "ready_for_worker"
    assert recycle["status_reset"] == true
    assert recycle["remint_available"] == true
    assert recycle["reason_codes"] == ["worker_recycled", "work_package_reset_for_recycle"]

    event = get_in(revoke_response, ["result", "structuredContent", "revocation_event"])
    assert event["payload"]["grant_id"] == first_grant_id
    assert event["payload"]["previous_status"] == "active"
    assert event["payload"]["new_status"] == "ready_for_worker"
    assert event["payload"]["status_reset"] == true
    assert event["payload"]["reason_codes"] == ["worker_recycled", "work_package_reset_for_recycle"]

    assert {:ok, reset_child} = WorkPackageRepository.get(repo, child_id)
    assert reset_child.status == "ready_for_worker"

    second_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id
      })

    second_grant_id = get_in(second_response, ["result", "structuredContent", "worker_grant", "id"])
    assert is_binary(second_grant_id)
    assert second_grant_id != first_grant_id

    stale_worker_response =
      mcp_tool(repo, worker_session, "report_blocker", %{
        "summary" => "stale worker should not mutate recycled child",
        "idempotency_key" => "stale-worker-blocker"
      })

    assert get_in(stale_worker_response, ["error", "code"]) == -32_001
    assert get_in(stale_worker_response, ["error", "data", "reason"]) == "revoked"

    assert {:ok, child_after_stale_worker_attempt} = WorkPackageRepository.get(repo, child_id)
    assert child_after_stale_worker_attempt.status == "ready_for_worker"
  end

  test "child worker revoke rejects normal grants and worker callers", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-REVOKE-NORMAL-ANCHOR", [
        "create:child_work_package",
        "revoke:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-REVOKE-NORMAL-CHILD")

    invalid_grant_id_response =
      mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
        "grant_id" => 123,
        "reason" => "invalid grant id"
      })

    assert get_in(invalid_grant_id_response, ["error", "code"]) == -32_602
    assert get_in(invalid_grant_id_response, ["error", "data", "reason"]) == "invalid_grant_id"

    invalid_reason_response =
      mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
        "grant_id" => "grant-id",
        "reason" => 123
      })

    assert get_in(invalid_reason_response, ["error", "code"]) == -32_602
    assert get_in(invalid_reason_response, ["error", "data", "reason"]) == "invalid_reason"

    assert {:ok, normal_minted} = AccessGrantService.mint_worker_grant(repo, child_id)

    normal_revoke_response =
      mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
        "grant_id" => normal_minted.grant.id,
        "reason" => "not a child-worker grant"
      })

    assert get_in(normal_revoke_response, ["error", "code"]) == -32_602
    assert get_in(normal_revoke_response, ["error", "data", "reason"]) == "not_child_worker_grant"

    assert {:ok, normal_grant_after_revoke_attempt} = AccessGrantRepository.get(repo, normal_minted.grant.id)
    assert normal_grant_after_revoke_attempt.revoked_at == nil

    assert {:ok, worker_minted} = AccessGrantService.mint_worker_grant(repo, child_id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, worker_minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: worker_minted.grant.secret_hash)

    worker_revoke_response =
      mcp_tool(repo, worker_session, "revoke_child_worker_key", %{
        "grant_id" => normal_minted.grant.id,
        "reason" => "worker caller denied"
      })

    assert get_in(worker_revoke_response, ["error", "code"]) == -32_001
    assert get_in(worker_revoke_response, ["error", "data", "reason"]) == "architect_grant_required"
  end

  test "child worker revoke rejects sibling and stale child grants", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-REVOKE-SCOPE-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "revoke:child_worker_key",
        "read:phase"
      ])

    {_other_anchor, other_architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-REVOKE-SCOPE-OTHER", [
        "revoke:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-REVOKE-SCOPE-CHILD")

    mint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id
      })

    grant_id = get_in(mint_response, ["result", "structuredContent", "worker_grant", "id"])
    assert is_binary(grant_id)

    sibling_revoke_response =
      mcp_tool(repo, other_architect_session, "revoke_child_worker_key", %{
        "grant_id" => grant_id,
        "reason" => "sibling denied"
      })

    assert get_in(sibling_revoke_response, ["error", "code"]) == -32_003
    assert get_in(sibling_revoke_response, ["error", "data", "reason"]) == "outside_session_scope"

    assert {:ok, grant_after_sibling_attempt} = AccessGrantRepository.get(repo, grant_id)
    assert grant_after_sibling_attempt.revoked_at == nil
  end

  test "child worker revoke rejects already revoked and expired grants", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-REVOKE-STALE-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "revoke:child_worker_key",
        "read:phase"
      ])

    revoked_child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-REVOKE-STALE-REVOKED")

    revoked_mint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => revoked_child_id
      })

    revoked_grant_id = get_in(revoked_mint_response, ["result", "structuredContent", "worker_grant", "id"])
    assert {:ok, _revoked_grant} = AccessGrantRepository.revoke(repo, revoked_grant_id, DateTime.utc_now(:microsecond))

    already_revoked_response =
      mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
        "grant_id" => revoked_grant_id,
        "reason" => "second revoke denied"
      })

    assert get_in(already_revoked_response, ["error", "code"]) == -32_602
    assert get_in(already_revoked_response, ["error", "data", "reason"]) == "child_worker_grant_already_revoked"

    expired_child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-REVOKE-STALE-EXPIRED")

    expired_mint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => expired_child_id
      })

    expired_grant_id = get_in(expired_mint_response, ["result", "structuredContent", "worker_grant", "id"])
    expired_at = DateTime.add(DateTime.utc_now(:microsecond), -60, :second)

    assert {1, _rows} =
             repo.update_all(
               from(grant in AccessGrant, where: grant.id == ^expired_grant_id),
               set: [expires_at: expired_at, updated_at: DateTime.utc_now(:microsecond)]
             )

    expired_revoke_response =
      mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
        "grant_id" => expired_grant_id,
        "reason" => "expired denied"
      })

    assert get_in(expired_revoke_response, ["error", "code"]) == -32_602
    assert get_in(expired_revoke_response, ["error", "data", "reason"]) == "child_worker_grant_expired"

    assert {:ok, expired_grant_after_revoke_attempt} = AccessGrantRepository.get(repo, expired_grant_id)
    assert expired_grant_after_revoke_attempt.revoked_at == nil
  end

  test "child worker revoke rejects architect-controlled child statuses", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-REVOKE-STATUS-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "revoke:child_worker_key",
        "read:phase"
      ])

    for status <- ["ready_for_architect_merge", "merging_into_phase", "merged_into_phase", "closed", "abandoned"] do
      suffix = status |> String.replace("_", "-") |> String.upcase()
      child_id = "SYMPP-P7-002-REVOKE-STATUS-#{suffix}"
      child_id = create_child_work_package(repo, architect_session, child_id)

      mint_response =
        mcp_tool(repo, architect_session, "mint_child_worker_key", %{
          "work_package_id" => child_id
        })

      grant_id = get_in(mint_response, ["result", "structuredContent", "worker_grant", "id"])
      assert is_binary(grant_id)
      assert {:ok, _updated_child} = WorkPackageRepository.update(repo, child_id, %{status: status})

      response =
        mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
          "grant_id" => grant_id,
          "reason" => "status denied"
        })

      assert get_in(response, ["error", "code"]) == -32_602
      assert get_in(response, ["error", "data", "reason"]) == "child_not_recyclable"

      assert {:ok, grant_after_revoke_attempt} = AccessGrantRepository.get(repo, grant_id)
      assert grant_after_revoke_attempt.revoked_at == nil
    end
  end

  test "child worker key minting rejects broader grants and worker callers", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-BROADER-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-BROADER-CHILD")

    broader_capability_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => %{"capabilities" => ["worker:claim", "read:phase"]}
      })

    assert get_in(broader_capability_response, ["error", "code"]) == -32_602
    assert get_in(broader_capability_response, ["error", "data", "reason"]) == "broader_child_grant"

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, child_id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: minted.grant.secret_hash)

    worker_mint_response =
      mcp_tool(repo, worker_session, "mint_child_worker_key", %{
        "work_package_id" => child_id
      })

    assert get_in(worker_mint_response, ["error", "code"]) == -32_001
    assert get_in(worker_mint_response, ["error", "data", "reason"]) == "architect_grant_required"
  end

  test "child worker key minting validates its remaining template keys narrowly", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-HANDOFF-TEMPLATE-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-HANDOFF-TEMPLATE-CHILD")

    invalid_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => %{"claimed_by" => "  "}
      })

    assert get_in(invalid_response, ["error", "code"]) == -32_602
    assert get_in(invalid_response, ["error", "data", "reason"]) == "invalid_claimed_by"

    unexpected_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => %{"env_var" => "SYMPP_OTHER_SECRET"}
      })

    assert get_in(unexpected_response, ["error", "code"]) == -32_602
    assert get_in(unexpected_response, ["error", "data", "reason"]) == "unexpected_template_field"
    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, child_id)
    assert active_worker_grants(grants) == []
  end

  test "child worker key minting rejects child packages not ready for worker", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-NOT-READY-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-NOT-READY-CHILD")
    assert {:ok, _child} = WorkPackageRepository.update(repo, child_id, %{status: "claimed"})

    grants_before = repo.aggregate(AccessGrant, :count)

    response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "child_not_ready_for_worker"
    assert repo.aggregate(AccessGrant, :count) == grants_before
  end

  test "child worker key minting revalidates ready state inside the mint transaction", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-RACE-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-RACE-CHILD")
    grants_before = repo.aggregate(AccessGrant, :count)
    MintReadyRaceRepo.arm(child_id)

    response =
      try do
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "mint_child_worker_key",
            "method" => "tools/call",
            "params" => %{
              "name" => "mint_child_worker_key",
              "arguments" => %{"work_package_id" => child_id}
            }
          },
          config: test_mcp_config(MintReadyRaceRepo),
          session: architect_session
        )
      after
        MintReadyRaceRepo.disarm()
      end

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "child_not_ready_for_worker"
    assert repo.aggregate(AccessGrant, :count) == grants_before

    assert {:ok, child} = WorkPackageRepository.get(repo, child_id)
    assert child.status == "ready_for_worker"
  end

  test "child worker key minting revalidates child scope after ready-state guard", %{repo: repo} do
    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-SCOPE-RACE-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-SCOPE-RACE-CHILD")

    assert {:ok, sibling_anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-MINT-SCOPE-RACE-SIBLING",
                 kind: "mcp",
                 phase_id: @architect_phase_id,
                 base_branch: anchor.base_branch,
                 repo: anchor.repo,
                 status: "planning"
               )
             )

    grants_before = repo.aggregate(AccessGrant, :count)
    MintChildScopeRaceRepo.arm(child_id, %{parent_id: sibling_anchor.id})

    response =
      try do
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "mint_child_worker_key",
            "method" => "tools/call",
            "params" => %{
              "name" => "mint_child_worker_key",
              "arguments" => %{"work_package_id" => child_id}
            }
          },
          config: test_mcp_config(MintChildScopeRaceRepo),
          session: architect_session
        )
      after
        MintChildScopeRaceRepo.disarm()
      end

    assert get_in(response, ["error", "code"]) == -32_003
    assert get_in(response, ["error", "data", "reason"]) == "outside_session_scope"
    assert repo.aggregate(AccessGrant, :count) == grants_before

    assert {:ok, child} = WorkPackageRepository.get(repo, child_id)
    assert child.parent_id == anchor.id
  end

  test "child worker key minting rejects revoked or expired parent architect grant inside transaction", %{repo: repo} do
    for {suffix, grant_update, expected_reason} <- [
          {"REVOKED", %{revoked_at: DateTime.utc_now(:microsecond)}, "revoked"},
          {"EXPIRED", %{expires_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)}, "expired"}
        ] do
      {_anchor, architect_session} =
        create_architect_session(repo, "SYMPP-P7-002-MINT-PARENT-#{suffix}-ANCHOR", [
          "create:child_work_package",
          "mint:child_worker_key",
          "read:phase"
        ])

      child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-PARENT-#{suffix}-CHILD")
      grants_before = repo.aggregate(AccessGrant, :count)
      MintParentGrantRaceRepo.arm(architect_session.assignment.grant_id, grant_update)

      response =
        try do
          MCPHarness.request(
            %{
              "jsonrpc" => "2.0",
              "id" => "mint_child_worker_key",
              "method" => "tools/call",
              "params" => %{
                "name" => "mint_child_worker_key",
                "arguments" => %{"work_package_id" => child_id}
              }
            },
            config: test_mcp_config(MintParentGrantRaceRepo),
            session: architect_session
          )
        after
          MintParentGrantRaceRepo.disarm()
        end

      assert get_in(response, ["error", "code"]) == -32_001
      assert get_in(response, ["error", "data", "reason"]) == expected_reason
      assert repo.aggregate(AccessGrant, :count) == grants_before
    end
  end
end
