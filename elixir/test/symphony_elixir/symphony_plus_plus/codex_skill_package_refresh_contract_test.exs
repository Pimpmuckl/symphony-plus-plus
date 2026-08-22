Code.require_file("codex_skill_package_case_test.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageRefreshContractTest do
  use SymphonyElixir.SymphonyPlusPlus.CodexSkillPackageCase, async: true

  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  test "ToolCatalog lists the current worker tools" do
    assert ToolCatalog.worker_tools() == @worker_tools
    assert ToolCatalog.contract_bound_worker_tools() -- ["sympp.health", "release_current_assignment"] == @worker_tools
    refute "request_context" in ToolCatalog.worker_tools()
  end

  test "runtime claim schema and worker prompt align on ledger local claim inputs" do
    claim_schema = ToolCatalog.worker_tool_input_schema("claim_local_assignment")

    assert claim_schema["required"] == ["work_package_id"]
    assert Map.keys(claim_schema["properties"]) |> Enum.sort() == ["claimed_by", "work_package_id"]

    prompt = File.read!(@mcp_plugin_prompt_path)

    for marker <- [
          "WorkPackage: <WORK_PACKAGE_ID>",
          ~s({"work_package_id":"<WORK_PACKAGE_ID>"}),
          "Include `claimed_by` only when"
        ] do
      assert prompt =~ marker
    end

    refute prompt =~ "claimed_by: <stable-worker-identity>"
  end

  test "runtime tool schemas use model enum values" do
    decision_schema = ToolCatalog.architect_tool_input_schema("record_decision")
    work_package_schema = ToolCatalog.architect_tool_input_schema("slice_work_request")

    assert get_in(decision_schema, ["properties", "source_type", "enum"]) ==
             DecisionLogEntry.source_types()

    assert get_in(work_package_schema, ["properties", "work_packages", "items", "properties", "kind", "enum"]) ==
             WorkPackage.executable_kinds()

    assert work_package_schema["required"] == ["work_packages"]

    assert get_in(work_package_schema, ["properties", "work_packages", "items", "required"]) == [
             "title",
             "goal",
             "acceptance_criteria"
           ]
  end
end
