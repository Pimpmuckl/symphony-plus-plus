defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, SoloTools}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog.{InputSchemas, SurfaceSpecs}

  @health_tool "sympp.health"
  @mcp_contract_schema_version "sympp-mcp-contract.v1"
  @mcp_contract_health_fields [
    "ledger",
    "mode",
    "source.mcp_contract.fingerprint",
    "source.mcp_contract.schema_version",
    "source.revision",
    "status",
    "version"
  ]
  @solo_tools SoloTools.tool_names()
  @assignment_release_tool "release_current_assignment"
  @bootstrap_tools ["create_work_request"]
  @local_operator_tools ["add_work_request_comment", "record_work_request_operator_decision", "summarize_failed_mcp_calls"]
  @blocker_closeout_decisions ["resolved", "still_active"]
  @local_assignment_claim_tool "claim_local_assignment"
  @local_architect_assignment_claim_tool "claim_local_architect_assignment"
  @session_claim_tools [@local_assignment_claim_tool, @local_architect_assignment_claim_tool]
  @local_assignment_claim_hidden_worker_arguments ["repo", "base_branch", "work_request_id", "branch", "worktree_path", "caller_id"]
  @session_scoped_worker_tools [
    "update_task_plan",
    "append_finding",
    "append_progress",
    "report_blocker",
    "resolve_blocker",
    "abandon",
    "add_comment",
    "list_comments",
    "resolve_comment",
    "read_guidance_request",
    "request_scope_expansion",
    "attach_branch",
    "attach_pr",
    "sync_pr",
    "submit_review_package",
    "complete_review"
  ]
  @worker_tools [
    "get_current_assignment",
    "read_context",
    "read_task_plan",
    "update_task_plan",
    "append_finding",
    "append_progress",
    "report_blocker",
    "resolve_blocker",
    "abandon",
    "add_comment",
    "list_comments",
    "resolve_comment",
    "read_guidance_request",
    "request_scope_expansion",
    "attach_branch",
    "attach_pr",
    "sync_pr",
    "submit_review_package",
    "complete_review",
    "mark_ready"
  ]
  @shared_worker_architect_tools ["add_comment", "list_comments", "resolve_comment", "resolve_blocker", "read_guidance_request"]
  @architect_tools [
    "create_child_work_package",
    "mint_child_worker_key",
    "revoke_child_worker_key",
    "list_work_requests",
    "read_work_request",
    "read_plan",
    "add_comment",
    "list_comments",
    "resolve_comment",
    "resolve_blocker",
    "read_delivery_board",
    "reconcile_work_request",
    "accept_review_rework",
    "cleanup_work_request_work_package_runtime",
    "record_work_package_delivery",
    "revoke_work_package_worker_key",
    "list_guidance_requests",
    "read_guidance_request",
    "answer_guidance_request",
    "escalate_guidance_request",
    "set_work_request_status",
    "ask_question",
    "answer_question",
    "answer_question_and_record_decision",
    "close_question",
    "record_decision",
    "slice_work_request",
    "update_work_package",
    "upsert_group",
    "delete_group",
    "upsert_dependency",
    "delete_dependency",
    "skip_work_package",
    "dispatch_work_package",
    "prepare_work_package_worktree",
    "cleanup_work_package_worktree",
    "read_child_status",
    "approve_scope_expansion",
    "read_phase_board",
    "approve_child_ready_state",
    "merge_child_into_phase"
  ]
  @known_tools Enum.uniq(
                 [@health_tool, @assignment_release_tool] ++
                   @solo_tools ++
                   @bootstrap_tools ++
                   @local_operator_tools ++
                   @session_claim_tools ++
                   @worker_tools ++ @architect_tools
               )
  @work_request_policy_tools [
    "list_work_requests",
    "read_work_request",
    "read_plan",
    "read_delivery_board",
    "set_work_request_status",
    "ask_question",
    "answer_question",
    "answer_question_and_record_decision",
    "close_question",
    "record_decision",
    "slice_work_request",
    "update_work_package",
    "upsert_group",
    "delete_group",
    "upsert_dependency",
    "delete_dependency",
    "skip_work_package",
    "dispatch_work_package"
  ]
  @current_work_request_write_tools [
    "slice_work_request",
    "update_work_package",
    "upsert_group",
    "delete_group",
    "upsert_dependency",
    "delete_dependency",
    "skip_work_package"
  ]
  @current_work_request_tools @current_work_request_write_tools ++
                                [
                                  "read_delivery_board",
                                  "reconcile_work_request",
                                  "accept_review_rework",
                                  "cleanup_work_request_work_package_runtime",
                                  "record_work_package_delivery",
                                  "revoke_work_package_worker_key",
                                  "dispatch_work_package"
                                ]
  @delivery_policy_tools [
    "reconcile_work_request",
    "accept_review_rework",
    "cleanup_work_request_work_package_runtime",
    "record_work_package_delivery",
    "revoke_work_package_worker_key"
  ]
  @work_request_product_tree_views ["groups_only", "groups_with_work_package_refs", "groups_with_work_packages"]
  @type tool_name :: String.t()
  @type input_schema :: map()
  @type tool_spec :: map()

  @spec health_tool() :: tool_name()
  def health_tool, do: @health_tool

  @spec mcp_contract_schema_version() :: String.t()
  def mcp_contract_schema_version, do: @mcp_contract_schema_version

  @spec mcp_contract_health_fields() :: [String.t()]
  def mcp_contract_health_fields, do: @mcp_contract_health_fields

  @spec solo_tools() :: [tool_name()]
  def solo_tools, do: @solo_tools

  @spec assignment_release_tool() :: tool_name()
  def assignment_release_tool, do: @assignment_release_tool

  @spec bootstrap_tools() :: [tool_name()]
  def bootstrap_tools, do: @bootstrap_tools

  @spec local_operator_tools() :: [tool_name()]
  def local_operator_tools, do: @local_operator_tools

  @spec blocker_closeout_decisions() :: [String.t()]
  def blocker_closeout_decisions, do: @blocker_closeout_decisions

  @spec local_assignment_claim_tool() :: tool_name()
  def local_assignment_claim_tool, do: @local_assignment_claim_tool

  @spec local_architect_assignment_claim_tool() :: tool_name()
  def local_architect_assignment_claim_tool, do: @local_architect_assignment_claim_tool

  @spec session_claim_tools() :: [tool_name()]
  def session_claim_tools, do: @session_claim_tools

  @spec worker_tools() :: [tool_name()]
  def worker_tools, do: @worker_tools

  @spec contract_unbound_tools() :: [tool_name()]
  def contract_unbound_tools, do: [@health_tool, @assignment_release_tool] ++ @solo_tools ++ @session_claim_tools

  @spec contract_trusted_local_http_extra_tools() :: [tool_name()]
  def contract_trusted_local_http_extra_tools, do: @bootstrap_tools ++ @local_operator_tools ++ ["list_comments"]

  @spec contract_bound_worker_tools() :: [tool_name()]
  def contract_bound_worker_tools, do: [@health_tool, @assignment_release_tool] ++ @worker_tools

  @spec contract_bound_architect_tools() :: [tool_name()]
  def contract_bound_architect_tools, do: [@health_tool, @assignment_release_tool, "get_current_assignment"] ++ @architect_tools

  @spec hidden_worker_argument_keys(tool_name()) :: [String.t()]
  def hidden_worker_argument_keys(@local_assignment_claim_tool), do: @local_assignment_claim_hidden_worker_arguments
  def hidden_worker_argument_keys(name) when name in @session_scoped_worker_tools, do: ["work_package_id"]
  def hidden_worker_argument_keys(_name), do: []

  @spec shared_worker_architect_tools() :: [tool_name()]
  def shared_worker_architect_tools, do: @shared_worker_architect_tools

  @spec architect_tools() :: [tool_name()]
  def architect_tools, do: @architect_tools

  @spec known_tool?(term()) :: boolean()
  def known_tool?(name), do: name in @known_tools

  @spec known_tools() :: [tool_name()]
  def known_tools, do: @known_tools

  @spec work_request_policy_tools() :: [tool_name()]
  def work_request_policy_tools, do: @work_request_policy_tools

  @spec delivery_policy_tools() :: [tool_name()]
  def delivery_policy_tools, do: @delivery_policy_tools

  @spec work_request_product_tree_views() :: [String.t()]
  def work_request_product_tree_views, do: @work_request_product_tree_views

  @doc false
  @spec current_work_request_tool?(tool_name()) :: boolean()
  def current_work_request_tool?(name), do: name in @current_work_request_tools

  @spec solo_tool_input_schema(tool_name()) :: input_schema()
  defdelegate solo_tool_input_schema(name), to: InputSchemas

  @spec bootstrap_tool_input_schema(tool_name()) :: input_schema()
  defdelegate bootstrap_tool_input_schema(name), to: InputSchemas

  @spec local_operator_tool_input_schema(tool_name()) :: input_schema()
  defdelegate local_operator_tool_input_schema(name), to: InputSchemas

  @spec local_architect_assignment_claim_tool_input_schema() :: input_schema()
  defdelegate local_architect_assignment_claim_tool_input_schema(), to: InputSchemas

  @spec assignment_release_tool_input_schema() :: input_schema()
  defdelegate assignment_release_tool_input_schema(), to: InputSchemas

  @spec worker_tool_input_schema(tool_name()) :: input_schema()
  defdelegate worker_tool_input_schema(name), to: InputSchemas

  @spec architect_tool_input_schema(tool_name()) :: input_schema()
  defdelegate architect_tool_input_schema(name), to: InputSchemas

  @spec claimable_tool_specs(Config.t()) :: [tool_spec()]
  defdelegate claimable_tool_specs(config), to: SurfaceSpecs

  @spec callable_claim_tool_specs(Config.t()) :: [tool_spec()]
  defdelegate callable_claim_tool_specs(config), to: SurfaceSpecs

  @spec unbound_tool_specs_for_config(Config.t()) :: [tool_spec()]
  defdelegate unbound_tool_specs_for_config(config), to: SurfaceSpecs

  @spec callable_unbound_tool_specs_for_config(Config.t()) :: [tool_spec()]
  defdelegate callable_unbound_tool_specs_for_config(config), to: SurfaceSpecs

  @spec startup_tool_specs(:full | :worker | :architect | :coordinator | :solo, Config.t()) :: [tool_spec()]
  defdelegate startup_tool_specs(profile, config), to: SurfaceSpecs

  @spec architect_session_tool_specs(keyword()) :: [tool_spec()]
  def architect_session_tool_specs(opts \\ []), do: SurfaceSpecs.architect_session_tool_specs(opts)

  @spec worker_session_tool_specs() :: [tool_spec()]
  defdelegate worker_session_tool_specs(), to: SurfaceSpecs

  @spec lean_tool_specs([tool_spec()]) :: [tool_spec()]
  defdelegate lean_tool_specs(specs), to: SurfaceSpecs

  @spec local_operator_tool_specs() :: [tool_spec()]
  defdelegate local_operator_tool_specs(), to: SurfaceSpecs
end
