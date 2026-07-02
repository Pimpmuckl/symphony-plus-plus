Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageRefreshContractTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  test "template skill mirrors installable skill metadata" do
    skill = File.read!(@skill_path)
    template_skill = File.read!(@template_skill_path)

    assert frontmatter(skill) == frontmatter(template_skill)

    for file <- ["worker_prompt.md", "mcp_wiring.md", "handoff.md"] do
      assert File.exists?(Path.join(@template_references_dir, file))
    end
  end

  test "handoff docs include skill installation and MCP setup" do
    handoff = File.read!(@handoff_path)
    runbook = File.read!(@runbook_path)

    for content <- [handoff, runbook] do
      assert content =~ ".codex/skills/symphony-work-package/"
      assert content =~ "plugins/symphony-plus-plus-mcp/"
      assert content =~ "mcp_wiring.md"
      assert content =~ "templates/worker_agent_prompt.md"
    end
  end

  test "MCP contract lists the current worker tools" do
    contract =
      @contract_path
      |> File.read!()
      |> Jason.decode!()

    actual_tools = get_in(contract, ["discovery_policy", "unbound_schema_sets", "worker_tools"])
    bound_worker_tools = get_in(contract, ["discovery_policy", "bound_worker_tools"]) -- ["sympp.health", "release_current_assignment"]

    assert actual_tools == @worker_tools
    assert bound_worker_tools == @worker_tools
    refute "request_context" in actual_tools
  end

  test "MCP contract and worker prompts align on ledger local claim inputs" do
    contract =
      @contract_path
      |> File.read!()
      |> Jason.decode!()

    worker_claim = get_in(contract, ["claim_policy", "worker_claim"])
    tool_schemas = Map.new(contract["tool_schemas"], &{&1["name"], &1})
    claim_tool = Map.fetch!(tool_schemas, "claim_local_assignment")

    assert worker_claim["tool"] == "claim_local_assignment"
    assert worker_claim["required_arguments"] == ["work_package_id"]

    assert worker_claim["optional_arguments"] == ["claimed_by"]

    assert claim_tool["required_arguments"] == [
             "work_package_id"
           ]

    assert claim_tool["optional_arguments"] == ["claimed_by"]

    assert get_in(contract, ["claim_policy", "reclaim_policy"]) =~ "Stale leases may be reclaimed"
    assert get_in(contract, ["claim_policy", "secret_policy"]) =~ "do not require raw grant secrets"

    prompt = File.read!(@template_prompt_path)

    for marker <- [
          "WorkPackage: <WORK_PACKAGE_ID>",
          ~s({"work_package_id":"<WORK_PACKAGE_ID>"}),
          "Include `claimed_by` only when"
        ] do
      assert prompt =~ marker
    end

    refute prompt =~ "claimed_by: <stable-worker-identity>"
  end

  test "MCP contract enum constraints mirror runtime values" do
    contract =
      @contract_path
      |> File.read!()
      |> Jason.decode!()

    tool_schemas = Map.new(contract["tool_schemas"], &{&1["name"], &1})

    assert get_in(tool_schemas, ["record_work_request_decision", "argument_constraints", "source_type"]) ==
             DecisionLogEntry.source_types()

    assert get_in(tool_schemas, ["add_work_request_planned_slice", "argument_constraints", "work_package_kind"]) ==
             WorkPackage.planned_slice_kinds()
  end
end
